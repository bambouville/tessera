"""OpenCode bounded window and shared-service protocol on owned SQLite files."""
import json
import base64
import ctypes
import os
from pathlib import Path
import sqlite3
import unittest
import test_service as service
from test_service import frame, receive


class OpenCodeReaderTests(unittest.TestCase):
    setUp = service.ServiceTests.setUp
    tearDown = service.ServiceTests.tearDown
    client = service.ServiceTests.client
    read_page = service.ServiceTests.read_page
    window_page = service.ServiceTests.window_page
    window_ack = service.ServiceTests.window_ack
    service = service.ServiceTests.service

    def core_search(self, begin, rows, end, query='reply'):
        library=os.environ.get('TESSERA_AGENT_CORE_LIBRARY')
        if not library: return
        function=ctypes.CDLL(library).tessera_agent_page_search
        function.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_size_t]
        function.restype=ctypes.c_int32
        wire=b''.join(frame(value) for value in [begin,*rows,end])
        request=json.dumps(dict(wire=base64.b64encode(wire).decode(),epoch=begin['serviceEpoch'],thread=begin['thread'],
            threadID=dict(hostID='A11CE000-0000-4000-8000-000000000001',providerID=dict(rawValue='opencode'),
                          providerSessionID='ses_synthetic'),query=query)).encode()
        size=function(request,len(request),None,0)
        self.assertGreater(size,0,'actual OpenCode wire rejected by shared Core')
        output=ctypes.create_string_buffer(size)
        self.assertEqual(function(request,len(request),output,size),size)
        return json.loads(output.raw)

    def start(self, count=250):
        path = Path(os.environ['XDG_DATA_HOME'])/'opencode/opencode.db'
        path.parent.mkdir(parents=True)
        self.db=sqlite3.connect(path)
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
        for index in range(count): self.append(index)
        self.service(idle=30000,lease=30000)
        client,hello=self.client()
        self.assertIn('opencode.sqlite.v1-v2',hello['capabilities'])
        client.sendall(frame(dict(kind='resolve',id='resolve',provider='opencode',nativeSessionID='ses_synthetic')))
        reply=receive(client)
        self.assertEqual(reply['kind'],'resolved',reply)
        return client,reply['thread']

    def append(self,index,text=None):
        self.db.execute('INSERT INTO part VALUES(?,?,?,?,?,?)',
            (f'prt_{index:04}','msg_synthetic','ses_synthetic',index,index,json.dumps(dict(type='text',text=text or f'reply {index}'))))
        self.db.commit()

    def test_latest_history_append_and_same_record_revision(self):
        client,thread=self.start()
        begin,rows,end=self.window_page(client,thread,'bootstrap',0)
        self.core_search(begin,rows,end)
        self.assertTrue(all('sourceEnd' not in row for row in rows))
        self.assertEqual(rows[0]['recordID'],'prt_0150')
        self.assertEqual(rows[-1]['recordID'],'prt_0249')
        self.assertEqual(end['backend'],'opencode-sqlite')
        head=end['window']['segmentID']; self.window_ack(client,thread,end,[head],head)
        _,older,history=self.window_page(client,thread,'before',end['window']['version'],end['window']['before'])
        self.assertEqual(older[0]['recordID'],'prt_0050')
        self.assertEqual(older[-1]['recordID'],'prt_0149')
        old=history['window']['segmentID']; self.window_ack(client,thread,history,[old],head)
        self.append(250)
        _,newer,live=self.window_page(client,thread,'head',history['window']['version'],end['liveCursor'])
        self.assertEqual(newer[-1]['recordID'],'prt_0250')
        head=live['window']['segmentID']; self.window_ack(client,thread,live,[old],head)
        self.db.execute('UPDATE part SET data=? WHERE id=?',(json.dumps(dict(type='text',text='grown reply')),'prt_0250')); self.db.commit()
        found=False
        for _ in range(6):
            _,patches,update=self.window_page(client,thread,'head',live['window']['version'],live['liveCursor'])
            found |= any(p['recordID']=='prt_0250' and p['record']['blocks'][0]['text']=='grown reply' for p in patches)
            # Revision partitions are adopted by the same generic ACK helper.
            window=update['window']
            if window.get('partitions'):
                head_parts=[p for p in window['partitions'] if p['original']==head]
                old_parts=[p for p in window['partitions'] if p['original']==old]
                if head_parts: head=head_parts[-1]['id']
                if old_parts: old=old_parts[0]['id']
            self.window_ack(client,thread,update,[old],head)
            live=update
            if found: break
        self.assertTrue(found)

    def test_empty_session_can_receive_first_live_record(self):
        client,thread=self.start(0)
        _,rows,end=self.window_page(client,thread,'bootstrap',0)
        self.assertEqual([row['disposition'] for row in rows],['metadata'])
        head=end['window']['segmentID']; self.window_ack(client,thread,end,[head],head)
        self.append(0)
        _,rows,_=self.window_page(client,thread,'head',end['window']['version'],end['liveCursor'])
        self.assertEqual(rows[-1]['recordID'],'prt_0000')

    def test_stateless_search_does_not_mutate_window(self):
        client,thread=self.start()
        _,_,end=self.window_page(client,thread,'bootstrap',0)
        head=end['window']['segmentID']; self.window_ack(client,thread,end,[head],head)
        client.sendall(frame(dict(kind='bootstrap',id='search',thread=thread)))
        begin,rows,page=self.read_page(client)
        self.core_search(begin,rows,page)
        self.assertEqual(rows[0]['recordID'],'prt_0150')
        client.sendall(frame(dict(kind='history',id='search-older',thread=thread,cursor=page['historyCursor'])))
        _,rows,_=self.read_page(client)
        self.assertEqual(rows[-1]['recordID'],'prt_0149')
        self.append(250)
        _,rows,_=self.window_page(client,thread,'head',end['window']['version'],end['liveCursor'])
        self.assertEqual(rows[-1]['recordID'],'prt_0250')

    def test_native_id_requires_database_membership(self):
        client,_=self.start(1)
        client.sendall(frame(dict(kind='resolve',id='unknown',provider='opencode',nativeSessionID='ses_missing')))
        self.assertEqual(receive(client)['kind'],'error')

    def test_interior_insertion_requires_resync_not_empty_success(self):
        client,thread=self.start(3)
        # Another message places the insertion behind the live head.
        self.db.execute('INSERT INTO message VALUES(?,?,?,?,?)',
            ('msg_tail','ses_synthetic',10,10,json.dumps(dict(role='assistant')))); self.db.commit()
        _,_,end=self.window_page(client,thread,'bootstrap',0)
        head=end['window']['segmentID']; self.window_ack(client,thread,end,[head],head)
        self.append(4)
        client.sendall(frame(dict(kind='window.read',id='changed',thread=thread,operation='head',
            windowVersion=end['window']['version'],cursor=end['liveCursor'])))
        response=receive(client)
        self.assertEqual(response['kind'],'error',response)
        self.assertEqual(response['code'],'sourceChanged')

    def test_summary_preserves_provider_title(self):
        client,thread=self.start(1)
        client.sendall(frame(dict(kind='summary',id='summary',thread=thread)))
        response=receive(client)
        self.assertEqual(response['kind'],'summary',response)
        self.assertTrue(any(row.get('type')=='session-title' and row.get('title')=='Synthetic' for row in response['records']))


if __name__ == '__main__': unittest.main()
