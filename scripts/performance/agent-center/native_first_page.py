#!/usr/bin/env python3
"""Cold host process -> committed native page -> actual shared app-model snapshot.

Uses finite private corpus snapshots. This excludes SSH/RTT and native view
layout/paint; those are separate integration gates, never inferred here.
"""
import argparse
from contextlib import closing
import hashlib
import errno
import json
import os
from pathlib import Path
import re
import select
import signal
import socket
import sqlite3
import struct
import subprocess
import sys
import threading
import time
from transcript_layout import claude_relative, claude_layout, default_claude_projects_root, candidate_is_session


def now_ns():
    # Explicit POSIX clock matches FirstPageConsumer.swift. Python's default
    # monotonic clock can use a different Darwin clock domain/epoch.
    return time.clock_gettime_ns(time.CLOCK_MONOTONIC)


def wire(value):
    raw = json.dumps(value, separators=(',', ':')).encode()
    return struct.pack('!I', len(raw)) + raw


def receive(stream):
    def exact(length):
        result = bytearray()
        deadline = time.monotonic() + 5
        while len(result) < length:
            if not select.select([stream], [], [], max(0, deadline - time.monotonic()))[0]:
                raise TimeoutError('frame deadline')
            part = stream.recv(length - len(result))
            if not part: raise EOFError('helper disconnected')
            result.extend(part)
        return bytes(result)
    header = exact(4)
    length, = struct.unpack('!I', header)
    if not 0 < length <= 65536: raise ValueError('frame budget')
    raw = exact(length)
    return json.loads(raw), header + raw


def clone(source, target):
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Inputs must already be finite snapshots, not a live SQLite main file.
    process = subprocess.run(['/bin/cp', '-c' if os.uname().sysname == 'Darwin' else '--reflink=auto',
                              str(source), str(target)], capture_output=True)
    if process.returncode: raise RuntimeError('private snapshot clone failed')
    target.chmod(0o600)


def seed_native_store(snapshot, codex_home, relocated):
    """Same finite Codex store for either selected provider; never touch inputs."""
    if snapshot is None:
        return
    for name in ('state_5.sqlite', 'thread_history_1.sqlite'):
        clone(snapshot / name, codex_home / name)
    with closing(sqlite3.connect(codex_home / 'state_5.sqlite')) as state, state:
        state.execute('DELETE FROM remote_control_enrollments')
        state.executemany('UPDATE threads SET rollout_path=? WHERE id=?',
                          [(str(path), session) for session, path in relocated.items()])


def connect_started_service(process, path, started):
    # bind() creates the socket node before listen(). Existence is not readiness.
    stream = socket.socket(socket.AF_UNIX)
    try:
        while True:
            if process.poll() is not None or now_ns() - started > 3_000_000_000:
                raise TimeoutError('service startup')
            try:
                stream.connect(str(path))
                return stream
            except OSError as error:
                if error.errno not in (errno.ENOENT, errno.ECONNREFUSED):
                    raise
                time.sleep(.002)
    except BaseException:
        stream.close()
        raise


class RelayStream:
    """The shipping stdio relay, with bounded writes and no buffering/read-ahead."""
    def __init__(self, process):
        self.process = process
        os.set_blocking(process.stdin.fileno(), False)

    def fileno(self): return self.process.stdout.fileno()
    def recv(self, size): return os.read(self.fileno(), size)

    def sendall(self, data):
        remaining = memoryview(data); deadline = time.monotonic() + 5
        while remaining:
            if not select.select([], [self.process.stdin], [], max(0, deadline - time.monotonic()))[1]:
                raise TimeoutError('relay write timeout')
            try: count = os.write(self.process.stdin.fileno(), remaining)
            except BlockingIOError: continue
            if not count: raise EOFError('relay write EOF')
            remaining = remaining[count:]

    def close(self):
        if not self.process.stdin.closed: self.process.stdin.close()


