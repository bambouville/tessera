"""Synthetic service/relay integration; no provider files or host connection."""
import json
import base64
import fcntl
import hashlib
import shutil
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from native_mock import native_mock

BINARY = str(Path(sys.argv.pop(1)).resolve())


def frame(value):
    data = json.dumps(value, separators=(',', ':')).encode()
    return struct.pack('!I', len(data)) + data


def receive(stream, timeout=2):
    descriptor = stream.fileno()
    def exact(size):
        data = bytearray()
        deadline = time.monotonic() + timeout
        while len(data) < size:
            if not select.select([descriptor], [], [], max(0, deadline - time.monotonic()))[0]:
                raise TimeoutError('frame timeout')
            chunk = os.read(descriptor, size - len(data))
            if not chunk:
                raise EOFError('frame EOF')
            data.extend(chunk)
        return bytes(data)
    size, = struct.unpack('!I', exact(4))
    if not 0 < size <= 65536:
        raise ValueError('frame limit')
    return json.loads(exact(size))


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tas-', dir='/tmp')
        self.root = Path(self.temporary.name).resolve()
        previous_pi = os.environ.get('PI_CODING_AGENT_DIR')
        os.environ['PI_CODING_AGENT_DIR'] = str(self.root / 'pi')
        def restore_pi():
            if previous_pi is None: os.environ.pop('PI_CODING_AGENT_DIR', None)
            else: os.environ['PI_CODING_AGENT_DIR'] = previous_pi
        self.addCleanup(restore_pi)
        previous_data = os.environ.get('XDG_DATA_HOME')
        os.environ['XDG_DATA_HOME'] = str(self.root / 'xdg-data')
        def restore_data():
            if previous_data is None: os.environ.pop('XDG_DATA_HOME', None)
            else: os.environ['XDG_DATA_HOME'] = previous_data
        self.addCleanup(restore_data)
        previous_kimi = os.environ.get('KIMI_CODE_HOME')
        os.environ['KIMI_CODE_HOME'] = str(self.root / 'kimi')
        def restore_kimi():
            if previous_kimi is None: os.environ.pop('KIMI_CODE_HOME', None)
            else: os.environ['KIMI_CODE_HOME'] = previous_kimi
        self.addCleanup(restore_kimi)
        self.runtime = self.root / 'r'
        self.processes = []
        self.connections = []

    def tearDown(self):
        for stream in self.connections:
            stream.close()
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream:
                    stream.close()
        self.temporary.cleanup()

    def test_packaged_service_pins_its_immutable_version_until_exit(self):
        versions = self.root / 'agent-host-versions'; versions.mkdir(mode=0o700)
        path = versions / hashlib.sha256(Path(BINARY).read_bytes()).hexdigest()
        shutil.copyfile(BINARY, path); path.chmod(0o700)
        process = subprocess.Popen([str(path), 'serve', '--runtime', str(self.runtime)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.processes.append(process)
        deadline = time.monotonic() + 3
        while not (self.runtime / 'client.sock').exists():
            self.assertIsNone(process.poll())
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        with path.open('rb') as descriptor:
            with self.assertRaises(BlockingIOError): fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            process.terminate(); process.wait(timeout=3)
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_packaged_service_rejects_a_version_being_collected(self):
        versions = self.root / 'agent-host-versions'; versions.mkdir(mode=0o700)
        path = versions / hashlib.sha256(Path(BINARY).read_bytes()).hexdigest()
        shutil.copyfile(BINARY, path); path.chmod(0o700)
        with path.open('rb') as descriptor:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run([str(path), 'serve', '--runtime', str(self.runtime)],
                                    capture_output=True, timeout=3)
        self.assertEqual(result.returncode, 77)
        self.assertFalse((self.runtime / 'client.sock').exists())

    def test_concurrent_relays_automatically_replace_published_helper(self):
        self.root.chmod(0o755) # Supported pre-existing deployment parent.
        versions = self.root / 'agent-host-versions'; versions.mkdir(mode=0o700)
        for digit in ('a', 'b'):
            path = versions / (digit * 64)
            shutil.copyfile(BINARY, path); path.chmod(0o700)
        published = self.root / 'tessera-agent-host'
        published.symlink_to('agent-host-versions/' + 'a' * 64)
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'),
                           CLAUDE_CONFIG_DIR=str(self.root / 'claude'))
        relays = []
        def connect():
            relay = subprocess.Popen([str(published), 'connect', '--stdio', '--runtime-base', str(self.runtime),
                '--context-from-hello', '--idle-ms', '100'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=environment, bufsize=0)
            self.processes.append(relay); relays.append(relay)
            relay.stdin.write(frame(dict(kind='hello', v=3, id='hello')))
            return relay
        try:
            first = [connect(), connect()]
            before = [receive(relay.stdout, timeout=5) for relay in first]
            self.assertEqual(before[0]['servicePID'], before[1]['servicePID'])
            replacement = self.root / 'next-publication'
            replacement.symlink_to('agent-host-versions/' + 'b' * 64)
            replacement.replace(published)
            for relay in first:
                self.assertEqual(relay.wait(timeout=5), 0)
            # No explicit serve call or PID signal: the production relay is
            # solely responsible for starting and sharing the replacement.
            second = [connect(), connect()]
            after = [receive(relay.stdout, timeout=5) for relay in second]
            self.assertEqual(after[0]['servicePID'], after[1]['servicePID'])
            self.assertNotEqual(before[0]['serviceEpoch'], after[0]['serviceEpoch'])
            self.assertEqual(before[0]['contextScope'], after[0]['contextScope'])
            self.assertEqual(len(list(self.runtime.glob('*/client.sock'))), 1)
            second[0].stdin.close(); second[0].wait(timeout=4)
            second[1].stdin.write(frame(dict(kind='heartbeat', id='survived')))
            self.assertEqual(receive(second[1].stdout)['id'], 'survived')
        finally:
            for relay in relays:
                if not relay.stdin.closed: relay.stdin.close()
                if relay.poll() is None: relay.wait(timeout=12)
            deadline = time.monotonic() + 5
            while list(self.runtime.glob('*/client.sock')) and time.monotonic() < deadline: time.sleep(.02)
            self.assertFalse(list(self.runtime.glob('*/client.sock')))

    def test_published_upgrade_retires_leased_service_then_reuses_one_replacement(self):
        # Synthetic immutable identities exercise publication without running
        # another release or touching the user's installed helper/provider data.
        versions = self.root / 'agent-host-versions'; versions.mkdir(mode=0o700)
        old, new = [versions / (digit * 64) for digit in ('a', 'b')]
        for path in (old, new):
            shutil.copyfile(BINARY, path); path.chmod(0o700)
        published = self.root / 'tessera-agent-host'
        published.symlink_to('agent-host-versions/' + old.name)
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'),
                           CLAUDE_CONFIG_DIR=str(self.root / 'claude'))
        service = subprocess.Popen([str(old), 'serve', '--runtime', str(self.runtime)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        self.processes.append(service)
        deadline = time.monotonic() + 3
        while not (self.runtime / 'client.sock').exists():
            self.assertIsNone(service.poll()); self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        peers = [self.client()[0], self.client()[0]]
        replacement = self.root / 'next-publication'
        replacement.symlink_to('agent-host-versions/' + new.name)
        replacement.replace(published)
        # Both clients still hold 30-second leases; expiry cannot explain exit.
        self.assertEqual(service.wait(timeout=4), 0)
        for peer in peers:
            peer.settimeout(2)
            self.assertEqual(peer.recv(1), b'')
        # Worker teardown and endpoint cleanup must precede lock release.
        with (self.runtime / 'service.lock').open('rb') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertFalse((self.runtime / 'client.sock').exists())
        service2 = subprocess.Popen([str(new), 'serve', '--runtime', str(self.runtime)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        self.processes.append(service2)
        deadline = time.monotonic() + 3
        while not (self.runtime / 'client.sock').exists():
            self.assertIsNone(service2.poll()); self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        relays = []
        for index in range(2):
            relay = subprocess.Popen([str(published), 'connect', '--stdio', '--runtime', str(self.runtime)],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=environment)
            self.processes.append(relay); relays.append(relay)
            relay.stdin.write(frame(dict(kind='hello', v=3, id='hello' + str(index)))); relay.stdin.flush()
            self.assertEqual(receive(relay.stdout)['servicePID'], service2.pid)
        relays[0].stdin.close(); relays[0].stdin = None
        relays[0].wait(timeout=4)
        relays[1].stdin.write(frame(dict(kind='heartbeat', id='sibling'))); relays[1].stdin.flush()
        self.assertEqual(receive(relays[1].stdout)['id'], 'sibling')

    def test_attach_only_reuses_owned_service_and_never_restarts_it(self):
        absent = subprocess.run([BINARY, 'connect', '--stdio', '--runtime', str(self.runtime), '--attach-only'],
                                capture_output=True, timeout=3)
        self.assertEqual(absent.returncode, 77)
        self.assertFalse(self.runtime.exists())
        service = self.service(idle=30000, lease=30000)
        relay = subprocess.Popen([BINARY, 'connect', '--stdio', '--runtime', str(self.runtime), '--attach-only'],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(relay)
        relay.stdin.write(frame(dict(kind='hello', v=3, id='hello'))); relay.stdin.flush()
        self.assertEqual(receive(relay.stdout)['servicePID'], service.pid)
        service.terminate(); service.wait(timeout=3)
        relay.wait(timeout=3)
        stopped = subprocess.run([BINARY, 'connect', '--stdio', '--runtime', str(self.runtime), '--attach-only'],
                                 capture_output=True, timeout=3)
        self.assertEqual(stopped.returncode, 69)
        self.assertFalse((self.runtime / 'client.sock').exists())

    def service(self, idle=1000, lease=1500, extra_environment=None):
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'), CLAUDE_CONFIG_DIR=str(self.root / 'claude'))
        environment.update(extra_environment or {})
        process = subprocess.Popen([BINARY, 'serve', '--runtime', str(self.runtime),
                                    '--idle-ms', str(idle), '--lease-ms', str(lease)],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        self.processes.append(process)
        deadline = time.monotonic() + 2
        while not (self.runtime / 'hooks.sock').exists():
            if process.poll() is not None or time.monotonic() >= deadline:
                self.fail('service did not start')
            time.sleep(.01)
        return process

    def client(self, session=None, interest='fast'):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(str(self.runtime / 'client.sock'))
        self.connections.append(connection)
        connection.sendall(frame({'kind': 'hello', 'v': 3, 'id': 'hello'}))
        hello = receive(connection)
        self.assertEqual(hello['kind'], 'hello')
        self.assertEqual(hello['v'], 3)
        self.assertIn('window.partitions', hello['capabilities'])
        if session:
            connection.sendall(frame({'kind': 'subscribe', 'id': 'sub', 'session_id': session, 'interest': interest}))
            self.assertEqual(receive(connection)['kind'], 'subscribed')
        return connection, hello

    def test_incompatible_window_protocol_cannot_attach_or_replace_service(self):
        self.service()
        current, original = self.client()
        for version in (1, 2, 4, '3', 3.5):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as obsolete:
                obsolete.connect(str(self.runtime / 'client.sock'))
                obsolete.sendall(frame(dict(kind='hello', v=version, id='hello')))
                with self.assertRaises(EOFError):
                    receive(obsolete)
            current.sendall(frame(dict(kind='heartbeat', id='still_alive')))
            self.assertEqual(receive(current)['serviceEpoch'], original['serviceEpoch'])
        _, reused = self.client()
        self.assertEqual(reused['serviceEpoch'], original['serviceEpoch'])
        self.assertEqual(reused['servicePID'], original['servicePID'])

    def hook(self, session='synthetic', **fields):
        value = {'hook_event_name': 'MessageDisplay', 'session_id': session, 'message_id': 'display',
                 'turn_id': 'turn', 'index': 0, 'final': True, 'delta': 'synthetic'}
        value.update(fields)
        result = subprocess.run([BINARY, 'hook', '--socket', str(self.runtime / 'hooks.sock')],
                                input=json.dumps(value).encode(), capture_output=True, timeout=2)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b'', b''))

    def transcript(self, name='synthetic', count=250):
        path = self.root / 'claude/projects/project' / (name + '.jsonl')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(''.join(json.dumps({'type': 'user', 'uuid': f'{name}-{n}',
            'parentUuid': f'{name}-{n - 1}' if n else None,
            'message': {'role': 'user', 'content': f'line {n}'}}) + '\n' for n in range(count)))
        return path

    def resolve(self, client, path, provider='claude'):
        client.sendall(frame({'kind': 'resolve', 'id': 'resolve', 'provider': provider, 'transcriptRef': str(path)}))
        response = receive(client)
        self.assertEqual(response['kind'], 'resolved', response)
        return response['thread']

    def page(self, client, thread, kind='bootstrap', cursor=None):
        request = {'kind': kind, 'id': 'read', 'thread': thread}
        if cursor is not None: request['cursor'] = cursor
        client.sendall(frame(request))
        return self.read_page(client)

    def read_page(self, client):
        begin = receive(client, timeout=5)
        self.assertEqual(begin['kind'], 'page.begin', begin)
        records = []
        while True:
            item = receive(client)
            self.assertEqual(item['id'], begin['id'])
            if item['kind'] == 'page.end':
                self.assertEqual(item['records'], len(records))
                return begin, records, item
            self.assertEqual(item['kind'], 'page.record')
            records.append(item)

    def window_page(self, client, thread, operation, version, cursor=None, limit=None):
        request = {'kind': 'window.read', 'id': f'window_{version}_{operation}', 'thread': thread,
                   'operation': operation, 'windowVersion': version}
        if cursor is not None: request['cursor'] = cursor
        if limit is not None: request['limit'] = limit
        client.sendall(frame(request))
        return self.read_page(client)

    def window_ack(self, client, thread, end, viewport, head):
        client.sendall(frame({'kind': 'window.ack', 'id': 'commit_' + end['id'], 'thread': thread,
            'transaction': end['id'], 'windowVersion': end['window']['version'], 'viewport': viewport, 'head': head}))
        reply = receive(client)
        self.assertEqual(reply['kind'], 'window.acked', reply)
        return reply

    def test_window_jsonl_traverses_both_directions_and_preserves_live_head(self):
        path = self.transcript(count=1000)
        self.service(lease=30000)
        client, _ = self.client(); thread = self.resolve(client, path)
        _, records, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']; viewport = [head]
        self.window_ack(client, thread, end, viewport, head)
        live = end['liveCursor']
        pages = [(end['window'], records)]
        for start in range(800, -1, -100):
            _, records, end = self.window_page(client, thread, 'before', end['window']['version'], pages[0][0]['before'])
            self.assertEqual([record['record']['blocks'][0]['text'] for record in records], [f'line {n}' for n in range(start, start + 100)])
            pages.insert(0, (end['window'], records)); pages = pages[:4]
            viewport = [page[0]['segmentID'] for page in pages]
            ack = self.window_ack(client, thread, end, viewport, head)
            self.assertEqual(ack['liveCursor'], live)
        for start in range(400, 901, 100):
            _, records, end = self.window_page(client, thread, 'after', end['window']['version'], pages[-1][0]['after'])
            self.assertEqual([record['record']['blocks'][0]['text'] for record in records], [f'line {n}' for n in range(start, start + 100)])
            pages.append((end['window'], records)); pages = pages[-4:]
            self.window_ack(client, thread, end, [page[0]['segmentID'] for page in pages], head)

    def test_window_capacity_is_advertised_and_bounds_the_acknowledged_viewport(self):
        path = self.transcript(count=6600)
        self.service(lease=30000)
        client, hello = self.client()
        self.assertEqual(hello['v'], 3)
        self.assertIn('window.capacity.v1', hello['capabilities'])
        self.assertIs(type(hello['maxWindowSegments']), int)
        self.assertEqual(hello['maxWindowSegments'], 64)
        thread = self.resolve(client, path)
        _, records, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']; viewport = [head]; before = end['window']['before']; retained = len(records)
        live = end['liveCursor']
        self.window_ack(client, thread, end, viewport, head)
        while len(viewport) < 64:
            _, records, end = self.window_page(client, thread, 'before', end['window']['version'], before)
            self.assertEqual(len(records), 100)
            before = end['window']['before']; viewport.insert(0, end['window']['segmentID']); retained += len(records)
            self.window_ack(client, thread, end, viewport, head)
        # 64 contiguous full pages: 64 x 100 records, far past the legacy 4/400 bound.
        self.assertEqual(retained, 64 * 100)
        _, records, end = self.window_page(client, thread, 'before', end['window']['version'], before)
        self.assertEqual(records[0]['record']['blocks'][0]['text'], 'line 100')
        oversized = [end['window']['segmentID'], *viewport]
        client.sendall(frame({'kind': 'window.ack', 'id': 'oversized-ack', 'thread': thread,
            'transaction': end['id'], 'windowVersion': end['window']['version'], 'viewport': oversized, 'head': head}))
        self.assertEqual(receive(client)['kind'], 'resyncRequired')
        rejected = receive(client)
        self.assertEqual((rejected['kind'], rejected['code']), ('error', 'windowCapacity'))
        # The rejected ACK leaves the staged page; 64 segments plus the detached head commit.
        self.assertEqual(self.window_ack(client, thread, end, oversized[:64], head)['liveCursor'], live)
        _, updates, fresh = self.window_page(client, thread, 'head', end['window']['version'], live)
        self.assertEqual((updates, fresh['window']['lane']), ([], 'revisions'))

    def test_window_revision_slice_bounds_distinct_revised_segments(self):
        client, thread, fixture = self.native_codex(20)
        _, records, end = self.window_page(client, thread, 'bootstrap', 0, limit=1)
        head = end['window']['segmentID']; viewport = [head]; before = end['window']['before']; live = end['liveCursor']
        self.window_ack(client, thread, end, viewport, head)
        for _ in range(9):
            _, records, end = self.window_page(client, thread, 'before', end['window']['version'], before, limit=1)
            self.assertEqual(len(records), 1)
            before = end['window']['before']; viewport.insert(0, end['window']['segmentID'])
            self.window_ack(client, thread, end, viewport, head)
        self.assertEqual(len(viewport), 10)
        # Six one-record segments change. One revisions transaction may touch at
        # most four, so the 20-partition wire bound keeps its legacy headroom.
        revised = [f'item-{n}' for n in (10, 12, 14, 16, 18, 19)]
        items = json.loads(fixture.read_text())
        for item in items:
            if item['item']['id'] in revised: item['item']['text'] = 'revised ' + item['item']['id']
        fixture.write_text(json.dumps(items))
        slices = []
        for _ in range(8):
            _, updates, end = self.window_page(client, thread, 'head', end['window']['version'], live, limit=100)
            self.assertEqual(end['window']['lane'], 'revisions')
            self.assertEqual(end['window'].get('partitions', []), [])
            slices.append([item['recordID'] for item in updates])
            self.window_ack(client, thread, end, viewport, head)
            if not end['hasNewer']: break
        self.assertFalse(end['hasNewer'])
        self.assertEqual(sorted(sum(slices, [])), sorted(revised))
        self.assertLessEqual(max(len(part) for part in slices), 4)
        self.assertGreaterEqual(len([part for part in slices if part]), 2)

    def test_window_service_budget_refuses_growth_but_keeps_live_refresh(self):
        # All clients' windows share one 64 MiB retained budget, including
        # staged but unacknowledged pages. History growth is refused there with
        # a retryable windowCapacity; live refreshes and ACKs still commit, and
        # a disconnect frees the budget for the other clients.
        path = self.root / 'claude/projects/project/budget.jsonl'; path.parent.mkdir(parents=True)
        padding = 'x' * 2000
        def lines(first, count):
            return ''.join(json.dumps({'type': 'user', 'uuid': f'budget-{n}', 'parentUuid': f'budget-{n - 1}' if n else None,
                'message': {'role': 'user', 'content': f'line {n} {padding}'}}) + '\n' for n in range(first, first + count))
        path.write_text(lines(0, 7000))
        self.service(lease=30000)
        probe, hello = self.client()
        self.assertEqual(hello['maxRetainedBytes'], 64 * 1024 * 1024)
        thread = self.resolve(probe, path)
        serial = iter(range(1 << 20))
        def read(client, operation, version, cursor=None, limit=None):
            request = {'kind': 'window.read', 'id': f'budget_{next(serial)}', 'thread': thread,
                       'operation': operation, 'windowVersion': version}
            if cursor is not None: request['cursor'] = cursor
            if limit is not None: request['limit'] = limit
            client.sendall(frame(request))
            begin = receive(client, timeout=5)
            self.assertEqual(begin['id'], request['id'])
            if begin['kind'] == 'error': return begin, None
            self.assertEqual(begin['kind'], 'page.begin', begin)
            records = []
            while True:
                item = receive(client)
                if item['kind'] == 'page.end':
                    self.assertEqual(item['records'], len(records)); return item, records
                records.append(item)
        def cancel(client, end):
            client.sendall(frame({'kind': 'window.cancel', 'id': 'cancel_' + end['id'], 'thread': thread, 'transaction': end['id']}))
            self.assertEqual(receive(client)['kind'], 'window.cancelled')
        def refused(reply):
            self.assertEqual((reply['kind'], reply['code']), ('error', 'windowCapacity'), reply)
            self.assertEqual((reply['status']['state'], reply['status']['recovery']), ('resourceLimited', 'retryRead'))
        # A one-record probe window tests admission without adding retention.
        end, _ = read(probe, 'bootstrap', 0, limit=1)
        probe_before = end['window']['before']
        self.window_ack(probe, thread, end, [end['window']['segmentID']], end['window']['segmentID'])
        windows, proved, refusal = [], False, None
        beat = [time.monotonic()]
        def keep_alive():
            # Clients stay idle while later ones fill; a slow fixture host must
            # not expire their leases and release their windows mid-test.
            if time.monotonic() - beat[0] < 5: return
            for number, client in enumerate([probe] + [state['client'] for state in windows]):
                client.sendall(frame({'kind': 'heartbeat', 'id': f'beat_{number}'}))
                self.assertEqual(receive(client)['kind'], 'ack')
            beat[0] = time.monotonic()
        def staged(client, end, again):
            # While each admitted fill page is still staged, the probe tests
            # admission. Once only that unacknowledged page is in the way,
            # cancelling it readmits the probe.
            nonlocal proved
            keep_alive()
            check, _ = read(probe, 'before', 1, probe_before, limit=1)
            if check['kind'] == 'page.end': cancel(probe, check); return end
            if proved: return end
            refused(check); cancel(client, end)
            check, _ = read(probe, 'before', 1, probe_before, limit=1)
            self.assertEqual(check['kind'], 'page.end', check); cancel(probe, check)
            end, _ = again()
            self.assertEqual(end['kind'], 'page.end', end); proved = True
            return end
        while refusal is None:
            client, _ = self.client(); self.resolve(client, path)
            again = lambda client=client: read(client, 'bootstrap', 0)
            end, _ = again()
            if end['kind'] == 'error':
                refusal, retry = end, again; break
            end = staged(client, end, again)
            state = dict(client=client, head=end['window']['segmentID'], live=end['liveCursor'],
                         viewport=[end['window']['segmentID']], before=end['window']['before'], end=end)
            self.window_ack(client, thread, end, state['viewport'], state['head']); windows.append(state)
            while len(state['viewport']) < 64 and state['end']['hasOlder']:
                version = state['end']['window']['version']
                again = lambda state=state, version=version: read(state['client'], 'before', version, state['before'])
                end, _ = again()
                if end['kind'] == 'error':
                    refusal, retry = end, again; break
                end = staged(client, end, again)
                state['before'] = end['window']['before']; state['viewport'].insert(0, end['window']['segmentID'])
                self.window_ack(client, thread, end, state['viewport'], state['head']); state['end'] = end
        refused(refusal)
        self.assertTrue(proved)
        # Well past the old 24 x 5-page service total, before 24 windows or any
        # client's four-window limit, so the service budget refused it.
        self.assertGreater(sum(len(state['viewport']) for state in windows), 200)
        self.assertTrue(4 <= len(windows) < 8)
        # A live head refresh, delivered automatically, still commits at the
        # budget; the scrolled-back client keeps its history and a detached head.
        with path.open('a') as stream: stream.write(lines(7000, 3))
        live = windows[0]
        live['client'].sendall(frame({'kind': 'subscribe', 'id': 'watch', 'thread': thread, 'interest': 'fast',
            'windowVersion': live['end']['window']['version'], 'liveCursor': live['live']}))
        self.assertEqual(receive(live['client'])['kind'], 'subscribed')
        _, updates, update = self.read_page(live['client'])
        self.assertEqual(update['window']['lane'], 'head')
        self.assertEqual([item['record']['blocks'][0]['text'].split()[1] for item in updates[-3:]], ['7000', '7001', '7002'])
        acked = self.window_ack(live['client'], thread, update, live['viewport'], update['window']['segmentID'])
        live['client'].sendall(frame({'kind': 'unsubscribe', 'id': 'quiet', 'thread': thread}))
        self.assertIn(receive(live['client'])['kind'], ('ack', 'window.cancelled'))
        # So does a revisions refresh, and a manual head append by another client.
        sweep, patches = read(live['client'], 'head', update['window']['version'], acked['liveCursor'])
        self.assertEqual((sweep['window']['lane'], patches), ('revisions', []))
        self.window_ack(live['client'], thread, sweep, live['viewport'], update['window']['segmentID'])
        other = windows[1]
        update, updates = read(other['client'], 'head', other['end']['window']['version'], other['live'])
        self.assertEqual((update['window']['lane'], updates[-1]['record']['blocks'][0]['text'].split()[1]), ('head', '7002'))
        self.window_ack(other['client'], thread, update, other['viewport'], update['window']['segmentID'])
        # History growth is still refused after those refreshes.
        refused(retry()[0])
        # A disconnect releases that client's windows before later jobs run.
        other['client'].sendall(frame({'kind': 'bye', 'id': 'bye'}))
        other['client'].settimeout(5)
        self.assertEqual(other['client'].recv(1), b'')
        end, _ = retry()
        self.assertEqual(end['kind'], 'page.end', end)

    def test_paginated_file_revision_survives_transaction_ack_and_two_clients(self):
        session = '00000000-0000-0000-0000-000000000001'
        path = self.root / 'codex/sessions' / ('rollout-' + session + '.jsonl'); path.parent.mkdir(parents=True)
        executable = self.root / 'bin/codex'; executable.parent.mkdir()
        executable.write_text('#!/bin/sh\nprintf "codex-cli 0.0.0\\n"\n'); executable.chmod(0o700)
        def item(ordinal, turn, body):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=session, turn_id=turn,
                item=dict(type='AgentMessage', id='same-provider-id', content=[dict(type='Text', text=body)])))
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=session, history_mode='paginated')),
                item(1, 'first-turn', 'first'), item(2, 'second-turn', 'second')]
        path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        self.service(lease=30000, extra_environment={'PATH': str(executable.parent)})
        windows = []
        for _ in range(2):
            client, _ = self.client(); thread = self.resolve(client, path, 'codex')
            _, records, end = self.window_page(client, thread, 'bootstrap', 0)
            self.assertEqual([row['record']['blocks'][0]['text'] for row in records], ['first', 'second'])
            self.assertNotEqual(records[0]['recordID'], records[1]['recordID'])
            head = end['window']['segmentID']; self.window_ack(client, thread, end, [head], head)
            windows.append((client, thread, records, end, head))
        with path.open('a') as output: output.write(json.dumps(item(3, 'first-turn', 'revised first')) + '\n')
        for client, thread, original, end, head in windows:
            _, patches, update = self.window_page(client, thread, 'head', end['window']['version'], end['liveCursor'])
            self.assertEqual(len(patches), 1)
            self.assertEqual(patches[0]['recordID'], original[0]['recordID'])
            self.assertEqual(patches[0]['record']['blocks'][0]['text'], 'revised first')
            self.assertGreater(patches[0]['revision'], original[0]['revision'])
            self.window_ack(client, thread, update, [head], head)
            _, repeated, fresh = self.window_page(client, thread, 'head', update['window']['version'], end['liveCursor'])
            self.assertEqual(repeated, [])
            self.window_ack(client, thread, fresh, [head], head)

    def test_oversized_single_record_bootstrap_is_resumable_for_both_providers(self):
        paths = []
        for provider in ('claude', 'codex'):
            identity = '00000000-0000-0000-0000-000000000007'
            path = self.root / provider / ('projects/project' if provider == 'claude' else 'sessions') / (identity + '.jsonl')
            path.parent.mkdir(parents=True)
            with path.open('wb') as stream:
                if provider == 'codex':
                    stream.write((json.dumps(dict(type='session_meta', ordinal=0, payload=dict(id=identity, history_mode='paginated'))) + '\n').encode())
                    stream.write(b'{"type":"event_msg","ordinal":1,"opaque":"')
                else: stream.write(b'{"type":"user","uuid":"large","parentUuid":null,"opaque":"')
                for _ in range(70 * 16): stream.write(b'x' * 65536)
                if provider == 'codex':
                    stream.write(b'","payload":{"type":"item_completed","thread_id":"' + identity.encode() +
                        b'","turn_id":"turn","item":{"type":"AgentMessage","id":"large","content":[{"type":"Text","text":"after giant field"}]}}}\n')
                else: stream.write(b'","message":{"role":"user","content":"after giant field"}}\n')
            paths.append((provider, path))
        self.service(lease=30000, extra_environment={'PATH': '/nonexistent'})
        client, _ = self.client()
        for provider, path in paths:
            with self.subTest(provider=provider):
                thread = self.resolve(client, path, provider)
                _, rows, end = self.window_page(client, thread, 'bootstrap', 0)
                self.assertEqual(len(rows), 1)
                self.assertTrue(rows[0]['recordID'])
                self.assertEqual(rows[0]['record']['blocks'][0]['text'], 'after giant field')
                head = end['window']['segmentID']
                self.window_ack(client, thread, end, [head], head)
                self.assertLess(end['hostPeakRSSBytes'], 64 * 1024 * 1024)
                self.assertGreaterEqual(end['bytesRead'], path.stat().st_size)

    def test_fork_history_virtual_offsets_and_two_client_revisions(self):
        child = '00000000-0000-0000-0000-000000000001'
        parent = '00000000-0000-0000-0000-000000000002'
        root = self.root / 'codex/sessions'; root.mkdir(parents=True)
        path = root / ('rollout-' + child + '.jsonl')
        parent_path = root / ('rollout-' + parent + '.jsonl')
        def item(ordinal, owner, identity, body):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=owner,
                turn_id='turn', item=dict(type='AgentMessage', id=identity, content=[dict(type='Text', text=body)])))
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=parent, history_mode='paginated', padding='x' * 20000)),
                item(1, parent, 'parent-item', 'parent body')]
        parent_path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        parent_bytes = parent_path.stat().st_size
        rows = [dict(ordinal=2, type='session_meta', payload=dict(id=child, history_mode='paginated',
            history_base=dict(thread_id=parent, end_ordinal_exclusive=2, end_byte_offset=parent_bytes))),
            item(3, child, 'child-item', 'child body')]
        path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        executable = self.root / 'bin/codex'; executable.parent.mkdir()
        executable.write_text('#!/bin/sh\nprintf "codex-cli 0.0.0\\n"\n'); executable.chmod(0o700)
        self.service(lease=30000, extra_environment={'PATH': str(executable.parent)})
        windows = []
        for _ in range(2):
            client, hello = self.client(); thread = self.resolve(client, path, 'codex')
            begin, records, end = self.window_page(client, thread, 'bootstrap', 0)
            self.assertEqual([row['record']['blocks'][0]['text'] for row in records], ['parent body', 'child body'])
            self.assertGreater(records[0]['sourceOffset'], path.stat().st_size)
            self.assertGreaterEqual(records[1]['sourceOffset'], parent_bytes)
            self.assertEqual(end['sourceEnd'], parent_bytes + path.stat().st_size)
            self.assertTrue(all(row['sourceOffset'] < end['sourceEnd'] for row in records))
            consumer = os.environ.get('TESSERA_TEST_FIRST_PAGE_CONSUMER')
            if consumer:
                result = subprocess.run([consumer, 'codex', '--native'], input=b''.join(frame(value) for value in
                    [hello, begin, *records, end]), capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, 'shared native consumer rejected lineage transaction')
                self.assertEqual(json.loads(result.stdout)['renderable_records'], 2)
            head = end['window']['segmentID']; self.window_ack(client, thread, end, [head], head)
            windows.append((client, thread, records, end, head))
        with path.open('a') as output: output.write(json.dumps(item(4, child, 'child-item', 'revised child')) + '\n')
        for client, thread, original, end, head in windows:
            _, patches, updated = self.window_page(client, thread, 'head', end['window']['version'], end['liveCursor'])
            self.assertEqual(len(patches), 1)
            self.assertEqual(patches[0]['recordID'], original[1]['recordID'])
            self.assertEqual(patches[0]['record']['blocks'][0]['text'], 'revised child')
            self.assertGreaterEqual(patches[0]['sourceOffset'], end['sourceEnd'])
            self.assertLess(patches[0]['sourceOffset'], updated['sourceEnd'])
            self.window_ack(client, thread, updated, [head], head)

    def test_canonical_summary_revalidates_unchanged_child_dependencies(self):
        child = '00000000-0000-0000-0000-000000000001'
        parent = '00000000-0000-0000-0000-000000000002'
        root = self.root / 'codex/sessions'; root.mkdir(parents=True)
        parent_path = root / ('rollout-' + parent + '.jsonl')
        row = self.canonical_codex_row(1, 'parent-item', 'inherited canonical')
        row['payload']['thread_id'] = parent
        parent_path.write_text(json.dumps(dict(type='session_meta', ordinal=0,
            payload=dict(id=parent, history_mode='paginated'))) + '\n' + json.dumps(row) + '\n')
        path = root / ('rollout-' + child + '.jsonl')
        path.write_text(json.dumps(dict(type='session_meta', ordinal=2, payload=dict(id=child,
            history_mode='paginated', history_base=dict(thread_id=parent, end_ordinal_exclusive=2,
            end_byte_offset=parent_path.stat().st_size)))) + '\n')
        self.service(lease=30000, extra_environment={'PATH': '/nonexistent'})
        client, _ = self.client(); thread = self.resolve(client, path, 'codex')
        client.sendall(frame(dict(kind='summary', id='first', thread=thread)))
        first = receive(client)
        self.assertEqual(first['kind'], 'summary')
        self.assertIn('inherited canonical', json.dumps(first['records']))
        client.sendall(frame(dict(kind='summary', id='unchanged', thread=thread)))
        self.assertEqual(receive(client)['revision'], first['revision'])
        parent_path.unlink()  # This test owns the disposable synthetic source.
        client.sendall(frame(dict(kind='summary', id='parent_removed', thread=thread)))
        error = receive(client)
        self.assertEqual((error['kind'], error['code']), ('error', 'sourceMissing'))

    def test_canonical_summary_continuations_under_shared_cache_pressure(self):
        root = self.root / 'codex/sessions'; root.mkdir(parents=True)
        paths = []
        for number in range(4):
            session = f'00000000-0000-0000-0000-{number + 100:012d}'
            path = root / ('rollout-' + session + '.jsonl')
            with path.open('w') as output:
                output.write(json.dumps(dict(type='session_meta', ordinal=0,
                    payload=dict(id=session, history_mode='paginated'))) + '\n')
                # Four cold indexes share one metadata budget. The long final
                # record forces scheduler yields after the small-record
                # metadata prefix has been admitted; none may restart.
                for ordinal in range(1, 6001):
                    row = self.canonical_codex_row(ordinal, f'{ordinal:08d}' + 'x' * 232, 'preview')
                    row['payload']['thread_id'] = session
                    output.write(json.dumps(row) + '\n')
                output.write('{"ordinal":6001,"type":"world_state","payload":{"full":false,"state":"')
                for _ in range(70 * 16): output.write('x' * 65536)
                output.write('"}}\n')
            paths.append(path)
        self.service(lease=30000, extra_environment={'PATH': '/nonexistent'})
        readers = []
        for index, path in enumerate(paths):
            client, _ = self.client()
            readers.append((client, self.resolve(client, path, 'codex'), index))
        started = time.monotonic()
        for client, thread, index in readers:
            client.sendall(frame(dict(kind='summary', id=f'cold-{index}', thread=thread)))
        successes = capacities = 0
        for client, _, _ in readers:
            value = receive(client, timeout=20)
            if value['kind'] == 'error':
                self.assertEqual(value['code'], 'codexIndexCapacity', value)
                capacities += 1
            else:
                self.assertEqual(value['kind'], 'summary', value)
                self.assertIn('preview', json.dumps(value['records']))
                self.assertGreater(value['bytesRead'], 64 * 1024 * 1024)
                successes += 1
        # Index size is not an admission criterion: every cold summary
        # completes under shared pressure instead of one being rejected.
        self.assertEqual((successes, capacities), (len(readers), 0))
        self.assertLess(time.monotonic() - started, 20, 'no 30-second continuation restart loop')
        print(json.dumps(dict(probe='canonical_cold_summary_cache_pressure', successes=successes,
                              capacities=capacities, elapsed_ms=round((time.monotonic() - started) * 1000, 3))), flush=True)

    def test_growing_retained_revision_splits_without_resetting_live_cursor(self):
        session = '00000000-0000-0000-0000-000000000001'
        path = self.root / 'codex/sessions' / ('rollout-' + session + '.jsonl'); path.parent.mkdir(parents=True)
        executable = self.root / 'bin/codex'; executable.parent.mkdir()
        executable.write_text('#!/bin/sh\nprintf "codex-cli 0.0.0\\n"\n'); executable.chmod(0o700)
        def item(ordinal, index, body):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=session, turn_id='turn',
                item=dict(type='AgentMessage', id=f'item-{index}', content=[dict(type='Text', text=body)])))
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=session, history_mode='paginated'))]
        rows += [item(index + 1, index, 'a' * 900) for index in range(100)]
        path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        self.service(lease=30000, extra_environment={'PATH': str(executable.parent)})
        client, _ = self.client(); thread = self.resolve(client, path, 'codex')
        _, records, original = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(len(records), 100)
        head = original['window']['segmentID']; self.window_ack(client, thread, original, [head], head)
        live = original['liveCursor']
        with path.open('a') as output:
            for index in range(12): output.write(json.dumps(item(101 + index, index, 'z' * 16000)) + '\n')
        _, patches, update = self.window_page(client, thread, 'head', 1, live)
        self.assertEqual(update['window']['lane'], 'revisions')
        parts = update['window'].get('partitions', [])
        self.assertGreaterEqual(len(parts), 2)
        self.assertEqual(sum(part['count'] for part in parts), 100)
        self.assertEqual(parts[0]['before'], original['window']['before'])
        self.assertEqual(parts[-1]['after'], original['window']['after'])
        self.assertEqual(update['liveCursor'], live)
        self.assertTrue(patches)
        # A rejected ACK cannot discard the original or its pending split.
        client.sendall(frame({'kind': 'window.ack', 'id': 'bad-split-ack', 'thread': thread,
            'transaction': update['id'], 'windowVersion': 2, 'viewport': [head], 'head': head}))
        self.assertEqual(receive(client)['kind'], 'resyncRequired')
        self.assertEqual(receive(client)['code'], 'windowAckRevisionRetention')
        ids = [part['id'] for part in parts]
        ack = self.window_ack(client, thread, update, ids[-4:], ids[-1])
        self.assertEqual(ack['liveCursor'], live)
        replay = self.window_ack(client, thread, update, ids[-4:], ids[-1])
        self.assertEqual(replay['liveCursor'], live)
        # Interior boundaries remain usable after the atomic split commits.
        _, older, history = self.window_page(client, thread, 'before', 2, parts[-1]['before'])
        self.assertTrue(older)
        self.assertLess(older[-1]['order'], parts[-1]['offset'])

    def test_window_rejects_reused_transaction_and_fractional_version(self):
        path = self.transcript(count=2); self.service(lease=30000)
        client, _ = self.client(); thread = self.resolve(client, path)
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']; self.window_ack(client, thread, end, [head], head)
        client.sendall(frame({'kind': 'window.read', 'id': end['id'], 'thread': thread, 'operation': 'bootstrap', 'windowVersion': 0}))
        self.assertEqual(receive(client)['code'], 'windowTransactionReused')
        for version in (None, 1.5, '1'):
            client.sendall(frame({'kind': 'window.read', 'id': 'invalid', 'thread': thread, 'operation': 'head',
                'windowVersion': version, 'cursor': end['liveCursor']}))
            self.assertEqual(receive(client)['code'], 'invalidWindowVersion')
        self.window_page(client, thread, 'head', 1, end['liveCursor'])

    def test_window_control_survives_deleted_source(self):
        path = self.transcript(count=2); self.service(lease=30000)
        client, _ = self.client(); thread = self.resolve(client, path)
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        path.unlink()
        head = end['window']['segmentID']; self.window_ack(client, thread, end, [head], head)
        client.sendall(frame({'kind': 'window.cancel', 'id': 'cancel', 'thread': thread, 'transaction': 'absent'}))
        self.assertEqual(receive(client)['kind'], 'window.cancelled')
        client.sendall(frame({'kind': 'window.release', 'id': 'release', 'thread': thread}))
        self.assertEqual(receive(client)['kind'], 'window.released')

    def test_window_release_reuses_capacity_and_is_client_scoped(self):
        path = self.transcript(count=2); self.service(lease=30000)
        client, _ = self.client(); other, _ = self.client()
        thread = self.resolve(client, path); self.resolve(other, path)
        _, _, other_end = self.window_page(other, thread, 'bootstrap', 0)
        other_head = other_end['window']['segmentID']; self.window_ack(other, thread, other_end, [other_head], other_head)
        for index in range(20):
            candidate = path.parent / f'fixture-{index}.jsonl'; candidate.write_bytes(path.read_bytes())
            selected = self.resolve(client, candidate)
            _, _, end = self.window_page(client, selected, 'bootstrap', 0)
            head = end['window']['segmentID']; self.window_ack(client, selected, end, [head], head)
            client.sendall(frame({'kind': 'window.release', 'id': 'release', 'thread': selected}))
            self.assertEqual(receive(client)['kind'], 'window.released')
        self.window_page(other, thread, 'head', 1, other_end['liveCursor'])

    def test_window_cancel_after_queued_read_frees_staging(self):
        path = self.transcript(count=2); self.service(lease=30000)
        client, _ = self.client(); thread = self.resolve(client, path)
        client.sendall(frame({'kind': 'window.read', 'id': 'abandoned', 'thread': thread, 'operation': 'bootstrap', 'windowVersion': 0}) +
            frame({'kind': 'window.cancel', 'id': 'cancel', 'thread': thread, 'transaction': 'abandoned'}))
        self.read_page(client)
        self.assertEqual(receive(client)['kind'], 'window.cancelled')
        self.window_page(client, thread, 'bootstrap', 0)

    def test_window_unsubscribe_all_requires_exact_pending_thread_drain(self):
        path = self.transcript(count=2); self.service(lease=30000)
        client, _ = self.client(); thread = self.resolve(client, path)
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        self.window_ack(client, thread, end, [head], head)
        with path.open('a') as output:
            output.write(json.dumps({'type': 'user', 'uuid': 'appended',
                'parentUuid': 'synthetic-1',
                'message': {'role': 'user', 'content': 'appended'}}) + '\n')
        client.sendall(frame({'kind': 'subscribe', 'id': 'watch', 'thread': thread,
            'interest': 'fast', 'windowVersion': 1, 'liveCursor': end['liveCursor']}))
        self.assertEqual(receive(client)['kind'], 'subscribed')
        self.read_page(client)
        client.sendall(frame({'kind': 'unsubscribe', 'id': 'all'}))
        self.assertEqual(receive(client).get('code'), 'threadRequired')
        client.sendall(frame({'kind': 'unsubscribe', 'id': 'exact', 'thread': thread}))
        drained = receive(client)
        self.assertEqual((drained['kind'], drained['id']), ('window.cancelled', 'exact'))
        self.window_page(client, thread, 'head', 1, end['liveCursor'])

    def test_window_native_deep_revision_survives_more_than_512_loaded_records(self):
        client, thread, fixture = self.native_codex(1000)
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']; viewport = [head]; before = end['window']['before']; live = end['liveCursor']
        self.window_ack(client, thread, end, viewport, head)
        for _ in range(9):
            _, records, end = self.window_page(client, thread, 'before', end['window']['version'], before)
            before = end['window']['before']; viewport.insert(0, end['window']['segmentID']); viewport = viewport[:4]
            self.window_ack(client, thread, end, viewport, head)
        original = records[0]['revision']
        items = json.loads(fixture.read_text()); items[0]['item']['text'] = 'revised deep visible record'; fixture.write_text(json.dumps(items))
        changed = []
        for _ in range(32):
            _, updates, end = self.window_page(client, thread, 'head', end['window']['version'], live)
            self.assertEqual(end['window']['lane'], 'revisions')
            changed.extend(updates)
            self.window_ack(client, thread, end, viewport, head)
            if not end['hasNewer']: break
        self.assertFalse(end['hasNewer'], 'revision sweep must finish without rereading its prefix')
        self.assertEqual([item['recordID'] for item in changed], ['item-0'])
        self.assertGreater(changed[0]['revision'], original)

    def test_window_wire_preserves_known_and_unknown_native_dispositions(self):
        client, thread, fixture = self.native_codex(1)
        _, records, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(records[0]['disposition'], 'message')
        self.assertTrue(records[0]['visible'])
        head = end['window']['segmentID']; self.window_ack(client, thread, end, [head], head)
        items = json.loads(fixture.read_text())
        items[0]['item'] = {'id': 'item-0', 'type': 'futureItem', 'text': 'synthetic'}
        fixture.write_text(json.dumps(items))
        _, records, _ = self.window_page(client, thread, 'head', end['window']['version'], end['liveCursor'])
        self.assertEqual(records[0]['disposition'], 'unclassified')
        self.assertEqual(records[0]['sourceType'], 'app-server/futureItem')

    def test_native_revision_sweep_cancel_replays_unacknowledged_coverage(self):
        client, thread, fixture = self.native_codex(100)
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']; live = end['liveCursor']
        self.window_ack(client, thread, end, [head], head)
        items = json.loads(fixture.read_text())
        for item in items: item['item']['text'] += ' revised'
        fixture.write_text(json.dumps(items))
        _, first, pending = self.window_page(client, thread, 'head', 1, live)
        self.assertTrue(pending['hasNewer'])
        self.assertLessEqual(len(first), 64)
        client.sendall(frame({'kind': 'window.cancel', 'id': 'cancel_slice', 'thread': thread,
                             'transaction': pending['id']}))
        self.assertEqual(receive(client)['kind'], 'window.cancelled')
        _, replay, end = self.window_page(client, thread, 'head', 1, live)
        self.assertEqual(replay[0]['recordID'], first[0]['recordID'])
        changed = list(replay)
        for _ in range(32):
            self.window_ack(client, thread, end, [head], head)
            if not end['hasNewer']: break
            _, updates, end = self.window_page(client, thread, 'head', end['window']['version'], live)
            changed.extend(updates)
        self.assertFalse(end['hasNewer'])
        self.assertEqual(len(changed), 100)
        self.assertEqual(len({item['recordID'] for item in changed}), 100)

    def test_automatic_native_reads_coalesce_but_manual_receipt_reads_are_fresh(self):
        client, thread, fixture = self.native_codex(1)
        other, _ = self.client()
        self.resolve(other, self.root / 'codex/sessions/2026/09/12/rollout-00000000-0000-0000-0000-000000000001.jsonl', provider='codex')
        checkpoints = []
        for stream in (client, other):
            _, _, end = self.window_page(stream, thread, 'bootstrap', 0)
            head = end['window']['segmentID']
            self.window_ack(stream, thread, end, [head], head)
            checkpoints.append(end)
        items = json.loads(fixture.read_text()); items[0]['item']['text'] = 'automatic revision'
        fixture.write_text(json.dumps(items))
        time.sleep(.21)  # Expire the deliberately bounded provider response cache.
        calls = self.root / 'native-calls'
        before = len(calls.read_text().splitlines())
        for stream, end in zip((client, other), checkpoints):
            stream.sendall(frame({'kind': 'subscribe', 'id': 'watch', 'thread': thread,
                'interest': 'fast', 'windowVersion': 1, 'liveCursor': end['liveCursor']}))
        for stream in (client, other):
            self.assertEqual(receive(stream)['kind'], 'subscribed')
            _, changed, end = self.read_page(stream)
            self.assertEqual(changed[0]['record']['blocks'][0]['text'], 'automatic revision')
        self.assertEqual(len(calls.read_text().splitlines()) - before, 1,
                         'two clients share an identical inclusive tail/revision RPC')
        client.sendall(frame({'kind': 'unsubscribe', 'id': 'drain', 'thread': thread}))
        self.assertEqual(receive(client)['kind'], 'window.cancelled')
        items[0]['item']['text'] = 'fresh receipt revision'; fixture.write_text(json.dumps(items))
        _, changed, end = self.window_page(client, thread, 'head', 1, checkpoints[0]['liveCursor'])
        self.assertEqual(changed[0]['record']['blocks'][0]['text'], 'fresh receipt revision')

    def test_encoded_locator_and_raw_eof_include_partial_tail(self):
        path = self.transcript(count=2)
        with path.open('ab') as stream:
            stream.write(b'{"type":"user","text":"preexisting')
        self.service()
        client, _ = self.client()
        encoded = base64.urlsafe_b64encode(str(path).encode()).decode().rstrip('=')
        thread = self.resolve(client, encoded)
        _, records, end = self.page(client, thread)
        self.assertEqual(len(records), 2)
        self.assertEqual(end['sourceEnd'], path.stat().st_size)
        _, updates, fresh = self.page(client, thread, 'updates', end['liveCursor'])
        self.assertEqual(updates, [])
        self.assertEqual(fresh['sourceEnd'], path.stat().st_size)
        self.assertFalse(fresh['hasNewer'])

    def native_codex(self, count=250, native_only=False):
        path = self.root / 'codex/sessions/2026/09/12/rollout-00000000-0000-0000-0000-000000000001.jsonl'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({'type': 'response_item', 'payload': {'type': 'message', 'role': 'assistant',
            'content': [{'type': 'output_text', 'text': 'fallback'}]}}) + '\n')
        fixture = self.root / 'items.json'
        fixture.write_text(json.dumps([{'turnId': 'turn', 'item': {'type': 'agentMessage', 'id': f'item-{n}', 'text': f'native {n}'}}
                                       for n in range(count)]))
        executable = self.root / 'codex-bin/codex'
        executable.parent.mkdir()
        executable.write_text('''#!/usr/bin/env python3
import json, os, sys
assert os.environ.get('CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED') == '1'
if '--version' in sys.argv:
    print('codex-cli 0.154.0'); raise SystemExit(0)
for raw in sys.stdin:
    request = json.loads(raw)
    method = request['method']
    if method == 'initialized': continue
    if method == 'initialize': result = {}
    elif method == 'thread/list':
        assert request['params']['useStateDbOnly'] is True
        assert request['params']['modelProviders'] == []
        assert 'subAgentThreadSpawn' in request['params']['sourceKinds']
        result = {'data': [] if request['params']['archived'] else [{'id': '00000000-0000-0000-0000-000000000002',
                  'path': None if os.environ.get('MOCK_NATIVE_ONLY') == '1' else os.environ['MOCK_TRANSCRIPT'], 'updatedAt': 2000000000,
                  'preview': 'x' * 2000000 if os.path.exists(os.environ['MOCK_ITEMS'] + '.large-inventory') else ''}], 'nextCursor': None}
        if os.path.exists(os.environ['MOCK_ITEMS'] + '.escaped-cursor'):
            assert not request['params'].get('cursor'), 'clipped opaque cursor was reused'
            result['nextCursor'] = chr(1) * 5000
        if result['data'] and os.path.exists(os.environ['MOCK_ITEMS'] + '.identity-conflict'):
            result['data'].append(dict(result['data'][0], id='00000000-0000-0000-0000-000000000003'))
    elif method == 'thread/read':
        assert request['params']['includeTurns'] is False
        if request['params']['threadId'] == '00000000-0000-0000-0000-000000000099':
            print(json.dumps({'id': request['id'], 'error': {'code': -32600, 'message': 'not found'}}), flush=True); continue
        with open(os.environ['MOCK_CALLS'], 'a') as log: log.write('summary\\n')
        updated = 0
        if os.path.exists(os.environ['MOCK_ITEMS'] + '.updated'):
            with open(os.environ['MOCK_ITEMS'] + '.updated') as marker: updated = int(marker.read() or '1')
        result = {'thread': {'id': request['params']['threadId'], 'name': 'Native title', 'preview': 'Stored preview',
                  'cwd': '/synthetic/project', 'gitInfo': {'branch': 'test'},
                  'updatedAt': 2000000000 + updated, 'turns': []}}
    elif method == 'thread/items/list':
        with open(os.environ['MOCK_CALLS'], 'a') as log: log.write('read\\n')
        with open(os.environ['MOCK_ITEMS']) as stream: items = json.load(stream)
        params = request['params']; asc = params['sortDirection'] == 'asc'
        cursor = params.get('cursor')
        reverse = cursor and cursor.startswith('reverse-')
        boundary = int(cursor.split('-', 1)[1]) if cursor else (-1 if asc else len(items))
        indices = [n for n in (range(len(items)) if asc else reversed(range(len(items))))
                   if ((n >= boundary if asc else n <= boundary) if reverse else (n > boundary if asc else n < boundary))]
        selected = indices[:params['limit']]
        result = {'data': [items[n] for n in selected],
                  'nextCursor': f'opaque-{selected[-1]}' if len(indices) > len(selected) else None,
                  'backwardsCursor': f'reverse-{selected[0]}' if selected else None}
    else: raise SystemExit(3)
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
''')
        executable.chmod(0o700)
        native_mock(executable)
        self.service(lease=30000, extra_environment={'PATH': str(executable.parent) + os.pathsep + os.environ['PATH'],
            'MOCK_ITEMS': str(fixture), 'MOCK_TRANSCRIPT': str(path), 'MOCK_CALLS': str(self.root / 'native-calls'),
            'MOCK_NATIVE_ONLY': '1' if native_only else '0'})
        client, _ = self.client()
        client.sendall(frame({'kind': 'resolve', 'id': 'resolve', 'provider': 'codex', 'transcriptRef': str(path)}))
        resolved = receive(client)
        self.assertEqual(resolved['kind'], 'resolved')
        return client, resolved['thread'], fixture

    def canonical_codex_row(self, ordinal, identity, body):
        return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed',
            thread_id='00000000-0000-0000-0000-000000000001', turn_id='turn',
            item=dict(type='AgentMessage', id=identity, content=[dict(type='Text', text=body)])))

    def canonical_codex_file(self, rows):
        path = self.root / 'codex/sessions/2026/09/12/rollout-00000000-0000-0000-0000-000000000001.jsonl'
        header = dict(ordinal=0, type='session_meta', payload=dict(
            id='00000000-0000-0000-0000-000000000001', history_mode='paginated'))
        path.write_text(''.join(json.dumps(row) + '\n' for row in [header, *rows]))
        return path

    def test_codex_native_store_cannot_hide_newer_canonical_transcript(self):
        client, thread, _ = self.native_codex(1)
        self.canonical_codex_file([self.canonical_codex_row(1, 'item-0', 'native 0'),
                                   self.canonical_codex_row(2, 'item-1', 'canonical latest')])
        _, records, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual([row['record']['blocks'][0]['text'] for row in records], ['native 0', 'canonical latest'])
        self.assertEqual(end['backend'], 'jsonl')
        self.assertEqual(end['fallbackReason'], 'codexCanonicalTranscriptAuthority')
        head = end['window']['segmentID']
        self.window_ack(client, thread, end, [head], head)

    def test_codex_native_store_cannot_hide_canonical_revision(self):
        client, thread, _ = self.native_codex(1)
        path = self.canonical_codex_file([self.canonical_codex_row(1, 'item-0', 'native 0')])
        _, records, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(records[0]['record']['blocks'][0]['text'], 'native 0')
        head = end['window']['segmentID']
        self.window_ack(client, thread, end, [head], head)
        with path.open('a') as output:
            output.write(json.dumps(self.canonical_codex_row(2, 'item-0', 'canonical revision')) + '\n')
        _, patches, update = self.window_page(client, thread, 'head', end['window']['version'], end['liveCursor'])
        self.assertEqual([row['record']['blocks'][0]['text'] for row in patches], ['canonical revision'])
        self.assertEqual(patches[0]['recordID'], records[0]['recordID'])
        self.assertGreater(patches[0]['revision'], records[0]['revision'])
        self.window_ack(client, thread, update, [head], head)

    def test_codex_native_store_cannot_hide_canonical_summary(self):
        client, thread, _ = self.native_codex(1)
        self.canonical_codex_file([self.canonical_codex_row(1, 'item-0', 'canonical preview')])
        client.sendall(frame(dict(kind='summary', id='fresh_summary', thread=thread)))
        summary = receive(client)
        self.assertEqual(summary['kind'], 'summary', summary)
        self.assertIn('canonical preview', json.dumps(summary['records']))
        self.assertNotIn('Stored preview', json.dumps(summary['records']))

    def test_codex_new_canonical_authority_fences_native_window(self):
        client, thread, _ = self.native_codex(1)
        _, records, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(end['backend'], 'codex-appserver')
        head = end['window']['segmentID']
        self.window_ack(client, thread, end, [head], head)
        self.canonical_codex_file([self.canonical_codex_row(1, 'item-0', 'canonical replacement')])
        client.sendall(frame(dict(kind='window.read', id='old_head', thread=thread,
            operation='head', windowVersion=end['window']['version'], cursor=end['liveCursor'])))
        error = receive(client)
        self.assertEqual((error['kind'], error['code']), ('error', 'sourceChanged'))
        client.sendall(frame(dict(kind='window.read', id='replacement_bootstrap', thread=thread,
                                 operation='bootstrap', windowVersion=0)))
        _, fresh, replacement = self.read_page(client)
        self.assertEqual(replacement['backend'], 'jsonl')
        self.assertEqual(fresh[0]['record']['blocks'][0]['text'], 'canonical replacement')
        new_head = replacement['window']['segmentID']
        self.window_ack(client, thread, replacement, [new_head], new_head)

    def test_codex_canonical_header_identity_conflict_never_uses_native_store(self):
        client, thread, _ = self.native_codex(1)
        path = self.canonical_codex_file([])
        header = dict(ordinal=0, type='session_meta', payload=dict(
            id='00000000-0000-0000-0000-000000000099', history_mode='paginated'))
        path.write_text(json.dumps(header) + '\n')
        client.sendall(frame(dict(kind='window.read', id='wrong_identity', thread=thread,
                                 operation='bootstrap', windowVersion=0)))
        error = receive(client)
        self.assertEqual((error['kind'], error['code']), ('error', 'codexIdentityConflict'))

    def test_codex_canonical_summary_excludes_inherited_and_model_context(self):
        client, thread, _ = self.native_codex(1)
        path = self.canonical_codex_file([])
        header = dict(ordinal=0, type='session_meta', payload=dict(
            id='00000000-0000-0000-0000-000000000001', history_mode='paginated',
            subagent_history_start_ordinal=3))
        inherited = self.canonical_codex_row(1, 'parent-item', 'inherited parent prose')
        inherited['payload']['thread_id'] = 'parent'
        context = dict(ordinal=2, type='response_item', payload=dict(type='message',
            role='assistant', content=[dict(type='output_text', text='model context prose')]))
        path.write_text(''.join(json.dumps(row) + '\n' for row in (header, inherited, context)))
        client.sendall(frame(dict(kind='summary', id='child_summary', thread=thread)))
        summary = receive(client)
        self.assertEqual(summary['kind'], 'summary', summary)
        self.assertEqual(summary['records'], [])

    def test_codex_canonical_archive_move_never_restores_stale_store(self):
        client, thread, _ = self.native_codex(1)
        path = self.canonical_codex_file([self.canonical_codex_row(1, 'item-0', 'archived canonical')])
        archived = self.root / 'codex/archived_sessions' / path.name
        archived.parent.mkdir()
        path.rename(archived)
        _, records, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(end['backend'], 'jsonl')
        self.assertEqual(records[0]['record']['blocks'][0]['text'], 'archived canonical')
        head = end['window']['segmentID']
        self.window_ack(client, thread, end, [head], head)
        with archived.open('a') as output:
            output.write(json.dumps(self.canonical_codex_row(2, 'item-1', 'archived live')) + '\n')
        _, records, update = self.window_page(client, thread, 'head', end['window']['version'], end['liveCursor'])
        self.assertEqual(records[-1]['record']['blocks'][0]['text'], 'archived live')
        new_head = update['window']['segmentID']
        self.window_ack(client, thread, update, [new_head], new_head)

    def test_codex_summary_churn_preserves_acknowledged_window_index(self):
        client, thread, _ = self.native_codex(1)
        path = self.canonical_codex_file([self.canonical_codex_row(1, 'item-0', 'retained')])
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        self.window_ack(client, thread, end, [head], head)
        other, _ = self.client()
        for number in range(26):
            session = f'00000000-0000-0000-0000-{number + 100:012d}'
            unrelated = path.parent / ('rollout-' + session + '.jsonl')
            row = self.canonical_codex_row(1, 'item', 'unrelated')
            row['payload']['thread_id'] = session
            unrelated.write_text(json.dumps(dict(type='session_meta', ordinal=0,
                payload=dict(id=session, history_mode='paginated'))) + '\n' + json.dumps(row) + '\n')
            handle = self.resolve(other, unrelated, 'codex')
            other.sendall(frame(dict(kind='summary', id=f'churn-{number}', thread=handle)))
            self.assertEqual(receive(other)['kind'], 'summary')
        _, records, update = self.window_page(client, thread, 'head', end['window']['version'], end['liveCursor'])
        self.assertEqual(records, [])
        self.window_ack(client, thread, update, [head], head)

    def test_codex_inventory_uses_native_id_and_metadata_without_history_hydration(self):
        client, thread, _ = self.native_codex(1)
        client.sendall(frame({'kind': 'inventory', 'id': 'inventory'}))
        self.assertEqual(receive(client)['kind'], 'inventory.begin')
        row = receive(client)
        self.assertEqual(row['thread'], thread)
        self.assertEqual(row['sessionID'], '00000000-0000-0000-0000-000000000002')
        self.assertEqual(row['modified'], 2000000000)
        self.assertEqual(receive(client)['kind'], 'inventory.end')

    def test_idle_codex_child_memory_is_supervised_without_a_new_request(self):
        executable = self.root / 'bin/codex'; executable.parent.mkdir()
        executable.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, threading, time
