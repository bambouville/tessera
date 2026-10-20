#!/usr/bin/env python3
"""Read every discovered JSONL session. Private manifest/results, never raw data in git.

This is the native physical-file stage of the full-corpus gate. Native Codex
store inventory, differential semantic comparison and incremental replay are
separate required stages; this runner does not claim they passed.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import time


def discover(roots):
    candidates, errors, exclusions = [], [], collections.Counter()
    seen = set()
    for provider, root in roots:
        pending = [root]
        while pending:
            directory = pending.pop()
            try:
                with os.scandir(directory) as entries:
                    for entry in entries:
                        if entry.is_symlink():
                            exclusions['symlink'] += 1
                        elif entry.is_dir(follow_symlinks=False):
                            pending.append(Path(entry.path))
                        elif entry.name.endswith('.jsonl'):
                            info = entry.stat(follow_symlinks=False)
                            if not stat.S_ISREG(info.st_mode):
                                exclusions['non_regular'] += 1
                                continue
                            identity = (info.st_dev, info.st_ino)
                            if identity in seen:
                                exclusions['duplicate_inode'] += 1
                                continue
                            seen.add(identity)
                            candidates.append({'provider': provider, 'path': entry.path, 'bytes': info.st_size,
                                               'source_root': str(root),
                                               'mtime_ns': info.st_mtime_ns, 'inode': info.st_ino, 'device': info.st_dev})
            except OSError as error:
                errors.append({'provider': provider, 'path': str(directory), 'error': type(error).__name__})
    return sorted(candidates, key=lambda value: (value['provider'], -value['bytes'], value['path'])), errors, dict(exclusions)


def private_json(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--root', action='append', help='provider=absolute-path; default all local Codex/Claude JSONL roots')
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--snapshot', action='store_true', help='audit private finite file snapshots, using APFS clones when available')
    args = parser.parse_args()
    if not 1 <= args.timeout <= 600:
        parser.error('timeout must be 1..600 seconds')
    binary = args.binary.resolve(strict=True)
    output = args.output.resolve()
    # Make accidental git publication impossible by rejecting any in-repo run.
    if any((parent / '.git').exists() for parent in [output, *output.parents]):
        parser.error('private corpus evidence must be outside the repository')
    output.mkdir(mode=0o700, parents=False)
    roots = []
    for value in args.root or [f'codex={Path.home() / ".codex/sessions"}',
                              f'codex={Path.home() / ".codex/archived_sessions"}',
                              f'claude={Path.home() / ".claude/projects"}']:
        provider, separator, path = value.partition('=')
        if not separator or provider not in {'claude', 'codex'} or not Path(path).is_absolute():
            parser.error('root must be codex=/absolute/path or claude=/absolute/path')
        roots.append((provider, Path(path)))
    candidates, errors, exclusions = discover(roots)
    if args.snapshot:
        snapshot_root = output / 'snapshots'
        snapshot_root.mkdir(mode=0o700)
        for index, candidate in enumerate(candidates):
            target = snapshot_root / f'{index:06d}.jsonl'
            # clonefile-backed cp on macOS captures an immutable point-in-time
            # inode without duplicating gigabytes of private session blocks.
            cloned = False
            if os.uname().sysname == 'Darwin':
                cloned = subprocess.run(['/bin/cp', '-c', candidate['path'], str(target)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            if not cloned:
                # Copy a finite initial prefix, never chase a growing session.
                with open(candidate['path'], 'rb') as source, target.open('xb') as destination:
                    before = os.fstat(source.fileno())
                    remaining = before.st_size
                    while remaining:
                        chunk = source.read(min(1048576, remaining))
                        if not chunk: raise RuntimeError('source truncated during snapshot')
                        destination.write(chunk); remaining -= len(chunk)
                    after = os.fstat(source.fileno())
                    if (after.st_size, after.st_mtime_ns) != (before.st_size, before.st_mtime_ns):
                        raise RuntimeError('non-atomic snapshot source changed; retry')
            target.chmod(0o600)
            info = target.stat()
            candidate['original_path'] = candidate['path']
            candidate.update(path=str(target), bytes=info.st_size, mtime_ns=info.st_mtime_ns, inode=info.st_ino, device=info.st_dev)
    private_json(output / 'private-manifest.json', {'candidates': candidates, 'errors': errors, 'exclusions': exclusions})
    print(json.dumps({'candidates': len(candidates), 'discovery_errors': len(errors), 'exclusions': exclusions}), flush=True)
    counts, types, dispositions = collections.Counter(), collections.Counter(), collections.Counter()
    failures = changed = deferred_files = deferred_bytes = 0
    started = time.monotonic()
    for index, candidate in enumerate(candidates):
        row = {'index': index, 'provider': candidate['provider'], 'file_bytes': candidate['bytes']}
        try:
            process = subprocess.run([str(binary), 'jsonl', '--provider', candidate['provider'], '--path', candidate['path'], '--audit'],
                capture_output=True, timeout=args.timeout)
            row['exit_code'] = process.returncode
            if len(process.stdout) > 1048576 or process.stderr:
                raise ValueError('diagnostic_or_output_limit')
            row['native'] = json.loads(process.stdout)
            after = os.stat(candidate['path'], follow_symlinks=False)
            row['changed_during_read'] = (after.st_size, after.st_mtime_ns, after.st_dev, after.st_ino) != (
                candidate['bytes'], candidate['mtime_ns'], candidate['device'], candidate['inode'])
            changed += row['changed_during_read']
            tail = row['native'].get('deferredTailBytes', 0)
            deferred_files += tail > 0
            deferred_bytes += tail
            counts[candidate['provider']] += 1
            for name, count in row['native'].get('types', {}).items(): types[candidate['provider'] + ':' + name] += count
            for name, count in row['native'].get('dispositions', {}).items(): dispositions[candidate['provider'] + ':' + name] += count
            if process.returncode: failures += 1
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            row['failure'] = type(error).__name__
            failures += 1
        private_json(output / f'file-{index:06d}.json', row)
        if (index + 1) % 100 == 0:
            print(json.dumps({'completed': index + 1, 'total': len(candidates), 'failures': failures}), flush=True)
    summary = {'stage': 'physical_jsonl_native_audit_only', 'files': dict(counts), 'candidates': len(candidates),
               'discovery_errors': len(errors), 'exclusions': exclusions, 'failures': failures,
               'changed_during_read': changed, 'deferred_tail_files': deferred_files, 'deferred_tail_bytes': deferred_bytes,
               'finite_snapshots': args.snapshot,
               'types': dict(types), 'dispositions': dict(dispositions), 'elapsed_seconds': time.monotonic() - started,
               'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
               'pending_gates': ['native_store_inventory', 'semantic_differential', 'incremental_replay', 'branch_history']}
    private_json(output / 'private-summary.json', summary)
    print(json.dumps({key: value for key, value in summary.items() if key != 'types'}), flush=True)
    if failures or errors or changed or deferred_files:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
