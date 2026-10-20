"""Real SQLite/WAL engine with synthetic provider rows only; no credentials."""
import json
import os
import select
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest

BINARY = sys.argv.pop(1)


class OpenCodeStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tessera-opencode-store-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.path = self.root / 'opencode.db'
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        self.db.executescript('''PRAGMA journal_mode=WAL;
            CREATE TABLE session(id TEXT PRIMARY KEY,title TEXT,time_updated INTEGER,time_archived INTEGER);
            CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);
            CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);
            CREATE INDEX message_session_time_created_id_idx ON message(session_id,time_created,id);
            CREATE INDEX part_session_idx ON part(session_id);
            CREATE INDEX part_message_id_id_idx ON part(message_id,id);
            INSERT INTO session VALUES('ses_synthetic','Synthetic',1000,NULL);
            INSERT INTO message VALUES('msg_synthetic','ses_synthetic',1,1,'{"role":"assistant"}');''')
        self.db.commit()

    def probe(self, **request):
        request.setdefault('session', 'ses_synthetic')
        completed = subprocess.run([BINARY, str(self.path)], input=json.dumps(request)+'\n',
                                   capture_output=True, text=True, timeout=5)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(completed.stderr, '')
        return json.loads(completed.stdout)

    def part(self, part_id='prt_synthetic', created=1, **part):
        if not part: part = dict(type='text', text='synthetic assistant')
        self.db.execute('INSERT INTO part VALUES(?,?,?, ?,?,?)',
                        (part_id, 'msg_synthetic', 'ses_synthetic', created, created, json.dumps(part)))
        self.db.commit()

    def test_reads_uncheckpointed_wal_and_keeps_database_unchanged(self):
        self.part()
        before = self.path.stat()
        self.assertGreater(Path(str(self.path)+'-wal').stat().st_size, 0)
        self.assertEqual(self.probe(operation='inventory')['sessions'], ['ses_synthetic'])
        row = self.probe()['rows'][0]
        self.assertEqual(row['record']['blocks'][0]['text'], 'synthetic assistant')
        self.assertEqual(row['disposition'], 'message')
        self.assertEqual(self.path.stat().st_mtime_ns, before.st_mtime_ns)

    def test_keyset_paging_and_exact_revision_at_equal_timestamps(self):
        for n in range(25): self.part(f'prt_{n:03}', 123, type='text', text=str(n))
        head = self.probe()['rows']
        self.assertEqual([r['id'] for r in head], [f'prt_{n:03}' for n in range(24,14,-1)])
        older = self.probe(id='prt_015', created=1)['rows']
        self.assertEqual(older[0]['id'], 'prt_014')
        self.assertEqual(self.probe(id='prt_010', created=1, forward=True)['rows'][0]['id'], 'prt_011')
        self.assertEqual(self.probe(operation='exact', id='prt_010', created=1)['rows'][0]['id'], 'prt_010')
        self.assertIn('error', self.probe(operation='exact', id='prt_010', created=124))

    def test_cross_message_cursor_seams_follow_provider_order(self):
        expected=['msg_synthetic']
        for n in range(5):
            message=f'msg_{n:03}'
            self.db.execute('INSERT INTO message VALUES(?,?,?,?,?)',
                (message,'ses_synthetic',2,2,json.dumps(dict(role='user'))))
            expected.append(message)
            for p in range(7):
                part=f'prt_{n:03}_{p:03}'; expected.append(part)
                self.db.execute('INSERT INTO part VALUES(?,?,?,?,?,?)',
                    (part,message,'ses_synthetic',100-p,100-p,json.dumps(dict(type='text',text=part))))
        self.db.commit()
        all_rows=[]; cursor={}
        for _ in range(10):
            rows=self.probe(**cursor)['rows']
            if not rows: break
            all_rows+=rows
            cursor={key:rows[-1][key] for key in ('id','created','message')}
        self.assertEqual([r['id'] for r in all_rows],list(reversed(expected)))
        middle=all_rows[19]
        forward=self.probe(**{key:middle[key] for key in ('id','created','message')},forward=True)['rows']
        self.assertEqual([r['id'] for r in forward],[r['id'] for r in reversed(all_rows[9:19])])

    def test_wal_commit_generates_native_dirty_notification(self):
        self.part()
        before=self.path.stat().st_mtime_ns
        process=subprocess.Popen([BINARY,str(self.path)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            process.stdin.write(json.dumps(dict(operation='watch'))+'\n'); process.stdin.flush()
            self.assertTrue(select.select([process.stdout],[],[],3)[0])
            self.assertTrue(json.loads(process.stdout.readline())['ready'])
            self.part('prt_next',2)
            result,_=process.communicate('continue\n',timeout=3)
            self.assertTrue(json.loads(result)['changed'])
            self.assertEqual(self.path.stat().st_mtime_ns,before)
        finally:
            if process.poll() is None: process.kill(); process.wait(timeout=3)

    def test_completed_tool_preserves_call_and_output_identity(self):
        self.part(type='tool', tool='Read', callID='call_test', state=dict(status='completed', input={'path':'synthetic'}, output='result'))
        blocks = self.probe()['rows'][0]['record']['blocks']
        self.assertEqual([b['type'] for b in blocks], ['tool_call', 'tool_result'])
        self.assertEqual([b['toolCallID'] for b in blocks], ['call_test', 'call_test'])
        self.assertEqual(blocks[1]['preview'], 'result')

    def test_all_documented_legacy_part_tags_are_classified(self):
        parts = [dict(type='text',text='hi'),dict(type='reasoning',text='why'),
            dict(type='file',filename='synthetic.png',mime='image/png'),dict(type='compaction',auto=True),
            dict(type='subtask',prompt='delegated synthetic'),dict(type='step-start'),dict(type='step-finish',reason='stop'),
            dict(type='snapshot',snapshot='hash'),dict(type='patch',hash='hash',files=[]),dict(type='agent',name='build'),
            dict(type='retry',error=dict(data=dict(message='retry')))]
        for index, part in enumerate(parts):
            self.part(f'prt_{index}', index, **part)
            record = self.probe(operation='exact', id=f'prt_{index}', created=1)['rows'][0]
            self.assertNotEqual(record['disposition'], 'unclassified', part['type'])
            self.assertEqual(record['record'].get('unparsedContentCount', 0), 0, part['type'])

    def test_unknown_and_malformed_known_types_are_not_swallowed(self):
        self.part(type='future-part', text='unknown')
        row = self.probe()['rows'][0]
        self.assertEqual(row['disposition'], 'unclassified')
        self.assertEqual(row['record']['unparsedContentCount'], 1)
        self.part('prt_invalid', 2, type='tool', state={})
        row = self.probe(operation='exact',id='prt_invalid',created=1)['rows'][0]
        self.assertTrue(row['record']['malformed'])

    def test_large_strings_are_streamed_not_whole_blob_allocations(self):
        self.part(type='text', text='x'*3_000_000)
        result = self.probe()
        self.assertGreater(result['bytesRead'], 3_000_000)
        self.assertLess(len(json.dumps(result)), 50000)
        self.assertTrue(result['rows'][0]['record']['truncated'])

    def test_large_session_uses_only_official_indexes(self):
        data=json.dumps(dict(type='text',text='synthetic'))
        self.db.executemany('INSERT INTO part VALUES(?,?,?,?,?,?)',
            ((f'prt_{n:06}','msg_synthetic','ses_synthetic',n,n,data) for n in range(100000)))
        self.db.commit()
        result=self.probe()
        self.assertNotIn('error',result)
        self.assertEqual(result['rows'][0]['id'],'prt_099999')
        self.assertLess(result['bytesRead'],10000)
        older=self.probe(id='prt_099990',created=1)
        self.assertEqual(older['rows'][0]['id'],'prt_099989')

    def test_message_error_without_parts_is_visible(self):
        self.db.execute('UPDATE message SET data=?',(json.dumps(dict(role='assistant',error=dict(
            name='UnknownError',data=dict(message='failure sentinel')))),)); self.db.commit()
        row=self.probe()['rows'][0]
        self.assertEqual(row['record']['blocks'][0]['text'],'failure sentinel')
        self.assertEqual(row['disposition'],'message')

    def test_legacy_agent_mention_is_visible(self):
        self.part(type='agent',name='reviewer')
        row=self.probe()['rows'][0]
        self.assertEqual(row['disposition'],'message')
        self.assertEqual(row['record']['blocks'][0]['name'],'reviewer')

    def test_malformed_modern_shell_and_metadata_are_explicit(self):
        self.db.executescript('''CREATE TABLE session_message(id TEXT PRIMARY KEY,session_id TEXT,
            type TEXT,seq INTEGER,time_created INTEGER,time_updated INTEGER,data TEXT);''')
        for index,(kind,data) in enumerate([('shell',dict(command={'text':'wrong'},output=17)),
                ('model-switched',dict(model={})),('agent-switched',dict(agent=17))]):
            self.db.execute('INSERT INTO session_message VALUES(?,?,?,?,?,?,?)',
                (f'msg_{index}','ses_synthetic',kind,index,0,0,json.dumps(data)))
        self.db.commit()
        rows=self.probe()['rows']
        self.assertEqual(len(rows),3)
        self.assertTrue(all(r['record'].get('malformed') and r['record'].get('unparsedContentCount') for r in rows))

    def test_malformed_json_does_not_become_empty_success(self):
        self.part()
        self.db.execute("UPDATE part SET data='not JSON'"); self.db.commit()
        self.assertEqual(self.probe()['error'], 'opencodeInvalidRecord')

    def test_modern_store_wins_without_duplicate_legacy_messages(self):
        self.part()
        self.db.executescript('''CREATE TABLE session_message(id TEXT PRIMARY KEY,session_id TEXT,
            type TEXT,seq INTEGER,time_created INTEGER,time_updated INTEGER,data TEXT);
            CREATE UNIQUE INDEX session_message_seq ON session_message(session_id,seq);''')
        for index, (kind, data) in enumerate([
            ('user',dict(text='request',files=[])),('assistant',dict(content=[dict(type='text',text='modern reply')])),
            ('compaction',dict(summary='summary')),('model-switched',dict(model=dict(id='model',providerID='deepseek'))),
            ('agent-switched',dict(agent='build')),('synthetic',dict(text='hidden')),('system',dict(text='hidden')),
            ('shell',dict(callID='shell1',command='echo synthetic',output='synthetic'))]):
            self.db.execute('INSERT INTO session_message VALUES(?,?,?,?,?,?,?)',
                (f'msg_{index}', 'ses_synthetic',kind,index,0,0,json.dumps(data)))
        self.db.commit()
        result = self.probe()
        self.assertTrue(result['identity'].endswith(':messages'))
        self.assertEqual(len(result['rows']),8)
        self.assertFalse(any(r['disposition']=='unclassified' or r['record'].get('unparsedContentCount') for r in result['rows']))

    def test_symlink_database_and_ancestor_are_rejected(self):
        alias = self.root/'alias.db'; alias.symlink_to(self.path); self.path=alias
        self.assertIn('error',self.probe())
        parent=self.root/'redirect'; parent.symlink_to(self.root,target_is_directory=True); self.path=parent/'opencode.db'
        self.assertIn('error',self.probe())

    def test_modern_attachments_mentions_and_mixed_tool_output_survive(self):
        self.db.executescript('''CREATE TABLE session_message(id TEXT PRIMARY KEY,session_id TEXT,
            type TEXT,seq INTEGER,time_created INTEGER,time_updated INTEGER,data TEXT);
            CREATE UNIQUE INDEX session_message_seq ON session_message(session_id,seq);''')
        file = dict(uri='file:///never-open-this', name='synthetic.png', mime='image/png')
        user = dict(text='request', files=[file], agents=[dict(name='review')])
        assistant = dict(content=[dict(type='tool',id='call_synthetic',name='Read',state=dict(
            status='completed',input={},attachments=[file],content=[dict(type='text',text='result'),dict(type='file',**file)]))])
        for index, (kind, data) in enumerate([('user',user),('assistant',assistant)]):
            self.db.execute('INSERT INTO session_message VALUES(?,?,?,?,?,?,?)',
                (f'msg_{index}','ses_synthetic',kind,index,0,0,json.dumps(data)))
        self.db.commit()
        rows=self.probe()['rows']
        self.assertEqual([b['type'] for b in rows[1]['record']['blocks']], ['text','attachment','attachment'])
        self.assertEqual(rows[1]['record']['blocks'][2]['name'], 'review')
        blocks=rows[0]['record']['blocks']
        self.assertEqual([b['type'] for b in blocks], ['tool_call','tool_result','attachment','attachment'])
        self.assertEqual(blocks[1]['toolCallID'],'call_synthetic')
        self.assertEqual(blocks[1]['preview'],'result')
        self.assertNotIn('never-open-this',json.dumps(rows))
        self.assertFalse(any(r['record'].get('unparsedContentCount') for r in rows))
    def test_symlink_wal_cannot_be_opened(self):
        self.part()
        wal=Path(str(self.path)+'-wal'); saved=self.root/'saved-wal'; wal.rename(saved); wal.symlink_to(saved)
        self.assertIn('error',self.probe())

    def test_cross_session_join_cannot_leak_another_message(self):
        self.part()
        self.db.execute("UPDATE message SET session_id='other'"); self.db.commit()
        self.assertEqual(self.probe()['rows'],[])

    def test_reads_a_store_whose_writer_has_closed(self):
        # OpenCode removes its -wal and -shm when it exits; a reader that may
        # not create sidecars reads the checkpointed main file as an
        # immutable snapshot instead of failing every stored transcript.
        self.part()
        self.db.close()
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['opencode.db'])
        before = self.path.stat()
        page = self.probe()
        self.assertTrue(page['snapshot'])
        self.assertEqual(page['rows'][0]['record']['blocks'][0]['text'], 'synthetic assistant')
        self.assertEqual(self.probe(operation='inventory')['sessions'], ['ses_synthetic'])
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['opencode.db'], 'the snapshot read created sidecars')
        self.assertEqual(self.path.stat().st_mtime_ns, before.st_mtime_ns)
        self.db = sqlite3.connect(self.path); self.addCleanup(self.db.close)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.part('prt_reopened', created=2, type='text', text='after reopening')
        page = self.probe()
        self.assertFalse(page['snapshot'], 'a live writer is followed through its WAL, never snapshotted')
        reopened = json.dumps(page['rows'])
        self.assertIn('synthetic assistant', reopened); self.assertIn('after reopening', reopened)

    def test_rollback_journal_store_keeps_sqlite_locking(self):
        # Only a WAL-header database is read as a snapshot: a rollback-journal
        # store has no sidecar to miss, and the unlocked snapshot path would
        # skip hot-journal recovery.
        path = self.root / 'rollback.db'
        db = sqlite3.connect(path)
        db.executescript('''CREATE TABLE session(id TEXT PRIMARY KEY,title TEXT,time_updated INTEGER,time_archived INTEGER);
            CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);
            CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,session_id TEXT,time_created INTEGER,time_updated INTEGER,data TEXT);
            INSERT INTO session VALUES('ses_synthetic','Synthetic',1000,NULL);''')
        db.commit(); db.close()
        self.assertEqual(path.read_bytes()[18:20], b'\x01\x01')
        completed = subprocess.run([BINARY, str(path)], input=json.dumps(dict(operation='inventory'))+'\n',
                                   capture_output=True, text=True, timeout=5)
        result = json.loads(completed.stdout)
        self.assertEqual(result['sessions'], ['ses_synthetic'])
        self.assertFalse(result['snapshot'])

    def test_snapshot_torn_by_a_checkpoint_is_reported_as_source_changed(self):
        # The provider reopens, rewrites and checkpoints the store while a
        # snapshot read is in flight: the same-sized main file changed under
        # the reader, which must say sourceChanged rather than return rows.
        self.part()
        self.db.close()
        process = subprocess.Popen([BINARY, str(self.path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.stdin.write(json.dumps(dict(operation='hold'))+'\n'); process.stdin.flush()
            self.assertTrue(select.select([process.stdout], [], [], 5)[0])
            self.assertTrue(json.loads(process.stdout.readline())['ready'])
            size = self.path.stat().st_size
            writer = sqlite3.connect(self.path)
            writer.execute('PRAGMA journal_mode=WAL')
            writer.execute("UPDATE part SET data=? WHERE id='prt_synthetic'", (json.dumps(dict(type='text', text='rewritten in place')),))
            writer.commit(); writer.close()
            self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['opencode.db'], 'closing the writer must checkpoint')
            self.assertEqual(self.path.stat().st_size, size, 'the rewrite must not change the size for this test to mean anything')
            result, _ = process.communicate('continue\n', timeout=5)
            self.assertEqual(json.loads(result)['error'], 'sourceChanged')
        finally:
            if process.poll() is None: process.kill(); process.wait(timeout=3)

    def test_views_are_not_accepted_as_provider_tables(self):
        self.db.executescript('DROP TABLE part; CREATE VIEW part AS SELECT * FROM message;')
        self.assertEqual(self.probe()['error'], 'opencodeInvalidSchema')

    def test_rejected_empty_database_cannot_delete_existing_wal(self):
        self.part()
        wal=Path(str(self.path)+'-wal'); before=wal.read_bytes()
        with self.path.open('r+b') as output: output.truncate(0)
        self.assertIn('error',self.probe())
        self.assertTrue(wal.exists(),'read-only failure deleted provider WAL')
        self.assertEqual(wal.read_bytes(),before)

    def test_rowid_shadow_cannot_redirect_blob_to_another_session(self):
        self.part()
        self.db.execute('INSERT INTO part VALUES(?,?,?,?,?,?)',
            ('prt_foreign','msg_foreign','ses_foreign',2,2,json.dumps(dict(type='text',text='foreign content'))))
        self.db.execute('ALTER TABLE part ADD COLUMN rowid INTEGER')
        self.db.execute('UPDATE part SET rowid=2 WHERE id=?',('prt_synthetic',)); self.db.commit()
        result=self.probe()
        self.assertIn('error',result,'declared rowid must not redirect the blob read')
        self.assertNotIn('foreign content',json.dumps(result))

    def test_codex_metadata_read_trims_and_clips_both_fields(self):
        self.db.execute('CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT, title TEXT, first_user_message TEXT, extra INTEGER)')
        self.db.execute('INSERT INTO threads VALUES(?,?,?,?,?)',
                        ('codex_session', '  ' + 'é' * 300 + '  ', 'Short title',
                         '  ' + '😀' * 1100 + '  ', 1))
        self.db.commit()
        metadata = self.probe(operation='codexMetadata', session='codex_session')
        self.assertEqual(metadata, dict(nativeTitle='é' * 256, openingPrompt='😀' * 1024))
        self.assertEqual(self.probe(operation='codexTitle', session='codex_session')['title'], 'é' * 300)

    def test_codex_metadata_old_schema_and_short_summary_fallback(self):
        self.db.execute('CREATE TABLE threads(id TEXT PRIMARY KEY, name TEXT, title TEXT)')
        self.db.execute('INSERT INTO threads VALUES(?,?,?)', ('codex_session', None, '  First prompt  '))
        self.db.commit()
        self.assertEqual(self.probe(operation='codexMetadata', session='codex_session'),
                         dict(openingPrompt='First prompt'))
        self.assertEqual(self.probe(operation='codexTitle', session='codex_session')['title'], 'First prompt')
        self.db.execute('UPDATE threads SET title=?', ('x' * 201,)); self.db.commit()
        self.assertEqual(self.probe(operation='codexTitle', session='codex_session')['title'], '')
        self.assertEqual(self.probe(operation='codexMetadata', session='codex_session')['openingPrompt'], 'x' * 201)


class CodexWorkerMetadataTests(unittest.TestCase):
    session = '00000000-0000-0000-0000-000000000001'

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tessera-codex-worker-', dir='/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.path = self.root / 'codex/sessions' / f'{self.session}.jsonl'
        self.path.parent.mkdir(parents=True)
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=self.session, history_mode='paginated'))]
        rows += [self.item(n) for n in range(1, 21)]
        self.path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        self.database = None
        self.process = None

    def tearDown(self):
        if self.process is not None:
            self.process.stdin.close()
            self.process.wait(timeout=5)
            self.process.stdout.close(); self.process.stderr.close()
        if self.database is not None: self.database.close()

    def item(self, ordinal):
        return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed',
            thread_id=self.session, turn_id='turn', item=dict(type='AgentMessage', id=f'item-{ordinal}',
            content=[dict(type='Text', text=f'synthetic {ordinal}')])) )

    def state(self, schema='id TEXT PRIMARY KEY, name TEXT, title TEXT, first_user_message TEXT, extra INTEGER', values=None):
        self.database = sqlite3.connect(self.root / 'codex/state_5.sqlite')
        self.database.execute('PRAGMA journal_mode=WAL')
        self.database.execute(f'CREATE TABLE threads({schema})')
        if values is not None:
            self.database.execute(f'INSERT INTO threads VALUES({",".join("?" for _ in values)})', values)
        self.database.commit()

    def call(self, request):
        if self.process is None:
            environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'),
                               CLAUDE_CONFIG_DIR=str(self.root / 'claude'),
                               XDG_DATA_HOME=str(self.root / 'xdg'))
            self.process = subprocess.Popen([BINARY, str(self.root / 'unused.db')],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, env=environment, bufsize=1)
        self.process.stdin.write(json.dumps(dict(operation='worker', request=json.dumps(request))) + '\n')
        self.process.stdin.flush()
        self.assertTrue(select.select([self.process.stdout], [], [], 6)[0], 'worker driver response timeout')
        value = json.loads(self.process.stdout.readline())
        self.assertIn('frames', value, value)
        return value['frames']

    def resolve(self):
        frames = self.call(dict(kind='resolve', id='resolve', provider='codex', transcriptRef=str(self.path)))
        self.assertEqual(frames[0]['kind'], 'resolved', frames)
        return frames[0]['thread']

    def bootstrap(self, thread, index=0):
        frames = self.call(dict(kind='window.read', id=f'bootstrap-{index}', thread=thread,
                                operation='bootstrap', windowVersion=0))
        self.assertEqual((frames[0]['kind'], frames[-1]['kind']), ('page.begin', 'page.end'), frames)
        self.assertEqual(frames[-1]['backend'], 'jsonl')
        return frames[-1]

    def ack(self, thread, end):
        head = end['window']['segmentID']
        frames = self.call(dict(kind='window.ack', id='ack-' + end['id'], thread=thread,
            transaction=end['id'], windowVersion=end['window']['version'], viewport=[head], head=head))
        self.assertEqual(frames[0]['kind'], 'window.acked', frames)

    def test_worker_page_metadata_name_prompt_and_old_schema(self):
        self.state(values=(self.session, '  Native name  ', 'Late title', '  First user prompt  ', 0))
        thread = self.resolve()
        end = self.bootstrap(thread)
        self.assertEqual(end['metadata'], dict(nativeTitle='Native name', openingPrompt='First user prompt'))
        self.ack(thread, end)
        self.database.execute('UPDATE threads SET name=NULL'); self.database.commit()
        end = self.bootstrap(thread, 1)
        self.assertEqual(end['metadata'], dict(openingPrompt='First user prompt'))
        self.ack(thread, end)
        self.database.execute('UPDATE threads SET first_user_message=NULL'); self.database.commit()
        end = self.bootstrap(thread, 2)
        self.assertEqual(end['metadata'], dict(openingPrompt='Late title'))

    def test_worker_page_metadata_missing_and_unsupported_stores(self):
        thread = self.resolve()
        end = self.bootstrap(thread)
        self.assertNotIn('metadata', end)
        self.assertNotIn('metadataIssue', end)
        self.ack(thread, end)
        self.state('id TEXT, name TEXT, title TEXT', (self.session, 'Name', 'Prompt'))
        end = self.bootstrap(thread, 1)
        self.assertNotIn('metadata', end)
        self.assertEqual((end['metadataIssue'], end['metadataReason']),
                         ('codexTitleUnavailable', 'codexMetadataSchemaUnsupported'))

    def test_worker_page_metadata_title_only_schema(self):
        self.state('id TEXT PRIMARY KEY, title TEXT', (self.session, '  Opening legacy prompt  '))
        end = self.bootstrap(self.resolve())
        self.assertEqual(end['metadata'], dict(openingPrompt='Opening legacy prompt'))

    def test_worker_page_metadata_empty_fields_omit_object(self):
        self.state(values=(self.session, None, ' \t ', ' \n ', 0))
        end = self.bootstrap(self.resolve())
        self.assertNotIn('metadata', end)
        self.assertNotIn('metadataIssue', end)

    def test_worker_page_metadata_clips_utf8(self):
        self.state(values=(self.session, 'é' * 300, 'Unused', '😀' * 1100, 0))
        end = self.bootstrap(self.resolve())
        self.assertEqual(end['metadata'], dict(nativeTitle='é' * 256, openingPrompt='😀' * 1024))
        self.assertLess(len(json.dumps(end).encode()), 65536)

    def test_worker_page_metadata_respects_aggregate_wire_budget(self):
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id=self.session, history_mode='paginated'))]
        for ordinal in range(1, 121):
            row = self.item(ordinal)
            row['payload']['item']['content'][0]['text'] = 'x' * 2200
            rows.append(row)
        self.path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        self.state(values=(self.session, '\x01' * 512, 'Prompt', '\x01' * 4096, 0))
        thread = self.resolve()
        frames = self.call(dict(kind='window.read', id='wire-budget', thread=thread,
            operation='bootstrap', windowVersion=0))
        self.assertEqual(frames[-1]['kind'], 'page.end', frames[-1])
        self.assertLessEqual(max(len(json.dumps(frame, separators=(',', ':'), ensure_ascii=False).encode()) for frame in frames), 65536)
        self.assertLessEqual(sum(len(json.dumps(frame, separators=(',', ':'), ensure_ascii=False).encode()) for frame in frames), 262144)
        self.assertIn('metadata', frames[-1])
        self.assertLess(len(frames[-1]['metadata'].get('openingPrompt', '')), 4096,
                        'this fixture must exercise aggregate metadata clipping')

    def test_worker_page_metadata_rename_uses_five_second_cache(self):
        self.state(values=(self.session, 'First', 'Prompt', 'Opening', 0))
        thread = self.resolve()
        end = self.bootstrap(thread)
        self.ack(thread, end)
        self.database.execute('UPDATE threads SET name=?', ('Second',)); self.database.commit()
        with self.path.open('a') as stream: stream.write(json.dumps(self.item(21)) + '\n')
        frames = self.call(dict(kind='window.read', id='head-21', thread=thread,
            operation='head', windowVersion=end['window']['version'], cursor=end['liveCursor']))
        self.assertEqual(frames[-1]['metadata']['nativeTitle'], 'First')
        end = frames[-1]; self.ack(thread, end)
        deadline = time.monotonic() + 6
        ordinal = 22
        while time.monotonic() < deadline:
            time.sleep(.2)
            with self.path.open('a') as stream: stream.write(json.dumps(self.item(ordinal)) + '\n')
            frames = self.call(dict(kind='window.read', id=f'head-{ordinal}', thread=thread,
                operation='head', windowVersion=end['window']['version'], cursor=end['liveCursor']))
            end = frames[-1]
            self.assertEqual(end['kind'], 'page.end', frames)
            self.ack(thread, end)
            if end['metadata']['nativeTitle'] == 'Second': break
            ordinal += 1
        self.assertEqual(end['metadata']['nativeTitle'], 'Second')

    def test_worker_page_metadata_head_does_not_query_store_within_ttl(self):
        self.state(values=(self.session, 'Cached', 'Prompt', 'Opening', 0))
        thread = self.resolve()
        end = self.bootstrap(thread)
        self.ack(thread, end)
        self.database.execute('DROP TABLE threads'); self.database.commit()
        with self.path.open('a') as stream: stream.write(json.dumps(self.item(21)) + '\n')
        frames = self.call(dict(kind='window.read', id='head-with-unsupported-store', thread=thread,
            operation='head', windowVersion=end['window']['version'], cursor=end['liveCursor']))
        self.assertEqual(frames[-1]['kind'], 'page.end', frames)
        self.assertEqual(frames[-1]['metadata']['nativeTitle'], 'Cached')
        self.assertNotIn('metadataIssue', frames[-1])

    def test_worker_page_metadata_survives_fifty_wal_bootstraps(self):
        self.state(values=(self.session, 'Stable', 'Prompt', 'Opening', 0))
        thread = self.resolve()
        stop = threading.Event(); committed = threading.Event(); errors = []; commits = [0]
        def writer():
            try:
                with sqlite3.connect(self.root / 'codex/state_5.sqlite', timeout=1) as database:
                    count = 0
                    while not stop.is_set():
                        database.execute('UPDATE threads SET extra=?', (count,)); database.commit()
                        count += 1; commits[0] = count; committed.set(); time.sleep(.001)
            except Exception as error: errors.append(error)
        active = threading.Thread(target=writer, daemon=True); active.start()
        try:
            self.assertTrue(committed.wait(2), 'WAL writer did not commit before reads')
            for index in range(50):
                end = self.bootstrap(thread, index)
                self.assertEqual(end['metadata'], dict(nativeTitle='Stable', openingPrompt='Opening'))
                self.ack(thread, end)
        finally:
            stop.set(); active.join(timeout=2)
        self.assertFalse(active.is_alive())
        self.assertGreater(commits[0], 1)
        self.assertEqual(errors, [])


if __name__ == '__main__': unittest.main()
