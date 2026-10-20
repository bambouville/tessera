"""Linux fixture-only sustained capacity gate. Synthetic data, real service/relays.

Usage: python3 test_service_soak.py BINARY [seconds=1800]
The Codex child is a protocol mock, not evidence of real App Server memory.
"""
import json
import fcntl
import hashlib
import os
import platform
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

import test_service as support  # consumes the binary argument


class Relay:
    def __init__(self, fixture):
        self.process = subprocess.Popen(
            [support.BINARY, 'connect', '--stdio', '--runtime', str(fixture.runtime)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        fixture.processes.append(self.process)
        fcntl.fcntl(self.process.stdin, fcntl.F_SETFL, os.O_NONBLOCK)

    def fileno(self):
        return self.process.stdout.fileno()

    def sendall(self, data):
        view = memoryview(data)
        deadline = time.monotonic() + 3
        while view:
            if not select.select([], [self.process.stdin], [], max(0, deadline - time.monotonic()))[1]:
                raise TimeoutError('relay write timeout')
            try:
                count = os.write(self.process.stdin.fileno(), view)
            except BlockingIOError:
                continue
            if not count:
                raise EOFError('relay write failed')
            view = view[count:]

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)
        if self.process.returncode:
            raise RuntimeError('relay failed')


def census(roots):
    """One simultaneous /proc census; only roots and their descendants."""
    rows = {}
    for path in Path('/proc').iterdir():
        if not path.name.isdecimal():
            continue
        try:
            fields = (path / 'stat').read_text().rsplit(')', 1)[1].split()
            rows[int(path.name)] = (int(fields[1]), int(fields[11]) + int(fields[12]),
                                    int(fields[21]) * os.sysconf('SC_PAGE_SIZE'), int(fields[19]),
                                    int(fields[13]) + int(fields[14]))
        except (OSError, ValueError, IndexError):
            continue
    owned = set(roots) & rows.keys()
    while True:
        expanded = owned | {pid for pid, row in rows.items() if row[0] in owned}
        if expanded == owned:
            break
        owned = expanded
    descriptors = 0
    counters = {}
    for pid in owned:
        try:
            descriptors += len(list(Path(f'/proc/{pid}/fd').iterdir()))
            values = {}
            for filename, allowed in (
                ('io', {'rchar', 'wchar', 'syscr', 'syscw', 'read_bytes', 'write_bytes'}),
                ('status', {'voluntary_ctxt_switches', 'nonvoluntary_ctxt_switches'})):
                for line in Path(f'/proc/{pid}/{filename}').read_text().splitlines():
                    key, _, value = line.partition(':')
                    if key in allowed:
                        values[key] = int(value.strip())
            counters[pid] = values
        except FileNotFoundError:
            pass
    return dict(rss=sum(rows[pid][2] for pid in owned),
                serviceRSS=rows.get(roots[0], (0, 0, 0))[2],
                cpuTicks={pid: rows[pid][1] for pid in owned},
                reapedCpuTicks={pid: rows[pid][4] for pid in owned},
                identities={pid: rows[pid][3] for pid in owned},
                counters=counters,
                processes=len(owned), descriptors=descriptors)


def run(seconds):
    fixture = support.ServiceTests()
    fixture.setUp()
    samples = []
    latency = []
    slow_latency = []
    received = 0
    try:
        print(json.dumps(dict(provenance=dict(binarySHA256=hashlib.sha256(Path(support.BINARY).read_bytes()).hexdigest(),
            scriptSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            fixtureSHA256=hashlib.sha256(Path(support.__file__).read_bytes()).hexdigest(),
            platform=platform.platform(), machine=platform.machine(), cpuCount=os.cpu_count(),
            durationSeconds=seconds, sampleIntervalSeconds=5, filesystemCache='warm; synthetic fixtures',
            measurement='sampled simultaneous RSS; stable-identity idle CPU counters'))), flush=True)
        initial, _, native = fixture.native_codex(100)
        initial.close()
        paths = []
        for index in range(27):
            # This lane intentionally exercises the structured Codex child.
            # An invalid session_meta file is no longer a native fallback:
            # malformed canonical authority must fail closed in production.
            session = f'00000000-0000-0000-0000-{index + 100:012d}'
            paths.extend([('codex', session), ('claude', fixture.transcript(f'soak-{index}', 100))])
        service = fixture.processes[0]
        clients = [Relay(fixture), Relay(fixture)]
        epochs = []
        for client in clients:
            client.sendall(support.frame(dict(kind='hello', v=3, id='hello')))
            epochs.append(support.receive(client)['serviceEpoch'])
        assert len(set(epochs)) == 1, 'duplicate service'
        handles = []
        for provider, path in paths:
            if provider == 'codex':
                clients[0].sendall(support.frame(dict(kind='resolve', id='resolve_native', provider=provider, nativeSessionID=path)))
                resolved = support.receive(clients[0])
                assert resolved['kind'] == 'resolved', 'native-only Codex fixture resolve failed'
                handles.append(resolved['thread'])
            else: handles.append(fixture.resolve(clients[0], path, provider))
        fast = set(handles[:4])
        heads = {}
        versions = {}
        cursors = {}
        for number, client in enumerate(clients):
            for thread in handles[:4]:
                _, _, end = fixture.window_page(client, thread, 'bootstrap', 0)
                expected = 'codex-appserver' if paths[handles.index(thread)][0] == 'codex' else 'jsonl'
                assert end['backend'] == expected, 'capacity fixture exercised the wrong provider backend'
                head = end['window']['segmentID']
                fixture.window_ack(client, thread, end, [head], head)
                heads[number, thread] = head
                versions[number, thread] = end['window']['version']
                cursors[number, thread] = end['liveCursor']
        for number, client in enumerate(clients):
            for thread in handles:
                request = dict(kind='subscribe', id='watch_' + thread, thread=thread,
                               interest='fast' if thread in fast else 'slow')
                if thread in fast:
                    request.update(windowVersion=versions[number, thread], liveCursor=cursors[number, thread])
                client.sendall(support.frame(request))
        started = time.monotonic()
        next_write = started + 10
        next_heartbeat = started
        next_sample = started
        pending = {}
        pending_slow = {}
        observed = set()
        transactions = {}
        providers = {thread: paths[index][0] for index, thread in enumerate(handles)}
        sequence = 0
        idle = False
        while time.monotonic() - started < seconds:
            now = time.monotonic()
            if not idle and now - started >= seconds / 2:
                assert not pending and not pending_slow, 'unobserved active update before idle'
                # Close both leased streams to drain their exact pending pages.
                # Reattach to the same still-live service, with only 50 slow cards.
                for client in clients:
                    client.close()
                transactions.clear(); observed.clear()
                clients = [Relay(fixture), Relay(fixture)]
                for client in clients:
                    client.sendall(support.frame(dict(kind='hello', v=3, id='hello')))
                    assert support.receive(client)['serviceEpoch'] == epochs[0]
                    for thread in handles[4:]:
                        client.sendall(support.frame(dict(kind='subscribe', id='watch_' + thread,
                                                         thread=thread, interest='slow')))
                idle = True
            if not idle and now >= next_write and now - started < seconds / 2 - 8:
                assert not pending and not pending_slow, 'update starved under capacity load'
                sequence += 1
                items = json.loads(native.read_text())
                items[-1]['item']['text'] = f'updated {sequence}'
                replacement = native.with_suffix('.pending')
                replacement.write_text(json.dumps(items))
                os.replace(replacement, native)
                marker = Path(str(native) + '.updated')
                marker_pending = Path(str(marker) + '.pending')
                marker_pending.write_text(str(sequence)); os.replace(marker_pending, marker)
                for index, (provider, path) in enumerate(paths):
                    if provider == 'claude':
                        with path.open('a') as stream:
                            stream.write(json.dumps(dict(type='user', uuid=f'append-{index}-{sequence}',
                                parentUuid=f'append-{index}-{sequence - 1}' if sequence > 1 else f'soak-{index // 2}-99',
                                message=dict(role='user', content=f'updated {sequence}'))) + '\n')
                pending = {(number, thread): now for number in range(2) for thread in fast}
                pending_slow = {(number, thread): now for number in range(2) for thread in handles[4:]}
                next_write = now + 17.3  # walk across the five-second poll phase
            if now >= next_heartbeat:
                for client in clients:
                    client.sendall(support.frame(dict(kind='heartbeat', id='lease')))
                next_heartbeat = now + 10
            if now >= next_sample:
                assert service.poll() is None, 'service exited'
                sample = census([service.pid] + [client.process.pid for client in clients])
                sample.update(elapsed=round(now - started, 3), phase='idle' if idle else 'active')
                assert sample['rss'] <= 256 * 1024 * 1024, 'owned process tree exceeded memory guard'
                assert sample['serviceRSS'] <= 64 * 1024 * 1024, 'service exceeded memory target'
                samples.append(sample)
                print(json.dumps(dict(sample=sample)), flush=True)
                next_sample = now + 5
            if pending:
                assert now - min(pending.values()) < 7, 'fast update missing: ' + ','.join(providers[thread] for _, thread in pending)
            if pending_slow:
                assert now - min(pending_slow.values()) < 7, 'slow update missing'
            ready, _, _ = select.select(clients, [], [], .05)
            for client in ready:
                number = clients.index(client)
                value = support.receive(client)
                received += 1
                kind = value['kind']
                assert kind not in ('error', 'resyncRequired'), 'protocol failure: ' + value.get('code', kind)
                if kind == 'summary':
                    key = number, value['thread']
                    matched = value.get('modified') == 2000000000 + sequence or any(
                        block.get('text') == f'updated {sequence}' for record in value.get('records', [])
                        for block in record.get('blocks', []))
                    if matched and key in pending_slow:
                        slow_latency.append(1000 * (time.monotonic() - pending_slow.pop(key)))
                    client.sendall(support.frame(dict(kind='ack', id='summary_ack', requestID=value['id'])))
                elif kind == 'page.record':
                    transaction = transactions[number, value['id']]
                    assert transaction['thread'] == value['thread'], 'cross-thread record'
                    transaction['count'] += 1
                    assert transaction['count'] <= 100, 'page record capacity'
                    thread = value['thread']; index = handles.index(thread)
                    expected_id = 'item-99' if providers[thread] == 'codex' else f'append-{index}-{sequence}'
                    expected_role = 'assistant' if providers[thread] == 'codex' else 'user'
                    identity = value['recordID'] if providers[thread] == 'codex' else value['record'].get('turnID')
                    if identity == expected_id and value['record'].get('role') == expected_role and any(
                            block.get('text') == f'updated {sequence}' for block in value['record'].get('blocks', [])):
                        observed.add((number, value['id']))
                elif kind == 'page.begin':
                    key = number, value['id']
                    assert key not in transactions and value['thread'] in fast, 'unexpected page transaction'
                    transactions[key] = dict(thread=value['thread'], count=0)
                elif kind == 'page.end':
                    transaction = transactions.pop((number, value['id']))
                    assert transaction == dict(thread=value['thread'], count=value['records']), 'incomplete page transaction'
                    key = number, value['thread']
                    if (number, value['id']) in observed and key in pending:
                        latency.append(1000 * (time.monotonic() - pending.pop(key)))
                    observed.discard((number, value['id']))
                    head = value['window'].get('segmentID', heads[key])
                    heads[key] = head
                    client.sendall(support.frame(dict(kind='window.ack', id='commit_' + value['id'],
                        thread=value['thread'], transaction=value['id'], windowVersion=value['window']['version'],
                        viewport=[head], head=head)))
        assert not pending and not pending_slow
        idle_samples = [sample for sample in samples if sample['phase'] == 'idle']
        ticks = 0
        for previous, current in zip(idle_samples, idle_samples[1:]):
            assert previous['identities'] == current['identities'], 'idle process identity churn invalidates CPU samples'
            ticks += sum(max(0, count - previous['cpuTicks'][pid]) for pid, count in current['cpuTicks'].items()
                         if pid in previous['cpuTicks'])
            ticks += sum(max(0, count - previous['reapedCpuTicks'][pid]) for pid, count in current['reapedCpuTicks'].items()
                         if pid in previous['reapedCpuTicks'])
        elapsed = idle_samples[-1]['elapsed'] - idle_samples[0]['elapsed']
        cpu = 100 * ticks / os.sysconf('SC_CLK_TCK') / elapsed
        ordered = sorted(latency)
        p95 = ordered[max(0, (95 * len(ordered) + 99) // 100 - 1)]
        print(json.dumps(dict(measurements=dict(fastP95MS=p95, idleCPUPercent=cpu,
            fastLatencyMS=latency, slowLatencyMS=slow_latency,
            peakSimultaneousRSS=max(sample['rss'] for sample in samples),
            peakServiceRSS=max(sample['serviceRSS'] for sample in samples)))), flush=True)
        failures = [message for passed, message in (
            (p95 <= 1000, 'fast p95 exceeded target'),
            (bool(slow_latency) and max(slow_latency) <= 7000, 'slow freshness exceeded target'),
            (cpu <= 1, 'idle CPU exceeded target'),
            (idle_samples[-1]['descriptors'] <= idle_samples[0]['descriptors'] + 2, 'descriptor growth'),
            (idle_samples[-1]['processes'] == idle_samples[0]['processes'], 'process growth')) if not passed]
        print(json.dumps(dict(gateFailures=failures)), flush=True)
        assert not failures, '; '.join(failures)
        print(json.dumps(dict(status='passed_scoped_checks', durationSeconds=seconds, updates=sequence,
            frames=received, fastSamples=len(latency), fastP95MS=p95, idleCPUPercent=cpu,
            fastLatencyMS=latency, slowLatencyMS=slow_latency,
            peakSimultaneousRSS=max(sample['rss'] for sample in samples),
            peakServiceRSS=max(sample['serviceRSS'] for sample in samples),
            codexChild='synthetic protocol mock', network='local stdio relays on disposable Linux fixture',
            scope='two clients; 4 fast plus 50 slow active; reconnect; 50 slow idle')), flush=True)
    finally:
        owned = {pid: identity for sample in samples for pid, identity in sample['identities'].items()}
        try:
            if fixture.processes:
                owned.update(census([process.pid for process in fixture.processes])['identities'])
        finally:
            fixture.tearDown()
        for pid, identity in owned.items():
            try:
                fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            except FileNotFoundError:
                continue
            assert int(fields[19]) != identity, 'run-owned process leaked after cleanup'
        print(json.dumps(dict(cleanup='all sampled run-owned process identities exited; fixture directory removed')), flush=True)


if __name__ == '__main__':
    duration = int(sys.argv[1]) if len(sys.argv) > 1 else 1800
    if not 40 <= duration <= 7200 or not Path('/proc/self/stat').is_file():
        raise SystemExit('requires Linux fixture and duration 40..7200 seconds')
    def interrupted(signum, _):
        raise KeyboardInterrupt(signum)
    signal.signal(signal.SIGTERM, interrupted)
    run(duration)