if '--version' in sys.argv:
    print('codex-cli 0.154.0'); raise SystemExit(0)
root = pathlib.Path(os.environ['RESOURCE_PROBE'])
(root / 'child.pid').write_text(str(os.getpid()))
def allocate():
    while not (root / 'allocate').exists(): time.sleep(.02)
    # The guard samples resident memory, not virtual allocation or peak RSS.
    # Keep an incompressible working set resident even under simulator load;
    # an idle zero-filled buffer is not a reliable resident-budget fixture.
    retained = bytearray(200 * 1024 * 1024)
    for offset in range(0, len(retained), 65536):
        retained[offset:offset + 65536] = os.urandom(65536)
    (root / 'allocated').touch()
    while True:
        for offset in range(0, len(retained), 4096): retained[offset] ^= 1
        time.sleep(.1)
threading.Thread(target=allocate, daemon=True).start()
for line in sys.stdin:
    request = json.loads(line)
    if request['method'] == 'initialized': continue
    result = {'data': [], 'nextCursor': None} if request['method'] == 'thread/list' else {}
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
''')
        executable.chmod(0o700)
        native_mock(executable)
        service = self.service(lease=10000, extra_environment={
            'PATH': str(executable.parent) + os.pathsep + os.environ['PATH'], 'RESOURCE_PROBE': str(self.root)})
        client, _ = self.client()
        client.sendall(frame(dict(kind='inventory', id='inventory')))
        self.assertEqual(receive(client)['kind'], 'inventory.begin')
        self.assertEqual(receive(client)['kind'], 'inventory.end')
        pid = int((self.root / 'child.pid').read_text())
        (self.root / 'allocate').touch()
        deadline = time.monotonic() + 4
        while True:
            try: os.kill(pid, 0)
            except ProcessLookupError: break
            if time.monotonic() >= deadline:
                resident = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)],
                                          capture_output=True, text=True, timeout=2).stdout.strip()
                self.fail('idle memory watchdog must reap the owned child; '
                          f'allocated={(self.root / "allocated").exists()}, rssKiB={resident}')
            time.sleep(.02)
        self.assertIsNone(service.poll())
        client.sendall(frame(dict(kind='heartbeat', id='survived')))
        self.assertEqual(receive(client)['kind'], 'ack')

    def test_codex_large_inventory_preview_does_not_drop_native_identity(self):
        client, thread, fixture = self.native_codex(1)
        Path(str(fixture) + '.large-inventory').touch()
        client.sendall(frame({'kind': 'inventory', 'id': 'inventory'}))
        self.assertEqual(receive(client)['kind'], 'inventory.begin')
        row = receive(client)
        self.assertEqual(row['thread'], thread)
        self.assertEqual(row['sessionID'], '00000000-0000-0000-0000-000000000002')
        end = receive(client)
        self.assertEqual(end['kind'], 'inventory.end')
        self.assertNotIn('fallbackReason', end)

    def test_path_refresh_cannot_retarget_confirmed_native_id(self):
        client, thread, fixture = self.native_codex(1)
        client.sendall(frame({'kind': 'inventory', 'id': 'inventory'}))
        while receive(client)['kind'] != 'inventory.end': pass
        path = self.root / 'codex/sessions/2026/09/12/rollout-00000000-0000-0000-0000-000000000001.jsonl'
        self.assertEqual(self.resolve(client, path, provider='codex'), thread)
        client.sendall(frame({'kind': 'resolve', 'id': 'native', 'provider': 'codex',
            'nativeSessionID': '00000000-0000-0000-0000-000000000002'}))
        value = receive(client)
        self.assertEqual(value['kind'], 'resolved')
        self.assertEqual(value['sessionID'], '00000000-0000-0000-0000-000000000002')
        self.assertEqual(value['thread'], thread)

    def test_native_inventory_rejects_two_identities_claiming_same_path(self):
        client, _, fixture = self.native_codex(1)
        Path(str(fixture) + '.identity-conflict').touch()
        client.sendall(frame({'kind': 'inventory', 'id': 'inventory'}))
        while True:
            row = receive(client)
            if row['kind'] == 'inventory.end': break
        self.assertEqual(row.get('fallbackReason'), 'codexIdentityConflict')

    def test_native_only_inventory_locator_bootstrap_and_metadata_summary(self):
        client, _, _ = self.native_codex(2, native_only=True)
        client.sendall(frame({'kind': 'inventory', 'id': 'inventory'}))
        self.assertEqual(receive(client)['kind'], 'inventory.begin')
        rows = []
        while True:
            row = receive(client)
            if row['kind'] == 'inventory.end': break
            rows.append(row)
        native = next(row for row in rows if row.get('nativeSessionID'))
        self.assertEqual(native['transcriptRef'], '')
        client.sendall(frame({'kind': 'resolve', 'id': 'native', 'provider': 'codex', 'nativeSessionID': native['sessionID']}))
        resolved = receive(client); self.assertEqual(resolved['thread'], native['thread'])
        for stream in (client, self.client()[0]):
            stream.sendall(frame({'kind': 'summary', 'id': 'summary', 'thread': native['thread']}))
            summary = receive(stream)
            self.assertEqual(summary['kind'], 'summary', summary)
            self.assertEqual(summary['records'][0]['title'], 'Native title')
            self.assertNotIn('status', summary)
        self.assertEqual((self.root / 'native-calls').read_text().splitlines(), ['summary'])
        _, records, end = self.window_page(client, native['thread'], 'bootstrap', 0)
        self.assertEqual([record['recordID'] for record in records], ['item-0', 'item-1'])
        client.sendall(frame({'kind': 'resolve', 'id': 'forged', 'provider': 'codex', 'nativeSessionID': '00000000-0000-0000-0000-000000000099'}))
        self.assertEqual(receive(client)['kind'], 'error')

    def test_inventory_rejects_clipped_escaped_opaque_cursor(self):
        client, _, fixture = self.native_codex(1)
        Path(str(fixture) + '.large-inventory').touch()
        Path(str(fixture) + '.escaped-cursor').touch()
        client.sendall(frame({'kind': 'inventory', 'id': 'inventory'}))
        while True:
            row = receive(client)
            if row['kind'] == 'inventory.end': break
        self.assertEqual(row.get('fallbackReason'), 'codexInventoryBudgetExceeded')

    def test_known_empty_preview_native_thread_resolves_without_listing(self):
        client, _, _ = self.native_codex(2, native_only=True)
        client.sendall(frame({'kind': 'resolve', 'id': 'empty-preview', 'provider': 'codex',
            'nativeSessionID': '00000000-0000-0000-0000-000000000003'}))
        resolved = receive(client)
        self.assertEqual(resolved['kind'], 'resolved', resolved)
        _, records, _ = self.window_page(client, resolved['thread'], 'bootstrap', 0)
        self.assertEqual([record['recordID'] for record in records], ['item-0', 'item-1'])

    def test_two_clients_four_fast_fifty_slow_interests_have_bounded_delivery(self):
        self.multi_client_load('claude')

    def test_two_clients_four_fast_fifty_slow_codex_interests_have_bounded_delivery(self):
        self.multi_client_load('codex')

    def multi_client_load(self, provider):
        if provider == 'claude':
            paths = [self.transcript(name=f'load-{index}', count=2) for index in range(54)]
            self.service(lease=30000)
        else:
            _, _, fixture = self.native_codex(100)
            paths = []
            for index in range(54):
                path = self.root / f'codex/sessions/rollout-00000000-0000-0000-0000-{index + 100:012d}.jsonl'
                # Native-only capability: no invalid pseudo-canonical header.
                path.write_text(''); paths.append(path)
        clients = [self.client()[0], self.client()[0]]
        handles = [self.resolve(clients[0], path, provider=provider) for path in paths]
        fast = set(handles[:4]); slow = set(handles[4:])
        checkpoints = {}
        for number, stream in enumerate(clients):
            for thread in handles[:4]:
                _, _, end = self.window_page(stream, thread, 'bootstrap', 0)
                head = end['window']['segmentID']; self.window_ack(stream, thread, end, [head], head)
                checkpoints[number, thread] = end
        for number, stream in enumerate(clients):
            requests = []
            for thread in handles:
                request = {'kind': 'subscribe', 'id': 'watch_' + thread, 'thread': thread,
                           'interest': 'fast' if thread in fast else 'slow'}
                if thread in fast:
                    request.update(windowVersion=1, liveCursor=checkpoints[number, thread]['liveCursor'])
                requests.append(frame(request))
            stream.sendall(b''.join(requests))

        def collect(expected_fast, timeout, started=None):
            seen_fast = [set(), set()]; seen_slow = [set(), set()]
            started = started if started is not None else time.monotonic(); latest_fast = 0
            while any(seen_slow[n] != slow or (expected_fast and seen_fast[n] != fast) for n in range(2)):
                remaining = timeout - (time.monotonic() - started)
                self.assertGreater(remaining, 0, 'both clients must receive every due interest without starvation')
                ready, _, _ = select.select(clients, [], [], remaining)
                self.assertTrue(ready, f'missing deliveries fast={[len(values) for values in seen_fast]} slow={[len(values) for values in seen_slow]}')
                for stream in ready:
                    number = clients.index(stream); value = receive(stream)
                    kind = value['kind']
                    self.assertNotIn(kind, ('error', 'resyncRequired'), value)
                    if kind == 'summary':
                        seen_slow[number].add(value['thread'])
                        stream.sendall(frame({'kind': 'ack', 'id': 'summary_ack', 'requestID': value['id']}))
                    elif kind == 'page.end':
                        if value['records']:
                            seen_fast[number].add(value['thread']); latest_fast = max(latest_fast, time.monotonic() - started)
                        checkpoint = checkpoints[number, value['thread']]
                        head = value['window'].get('segmentID', checkpoint['window']['segmentID'])
                        if value['window'].get('segmentID'): checkpoints[number, value['thread']] = value
                        stream.sendall(frame({'kind': 'window.ack', 'id': 'commit_' + value['id'], 'thread': value['thread'],
                            'transaction': value['id'], 'windowVersion': value['window']['version'], 'viewport': [head], 'head': head}))
            return latest_fast, time.monotonic() - started

        collect(False, 7)
        started = time.monotonic()
        if provider == 'claude':
            for index, path in enumerate(paths):
                with path.open('a') as output:
                    output.write(json.dumps({'type': 'user', 'uuid': f'load-{index}-2', 'parentUuid': f'load-{index}-1',
                        'message': {'role': 'user', 'content': 'new live update'}}) + '\n')
        else:
            items = json.loads(fixture.read_text()); items[-1]['item']['text'] = 'latest live revision'
            # The mock reads this file per RPC. Publish its database snapshot
            # atomically: truncate/write would let it parse a half-written
            # test fixture and crash, which is not a provider pagination test.
            updated = fixture.with_suffix('.pending')
            updated.write_text(json.dumps(items)); os.replace(updated, fixture)
            Path(str(fixture) + '.updated').touch()
        fast_latency, slow_latency = collect(True, 7, started)
        print(json.dumps({'probe': 'two_clients_4_fast_50_slow', 'provider': provider,
                          'fast_delivery_ms': round(fast_latency * 1000, 3), 'slow_delivery_ms': round(slow_latency * 1000, 3)}), flush=True)
        self.assertLess(fast_latency, 1.0, 'opened-thread delivery under 4 fast / 50 slow load')
        self.assertLess(slow_latency, 7.0, 'visible-card delivery under 4 fast / 50 slow load')

    def test_codex_native_pagination_revision_and_retry(self):
        client, thread, fixture = self.native_codex()
        begin, newest, end = self.page(client, thread)
        self.assertTrue(begin['sourceIdentity'].startswith('codex-appserver:'), begin)
        self.assertEqual([x['recordID'] for x in newest], [f'item-{n}' for n in range(150, 250)])
        _, older, history = self.page(client, thread, 'history', end['historyCursor'])
        self.assertEqual([x['recordID'] for x in older], [f'item-{n}' for n in range(50, 150)])
        self.assertNotIn('liveCursor', history)
        items = json.loads(fixture.read_text())
        items[-1]['item']['text'] = 'revised in place'
        items.append({'turnId': 'turn', 'item': {'type': 'agentMessage', 'id': 'item-250', 'text': 'new'}})
        fixture.write_text(json.dumps(items))
        _, updates, live = self.page(client, thread, 'updates', end['liveCursor'])
        self.assertEqual([x['recordID'] for x in updates], ['item-249', 'item-250'])
        self.assertGreater(updates[0]['revision'], newest[-1]['revision'])
        self.assertFalse(live['hasNewer'])
        _, replay, _ = self.page(client, thread, 'updates', end['liveCursor'])
        self.assertEqual(replay, updates)
        _, unchanged, current = self.page(client, thread, 'updates', live['liveCursor'])
        self.assertEqual(unchanged, [])
        self.assertEqual(current['liveCursor'], live['liveCursor'])

    def test_codex_native_revision_without_new_item_keeps_live_checkpoint(self):
        client, thread, fixture = self.native_codex(4)
        _, _, end = self.page(client, thread)
        items = json.loads(fixture.read_text()); items[-1]['item']['text'] = 'revised'
        fixture.write_text(json.dumps(items))
        _, changes, live = self.page(client, thread, 'updates', end['liveCursor'])
        self.assertEqual([x['recordID'] for x in changes], ['item-3'])
        self.assertGreater(changes[0]['revision'], 4)
        _, replay, _ = self.page(client, thread, 'updates', end['liveCursor'])
        self.assertEqual(replay, changes)
        items.append({'turnId': 'turn', 'item': {'type': 'agentMessage', 'id': 'item-4', 'text': 'appended'}})
        fixture.write_text(json.dumps(items))
        _, appended, _ = self.page(client, thread, 'updates', live['liveCursor'])
        self.assertEqual([x['recordID'] for x in appended], ['item-4'])

    def test_codex_native_multimedia_and_questions_are_not_erased(self):
        client, thread, fixture = self.native_codex(4)
        fixture.write_text(json.dumps([
            {'turnId': 'turn', 'item': {'type': 'functionCallOutput', 'id': 'image', 'output': [{'type': 'input_image', 'image_url': 'synthetic'}]}},
            {'turnId': 'turn', 'item': {'type': 'dynamicToolCall', 'id': 'audio', 'tool': 'synthetic', 'arguments': {}, 'status': 'completed', 'contentItems': [{'type': 'inputAudio', 'audioUrl': 'synthetic'}]}},
            {'turnId': 'turn', 'item': {'type': 'agentMessage', 'id': 'question', 'text': '', 'questions': [{'title': 'Choose a mode', 'options': ['One', 'Two']}]}}
        ]))
        _, records, _ = self.page(client, thread)
        self.assertEqual(records[0]['record']['blocks'][0]['type'], 'attachment')
        self.assertEqual(records[1]['record']['blocks'][-1]['mediaType'], 'audio')
        self.assertEqual([b['text'] for b in records[2]['record']['blocks']], ['', 'Choose a mode', 'One', 'Two'])

    def test_native_bootstrap_history_and_live_have_independent_cursors(self):
        path = self.transcript()
        self.service(lease=10000)
        client, _ = self.client()
        thread = self.resolve(client, path)
        _, newest, end = self.page(client, thread)
        self.assertEqual(len(newest), 100)
        self.assertEqual(newest[-1]['record']['blocks'][0]['text'], 'line 249')
        _, older, history = self.page(client, thread, 'history', end['historyCursor'])
        self.assertEqual(len(older), 100)
        self.assertNotIn('liveCursor', history)
        with path.open('a') as stream:
            stream.write(json.dumps({'type': 'assistant', 'uuid': 'reply', 'parentUuid': 'synthetic-249', 'message': {'role': 'assistant', 'content': 'new reply'}}) + '\n')
        _, updates, live = self.page(client, thread, 'updates', end['liveCursor'])
        self.assertEqual(len(updates), 1)
        self.assertNotIn('historyCursor', live)
        self.assertNotIn('hasOlder', live)
        _, first, _ = self.page(client, thread, 'history', history['historyCursor'])
        self.assertEqual(len(first), 50)
        self.assertEqual(len({x['recordID'] for x in first + older + newest + updates}), 251)

    def test_native_cursor_is_client_scoped_and_direction_scoped(self):
        path = self.transcript()
        self.service(lease=10000)
        first, _ = self.client(); second, _ = self.client()
        thread = self.resolve(first, path)
        _, _, end = self.page(first, thread)
        for client, kind, token in [(second, 'history', end['historyCursor']), (first, 'history', end['liveCursor'])]:
            client.sendall(frame({'kind': kind, 'id': 'bad', 'thread': thread, 'cursor': token}))
            self.assertEqual(receive(client)['code'], 'cursorExpired')

    def test_native_source_authority_rejects_traversal_and_symlinks(self):
        path = self.transcript()
        outside = self.root / 'private.jsonl'; outside.write_text('{}\n')
        link = path.parent / 'link.jsonl'; link.symlink_to(outside)
        directory = path.parent / 'escape'; directory.symlink_to(self.root, target_is_directory=True)
        self.service()
        client, _ = self.client()
        disguised = path.parent / 'not-a-transcript.txt'; disguised.write_text('{}\n')
        for target in [outside, link, directory / 'private.jsonl', path.parent / '../../../private.jsonl',
                       str(disguised) + '\0.jsonl', str(path.parent) + '/..\0/private.jsonl']:
            client.sendall(frame({'kind': 'resolve', 'id': 'bad', 'provider': 'claude', 'transcriptRef': str(target)}))
            self.assertEqual(receive(client)['kind'], 'error')
        self.resolve(client, path)

    def test_native_source_replacement_and_anchor_mutation_require_resync(self):
        path = self.transcript()
        self.service(lease=10000)
        client, _ = self.client(); thread = self.resolve(client, path)
        _, _, end = self.page(client, thread)
        content = path.read_bytes(); path.write_bytes(content[:-5] + b'bad!\n')
        client.sendall(frame({'kind': 'updates', 'id': 'mutate', 'thread': thread, 'cursor': end['liveCursor']}))
        self.assertEqual(receive(client)['code'], 'claudeIndexUnproven')
        replacement = path.with_suffix('.replacement'); replacement.write_bytes(content); replacement.replace(path)
        client.sendall(frame({'kind': 'history', 'id': 'replace', 'thread': thread, 'cursor': end['historyCursor']}))
        self.assertEqual(receive(client)['code'], 'sourceChanged')

    def test_native_subscription_pushes_canonical_page_and_requires_ack(self):
        path = self.transcript(count=2)
        self.service(lease=10000)
        client, _ = self.client(); thread = self.resolve(client, path)
        _, _, end = self.page(client, thread)
        client.sendall(frame({'kind': 'subscribe', 'id': 'sub', 'thread': thread, 'interest': 'fast', 'liveCursor': end['liveCursor']}))
        self.assertEqual(receive(client)['kind'], 'subscribed')
        with path.open('a') as stream: stream.write('{"type":"assistant","uuid":"first","parentUuid":"synthetic-1","message":{"role":"assistant","content":"first"}}\n')
        _, records, update = self.read_page(client)
        self.assertEqual(records[0]['record']['blocks'][0]['text'], 'first')
        with path.open('a') as stream: stream.write('{"type":"assistant","uuid":"second","parentUuid":"first","message":{"role":"assistant","content":"second"}}\n')
        self.assertFalse(select.select([client], [], [], 1.1)[0])
        client.sendall(frame({'kind': 'ack', 'id': 'ack', 'requestID': update['id']}))
        _, records, _ = self.read_page(client)
        self.assertEqual(records[0]['record']['blocks'][0]['text'], 'second')

    def test_native_one_connection_can_subscribe_to_multiple_threads(self):
        paths = [self.transcript('first', 1), self.transcript('second', 1)]
        self.service(lease=10000)
        client, _ = self.client()
        threads = []
        for path in paths:
            thread = self.resolve(client, path); threads.append(thread)
            _, _, end = self.page(client, thread)
            client.sendall(frame({'kind': 'subscribe', 'id': 'sub', 'thread': thread, 'interest': 'fast', 'liveCursor': end['liveCursor']}))
            self.assertEqual(receive(client)['kind'], 'subscribed')
        for path in paths:
            with path.open('a') as stream:
                stream.write(json.dumps(dict(type='user', uuid='appended', parentUuid=path.stem + '-0',
                    message=dict(role='user', content='appended'))) + '\n')
        observed = set()
        for _ in paths:
            begin, records, _ = self.read_page(client); observed.add(begin['thread'])
            self.assertEqual(len(records), 1)
        self.assertEqual(observed, set(threads))

    def test_native_page_commits_without_stdio_eof(self):
        path = self.transcript(count=1)
        self.service(lease=10000)
        client, _ = self.client(); thread = self.resolve(client, path)
        self.page(client, thread)
        client.sendall(frame({'kind': 'heartbeat', 'id': 'stillopen'}))
        self.assertEqual(receive(client)['kind'], 'ack')

    def test_slow_summary_needs_no_bootstrap_and_shares_cache_across_clients(self):
        path = self.transcript(count=250)
        self.service(lease=15000)
        first, _ = self.client(); second, _ = self.client()
        thread = self.resolve(first, path)
        summaries = []
        for client in (first, second):
            client.sendall(frame({'kind': 'subscribe', 'id': 'sub', 'thread': thread, 'interest': 'slow'}))
            self.assertEqual(receive(client)['kind'], 'subscribed')
            summary = receive(client)
            self.assertEqual(summary['kind'], 'summary')
            self.assertLessEqual(len(summary['records']), 16)
            self.assertNotIn('liveCursor', summary)
            self.assertNotIn('historyCursor', summary)
            summaries.append(summary)
            client.sendall(frame({'kind': 'ack', 'id': 'ack', 'requestID': summary['id']}))
        self.assertEqual(summaries[0]['revision'], summaries[1]['revision'])
        self.assertEqual(summaries[0]['records'], summaries[1]['records'])

    def test_escaped_hook_overflow_invalidates_preview_without_disconnect(self):
        path = self.transcript(count=1)
        self.service(lease=15000)
        client, _ = self.client(); thread = self.resolve(client, path)
        _, _, boot = self.page(client, thread)
        client.sendall(frame({'kind': 'subscribe', 'id': 'sub', 'thread': thread,
                             'interest': 'fast', 'liveCursor': boot['liveCursor']}))
        self.assertEqual(receive(client)['kind'], 'subscribed')
        self.hook(delta='\t' * 12000)
        preview = receive(client)
        self.assertEqual(preview['event']['hook_event_name'], 'TesseraHookOverflow')
        client.sendall(frame({'kind': 'heartbeat', 'id': 'survived'}))
        self.assertEqual(receive(client)['id'], 'survived')
        _, changes, current = self.page(client, thread, 'updates', boot['liveCursor'])
        self.assertEqual(changes, [])
        self.assertEqual(current['liveCursor'], boot['liveCursor'])

    def test_scoped_relays_share_only_matching_provider_roots(self):
        relays, owned = [], {}
        (self.root / 'codex-0').mkdir()
        alias = self.root / 'codex-alias'; alias.symlink_to(self.root / 'codex-0', target_is_directory=True)
        try:
            for index, group in enumerate((0, 0, 1)):
                environment = dict(os.environ, CODEX_HOME=str(alias if index == 1 else self.root / f'codex-{group}'),
                                   CLAUDE_CONFIG_DIR=str(self.root / 'claude'))
                process = subprocess.Popen([BINARY, 'connect', '--stdio', '--runtime-base', str(self.runtime)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, env=environment)
                self.processes.append(process); relays.append(process)
            hellos = []
            for process in relays:
                process.stdin.write(frame({'kind': 'hello', 'v': 3, 'id': 'hello'}))
                hello = receive(process.stdout, timeout=5); hellos.append(hello)
                owned[hello['servicePID']] = hello['serviceEpoch']
            self.assertEqual(hellos[0]['serviceEpoch'], hellos[1]['serviceEpoch'])
            self.assertNotEqual(hellos[0]['serviceEpoch'], hellos[2]['serviceEpoch'])
            self.assertEqual(len(list(self.runtime.glob('*/scope'))), 2)
            relays[0].stdin.close(); relays[0].wait(timeout=3)
            relays[1].stdin.write(frame({'kind': 'heartbeat', 'id': 'survived'}))
            self.assertEqual(receive(relays[1].stdout)['id'], 'survived')
        finally:
            for process in relays:
                if not process.stdin.closed: process.stdin.close()
                if process.poll() is None: process.wait(timeout=3)
            for pid in owned:
                command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout.strip()
                expected = f'{BINARY} serve --runtime {self.runtime}/'
                if command.startswith(expected) and len(command[len(expected):]) == 16:
                    os.kill(pid, signal.SIGTERM)
            deadline = time.monotonic() + 3
            while list(self.runtime.glob('*/client.sock')) and time.monotonic() < deadline: time.sleep(.02)
            self.assertFalse(list(self.runtime.glob('*/client.sock')))

    def context_process(self, environment, code='import time; print("ready", flush=True); time.sleep(60)'):
        process = subprocess.Popen([sys.executable, '-c', code], env=environment,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        self.assertTrue(select.select([process.stdout], [], [], 3)[0])
        self.assertEqual(process.stdout.readline(), b'ready\n')
        return process

    def context_relay(self, environment, hello):
        process = subprocess.Popen([BINARY, 'connect', '--stdio', '--runtime-base', str(self.runtime),
            '--context-from-hello'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, bufsize=0, env=environment)
        self.processes.append(process)
        process.stdin.write(frame(hello))
        return process

    def stop_context_services(self, relays, owned):
        for process in relays:
            if not process.stdin.closed: process.stdin.close()
            if process.poll() is None: process.wait(timeout=3)
        for pid in owned:
            command = subprocess.run(['ps', '-p', str(pid), '-o', 'command='], capture_output=True, text=True).stdout.strip()
            expected = f'{BINARY} serve --runtime {self.runtime}/'
            if command.startswith(expected) and len(command[len(expected):]) == 16:
                os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 3
        while list(self.runtime.glob('*/client.sock')) and time.monotonic() < deadline: time.sleep(.02)
        self.assertFalse(list(self.runtime.glob('*/client.sock')))

    def test_process_context_selects_owned_roots_reuses_service_and_survives_exit(self):
        # Entirely synthetic children/roots. No user's process environment or
        # provider transcript is inspected, and target PATH is never adopted.
        path = self.transcript(count=2)
        selected = dict(os.environ, CODEX_HOME=str(self.root / 'codex'),
                        CLAUDE_CONFIG_DIR=str(self.root / 'claude'), PI_CODING_AGENT_DIR=str(self.root / 'pi-selected'),
                        PATH='/not-a-provider-path')
        alias = self.root / 'claude-alias'; alias.symlink_to(self.root / 'claude', target_is_directory=True)
        targets = [self.context_process(selected), self.context_process(dict(selected, CLAUDE_CONFIG_DIR=str(alias)))]
        carrier = dict(os.environ, CODEX_HOME=str(self.root / 'carrier-codex'),
                       CLAUDE_CONFIG_DIR=str(self.root / 'carrier-claude'), PI_CODING_AGENT_DIR=str(self.root / 'carrier-pi'))
        relays, owned, hellos = [], set(), []
        try:
            for index, pid in enumerate([targets[0].pid, targets[1].pid, None]):
                hello = dict(kind='hello', id='hello', v=3)
                if pid is not None: hello['contextPID'] = pid
                # A valid PID context must supersede even invalid inherited roots.
                environment = dict(carrier, CODEX_HOME='relative-invalid') if index == 0 else carrier
                process = self.context_relay(environment, hello); relays.append(process)
                # Already queued after hello: no read-ahead loss or duplicate hello.
                process.stdin.write(frame(dict(kind='heartbeat', id='after_hello')))
                response = receive(process.stdout, timeout=5); hellos.append(response)
                owned.add(response['servicePID'])
                self.assertEqual(receive(process.stdout)['id'], 'after_hello')
            self.assertEqual(hellos[0]['serviceEpoch'], hellos[1]['serviceEpoch'])
            self.assertNotEqual(hellos[0]['serviceEpoch'], hellos[2]['serviceEpoch'])
            self.assertEqual(len(list(self.runtime.glob('*/scope'))), 2)
            for target in targets: target.terminate(); target.wait(timeout=3)
            token = hellos[0]['contextScope']
            self.assertRegex(token, r'^[0-9a-f]{16}$')
            # A new connection after backgrounding needs no live provider PID,
            # only a host-issued lookup under the authenticated private base.
            reconnected = self.context_relay(dict(carrier, CODEX_HOME='relative-invalid'),
                dict(kind='hello', id='hello', v=3, contextScope=token))
            relays.append(reconnected)
            resumed = receive(reconnected.stdout, timeout=5)
            owned.add(resumed['servicePID'])
            self.assertEqual(resumed['serviceEpoch'], hellos[0]['serviceEpoch'])
            self.assertEqual(resumed['contextScope'], token)
            # Existing context does not need the exited provider for history.
            relays[0].stdin.write(frame(dict(kind='resolve', id='resolve', provider='claude',
                transcriptRef=base64.urlsafe_b64encode(str(path).encode()).decode().rstrip('='))))
            self.assertEqual(receive(relays[0].stdout)['kind'], 'resolved')
            relays[0].stdin.close(); relays[0].wait(timeout=3)
            relays[1].stdin.write(frame(dict(kind='heartbeat', id='sibling_alive')))
            self.assertEqual(receive(relays[1].stdout)['id'], 'sibling_alive')
            self.stop_context_services(relays, owned); relays.clear(); owned.clear()
            restarted = self.context_relay(carrier, dict(kind='hello', id='hello', v=3, contextScope=token))
            relays.append(restarted)
            fresh = receive(restarted.stdout, timeout=5); owned.add(fresh['servicePID'])
            self.assertEqual(fresh['contextScope'], token)
            self.assertNotEqual(fresh['serviceEpoch'], hellos[0]['serviceEpoch'])
            witness = self.runtime / token / 'scope'
            # The owner decides the witness's mode; only its contents and
            # ownership gate a hello.
            witness.chmod(0o664)
            shared = self.context_relay(carrier, dict(kind='hello', id='hello', v=3, contextScope=token))
            relays.append(shared)
            accepted = receive(shared.stdout, timeout=5); owned.add(accepted['servicePID'])
            self.assertEqual(accepted['contextScope'], token)
            witness.chmod(0o600)
            original = witness.read_bytes()
            witness.write_bytes(original.replace(b'uid=', b'uid=9', 1))
            rejected = self.context_relay(carrier, dict(kind='hello', id='hello', v=3, contextScope=token))
            rejected.stdin.close(); self.assertEqual(rejected.wait(timeout=3), 77)
            witness.write_bytes(original)
            self.stop_context_services(relays, owned); relays.clear(); owned.clear()
            # A concurrent attach holds the existing witness briefly. Service
            # startup must wait, not permanently advertise an empty token.
            with witness.open('rb') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                waiting = subprocess.Popen([BINARY, 'serve', '--runtime', str(witness.parent)],
                    env=selected, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                self.processes.append(waiting); owned.add(waiting.pid)
                time.sleep(.15)
                self.assertIsNone(waiting.poll())
                self.assertFalse((witness.parent / 'client.sock').exists())
                fcntl.flock(lock, fcntl.LOCK_UN)
            deadline = time.monotonic() + 3
            while not (witness.parent / 'client.sock').exists():
                self.assertIsNone(waiting.poll()); self.assertLess(time.monotonic(), deadline); time.sleep(.01)
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.connections.append(client); client.connect(str(witness.parent / 'client.sock'))
            client.sendall(frame(dict(kind='hello', id='hello', v=3)))
            self.assertEqual(receive(client)['contextScope'], token)
        finally:
            self.stop_context_services(relays, owned)

    def test_context_hello_rejects_invalid_and_dead_process_before_service_start(self):
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'), CLAUDE_CONFIG_DIR=str(self.root / 'claude'))
        dead = self.context_process(environment); dead.terminate(); dead.wait(timeout=3)
        for pid in [0, 1, -1, 2**31, 2.5, '42', None, dead.pid]:
            with self.subTest(pid=pid):
                process = self.context_relay(environment, dict(kind='hello', id='hello', v=3, contextPID=pid))
                process.stdin.close(); self.assertEqual(process.wait(timeout=3), 77)
                self.assertEqual(process.stdout.read(), b'')
        for body in [b'{"kind":"hello","v":3,"id":"hello","contextPID":2,"contextPID":3}',
                     b'{"kind":"hello","v":3,"id":"hello","contextScope":"../escape"}',
                     b'{"kind":"hello","v":3,"id":"hello","contextScope":"0000000000000000"}',
                     b'{"kind":"hello","v":3,"id":"hello","contextScope":"0000000000000000","contextPID":2}',
                     b'{"kind":"hello","v":3,"id":"bad id"}', b'{"kind":"hello","v":3}',
                     b'{"kind":"hello","v":"3","id":"hello"}', b'{}', b'x' * 8193]:
            process = subprocess.Popen([BINARY, 'connect', '--stdio', '--runtime-base', str(self.runtime),
                '--context-from-hello'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
            self.processes.append(process)
            output, _ = process.communicate(struct.pack('!I', len(body)) + body, timeout=3)
            self.assertEqual(process.returncode, 77); self.assertEqual(output, b'')
        self.assertFalse(list(self.runtime.glob('*/scope')))

    def test_context_partial_hello_times_out_without_starting_service(self):
        process = subprocess.Popen([BINARY, 'connect', '--stdio', '--runtime-base', str(self.runtime),
            '--context-from-hello'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        process.stdin.write(b'\x00\x00'); process.stdin.flush()
        started = time.monotonic()
        self.assertEqual(process.wait(timeout=7), 77)
        self.assertLess(time.monotonic() - started, 6.5)
        self.assertFalse(list(self.runtime.glob('*/scope')))

    @unittest.skipUnless(sys.platform.startswith('linux') and os.geteuid() == 0, 'Linux owned chroot requires root fixture')
    def test_context_rejects_same_uid_foreign_filesystem_root(self):
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'), CLAUDE_CONFIG_DIR=str(self.root / 'claude'))
        target = self.context_process(environment, 'import os, time; os.chroot(' + repr(str(self.root)) +
            '); print("ready", flush=True); time.sleep(60)')
        relay = self.context_relay(environment, dict(kind='hello', id='hello', v=3, contextPID=target.pid))
        relay.stdin.close(); self.assertEqual(relay.wait(timeout=3), 77)
        self.assertEqual(relay.stdout.read(), b'')
        self.assertFalse(list(self.runtime.glob('*/scope')))

    @unittest.skipUnless(sys.platform.startswith('linux') and os.geteuid() == 0, 'Linux owned UID transition requires root fixture')
    def test_context_rejects_foreign_uid_before_environment_capture(self):
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'), CLAUDE_CONFIG_DIR=str(self.root / 'claude'))
        target = self.context_process(environment, 'import os, time; os.setuid(65534); print("ready", flush=True); time.sleep(60)')
        relay = self.context_relay(environment, dict(kind='hello', id='hello', v=3, contextPID=target.pid))
        relay.stdin.close(); self.assertEqual(relay.wait(timeout=3), 77)
        self.assertEqual(relay.stdout.read(), b'')
        self.assertFalse(list(self.runtime.glob('*/scope')))

    def test_root_alias_resolves_same_handle_without_authorizing_leaf_symlinks(self):
        path = self.transcript(count=2); self.service(lease=30000)
        client, _ = self.client()
        alias = self.root / 'claude-alias'; alias.symlink_to(self.root / 'claude', target_is_directory=True)
        through_alias = alias / 'projects/project' / path.name
        self.assertEqual(self.resolve(client, path), self.resolve(client, through_alias))
        leaf = path.parent / 'leaf.jsonl'; leaf.symlink_to(path)
        client.sendall(frame({'kind': 'resolve', 'id': 'leaf', 'provider': 'claude', 'transcriptRef': str(leaf)}))
        self.assertEqual(receive(client)['kind'], 'error')

    def test_deferred_codex_spawn_uses_frozen_scope_not_retargeted_alias(self):
        first = self.root / 'first-root'; first.mkdir()
        second = self.root / 'second-root'; second.mkdir()
        alias = self.root / 'provider-alias'; alias.symlink_to(first, target_is_directory=True)
        executable = self.root / 'bin/codex'; executable.parent.mkdir()
        executable.write_text('''#!/usr/bin/env python3
