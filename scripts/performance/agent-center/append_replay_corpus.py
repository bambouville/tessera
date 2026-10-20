#!/usr/bin/env python3
"""Private all-file append selection equivalence, not an upstream semantic oracle.

The real native index survives arbitrary byte-prefix appends (including partial
lines). A separate fresh index checks every selected source span, stable ID,
parent/turn identity, canonical order and revision ordinal at each checkpoint.
No authored data, provider IDs or source paths enter the content-free report.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from codex_completed_projection_corpus import line
from native_first_page import Guard, clone


def audit(source, provider, binary, root, checkpoints):
    with tempfile.TemporaryDirectory(prefix='prefix-', dir=root) as temporary:
        private = Path(temporary)
        snapshot = private / 'snapshot.jsonl'; clone(source, snapshot)
        target = private / 'growing.jsonl'; target.touch(mode=0o600)
        size = snapshot.stat().st_size
        positions = sorted({0, size, *(size * n // checkpoints for n in range(1, checkpoints))})
        samples = []
        with subprocess.Popen([str(binary), provider, str(target)], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
                              start_new_session=True) as process:
            guard = Guard(process)
            try:
                with snapshot.open('rb') as original, target.open('ab', buffering=0) as growing:
                    position = 0
                    for end in positions:
                        while position < end:
                            chunk = original.read(min(65536, end - position))
                            if not chunk: raise RuntimeError('snapshot_short_read')
                            view = memoryview(chunk)
                            while view:
                                count = growing.write(view)
                                if not count: raise RuntimeError('prefix_short_write')
                                view = view[count:]
                            position += len(chunk)
                        start = time.monotonic_ns()
                        process.stdin.write(b'refresh\n')
                        value = line(process, maximum=4096, deadline=time.monotonic() + 120, allow_error=True)
                        if 'error' in value:
                            return dict(error=value['error'], checkpoints=samples, sourceBytes=size)
                        if value.get('matched') is not True or value.get('sourceEnd') != end:
                            raise RuntimeError('checkpoint_incomplete')
                        if not 0 < value.get('peakRSSBytes', 0) <= 256 * 1024 * 1024:
                            raise RuntimeError('native_peak_memory_budget')
                        samples.append(dict(value, wallMS=(time.monotonic_ns() - start) / 1e6))
                    # Idempotent refresh must not turn a final incomplete line
                    # into a record, nor change selection without new bytes.
                    process.stdin.write(b'refresh\n')
                    repeated = line(process, maximum=4096, allow_error=True)
                    if repeated.get('records') != samples[-1]['records'] or repeated.get('matched') is not True:
                        raise RuntimeError('idempotent_refresh_mismatch')
                process.stdin.close()
                if process.wait(timeout=5): raise RuntimeError('worker_exit')
            finally:
                guard.close()
                if process.poll() is None: process.kill(); process.wait(timeout=5)
            failure = guard.failure
            # getrusage is the lifetime peak oracle for a worker shorter than
            # the sampler interval; a running/failed sampler is never waived.
            if failure == 'rss_guard_incomplete' and not guard.thread.is_alive() and samples:
                failure = None
            return dict(sourceBytes=size, checkpoints=samples, sampledPeakBytes=guard.peak,
                        resourceError=failure, matched=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--driver', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--checkpoints', type=int, default=8)
    args = parser.parse_args()
    output = args.output.resolve()
    if any((path / '.git').exists() for path in [output, *output.parents]): parser.error('private output must be outside Git')
    if not 2 <= args.checkpoints <= 64: parser.error('checkpoints must be 2..64')
    raw = args.manifest.read_bytes(); candidates = json.loads(raw)['candidates']
    if not candidates or any(item['provider'] not in ('codex', 'claude') for item in candidates):
        parser.error('complete Codex/Claude finite manifest required')
    os.umask(0o077); output.mkdir(mode=0o700, parents=True, exist_ok=False)
    binary = output / 'driver'; clone(args.driver, binary); binary.chmod(0o700)
    scripts = {}
    for name in ('append_replay_corpus.py', 'native_first_page.py', 'codex_completed_projection_corpus.py'):
        source = Path(__file__).with_name(name); clone(source, output / name)
        scripts[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    report = dict(stage='append_selection_vs_fresh_index_not_upstream_semantic_parity',
                  manifestSHA256=hashlib.sha256(raw).hexdigest(), driverSHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  scripts=scripts, expectedFiles=len(candidates), checkpoints=args.checkpoints, results=[])
    for ordinal, item in enumerate(candidates):
        try: result = audit(Path(item['path']), item['provider'], binary, output, args.checkpoints)
        except Exception as error: result = dict(error=str(error) if isinstance(error, RuntimeError) else type(error).__name__)
        report['results'].append(dict(ordinal=ordinal, provider=item['provider'], **result))
        report['files'] = len(report['results'])
        report['failures'] = sum(not row.get('matched') or bool(row.get('resourceError')) for row in report['results'])
        report['status'] = 'passed_scoped_checks' if report['files'] == report['expectedFiles'] and not report['failures'] else 'failed_or_incomplete'
        pending = output / 'report.pending'; pending.write_text(json.dumps(report, indent=2) + '\n')
        os.replace(pending, output / 'content-free-results.json')
        print(json.dumps(dict(files=report['files'], failures=report['failures'])), flush=True)
    return int(report['status'] != 'passed_scoped_checks')


if __name__ == '__main__': raise SystemExit(main())
