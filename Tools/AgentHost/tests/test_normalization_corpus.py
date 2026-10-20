#!/usr/bin/env python3
from pathlib import Path
import sys
import tempfile
import unittest
import json
import sqlite3
import shutil
import errno
import os
import signal
import io
import gc
import types
import threading
from contextlib import closing
from unittest.mock import Mock, patch
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'scripts/performance/agent-center'))
from codex_event_text_corpus import candidate as event_text_candidate, display as event_text_display
from codex_completed_projection_corpus import line as completed_projection_line, write_frame, compare_item as completed_projection_compare, equivalent_projection, command_argv
from normalization_corpus import compare, compare_metadata, coverage, input_coverage, projector, safe_type, reference_records, gate_status, scope_summary, worker_memory
from native_first_page import Guard, seed_native_store, trial, connect_started_service, owned_services, cleanup_trial, start_context
from normalization_schema import output_issues, source_shape_issues
from native_ui_resources import census as ui_census
from transcript_layout import claude_relative, claude_layout, candidate_is_session
from upstream_core_corpus import native_extension
from canonical_authority_corpus import header_expectation, MAXIMUM_HEADER
from codex_history_corpus import validate_reference as validate_history_reference, validate_completion as validate_history_completion
from opencode_corpus import expected_keys as opencode_expected_keys, audit_session as opencode_audit_session


