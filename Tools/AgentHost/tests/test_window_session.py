"""WindowSession revision slices under the service budget. Synthetic only."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest

DRIVER = str(Path(sys.argv.pop(1)).resolve())
SESSION = '00000000-0000-0000-0000-000000000001'
# PageWindow.h: one page, the history growth budget and the refresh ceiling.
PAGE = 256 * 1024
REFRESH = 64 * 1024 * 1024 + 2 * 24 * PAGE


class WindowSessionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='tessera-window-session-')
        self.root = Path(self.directory.name).resolve()
        self.path = self.root / 'codex/sessions' / ('rollout-' + SESSION + '.jsonl')
        self.path.parent.mkdir(parents=True)
        self.rows = [dict(ordinal=0, type='session_meta', payload=dict(id=SESSION, history_mode='paginated'))]
        for index in range(60): self.append(index, f'original {index}')
        self.flush()
        executable = self.root / 'bin/codex'; executable.parent.mkdir()
        executable.write_text('#!/bin/sh\nprintf "codex-cli 0.0.0\\n"\n'); executable.chmod(0o700)
        environment = dict(os.environ, CODEX_HOME=str(self.root / 'codex'), CLAUDE_CONFIG_DIR=str(self.root / 'claude'),
                           PI_CODING_AGENT_DIR=str(self.root / 'pi'), PATH=str(executable.parent))
        self.process = subprocess.Popen([DRIVER, 'codex', str(self.path)], env=environment, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def tearDown(self):
        self.process.stdin.close()
        try: self.process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait(timeout=4)
        self.process.stdout.close(); self.process.stderr.close()
        self.directory.cleanup()

    def append(self, index, text):
        self.rows.append(dict(ordinal=len(self.rows), type='event_msg', payload=dict(type='item_completed', thread_id=SESSION,
            turn_id=f'turn-{index}', item=dict(type='AgentMessage', id=f'r{index}', content=[dict(type='Text', text=text)]))))

    def flush(self):
        self.path.write_text(''.join(json.dumps(row) + '\n' for row in self.rows))

    def request(self, expected_error=None, **request):
        self.process.stdin.write(json.dumps(request) + '\n'); self.process.stdin.flush()
        self.assertTrue(select.select([self.process.stdout], [], [], 10)[0], 'driver deadline')
        line = self.process.stdout.readline()
        self.assertTrue(line, 'driver disconnected')
        reply = json.loads(line)
        if expected_error: self.assertEqual(reply.get('error'), expected_error, reply)
        else: self.assertNotIn('error', reply, reply)
        return reply

    def revise(self, size=5000):
        page = self.request(op='bootstrap', serviceBytes=0)
        self.assertEqual([row['id'] for row in page['records']], [f'r{index}' for index in range(60)])
        self.request(op='ack')
        revised = {f'r{index}': 'revised ' + str(index) + ' ' + 'v' * size for index in range(10, 40)}
        for index in range(10, 40): self.append(index, revised[f'r{index}'])
        self.flush()
        return revised

    def sweep(self, serviceBytes):
        slices = []
        for _ in range(8):
            reply = self.request(op='head', serviceBytes=serviceBytes)
            self.assertEqual(reply['lane'], 'revisions')
            self.request(op='ack')
            slices.append(reply)
            if not reply['hasNewer']: return slices
        self.fail('revision sweep did not finish')

    def assertDeliveredOnce(self, slices, revised):
        delivered = [row['id'] for reply in slices for row in reply['records']]
        self.assertEqual(sorted(delivered), sorted(revised))
        for reply in slices:
            for row in reply['records']:
                # Normalization may cap very long display text.
                text = row['body']['blocks'][0]['text']
                self.assertGreater(len(text), 4000); self.assertTrue(revised[row['id']].startswith(text))

    def test_revision_sweep_defers_patches_that_do_not_fit_the_service_room(self):
        revised = self.revise()
        # Other windows leave this refresh exactly one page of room.
        slices = self.sweep(REFRESH - PAGE)
        self.assertGreater(len(slices), 1)
        self.assertTrue(slices[0]['hasNewer'])
        self.assertTrue(0 < len(slices[0]['records']) < len(revised))
        self.assertDeliveredOnce(slices, revised)
        # A finished sweep repeats nothing.
        self.assertEqual(self.sweep(REFRESH - PAGE)[0]['records'], [])

    def test_deferred_patches_resume_before_a_full_slice_boundary(self):
        # Larger patches also fill the slice's frame bound, so the sweep
        # position is past the deferred patches and must be rewound.
        revised = self.revise(9000)
        slices = self.sweep(REFRESH - PAGE)
        self.assertGreater(len(slices), 2)
        self.assertDeliveredOnce(slices, revised)
        self.assertEqual(self.sweep(REFRESH - PAGE)[0]['records'], [])

    def test_revision_sweep_with_room_delivers_every_patch_in_one_slice(self):
        revised = self.revise()
        slices = self.sweep(0)
        self.assertEqual(len(slices), 1)
        self.assertDeliveredOnce(slices, revised)

    def test_refresh_without_one_page_of_room_is_refused_and_recoverable(self):
        revised = self.revise()
        footprint = self.request(op='head', serviceBytes=REFRESH - PAGE + 1, expected_error='windowCapacity')['footprint']
        self.assertEqual(self.request(op='head', serviceBytes=REFRESH, expected_error='windowCapacity')['footprint'], footprint)
        self.assertDeliveredOnce(self.sweep(0), revised)

    def settings_row(self, ordinal):
        # Codex's recorder writes thread_settings_applied with the preceding
        # row's ordinal (observed in cli 0.153 rollouts); the counter then continues.
        # The settings shape is codex-cli 0.156's, which every resume appends.
        return dict(ordinal=ordinal, type='event_msg', payload=dict(type='thread_settings_applied', thread_id=SESSION,
            thread_settings=dict(model='gpt-5', model_provider_id='openai', service_tier='default', approval_policy='on-request',
                            approvals_reviewer='user', permission_profile=dict(type='workspace-write'),
                            active_permission_profile=dict(id='default'), cwd='/synthetic', reasoning_effort='high',
                            collaboration_mode=dict(mode='default', settings=dict()),
                            runtime_workspace_roots=['/synthetic'], disabled_plugin_ids=[])))

    def insert_settings(self, after, ordinal):
        position = after + 1  # rows[0] is session_meta; message index i is rows[i + 1]
        self.rows.insert(position + 1, self.settings_row(ordinal))
        self.flush()

    def test_repeated_ordinal_on_a_settings_row_keeps_the_conversation_readable(self):
        self.insert_settings(after=29, ordinal=30)
        page = self.request(op='bootstrap', serviceBytes=0)
        self.assertEqual([row['id'] for row in page['records']], [f'r{index}' for index in range(60)])
        self.request(op='ack')
        # Growth after the repeat continues from the repeated value, as Codex's own counter does.
        self.rows.append(dict(ordinal=61, type='event_msg', payload=dict(type='item_completed', thread_id=SESSION,
            turn_id='turn-60', item=dict(type='AgentMessage', id='r60', content=[dict(type='Text', text='appended 60')]))))
        self.flush()
        page = self.request(op='bootstrap', serviceBytes=0)
        self.assertEqual([row['id'] for row in page['records']], [f'r{index}' for index in range(61)])

    def test_ordinal_gaps_and_decreases_remain_discontinuities(self):
        # 32: a gap; 29: one below the repeated value; 3: a decrease.
        for ordinal in (32, 29, 3):
            with self.subTest(ordinal=ordinal):
                self.insert_settings(after=29, ordinal=ordinal)
                self.request(op='bootstrap', serviceBytes=0, expected_error='codexOrdinalDiscontinuity')
                del self.rows[31]
        self.flush()
        page = self.request(op='bootstrap', serviceBytes=0)
        self.assertEqual(len(page['records']), 60)

    def test_repeated_ordinal_on_an_item_row_fails_closed(self):
        # A repeated item ordinal would defeat the lazy index's ordinal-based
        # revision bookkeeping (ordinal == updatedOrdinal reads as unrevised).
        def item(ordinal, index, text):
            return dict(ordinal=ordinal, type='event_msg', payload=dict(type='item_completed', thread_id=SESSION,
                turn_id=f'turn-{index}', item=dict(type='AgentMessage', id=f'r{index}', content=[dict(type='Text', text=text)])))
        for row in (item(30, 29, 'revised 29'), item(30, 60, 'new 60')):
            with self.subTest(item=row['payload']['item']['id']):
                self.rows.insert(31, row); self.flush()
                self.request(op='bootstrap', serviceBytes=0, expected_error='codexOrdinalDiscontinuity')
                del self.rows[31]

    def test_repeated_ordinal_right_after_session_meta_is_tolerated(self):
        self.rows.insert(1, self.settings_row(0)); self.flush()
        page = self.request(op='bootstrap', serviceBytes=0)
        self.assertEqual([row['id'] for row in page['records']], [f'r{index}' for index in range(60)])


if __name__ == '__main__':
    unittest.main()
