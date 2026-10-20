#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || {
  printf 'usage: run-agent-integration-script-tests.sh RUN_DIR [--hook-deferral-only]\n' >&2
  exit 2
}

WORK_DIR="$(mktemp -d "$RUN_DIR/agent-integration-scripts.XXXXXX")"
DUMPER="$WORK_DIR/dump-agent-integration"
MODULE_CACHE="$WORK_DIR/module-cache"
sh "$HERE/build-agent-integration-dumper.sh" "$DUMPER" "$MODULE_CACHE"

# Syntax-check every generated executable and both supported interactive-shell
# source paths before exercising their behavior.
for source_name in hook launcher projector semantic-launcher process-proof codex-readiness codex-recovery claude-shim codex-shim; do
  "$DUMPER" "$source_name" | /bin/sh -n
done
"$DUMPER" shell | /bin/bash -n
"$DUMPER" shell | /bin/zsh -n


# Background companions inherit a pane but must preserve its live foreground
# holder. Use real PTYs so both shell and Python OSC writes are observable.
DEFERRAL_DIR="$WORK_DIR/hook-deferral"
mkdir -p "$DEFERRAL_DIR/bin"
"$DUMPER" hook >"$DEFERRAL_DIR/agent-lifecycle-hook.sh"
"$DUMPER" process-proof >"$DEFERRAL_DIR/process-proof.sh"
cat >"$DEFERRAL_DIR/bin/ps" <<'SH'
#!/bin/sh
if [ -n "$TESSERA_TEST_PROOF_PID" ]; then
  case "$*" in
    "-o ppid= -p $TESSERA_TEST_PROOF_PID") printf '%s\n' "$TESSERA_TEST_PROOF_ROOT" ;;
    "-o comm= -o args= -p $TESSERA_TEST_PROOF_PID") printf 'claude /opt/bin/claude\n' ;;
    "-o lstart= -p $TESSERA_TEST_PROOF_PID") printf 'Mon Oct 12 12:34:56 2026\n' ;;
    "-o pgid= -o tpgid= -p $TESSERA_TEST_PROOF_PID")
      [ "$TESSERA_TEST_PROOF_GROUPS" != unknown ] || exit 1
      printf '%s\n' "$TESSERA_TEST_PROOF_GROUPS"
      ;;
    *) exit 1 ;;
  esac
  exit
fi
if [ -n "$TESSERA_TEST_RESOLVED_PID" ] && [ "$4" != "$TESSERA_TEST_RESOLVED_PID" ]; then
  case "$2" in
    comm=) printf 'sh\n'; exit ;;
    args=) printf '/bin/sh\n'; exit ;;
    ppid=) printf '%s\n' "$TESSERA_TEST_RESOLVED_PID"; exit ;;
  esac
fi
case "$2" in
  comm=) printf '%s\n' "$TESSERA_TEST_PROVIDER" ;;
  args=) printf '/opt/bin/%s\n' "$TESSERA_TEST_PROVIDER" ;;
  tty=) printf '%s\n' "${TESSERA_TEST_TERMINAL#/dev/}" ;;
  stat=)
    printf '%s\n' "$4" >>"$TESSERA_TEST_PS_LOG"
    if [ "$4" = "$TESSERA_TEST_AGENT_PID" ]; then
      [ "$TESSERA_TEST_AGENT_STAT" != unknown ] || exit 1
      printf '%s\n' "$TESSERA_TEST_AGENT_STAT"
    else
      [ "$TESSERA_TEST_HOLDER_STAT" != unknown ] || exit 1
      printf '%s\n' "$TESSERA_TEST_HOLDER_STAT"
    fi
    ;;
  *) exit 1 ;;
esac
SH
cat >"$DEFERRAL_DIR/bin/tmux" <<'SH'
#!/bin/sh
printf '%s\n' "$1" >>"$TESSERA_TEST_TMUX_LOG"
case "$1" in
  show-options)
    retained="$(cat "$TESSERA_TEST_PANE_STATE")"
    if [ -n "$TESSERA_TEST_READ_BARRIER" ]; then
      touch "$TESSERA_TEST_READ_BARRIER"
      while [ ! -f "$TESSERA_TEST_RELEASE_BARRIER" ]; do sleep 0.01; done
    fi
    printf '%s\n' "$retained"
    ;;
  display-message)
    if [ "$5" = '#{pid}:#{socket_path}' ]; then
      printf '%s\n' "$TESSERA_TEST_SERVER"
    else
      printf '%s\n' "$TESSERA_TEST_TERMINAL"
    fi
    ;;
  set-option)
    printf '%s\n' "$6" >"$TESSERA_TEST_PUBLISHED"
    printf '%s\n' "$6" >"$TESSERA_TEST_PANE_STATE"
    ;;
  *) exit 1 ;;
esac
SH
cat >"$DEFERRAL_DIR/agent-codex-recover.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$TESSERA_TEST_RECOVERY_LOG"
case "$1" in
  --verify-observation) printf '%s\n' "$TESSERA_TEST_AGENT_PID" ;;
esac
SH
cat >"$DEFERRAL_DIR/bin/python3" <<'SH'
#!/bin/sh
case "$2" in
  "import base64,json,os,re,stat"*)
    exec "$TESSERA_TEST_PYTHON" -c 'import os,sys
original=os.lstat
def listed(path,*args,**kwargs):
 try: return original(path,*args,**kwargs)
 finally:
  marker=os.environ.get("TESSERA_TEST_INDEX_READ","")
  if marker and str(path).endswith("/session_index.jsonl"):
   with open(marker,"a") as output: output.write("read\n")
os.lstat=listed
exec(sys.argv[1])' "$2"
    ;;
  *) exec "$TESSERA_TEST_PYTHON" "$@" ;;
esac
SH
chmod 700 "$DEFERRAL_DIR/agent-lifecycle-hook.sh" "$DEFERRAL_DIR/agent-codex-recover.sh" "$DEFERRAL_DIR/bin/ps" "$DEFERRAL_DIR/bin/tmux"
chmod 700 "$DEFERRAL_DIR/bin/python3"
python3 - "$DEFERRAL_DIR" <<'PY'
import base64, builtins, contextlib, fcntl, hashlib, io, json, os, pathlib, select, stat, subprocess, sys, time
from unittest import mock
root = pathlib.Path(sys.argv[1])
agent = os.getpid()
holder = 99999999
cases = [
    # name, provider, proc/ps, agent status, holder state/status, deferred
    ("linux-held", "claude", "proc", "background", "foreground", True),
    ("linux-exited", "claude", "proc", "background", "exited", False),
    ("linux-empty", "claude", "proc", "background", "empty", False),
    ("linux-foreground", "claude", "proc", "foreground", "foreground", False),
    ("unknown", "claude", "ps", "unknown", "foreground", False),
    ("codex-held", "codex", "proc", "background", "foreground", True),
    ("codex-observer-held", "codex", "proc", "background", "foreground", True),
    ("codex-foreground", "codex", "proc", "foreground", "foreground", False),
    ("bsd-held", "claude", "ps", "background", "foreground", True),
    ("bsd-foreground", "claude", "ps", "foreground", "foreground", False),
    ("bsd-exited", "claude", "ps", "background", "exited", False),
    ("linux-background-holder", "claude", "proc", "background", "background", False),
    ("linux-same-holder", "claude", "proc", "background", "same", False),
    ("linux-unparseable", "claude", "proc", "background", "unparseable", False),
    ("linux-null-holder", "claude", "proc", "background", "null", False),
    ("linux-no-terminal-group", "claude", "proc", "no-tty", "foreground", True),
    ("raw-background", "claude", "proc", "background", "foreground", False),
]
for name, provider, source, status, retained, deferred in cases:
    home = root / name
    home.mkdir()
    proc = home / "proc"
    proc.mkdir()
    def write_stat(pid, foreground):
        directory = proc / str(pid)
        directory.mkdir()
        # The last ') ' matters: comm contains spaces, parens, and an earlier ') '.
        tpgid = 42 if foreground else (-1 if status == "no-tty" and pid == agent else 43)
        (directory / "stat").write_text(f"{pid} (agent ) name (nested)) S 1 42 42 1 {tpgid} 0\n")
    if source == "proc":
        write_stat(agent, status == "foreground")
        if retained in ("foreground", "background"):
            write_stat(holder, retained == "foreground")
    state = ("" if retained == "empty" else "not-json" if retained == "unparseable" else
             '{"agentPid":null}' if retained == "null" else
             json.dumps({"agentPid": agent if retained == "same" else holder}, separators=(",", ":")))
    state_path = home / "pane-state"
    state_path.write_text(state)
    master, slave = os.openpty()
    try:
        env = dict(os.environ, HOME=str(home), PATH=str(root / "bin") + ":" + os.environ["PATH"],
                   TMUX_PANE="%42", TESSERA_AGENT_PROC_ROOT=str(proc),
                   TESSERA_TEST_PROVIDER=provider, TESSERA_TEST_AGENT_PID=str(agent),
                   TESSERA_TEST_RESOLVED_PID="", TESSERA_TEST_READ_BARRIER="", TESSERA_TEST_RELEASE_BARRIER="",
                   TESSERA_TEST_SERVER="1234:/tmp/tessera-script-tests.sock",
                   TESSERA_TEST_PYTHON=sys.executable, TESSERA_TEST_INDEX_READ="",
                   TESSERA_TEST_AGENT_STAT={"background": "S", "foreground": "S+"}.get(status, "unknown"),
                   TESSERA_TEST_HOLDER_STAT={"foreground": "S+", "background": "S"}.get(retained, "unknown"),
                   TESSERA_TEST_TERMINAL=os.ttyname(slave), TESSERA_TEST_PANE_STATE=str(state_path),
                   TESSERA_TEST_TMUX_LOG=str(home / "tmux-log"), TESSERA_TEST_PS_LOG=str(home / "ps-log"),
                   TESSERA_TEST_PUBLISHED=str(home / "published"), TESSERA_TEST_RECOVERY_LOG=str(home / "recovery-log"))
        for key in ("TESSERA_AGENT_OBSERVER", "TESSERA_AGENT_OBSERVED_TIMESTAMP_NS", "TESSERA_AGENT_VERIFIED_PROVIDER_PID"):
            env.pop(key, None)
        if name == "codex-observer-held":
            env["TESSERA_AGENT_OBSERVER"] = "1"
        if name == "raw-background":
            env.pop("TMUX_PANE", None)
            env.pop("TMUX", None)
        result = subprocess.run(["/bin/sh", str(root / "agent-lifecycle-hook.sh"), provider,
                                 "SessionStart", "idle", "session-start"],
                                input=json.dumps({"session_id": "deferral-test", "transcript_path": "/tmp/deferral-test"}).encode(),
                                env=env, stdout=slave, stderr=subprocess.PIPE, timeout=10)
        assert result.returncode == 0, (name, result.stderr)
        wire = b""
        while select.select([master], [], [], 0.1)[0]:
            wire += os.read(master, 65536)
        def contents(path):
            return path.read_text() if path.exists() else ""
        calls = contents(home / "tmux-log").splitlines()
        diagnostic = contents(home / ".config/tessera/agent-lifecycle-diagnostics.log").splitlines()[-1]
        expected = "deferred" if deferred else "written"
        tmux_expected = "not-applicable" if name == "raw-background" else expected
        assert f"tmuxState={tmux_expected} terminalEmission={expected}" in diagnostic, (name, diagnostic)
        assert ("set-option" in calls) == (not deferred and name != "raw-background"), (name, calls)
        assert (b"\x1b]1337;TesseraAgentState=" in wire) == (not deferred), (name, wire)
        if name == "raw-background":
            assert "show-options" not in calls, (name, calls)
        else:
            assert "show-options" in calls, (name, calls)
            locks = list((home / ".config/tessera/agent-runtime-state").glob("pane-*.delivery.lock"))
            assert len(locks) == 1 and stat.S_IMODE(locks[0].stat().st_mode) == 0o600, (name, locks)
        if source == "proc":
            ps_calls = contents(home / "ps-log").splitlines()
            assert str(agent) not in ps_calls, (name, ps_calls)
        if provider == "codex":
            runtime = json.loads((home / f".config/tessera/agent-runtime-state/{agent}.json").read_text())
            assert runtime["agentPid"] == agent and runtime["sessionId"] == "deferral-test", (name, runtime)
            recovery = contents(home / "recovery-log")
            if name != "codex-observer-held":
                assert f"--watch-root {agent}" in recovery, (name, recovery)
        print(f"hook deferral PASS: {name}")
    finally:
        os.close(master)
        os.close(slave)
