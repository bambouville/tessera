#!/usr/bin/env python3
"""Host-free, synthetic failure coverage; never reads provider credentials."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


HERE = Path(__file__).resolve().parent
ssh = module('mac_ssh_fixture', HERE / 'mac-agent-ssh-fixture.py')
owned = module('owned_process', HERE / 'owned-process.py')
deepseek = module('deepseek_smoke', HERE.parent / 'performance/agent-center/deepseek_provider_smoke.py')
live = module('mac_live', HERE / 'mac-live-ingestion-probe.py')


class SafetyTests(unittest.TestCase):
    def test_deepseek_dotenv_is_data_not_shell_and_rejects_ambiguous_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'fixture.env'
            key = 'synthetic_key_123456789'
            path.write_text('DEEPSEEK_API_KEY="' + key + '"\nUNRELATED=ignored\n')
            self.assertEqual(deepseek.read_deepseek_key(path), key)
            for content in ['DEEPSEEK_API_KEY=$(not-a-command)\n',
                            'DEEPSEEK_API_KEY=' + key + '\nDEEPSEEK_API_KEY=' + key + '\n']:
                path.write_text(content)
                with self.assertRaises(ValueError): deepseek.read_deepseek_key(path)

    def test_deepseek_provider_error_after_assistant_marker_is_not_success(self):
        for provider, events in (
            ('opencode', [{'type': 'text', 'part': {'text': 'synthetic'}}, {'type': 'error'}]),
            ('pi', [{'type': 'message_end', 'message': {'role': 'assistant', 'stopReason': 'error',
                'content': [{'type': 'text', 'text': 'synthetic'}]}}]),
            ('pi', [{'type': 'message_end', 'message': {'role': 'assistant', 'stopReason': 'aborted'}}]),
        ):
            with self.subTest(provider=provider), self.assertRaisesRegex(RuntimeError, 'provider_reported_error'):
                deepseek.assistant_texts(provider, events)
            with self.subTest(provider=provider), self.assertRaisesRegex(RuntimeError, 'provider_reported_error'):
                live.successful_provider_events(('\n'.join(json.dumps(event) for event in events)).encode())
        self.assertEqual(deepseek.assistant_texts('pi', [{'type': 'message_end', 'message': {
            'role': 'user', 'content': [{'type': 'text', 'text': 'synthetic'}]}}]), [])

    def test_nested_sigterm_cleanup_finishes_all_clients(self):
        stages = []
        with self.assertRaises(SystemExit) as result:
            with owned.cleanup_signals():
                with owned.cleanup_signals():
                    signal.raise_signal(signal.SIGTERM)
                    stages.append('first')
                with owned.cleanup_signals():
                    stages.append('second')
                stages.append('outer')
        self.assertEqual(result.exception.code, 143)
        self.assertEqual(stages, ['first', 'second', 'outer'])

    def test_live_delivery_requires_matching_page_end_and_ack(self):
        client = Mock()
        page = live.CommittedPage(client)
        row = {'kind': 'page.record', 'id': 'live', 'record': {'role': 'assistant',
            'blocks': [{'type': 'text', 'text': 'synthetic'}]}}
        self.assertIsNone(page.accept({'kind': 'page.begin', 'id': 'live'}))
        self.assertIsNone(page.accept(row))
        client.ack.assert_not_called()
        end = {'kind': 'page.end', 'id': 'live', 'records': 1,
            'window': {'version': 2}, 'liveCursor': 'cursor'}
        self.assertIsNone(page.accept(end))
        client.ack.assert_called_once_with(end)
        ack = {'kind': 'window.acked', 'id': 'ack_live', 'windowVersion': 2, 'liveCursor': 'cursor'}
        for changed in ({'id': 'wrong'}, {'windowVersion': 1}, {'liveCursor': 'wrong'}):
            with self.assertRaisesRegex(RuntimeError, 'unmatched_native_ack'):
                page.accept(dict(ack, **changed))
        self.assertEqual(page.accept(ack), [row])
        self.assertEqual(client.cursor, 'cursor')

    def test_live_delivery_rejects_truncated_or_unmatched_pages(self):
        for values in (
            [{'kind': 'page.record', 'id': 'live'}],
            [{'kind': 'window.acked', 'id': 'ack_live'}],
            [{'kind': 'page.begin', 'id': 'live'}, {'kind': 'page.end', 'id': 'wrong'}],
            [{'kind': 'page.begin', 'id': 'live'}, {'kind': 'page.end', 'id': 'live', 'records': 1}],
            [{'kind': 'page.begin', 'id': 'live'}, {'kind': 'page.begin', 'id': 'second'}],
        ):
            page = live.CommittedPage(Mock())
            with self.subTest(values=values), self.assertRaises(RuntimeError):
                for value in values: page.accept(value)

    def test_provider_error_result_is_not_a_successful_empty_turn(self):
        with self.assertRaisesRegex(RuntimeError, 'provider_reported_error'):
            live.successful_provider_events(b'{"type":"result","is_error":true}\n')

    def test_native_probe_rejects_every_unknown_record_representation(self):
        for row in ({'disposition': 'unclassified'}, {'disposition': 'unsupported'},
                    {'record': {'type': 'unknown'}}, {'record': {'unparsedContentCount': 1}},
                    {'record': {'blocks': [{'type': 'unknown'}]}}):
            with self.subTest(row=row), self.assertRaises(RuntimeError):
                live.check_rows([row])
        live.check_rows([{'disposition': 'message', 'record': {'type': 'message', 'role': 'assistant',
            'blocks': [{'type': 'text', 'text': 'synthetic'}]}}])

    def test_native_recovery_never_reuses_bootstrap_transaction(self):
        client = live.Client.__new__(live.Client)
        client.send = Mock()
        responses = []
        for name in ('first', 'second'):
            responses += [{'kind': 'resolved', 'thread': 'thread'},
                {'kind': 'page.begin', 'id': name},
                {'kind': 'page.end', 'id': name, 'records': 0, 'liveCursor': 'cursor',
                    'window': {'segmentID': 'segment', 'version': 1}},
                {'kind': 'window.acked', 'id': 'ack_' + name, 'liveCursor': 'cursor', 'windowVersion': 1}]
        client.receive = Mock(side_effect=responses)
        client.head = None
        client.bootstrap('claude', Path('/synthetic'))
        client.bootstrap('claude', Path('/synthetic'))
        requests = [call.args[0] for call in client.send.call_args_list if call.args[0]['kind'] == 'window.read']
        self.assertEqual(len(requests), 2)
        self.assertNotEqual(requests[0]['id'], requests[1]['id'])

    def test_sigterm_during_ssh_cleanup_still_deletes_both_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ssh.MacSSHFixture.__new__(ssh.MacSSHFixture)
            fixture.root = Path(directory)
            for name in ('client', 'host'):
                (fixture.root / name).write_text('synthetic-not-a-key')
            fixture.process = Mock()
            fixture.process.poll.return_value = None
            fixture.process.wait.side_effect = lambda **_: signal.raise_signal(signal.SIGTERM)
            fixture.log = Mock()
            with self.assertRaises(SystemExit) as result:
                fixture.close()
            self.assertEqual(result.exception.code, 143)
            self.assertFalse((fixture.root / 'client').exists())
            self.assertFalse((fixture.root / 'host').exists())
            fixture.log.close.assert_called_once()

    def test_ssh_wait_and_log_failure_still_delete_both_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ssh.MacSSHFixture.__new__(ssh.MacSSHFixture)
            fixture.root = Path(directory)
            for name in ('client', 'host'):
                (fixture.root / name).write_text('synthetic-not-a-key')
            fixture.process = Mock()
            fixture.process.poll.return_value = None
            fixture.process.wait.side_effect = OSError('synthetic wait failure')
            fixture.log = Mock()
            fixture.log.close.side_effect = OSError('synthetic close failure')
            with self.assertRaises(RuntimeError):
                fixture.close()
            self.assertFalse((fixture.root / 'client').exists())
            self.assertFalse((fixture.root / 'host').exists())

    def test_ssh_unlink_failure_does_not_skip_second_key(self):
        fixture = ssh.MacSSHFixture.__new__(ssh.MacSSHFixture)
        fixture.root = Path('/synthetic-no-real-key-access')
        fixture.process = fixture.log = None
        with patch.object(Path, 'unlink', side_effect=[PermissionError(), None]) as unlink:
            with self.assertRaises(RuntimeError):
                fixture.close()
            self.assertEqual(unlink.call_count, 2)

    def test_exit_time_output_burst_is_bounded_and_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'stdout.jsonl').write_bytes(b'x' * (deepseek.OUTPUT_LIMIT + 100))
            (root / 'stderr.log').write_bytes(b'')
            with self.assertRaises(RuntimeError):
                deepseek.read_private_logs(root, 'synthetic-secret')
            self.assertFalse((root / 'stdout.jsonl').exists())
            self.assertEqual(json.loads((root / 'output-guard.json').read_text())['guard'], 'output_limit')

    def test_detected_secret_removes_both_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('stdout.jsonl', 'stderr.log'):
                (root / name).write_text('synthetic-secret')
            with self.assertRaises(RuntimeError):
                deepseek.read_private_logs(root, 'synthetic-secret')
            self.assertFalse((root / 'stdout.jsonl').exists())
            self.assertFalse((root / 'stderr.log').exists())
            self.assertNotIn('synthetic-secret', (root / 'output-guard.json').read_text())

    def test_detected_secret_is_removed_when_other_log_read_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'stdout.jsonl').write_text('synthetic-secret')
            # Missing stderr raises while opening; stdout still must go.
            with self.assertRaises(RuntimeError):
                deepseek.read_private_logs(root, 'synthetic-secret')
            self.assertFalse((root / 'stdout.jsonl').exists())

    def test_json_escaped_secret_is_removed_and_unknown_types_never_echo(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'stdout.jsonl').write_text('{"type":"\\u0073ynthetic-secret"}')
            (root / 'stderr.log').write_bytes(b'')
            with self.assertRaises(RuntimeError):
                deepseek.read_private_logs(root, 'synthetic-secret')
            self.assertFalse((root / 'stdout.jsonl').exists())
            self.assertEqual(deepseek.event_counts([{'type': 'synthetic-secret'}]), {'<unknown>': 1})

    def test_interrupted_capture_still_inspects_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = Mock()
            process.poll.side_effect = SystemExit(143)
            with patch.object(deepseek._owned, 'OwnedProcess', return_value=process), \
                 patch.object(deepseek, 'read_private_logs', return_value=b'') as inspect:
                with self.assertRaises(SystemExit):
                    deepseek.capture_provider([], root, {}, 'synthetic-secret', time.monotonic())
                process.close.assert_called_once()
                inspect.assert_called_once_with(root, 'synthetic-secret')

    def test_leader_exits_before_child_group_is_still_cleaned(self):
        with tempfile.TemporaryFile() as output:
            command = [sys.executable, '-c',
                'import subprocess,sys; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"]); print(p.pid, flush=True)']
            process = owned.OwnedProcess(command, stdout=output, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.02)
                self.assertEqual(process.poll(), 0)
                self.assertIsInstance(process.child_pid, int)
                self.assertNotEqual(process.child_pid, process.process.pid)
                output.seek(0)
                child = int(output.read())
            finally:
                process.close()
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                state = subprocess.run(['ps', '-p', str(child), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                if not state or state.startswith('Z'):
                    break
                time.sleep(.05)
            self.assertTrue(not state or state.startswith('Z'), 'owned descendant survived cleanup')

    def test_sigterm_runs_finally_cleanup(self):
        command = [sys.executable, '-c',
            'import importlib.util,sys,time; s=importlib.util.spec_from_file_location("owned",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)\n'
            'with m.termination_cleanup():\n'
            ' try:\n  print("ready",flush=True); time.sleep(60)\n'
            ' finally:\n  print("cleaned",flush=True)\n', str(HERE / 'owned-process.py')]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), 'ready')
            process.send_signal(signal.SIGTERM)
            output, _ = process.communicate(timeout=5)
            self.assertEqual(output.strip(), 'cleaned')
            self.assertEqual(process.returncode, 143)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


if __name__ == '__main__':
    unittest.main()
