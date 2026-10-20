#!/usr/bin/env python3
"""Real-tmux half of the tmux semantics model differential.

Runs ONLY on a disposable VPS fixture, through
scripts/integration/run-tmux-model-differential.sh, which embeds the scenario
plan below and pipes this file to `python3 - --disposable-fixture` over SSH.
Never run it on a user host.

Every scenario gets its own tmux server on an exact socket inside a private
mkdtemp directory (`tmux -S DIR/tmux.sock -f /dev/null`), so nothing touches
the account's default server, sessions or configuration. Clients are real
tmux processes: control clients over pipes (`tmux -C attach-session`) and
terminal clients on a pseudo-terminal. After the last step every client is
killed, the server is killed and its directory removed; the result records
whether that cleanup was verified.

`--check-plan` only decodes and checks the embedded plan, and
`--stub-tmux PATH` runs the plan against scripts/integration/tmux-model-stub-tmux.py
(it refuses any binary whose -V is not `tmux-model-stub`). Neither starts tmux
or contacts anything, so the dry run executes both locally.

Output (stdout, JSON): {"format": 1, "run_id", "host", "runs": [{"tmux",
"version", "scenarios": [{"name", "source", "status", "ids", "clients",
"steps": [{"index", "kind", "start", "read", "lines": {label: [...]}}],
"stderr", "cleanup"}]}]}. Step times are seconds from the scenario's first
action, the timeline the model replays.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import os
import pty
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tarfile
import tempfile
import termios
import threading
import time
import urllib.request

PLAN = "__PLAN_BASE64__"
PANE_COMMAND = "stty -echo; exec cat >/dev/null"
RELEASE_URL = "https://github.com/tmux/tmux/releases/download/{0}/tmux-{0}.tar.gz"
ATTACH_TIMEOUT = 5.0


def log(message):
    print(f"[tmux-model-runner] {message}", file=sys.stderr, flush=True)


def load_plan():
    if PLAN.startswith("__"):
        raise SystemExit("no plan embedded; build the payload with tmux-model-differential.py prepare")
    plan = json.loads(base64.b64decode(PLAN))
    if plan.get("format") != 1 or not plan.get("scenarios"):
        raise SystemExit("unsupported or empty plan")
    for scenario in plan["scenarios"]:
        labels, sessions = set(), set()
        for step in scenario["setup"]:
            if step["kind"] not in ("session", "window", "group"):
                raise SystemExit(f"{scenario['name']}: bad setup step {step}")
            sessions.add(step.get("name") or step.get("session"))
        for step in scenario["actions"]:
            kind = step["kind"]
            if kind in ("control", "tty"):
                if step["session"] not in sessions or step["client"] in labels:
                    raise SystemExit(f"{scenario['name']}: bad client step {step}")
                labels.add(step["client"])
            elif kind in ("send", "key", "resize", "detach"):
                if step["client"] not in labels:
                    raise SystemExit(f"{scenario['name']}: unknown client in {step}")
            elif kind != "advance":
                raise SystemExit(f"{scenario['name']}: bad action {step}")
    return plan


class ControlClient:
    """`tmux -C attach-session` on pipes; reader threads collect stdout lines
    (taken at each step's read time) and stderr."""

    def __init__(self, base, env, session_target, flags):
        command = base + ["-C", "attach-session", "-t", session_target]
        if flags:
            command += ["-f", ",".join(flags)]
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env, start_new_session=True)
        self.name = f"client-{self.process.pid}"
        self.lines, self.errors, self.lock = [], [], threading.Lock()
        self.threads = [threading.Thread(target=self._read, args=(self.process.stdout, self.lines), daemon=True),
                        threading.Thread(target=self._read, args=(self.process.stderr, self.errors), daemon=True)]
        for thread in self.threads:
            thread.start()

    def _read(self, stream, target):
        for raw in iter(stream.readline, b""):
            with self.lock:
                target.append(raw.decode("utf-8", "replace").rstrip("\n"))

    def send(self, line):
        self.process.stdin.write(line.encode() + b"\n")
        self.process.stdin.flush()

    def take(self):
        with self.lock:
            lines, self.lines[:] = list(self.lines), []
        return lines

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        try:
            self.process.stdin.close()
        except OSError:
            pass