print(f"hook deferral tests: {len(cases)} passed, 0 failed")

def fixture(name, provider="claude", pid=agent):
    home = root / name
    home.mkdir()
    proc = home / "proc"
    proc.mkdir()
    state_path = home / "pane-state"
    state_path.write_text("")
    env = dict(os.environ, HOME=str(home), PATH=str(root / "bin") + ":" + os.environ["PATH"],
               TMUX_PANE="%42", TESSERA_AGENT_PROC_ROOT=str(proc),
               TESSERA_TEST_PROVIDER=provider, TESSERA_TEST_AGENT_PID=str(pid),
               TESSERA_TEST_RESOLVED_PID=str(pid), TESSERA_TEST_AGENT_STAT="S+",
               TESSERA_TEST_HOLDER_STAT="S+", TESSERA_TEST_TERMINAL="",
               TESSERA_TEST_PANE_STATE=str(state_path), TESSERA_TEST_PUBLISHED=str(home / "published"),
               TESSERA_TEST_TMUX_LOG=str(home / "tmux-log"), TESSERA_TEST_PS_LOG=str(home / "ps-log"),
               TESSERA_TEST_RECOVERY_LOG=str(home / "recovery-log"), TESSERA_TEST_READ_BARRIER="",
               TESSERA_TEST_RELEASE_BARRIER="", TESSERA_TEST_SERVER="1234:/tmp/tessera-script-tests.sock",
               TESSERA_TEST_PYTHON=sys.executable, TESSERA_TEST_INDEX_READ="")
    for key in ("TESSERA_AGENT_OBSERVER", "TESSERA_AGENT_OBSERVED_TIMESTAMP_NS", "TESSERA_AGENT_VERIFIED_PROVIDER_PID"):
        env.pop(key, None)
    return home, env

def start_hook(env, slave, session_id, event="SessionStart", transcript="/tmp/script-test"):
    payload = {"session_id": session_id}
    if transcript is not None:
        payload["transcript_path"] = transcript
    process = subprocess.Popen(["/bin/sh", str(root / "agent-lifecycle-hook.sh"), env["TESSERA_TEST_PROVIDER"],
                                event, "idle", "session-start" if event == "SessionStart" else "session-ended"],
                               stdin=subprocess.PIPE, stdout=slave, stderr=subprocess.PIPE, env=env)
    process.stdin.write(json.dumps(payload).encode())
    process.stdin.close()
    process.stdin = None
    return process

def finish(process):
    _, error = process.communicate(timeout=10)
    assert process.returncode == 0, error

def drain(master):
    wire = b""
    while select.select([master], [], [], 0.05)[0]:
        wire += os.read(master, 65536)
    return wire

def await_file(path):
    deadline = time.monotonic() + 3
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert path.exists(), path

added = 0
for provider in ("claude", "codex", "kimi"):
    home, background = fixture("interleaving-" + provider, provider, 424201)
    foreground = dict(background, TESSERA_TEST_AGENT_PID="424202", TESSERA_TEST_RESOLVED_PID="424202",
                      TESSERA_TEST_TMUX_LOG=str(home / "foreground-log"),
                      TESSERA_TEST_PUBLISHED=str(home / "foreground-published"))
    for pid, pgid in ((424201, 42), (424202, 43)):
        directory = home / "proc" / str(pid)
        directory.mkdir()
        (directory / "stat").write_text(f"{pid} (nested ) agent) S 1 {pgid} {pgid} 1 43 0\n")
    read_barrier, release = home / "read", home / "release"
    background.update(TESSERA_TEST_READ_BARRIER=str(read_barrier), TESSERA_TEST_RELEASE_BARRIER=str(release))
    master, slave = os.openpty()
    background["TESSERA_TEST_TERMINAL"] = foreground["TESSERA_TEST_TERMINAL"] = os.ttyname(slave)
    c = b = None
    try:
        c = start_hook(background, slave, "background-c")
        await_file(read_barrier)
        b = start_hook(foreground, slave, "foreground-b")
        await_file(home / "foreground-log")
        time.sleep(0.1)
        assert not (home / "foreground-published").exists(), provider
        release.touch()
        finish(c)
        finish(b)
        retained = json.loads((home / "pane-state").read_text())
        assert retained["sessionId"] == "foreground-b" and retained["agentPid"] == 424202, retained
        print(f"pane publication PASS: barrier interleaving {provider}")
        added += 1
    finally:
        release.touch()
        for process in (c, b):
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
        os.close(master)
        os.close(slave)

for provider in ("claude", "codex", "kimi"):
    for future, minutes in ((False, 1), (True, 11)):
        home, env = fixture(f"retained-{provider}-{minutes}", provider)
        retained = {"agentPid": agent, "sessionId": "newer-b", "provider": provider,
                    "timestampNs": str(time.time_ns() + minutes * 60_000_000_000)}
        previous = json.dumps(retained)
        (home / "pane-state").write_text(previous)
        if provider == "codex":
            runtime = home / ".config/tessera/agent-runtime-state"
            runtime.mkdir(parents=True)
            (runtime / f"{agent}.json").write_text(previous)
        master, slave = os.openpty()
        env["TESSERA_TEST_TERMINAL"] = os.ttyname(slave)
        try:
            # A clock jump is proved by a frame that is not another
            # conversation's End, which identity alone already refuses.
            finish(start_hook(env, slave, "older-a", "Stop" if future else "SessionEnd"))
            wire = drain(master)
            assert b"\x1b]1337;TesseraAgentState=" in wire, (provider, wire)
            current = (home / "pane-state").read_text()
            if future:
                assert json.loads(current)["sessionId"] == "older-a", current
            else:
                assert current == previous, current
            if provider == "codex":
                claim = json.loads((runtime / f"{agent}.json").read_text())
                assert claim["sessionId"] == ("older-a" if future else "newer-b"), claim
            print(f"pane publication PASS: {provider} {'clock jump ignored' if future else 'late End retains Start'}")
            added += 1
        finally:
            os.close(master)
            os.close(slave)

# A process runs one root conversation at a time: an End of another one
# on the same process is a late hook of a replaced conversation (`/clear`
# ran End and Start hooks concurrently), whatever its timestamp. The
# current conversation's own End, another provider's or process's End,
# and a root End over a Codex child's state still publish. A Claude or
# Kimi subagent callback carries its root's session, so it is root state.
for provider in ("claude", "codex", "kimi"):
    for label, session, held_pid, held_agent, held_provider, replaced in (
            ("other conversation's newer End keeps the root", "older-a", agent, "", provider, False),
            ("own End publishes", "newer-b", agent, "", provider, True),
            ("another process's End publishes", "older-a", holder, "", provider, True),
            ("another provider's End publishes", "older-a", agent, "", "kimi" if provider == "claude" else "claude", True),
            ("subagent state of the root" if provider != "codex" else "child state takes the root's End",
             "older-a", agent, "child-1", provider, provider == "codex")):
        home, env = fixture(f"obsolete-end-{provider}-{added}", provider)
        retained = {"agentPid": held_pid, "sessionId": "newer-b", "provider": held_provider, "event": "PermissionRequest" if held_agent else "SessionStart",
                    "agentId": held_agent, "timestampNs": str(time.time_ns() - 60_000_000_000)}
        previous = json.dumps(retained)
        (home / "pane-state").write_text(previous)
        if provider == "codex":
            runtime = home / ".config/tessera/agent-runtime-state"
            runtime.mkdir(parents=True)
            (runtime / f"{agent}.json").write_text(previous)
        master, slave = os.openpty()
        env["TESSERA_TEST_TERMINAL"] = os.ttyname(slave)
        try:
            finish(start_hook(env, slave, session, "SessionEnd"))
            assert b"\x1b]1337;TesseraAgentState=" in drain(master), (provider, label)
            current = (home / "pane-state").read_text()
            if replaced:
                assert json.loads(current)["sessionId"] == session and json.loads(current)["event"] == "SessionEnd", (label, current)
            else:
                assert current == previous, (label, current)
            if provider == "codex":
                claim = json.loads((runtime / f"{agent}.json").read_text())
                assert claim["sessionId"] == (session if replaced else "newer-b"), (label, claim)
            print(f"pane publication PASS: {provider} {label}")
            added += 1
        finally:
            os.close(master)
            os.close(slave)

