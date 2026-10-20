#!/usr/bin/env python3
"""TEST ONLY: ask an offline Codex process to materialize one finite clone.

Never used by Tessera's production reader. No turn/start, model request,
credentials, live database mutation, or live provider attachment. macOS Seatbelt
denies network and writes outside the newly created private probe directory.
The only thread/resume target is the exact copied transcript; excludeTurns
avoids requesting an unbounded history response. Results contain counts only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import sqlite3
import stat
import subprocess
import time
from native_first_page import Guard


class RPC:
    def __init__(self, process):
        self.process = process; self.buffer = bytearray(); self.sequence = 0

    def send(self, value):
        data = json.dumps(value, separators=(',', ':')).encode() + b'\n'
        if len(data) > 8192: raise RuntimeError('probe_request_budget')
        self.process.stdin.write(data); self.process.stdin.flush()

    def call(self, method, params):
        if method not in ('initialize', 'thread/read', 'thread/resume', 'thread/items/list'):
            raise RuntimeError('probe_method_not_allowed')
        self.sequence += 1
        self.send(dict(id=self.sequence, method=method, params=params))
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if b'\n' in self.buffer:
                raw, _, rest = self.buffer.partition(b'\n'); self.buffer = bytearray(rest)
                if not raw: continue
                value = json.loads(raw)
                # Notifications are bounded and discarded, never logged.
                if value.get('id') == self.sequence:
                    if 'error' in value:
                        message = str(value['error'].get('message', '')).lower()
                        # Fixed diagnostic labels only, never the provider's
                        # free-text error (which may contain user paths/data).
                        return dict(errorCode=value['error'].get('code'), errorLabels=[word for word in
                            ('archived', 'subagent', 'parent', 'rollout', 'not found', 'permission',
                             'model', 'session', 'history', 'config', 'unsupported', 'fork', 'agent')
                            if word in message])
                    return value['result']
                continue
            if not select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
                break
            data = os.read(self.process.stdout.fileno(), 65536)
            if not data: raise RuntimeError('probe_server_exited')
            self.buffer.extend(data)
            if len(self.buffer) > 4 * 1024 * 1024: raise RuntimeError('probe_response_budget')
        raise RuntimeError('probe_rpc_timeout')


def sandbox_profile(output, executable):
    # Paths are generated locally; escaping is still explicit, not shell text.
    quoted = lambda value: json.dumps(str(value))
    return ('(version 1)(allow default)(deny network*)(deny mach-lookup)'
            '(deny process-fork)(deny process-exec)(deny file-read-data)(deny file-write*)'
            f'(allow process-exec (literal {quoted(executable)}))'
            f'(allow file-read-data (subpath {quoted(output)})'
            ' (subpath "/System/Library") (subpath "/usr/lib")'
            ' (subpath "/Library/Apple/System/Library") (subpath "/private/var/db/dyld")'
            ' (subpath "/System/Volumes/Preboot/Cryptexes/OS/System/Library")'
            ' (subpath "/System/Volumes/Preboot/Cryptexes/OS/usr/lib")'
            ' (literal "/System/Volumes/Preboot")'
            ' (literal "/System/Volumes/Preboot/Cryptexes/OS")'
            ' (literal "/") (literal "/System") (literal "/System/Volumes")'
            ' (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))'
            f'(allow file-write* (subpath {quoted(output)}) (literal "/dev/null"))'
            )


def stable_copy(source, target, expected=None, original=None):
    """No-follow regular-file copy; verify identity and stability around the copy."""
    source = Path(source)
    if source != source.resolve(strict=True): raise RuntimeError('probe_source_symlink')
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid() or before.st_nlink != 1:
            raise RuntimeError('probe_source_not_owned_regular_single_link')
        if expected is not None and any(expected[key] != value for key, value in (
            ('device', before.st_dev), ('inode', before.st_ino),
            ('bytes', before.st_size), ('mtime_ns', before.st_mtime_ns))):
            raise RuntimeError('probe_source_manifest_mismatch')
        if original is not None:
            try: live = os.stat(original)
            except FileNotFoundError: live = None
            if live is not None and (live.st_dev, live.st_ino) == (before.st_dev, before.st_ino):
                raise RuntimeError('probe_source_is_live_original')
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with target.open('xb') as destination:
            shutil.copyfileobj(stream, destination, 1024 * 1024)
        after = os.fstat(stream.fileno())
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
        if identity(before) != identity(after) or identity(before) != identity(os.stat(source, follow_symlinks=False)):
            raise RuntimeError('probe_source_changed')
    target.chmod(0o600)


def finite_directory(path, prefix):
    path = Path(path)
    if path != path.resolve(strict=True) or not str(path).startswith(prefix):
        raise RuntimeError('probe_finite_source_root')
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid():
        raise RuntimeError('probe_source_directory_permissions')
    return path


def copy_database_snapshot(source, target):
    """Copy the entire stable, completed private snapshot, including its WAL.

    A completed read-server audit can leave a WAL without an active process.
    Verify the complete file set before/after; recovery occurs only on the new
    owned copy. Never open the source database through SQLite or copy a live
    main file alone.
    """
    def identities():
        result = {}
        for suffix in ('', '-wal', '-shm', '-journal'):
            path = Path(str(source) + suffix)
            if path.exists():
                value = path.lstat()
                result[suffix] = (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        return result
    before = identities()
    for suffix in before:
        stable_copy(Path(str(source) + suffix), Path(str(target) + suffix))
    if before != identities(): raise RuntimeError('probe_database_snapshot_changed')
    with sqlite3.connect(target) as database:
        if database.execute('PRAGMA quick_check').fetchone() != ('ok',):
            raise RuntimeError('probe_snapshot_integrity')
        database.execute('PRAGMA wal_checkpoint(TRUNCATE)')


def validate_snapshot(snapshot, manifest_hash):
    parent = snapshot.parent
    if parent.name.startswith('tessera-native-window-coverage-'):
        finite_directory(parent, '/private/tmp/tessera-native-window-coverage-')
        report = json.loads((parent / 'content-free-results.json').read_bytes())
        if not report.get('tested_threads') or report.get('failed_threads'):
            raise RuntimeError('probe_snapshot_audit_incomplete')
    else:
        finite_directory(parent, '/private/tmp/tessera-native-reference-')
        report = json.loads((parent / 'content-free-results.json').read_bytes())
        if (report.get('stage') != 'offline_private_clone_materialization_not_live_attachment'
            or report.get('manifestSHA256') != manifest_hash
            or not all(report.get(key) is True for key in ('isolationPreflightPassed',
                'resumedPrivateClone', 'materializationAdvanced', 'ownedProcessExited'))
            or any(report.get(key) for key in ('failure', 'guardFailure', 'cleanupErrors', 'resumeErrorCode'))):
            raise RuntimeError('probe_snapshot_materialization_incomplete')
    if snapshot != parent / 'codex': raise RuntimeError('probe_snapshot_provider_directory')
    finite_directory(snapshot, str(parent) + '/codex')
    return hashlib.sha256((parent / 'content-free-results.json').read_bytes()).hexdigest()


def copy_lineage(candidates, candidate, manifest_directory, provider_home):
    """Only manifest-owned ancestors; no original header path becomes authority."""
    by_id = {}
    for row in candidates:
        if row.get('provider') == 'codex':
            identifier = Path(row['original_path']).stem[-36:]
            if identifier in by_id: raise RuntimeError('probe_manifest_duplicate_thread')
            by_id[identifier] = row
    relocated = {}; first = None
    for _ in range(8):
        source = Path(candidate['path'])
        if source.parent != manifest_directory / 'snapshots': raise RuntimeError('probe_lineage_source_root')
        target = provider_home / 'sessions' / Path(candidate['original_path']).name
        stable_copy(source, target, candidate, candidate['original_path'])
        with target.open('rb') as stream: header = stream.readline(262145)
        if len(header) > 262144: raise RuntimeError('probe_header_budget')
        metadata = json.loads(header)
        if metadata.get('type') != 'session_meta': raise RuntimeError('probe_header_type')
        thread = metadata['payload']['id']
        if thread != Path(candidate['original_path']).stem[-36:] or thread in relocated:
            raise RuntimeError('probe_lineage_identity')
        relocated[thread] = target
        if first is None: first = (thread, target)
        parent = metadata['payload'].get('forked_from_id')
        if not parent: return first, relocated
        if parent not in by_id or parent in relocated: raise RuntimeError('probe_lineage_missing_or_cycle')
        candidate = by_id[parent]
    raise RuntimeError('probe_lineage_depth')


def private_stats(database, thread):
    with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as connection:
        row = connection.execute('SELECT count(*), max(updated_at_ordinal) FROM thread_items WHERE thread_id=?',
                                 (thread,)).fetchone()
        return dict(items=row[0], maximumUpdatedOrdinal=row[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'snapshot', 'manifest', 'output', 'isolation-checker'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--ordinal', type=int, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    if os.uname().sysname != 'Darwin': parser.error('requires macOS Seatbelt')
    if args.output.exists() or not str(args.output).startswith('/private/tmp/tessera-native-reference-'):
        parser.error('fresh private tessera-native-reference output required')
    if any((parent / '.git').exists() for parent in [args.output, *args.output.parents]):
        parser.error('private output must be outside Git')
    finite_directory(args.manifest.parent, '/private/tmp/tessera-full-corpus-')
    snapshot_evidence = validate_snapshot(args.snapshot, hashlib.sha256(args.manifest.read_bytes()).hexdigest())
    candidates = json.loads(args.manifest.read_bytes())['candidates']
    if not 0 <= args.ordinal < len(candidates) or candidates[args.ordinal]['provider'] != 'codex':
        parser.error('finite Codex snapshot ordinal required')
    candidate = candidates[args.ordinal]
    source = Path(candidate['path'])
    if source.parent != args.manifest.parent / 'snapshots':
        parser.error('source must belong to finite manifest snapshots directory')
    finite_directory(source.parent, str(args.manifest.parent) + '/snapshots')
    os.umask(0o077); args.output.mkdir(mode=0o700)
    provider_home = args.output / 'codex'; provider_home.mkdir(mode=0o700)
    (provider_home / 'config.toml').write_text('cli_auth_credentials_store = "file"\n')
    cwd = args.output / 'empty-workspace'; cwd.mkdir(mode=0o700)
    temporary = args.output / 'tmp'; temporary.mkdir(mode=0o700)
    (thread, transcript), relocated = copy_lineage(candidates, candidate, args.manifest.parent, provider_home)
    for name in ('state_5.sqlite', 'thread_history_1.sqlite'):
        copy_database_snapshot(args.snapshot / name, provider_home / name)
    with sqlite3.connect(provider_home / 'state_5.sqlite') as database:
        database.execute('DELETE FROM remote_control_enrollments')
        # Prevent incidental hydration of another row's original user path.
        database.execute('UPDATE threads SET rollout_path=?, cwd=?', (str(cwd / 'absent'), str(cwd)))
        database.executemany('UPDATE threads SET rollout_path=? WHERE id=?',
                             [(str(path), identifier) for identifier, path in relocated.items()])
        database.commit()
    history = provider_home / 'thread_history_1.sqlite'
    before = private_stats(history, thread)
    executable = args.output / 'pinned-codex'
    stable_copy(args.binary.resolve(strict=True), executable)
    executable.chmod(0o700)
    marker = b'CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED'
    if marker not in executable.read_bytes(): raise RuntimeError('probe_remote_control_disable_unavailable')
    environment = {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8', 'TMPDIR': str(temporary),
                   'CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED': '1'}
    environment['CODEX_HOME'] = str(provider_home)
    environment['RUST_LOG'] = 'off'
    # No inherited API keys, auth files, user configuration or project config.
    # The copied native paths are redirected above; live provider homes are
    # additionally unreadable to this test child. All non-runtime read-data,
    # Mach services (including Keychain), network and child creation are denied.
    profile = sandbox_profile(args.output, executable)
    process = None; guard = None
    report = dict(stage='offline_private_clone_materialization_not_live_attachment', ordinal=args.ordinal,
                  before=before, transcriptBytes=source.stat().st_size,
                  binarySHA256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                  manifestSHA256=hashlib.sha256(args.manifest.read_bytes()).hexdigest(),
                  sourceSnapshotEvidenceSHA256=snapshot_evidence,
                  copiedLineageFiles=len(relocated),
                  scriptSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    try:
        checker = args.output / 'pinned-isolation-checker'
        stable_copy(args.isolation_checker.resolve(strict=True), checker); checker.chmod(0o700)
        # Synthetic denied files live in a different run-owned directory; no
        # credential or real user file is opened by the negative checks.
        import tempfile
        with tempfile.TemporaryDirectory(prefix='tessera-probe-denied-', dir='/private/tmp') as denied:
            denied_file = Path(denied) / 'sentinel'; denied_file.write_text('synthetic')
            allowed_file = args.output / 'sentinel'; allowed_file.write_text('synthetic')
            check = subprocess.run(['/usr/bin/sandbox-exec', '-p', sandbox_profile(args.output, checker),
                str(checker), str(allowed_file), str(denied_file)], env=environment, cwd=cwd,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            if check.returncode: raise RuntimeError('probe_isolation_preflight_failed')
        report['isolationPreflightPassed'] = True
        process = subprocess.Popen(['/usr/bin/sandbox-exec', '-p', profile, str(executable), 'app-server',
            '--listen', 'stdio://'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=environment, cwd=cwd, start_new_session=True, bufsize=0)
        guard = Guard(process); rpc = RPC(process)
        initialized = rpc.call('initialize', dict(clientInfo=dict(name='tessera_private_reference_probe', version='1'),
            capabilities=dict(experimentalApi=True)))
        if 'errorCode' in initialized: raise RuntimeError('probe_initialize_rejected')
        rpc.send(dict(method='initialized', params={}))
        read = rpc.call('thread/read', dict(threadId=thread, includeTurns=False))
        report['readErrorCode'] = read.get('errorCode')
        # Installed multi-agent v2 requires a loaded parent even for resuming
        # an existing child. Load only the already copied finite ancestors,
        # oldest first; this never issues a provider turn or a live attachment.
        report['resumedPrivateAncestors'] = 0
        for parent, parent_path in reversed(list(relocated.items())[1:]):
            result = rpc.call('thread/resume', dict(threadId=parent, path=str(parent_path), cwd=str(cwd),
                runtimeWorkspaceRoots=[str(cwd)], excludeTurns=True, sandbox='read-only', approvalPolicy='never',
                config={'shell_environment_policy.inherit': 'none', 'mcp_servers': {}, 'notify': []}))
            if (result.get('thread', {}).get('id') != parent or result.get('thread', {}).get('path') != str(parent_path)):
                report['ancestorResumeErrorCode'] = result.get('errorCode')
                report['ancestorResumeErrorLabels'] = result.get('errorLabels', [])
                raise RuntimeError('probe_ancestor_resume_rejected')
            report['resumedPrivateAncestors'] += 1
        resumed = rpc.call('thread/resume', dict(threadId=thread, path=str(transcript), cwd=str(cwd),
            runtimeWorkspaceRoots=[str(cwd)], excludeTurns=True, sandbox='read-only', approvalPolicy='never',
            config={'shell_environment_policy.inherit': 'none', 'mcp_servers': {}, 'notify': []}))
        report['resumeErrorCode'] = resumed.get('errorCode')
        report['resumeErrorLabels'] = resumed.get('errorLabels', [])
        report['resumedPrivateClone'] = (resumed.get('thread', {}).get('id') == thread
            and resumed.get('thread', {}).get('path') == str(transcript))
        if 'errorCode' not in resumed and not report['resumedPrivateClone']:
            raise RuntimeError('probe_resume_identity_mismatch')
        if report['resumedPrivateClone']:
            latest = rpc.call('thread/items/list', dict(threadId=thread, limit=1, sortDirection='desc'))
            report['latestReadErrorCode'] = latest.get('errorCode')
            if 'errorCode' in latest: raise RuntimeError('probe_latest_read_rejected')
        report['after'] = private_stats(history, thread)
        report['materializationAdvanced'] = (report['after']['items'] > before['items'] or
            (report['after']['maximumUpdatedOrdinal'] or 0) > (before['maximumUpdatedOrdinal'] or 0))
    except Exception as error:
        report['failure'] = str(error) if isinstance(error, RuntimeError) and str(error).replace('_', '').isalnum() else type(error).__name__
    finally:
        cleanup_errors = []
        try:
            if process is not None:
                if process.poll() is None: process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL); process.wait(timeout=3)
                report['ownedProcessExited'] = process.poll() is not None
        except Exception: cleanup_errors.append('process_cleanup_failed')
        try:
            if guard is not None:
                try: guard.signal_owned(signal.SIGKILL)
                finally: guard.close()
                report['sampledTreePeakBytes'] = guard.peak
                report['guardFailure'] = guard.failure
        except Exception: cleanup_errors.append('guard_cleanup_failed')
        report['cleanupErrors'] = cleanup_errors
        (args.output / 'content-free-results.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report))
    return 1 if (report.get('failure') or report.get('guardFailure') or report.get('resumeErrorCode')
        or report.get('cleanupErrors') or not report.get('resumedPrivateClone')
        or not report.get('ownedProcessExited') or not report.get('materializationAdvanced')) else 0


if __name__ == '__main__': raise SystemExit(main())
