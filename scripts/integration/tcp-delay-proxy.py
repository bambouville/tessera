#!/usr/bin/env python3
"""Run-owned fixture relay: delay each TCP direction without serializing packets.

With --rate, each direction also drains no faster than that many bytes per
second, and bytes a sender pushes beyond it wait in the relay like they would
in a slow link's buffer.
"""
import argparse
import asyncio
import os
from pathlib import Path
import signal
import time


async def main(args):
    state = Path(args.state_dir)
    state.mkdir(parents=True, exist_ok=True)
    stopped = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stopped.set)
    connections = set()

    async def relay(reader, writer):
        queue = asyncio.Queue()

        async def read():
            try:
                while data := await reader.read(65536):
                    await queue.put((time.monotonic() + args.delay_ms / 1000, data))
            finally:
                await queue.put((time.monotonic() + args.delay_ms / 1000, None))

        async def write():
            delay = args.delay_ms / 1000
            link_free_at = time.monotonic()
            while True:
                deadline, data = await queue.get()
                if args.rate and data is not None:
                    # Serialize behind earlier bytes, then add the delay.
                    link_free_at = max(deadline - delay, link_free_at) + len(data) / args.rate
                    deadline = link_free_at + delay
                await asyncio.sleep(max(0, deadline - time.monotonic()))
                if data is None:
                    writer.close()
                    return
                writer.write(data)
                await writer.drain()

        tasks = [asyncio.create_task(read()), asyncio.create_task(write())]
        try:
            await asyncio.gather(*tasks)
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            writer.close()

    async def connection(reader, writer):
        task = asyncio.current_task()
        connections.add(task)
        upstream = None
        try:
            remote, upstream = await asyncio.open_connection('127.0.0.1', args.target_port)
            await asyncio.gather(relay(reader, upstream), relay(remote, writer))
        except (OSError, ConnectionError):
            pass
        finally:
            writer.close()
            if upstream:
                upstream.close()
            connections.discard(task)

    server = await asyncio.start_server(connection, '0.0.0.0', 0)
    (state / 'pid').write_text(str(os.getpid()))
    (state / 'port').write_text(str(server.sockets[0].getsockname()[1]))
    async with server:
        try:
            await asyncio.wait_for(stopped.wait(), 1200)
        except asyncio.TimeoutError:
            pass
    for task in list(connections):
        task.cancel()
    await asyncio.gather(*connections, return_exceptions=True)


parser = argparse.ArgumentParser()
parser.add_argument('--state-dir', required=True)
parser.add_argument('--target-port', type=int, required=True)
parser.add_argument('--delay-ms', type=int, required=True)
parser.add_argument('--rate', type=float, default=0, help='bytes per second in each direction; 0 is unlimited')
asyncio.run(main(parser.parse_args()))