for different_server in (False, True):
    home, env = fixture("lock-server-" + str(different_server))
    runtime = home / ".config/tessera/agent-runtime-state"
    runtime.mkdir(parents=True)
    key = hashlib.sha256((env["TESSERA_TEST_SERVER"] + ":" + env["TMUX_PANE"]).encode()).hexdigest()
    with open(runtime / f"pane-{key}.delivery.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if different_server:
            env["TESSERA_TEST_SERVER"] = "5678:/tmp/another-tmux-server.sock"
        master, slave = os.openpty()
        env["TESSERA_TEST_TERMINAL"] = os.ttyname(slave)
        try:
            started = time.monotonic()
            finish(start_hook(env, slave, "lock-live"))
            elapsed = time.monotonic() - started
            diagnostic = (home / ".config/tessera/agent-lifecycle-diagnostics.log").read_text()
            assert ("paneLock=timeout" in diagnostic) == (not different_server), diagnostic
            assert elapsed < 5, elapsed
            assert b"\x1b]1337;TesseraAgentState=" in drain(master)
            assert json.loads((home / "pane-state").read_text())["sessionId"] == "lock-live"
            assert len(list(runtime.glob("pane-*.delivery.lock"))) == (2 if different_server else 1)
            print(f"pane publication PASS: {'server isolation' if different_server else 'bounded timeout publishes'}")
            added += 1
        finally:
            os.close(master)
            os.close(slave)

for name in ("missing", "empty", "missing-path", "unusable-ref", "directory", "usable", "duplicate", "symlink-file", "symlink-project"):
    home, env = fixture("claude-locator-" + name)
    config = home / "configured-claude"
    projects = config / "projects"
    project = projects / "another-project"
    project.mkdir(parents=True)
    source = project / "locator-id.jsonl"
    source.write_text("{}\n")
    env["CLAUDE_CONFIG_DIR"] = str(config)
    transcript = None if name == "missing" else "" if name == "empty" else str(home / "absent")
    expected = str(source)
    if name == "unusable-ref":
        transcript = "/" + "x" * 3070 + "é" + "x" * 30
    elif name == "directory":
        transcript = str(project)
    elif name == "usable":
        transcript = str(home / "supplied.jsonl")
        pathlib.Path(transcript).write_text("{}\n")
        expected = transcript
    elif name == "duplicate":
        second = projects / "second-project"
        second.mkdir()
        (second / source.name).write_text("{}\n")
        transcript = None
        expected = ""
    elif name in ("symlink-file", "symlink-project"):
        outside = home / "outside"
        outside.mkdir()
        other = outside / source.name
        other.write_text("{}\n")
        source.unlink()
        if name == "symlink-file":
            source.symlink_to(other)
        else:
            project.rmdir()
            project.symlink_to(outside, target_is_directory=True)
        transcript = None
        expected = ""
    master, slave = os.openpty()
    env["TESSERA_TEST_TERMINAL"] = os.ttyname(slave)
    try:
        finish(start_hook(env, slave, "locator-id", transcript=transcript))
        payload = json.loads((home / "pane-state").read_text())
        encoded = payload["transcriptRef"]
        actual = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode() if encoded else ""
        assert actual == expected, (name, actual, expected)
        print(f"locator recovery PASS: Claude {name}")
        added += 1
    finally:
        os.close(master)
        os.close(slave)

for delayed in (True, False):
    home, env = fixture("kimi-index-" + str(delayed), "kimi")
    config = home / "configured-kimi"
    wire = config / "sessions/locator-id/agents/main/wire.jsonl"
    wire.parent.mkdir(parents=True)
    wire.write_text("{}\n")
    index = config / "session_index.jsonl"
    marker = home / "index-read"
    env.update(KIMI_CODE_HOME=str(config), TESSERA_TEST_INDEX_READ=str(marker))
    master, slave = os.openpty()
    env["TESSERA_TEST_TERMINAL"] = os.ttyname(slave)
    try:
        process = start_hook(env, slave, "locator-id", "SessionStart" if delayed else "Stop", transcript=None)
        await_file(marker)
        if delayed:
            time.sleep(0.05)
            index.write_text(json.dumps({"sessionId": "locator-id", "sessionDir": str(wire.parents[2])}) + "\n")
        finish(process)
        payload = json.loads((home / "pane-state").read_text())
        encoded = payload["transcriptRef"]
        actual = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)).decode() if encoded else ""
        assert actual == (str(wire) if delayed else ""), payload
        assert len(marker.read_text().splitlines()) >= 2 if delayed else len(marker.read_text().splitlines()) == 1
        print(f"locator recovery PASS: Kimi {'delayed SessionStart index' if delayed else 'Stop reads once'}")
        added += 1
    finally:
        os.close(master)
        os.close(slave)
print(f"pane publication and locator tests: {added} passed, 0 failed")

# Execute the unmodified Python proof with only /proc redirected to fixtures.
# BSD cases read the same PATH ps double used by the hook tests.
proof = (root / "process-proof.sh").read_text().split("exec python3 -c '\n", 1)[1].rsplit("\n'\n", 1)[0]
real_open = builtins.open
proof_count = 0
for platform in ("linux", "bsd"):
    for status, groups, expected in (("foreground", "42 42", True), ("background", "42 43", False),
                                     ("no-tty", "42 -1", None), ("unknown", "unknown", None)):
        for require in (False, True):
            home, env = fixture(f"proof-{platform}-{status}-{require}")
            claimed, route = 424299, 424200
            env.update(TESSERA_TEST_PROOF_PID=str(claimed), TESSERA_TEST_PROOF_ROOT=str(route),
                       TESSERA_TEST_PROOF_GROUPS=groups)
            if platform == "linux":
                proc = home / "proc" / str(claimed)
                proc.mkdir()
                (proc / "comm").write_text("claude\n")
                (proc / "cmdline").write_bytes(b"/opt/bin/claude\0")
                if groups != "unknown":
                    pgid, tpgid = groups.split()
                    fields = ["S", str(route), pgid, pgid, "1", tpgid] + ["0"] * 13 + ["123456"]
                    (proc / "stat").write_text(f"{claimed} (agent ) name (nested)) " + " ".join(fields) + "\n")
            def proc_open(path, *args, **kwargs):
                if isinstance(path, str) and path.startswith("/proc/"):
                    path = home / "proc" / path.removeprefix("/proc/")
                return real_open(path, *args, **kwargs)
            request = {"v": 1, "claimedPID": claimed, "rootPID": route, "provider": "claude"}
            if require:
                request["requireForeground"] = True
            output = io.StringIO()
            code = 0
            with mock.patch.dict(os.environ, env), mock.patch("builtins.open", side_effect=proc_open), \
                 mock.patch("sys.stdin", io.TextIOWrapper(io.BytesIO(json.dumps(request).encode()))), \
                 contextlib.redirect_stdout(output):
                try:
                    exec(compile(proof, str(root / "process-proof.sh"), "exec"), {})
                except SystemExit as exit:
                    code = exit.code
            response = json.loads(output.getvalue())
            if require and expected is False:
                assert code == 1 and response["error"] == "backgroundProcess", response
            else:
                assert code == 0 and response["valid"] is True and response["foreground"] is expected, response
                assert response["processIDs"] == [claimed, route] and response["processStart"], response
            print(f"process proof PASS: {platform} {status} requireForeground={require}")
            proof_count += 1
print(f"process foreground proof tests: {proof_count} passed, 0 failed")
PY
if [[ "${2:-}" == --hook-deferral-only ]]; then
  exit 0
fi

"$DUMPER" projector > "$WORK_DIR/projector.sh"
"$DUMPER" codex-recovery > "$WORK_DIR/codex-recovery.sh"
chmod 700 "$WORK_DIR/projector.sh" "$WORK_DIR/codex-recovery.sh"
python3 "$HERE/test-agent-conversation-projector.py" "$WORK_DIR/projector.sh"
python3 "$HERE/../performance/agent-center/test_benchmark.py" "$WORK_DIR/projector.sh"
python3 "$HERE/../performance/agent-center/build_first_page_consumer.py" "$WORK_DIR/first-page-consumer"
python3 "$HERE/../performance/agent-center/test_first_page.py" "$WORK_DIR/first-page-consumer"
python3 "$HERE/test-codex-conversation-recovery.py" "$WORK_DIR/codex-recovery.sh"

# Remote settings are rejected by byte count before base64 reads them. This
# keeps a hostile or accidental large config from flooding the side channel.
OVERSIZED_HOME="$WORK_DIR/oversized-home"
mkdir -p "$OVERSIZED_HOME/.codex" "$OVERSIZED_HOME/.claude" "$OVERSIZED_HOME/.kimi-code"
python3 - "$OVERSIZED_HOME" <<'PY'
import os, sys
for relative in (".codex/hooks.json", ".claude/settings.json", ".kimi-code/config.toml"):
    with open(os.path.join(sys.argv[1], relative), "wb") as handle:
        handle.write(b"x" * 1_048_577)
PY
HOME="$OVERSIZED_HOME" CODEX_HOME="$OVERSIZED_HOME/.codex" CLAUDE_CONFIG_DIR="$OVERSIZED_HOME/.claude" KIMI_CODE_HOME="$OVERSIZED_HOME/.kimi-code" \
  /bin/sh -c "$("$DUMPER" read-codex); $("$DUMPER" read-claude); $("$DUMPER" read-kimi)" >"$WORK_DIR/oversized-config-output.txt"
grep -Fq 'TESSERA_AGENT_CODEX_HOOKS error:too-large' "$WORK_DIR/oversized-config-output.txt"
grep -Fq 'TESSERA_AGENT_CLAUDE_SETTINGS error:too-large' "$WORK_DIR/oversized-config-output.txt"
grep -Fq 'TESSERA_AGENT_KIMI_CONFIG error:too-large' "$WORK_DIR/oversized-config-output.txt"
! grep -Fq 'present:' "$WORK_DIR/oversized-config-output.txt"

install_in_home() {
  local home="$1"
  local login_shell="$2"
  local zdotdir="${3:-}"
  local install_output="$home/install-output.txt"
  local status_output="$home/status-output.txt"

  mkdir -p "$home"
  HOME="$home" SHELL="$login_shell" ZDOTDIR="$zdotdir" \
    CODEX_HOME="$home/.codex" CLAUDE_CONFIG_DIR="$home/.claude" \
    /bin/sh -c "$("$DUMPER" install-command)" >"$install_output"
  grep -Fq 'TESSERA_AGENT_INTEGRATION_INSTALLED' "$install_output"

  HOME="$home" SHELL="$login_shell" ZDOTDIR="$zdotdir" \
    CODEX_HOME="$home/.codex" CLAUDE_CONFIG_DIR="$home/.claude" \
    /bin/sh -c "$("$DUMPER" status-command)" >"$status_output"
  grep -Fq 'TESSERA_AGENT_INTEGRATION_STATUS current' "$status_output"
  grep -Fq 'claudeLegacy=match' "$status_output"
  python3 -m json.tool \
    "$home/.config/tessera/claude-agent-hooks.json" >/dev/null
  grep -Fq 'claude SessionStart idle session-start' \
    "$home/.config/tessera/claude-agent-hooks.json"
}

ZSH_HOME="$WORK_DIR/zsh-home"
ZDOTDIR="$ZSH_HOME/custom-zdot"
install_in_home "$ZSH_HOME" /bin/zsh "$ZDOTDIR"
HOME="$ZSH_HOME" SHELL=/bin/zsh ZDOTDIR="$ZDOTDIR" \
  /bin/zsh -f -c \
    '_tessera_agent_rc_ok=preserved; _tessera_agent_append() { printf preserved; }; eval "$("$1" persist-shell)"; [[ "$_tessera_agent_rc_ok" == preserved ]]; [[ "$(_tessera_agent_append)" == preserved ]]; eval "$("$1" persist-shell)"' \
  _ "$DUMPER"
[[ "$(grep -cF 'TESSERA-AGENT-LIFECYCLE' "$ZDOTDIR/.zshrc")" == 1 ]]
[[ ! -e "$ZSH_HOME/.zshrc" ]]

# sshd hands a non-interactive command the stock PATH, not the developer's
# login PATH. On macOS that resolves python3 to /usr/bin/python3 3.9, which has
# no tomllib: the Kimi config check used to read every correct config as
# corrupt, so status answered outdated forever and Install/Update could never
# converge. Install once under exactly that PATH so the shared installer stays
# honest about hosts whose only reachable interpreter cannot parse TOML.
RESTRICTED_PATH_HOME="$WORK_DIR/restricted-path-home"
mkdir -p "$RESTRICTED_PATH_HOME"
env -i HOME="$RESTRICTED_PATH_HOME" SHELL=/bin/bash PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  CODEX_HOME="$RESTRICTED_PATH_HOME/.codex" \
  CLAUDE_CONFIG_DIR="$RESTRICTED_PATH_HOME/.claude" \
  /bin/sh -c "$("$DUMPER" install-command)" \
  >"$RESTRICTED_PATH_HOME/install-output.txt"
