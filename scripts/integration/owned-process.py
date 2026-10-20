#!/usr/bin/env python3
"""POSIX test-process group with an unreaped, waitable ownership anchor.

The supervisor stays alive after the command exits, so group cleanup cannot
target a recycled PID. Intended for trusted, non-daemonizing test commands;
commands which deliberately escape the session need a separate sandbox.
"""
import contextlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time


@contextlib.contextmanager
def cleanup_signals():
    """Finish all cleanup stages before honoring a first termination signal."""
    current = signal.getsignal(signal.SIGTERM)
    if getattr(current, 'tessera_cleanup_handler', False) or current == signal.SIG_IGN:
        yield
        return
    pending = []
    def defer(signum, _frame):
        pending.append(signum)
    defer.tessera_cleanup_handler = True
    previous = signal.signal(signal.SIGTERM, defer)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)
        if pending:
            raise SystemExit(128 + pending[0])


@contextlib.contextmanager
def termination_cleanup():
    def terminate(signum, _frame):
        # A second termination must not interrupt finally-based cleanup.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        raise SystemExit(128 + signum)
    previous = signal.signal(signal.SIGTERM, terminate)
    try:
        yield
    finally:
        signal.signal(signal.SIGTERM, previous)


class OwnedProcess:
    def __init__(self, command, **kwargs):
        read_fd, write_fd = os.pipe()
        self.status = read_fd
        self.returncode = None
        self.child_pid = None
        self.status_buffer = b''
        self.closed = False
        try:
            self.process = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), str(write_fd), *command],
                stdin=subprocess.PIPE, pass_fds=(write_fd,), start_new_session=True, **kwargs)
        except BaseException:
            os.close(read_fd)
            raise
        finally:
            os.close(write_fd)

    def poll(self):
        if self.returncode is None and select.select([self.status], [], [], 0)[0]:
            data = os.read(self.status, 128)
            if not data:
                raise RuntimeError('owned process supervisor lost')
            self.status_buffer += data
            while b'\n' in self.status_buffer:
                line, self.status_buffer = self.status_buffer.split(b'\n', 1)
                event = json.loads(line)
                if 'pid' in event: self.child_pid = event['pid']
                if 'returncode' in event: self.returncode = event['returncode']
        return self.returncode

    def close(self):
        with cleanup_signals():
            self._close()

    def _close(self):
        if self.closed:
            return
        try:
            # Do not poll/reap the supervisor before the last group signal.
            # A still-waitable direct child reserves its PID even if killed.
            try:
                os.killpg(self.process.pid, signal.SIGTERM)
                time.sleep(.1)
                os.killpg(self.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.process.wait(timeout=3)
        finally:
            self.closed = True
            self.process.stdin.close()
            os.close(self.status)


def supervise():
    status = int(sys.argv[1])
    # A handler (not SIG_IGN) resets on exec for the actual command.
    signal.signal(signal.SIGTERM, lambda *_: None)
    child = subprocess.Popen(sys.argv[2:], stdin=subprocess.DEVNULL)
    os.write(status, (json.dumps({'pid': child.pid}) + '\n').encode())
    reported = False
    while True:
        code = child.poll()
        if code is not None and not reported:
            os.write(status, (json.dumps({'returncode': code}) + '\n').encode())
            reported = True
        if select.select([sys.stdin], [], [], .05)[0] and not os.read(0, 1):
            # Controller died (including SIGKILL): own group cleanup still
            # runs; this supervisor itself anchors the group identity.
            os.killpg(os.getpgrp(), signal.SIGTERM)
            time.sleep(.1)
            os.killpg(os.getpgrp(), signal.SIGKILL)


if __name__ == '__main__':
    supervise()
