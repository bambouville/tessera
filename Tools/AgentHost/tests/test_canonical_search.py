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