grep -Fq 'TESSERA_AGENT_INTEGRATION_INSTALLED' \
  "$RESTRICTED_PATH_HOME/install-output.txt"
grep -Fq 'TESSERA_AGENT_INTEGRATION_STATUS current' \
  "$RESTRICTED_PATH_HOME/install-output.txt"
# The merged config is published, not abandoned beside the destination.
grep -Fq '# TESSERA-AGENT-CENTER-KIMI-HOOKS-BEGIN' \
  "$RESTRICTED_PATH_HOME/.kimi-code/config.toml"
[[ -z "$(find "$RESTRICTED_PATH_HOME/.kimi-code" -name 'config.toml.tessera.*' -print -quit)" ]]
# Whichever branch this host takes — an off-PATH interpreter that can parse
# TOML, or no parser at all — the diagnostic must say which, and neither answer
# may turn a correct config into a mismatch.
grep -Eq 'TESSERA_AGENT_INSTALL_DIAG .* kimiHooks=match kimiToml=(available|unavailable)$' \
  "$RESTRICTED_PATH_HOME/install-output.txt"

BASH_HOME="$WORK_DIR/bash-home"
install_in_home "$BASH_HOME" /bin/bash
HOME="$BASH_HOME" SHELL=/bin/bash \
  /bin/bash --noprofile --norc -c \
    '_tessera_agent_rc_ok=preserved; _tessera_agent_append() { printf preserved; }; eval "$("$1" persist-shell)"; [[ "$_tessera_agent_rc_ok" == preserved ]]; [[ "$(_tessera_agent_append)" == preserved ]]; eval "$("$1" persist-shell)"' \
  _ "$DUMPER"
[[ "$(grep -cF 'TESSERA-AGENT-LIFECYCLE' "$BASH_HOME/.bashrc")" == 1 ]]
[[ "$(grep -cF 'TESSERA-AGENT-LIFECYCLE' "$BASH_HOME/.bash_profile")" == 1 ]]

# A deterministic app-server double exercises the same machine-readable
# hooks/list contract as a real Codex install. It keeps this critical bootstrap
# gate available in CI without credentials or provider network access.
FAKE_BIN="$WORK_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/codex" <<'SH'
#!/bin/sh
app_server=0
for argument in "$@"; do
  [ "$argument" = app-server ] && app_server=1
done
[ "$app_server" -eq 1 ] || exit 0

while IFS= read -r request; do
  case "$request" in
    *'"id":1'*)
      printf '%s\n' '{"id":1,"result":{"serverInfo":{"name":"fake-codex"}}}'
      ;;
    *'"id":2'*)
      printf '{"id":2,"result":{"items":[{"key":"tessera-session-start","eventName":"sessionStart","matcher":"startup|resume|clear|compact","enabled":%s,"trustStatus":"%s","command":"\\"$HOME/.config/tessera/agent-lifecycle-hook.sh\\" codex SessionStart idle session-start"}]}}\n' \
        "${TESSERA_FAKE_CODEX_ENABLED:-true}" \
        "${TESSERA_FAKE_CODEX_TRUST_STATUS:-untrusted}"
      ;;
  esac
done
SH
chmod 700 "$FAKE_BIN/codex"

# A shim is the foreground process-group leader, not the provider PID. Every
# member of that foreground job must be visible to the shared classifier.
PROCESS_BIN="$WORK_DIR/process-bin"
mkdir -p "$PROCESS_BIN"
cat >"$PROCESS_BIN/ps" <<'SH'
#!/bin/sh
printf '%s\n' '100 1 100 200 /bin/bash' '200 100 200 200 /bin/sh' '201 200 200 200 /opt/bin/codex' '202 100 202 200 /opt/bin/codex'
SH
chmod 700 "$PROCESS_BIN/ps"
PATH="$PROCESS_BIN:/usr/bin:/bin" /bin/sh -c "$("$DUMPER" process-discovery 100)" >"$WORK_DIR/foreground-processes.txt"
python3 - "$WORK_DIR/foreground-processes.txt" <<'PY'
import json,sys
value=json.loads(open(sys.argv[1]).read().split(' ',1)[1])
assert {p['pid'] for p in value['processes'] if p['foreground']} == {200,201}
PY

# The wrapper that reports WrapperExit is the hook's parent and its arguments
# name the provider. It must bind that final event to itself, and only a live
# provider above it may turn the exit into an ignored nested one.
ANCESTRY_BIN="$WORK_DIR/ancestry-bin"
mkdir -p "$ANCESTRY_BIN"
cat >"$ANCESTRY_BIN/ps" <<'SH'
#!/bin/sh
field=""; pid=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field="$2"; shift 2 ;;
    -p) pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$pid" = "${TESSERA_TEST_WRAPPER_PID:-}" ] && pid=wrapper
line="$(grep "^$pid " "$TESSERA_TEST_PS_TABLE" | head -n 1)"
[ -n "$line" ] || exit 1
set -- $line
case "$field" in
  ppid=) printf '%s\n' "$2" ;;
  comm=) printf '%s\n' "$3" ;;
  args=) shift 3; printf '%s\n' "$*" ;;
esac
SH
chmod 700 "$ANCESTRY_BIN/ps"
printf '%s\n' 'wrapper 500 sh /bin/sh /home/u/.config/tessera/bin/codex' '500 1 zsh -zsh' >"$WORK_DIR/ps-plain.txt"
printf '%s\n' 'wrapper 600 sh /bin/sh /home/u/.config/tessera/bin/codex' '600 601 sh /bin/sh -c codex' '601 602 codex /opt/bin/codex' '602 1 zsh -zsh' >"$WORK_DIR/ps-nested.txt"
HOOK="$ZSH_HOME/.config/tessera/agent-lifecycle-hook.sh"
# Exercise the generated hook's conservative clock path with a fixed second.
# Independent hook PIDs must distinguish repeated events within that tick.
MINIMAL_TIMESTAMP_LINE="$(sed -n '/^case "$timestamp_ns" in /p' "$HOOK")"
FIRST_TIMESTAMP="$(/bin/sh -c 'date() { printf 123; }; timestamp_ns=""; eval "$1"; printf %s "$timestamp_ns"' _ "$MINIMAL_TIMESTAMP_LINE")"
SECOND_TIMESTAMP="$(/bin/sh -c 'date() { printf 123; }; timestamp_ns=""; eval "$1"; printf %s "$timestamp_ns"' _ "$MINIMAL_TIMESTAMP_LINE")"
[[ "$FIRST_TIMESTAMP" == 123* && "$SECOND_TIMESTAMP" == 123* && "$FIRST_TIMESTAMP" != "$SECOND_TIMESTAMP" ]]
# Run the actual generated attribution block in an isolated fixture home.
# A live child cannot suppress root PostToolUse/Stop after auto approval.
ATTRIBUTION_BLOCK="$(sed -n '/^# Track dedicated child/,/^payload=/p' "$HOOK" | sed '$d')"
for event in PostToolUse Stop; do
  ROOT_EVENT_OUTPUT="$(HOME="$ZSH_HOME" /bin/sh -c 'provider=codex; event="$1"; state=working; agent_pid=424242; agent_id=""; mkdir -p "$HOME/.config/tessera/active-subagents/$agent_pid"; eval "$2"; printf accepted' _ "$event" "$ATTRIBUTION_BLOCK")"
  [[ "$ROOT_EVENT_OUTPUT" == accepted ]]
  CHILD_EVENT_OUTPUT="$(HOME="$ZSH_HOME" /bin/sh -c 'provider=codex; event="$1"; state=working; agent_pid=424242; agent_id=child; eval "$2"; printf accepted' _ "$event" "$ATTRIBUTION_BLOCK")"
  [[ -z "$CHILD_EVENT_OUTPUT" ]]
done
env -u TMUX -u TMUX_PANE HOME="$ZSH_HOME" PATH="$ANCESTRY_BIN:/usr/bin:/bin" TESSERA_AGENT_TTY=/dev/null \
  TESSERA_TEST_PS_TABLE="$WORK_DIR/ps-plain.txt" \
  /bin/sh -c 'export TESSERA_TEST_WRAPPER_PID=$$; printf %s "$$" >"$1"; "$2" codex WrapperExit unavailable session-ended </dev/null' \
  _ "$WORK_DIR/wrapper-pid.txt" "$HOOK"
WRAPPER_PID="$(cat "$WORK_DIR/wrapper-pid.txt")"
grep -Fq '"event":"WrapperExit"' "$ZSH_HOME/.config/tessera/agent-runtime-state/$WRAPPER_PID.json"
grep -Fq "\"agentPid\":$WRAPPER_PID," "$ZSH_HOME/.config/tessera/agent-runtime-state/$WRAPPER_PID.json"
grep -Eq 'provider=codex event=WrapperExit .* phase=resolved agentPid=present' "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log"
env -u TMUX -u TMUX_PANE HOME="$ZSH_HOME" PATH="$ANCESTRY_BIN:/usr/bin:/bin" TESSERA_AGENT_TTY=/dev/null \
  TESSERA_TEST_PS_TABLE="$WORK_DIR/ps-nested.txt" \
  /bin/sh -c 'export TESSERA_TEST_WRAPPER_PID=$$; printf %s "$$" >"$1"; "$2" codex WrapperExit unavailable session-ended </dev/null' \
  _ "$WORK_DIR/nested-wrapper-pid.txt" "$HOOK"
NESTED_WRAPPER_PID="$(cat "$WORK_DIR/nested-wrapper-pid.txt")"
[[ ! -e "$ZSH_HOME/.config/tessera/agent-runtime-state/$NESTED_WRAPPER_PID.json" ]]
grep -Fq 'event=WrapperExit state=unavailable reason=session-ended phase=ignored source=nested-wrapper' "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log"

# Question tools publish a content-free marker as the reason of their tool
# boundaries (integration v21); nothing of the question reaches the log.
: >"$WORK_DIR/ps-empty.txt"
question_reason() {
  printf '%s' "$4" | env -u TMUX -u TMUX_PANE HOME="$ZSH_HOME" PATH="$ANCESTRY_BIN:/usr/bin:/bin" \
    TESSERA_AGENT_TTY=/dev/null TESSERA_TEST_PS_TABLE="$WORK_DIR/ps-empty.txt" "$HOOK" "$1" "$2" "$3" "$5"
  tail -n 1 "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log" \
    | sed -n "s/.* provider=$1 event=$2 state=$3 reason=\([A-Za-z-]*\) phase=resolved .*/\1/p"
}
ASK='{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Secret ledger question?"}]}}'
ASK_BACKGROUND='{"tool_name":"AskUserQuestion","tool_input":{"background":true,"questions":[{"question":"Secret ledger question?"}]}}'
[[ "$(question_reason claude PreToolUse working "$ASK" agent-turn)" == question ]]
[[ "$(question_reason claude PostToolUse working "$ASK" agent-turn)" == question ]]
[[ "$(question_reason kimi PreToolUse working "$ASK" agent-turn)" == question ]]
[[ "$(question_reason kimi PreToolUse working "$ASK_BACKGROUND" agent-turn)" == deferred-question ]]
[[ "$(question_reason codex PreToolUse working '{"tool_name":"request_user_input","tool_input":{}}' agent-turn)" == question ]]
[[ "$(question_reason codex PreToolUse working '{"tool_name":"request_user_input_async","tool_input":{}}' agent-turn)" == deferred-question ]]
[[ "$(question_reason claude PreToolUse working '{"tool_name":"Bash","tool_input":{"command":"ls"}}' agent-turn)" == agent-turn ]]
# Only tool boundaries carry the marker.
[[ "$(question_reason claude PermissionRequest waitingForInput "$ASK" permission)" == permission ]]
if grep -Fq 'Secret ledger' "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log"; then exit 1; fi
# Hosts without Python read the tool name with the bounded sed fallback.
QUESTION_FALLBACK="$(awk '/^if \[ -z "\$question_marker" \] && \[ -n "\$input" \]; then$/ { copy = 1 } copy { print } copy && /^esac$/ { exit }' "$HOOK")"
[[ -n "$QUESTION_FALLBACK" ]]
fallback_reason() {
  /bin/sh -c 'event="$1"; input="$2"; question_marker=""; reason=agent-turn; eval "$3"; printf %s "$reason"' _ "$1" "$2" "$QUESTION_FALLBACK"
}
[[ "$(fallback_reason PreToolUse "$ASK")" == question ]]
[[ "$(fallback_reason PreToolUse "$ASK_BACKGROUND")" == deferred-question ]]
[[ "$(fallback_reason PreToolUse '{"tool_name":"request_user_input_async"}')" == deferred-question ]]
[[ "$(fallback_reason Stop "$ASK")" == agent-turn ]]

