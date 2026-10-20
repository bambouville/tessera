"""Portable installer tests. Every execution substitutes a disposable home.

No SSH, real user installation, credentials, or provider settings are touched.
"""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[3] / 'Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentHostDeployment.swift'
PROGRAM = SOURCE.read_text().split('public static let program = #"""\n', 1)[1].split('\n"""#', 1)[0]
PAYLOAD = b'#!/bin/sh\nprintf "tessera-agent-host 0.1.0\\n"\n'
# The app stamps every request with its integration version; activation refuses
# to replace a host whose lifecycle hook records a newer one.
INSTALLER = SOURCE.with_name('RemoteAgentLifecycleIntegrationInstaller.swift')
INTEGRATION = int(re.search(r'public static let integrationVersion = (\d+)', INSTALLER.read_text()).group(1))


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tessera-artifact-test-')
        self.home = Path(self.temporary.name).resolve()
        real_home = 'home=pwd.getpwuid(os.geteuid()).pw_dir'
        # Without the substitution every request would act on the real home.
        self.assertEqual(PROGRAM.count(real_home), 1)
        self.program = PROGRAM.replace(real_home, 'home=' + repr(str(self.home)))
        self.digest = hashlib.sha256(PAYLOAD).hexdigest()
        self.upload = 'a' * 32

    def tearDown(self):
        self.temporary.cleanup()

    def run_request(self, operation, *, good=True, error=None, **fields):
        request = dict(operation=operation, upload=self.upload, sha256=self.digest, bytes=len(PAYLOAD),
                       integration=INTEGRATION)
        request.update(fields)
        request = {key: value for key, value in request.items() if value is not None}
        result = subprocess.run([sys.executable, '-c', self.program], input=base64.b64encode(json.dumps(request).encode()),
                                capture_output=True, timeout=6)
        if good:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        if error: self.assertIn(error.encode(), result.stderr, result.stderr.decode())
        return result

    def write_hook(self, version):
        hook = self.home / '.config/tessera/agent-lifecycle-hook.sh'
        hook.write_text(f'#!/bin/sh\nTESSERA_AGENT_INTEGRATION_VERSION={version}\n')
        hook.chmod(0o700)

    def stage(self):
        self.run_request('begin')
        return self.run_request('write', offset=0, content=base64.b64encode(PAYLOAD).decode())

    def test_activate_retry_and_private_modes(self):
        self.stage()
        self.assertTrue(self.run_request('activate')['installed'])
        self.assertTrue(self.run_request('activate')['installed'])
        root = self.home / '.config/tessera'
        self.assertEqual((root / 'tessera-agent-host').read_bytes(), PAYLOAD)
        self.assertEqual((root / 'agent-host-versions' / self.digest).stat().st_mode & 0o777, 0o700)
        self.assertEqual(list((root / 'agent-host-staging').iterdir()), [])

    def test_shared_config_directories_still_install_for_their_owner(self):
        # A umask-0002 host leaves ~/.config and ~/.config/tessera group-writable;
        # they are the owner's directories and must not abort the install.
        config = self.home / '.config'; config.mkdir(mode=0o775)
        root = config / 'tessera'; root.mkdir(mode=0o775)
        config.chmod(0o775); root.chmod(0o775)
        self.stage()
        self.assertTrue(self.run_request('activate')['installed'])
        self.assertEqual((root / 'tessera-agent-host').read_bytes(), PAYLOAD)
        self.assertEqual(config.stat().st_mode & 0o777, 0o775)
        self.assertEqual(root.stat().st_mode & 0o777, 0o775)

    def test_replayed_chunks_are_idempotent_but_changed_metadata_is_rejected(self):
        self.stage()
        self.assertTrue(self.run_request('begin')['ready'])
        self.run_request('begin', good=False, bytes=len(PAYLOAD)+1)
        self.run_request('write', offset=0, content=base64.b64encode(PAYLOAD).decode())
        self.run_request('write', good=False, bytes=len(PAYLOAD)+1, offset=len(PAYLOAD), content='eA==')
        self.assertTrue(self.run_request('activate')['installed'])

    def test_checksum_failure_never_activates_and_abort_is_scoped(self):
        self.run_request('begin')
        self.run_request('write', offset=0, content=base64.b64encode(b'x' * len(PAYLOAD)).decode())
        self.run_request('activate', good=False, error='checksumMismatch')
        root = self.home / '.config/tessera'
        sentinel = root / 'agent-host-staging/sentinel'; sentinel.write_text('preserve')
        result = self.run_request('abort')
        self.assertFalse(result['installed'])
        self.assertEqual(sentinel.read_text(), 'preserve')
        self.assertFalse((root / 'tessera-agent-host').exists())

    def test_symlink_staging_is_rejected(self):
        root = self.home / '.config/tessera'; root.mkdir(parents=True)
        outside = self.home / 'outside'; outside.mkdir()
        (root / 'agent-host-staging').symlink_to(outside)
        self.run_request('begin', good=False)
        self.assertEqual(list(outside.iterdir()), [])

    def test_newer_integration_on_the_host_is_never_replaced(self):
        self.stage()
        self.write_hook(INTEGRATION + 1)
        self.run_request('activate', good=False, error='newerIntegrationInstalled')
        self.assertFalse((self.home / '.config/tessera/tessera-agent-host').exists())
        # The app's own version, or an older one, is replaced as before.
        self.write_hook(INTEGRATION)
        self.assertTrue(self.run_request('activate')['installed'])

    def test_probe_reports_a_newer_integration_before_any_upload(self):
        self.assertFalse(self.run_request('probe')['newerIntegration'])
        self.run_request('begin')
        self.write_hook(INTEGRATION)
        self.assertFalse(self.run_request('probe')['newerIntegration'])
        self.write_hook(INTEGRATION + 1)
        self.assertTrue(self.run_request('probe')['newerIntegration'])

    def test_only_the_owners_regular_hook_can_claim_a_newer_version(self):
        self.stage()
        self.write_hook(INTEGRATION + 1)
        hook = self.home / '.config/tessera/agent-lifecycle-hook.sh'
        # The owner decides the hook's mode: a umask 0002 host writes it
        # group-writable and the newer manifest still counts.
        hook.chmod(0o722)
        self.assertTrue(self.run_request('probe')['newerIntegration'])
        self.run_request('activate', good=False, error='newerIntegrationInstalled')
        hook.chmod(0o700)
        real = self.home / 'elsewhere.sh'; hook.rename(real); hook.symlink_to(real)
        self.assertFalse(self.run_request('probe')['newerIntegration'])
        self.assertTrue(self.run_request('activate')['installed'])

    def test_request_without_integration_version_fails_closed(self):
        self.stage()
        self.run_request('activate', good=False, error='invalidArtifact', integration=None)
        self.assertFalse((self.home / '.config/tessera/tessera-agent-host').exists())

    def test_two_apps_same_artifact_reuse_activation(self):
        self.stage(); first = self.upload
        self.upload = 'b' * 32; self.stage()
        self.assertTrue(self.run_request('activate')['installed'])
        self.upload = first
        self.assertTrue(self.run_request('activate')['installed'])
        self.assertEqual(list((self.home / '.config/tessera/agent-host-staging').iterdir()), [])
        self.assertEqual(len(list((self.home / '.config/tessera/agent-host-versions').iterdir())), 1)

    def test_version_gc_preserves_active_previous_recent_pinned_and_unknown_files(self):
        self.stage()
        root = self.home / '.config/tessera'; versions = root / 'agent-host-versions'
        def version(label, expired=True):
            data = PAYLOAD + ('# ' + label + '\n').encode()
            path = versions / hashlib.sha256(data).hexdigest()
            path.write_bytes(data); path.chmod(0o700)
            if expired: os.utime(path, (time.time()-90000, time.time()-90000))
            return path
        active = version('active'); previous = version('previous'); pinned = version('pinned')
        recent = version('recent', False); obsolete = version('obsolete')
        unknown = versions / ('f' * 64); unknown.write_bytes(b'not the named digest'); unknown.chmod(0o700)
        os.utime(unknown, (time.time()-90000, time.time()-90000))
        sentinel = versions / 'sentinel'; sentinel.write_text('preserve')
        (root / 'tessera-agent-host').symlink_to('agent-host-versions/' + active.name)
        (root / 'tessera-agent-host.previous').symlink_to('agent-host-versions/' + previous.name)
        # Refresh the upload's CAS snapshot after arranging the fixture links.
        meta = root / 'agent-host-staging' / (self.upload + '.json')
        saved = json.loads(meta.read_text()); saved['current'] = 'agent-host-versions/' + active.name
        meta.write_text(json.dumps(saved))
        with pinned.open('rb') as pin:
            fcntl.flock(pin, fcntl.LOCK_SH | fcntl.LOCK_NB)
            self.assertTrue(self.run_request('activate')['installed'])
            self.assertTrue(pinned.exists())
        self.assertFalse(obsolete.exists())
        for path in (active, previous, recent, unknown, sentinel): self.assertTrue(path.exists())

    def test_staging_budget_and_invalid_rollback_target_fail_closed(self):
        for n in range(8):
            self.upload = f'{n:032x}'; self.run_request('begin')
        self.upload = 'f' * 32; self.run_request('begin', good=False, error='stagingBudget')
        self.upload = f'{0:032x}'
        self.run_request('write', offset=0, content=base64.b64encode(PAYLOAD).decode())
        previous = self.home / '.config/tessera/tessera-agent-host.previous'
        previous.write_text('user sentinel')
        self.run_request('activate', good=False, error="'tessera-agent-host.previous'")
        self.assertEqual(previous.read_text(), 'user sentinel')

    def test_expired_owned_uploads_are_collected_but_unknown_and_recent_are_preserved(self):
        self.stage(); root = self.home / '.config/tessera/agent-host-staging'
        expired = self.upload; meta = root / (expired + '.json')
        saved = json.loads(meta.read_text()); saved['created'] = time.time() - 90000
        meta.write_text(json.dumps(saved)); meta.chmod(0o600)
        for path in [meta, root / expired]: os.utime(path, (time.time() - 90000, time.time() - 90000))
        unknown = root / ('c' * 32 + '.json'); unknown.write_text('{}'); unknown.chmod(0o600)
        os.utime(unknown, (time.time() - 90000, time.time() - 90000))
        self.upload = 'b' * 32; self.run_request('begin')
        self.assertFalse(meta.exists()); self.assertFalse((root / expired).exists())
        self.assertTrue(unknown.exists()); self.assertTrue((root / self.upload).exists())

    def test_rollback_compare_and_swap_does_not_replace_another_app_installation(self):
        self.stage(); self.run_request('activate'); previous = self.digest
        replacement = PAYLOAD + b'# second\n'; current = hashlib.sha256(replacement).hexdigest()
        self.upload = 'b' * 32
        self.run_request('begin', sha256=current, bytes=len(replacement))
        self.run_request('write', sha256=current, bytes=len(replacement), offset=0,
                         content=base64.b64encode(replacement).decode())
        self.run_request('activate', sha256=current, bytes=len(replacement))
        self.run_request('rollback', good=False, expectedCurrent='0' * 64)
        root = self.home / '.config/tessera'
        self.assertEqual(os.readlink(root / 'tessera-agent-host'), 'agent-host-versions/' + current)
        result = self.run_request('rollback', expectedCurrent=current)
        self.assertTrue(result['rolledBack'])
        self.assertEqual(os.readlink(root / 'tessera-agent-host'), 'agent-host-versions/' + previous)
        self.assertTrue(self.run_request('rollback', expectedCurrent=current)['rolledBack'])

    def test_rollback_recovers_interruption_between_link_publications(self):
        self.stage(); self.run_request('activate')
        replacement = PAYLOAD + b'# second\n'; second = hashlib.sha256(replacement).hexdigest()
        self.upload = 'b' * 32
        self.run_request('begin', sha256=second, bytes=len(replacement))
        self.run_request('write', sha256=second, bytes=len(replacement), offset=0,
                         content=base64.b64encode(replacement).decode())
        self.run_request('activate', sha256=second, bytes=len(replacement))
        original = self.program
        self.program = self.program.replace("if old: activate_link('tessera-agent-host.previous',old)",
            "if old: activate_link('tessera-agent-host.previous',old); os._exit(91)")
        self.run_request('rollback', good=False, expectedCurrent=second)
        self.program = original
        self.assertTrue(self.run_request('rollback', expectedCurrent=second)['rolledBack'])
        root = self.home / '.config/tessera'
        self.assertEqual(os.readlink(root / 'tessera-agent-host.previous'), 'agent-host-versions/' + second)
        self.assertFalse((root / 'agent-host-publication.json').exists())
        self.assertTrue(self.run_request('rollback', expectedCurrent=self.digest,
            sha256=second, bytes=len(replacement))['rolledBack'])

    def test_unknown_json_metadata_types_do_not_block_uploads(self):
        self.stage(); staging = self.home / '.config/tessera/agent-host-staging'
        for index, value in enumerate(([], None, 42, 'unknown')):
            path = staging / (f'{index:032x}' + '.json')
            path.write_text(json.dumps(value)); path.chmod(0o600)
        self.upload = 'b' * 32
        self.assertTrue(self.run_request('begin')['ready'])
        for index in range(4): self.assertTrue((staging / (f'{index:032x}' + '.json')).exists())

    def test_activation_recovers_partial_unpublished_journal(self):
        self.stage(); original = self.program
        self.program = self.program.replace('count=os.write(fd,remaining)', 'count=os.write(fd,remaining[:10]); os._exit(91)')
        self.run_request('activate', good=False)
        self.program = original
        self.assertTrue(self.run_request('activate')['installed'])
        root = self.home / '.config/tessera'
        self.assertFalse((root / ('agent-host-publication.' + self.upload)).exists())

    def test_verification_output_is_bounded(self):
        global PAYLOAD
        original = PAYLOAD
        try:
            PAYLOAD = b'#!/bin/sh\nyes overflow\n'
            self.digest = hashlib.sha256(PAYLOAD).hexdigest()
            self.stage()
            result = self.run_request('activate', good=False)
            self.assertIn(b'verificationOutputBudget', result.stderr)
            self.assertFalse((self.home / '.config/tessera/tessera-agent-host').exists())
        finally: PAYLOAD = original

    def test_activation_recovers_after_version_rename_before_publish(self):
        self.stage()
        root = self.home / '.config/tessera'
        staged = root / 'agent-host-staging' / self.upload
        staged.chmod(0o700)
        staged.rename(root / 'agent-host-versions' / self.digest)
        self.assertTrue(self.run_request('activate')['installed'])

    def test_activation_recovers_own_temporary_link_but_preserves_conflicts(self):
        self.stage()
        root = self.home / '.config/tessera'
        temporary = root / ('tessera-agent-host.' + self.upload)
        temporary.write_text('user sentinel')
        self.run_request('activate', good=False)
        self.assertEqual(temporary.read_text(), 'user sentinel')
        temporary.unlink()  # Exact test-owned sentinel, not installation data.
        temporary.symlink_to('agent-host-versions/' + self.digest)
        self.assertTrue(self.run_request('activate')['installed'])
        self.assertFalse(temporary.exists())


if __name__ == '__main__':
    unittest.main()