import json, os, sys
assert os.environ['CODEX_HOME'] == os.environ['EXPECTED_PROVIDER_HOME']
if '--version' in sys.argv:
    print('codex-cli 0.154.0'); raise SystemExit(0)
for raw in sys.stdin:
    request = json.loads(raw); method = request['method']
    if method == 'initialized': continue
    if method == 'initialize': result = {}
    elif method == 'thread/read':
        result = {'thread': {'id': request['params']['threadId'], 'turns': [], 'name': 'Frozen scope', 'updatedAt': 1}}
    elif method == 'thread/items/list':
        result = {'data': [{'turnId': 'turn', 'item': {'type': 'agentMessage', 'id': 'item', 'text': 'Correct scope'}}],
                  'nextCursor': None, 'backwardsCursor': 'cursor'}
    else: raise SystemExit(3)
    print(json.dumps({'id': request['id'], 'result': result}), flush=True)
'''); executable.chmod(0o700)
        native_mock(executable)
        self.service(lease=30000, extra_environment={'CODEX_HOME': str(alias),
            'EXPECTED_PROVIDER_HOME': str(first), 'PATH': str(executable.parent) + os.pathsep + os.environ['PATH']})
        client, _ = self.client()
        alias.unlink(); alias.symlink_to(second, target_is_directory=True)
        client.sendall(frame({'kind': 'resolve', 'id': 'native', 'provider': 'codex',
                             'nativeSessionID': '00000000-0000-0000-0000-000000000002'}))
        reply = receive(client); self.assertEqual(reply['kind'], 'resolved', reply)
        _, records, _ = self.page(client, reply['thread'])
        self.assertEqual(records[0]['record']['blocks'][0]['text'], 'Correct scope')

    def test_scoped_hook_does_not_create_runtime_or_service(self):
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'absent'), CLAUDE_CONFIG_DIR=str(self.root / 'claude'))
        result = subprocess.run([BINARY, 'hook', '--runtime-base', str(self.runtime)],
            input=b'{}', capture_output=True, timeout=1, env=environment)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b'', b''))
        self.assertFalse(self.runtime.exists())

    def test_interest_change_preserves_unacknowledged_canonical_cursor(self):
        path = self.transcript(count=2)
        self.service(lease=15000)
        client, _ = self.client(); thread = self.resolve(client, path)
        _, _, boot = self.page(client, thread)
        client.sendall(frame({'kind': 'subscribe', 'id': 'fast', 'thread': thread, 'interest': 'fast', 'liveCursor': boot['liveCursor']}))
        self.assertEqual(receive(client)['kind'], 'subscribed')
        with path.open('a') as stream: stream.write('{"type":"user","uuid":"first","parentUuid":"synthetic-1","message":{"role":"user","content":"first"}}\n')
        _, first, pending = self.read_page(client)
        self.assertEqual(len(first), 1)
        client.sendall(frame({'kind': 'subscribe', 'id': 'slow', 'thread': thread, 'interest': 'slow'}))
        self.assertEqual(receive(client)['kind'], 'subscribed')
        client.sendall(frame({'kind': 'ack', 'id': 'ack', 'requestID': pending['id']}))
        summary = receive(client)
        self.assertEqual(summary['kind'], 'summary')
        client.sendall(frame({'kind': 'ack', 'id': 'ack', 'requestID': summary['id']}))
        # Deliberately stale client capture. Changing interest is not rewind.
        client.sendall(frame({'kind': 'subscribe', 'id': 'fast-again', 'thread': thread,
                             'interest': 'fast', 'liveCursor': boot['liveCursor']}))
        self.assertEqual(receive(client)['kind'], 'subscribed')
        with path.open('a') as stream: stream.write('{"type":"user","uuid":"second","parentUuid":"first","message":{"role":"user","content":"second"}}\n')
        _, second, _ = self.read_page(client)
        self.assertEqual(len(second), 1)
        self.assertEqual(second[0]['record']['blocks'][0]['text'], 'second')

    def test_native_inventory_paginates_all_sources(self):
        for n in range(105): self.transcript(f'00000000-0000-0000-0000-{n:012x}', 1)
        self.service(lease=10000)
        client, _ = self.client(); cursor = None; sources = []
        while True:
            request = {'kind': 'inventory', 'id': 'inventory'}
            if cursor: request['cursor'] = cursor
            client.sendall(frame(request))
            self.assertEqual(receive(client)['kind'], 'inventory.begin')
            while True:
                value = receive(client)
                if value['kind'] == 'inventory.end': break
                sources.append(value['thread'])
            if not value['hasMore']: break
            cursor = value['cursor']
        self.assertEqual(len(set(sources)), 105)

    def test_inventory_requested_limit_is_bounded_and_byte_capped(self):
        for n in range(505): self.transcript(f'00000000-0000-0000-0000-{n:012x}', 1)
        self.service(lease=20000)
        client, _ = self.client()
        for limit in (0, -1, 501, 1.5, '500', True):
            client.sendall(frame(dict(kind='inventory', id='bad_limit', limit=limit)))
            self.assertEqual(receive(client)['code'], 'invalidRequest')
        cursor = None; sources = []; page_sizes = []
        while True:
            client.sendall(frame(dict(kind='inventory', id='inventory', limit=500,
                                     **({'cursor': cursor} if cursor else {}))))
            rows = []; encoded_bytes = 0
            while True:
                value = receive(client)
                self.assertNotEqual(value['kind'], 'error', value)
                # The producer uses compact UTF-8 JSON plus four-byte framing.
                encoded_bytes += len(json.dumps(value, separators=(',', ':'), ensure_ascii=False).encode()) + 4
                if value['kind'] == 'inventory.thread': rows.append(value['thread'])
                if value['kind'] == 'inventory.end': break
            self.assertLessEqual(encoded_bytes, 192 * 1024)
            self.assertLessEqual(len(rows), 500)
            self.assertGreater(len(rows), 0)
            sources.extend(rows); page_sizes.append(len(rows))
            if not value['hasMore']: break
            cursor = value['cursor']
        self.assertEqual(len(sources), 505)
        self.assertEqual(len(set(sources)), 505)
        self.assertGreater(page_sizes[0], 100, 'larger pages must actually reduce round trips')
        self.assertLess(len(page_sizes), 6)

    def test_inventory_long_paths_shorten_pages_without_losing_cursor_rows(self):
        # A valid control character in a private fixture directory expands to
        # six JSON bytes. This stresses encoded bytes rather than row count.
        project = self.root / 'claude/projects' / ('\x01' * 120)
        project.mkdir(parents=True)
        for n in range(240):
            path = self.transcript(f'00000000-0000-0000-0000-{n:012x}', 1)
            path.rename(project / path.name)
        self.service(lease=20000)
        client, _ = self.client(); cursor = None; sources = []; page_sizes = []
        while True:
            client.sendall(frame(dict(kind='inventory', id='long_paths', limit=500,
                                     **({'cursor': cursor} if cursor else {}))))
            rows = []; encoded_bytes = 0
            while True:
                value = receive(client)
                self.assertNotEqual(value['kind'], 'error', value)
                encoded_bytes += len(json.dumps(value, separators=(',', ':'), ensure_ascii=False).encode()) + 4
                if value['kind'] == 'inventory.thread': rows.append(value['thread'])
                if value['kind'] == 'inventory.end': break
            self.assertLessEqual(encoded_bytes, 192 * 1024)
            self.assertGreater(len(rows), 0)
            sources.extend(rows); page_sizes.append(len(rows))
            if not value['hasMore']: break
            cursor = value['cursor']
        self.assertEqual(len(sources), 240)
        self.assertEqual(len(set(sources)), 240)
        self.assertGreater(len(page_sizes), 1, 'escaped paths must trigger the byte cap before the row cap')

    def test_native_inventory_cursor_survives_another_clients_inventory(self):
        for n in range(105): self.transcript(f'00000000-0000-0000-0000-{n:012x}', 1)
        self.service(lease=10000)
        first, _ = self.client(); second, _ = self.client()
        def inventory(client, cursor=None):
            client.sendall(frame({'kind': 'inventory', 'id': 'inventory', **({'cursor': cursor} if cursor else {})}))
            rows = []
            while True:
                item = receive(client)
                self.assertNotEqual(item['kind'], 'error', item)
                rows.append(item)
                if item['kind'] == 'inventory.end': return rows
        a = inventory(first); b = inventory(second)
        for client, rows in [(first, a), (second, b)]:
            remaining = inventory(client, rows[-1]['cursor'])
            self.assertEqual(sum(item['kind'] == 'inventory.thread' for item in remaining), 5)

    def test_canonical_subscription_receives_only_its_claude_display_overlay(self):
        path = self.transcript(count=1)
        self.service(lease=20000)
        client, _ = self.client(); thread = self.resolve(client, path)
        _, _, boot = self.page(client, thread)
        client.sendall(frame({'kind': 'subscribe', 'id': 'sub', 'thread': thread, 'interest': 'fast', 'liveCursor': boot['liveCursor']}))
        self.assertEqual(receive(client)['kind'], 'subscribed')
        self.hook(session='unrelated')
        self.assertFalse(select.select([client], [], [], .15)[0])
        self.hook(transcript_path='/not-an-authority/private.jsonl')
        preview = receive(client)
        self.assertEqual(preview['kind'], 'hookPreview')
        self.assertEqual(preview['thread'], thread)
        self.assertEqual(preview['event']['delta'], 'synthetic')
        self.assertNotIn('transcript_path', preview['event'])
        # Hooks neither advance canonical checkpoints nor create records.
        _, records, fresh = self.page(client, thread, 'updates', boot['liveCursor'])
        self.assertEqual(records, [])
        self.assertEqual(fresh['liveCursor'], boot['liveCursor'])

    def test_two_clients_share_epoch_and_receive_independently(self):
        service = self.service()
        first, a = self.client('synthetic')
        second, b = self.client('synthetic')
        self.assertEqual(a['serviceEpoch'], b['serviceEpoch'])
        self.hook()
        for client in (first, second):
            event = receive(client)
            self.assertEqual(event['kind'], 'hookPreview')
            self.assertEqual(event['event']['delta'], 'synthetic')
        first.close()
        self.hook(index=1)
        self.assertEqual(receive(second)['event']['index'], 1)
        self.assertIsNone(service.poll())

    def test_subscriptions_are_connection_scoped(self):
        self.service()
        first, _ = self.client('synthetic')
        second, _ = self.client('different')
        first.sendall(frame({'kind': 'unsubscribe', 'id': 'off'}))
        self.assertEqual(receive(first)['kind'], 'ack')
        self.hook(session='different')
        self.assertEqual(receive(second)['kind'], 'hookPreview')
        self.assertFalse(select.select([first], [], [], .1)[0])

    def test_slow_interest_coalesces_without_affecting_fast(self):
        self.service()
        slow, _ = self.client('synthetic', 'slow')
        fast, _ = self.client('synthetic')
        self.hook()
        self.assertEqual(receive(slow)['kind'], 'summaryInvalidated')
        self.assertEqual(receive(fast)['kind'], 'hookPreview')
        self.hook(index=1)
        self.assertEqual(receive(fast)['event']['index'], 1)
        self.assertFalse(select.select([slow], [], [], .1)[0])

    def test_hooks_do_not_keep_service_alive(self):
        service = self.service(idle=250)
        for _ in range(8):
            self.hook()
            time.sleep(.05)
        self.assertEqual(service.wait(timeout=1), 0)
        self.assertFalse((self.runtime / 'hooks.sock').exists())

    def test_expired_client_does_not_expire_other_client(self):
        service = self.service(idle=200, lease=300)
        expired, _ = self.client('synthetic')
        active, _ = self.client('synthetic')
        for n in range(5):
            time.sleep(.1)
            active.sendall(frame({'kind': 'heartbeat', 'id': f'beat{n}'}))
            self.assertEqual(receive(active)['kind'], 'ack')
        with self.assertRaises(EOFError):
            receive(expired)
        self.assertIsNone(service.poll())
        active.close()
        self.assertEqual(service.wait(timeout=2), 0)

    def test_singleton_lock_rejects_second_server(self):
        first = self.service()
        result = subprocess.run([BINARY, 'serve', '--runtime', str(self.runtime)],
                                capture_output=True, timeout=2)
        self.assertEqual(result.returncode, 75)
        self.assertIsNone(first.poll())
        self.client()

    def test_shared_runtime_directory_still_serves_the_owner(self):
        # A umask 0002 host creates the runtime directory group-writable. The
        # owner decides its mode; ownership and the symlink walk are the gate.
        self.runtime.mkdir(); self.runtime.chmod(0o775)
        service = self.service()
        self.assertIsNone(service.poll())
        self.client()

    def test_symlink_lock_fails_closed(self):
        self.runtime.mkdir(mode=0o700)
        target = self.root / 'preserved'
        target.write_text('preserved')
        (self.runtime / 'service.lock').symlink_to(target)
        result = subprocess.run([BINARY, 'serve', '--runtime', str(self.runtime)], capture_output=True, timeout=2)
        self.assertEqual(result.returncode, 77)
        self.assertEqual(target.read_text(), 'preserved')

    def test_unsupported_version_does_not_replace_service(self):
        service = self.service()
        good, hello = self.client()
        bad = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.connections.append(bad)
        bad.connect(str(self.runtime / 'client.sock'))
        bad.sendall(frame({'kind': 'hello', 'v': 1, 'id': 'hello'}))
        with self.assertRaises(EOFError):
            receive(bad)
        good.sendall(frame({'kind': 'heartbeat', 'id': 'beat'}))
        self.assertEqual(receive(good)['serviceEpoch'], hello['serviceEpoch'])
        self.assertIsNone(service.poll())

    def test_hook_overflow_is_explicit_resync(self):
        self.service()
        client, _ = self.client('synthetic')
        self.hook(delta='x' * 65536)
        value = receive(client)
        self.assertEqual((value['kind'], value['reason']), ('resyncRequired', 'hookOverflow'))

    def test_fragmented_frame_is_applied_only_when_complete(self):
        self.service()
        client, _ = self.client()
        data = frame({'kind': 'heartbeat', 'id': 'fragmented'})
        client.sendall(data[:-1])
        self.assertFalse(select.select([client], [], [], .1)[0])
        client.sendall(data[-1:])
        self.assertEqual(receive(client)['id'], 'fragmented')

    def test_malformed_and_oversized_frames_are_isolated(self):
        self.service()
        good, _ = self.client('synthetic')
        for payload in (struct.pack('!I', 65537), struct.pack('!I', 1) + b'{'):
            bad, _ = self.client()
            bad.sendall(payload)
            with self.assertRaises(EOFError):
                receive(bad)
        self.hook()
        self.assertEqual(receive(good)['kind'], 'hookPreview')

    def test_stale_socket_recovers_but_regular_file_is_not_removed(self):
        self.runtime.mkdir(mode=0o700)
        socket_path = self.runtime / 'client.sock'
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
            stale.bind(str(socket_path))
            socket_path.chmod(0o600)
        service = self.service()
        self.client()
        service.terminate()
        service.wait(timeout=2)
        socket_path.write_text('do not remove')
        result = subprocess.run([BINARY, 'serve', '--runtime', str(self.runtime)], capture_output=True, timeout=2)
        self.assertEqual(result.returncode, 77)
        self.assertEqual(socket_path.read_text(), 'do not remove')

    def test_duplex_relay_reuses_service_without_closing_stdin(self):
        self.service()
        relays = []
        for _ in range(2):
            process = subprocess.Popen([BINARY, 'connect', '--stdio', '--runtime', str(self.runtime)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            self.processes.append(process)
            relays.append(process)
        epochs = []
        for process in relays:
            process.stdin.write(frame({'kind': 'hello', 'v': 3, 'id': 'hello'}))
            epochs.append(receive(process.stdout)['serviceEpoch'])
            process.stdin.write(frame({'kind': 'subscribe', 'id': 'sub', 'session_id': 'synthetic', 'interest': 'fast'}))
            self.assertEqual(receive(process.stdout)['kind'], 'subscribed')
        self.assertEqual(epochs[0], epochs[1])
        self.hook()
        for process in relays:
            self.assertEqual(receive(process.stdout)['kind'], 'hookPreview')
        relays[0].stdin.close()
        self.assertEqual(relays[0].wait(timeout=2), 0)
        self.hook(index=1)
        self.assertEqual(receive(relays[1].stdout)['event']['index'], 1)

    def test_batched_requests_make_progress_without_more_input(self):
        self.service()
        connection, _ = self.client()
        connection.sendall(b''.join(frame({'kind': 'heartbeat', 'id': f'request{n}'}) for n in range(20)))
        for n in range(20):
            self.assertEqual(receive(connection)['id'], f'request{n}')

    def test_half_close_drains_batched_requests_and_replies(self):
        self.service()
        connection, _ = self.client()
        connection.sendall(b''.join(frame({'kind': 'heartbeat', 'id': f'request{n}'}) for n in range(20)))
        connection.shutdown(socket.SHUT_WR)
        for n in range(20):
            self.assertEqual(receive(connection)['id'], f'request{n}')
        with self.assertRaises(EOFError):
            receive(connection)

    def test_stalled_consumer_does_not_stall_other_client(self):
        self.service(lease=15000)
        stalled, _ = self.client('synthetic')
        healthy, _ = self.client('synthetic')
        for index in range(100):
            self.hook(index=index, delta='x' * 32000)
            self.assertEqual(receive(healthy)['event']['index'], index)
        received = 0
        try:
            while received < 100:
                receive(stalled)
                received += 1
        except EOFError:
            pass
        self.assertLess(received, 100, 'stalled consumer should be disconnected at its queue limit')
        self.hook(index=100)
        self.assertEqual(receive(healthy)['event']['index'], 100)

    def test_context_relay_short_idle_shutdown_needs_no_pid_signal(self):
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'), CLAUDE_CONFIG_DIR=str(self.root / 'claude'))
        process = subprocess.Popen([BINARY, 'connect', '--stdio', '--runtime-base', str(self.runtime),
            '--context-from-hello', '--idle-ms', '100'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, bufsize=0)
        self.processes.append(process)
        try:
            process.stdin.write(frame(dict(kind='hello', id='hello', v=3)))
            hello = receive(process.stdout, timeout=5)
            self.assertRegex(hello['contextScope'], '^[0-9a-f]{16}$')
        finally:
            process.stdin.close()
            self.assertEqual(process.wait(timeout=12), 0)
            deadline = time.monotonic() + 5
            while list(self.runtime.glob('*/client.sock')) and time.monotonic() < deadline: time.sleep(.02)
            self.assertFalse(list(self.runtime.glob('*/client.sock')))

    def test_context_relay_rejects_invalid_idle_before_startup(self):
        for value in ('0', '99', '30001', '100x', ''):
            result = subprocess.run([BINARY, 'connect', '--stdio', '--runtime-base', str(self.runtime),
                '--context-from-hello', '--idle-ms', value], capture_output=True, timeout=2)
            self.assertEqual(result.returncode, 64)
        self.assertFalse(self.runtime.exists())

    def test_simultaneous_cold_relays_start_one_detached_service(self):
        relays = []
        owned_pid = None
        try:
            for _ in range(3):
                process = subprocess.Popen([BINARY, 'connect', '--stdio', '--runtime', str(self.runtime)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
                self.processes.append(process)
                relays.append(process)
            hellos = []
            for process in relays:
                process.stdin.write(frame({'kind': 'hello', 'v': 3, 'id': 'hello'}))
                hello = receive(process.stdout, timeout=5)
                owned_pid = hello['servicePID']
                hellos.append(hello)
            self.assertEqual(len({value['serviceEpoch'] for value in hellos}), 1)
            self.assertEqual(len({value['servicePID'] for value in hellos}), 1)
            relays[0].stdin.close()
            relays[0].wait(timeout=3)
            relays[1].stdin.write(frame({'kind': 'heartbeat', 'id': 'survived'}))
            self.assertEqual(receive(relays[1].stdout)['id'], 'survived')
            for process in relays[1:]:
                process.stdin.close()
                process.wait(timeout=3)
            deadline = time.monotonic() + 34
            while (self.runtime / 'client.sock').exists() and time.monotonic() < deadline:
                time.sleep(.1)
            self.assertFalse((self.runtime / 'client.sock').exists(), 'detached service exceeded final idle grace')
        finally:
            for process in relays:
                if process.stdin and not process.stdin.closed:
                    process.stdin.close()
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3)
            # Failure cleanup: exact PID from this private service handshake,
            # revalidated against its unique runtime argv, never a PID alone.
            if owned_pid:
                command = subprocess.run(['ps', '-p', str(owned_pid), '-o', 'command='], capture_output=True, text=True)
                if command.stdout.strip() == f'{BINARY} serve --runtime {self.runtime}':
                    os.kill(owned_pid, signal.SIGTERM)
                    deadline = time.monotonic() + 3
                    while (self.runtime / 'client.sock').exists() and time.monotonic() < deadline:
                        time.sleep(.05)


if __name__ == '__main__':
    unittest.main()