# A stale integration copy can remain earlier than a version-manager provider
# after HOME/PATH changes. Both production shims must skip any Tessera-owned
# copy, not merely the exact inode that is currently executing.
STALE_BIN="$WORK_DIR/stale-tessera-bin"
mkdir -p "$STALE_BIN"
cat >"$STALE_BIN/codex" <<'SH'
#!/bin/sh
# Tessera Agent Center Codex shim — stale test double.
exit 88
SH
cat >"$STALE_BIN/claude" <<'SH'
#!/bin/sh
# Tessera Agent Center Claude shim — stale test double.
exit 88
SH
cat >"$FAKE_BIN/claude" <<'SH'
#!/bin/sh
: >"$TESSERA_FAKE_CLAUDE_MARKER"
exit 0
SH
chmod 700 "$STALE_BIN/codex" "$STALE_BIN/claude" "$FAKE_BIN/claude"

READINESS="$ZSH_HOME/.config/tessera/agent-codex-readiness.sh"
set +e
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=untrusted \
  "$READINESS" "$FAKE_BIN/codex"
UNTRUSTED_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex"
TRUSTED_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_ENABLED=false \
  "$READINESS" "$FAKE_BIN/codex"
DISABLED_STATUS=$?
set -e
[[ "$UNTRUSTED_STATUS" == 2 ]]
[[ "$TRUSTED_STATUS" == 0 ]]
[[ "$DISABLED_STATUS" == 1 ]]
grep -Fq 'result=handler-untrusted' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log"
grep -Fq 'result=trusted' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log"
grep -Fq 'result=handler-disabled' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log"

# A resumed or forked thread starts at an empty composer and gets no native
# SessionStart before its first turn, so it takes the same pre-exec bootstrap
# as a fresh start. Thread-selection flags never reach the app-server probe.
# A prompt argument starts a turn at once and stays with the native hooks.
set +e
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" resume
RESUME_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" resume --last --include-non-interactive
RESUME_LAST_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" -m gpt-5 fork 019a-thread-name --all
FORK_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" resume 019a-thread-name 'start a turn'
RESUME_PROMPT_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" 'start a turn'
PROMPT_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" --last
TOP_LEVEL_LAST_STATUS=$?
# With --last the only positional is a prompt, wherever it stands.
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" resume --last 'start a turn'
RESUME_LAST_PROMPT_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" resume 'start a turn' --last
RESUME_PROMPT_LAST_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" fork --last 'start a turn'
FORK_LAST_PROMPT_STATUS=$?
# fork rejects --include-non-interactive, so no bootstrap precedes that error.
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex" fork --include-non-interactive
FORK_NON_INTERACTIVE_STATUS=$?
set -e
[[ "$RESUME_STATUS" == 0 && "$RESUME_LAST_STATUS" == 0 && "$FORK_STATUS" == 0 ]]
[[ "$RESUME_PROMPT_STATUS" == 1 && "$PROMPT_STATUS" == 1 && "$TOP_LEVEL_LAST_STATUS" == 1 ]]
[[ "$RESUME_LAST_PROMPT_STATUS" == 1 && "$RESUME_PROMPT_LAST_STATUS" == 1 ]]
[[ "$FORK_LAST_PROMPT_STATUS" == 1 && "$FORK_NON_INTERACTIVE_STATUS" == 1 ]]
[[ "$(grep -c 'result=trusted profile=absent cwdOverride=absent launch=resume$' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log")" == 2 ]]
[[ "$(grep -c 'result=trusted profile=absent cwdOverride=absent launch=fork$' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log")" == 1 ]]
[[ "$(grep -c 'result=deferred-to-provider-hook profile=absent cwdOverride=absent launch=resume$' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log")" == 3 ]]
[[ "$(grep -c 'result=deferred-to-provider-hook profile=absent cwdOverride=absent launch=fork$' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log")" == 2 ]]
[[ "$(grep -c 'result=deferred-to-provider-hook profile=absent cwdOverride=absent launch=composer$' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log")" == 2 ]]

# Shim runs publish real lifecycle frames: keep them off the developer's own
# tmux pane and terminal.
SHIM="$ZSH_HOME/.config/tessera/bin/codex"
env -u TMUX -u TMUX_PANE HOME="$ZSH_HOME" TESSERA_AGENT_TTY=/dev/null \
  PATH="$ZSH_HOME/.config/tessera/bin:$STALE_BIN:$FAKE_BIN:/usr/bin:/bin" \
  TESSERA_FAKE_CODEX_TRUST_STATUS=untrusted \
  "$SHIM"
env -u TMUX -u TMUX_PANE HOME="$ZSH_HOME" TESSERA_AGENT_TTY=/dev/null \
  PATH="$ZSH_HOME/.config/tessera/bin:$STALE_BIN:$FAKE_BIN:/usr/bin:/bin" \
  TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$SHIM"
# The shim bootstraps a resumed thread too, and the hook's root observer must
# no longer stall the launch: it binds the launcher's pre-exec identity and
# waits for the exec detached, so the shim returns as soon as the provider
# exits. The fake provider exits at once, so the detached observer sees its
# process identity vanish and ends without publishing anything.
BOOTSTRAP_LINES_BEFORE="$(grep -c 'reason=verified-trusted-empty-composer' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log")"
RESUME_SHIM_START="$(python3 -c 'import time; print(time.monotonic())')"
env -u TMUX -u TMUX_PANE HOME="$ZSH_HOME" TESSERA_AGENT_TTY=/dev/null \
  PATH="$ZSH_HOME/.config/tessera/bin:$STALE_BIN:$FAKE_BIN:/usr/bin:/bin" \
  TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$SHIM" resume --last
# The old hook waited a full 2 s before giving up on the pre-exec launcher.
python3 -c 'import sys, time; sys.exit(0 if time.monotonic() - float(sys.argv[1]) < 2.0 else 1)' \
  "$RESUME_SHIM_START"
BOOTSTRAP_LINES_AFTER="$(grep -c 'reason=verified-trusted-empty-composer' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log")"
[[ "$BOOTSTRAP_LINES_AFTER" == $(( BOOTSTRAP_LINES_BEFORE + 2 )) ]]
grep -Fq 'result=trusted profile=absent cwdOverride=absent launch=resume' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log"

# The detached observer must bind the launcher's PID, wait for the exec and
# publish the resumed thread's identity from the rollout the provider holds
# open, then end with the provider. The observer accepts only a process whose
# command name is codex, which no shell script presents, so the provider
# double is a compiled program that opens its rollout one second in.
OBSERVED_BIN="$WORK_DIR/observed-bin"
mkdir -p "$OBSERVED_BIN"
C_COMPILER="$(command -v cc || command -v clang || command -v gcc || true)"
[[ -n "$C_COMPILER" ]] || {
  printf 'agent integration scripts: a C compiler is required for the observer check\n' >&2
  exit 1
}
cat >"$WORK_DIR/observed-codex.c" <<'C'
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    const char *app_server = getenv("TESSERA_FAKE_APP_SERVER");
    for (int index = 1; index < argc; index++) {
        if (app_server != NULL && strcmp(argv[index], "app-server") == 0) {
            execv(app_server, argv);
            return 127;
        }
    }
    const char *pid_file = getenv("TESSERA_FAKE_CODEX_PID_FILE");
    if (pid_file != NULL) {
        FILE *handle = fopen(pid_file, "w");
        if (handle != NULL) { fprintf(handle, "%d\n", (int) getpid()); fclose(handle); }
    }
    sleep(1);
    const char *rollout = getenv("TESSERA_FAKE_ROLLOUT");
    int descriptor = rollout != NULL ? open(rollout, O_RDONLY) : -1;
    const char *lifetime = getenv("TESSERA_FAKE_LIFETIME");
    sleep(lifetime != NULL ? (unsigned) atoi(lifetime) : 1);
    if (descriptor >= 0) close(descriptor);
    return 0;
}
C
"$C_COMPILER" -o "$OBSERVED_BIN/codex" "$WORK_DIR/observed-codex.c"
OBSERVED_SESSION=019a0000-1111-7222-8333-444455556666
OBSERVED_SESSIONS="$ZSH_HOME/.codex/sessions/2026/09/24"
mkdir -p "$OBSERVED_SESSIONS"
OBSERVED_ROLLOUT="$OBSERVED_SESSIONS/rollout-2026-09-24T10-00-00-$OBSERVED_SESSION.jsonl"
(umask 077; printf '{"type":"session_meta","payload":{"id":"%s","source":"cli"}}\n' \
  "$OBSERVED_SESSION" >"$OBSERVED_ROLLOUT")
OBSERVED_PID_FILE="$WORK_DIR/observed-codex.pid"
OBSERVER_LINES_BEFORE="$(grep -c 'reason=session-start phase=resolved' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log" || true)"
# macOS observers read open files through lsof in /usr/sbin.
env -u TMUX -u TMUX_PANE HOME="$ZSH_HOME" CODEX_HOME="$ZSH_HOME/.codex" TESSERA_AGENT_TTY=/dev/null \
  PATH="$ZSH_HOME/.config/tessera/bin:$OBSERVED_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TESSERA_FAKE_APP_SERVER="$FAKE_BIN/codex" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  TESSERA_FAKE_CODEX_PID_FILE="$OBSERVED_PID_FILE" TESSERA_FAKE_ROLLOUT="$OBSERVED_ROLLOUT" \
  TESSERA_FAKE_LIFETIME=10 \
  "$SHIM" resume --last </dev/null &
OBSERVED_SHIM=$!
OBSERVED_STATE=""
for _ in $(seq 1 40); do
  sleep 0.2
  [[ -s "$OBSERVED_PID_FILE" ]] || continue
  OBSERVED_CANDIDATE="$ZSH_HOME/.config/tessera/agent-runtime-state/$(cat "$OBSERVED_PID_FILE").json"
  if [[ -f "$OBSERVED_CANDIDATE" ]] && grep -Fq "\"sessionId\":\"$OBSERVED_SESSION\"" "$OBSERVED_CANDIDATE"; then
    OBSERVED_STATE="$(cat "$OBSERVED_CANDIDATE")"
    break
  fi
done
wait "$OBSERVED_SHIM"
OBSERVED_PID="$(cat "$OBSERVED_PID_FILE")"
[[ -n "$OBSERVED_STATE" ]]
grep -Fq '"event":"SessionStart"' <<<"$OBSERVED_STATE"
grep -Fq '"reason":"session-start"' <<<"$OBSERVED_STATE"
grep -Fq "\"agentPid\":$OBSERVED_PID," <<<"$OBSERVED_STATE"
OBSERVER_LINES_AFTER="$(grep -c 'reason=session-start phase=resolved' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log" || true)"
[[ "$OBSERVER_LINES_AFTER" == $(( OBSERVER_LINES_BEFORE + 1 )) ]]
sleep 2
if ps -axo pid=,command= | grep -F -- "--watch-root $OBSERVED_PID" | grep -v grep; then
  printf 'agent integration scripts: an observer outlived its provider\n' >&2
  exit 1
