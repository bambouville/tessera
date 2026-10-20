#!/usr/bin/env python3
"""Deterministic remote PTY oracle used only by Tessera integration tests."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import re
import select
import signal
import socketserver
import subprocess
import sys
import termios
import time
import tty


def command_identity(_: argparse.Namespace) -> int:
    print(json.dumps({
        "marker": "TESSERA_FIXTURE_IDENTITY_V1",
        "user": os.environ.get("USER", ""),
        "home": os.environ.get("HOME", ""),
        "shell": os.environ.get("SHELL", ""),
        "cwd": os.getcwd(),
    }, sort_keys=True))
    return 0


def command_lines(args: argparse.Namespace) -> int:
    for index in range(1, args.count + 1):
        color = 16 + (index % 216)
        marker = f"TESSERA_ROW_{index:05d}"
        if args.color:
            print(f"\x1b[48;5;{color}m{marker:<72}\x1b[0m")
        else:
            print(marker)
    return 0


def command_capture(args: argparse.Namespace) -> int:
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    payload = bytearray()
    started = time.monotonic()
    deadline = started + args.timeout
    sequences = []

    if args.alt_screen:
        sequences.append("\x1b[?1049h")
    if args.bracketed_paste:
        sequences.append("\x1b[?2004h")
    if args.mouse:
        sequences.append("\x1b[?1000h\x1b[?1006h")

    try:
        tty.setraw(fd)
        sys.stdout.write("".join(sequences))
        sys.stdout.write("TESSERA_CAPTURE_READY\r\n")
        sys.stdout.flush()
        while len(payload) < args.bytes and time.monotonic() < deadline:
            readable, _, _ = select.select([fd], [], [], 0.1)
            if not readable:
                continue
            chunk = os.read(fd, min(4096, args.bytes - len(payload)))
            if not chunk:
                break
            payload.extend(chunk)
    finally:
        sys.stdout.write("\x1b[?1006l\x1b[?1000l\x1b[?2004l\x1b[?1049l")
        sys.stdout.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, original)

    report = {
        "marker": "TESSERA_FIXTURE_CAPTURE_V1",
        "byte_count": len(payload),
        "base64": base64.b64encode(payload).decode("ascii"),
        "hex": payload.hex(),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "elapsed_ms": round((time.monotonic() - started) * 1000),
        "requested": {
            "bytes": args.bytes,
            "mouse": args.mouse,
            "bracketed_paste": args.bracketed_paste,
            "alt_screen": args.alt_screen,
        },
    }
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    temporary.replace(output)
    matches = args.expect_sha256 is None or report["sha256"] == args.expect_sha256
    verdict = "pass" if matches else "fail"
    print(f"TESSERA_CAPTURE_COMPLETE sha256={report['sha256']} verdict={verdict}")
    return 0 if matches else 1


def command_scroll_scenario(args: argparse.Namespace) -> int:
    """Produce real primary history, then deterministic htop and vim stages."""
    trigger = pathlib.Path(args.trigger)
    vim_file = trigger.with_suffix(trigger.suffix + ".vim.txt")
    vim_file.write_text("".join(
        f"TESSERA_VIM_{args.label}_{index:05d} | "
        f"0123456789abcdef0123456789abcdef\n"
        for index in range(1, 1001)
    ))

    for index in range(1, args.count + 1):
        print(
            f"TESSERA_SCROLL_{args.label}_{index:05d} | "
            "0123456789abcdef0123456789abcdef",
            flush=True,
        )
        if args.delay > 0:
            time.sleep(args.delay)
    print(f"TESSERA_SCROLL_{args.label}_BOTTOM_READY", flush=True)

    print("TESSERA_SCROLL_WAITING_FOR_HTOP", flush=True)
    deadline = time.monotonic() + args.trigger_timeout
    while not trigger.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    if not trigger.exists():
        print("TESSERA_SCROLL_TRIGGER_TIMEOUT", file=sys.stderr, flush=True)
        return 1

    trigger.with_suffix(trigger.suffix + ".htop").touch()
    env = os.environ.copy()
    env.setdefault("TERM", "xterm-256color")
    # Let GNU timeout own htop's process group. A Python parent that polls a
    # cross-SSH sentinel can stop progressing after htop takes ownership of a
    # mosh PTY, leaving the visual sequence permanently in the htop phase.
    # --foreground keeps the timer in the TTY's foreground process group too.
    # Plain mosh can still retain htop across this transition, so that one Vim
    # row remains diagnostic-only; allocated PTYs and tmux advance reliably.
    subprocess.run(
        [
            "timeout", "--foreground", str(args.htop_seconds),
            "htop", "-d", "100",
        ],
        env=env,
        check=False,
    )

    vim_ready = trigger.with_suffix(trigger.suffix + ".vim")
    vim_ready_command = (
        "silent call writefile(['ready'], "
        f"'{str(vim_ready).replace(chr(39), chr(39) * 2)}')"
    )
    os.execvpe(
        "timeout",
        [
            "timeout", str(args.vim_seconds), "vim", "-Nu", "NONE", "-n",
            "+300", "-c", "set mouse=a", "-c", "set nowrap",
            "-c", vim_ready_command, str(vim_file),
        ],
        env,
    )
    return 0


def command_tmux_redraw_burst(args: argparse.Namespace) -> int:
    """Write many viewport redraws through a live tmux pane's PTY."""
    pane_tty = subprocess.check_output(
        [
            "tmux", "display-message", "-p", "-t", args.session,
            "#{pane_tty}",
        ],
        text=True,
    ).strip()
    if not pane_tty:
        raise RuntimeError(f"tmux session has no pane tty: {args.session}")

    if args.start_delay > 0:
        time.sleep(args.start_delay)
    fd = os.open(pane_tty, os.O_WRONLY | os.O_NOCTTY)
    try:
        for frame in range(1, args.frames + 1):
            rows = [
                (
                    f"TESSERA_FOREGROUND_REDRAW_{frame:04d}_{row:03d} | "
                    "0123456789abcdef0123456789abcdef"
                )
                for row in range(1, args.rows + 1)
            ]
            payload = ("\x1b[H\x1b[2J" + "\r\n".join(rows)).encode("utf-8")
            offset = 0
            while offset < len(payload):
                offset += os.write(fd, payload[offset:])
            if args.frame_delay > 0:
                time.sleep(args.frame_delay)
    finally:
        os.close(fd)
    print(
        f"TESSERA_TMUX_REDRAW_COMPLETE frames={args.frames} rows={args.rows}",
        flush=True,
    )
    return 0


