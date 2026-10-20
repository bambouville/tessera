import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest

BINARY = sys.argv.pop(1)


class ReplayTests(unittest.TestCase):
    def replay(self, provider, rows, expected):
        with tempfile.TemporaryDirectory(prefix='tessera-replay-unit-') as temporary:
            path = Path(temporary) / 'prefix.jsonl'; path.touch()
            with subprocess.Popen([BINARY, provider, str(path)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0) as worker:
                try:
                    def check(count=None):
                        worker.stdin.write(b'refresh\n')
                        self.assertTrue(select.select([worker.stdout], [], [], 5)[0])
                        value = json.loads(worker.stdout.readline())
                        self.assertTrue(value.get('matched'), value)
                        if count is not None: self.assertEqual(value['records'], count)
                    check(0)
                    for row, count in zip(rows, expected):
                        raw = (json.dumps(row) + '\n').encode()
                        with path.open('ab', buffering=0) as output:
                            output.write(raw[:len(raw)//2]); check()
                            output.write(raw[len(raw)//2:]); check(count)
                    check(expected[-1])
                    # Truncation/replacement must rebuild, never retain an old
                    # canonical tail just because its IDs look familiar.
                    path.write_bytes(b''); check(0)
                    worker.stdin.close(); self.assertEqual(worker.wait(timeout=5), 0)
                finally:
                    if worker.poll() is None: worker.kill(); worker.wait(timeout=5)

    def test_codex_revision_ordinals_and_partial_lines(self):
        def item(ordinal, identity):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed',
                thread_id='thread', turn_id='turn', item=dict(type='AgentMessage', id=identity,
                content=[dict(type='Text', text=str(ordinal))])))
        self.replay('codex', [dict(ordinal=0, type='session_meta', payload=dict(id='thread', history_mode='paginated')),
            item(1, 'a'), item(2, 'b'), item(3, 'a')], [0, 1, 2, 2])

    def test_claude_branch_and_rewritten_terminal(self):
        def item(identity, parent, text):
            return dict(type='assistant', uuid=identity, parentUuid=parent,
                        message=dict(role='assistant', content=[dict(type='text', text=text)]))
        self.replay('claude', [item('a', None, 'root'), item('b', 'a', 'first'),
            item('c', 'a', 'branch'), item('c', 'a', 'revised')], [1, 2, 2, 2])


if __name__ == '__main__': unittest.main()