fi

# The npm launcher remains node while its native child owns the rollout.
# Keep that parent alive after the child exits to prove observer cleanup is
# fenced to the child lifetime, without any native lifecycle prompt.
NODE_BIN="$WORK_DIR/node-bin"
mkdir -p "$NODE_BIN"
cat >"$WORK_DIR/observed-node.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 3) return 2;
    const char *pid_file = getenv("TESSERA_FAKE_NODE_PID_FILE");
    if (pid_file != NULL) {
        FILE *handle = fopen(pid_file, "w");
        if (handle != NULL) { fprintf(handle, "%d\n", (int) getpid()); fclose(handle); }
    }
    pid_t child = fork();
    if (child < 0) return 1;
    if (child == 0) { execv(argv[2], argv + 2); return 127; }
    int status;
    waitpid(child, &status, 0);
    sleep(4);
    return 0;
}
C
"$C_COMPILER" -o "$NODE_BIN/node" "$WORK_DIR/observed-node.c"
cat >"$NODE_BIN/codex" <<'SH'
#!/bin/sh
case "$1" in
  app-server|--version|--help) exec "$TESSERA_FAKE_APP_SERVER" "$@" ;;
esac
exec "$TESSERA_FAKE_NODE" /opt/node_modules/@openai/codex/bin/codex.js "$TESSERA_FAKE_NATIVE_CODEX" "$@"
SH
chmod 700 "$NODE_BIN/codex"
NODE_SESSION=019a0000-1111-7222-8333-444455557777
NODE_ROLLOUT="$OBSERVED_SESSIONS/rollout-2026-09-24T10-00-00-$NODE_SESSION.jsonl"
(umask 077; printf '{"type":"session_meta","payload":{"id":"%s","source":"cli"}}\n' "$NODE_SESSION" >"$NODE_ROLLOUT")
NODE_PID_FILE="$WORK_DIR/observed-node.pid"
NATIVE_PID_FILE="$WORK_DIR/node-native-codex.pid"
env -u TMUX -u TMUX_PANE HOME="$ZSH_HOME" CODEX_HOME="$ZSH_HOME/.codex" TESSERA_AGENT_TTY=/dev/null \
  PATH="$ZSH_HOME/.config/tessera/bin:$NODE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  TESSERA_FAKE_NODE="$NODE_BIN/node" TESSERA_FAKE_NATIVE_CODEX="$OBSERVED_BIN/codex" \
  TESSERA_FAKE_APP_SERVER="$FAKE_BIN/codex" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  TESSERA_FAKE_NODE_PID_FILE="$NODE_PID_FILE" TESSERA_FAKE_CODEX_PID_FILE="$NATIVE_PID_FILE" \
  TESSERA_FAKE_ROLLOUT="$NODE_ROLLOUT" TESSERA_FAKE_LIFETIME=10 \
  "$SHIM" resume --last </dev/null &
NODE_SHIM=$!
NODE_NATIVE_PID=""
NODE_LAUNCHER_PID=""
kill_children() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  kill "$@" 2>/dev/null || true
  exit "$status"
}
trap 'kill_children "$NODE_SHIM" "$NODE_NATIVE_PID" "$NODE_LAUNCHER_PID"' EXIT
NODE_STATE=""
for _ in $(seq 1 40); do
  sleep 0.2
  [[ -s "$NATIVE_PID_FILE" && -s "$NODE_PID_FILE" ]] || continue
  NODE_NATIVE_PID="$(cat "$NATIVE_PID_FILE")"
  NODE_LAUNCHER_PID="$(cat "$NODE_PID_FILE")"
  NODE_CLAIM="$ZSH_HOME/.config/tessera/agent-runtime-state/$NODE_NATIVE_PID.json"
  if [[ -f "$NODE_CLAIM" ]] && grep -Fq "\"sessionId\":\"$NODE_SESSION\"" "$NODE_CLAIM"; then
    NODE_STATE="$(cat "$NODE_CLAIM")"
    break
  fi
done
[[ -n "$NODE_STATE" && "$NODE_NATIVE_PID" != "$NODE_LAUNCHER_PID" ]]
grep -Fq '"event":"SessionStart"' <<<"$NODE_STATE"
grep -Fq "\"agentPid\":$NODE_NATIVE_PID," <<<"$NODE_STATE"
kill "$NODE_NATIVE_PID"
sleep 2
kill -0 "$NODE_LAUNCHER_PID"
if ps -axo pid=,command= | grep -F -- "--watch-root $NODE_LAUNCHER_PID" | grep -v grep; then
  printf 'agent integration scripts: a node observer outlived its native child\n' >&2
  exit 1
fi
wait "$NODE_SHIM"
trap - EXIT
printf 'node launcher observer tests: 1 passed, 0 failed\n'
CLAUDE_MARKER="$WORK_DIR/fake-claude-invoked"
HOME="$ZSH_HOME" \
  PATH="$ZSH_HOME/.config/tessera/bin:$STALE_BIN:$FAKE_BIN:/usr/bin:/bin" \
  TESSERA_FAKE_CLAUDE_MARKER="$CLAUDE_MARKER" \
  "$ZSH_HOME/.config/tessera/bin/claude" --resume test-session
[[ -f "$CLAUDE_MARKER" ]]
grep -Fq 'reason=verified-configured-empty-composer' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log"
grep -Fq 'reason=verified-trusted-empty-composer' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log"
grep -Fq 'phase=resolved agentPid=present' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log"

# Projection v1 is exercised against a provider-owned source. Append order is
# authoritative even when display timestamps move backwards, meta user input
# is classified as system content, and a source line larger than the protocol
# page limit is drained into an explicitly truncated record.
PROJECT_ROOT="$ZSH_HOME/.claude/projects/example"
PROJECT_SOURCE="$PROJECT_ROOT/session.jsonl"
mkdir -p "$PROJECT_ROOT"
python3 - "$PROJECT_SOURCE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"type":"user","sessionId":"permission-fixture","timestamp":"2026-08-29T12:00:02Z","message":{"role":"user","content":"first"},"cwd":"/srv/tessera","gitBranch":"feat/v2"}) + "\n")
    handle.write(json.dumps({"type":"user","timestamp":"2026-08-29T12:00:01Z","isMeta":True,"message":{"role":"user","content":"injected"}}) + "\n")
    handle.write(json.dumps({"type":"assistant","message":{"role":"assistant","model":"opus","content":[{"type":"thinking","thinking":"checking"},{"type":"tool_use","name":"Read","input":{"file_path":"App.swift"}}]}}) + "\n")
    handle.write(json.dumps({"type":"ai-title","title":"agent center v2"}) + "\n")
    handle.write(json.dumps({"type":"cost-state","cost":1.25,"lines_added":9,"lines_removed":3}) + "\n")
    handle.write(json.dumps({"type":"queue-operation","pending":2}) + "\n")
    handle.write(json.dumps({"type":"tool_result","content":"x" * 1400000}) + "\n")
PY
PROJECT_REF="$(python3 - "$PROJECT_SOURCE" <<'PY'
import base64, sys
print(base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip("="))
PY
)"
PROJECTOR="$ZSH_HOME/.config/tessera/tessera-agent-project"
PROJECT_OUTPUT="$WORK_DIR/project-output.ndjson"
HOME="$ZSH_HOME" "$PROJECTOR" <<JSON >"$PROJECT_OUTPUT"
{"v":1,"kind":"project","provider":"claude","transcriptRef":"$PROJECT_REF","cursor":null,"limitBytes":262144,"limitRecords":100,"query":null}
JSON
python3 - "$PROJECT_OUTPUT" <<'PY'
import json, sys
frames = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
records = [frame for frame in frames if frame.get("kind") == "record"]
assert [record["sequence"] for record in records] == list(range(7))
assert records[0]["record"]["blocks"][0]["text"] == "first"
assert records[1]["record"]["role"] == "system"
assert [block["type"] for block in records[2]["record"]["blocks"]] == ["thinking", "tool_call"]
assert records[2]["record"]["model"] == "opus"
assert records[3]["record"]["title"] == "agent center v2"
assert records[4]["record"]["cost"] == 1.25
assert records[5]["record"]["pending"] == 2
assert records[6]["record"]["truncated"] is True
assert len(open(sys.argv[1], "rb").read()) <= 262144
assert all(len(line) <= 65536 for line in open(sys.argv[1], "rb"))
assert frames[-1]["kind"] == "end"
PY

# Cursor identity is inode-bound. Replacing the source after a page must fail
# closed instead of applying the old offset to unrelated content.
PROJECT_CURSOR="$(python3 - "$PROJECT_OUTPUT" <<'PY'
import json, sys
frames = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
print(frames[-1]["cursor"])
PY
)"
mv "$PROJECT_SOURCE" "$PROJECT_SOURCE.rotated"
printf '%s\n' '{"type":"assistant","sessionId":"permission-fixture","text":"replacement"}' >"$PROJECT_SOURCE"
set +e
HOME="$ZSH_HOME" "$PROJECTOR" <<JSON >"$WORK_DIR/project-rotated.ndjson"
{"v":1,"kind":"project","provider":"claude","transcriptRef":"$PROJECT_REF","cursor":"$PROJECT_CURSOR"}
JSON
ROTATED_STATUS=$?
set -e
[[ "$ROTATED_STATUS" != 0 ]]
grep -Fq '"error":"sourceChanged"' "$WORK_DIR/project-rotated.ndjson"

# Transcript write permissions belong to the user. Reading and discovery must
# accept them unchanged. Symlinks escaping the provider root remain rejected.
chmod 666 "$PROJECT_SOURCE"
HOME="$ZSH_HOME" "$PROJECTOR" <<JSON >"$WORK_DIR/project-permissions.ndjson"
{"v":1,"kind":"project","provider":"claude","transcriptRef":"$PROJECT_REF"}
JSON
grep -Fq '"kind":"end"' "$WORK_DIR/project-permissions.ndjson"
HOME="$ZSH_HOME" "$PROJECTOR" <<'JSON' >"$WORK_DIR/inventory-permissions.ndjson"
{"v":1,"kind":"inventory","provider":"claude"}
JSON
grep -Fq '"providerSessionID":"permission-fixture"' "$WORK_DIR/inventory-permissions.ndjson"
chmod 600 "$PROJECT_SOURCE"

