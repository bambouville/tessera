"""Same-input parity: native host reader against the embedded Tier C projector.

Usage: test_projector_parity.py <tessera-agent-host>

Synthetic records only. Each shape is written once and read by both
implementations, so a divergence in either one fails here even when their
separate shape tests still pass.
"""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())
REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts/performance/agent-center'))
from normalization_corpus import compare, projector  # noqa: E402

INSTALLER = REPO / 'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift'


def field(number, payload):
    def varint(value):
        data = bytearray()
        while value >= 128:
            data.append((value & 127) | 128)
            value >>= 7
        data.append(value)
        return bytes(data)
    return varint(number * 8 + 2) + varint(len(payload)) + payload


def signature(kind):
    return base64.b64encode(field(2, field(1, field(8, kind.encode())))).decode()


def assistant(uuid, content):
    return dict(type='assistant', uuid=uuid, message=dict(role='assistant', content=content))


def queued(uuid, prompt, **attachment):
    return dict(type='attachment', uuid=uuid, attachment=dict(type='queued_command', prompt=prompt, **attachment))


def tool(index):
    return dict(type='tool_use', id=f't{index}', name='Read', input=dict(path=f'/tmp/{index}'))


class ProjectorParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='tessera-parity-')
        swift = INSTALLER.read_text()
        marker = 'public static let projectorScript = #"""'
        start = swift.index(marker) + len(marker)
        script = Path(cls.temporary.name) / 'projector.sh'
        script.write_text(swift[start:swift.index('"""#', start)].lstrip('\n'))
        cls.reference = staticmethod(projector(script)[0]['normalized'])

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def both(self, provider, values):
        path = Path(self.temporary.name) / f'{provider}.jsonl'
        lines = [json.dumps(value, ensure_ascii=False) for value in values]
        path.write_text(''.join(line + '\n' for line in lines))
        process = subprocess.run([BINARY, 'jsonl', '--provider', provider, '--path', str(path), '--limit', '100'],
                                 capture_output=True, timeout=10)
        self.assertEqual(process.returncode, 0, process.stderr)
        rows = json.loads(process.stdout)['records']
        self.assertEqual(len(rows), len(lines))
        return [(self.reference(provider, line.encode(), False), row['record']) for line, row in zip(lines, rows)]

    def assertSame(self, reference, native, message=None):
        self.assertEqual(reference.get('type'), native.get('type'), message)
        self.assertIn(compare(reference, native), {'exact_visible_payload', 'metadata_not_compared'}, message)
        self.assertEqual(bool(reference.get('truncated')), bool(native.get('truncated')), message)

    def test_claude_narration_and_queued_prompts_project_identically(self):
        values = [
            assistant('a1', [dict(type='thinking', thinking='Checking the log.', signature=signature('narration')),
                             dict(type='thinking', thinking='', signature=signature('reasoning')), tool(0)]),
            assistant('a2', [dict(type='thinking', thinking='  \n', signature=signature('narration')), tool(1)]),
            queued('q1', 'typed while running', commandMode='prompt', origin=dict(kind='human')),
            queued('q2', [dict(type='text', text='with an image'), dict(type='image', source=dict(type='base64'))]),
            queued('q3', 'older Claude builds omit mode and origin'),
            queued('q4', [dict(type=['future'], text='bad')]),
            queued('n1', '<task-notification>done</task-notification>', commandMode='task-notification'),
            queued('p1', 'from a peer', origin=dict(kind='peer')),
            queued('m1', 'forwarded', isMeta=True, origin=dict(kind='unclassified')),
        ]
        rows = self.both('claude', values)
        for value, (reference, native) in zip(values, rows):
            self.assertSame(reference, native, value['uuid'])
        self.assertEqual([row[1]['type'] for row in rows[-3:]], ['system'] * 3)
        self.assertEqual(rows[5][1]['blocks'][0]['text'], 'bad')

    def test_evicted_blocks_mark_both_records_truncated(self):
        content = [tool(index) for index in range(70)] + [dict(type='text', text='prose after a tool batch')]
        values = [assistant('a1', content), queued('q1', [dict(type='image')] * 70 + [dict(type='text', text='late')])]
        for (reference, native), value in zip(self.both('claude', values), values):
            self.assertSame(reference, native, value['uuid'])
            self.assertTrue(native['truncated'])
            self.assertEqual(native['blocks'][-1]['type'], 'text')

    def test_codex_input_fragments_join_identically(self):
        values = [dict(type='response_item', payload=dict(type='message', role='user', content=[
            dict(type='input_text', text='Hel'), dict(type='input_text', text='lo'),
            dict(type='input_image', image_url='tessera:image'), dict(type='input_text', text=' again')]))]
        (reference, native), = self.both('codex', values)
        self.assertSame(reference, native)
        self.assertEqual([block.get('text') for block in native['blocks']], ['Hello', None, ' again'])


if __name__ == '__main__':
    unittest.main()
