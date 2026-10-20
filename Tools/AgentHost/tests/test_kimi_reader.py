"""Kimi 0.41.0 wire 1.4/1.5 public synthetic replay and authority tests.

No provider execution, credentials, hooks or private transcript data.
"""
import json
import base64
import ctypes
import hashlib
import os
import time
from pathlib import Path
import unittest
import test_service as service
from test_service import frame, receive


class KimiReaderTests(unittest.TestCase):
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
        if not library: return None
        function = ctypes.CDLL(library).tessera_agent_page_search
        function.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        function.restype = ctypes.c_int32
        wire = b''.join(frame(value) for value in [begin, *rows, end])
        request = json.dumps(dict(wire=base64.b64encode(wire).decode(), epoch=begin['serviceEpoch'], thread=begin['thread'],
            threadID=dict(hostID='A11CE000-0000-4000-8000-000000000001', providerID=dict(rawValue='kimi'),
                providerSessionID='session_synthetic'), query=query)).encode()
        size = function(request, len(request), None, 0)
        self.assertGreater(size, 0, 'actual native Kimi wire rejected by shared Core')
        output = ctypes.create_string_buffer(size)
        self.assertEqual(function(request, len(request), output, size), size)
        return json.loads(output.raw)

    def test_all_sixty_pinned_durable_record_types(self):
        path = Path(__file__).resolve().parents[3] / 'Packages/TesseraCore/Tests/TesseraAgentCoreTests/Vectors/kimi-native-wire.json'
        raw = path.read_bytes()
        self.assertEqual(hashlib.sha256(raw).hexdigest(), '166878e3a179db49910076d943db4fb395c7a4c3864fa01ddd60f5a9ca464e31')
        fixture = json.loads(raw)
        self.assertEqual(len({r['type'] for r in fixture['records']}), 60)
        _, client, thread = self.start(fixture['records'], fixture['protocolVersion'])
        begin, rows, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(len(rows), 61)
        self.assertFalse(any(r['record'].get('type') == 'unknown' or r['record'].get('unparsedContentCount', 0) for r in rows))
        self.core_search(begin, rows, end)

    def start(self, entries, version='1.4'):
        root = self.root / 'kimi'
        directory = root / 'sessions/work/session_synthetic'
        path = directory / 'agents/main/wire.jsonl'
        path.parent.mkdir(parents=True)
        index = root / 'session_index.jsonl'
        index.write_text(json.dumps(dict(sessionId=directory.name,
            sessionDir=str(directory), workDir='/synthetic')) + '\n')
        index.chmod(0o600)  # Do not depend on the test host's umask.
        self.append(path, [dict(type='metadata', protocol_version=version), *entries])
        self.service(idle=30000, lease=30000)
        client, _ = self.client()
        return path, client, self.resolve(client, path, 'kimi')

    @staticmethod
    def append(path, rows):
        with path.open('a') as output:
            for row in rows: output.write(json.dumps(row) + '\n')

    def test_group_writable_index_still_serves_the_owner(self):
        # A umask 0002 host writes the index group-writable. The owner decides
        # the mode of their own index; it must keep listing their sessions.
        path, client, thread = self.start([self.message('synthetic')])
        (self.root / 'kimi/session_index.jsonl').chmod(0o664)
        begin, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        self.assertTrue(begin['sourceIdentity'].startswith('kimi-history:'))
        self.assertEqual(self.text(rows), ['synthetic'])

    @staticmethod
    def message(text, role='user', origin=None):
        message = dict(role=role, content=[dict(type='text', text=text)], toolCalls=[])
        if origin: message['origin'] = origin
        return dict(type='context.append_message', agentId='main', message=message)

    @staticmethod
    def loop(kind, **fields):
        return dict(type='context.append_loop_event', agentId='main', event=dict(type=kind, **fields))

    @staticmethod
    def text(rows):
        return [block['text'] for row in rows for block in row['record'].get('blocks', []) if block.get('type') in ('text', 'compact-summary')]

    def test_prompt_admission_does_not_duplicate_authored_content(self):
        _, client, thread = self.start([dict(type='turn.prompt', input=[dict(type='text', text='authored')]),
            self.message('authored'), self.loop('step.begin', uuid='s1'),
            self.loop('content.part', stepUuid='s1', part=dict(type='text', text='reply')),
            self.loop('step.end', uuid='s1')])
        begin, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        self.assertTrue(begin['sourceIdentity'].startswith('kimi-history:'))
        self.assertEqual(self.text(rows), ['authored', 'reply'])
        self.assertTrue(all(row['disposition'] != 'unclassified' for row in rows))

    def test_oversized_timestamp_cannot_wedge_paging(self):
        first = self.message('before oversized time')
        first['time'] = 'x' * 200000
        second = self.message('after oversized time')
        second['time'] = {'opaque': 'x' * 200000}
        _, client, thread = self.start([first, second, self.message('last message')])
        _, rows, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(self.text(rows), ['before oversized time', 'after oversized time', 'last message'])
        for row in rows:
            value = row['record'].get('timestamp')
            self.assertTrue(value is None or isinstance(value, (str, int, float)))
            if isinstance(value, str): self.assertLessEqual(len(value), 128)


    def test_tool_result_defers_steering_and_preserves_call_identity(self):
        _, client, thread = self.start([self.loop('step.begin', uuid='s1'),
            self.loop('tool.call', stepUuid='s1', toolCallId='call1', name='Read', args={'path': 'synthetic'}),
            self.message('steering'), self.loop('tool.result', toolCallId='call1', result=dict(output='result'))])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        blocks = [block for row in rows for block in row['record'].get('blocks', [])]
        self.assertEqual([block['type'] for block in blocks], ['tool_call', 'tool_result', 'text'])
        self.assertEqual(blocks[0]['toolCallID'], 'call1')
        self.assertEqual(blocks[1]['toolCallID'], 'call1')
        self.assertEqual(blocks[2]['text'], 'steering')

    def test_interrupted_calls_settle_in_insertion_order_only_at_next_step(self):
        path, client, thread = self.start([self.loop('step.begin', uuid='s1'),
            self.loop('tool.call', stepUuid='s1', toolCallId='z', name='Read'),
            self.loop('tool.call', stepUuid='s1', toolCallId='a', name='Read'), self.message('deferred'),
            self.loop('step.end', uuid='s1', finishReason='interrupted')])
        _, rows, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertNotIn('deferred', self.text(rows))
        self.assertFalse(any(b['type'] == 'tool_result' for r in rows for b in r['record'].get('blocks', [])))
        segment = end['window']['segmentID']; self.window_ack(client, thread, end, [segment], segment)
        self.append(path, [self.loop('step.begin', uuid='s2')])
        _, rows, _ = self.window_page(client, thread, 'head', end['window']['version'], end['liveCursor'])
        results = [b for r in rows for b in r['record'].get('blocks', []) if b['type'] == 'tool_result']
        self.assertEqual([b['toolCallID'] for b in results], ['z', 'a'])
        self.assertIn('deferred', self.text(rows))

    def test_undo_replaces_generation_and_retains_compacted_history(self):
        path, client, thread = self.start([self.message('old'), self.message('old reply', 'assistant'),
            dict(type='context.apply_compaction', summary='summary', compactedCount=2),
            self.message('undo me'), self.message('undo reply', 'assistant')], '1.5')
        begin, rows, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(self.text(rows), ['old', 'old reply', 'summary', 'undo me', 'undo reply'])
        segment = end['window']['segmentID']; self.window_ack(client, thread, end, [segment], segment)
        self.append(path, [dict(type='context.undo', count=2)])
        client.sendall(frame(dict(kind='window.read', id='undo', thread=thread, operation='head',
            windowVersion=end['window']['version'], cursor=end['liveCursor'])))
        failure = receive(client)
        self.assertEqual(failure.get('code'), 'sourceChanged', failure)
        # A new client has no stale retained window and gets the canonical history.
        other, _ = self.client()
        new, rows, _ = self.window_page(other, thread, 'bootstrap', 0)
        self.assertNotEqual(begin['sourceIdentity'], new['sourceIdentity'])
        self.assertEqual(self.text(rows), ['old', 'old reply', 'summary'])

    def test_unknown_records_and_parts_are_not_eaten(self):
        _, client, thread = self.start([dict(type='future.event'), self.message('known'),
            dict(type='context.append_message', message=dict(role='assistant', content=[dict(type='future.part')]))])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(sum(r['record'].get('unparsedContentCount', 0) for r in rows), 2)

    def test_deleted_index_membership_revokes_existing_handle(self):
        _, client, thread = self.start([self.message('synthetic')])
        self.append(self.root / 'kimi/session_index.jsonl', [dict(sessionId='session_synthetic', deleted=True)])
        client.sendall(frame(dict(kind='bootstrap', id='deleted', thread=thread)))
        self.assertEqual(receive(client).get('code'), 'sourceNotAuthorized')

    def test_main_and_child_inventory_are_distinct_and_unindexed_files_are_excluded(self):
        path, client, _ = self.start([self.message('main')])
        child = path.parent.parent / 'child/wire.jsonl'; child.parent.mkdir()
        self.append(child, [dict(type='metadata', protocol_version='1.4'), self.message('child')])
        client.sendall(frame(dict(kind='inventory', id='inventory', provider='kimi')))
        rows = []
        while True:
            row = receive(client)
            if row['kind'] == 'inventory.end': break
            self.assertNotEqual(row['kind'], 'error', row)
            if row['kind'] == 'inventory.thread': rows.append(row)
        self.assertEqual({r['sessionID'] for r in rows}, {'session_synthetic', 'session_synthetic@child'})

    def test_history_and_search_use_same_replay_order(self):
        _, client, thread = self.start([self.message('message ' + str(n)) for n in range(240)])
        _, rows, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(self.text(rows), ['message ' + str(n) for n in range(140, 240)])
        segment = end['window']['segmentID']; self.window_ack(client, thread, end, [segment], segment)
        _, rows, _ = self.window_page(client, thread, 'before', end['window']['version'], end['window']['before'])
        self.assertEqual(self.text(rows), ['message ' + str(n) for n in range(40, 140)])

    def test_late_assistant_content_precedes_calls_and_results(self):
        _, client, thread = self.start([self.loop('step.begin', uuid='s'),
            self.loop('content.part', stepUuid='s', part=dict(type='text', text='A')),
            self.loop('tool.call', stepUuid='s', toolCallId='t', name='Read'),
            self.loop('tool.result', toolCallId='t', result=dict(output='R')),
            self.loop('content.part', stepUuid='s', part=dict(type='text', text='B')),
            self.loop('step.end', uuid='s')])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        blocks = [b for r in rows for b in r['record'].get('blocks', [])]
        self.assertEqual([b['type'] for b in blocks], ['text', 'text', 'tool_call', 'tool_result'])
        self.assertEqual(self.text(rows), ['A', 'B'])

    def test_deferred_compaction_marker_remains_an_undo_boundary(self):
        _, client, thread = self.start([self.message('old'), self.loop('step.begin', uuid='s'),
            self.loop('tool.call', stepUuid='s', toolCallId='t', name='Read'),
            self.message('boundary', origin=dict(kind='compaction_summary')),
            self.loop('tool.result', toolCallId='t', result=dict(output='R')),
            self.loop('step.end', uuid='s'), self.message('new'), dict(type='context.undo', count=2)])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(self.text(rows), ['old', 'boundary'])

    def test_origin_attachments_bundled_skills_and_typed_system_notices(self):
        message = self.message('skill context', origin=dict(kind='user',
            skillActivations=[dict(activationId='a', skillName='review')],
            attachments=[dict(name='fixture.txt', mediaType='text/plain', size=123, path='/not-read')]))
        message['message']['content'].append(dict(type='text', text='authored request'))
        _, client, thread = self.start([message, dict(type='turn.ended', turnId=1, reason='failed', error=dict(message='synthetic failure')),
            self.message('background update', origin=dict(kind='background_task', taskId='t', status='completed', notificationId='n'))])
        begin, rows, end = self.window_page(client, thread, 'bootstrap', 0)
        blocks = [b for r in rows for b in r['record'].get('blocks', [])]
        self.assertTrue(any(b.get('type') == 'system-event' and b.get('text') == 'skill context' for b in blocks))
        self.assertIn('authored request', self.text(rows))
        self.assertNotIn('skill context', self.text(rows))
        attachment = next(b for b in blocks if b['type'] == 'attachment')
        self.assertEqual(attachment['name'], 'fixture.txt')
        self.assertNotIn('/not-read', json.dumps(rows))
        error = next(r['record'] for r in rows if r['record'].get('providerSystemMessage'))
        self.assertEqual(error['role'], 'system'); self.assertIn('synthetic failure', json.dumps(error))
        self.assertFalse(any(r['record'].get('unparsedContentCount', 0) for r in rows))
        matches = self.core_search(begin, rows, end, 'synthetic failure')
        if matches is not None:
            self.assertIn('synthetic failure', json.dumps(matches), 'typed Kimi errors must remain displayable and searchable in Core')

    def test_malformed_known_nested_types_are_explicit(self):
        bad_call = self.message('known', 'assistant')
        bad_call['message']['toolCalls'] = [dict(type='future-call', id='t', name='Read', arguments=17)]
        _, client, thread = self.start([bad_call,
            self.message('future origin', origin=dict(kind='future-origin')),
            self.loop('step.begin', uuid='s'), self.loop('tool.call', stepUuid='s', toolCallId='t', name='Read'),
            self.loop('tool.result', toolCallId='t', result=dict(output='failure', isError='true')),
            dict(type='context.append_message', message=dict(role='system', content=[dict(type='future-part')], toolCalls=[]))])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(sum(r['record'].get('unparsedContentCount', 0) for r in rows), 4)

    def test_duplicate_tombstone_is_not_accepted_as_active(self):
        _, client, thread = self.start([self.message('synthetic')])
        with (self.root / 'kimi/session_index.jsonl').open('a') as output:
            output.write('{"sessionId":"session_synthetic","deleted":false,"deleted":true}\n')
        client.sendall(frame(dict(kind='bootstrap', id='ambiguous', thread=thread)))
        self.assertEqual(receive(client).get('code'), 'kimiIndexUnproven')

    def test_duplicate_undo_count_fails_closed(self):
        path, client, thread = self.start([self.message('synthetic')])
        with path.open('a') as output: output.write('{"type":"context.undo","count":1,"count":2}\n')
        client.sendall(frame(dict(kind='window.read', id='ambiguous', thread=thread, operation='bootstrap', windowVersion=0)))
        self.assertEqual(receive(client).get('code'), 'kimiIndexUnproven')

    def test_inventory_reuses_large_index_instead_of_restarting_a_read_slice(self):
        _, client, _ = self.start([self.message('first')])
        root = self.root / 'kimi'; entries = []
        for i in range(110):
            directory = root / ('sessions/work/session_' + str(i))
            path = directory / 'agents/main/wire.jsonl'; path.parent.mkdir(parents=True)
            self.append(path, [dict(type='metadata', protocol_version='1.4'), self.message('synthetic')])
            entries.append(dict(sessionId=directory.name, sessionDir=str(directory), workDir='/synthetic', ignored='x' * 4096))
        self.append(root / 'session_index.jsonl', entries)
        client.sendall(frame(dict(kind='inventory', id='many', provider='kimi', limit=500)))
        count = 0
        while True:
            row = receive(client)
            if row['kind'] == 'inventory.end': break
            self.assertNotEqual(row['kind'], 'error', row)
            if row['kind'] == 'inventory.thread': count += 1
        self.assertEqual(count, 111)

    def test_inventory_walk_longer_than_a_slice_reads_each_header_once(self):
        # A real host: the walk over thousands of Claude transcripts outlasted
        # one 250 ms read slice, so every uncached Kimi header after it yielded
        # and reran the whole walk. 80 headers took 88 s instead of one walk.
        projects = self.root / 'claude/projects'
        for i in range(3000):
            project = projects / f'-work-{i % 60}'; session = f'00000000-0000-4000-8000-{i:012d}'
            (project / session / 'subagents').mkdir(parents=True)
            (project / f'{session}.jsonl').write_text('{"type":"user","uuid":"u","message":{"role":"user","content":"x"}}\n')
            (project / session / 'subagents/agent-a.jsonl').write_text('{"type":"user","uuid":"u","isSidechain":true}\n')
        root = self.root / 'kimi'; entries = []
        for i in range(80):
            directory = root / ('sessions/work/session_' + str(i))
            path = directory / 'agents/main/wire.jsonl'; path.parent.mkdir(parents=True)
            self.append(path, [dict(type='metadata', protocol_version='1.4'), self.message('synthetic')])
            entries.append(dict(sessionId=directory.name, sessionDir=str(directory), workDir='/synthetic'))
        root.mkdir(exist_ok=True); self.append(root / 'session_index.jsonl', entries)
        (root / 'session_index.jsonl').chmod(0o600)
        self.service(idle=30000, lease=30000)
        client, _ = self.client()
        started = time.monotonic()
        client.sendall(frame(dict(kind='inventory', id='walk', limit=500)))
        # One walk is well under a second here; rerunning it per header is 20 s+.
        begin = receive(client, timeout=10)
        self.assertEqual(begin['kind'], 'inventory.begin', begin)
        self.assertLess(time.monotonic() - started, 10)
        # The walk read every header: each Kimi session is listed.
        kimi = 0
        while True:
            row = receive(client)
            self.assertNotEqual(row['kind'], 'error', row)
            kimi += row['kind'] == 'inventory.thread' and row['provider'] == 'kimi'
            if row['kind'] != 'inventory.end': continue
            if not row['hasMore']: break
            client.sendall(frame(dict(kind='inventory', id='walk', limit=500, cursor=row['cursor'])))
        self.assertEqual(kimi, 80)

    def test_warm_header_duplicate_rewrite_with_growth_fails_closed(self):
        path, client, thread = self.start([])
        header = dict(type='metadata', protocol_version='1.4', reserved_version='1.4', padding='x' * 256)
        path.write_text(json.dumps(header) + '\n')
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        segment = end['window']['segmentID']; self.window_ack(client, thread, end, [segment], segment)
        raw = path.read_bytes(); rewritten = raw.replace(b'"reserved_version"', b'"protocol_version"')
        self.assertEqual(len(raw), len(rewritten)); self.assertEqual(raw[-64:], rewritten[-64:])
        path.write_bytes(rewritten); self.append(path, [self.message('append after rewrite')])
        client.sendall(frame(dict(kind='window.read', id='duplicate-header', thread=thread, operation='head',
            windowVersion=end['window']['version'], cursor=end['liveCursor'])))
        self.assertEqual(receive(client).get('code'), 'kimiIndexUnproven')

    def test_image_before_bundled_skill_and_encrypted_reasoning(self):
        message = self.message('skill body', origin=dict(kind='user', skillActivations=[dict(activationId='a', skillName='review')]))
        message['message']['content'].insert(0, dict(type='image_url', imageUrl=dict(url='blob:never-resolve')))
        message['message']['content'].append(dict(type='text', text='authored'))
        _, client, thread = self.start([message, self.loop('step.begin', uuid='s'),
            self.loop('content.part', stepUuid='s', part=dict(type='think', think='', encrypted='never-display')),
            self.loop('step.end', uuid='s')])
        _, rows, _ = self.window_page(client, thread, 'bootstrap', 0)
        self.assertFalse(any(r['record'].get('unparsedContentCount', 0) for r in rows))
        self.assertEqual(self.text(rows), ['authored'])
        self.assertNotIn('never-display', json.dumps(rows)); self.assertNotIn('never-resolve', json.dumps(rows))
        blocks = [b for r in rows for b in r['record'].get('blocks', [])]
        self.assertEqual([b['type'] for b in blocks], ['attachment', 'system-event', 'text', 'attachment'])


if __name__ == '__main__':
    unittest.main(argv=[__file__])