ESCAPE_LINK="$PROJECT_ROOT/escape.jsonl"
ln -s /etc/passwd "$ESCAPE_LINK"
ESCAPE_REF="$(python3 - "$ESCAPE_LINK" <<'PY'
import base64, sys
print(base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip("="))
PY
)"
set +e
HOME="$ZSH_HOME" "$PROJECTOR" <<JSON >"$WORK_DIR/project-symlink.ndjson"
{"v":1,"kind":"project","provider":"claude","transcriptRef":"$ESCAPE_REF"}
JSON
SYMLINK_STATUS=$?
set -e
[[ "$SYMLINK_STATUS" != 0 ]]
grep -Fq '"error":"permissionDenied"' "$WORK_DIR/project-symlink.ndjson"

# Malformed/oversized requests and bounded search use typed, content-free
# errors/results and never spill an unbounded source line.
set +e
printf '%s\n' '{not-json' | HOME="$ZSH_HOME" "$PROJECTOR" >"$WORK_DIR/project-malformed.ndjson"
MALFORMED_STATUS=$?
python3 - <<'PY' | HOME="$ZSH_HOME" "$PROJECTOR" >"$WORK_DIR/project-oversized.ndjson"
print("x" * 70000)
PY
OVERSIZED_STATUS=$?
set -e
[[ "$MALFORMED_STATUS" != 0 && "$OVERSIZED_STATUS" != 0 ]]
grep -Fq '"error":"malformed"' "$WORK_DIR/project-malformed.ndjson"
grep -Fq '"error":"malformed"' "$WORK_DIR/project-oversized.ndjson"
printf '%s\n' '{"type":"assistant","text":"bounded search needle"}' >>"$PROJECT_SOURCE"
HOME="$ZSH_HOME" "$PROJECTOR" <<JSON >"$WORK_DIR/project-search.ndjson"
{"v":1,"kind":"search","provider":"claude","transcriptRef":"$PROJECT_REF","query":"search needle","limitRecords":100}
JSON
grep -Fq '"kind":"searchResult"' "$WORK_DIR/project-search.ndjson"
[[ "$(wc -c <"$WORK_DIR/project-search.ndjson")" -le 262144 ]]

# Codex rollout envelopes normalize into the same canonical blocks/metadata
# without changing ordering or exposing the raw envelope shape to clients.
CODEX_ROOT="$ZSH_HOME/.codex/sessions/2026/08/29"
CODEX_SOURCE="$CODEX_ROOT/rollout-fixture.jsonl"
mkdir -p "$CODEX_ROOT"
python3 - "$CODEX_SOURCE" <<'PY'
import json, sys
rows = [
    {"type":"session_meta","payload":{"id":"codex-session","cwd":"/srv/tessera","git":{"branch":"feat/v2"},"model":"gpt-5"}},
    {"type":"response_item","payload":{"type":"user_message","message":"inspect the reducer"}},
    {"type":"response_item","payload":{"type":"reasoning","text":"checking ordering"}},
    {"type":"response_item","payload":{"type":"custom_tool_call","name":"read_file","arguments":{"path":"Reducer.swift"}}},
    {"type":"response_item","payload":{"type":"custom_tool_call_output","output":"bounded output"}},
    {"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":200000,"total_token_usage":{"input_tokens":100,"output_tokens":25}}}},
    {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}},
]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for row in rows: handle.write(json.dumps(row) + "\n")
PY
CODEX_REF="$(python3 - "$CODEX_SOURCE" <<'PY'
import base64, sys
print(base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip("="))
PY
)"
HOME="$ZSH_HOME" "$PROJECTOR" <<JSON >"$WORK_DIR/codex-project.ndjson"
{"v":1,"kind":"project","provider":"codex","transcriptRef":"$CODEX_REF","limitBytes":262144,"limitRecords":100}
JSON
python3 - "$WORK_DIR/codex-project.ndjson" <<'PY'
import json, sys
records = [frame["record"] for frame in map(json.loads, open(sys.argv[1], encoding="utf-8")) if frame.get("kind") == "record"]
assert records[0]["type"] == "session_meta" and records[0]["project"] == "tessera" and records[0]["branch"] == "feat/v2"
assert records[1]["role"] == "user" and records[1]["blocks"][0]["text"] == "inspect the reducer"
assert records[2]["blocks"][0]["type"] == "thinking"
assert records[3]["blocks"][0]["type"] == "tool_call"
assert records[4]["blocks"][0]["type"] == "tool_result"
assert records[5]["type"] == "cost-state" and records[5]["used_tokens"] == 125
assert records[6]["type"] == "completion" and records[6]["summary"] == "done"
PY

# Kimi's canonical wire does not repeat the session ID inside each envelope;
# inventory must bind the exact validated session-index entry to its wire path.
KIMI_SESSION_ID="session_01234567-89ab-cdef-0123-456789abcdef"
KIMI_ROOT="$ZSH_HOME/.kimi-code/sessions/wd_fixture/$KIMI_SESSION_ID"
KIMI_SOURCE="$KIMI_ROOT/agents/main/wire.jsonl"
mkdir -p "${KIMI_SOURCE%/*}"
python3 - "$KIMI_SOURCE" <<'PY'
import json, sys
rows = [
    {"type":"metadata","protocol_version":1,"created_at":"2026-08-30T12:00:00Z"},
    {"type":"config.update","modelAlias":"kimi-code/k3","time":1},
    {"type":"turn.prompt","input":"inspect the adapter","time":2},
    {"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"adapter ready"}},"time":3},
]
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    for row in rows: handle.write(json.dumps(row) + "\n")
PY
printf '{"sessionId":"%s","sessionDir":"%s","workDir":"/srv/tessera"}\n' \
  "$KIMI_SESSION_ID" "$KIMI_ROOT" >"$ZSH_HOME/.kimi-code/session_index.jsonl"
chmod 600 "$ZSH_HOME/.kimi-code/session_index.jsonl" "$KIMI_SOURCE"
HOME="$ZSH_HOME" "$PROJECTOR" <<'JSON' >"$WORK_DIR/kimi-inventory.ndjson"
{"v":1,"kind":"inventory","provider":"kimi"}
JSON
python3 - "$WORK_DIR/kimi-inventory.ndjson" "$KIMI_SESSION_ID" <<'PY'
import json, sys
frames = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
items = [frame for frame in frames if frame.get("kind") == "inventory"]
assert len(items) == 1 and items[0]["providerSessionID"] == sys.argv[2]
assert frames[-1]["kind"] == "end"
PY
KIMI_REF="$(python3 - "$WORK_DIR/kimi-inventory.ndjson" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    frame=json.loads(line)
    if frame.get("kind") == "inventory":
        print(frame["transcriptRef"])
        break
PY
)"
HOME="$ZSH_HOME" "$PROJECTOR" <<JSON >"$WORK_DIR/kimi-project.ndjson"
{"v":1,"kind":"project","provider":"kimi","transcriptRef":"$KIMI_REF","limitBytes":262144,"limitRecords":100}
JSON
python3 - "$WORK_DIR/kimi-project.ndjson" <<'PY'
import json, sys
records = [frame["record"] for frame in map(json.loads, open(sys.argv[1], encoding="utf-8")) if frame.get("kind") == "record"]
assert records[1]["type"] == "metadata" and records[1]["model"] == "kimi-code/k3"
assert records[2]["role"] == "user" and records[2]["blocks"][0]["text"] == "inspect the adapter"
assert records[3]["role"] == "assistant" and records[3]["blocks"][0]["text"] == "adapter ready"
PY

# Tier 1 of the title waterfall is the title an agent writes for itself. It can
# fail as well as be absent, and a failure must cost only the title: the same
# projection carries the opening prompt that tiers 2 and 3 are built from, so a
# title the adapter cannot read is dropped rather than raised.
TITLE_SOURCE="$PROJECT_ROOT/malformed-title.jsonl"
python3 - "$TITLE_SOURCE" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"type":"ai-title","aiTitle":{"text":"a structure, not a string"}}) + "\n")
    handle.write(json.dumps({"type":"ai-title","aiTitle":"   "}) + "\n")
    handle.write(json.dumps({"type":"ai-title"}) + "\n")
    handle.write(json.dumps({"type":"user","message":{"role":"user","content":"explain the title waterfall"}}) + "\n")
PY
chmod 600 "$TITLE_SOURCE"
TITLE_REF="$(python3 - "$TITLE_SOURCE" <<'PY'
import base64, sys
print(base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip("="))
PY
)"
HOME="$ZSH_HOME" "$PROJECTOR" <<JSON >"$WORK_DIR/project-malformed-title.ndjson"
{"v":1,"kind":"project","provider":"claude","transcriptRef":"$TITLE_REF","limitBytes":262144,"limitRecords":100}
JSON
python3 - "$WORK_DIR/project-malformed-title.ndjson" <<'PY'
import json, sys
frames = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
records = [frame["record"] for frame in frames if frame.get("kind") == "record"]
assert len(records) == 4, records
for record in records[:3]:
    assert record["type"] == "ai-title"
    title = record.get("title")
    assert not isinstance(title, str) or not title.strip(), record
assert records[3]["role"] == "user"
assert records[3]["blocks"][0]["text"] == "explain the title waterfall"
assert frames[-1]["kind"] == "end"
PY

# pi answers its session name over RPC rather than writing it into the
# transcript, so a name of the wrong type used to fail the whole projection and
# take the opening prompt down with it. A stub pi answers get_state both ways.
PI_ROOT="$ZSH_HOME/.pi/agent/sessions"
PI_SOURCE="$PI_ROOT/session.jsonl"
mkdir -p "$PI_ROOT"
python3 - "$PI_SOURCE" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"type":"session","id":"01a0789e-4284-7605-b065-7dc819c473ec","version":1,"cwd":"/srv/tessera"}) + "\n")
    handle.write(json.dumps({"role":"user","content":[{"type":"text","text":"explain the title waterfall"}]}) + "\n")
PY
chmod 600 "$PI_SOURCE"
PI_BIN="$WORK_DIR/pi-bin"
mkdir -p "$PI_BIN"
cat >"$PI_BIN/pi" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
arguments = sys.argv[1:]
snapshot = arguments[arguments.index("--session") + 1]
lines = [line for line in open(snapshot, encoding="utf-8").read().splitlines() if line]
messages = [json.loads(line) for line in lines[1:]]
name = os.environ.get("TESSERA_STUB_PI_NAME")
if name == "__structured__":
    name = {"text": "a structure, not a string"}
while True:
    line = sys.stdin.readline()
    if not line:
        break
    command = json.loads(line)
    if command["type"] == "get_state":
        data = {
            "isStreaming": False,
            "sessionId": "01a0789e-4284-7605-b065-7dc819c473ec",
            "sessionFile": snapshot,
            "messageCount": len(messages),
            "pendingMessageCount": 0,
        }
        if name is not None:
            data["sessionName"] = name
    else:
        data = {"messages": messages}
    sys.stdout.write(json.dumps({"type":"response","id":command["id"],"command":command["type"],"success":True,"data":data}) + "\n")
    sys.stdout.flush()
