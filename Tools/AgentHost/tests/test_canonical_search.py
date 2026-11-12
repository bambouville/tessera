"""Stateless search must select the same canonical history as display."""
import base64
import ctypes
import json
import os
import sqlite3
import threading
import time
import unittest
import test_service as service
from test_service import frame, receive


class CanonicalSearchTests(unittest.TestCase):
    setUp = service.ServiceTests.setUp
    tearDown = service.ServiceTests.tearDown
    client = service.ServiceTests.client
    resolve = service.ServiceTests.resolve
    read_page = service.ServiceTests.read_page
    page = service.ServiceTests.page
    window_page = service.ServiceTests.window_page
    window_ack = service.ServiceTests.window_ack
    service = service.ServiceTests.service

    def start(self, provider, rows):
        self.provider = provider
        self.session = '00000000-0000-0000-0000-000000000001'
        path = self.root / provider / ('sessions' if provider == 'codex' else 'projects/project') / (self.session + '.jsonl')
        path.parent.mkdir(parents=True)
        self.append(path, rows)
        # Never execute an ambient provider, even if canonical authority fails.
        executable = self.root / 'bin/codex'; executable.parent.mkdir()
        executable.write_text('#!/bin/sh\nprintf "codex-cli 0.0.0\\n"\n'); executable.chmod(0o700)
        self.service(idle=30000, lease=30000, extra_environment={'PATH': str(executable.parent)})
        client, _ = self.client()
        return path, client, self.resolve(client, path, provider)

    @staticmethod
    def append(path, rows):
        with path.open('a') as stream:
            for row in rows: stream.write(json.dumps(row) + '\n')

    @staticmethod
    def message(identity, parent=None):
        return dict(type='user', uuid=identity, parentUuid=parent, message=dict(role='user', content='synthetic ' + identity))

    def core_search(self, page):
        library = os.environ.get('TESSERA_AGENT_CORE_LIBRARY')
        if not library: return
        begin, rows, end = page
        function = ctypes.CDLL(library).tessera_agent_page_search
        function.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]
        function.restype = ctypes.c_int32
        request = json.dumps(dict(wire=base64.b64encode(b''.join(frame(row) for row in [begin, *rows, end])).decode(),
            epoch=begin['serviceEpoch'], thread=begin['thread'], query='synthetic', threadID=dict(
                hostID='A11CE000-0000-4000-8000-000000000001', providerID=dict(rawValue=self.provider), providerSessionID=self.session))).encode()
        count = function(request, len(request), None, 0)
        self.assertGreater(count, 0, 'canonical search wire rejected by shared Core')
        output = ctypes.create_string_buffer(count)
        self.assertEqual(function(request, len(request), output, count), count)
        matches = json.loads(output.raw)
        self.assertEqual([row['recordID'] for row in matches], [row['recordID'] for row in rows])

    def test_claude_search_omits_obsolete_branch_and_does_not_move_window(self):
        rows = [self.message('root'), self.message('obsolete', 'root')]
        rows += [self.message('main-' + str(i), 'main-' + str(i - 1) if i else 'root') for i in range(150)]
        path, client, thread = self.start('claude', rows)
        display = self.window_page(client, thread, 'bootstrap', 0)
        head = display[2]['window']['segmentID']
        self.window_ack(client, thread, display[2], [head], head)
        newest = self.page(client, thread)
        self.assertEqual(newest[0]['sourceIdentity'], display[0]['sourceIdentity'])
        self.assertEqual([r['recordID'] for r in newest[1]], [r['recordID'] for r in display[1]])
        self.core_search(newest)
        older = self.page(client, thread, 'history', newest[2]['historyCursor'])
        self.assertEqual(len(older[1]), 51)
        self.assertFalse(older[2]['hasOlder'])
        self.assertFalse(any('obsolete' in json.dumps(r['record']) for r in newest[1] + older[1]))
        self.core_search(older)
        self.append(path, [self.message('new', 'main-149')])
        advanced = self.window_page(client, thread, 'head', display[2]['window']['version'], display[2]['liveCursor'])
        self.assertEqual(advanced[1][-1]['record']['blocks'][0]['text'], 'synthetic new')

    def test_claude_changed_branch_rejects_search_history_cursor(self):
        rows = [self.message('r' + str(i), 'r' + str(i - 1) if i else None) for i in range(150)]
        path, client, thread = self.start('claude', rows)
        page = self.page(client, thread)
        self.append(path, [self.message('replacement', 'r0')])
        client.sendall(frame(dict(kind='history', id='changed', thread=thread, cursor=page[2]['historyCursor'])))
        self.assertEqual(receive(client)['code'], 'sourceChanged')

    def test_codex_search_uses_latest_completed_items_and_rejects_stateless_live(self):
        session = '00000000-0000-0000-0000-000000000001'
        def item(ordinal, identity, text):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=session, turn_id='turn',
                item=dict(type='AgentMessage', id=identity, content=[dict(type='Text', text='synthetic ' + text)])))
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=session, history_mode='paginated'))]
        rows += [item(i + 1, 'item-' + str(i), str(i)) for i in range(150)]
        rows.append(item(151, 'item-149', 'revised'))
        path, client, thread = self.start('codex', rows)
        display = self.window_page(client, thread, 'bootstrap', 0)
        head = display[2]['window']['segmentID']
        self.window_ack(client, thread, display[2], [head], head)
        newest = self.page(client, thread)
        self.assertEqual(newest[0]['sourceIdentity'], display[0]['sourceIdentity'])
        self.assertEqual([r['recordID'] for r in newest[1]], [r['recordID'] for r in display[1]])
        self.assertEqual(newest[1][-1]['record']['blocks'][0]['text'], 'synthetic revised')
        self.core_search(newest)
        older = self.page(client, thread, 'history', newest[2]['historyCursor'])
        self.assertEqual(len(older[1]), 50)
        self.core_search(older)
        self.append(path, [item(152, 'item-149', 'revised again')])
        client.sendall(frame(dict(kind='updates', id='no-silent-loss', thread=thread, cursor=newest[2]['liveCursor'])))
        self.assertEqual(receive(client)['code'], 'windowSubscriptionRequired')
        advanced = self.window_page(client, thread, 'head', display[2]['window']['version'], display[2]['liveCursor'])
        self.assertTrue(any(r['record']['blocks'][0]['text'] == 'synthetic revised again' for r in advanced[1]))

    def test_host_search_reports_a_codex_rollout_archived_mid_search(self):
        session = '00000000-0000-0000-0000-000000000001'
        def item(ordinal, identity, text):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=session, turn_id='turn',
                item=dict(type='AgentMessage', id=identity, content=[dict(type='Text', text=text)])))
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=session, history_mode='paginated'))]
        rows += [item(i + 1, 'item-' + str(i), 'needle %d %s' % (i, 'z' * 20000)) for i in range(40)]
        path, client, thread = self.start('codex', rows)
        expected = [row['recordID'] for row in self.display_records(client, thread)]
        self.assertEqual(len(expected), 40)
        frames = self.host_search(client, 'codex-first', query='needle', threads=[thread])
        found = [value['recordID'] for value in frames if value['kind'] == 'search.record']
        cursor = frames[-1].get('cursor')
        self.assertTrue(cursor and 0 < len(found) < 40, frames[-1])
        # Codex archives the rollout between replies. Its records are then
        # another source's, so the rest of the thread is reported unread,
        # never silently ended.
        archived = self.root / 'codex/archived_sessions' / path.name
        archived.parent.mkdir(parents=True)
        path.rename(archived)
        skipped = []
        while cursor:
            frames = self.host_search(client, 'codex-%d' % len(found), cursor=cursor)
            skipped += [(value['thread'], value['code']) for value in frames if value['kind'] == 'search.skipped']
            found += [value['recordID'] for value in frames if value['kind'] == 'search.record']
            cursor = frames[-1].get('cursor')
        self.assertEqual([handle for handle, _ in skipped], [thread], skipped)
        self.assertEqual(found, expected[:len(found)])
        # A new search reads the archived rollout whole.
        client, _ = self.client()
        moved = self.resolve(client, archived, 'codex')
        expected = [row['recordID'] for row in self.display_records(client, moved)]
        frames, found = [], []
        cursor = None
        while True:
            frames = self.host_search(client, 'codex-new-%d' % len(found), **(dict(cursor=cursor) if cursor else dict(query='needle', threads=[moved])))
            found += [value['recordID'] for value in frames if value['kind'] == 'search.record']
            cursor = frames[-1].get('cursor')
            if not cursor: break
        self.assertEqual((len(found), found), (40, expected))

    def host_search(self, client, request_id, **fields):
        # A whole reply: search.begin, records and skipped threads, search.end.
        client.sendall(frame(dict(kind='search', id=request_id, **fields)))
        frames = [receive(client, timeout=10)]
        if frames[0]['kind'] == 'error': return frames
        self.assertEqual(frames[0]['kind'], 'search.begin', frames[0])
        while frames[-1]['kind'] != 'search.end':
            frames.append(receive(client, timeout=10))
            self.assertIn(frames[-1]['kind'], ('search.record', 'search.skipped', 'search.end'), frames[-1])
        self.assertLess(sum(len(frame(value)) for value in frames), 1024 * 1024, 'a reply stays far below the peer queue')
        return frames

    def display_records(self, client, thread):
        # Every display page, newest first, as the app would page them.
        page = self.page(client, thread)
        records = list(reversed(page[1]))
        while page[2].get('hasOlder'):
            page = self.page(client, thread, 'history', page[2]['historyCursor'])
            records += reversed(page[1])
        return records

    def claude_thread(self, client, session, rows):
        path = self.root / 'claude/projects/project' / (session + '.jsonl')
        self.append(path, rows)
        return path, self.resolve(client, path)

    def test_host_search_finds_every_thread_by_display_record_ids(self):
        texts = {'match-case': 'the NeEdLe here', 'match-mark': 'a n\u00eae\u0301dle too', 'match-escape': 'line\n"needle"\ttab',
                 'miss': 'nothing to see', 'miss-split': 'nee dle'}
        rows = [dict(type='user', uuid=key, parentUuid=None if index == 0 else list(texts)[index - 1],
                     message=dict(role='user', content=text)) for index, (key, text) in enumerate(texts.items())]
        _, client, first = self.start('claude', rows)
        _, second = self.claude_thread(client, '00000000-0000-0000-0000-000000000002', [self.message('other-needle')])
        display = {thread: self.page(client, thread) for thread in (first, second)}
        frames = self.host_search(client, 'find', query='NÉEDLE', threads=[first, second, 'unknown_handle'])
        records = [value for value in frames if value['kind'] == 'search.record']
        found = {thread: {value['recordID'] for value in records if value['thread'] == thread} for thread in (first, second)}
        self.assertEqual(len(found[first]), 3, records)
        self.assertEqual(len(found[second]), 1, records)
        for thread, page in display.items():
            self.assertTrue(found[thread] <= {row['recordID'] for row in page[1]}, 'record IDs are the display ones')
            for value in records:
                if value['thread'] == thread:
                    shown = next(row for row in page[1] if row['recordID'] == value['recordID'])
                    self.assertEqual(value['record'], shown['record'])
                    self.assertEqual(value['sourceIdentity'], page[0]['sourceIdentity'])
        skipped = [value for value in frames if value['kind'] == 'search.skipped']
        self.assertEqual([value['thread'] for value in skipped], ['unknown_handle'])
        end = frames[-1]
        self.assertEqual(end['records'], 4)
        self.assertEqual(end['threadsLeft'], 0)
        self.assertNotIn('cursor', end)

    def test_host_search_resumes_a_large_page_without_losing_or_repeating_a_record(self):
        # Sixty long matches (about 9 KB each once bounded) fill more than one
        # reply: each continues at the record the last one stopped before,
        # inside the same page.
        rows = [self.message('r0')]
        for index in range(1, 91):
            text = ('needle ' if index % 3 else 'hay ') + str(index) + ' ' + 'x' * 40000
            rows.append(dict(type='user', uuid='r' + str(index), parentUuid='r' + str(index - 1), message=dict(role='user', content=text)))
        _, client, thread = self.start('claude', rows)
        expected = [row['recordID'] for row in self.display_records(client, thread) if 'needle' in json.dumps(row['record'])]
        self.assertEqual(len(expected), 60)
        found, cursor, replies, paused = [], None, 0, False
        while True:
            fields = dict(cursor=cursor) if cursor else dict(query='needle', threads=[thread], limit=100)
            frames = self.host_search(client, 'resume-' + str(replies), **fields)
            replies += 1
            found += [value['recordID'] for value in frames if value['kind'] == 'search.record']
            self.assertLess(sum(len(frame(value)) for value in frames), 256 * 1024, 'one reply keeps its budget')
            cursor = frames[-1].get('cursor')
            if not cursor: break
            # One thread still left: the reply stopped inside its history.
            paused = paused or frames[-1]['threadsLeft'] == 1
            self.assertLess(replies, 10)
        self.assertGreater(replies, 1, 'the matches must not fit one reply')
        self.assertTrue(paused)
        self.assertEqual(found, expected, 'newest first, each exactly once')

    def test_host_search_reads_every_candidate_until_the_client_is_satisfied(self):
        # No cap by default: a common word cannot hide older exact matches
        # behind newer prefilter hits. A satisfied thread is read no further.
        rows = [dict(type='user', uuid='n' + str(index), parentUuid='n' + str(index - 1) if index else None,
                     message=dict(role='user', content='needle ' + str(index) + ' ' + 'z' * 20000)) for index in range(60)]
        _, client, busy = self.start('claude', rows)
        _, quiet = self.claude_thread(client, '00000000-0000-0000-0000-000000000002',
                                      [self.message('a-needle'), self.message('b-needle', 'a-needle')])
        expected = {thread: [row['recordID'] for row in self.display_records(client, thread)] for thread in (busy, quiet)}
        self.assertEqual(len(expected[busy]), 60)

        def run(satisfy):
            found, cursor, replies = [], None, 0
            while True:
                if cursor: fields = dict(cursor=cursor, satisfied=[busy] if satisfy else [])
                else: fields = dict(query='needle', threads=[busy, quiet])
                frames = self.host_search(client, 'all-%s-%d' % (satisfy, replies), **fields)
                replies += 1
                found += [(value['thread'], value['recordID']) for value in frames if value['kind'] == 'search.record']
                cursor = frames[-1].get('cursor')
                if not cursor: return found, replies
                self.assertLess(replies, 20)

        found, replies = run(False)
        self.assertGreater(replies, 2)
        self.assertEqual(found, [(busy, record) for record in expected[busy]] + [(quiet, record) for record in expected[quiet]])
        found, replies = run(True)
        first = [record for thread, record in found if thread == busy]
        self.assertTrue(first and len(first) < 60, 'the first reply holds part of the busy thread')
        self.assertEqual(first, expected[busy][:len(first)])
        self.assertEqual([record for thread, record in found if thread == quiet], expected[quiet])
        self.assertEqual(replies, 2, 'satisfied: the next reply moves straight on')

    def test_host_search_skips_record_metadata_and_reads_labelled_records_only(self):
        # The project and branch ride every record; only the text names the needle.
        rows = [dict(type='user', uuid='m' + str(index), parentUuid='m' + str(index - 1) if index else None,
                     cwd='/work/needleproject', gitBranch='needlebranch', timestamp='2026-11-10T00:00:00Z',
                     message=dict(role='user', content='a needle here' if index == 3 else 'plain ' + str(index)))
                for index in range(8)]
        _, client, thread = self.start('claude', rows)
        display = self.display_records(client, thread)
        self.assertIn('needleproject', json.dumps([row['record'] for row in display]), 'the fixture carries the project')
        frames = self.host_search(client, 'metadata', query='needle', threads=[thread])
        self.assertEqual([value['recordID'] for value in frames if value['kind'] == 'search.record'],
                         [row['recordID'] for row in display if 'a needle here' in json.dumps(row['record'])])
        # A word inside one of the app's labels ("Tool", "System event")
        # still selects: only a record the app labels is read for it.
        for index, query in enumerate(('TOOL', 'event', 'content')):
            frames = self.host_search(client, 'label-%d' % index, query=query, threads=[thread])
            self.assertEqual([value['kind'] for value in frames], ['search.begin', 'search.end'], query)
            self.assertEqual(frames[-1]['scannedRecords'], 8)

    def test_host_search_reads_a_record_the_app_labels_for_any_query(self):
        # An undecodable block: the app shows "Unsupported content · some
        # blocks could not be decoded" above the record's own text.
        rows = [dict(type='user', uuid='u0', parentUuid=None, message=dict(role='user', content='plain')),
                dict(type='assistant', uuid='u1', parentUuid='u0',
                     message=dict(role='assistant', content=[dict(type='text', text='hay'), dict(type='mystery_block', data=1)]))]
        _, client, thread = self.start('claude', rows)
        display = self.display_records(client, thread)
        labelled = {value['recordID'] for value in display if value['record'].get('unparsedContentCount')}
        self.assertEqual(len(labelled), 1, display)
        for index, query in enumerate(('could not be decoded', 'UNSUPPORTED', 'hay')):
            frames = self.host_search(client, 'labelled-%d' % index, query=query, threads=[thread])
            self.assertEqual({value['recordID'] for value in frames if value['kind'] == 'search.record'}, labelled, query)

    def test_host_search_reads_words_phrases_and_edit_diffs_as_the_app_shows_them(self):
        def row(index, role, content):
            return dict(type=role, uuid='w' + str(index), parentUuid='w' + str(index - 1) if index else None,
                        message=dict(role=role, content=content))
        rows = [row(0, 'user', 'plain 0'),
                row(1, 'assistant', [dict(type='text', text='hay'), dict(type='text', text='needle')]),
                row(2, 'assistant', [dict(type='tool_use', id='toolu_w2', name='Edit',
                                          input=dict(file_path='/work/a.py', old_string='say "hi"', new_string='say "bye"'))]),
                row(3, 'user', 'hay needle together')]
        _, client, thread = self.start('claude', rows)
        display = self.display_records(client, thread)
        def holding(fragment):
            return {value['recordID'] for value in display if fragment in json.dumps(value['record'])}
        split, edit, together = holding('"text": "hay"'), holding('"name": "Edit"'), holding('hay needle together')
        self.assertEqual((len(split), len(edit), len(together)), (1, 1, 1), display)
        self.assertEqual(split, holding('"text": "needle"'), 'both blocks ride one record')
        def found(query):
            frames = self.host_search(client, 'q' + str(len(query)), query=query, threads=[thread])
            return {value['recordID'] for value in frames if value['kind'] == 'search.record'}
        # Spaces only: the phrase lies in one value, as the app joins blocks
        # with newlines. Any other separator: each word, anywhere.
        self.assertEqual(found('hay needle'), together)
        self.assertEqual(found('HAY\nneedle'), split | together)
        # The app decodes an Edit call's input into a diff whose lines start
        # with - or +; the raw preview escapes the quotes.
        self.assertEqual(found('-say "hi"'), edit)
        self.assertEqual(found('+SAY "bye"'), edit)
        self.assertEqual(found('say "nope"'), set())
        # Under the hunk header the app writes: one line out, one in.
        self.assertEqual(found('@@ -0,1 +0,1 @@'), edit)
        self.assertEqual(found('-0,2'), set())
        # The app compares only the first character of ß's fold, s, then any
        # one character: "ß" finds "say".
        self.assertEqual(found('\u00df'), edit)

    def test_host_search_rejects_a_satisfied_thread_it_was_not_asked_about(self):
        rows = [dict(type='user', uuid='s' + str(index), parentUuid='s' + str(index - 1) if index else None,
                     message=dict(role='user', content='needle ' + str(index) + ' ' + 'z' * 20000)) for index in range(40)]
        _, client, thread = self.start('claude', rows)
        frames = self.host_search(client, 'first', query='needle', threads=[thread])
        cursor = frames[-1].get('cursor')
        self.assertTrue(cursor, frames[-1])
        for index, satisfied in enumerate((['other_handle'], thread, [7], [thread, 'other_handle'])):
            reply = self.host_search(client, 'bad-satisfied-' + str(index), cursor=cursor, satisfied=satisfied)
            self.assertEqual((reply[0]['kind'], reply[0].get('code')), ('error', 'invalidRequest'), satisfied)
        # A rejected list marks nothing: the thread is still read.
        frames = self.host_search(client, 'after', cursor=cursor)
        self.assertTrue(any(value['kind'] == 'search.record' for value in frames), frames[-1])

    def test_host_search_rejects_malformed_requests_and_foreign_cursors(self):
        rows = [self.message('r' + str(i), 'r' + str(i - 1) if i else None) for i in range(3)]
        _, client, thread = self.start('claude', rows)
        hello_client, hello = self.client()
        for index, fields in enumerate((dict(query='', threads=[thread]), dict(query='x' * 513, threads=[thread]),
                                        dict(query='synthetic', threads=thread), dict(query='synthetic', threads=[]),
                                        dict(query='synthetic', threads=[thread, thread]), dict(query='synthetic', threads=['bad/handle']),
                                        dict(query='synthetic', threads=[thread], limit=0), dict(query='synthetic', threads=[thread], limit=101),
                                        dict(query='\u0301', threads=[thread]), dict(query='\u200d \t', threads=[thread]),
                                        dict(query='synthetic', threads=[thread], thread=thread))):
            reply = self.host_search(client, 'bad-' + str(index), **json.loads(json.dumps(fields)))
            self.assertEqual(reply[0]['kind'], 'error', fields)
            self.assertEqual(reply[0]['code'], 'invalidRequest', fields)
        # A cursor reaches only the client that started the search.
        many = [self.claude_thread(client, '00000000-0000-0000-0000-0000000001%02d' % index,
                                   [dict(type='user', uuid='big' + str(index), parentUuid=None,
                                         message=dict(role='user', content='needle ' + 'y' * 60000))])[1] for index in range(40)]
        frames = self.host_search(client, 'owned', query='needle', threads=many)
        cursor = frames[-1].get('cursor')
        self.assertTrue(cursor, frames[-1])
        foreign = self.host_search(hello_client, 'foreign', cursor=cursor)
        self.assertEqual(foreign[0]['kind'], 'error')
        self.assertEqual(foreign[0]['code'], 'cursorExpired')
        self.assertIn('search.v1', hello['capabilities'])

    def codex_summary_fixture(self):
        session = '00000000-0000-0000-0000-000000000001'
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=session, history_mode='paginated'))]
        rows += [dict(ordinal=i + 1, type='event_msg', payload=dict(type='item_completed', thread_id=session,
            turn_id='turn', item=dict(type='AgentMessage', id='item-' + str(i),
                content=[dict(type='Text', text='synthetic visible reply ' + str(i))]))) for i in range(20)]
        return self.start('codex', rows)

    def summary(self, client, thread):
        client.sendall(frame(dict(kind='summary', id='card', thread=thread)))
        result = receive(client)
        self.assertEqual(result['kind'], 'summary', result)
        self.assertLessEqual(len(result['records']), 16, 'shared Core summary record limit')
        self.assertTrue(any('synthetic visible reply 19' in json.dumps(row) for row in result['records']))
        return result

    def seek(self, client, thread, version, cursor, match=None, order=None, source_offset=None, limit=40, record_id=None,
             token=True):
        # A seek to a search match: the frames of its page, or its error. The
        # match's seek token goes along, as the app sends it; `token=None`
        # leaves it out, as an app from before tokens did.
        request = dict(kind='window.read', id=f'seek_{version}', thread=thread, operation='seek', windowVersion=version,
                       cursor=cursor, order=match['order'] if match else order, limit=limit)
        offset = match.get('sourceOffset') if match and source_offset is None else source_offset
        if offset is not None: request['sourceOffset'] = offset
        identity = match['recordID'] if match and record_id is None else record_id
        if identity is not None: request['recordID'] = identity
        token = match.get('seekToken') if match and token is True else None if token is True else token
        if token is not None: request['seekToken'] = token
        client.sendall(frame(request))
        begin = receive(client, timeout=5)
        if begin['kind'] == 'error': return begin
        self.assertEqual(begin['kind'], 'page.begin', begin)
        records = []
        while True:
            item = receive(client)
            if item['kind'] == 'page.end': return begin, records, item
            self.assertEqual(item['kind'], 'page.record', item)
            records.append(item)

    def seek_fixture(self, count=300):
        rows = [self.message(f'm-{i:03}', f'm-{i - 1:03}' if i else None) for i in range(count)]
        path, client, thread = self.start('claude', rows)
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        ack = self.window_ack(client, thread, end, [head], head)
        return path, client, thread, head, ack

    def search_match(self, client, thread, text):
        frames = self.host_search(client, 'find-' + text, query='synthetic ' + text, threads=[thread])
        matches = [value for value in frames if value['kind'] == 'search.record']
        self.assertEqual(len(matches), 1, frames)
        return matches[0]

    def test_claude_seek_opens_at_a_search_match_and_pages_newer_to_the_live_head(self):
        path, client, thread, head, ack = self.seek_fixture()
        match = self.search_match(client, thread, 'm-037')
        self.assertIn('sourceOffset', match)
        begin, records, end = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertEqual((begin['operation'], end['window']['lane']), ('history', 'seek'))
        self.assertEqual(begin['sourceIdentity'], match['sourceIdentity'])
        # Ten rows of context above the match, then the match and newer rows.
        self.assertEqual([row['order'] for row in records], list(range(27, 67)))
        landed = next(row for row in records if row['order'] == match['order'])
        self.assertEqual((landed['recordID'], landed['sourceOffset']), (match['recordID'], match['sourceOffset']))
        self.assertTrue(end['window']['hasOlder'] and end['window']['hasNewer'])
        # The seek page becomes the viewport and the live head stays apart
        # (window_tests.cpp covers the ACKs a seek refuses).
        seek = end['window']['segmentID']
        landed_ack = self.window_ack(client, thread, end, [seek], head)
        self.assertEqual(landed_ack['liveCursor'], ack['liveCursor'])
        # Older and newer pages read from the match's page.
        _, older, before = self.window_page(client, thread, 'before', landed_ack['windowVersion'], end['window']['before'])
        self.assertEqual([row['order'] for row in older], list(range(0, 27)))
        # A row of a page carries the token its search result does, so the app
        # can seek to a match it found among loaded rows.
        self.assertEqual(older[10]['seekToken'], self.search_match(client, thread, 'm-010')['seekToken'])
        self.assertEqual(landed['seekToken'], match['seekToken'])
        self.window_ack(client, thread, before, [before['window']['segmentID'], seek], head)
        version, after, viewport = before['window']['version'], end['window']['after'], [before['window']['segmentID'], seek]
        orders = []
        while True:
            _, newer, page = self.window_page(client, thread, 'after', version, after, limit=100)
            orders += [row['order'] for row in newer]
            viewport.append(page['window']['segmentID'])
            self.window_ack(client, thread, page, viewport, head)
            version, after = page['window']['version'], page['window']['after']
            if not page['window']['hasNewer']: break
        self.assertEqual(orders, list(range(67, 300)))
        # The head still follows the transcript.
        self.append(path, [self.message('m-300', 'm-299')])
        _, appended, _ = self.window_page(client, thread, 'head', version, ack['liveCursor'])
        self.assertEqual(appended[-1]['record']['blocks'][0]['text'], 'synthetic m-300')

    def test_claude_seek_to_the_first_record_and_a_record_in_the_head(self):
        _, client, thread, head, ack = self.seek_fixture()
        _, records, end = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], self.search_match(client, thread, 'm-000'))
        self.assertEqual(records[0]['order'], 0)
        self.assertFalse(end['window']['hasOlder'])
        self.window_ack(client, thread, end, [end['window']['segmentID']], head)
        # A match the head already holds still lands with rows above it.
        _, records, end = self.seek(client, thread, end['window']['version'], ack['liveCursor'], self.search_match(client, thread, 'm-299'))
        self.assertEqual([row['order'] for row in records], list(range(289, 300)))
        self.assertFalse(end['window']['hasNewer'])

    def test_claude_seek_refuses_a_moved_record_and_a_cursor_that_is_not_live(self):
        _, client, thread, head, ack = self.seek_fixture()
        match = self.search_match(client, thread, 'm-150')
        moved = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match, source_offset=match['sourceOffset'] + 1,
                          token=None)
        self.assertEqual((moved['kind'], moved['code']), ('error', 'seekRecordMoved'))
        # A refused seek reports no read failure: the app opens at the newest page.
        self.assertNotIn('status', moved)
        # An order this generation never had is moved too, not a changed
        # source the app would rebuild its window for.
        beyond = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], order=100000,
                           record_id=match['sourceIdentity'] + ':100000')
        self.assertEqual((beyond['kind'], beyond['code']), ('error', 'seekRecordMoved'))
        self.assertNotIn('status', beyond)
        # Counted in another generation, the order must hold the record at
        # the search's offset.
        rebuilt = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match,
                            record_id=f"claude-chain:rebuilt:{match['order']}", source_offset=match['sourceOffset'] + 1, token=None)
        self.assertEqual((rebuilt['kind'], rebuilt['code']), ('error', 'seekRecordMoved'))
        unproven = dict(match); del unproven['sourceOffset']
        unproven = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], unproven,
                             record_id=f"claude-chain:rebuilt:{match['order']}", token=None)
        self.assertEqual((unproven['kind'], unproven['code']), ('error', 'seekRecordMoved'))
        # A token naming another record, or no record at all.
        other = self.search_match(client, thread, 'm-151')
        named = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match,
                          record_id=f"claude-chain:rebuilt:{match['order']}", token=other['seekToken'])
        self.assertEqual((named['kind'], named['code']), ('error', 'seekRecordMoved'))
        for token in ('', 'not-a-digest', match['seekToken'][:15], match['seekToken'] + ' ', match['seekToken'][:16] + ':v1:7'):
            malformed = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match, token=token)
            self.assertEqual((malformed['kind'], malformed['code']), ('error', 'invalidRequest'), token)
        unnamed = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], order=match['order'])
        self.assertEqual((unnamed['kind'], unnamed['code']), ('error', 'invalidRequest'))
        stale = self.seek(client, thread, ack['windowVersion'], 'not-a-live-cursor', match)
        self.assertEqual((stale['kind'], stale['code']), ('error', 'windowAnchorExpired'))
        old = self.seek(client, thread, ack['windowVersion'] + 5, ack['liveCursor'], match)
        self.assertEqual((old['kind'], old['code']), ('error', 'windowStale'))
        # None of those moved the window: the seek still lands.
        _, records, end = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertIn(match['order'], [row['order'] for row in records])
        self.window_ack(client, thread, end, [end['window']['segmentID']], head)

    def test_claude_seek_after_a_branch_opens_only_a_record_that_kept_its_order(self):
        path, client, thread, head, ack = self.seek_fixture()
        kept, lost = self.search_match(client, thread, 'm-050'), self.search_match(client, thread, 'm-150')
        # A branch back at m-100 numbers the path anew: m-050 keeps its order
        # and offset, while m-150's order now names a record of the branch.
        self.append(path, [self.message('fork', 'm-100')] +
                    [self.message(f'f-{i:03}', f'f-{i - 1:03}' if i else 'fork') for i in range(60)])
        client.sendall(frame(dict(kind='window.read', id='rebootstrap', thread=thread, operation='bootstrap',
                                  windowVersion=ack['windowVersion'])))
        begin, _, end = self.read_page(client)
        self.assertNotEqual(begin['sourceIdentity'], kept['sourceIdentity'])
        head = end['window']['segmentID']
        ack = self.window_ack(client, thread, end, [head], head)
        moved = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], lost)
        self.assertEqual((moved['kind'], moved['code']), ('error', 'seekRecordMoved'))
        _, records, _ = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], kept)
        landed = [row for row in records if row['order'] == kept['order']]
        self.assertEqual([(row['recordID'], row['sourceOffset']) for row in landed],
                         [(f"{begin['sourceIdentity']}:{kept['order']}", kept['sourceOffset'])])

    def test_claude_seek_refuses_another_record_a_rewrite_put_at_the_match(self):
        # Rewritten in place from the match on: another record starts at the
        # match's offset under the same order, in a new generation.
        path, client, thread, head, ack = self.seek_fixture()
        match = self.search_match(client, thread, 'm-150')
        self.assertTrue(match['seekToken'].endswith(':m-150'), match['seekToken'])
        os.truncate(path, match['sourceOffset'])
        self.append(path, [dict(type='user', uuid='other-150', parentUuid='m-149',
                                message=dict(role='user', content='synthetic replacement'))] +
                    [self.message(f'x-{i:03}', 'other-150' if i == 0 else f'x-{i - 1:03}') for i in range(160)])
        client.sendall(frame(dict(kind='window.read', id='rebootstrap', thread=thread, operation='bootstrap',
                                  windowVersion=ack['windowVersion'])))
        begin, _, end = self.read_page(client)
        self.assertNotEqual(begin['sourceIdentity'], match['sourceIdentity'])
        head = end['window']['segmentID']
        ack = self.window_ack(client, thread, end, [head], head)
        moved = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertEqual((moved['kind'], moved['code']), ('error', 'seekRecordMoved'))
        self.assertNotIn('status', moved)

    def test_claude_seek_lands_on_a_record_written_again_after_the_search(self):
        # Claude writes the same UUID again: a new generation, the UUID's
        # latest copy further down, still at the match's order.
        path, client, thread, head, ack = self.seek_fixture()
        match = self.search_match(client, thread, 'm-150')
        self.append(path, [self.message('m-150', 'm-149')])
        client.sendall(frame(dict(kind='window.read', id='rebootstrap', thread=thread, operation='bootstrap',
                                  windowVersion=ack['windowVersion'])))
        begin, _, end = self.read_page(client)
        self.assertNotEqual(begin['sourceIdentity'], match['sourceIdentity'])
        head = end['window']['segmentID']
        ack = self.window_ack(client, thread, end, [head], head)
        _, records, page = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertEqual(page['window']['lane'], 'seek')
        landed = [row for row in records if row['order'] == match['order']]
        self.assertEqual(len(landed), 1)
        self.assertGreater(landed[0]['sourceOffset'], match['sourceOffset'])
        self.assertEqual(landed[0]['seekToken'], match['seekToken'])
        # Without a token the moved offset refuses it, as before.
        ack = self.window_ack(client, thread, page, [page['window']['segmentID']], head)
        moved = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match, token=None)
        self.assertEqual((moved['kind'], moved['code']), ('error', 'seekRecordMoved'))

    def test_seek_lands_on_a_match_whose_index_the_cache_rebuilt(self):
        # Searching more threads than the host keeps indexes for evicts the
        # first ones; tapping a result rebuilds that index under a new
        # generation, where the record still holds its order and offset.
        rows = lambda tag: [self.message(f'{tag}-m-{i:03}', f'{tag}-m-{i - 1:03}' if i else None) for i in range(300)]
        _, client, first = self.start('claude', rows('t00'))
        threads = [first]
        for n in range(1, 30):
            _, handle = self.claude_thread(client, f'00000000-0000-0000-0000-{n + 1:012d}', rows(f't{n:02}'))
            threads.append(handle)
        matches, cursor, replies = [], None, 0
        while True:
            fields = dict(cursor=cursor) if cursor else dict(query='synthetic', threads=threads)
            frames = self.host_search(client, f'all-{replies}', **fields); replies += 1
            matches += [value for value in frames if value['kind'] == 'search.record']
            cursor = frames[-1].get('cursor')
            if not cursor: break
        match = next(value for value in matches if value['thread'] == first and 't00-m-050' in json.dumps(value['record']))
        _, _, end = self.window_page(client, first, 'bootstrap', 0)
        head = end['window']['segmentID']
        ack = self.window_ack(client, first, end, [head], head)
        begin, records, _ = self.seek(client, first, ack['windowVersion'], ack['liveCursor'], match)
        self.assertNotEqual(begin['sourceIdentity'], match['sourceIdentity'], 'the index was not rebuilt')
        landed = [row for row in records if row['order'] == match['order']]
        self.assertEqual([(row['recordID'], row['sourceOffset']) for row in landed],
                         [(f"{begin['sourceIdentity']}:{match['order']}", match['sourceOffset'])])

    def assert_seek_lands(self, client, thread, prefix):
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        ack = self.window_ack(client, thread, end, [head], head)
        match = self.search_match(client, thread, 'm-150')
        self.assertTrue(match['sourceIdentity'].startswith(prefix), match)
        self.assertIn('sourceOffset', match)
        moved = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match,
                          record_id=f"{prefix}rebuilt:{match['order']}", source_offset=match['sourceOffset'] + 1, token=None)
        self.assertEqual((moved['kind'], moved['code']), ('error', 'seekRecordMoved'))
        beyond = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], order=100000,
                           record_id=match['sourceIdentity'] + ':100000')
        self.assertEqual((beyond['kind'], beyond['code']), ('error', 'seekRecordMoved'))
        begin, records, page = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertEqual((begin['sourceIdentity'], page['window']['lane']), (match['sourceIdentity'], 'seek'))
        landed = [row for row in records if row['order'] == match['order']]
        self.assertEqual([row['recordID'] for row in landed], [match['recordID']])
        self.assertEqual(landed[0]['seekToken'], match['seekToken'])
        # Ten rows of context above the match.
        self.assertEqual(records[0]['order'], match['order'] - 10)
        landed_ack = self.window_ack(client, thread, page, [page['window']['segmentID']], head)
        # From a generation the cache has since replaced, the record at the
        # search's offset still opens, with its token or without one.
        for token in (True, None):
            _, records, page = self.seek(client, thread, landed_ack['windowVersion'], landed_ack['liveCursor'], match,
                                         record_id=f"{prefix}rebuilt:{match['order']}", token=token)
            self.assertIn(match['recordID'], [row['recordID'] for row in records])
            landed_ack = self.window_ack(client, thread, page, [page['window']['segmentID']], head)
        # Another record's token does not open it there.
        other = self.search_match(client, thread, 'm-151')
        named = self.seek(client, thread, landed_ack['windowVersion'], landed_ack['liveCursor'], match,
                          record_id=f"{prefix}rebuilt:{match['order']}", token=other['seekToken'])
        self.assertEqual((named['kind'], named['code']), ('error', 'seekRecordMoved'))
        return match, landed_ack['windowVersion']

    @staticmethod
    def kimi_message(text):
        return dict(type='context.append_message', agentId='main',
                    message=dict(role='user', content=[dict(type='text', text='synthetic ' + text)], toolCalls=[]))

    def kimi_thread(self, rows):
        # A Kimi session whose wire.jsonl starts with `rows`: (path, client, thread).
        root = self.root / 'kimi'
        directory = root / 'sessions/work/session_synthetic'
        path = directory / 'agents/main/wire.jsonl'
        path.parent.mkdir(parents=True)
        index = root / 'session_index.jsonl'
        index.write_text(json.dumps(dict(sessionId=directory.name, sessionDir=str(directory), workDir='/synthetic')) + '\n')
        index.chmod(0o600)
        self.append(path, [dict(type='metadata', protocol_version='1.5'), *rows])
        self.service(idle=30000, lease=30000)
        client, _ = self.client()
        return path, client, self.resolve(client, path, 'kimi')

    def replace_after(self, path, offset, rows):
        # The file replaced at its path: its bytes before `offset`, then `rows`.
        replacement = path.with_name('replacement.jsonl')
        with open(path, 'rb') as original: replacement.write_bytes(original.read(offset))
        replacement.chmod(path.stat().st_mode & 0o777)
        self.append(replacement, rows)
        os.replace(replacement, path)

    def rebootstrap(self, client, thread, version):
        client.sendall(frame(dict(kind='window.read', id='rebootstrap', thread=thread, operation='bootstrap', windowVersion=version)))
        begin, _, end = self.read_page(client)
        head = end['window']['segmentID']
        return begin, self.window_ack(client, thread, end, [head], head)

    def test_kimi_seek_opens_at_a_match_of_its_generation_only(self):
        message = self.kimi_message
        path, client, thread = self.kimi_thread([message(f'm-{i:03}') for i in range(300)])
        match, version = self.assert_seek_lands(client, thread, 'kimi-history:')
        # Kimi records have no IDs of their own: the token is the record's
        # content, and a file replaced at its path with other records from
        # the match on puts other content at its offset, under the same order.
        self.assertNotIn(':', match['seekToken'])
        self.replace_after(path, match['sourceOffset'], [message(f'x-{i:03}') for i in range(150, 320)])
        _, ack = self.rebootstrap(client, thread, version)
        moved = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertEqual((moved['kind'], moved['code']), ('error', 'seekRecordMoved'))
        # Without a token the offset alone opens the other record there.
        _, records, _ = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match, token=None)
        landed = [row for row in records if row['order'] == match['order']]
        self.assertIn('synthetic x-150', json.dumps(landed))

    def test_kimi_seek_refuses_another_calls_interrupted_result_a_rewrite_put_at_the_match(self):
        # The result the host writes for a call a step left unanswered is
        # named after its offset, not by Kimi: its token is its content.
        loop = lambda kind, **fields: dict(type='context.append_loop_event', agentId='main', event=dict(type=kind, **fields))
        tail = lambda call: [loop('tool.call', stepUuid='s1', toolCallId=call, name='Read'),
                             loop('step.end', uuid='s1', finishReason='interrupted'), loop('step.begin', uuid='s2'),
                             *[self.kimi_message(f'after-{i:03}') for i in range(20)]]
        path, client, thread = self.kimi_thread([*[self.kimi_message(f'm-{i:03}') for i in range(100)], loop('step.begin', uuid='s1')])
        cut = path.stat().st_size
        self.append(path, tail('call-AAAA'))
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        ack = self.window_ack(client, thread, end, [head], head)
        frames = self.host_search(client, 'find-interrupted', query='interrupted before its result', threads=[thread])
        matches = [value for value in frames if value['kind'] == 'search.record']
        self.assertEqual(len(matches), 1, frames)
        match = matches[0]
        self.assertIn('call-AAAA', json.dumps(match['record']))
        self.assertNotIn(':', match['seekToken'])
        _, records, page = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertIn('call-AAAA', json.dumps([row for row in records if row['order'] == match['order']]))
        # Another call in its place, at the same offset and order.
        self.replace_after(path, cut, tail('call-BBBB'))
        begin, ack = self.rebootstrap(client, thread, self.window_ack(client, thread, page, [page['window']['segmentID']], head)['windowVersion'])
        self.assertNotEqual(begin['sourceIdentity'], match['sourceIdentity'])
        moved = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertEqual((moved['kind'], moved['code']), ('error', 'seekRecordMoved'))

    def test_pi_seek_opens_at_a_match_of_its_generation_only(self):
        root = self.root / 'pi'
        path = root / 'sessions/--synthetic--/timestamp_synthetic-session.jsonl'
        path.parent.mkdir(parents=True)
        rows = [dict(type='session', version=3, id='synthetic-session', cwd='/synthetic')]
        rows += [dict(type='message', id=f'm-{i:03}', parentId=f'm-{i - 1:03}' if i else None,
                      message=dict(role='user', content=f'synthetic m-{i:03}')) for i in range(300)]
        self.append(path, rows)
        self.service(idle=30000, lease=30000, extra_environment={'PI_CODING_AGENT_DIR': str(root)})
        client, _ = self.client()
        self.assert_seek_lands(client, self.resolve(client, path, 'pi'), 'pi-chain:')

    def test_codex_seek_lands_on_a_match_and_on_a_revised_item(self):
        session = '00000000-0000-0000-0000-000000000001'
        def item(ordinal, identity, text):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=session, turn_id='turn',
                item=dict(type='AgentMessage', id=identity, content=[dict(type='Text', text='synthetic ' + text)])))
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=session, history_mode='paginated'))]
        rows += [item(i + 1, f'item-{i:03}', f'reply-{i:03}') for i in range(300)]
        rows.append(item(301, 'item-120', 'revised-120'))
        _, client, thread = self.start('codex', rows)
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        ack = self.window_ack(client, thread, end, [head], head)
        for text, identity in (('reply-037', 'item-037'), ('revised-120', 'item-120')):
            match = self.search_match(client, thread, text)
            _, records, page = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
            self.assertEqual(page['window']['lane'], 'seek')
            landed = [row for row in records if row['order'] == match['order']]
            self.assertEqual([row['recordID'] for row in landed], [match['recordID']])
            self.assertEqual(landed[0]['record']['blocks'][0]['text'], 'synthetic ' + text)
            self.assertIn(identity, json.dumps(landed[0]))
            self.assertEqual(landed[0]['seekToken'], match['seekToken'])
            ack = self.window_ack(client, thread, page, [page['window']['segmentID']], head)

    def test_codex_seek_lands_on_an_item_revised_after_the_search(self):
        session = '00000000-0000-0000-0000-000000000001'
        def item(ordinal, identity, text):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=session, turn_id='turn',
                item=dict(type='AgentMessage', id=identity, content=[dict(type='Text', text='synthetic ' + text)])))
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=session, history_mode='paginated'))]
        path, client, thread = self.start('codex', rows + [item(i + 1, f'item-{i:03}', f'reply-{i:03}') for i in range(300)])
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        ack = self.window_ack(client, thread, end, [head], head)
        match = self.search_match(client, thread, 'reply-200')
        # Completed again further down: its order stays, its offset moves on.
        self.append(path, [item(301, 'item-200', 'revised-200')])
        _, records, page = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertEqual(page['window']['lane'], 'seek')
        landed = [row for row in records if row['order'] == match['order']]
        self.assertEqual([row['recordID'] for row in landed], [match['recordID']])
        self.assertEqual(landed[0]['record']['blocks'][0]['text'], 'synthetic revised-200')
        self.assertGreater(landed[0]['sourceOffset'], match['sourceOffset'])
        # An offset before any copy of it names some other item.
        ack = self.window_ack(client, thread, page, [page['window']['segmentID']], head)
        refused = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match,
                            source_offset=landed[0]['sourceOffset'] + 1, token=None)
        self.assertEqual((refused['kind'], refused['code']), ('error', 'seekRecordMoved'))
        # Its token names the item wherever the revision put it.
        ack = self.window_ack(client, thread, page, [page['window']['segmentID']], head)
        _, records, _ = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertIn('synthetic revised-200', json.dumps([row for row in records if row['order'] == match['order']]))

    def test_codex_seek_refuses_another_turns_item_with_the_same_id(self):
        # Codex names an item by its turn and ID: a rewrite that puts another
        # turn's item with the same ID at the match is another item.
        session = '00000000-0000-0000-0000-000000000001'
        def item(ordinal, identity, text, turn):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=session, turn_id=turn,
                item=dict(type='AgentMessage', id=identity, content=[dict(type='Text', text='synthetic ' + text)])))
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=session, history_mode='paginated'))]
        path, client, thread = self.start('codex', rows + [item(i + 1, f'item-{i:03}', f'reply-{i:03}', 'turn-a') for i in range(300)])
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        head = end['window']['segmentID']
        ack = self.window_ack(client, thread, end, [head], head)
        match = self.search_match(client, thread, 'reply-150')
        self.assertTrue(match['seekToken'].endswith(':item-150'), match['seekToken'])
        os.truncate(path, match['sourceOffset'])
        self.append(path, [item(151 + i, f'item-{150 + i:03}', f'other-{i:03}', 'turn-b') for i in range(150)])
        begin, ack = self.rebootstrap(client, thread, ack['windowVersion'])
        self.assertNotEqual(begin['sourceIdentity'], match['sourceIdentity'])
        moved = self.seek(client, thread, ack['windowVersion'], ack['liveCursor'], match)
        self.assertEqual((moved['kind'], moved['code']), ('error', 'seekRecordMoved'))
        # The new turn's item has a token of its own.
        other = self.search_match(client, thread, 'other-000')
        self.assertNotEqual(other['seekToken'], match['seekToken'])
        self.assertTrue(other['seekToken'].endswith(':item-150'), other['seekToken'])

    def codex_state(self, schema='id TEXT PRIMARY KEY, name TEXT, title TEXT, first_user_message TEXT, updated_at INTEGER, metadata TEXT',
                    values=None):
        database = sqlite3.connect(self.root / 'codex/state_5.sqlite')
        self.addCleanup(database.close)
        database.execute('PRAGMA journal_mode=WAL')
        database.execute(f'CREATE TABLE threads({schema})')
        if values is not None:
            placeholders = ','.join('?' for _ in values)
            database.execute(f'INSERT INTO threads VALUES({placeholders})', values)
        database.commit()
        return database

    def codex_append(self, path, ordinal):
        self.append(path, [dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed',
            thread_id=self.session, turn_id='turn', item=dict(type='AgentMessage', id=f'new-{ordinal}',
            content=[dict(type='Text', text=f'synthetic append {ordinal}')])) )])

    def test_codex_window_bootstrap_carries_native_name_and_first_prompt(self):
        path, client, thread = self.codex_summary_fixture()
        self.codex_state(values=(self.session, '  Survey the build cache layout  ',
            'Late user prompt', '  Opening user prompt  ', 123, '{}'))
        _, _, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(end['backend'], 'jsonl')
        self.assertEqual(end['metadata'], dict(nativeTitle='Survey the build cache layout',
                                                openingPrompt='Opening user prompt'))
        self.assertNotIn('metadataIssue', end)
        self.assertEqual(self.summary(client, thread)['records'][0]['title'], 'Survey the build cache layout')

    def test_codex_window_null_name_only_opening_prompt(self):
        path, client, thread = self.codex_summary_fixture()
        self.codex_state(values=(self.session, None, 'Title fallback', 'First actual prompt', 0, '{}'))
        end = self.window_page(client, thread, 'bootstrap', 0)[2]
        self.assertEqual(end['metadata'], dict(openingPrompt='First actual prompt'))
        self.assertEqual(self.summary(client, thread)['records'][0]['title'], 'Title fallback')

    def test_codex_window_old_schema_uses_title_as_opening_prompt(self):
        path, client, thread = self.codex_summary_fixture()
        self.codex_state('id TEXT PRIMARY KEY, name TEXT, title TEXT', (self.session, None, '  Legacy first prompt  '))
        end = self.window_page(client, thread, 'bootstrap', 0)[2]
        self.assertEqual(end['metadata'], dict(openingPrompt='Legacy first prompt'))

    def test_codex_window_absent_store_omits_metadata(self):
        path, client, thread = self.codex_summary_fixture()
        end = self.window_page(client, thread, 'bootstrap', 0)[2]
        self.assertNotIn('metadata', end)
        self.assertNotIn('metadataIssue', end)

    def test_codex_window_unsupported_store_reports_reason_without_losing_page(self):
        path, client, thread = self.codex_summary_fixture()
        self.codex_state('id TEXT, name TEXT, title TEXT', (self.session, 'Unsafe', 'Prompt'))
        _, records, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(len(records), 20)
        self.assertNotIn('metadata', end)
        self.assertEqual(end['metadataIssue'], 'codexTitleUnavailable')
        self.assertEqual(end['metadataReason'], 'codexMetadataSchemaUnsupported')

    def test_codex_window_metadata_clips_multibyte_utf8_at_byte_limits(self):
        path, client, thread = self.codex_summary_fixture()
        self.codex_state(values=(self.session, 'é' * 300, 'Unused', '😀' * 1100, 0, '{}'))
        end = self.window_page(client, thread, 'bootstrap', 0)[2]
        metadata = end['metadata']
        self.assertLessEqual(len(metadata['nativeTitle'].encode()), 512)
        self.assertLessEqual(len(metadata['openingPrompt'].encode()), 4096)
        self.assertEqual(metadata['nativeTitle'], 'é' * 256)
        self.assertEqual(metadata['openingPrompt'], '😀' * 1024)
        self.assertNotIn('\ufffd', json.dumps(metadata, ensure_ascii=False))

    def test_codex_window_huge_opening_prompt_keeps_native_name(self):
        # SQLite materializes a whole column value under the helper's 16 MiB
        # heap limit, so a 20 MB pasted prompt is unreadable; it must cost
        # only the prompt, which then falls back to the title column.
        path, client, thread = self.codex_summary_fixture()
        self.codex_state(values=(self.session, 'Native name', 'Short first prompt', 'x' * 20_000_000, 0, '{}'))
        end = self.window_page(client, thread, 'bootstrap', 0)[2]
        self.assertEqual(end['metadata'], dict(nativeTitle='Native name', openingPrompt='Short first prompt'))
        self.assertNotIn('metadataIssue', end)

    def test_codex_window_unreadable_prompts_report_issue_and_keep_name(self):
        path, client, thread = self.codex_summary_fixture()
        self.codex_state(values=(self.session, 'Native name', 'y' * 20_000_000, 'x' * 20_000_000, 0, '{}'))
        _, records, end = self.window_page(client, thread, 'bootstrap', 0)
        self.assertEqual(len(records), 20)
        self.assertEqual(end['metadata'], dict(nativeTitle='Native name'))
        self.assertEqual(end['metadataIssue'], 'codexOpeningPromptUnavailable')
        self.assertRegex(end['metadataReason'], r'^[A-Za-z0-9]{1,80}$')
        self.assertEqual(self.summary(client, thread)['records'][0]['title'], 'Native name')

    def test_codex_window_head_reuses_metadata_then_refreshes_rename(self):
        path, client, thread = self.codex_summary_fixture()
        database = self.codex_state(values=(self.session, 'First name', 'Prompt', 'Opening', 0, '{}'))
        end = self.window_page(client, thread, 'bootstrap', 0)[2]
        self.assertEqual(end['metadata']['nativeTitle'], 'First name')
        # Each head page is acknowledged as the newest single-segment viewport,
        # and the next head read continues from that acknowledgement's cursor.
        head = end['window']['segmentID']
        live = self.window_ack(client, thread, end, [head], head)['liveCursor']
        database.execute('UPDATE threads SET name=?', ('Second name',)); database.commit()
        self.codex_append(path, 21)
        newer = self.window_page(client, thread, 'head', end['window']['version'], live)[2]
        self.assertEqual(newer['metadata']['nativeTitle'], 'First name', 'head within five seconds must reuse cache')
        head = newer['window']['segmentID']
        live = self.window_ack(client, thread, newer, [head], head)['liveCursor']
        deadline = time.monotonic() + 6
        ordinal = 22
        while time.monotonic() < deadline:
            time.sleep(.2)
            self.codex_append(path, ordinal); ordinal += 1
            newer = self.window_page(client, thread, 'head', newer['window']['version'], live)[2]
            head = newer['window']['segmentID']
            live = self.window_ack(client, thread, newer, [head], head)['liveCursor']
            if newer['metadata']['nativeTitle'] == 'Second name': break
        self.assertEqual(newer['metadata']['nativeTitle'], 'Second name')

    def test_codex_window_wal_writer_all_fifty_bootstraps_keep_name(self):
        path, client, thread = self.codex_summary_fixture()
        database = self.codex_state(values=(self.session, 'Stable name', 'Prompt', 'Opening', 0, '{}'))
        stop = threading.Event(); committed = threading.Event(); errors = []; commits = [0]
        def writer():
            try:
                with sqlite3.connect(self.root / 'codex/state_5.sqlite', timeout=1) as connection:
                    count = 0
                    while not stop.is_set():
                        connection.execute('UPDATE threads SET updated_at=?', (count,))
                        connection.commit(); count += 1; commits[0] = count; committed.set()
                        time.sleep(.001)
            except Exception as error:
                errors.append(error)
        thread_writer = threading.Thread(target=writer, daemon=True)
        thread_writer.start()
        try:
            self.assertTrue(committed.wait(2), 'WAL writer did not commit before reads')
            for index in range(50):
                client.sendall(frame(dict(kind='window.read', id=f'metadata-bootstrap-{index}', thread=thread,
                                          operation='bootstrap', windowVersion=0)))
                _, records, end = self.read_page(client)
                self.assertEqual(len(records), 20)
                self.assertEqual(end['metadata'], dict(nativeTitle='Stable name', openingPrompt='Opening'))
                head = end['window']['segmentID']
                self.window_ack(client, thread, end, [head], head)
        finally:
            stop.set(); thread_writer.join(timeout=2)
        self.assertFalse(thread_writer.is_alive())
        self.assertGreater(commits[0], 1)
        self.assertEqual(errors, [])

    def test_codex_names_use_latest_metadata_store_and_follow_wal_renames(self):
        path, client, thread = self.codex_summary_fixture()
        old = sqlite3.connect(self.root / 'codex/state_4.sqlite')
        old.execute('CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT)')
        old.execute('INSERT INTO threads VALUES(?,?)', (self.session, 'Obsolete title')); old.commit(); old.close()
        database = sqlite3.connect(self.root / 'codex/state_5.sqlite')
        self.addCleanup(database.close)
        database.execute('PRAGMA journal_mode=WAL')
        database.execute('CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT, title TEXT)')
        database.execute('INSERT INTO threads VALUES(?,?,?)', (self.session, '  Named conversation  ', 'Original prompt'))
        database.commit()
        first = self.summary(client, thread)
        self.assertEqual(first['records'][0], dict(type='session-title', title='Named conversation'))
        database.execute('UPDATE threads SET name=?', ('Renamed conversation',)); database.commit()
        renamed = self.summary(client, thread)
        self.assertEqual(renamed['records'][0]['title'], 'Renamed conversation')
        self.assertNotEqual(first['revision'], renamed['revision'])
        database.execute('UPDATE threads SET name=?', (' ',)); database.commit()
        self.assertEqual(self.summary(client, thread)['records'][0]['title'], 'Original prompt')
        database.execute('UPDATE threads SET title=?', ('x' * 201,)); database.commit()
        self.assertFalse(any(row['type'] == 'session-title' for row in self.summary(client, thread)['records']))
        # Metadata never enters the canonical message window or invents a record identity.
        self.assertTrue(all(row['record']['type'] != 'session-title' for row in self.page(client, thread)[1]))

    def test_codex_names_survive_the_provider_closing_its_store(self):
        # Codex keeps its state store in WAL mode and, like any SQLite writer,
        # removes the -wal and -shm sidecars when it closes. A read-only
        # reader that may not create them cannot open the store the normal
        # way; on a real host that dropped every thread name whenever Codex
        # had closed its store. The main file is complete then, and is read
        # as an immutable snapshot.
        path, client, thread = self.codex_summary_fixture()
        metadata = self.root / 'codex/state_5.sqlite'
        def write(sql, *args):
            database = sqlite3.connect(metadata)
            database.execute('PRAGMA journal_mode=WAL')
            database.execute(sql, args); database.commit(); database.close()
            self.assertEqual(sorted(p.name for p in metadata.parent.iterdir() if p.name.startswith('state_5')), ['state_5.sqlite'])
        write('CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT, title TEXT)')
        write('INSERT INTO threads VALUES(?,?,?)', self.session, 'Implement waterbank graphics', 'ok looks good we can go')
        first = self.summary(client, thread)
        self.assertNotIn('metadataIssue', first)
        self.assertEqual(first['records'][0], dict(type='session-title', title='Implement waterbank graphics'))
        write('UPDATE threads SET name=?', 'Renamed while closed')
        self.assertEqual(self.summary(client, thread)['records'][0]['title'], 'Renamed while closed')
        # A writer that reopens the store is followed through its WAL again.
        database = sqlite3.connect(metadata); self.addCleanup(database.close)
        database.execute('PRAGMA journal_mode=WAL'); database.execute('UPDATE threads SET name=?', ('Renamed while open',)); database.commit()
        self.assertTrue((metadata.parent / 'state_5.sqlite-wal').exists())
        self.assertEqual(self.summary(client, thread)['records'][0]['title'], 'Renamed while open')

    def test_codex_missing_unsafe_or_unsupported_metadata_does_not_lose_transcript(self):
        path, client, thread = self.codex_summary_fixture()
        self.assertNotIn('metadataIssue', self.summary(client, thread))
        metadata = self.root / 'codex/state_5.sqlite'
        database = sqlite3.connect(metadata)
        database.execute('CREATE VIEW threads AS SELECT 1 AS id'); database.commit(); database.close()
        unsupported = self.summary(client, thread)
        self.assertEqual(unsupported['metadataIssue'], 'codexTitleUnavailable')
        # The store's own code names the cause; the issue alone once hid a
        # closed store behind the same word as a refused one.
        self.assertEqual(unsupported['metadataReason'], 'codexMetadataSchemaUnsupported')
        metadata.unlink()
        outside = self.root / 'outside.sqlite'
        database = sqlite3.connect(outside)
        database.execute('CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT)')
        database.execute('INSERT INTO threads VALUES(?,?)', (self.session, 'Must not follow symlink'))
        database.commit(); database.close()
        metadata.symlink_to(outside)
        self.assertEqual(self.summary(client, thread)['metadataIssue'], 'codexTitleUnavailable')
        self.assertEqual(len(self.page(client, thread)[1]), 20)

    def test_codex_group_writable_metadata_store_still_names_the_thread(self):
        # Ubuntu-style hosts create every file group-writable under umask
        # 0002. The owner decides the mode of their own Codex state store: a
        # group-writable database, WAL or shm sidecar must still name the
        # thread instead of leaving the card on a generated title.
        path, client, thread = self.codex_summary_fixture()
        metadata = self.root / 'codex/state_5.sqlite'
        database = sqlite3.connect(metadata)
        self.addCleanup(database.close)
        database.execute('PRAGMA journal_mode=WAL')
        database.execute('CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT, title TEXT)')
        database.execute('INSERT INTO threads VALUES(?,?,?)', (self.session, 'Implement waterbank graphics', 'Original prompt'))
        database.commit()
        (self.root / 'codex').chmod(0o775)
        for sidecar in ('', '-wal', '-shm'):
            sidecar_path = metadata.parent / (metadata.name + sidecar)
            self.assertTrue(sidecar_path.exists(), sidecar)
            sidecar_path.chmod(0o664)
        summary = self.summary(client, thread)
        self.assertNotIn('metadataIssue', summary)
        self.assertEqual(summary['records'][0], dict(type='session-title', title='Implement waterbank graphics'))

    def test_codex_legacy_title_column_remains_supported(self):
        path, client, thread = self.codex_summary_fixture()
        with sqlite3.connect(self.root / 'codex/state_9.sqlite') as database:
            database.execute('CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT)')
            database.execute('INSERT INTO threads VALUES(?,?)', (self.session, 'Short first prompt'))
        self.assertEqual(self.summary(client, thread)['records'][0]['title'], 'Short first prompt')


if __name__ == '__main__': unittest.main()