def owned_services(binary, runtime_base, *, exiting=False):
    """Discover only this fresh private trial's detached service argv.

    pgrep returns PIDs, not other processes' arguments. Recheck the exact
    matching command and UID for sampling only. These snapshots NEVER authorize
    a signal: PID reuse cannot be excluded by a command-line census.
    """
    prefix = f'{binary} serve --runtime {runtime_base}/'
    expression = '^' + re.escape(prefix) + '[0-9a-f]{16} --idle-ms 100$'
    found = subprocess.run(['/usr/bin/pgrep', '-f', expression], capture_output=True, timeout=5)
    if found.returncode not in (0, 1): raise RuntimeError('service ownership census unavailable')
    result = {}
    for value in found.stdout.splitlines():
        if not value.isdigit() or int(value) <= 1: raise RuntimeError('service ownership census invalid')
        pid = int(value)
        row = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'uid=,command='], capture_output=True, timeout=5)
        if row.returncode: continue # Process exited between the two snapshots.
        fields = row.stdout.decode('utf-8', errors='strict').strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) != os.geteuid():
            if exiting: continue
            raise RuntimeError('service ownership mismatch')
        command = fields[1]
        if not command.startswith(prefix) or not re.fullmatch('[0-9a-f]{16} --idle-ms 100', command[len(prefix):]):
            # At idle exit, pgrep may observe the executable and the later ps
            # observe its zombie label (or a recycled PID). It is no longer a
            # matching live helper. Never adopt or signal the replacement.
            if exiting: continue
            raise RuntimeError('service ownership mismatch')
        try: result[pid] = os.getsid(pid)
        except ProcessLookupError: continue
    return result


