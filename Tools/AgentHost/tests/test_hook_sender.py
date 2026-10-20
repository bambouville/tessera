"""Native observational sender contract. Uses only private, owned sockets."""
import json
import concurrent.futures
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

BINARY = str(Path(sys.argv.pop(1)).resolve())


class HookSenderTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="tah-", dir="/tmp")
        self.directory = Path(self.temporary.name).resolve()
        self.path = self.directory / "s"
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.path))
        self.path.chmod(0o600)
        self.listener.listen(8)
        self.listener.settimeout(1)

    def tearDown(self):
        self.listener.close()
        self.temporary.cleanup()

    def invoke(self, data=b'{}', path=None):
        started = time.monotonic()
        result = subprocess.run([BINARY, "hook", "--socket", str(path or self.path)],
                                input=data, capture_output=True, timeout=2)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b'', b''))
        self.assertLess(time.monotonic() - started, 1)
        return result

    def receive(self):
        connection, _ = self.listener.accept()
        with connection:
            connection.settimeout(1)
            data = bytearray()
            while chunk := connection.recv(8192):
                data.extend(chunk)
            size, = struct.unpack("!I", data[:4])
            self.assertEqual(size, len(data) - 4)
            self.assertLessEqual(size, 65536)
            return bytes(data[4:])

    def test_complete_payload(self):
        payload = json.dumps({"hook_event_name": "Stop", "last_assistant_message": "café"}).encode()
        self.invoke(payload)
        self.assertEqual(self.receive(), payload)

    def test_absent_service_never_created(self):
        missing = self.directory / "absent"
        self.invoke(path=missing)
        self.assertFalse(missing.exists())

    def test_oversize_emits_only_reconcile_hint(self):
        self.invoke(b'x' * 65537)
        self.assertEqual(json.loads(self.receive())["hook_event_name"], "TesseraHookOverflow")

    def test_exact_limit_is_not_truncated(self):
        payload = b' ' * 65534 + b'{}'
        # Drain concurrently: waiting for sender exit first intentionally
        # backpressures the small platform socket buffer until its deadline.
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            receipt = pool.submit(self.receive)
            self.invoke(payload)
            self.assertEqual(receipt.result(timeout=2), payload)

    def test_backpressure_does_not_hold_provider(self):
        # Deliberately do not accept/read while the sender runs. It must exit
        # even if this platform's socket buffer cannot hold the full frame.
        self.invoke(b' ' * 65534 + b'{}')
        connection, _ = self.listener.accept()
        with connection:
            connection.settimeout(1)
            data = bytearray()
            while chunk := connection.recv(8192):
                data.extend(chunk)
            self.assertLessEqual(len(data), 65540)

    def test_insecure_ancestor_symlink_is_rejected(self):
        alias = self.directory / 'alias-directory'
        actual = self.directory / 'actual'
        actual.mkdir(mode=0o700)
        alias.symlink_to(actual, target_is_directory=True)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(actual / 's'))
            (actual / 's').chmod(0o600)
            listener.listen(1)
            listener.settimeout(.1)
            self.invoke(path=alias / 's')
            with self.assertRaises(socket.timeout):
                listener.accept()

    def test_shared_directory_still_delivers_to_the_owner(self):
        # A umask 0002 host leaves the runtime directory group-writable. The
        # owner decides its mode; ownership and the symlink walk are the gate.
        self.directory.chmod(0o775)
        payload = json.dumps({"hook_event_name": "Stop"}).encode()
        self.invoke(payload)
        self.assertEqual(self.receive(), payload)

    def test_shared_socket_still_delivers_to_the_owner(self):
        self.path.chmod(0o666)
        payload = json.dumps({"hook_event_name": "Stop"}).encode()
        self.invoke(payload)
        self.assertEqual(self.receive(), payload)

    def test_symlink_socket_rejected(self):
        alias = self.directory / "alias"
        alias.symlink_to(self.path)
        self.invoke(path=alias)
        with self.assertRaises(socket.timeout):
            self.listener.accept()

    def test_stalled_input_exits_without_waiting_for_eof(self):
        process = subprocess.Popen([BINARY, "hook", "--socket", str(self.path)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(process.wait(timeout=1), 0)
            self.assertEqual(process.stdout.read(), b'')
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=1)
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()


if __name__ == '__main__':
    unittest.main()
