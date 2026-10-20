#!/usr/bin/env python3
"""Cold helper -> real iOS transcript display on finite private corpus snapshots.

Protected Unix streams with controlled one-way delay; optional owned loopback
SSH and launch-inclusive DEBUG app startup. No provider-session control.
Display-link ticks are a candidate; compositor capture is a visibility upper
bound, subject to original-pixel review, not an exact first-paint timestamp.
"""
import argparse
import asyncio
import base64
import hashlib
import json
import importlib.util
import math
import os
from pathlib import Path
import signal
import shutil
import subprocess
import time
from types import SimpleNamespace
from native_first_page import clone, Guard, now_ns
from transcript_layout import claude_relative, claude_layout, candidate_is_session, default_claude_projects_root

BUNDLE = 'com.bambouville.TesseraApp'


def summarize(results):
    summaries = {}
    for provider in ('codex', 'claude'):
        rows = [row for row in results if row['provider'] == provider and 'error' not in row]
        if not rows: continue
        values = sorted(row['coldHelperToPaintCandidateMS'] for row in rows)
        p95 = values[math.ceil(len(values) * .95) - 1]
        peak = max(row['appIncrementalPeakUpperBoundBytes'] for row in rows)
        summaries[provider] = dict(trials=len(rows), minMS=values[0], p95MS=p95, maxMS=values[-1],
            appIncrementalPeakUpperBoundBytes=peak, sufficientPercentileTrials=len(rows) >= 20,
            candidateLatencyTargetMet=p95 <= 2000, clientMemoryTargetMet=peak <= 64 * 1024 * 1024)
        for metric in ('coldAppToPaintCandidateMS', 'coldAppToCapturedPixelsUpperMS', 'coldHelperToCapturedPixelsUpperMS'):
            if all(metric in row for row in rows):
                measured = sorted(row[metric] for row in rows)
                summaries[provider][metric] = dict(min=measured[0], p95=measured[math.ceil(len(measured) * .95) - 1], max=measured[-1])
    return summaries


def validate_memory(measured):
    fields = ('appBaselineRSSBytes', 'appPaintRSSBytes', 'appLifetimePeakRSSBytes',
              'appAfterInventoryRSSBytes', 'appAfterInventoryLifetimePeakRSSBytes')
    if any(type(measured.get(key)) is not int or measured[key] <= 0 for key in fields):
        raise RuntimeError('native_benchmark_memory_evidence_incomplete')
    return max(0, max(measured['appLifetimePeakRSSBytes'], measured['appAfterInventoryLifetimePeakRSSBytes'])
               - measured['appBaselineRSSBytes'])


async def command(*args, environment=None, timeout=30, required=True):
    process = await asyncio.create_subprocess_exec(*map(str, args), env=environment,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout)
    except BaseException:
        if process.returncode is None:
            try: process.kill()
            except ProcessLookupError: pass
        await process.wait(); raise
    if required and process.returncode:
        raise RuntimeError('benchmark_command_failed')
    return stdout, stderr


def prepare(root, candidate, candidates):
    expected = set(); target = None
    for ordinal, row in enumerate(candidates):
        original = Path(row['original_path'])
        if row['provider'] == 'codex':
            destination = root / 'codex/sessions' / f'snapshot-{ordinal}' / original.name
            discovered = True
        else:
            relative = claude_relative(original, row.get('source_root', default_claude_projects_root()))
            destination = root / 'claude/projects' / relative
            discovered = claude_layout(relative) != 'non_session_jsonl'
        clone(row['path'], destination)
        if discovered: expected.add(str(destination))
        if row['path'] == candidate['path']: target = destination
    if target is None: raise RuntimeError('benchmark_target_missing')
    return target, expected


