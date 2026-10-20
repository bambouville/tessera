#!/usr/bin/env python3
"""Deterministic cleanup tests; only temporary local files, no remote access."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "revoke", Path(__file__).parent / "remote/revoke-qr-fixture-key.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class KeyCleanupTests(unittest.TestCase):
    owned = b"ssh-ed25519 YWJj owned\n"
    other = b"ssh-ed25519 ZGVm other\n"
    appended = b"ecdsa-sha2-nistp256 Z2hp concurrent\n"

    def test_append_between_snapshot_and_revocation_survives(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "authorized_keys"
            path.write_bytes(self.other + self.owned)
            def append():
                with path.open("ab") as stream:
                    stream.write(self.appended)
            self.assertEqual(module.revoke(path, module.fingerprint(self.owned), append), 1)
            result = path.read_bytes()
            self.assertTrue(result.startswith(self.other))
            self.assertTrue(result.endswith(self.appended))
            self.assertNotIn(self.owned, result)

    def test_interrupted_transfer_only_needs_preapproved_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "authorized_keys"
            path.write_bytes(self.other + self.owned)
            self.assertEqual(module.revoke(path, module.fingerprint(self.owned)), 1)
            self.assertEqual(module.revoke(path, module.fingerprint(self.owned)), 0)
            self.assertTrue(path.read_bytes().startswith(self.other))

    def test_replacement_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "authorized_keys"
            path.write_bytes(self.owned)
            def replace():
                new = Path(directory) / "replacement"
                new.write_bytes(self.appended)
                new.replace(path)
            with self.assertRaises(RuntimeError):
                module.revoke(path, module.fingerprint(self.owned), replace)
            self.assertEqual(path.read_bytes(), self.appended)


if __name__ == "__main__":
    unittest.main()
