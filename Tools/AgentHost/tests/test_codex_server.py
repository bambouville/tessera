"""Read-only App Server transport contract, using an owned synthetic child."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())
MOCK = '''#!/usr/bin/env python3
import json, os, sys
assert os.environ.get('CODEX_INTERNAL_APP_SERVER_REMOTE_CONTROL_DISABLED') == '1'
if '--version' in sys.argv:
    print('codex-cli 0.154.0'); raise SystemExit(0)
ready = False
for raw in sys.stdin:
    value = json.loads(raw)
    method = value['method']
    with open(os.environ['MOCK_LOG'], 'a') as log: log.write(method + '\\n')
    if method == 'initialized':
        ready = True
        continue
    if method == 'initialize': result = {'userAgent': 'synthetic'}
    elif not ready:
        raise SystemExit(3)
    elif method == 'thread/list':
        assert value['params']['useStateDbOnly'] is True
        result = {'data': [{'id': 'synthetic'}]}
    elif method == 'thread/items/list':
        assert value['params']['sortDirection'] == 'desc'
        assert value['params']['limit'] <= 100
        mode = os.environ.get('MOCK_MODE', '')
        if mode == 'unsupported':
            print(json.dumps({'id': value['id'], 'error': {'code': -32601, 'message': 'unsupported'}}), flush=True)
            continue
        if mode == 'serverRequest':
            print(json.dumps({'id': 123, 'method': 'item/tool/call', 'params': {}}), flush=True)
            continue
        if mode == 'oversized':
            result = {'data': [{'turnId': 'turn', 'item': {'id': 'item', 'type': 'agentMessage', 'text': 'x' * 2000000}}]}
        elif mode == 'budget':
            result = {'data': [], 'padding': 'x' * 18000000}
        else:
            result = {'data': [{'turnId': 'turn', 'item': {'id': 'item', 'type': 'agentMessage', 'text': 'private synthetic'}}],
                      'nextCursor': 'older', 'backwardsCursor': 'live'}
    else: raise SystemExit(4)
    notification = json.dumps({'method': 'test/notification', 'params': {}}) + '\\n'
    payload = (notification + json.dumps({'id': value['id'], 'result': result}) + '\\n').encode()
    for offset in range(0, len(payload), 257):
        sys.stdout.buffer.write(payload[offset:offset+257]); sys.stdout.buffer.flush()
'''


class CodexServerTests(unittest.TestCase):
    def test_unsafe_path_candidates_never_execute(self):
        for kind in ('script', 'relative', 'empty', 'directory'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(prefix='tcs-security-') as directory:
                root = Path(directory)
                candidate = root / 'codex'
                marker = root / 'executed'
                candidate.write_text('#!/bin/sh\ntouch ' + str(marker) + '\n')
                candidate.chmod(0o700)
                if kind == 'directory':
                    candidate.unlink(); candidate.mkdir()
                path = '.' if kind == 'relative' else '' if kind == 'empty' else str(root)
                result = subprocess.run([BINARY, 'codex-probe'], cwd=root,
                    env=dict(os.environ, PATH=path), capture_output=True, timeout=5)
                self.assertFalse(marker.exists())
                self.assertEqual(result.returncode, 65)
                self.assertIn(json.loads(result.stdout)['error'], ('codexUnsafeExecutable', 'codexUnavailable'))

    def test_the_owners_native_binary_is_accepted_whatever_its_mode(self):
        # npm-style installs leave group- or world-writable files and parents
        # under the owner's home; the owner decides their modes. Only the
        # ownership, symlink and native-binary gates remain.
        with tempfile.TemporaryDirectory(prefix='tcs-mode-') as directory:
            root = Path(directory)
            candidate = root / 'codex'
            shutil.copyfile('/usr/bin/true', candidate)
            candidate.chmod(0o777); root.chmod(0o777)
            result = subprocess.run([BINARY, 'codex-probe'], cwd=root, env=dict(os.environ, PATH=str(root)),
                capture_output=True, timeout=5)
            self.assertNotEqual(json.loads(result.stdout).get('error'), 'codexUnsafeExecutable', result.stdout)
            self.assertNotEqual(json.loads(result.stdout).get('error'), 'codexUnavailable', result.stdout)

    def probe(self, mode=''):
        with tempfile.TemporaryDirectory(prefix='tcs-') as directory:
            root = Path(directory)
            executable = root / 'codex'
            mock = root / 'mock.py'; mock.write_text(MOCK)
            launcher = root / 'launcher.c'
            launcher.write_text('#include <unistd.h>\nint main(int argc,char**argv){char*args[32]={' + json.dumps(sys.executable) + ',' + json.dumps(str(mock)) + '};for(int i=1;i<argc&&i<30;i++)args[i+1]=argv[i];execv(args[0],args);return 127;}')
            subprocess.run(['cc',str(launcher),'-o',str(executable)],check=True,capture_output=True)
            executable.chmod(0o700)
            log = root / 'methods'
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'], MOCK_LOG=str(log), MOCK_MODE=mode)
            result = subprocess.run([BINARY, 'codex-probe'], capture_output=True, timeout=12, env=environment)
            self.assertEqual(result.stderr, b'')
            self.assertNotIn(b'private synthetic', result.stdout)
            methods = log.read_text().splitlines()
            self.assertEqual(methods, ['initialize', 'initialized', 'thread/list', 'thread/items/list'])
            return result.returncode, json.loads(result.stdout)

    def test_initializes_once_and_uses_only_read_methods(self):
        code, result = self.probe()
        self.assertEqual(code, 0)
        self.assertEqual(result['itemTypes'], {'agentMessage': 1})
        self.assertTrue(result['hasOlder'])
        self.assertTrue(result['hasLiveAnchor'])

    def test_unsupported_pagination_is_explicit(self):
        code, result = self.probe('unsupported')
        self.assertEqual(code, 65)
        self.assertEqual(result['error'], 'codexPaginationUnavailable')

    def test_server_tool_request_is_never_executed(self):
        code, result = self.probe('serverRequest')
        self.assertEqual(code, 65)
        self.assertEqual(result['error'], 'codexUnexpectedServerRequest')

    def test_oversized_string_is_streamed_with_bounded_retention(self):
        code, result = self.probe('oversized')
        self.assertEqual(code, 0)
        self.assertEqual(result['items'], 1)

    def test_response_work_budget_stops_child(self):
        code, result = self.probe('budget')
        self.assertEqual(code, 65)
        self.assertEqual(result['error'], 'codexResponseBudgetExceeded')


if __name__ == '__main__': unittest.main()
