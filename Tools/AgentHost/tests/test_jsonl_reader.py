"""Bounded native reader and historical semantics, synthetic fixtures only."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tjr-')
        self.path = Path(self.temporary.name) / 'session.jsonl'

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, values):
        self.path.write_text(''.join(json.dumps(value, ensure_ascii=False) + '\n' for value in values))

    def read(self, provider='claude', *arguments):
        process = subprocess.run([BINARY, 'jsonl', '--provider', provider, '--path', str(self.path), *arguments],
                                 capture_output=True, timeout=5)
        self.assertEqual(process.stderr, b'')
        self.assertEqual(process.returncode, 0, process.stdout)
        result = json.loads(process.stdout)
        self.assertLess(len(process.stdout), 262144)
        return result

    def test_claude_usage_survives_public_bounded_message_projection(self):
        # Usage after an oversized content string must survive streaming cuts.
        for length in [5, 2 * 1024 * 1024]:
            for usage, expected in [
                (dict(input_tokens=100, cache_creation_input_tokens=200,
                      cache_read_input_tokens=300, output_tokens=40), 640),
                (dict(input_tokens=100, output_tokens=40), 140),
            ]:
                self.write([dict(type='assistant', uuid='usage-main',
                    message=dict(role='assistant', content='x' * length, usage=usage))])
                record = self.read()['records'][0]['record']
                self.assertEqual(record['type'], 'message')
                self.assertEqual(record['used_tokens'], expected)
                self.assertNotIn('max_tokens', record)

    def test_backward_pages_are_exclusive_and_stable(self):
        self.write([{'type': 'user', 'uuid': str(n), 'message': {'content': str(n)}} for n in range(250)])
        latest = self.read('claude', '--limit', '100')
        self.assertEqual(len(latest['records']), 100)
        self.assertEqual(latest['records'][0]['providerRecordID'], '150')
        older = self.read('claude', '--before', str(latest['olderPosition']))
        self.assertEqual(older['records'][-1]['providerRecordID'], '149')
        self.assertEqual(older['livePosition'], latest['livePosition'])
        self.assertFalse({r['recordID'] for r in latest['records']} & {r['recordID'] for r in older['records']})

    def test_io_slice_returns_admitted_records_and_preserves_continuation(self):
        # Small visible projections can span much more than one I/O slice.
        # Build this synthetic file incrementally, not as one giant test DOM.
        with self.path.open('w') as stream:
            for index in range(20):
                stream.write(json.dumps(dict(type='user', uuid=str(index), message=dict(content=str(index)),
                    opaque='x' * (2 * 1024 * 1024))) + '\n')
        seen = []; before = None
        while True:
            page = self.read('claude', *([] if before is None else ['--before', str(before)]))
            self.assertGreater(len(page['records']), 0)
            self.assertLessEqual(page['bytesRead'], 64 * 1024 * 1024)
            seen[:0] = [int(row['providerRecordID']) for row in page['records']]
            if not page['hasOlder']: break
            self.assertLess(len(page['records']), 20)
            next_before = page['olderPosition']
            if before is not None: self.assertLess(next_before, before)
            before = next_before
        self.assertEqual(seen, list(range(20)))

    def test_claude_message_model_precedes_envelope_fallback(self):
        self.write([{'type': 'assistant', 'model': 'envelope-model', 'uuid': 'fixture',
                     'message': {'model': 'message-model', 'content': 'synthetic'}}])
        self.assertEqual(self.read()['records'][0]['record']['model'], 'message-model')

    def test_forward_large_records_are_read_once_not_scanned_then_reread(self):
        with self.path.open('w') as stream:
            for index in range(20):
                stream.write(json.dumps(dict(type='user', uuid=str(index), message=dict(content=str(index)),
                    opaque='x' * (2 * 1024 * 1024))) + '\n')
        page = self.read('claude', '--after', '0')
        self.assertEqual([row['providerRecordID'] for row in page['records']], [str(index) for index in range(20)])
        self.assertFalse(page['hasNewer'])
        self.assertLessEqual(page['bytesRead'], self.path.stat().st_size + 2 * 65536)

    def test_forward_stream_promotion_matches_known_record_decoding(self):
        for length in (65535, 65536, 1048400, 1048575, 1048576, 1048700, 2097152):
            with self.subTest(length=length):
                self.write([dict(type='user', uuid='before', message=dict(content='before')),
                    dict(type='user', uuid='large', opaque='x' * length,
                         message=dict(content='café 😀 after the opaque field')),
                    dict(type='assistant', uuid='after', message=dict(content='after'))])
                backward = self.read('claude')['records']
                forward = self.read('claude', '--after', '0')['records']
                self.assertEqual(forward, backward)
        self.path.write_bytes(b'\n{"type":"user","message":{"content":"bad\njson"}}\n')
        self.assertEqual(self.read('claude', '--after', '0')['records'], self.read('claude')['records'])

    def test_codex_token_count_preserves_model_metadata(self):
        self.write([{'type': 'event_msg', 'payload': {'type': 'token_count', 'info': {
            'model': 'fixture-model', 'model_context_window': 1000,
            'last_token_usage': {'input_tokens': 200, 'output_tokens': 30}}}}])
        record = self.read('codex')['records'][0]['record']
        self.assertEqual(record.get('model'), 'fixture-model')
        self.assertEqual(record['used_tokens'], 230)

    def test_codex_input_fragments_coalesce_before_the_block_budget(self):
        parts = [f'fragment-{index} ' for index in range(150)]
        self.write([{'type': 'response_item', 'payload': {'type': 'message', 'role': 'user',
            'content': [{'type': 'input_text', 'text': part} for part in parts]}}])
        value = self.read('codex')['records'][0]['record']
        self.assertEqual(len(value['blocks']), 1)
        self.assertEqual(value['blocks'][0]['text'], ''.join(parts))
        self.assertFalse(value['truncated'])

    def test_codex_input_fragment_coalescing_does_not_cross_other_content(self):
        self.write([{'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [
            {'type': 'input_text', 'text': 'one'}, {'type': 'input_text', 'text': ' two'},
            {'type': 'input_image', 'image_url': 'tessera:image'},
            {'type': 'input_text', 'text': 'three'}, {'type': 'input_text', 'text': ' four'}]}}])
        value = self.read('codex')['records'][0]['record']
        self.assertEqual([block['type'] for block in value['blocks']], ['text', 'attachment', 'text'])
        self.assertEqual([block['text'] for block in value['blocks'] if block['type'] == 'text'], ['one two', 'three four'])

    def test_codex_input_fragments_keep_injected_content_out(self):
        parts = [{'type': 'input_text', 'text': 'injected context'}] + [{'type': 'input_text', 'text': 'human '} for _ in range(150)]
        self.write([{'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': parts,
            'internal_chat_message_metadata_passthrough': {'content_item_kinds': ['context'] + ['user.text'] * 150}}}])
        value = self.read('codex')['records'][0]['record']
        self.assertEqual([block['text'] for block in value['blocks']], ['human ' * 150])
        self.assertFalse(value['truncated'])

    def test_codex_input_fragment_truncation_is_never_silent(self):
        for text in ['x' * size for size in (8192, 8193, 16384, 16385)] + ['é' * 8193, '\n' * 10000]:
            with self.subTest(bytes=len(text.encode())):
                self.write([{'type': 'response_item', 'payload': {'type': 'message', 'role': 'user',
                    'content': [{'type': 'input_text', 'text': text[:4000]}, {'type': 'input_text', 'text': text[4000:]}]}}])
                value = self.read('codex')['records'][0]['record']
                block = value['blocks'][0]
                self.assertTrue(text.startswith(block['text']))
                shortened = block['text'] != text
                self.assertEqual(value['truncated'], shortened)
                self.assertEqual(block['truncated'], shortened)

    def test_claude_server_advisor_calls_and_all_result_variants(self):
        variants = [({'type': 'advisor_result', 'text': 'synthetic advice'}, 'synthetic advice'),
                    ({'type': 'advisor_redacted_result', 'encrypted_content': 'do-not-display'}, 'Advisor result is encrypted'),
                    ({'type': 'advisor_tool_result_error', 'error_code': 'overloaded'}, 'Advisor error: overloaded')]
        for content, expected in variants:
            self.write([{'type': 'assistant', 'message': {'content': [
                {'type': 'server_tool_use', 'id': 'advisor-1', 'name': 'advisor', 'input': {}},
                {'type': 'advisor_tool_result', 'tool_use_id': 'advisor-1', 'content': content}]}}])
            blocks = self.read()['records'][0]['record']['blocks']
            self.assertEqual([b['type'] for b in blocks], ['tool_call', 'tool_result'])
            self.assertEqual([b['toolCallID'] for b in blocks], ['advisor-1', 'advisor-1'])
            self.assertEqual(blocks[1]['preview'], expected)
            self.assertNotIn('do-not-display', json.dumps(blocks))

    def test_future_advisor_result_stays_explicitly_unknown(self):
        self.write([{'type': 'assistant', 'message': {'content': [
            {'type': 'advisor_tool_result', 'tool_use_id': 'advisor-1',
             'content': {'type': 'future_advisor_result', 'text': 'not silently flattened'}}]}}])
        block = self.read()['records'][0]['record']['blocks'][0]
        self.assertEqual(block['type'], 'unknown')
        self.assertEqual(block['sourceType'], 'advisor_tool_result/future_advisor_result')

    def test_unknown_blocks_outside_preview_budget_remain_counted(self):
        self.write([{'type': 'assistant', 'message': {'content': [
            *[{'type': 'tool_use', 'id': f't{n}', 'name': 'fixture', 'input': {}} for n in range(64)],
            {'type': 'future_block', 'text': 'outside preview'}, 42]}}])
        record = self.read()['records'][0]['record']
        self.assertTrue(record['truncated'])
        self.assertEqual(len(record['blocks']), 64)
        self.assertEqual(record['unparsedContentCount'], 2)

    def test_mixed_tool_results_keep_images_references_and_unknowns_in_order(self):
        self.write([{'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'call-1', 'content': [
            {'type': 'text', 'text': 'before'}, {'type': 'image', 'source': {'data': 'opaque-image'}},
            {'type': 'tool_reference', 'tool_name': 'discovered-tool'}, {'type': 'future_result', 'text': 'not silently flattened'},
            {'type': 'text', 'text': 'after'}]}]}}])
        record = self.read()['records'][0]['record']
        self.assertEqual(record['role'], 'tool')
        self.assertEqual([b['type'] for b in record['blocks']], ['tool_result', 'attachment', 'attachment', 'unknown', 'tool_result'])
        self.assertEqual([b['toolCallID'] for b in record['blocks']], ['call-1'] * 5)
        self.assertEqual(record['blocks'][2]['name'], 'discovered-tool')
        self.assertEqual(record['blocks'][-1]['preview'], 'after')
        self.assertEqual(record['unparsedContentCount'], 1)
        self.assertNotIn('opaque-image', json.dumps(record))

    def test_codex_search_items_and_call_ids_are_not_unknown(self):
        self.write([{'type': 'response_item', 'payload': payload} for payload in [
            {'type': 'tool_search_call', 'id': 'item-1', 'call_id': 'call-1', 'arguments': {'query': 'synthetic'}, 'execution': 'server'},
            {'type': 'tool_search_output', 'id': 'item-2', 'call_id': 'call-1', 'tools': [{'name': 'fixture'}], 'status': 'completed', 'execution': 'server'},
            {'type': 'web_search_call', 'id': 'web-1', 'action': {'type': 'search', 'query': 'synthetic'}},
            {'type': 'function_call', 'id': 'item-3', 'call_id': 'call-2', 'name': 'fixture', 'arguments': '{}'}]])
        records = self.read('codex')['records']
        self.assertEqual([r['disposition'] for r in records], ['message'] * 4)
        blocks = [r['record']['blocks'][0] for r in records]
        self.assertEqual([b['type'] for b in blocks], ['tool_call', 'tool_result', 'tool_call', 'tool_call'])
        self.assertEqual([b['toolCallID'] for b in blocks], ['call-1', 'call-1', 'web-1', 'call-2'])
        self.assertIn('fixture', blocks[1]['preview'])

    def test_encrypted_content_and_model_fallback_are_typed_not_authored_prose(self):
        self.write([{'type': 'assistant', 'message': {'content': [
            {'type': 'fallback', 'from': {'model': 'model-a'}, 'to': {'model': 'model-b'}},
            {'type': 'text', 'text': 'answer'}]}}])
        blocks = self.read()['records'][0]['record']['blocks']
        self.assertEqual(blocks[0]['type'], 'system-event')
        self.assertEqual(blocks[0]['text'], 'Model fallback: model-a → model-b')
        self.write([{'type': 'response_item', 'payload': {'type': 'agent_message', 'content': [
            {'type': 'encrypted_content', 'encrypted_content': 'opaque-never-display'}]}}])
        record = self.read('codex')['records'][0]['record']
        self.assertEqual(record['blocks'][0]['name'], 'Encrypted content')
        self.assertNotIn('opaque-never-display', json.dumps(record))

    def test_invalid_text_wrappers_and_null_content_fallback_cannot_hide_unknowns(self):
        for content, output in [({'type': 'text', 'content': {'type': 'future_content', 'text': 'not flattenable'}}, None),
                                (None, {'type': 'future_content', 'text': 'not flattenable'})]:
            self.write([{'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'call',
                'content': content, 'output': output}]}}])
            record = self.read()['records'][0]['record']
            self.assertEqual(record['role'], 'tool')
            self.assertEqual(record['unparsedContentCount'], 1)
            self.assertEqual(record['blocks'][0]['type'], 'unknown')
            self.assertNotIn('not flattenable', json.dumps(record))

    def test_reasoning_aliases_validate_content_and_preserve_plaintext_details(self):
        self.write([{'type': 'response_item', 'payload': {'type': 'reasoning',
            'text': {'type': 'future_reasoning', 'text': 'not reasoning text'}}}])
        record = self.read('codex')['records'][0]['record']
        self.assertEqual(record['unparsedContentCount'], 1)
        self.assertNotIn('not reasoning text', json.dumps(record))
        self.write([{'type': 'response_item', 'payload': {'type': 'reasoning',
            'summary': [{'type': 'summary_text', 'text': 'summary'}],
            'content': [{'type': 'reasoning_text', 'text': 'details'}]}}])
        record = self.read('codex')['records'][0]['record']
        self.assertEqual(record['blocks'][0]['text'], 'summary\ndetails')

    def test_page_budget_includes_escaped_record_identifiers(self):
        self.write([{'type': 'assistant', 'uuid': '\t' * 256, 'parentUuid': '\t' * 256,
                     'message': {'content': 'x' * 3000}} for _ in range(100)])
        page = self.read()
        self.assertTrue(page['hasOlder'])

    def test_tool_batch_cannot_hide_trailing_human_prose(self):
        self.write([{'type': 'user', 'message': {'content': [
            *[{'type': 'tool_result', 'content': 'tool'} for _ in range(64)], {'type': 'text', 'text': 'human'}]}}])
        record = self.read()['records'][0]['record']
        self.assertEqual(record['role'], 'user')
        self.assertIn('human', [block.get('text') for block in record['blocks']])
        self.assertTrue(record['truncated'])

    def test_exact_block_cap_is_not_truncation(self):
        self.write([{'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 't'} for _ in range(64)]}}])
        record = self.read()['records'][0]['record']
        self.assertEqual(len(record['blocks']), 64)
        self.assertFalse(record['truncated'])

    def test_empty_reasoning_does_not_add_a_visible_block(self):
        self.write([{'type': 'assistant', 'message': {'content': [
            {'type': 'thinking', 'thinking': ''}, {'type': 'text', 'text': 'visible'}]}}])
        blocks = self.read()['records'][0]['record']['blocks']
        self.assertEqual([block['type'] for block in blocks], ['text'])
        self.write([{'type': 'response_item', 'payload': {'type': 'reasoning', 'summary': []}}])
        self.assertEqual(self.read('codex')['records'][0]['record']['blocks'], [])
        self.write([{'type': 'response_item', 'payload': {'type': 'reasoning',
                    'summary': [{'type': 'summary_text', 'text': '\r\u202e'}]}}])
        self.assertEqual(self.read('codex')['records'][0]['record']['blocks'], [])
        self.write([{'type': 'response_item', 'payload': {'type': 'reasoning',
                    'summary': [{'type': 'summary_text', 'text': 'thought\r\u202e'}]}}])
        self.assertEqual(self.read('codex')['records'][0]['record']['blocks'][0]['text'], 'thought')

    def test_display_controls_are_removed_without_mutating_source_identity(self):
        self.write([{'type': 'assistant', 'uuid': 'identity-\u202e', 'message': {'content': [
            {'type': 'text', 'text': 'a\r\x00\x1bb\u202ac\u202ed\u2066e\u2069\n\t界'},
            {'type': 'tool_result', 'content': 'tool\r\nresult\u202e'}]}}])
        item = self.read()['records'][0]
        self.assertEqual(item['providerRecordID'], 'identity-\u202e')
        self.assertEqual(item['record']['blocks'][0]['text'], 'abcde\n\t界')
        self.assertEqual(item['record']['blocks'][1]['preview'], 'tool\nresult')

    def test_escaped_text_is_shortened_not_erased(self):
        self.write([{'type': 'assistant', 'message': {'content': '\t' * 8192}}])
        record = self.read()['records'][0]['record']
        self.assertTrue(record['blocks'][0]['text'])

    def test_tool_result_filters_controls_before_text_retention_budget(self):
        for body in ('\r' * 17000 + 'visible tail', '\u202e' * 6000 + 'visible tail',
                     '\r' * 17000 + 'x' * 20000):
            with self.subTest(length=len(body)):
                self.write([{'type': 'response_item', 'payload': {
                    'type': 'function_call_output', 'call_id': 'call', 'output': body}}])
                record = self.read('codex')['records'][0]['record']; block = record['blocks'][0]
                expected = body.replace('\r', '').replace('\u202e', '')
                self.assertEqual(block['preview'], expected[:8192])
                self.assertEqual(block['truncated'], len(expected) > 8192)
                self.assertEqual(record['truncated'], len(expected) > 8192)

    def test_audit_accounts_for_unterminated_tail(self):
        self.path.write_bytes(b'{"type":"assistant","message":{"content":"pending"}}')
        audit = self.read('claude', '--audit')
        self.assertEqual(audit['records'], 0)
        self.assertEqual(audit['committedBytes'], 0)
        self.assertEqual(audit['deferredTailBytes'], self.path.stat().st_size)

    def test_valid_excessive_depth_is_unsupported_not_malformed(self):
        nested = 0
        for _ in range(130): nested = [nested]
        self.write([{'type': 'assistant', 'message': {'content': 'visible'}, 'metadata': nested, 'padding': 'x' * 1100000}])
        self.assertEqual(self.read()['records'][0]['disposition'], 'unsupported')

    def test_live_checkpoint_survives_append_and_defers_partial_line(self):
        self.write([{'type': 'user', 'message': {'content': 'first'}}])
        initial = self.read()
        with self.path.open('ab') as stream:
            stream.write(b'{"type":"assistant","message":{"content":"caf\xc3')
        unchanged = self.read('claude', '--after', str(initial['livePosition']))
        self.assertEqual(unchanged['records'], [])
        with self.path.open('ab') as stream:
            stream.write(b'\xa9"}}\n')
        updated = self.read('claude', '--after', str(initial['livePosition']))
        self.assertEqual(updated['records'][0]['record']['blocks'][0]['text'], 'café')
        self.assertEqual(initial['sourceIdentity'], updated['sourceIdentity'])

    def test_giant_image_does_not_hide_trailing_prose(self):
        self.write([{'type': 'response_item', 'payload': {'type': 'message', 'role': 'user', 'content': [
            {'type': 'input_image', 'image_url': 'data:image/png;base64,' + 'A' * (8 * 1024 * 1024)},
            {'type': 'input_text', 'text': 'trailing human text'}]}}])
        page = self.read('codex')
        blocks = page['records'][0]['record']['blocks']
        self.assertEqual([value['type'] for value in blocks], ['attachment', 'text'])
        self.assertEqual(blocks[1]['text'], 'trailing human text')
        self.assertTrue(page['records'][0]['record']['truncated'])
        self.assertLess(page['bytesRead'], 20 * 1024 * 1024)

    def test_oversized_codex_checkpoint_omits_duplicate_context_not_summary(self):
        self.write([{'type': 'compacted', 'payload': {'replacement_history': [{'text': 'old' * 4000} for _ in range(300)],
            'guardian_history': [{'role': 'assistant', 'content': 'old' * 4000} for _ in range(300)],
            'message': 'canonical compaction boundary'}}])
        record = self.read('codex')['records'][0]
        self.assertEqual(record['disposition'], 'system')
        self.assertEqual(record['record']['blocks'][0]['text'], 'canonical compaction boundary')
        self.assertNotIn('replacement_history', record['record'])

    def test_skipped_checkpoint_context_is_still_validated(self):
        prefix = b'{"type":"compacted","payload":{"guardian_history":[' + b'{"text":"old"},' * 100000
        for invalid in [b']', b'true false]', b'01]', b'{"a":}]']:
            self.path.write_bytes(prefix + invalid + b',"message":"summary"}}\n')
            self.assertEqual(self.read('codex')['records'][0]['disposition'], 'malformed')

    def test_checkpoint_omission_matches_escaped_keys_and_not_tool_arguments(self):
        value = {'payload': {'guardian_history': ['x' * 100 for _ in range(12000)], 'message': 'summary'}, 'type': 'compacted'}
        self.path.write_text(json.dumps(value).replace('guardian_history', 'guardian_\\u0068istory') + '\n')
        self.assertEqual(self.read('codex')['records'][0]['record']['blocks'][0]['text'], 'summary')
        self.write([{'type': 'response_item', 'payload': {'type': 'function_call', 'name': 'tool',
            'arguments': {'guardian_history': 'keep this tool input'}, 'padding': 'x' * 1100000}}])
        self.assertIn('keep this tool input', self.read('codex')['records'][0]['record']['blocks'][0]['preview'])

    def test_oversized_string_checks_invalid_escape_after_retention_limit(self):
        self.path.write_bytes(b'{"type":"assistant","message":{"content":"' + b'x' * 1100000 + b'\\q"}}\n')
        result = self.read()['records'][0]
        self.assertEqual(result['disposition'], 'malformed')

    def test_oversized_string_checks_invalid_utf8_after_retention_limit(self):
        self.path.write_bytes(b'{"type":"assistant","message":{"content":"' + b'x' * 1100000 + b'\xf0\x80\x80\x80"}}\n')
        self.assertEqual(self.read()['records'][0]['disposition'], 'malformed')

    def test_large_text_keeps_utf8_and_surrogate_pairs_well_formed(self):
        self.write([{'type': 'assistant', 'message': {'content': '😀' * 300000}}])
        text = self.read()['records'][0]['record']['blocks'][0]['text']
        self.assertEqual(text, '😀' * 2048)
        self.path.write_bytes(b'{"type":"assistant","message":{"content":"' + b'\\ud83d\\ude00' * 100000 + b'"}}\n')
        self.assertTrue(self.read()['records'][0]['record']['blocks'][0]['text'].startswith('😀'))

    def test_compact_summary_is_not_a_human_or_title_seed(self):
        self.write([{'type': 'user', 'isCompactSummary': True, 'message': {'content': 'summary'}}])
        record = self.read()['records'][0]['record']
        self.assertEqual(record['role'], 'system')
        self.assertEqual(record['blocks'][0]['type'], 'compact-summary')
        self.assertTrue(record['isCompactSummary'])

    def test_metadata_queue_payload_is_not_copied(self):
        self.write([{'type': 'queue-operation', 'pending': 2, 'content': 'x' * 2000000}])
        record = self.read()['records'][0]['record']
        self.assertEqual(record['pending'], 2)
        self.assertNotIn('content', record)

    def test_claude_bookkeeping_requires_exact_known_shapes_and_reason(self):
        fixtures = [
            dict(type='file-history-snapshot', messageId='fixture', snapshot={}, isSnapshotUpdate=False),
            dict(type='file-history-delta', messageId='fixture', snapshotMessageId='prior', trackingPath='private', backup={}, timestamp='fixture'),
            dict(type='last-prompt', leafUuid='fixture', sessionId='session', lastPrompt='private cached prompt'),
            dict(type='atis-latch', atis='private', sessionId='session'),
            dict(type='bridge-session', sessionId='session', bridgeSessionId='private', lastSequenceNum=1,
                 ownerAccountUuid='private', ownerOrganizationUuid='private'),
            dict(type='relocated', sessionId='session', relocatedCwd='private'),
            dict(type='worktree-state', sessionId='session', worktreeSession=None),
            dict(type='pr-link', sessionId='session', prNumber=1, prUrl='private', prRepository='private', timestamp='fixture'),
            dict(type='fork-context-ref', agentId='private', parentSessionId='private', parentLastUuid='private', contextLength=1),
        ]
        for source in fixtures:
            with self.subTest(kind=source['type']):
                self.write([source])
                row = self.read()['records'][0]
                self.assertEqual(row['disposition'], 'ignored')
                self.assertFalse(row['visible'])
                self.assertEqual(row['record']['ignoreReason'], 'claude-sdk-non-message/' + source['type'])
                self.assertNotIn('private', json.dumps(row['record']))
                self.write([{**source, 'message': {'content': 'future authored content'}}])
                self.assertEqual(self.read()['records'][0]['disposition'], 'unclassified')
                field = next(key for key in source if key != 'type')
                self.write([{**source, field: []}])
                self.assertEqual(self.read()['records'][0]['disposition'], 'unclassified')
                self.write([{key: value for key, value in source.items() if key != field}])
                self.assertEqual(self.read()['records'][0]['disposition'], 'unclassified')

    def test_claude_bookkeeping_duplicate_keys_never_qualify_for_ignore(self):
        prefix = '{"type":"file-history-snapshot","messageId":"fixture","snapshot":{},"isSnapshotUpdate":false'
        for suffix in (',"type":"future-authored-record"}', ',"snapshot":42}', ',"snapshot":{}}',
                       ',"type":"file-history-snapshot"}'):
            self.path.write_text(prefix + suffix + '\n')
            self.assertEqual(self.read()['records'][0]['disposition'], 'unclassified')

    def test_claude_bookkeeping_nullable_and_optional_fields_are_deliberate(self):
        self.write([dict(type='last-prompt', leafUuid='fixture', sessionId='session'),
                    dict(type='worktree-state', sessionId='session', worktreeSession={})])
        self.assertTrue(all(row['disposition'] == 'ignored' for row in self.read()['records']))
        for value in (-1, 1.5, True, '1'):
            self.write([dict(type='fork-context-ref', agentId='fixture', parentSessionId='parent', parentLastUuid='prior', contextLength=value)])
            self.assertEqual(self.read()['records'][0]['disposition'], 'unclassified')

    def test_subagent_metadata_cannot_replace_parent_metadata(self):
        self.write([{'type': 'assistant', 'isSidechain': True, 'model': 'wrong', 'cwd': '/wrong',
                     'message': {'model': 'also-wrong', 'content': 'child text'}}])
        record = self.read()['records'][0]['record']
        self.assertTrue(record['isSidechain'])
        self.assertNotIn('model', record)
        self.assertNotIn('project', record)

    def test_codex_internal_user_items_are_filtered(self):
        self.write([{'type': 'response_item', 'payload': {'type': 'message', 'role': 'user',
            'content': [{'type': 'input_text', 'text': 'injected'}, {'type': 'input_text', 'text': 'human'}],
            'internal_chat_message_metadata_passthrough': {'content_item_kinds': ['system.foo', 'user.text']}}}])
        self.assertEqual([b['text'] for b in self.read('codex')['records'][0]['record']['blocks']], ['human'])

    def test_codex_invalid_content_annotations_cannot_expose_context(self):
        for kinds in (['user.text'], ['system.foo', 7], 'user.text', None, []):
            with self.subTest(kinds=kinds):
                self.write([{'type': 'response_item', 'payload': {'type': 'message', 'role': 'user',
                    'content': [{'type': 'input_text', 'text': 'private injected context'},
                                {'type': 'input_text', 'text': 'human'}],
                    'internal_chat_message_metadata_passthrough': {'content_item_kinds': kinds}}}])
                value = self.read('codex')['records'][0]['record']
                self.assertEqual(value.get('unparsedContentCount'), 1)
                self.assertEqual(value['role'], 'system')
                self.assertNotIn('private injected context', json.dumps(value))
                self.assertEqual(value['blocks'][0]['type'], 'unknown')

    def test_codex_invalid_annotation_container_cannot_expose_context(self):
        for annotation in ('invalid', [], 42):
            self.write([{'type': 'response_item', 'payload': {'type': 'message', 'role': 'user',
                'content': [{'type': 'input_text', 'text': 'private injected context'}],
                'internal_chat_message_metadata_passthrough': annotation}}])
            value = self.read('codex')['records'][0]['record']
            self.assertEqual(value.get('unparsedContentCount'), 1)
            self.assertEqual(value['role'], 'system')
            self.assertNotIn('private injected context', json.dumps(value))

    def test_tool_ids_and_model_facing_result_text_are_preserved(self):
        self.write([{'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 'call',
            'content': [{'type': 'text', 'text': 'one'}, {'type': 'text', 'text': 'two'}]}]}}])
        record = self.read()['records'][0]['record']
        self.assertEqual(record['role'], 'tool')
        self.assertEqual(record['blocks'][0]['toolCallID'], 'call')
        self.assertEqual(record['blocks'][0]['preview'], 'one\ntwo')

    def test_budget_exhaustion_is_not_malformed_json(self):
        self.write([{'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'x'}] * 40000}}])
        result = self.read()['records'][0]
        self.assertEqual(result['disposition'], 'unsupported')
        self.assertFalse(result['record']['malformed'])

    def test_audit_reconstructs_all_pages_without_emitting_content(self):
        self.write([{'type': 'user', 'message': {'content': 'private-synthetic'}} for _ in range(250)])
        result = self.read('claude', '--audit')
        self.assertEqual(result['records'], 250)
        self.assertNotIn('private-synthetic', json.dumps(result))


if __name__ == '__main__':
    unittest.main()
