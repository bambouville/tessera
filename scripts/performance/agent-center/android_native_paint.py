#!/usr/bin/env python3
"""Private finite corpus -> real Android decoder/Core/Compose paint candidate.

Uses only runner-owned emulators and unique adb-reversed Unix sockets, with
optional owned loopback SSH. No provider session control. Calibrates a clock
offset interval and reports conservative candidate/capture latency bounds.
"""
import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import signal
import struct
import subprocess
import time
from native_first_page import clone, now_ns
from native_paint import DelayProxy, OwnedSSHBackend, SamplingOnlyGuard, isolated_provider_environment, command, prepare, summarize, validate_memory, cleanup_trial
from transcript_layout import candidate_is_session, default_claude_projects_root

PACKAGE = 'com.bambouville.tessera.feature.agentcenter.test'


async def verify_owned(adb, serial, name):
    actual, _ = await command(adb, '-s', serial, 'emu', 'avd', 'name', timeout=5)
    lines = actual.decode().splitlines()
    if not lines or lines[0] != name: raise RuntimeError('owned_emulator_identity_changed')


async def owned_command(adb, serial, name, *parts, **kwargs):
    await verify_owned(adb, serial, name)
    return await command(adb, '-s', serial, *parts, **kwargs)


def clock_bounds(samples):
    if len(samples) != 5: raise RuntimeError('clock_calibration_incomplete')
    lows = []; highs = []
    for h0, a1, a2, h3 in samples:
        if any(type(value) is not int or value <= 0 for value in (h0, a1, a2, h3)) or h0 > h3 or a1 > a2:
            raise RuntimeError('clock_calibration_order')
        lows.append(a2 - h3); highs.append(a1 - h0)
    lower, upper = max(lows), min(highs)
    if not lower <= upper or upper - lower > 20_000_000:
        raise RuntimeError('clock_calibration_uncertain')
    return lower, upper


class AndroidProxy(DelayProxy):
    def __init__(self, target, delay, token):
        super().__init__(target, delay)
        self.token = token; self.ready = asyncio.Event(); self.go = asyncio.Event()
        self.handshakes = set(); self.samples = []; self.offset = None
        self.authenticated = 0; self.baseline = None

    async def accept(self, reader, writer):
        if len(self.handshakes) >= 4:
            writer.close(); self.failure = 'android_fixture_handshake_capacity'; self.ready.set(); return
        task = asyncio.current_task(); self.handshakes.add(task)
        try:
            supplied = await asyncio.wait_for(reader.readexactly(64), 3)
            if not hmac.compare_digest(supplied, self.token.encode('ascii')):
                raise RuntimeError('android_fixture_authentication')
            self.authenticated += 1
            if self.authenticated != 1: raise RuntimeError('android_fixture_duplicate_connection')
            for _ in range(5):
                started = now_ns()
                writer.write(struct.pack('!q', started)); await writer.drain()
                raw = await asyncio.wait_for(reader.readexactly(24), 3)
                finished = now_ns(); nonce, received, sent = struct.unpack('!qqq', raw)
                if nonce != started: raise RuntimeError('clock_calibration_nonce')
                self.samples.append((started, received, sent, finished))
            self.offset = clock_bounds(self.samples)
            self.baseline, = struct.unpack('!q', await asyncio.wait_for(reader.readexactly(8), 3))
            if self.baseline <= 0: raise RuntimeError('android_fixture_memory_missing')
            self.ready.set()
            await asyncio.wait_for(self.go.wait(), 10)
            writer.write(b'\x01'); await writer.drain()
            await super().accept(reader, writer)
        except asyncio.CancelledError: raise
        except Exception as error:
            self.failure = str(error) if isinstance(error, RuntimeError) else type(error).__name__
            self.ready.set()
        finally:
            writer.close(); self.handshakes.discard(task)

    async def close(self):
        tasks = list(self.handshakes)
        for task in tasks: task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await super().close()


