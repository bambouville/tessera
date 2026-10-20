"""Host-free tests of the private native-paint benchmark's stream model."""
import asyncio
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'scripts/performance/agent-center'))
from native_paint import DelayProxy, OwnedSSHBackend, SamplingOnlyGuard, prepare, command, cleanup_trial, summarize, validate_memory


class Reader:
    def __init__(self, values): self.values = iter(values)
    async def read(self, maximum):
        value = next(self.values, b'')
        assert len(value) <= maximum
        return value


class Writer:
    def __init__(self): self.arrivals = []; self.count = 0; self.eof = False
    def write(self, value):
        self.arrivals.append(asyncio.get_running_loop().time()); self.count += len(value)
    async def drain(self): await asyncio.sleep(0)
    def can_write_eof(self): return True
    def write_eof(self): self.eof = True


class PaintTests(unittest.IsolatedAsyncioTestCase):
    def test_ssh_requires_explicit_mac_fixture_opt_in(self):
        with patch.dict('os.environ', {'TESSERA_RUN_MAC_AGENT_LIVE': '0'}):
            with self.assertRaisesRegex(RuntimeError, 'not_authorized'):
                OwnedSSHBackend(Path('/unused'), Path('/unused'))

    async def test_proxy_always_closes_its_optional_owned_ssh_backend(self):
        proxy = DelayProxy('unused', 0)
        proxy.ssh = Mock(close=AsyncMock())
        await proxy.close()
        proxy.ssh.close.assert_awaited_once()

    async def test_ssh_fixture_cleanup_keeps_signal_handlers_on_main_thread(self):
        backend = OwnedSSHBackend.__new__(OwnedSSHBackend)
        backend.process = None; backend.guard = None; backend.server_guard = None
        def close(): self.assertIs(threading.current_thread(), threading.main_thread())
        backend.fixture = Mock(close=Mock(side_effect=close))
        await backend.close()
        backend.fixture.close.assert_called_once()

    def test_sampling_never_signals_census_pids(self):
        guard = SamplingOnlyGuard.__new__(SamplingOnlyGuard)
        with patch('os.killpg') as kill:
            guard.abort()
            with self.assertRaisesRegex(RuntimeError, 'no_signal_authority'): guard.signal_owned(9)
            kill.assert_not_called()

    async def test_ssh_closes_both_samplers_and_fixture_after_sampling_failure(self):
        backend = OwnedSSHBackend.__new__(OwnedSSHBackend)
        backend.process = Mock(returncode=0, wait=AsyncMock(return_value=0))
        backend.guard = Mock(close=Mock(side_effect=RuntimeError('failed')))
        backend.server_guard = Mock(failure=None, peak=10)
        backend.fixture = Mock()
        with self.assertRaisesRegex(RuntimeError, 'ssh_memory_evidence_failed'): await backend.close()
        backend.guard.close.assert_called_once(); backend.server_guard.close.assert_called_once()
        backend.guard.signal_owned.assert_not_called(); backend.server_guard.signal_owned.assert_not_called()
        backend.fixture.close.assert_called_once()

    def test_memory_requires_post_inventory_peak_even_after_successful_paint(self):
        sample = dict(appBaselineRSSBytes=90, appPaintRSSBytes=95, appLifetimePeakRSSBytes=100,
                      appAfterInventoryRSSBytes=130, appAfterInventoryLifetimePeakRSSBytes=140)
        self.assertEqual(validate_memory(sample), 50)
        for value in (None, 0, -1, True, '140'):
            with self.assertRaisesRegex(RuntimeError, 'memory_evidence_incomplete'):
                validate_memory(dict(sample, appAfterInventoryLifetimePeakRSSBytes=value))
        del sample['appAfterInventoryLifetimePeakRSSBytes']
        with self.assertRaisesRegex(RuntimeError, 'memory_evidence_incomplete'): validate_memory(sample)

    def test_percentiles_require_twenty_trials_and_do_not_hide_failed_targets(self):
        rows = [dict(provider='codex', coldHelperToPaintCandidateMS=value,
                     appIncrementalPeakUpperBoundBytes=65 * 1024 * 1024) for value in range(2001, 2021)]
        summary = summarize(rows)['codex']
        self.assertEqual(summary['p95MS'], 2019)
        self.assertTrue(summary['sufficientPercentileTrials'])
        self.assertFalse(summary['candidateLatencyTargetMet'])
        self.assertFalse(summary['clientMemoryTargetMet'])
        self.assertFalse(summarize(rows[:1])['codex']['sufficientPercentileTrials'])
    async def test_fixed_delay_is_not_multiplied_by_chunk_or_record_count(self):
        proxy = DelayProxy('unused', .05); writer = Writer()
        started = asyncio.get_running_loop().time()
        await proxy.direction(Reader([b'one', b'two', b'three']), writer, 0)
        self.assertEqual(writer.count, 11)
        self.assertTrue(writer.eof)
        self.assertGreaterEqual(writer.arrivals[0] - started, .045)
        self.assertLess(writer.arrivals[-1] - writer.arrivals[0], .03)
        self.assertEqual(proxy.bytes, [11, 0])

    async def test_queue_is_bounded_and_does_not_drop_stream_bytes(self):
        proxy = DelayProxy('unused', .002); writer = Writer()
        block = b'x' * 65536
        await proxy.direction(Reader([block] * 64), writer, 1)
        self.assertEqual(writer.count, 64 * len(block))
        self.assertLessEqual(proxy.max_queued[1], 16 * 65536)
        self.assertTrue(writer.eof)

    async def test_command_failure_is_explicit_and_timeout_reaps_child(self):
        with self.assertRaisesRegex(RuntimeError, 'benchmark_command_failed'):
            await command(sys.executable, '-c', 'raise SystemExit(7)')
        with self.assertRaises(asyncio.TimeoutError):
            await command(sys.executable, '-c', 'import time; time.sleep(10)', timeout=.05)

    async def test_cleanup_attempts_every_resource_after_independent_failures(self):
        server = Mock(); server.wait_closed = AsyncMock(side_effect=TimeoutError())
        proxy = Mock(); proxy.close = AsyncMock(side_effect=asyncio.CancelledError())
        video = Mock(returncode=0); video.wait = AsyncMock(return_value=0)
        process = Mock(); process.poll.return_value = None
        process.wait.side_effect = lambda **kwargs: setattr(process.poll, 'return_value', 0)
        guard = Mock(failure=None)
        diagnostic = AsyncMock(side_effect=TimeoutError())
        terminate = AsyncMock(side_effect=TimeoutError())
        with self.assertRaisesRegex(RuntimeError, 'cleanup_failed_proxy_server_diagnostic_app'):
            await cleanup_trial(server, proxy, video, process, guard, diagnostic, terminate)
        server.close.assert_called_once(); proxy.close.assert_awaited_once()
        video.wait.assert_awaited_once(); process.terminate.assert_called_once()
        guard.signal_owned.assert_not_called(); guard.close.assert_called_once()
        diagnostic.assert_awaited_once(); terminate.assert_awaited_once()

    async def test_cleanup_closes_attached_unix_clients_before_waiting_for_server(self):
        with tempfile.TemporaryDirectory(prefix='tessera-paint-cleanup-') as directory:
            path = str(Path(directory) / 'proxy')
            proxy = DelayProxy(str(Path(directory) / 'absent-helper'), 0)
            server = await asyncio.start_unix_server(proxy.accept, path)
            reader, writer = await asyncio.open_unix_connection(path)
            try:
                for _ in range(100):
                    if proxy.tasks: break
                    await asyncio.sleep(.001)
                self.assertTrue(proxy.tasks)
                await asyncio.wait_for(cleanup_trial(server, proxy, None, None, None,
                    AsyncMock(), AsyncMock()), 1)
                self.assertFalse(proxy.tasks)
                self.assertEqual(await reader.read(), b'')
            finally:
                writer.close(); await writer.wait_closed()
                server.close(); await proxy.close(); await server.wait_closed()

    def test_preparation_keeps_all_files_but_counts_only_session_layouts(self):
        with tempfile.TemporaryDirectory(prefix='tessera-paint-fixture-') as directory:
            base = Path(directory); source = base / 'finite.jsonl'; source.write_text('{}\n')
            session = '00000000-0000-0000-0000-000000000001'
            candidates = [dict(provider='codex', path=str(source), original_path='/synthetic/rollout-' + session + '.jsonl'),
                dict(provider='claude', path=str(source), original_path='/synthetic/projects/p/' + session + '.jsonl', source_root='/synthetic/projects'),
                dict(provider='claude', path=str(source), original_path='/synthetic/projects/p/results.jsonl', source_root='/synthetic/projects')]
            target, expected = prepare(base / 'copy', candidates[0], candidates)
            self.assertTrue(target.exists())
            self.assertEqual(len(expected), 2)
            self.assertEqual(len(list((base / 'copy').rglob('*.jsonl'))), 3)


if __name__ == '__main__': unittest.main()