class Guard:
    def __init__(self, process, detached=None):
        self.process = process
        self.detached = detached
        self.peak = 0
        self.failure = None
        self.samples = 0
        self.required_service = None
        self.sampled_services = set()
        self.groups = {process.pid: {process.pid}}
        self.members = {process.pid: process.pid}
        self.roots = {process.pid: process.pid}
        self.lock = threading.Lock()
        self.finished = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try: self.sample_loop()
        except Exception:
            self.failure = 'rss_guard_failed'
            self.abort()

    def abort(self):
        if self.detached is not None:
            # Stop accepting work immediately without acquiring PID-based kill
            # authority. EOF disconnects the relay; the service idles out.
            if self.process.stdin and not self.process.stdin.closed: self.process.stdin.close()
        else:
            self.signal_owned(signal.SIGTERM)

    def signal_owned(self, signum):
        if self.detached is not None:
            # Let the relay finish its waitable startup supervisor, then the
            # isolated helper exits via idle grace. Never signal census PIDs.
            return
        # Codex owns a separate process group, but remains in the private
        # service session. Validate both IDs live before touching a group.
        with self.lock:
            members = tuple(self.members.items())
            groups = {key: set(value) for key, value in self.groups.items()}
        failures = []
        for pid, session in members:
            try:
                group = os.getpgid(pid)
                if os.getsid(pid) == session and group in groups.get(session, set()):
                    os.killpg(group, signum)
            except ProcessLookupError: pass
            except OSError as error: failures.append(error)
        if failures: raise RuntimeError('owned group cleanup failed') from failures[0]

    def discover(self):
        if self.detached is None: return
        roots = owned_services(*self.detached)
        with self.lock:
            self.roots = {self.process.pid: self.process.pid, **roots}
        if len(roots) > 1: raise RuntimeError('duplicate private service')

    def sample_loop(self):
        empty_samples = 0
        while not self.finished.is_set() and self.process.poll() is None:
            self.discover()
            result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,rss='], capture_output=True, timeout=5)
            if result.returncode:
                self.failure = 'rss_guard_unavailable'
            else:
                rows = [tuple(map(int, line.split())) for line in result.stdout.splitlines() if len(line.split()) == 3]
                with self.lock: roots = dict(self.roots)
                owned = set(roots)
                while True:
                    grown = owned | {pid for pid, parent, _ in rows if parent in owned}
                    if grown == owned: break
                    owned = grown
                for pid in owned if self.detached is None else ():
                    try:
                        session = os.getsid(pid)
                        if session in roots.values():
                            with self.lock:
                                self.members[pid] = session
                                self.groups.setdefault(session, set()).add(os.getpgid(pid))
                    except ProcessLookupError: pass
                current = sum(rss * 1024 for pid, _, rss in rows if pid in owned)
                if current <= 0:
                    if self.process.poll() is not None: return
                    # ps and waitpid are separate snapshots. A short-lived
                    # worker can disappear from ps just before waitpid observes
                    # its exit. Retry briefly; sustained missing samples remain
                    # a hard guard failure, never a zero-memory pass.
                    empty_samples += 1
                    if empty_samples >= 3: raise RuntimeError('empty RSS sample')
                    self.finished.wait(.05)
                    continue
                empty_samples = 0
                self.samples += 1
                self.sampled_services.update(pid for pid, _, rss in rows if pid in roots and rss > 0)
                self.peak = max(self.peak, current)
                if current > 256 * 1024 * 1024: self.failure = 'process_tree_memory_budget'
            if self.failure:
                self.abort()
                return
            self.finished.wait(.05)

    def close(self):
        self.finished.set(); self.thread.join(timeout=6)
        if not self.failure and (self.thread.is_alive() or not self.samples): self.failure = 'rss_guard_incomplete'
        if self.detached is not None and (self.required_service is None or self.required_service not in self.sampled_services):
            self.failure = 'rss_service_not_sampled'

    def final_service_sample(self):
        self.close()
        roots = owned_services(*self.detached)
        result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,rss='], capture_output=True, timeout=5)
        rows = [tuple(map(int, line.split())) for line in result.stdout.splitlines() if len(line.split()) == 3]
        if result.returncode or self.required_service not in roots or not any(
                pid == self.required_service and rss > 0 for pid, _, rss in rows):
            raise RuntimeError('final_service_rss_missing')
        sampled = {self.process.pid, *roots}
        while True:
            grown = sampled | {pid for pid, parent, _ in rows if parent in sampled}
            if grown == sampled: break
            sampled = grown
        current = sum(rss * 1024 for pid, _, rss in rows if pid in sampled)
        self.peak = max(self.peak, current); self.samples += 1
        if current > 256 * 1024 * 1024: self.failure = 'process_tree_memory_budget'

    def require_service_sample(self, pid):
        self.required_service = pid
        deadline = time.monotonic() + 6
        while pid not in self.sampled_services:
            if self.failure or not self.thread.is_alive() or time.monotonic() >= deadline:
                raise RuntimeError('rss_service_not_sampled')
            time.sleep(.005)


def cleanup_trial(process, guard, stream, context, detached):
    """Attempt every owned cleanup even if ownership census or another step fails."""
    failures = []
    def attempt(name, operation):
        try: operation()
        except BaseException as error:
            # Keep only fixed local reasons; subprocess errors can embed paths
            # and command arguments, so their free-form text is never retained.
            reason = str(error)
            safe = {'service ownership census unavailable', 'service ownership census invalid',
                    'service ownership mismatch', 'private service cleanup incomplete',
                    'relay startup supervision incomplete'}
            failures.append(name + ':' + (reason if reason in safe else type(error).__name__))
    if stream: attempt('stream', stream.close)
    if guard and detached is None:
        attempt('final_census', guard.discover)
        attempt('owned_terminate', lambda: guard.signal_owned(signal.SIGTERM))
    def stop_process():
        if process is None: return
        if detached:
            # EOF lets the relay finish supervising exec before it exits.
            if process.stdin and not process.stdin.closed: process.stdin.close()
            process.wait(timeout=12)
            return
        if process.poll() is None: process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            if os.getsid(process.pid) == process.pid: os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
    attempt('relay_or_service', stop_process)
    if guard:
        attempt('owned_kill', lambda: guard.signal_owned(signal.SIGKILL))
        attempt('guard', guard.close)
    if detached:
        def stop_detached():
            if process is not None and process.poll() is None:
                raise RuntimeError('relay startup supervision incomplete')
            # After relay exit no pre-exec child can appear later. Check both
            # argv and socket ownership until the helper's normal idle exit.
            deadline = time.monotonic() + 5
            while True:
                running = owned_services(*detached, exiting=True)
                sockets = list(Path(detached[1]).glob('*/client.sock'))
                if not running and not sockets: return
                if time.monotonic() >= deadline: raise RuntimeError('private service cleanup incomplete')
                time.sleep(.02)
        attempt('detached_service', stop_detached)
    for pipe in (process.stdin, process.stdout, process.stderr) if process else ():
        if pipe: attempt('pipe', pipe.close)
    if context:
        def stop_context():
            if context.poll() is None: context.terminate()
            try: context.wait(timeout=3)
            except subprocess.TimeoutExpired: context.kill(); context.wait(timeout=3)
        attempt('synthetic_context', stop_context)
        attempt('context_pipe', context.stdout.close)
    if failures: raise RuntimeError('trial cleanup failed: ' + ','.join(failures))


