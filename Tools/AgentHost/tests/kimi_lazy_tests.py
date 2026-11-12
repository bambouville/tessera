"""Public synthetic long-history and forced-lazy replay equivalence regressions."""
import json
import pathlib
import random
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


def random_history(seed, count):
    # Prompts, replies, steps with tool calls, undos, compactions and owned
    # injections in a seeded mix.
    r = random.Random(seed)
    rows, step, calls, n, prompt = [], None, [], 0, 0
    while len(rows) < count:
        k = r.random()
        if step is None:
            if k < 0.35: rows.append(message('u%d' % n, id='p%d' % prompt)); prompt += 1
            elif k < 0.45: rows.append(message('a%d' % n, 'assistant'))
            elif k < 0.6: step = 's%d' % n; rows.append(loop('step.begin', uuid=step)); calls = []
            elif k < 0.64: rows.append(dict(type='context.undo', count=r.randint(1, 4)))
            elif k < 0.66: rows.append(dict(type='context.apply_compaction', summary='x'))
            elif k < 0.70: rows.append(message('inj', origin=dict(kind='injection', ownerPromptId='p%d' % r.randint(0, max(prompt, 1)))))
            else: rows.append(message('u%d' % n))
        else:
            if k < 0.25: rows.append(loop('content.part', stepUuid=step, part=dict(type='text', text=r.choice(['t', ' ']))))
            elif k < 0.45: calls.append('c%d' % n); rows.append(loop('tool.call', stepUuid=step, toolCallId=calls[-1], name='Read'))
            elif k < 0.6 and calls: rows.append(loop('tool.result', toolCallId=calls.pop(r.randrange(len(calls))), result=dict(output='o')))
            elif k < 0.68: rows.append(message('deferred%d' % n))
            elif k < 0.78: rows.append(loop('step.end', uuid=step, finishReason=r.choice(['stop', 'interrupted', 'error']))); step = None
            elif k < 0.82: step = 's%d' % n; rows.append(loop('step.begin', uuid=step)); calls = []
            elif k < 0.84: rows.append(dict(type='context.undo', count=r.randint(1, 3))); step = None
            else: rows.append(message('u%d' % n))
        n += 1
    return rows


class KimiLazyTests(unittest.TestCase):
    def replay(self, records, budget=128 * 1024 * 1024, *window):
        with tempfile.TemporaryDirectory(prefix='tessera-kimi-lazy-') as directory:
            path = pathlib.Path(directory) / 'wire.jsonl'
            path.write_text(''.join(json.dumps(row) + '\n' for row in [dict(type='metadata', protocol_version='1.5'), *records]))
            result = subprocess.run([DRIVER, str(path), str(budget), *map(str, window)], text=True, capture_output=True, timeout=120)
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

    def test_newer_pages_resume_the_replay_near_them(self):
        # Paging oldest first under a lazy index resumes the newest-first
        # replay at a slice boundary it passed, not at the newest record:
        # each page costs about what the newest does, one slice's replay.
        records = [message(str(i)) for i in range(6000)]
        records += [dict(type='context.undo', count=2), message('after undo')]
        budget = 131072
        every = self.replay(records, budget)
        count = every['count']
        built, newest = self.replay(records, budget, count, 0), self.replay(records, budget, 'tail', 100)
        first = self.replay(records, budget, 0, 100)
        self.assertEqual(every['selected'], self.replay(records)['selected'])
        self.assertEqual(first['selected'], every['selected'][:100])
        self.assertLessEqual(every['indexBytes'], budget)
        pages, page = (count + 99) // 100, newest['bytesRead'] - built['bytesRead']
        paging = every['bytesRead'] - built['bytesRead']
        self.assertLess(paging, 2 * pages * page, (paging, pages, page))

    def test_a_page_inside_an_interrupted_read_replays_instead_of_reading_its_half(self):
        # A newest-page read cancelled partway leaves its window half built;
        # a smaller page inside it must not be served from that half.
        result = self.replay(random_history(1, 1499), 16384, 'interrupt', 10)
        self.assertGreater(result['interrupted'], 0, result)
        self.assertEqual(result['mismatches'], 0, result)

    def test_a_smaller_budget_keeps_the_replay_checkpoints_that_fit(self):
        # Another index opening shrinks this one's budget below what it holds:
        # the checkpoints thin to fit instead of going, so a page deep in the
        # history does not replay from the newest record again.
        records = [message(str(i)) for i in range(6000)]
        budget, smaller = 131072, 49152
        every = self.replay(records, budget, 'shrink', smaller)
        count = every['count']
        first = count // 4
        self.assertEqual(every['shrunkPage'], every['selected'][first:first + 100])
        self.assertLessEqual(every['refreshedBytes'], smaller)
        self.assertLessEqual(every['indexBytes'], smaller)
        built, fresh = self.replay(records, smaller, count, 0), self.replay(records, smaller, first, 100)
        replay = fresh['bytesRead'] - built['bytesRead']
        self.assertLess(every['shrunkPageBytes'], replay // 2, (every['shrunkPageBytes'], replay))

    def test_a_batch_that_grows_after_dropping_a_row_keeps_every_row(self):
        # The slice batch's capacity follows the index's other memory, which
        # changes from record to record within a pass.
        for seed, budget in ((3, 6000), (3, 6472), (3, 6500), (5, 6475)):
            records = random_history(seed, 3000)
            cached = self.replay(records)
            lazy = self.replay(records, budget, 0, 100)
            self.assertEqual(lazy['selected'], cached['selected'][:100], (seed, budget))

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
