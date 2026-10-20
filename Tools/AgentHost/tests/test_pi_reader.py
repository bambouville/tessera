"""Synthetic Pi session-format v1/v2/v3 history and append contract.

No Pi executable, credentials, extension loading or user sessions are used.
The display history follows persisted parent links, not compacted LLM context.
"""
import json
import base64
import hashlib
import ctypes
import os
from pathlib import Path
import unittest

import test_service as service
from test_service import frame, receive


class PiReaderTests(unittest.TestCase):
    setUp = service.ServiceTests.setUp
    tearDown = service.ServiceTests.tearDown
    client = service.ServiceTests.client
    resolve = service.ServiceTests.resolve
    read_page = service.ServiceTests.read_page
    window_page = service.ServiceTests.window_page
    window_ack = service.ServiceTests.window_ack
    service = service.ServiceTests.service

    def core_search(self, begin, rows, end, query='synthetic'):
        library = os.environ.get('TESSERA_AGENT_CORE_LIBRARY')
        if not library:
            return  # The explicit native-to-Core integration lane supplies it.
        function = ctypes.CDLL(library).tessera_agent_page_search
        function.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        function.restype = ctypes.c_int32
        wire = b''.join(frame(value) for value in [begin, *rows, end])
        value = json.dumps(dict(wire=base64.b64encode(wire).decode(), epoch=begin['serviceEpoch'],
            thread=begin['thread'], threadID=dict(hostID='A11CE000-0000-4000-8000-000000000001',
                providerID=dict(rawValue='pi'), providerSessionID='synthetic-session'), query=query)).encode()
        required = function(value, len(value), None, 0)
        self.assertGreater(required, 0, 'actual native Pi wire was rejected by shared Core')
        output = ctypes.create_string_buffer(required)
        self.assertEqual(function(value, len(value), output, required), required)
        return json.loads(output.raw)

    def test_pinned_native_session_vector(self):
        path = Path(__file__).resolve().parents[3] / 'Packages/TesseraCore/Tests/TesseraAgentCoreTests/Vectors/pi-native-session.json'
        data = path.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), '56133a1d19b4b6f99d388f2c9774e55c2c1e93227e6b60b697f0fcff589aed63')
        fixture = json.loads(data)
        transcript, client, thread = self.start(fixture['entries'], fixture['version'])
        source_ids = {}
        offset = 0
        for line in transcript.read_bytes().splitlines(keepends=True):
            source_ids[offset] = json.loads(line)['id']
            offset += len(line)
        begin, rows, end = self.window_page(client, thread, 'bootstrap', 0)
        self.core_search(begin, rows, end)
        self.assertEqual([source_ids[row['sourceOffset']] for row in rows], fixture['expectedRecordIDs'])
        self.assertTrue(all(row['disposition'] != 'unclassified' for row in rows))
        notice = next(row['record'] for row in rows if source_ids[row['sourceOffset']] == 'notice')
        self.assertTrue(notice['providerSystemMessage'])
        self.assertEqual(notice['blocks'][0]['text'], 'visible extension notice')

    def start(self, entries, version=3):
        root = self.root / 'pi'
        path = root / 'sessions/--synthetic--/timestamp_synthetic-session.jsonl'
        path.parent.mkdir(parents=True)
        header = dict(type='session', version=version, id='synthetic-session', cwd='/synthetic')
        path.write_text(''.join(json.dumps(row) + '\n' for row in [header, *entries]))
        self.service(idle=30000, lease=30000, extra_environment={'PI_CODING_AGENT_DIR': str(root)})
        client, _ = self.client()
        thread = self.resolve(client, path, 'pi')
        return path, client, thread

    @staticmethod
    def message(name, parent, role='assistant', content='synthetic'):
        return dict(type='message', id=name, parentId=parent, message=dict(role=role, content=content))

    @staticmethod
    def text(rows):
        return [block['text'] for row in rows for block in row['record'].get('blocks', []) if block.get('type') == 'text']

    def test_active_branch_is_not_a_physical_tail_or_compacted_context(self):
        entries = [self.message('root', None, 'user', 'root request'),
            self.message('abandoned', 'root', content='abandoned reply'),
            self.message('current', 'root', content='current reply'),
            dict(type='compaction', id='compact', parentId='current', summary='Context compacted',
                retainedTail=[dict(role='user', content='model-only checkpoint')]),
            self.message('tail', 'compact', content='latest reply')]
        _, client, thread = self.start(entries)
        _, rows, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(self.text(rows), ['root request', 'current reply', 'latest reply'])
        self.assertTrue(any(row['record'].get('isCompactSummary') for row in rows))
        self.assertFalse(any(row['record'].get('unparsedContentCount', 0) for row in rows))
        self.window_ack(client, thread, end, [end['window']['segmentID']], end['window']['segmentID'])

    def test_history_prepend_and_append_keep_stable_generation(self):
        entries = [self.message('m' + str(n), 'm' + str(n-1) if n else None,
            content='message ' + str(n)) for n in range(250)]
        path, client, thread = self.start(entries)
        begin, rows, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(self.text(rows), ['message ' + str(n) for n in range(150, 250)])
        head = end['window']['segmentID']
        self.window_ack(client, thread, end, [head], head)
        with path.open('a') as output:
            output.write(json.dumps(self.message('m250', 'm249', content='message 250')) + '\n')
        newer, rows, updated = self.window_page(client, thread, 'head', end['window']['version'], end['liveCursor'])
        self.assertEqual(newer['sourceIdentity'], begin['sourceIdentity'])
        self.assertIn('message 250', self.text(rows))
        head = updated['window']['segmentID']
        self.window_ack(client, thread, updated, [head], head)
        _, older, _ = self.window_page(client, thread, 'before', updated['window']['version'], updated['window']['before'])
        self.assertEqual(self.text(older)[-1], 'message 150')

    def test_stateless_search_pages_share_branch_and_ids_without_moving_window(self):
        entries = [self.message('root', None, 'user'), self.message('abandoned', 'root')]
        entries += [self.message('m' + str(n), 'm' + str(n-1) if n else 'root') for n in range(250)]
        path, client, thread = self.start(entries)
        _, visible, window = self.window_page(client, thread, 'bootstrap', 0)
        head = window['window']['segmentID']
        self.window_ack(client, thread, window, [head], head)
        client.sendall(frame(dict(kind='bootstrap', id='search-first', thread=thread)))
        begin, first, page = self.read_page(client)
        self.core_search(begin, first, page)
        self.assertEqual([row['recordID'] for row in first], [row['recordID'] for row in visible])
        selected = list(first)
        while page['hasOlder']:
            client.sendall(frame(dict(kind='history', id='search-older', thread=thread, cursor=page['historyCursor'])))
            begin, older, page = self.read_page(client)
            self.core_search(begin, older, page)
            selected = older + selected
        self.assertEqual([row['providerRecordID'] for row in selected],
                         ['synthetic-session', 'root'] + ['m' + str(n) for n in range(250)])
        with path.open('a') as output:
            output.write(json.dumps(self.message('m250', 'm249')) + '\n')
        _, updates, advanced = self.window_page(client, thread, 'head', window['window']['version'], window['liveCursor'])
        self.assertGreater(advanced['window']['version'], window['window']['version'])
        self.assertTrue(updates)

    def check_window_survives_index_pressure(self, acknowledge_before_pressure):
        entries = [self.message('m' + str(n), 'm' + str(n-1) if n else None,
            content='message ' + str(n)) for n in range(250)]
        path, client, thread = self.start(entries)
        begin, _, page = self.window_page(client, thread, 'bootstrap', 0)
        head = page['window']['segmentID']
        if acknowledge_before_pressure:
            self.window_ack(client, thread, page, [head], head)
        # Stateless reads from another client must exercise the 24-index LRU
        # without consuming the four-window limit or pinning the distractors.
        other, _ = self.client()
        for number in range(26):
            identifier = 'pressure-' + str(number)
            distractor = path.parent / ('timestamp_' + identifier + '.jsonl')
            distractor.write_text(json.dumps(dict(type='session', version=3,
                id=identifier, cwd='/synthetic')) + '\n' +
                json.dumps(self.message('entry', None)) + '\n')
            reference = self.resolve(other, distractor, 'pi')
            other.sendall(frame(dict(kind='bootstrap', id=identifier, thread=reference)))
            _, rows, _ = self.read_page(other)
            self.assertTrue(rows)
        if not acknowledge_before_pressure:
            self.window_ack(client, thread, page, [head], head)
        older, rows, _ = self.window_page(client, thread, 'before',
            page['window']['version'], page['window']['before'])
        self.assertEqual(older['sourceIdentity'], begin['sourceIdentity'])
        self.assertEqual(self.text(rows), ['message ' + str(n) for n in range(50, 150)])

    def test_pending_window_pins_pi_index_under_pressure(self):
        self.check_window_survives_index_pressure(False)

    def test_acknowledged_window_pins_pi_index_under_pressure(self):
        self.check_window_survives_index_pressure(True)

    def test_branch_change_invalidates_the_old_cursor(self):
        path, client, thread = self.start([self.message('root', None), self.message('old', 'root')])
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        self.window_ack(client, thread, end, [head], head)
        with path.open('a') as output:
            output.write(json.dumps(self.message('branch', 'root')) + '\n')
        client.sendall(frame(dict(kind='window.read', id='changed', thread=thread,
            operation='head', windowVersion=end['window']['version'], cursor=end['liveCursor'])))
        self.assertEqual(receive(client)['code'], 'sourceChanged')

    def test_tool_relationships_and_hidden_extension_messages(self):
        entries = [self.message('call', None, content=[dict(type='toolCall', id='tool-1', name='read', arguments={})]),
            dict(type='message', id='result', parentId='call', message=dict(role='toolResult',
                toolCallId='tool-1', toolName='read', content=[dict(type='text', text='tool output')], isError=False)),
            dict(type='custom_message', id='hidden', parentId='result', customType='context', content='hidden context', display=False),
            dict(type='custom_message', id='shown', parentId='hidden', customType='notice', content='visible notice', display=True)]
        _, client, thread = self.start(entries)
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        blocks = [block for row in rows for block in row['record'].get('blocks', [])]
        self.assertEqual([block['toolCallID'] for block in blocks if block['type'] in ('tool_call', 'tool_result')], ['tool-1', 'tool-1'])
        self.assertNotIn('hidden context', self.text(rows))
        self.assertIn('visible notice', self.text(rows))
        self.assertTrue(all(row['disposition'] != 'unclassified' for row in rows))

    def test_unknown_records_are_visible_not_silently_dropped(self):
        _, client, thread = self.start([dict(type='future_entry', id='future', parentId=None, payload='synthetic')])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        self.assertTrue(any(row['disposition'] == 'unclassified' for row in rows))

    def test_malformed_known_payloads_are_not_empty_or_hidden_successes(self):
        _, client, thread = self.start([
            dict(type='message', id='bash', parentId=None, message=dict(role='bashExecution', command={}, output=[])),
            dict(type='message', id='custom', parentId='bash', message=dict(role='custom', display='yes', content='must not disappear')),
            dict(type='message', id='result', parentId='custom', message=dict(role='toolResult', content=[dict(type='text', text='output')]))])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        invalid = [row for row in rows if row['record'].get('type') == 'unknown']
        self.assertEqual(len(invalid), 3)
        self.assertTrue(all(row['disposition'] == 'unclassified' for row in invalid))

    def test_version_one_bash_entries_have_distinct_stable_tool_identity(self):
        _, client, thread = self.start([dict(type='message', message=dict(role='bashExecution', command='printf synthetic', output='synthetic'))
            for _ in range(2)], version=1)
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        calls = [block['toolCallID'] for row in rows for block in row['record'].get('blocks', []) if block['type'] == 'tool_call']
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(set(calls)), 2)

    def test_version_two_parent_selection_and_legacy_custom_role(self):
        _, client, thread = self.start([self.message('root', None, content='root'),
            self.message('abandoned', 'root', content='abandoned'),
            dict(type='message', id='hook', parentId='root', message=dict(role='hookMessage', display=True, content='legacy notice'))], version=2)
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(self.text(rows), ['root', 'legacy notice'])

    def test_duplicate_parent_keys_cannot_choose_a_different_branch(self):
        path, client, thread = self.start([self.message('root', None)])
        with path.open('a') as output:
            output.write('{"type":"message","id":"child","parentId":"root","parentId":null,"message":{"role":"assistant","content":"child"}}\n')
        client.sendall(frame(dict(kind='window.read', id='duplicate', thread=thread, operation='bootstrap', windowVersion=0)))
        reply = receive(client)
        self.assertEqual(reply['kind'], 'error')

    def test_empty_assistant_error_remains_visible(self):
        _, client, thread = self.start([dict(type='message', id='error', parentId=None,
            message=dict(role='assistant', content=[], stopReason='error', errorMessage='synthetic failure'))])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        blocks = [block for row in rows for block in row['record'].get('blocks', [])]
        self.assertEqual([(block['type'], block.get('text')) for block in blocks], [('system-event', 'synthetic failure')])

    def test_failures_survive_display_block_budget_without_becoming_authored_prose(self):
        _, client, thread = self.start([
            dict(type='message', id='error', parentId=None, message=dict(role='assistant',
                content=[dict(type='text', text='authored ' + str(n)) for n in range(70)],
                stopReason='error', errorMessage='\x01' * 18000 + 'failure sentinel')),
            dict(type='message', id='tool', parentId='error', message=dict(role='toolResult', toolCallId='call', content=[], isError=True)),
            dict(type='message', id='bash', parentId='tool', message=dict(role='bashExecution', command='false', output='', exitCode=7))])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        blocks = [block for row in rows for block in row['record'].get('blocks', [])]
        self.assertEqual([block['text'] for block in blocks if block['type'] == 'system-event'],
            ['failure sentinel', 'Tool execution failed', 'Bash exited with code 7'])
        self.assertNotIn('failure sentinel', self.text(rows))

    def test_existing_handle_cannot_read_a_replacement_session(self):
        path, client, thread = self.start([self.message('root', None)])
        path.write_text(json.dumps(dict(type='session', version=3, id='replacement')) + '\n' +
            json.dumps(self.message('root', None, content='wrong session')) + '\n')
        client.sendall(frame(dict(kind='window.read', id='replaced', thread=thread, operation='bootstrap', windowVersion=0)))
        self.assertEqual(receive(client)['code'], 'piIdentityConflict')
        client.sendall(frame(dict(kind='resolve', id='resolve-again', provider='pi',
            transcriptRef=base64.urlsafe_b64encode(str(path).encode()).decode().rstrip('='))))
        self.assertEqual(receive(client)['code'], 'piIdentityConflict')

    def test_header_id_is_exact_and_not_uuid(self):
        path, client, thread = self.start([self.message('root', None)])
        rows = path.read_text().splitlines()
        header = json.loads(rows[0]); header['uuid'] = 'wrong-provider-id'
        path.write_text(json.dumps(header) + '\n' + '\n'.join(rows[1:]) + '\n')
        self.assertEqual(self.resolve(client, path, 'pi'), thread)
        del header['id']
        path.write_text(json.dumps(header) + '\n' + '\n'.join(rows[1:]) + '\n')
        client.sendall(frame(dict(kind='window.read', id='no-id', thread=thread, operation='bootstrap', windowVersion=0)))
        self.assertEqual(receive(client)['kind'], 'error')

    def test_warm_identity_check_covers_header_prefix_during_growth(self):
        path, client, thread = self.start([self.message('root', None)])
        header = dict(type='session', version=3, id='synthetic-session', cwd='/' + 'x' * 200)
        path.write_text(json.dumps(header) + '\n' + json.dumps(self.message('root', None)) + '\n')
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        self.window_ack(client, thread, end, [head], head)
        with path.open('r+b') as output:
            original = output.read()
            output.seek(0)
            output.write(original.replace(b'synthetic-session', b'different-session', 1))
            output.write((json.dumps(self.message('new', 'root', content='wrong session')) + '\n').encode())
        client.sendall(frame(dict(kind='window.read', id='warm-replaced', thread=thread,
            operation='head', windowVersion=end['window']['version'], cursor=end['liveCursor'])))
        self.assertEqual(receive(client)['code'], 'piIdentityConflict')

    def test_summary_selects_the_same_persisted_branch(self):
        _, client, thread = self.start([self.message('root', None, 'user', 'root request'),
            self.message('abandoned', 'root', content='must not be the preview'),
            dict(type='custom', id='current', parentId='root', customType='test', data={})])
        client.sendall(frame(dict(kind='summary', id='summary', thread=thread)))
        reply = receive(client)
        self.assertEqual(reply['kind'], 'summary')
        text = self.text([dict(record=row) for row in reply['records']])
        self.assertEqual(text, ['root request'])

    def test_inventory_continues_beyond_one_thousand_header_reads(self):
        path, client, _ = self.start([self.message('root', None)])
        for number in range(1025):
            header = dict(type='session', version=3, id='session-' + str(number))
            (path.parent / f'{number}.jsonl').write_text(json.dumps(header) + '\n' + ' ' * 65536)
        total = 0
        cursor = None
        while True:
            request = dict(kind='inventory', id='inventory', provider='pi', limit=500)
            if cursor: request['cursor'] = cursor
            client.sendall(frame(request))
            self.assertEqual(receive(client, timeout=30)['kind'], 'inventory.begin')
            while True:
                value = receive(client, timeout=30)
                if value['kind'] == 'inventory.end': break
                self.assertEqual(value['kind'], 'inventory.thread')
                total += 1
            if not value.get('hasMore'): break
            cursor = value['cursor']
        self.assertEqual(total, 1026)


if __name__ == '__main__':
    unittest.main()