def start_context(environment):
    context = subprocess.Popen([sys.executable, '-c', 'import os,time; os.write(1,b"1"); time.sleep(120)'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment, start_new_session=True)
    try:
        if not select.select([context.stdout], [], [], 3)[0] or context.stdout.read(1) != b'1':
            raise RuntimeError('synthetic context startup')
        return context
    except BaseException:
        cleanup_trial(None, None, None, context, None)
        raise


def trial(args, candidate, index):
    root = args.output / f'{candidate["provider"]}-{index}'
    root.mkdir(mode=0o700)
    provider = candidate['provider']
    original = Path(candidate.get('original_path', candidate['path']))
    codex_home = root / 'codex'
    target = codex_home / 'sessions' / original.name if provider == 'codex' else root / 'claude/projects' / claude_relative(
        original, candidate.get('source_root', args.claude_projects_root))
    clone(candidate['path'], target)
    relocated = {original.stem[-36:]: target} if provider == 'codex' else {}
    expected_paths = {str(target)}
    if not args.known_locator:
        # Discovery must see the whole finite host catalog, not an artificially
        # empty home containing only the largest file. Setup is outside timing.
        for ordinal, other in enumerate(args.candidates):
            if other['path'] == candidate['path']: continue
            name = Path(other['original_path']).name
            if other['provider'] == 'codex':
                destination = codex_home / 'sessions' / f'snapshot-{ordinal}' / name
                discovered = True
            else:
                relative = claude_relative(other['original_path'], other.get('source_root', args.claude_projects_root))
                destination = root / 'claude/projects' / relative
                discovered = claude_layout(relative) != 'non_session_jsonl'
            clone(other['path'], destination)
            if discovered: expected_paths.add(str(destination))
            if other['provider'] == 'codex': relocated[Path(name).stem[-36:]] = destination
    # Both provider measurements discover the same host. Omitting the native
    # store only for Claude forces a different Codex index-rebuild workload
    # during inventory and cannot be compared as an equivalent cold start.
    seed_native_store(args.native_store, codex_home, relocated)
    runtime = root / 'r'
    environment = dict(os.environ, CODEX_HOME=str(codex_home), CLAUDE_CONFIG_DIR=str(root / 'claude'),
                       PI_CODING_AGENT_DIR=str(root / 'pi'), XDG_DATA_HOME=str(root / 'data'), KIMI_CODE_HOME=str(root / 'kimi'))
    if not args.native_store:
        # Deliberately measure the JSONL fallback, without a user CLI/config.
        environment['PATH'] = str(root / 'no-provider-executables')
    entry = getattr(args, 'host_entry', 'service')
    context = None
    hello_request = {'kind': 'hello', 'id': 'hello', 'v': 3}
    if entry == 'context-relay':
        # Stand-in for an already-running agent. Its startup/RSS is outside
        # ingestion timing, just like the user's existing provider process.
        context = start_context(environment)
        hello_request['contextPID'] = context.pid
        environment = dict(environment, CODEX_HOME=str(root / 'carrier-codex'), CLAUDE_CONFIG_DIR=str(root / 'carrier-claude'))
    started = now_ns()
    try:
        process = subprocess.Popen([str(args.binary), 'serve', '--runtime', str(runtime)] if entry == 'service' else
            [str(args.binary), 'connect', '--stdio', '--runtime-base', str(runtime), '--context-from-hello', '--idle-ms', '100'],
            stdin=subprocess.PIPE if entry != 'service' else subprocess.DEVNULL,
            stdout=subprocess.PIPE if entry != 'service' else subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, env=environment, start_new_session=True, bufsize=0)
    except BaseException:
        cleanup_trial(None, None, None, context, None)
        raise
    guard = None; stream = None
    try:
        guard = Guard(process, detached=(args.binary, runtime) if entry != 'service' else None)
        stream = connect_started_service(process, runtime / 'client.sock', started) if entry == 'service' else RelayStream(process)
        stream.sendall(wire(hello_request))
        hello, captured = receive(stream)
        negotiated = now_ns()
        if entry != 'service':
            guard.discover()
            if hello.get('servicePID') not in owned_services(args.binary, runtime):
                raise RuntimeError('hello service ownership mismatch')
            if not re.fullmatch('[0-9a-f]{16}', hello.get('contextScope', '')):
                raise RuntimeError('missing authenticated scope')
            guard.required_service = hello['servicePID']
        inventory_rows = 0
        discovered_paths = set(); discovered_threads = set(); discovery_fallbacks = set()
        if not args.known_locator:
            cursor = None; seen = set()
            while True:
                stream.sendall(wire({'kind': 'inventory', 'id': 'inventory', 'limit': 500, **({'cursor': cursor} if cursor else {})}))
                while True:
                    row, raw = receive(stream)
                    if len(captured) + len(raw) > 1572864: raise RuntimeError('captured inventory budget')
                    captured += raw
                    if row['kind'] == 'error': raise RuntimeError('inventory: ' + row.get('code', 'failed'))
                    if row['kind'] == 'inventory.thread':
                        inventory_rows += 1
                        if row['transcriptRef'] in discovered_paths: raise RuntimeError('duplicate inventory source')
                        discovered_paths.add(row['transcriptRef'])
                        discovered_threads.add((row['provider'], row['sessionID']))
                    if row['kind'] == 'inventory.end': break
                if row.get('fallbackReason'): discovery_fallbacks.add(row['fallbackReason'])
                if not row['hasMore']: break
                cursor = row['cursor']
                if cursor in seen or len(seen) >= 164: raise RuntimeError('inventory cursor failed to advance')
                seen.add(cursor)
            if discovered_paths != expected_paths: raise RuntimeError('incomplete snapshot inventory')
        discovered = now_ns()
        stream.sendall(wire({'kind': 'resolve', 'id': 'resolve', 'provider': provider, 'transcriptRef': str(target)}))
        resolved, _ = receive(stream)
        if resolved.get('kind') != 'resolved': raise RuntimeError('resolution failed')
        catalog_wire = captured
        limit = 100; attempts = 0; read_bytes = 0; consumer_peak = 0
        while True:
            transaction = f'cold_{attempts}'; attempts += 1
            stream.sendall(wire({'kind': 'window.read', 'operation': 'bootstrap', 'windowVersion': 0,
                'id': transaction, 'limit': limit, 'thread': resolved['thread']}))
            count = 0; identity = ''; captured = catalog_wire
            while True:
                item, raw = receive(stream)
                if len(captured) + len(raw) > 2097152: raise ValueError('catalog and page budget')
                captured += raw
                if item['kind'] == 'error': raise RuntimeError(item.get('code', 'read failed'))
                if item['kind'] == 'page.begin': identity = item['sourceIdentity']
                if item['kind'] == 'page.record': count += 1
                if item['kind'] == 'page.end': break
            committed = now_ns(); read_bytes += item['bytesRead']
            consumer = subprocess.run([str(args.consumer), provider, '--native'], input=captured, capture_output=True, timeout=5)
            if consumer.returncode or consumer.stderr: raise RuntimeError('shared model rejected native page')
            model = json.loads(consumer.stdout)
            consumer_peak = max(consumer_peak, model.get('consumer_peak_rss_bytes', 0))
            if not model.get('capacityExceeded'): break
            stream.sendall(wire({'kind': 'window.cancel', 'id': 'cancel_' + transaction,
                'transaction': transaction, 'thread': resolved['thread']}))
            cancelled, _ = receive(stream)
            if cancelled['kind'] != 'window.cancelled': raise RuntimeError('capacity cancellation rejected')
            if limit == 1: raise RuntimeError('one-record model capacity exhausted')
            limit = max(1, limit // 2)
        if model.get('inventory_model_threads', 0) != len(discovered_threads): raise RuntimeError('model inventory coverage mismatch')
        if model['consumer_peak_rss_bytes'] > 128 * 1024 * 1024: raise RuntimeError('consumer memory budget')
        if not committed <= model['ready_monotonic_ns'] <= now_ns(): raise RuntimeError('cross-process clock domain mismatch')
        result = {'provider': provider, 'trial': index, 'file_bytes': candidate['bytes'], 'host_entry': entry,
            'backend': 'app-server' if identity.startswith('codex-appserver:') else 'jsonl',
            'cold_process_to_hello_ms': (negotiated - started) / 1e6,
            'discovery': 'known_locator' if args.known_locator else 'whole_snapshot_catalog',
            'inventory_rows': inventory_rows,
            'inventory_fallback_reasons': sorted(discovery_fallbacks),
            'cold_process_to_discovery_ms': (discovered - started) / 1e6,
            'cold_process_to_page_commit_ms': (committed - started) / 1e6,
            'cold_process_to_renderable_model_ms': (model['ready_monotonic_ns'] - started) / 1e6,
            'shared_model': model, 'records': count, 'read_bytes': read_bytes,
            'bootstrap_attempts': attempts, 'accepted_limit': limit, 'all_consumer_peak_rss_bytes': consumer_peak,
            'host_peak_rss_bytes': item['hostPeakRSSBytes'],
            'codex_sampled_peak_rss_bytes': item['codexSampledPeakRSSBytes']}
        checkpoint = model['window']
        stream.sendall(wire({'kind': 'window.ack', 'id': 'cold_ack', 'thread': resolved['thread'], 'transaction': transaction,
            'windowVersion': checkpoint['version'], 'viewport': checkpoint['viewportSegmentIDs'], 'head': checkpoint['headSegmentID']}))
        ack, _ = receive(stream)
        if ack['kind'] != 'window.acked': raise RuntimeError('model retention ACK rejected')
        result['cold_process_to_retention_ack_ms'] = (now_ns() - started) / 1e6
        update_started = now_ns()
        revision_version = checkpoint['version']; update_bytes = 0
        for sweep in range(32):
            transaction = f'unchanged_{sweep}'
            stream.sendall(wire({'kind': 'window.read', 'operation': 'head', 'windowVersion': revision_version,
                                'id': transaction, 'thread': resolved['thread'], 'cursor': item['liveCursor']}))
            while True:
                update, _ = receive(stream)
                if update['kind'] == 'error': raise RuntimeError('unchanged update: ' + update.get('code', 'failed'))
                if update['kind'] == 'page.end': break
            if update['records']: raise RuntimeError('finite snapshot changed during unchanged-read measurement')
            update_bytes += update['bytesRead']; revision_version = update['window']['version']
            stream.sendall(wire({'kind': 'window.ack', 'id': 'ack_' + transaction, 'thread': resolved['thread'],
                'transaction': transaction, 'windowVersion': revision_version,
                'viewport': checkpoint['viewportSegmentIDs'], 'head': checkpoint['headSegmentID']}))
            ack, _ = receive(stream)
            if ack['kind'] != 'window.acked': raise RuntimeError('unchanged sweep retention ACK rejected')
            if not update['hasNewer']: break
        else: raise RuntimeError('unchanged sweep did not finish')
        result.update(unchanged_update_ms=(now_ns() - update_started) / 1e6,
                      unchanged_update_records=0, unchanged_update_read_bytes=update_bytes,
                      unchanged_update_acknowledged_slices=sweep + 1)
        if item['hostPeakRSSBytes'] > 256 * 1024 * 1024: raise RuntimeError('service_memory_budget')
        if entry != 'service':
            # Memory evidence must not insert a sampling barrier into any
            # latency endpoint above; shipping clients never wait for ps.
            guard.require_service_sample(hello['servicePID'])
            guard.final_service_sample()
        else: guard.close()
        result['sampled_service_tree_peak_bytes'] = guard.peak
        result['sampled_process_scope'] = 'service_tree' if entry == 'service' else 'relay_and_service_trees'
        result['helper_idle_grace_ms'] = 30000 if entry == 'service' else 100
        result['memory_samples'] = guard.samples
        if guard.failure: raise RuntimeError(guard.failure)
        return result
    finally:
        cleanup_trial(process, guard, stream, context, (args.binary, runtime) if entry != 'service' else None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--consumer', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--claude-projects-root', type=Path, default=default_claude_projects_root(),
                        help='Original host provider root for older manifests without source_root')
    parser.add_argument('--native-store', type=Path, help='private consistent Codex database snapshot, never the live provider home')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--host-entry', choices=('service', 'relay', 'context-relay'), default='service',
                        help='Direct-helper baseline or shipping cold relay, optionally capturing an existing synthetic process context')
    parser.add_argument('--known-locator', action='store_true', help='exclude discovery, matching the earlier known-locator baseline')
    args = parser.parse_args()
    if args.native_store and args.host_entry != 'service': parser.error('relay measurement requires the finite JSONL fallback lane')
    args.binary = args.binary.resolve(strict=True); args.consumer = args.consumer.resolve(strict=True)
    args.output = args.output.resolve()
    if not 1 <= args.trials <= 20: parser.error('trials must be 1..20')
    if any((parent / '.git').exists() for parent in [args.output, *args.output.parents]): parser.error('private output must be outside Git')
    manifest_bytes = args.manifest.read_bytes()
    candidates = json.loads(manifest_bytes)['candidates']
    args.candidates = candidates
    if any('original_path' not in row for row in candidates): parser.error('manifest must contain finite snapshots')
    os.umask(0o077); args.output.mkdir(mode=0o700)
    # A long trial matrix must not switch executables underneath itself when
    # the developer rebuilds in another terminal. Hash the pinned copies too.
    for name in ('binary', 'consumer'):
        target = args.output / ('measured-' + name)
        clone(getattr(args, name), target); target.chmod(0o700)
        setattr(args, name, target)
    rows = []
    for provider in ('codex', 'claude'):
        selected = max((row for row in candidates if row['provider'] == provider and candidate_is_session(row, args.claude_projects_root)), key=lambda row: row['bytes'])
        for index in range(args.trials):
            row = trial(args, selected, index); rows.append(row); print(json.dumps(row), flush=True)
    evidence = {'stage': 'host_cold_to_shared_model_not_native_paint', 'trials': rows,
        'host_entry': args.host_entry,
        'manifest_sha256': hashlib.sha256(manifest_bytes).hexdigest(),
        'benchmark_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'layout_sha256': hashlib.sha256(Path(__file__).with_name('transcript_layout.py').read_bytes()).hexdigest(),
        'host': {'system': os.uname().sysname, 'release': os.uname().release, 'architecture': os.uname().machine},
        'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        'consumer_sha256': hashlib.sha256(args.consumer.read_bytes()).hexdigest(),
        'cache_condition': 'new service/connection/model process each trial; OS filesystem cache not flushed',
        'pending_gates': ['ssh_rtt', 'ios_first_paint', 'android_first_paint', 'append_latency']}
    with (args.output / 'content-free-results.json').open('x') as stream: json.dump(evidence, stream, indent=2)


if __name__ == '__main__': main()