async def cleanup_trial(server, proxy, video, process, guard, diagnostic, terminate):
    """Every owned resource gets a cleanup attempt even when another fails."""
    failures = []
    async def attempt(name, operation):
        try: await operation()
        except BaseException as error: failures.append((name, type(error).__name__))
    async def stop_accepting(): server.close()
    async def close_server(): await asyncio.wait_for(server.wait_closed(), 5)
    async def stop_video():
        if video is None: return
        try:
            if video.returncode is None: video.send_signal(signal.SIGINT)
            await asyncio.wait_for(video.wait(), 5)
        finally:
            if video.returncode is None:
                try: video.kill()
                except ProcessLookupError: pass
                await video.wait()
    async def stop_helper():
        if process is None: return
        try:
            if process.poll() is None: process.terminate()
            await asyncio.to_thread(process.wait, timeout=5)
        finally:
            if process.poll() is None:
                try: process.kill()
                except ProcessLookupError: pass
                await asyncio.to_thread(process.wait, timeout=3)
    async def close_guard():
        if guard is None: return
        guard.close()
        if guard.failure: raise RuntimeError('native_benchmark_guard_failure')
    # Diagnostics cannot delay host resource teardown or suppress it.
    for name, operation in [('listener', stop_accepting), ('proxy', proxy.close), ('server', close_server),
            ('helper', stop_helper), ('guard', close_guard), ('video', stop_video),
            ('diagnostic', diagnostic), ('app', terminate)]:
        await attempt(name, operation)
    if failures: raise RuntimeError('native_benchmark_cleanup_failed_' + '_'.join(name for name, _ in failures))


class DelayProxy:
    """Delay stream arrival, not each sequential read/record/RPC processing."""
    def __init__(self, target, delay):
        self.target = target; self.delay = delay
        self.tasks = set(); self.failure = None; self.connections = 0
        self.bytes = [0, 0]; self.max_queued = [0, 0]
        self.ssh = None

    async def direction(self, reader, writer, direction):
        queue = asyncio.Queue(maxsize=16)
        async def receive():
            while True:
                data = await reader.read(65536)
                await queue.put((asyncio.get_running_loop().time() + self.delay, data))
                self.max_queued[direction] = max(self.max_queued[direction], queue.qsize() * 65536)
                if not data: return
        async def deliver():
            while True:
                due, data = await queue.get()
                await asyncio.sleep(max(0, due - asyncio.get_running_loop().time()))
                if not data:
                    if writer.can_write_eof(): writer.write_eof()
                    return
                self.bytes[direction] += len(data)
                writer.write(data); await writer.drain()
        receivers = [asyncio.create_task(receive()), asyncio.create_task(deliver())]
        try: await asyncio.gather(*receivers)
        finally:
            for task in receivers: task.cancel()
            await asyncio.gather(*receivers, return_exceptions=True)

    async def accept(self, reader, writer):
        task = asyncio.current_task(); self.tasks.add(task); self.connections += 1
        backend = None
        try:
            if self.connections > 1: raise RuntimeError('unexpected_benchmark_connection')
            deadline = time.monotonic() + 10
            while True:
                try:
                    if self.ssh:
                        if not Path(self.target).exists(): raise FileNotFoundError()
                        upstream, backend = await self.ssh.connect()
                    else:
                        upstream, backend = await asyncio.open_unix_connection(self.target, limit=131072)
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if time.monotonic() > deadline: raise RuntimeError('helper_start_timeout')
                    await asyncio.sleep(.002)
            directions = [asyncio.create_task(self.direction(reader, backend, 0)),
                          asyncio.create_task(self.direction(upstream, writer, 1))]
            try: await asyncio.gather(*directions)
            finally:
                for direction in directions: direction.cancel()
                await asyncio.gather(*directions, return_exceptions=True)
        except asyncio.CancelledError: raise
        except Exception as error: self.failure = type(error).__name__
        finally:
            writer.close()
            if backend: backend.close()
            self.tasks.discard(task)

    async def close(self):
        tasks = list(self.tasks)
        for task in tasks: task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if self.ssh: await self.ssh.close()


class SamplingOnlyGuard(Guard):
    """A census never grants signal authority over asynchronously reaped PIDs.

    Failure remains a red benchmark result. The owner closes its exact process
    handles in bounded teardown; no sampled PID or group is ever signaled.
    """
    def abort(self): pass
    def signal_owned(self, signum): raise RuntimeError('sampling_has_no_signal_authority')