_ISOLATION_OWNERS = ("W1", "W2", "P2b")
_ISOLATION_TOKEN = re.compile(r"[A-Za-z0-9_-]{1,64}\Z")
_ISOLATION_SESSION = re.compile(r"[A-Za-z0-9_.-]{1,80}\Z")


def _isolation_marker(owner: str, token: str) -> str:
    if owner not in _ISOLATION_OWNERS:
        raise ValueError(f"unsupported isolation owner: {owner}")
    if not _ISOLATION_TOKEN.fullmatch(token):
        raise ValueError("isolation token must use 1-64 ASCII letters, digits, underscore, or dash")
    return f"TESSERA-{owner}-{token}"


def command_tmux_isolation_stream(args: argparse.Namespace) -> int:
    """Keep one tmux pane alive after emitting its unique history marker."""
    marker = _isolation_marker(args.owner, args.token)
    if args.count <= 0:
        raise ValueError("isolation marker count must be positive")
    if args.hold_seconds <= 0:
        raise ValueError("isolation hold duration must be positive")
    if args.heartbeat_seconds < 0:
        raise ValueError("isolation heartbeat interval cannot be negative")
    for _ in range(args.count):
        print(marker, flush=True)
    # The controller gate owns session teardown. Keeping the pane alive lets a
    # reconnect or side-channel interruption inspect the same server history.
    deadline = time.monotonic() + args.hold_seconds
    heartbeat = 0
    next_heartbeat = (
        time.monotonic() + args.heartbeat_seconds
        if args.heartbeat_seconds > 0
        else None
    )
    while time.monotonic() < deadline:
        now = time.monotonic()
        if next_heartbeat is not None and now >= next_heartbeat:
            # The mosh+tmux half of the gate drops only the SSH `-CC`
            # side-channel. A periodic mutation of the visible pane proves
            # that the UDP painter stayed alive after that forced drop.
            heartbeat += 1
            # The increasing suffix is deliberately observable in the live
            # Mosh canvas.  The native gate records it before and after a
            # targeted side-channel drop, proving the UDP painter progressed
            # rather than merely remaining in a connected state.
            print(f"{marker}-HEARTBEAT-{heartbeat}", flush=True)
            next_heartbeat = now + args.heartbeat_seconds
        delay = min(0.25, deadline - now)
        if next_heartbeat is not None:
            delay = min(delay, max(0, next_heartbeat - now))
        if delay > 0:
            time.sleep(delay)
    return 0