async def trial(args, candidate, index):
    root = args.output / f'{candidate["provider"]}-{index}'
    root.mkdir(mode=0o700)
    target, expected = prepare(root, candidate, args.candidates)
    socket_name = 'tessera-paint-' + secrets.token_hex(16)
    token = secrets.token_hex(32)
    proxy = AndroidProxy(str(root / 'r/client.sock'), args.rtt_ms / 2000, token)
    path = root / 'proxy.sock'
    server = await asyncio.start_unix_server(proxy.accept, path, limit=131072); path.chmod(0o600)
    config = dict(socket=socket_name, token=token, transcript=str(target), provider=candidate['provider'],
        expectedInventory=len(expected), expectedInventorySHA256=hashlib.sha256('\n'.join(sorted(expected)).encode()).hexdigest(),
        landscape=args.device_profile == 'pixel_tablet',
        inventoryBeforeBootstrap=args.discovery_order == 'inventory-first', coldApp=args.launch_inclusive)
    process = None; guard = None; instrument = None; recording = None; instrument_log = None
    async def owned():
        await verify_owned(args.adb, args.serial, args.avd_name)
    async def adb(*parts, **kwargs):
        return await owned_command(args.adb, args.serial, args.avd_name, *parts, **kwargs)
    try:
        if args.ssh: proxy.ssh = OwnedSSHBackend(args.binary, root)
        await adb('reverse', '--no-rebind', 'localabstract:' + socket_name, 'localfilesystem:' + str(path))
        # Each instrument invocation is a fresh test application process. Only
        # this run-owned AVD/package is force-stopped or has fixture files reset.
        await adb('shell', 'am', 'force-stop', PACKAGE)
        await adb('shell', 'run-as', PACKAGE, 'rm', '-f', 'files/cold-page.json', 'files/cold-page.pending', 'files/cold-page.png')
        if index == 0:
            await owned()
            recording = await asyncio.create_subprocess_exec(str(args.adb), '-s', args.serial, 'shell',
                'screenrecord --time-limit 120 /data/local/tmp/tessera-cold-page.mp4 & echo $! > /data/local/tmp/tessera-cold-page.pid; wait',
                stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
        await owned()
        instrument_log = (root / 'instrumentation.log').open('wb')
        launch_requested = now_ns()
        instrument = await asyncio.create_subprocess_exec(str(args.adb), '-s', args.serial, 'shell', 'am', 'instrument', '-w', '-r', '-e', 'class',
            'com.bambouville.tessera.feature.agentcenter.AgentColdPageInstrumentedTest', '-e', 'tesseraColdPage',
            base64.b64encode(json.dumps(config).encode()).decode(), PACKAGE + '/androidx.test.runner.AndroidJUnitRunner',
            stdout=instrument_log, stderr=asyncio.subprocess.STDOUT)
        await asyncio.wait_for(proxy.ready.wait(), 30)
        if proxy.failure or proxy.offset is None: raise RuntimeError('android_fixture_handshake_failed')
        environment = isolated_provider_environment(root)
        started = now_ns()
        process = subprocess.Popen([str(args.binary), 'serve', '--runtime', str(root / 'r')],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment, start_new_session=True)
        guard = SamplingOnlyGuard(process); proxy.go.set()
        await asyncio.wait_for(instrument.wait(), 90)
        instrument_log.flush()
        stdout = (root / 'instrumentation.log').read_bytes()
        raw, _ = await adb('exec-out', 'run-as', PACKAGE, 'cat', 'files/cold-page.json')
        if len(raw) > 8192: raise RuntimeError('android_fixture_report_budget')
        measured = json.loads(raw); (root / 'device-measurements.json').write_bytes(raw)
        if 'OK (1 test)' not in stdout.decode(errors='replace') or measured.get('error'):
            raise RuntimeError('android_fixture_test_failed')
        increment = validate_memory(measured)
        if measured['appBaselineRSSBytes'] != proxy.baseline or measured['inventoryCount'] != len(expected) or measured['messages'] <= 0:
            raise RuntimeError('android_fixture_evidence_mismatch')
        if not measured['helloNS'] <= measured['modelNS'] <= measured['visibleLayoutNS'] <= measured['paintNS']:
            raise RuntimeError('android_fixture_event_order')
        if (args.discovery_order == 'inventory-first') != (measured['inventoryNS'] <= measured['modelNS']):
            raise RuntimeError('android_fixture_inventory_order')
        lower, upper = proxy.offset
        earliest = measured['paintNS'] - upper
        latest = measured['paintNS'] - lower
        captured = measured['capturedPixelsNS'] - lower
        if measured['capturedPixelsNS'] < measured['paintNS'] or captured > now_ns():
            raise RuntimeError('android_fixture_capture_clock')
        if earliest < started or latest > now_ns(): raise RuntimeError('android_fixture_clock_mapping')
        if proxy.failure or proxy.connections != 1 or guard.failure or guard.samples <= 0:
            raise RuntimeError('android_fixture_stream_or_resource_failure')
        pixels, _ = await adb('exec-out', 'run-as', PACKAGE, 'cat', 'files/cold-page.png')
        if not pixels.startswith(b'\x89PNG\r\n\x1a\n'): raise RuntimeError('android_fixture_screenshot_missing')
        (root / 'paint.png').write_bytes(pixels)
        return dict(provider=candidate['provider'], trial=index, fileBytes=candidate['bytes'], rttMS=args.rtt_ms,
            discoveryOrder=args.discovery_order, coldHelperToPaintCandidateMS=(latest - started) / 1e6,
            coldHelperToPaintCandidateLowerMS=(earliest - started) / 1e6,
            coldAppToPaintCandidateMS=(latest - launch_requested) / 1e6,
            coldAppToCapturedPixelsUpperMS=(captured - launch_requested) / 1e6,
            coldHelperToCapturedPixelsUpperMS=(captured - started) / 1e6,
            appLaunchRequestedNS=launch_requested, capturedPixelsNS=captured,
            sshClientTreeSampledPeakBytes=proxy.ssh.guard.peak if proxy.ssh and proxy.ssh.guard else None,
            sshServerAndRelayTreeSampledPeakBytes=proxy.ssh.server_guard.peak if proxy.ssh else None,
            coldHelperToModelUpperMS=(measured['modelNS'] - lower - started) / 1e6,
            fullInventoryCompletedUpperMS=(measured['inventoryNS'] - lower - started) / 1e6,
            clockOffsetIntervalNS=[lower, upper], clockCalibrationNS=proxy.samples,
            helperTreeSampledPeakBytes=guard.peak, appIncrementalPeakUpperBoundBytes=increment,
            helperStartedNS=started, measurements=measured, proxyBytes=proxy.bytes, proxyMaxQueuedBytes=proxy.max_queued,
            proxyConnections=proxy.connections, visualVerification='pending original screenshot/video review')
    finally:
        async def diagnostics():
            if instrument is not None:
                if instrument.returncode is None: instrument.kill()
                await instrument.wait()
            if instrument_log is not None: instrument_log.close()
            raw, _ = await adb('exec-out', 'run-as', PACKAGE, 'cat', 'files/cold-page.json', required=False)
            if len(raw) <= 8192: (root / 'device-final-report.json').write_bytes(raw)
        async def terminate():
            failures = []
            for parts in [('shell', 'am', 'force-stop', PACKAGE), ('reverse', '--remove', 'localabstract:' + socket_name)]:
                try: await adb(*parts)
                except Exception: failures.append('android_fixture_cleanup')
            if recording is not None:
                try:
                    pid, _ = await adb('shell', 'cat', '/data/local/tmp/tessera-cold-page.pid')
                    pid = pid.decode().strip()
                    if not pid.isdigit(): raise RuntimeError('android_recorder_identity')
                    name, _ = await adb('shell', 'cat', '/proc/' + pid + '/comm')
                    if name.decode().strip() != 'screenrecord': raise RuntimeError('android_recorder_identity')
                    await adb('shell', 'kill', '-INT', pid)
                    await asyncio.wait_for(recording.wait(), 5)
                    await adb('pull', '/data/local/tmp/tessera-cold-page.mp4', root / 'paint.mp4')
                except Exception: failures.append('android_recorder_cleanup')
                finally:
                    if recording.returncode is None:
                        recording.kill(); await recording.wait()
            if failures: raise RuntimeError('android_fixture_cleanup_failed')
        await cleanup_trial(server, proxy, None, process, guard, diagnostics, terminate)


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('binary', 'apk', 'manifest', 'output', 'owned-device-file', 'adb'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--trials', type=int, default=20)
    parser.add_argument('--rtt-ms', type=float, default=50)
    parser.add_argument('--discovery-order', choices=('inventory-first', 'selected-first'), default='inventory-first')
    parser.add_argument('--device-profile', choices=('pixel_tablet', 'pixel_7'), required=True)
    parser.add_argument('--ssh', action='store_true')
    parser.add_argument('--launch-inclusive', action='store_true')
    args = parser.parse_args(); args.output = args.output.resolve()
    if not str(args.output).startswith('/private/tmp/tessera-android-paint-') or len(str(args.output)) > 65 or args.output.exists():
        parser.error('fresh short private Android paint output required')
    if not 1 <= args.trials <= 20 or not 0 <= args.rtt_ms <= 100: parser.error('bounded trials and RTT required')
    device = args.owned_device_file.read_text().splitlines()
    if len(device) != 2 or not device[0].startswith('tessera-agent-window-') or not device[1].startswith('emulator-'):
        parser.error('runner-owned emulator required')
    args.serial = device[1]; args.avd_name = device[0]
    actual, _ = await command(args.adb, '-s', args.serial, 'emu', 'avd', 'name')
    if actual.decode().splitlines()[0] != device[0]: parser.error('owned emulator identity mismatch')
    os.umask(0o077); args.output.mkdir(mode=0o700)
    args.candidates = json.loads(args.manifest.read_bytes())['candidates']
    binary = args.output / 'measured-native'; clone(args.binary.resolve(), binary); binary.chmod(0o700); args.binary = binary
    apk = args.output / 'measured-test.apk'; clone(args.apk, apk)
    await owned_command(args.adb, args.serial, args.avd_name, 'install', '-r', apk)
    provenance = dict(binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(), apkSHA256=hashlib.sha256(apk.read_bytes()).hexdigest(),
        manifestSHA256=hashlib.sha256(args.manifest.read_bytes()).hexdigest(), pythonSources={})
    for name in ('android_native_paint.py', 'native_paint.py', 'native_first_page.py', 'transcript_layout.py'):
        source = Path(__file__).with_name(name); clone(source, args.output / 'measured-scripts' / name)
        provenance['pythonSources'][name] = hashlib.sha256(source.read_bytes()).hexdigest()
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
            report = dict(stage='cold_app_and_helper_to_android_capture_' + ('owned_ssh' if args.ssh else 'private_adb_unix'), trials=results,
                **provenance, summaries=summarize(results), reference=dict(discoveryOrder=args.discovery_order,
                    deviceProfile=args.device_profile,
                    buildMode='DEBUG instrumentation APK, owned emulator', filesystemCache='warm finite snapshots; no cache purge',
                    appState='fresh instrumentation APK per trial; launch-inclusive includes Android test runner startup; ' +
                        ('no artificial settle' if args.launch_inclusive else 'resident fixture 500ms settle'),
                    providerMode='canonical JSONL; no provider executable available',
                    network='owned loopback SSH via adb Unix adapter; fresh local authentication; injected RTT only affects post-auth application streams' if args.ssh else 'authenticated adb-reversed Unix streams; no TCP listener or SSH',
                    clock='five pre-start round trips; intersected offset interval; reported latency is conservative upper bound'),
                pendingGates=['original_pixel_readability_verification', 'physical_device_memory'] + ([] if args.ssh else ['real_SSH_overhead']))
            (args.output / 'content-free-results.json').write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps(row), flush=True)
            if 'error' in row: raise RuntimeError('android_native_paint_trial_failed')


async def run():
    task = asyncio.current_task()
    asyncio.get_running_loop().add_signal_handler(signal.SIGTERM, task.cancel)
    await main()


if __name__ == '__main__': asyncio.run(run())
