"""Synthetic ranged-reader probes. No provider home or user session is used."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from native_mock import native_mock

DRIVER = str(Path(sys.argv.pop(1)).resolve())
MOCK = '''#!/usr/bin/env python3
import json, os, sys
if '--version' in sys.argv:
    print('codex-cli 0.154.0'); raise SystemExit(0)
assert os.environ.get('CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED') == '1'
for line in sys.stdin:
    request=json.loads(line); method=request['method']
    if method=='initialized': continue
    if method=='initialize': result={}
    elif method=='thread/items/list':
        with open(os.environ['MOCK_ITEMS']) as source: items=json.load(source)
        p=request['params']; asc=p['sortDirection']=='asc'; cursor=p.get('cursor')
        boundary=int(cursor.split('-',1)[1]) if cursor else (-1 if asc else len(items))
        reverse=bool(cursor and cursor.startswith('reverse-'))
        indices=[n for n in (range(len(items)) if asc else reversed(range(len(items))))
                 if ((n>=boundary if asc else n<=boundary) if reverse else (n>boundary if asc else n<boundary))]
        selected=indices[:p['limit']]
        result={'data':[items[n] for n in selected], 'nextCursor':f'opaque-{selected[-1]}' if len(indices)>len(selected) else None,
                'backwardsCursor':f'reverse-{selected[0]}' if selected else None}
    else: raise SystemExit(3)
    print(json.dumps({'id':request['id'],'result':result}),flush=True)
'''


class WindowReaderTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='tessera-window-reader-')
        self.root = Path(self.directory.name).resolve()
        self.process = None

    def tearDown(self):
        if self.process:
            self.process.stdin.close()
            try: self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait(timeout=4)
            self.process.stdout.close(); self.process.stderr.close()
        self.directory.cleanup()

    def start(self, provider, count=1000, entries=None):
        home = self.root / provider
        path = home / ('sessions/rollout-00000000-0000-0000-0000-000000000001.jsonl' if provider == 'codex' else 'projects/project/session.jsonl')
        path.parent.mkdir(parents=True)
        self.path = path
        entries = entries if entries is not None else [{'type': 'user', 'uuid': f'r{index}',
            'parentUuid': f'r{index - 1}' if index else None,
            'message': {'role': 'user', 'content': f'synthetic {index}'}} for index in range(count)]
        path.write_text(''.join(json.dumps(entry) + '\n' for entry in entries))
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'), CLAUDE_CONFIG_DIR=str(self.root / 'claude'),
                           PI_CODING_AGENT_DIR=str(self.root / 'pi'))
        self.items = self.root / 'items.json'
        if provider == 'codex':
            self.items.write_text(json.dumps([{'turnId': 'synthetic', 'item': {'type': 'agentMessage', 'id': f'r{index}', 'text': 'synthetic'}} for index in range(count)]))
            executable = self.root / 'bin/codex'; executable.parent.mkdir(); executable.write_text(MOCK); executable.chmod(0o700)
            native_mock(executable)
            environment.update(PATH=str(executable.parent) + os.pathsep + os.environ['PATH'], MOCK_ITEMS=str(self.items))
        self.process = subprocess.Popen([DRIVER, provider, str(path)], env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def request(self, **request):
        expected_error = request.pop('expected_error', None)
        self.process.stdin.write(json.dumps(request) + '\n'); self.process.stdin.flush()
        self.assertTrue(select.select([self.process.stdout], [], [], 5)[0], 'reader deadline')
        line = self.process.stdout.readline()
        self.assertTrue(line, 'reader disconnected')
        reply = json.loads(line)
        if expected_error: self.assertEqual(reply.get('error'), expected_error)
        else: self.assertNotIn('error', reply, reply)
        return reply

    def test_canonical_authority_reads_prefix_not_unfinished_tail(self):
        self.start('codex', entries=[dict(type='session_meta', payload=dict(
            id='00000000-0000-0000-0000-000000000001', history_mode='paginated'))])
        with self.path.open('ab') as output:
            output.write(b'{"unfinished":"')
            output.truncate(80 * 1024 * 1024)
        result = self.request(op='authority')
        self.assertTrue(result['canonical'])
        self.assertLessEqual(result['bytesRead'], 65536)

    def test_unmarked_authority_probe_does_not_scan_unfinished_tail(self):
        self.start('codex', entries=[dict(type='response_item', payload=dict(
            type='message', role='assistant', content=[]))])
        with self.path.open('ab') as output:
            output.truncate(80 * 1024 * 1024)
        result = self.request(op='authority')
        self.assertFalse(result['canonical'])
        self.assertLessEqual(result['bytesRead'], 65536)

    def test_canonical_authority_header_failures_are_explicit(self):
        self.start('codex', entries=[])
        self.assertFalse(self.request(op='authority')['canonical'])
        self.path.write_text('{"type":"session_meta"')
        self.request(op='authority', expected_error='headerIncomplete')
        with self.path.open('ab') as output:
            output.truncate(9 * 1024 * 1024)
        self.request(op='authority', expected_error='headerBudgetExceeded')
        self.path.write_text('{"type":"session_meta","payload":{}}\n')
        self.request(op='authority', expected_error='codexInvalidCanonicalHeader')

    def test_canonical_authority_recovers_archive_move(self):
        self.start('codex', entries=[dict(type='session_meta', payload=dict(
            id='00000000-0000-0000-0000-000000000001', history_mode='paginated'))])
        self.assertTrue(self.request(op='authority')['canonical'])
        archived = self.root / 'codex/archived_sessions' / self.path.name
        archived.parent.mkdir()
        self.path.rename(archived)
        result = self.request(op='authority')
        self.assertTrue(result['canonical'])
        self.assertEqual(result['path'], str(archived))

    @staticmethod
    def message(identifier, parent=None, **fields):
        return dict(type='user', uuid=identifier, parentUuid=parent,
                    message={'role': 'user', 'content': identifier}, **fields)

    @staticmethod
    def fork_completed(ordinal, owner, identity, text):
        return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed',
            thread_id=owner, turn_id='turn', item=dict(type='AgentMessage', id=identity,
            content=[dict(type='Text', text=text)])))

    def fork_fixture(self, parent_base=None):
        child = '00000000-0000-0000-0000-000000000001'
        parent = '00000000-0000-0000-0000-000000000002'
        parent_rows = [dict(ordinal=0, type='session_meta', payload=dict(id=parent, history_mode='paginated')),
                       self.fork_completed(1, parent, 'parent-item', 'parent at fork')]
        parent_raw = ''.join(json.dumps(row) + '\n' for row in parent_rows)
        base = dict(thread_id=parent, end_ordinal_exclusive=2, end_byte_offset=len(parent_raw.encode()))
        self.start('codex', entries=[dict(ordinal=2, type='session_meta', payload=dict(id=child,
            history_mode='paginated', history_base=parent_base or base)),
            self.fork_completed(3, child, 'child-item', 'child body')])
        parent_path = self.path.with_name('rollout-' + parent + '.jsonl')
        parent_path.write_text(parent_raw)
        return child, parent, parent_path, base

    def test_codex_fork_prefix_is_authorized_bounded_and_live_independent(self):
        child, parent, parent_path, _ = self.fork_fixture()
        first = self.request(op='read', fallback=True)
        self.assertEqual([row['id'] for row in first['records']], ['parent-item', 'child-item'])
        self.assertEqual(first['sourceEnd'], parent_path.stat().st_size + self.path.stat().st_size)
        self.assertTrue(all(row['sourceOffset'] < first['sourceEnd'] for row in first['records']))
        self.assertGreaterEqual(first['records'][1]['sourceOffset'], parent_path.stat().st_size)
        with parent_path.open('a') as output:
            output.write(json.dumps(self.fork_completed(2, parent, 'outside-cutoff', 'not inherited')) + '\n')
            output.write(json.dumps(self.fork_completed(3, parent, 'parent-item', 'parent revised after fork')) + '\n')
        unchanged = self.request(op='read', page=first['page'], direction='after')
        self.assertEqual(unchanged['records'], [])
        with self.path.open('a') as output:
            output.write(json.dumps(self.fork_completed(4, child, 'new-child', 'new')) + '\n')
            output.write(json.dumps(self.fork_completed(5, child, 'child-item', 'revised')) + '\n')
        latest = self.request(op='read', page=unchanged['page'], direction='after')
        self.assertEqual([row['id'] for row in latest['records']], ['new-child'])
        revision = self.request(op='revise', page=first['page'], index=1)
        self.assertTrue(revision['changed'])
        self.assertEqual(revision['recordID'], 'child-item')
        fresh = self.request(op='read', fallback=True)
        self.assertEqual([row['id'] for row in fresh['records']], ['parent-item', 'child-item', 'new-child'])
        self.assertEqual(fresh['records'][0]['body']['blocks'][0]['text'], 'parent at fork')
        parent_path.write_text('')
        self.request(op='read', page=latest['page'], direction='after', expected_error='sourceChanged')

    def test_codex_fork_rejects_mismatched_byte_ordinal_cutoff_and_header(self):
        _, _, parent_path, base = self.fork_fixture()
        rows = [json.loads(row) for row in self.path.read_text().splitlines()]
        for changed in (dict(base, end_byte_offset=base['end_byte_offset'] - 1),
                        dict(base, end_ordinal_exclusive=3)):
            rows[0]['payload']['history_base'] = changed
            rows[0]['ordinal'] = changed['end_ordinal_exclusive']
            rows[1]['ordinal'] = rows[0]['ordinal'] + 1
            self.path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            self.request(op='read', fallback=True, expected_error='codexLineageCutoffMismatch')
        rows[0]['payload']['history_base'] = base; rows[0]['ordinal'] = 2; rows[1]['ordinal'] = 3
        self.path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        parent_path.write_text(parent_path.read_text().replace('000000000002', '000000000099'))
        self.request(op='read', fallback=True, expected_error='sourceChanged')

    def test_codex_parent_lookup_ignores_other_provider_failure_and_reuses_hint(self):
        child, _, _, _ = self.fork_fixture()
        claude = self.root / 'claude'; claude.mkdir()
        (claude / 'projects').write_text('not a provider directory')
        first = self.request(op='read', fallback=True)
        self.assertEqual(len(first['records']), 2)
        # The confirmed candidate hint should now avoid another catalog walk;
        # its actual file/header still must be reopened and verified.
        (self.root / 'codex/archived_sessions').write_text('unrelated unavailable root')
        with self.path.open('a') as output:
            output.write(json.dumps(self.fork_completed(4, child, 'next', 'next')) + '\n')
        update = self.request(op='read', page=first['page'], direction='after')
        self.assertEqual([row['id'] for row in update['records']], ['next'])

    def test_codex_parent_archive_keeps_identical_prefix_generation_and_rediscovers(self):
        child, _, parent_path, _ = self.fork_fixture()
        first = self.request(op='read', fallback=True)
        archived = self.root / 'codex/archived_sessions'
        archived.mkdir()
        archived_path = archived / parent_path.name
        parent_path.rename(archived_path)
        # A relocated dependency with an identical validated prefix keeps its
        # content-derived generation: the old cursor stays usable and sees no
        # new records, while bootstrap rediscovers the authorized file.
        unchanged = self.request(op='read', page=first['page'], direction='after')
        self.assertEqual(unchanged['records'], [])
        fresh = self.request(op='read', fallback=True)
        self.assertEqual([row['id'] for row in fresh['records']], ['parent-item', 'child-item'])
        with self.path.open('a') as output:
            output.write(json.dumps(self.fork_completed(4, child, 'next', 'next')) + '\n')
        update = self.request(op='read', page=fresh['page'], direction='after')
        self.assertEqual([row['id'] for row in update['records']], ['next'])
        # Both cached aliases remain safe when the same file moves back.
        archived_path.rename(parent_path)
        fresh = self.request(op='read', fallback=True)
        self.assertEqual(len(fresh['records']), 3)

    def test_codex_cached_parent_symlink_cannot_redirect_to_archived_copy(self):
        _, _, parent_path, _ = self.fork_fixture()
        self.request(op='read', fallback=True)
        archived = self.root / 'codex/archived_sessions'
        archived.mkdir()
        archived_path = archived / parent_path.name
        parent_path.rename(archived_path)
        parent_path.symlink_to(archived_path)
        self.request(op='read', fallback=True, expected_error='sourceMissing')

    def test_codex_fork_rejects_cycle_and_parent_symlink(self):
        child, _, parent_path, base = self.fork_fixture()
        rows = [json.loads(row) for row in self.path.read_text().splitlines()]
        rows[0]['payload']['history_base']['thread_id'] = child
        self.path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        self.request(op='read', fallback=True, expected_error='codexLineageCycle')
        rows[0]['payload']['history_base'] = base
        self.path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        saved = self.root / 'outside.jsonl'; parent_path.rename(saved); parent_path.symlink_to(saved)
        self.request(op='read', fallback=True, expected_error='sourceMissing')

    def test_codex_fork_pages_cross_physical_sources_in_both_directions(self):
        child, parent, parent_path, _ = self.fork_fixture()
        parent_rows = [dict(ordinal=0, type='session_meta', payload=dict(id=parent, history_mode='paginated'))]
        parent_rows += [self.fork_completed(index + 1, parent, f'p{index}', f'parent {index}') for index in range(120)]
        parent_path.write_text(''.join(json.dumps(row) + '\n' for row in parent_rows))
        rows = [dict(ordinal=121, type='session_meta', payload=dict(id=child, history_mode='paginated',
            history_base=dict(thread_id=parent, end_ordinal_exclusive=121, end_byte_offset=parent_path.stat().st_size)))]
        rows += [self.fork_completed(index + 122, child, f'c{index}', f'child {index}') for index in range(120)]
        self.path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        latest = self.request(op='read', fallback=True)
        self.assertEqual([row['id'] for row in latest['records']], [f'c{i}' for i in range(20, 120)])
        middle = self.request(op='read', page=latest['page'], direction='before')
        self.assertEqual([row['id'] for row in middle['records']], [f'p{i}' for i in range(40, 120)] + [f'c{i}' for i in range(20)])
        oldest = self.request(op='read', page=middle['page'], direction='before')
        self.assertEqual([row['id'] for row in oldest['records']], [f'p{i}' for i in range(40)])
        back = self.request(op='read', page=oldest['page'], direction='after')
        self.assertEqual([row['id'] for row in back['records']], [row['id'] for row in middle['records']])
        self.assertFalse(oldest['hasOlder'])

    def test_codex_multilevel_fork_has_no_depth_capacity(self):
        child, _, _, _ = self.fork_fixture()
        def build(count):
            base = None
            for number in reversed(range(1, count + 1)):
                identity = f'00000000-0000-0000-0000-{number:012d}'
                ordinal = base['end_ordinal_exclusive'] if base else 0
                rows = [dict(ordinal=ordinal, type='session_meta', payload=dict(id=identity,
                    history_mode='paginated', **(dict(history_base=base) if base else {}))),
                    self.fork_completed(ordinal + 1, identity, f'item-{number}', 'synthetic')]
                target = self.path.with_name('rollout-' + identity + '.jsonl')
                target.write_text(''.join(json.dumps(row) + '\n' for row in rows))
                base = dict(thread_id=identity, end_ordinal_exclusive=ordinal + 2, end_byte_offset=target.stat().st_size)
        build(3)
        page = self.request(op='read', fallback=True)
        self.assertEqual([row['id'] for row in page['records']], ['item-3', 'item-2', 'item-1'])
        # Lineage depth is not an admission criterion: nine physical
        # ancestors page through the same bounded reader as three.
        build(9)
        page = self.request(op='read', fallback=True)
        self.assertEqual([row['id'] for row in page['records']], [f'item-{number}' for number in range(9, 0, -1)])

    def test_claude_selects_latest_main_leaf_and_compaction_parent(self):
        rows = [self.message('root'), self.message('obsolete', 'root'),
                self.message('fork', 'root'), self.message('child', 'fork', isSidechain=True),
                self.message('meta', 'fork', isMeta=True), self.message('team', 'fork', teamName='worker'),
                {'type': 'progress', 'uuid': 'progress', 'parentUuid': 'fork'},
                self.message('summary', isCompactSummary=True, logicalParentUuid='fork'),
                self.message('latest', 'summary')]
        self.start('claude', entries=rows)
        page = self.request(op='read')
        self.assertEqual([row['id'] for row in page['records']], ['summary', 'latest'])
        self.assertFalse(page['hasOlder'])

    def test_claude_history_pages_back_past_compaction_boundary(self):
        # Claude Code's compact_boundary is a parentUuid root; its advisory
        # logicalParentUuid links the display history to prior records.
        rows = [self.message(f'r{n}', f'r{n - 1}' if n else None) for n in range(150)]
        rows.append(dict(type='system', subtype='compact_boundary', uuid='boundary', parentUuid=None,
                         logicalParentUuid='r149', content='Conversation compacted'))
        rows.append(self.message('summary', 'boundary', isCompactSummary=True))
        rows += [self.message(f'p{n}', f'p{n - 1}' if n else 'summary') for n in range(60)]
        self.start('claude', entries=rows)
        latest = self.request(op='read')
        self.assertEqual([row['id'] for row in latest['records']],
                         [f'r{n}' for n in range(112, 150)] + ['boundary', 'summary'] + [f'p{n}' for n in range(60)])
        self.assertTrue(latest['hasOlder'])
        older = self.request(op='read', page=latest['page'], direction='before')
        self.assertEqual([row['id'] for row in older['records']], [f'r{n}' for n in range(12, 112)])
        oldest = self.request(op='read', page=older['page'], direction='before')
        self.assertEqual([row['id'] for row in oldest['records']], [f'r{n}' for n in range(12)])
        self.assertFalse(oldest['hasOlder'])

    def test_claude_append_keeps_cursor_but_branch_switch_invalidates_it(self):
        self.start('claude', entries=[self.message('root'), self.message('first', 'root')])
        page = self.request(op='read')
        with self.path.open('a') as output: output.write(json.dumps(self.message('next', 'first')) + '\n')
        update = self.request(op='read', page=page['page'], direction='after')
        self.assertEqual([row['id'] for row in update['records']], ['next'])
        with self.path.open('a') as output: output.write(json.dumps(self.message('replacement', 'root')) + '\n')
        self.request(op='read', page=update['page'], direction='after', expected_error='sourceChanged')
        fresh = self.request(op='read')
        self.assertEqual([row['id'] for row in fresh['records']], ['root', 'replacement'])

    def test_claude_terminal_progress_selects_main_branch_over_later_sidechain(self):
        rows = [self.message('root'), self.message('main', 'root'),
                {'type': 'progress', 'uuid': 'progress', 'parentUuid': 'main'},
                self.message('child', 'root', isSidechain=True)]
        self.start('claude', entries=rows)
        page = self.request(op='read')
        # Authored-message selection still follows the SDK's main leaf. Keep
        # trailing context in canonical ordinals before a later user parents
        # to it; context is not an extra authored message.
        self.assertEqual([row['id'] for row in page['records']], ['root', 'main', 'progress'])
        self.assertEqual([row['id'] for row in page['records'] if row['body'].get('role') in ('user', 'assistant')], ['root', 'main'])

    def test_claude_ignores_generic_id_and_parent_aliases(self):
        rows = [self.message('root'), {'type': 'user', 'uuid': 'newroot', 'parentId': 'root',
                'message': {'role': 'user', 'content': 'newroot'}},
                {'type': 'user', 'id': 'not-a-uuid', 'message': {'role': 'user', 'content': 'excluded'}}]
        self.start('claude', entries=rows)
        page = self.request(op='read')
        self.assertEqual([row['id'] for row in page['records']], ['newroot'])

    def test_claude_overlong_structural_id_is_not_silently_omitted(self):
        self.start('claude', entries=[self.message('x' * 257), self.message('child', 'x' * 257)])
        self.request(op='read', expected_error='claudeIndexUnproven')

    def test_claude_in_place_same_size_rewrite_invalidates_generation(self):
        self.start('claude', entries=[self.message('root'), self.message('next', 'root')])
        page = self.request(op='read')
        self.path.write_text(self.path.read_text().replace('"content": "root"', '"content": "edit"'))
        self.request(op='read', page=page['page'], direction='after', expected_error='sourceChanged')

    def test_claude_duplicate_terminal_uses_newest_body_and_invalidates_window(self):
        self.start('claude', entries=[self.message('root'), self.message('leaf', 'root')])
        page = self.request(op='read')
        updated = self.message('leaf', 'root'); updated['message']['content'] = 'newest body'
        with self.path.open('a') as output: output.write(json.dumps(updated) + '\n')
        self.request(op='read', page=page['page'], direction='after', expected_error='sourceChanged')
        fresh = self.request(op='read')
        self.assertEqual([row['id'] for row in fresh['records']], ['root', 'leaf'])
        self.assertEqual(fresh['records'][-1]['body']['blocks'][0]['text'], 'newest body')

    def test_claude_duplicate_ancestor_uses_parent_order_not_physical_order(self):
        updated = self.message('root'); updated['message']['content'] = 'updated root'
        self.start('claude', entries=[self.message('root'), self.message('leaf', 'root'), updated])
        page = self.request(op='read')
        self.assertEqual([row['id'] for row in page['records']], ['root', 'leaf'])
        self.assertEqual(page['records'][0]['body']['blocks'][0]['text'], 'updated root')

    def test_claude_revised_context_parent_does_not_hide_current_messages(self):
        self.start('claude', entries=[self.message('root'), self.message('main', 'root'),
            dict(type='progress', uuid='context', parentUuid='main')])
        page = self.request(op='read')
        self.assertEqual([row['id'] for row in page['records']], ['root', 'main', 'context'])
        with self.path.open('a') as output:
            output.write(json.dumps(dict(type='progress', uuid='context', parentUuid='root')) + '\n')
        self.request(op='read', page=page['page'], direction='after', expected_error='sourceChanged')
        fresh = self.request(op='read')
        self.assertEqual([row['id'] for row in fresh['records']], ['root', 'main'])

    def test_claude_selected_cycle_is_not_successful_empty_history(self):
        self.start('claude', entries=[self.message('a', 'b'), self.message('b', 'a')])
        self.request(op='read', expected_error='claudeIndexUnproven')

    def test_claude_ambiguous_or_invalid_structural_fields_fail_closed(self):
        self.start('claude', entries=[self.message('root')])
        prefix = self.path.read_text()
        for fields in ['"uuid":"leaf","parentUuid":"root","parentUuid":null',
                       '"uuid":"leaf","uuid":"other","parentUuid":"root"',
                       '"uuid":"leaf","parentUuid":23',
                       '"uuid":"leaf","parentUuid":"root","isSidechain":"false"',
                       '"uuid":"leaf","parentUuid":"root","isMeta":0',
                       '"uuid":"","parentUuid":"root"']:
            with self.subTest(fields=fields):
                self.path.write_text(prefix + '{"type":"user",' + fields +
                    ',"message":{"role":"user","content":"synthetic"}}\n')
                self.request(op='read', expected_error='claudeIndexUnproven')

    def test_claude_bad_display_content_preserves_proven_history(self):
        self.start('claude', entries=[self.message('root'),
            dict(type='assistant', uuid='bad-content', parentUuid='root', message=dict(content=[dict(type='future-block')])),
            self.message('after', 'bad-content')])
        page = self.request(op='read')
        self.assertEqual([row['id'] for row in page['records']], ['root', 'bad-content', 'after'])
        self.assertEqual(page['records'][1]['body']['unparsedContentCount'], 1)

    def traverse(self, provider):
        self.start(provider)
        page = self.request(op='read')
        first = page
        self.assertEqual([row['id'] for row in page['records']], [f'r{n}' for n in range(900, 1000)])
        for start in range(800, -1, -100):
            page = self.request(op='read', page=page['page'], direction='before')
            self.assertEqual([row['id'] for row in page['records']], [f'r{n}' for n in range(start, start + 100)])
        self.assertFalse(page['hasOlder'])
        for start in range(100, 901, 100):
            page = self.request(op='read', page=page['page'], direction='after')
            self.assertEqual([row['id'] for row in page['records']], [f'r{n}' for n in range(start, start + 100)])
        self.assertFalse(page['hasNewer'])
        self.assertEqual([row['order'] for row in page['records']], [row['order'] for row in first['records']])

    def test_jsonl_both_directions(self): self.traverse('claude')
    def test_native_both_directions(self): self.traverse('codex')

    @staticmethod
    def codex_completed(ordinal, identifier, text, owner='00000000-0000-0000-0000-000000000001'):
        return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=owner,
            turn_id='turn', item=dict(type='AgentMessage', id=identifier, content=[dict(type='Text', text=text)])))

    def test_paginated_codex_fallback_uses_canonical_items_and_latest_revision(self):
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id='00000000-0000-0000-0000-000000000001', history_mode='paginated'))]
        for index in range(240):
            rows.append(dict(ordinal=len(rows), type='response_item', payload=dict(type='message', role='assistant',
                content=[dict(type='output_text', text='model context must not duplicate canonical message')])))
            rows.append(self.codex_completed(len(rows), f'r{index}', f'canonical {index}'))
        self.start('codex', entries=rows)
        latest = self.request(op='read', fallback=True)
        self.assertEqual([row['id'] for row in latest['records']], [f'r{index}' for index in range(140, 240)])
        older = self.request(op='read', page=latest['page'], direction='before')
        self.assertEqual([row['id'] for row in older['records']], [f'r{index}' for index in range(40, 140)])
        back = self.request(op='read', page=older['page'], direction='after')
        self.assertEqual([row['order'] for row in back['records']], [row['order'] for row in latest['records']])
        with self.path.open('a') as output:
            output.write(json.dumps(self.codex_completed(len(rows), 'r40', 'revised deep history')) + '\n')
        head = self.request(op='read', page=latest['page'], direction='after')
        self.assertEqual(head['records'], [])
        update = self.request(op='revise', page=older['page'], index=0)
        self.assertTrue(update['changed']); self.assertEqual(update['recordID'], 'r40')
        self.assertGreater(update['revision'], older['records'][0]['revision'])
        refreshed = self.request(op='read', page=latest['page'], direction='before')
        self.assertEqual(refreshed['records'][0]['body']['blocks'][0]['text'], 'revised deep history')

    def test_paginated_codex_fallback_honors_inherited_header_boundary(self):
        rows = [dict(ordinal=0, type='session_meta', payload=dict(id='00000000-0000-0000-0000-000000000001',
            history_mode='paginated', subagent_history_start_ordinal=3)),
            dict(ordinal=1, type='session_meta', payload=dict(id='parent', history_mode='paginated')),
            self.codex_completed(2, 'parent-only', 'inherited context', owner='parent'), self.codex_completed(3, 'own', 'own text')]
        self.start('codex', entries=rows)
        page = self.request(op='read', fallback=True)
        self.assertEqual([row['id'] for row in page['records']], ['own'])
        self.assertFalse(page['hasOlder'])

    def test_legacy_codex_fallback_does_not_require_completed_items(self):
        rows = [dict(type='session_meta', payload=dict(id='00000000-0000-0000-0000-000000000001', history_mode='legacy')),
                dict(type='response_item', payload=dict(type='message', role='assistant', content=[dict(type='output_text', text='legacy body')]))]
        self.start('codex', entries=rows)
        page = self.request(op='read', fallback=True)
        self.assertEqual(page['records'][-1]['body']['blocks'][0]['text'], 'legacy body')

    def test_paginated_rejected_lines_are_visible_without_losing_later_history(self):
        rows = [dict(ordinal=0, type='session_meta', payload=dict(
            id='00000000-0000-0000-0000-000000000001', history_mode='paginated')),
            self.codex_completed(1, 'before', 'before')]
        self.start('codex', entries=rows)
        with self.path.open('a') as output:
            output.write('not json\n\n' + json.dumps(self.codex_completed(2, 'after', 'after')) + '\n')
        page = self.request(op='read', fallback=True)
        self.assertEqual(len(page['records']), 4)
        self.assertEqual(page['records'][0]['id'], 'before')
        self.assertEqual(page['records'][-1]['id'], 'after')
        for row in page['records'][1:3]:
            self.assertTrue(row['body']['malformed'])
            self.assertEqual(row['body']['sourceType'], 'malformed-json')
        with self.path.open('a') as output:
            output.write(json.dumps(self.codex_completed(3, 'before', 'revised')) + '\n')
        head = self.request(op='read', page=page['page'], direction='after')
        self.assertEqual(head['records'], [])
        self.assertTrue(self.request(op='revise', page=page['page'], index=0)['changed'])
        self.assertFalse(self.request(op='revise', page=page['page'], index=1)['changed'])

    def test_paginated_unknown_envelopes_and_nested_content_are_not_silently_dropped(self):
        rows = [dict(ordinal=0, type='session_meta', payload=dict(
            id='00000000-0000-0000-0000-000000000001', history_mode='paginated', subagent_history_start_ordinal=4)),
            dict(ordinal=1, type='future_root', payload=['new schema']),
            dict(ordinal=2, type='event_msg', payload=dict(type='future_event')),
            dict(ordinal=3, type='response_item', payload=dict(type='message', role='assistant',
                content=[dict(type='output_text', text='parent context must not become authored chat'),
                         dict(type='future_content', text='not understood')])),
            self.codex_completed(4, 'after', 'after diagnostics')]
        self.start('codex', entries=rows)
        page = self.request(op='read', fallback=True)
        self.assertEqual(len(page['records']), 4)
        self.assertEqual([row['body']['type'] for row in page['records'][:2]], ['unknown', 'unknown'])
        self.assertGreater(page['records'][2]['body']['unparsedContentCount'], 0)
        self.assertNotIn('parent context', json.dumps(page))
        self.assertEqual(page['records'][-1]['id'], 'after')

    def test_legacy_mirrors_keep_ranged_and_live_boundaries_stable(self):
        def event(text): return dict(type='event_msg', payload=dict(type='agent_message', message=text))
        def response(text): return dict(type='response_item', payload=dict(type='message', role='assistant', content=[dict(type='output_text', text=text)]))
        rows = [dict(type='session_meta', payload=dict(id='00000000-0000-0000-0000-000000000001', history_mode='legacy')),
                dict(type='event_msg', payload=dict(type='task_started', turn_id='turn'))]
        for i in range(120): rows.extend([response(str(i)), event(str(i))])
        self.start('codex', entries=rows)
        newest = self.request(op='read', fallback=True)
        texts = lambda page: [block['text'] for row in page['records'] for block in row['body'].get('blocks', []) if block['type'] == 'text']
        self.assertEqual(texts(newest), [str(i) for i in range(20, 120)])
        older = self.request(op='read', page=newest['page'], direction='before')
        self.assertEqual(texts(older), [str(i) for i in range(20)])
        with self.path.open('a') as output: output.write(json.dumps(event('live')) + '\n')
        live = self.request(op='read', page=newest['page'], direction='after')
        self.assertEqual(texts(live), ['live'])
        with self.path.open('a') as output: output.write(json.dumps(response('live')) + '\n')
        unchanged = self.request(op='read', page=live['page'], direction='after')
        self.assertEqual(unchanged['records'], [])
        revision = self.request(op='revise', page=live['page'], index=0)
        self.assertFalse(revision['changed'])
        self.assertEqual(revision['revision'], live['records'][0]['revision'])

    def test_paginated_revision_rejects_replacement_after_index_refresh(self):
        for changed in (False, True):
            with self.subTest(changed=changed):
                if self.process:
                    self.process.stdin.close(); self.process.wait(timeout=4)
                    self.process.stdout.close(); self.process.stderr.close(); self.process = None
                    # Reuse only the run-owned fixture directory.
                    self.directory.cleanup(); self.directory = tempfile.TemporaryDirectory(prefix='tessera-window-reader-')
                    self.root = Path(self.directory.name).resolve()
                rows = [dict(ordinal=0, type='session_meta', payload=dict(id='00000000-0000-0000-0000-000000000001', history_mode='paginated')),
                        self.codex_completed(1, 'item', 'original')]
                self.start('codex', entries=rows)
                page = self.request(op='read', fallback=True)
                if changed:
                    with self.path.open('a') as output: output.write(json.dumps(self.codex_completed(2, 'item', 'revised')) + '\n')
                self.request(op='read', page=page['page'], direction='after')
                replacement = self.path.with_suffix('.replacement')
                replacement.write_bytes(self.path.read_bytes()); replacement.replace(self.path)
                self.request(op='revise', page=page['page'], index=0, expected_error='sourceChanged')

    def test_deep_native_revision_uses_item_local_anchor(self):
        self.start('codex')
        page = self.request(op='read')
        for _ in range(9): page = self.request(op='read', page=page['page'], direction='before')
        items = json.loads(self.items.read_text()); items[0]['item']['text'] = 'revised deep history'; self.items.write_text(json.dumps(items))
        reply = self.request(op='revise', page=page['page'], index=0)
        self.assertEqual(reply['recordID'], 'r0'); self.assertTrue(reply['changed'])
        self.assertGreater(reply['revision'], page['records'][0]['revision'])


if __name__ == '__main__': unittest.main()
