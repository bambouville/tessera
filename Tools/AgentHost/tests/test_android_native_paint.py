#!/usr/bin/env python3
"""Clock/IPC safety oracles; synthetic bytes only, no emulator or provider."""
import asyncio
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'scripts/performance/agent-center'))
from android_native_paint import AndroidProxy, clock_bounds, owned_command
from native_first_page import now_ns


class ClockTests(unittest.TestCase):
    def test_intersection_contains_true_offset(self):
        samples = [(1000, 51010, 51020, 1040)] * 5
        self.assertEqual(clock_bounds(samples), (49980, 50010))

    def test_missing_or_invalid_samples_fail(self):
        for samples in ([], [(1000, 51010, 51020, 1040)] * 4,
                        [(1000, 51020, 51010, 1040)] * 5,
                        [(True, 2, 3, 4)] * 5,
                        [(1000, 51010, 51020, 40)] * 5):
            with self.subTest(samples=samples):
                with self.assertRaises(RuntimeError): clock_bounds(samples)

    def test_inconsistent_or_imprecise_calibration_fails(self):
        with self.assertRaises(RuntimeError):
            clock_bounds([(1000, 51010, 51020, 1040)] * 4 + [(1000, 61010, 61020, 1040)])
        with self.assertRaises(RuntimeError):
            clock_bounds([(1, 2, 3, 100_000_000)] * 5)


class ProxyTests(unittest.IsolatedAsyncioTestCase):
    async def test_reused_serial_never_receives_mutation(self):
        for name in (b'other-device\nOK\n', b''):
            with patch('android_native_paint.command', AsyncMock(return_value=(name, b''))) as operation:
                with self.assertRaisesRegex(RuntimeError, 'identity_changed'):
                    await owned_command('/synthetic/adb', 'emulator-5998', 'tessera-agent-window-owned', 'install', '-r', '/synthetic.apk')
                self.assertEqual(operation.await_count, 1)
                self.assertEqual(operation.await_args.args[3:], ('emu', 'avd', 'name'))

    async def test_matching_identity_allows_only_requested_operation(self):
        with patch('android_native_paint.command', AsyncMock(side_effect=[(b'tessera-agent-window-owned\nOK\n', b''), (b'done', b'')])) as operation:
            self.assertEqual(await owned_command('/synthetic/adb', 'emulator-5998', 'tessera-agent-window-owned', 'install', '-r', '/synthetic.apk'), (b'done', b''))
            self.assertEqual(operation.await_count, 2)
            self.assertEqual(operation.await_args.args[3:], ('install', '-r', '/synthetic.apk'))

    async def test_authentication_precedes_backend_connection(self):
        with tempfile.TemporaryDirectory(prefix='tessera-android-proxy-', dir='/private/tmp') as directory:
            proxy = AndroidProxy(str(Path(directory) / 'absent.sock'), 0, 'a' * 64)
            server = await asyncio.start_unix_server(proxy.accept, str(Path(directory) / 'proxy.sock'))
            reader, writer = await asyncio.open_unix_connection(str(Path(directory) / 'proxy.sock'))
            try:
                writer.write(b'b' * 64); await writer.drain()
                await asyncio.wait_for(proxy.ready.wait(), 2)
                self.assertEqual(proxy.failure, 'android_fixture_authentication')
                self.assertEqual(proxy.connections, 0)
                self.assertEqual(await reader.read(), b'')
            finally:
                writer.close(); server.close(); await proxy.close(); await server.wait_closed()

    async def test_calibrated_authenticated_stream_and_cleanup(self):
        with tempfile.TemporaryDirectory(prefix='tessera-android-proxy-', dir='/private/tmp') as directory:
            root = Path(directory); backend_tasks = set()
            async def echo(reader, writer):
                task = asyncio.current_task(); backend_tasks.add(task)
                try:
                    writer.write(await reader.readexactly(5)); await writer.drain()
                finally: writer.close(); backend_tasks.discard(task)
            backend = await asyncio.start_unix_server(echo, root / 'backend.sock')
            proxy = AndroidProxy(str(root / 'backend.sock'), .005, 'a' * 64)
            server = await asyncio.start_unix_server(proxy.accept, root / 'proxy.sock')
            reader, writer = await asyncio.open_unix_connection(root / 'proxy.sock')
            async def device():
                writer.write(b'a' * 64); await writer.drain()
                for _ in range(5):
                    nonce, = struct.unpack('!q', await reader.readexactly(8))
                    received = now_ns() + 50_000_000
                    writer.write(struct.pack('!qqq', nonce, received, now_ns() + 50_000_000)); await writer.drain()
                writer.write(struct.pack('!q', 123456)); await writer.drain()
                self.assertEqual(await reader.readexactly(1), b'\x01')
                writer.write(b'hello'); await writer.drain()
                self.assertEqual(await reader.readexactly(5), b'hello')
            task = asyncio.create_task(device())
            try:
                await asyncio.wait_for(proxy.ready.wait(), 3)
                self.assertIsNone(proxy.failure)
                self.assertLessEqual(proxy.offset[0], 50_000_000)
                self.assertGreaterEqual(proxy.offset[1], 50_000_000)
                self.assertEqual(proxy.baseline, 123456)
                proxy.go.set()
                await asyncio.wait_for(task, 3)
                self.assertEqual(proxy.connections, 1)
                self.assertEqual(proxy.bytes, [5, 5])
            finally:
                task.cancel(); await asyncio.gather(task, return_exceptions=True)
                writer.close(); server.close(); backend.close()
                await proxy.close()
                for child in list(backend_tasks): child.cancel()
                await asyncio.gather(*backend_tasks, return_exceptions=True)
                await server.wait_closed(); await backend.wait_closed()
            self.assertFalse(proxy.tasks or proxy.handshakes)


if __name__ == '__main__': unittest.main()