STUB
chmod 700 "$PI_BIN/pi"
PI_REF="$(python3 - <<'PY'
import base64
print(base64.urlsafe_b64encode(b"pi:session.jsonl").decode().rstrip("="))
PY
)"
PATH="$PI_BIN:$PATH" TESSERA_STUB_PI_NAME=__structured__ HOME="$ZSH_HOME" "$PROJECTOR" \
  <<JSON >"$WORK_DIR/pi-unreadable-name.ndjson"
{"v":1,"kind":"project","provider":"pi","transcriptRef":"$PI_REF","limitBytes":262144,"limitRecords":100}
JSON
PATH="$PI_BIN:$PATH" TESSERA_STUB_PI_NAME="Calc audit" HOME="$ZSH_HOME" "$PROJECTOR" \
  <<JSON >"$WORK_DIR/pi-named.ndjson"
{"v":1,"kind":"project","provider":"pi","transcriptRef":"$PI_REF","limitBytes":262144,"limitRecords":100}
JSON
python3 - "$WORK_DIR/pi-unreadable-name.ndjson" "$WORK_DIR/pi-named.ndjson" <<'PY'
import json, sys
def frames(path):
    return [json.loads(line) for line in open(path, encoding="utf-8")]
unreadable = frames(sys.argv[1])
assert not any(frame.get("kind") == "error" for frame in unreadable), unreadable
records = [frame for frame in unreadable if frame.get("kind") == "record"]
assert [record["sequence"] for record in records] == [1], records
assert records[0]["record"]["type"] == "message"
assert records[0]["record"]["blocks"][0]["text"] == "explain the title waterfall"
assert unreadable[-1]["kind"] == "end"

named = [frame for frame in frames(sys.argv[2]) if frame.get("kind") == "record"]
assert [record["sequence"] for record in named] == [0, 1], named
assert named[0]["record"]["type"] == "session-title"
assert named[0]["record"]["title"] == "Calc audit"
PY

TRAVERSAL_REF="$(python3 - <<'PY'
import base64
print(base64.urlsafe_b64encode(b"/etc/passwd").decode().rstrip("="))
PY
)"
set +e
HOME="$ZSH_HOME" "$PROJECTOR" <<JSON >"$WORK_DIR/project-traversal.ndjson"
{"v":1,"kind":"project","provider":"claude","transcriptRef":"$TRAVERSAL_REF"}
JSON
TRAVERSAL_STATUS=$?
# Model a host without either PATH Python or a standard package-manager
# interpreter, even when the machine running this hermetic test has one.
sed -e 's|/opt/homebrew/bin/python3|/nonexistent/tessera-test-python3|g' \
    -e 's|/usr/local/bin/python3|/nonexistent/tessera-test-python3|g' \
    "$PROJECTOR" > "$WORK_DIR/projector-no-python.sh"
PATH=/bin HOME="$ZSH_HOME" /bin/sh "$WORK_DIR/projector-no-python.sh" <<'JSON' >"$WORK_DIR/project-no-python.ndjson"
{"v":1,"kind":"inventory","provider":"claude"}
JSON
NO_PYTHON_STATUS=$?
set -e
[[ "$TRAVERSAL_STATUS" != 0 ]]
grep -Fq '"error":"permissionDenied"' "$WORK_DIR/project-traversal.ndjson"
[[ "$NO_PYTHON_STATUS" == 69 ]]
grep -Fq '"detail":"pythonUnavailable"' "$WORK_DIR/project-no-python.ndjson"

SEMANTIC_LAUNCHER="$ZSH_HOME/.config/tessera/tessera-agent-launch"
PROCESS_PROOF="$ZSH_HOME/.config/tessera/tessera-agent-prove"
# A route root alone is not authority: the claimed process must be the exact
# provider binary. Build a test-owned sleeper (rather than renaming an Apple
# platform binary, which macOS terminates for violating its platform signature)
# so both /proc comm and ps argv retain the provider basename.
PROOF_BIN="$WORK_DIR/proof-bin"
mkdir -p "$PROOF_BIN"
PROOF_SLEEPER_SOURCE="$WORK_DIR/proof-sleeper.swift"
printf '%s\n' \
  'import Foundation' \
  'let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 10' \
  'Thread.sleep(forTimeInterval: seconds)' \
  >"$PROOF_SLEEPER_SOURCE"
swiftc -O -module-cache-path "$MODULE_CACHE" "$PROOF_SLEEPER_SOURCE" -o "$WORK_DIR/proof-sleeper"
cp "$WORK_DIR/proof-sleeper" "$PROOF_BIN/claude"
LC_TESSERA_ROUTE='01234567-89ab-cdef-0123-456789abcdef' "$PROOF_BIN/claude" 10 &
CLAUDE_PROOF_CHILD=$!
trap 'kill_children "$CLAUDE_PROOF_CHILD"' EXIT
printf '{"v":1,"claimedPID":%s,"rootPID":%s,"provider":"claude"}\n' "$CLAUDE_PROOF_CHILD" "$$" \
  | HOME="$ZSH_HOME" "$PROCESS_PROOF" >"$WORK_DIR/process-proof-root.json"
grep -Fq '"valid":true' "$WORK_DIR/process-proof-root.json"
grep -Fq '"provider":"claude"' "$WORK_DIR/process-proof-root.json"

# Claude's official self-updater runs a semver-named binary. Accept only its
# exact private install path, then prove a lookalike version-named descendant
# elsewhere is still rejected.
CLAUDE_VERSION_DIR="$ZSH_HOME/.local/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
cp "$WORK_DIR/proof-sleeper" "$CLAUDE_VERSION_DIR/1.2.3"
"$CLAUDE_VERSION_DIR/1.2.3" 10 &
VERSIONED_CLAUDE_PID=$!
printf '{"v":1,"claimedPID":%s,"rootPID":%s,"provider":"claude"}\n' "$VERSIONED_CLAUDE_PID" "$$" \
  | HOME="$ZSH_HOME" "$PROCESS_PROOF" >"$WORK_DIR/process-proof-versioned-claude.json"
grep -Fq '"valid":true' "$WORK_DIR/process-proof-versioned-claude.json"
kill "$VERSIONED_CLAUDE_PID" 2>/dev/null || true
wait "$VERSIONED_CLAUDE_PID" 2>/dev/null || true
cp "$WORK_DIR/proof-sleeper" "$PROOF_BIN/1.2.3"
"$PROOF_BIN/1.2.3" 10 &
VERSION_LOOKALIKE_PID=$!
set +e
printf '{"v":1,"claimedPID":%s,"rootPID":%s,"provider":"claude"}\n' "$VERSION_LOOKALIKE_PID" "$$" \
  | HOME="$ZSH_HOME" "$PROCESS_PROOF" >"$WORK_DIR/process-proof-version-lookalike.json"
VERSION_LOOKALIKE_STATUS=$?
set -e
[[ "$VERSION_LOOKALIKE_STATUS" != 0 ]]
grep -Fq '"error":"providerMismatch"' "$WORK_DIR/process-proof-version-lookalike.json"
kill "$VERSION_LOOKALIKE_PID" 2>/dev/null || true
wait "$VERSION_LOOKALIKE_PID" 2>/dev/null || true

# A forged lifecycle OSC can name any descendant of the real route. It must
# not upgrade that shell-owned sleep process to Claude authority.
sleep 10 &
FORGED_PROOF_CHILD=$!
set +e
printf '{"v":1,"claimedPID":%s,"rootPID":%s,"provider":"claude"}\n' "$FORGED_PROOF_CHILD" "$$" \
  | HOME="$ZSH_HOME" "$PROCESS_PROOF" >"$WORK_DIR/process-proof-forged.json"
FORGED_PROOF_STATUS=$?
set -e
[[ "$FORGED_PROOF_STATUS" != 0 ]]
grep -Fq '"error":"providerMismatch"' "$WORK_DIR/process-proof-forged.json"
kill "$FORGED_PROOF_CHILD" 2>/dev/null || true
wait "$FORGED_PROOF_CHILD" 2>/dev/null || true

PROOF_MARKER='01234567-89ab-cdef-0123-456789abcdef'
LC_TESSERA_ROUTE="$PROOF_MARKER" "$PROOF_BIN/claude" 10 &
PROOF_CHILD=$!
trap 'kill_children "$PROOF_CHILD" "$CLAUDE_PROOF_CHILD"' EXIT
set +e
printf '{"v":1,"claimedPID":%s,"routeMarker":"%s","provider":"claude"}\n' "$PROOF_CHILD" "$PROOF_MARKER" \
  | HOME="$ZSH_HOME" "$PROCESS_PROOF" >"$WORK_DIR/process-proof-marker.json"
PROOF_MARKER_STATUS=$?
set -e
if [[ -r "/proc/$PROOF_CHILD/environ" ]]; then
  # Linux remote hosts expose the exact environment inherited from the
  # SSH-server-accepted PTY marker, so prove the positive route-binding path.
  [[ "$PROOF_MARKER_STATUS" == 0 ]]
  grep -Fq '"valid":true' "$WORK_DIR/process-proof-marker.json"
else
  # macOS deliberately withholds another process's environment from ps. Keep
  # the host-side test deterministic and verify the proof fails closed there;
  # the Linux fixture lane above is the authoritative positive marker test.
  [[ "$PROOF_MARKER_STATUS" != 0 ]]
  grep -Fq '"error":"unrelatedProcess"' "$WORK_DIR/process-proof-marker.json"
fi
kill "$PROOF_CHILD" 2>/dev/null || true
wait "$PROOF_CHILD" 2>/dev/null || true
trap - EXIT
set +e
printf '%s\n' '{"v":1,"requestID":"00000000-0000-4000-8000-000000000001","kind":"spawn","provider":"claude","directory":"/tmp","task":"ok","isolation":{"kind":"worktree","branch":"bad;touch-pwned"}}' \
  | HOME="$ZSH_HOME" "$SEMANTIC_LAUNCHER" >"$WORK_DIR/launch-injection.ndjson"
LAUNCH_INJECTION_STATUS=$?
set -e
[[ "$LAUNCH_INJECTION_STATUS" != 0 ]]
grep -Fq '"error":"invalidBranch"' "$WORK_DIR/launch-injection.ndjson"
[[ ! -e "$WORK_DIR/touch-pwned" ]]

# tmux show-buffer appends a newline to the buffer it displays. Exercise that
# exact transport shape while retaining strict validation of the base64 body.
LAUNCH_MARKER="$WORK_DIR/fake-launch-claude-invoked"
LAUNCH_REQUEST='{"v":1,"requestID":"00000000-0000-4000-8000-000000000002","kind":"spawn","provider":"claude","directory":"/tmp","task":"tmux newline","isolation":{"kind":"current"}}'
LAUNCH_ENCODED="$(printf '%s' "$LAUNCH_REQUEST" | base64 | tr -d '\n')"
printf '%s\n' "$LAUNCH_ENCODED" \
  | HOME="$ZSH_HOME" PATH="$FAKE_BIN:/usr/bin:/bin" TMUX_PANE= TESSERA_FAKE_CLAUDE_MARKER="$LAUNCH_MARKER" \
      "$SEMANTIC_LAUNCHER" --request-base64-stdin >"$WORK_DIR/launch-base64-newline.ndjson"
grep -Fq '"kind":"launchReceipt"' "$WORK_DIR/launch-base64-newline.ndjson"
[[ -f "$LAUNCH_MARKER" ]]

printf 'agent integration scripts: syntax, install, lifecycle v9, bounded projection, safe launch, Claude compatibility, and Codex bootstrap passed\n'
script_completed=1
