#!/usr/bin/env python3
"""Deterministic remote PTY oracle used only by Tessera integration tests."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import select
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
