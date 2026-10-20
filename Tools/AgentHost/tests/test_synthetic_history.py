"""Production-window synthetic acceptance; deterministic oracles, bounded pages."""
import base64
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
import uuid
from types import SimpleNamespace
from synthetic_history import History, WindowClient, install_termination_handler

BINARY = Path(sys.argv.pop(1)).resolve()


class SyntheticHistoryTests(unittest.TestCase):
    def test_claude_oversized_image_tail_completes_first_page(self):
        # Claude stores each image's base64 twice. A newest page spanning more
        # bytes and oversized records than one read slice retains must still
        # finish instead of replaying its first records every slice.
        with tempfile.TemporaryDirectory(prefix='tessera-images-', dir='/tmp') as directory:
            root = Path(directory).resolve()
            session = '0b0e0000-0000-4000-8000-00000000000a'
            path = root / 'claude/projects/-home-user-project' / f'{session}.jsonl'
            path.parent.mkdir(parents=True)
            image = base64.b64encode(b'\x89PNG' * (3 * 1024 * 1024 // 4)).decode()
            parent = None

            def write(stream, kind, message, **extra):
                nonlocal parent
                row = dict(parentUuid=parent, isSidechain=False, userType='external',
                           cwd='/home/user/project', sessionId=session, version='2.1.283',
                           gitBranch='main', type=kind, uuid=str(uuid.uuid4()),
                           timestamp='2026-09-28T10:00:00.000Z', message=message, **extra)
                stream.write(json.dumps(row, separators=(',', ':')) + '\n')
                parent = row['uuid']

            with path.open('w') as stream:
                write(stream, 'user', dict(role='user', content='Please look at these screenshots'))
                for index in range(12):
                    tool = f'toolu_{index:06d}'
                    write(stream, 'assistant', dict(id=f'msg_{index}', role='assistant',
                          model='claude-opus-5-5', content=[dict(type='tool_use', id=tool,
                          name='Read', input=dict(file_path=f'/tmp/shot{index}.png'))]))
                    write(stream, 'user', dict(role='user', content=[dict(type='tool_result',
                          tool_use_id=tool, content=[dict(type='image', source=dict(type='base64',
                          media_type='image/png', data=image))])]), toolUseResult=dict(type='image',
                          file=dict(base64=image, type='image/png', originalSize=len(image))))
                    write(stream, 'assistant', dict(id=f'msg_{index}_note', role='assistant',
                          model='claude-opus-5-5', content=[dict(type='text',
                          text=f'Screenshot {index} note.')]))
            file_size = path.stat().st_size
            self.assertGreater(file_size, 64 * 1024 * 1024)
            history = SimpleNamespace(root=root, provider='claude', path=path)
            with WindowClient(BINARY, history, timeout=20, rss_limit=2 * 1024 * 1024 * 1024) as client:
                started = time.monotonic()
                identifier = client.send(dict(kind='window.read', thread=client.thread,
                                              operation='bootstrap', windowVersion=0,
                                              readProgress=True))
                progress = []
                records = []
                while True:
                    frame = client.receive(identifier)
                    if frame['kind'] == 'read.progress':
                        progress.append(int(frame['bytesRead']))
                    elif frame['kind'] == 'page.begin':
                        continue
                    elif frame['kind'] == 'page.record':
                        records.append(frame)
                    elif frame['kind'] == 'page.end':
                        break
                    else:
                        self.fail(f'unexpected frame: {frame["kind"]}')
                elapsed = time.monotonic() - started
                self.assertLess(elapsed, 20)
                self.assertEqual(frame['records'], len(records))
                self.assertGreaterEqual(len(records), 12)
                self.assertEqual([row['order'] for row in records],
                                 list(range(records[0]['order'], records[0]['order'] + len(records))))
                texts = [block['text'] for row in records
                         for block in row['record'].get('blocks', []) if block.get('type') == 'text']
                self.assertIn('Screenshot 11 note.', texts)
                # uint64 counters travel as decimal strings.
                bytes_read = max([int(frame['bytesRead']), *progress])
                self.assertLess(bytes_read, file_size * 12)
                print(f'oversized_image_tail seconds={elapsed:.3f} bytesRead={bytes_read} '
                      f'fileSize={file_size} records={len(records)} progress={len(progress)}')

    def test_claude_live_append_reads_only_its_validation(self):
        # An active Claude session appends a record every few seconds, and
        # each append triggers a head read. Rebuilding the branch index from
        # the start rereads the whole transcript, and the single read worker
        # then answers everything else with busy.
        with tempfile.TemporaryDirectory(prefix='tessera-live-append-', dir='/tmp') as directory:
            root = Path(directory).resolve()
            session = '0b0e0000-0000-4000-8000-00000000000b'
            path = root / 'claude/projects/-home-user-project' / f'{session}.jsonl'
            path.parent.mkdir(parents=True)
            output = 'x' * (48 * 1024)
            parent = None

            def row(kind, message, **extra):
                nonlocal parent
                value = dict(parentUuid=parent, isSidechain=False, userType='external',
                             cwd='/home/user/project', sessionId=session, version='2.1.283',
                             gitBranch='main', type=kind, uuid=str(uuid.uuid4()),
                             timestamp='2026-09-28T10:00:00.000Z', message=message, **extra)
                parent = value['uuid']
                return json.dumps(value, separators=(',', ':')) + '\n'

            with path.open('w') as stream:
                for turn in range(160):
                    stream.write(row('user', dict(role='user', content=f'Turn {turn}')))
                    # Per-turn bookkeeping carries no uuid: a parent lookup
                    # can no longer rely on the immediately previous record.
                    for kind in ('ai-title', 'mode', 'permission-mode', 'last-prompt'):
                        stream.write(json.dumps(dict(type=kind, sessionId=session, aiTitle='Live append')) + '\n')
                    for call in range(3):
                        tool = f'toolu_{turn:04d}_{call}'
                        stream.write(row('assistant', dict(id=f'msg_{turn}_{call}', role='assistant',
                                         model='claude-opus-5-5', content=[dict(type='tool_use', id=tool,
                                         name='Bash', input=dict(command='ls'))])))
                        stream.write(row('user', dict(role='user', content=[dict(type='tool_result',
                                         tool_use_id=tool, content=output)])))
                    stream.write(row('assistant', dict(id=f'msg_{turn}_text', role='assistant',
                                     model='claude-opus-5-5', content=[dict(type='text', text=f'Done {turn}.')])))
            history = SimpleNamespace(root=root, provider='claude', path=path)

            def read(client, fields):
                identifier = client.send(dict(kind='window.read', thread=client.thread, readProgress=True, **fields))
                records, progress = [], []
                while True:
                    frame = client.receive(identifier)
                    if frame['kind'] == 'read.progress': progress.append(int(frame['bytesRead']))
                    elif frame['kind'] == 'page.record': records.append(frame)
                    elif frame['kind'] == 'page.end':
                        window = frame['window']
                        head = window.get('segmentID') or ''
                        acked = client.one(dict(kind='window.ack', thread=client.thread, transaction=identifier,
                                                windowVersion=window['version'], viewport=[head] if head else [],
                                                head=head), 'window.acked')
                        return records, max([int(frame['bytesRead']), *progress]), window['version'], acked['liveCursor']
                    elif frame['kind'] != 'page.begin':
                        self.fail(f'unexpected frame: {frame["kind"]}')

            with WindowClient(BINARY, history, timeout=60, rss_limit=1024 * 1024 * 1024) as client:
                records, cold, version, live = read(client, dict(operation='bootstrap', windowVersion=0))
                self.assertTrue(records)
                for index in range(3):
                    with path.open('a') as stream:
                        stream.write(row('assistant', dict(id=f'msg_live_{index}', role='assistant',
                                         model='claude-opus-5-5', content=[dict(type='text', text=f'Live {index}.')])))
                    file_size = path.stat().st_size
                    started = time.monotonic()
                    records, warm, version, live = read(client, dict(operation='head', cursor=live, windowVersion=version))
                    texts = [block['text'] for frame in records
                             for block in frame['record'].get('blocks', []) if block.get('type') == 'text']
                    self.assertIn(f'Live {index}.', texts)
                    # Validation rehashes the prefix once; the index and the
                    # page read only the append and the newest records.
                    self.assertLess(warm, file_size + 4 * 1024 * 1024)
                    print(f'live_append index={index} seconds={time.monotonic() - started:.3f} '
                          f'bytesRead={warm} coldBytesRead={cold} fileSize={file_size}')

    def run_history(self, provider, count, shape='linear', traverse=False, rewrite=False, interrupt=False):
        with tempfile.TemporaryDirectory(prefix='tessera-synthetic-', dir='/tmp') as directory:
            history = History(Path(directory), provider, count, shape).generate()
            with WindowClient(BINARY, history, timeout=90) as client:
                result = client.exercise(traverse, rewrite, interrupt=interrupt)
            initial_records = count + int(provider in {'pi', 'kimi'})
            if shape == 'undo': initial_records = count - count // 2 + 2
            self.assertEqual(result['initial_pages'], min(3, (initial_records + 99) // 100))
            self.assertLessEqual(result['retained_pages'], 4)

    def test_old_capacity_boundary_is_not_a_conversation_limit(self):
        for provider in ('claude', 'codex', 'pi', 'kimi'):
            for count in (19999, 20000, 20001):
                with self.subTest(provider=provider, canonical_messages=count):
                    self.run_history(provider, count)

    def test_provider_selection_and_bounded_bidirectional_paging(self):
        for provider, shape in [('claude', 'branches'), ('claude', 'revisions'),
                                ('codex', 'revisions'), ('pi', 'branches'), ('kimi', 'undo')]:
            with self.subTest(provider=provider, shape=shape):
                self.run_history(provider, 1200, shape, traverse=True)

    def test_warm_interior_rewrite_followed_by_growth(self):
        for provider in ('claude', 'codex'):
            with self.subTest(provider=provider):
                self.run_history(provider, 1200, rewrite=True)

    def test_codex_history_spans_thirty_two_physical_ancestors(self):
        self.run_history('codex', 1200, 'lineage', traverse=True)

    def test_codex_repeated_settings_ordinal_is_readable(self):
        self.run_history('codex', 250, 'settings', traverse=True)

    def test_codex_fork_cutoffs_stay_aligned_across_repeated_settings_ordinals(self):
        # Codex's counter does not advance for the repeated row, so a child's
        # end_ordinal_exclusive still equals the parent's next ordinal wherever
        # the repeat sits relative to the cutoff. 'middle', 'last' and 'child'
        # fail on a host without the repeat tolerance; 'after' is a control
        # that the cutoff keeps the parent's tail out of the child's read.
        for placement in ('middle', 'last', 'after', 'child'):
            with self.subTest(placement=placement), \
                    tempfile.TemporaryDirectory(prefix='tessera-synthetic-', dir='/tmp') as directory:
                history = History(Path(directory), 'codex', 96, 'lineage', settings_placement=placement).generate()
                with WindowClient(BINARY, history, timeout=90) as client:
                    result = client.exercise(traverse=True)
                self.assertEqual(result['initial_pages'], 1)

    def test_interrupted_read_reconnects_with_fresh_window_ownership(self):
        for provider in ('claude', 'codex', 'pi', 'kimi'):
            with self.subTest(provider=provider):
                self.run_history(provider, 1200, traverse=True, interrupt=True)

    def test_initial_prefetch_stops_at_short_history_boundary(self):
        for provider in ('claude', 'codex', 'pi', 'kimi'):
            for count in (2, 101, 201):
                with self.subTest(provider=provider, count=count):
                    self.run_history(provider, count, traverse=True)


if __name__ == '__main__':
    install_termination_handler()
    unittest.main()
