"""Claude compaction ancestry across every file-backed index strategy.

Synthetic transcripts only; no provider home, private transcript or remote
host is used. The driver runs the real JSONL reader and ClaudeChainIndex:
the default budget keeps the compact index, a 128-byte budget demotes it to
the linear proof or, when the history is not a linear append, the exact lazy
evaluator. Every strategy must publish the same records in the same order.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

DRIVER = str(Path(sys.argv.pop(1)).resolve())
TINY = 128


class Transcript:
    """Claude Code 2.1-shaped rows; returns each row's physical offset."""

    def __init__(self):
        self.rows, self.previous, self.serial = [], None, 0

    def uuid(self):
        self.serial += 1
        return f'00000000-0000-4000-8000-{self.serial:012d}'

    def add(self, row, link=True):
        if link and 'uuid' in row and 'parentUuid' not in row:
            row['parentUuid'] = self.previous
        self.rows.append(row)
        if 'uuid' in row and not row.get('isSidechain'): self.previous = row['uuid']
        return row.get('uuid')

    def turn(self, text):
        user = self.add(dict(type='user', uuid=self.uuid(), isSidechain=False,
                             message=dict(role='user', content=text)))
        self.add(dict(type='assistant', uuid=self.uuid(), isSidechain=False,
                      message=dict(role='assistant', content=[dict(type='text', text='reply ' + text)])))
        self.add(dict(type='progress', uuid=self.uuid(), isSidechain=False, data=dict(type='hook_progress')))
        self.add(dict(type='file-history-snapshot', messageId=user, snapshot={}))
        return user

    def compact(self, logical='previous', summary_first=True):
        """logical: previous, earlier, later, missing or absent."""
        earlier = self.previous
        if logical == 'earlier':
            self.add(dict(type='user', uuid=self.uuid(), isSidechain=False,
                          message=dict(role='user', content='<command-name>/compact</command-name>')))
        boundary_id, later = self.uuid(), self.uuid()
        names = dict(previous=self.previous, earlier=earlier, later=later, missing=self.uuid(), absent=None)
        boundary = dict(type='system', subtype='compact_boundary', uuid=boundary_id, parentUuid=None,
                        isSidechain=False, content='Conversation compacted',
                        compactMetadata=dict(trigger='auto', preTokens=1))
        if names[logical] is not None: boundary['logicalParentUuid'] = names[logical]
        self.add(boundary, link=False); self.previous = boundary_id
        attachment = dict(type='attachment', uuid=later, isSidechain=False,
                          attachment=dict(type='total_tokens_reminder'))
        if not summary_first: self.add(attachment)
        self.add(dict(type='user', uuid=self.uuid(), isSidechain=False, isCompactSummary=True,
                      message=dict(role='user', content='summary')))
        if summary_first: self.add(attachment)

    def write(self, path):
        offsets, position, data = [], 0, []
        for row in self.rows:
            line = (json.dumps(row) + '\n').encode()
            offsets.append(position); position += len(line); data.append(line)
        path.write_bytes(b''.join(data))
        return offsets


def history(shapes, turns=40):
    transcript = Transcript()
    transcript.add(dict(type='permission-mode', permissionMode='default'))
    for shape in shapes:
        for index in range(turns): transcript.turn(f'{shape} {index}')
        transcript.compact(*shape) if isinstance(shape, tuple) else transcript.compact(shape)
    for index in range(turns): transcript.turn(f'tail {index}')
    transcript.add(dict(type='last-prompt', lastPrompt='tail'))
    return transcript


class CompactionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='tessera-claude-compaction-')
        self.path = Path(self.directory.name) / 'session.jsonl'

    def tearDown(self): self.directory.cleanup()

    def run_driver(self, budget=None):
        command = [DRIVER, str(self.path)] + ([str(budget)] if budget else [])
        result = subprocess.run(command, capture_output=True, text=True, timeout=120)
        reply = json.loads(result.stdout)
        self.assertNotIn('error', reply, reply)
        self.assertEqual(result.returncode, 0)
        return reply

    def modes(self, transcript, tiny_mode):
        offsets = transcript.write(self.path)
        compact, tiny = self.run_driver(), self.run_driver(TINY)
        self.assertEqual(compact['mode'], 'compact')
        self.assertEqual(tiny['mode'], tiny_mode)
        # Identical ordinals, physical records and authored messages.
        self.assertEqual(tiny['selectedStarts'], compact['selectedStarts'])
        self.assertEqual(tiny['ids'], compact['ids'])
        self.assertEqual(tiny['count'], compact['count'])
        return compact, offsets

    def expect_complete(self, transcript, reply, offsets, excluded=()):
        # Pre-compaction history is selected, in physical order, down to the
        # first authored message; only the stale excluded branch is omitted.
        excluded = set(excluded)
        expected = [offset for row, offset in zip(transcript.rows, offsets)
                    if offset not in excluded and (row['type'] in ('user', 'assistant', 'progress', 'system', 'attachment')
                                                   or 'uuid' not in row)]
        self.assertEqual([int(value) for value in reply['selectedStarts']], expected)
        first = next(offset for row, offset in zip(transcript.rows, offsets) if row['type'] == 'user')
        self.assertEqual(int(reply['sourceOffsets'][0]), first)

    def test_linear_compactions_stay_linear_and_select_prior_history(self):
        # Measured shapes: logical parent is the previous node, a later
        # total_tokens_reminder attachment, a missing UUID, or absent.
        transcript = history(['previous', ('later', False), 'missing', 'absent'])
        reply, offsets = self.modes(transcript, 'linear')
        self.expect_complete(transcript, reply, offsets)
        boundaries = [offset for row, offset in zip(transcript.rows, offsets) if row.get('subtype') == 'compact_boundary']
        self.assertEqual(len(boundaries), 4)
        self.assertTrue(set(boundaries) <= {int(value) for value in reply['selectedStarts']})

    def test_nonlinear_history_uses_exact_lazy_path_with_same_selection(self):
        linear = history(['previous', 'later'])
        reference, _ = self.modes(linear, 'linear')
        # A trailing sidechain record breaks the linear proof but is not
        # selected: the exact lazy evaluator must publish the same records.
        linear.add(dict(type='user', uuid=linear.uuid(), parentUuid=linear.rows[2]['uuid'], isSidechain=True,
                        message=dict(role='user', content='aside')), link=False)
        branched, _ = self.modes(linear, 'lazy')
        self.assertEqual(branched['selectedStarts'], reference['selectedStarts'])

    def test_earlier_logical_parent_drops_only_the_compact_command_branch(self):
        transcript = history(['earlier', 'previous'])
        reply, offsets = self.modes(transcript, 'lazy')
        command = [offset for row, offset in zip(transcript.rows, offsets)
                   if isinstance(row.get('message', {}).get('content'), str) and row['message']['content'].startswith('<command-name>')]
        self.assertEqual(len(command), 1)
        self.expect_complete(transcript, reply, offsets, excluded=command)

    def test_sidechain_before_boundary_is_not_the_positional_parent(self):
        transcript = Transcript()
        for index in range(30): transcript.turn(f'before {index}')
        main = transcript.previous
        for _ in range(3):
            transcript.add(dict(type='progress', uuid=transcript.uuid(), parentUuid=main, isSidechain=True,
                                data=dict(type='agent_progress')), link=False)
        transcript.compact('missing')
        for index in range(30): transcript.turn(f'after {index}')
        reply, offsets = self.modes(transcript, 'lazy')
        sidechain = [offset for row, offset in zip(transcript.rows, offsets) if row.get('isSidechain')]
        self.expect_complete(transcript, reply, offsets, excluded=sidechain)

    def test_forward_parent_below_boundary_stops_the_path_instead_of_failing(self):
        # A row before the boundary that names a post-compaction parent would
        # lead the display path back onto itself. The path stops at that row
        # (older history is omitted) rather than making the file unreadable.
        transcript = Transcript()
        for index in range(20): transcript.turn(f'before {index}')
        stray = dict(type='progress', uuid=transcript.uuid(), isSidechain=False, data=dict(type='hook_progress'))
        transcript.add(stray, link=False)
        transcript.compact('absent')
        stray['parentUuid'] = next(row['uuid'] for row in transcript.rows if row.get('isCompactSummary'))
        for index in range(20): transcript.turn(f'after {index}')
        reply, offsets = self.modes(transcript, 'lazy')
        start = offsets[transcript.rows.index(stray)]
        expected = [offset for row, offset in zip(transcript.rows, offsets) if 'uuid' not in row or offset >= start]
        self.assertEqual([int(value) for value in reply['selectedStarts']], expected)


if __name__ == '__main__': unittest.main()
