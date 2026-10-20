#!/usr/bin/env python3
"""Synthetic-only safety tests; never launch Codex or inspect real sessions."""
import os
import json
from pathlib import Path
import subprocess
import sqlite3
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts/performance/agent-center'))
import codex_private_materialization_probe as probe


class PrivateProbeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='tessera-probe-test-', dir='/private/tmp')
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / 'source'; self.source.write_text('synthetic')
        info = self.source.stat()
        self.expected = dict(device=info.st_dev, inode=info.st_ino, bytes=info.st_size, mtime_ns=info.st_mtime_ns)

    def tearDown(self): self.temporary.cleanup()

    def test_stable_regular_copy(self):
        target = self.root / 'new/target'
        probe.stable_copy(self.source, target, self.expected)
        self.assertEqual(target.read_text(), 'synthetic')
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertNotEqual(target.stat().st_ino, self.source.stat().st_ino)

    def test_symlink_rejected(self):
        link = self.root / 'link'; link.symlink_to(self.source)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            probe.stable_copy(link, self.root / 'target')

    def test_hardlink_rejected(self):
        link = self.root / 'link'; os.link(self.source, link)
        with self.assertRaisesRegex(RuntimeError, 'single_link'):
            probe.stable_copy(link, self.root / 'target')

    def test_original_identity_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'live_original'):
            probe.stable_copy(self.source, self.root / 'target', self.expected, self.source)

    def test_each_manifest_identity_field_required(self):
        for key in self.expected:
            with self.subTest(key=key):
                expected = dict(self.expected); expected[key] += 1
                with self.assertRaisesRegex(RuntimeError, 'manifest_mismatch'):
                    probe.stable_copy(self.source, self.root / key, expected)

    def test_no_target_overwrite(self):
        target = self.root / 'target'; target.write_text('preserve')
        with self.assertRaises(FileExistsError): probe.stable_copy(self.source, target)
        self.assertEqual(target.read_text(), 'preserve')

    def test_directory_ownership_not_mode_gates_the_probe(self):
        self.root.chmod(0o700)
        probe.finite_directory(self.root, '/private/tmp/tessera-probe-test-')
        # The owner decides the mode; a shared root is still theirs.
        self.root.chmod(0o775)
        probe.finite_directory(self.root, '/private/tmp/tessera-probe-test-')
        with self.assertRaisesRegex(RuntimeError, 'probe_finite_source_root'):
            probe.finite_directory(self.root, '/private/tmp/elsewhere-')

    def test_rpc_rejects_turn_start_before_writing(self):
        with self.assertRaisesRegex(RuntimeError, 'method_not_allowed'):
            probe.RPC(None).call('turn/start', {})

    def test_complete_private_sqlite_wal_copy(self):
        source = self.root / 'source.sqlite'
        with sqlite3.connect(source) as connection:
            connection.execute('PRAGMA journal_mode=WAL')
            connection.execute('CREATE TABLE synthetic(value TEXT)')
            connection.execute("INSERT INTO synthetic VALUES ('finite')")
            connection.commit()
            self.assertTrue(Path(str(source) + '-wal').exists())
            target = self.root / 'target.sqlite'
            probe.copy_database_snapshot(source, target)
            with sqlite3.connect(target) as copied:
                self.assertEqual(copied.execute('SELECT value FROM synthetic').fetchall(), [('finite',)])

    def lineage_candidate(self, identifier, parent=None):
        snapshots = self.root / 'snapshots'; snapshots.mkdir(exist_ok=True)
        path = snapshots / (identifier + '.jsonl')
        path.write_text(json.dumps(dict(type='session_meta', payload=dict(id=identifier, forked_from_id=parent))) + '\n')
        info = path.stat()
        return dict(provider='codex', path=str(path), original_path='/not-a-live-source/rollout-' + identifier + '.jsonl',
                    device=info.st_dev, inode=info.st_ino, bytes=info.st_size, mtime_ns=info.st_mtime_ns)

    def test_lineage_only_copies_exact_manifest_ancestors(self):
        parent_id = '00000000-0000-0000-0000-000000000001'
        child_id = '00000000-0000-0000-0000-000000000002'
        parent = self.lineage_candidate(parent_id)
        child = self.lineage_candidate(child_id, parent_id)
        first, copied = probe.copy_lineage([child, parent], child, self.root, self.root / 'codex')
        self.assertEqual(first[0], child_id)
        self.assertEqual(list(copied), [child_id, parent_id])
        self.assertTrue(all(path.is_relative_to(self.root / 'codex') for path in copied.values()))

    def test_lineage_missing_parent_is_failure(self):
        child = self.lineage_candidate('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000001')
        with self.assertRaisesRegex(RuntimeError, 'missing_or_cycle'):
            probe.copy_lineage([child], child, self.root, self.root / 'codex')

    def test_lineage_cycle_is_failure(self):
        first_id = '00000000-0000-0000-0000-000000000001'
        second_id = '00000000-0000-0000-0000-000000000002'
        first = self.lineage_candidate(first_id, second_id)
        second = self.lineage_candidate(second_id, first_id)
        with self.assertRaisesRegex(RuntimeError, 'missing_or_cycle'):
            probe.copy_lineage([first, second], first, self.root, self.root / 'codex')

    def test_failed_prior_materialization_never_becomes_provenance(self):
        with tempfile.TemporaryDirectory(prefix='tessera-native-reference-test-', dir='/private/tmp') as directory:
            root = Path(directory).resolve(); (root / 'codex').mkdir(mode=0o700)
            valid = dict(stage='offline_private_clone_materialization_not_live_attachment', manifestSHA256='synthetic',
                         isolationPreflightPassed=True, resumedPrivateClone=True, materializationAdvanced=True,
                         ownedProcessExited=True, cleanupErrors=[], guardFailure=None)
            evidence = root / 'content-free-results.json'; evidence.write_text(json.dumps(valid))
            self.assertEqual(len(probe.validate_snapshot(root / 'codex', 'synthetic')), 64)
            for field in ('isolationPreflightPassed', 'resumedPrivateClone', 'materializationAdvanced', 'ownedProcessExited'):
                with self.subTest(field=field):
                    broken = dict(valid); broken[field] = False; evidence.write_text(json.dumps(broken))
                    with self.assertRaisesRegex(RuntimeError, 'incomplete'):
                        probe.validate_snapshot(root / 'codex', 'synthetic')

    @unittest.skipUnless(sys.platform == 'darwin' and os.environ.get('TESSERA_PROBE_ISOLATION_CHECKER'),
                         'requires separately built synthetic Seatbelt checker')
    def test_real_seatbelt_synthetic_negative_checks(self):
        executable = self.root / 'checker'
        probe.stable_copy(Path(os.environ['TESSERA_PROBE_ISOLATION_CHECKER']).resolve(), executable)
        executable.chmod(0o700)
        with tempfile.TemporaryDirectory(prefix='tessera-probe-denied-', dir='/private/tmp') as denied:
            sentinel = Path(denied) / 'sentinel'; sentinel.write_text('synthetic')
            result = subprocess.run(['/usr/bin/sandbox-exec', '-p', probe.sandbox_profile(self.root, executable),
                str(executable), str(self.source), str(sentinel)], env={'PATH': '/usr/bin:/bin'},
                capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, 'synthetic checker status ' + str(result.returncode)
                             + ': ' + result.stderr.decode(errors='replace')[:2048])


if __name__ == '__main__': unittest.main()
