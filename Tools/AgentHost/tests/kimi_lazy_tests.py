"""Public synthetic long-history and forced-lazy replay equivalence regressions."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

DRIVER = sys.argv.pop(1)


def message(text, role='user', origin=None, id=None):
    value = dict(role=role, content=[dict(type='text', text=text)])
    if origin: value['origin'] = origin
    if id: value['id'] = id
    return dict(type='context.append_message', message=value)


def loop(kind, **kwargs):
    return dict(type='context.append_loop_event', event=dict(type=kind, **kwargs))


class KimiLazyTests(unittest.TestCase):
    def replay(self, records, budget=128 * 1024 * 1024):
        with tempfile.TemporaryDirectory(prefix='tessera-kimi-lazy-') as directory:
            path = pathlib.Path(directory) / 'wire.jsonl'
            path.write_text(''.join(json.dumps(row) + '\n' for row in [dict(type='metadata', protocol_version='1.5'), *records]))
            result = subprocess.run([DRIVER, str(path), str(budget)], text=True, capture_output=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(result.stdout)

    def test_more_than_twenty_thousand_records_and_deep_undo(self):
        records = [message(str(i)) for i in range(25003)]
        records += [dict(type='context.undo', count=25001), message('survivor')]
        result = self.replay(records)
        self.assertEqual(len(result['selected']), 5)  # header, first two prompts, undo fact, new prompt

    def test_uint64_undo_is_a_count_not_an_admission_limit(self):
        result = self.replay([message('removed'), message('also removed'),
            dict(type='context.undo', count=18446744073709551615), message('new')])
        self.assertEqual(result['count'], 3)  # header, undo fact, new prompt

    def test_many_pending_calls_and_deferred_messages_match_across_windows(self):
        records = [loop('step.begin', uuid='s')]
        for i in range(90):
            records += [loop('tool.call', stepUuid='s', toolCallId=str(i), name='Read'), message('deferred ' + str(i))]
        records += [loop('content.part', stepUuid='s', part=dict(type='text', text='late content')),
            loop('step.end', uuid='s', finishReason='interrupted'), loop('step.begin', uuid='next'),
            dict(type='context.undo', count=75)]
        cached, lazy = self.replay(records), self.replay(records, 16384)
        self.assertEqual(lazy['selected'], cached['selected'])
        self.assertLessEqual(lazy['indexBytes'], 16384)

    def test_tiny_budget_matches_cached_compaction_undo_and_tool_order(self):
        records = [message(str(i)) for i in range(600)]
        records += [dict(type='context.apply_compaction', summary='retained'),
            loop('step.begin', uuid='s'), loop('content.part', stepUuid='s', part=dict(type='text', text='A')),
            loop('tool.call', stepUuid='s', toolCallId='z', name='Read'),
            message('deferred'), loop('tool.call', stepUuid='s', toolCallId='a', name='Read'),
            loop('tool.result', toolCallId='z', result=dict(output='Z')),
            loop('content.part', stepUuid='s', part=dict(type='text', text='B')),
            loop('step.end', uuid='s', finishReason='interrupted'), loop('step.begin', uuid='next'),
            loop('content.part', stepUuid='next', part=dict(type='text', text=' ')),
            loop('step.end', uuid='next'),
            message('owned context', origin=dict(kind='injection', ownerPromptId='prompt')),
            dict(type='future.fact'), message('remove', id='prompt'), message('remove reply', 'assistant'),
            dict(type='context.undo', count=1), message('retained after undo')]
        cached = self.replay(records)
        lazy = self.replay(records, 16384)
        self.assertEqual(lazy['selected'], cached['selected'])
        self.assertLessEqual(lazy['indexBytes'], 16384)


if __name__ == '__main__':
    unittest.main()