def _tmux_command(*args: str) -> str:
    return subprocess.check_output(("tmux", *args), text=True).strip()


def _proc_stat_fields(pid: int) -> list[str] | None:
    try:
        raw = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
        close = raw.rfind(")")
        if close < 2 or close + 2 > len(raw):
            return None
        return raw[close + 2:].split()
    except (FileNotFoundError, OSError):
        return None


def _proc_parent(pid: int) -> int | None:
    """Read one Linux parent PID without trusting the process display name."""
    fields = _proc_stat_fields(pid)
    try:
        parent = int(fields[1]) if fields is not None else 0
        return parent if parent > 0 else None
    except (IndexError, ValueError):
        return None


def _proc_start_time(pid: int) -> int | None:
    fields = _proc_stat_fields(pid)
    try:
        # `fields` begins at proc field 3; kernel starttime is field 22.
        return int(fields[19]) if fields is not None else None
    except (IndexError, ValueError):
        return None


def _proc_name(pid: int) -> str | None:
    try:
        return pathlib.Path(f"/proc/{pid}/comm").read_text(encoding="utf-8").strip()
    except (FileNotFoundError, OSError):
        return None


def _proc_ancestors(pid: int) -> list[int]:
    ancestors: list[int] = []
    seen: set[int] = set()
    current = _proc_parent(pid)
    while current is not None and current not in seen and len(ancestors) < 64:
        ancestors.append(current)
        seen.add(current)
        current = _proc_parent(current)
    return ancestors


def _proc_effective_uid(pid: int) -> int | None:
    try:
        for line in pathlib.Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
            if line.startswith("Uid:"):
                values = line.split()[1:]
                return int(values[1]) if len(values) >= 2 else None
    except (FileNotFoundError, OSError, ValueError):
        pass
    return None


def _owning_unprivileged_sshd(pid: int) -> int:
    """Resolve only the same-UID sshd child that owns one tmux client."""
    probe_chain = {os.getpid(), *_proc_ancestors(os.getpid())}
    for ancestor in _proc_ancestors(pid):
        if ancestor in probe_chain:
            raise RuntimeError("refusing to terminate the fixture probe transport")
        name = _proc_name(ancestor)
        if name not in ("sshd", "sshd-session"):
            continue
        if _proc_effective_uid(ancestor) != os.geteuid():
            raise RuntimeError("refusing to terminate a privileged sshd process")
        return ancestor
    raise RuntimeError("tmux control client has no same-UID sshd transport ancestor")


