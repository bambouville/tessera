"""Probe verdict regressions. Never invokes Claude or touches provider storage."""
import copy
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import types
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('probe', Path(__file__).with_name('claude_hook_probe.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
spec = importlib.util.spec_from_file_location('benchmark', Path(__file__).with_name('benchmark_hook_sender.py'))
benchmark = importlib.util.module_from_spec(spec)
spec.loader.exec_module(benchmark)


class VerdictTests(unittest.TestCase):
    def setUp(self):
        self.summary = {'exit_code': 0, 'timed_out': False, 'result_is_error': False,
            'collector_errors': [], 'tools': False, 'interactive': False,
            'hook_counts': {name: 1 for name in ('SessionStart', 'UserPromptSubmit', 'MessageDisplay', 'Stop', 'SessionEnd')},
            'display_matches_stop': True, 'display_indices_contiguous': True, 'display_final_count': 1,
            'display_batches': [{'index': 0, 'final': True}],
            'stop_matches_final_result': True}

    def test_complete_headless_passes(self):
        self.assertEqual(probe.case_failures(self.summary), [])

    def test_stop_only_is_not_success(self):
        self.summary['hook_counts'] = {'Stop': 1}
        self.assertIn('missing_required_hook', probe.case_failures(self.summary))

    def test_all_semantic_failures_fail(self):
        for key, value in [('display_matches_stop', False), ('display_indices_contiguous', False),
                           ('display_final_count', 0), ('display_final_count', 2), ('stop_matches_final_result', False)]:
            summary = copy.deepcopy(self.summary)
            summary[key] = value
            self.assertTrue(probe.case_failures(summary), key)

    def test_tool_case_requires_all_tool_hooks(self):
        self.summary['tools'] = True
        self.assertIn('missing_required_hook', probe.case_failures(self.summary))
        self.summary['hook_counts'].update({name: 1 for name in ('PreToolUse', 'PostToolUse', 'PostToolBatch')})
        self.assertEqual(probe.case_failures(self.summary), [])

    def test_interactive_requires_canonical_text_match(self):
        self.summary['interactive'] = True
        self.summary['stop_matches_final_result'] = False
        self.assertIn('canonical_text_mismatch', probe.case_failures(self.summary))
        self.summary['synthetic_transcript'] = {'available': True, 'display_matches_text': True}
        self.assertEqual(probe.case_failures(self.summary), [])

    def test_overflow_hint_cannot_pass_as_full_benchmark_payload(self):
        hint = b'{"hook_event_name":"TesseraHookOverflow"}'
        with self.assertRaisesRegex(ValueError, 'payload mismatch'):
            benchmark.validate_receipt(struct.pack('!I', len(hint)) + hint, b'x' * 65526)
        benchmark.validate_receipt(struct.pack('!I', len(hint)) + hint, hint)

    def test_final_batch_must_be_last(self):
        self.summary['display_batches'] = [{'index': 0, 'final': True}, {'index': 1, 'final': False}]
        self.assertIn('display_sequence_mismatch', probe.case_failures(self.summary))

    def test_nonzero_native_service_exit_fails_probe(self):
        collector = object.__new__(probe.NativeCollector)
        collector.closed = False
        collector.finished = mock.Mock()
        collector.thread = mock.Mock()
        collector.connection = mock.Mock()
        collector.process = mock.Mock()
        collector.process.wait.return_value = 2
        collector.errors = []
        collector.close()
        self.assertIn('native_exit_failed', collector.errors)
        collector.close()
        self.assertEqual(collector.process.wait.call_count, 1)

    def test_owned_process_cleanup_kills_and_reaps_after_timeout(self):
        process = mock.Mock()
        process.poll.return_value = None
        process.wait.side_effect = [subprocess.TimeoutExpired('synthetic', 3), 0]
        probe.stop_owned_process(process)
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.call_count, 2)

    def test_headless_launch_failure_closes_collector(self):
        collector = types.SimpleNamespace(close=mock.Mock(), thread=mock.Mock())
        with mock.patch.object(probe.subprocess, 'Popen', side_effect=OSError('synthetic launch error')):
            with self.assertRaises(OSError):
                probe.capture_headless([], {}, Path('/tmp'), collector, 5)
        collector.close.assert_called_once()

    def test_tmux_cleanup_failure_still_closes_collector(self):
        collector = types.SimpleNamespace(close=mock.Mock(), thread=mock.Mock(), errors=[])
        results = [subprocess.CompletedProcess([], 1), subprocess.TimeoutExpired('tmux', 5), subprocess.TimeoutExpired('tmux', 5)]
        with mock.patch.object(probe.subprocess, 'run', side_effect=results) as run:
            probe.capture_tmux([], {}, Path('/tmp'), collector, 5)
        collector.close.assert_called_once()
        self.assertIn('tmux_cleanup_failed', collector.errors)
        self.assertEqual(run.call_args_list[0].args[0][:3], ['tmux', '-f', '/dev/null'])

    def test_capture_failure_retains_private_partial_evidence(self):
        with tempfile.TemporaryDirectory(prefix='probe-unit-') as temporary:
            root = Path(temporary).resolve()
            collector = types.SimpleNamespace(path=root / 'events.sock', close=mock.Mock(),
                events=[{'input': {'hook_event_name': 'Stop'}}], partial_outputs={'stdout': b'synthetic'}, errors=[])
            args = types.SimpleNamespace(native_service=False, sender=Path('/bin/false'), claude=Path('/bin/false'),
                model='unused', interactive=False, persist=False, config_dir=None, timeout=5)
            with mock.patch.object(probe, 'Collector', return_value=collector), mock.patch.object(
                    probe, 'capture_headless', side_effect=RuntimeError('synthetic failure')):
                with self.assertRaises(RuntimeError):
                    probe.run_case(args, root, 'failure', False, False)
            self.assertEqual(json.loads((root / 'failure/private-events.json').read_text()), collector.events)
            self.assertEqual((root / 'failure/private-stdout.bin').read_bytes(), b'synthetic')
            self.assertEqual((root / 'failure/private-events.json').stat().st_mode & 0o777, 0o600)
            collector.close.assert_called_once()


if __name__ == '__main__':
    unittest.main()