class TerminalClient:
    """`tmux attach-session` on a pseudo-terminal of the requested size. The
    master is drained continuously so tmux never blocks on output."""

    def __init__(self, base, env, session_target, flags, size):
        self.master, slave = pty.openpty()
        self._winsize(slave, size)
        self.name = os.ttyname(slave)
        command = base + ["attach-session", "-t", session_target]
        if flags:
            command += ["-f", ",".join(flags)]
        self.process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave, env=env,
                                        start_new_session=True)
        os.close(slave)
        self.received, self.head = 0, bytearray()
        self.thread = threading.Thread(target=self._drain, args=(self.master,), daemon=True)
        self.thread.start()

    @staticmethod
    def _winsize(fd, size):
        columns, rows = size
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def _drain(self, fd):
        # Ends with EIO once the client and the server have closed the slave.
        while True:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            self.received += len(data)
            if len(self.head) < 4096:
                self.head += data[:4096 - len(self.head)]

    def key(self):
        os.write(self.master, b"x")

    def resize(self, size):
        # No controlling terminal, so the kernel signals nobody: SIGWINCH
        # makes the client send MSG_RESIZE (client.c), exactly once.
        self._winsize(self.master, size)
        os.kill(self.process.pid, signal.SIGWINCH)

    def kill(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        if self.master is not None:
            # Close once: a second close could hit a reused descriptor.
            self.thread.join(timeout=2)
            os.close(self.master)
            self.master = None


def pid_exists(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def substitute(text, ids):
    for key, value in ids.items():
        text = text.replace("{" + key + "}", value)
    return text


def run_scenario(tmux, scenario, plan):
    work = tempfile.mkdtemp(prefix=f"tessera-tmux-model-{plan['run_id']}-")
    sock = os.path.join(work, "tmux.sock")
    env = {key: value for key, value in os.environ.items() if key not in ("TMUX", "TMUX_PANE")}
    env.update(TERM="xterm-256color", TMUX_TMPDIR=work, LANG="C.UTF-8", SHELL="/bin/sh")
    base = [tmux, "-S", sock, "-f", "/dev/null"]
    settle = plan["settle"]
    result = {"name": scenario["name"], "source": scenario["source"], "status": "ok", "ids": {}, "clients": {},
              "steps": [], "stderr": {}, "cleanup": "pending"}
    clients, controls = {}, []

    def tmux_cmd(*args):
        completed = subprocess.run(base + list(args), env=env, capture_output=True, text=True, timeout=10)
        if completed.returncode != 0:
            raise RuntimeError(f"tmux {' '.join(args)}: {completed.stderr.strip()}")
        return completed.stdout.strip()

    try:
        ids = result["ids"]
        for step in scenario["setup"]:
            if step["kind"] == "session":
                columns, rows = step["size"]
                out = tmux_cmd("new-session", "-d", "-s", step["name"], "-x", str(columns), "-y", str(rows),
                               "-n", step["window"], "-P", "-F", "#{session_id} #{window_id} #{pane_id}", PANE_COMMAND)
                ids[step["name"]], ids[step["window"]], ids["pane:" + step["window"]] = out.split()
            elif step["kind"] == "window":
                out = tmux_cmd("new-window", "-d", "-t", "=" + step["session"] + ":", "-n", step["label"],
                               "-P", "-F", "#{window_id} #{pane_id}", PANE_COMMAND)
                ids[step["label"]], ids["pane:" + step["label"]] = out.split()
            elif step["kind"] == "group":
                # No command: with -t, cmd-new-session.c refuses "command or
                # window name given with target"; the window it spawns is
                # replaced by the group's windows at once.
                ids[step["name"]] = tmux_cmd("new-session", "-d", "-s", step["name"], "-t", step["target"],
                                             "-P", "-F", "#{session_id}")
        t0 = None
        for step in scenario["actions"]:
            kind = step["kind"]
            now = time.monotonic()
            if t0 is None:
                t0 = now
            start = now - t0
            if kind == "control":
                client = ControlClient(base, env, "=" + step["session"], step.get("flags", []))
                clients[step["client"]] = client
                controls.append(step["client"])
                result["clients"][step["client"]] = client.name
            elif kind == "tty":
                client = TerminalClient(base, env, "=" + step["session"], step.get("flags", []), step["size"])
                clients[step["client"]] = client
                result["clients"][step["client"]] = client.name
            elif kind == "send":
                clients[step["client"]].send(substitute(step["command"], ids))
            elif kind == "key":
                clients[step["client"]].key()
            elif kind == "resize":
                clients[step["client"]].resize(step["size"])
            elif kind == "detach":
                clients[step["client"]].kill()
            pause = step.get("seconds", 0) + settle
            deadline = t0 + start + pause
            time.sleep(max(0.0, deadline - time.monotonic()))
            read = time.monotonic() - t0
            lines = {label: clients[label].take() for label in controls}
            result["steps"].append({"index": step["index"], "kind": kind, "start": round(start, 6),
                                    "read": round(read, 6), "lines": lines})
        exited = [label for label, client in clients.items()
                  if client.process.poll() is not None and not any(
                      s["kind"] == "detach" and s["client"] == label for s in scenario["actions"])]
        if exited:
            details = [f"{label} ({bytes(clients[label].head[-300:])!r})" if isinstance(clients[label], TerminalClient)
                       else label for label in exited]
            result["status"] = f"error: clients exited early: {', '.join(details)}"
    except Exception as error:  # recorded, then the next scenario runs
        result["status"] = f"error: {type(error).__name__}: {error}"
    finally:
        for label, client in clients.items():
            try:
                client.kill()
            except Exception as error:
                result["status"] = f"error: could not kill {label}: {error}"
        # The exact processes this scenario owns: its server and pane commands.
        listing = subprocess.run(base + ["list-panes", "-a", "-F", "#{pid} #{pane_pid}"], env=env,
                                 capture_output=True, text=True, timeout=10)
        owned = sorted({int(word) for word in listing.stdout.split()}) if listing.returncode == 0 else []
        subprocess.run(base + ["kill-server"], env=env, capture_output=True, timeout=10)
        alive = subprocess.run(base + ["has-session"], env=env, capture_output=True, timeout=10).returncode == 0
        deadline = time.monotonic() + 5
        while any(pid_exists(pid) for pid in owned) and time.monotonic() < deadline:
            time.sleep(0.05)
        survivors = [pid for pid in owned if pid_exists(pid)]
        for pid in survivors:
            os.kill(pid, signal.SIGKILL)
        result["owned_pids"] = owned
        for label, client in clients.items():
            if isinstance(client, ControlClient):
                # The server held the pipes' far ends; they close with it.
                for thread in client.threads:
                    thread.join(timeout=2)
                result["stderr"][label] = client.errors
        shutil.rmtree(work, ignore_errors=True)
        verified = not alive and not survivors and owned and not os.path.exists(work)
        result["cleanup"] = "verified" if verified else f"FAILED (server alive {alive}, survivors {survivors})"
        if result["cleanup"] != "verified":
            result["status"] = "error: cleanup failed"
    return result


def build_release(version, expected_sha, root):
    """Builds an upstream release tarball inside the run's private build
    directory. Requires a compiler, make, pkg-config, yacc and the libevent and
    ncurses headers on the fixture; nothing is installed."""
    target = os.path.join(root, f"tmux-{version}")
    archive = target + ".tar.gz"
    with urllib.request.urlopen(RELEASE_URL.format(version), timeout=60) as response, open(archive, "wb") as handle:
        shutil.copyfileobj(response, handle)
    with open(archive, "rb") as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    if expected_sha and digest != expected_sha:
        raise SystemExit(f"tmux {version}: sha256 {digest} does not match {expected_sha}")
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            path = os.path.realpath(os.path.join(root, member.name))
            if not path.startswith(os.path.realpath(root) + os.sep) or member.issym() or member.islnk():
                raise SystemExit(f"tmux {version}: unexpected archive member {member.name}")
        if hasattr(tarfile, "data_filter"):
            bundle.extractall(root, filter="data")
        else:
            bundle.extractall(root)
    logfile = os.path.join(root, f"build-{version}.log")
    with open(logfile, "w") as handle:
        for command in (["./configure"], ["make", f"-j{os.cpu_count() or 2}"]):
            if subprocess.run(command, cwd=target, stdout=handle, stderr=subprocess.STDOUT).returncode != 0:
                with open(logfile) as reader:
                    tail = reader.read()[-3000:]
                raise SystemExit(f"tmux {version}: {' '.join(command)} failed\n{tail}")
    return os.path.join(target, "tmux"), digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--disposable-fixture", action="store_true")
    parser.add_argument("--check-plan", action="store_true", help="decode and check the plan, then exit")
    parser.add_argument("--tmux", action="append", default=[], help="a tmux binary to test (repeatable)")
    parser.add_argument("--build", action="append", default=[], metavar="VERSION[:SHA256]",
                        help="build an upstream release in the run's private directory (repeatable)")
    parser.add_argument("--no-system", action="store_true", help="skip the tmux on PATH")
    parser.add_argument("--scenario", action="append", default=[], help="run only these scenarios")
    parser.add_argument("--stub-tmux", metavar="PATH", help="dry run against the stub tmux only")
    parser.add_argument("--settle", type=float, help="override the plan's settle (stub runs only)")
    args = parser.parse_args()
    plan = load_plan()
    if args.check_plan:
        actions = sum(len(scenario["actions"]) for scenario in plan["scenarios"])
        print(json.dumps({"check": "ok", "scenarios": len(plan["scenarios"]), "actions": actions}))
        return
    if args.stub_tmux:
        if args.tmux or args.build or args.disposable_fixture:
            raise SystemExit("--stub-tmux excludes --tmux, --build and --disposable-fixture")
        stub_version = subprocess.run([args.stub_tmux, "-V"], capture_output=True, text=True, timeout=10).stdout.strip()
        if stub_version != "tmux-model-stub":
            raise SystemExit(f"--stub-tmux {args.stub_tmux} is not the stub ({stub_version!r})")
        args.no_system, args.tmux = True, [args.stub_tmux]
        if args.settle is not None:
            plan["settle"] = args.settle
    elif args.settle is not None:
        raise SystemExit("--settle is only for stub runs; the plan carries the live settle")
    elif not args.disposable_fixture:
        raise SystemExit("refusing to run without --disposable-fixture")
    for signum in (signal.SIGHUP, signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda number, frame: sys.exit(128 + number))
    scenarios = [s for s in plan["scenarios"] if not args.scenario or s["name"] in args.scenario]
    build_root = tempfile.mkdtemp(prefix=f"tessera-tmux-model-build-{plan['run_id']}-") if args.build else None
    output = {"format": 1, "run_id": plan["run_id"], "host": socket.gethostname(), "runs": []}
    try:
        binaries = [] if args.no_system or not shutil.which("tmux") else [(shutil.which("tmux"), None)]
        binaries += [(path, None) for path in args.tmux]
        for spec in args.build:
            version, _, sha = spec.partition(":")
            log(f"building tmux {version}")
            binaries.append(build_release(version, sha or None, build_root))
        if not binaries:
            raise SystemExit("no tmux to test")
        for binary, digest in binaries:
            version = subprocess.run([binary, "-V"], capture_output=True, text=True, timeout=10).stdout.strip()
            log(f"{binary}: {version}")
            run = {"tmux": binary, "version": version, "tarball_sha256": digest, "scenarios": []}
            for scenario in scenarios:
                log(f"  {scenario['name']}")
                run["scenarios"].append(run_scenario(binary, scenario, plan))
            output["runs"].append(run)
    finally:
        if build_root:
            shutil.rmtree(build_root, ignore_errors=True)
    json.dump(output, sys.stdout, indent=2)
    sys.stdout.write("\n")
    failed = [f"{run['version']} {s['name']}: {s['status']}" for run in output["runs"] for s in run["scenarios"]
              if s["status"] != "ok"]
    for line in failed:
        log(line)
    if failed:
        sys.exit(2)


if __name__ == "__main__":
    main()