def command_tmux_isolation_session(args: argparse.Namespace) -> int:
    """Create the W1 / W2 / P2b tmux topology used by the live isolation gate."""
    if not _ISOLATION_SESSION.fullmatch(args.session):
        raise ValueError("isolation session must use 1-80 ASCII letters, digits, dot, underscore, or dash")
    _isolation_marker("W1", args.token)
    if args.count <= 0 or args.hold_seconds <= 0:
        raise ValueError("isolation marker count and hold duration must be positive")
    if args.heartbeat_seconds < 0:
        raise ValueError("isolation heartbeat interval cannot be negative")
    if args.columns < 20 or args.rows < 8:
        raise ValueError("isolation session geometry is too small")

    probe = pathlib.Path(sys.argv[0]).resolve()

    def pane_command(owner: str) -> list[str]:
        return [
            sys.executable,
            str(probe),
            "tmux-isolation-stream",
            "--owner", owner,
            f"--token={args.token}",
            "--count", str(args.count),
            "--hold-seconds", str(args.hold_seconds),
            "--heartbeat-seconds", str(args.heartbeat_seconds),
        ]

    # Python invokes tmux with argv. tmux later uses its normal pane-command
    # shell, so every dynamic value that reaches it is token-validated first.
    subprocess.run(("tmux", "kill-session", "-t", args.session),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    subprocess.run(
        ("tmux", "new-session", "-d", "-x", str(args.columns), "-y", str(args.rows),
         "-s", args.session, "-n", "W1", *pane_command("W1")),
        check=True,
    )
    try:
        subprocess.run(("tmux", "set-option", "-t", args.session, "remain-on-exit", "on"), check=True)
        subprocess.run(
            ("tmux", "new-window", "-d", "-t", args.session, "-n", "W2", *pane_command("W2")),
            check=True,
        )
        window_two_id, window_two_pane = _tmux_command(
            "display-message", "-p", "-t", f"{args.session}:W2", "#{window_id}\t#{pane_id}",
        ).split("\t", 1)
        pane_two_b = _tmux_command(
            "split-window", "-P", "-F", "#{pane_id}", "-d", "-h", "-t", f"{args.session}:W2",
            *pane_command("P2b"),
        )
        # `split-window -d` keeps the current client elsewhere, but a detached
        # session has no client whose active-pane choice can carry that intent.
        # Pin W2 back to its original pane so every platform gate starts from
        # the topology it asserts: W2 active, P2b present but inactive.
        subprocess.run(("tmux", "select-pane", "-t", window_two_pane), check=True)
        subprocess.run(("tmux", "select-window", "-t", f"{args.session}:W2"), check=True)

        def target(window: str) -> dict[str, str]:
            output = _tmux_command("display-message", "-p", "-t", f"{args.session}:{window}", "#{window_id}\t#{pane_id}")
            window_id, pane_id = output.split("\t", 1)
            return {"window_id": window_id, "pane_id": pane_id}

        topology = {
            "W1": target("W1"),
            "W2": {"window_id": window_two_id, "pane_id": window_two_pane},
            "P2b": {"window_id": window_two_id, "pane_id": pane_two_b},
        }
    except BaseException:
        subprocess.run(("tmux", "kill-session", "-t", args.session),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        raise

    print(json.dumps({
        "marker": "TESSERA_TMUX_ISOLATION_FIXTURE_V1",
        "session": args.session,
        "token": args.token,
        "markers": {owner: _isolation_marker(owner, args.token) for owner in _ISOLATION_OWNERS},
        "topology": topology,
    }, sort_keys=True), flush=True)
    return 0


def command_tmux_isolation_drop_transport(args: argparse.Namespace) -> int:
    """Terminate only the SSH transport carrying the fixture's `tmux -CC` client.

    Killing the tmux client itself reports an authenticated remote exit, which
    correctly terminates a product session instead of exercising reconnect.
    Killing its same-UID sshd child with SIGKILL produces transport EOF without
    an exit status while leaving the detached tmux server and every pane alive.
    Exact session selection plus an exactly-one control-client preflight keeps
    concurrent fixture runs isolated.
    """
    if not _ISOLATION_SESSION.fullmatch(args.session):
        raise ValueError("isolation session must use 1-80 ASCII letters, digits, dot, underscore, or dash")

    output = _tmux_command(
        "list-clients", "-t", args.session,
        "-F", "#{client_pid}\t#{client_control_mode}",
    )
    control_pids: list[int] = []
    for row in output.splitlines():
        fields = row.split("\t")
        if len(fields) != 2 or fields[1] != "1" or not fields[0].isdigit():
            continue
        pid = int(fields[0])
        if pid > 1:
            control_pids.append(pid)
    if len(control_pids) != 1:
        raise RuntimeError(
            "isolation fixture requires exactly one attached tmux control client; "
            f"found {len(control_pids)}"
        )

    # Resolve through /proc rather than matching an sshd command line. The
    # closest same-UID sshd ancestor owns this exact client; the privileged
    # monitor and this probe's separate control connection are refused.
    control_pid = control_pids[0]
    fixture_uid = os.geteuid()
    if fixture_uid == 0 or _proc_effective_uid(control_pid) != fixture_uid:
        raise RuntimeError("refusing a root-owned or foreign tmux control client")
    control_start = _proc_start_time(control_pid)
    if control_start is None:
        raise RuntimeError("tmux control client disappeared before transport resolution")
    transport_pid = _owning_unprivileged_sshd(control_pid)
    transport_start = _proc_start_time(transport_pid)
    if transport_start is None:
        raise RuntimeError("SSH transport disappeared before identity validation")

    # Re-prove both process identities and the ancestry at the destructive
    # edge. PIDs can be reused between list-clients and kill; a stale number is
    # never authority to signal a different process.
    if (_proc_start_time(control_pid) != control_start or
            _proc_effective_uid(control_pid) != fixture_uid or
            _proc_start_time(transport_pid) != transport_start or
            _proc_effective_uid(transport_pid) != fixture_uid or
            _proc_name(transport_pid) not in ("sshd", "sshd-session") or
            transport_pid not in _proc_ancestors(control_pid)):
        raise RuntimeError("tmux control transport identity changed before drop")
    os.kill(transport_pid, signal.SIGKILL)
    print(json.dumps({
        "marker": "TESSERA_TMUX_ISOLATION_TRANSPORT_DROPPED_V1",
        "session": args.session,
        "control_client_count": 1,
        "control_client_pid": control_pid,
        "transport_pid": transport_pid,
    }, sort_keys=True), flush=True)
    return 0


def command_tmux_isolation_cleanup(args: argparse.Namespace) -> int:
    """Remove exactly the generated isolation session, if it still exists."""
    if not _ISOLATION_SESSION.fullmatch(args.session):
        raise ValueError("isolation session must use 1-80 ASCII letters, digits, dot, underscore, or dash")
    result = subprocess.run(
        ("tmux", "kill-session", "-t", args.session),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError(f"failed to remove isolation session (exit {result.returncode})")
    print(json.dumps({
        "marker": "TESSERA_TMUX_ISOLATION_CLEANUP_V1",
        "session": args.session,
    }, sort_keys=True), flush=True)
    return 0


def command_tmux_isolation_assert(args: argparse.Namespace) -> int:
    """Assert a client-side surface dump contains one owner and no foreign owner."""
    expected = _isolation_marker(args.owner, args.token)
    if args.max_bytes <= 0:
        raise ValueError("isolation transcript limit must be positive")
    payload = sys.stdin.buffer.read(args.max_bytes + 1)
    if len(payload) > args.max_bytes:
        raise ValueError(f"isolation transcript exceeds {args.max_bytes} bytes")
    transcript = payload.decode("utf-8", errors="replace")
    counts = {
        owner: transcript.count(_isolation_marker(owner, args.token))
        for owner in _ISOLATION_OWNERS
    }
    if counts[args.owner] == 0:
        raise AssertionError(f"isolation transcript is missing bound owner marker {expected}")
    foreign = {owner: count for owner, count in counts.items() if owner != args.owner and count > 0}
    if foreign:
        raise AssertionError(f"isolation transcript contains foreign owner markers: {foreign}")
    print(json.dumps({
        "marker": "TESSERA_TMUX_ISOLATION_ASSERTION_V1",
        "owner": args.owner,
        "marker_count": counts[args.owner],
        "foreign_marker_count": 0,
    }, sort_keys=True), flush=True)
    return 0


class _EchoHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        payload = bytearray()
        self.request.settimeout(2.0)
        while b"\r\n\r\n" not in payload and len(payload) < 65536:
            chunk = self.request.recv(4096)
            if not chunk:
                break
            payload.extend(chunk)
        body = b"TESSERA_FORWARD_OK\n"
        response = (
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Type: text/plain\r\n"
            + f"Content-Length: {len(body)}\r\n".encode("ascii")
            + b"Connection: close\r\n\r\n"
            + body
        )
        self.request.sendall(response)


def command_echo_server(args: argparse.Namespace) -> int:
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True

    with Server((args.host, args.port), _EchoHandler) as server:
        print(f"TESSERA_ECHO_READY {args.host}:{args.port}", flush=True)
        server.serve_forever()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    identity = subparsers.add_parser("identity")
    identity.set_defaults(handler=command_identity)

    lines = subparsers.add_parser("lines")
    lines.add_argument("--count", type=int, default=400)
    lines.add_argument("--color", action="store_true")
    lines.set_defaults(handler=command_lines)

    capture = subparsers.add_parser("capture")
    capture.add_argument("--output", required=True)
    capture.add_argument("--bytes", type=int, default=4096)
    capture.add_argument("--timeout", type=float, default=5.0)
    capture.add_argument("--mouse", action="store_true")
    capture.add_argument("--bracketed-paste", action="store_true")
    capture.add_argument("--alt-screen", action="store_true")
    capture.add_argument("--expect-sha256")
    capture.set_defaults(handler=command_capture)

    scroll = subparsers.add_parser("scroll-scenario")
    scroll.add_argument("--label", required=True)
    scroll.add_argument("--trigger", required=True)
    scroll.add_argument("--count", type=int, default=600)
    scroll.add_argument("--delay", type=float, default=0.005)
    scroll.add_argument("--trigger-timeout", type=float, default=120.0)
    scroll.add_argument("--htop-seconds", type=float, default=90.0)
    scroll.add_argument("--vim-seconds", type=float, default=45.0)
    scroll.set_defaults(handler=command_scroll_scenario)

    redraw = subparsers.add_parser("tmux-redraw-burst")
    redraw.add_argument("--session", required=True)
    redraw.add_argument("--start-delay", type=float, default=0.4)
    redraw.add_argument("--frames", type=int, default=80)
    redraw.add_argument("--rows", type=int, default=50)
    redraw.add_argument("--frame-delay", type=float, default=0.005)
    redraw.set_defaults(handler=command_tmux_redraw_burst)

    isolation_stream = subparsers.add_parser("tmux-isolation-stream")
    isolation_stream.add_argument("--owner", choices=_ISOLATION_OWNERS, required=True)
    isolation_stream.add_argument("--token", required=True)
    isolation_stream.add_argument("--count", type=int, default=300)
    isolation_stream.add_argument("--hold-seconds", type=float, default=300.0)
    isolation_stream.add_argument("--heartbeat-seconds", type=float, default=0.0)
    isolation_stream.set_defaults(handler=command_tmux_isolation_stream)

    isolation_session = subparsers.add_parser("tmux-isolation-session")
    isolation_session.add_argument("--session", required=True)
    isolation_session.add_argument("--token", required=True)
    isolation_session.add_argument("--count", type=int, default=300)
    isolation_session.add_argument("--hold-seconds", type=float, default=300.0)
    isolation_session.add_argument("--heartbeat-seconds", type=float, default=0.0)
    isolation_session.add_argument("--columns", type=int, default=160)
    isolation_session.add_argument("--rows", type=int, default=50)
    isolation_session.set_defaults(handler=command_tmux_isolation_session)

    isolation_assert = subparsers.add_parser("tmux-isolation-assert")
    isolation_assert.add_argument("--owner", choices=_ISOLATION_OWNERS, required=True)
    isolation_assert.add_argument("--token", required=True)
    isolation_assert.add_argument("--max-bytes", type=int, default=2 * 1024 * 1024)
    isolation_assert.set_defaults(handler=command_tmux_isolation_assert)

    isolation_drop_transport = subparsers.add_parser("tmux-isolation-drop-transport")
    isolation_drop_transport.add_argument("--session", required=True)
    isolation_drop_transport.set_defaults(handler=command_tmux_isolation_drop_transport)

    isolation_cleanup = subparsers.add_parser("tmux-isolation-cleanup")
    isolation_cleanup.add_argument("--session", required=True)
    isolation_cleanup.set_defaults(handler=command_tmux_isolation_cleanup)

    echo_server = subparsers.add_parser("echo-server")
    echo_server.add_argument("--host", default="127.0.0.1")
    echo_server.add_argument("--port", type=int, default=18080)
    echo_server.set_defaults(handler=command_echo_server)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