class OwnedSSHBackend:
    """Optional explicitly authorized SSH hop, never an unrestricted shell.

    Fixture provisioning is outside the measured boundary, like an existing
    known host. Each cold app gets a fresh authenticated SSH connection and
    shipping attach-only relay. No provider executable or credential is used.
    """
    def __init__(self, binary, root):
        if os.environ.get('TESSERA_RUN_MAC_AGENT_LIVE') != '1':
            raise RuntimeError('owned_mac_ssh_not_authorized')
        source = Path(__file__).resolve().parents[2] / 'integration/mac-agent-ssh-fixture.py'
        spec = importlib.util.spec_from_file_location('paint_mac_ssh', source)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        environment = isolated_provider_environment(root)
        forced = ['/usr/bin/env', *[key + '=' + environment[key] for key in
            ('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'PI_CODING_AGENT_DIR', 'XDG_DATA_HOME', 'KIMI_CODE_HOME', 'PATH')],
            str(binary), 'connect', '--stdio', '--runtime', str(root / 'r'), '--attach-only']
        self.fixture = module.MacSSHFixture(forced).__enter__()
        self.process = None; self.guard = None
        try: self.server_guard = SamplingOnlyGuard(self.fixture.process)
        except BaseException:
            self.fixture.close(); raise

    async def connect(self):
        if self.process is not None: raise RuntimeError('duplicate_ssh_relay')
        self.process = await asyncio.create_subprocess_exec(*self.fixture.command,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            start_new_session=True, limit=131072)
        process = self.process
        self.guard = SamplingOnlyGuard(SimpleNamespace(pid=process.pid, poll=lambda: process.returncode))
        return process.stdout, process.stdin

    async def close(self):
        try:
            if self.process:
                if self.process.returncode is None:
                    try: self.process.terminate()
                    except ProcessLookupError: pass
                try: await asyncio.wait_for(self.process.wait(), 5)
                except asyncio.TimeoutError:
                    try: self.process.kill()
                    except ProcessLookupError: pass
                    await self.process.wait()
        finally:
            try:
                failures = []
                for guard in (self.guard, self.server_guard):
                    if guard:
                        try:
                            guard.close()
                            if guard.failure or guard.peak <= 0: failures.append('sampling')
                        except Exception: failures.append('cleanup')
                if failures: raise RuntimeError('ssh_memory_evidence_failed')
            finally:
                # The fixture defers SIGTERM during teardown; Python signal
                # handlers must run on the main thread. Its waits are bounded.
                self.fixture.close()


def isolated_provider_environment(root):
    return dict(os.environ, CODEX_HOME=str(root / 'codex'), CLAUDE_CONFIG_DIR=str(root / 'claude'),
        PI_CODING_AGENT_DIR=str(root / 'pi'), XDG_DATA_HOME=str(root / 'xdg'), KIMI_CODE_HOME=str(root / 'kimi'),
        PATH=str(root / 'no-provider-executables'))


async def wait_file(path, timeout=30):
    deadline = time.monotonic() + timeout
    while not path.exists():
        if path.name == 'ready.json' and (path.parent / 'paint.json').exists():
            raise RuntimeError('native_benchmark_app_failed_before_ready')
        if time.monotonic() > deadline: raise RuntimeError('native_benchmark_checkpoint_timeout')
        await asyncio.sleep(.005)
    data = path.read_bytes()
    if len(data) > 8192: raise RuntimeError('native_benchmark_report_budget')
    return json.loads(data)


async def trial(args, candidate, index):
    root = args.output / f'{candidate["provider"]}-{index}'
    root.mkdir(mode=0o700)
    target, expected = prepare(root, candidate, args.candidates)
    inventory = len(expected)
    proxy = DelayProxy(str(root / 'r/client.sock'), args.rtt_ms / 2000)
    proxy_path = root / 'proxy.sock'
    server = await asyncio.start_unix_server(proxy.accept, str(proxy_path), limit=131072)
    proxy_path.chmod(0o600)
    config = dict(directory=str(root), socket=str(proxy_path), transcript=str(target),
        provider=candidate['provider'], expectedInventory=inventory,
        expectedInventorySHA256=hashlib.sha256('\n'.join(sorted(expected)).encode()).hexdigest(),
        inventoryBeforeBootstrap=args.discovery_order == 'inventory-first', coldApp=args.launch_inclusive)
    environment = dict(os.environ, SIMCTL_CHILD_TESSERA_AGENT_CENTER_V2_HARNESS='1',
        SIMCTL_CHILD_TESSERA_AGENT_CENTER_V2_HARNESS_SCENE='coldPage',
        SIMCTL_CHILD_TESSERA_COLD_PAGE_CONFIG=base64.b64encode(json.dumps(config).encode()).decode())
    process = None; guard = None; video = None; successful = False
    try:
        if args.ssh: proxy.ssh = OwnedSSHBackend(args.binary, root)
        if index == 0:
            video = await asyncio.create_subprocess_exec('xcrun', 'simctl', 'io', args.device, 'recordVideo', '--codec=h264',
                str(root / 'paint.mp4'), stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        launch_requested = now_ns()
        await command('xcrun', 'simctl', 'launch', '--terminate-running-process', args.device, BUNDLE, environment=environment)
        ready = await wait_file(root / 'ready.json')
        provider_environment = isolated_provider_environment(root)
        started = now_ns()
        process = subprocess.Popen([str(args.binary), 'serve', '--runtime', str(root / 'r')],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=provider_environment, start_new_session=True)
        # This isolated provider environment contains no executable provider;
        # the helper is directly owned and sampling never authorizes signals.
        guard = SamplingOnlyGuard(process)
        measured = await wait_file(root / 'paint.json')
        if 'error' in measured: raise RuntimeError('native_benchmark_app_failure')
        inventory_result = await wait_file(root / 'inventory.json')
        measured.update(inventory_result)
        app_peak = validate_memory(measured)
        if not ready['readyNS'] <= started <= measured['helloNS'] <= measured['modelNS'] <= measured['visibleLayoutNS'] <= measured['paintNS'] <= now_ns():
            raise RuntimeError('native_benchmark_clock_or_order')
        if measured['inventoryCount'] != inventory or measured['records'] <= 0 or measured['messages'] <= 0:
            raise RuntimeError('native_benchmark_empty_or_incomplete')
        if args.discovery_order == 'inventory-first' and measured['inventoryNS'] > measured['modelNS']:
            raise RuntimeError('native_benchmark_inventory_order')
        if args.discovery_order == 'selected-first' and measured['inventoryNS'] < measured['modelNS']:
            raise RuntimeError('native_benchmark_inventory_order')
        if guard.failure or proxy.failure or proxy.connections != 1 or guard.samples <= 0:
            raise RuntimeError('native_benchmark_resource_or_stream_failure')
        # Capture actual compositor pixels in every trial, without a settling
        # sleep. Completion is a conservative visibility upper bound, not the
        # precise first painted frame. Original pixels stay private.
        await command('xcrun', 'simctl', 'io', args.device, 'screenshot', root / 'paint.png')
        captured = now_ns()
        successful = True
        return dict(provider=candidate['provider'], trial=index, fileBytes=candidate['bytes'], rttMS=args.rtt_ms,
            discoveryOrder=args.discovery_order, fullInventoryCompletedMS=(measured['inventoryNS'] - started) / 1e6,
            coldHelperToPaintCandidateMS=(measured['paintNS'] - started) / 1e6,
            coldAppToPaintCandidateMS=(measured['paintNS'] - launch_requested) / 1e6,
            coldAppToCapturedPixelsUpperMS=(captured - launch_requested) / 1e6,
            coldHelperToCapturedPixelsUpperMS=(captured - started) / 1e6,
            appLaunchRequestedNS=launch_requested, capturedPixelsNS=captured,
            sshClientTreeSampledPeakBytes=proxy.ssh.guard.peak if proxy.ssh and proxy.ssh.guard else None,
            sshServerAndRelayTreeSampledPeakBytes=proxy.ssh.server_guard.peak if proxy.ssh else None,
            coldHelperToModelMS=(measured['modelNS'] - started) / 1e6,
            modelToPaintCandidateMS=(measured['paintNS'] - measured['modelNS']) / 1e6,
            helperTreeSampledPeakBytes=guard.peak, appIncrementalPeakUpperBoundBytes=app_peak,
            helperStartedNS=started, measurements=measured, proxyBytes=proxy.bytes, proxyMaxQueuedBytes=proxy.max_queued,
            proxyConnections=proxy.connections,
            visualVerification='pending original video review')
    finally:
        async def diagnostic():
            if not successful:
                logs, _ = await command('xcrun', 'simctl', 'spawn', args.device, 'log', 'show', '--last', '2m',
                    '--style', 'compact', '--predicate', 'eventMessage BEGINSWITH "TESSERA_NATIVE_PAINT"', required=False)
                (root / 'app-checkpoint-failure.log').write_bytes(logs)
                await command('xcrun', 'simctl', 'io', args.device, 'screenshot', root / 'failure.png', required=False)
        async def terminate():
            await command('xcrun', 'simctl', 'terminate', args.device, BUNDLE, required=False)
        await cleanup_trial(server, proxy, video, process, guard, diagnostic, terminate)


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'app', 'manifest', 'output', 'owned-device-file'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--trials', type=int, default=20)
    parser.add_argument('--rtt-ms', type=float, default=50)
    parser.add_argument('--discovery-order', choices=('inventory-first', 'selected-first'), default='inventory-first')
    parser.add_argument('--ssh', action='store_true', help='Opt-in run-owned authenticated Mac SSH fixture')
    parser.add_argument('--launch-inclusive', action='store_true', help='Remove resident-fixture settling delay and report cold app launch')
    args = parser.parse_args()
    args.output = args.output.resolve()
    if not str(args.output).startswith('/private/tmp/tessera-native-paint-') or len(str(args.output)) > 65:
        parser.error('use a short private tessera-native-paint output path')
    if args.output.exists() or not 1 <= args.trials <= 20 or not 0 <= args.rtt_ms <= 100:
        parser.error('fresh output, 1..20 trials and 0..100 ms RTT required')
    args.device = args.owned_device_file.read_text().strip()
    devices = json.loads((await command('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))[0])['devices']
    matches = [row for rows in devices.values() for row in rows if row['udid'] == args.device]
    if len(matches) != 1 or not matches[0]['name'].startswith('Tessera Native Paint '):
        parser.error('only the integration runner owned Native Paint simulator is permitted')
    os.umask(0o077); args.output.mkdir(mode=0o700)
    args.candidates = json.loads(args.manifest.read_bytes())['candidates']
    pinned = args.output / 'measured-native'
    clone(args.binary.resolve(), pinned); pinned.chmod(0o700); args.binary = pinned
    pinned_app = args.output / 'Tessera.app'
    shutil.copytree(args.app, pinned_app, symlinks=True)
    args.app = pinned_app
    provenance = dict(binarySHA256=hashlib.sha256(pinned.read_bytes()).hexdigest(),
        appExecutableSHA256=hashlib.sha256((pinned_app / 'Tessera').read_bytes()).hexdigest(),
        appCodeSHA256=hashlib.sha256((pinned_app / 'Tessera.debug.dylib').read_bytes()).hexdigest(),
        scriptSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        manifestSHA256=hashlib.sha256(args.manifest.read_bytes()).hexdigest())
    provenance['pythonSources'] = {}
    for name in ('native_paint.py', 'native_first_page.py', 'transcript_layout.py'):
        source = Path(__file__).with_name(name)
        destination = args.output / 'measured-scripts' / name
        clone(source, destination)
        provenance['pythonSources'][name] = hashlib.sha256(destination.read_bytes()).hexdigest()
    reference = dict(deviceType=matches[0]['deviceTypeIdentifier'], buildMode='DEBUG simulator',
        discoveryOrder=args.discovery_order, navigation='selected before async page bootstrap, as in the app',
        appState='fresh app process per trial; launch-inclusive and helper boundaries reported separately; ' +
            ('no artificial settle' if args.launch_inclusive else 'includes resident fixture 500ms settle'),
        filesystemCache='warm; finite reflink snapshots; no cache purge',
        providerMode='Codex native executable unavailable; canonical JSONL for both providers',
        hostCPU=(await command('/usr/sbin/sysctl', '-n', 'machdep.cpu.brand_string'))[0].decode().strip(),
        hostMemoryBytes=int((await command('/usr/sbin/sysctl', '-n', 'hw.memsize'))[0]),
        network='run-owned loopback SSH; fresh local authentication; injected RTT affects only post-auth application streams' if args.ssh else 'private Unix streams; fixed per-direction arrival delay; no SSH or TCP')
    await command('xcrun', 'simctl', 'install', args.device, args.app)
    results = []
    for provider in ('codex', 'claude'):
        candidate = max((row for row in args.candidates if row['provider'] == provider and
            candidate_is_session(row, default_claude_projects_root())), key=lambda row: row['bytes'])
        for index in range(args.trials):
            try: row = await trial(args, candidate, index)
            except Exception as error:
                reason = str(error) if isinstance(error, RuntimeError) and str(error).replace('_', '').isalnum() else type(error).__name__
                row = dict(provider=provider, trial=index, error=reason)
            results.append(row)
            print(json.dumps(row), flush=True)
            report = dict(stage='cold_app_and_helper_to_ios_capture_' + ('owned_ssh' if args.ssh else 'private_unix'), trials=results,
                **provenance, reference=reference, summaries=summarize(results),
                pendingGates=['original_pixel_readability_verification', 'physical_device_memory'] + ([] if args.ssh else ['real_SSH_overhead']))
            (args.output / 'content-free-results.json').write_text(json.dumps(report, indent=2) + '\n')
            if 'error' in row: raise RuntimeError('native_paint_trial_failed')


async def run():
    task = asyncio.current_task()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, task.cancel)
    await main()


if __name__ == '__main__': asyncio.run(run())