class DifferentialTests(unittest.TestCase):
    def test_opencode_oracle_orders_message_headers_then_parts_and_scopes_sessions(self):
        with closing(sqlite3.connect(':memory:')) as database:
            database.execute('CREATE TABLE message(id,session_id,time_created)')
            database.execute('CREATE TABLE part(id,session_id,message_id)')
            database.executemany('INSERT INTO message VALUES(?,?,?)', [('msg_b','s',1),('msg_a','s',1),('msg_other','other',0)])
            database.executemany('INSERT INTO part VALUES(?,?,?)', [('prt_b','s','msg_a'),('prt_a','s','msg_a'),('prt_hidden','other','msg_a')])
            self.assertEqual(list(opencode_expected_keys(database, 's')),
                             [(1,'msg_a','msg_a'),(1,'msg_a','prt_a'),(1,'msg_a','prt_b'),(1,'msg_b','msg_b')])
            database.execute('CREATE TABLE session_message(id,session_id,seq)')
            database.executemany('INSERT INTO session_message VALUES(?,?,?)', [('m_b','s',2),('m_a','s',1)])
            self.assertEqual(list(opencode_expected_keys(database, 's')), [(1,'','m_a'),(2,'','m_b')])

    def test_opencode_oracle_rejects_empty_success_with_missing_history(self):
        with patch('opencode_corpus.expected_keys', return_value=iter([(1,'','missing')])), \
             patch('opencode_corpus.write_frame'), patch('opencode_corpus.line', return_value=dict(identity='source',rows=[],peakRSSBytes=4096)):
            with self.assertRaisesRegex(RuntimeError, 'selected_history_incomplete'):
                opencode_audit_session(Mock(), Mock(), 's')

    def test_opencode_oracle_keeps_unknown_record_coverage_red(self):
        row = dict(created=1,message='',id='one',record=dict(type='unknown'),disposition='unclassified')
        with patch('opencode_corpus.expected_keys', return_value=iter([(1,'','one')])), \
             patch('opencode_corpus.write_frame'), patch('opencode_corpus.line', side_effect=[dict(identity='source',rows=[row],peakRSSBytes=4096),dict(identity='source',rows=[],peakRSSBytes=4096)]):
            result = opencode_audit_session(Mock(), Mock(), 's')
            self.assertEqual(result['records'], 1)
            self.assertGreater(result['coverage_issues']['disposition/unclassified'], 0)

    def test_opencode_oracle_requires_native_lifetime_memory_evidence(self):
        for memory in (None, 0, True, -1, 257 * 1024 * 1024):
            with patch('opencode_corpus.expected_keys', return_value=iter([])), \
                 patch('opencode_corpus.write_frame'), patch('opencode_corpus.line', return_value=dict(identity='source',rows=[],peakRSSBytes=memory)):
                with self.assertRaisesRegex(RuntimeError, 'worker_peak_invalid_or_over_budget'):
                    opencode_audit_session(Mock(), Mock(), 's')

    def test_history_oracle_rejects_wrong_database_before_scan(self):
        with closing(sqlite3.connect(':memory:')) as database:
            with self.assertRaisesRegex(RuntimeError, 'expected_thread_history_database'):
                validate_history_reference(database)
            database.execute('CREATE TABLE thread_items(thread_id,turn_id,item_id,rollout_ordinal,updated_at_ordinal)')
            database.execute('CREATE TABLE thread_history_projection_state(thread_id,next_rollout_ordinal)')
            validate_history_reference(database)

    def test_history_oracle_accounts_for_unemitted_legacy_records_without_claiming_comparison(self):
        base = dict(complete=True, indexBytes=1024, peakRSSBytes=4096, bytesRead=100)
        validate_history_completion(dict(base, paginated=False, records=8), 0)
        validate_history_completion(dict(base, paginated=True, records=8), 8)
        for row, emitted in [(dict(base, paginated=True, records=8), 0), (dict(base, paginated=False, records=8), 8)]:
            with self.assertRaisesRegex(RuntimeError, 'record_count_mismatch'):
                validate_history_completion(row, emitted)
        for row in [dict(records=0), dict(paginated=True, records=True), dict(paginated=True, records=-1)]:
            with self.assertRaisesRegex(RuntimeError, 'invalid_completion'):
                validate_history_completion(row, 0)

    def test_history_oracle_rejects_forged_completion_and_resource_evidence(self):
        base = dict(complete=True, paginated=True, records=1, indexBytes=1024, peakRSSBytes=4096, bytesRead=100)
        for key, values in [('complete', ('yes', 1, False, None)),
                            ('peakRSSBytes', (None, 0, True, -1, 257 * 1024 * 1024)),
                            ('indexBytes', (None, -1, True, 9 * 1024 * 1024)),
                            ('bytesRead', (None, -1, True, '100'))]:
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(RuntimeError):
                    validate_history_completion(dict(base, **{key:value}), 1)

    def test_finite_worker_lifetime_peak_closes_unsampled_exit_gap(self):
        monitor = SimpleNamespace(peak=0, failure='rss_guard_incomplete', thread=Mock())
        monitor.thread.is_alive.return_value = False
        self.assertEqual(worker_memory(4096, monitor), 4096)
        monitor.peak = 8192; monitor.failure = None
        self.assertEqual(worker_memory(4096, monitor), 8192)
        self.assertEqual(worker_memory(16384, monitor), 16384)

    def test_finite_worker_memory_evidence_fails_closed(self):
        monitor = SimpleNamespace(peak=0, failure=None, thread=Mock())
        monitor.thread.is_alive.return_value = False
        for value in (None, 0, -1, True, '4096', 4096.0):
            with self.subTest(value=value), self.assertRaisesRegex(RuntimeError, 'EvidenceInvalid'):
                worker_memory(value, monitor)
        with self.assertRaisesRegex(RuntimeError, 'BudgetExceeded'):
            worker_memory(256 * 1024 * 1024 + 1, monitor)
        monitor.peak = 256 * 1024 * 1024 + 1
        with self.assertRaisesRegex(RuntimeError, 'BudgetExceeded'): worker_memory(4096, monitor)
        monitor.peak = 0; monitor.failure = 'process_snapshot_failed'
        with self.assertRaisesRegex(RuntimeError, 'process_snapshot_failed'): worker_memory(4096, monitor)
        monitor.failure = 'rss_guard_incomplete'; monitor.thread.is_alive.return_value = True
        with self.assertRaisesRegex(RuntimeError, 'MonitorStillRunning'): worker_memory(4096, monitor)

    def test_authority_header_oracle_is_prefix_bounded_and_identity_strict(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'snapshot.jsonl'
            header = dict(type='session_meta', payload=dict(id='thread', history_mode='paginated'))
            encoded = (json.dumps(header) + '\n').encode()
            with path.open('wb') as output:
                output.write(encoded); output.truncate(80 * 1024 * 1024)
            self.assertEqual(header_expectation(path, 'thread'), (True, 'paginated', len(encoded)))
            with self.assertRaisesRegex(ValueError, 'header_identity_mismatch'):
                header_expectation(path, 'other')
            path.write_bytes(b'{"type":"session_meta","payload":{"id":"thread","id":"thread"}}\n')
            with self.assertRaisesRegex(ValueError, 'duplicate_header_key'):
                header_expectation(path, 'thread')
            path.write_bytes(b'{"type":"session_meta"')
            with self.assertRaisesRegex(ValueError, 'incomplete_header'):
                header_expectation(path, 'thread')
            with path.open('ab') as output:
                output.truncate(MAXIMUM_HEADER + 1)
            with self.assertRaisesRegex(ValueError, 'header_budget'):
                header_expectation(path, 'thread')
            path.write_bytes(b'')
            self.assertEqual(header_expectation(path, 'thread'), (False, 'empty', 0))

    def test_scope_breakdown_keeps_non_session_failures_visible(self):
        candidates = [dict(provider='codex', bytes=1, path='/synthetic/codex.jsonl'),
            dict(provider='claude', bytes=2, path='/synthetic/projects/project/00000000-0000-0000-0000-000000000001.jsonl', source_root='/synthetic/projects'),
            dict(provider='claude', bytes=3, path='/synthetic/projects/project/workflow.jsonl', source_root='/synthetic/projects')]
        rows = [dict(ordinal=i, provider=c['provider'], file_bytes=c['bytes'], coverage_issues={'unknown': 7} if i == 2 else {}) for i,c in enumerate(candidates)]
        scopes = scope_summary(candidates, rows)
        self.assertEqual(scopes['session_layout']['files'], 2)
        self.assertEqual(scopes['session_layout']['coverage_failed_files'], 0)
        self.assertEqual(scopes['non_session_jsonl_layout']['coverage_issues'], {'unknown': 7})
        with self.assertRaisesRegex(RuntimeError, 'invalid_scope_ordinal'): scope_summary(candidates, rows + rows[:1])

    def test_upstream_extension_requires_exact_independent_native_revision(self):
        item = dict(owner='owner', turn='turn', itemID='id', ordinal=8, sourceTruncated=False,
                    coreItem=dict(type='SubAgentActivity', kind='completed'),
                    projection=dict(type='message', role='system', blocks=[]))
        with closing(sqlite3.connect(':memory:')) as database:
            database.execute('CREATE TABLE thread_items(thread_id TEXT, turn_id TEXT, item_id TEXT, updated_at_ordinal INTEGER, item_json TEXT)')
            self.assertEqual(native_extension(item, database, Mock()), 'extension_missing_native_reference')
            database.execute('INSERT INTO thread_items VALUES(?,?,?,?,?)', ('owner', 'turn', 'id', 7, '{}'))
            self.assertEqual(native_extension(item, database, Mock()), 'extension_reference_revision_mismatch')
            database.execute('UPDATE thread_items SET updated_at_ordinal=8')
            with patch('upstream_core_corpus.rpc', return_value=dict(disposition='message', record=item['projection'])):
                self.assertEqual(native_extension(item, database, Mock()), 'exact_native_schema_extension')
            with patch('upstream_core_corpus.rpc', return_value=dict(disposition='message', record=dict(type='message', role='system', blocks=[dict(type='text', text='changed')]))):
                self.assertEqual(native_extension(item, database, Mock()), 'extension_projection_difference')
            for core in (dict(type='FutureType'), dict(type='SubAgentActivity', kind='future'), dict(type='AgentMessage', questions=[])):
                self.assertIsNone(native_extension(dict(item, coreItem=core), database, Mock()))

    def test_oracle_errors_must_be_explicitly_allowed(self):
        for raw, allowed, expected in [(b'{"error":"upstreamCoreShape"}\n', True, {'error': 'upstreamCoreShape'}),
                                       (b'{"error":"upstreamCoreShape"}\n', False, None),
                                       (b'[]\n', True, None)]:
            process = SimpleNamespace(_projection_buffer=bytearray(raw))
            if expected is None:
                with self.assertRaisesRegex(RuntimeError, 'worker_error'):
                    completed_projection_line(process, allow_error=allowed)
            else:
                self.assertEqual(completed_projection_line(process, allow_error=allowed), expected)

    def test_completed_envelope_timestamp_absence_is_not_null(self):
        source = dict(type='event_msg', payload=dict(type='item_completed', thread_id='t', turn_id='u', item={}))
        self.assertEqual(source_shape_issues(source, 'codex'), {})
        self.assertEqual(source_shape_issues(dict(source, ordinal=None), 'codex'), {})
        for valid in (dict(started_at_ms=None), dict(completed_at_ms=0), dict(completed_at_ms=-(2**63))):
            self.assertEqual(source_shape_issues(dict(source, payload=dict(source['payload'], **valid)), 'codex'), {})
        for invalid in (dict(completed_at_ms=None), dict(completed_at_ms=True), dict(completed_at_ms=2**63)):
            self.assertTrue(source_shape_issues(dict(source, payload=dict(source['payload'], **invalid)), 'codex'))

    def test_ui_census_excludes_other_devices_and_test_runners(self):
        prefix = '/CoreSimulator/Devices/OWNED/data/Containers/Bundle/'
        rows = '\n'.join(['123 100 2:03.50 ' + prefix + 'Tessera.app/Tessera',
                          '456 999 9:00.00 ' + prefix + 'TesseraUITests-Runner.app/Runner',
                          '789 888 8:00.00 /CoreSimulator/Devices/OTHER/Tessera.app/Tessera'])
        self.assertEqual(ui_census(rows, 'OWNED'), {123: (102400, 123.5)})

    def test_codex_auxiliary_contract_does_not_hide_new_fields_or_boolean_numbers(self):
        source = dict(type='event_msg', payload=dict(type='task_started', turn_id='turn', model_context_window=None))
        self.assertEqual(source_shape_issues(source, 'codex'), {})
        for payload in [dict(source['payload'], started_at=True), dict(source['payload'], future_message={})]:
            self.assertTrue(source_shape_issues(dict(source, payload=payload), 'codex'))
        self.assertEqual(source_shape_issues(dict(type='world_state', payload=dict(full=True, state={'type': 'arbitrary'})), 'codex'), {})
        self.assertTrue(source_shape_issues(dict(type='world_state', payload=dict(full=True, state={}, extra={})), 'codex'))
        settings = dict(model='gpt-5', cwd='/x', model_provider_id='openai', approval_policy='on-request', approvals_reviewer='user',
                        permission_profile={}, collaboration_mode={}, runtime_workspace_roots=['/x'], disabled_plugin_ids=[])
        applied = dict(type='event_msg', payload=dict(type='thread_settings_applied', thread_id='t', thread_settings=settings))
        self.assertEqual(source_shape_issues(applied, 'codex'), {})
        self.assertEqual(source_shape_issues(dict(applied, payload=dict(applied['payload'], thread_settings=dict(settings, disabled_plugin_ids=None))), 'codex'), {})
        for shape in [dict(settings, runtime_workspace_roots='/x'), dict(settings, future_setting=[])]:
            self.assertTrue(source_shape_issues(dict(applied, payload=dict(applied['payload'], thread_settings=shape)), 'codex'))

    def test_command_equivalence_does_not_erase_shell_operators(self):
        for command in ('echo one; echo two', 'echo ;', 'echo $VALUE', 'echo "$(date)"', 'echo `date`', 'echo a\necho b', 'echo *', 'echo #comment', 'echo >out'):
            self.assertIsNone(command_argv(command))
        self.assertEqual(command_argv("echo 'one;' echo two"), ['echo', 'one;', 'echo', 'two'])
        self.assertEqual(command_argv("echo ';'"), ['echo', ';'])
        self.assertEqual(command_argv('echo "\\$VALUE"'), ['echo', '\\$VALUE'])

    def test_completed_projection_backpressure_and_partial_writes(self):
        public = SimpleNamespace(stdin=SimpleNamespace(fileno=lambda: 7))
        with patch('codex_completed_projection_corpus.os.set_blocking') as blocking, \
             patch('codex_completed_projection_corpus.time.monotonic', return_value=1), \
             patch('codex_completed_projection_corpus.select.select', return_value=([], [7], [])), \
             patch('codex_completed_projection_corpus.os.write', side_effect=[BlockingIOError(), 2, 1]) as write:
            write_frame(public, [b'abc'], 2)
            blocking.assert_called_once_with(7, False)
            self.assertEqual([bytes(call.args[1]) for call in write.call_args_list], [b'abc', b'abc', b'c'])
        with patch('codex_completed_projection_corpus.os.set_blocking'), \
             patch('codex_completed_projection_corpus.time.monotonic', return_value=2):
            with self.assertRaisesRegex(RuntimeError, 'public_worker_write_timeout'): write_frame(public, [b'a'], 2)

    def test_completed_projection_response_has_absolute_deadline(self):
        process = SimpleNamespace(stdout=SimpleNamespace(fileno=lambda: 7))
        with patch('codex_completed_projection_corpus.time.monotonic', side_effect=[1, 3]), \
             patch('codex_completed_projection_corpus.select.select', return_value=([7], [], [])), \
             patch('codex_completed_projection_corpus.os.read', return_value=b'{'):
            with self.assertRaisesRegex(RuntimeError, 'worker_timeout'): completed_projection_line(process, deadline=2)

    def test_completed_projection_equivalence_never_excuses_changed_blocks(self):
        a = dict(type='message', role='tool', blocks=[dict(type='tool_call', name='Command', preview="echo 'hello world'")])
        b = dict(a, blocks=[dict(a['blocks'][0], preview='echo "hello world"')])
        self.assertEqual(equivalent_projection(a, b), 'equivalent_command_argv')
        self.assertIsNone(equivalent_projection(a, dict(b, blocks=[dict(b['blocks'][0], preview='echo changed')])))
        self.assertIsNone(equivalent_projection(a, dict(b, blocks=[dict(b['blocks'][0], truncated=True)])))
        self.assertIsNone(equivalent_projection(a, dict(b, blocks=b['blocks'] + [dict(type='text', text='lost')])) )
        self.assertEqual(equivalent_projection(a, dict(a, truncated=True)), 'same_projection_different_envelope_budget')
        self.assertIsNone(equivalent_projection(a, dict(a, blocks=[], truncated=True)))

    def test_completed_projection_pipe_retains_prefetched_rows(self):
        reader, writer = os.pipe()
        try:
            os.write(writer, b'{"one":1}\n{"two":2}\n')
            with os.fdopen(reader, 'rb', buffering=0) as stream:
                process = SimpleNamespace(stdout=stream)
                self.assertEqual(completed_projection_line(process), {'one': 1})
                # The writer remains open with no more data. The second row
                # must come from the owned buffer without blocking on select.
                with patch('codex_completed_projection_corpus.select.select', side_effect=AssertionError('unnecessary wait')):
                    self.assertEqual(completed_projection_line(process), {'two': 2})
                process._projection_buffer = bytearray(b'x' * 16)
                with self.assertRaisesRegex(RuntimeError, 'worker_frame_budget'):
                    completed_projection_line(process, maximum=16)
        finally: os.close(writer)

    def test_completed_projection_missing_owner_reference_is_not_a_pass(self):
        projection = dict(type='message', provider='codex', role='assistant', blocks=[dict(type='text', text='fixture')])
        row = dict(disposition='message', record=dict(projection=projection, owner='owner', turn='turn', itemID='item', ordinal=5))
        database = Mock(); database.execute.return_value.fetchone.return_value = None
        self.assertEqual(completed_projection_compare(row, database, Mock()), 'missing_native_reference')
        self.assertEqual(database.execute.call_args.args[1], ('owner', 'turn', 'item'))
        row['record']['owner'] = ''
        self.assertEqual(completed_projection_compare(row, database, Mock()), 'source_identity_failure')

    def test_completed_projection_streams_unicode_sqlite_text_as_bytes(self):
        projection = dict(type='message', provider='codex', role='assistant', blocks=[dict(type='text', text='fixture')])
        row = dict(disposition='message', record=dict(projection=projection, owner='owner', turn='turn', itemID='item', ordinal=5))
        with closing(sqlite3.connect(':memory:')) as database:
            database.execute('CREATE TABLE thread_items(thread_id,turn_id,item_id,item_json,updated_at_ordinal)')
            raw = json.dumps(dict(type='agentMessage', text='😀' * 20), ensure_ascii=False)
            database.execute('INSERT INTO thread_items VALUES(?,?,?,?,?)', ('owner', 'turn', 'item', raw, 5))
            public = SimpleNamespace(stdin=io.BytesIO())
            def capture(_process, chunks, _deadline):
                for chunk in chunks: public.stdin.write(chunk)
            with patch('codex_completed_projection_corpus.line', return_value=dict(disposition='message', record=projection)), \
                 patch('codex_completed_projection_corpus.write_frame', side_effect=capture):
                self.assertEqual(completed_projection_compare(row, database, public), 'exact_projection')
            length, body = public.stdin.getvalue().split(b'\n', 1)
            self.assertEqual(int(length), len(body))
            self.assertEqual(json.loads(body)['item']['text'], '😀' * 20)
            # Guard is byte-based and evaluated before opening the raw blob.
            fake = Mock(); fake.execute.return_value.fetchone.return_value = (1, 5, 32 * 1024 * 1024)
            self.assertEqual(completed_projection_compare(row, fake, public), 'native_reference_budget')
            fake.blobopen.assert_not_called()

    def test_ignored_reason_requires_known_string_and_consistent_scope(self):
        row = dict(disposition='ignored', sourceType='last-prompt', visible=False,
                   record=dict(type='system', provider='claude', ignoreReason='claude-sdk-non-message/last-prompt'))
        self.assertEqual(coverage(row), {})
        for reason in (42, True, [], 'future-reason', 'claude-sdk-non-message/atis-latch'):
            self.assertIn('ignored_invalid_reason', coverage(dict(row, record=dict(row['record'], ignoreReason=reason))))
        for changes in (dict(provider='codex'), dict(type='message')):
            self.assertIn('ignored_invalid_scope', coverage(dict(row, record=dict(row['record'], **changes))))
        self.assertIn('ignored_invalid_scope', coverage(dict(row, visible=True)))
        self.assertIn('ignored_invalid_reason', coverage(dict(row, sourceType='future-type')))

    def test_bookkeeping_ignores_are_shape_checked_independently(self):
        source = dict(type='last-prompt', leafUuid='fixture', sessionId='session')
        self.assertEqual(source_shape_issues(source, 'claude'), {})
        self.assertEqual(source_shape_issues({**source, 'message': {}}, 'claude'), {'source_unknown_bookkeeping_field': 1})
        self.assertEqual(source_shape_issues({**source, 'lastPrompt': []}, 'claude'), {'source_invalid_bookkeeping_field': 1})
        del source['leafUuid']
        self.assertEqual(source_shape_issues(source, 'claude'), {'source_missing_bookkeeping_field': 1})
    def test_cold_fixture_layout_preserves_nested_subagents_and_accounts_for_sidecars(self):
        session = '00000000-0000-0000-0000-000000000001'
        for suffix, expected in [(session + '.jsonl', 'main_session'),
                (session + '/subagents/workflows/run/agent-fixture.jsonl', 'subagent_session'),
                (session + '/subagents/workflows/run/results.jsonl', 'non_session_jsonl')]:
            relative = claude_relative('/private/provider/projects/project/' + suffix, '/private/provider/projects')
            self.assertEqual(str(relative), 'project/' + suffix)
            self.assertEqual(claude_layout(relative), expected)
        nested = Path('project/' + session + '/subagents/workflows/projects/run/agent-.jsonl')
        self.assertEqual(claude_relative(Path('/private/provider/projects') / nested, '/private/provider/projects'), nested)
        self.assertEqual(claude_layout(nested), 'subagent_session')
        sidecar = dict(provider='claude', path='/private/provider/projects/project/results.jsonl', bytes=999999999)
        self.assertFalse(candidate_is_session(sidecar, '/private/provider/projects'))
        with self.assertRaises(ValueError): claude_relative('/private/elsewhere/file.jsonl', '/private/provider/projects')

    def test_annotation_shape_audit_does_not_trust_native_filtering(self):
        source = dict(type='response_item', payload=dict(type='message', role='user',
            content=[dict(type='input_text', text='injected'), dict(type='input_text', text='human')],
            internal_chat_message_metadata_passthrough=dict(content_item_kinds=['user.text'])))
        self.assertEqual(source_shape_issues(source, 'codex'), {'source_invalid_content_item_kinds': 1})
        source['payload']['internal_chat_message_metadata_passthrough']['content_item_kinds'] = ['context', 'user.text']
        self.assertEqual(source_shape_issues(source, 'codex'), {})
        for container in ('invalid', [], 42):
            source['payload']['internal_chat_message_metadata_passthrough'] = container
            self.assertEqual(source_shape_issues(source, 'codex'), {'source_invalid_annotation_container': 1})

    def test_independent_event_text_oracle_detects_fragment_loss(self):
        source = dict(type='response_item', payload=dict(role='user', content=[
            dict(type='input_text', text='one '), dict(type='input_text', text='two')]))
        def outcome(text, truncated=False, block_truncated=False):
            return event_text_candidate(source, dict(type='message', role='user', truncated=truncated,
                blocks=[dict(type='text', text=text, truncated=block_truncated)]))[1]
        self.assertEqual(outcome('one two'), 'exact_native_text')
        self.assertEqual(outcome('two'), 'native_text_failure')
        self.assertEqual(outcome('one '), 'native_text_failure')
        self.assertEqual(outcome('one ', True), 'native_text_failure')
        self.assertEqual(outcome('one ', True, True), 'explicit_bounded_prefix')
        self.assertEqual(outcome('', True, True), 'native_text_failure')

    def test_event_oracle_matches_display_controls_not_ids(self):
        self.assertEqual(event_text_display('a\x01\u202eb\n\tc\u2066'), 'ab\n\tc')
        source = dict(type='response_item', payload=dict(role='user', content=[dict(type='input_text', text='hello')]))
        value = dict(type='message', role='system', blocks=[dict(type='text', text='hello')])
        self.assertEqual(event_text_candidate(source, value)[1], 'native_classification_failure')
        self.assertIsNone(event_text_candidate(dict(type='response_item', payload=None), value))

    def test_file_success_does_not_make_the_headline_a_pass(self):
        report = dict(files=2, expected_files=2, failed_files=0, coverage_failed_files=1, counts={},
                      resource_failed_files=0, memory_measured_files=2)
        self.assertEqual(gate_status(report), 'failed_coverage')
        report['coverage_failed_files'] = 0
        report['counts'] = {'block_count_mismatch': 1}
        self.assertEqual(gate_status(report), 'failed_payload_comparison')
        report['counts'] = {}
        report['metadata_counts'] = {'max_tokens': {'added': 1}}
        self.assertEqual(gate_status(report), 'failed_metadata_comparison')
        report['metadata_counts'] = {}
        self.assertEqual(gate_status(report), 'passed_scoped_checks')
        report['memory_measured_files'] = 1
        self.assertEqual(gate_status(report), 'failed_resources')
        report['memory_measured_files'] = 2; report['resource_failed_files'] = 1
        self.assertEqual(gate_status(report), 'failed_resources')
        del report['resource_failed_files']
        self.assertEqual(gate_status(report), 'failed_resources')
        report['files'] = 1
        self.assertEqual(gate_status(report), 'incomplete')
        report['files'] = report['expected_files'] = 0
        self.assertEqual(gate_status(report), 'empty_corpus')
    def test_inventory_does_not_retain_recursive_closure_per_record(self):
        gc.collect(); enabled = gc.isenabled(); gc.disable()
        try:
            count = lambda: sum(isinstance(value, types.FunctionType) and value.__name__ == 'content' for value in gc.get_objects())
            before = count()
            for _ in range(200):
                input_coverage('{"type":"assistant","message":{"content":[{"type":"text","text":"synthetic"}]}}', 'claude')
                input_coverage('{"type":"response_item","payload":null}', 'codex')
            self.assertEqual(count(), before)
        finally:
            if enabled: gc.enable()

    def test_bom_does_not_change_legacy_decode_semantics(self):
        source = Path(__file__).resolve().parents[3] / 'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift'
        reference, _ = projector(source)
        raw = b'\xef\xbb\xbf{"type":"user","message":{"content":"synthetic"}}\n'
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'bom.jsonl'; path.write_bytes(raw)
            actual = next(reference_records(path, 'claude', reference))
            self.assertTrue(actual['record']['malformed'])
            self.assertEqual(actual['input_issues'], {'input_malformed_json': 1})
            self.assertTrue(reference['normalized']('claude', raw, False)['malformed'])

    def test_reasoning_text_alias_cannot_hide_unknown_content(self):
        raw = json.dumps({'type': 'response_item', 'payload': {'type': 'reasoning',
            'text': {'type': 'future_reasoning', 'text': 'synthetic'}}})
        self.assertIn('flattened_content/future_reasoning', input_coverage(raw, 'codex')[1])
    def test_output_schema_does_not_trust_a_known_disposition(self):
        self.assertEqual(output_issues({'type': 'system', 'text': 42}), {'output_invalid_field/text': 1})
        self.assertEqual(output_issues({'type': 'future_metadata'}), {'output_unknown_record_type': 1})
        record = dict(type='message', role='assistant', blocks=[dict(type='text', text={'unexpected': 'object'})])
        self.assertEqual(output_issues(record), {'output_invalid_block_field/text': 1})
        self.assertEqual(output_issues(dict(type='cost-state', used_tokens=True)), {'output_invalid_number/used_tokens': 1})
        self.assertEqual(output_issues(dict(type='message', role='assistant', blocks=[dict(type='text', text='valid')])), {})

    def test_source_schema_rejects_recursive_text_wrapper(self):
        source = dict(type='user', message=dict(content=[dict(type='tool_result', content={
            'type': 'text', 'content': {'type': 'future_content', 'text': 'must not flatten'}})]))
        self.assertEqual(source_shape_issues(source, 'claude'), {'source_invalid_text_field': 1})
        source['message']['content'][0] = dict(type='tool_result', content=None, output=dict(type='text', text=42))
        self.assertEqual(source_shape_issues(source, 'claude'), {'source_invalid_text_field': 1})

    def test_null_message_and_malformed_roles_are_not_optional_metadata(self):
        self.assertEqual(source_shape_issues(dict(type='assistant', message=dict(content=None)), 'claude'),
                         {'source_missing_message_content': 1})
        self.assertEqual(source_shape_issues(dict(type='user', message=dict(role=42, content='synthetic')), 'claude'),
                         {'source_invalid_role_shape': 1})

    def test_input_audit_sees_nested_content_before_flattening(self):
        raw = json.dumps({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'content': [
            {'type': 'text', 'text': 'visible'}, {'type': 'future_content', 'text': 'must not flatten away'}]}]}})
        shapes, issues = input_coverage(raw, 'claude')
        self.assertEqual(issues, {'flattened_content/future_content': 1})
        self.assertEqual(shapes['tool-result/text'], 1)
        raw = json.dumps({'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'input': {'type': 'arbitrary-user-data'}}]}})
        self.assertEqual(input_coverage(raw, 'claude')[1], {})
        self.assertEqual(input_coverage('[]', 'claude')[1], {'input_non_object': 1})
        self.assertEqual(input_coverage('{', 'claude')[1], {'input_malformed_json': 1})

    def test_evicted_unknowns_still_fail_coverage(self):
        self.assertEqual(coverage(dict(disposition='message', record=dict(type='message', role='assistant',
            blocks=[dict(type='text', text='retained')], unparsedContentCount=4))),
            {'unparsed_content_including_evicted_blocks': 4})

    def test_shared_unknown_is_not_a_coverage_pass(self):
        record = dict(type='unknown')
        self.assertEqual(compare(record, record), 'metadata_not_compared')
        self.assertEqual(coverage(dict(record=record, disposition='unclassified')),
                         {'output_unknown_record_type': 1, 'disposition/unclassified': 1, 'unknown_record_type': 1})

    def test_generic_placeholder_and_swallowed_malformed_fail_independently(self):
        row = dict(disposition='unclassified', record=dict(type='message', role='assistant',
                   blocks=[dict(type='text', text='Unsupported Codex item: future')]))
        self.assertIn('disposition/unclassified', coverage(row))
        self.assertIn('malformed_record', coverage(dict(disposition='message', record=dict(type='message', malformed=True))))
        self.assertIn('ignored_without_reason', coverage(dict(disposition='ignored', record=dict(type='status'))))

    def test_unknown_blocks_and_missing_driver_accounting_fail(self):
        row = dict(disposition='message', record=dict(type='message', blocks=[dict(type='unknown', sourceType='future')]))
        row['record']['role'] = 'assistant'
        self.assertEqual(coverage(row), {'output_unknown_block_type': 1, 'unknown_block/future': 1})
        self.assertTrue(coverage(dict(record=dict(type='message'))))
        row['record']['blocks'] = [dict(type='attachment', name='Image', mediaType='image')]
        self.assertEqual(coverage(row), {})

    def test_metadata_gate_reports_identity_loss_and_scopes_child_fields(self):
        expected = dict(model='fixture-model', timestamp='fixture-time', turnID='fixture-turn', used_tokens=42)
        actual = dict(expected)
        self.assertEqual(set(compare_metadata(expected, actual).values()), {'exact'})
        actual.pop('turnID')
        self.assertEqual(compare_metadata(expected, actual)['turnID'], 'missing')
        child = dict(isSidechain=True, timestamp='fixture-time', turnID='fixture-turn')
        self.assertEqual(compare_metadata(expected, child)['model'], 'child_scope_filtered')
        self.assertEqual(compare_metadata(expected, child)['used_tokens'], 'child_scope_filtered')
        self.assertEqual(compare_metadata(expected, dict(child, timestamp='changed'))['timestamp'], 'mismatch')
        self.assertEqual(compare_metadata({}, dict(model='new'))['model'], 'added')

    def test_startup_connect_retries_bind_listen_gap_but_not_permissions(self):
        process = Mock(); process.poll.return_value = None
        connection = Mock()
        connection.connect.side_effect = [FileNotFoundError(errno.ENOENT, 'not bound'),
                                          ConnectionRefusedError(errno.ECONNREFUSED, 'not listening'), None]
        with patch('native_first_page.socket.socket', return_value=connection), \
                patch('native_first_page.now_ns', return_value=1), patch('native_first_page.time.sleep'):
            self.assertIs(connect_started_service(process, '/synthetic/socket', 0), connection)
            self.assertEqual(connection.connect.call_count, 3)
            connection.close.assert_not_called()
            connection.connect.side_effect = PermissionError(errno.EACCES, 'not authorized')
            with self.assertRaises(PermissionError): connect_started_service(process, '/synthetic/socket', 0)
            connection.close.assert_called_once()

    def test_both_trial_setups_seed_native_store_before_clock_and_launch(self):
        class SetupComplete(Exception):
            pass
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            candidates = [dict(provider=provider, path=str(root / (provider + '.jsonl')),
                               original_path=str(root / (provider + '.jsonl')) if provider == 'codex' else
                               str(root / 'claude/projects/project/00000000-0000-0000-0000-000000000001.jsonl'))
                          for provider in ('codex', 'claude')]
            args = SimpleNamespace(output=root, known_locator=False, candidates=candidates,
                                   claude_projects_root=root / 'claude/projects',
                                   native_store=root / 'snapshot', binary=root / 'helper')
            for candidate in candidates:
                events = []
                def seed(*arguments): events.append('seed')
                def clock(): events.append('clock'); raise SetupComplete()
                with patch('native_first_page.clone'), patch('native_first_page.seed_native_store', side_effect=seed) as seeded, \
                        patch('native_first_page.now_ns', side_effect=clock), patch('native_first_page.subprocess.Popen') as launched:
                    with self.assertRaises(SetupComplete): trial(args, candidate, 0)
                    self.assertEqual(events, ['seed', 'clock'])
                    self.assertEqual(seeded.call_args.args[0], args.native_store)
                    launched.assert_not_called()

    def test_native_store_is_provider_independent_and_only_mutates_copies(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            snapshot = root / 'snapshot'
            snapshot.mkdir()
            with closing(sqlite3.connect(snapshot / 'state_5.sqlite')) as state, state:
                state.executescript("CREATE TABLE threads(id TEXT, rollout_path TEXT);"
                                    "INSERT INTO threads VALUES('fixture', '/original/transcript');"
                                    "CREATE TABLE remote_control_enrollments(id TEXT);"
                                    "INSERT INTO remote_control_enrollments VALUES('must-not-activate');")
            with closing(sqlite3.connect(snapshot / 'thread_history_1.sqlite')) as history, history:
                history.execute('CREATE TABLE fixture(id TEXT)')
            def copy(source, target):
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
            with patch('native_first_page.clone', side_effect=copy):
                for selected in ('codex', 'claude'):
                    destination = root / selected / 'codex'
                    seed_native_store(snapshot, destination, {'fixture': '/copied/transcript'})
                    with closing(sqlite3.connect(destination / 'state_5.sqlite')) as state:
                        self.assertEqual(state.execute('SELECT rollout_path FROM threads').fetchone()[0], '/copied/transcript')
                        self.assertEqual(state.execute('SELECT COUNT(*) FROM remote_control_enrollments').fetchone()[0], 0)
            with closing(sqlite3.connect(snapshot / 'state_5.sqlite')) as state:
                self.assertEqual(state.execute('SELECT rollout_path FROM threads').fetchone()[0], '/original/transcript')
                self.assertEqual(state.execute('SELECT COUNT(*) FROM remote_control_enrollments').fetchone()[0], 1)

    def message(self, text, **fields):
        return dict(type='message', role='assistant', blocks=[dict(type='text', text=text, **fields)])

    def test_equal_and_explicit_bounded_prefix(self):
        self.assertEqual(compare(self.message('text', truncated=False), self.message('text')), 'exact_visible_payload')
        self.assertEqual(compare(self.message('larger text'), self.message('larger', truncated=True)), 'bounded_prefix')
        self.assertEqual(compare(self.message('larger text'), self.message('larger')), 'block_content_mismatch')

    def test_role_drop_and_content_change_fail(self):
        source = self.message('text')
        self.assertEqual(compare(source, dict(source, role='user')), 'role_mismatch')
        self.assertEqual(compare(source, dict(source, blocks=[])), 'block_count_mismatch')
        self.assertEqual(compare(source, self.message('different')), 'block_content_mismatch')
        self.assertEqual(compare(source, dict(type='unknown')), 'message_classification_mismatch')

    def test_reference_limit_is_not_a_pass(self):
        self.assertEqual(compare(dict(type='unknown', malformed=True), self.message('text')), 'reference_incomplete')

    def test_metadata_explicitly_not_claimed(self):
        self.assertEqual(compare(dict(type='cost-state', total=1), dict(type='unknown')), 'metadata_not_compared')

    def test_untrusted_type_never_enters_content_free_report(self):
        self.assertTrue(safe_type('private user text').startswith('opaque-type-'))
        self.assertEqual(safe_type('response_item/message'), 'response_item/message')

    def test_reference_title_lookup_is_disabled(self):
        source = Path(__file__).resolve().parents[3] / 'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift'
        reference, digest = projector(source)
        self.assertEqual(len(digest), 64)
        self.assertIsNone(reference['codex_title']('not-a-real-thread'))

    def test_predecoded_reference_preserves_legacy_semantics(self):
        source = Path(__file__).resolve().parents[3] / 'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift'
        reference, _ = projector(source)
        for provider in ('claude', 'codex'):
            for value in (None, [], {}, {'type': 'future'},
                          {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'synthetic'}]}},
                          {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'synthetic'}]}},
                          {'type': 'session_meta', 'payload': {'model': 'fixture', 'isSidechain': True}}):
                raw = json.dumps(value).encode()
                self.assertEqual(reference['normalized'](provider, raw, False), reference['normalized_source'](provider, json.loads(raw), False))

    def test_null_content_alias_is_audited_like_the_native_reader(self):
        raw = json.dumps(dict(type='user', message=dict(content=[dict(type='tool_result', content=None,
            output={'type': 'future_content', 'text': 'synthetic'})])))
        self.assertIn('flattened_content/future_content', input_coverage(raw, 'claude')[1])

    def test_full_reference_reads_past_legacy_prefix_and_defers_tail(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'source.jsonl'
            raw = json.dumps({'padding': 'x' * 100000, 'text': 'after prefix'}).encode() + b'\n'
            path.write_bytes(raw + b'{"unfinished":true}')
            reference = {'normalized': lambda provider, data, cut: self.message(json.loads(data)['text'])}
            rows = list(reference_records(path, 'codex', reference))
            self.assertEqual(rows[0]['record']['blocks'][0]['text'], 'after prefix')
            self.assertEqual(rows[0]['end'], len(raw))
            self.assertEqual(rows[1], dict(complete=True, sourceEnd=len(raw)))

    def test_reference_record_budget_is_explicit(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'source.jsonl'; path.write_bytes(b'x' * 33 + b'\n')
            with self.assertRaisesRegex(RuntimeError, 'referenceRecordBudget'):
                list(reference_records(path, 'codex', {}, limit=32))

    def test_memory_guard_retries_snapshot_exit_race_but_not_persistent_missing_rss(self):
        guard = Guard.__new__(Guard)
        guard.process = Mock(pid=123); guard.process.poll.return_value = None
        guard.finished = Mock(); guard.finished.is_set.side_effect = [False, False, False, True]
        guard.failure = None; guard.samples = 0; guard.peak = 0
        guard.sampled_services = set()
        guard.members = {123: 123}; guard.groups = {123: {123}}; guard.roots = {123: 123}
        guard.detached = None; guard.lock = threading.Lock()
        with patch('native_first_page.subprocess.run', side_effect=[
                Mock(returncode=0, stdout=b''), Mock(returncode=0, stdout=b''),
                Mock(returncode=0, stdout=b'123 1 2048\n')]), patch('native_first_page.os.getsid', return_value=1):
            guard.sample_loop()
        self.assertEqual(guard.samples, 1)
        self.assertEqual(guard.peak, 2 * 1024 * 1024)
        guard.finished.is_set.side_effect = None; guard.finished.is_set.return_value = False
        with patch('native_first_page.subprocess.run', return_value=Mock(returncode=0, stdout=b'')), patch('native_first_page.os.getsid', return_value=1):
            with self.assertRaisesRegex(RuntimeError, 'empty RSS sample'): guard.sample_loop()

    def test_memory_guard_cleanup_preserves_original_failure(self):
        guard = Guard.__new__(Guard); guard.finished = Mock(); guard.thread = Mock()
        guard.thread.is_alive.return_value = False; guard.samples = 0; guard.failure = 'rss_guard_failed'
        guard.detached = None
        guard.close()
        self.assertEqual(guard.failure, 'rss_guard_failed')

    def test_detached_census_requires_exact_private_command_and_uid(self):
        binary = '/private/fixture/measured-binary'; root = '/private/fixture/trial/r'
        command = f'{binary} serve --runtime {root}/0123456789abcdef --idle-ms 100'
        for uid, argv, valid in [(os.geteuid(), command, True), (os.geteuid() + 1, command, False),
                (os.geteuid(), command + ' --other', False), (os.geteuid(), command.replace('/trial/', '/sibling/'), False)]:
            with self.subTest(valid=valid, uid=uid), patch('native_first_page.subprocess.run', side_effect=[
                    Mock(returncode=0, stdout=b'42\n'), Mock(returncode=0, stdout=f'{uid} {argv}'.encode())]), \
                    patch('native_first_page.os.getsid', return_value=40):
                if valid: self.assertEqual(owned_services(binary, root), {42: 40})
                else:
                    with self.assertRaisesRegex(RuntimeError, 'ownership mismatch'): owned_services(binary, root)

    def test_relay_cleanup_does_not_skip_context_after_census_failure(self):
        process = Mock(pid=123); process.poll.return_value = 0
        context = Mock(); context.poll.return_value = None
        guard = Mock(); guard.discover.side_effect = RuntimeError('synthetic census failure')
        with patch('native_first_page.owned_services', side_effect=RuntimeError('synthetic census failure')):
            with self.assertRaisesRegex(RuntimeError, 'trial cleanup failed'):
                cleanup_trial(process, guard, Mock(), context, ('private-binary', 'private-runtime'))
        context.terminate.assert_called_once(); context.wait.assert_called_once(); context.stdout.close.assert_called_once()
        process.wait.assert_called_once(); guard.close.assert_called_once()

    def test_exit_census_does_not_adopt_zombie_or_recycled_pid(self):
        for uid, command in [(os.geteuid(), '(measured-binary)'), (os.geteuid() + 1, 'unrelated'),
                             (os.geteuid(), 'unrelated')]:
            with patch('native_first_page.subprocess.run', side_effect=[
                    Mock(returncode=0, stdout=b'42\n'), Mock(returncode=0, stdout=f'{uid} {command}'.encode())]), \
                    patch('native_first_page.os.getsid') as session, patch('native_first_page.os.kill') as kill:
                self.assertEqual(owned_services('binary', 'runtime', exiting=True), {})
            session.assert_not_called(); kill.assert_not_called()

    def test_cleanup_preserves_only_fixed_local_failure_reasons(self):
        process = Mock(); process.poll.return_value = 0
        with patch('native_first_page.owned_services', side_effect=RuntimeError('service ownership census unavailable')):
            with self.assertRaisesRegex(RuntimeError, 'detached_service:service ownership census unavailable'):
                cleanup_trial(process, None, None, None, ('binary', 'runtime'))
        with patch('native_first_page.owned_services', side_effect=RuntimeError('private arbitrary data')):
            with self.assertRaisesRegex(RuntimeError, 'detached_service:RuntimeError') as error:
                cleanup_trial(process, None, None, None, ('binary', 'runtime'))
            self.assertNotIn('private arbitrary data', str(error.exception))

    def test_context_readiness_exception_reaps_owned_child(self):
        context = Mock(); context.poll.return_value = None
        with patch('native_first_page.subprocess.Popen', return_value=context), \
                patch('native_first_page.select.select', side_effect=OSError('readiness failed')):
            with self.assertRaisesRegex(OSError, 'readiness failed'): start_context({})
        context.terminate.assert_called_once(); context.wait.assert_called_once(); context.stdout.close.assert_called_once()

    def test_detached_census_never_authorizes_a_signal(self):
        guard = Guard.__new__(Guard); guard.detached = ('binary', 'runtime')
        with patch('native_first_page.os.killpg') as groups, patch('native_first_page.os.kill') as pids:
            guard.signal_owned(signal.SIGKILL)
        groups.assert_not_called(); pids.assert_not_called()

    def test_relay_only_rss_cannot_pass_helper_coverage(self):
        guard = Guard.__new__(Guard); guard.finished = Mock(); guard.thread = Mock()
        guard.thread.is_alive.return_value = False; guard.samples = 1; guard.failure = None
        guard.detached = ('binary', 'runtime'); guard.required_service = 42; guard.sampled_services = {123}
        guard.close()
        self.assertEqual(guard.failure, 'rss_service_not_sampled')

    def test_detached_memory_failure_closes_stream_without_signaling_pids(self):
        guard = Guard.__new__(Guard); guard.detached = ('binary', 'runtime')
        guard.process = Mock(); guard.process.stdin.closed = False
        with patch('native_first_page.os.killpg') as groups, patch('native_first_page.os.kill') as pids:
            guard.abort()
        guard.process.stdin.close.assert_called_once()
        groups.assert_not_called(); pids.assert_not_called()

    def test_final_helper_sample_enforces_budget(self):
        guard = Guard.__new__(Guard); guard.close = Mock(); guard.detached = ('binary', 'runtime')
        guard.required_service = 42; guard.process = Mock(pid=123); guard.peak = 8192; guard.samples = 1
        guard.failure = None
        with patch('native_first_page.owned_services', return_value={42: 40}), \
                patch('native_first_page.subprocess.run', return_value=Mock(returncode=0, stdout=b'123 1 8192\n42 1 524288\n')):
            guard.final_service_sample()
        self.assertEqual(guard.failure, 'process_tree_memory_budget')
        self.assertEqual(guard.peak, (8192 + 524288) * 1024)


if __name__ == '__main__': unittest.main()
