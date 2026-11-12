#!/usr/bin/env python3
"""Two real Codex TUIs on one shared app-server, against the scripted Responses
API, in a disposable tmux server, HOME and CODEX_HOME with the production hooks.

The server runs every thread's hooks with the first TUI's environment, so the
hooks alone would put both threads on the first pane. Each pane must carry its
own thread under its own TUI, an idle /new must clear the pane, a thread
named later must be adopted, and a thread resumed idle through the shim must
be adopted from its title, all without a new hook event.

Usage: codex_shared_server.py RUN_DIR DUMPER EVIDENCE_DIR
"""

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
from urllib.request import urlopen


RUN = Path(sys.argv[1]).resolve()
DUMPER = Path(sys.argv[2]).resolve()
EVIDENCE = Path(sys.argv[3]).resolve()
SOURCE = Path(__file__).resolve().parent
HOME = RUN / "home"
CODEX_HOME = RUN / "codex-home"
WORK = RUN / "work"
SOCKET = str(RUN / "codex-shared.sock")
# The caller may have Tessera's real-home PATH shims ahead of the CLI binaries.
PATH = os.pathsep.join(part for part in os.environ.get("PATH", "").split(os.pathsep)
                       if part and not part.rstrip("/").endswith("/.config/tessera/bin"))
CODEX = shutil.which("codex", path=PATH)
FIRST = "%0"
# Every lane process inherits the private CODEX_HOME; a command line proves
# nothing, since any process can name the run directory.
OWNED = b"CODEX_HOME=" + os.fsencode(CODEX_HOME)
mock = []
cleaned = []
transcript = []


def note(message):
    line = f"{time.strftime('%H:%M:%S')} {message}"
    transcript.append(line)
    print(line, flush=True)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, env=None, check=True, timeout=30):
    result = subprocess.run(args, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stdout[-2000:]}")
    return result


def private_env():
    # No provider credentials, XDG paths or the caller's HOME.
    return {"HOME": str(HOME), "PATH": PATH or "/usr/bin:/bin", "SHELL": "/bin/sh",
            "TERM": "xterm-256color", "LANG": os.environ.get("LANG", "en_US.UTF-8"),
            "CODEX_HOME": str(CODEX_HOME), "MOCK_OPENAI_KEY": "mock"}


def tmux(*args, check=True):
    return run(["tmux", "-S", SOCKET, *args], env=private_env(), check=check)


def processes():
    table = {}
    for line in run(["ps", "-axo", "pid=,ppid=,command="]).stdout.splitlines():
        fields = line.split(None, 2)
        if len(fields) >= 2:
            table[int(fields[0])] = (int(fields[1]), fields[2] if len(fields) == 3 else "")
    return table


def descendants(root, table):
    found, pending = set(), [root]
    while pending:
        pid = pending.pop()
        if pid not in found:
            found.add(pid)
            pending.extend(child for child, (parent, _) in table.items() if parent == pid)
    return found


def pane_pids():
    pairs = {}
    for line in tmux("list-panes", "-a", "-F", "#{pane_id} #{pane_pid}", check=False).stdout.splitlines():
        pane, pid = line.split()
        pairs[pane] = int(pid)
    return pairs


def process_environment(pid):
    """The environment a process started with; empty when it is gone or not
    this user's."""
    try:
        if sys.platform.startswith("linux"):
            return Path(f"/proc/{pid}/environ").read_bytes().split(b"\0")
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        # KERN_PROCARGS2: argc, the executable path, the arguments, then the
        # environment up to an empty string.
        mib = (ctypes.c_int * 3)(1, 49, pid)
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) or size.value < 4:
            return []
        buffer = ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0):
            return []
        data = buffer.raw[:size.value]
        count = int.from_bytes(data[:4], sys.byteorder)
        strings = data[data.index(b"\0", 4):].lstrip(b"\0").split(b"\0")
        environment = []
        for value in strings[count:]:
            if not value:
                break
            environment.append(value)
        return environment
    except (OSError, ValueError):
        return []


def lane_owned(pid):
    return pid != os.getpid() and OWNED in process_environment(pid)


def capture(pane):
    return tmux("capture-pane", "-p", "-t", pane).stdout


def title(pane):
    return tmux("display-message", "-p", "-t", pane, "#{pane_title}").stdout.rstrip("\n")


def frame(pane):
    raw = tmux("show-options", "-pqv", "-t", pane, "@tessera_agent_state", check=False).stdout.strip()
    return json.loads(raw) if raw else {}


def answer_setup_dialog(pane):
    """Trusts the lane's own installed hooks; a TUI started before another
    trusted them shows the review table instead."""
    screen = capture(pane)
    if "t trust all" in screen:
        tmux("send-keys", "-t", pane, "t")
        time.sleep(0.8)
        if "trust all" in capture(pane):
            tmux("send-keys", "-t", pane, "Escape")
    elif "Hooks need review" in screen:
        # "2. Trust all and continue".
        tmux("send-keys", "-t", pane, "-H", "32")
        time.sleep(0.4)
        tmux("send-keys", "-t", pane, "Enter")
    elif "Lifecycle hooks from config" in screen and "esc close" in screen:
        # Keys typed while the review table opened can leave the hook list.
        tmux("send-keys", "-t", pane, "Escape")
        note(f"{pane}: closed the hook list")
        time.sleep(0.8)
        return True
    else:
        return False
    note(f"{pane}: trusted the installed hooks")
    time.sleep(0.8)
    return True


def wait(predicate, label, timeout=60, pane=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        if pane is not None:
            answer_setup_dialog(pane)
        time.sleep(0.25)
    screens = " || ".join(f"{name}: {capture(name)[-800:]}" for name in pane_pids())
    raise RuntimeError(f"timed out waiting for {label}; {screens}")


def composer_ready(pane):
    screen = capture(pane)
    return (re.search(r"(?m)^\s*›", screen) is not None and "Hooks need review" not in screen
            and "trust all" not in screen and "esc to interrupt" not in screen and "esc close" not in screen)


def submit(pane, text):
    tmux("send-keys", "-t", pane, "-l", text)
    time.sleep(0.4)
    tmux("send-keys", "-t", pane, "Enter")


def mock_requests():
    log = EVIDENCE / "mock-prompts.jsonl"
    return log.read_text(errors="replace").splitlines() if log.exists() else []


def prompt(pane, text):
    # The hook review can open late and swallow the keys, so a prompt is sent
    # only once the scripted API has it.
    for attempt in range(3):
        wait(lambda: composer_ready(pane), f"{pane} composer for {text!r}", 60, pane)
        before = len(mock_requests())
        submit(pane, text)
        try:
            wait(lambda: any(text in line for line in mock_requests()[before:]), f"the API to receive {text!r}", 20, pane)
            break
        except RuntimeError:
            if attempt == 2:
                raise
            note(f"{pane}: {text!r} never reached the API; sending it again")
    wait(lambda: "OK." in capture(pane) and composer_ready(pane), f"{pane} reply to {text!r}", 60, pane)
    time.sleep(0.5)
    wait(lambda: composer_ready(pane), f"{pane} reply to {text!r} to settle", 30, pane)


def rename(pane, name):
    # The scripted API answers Codex's title request with "OK." for every
    # thread, so the lane names its threads itself.
    submit(pane, f"/rename {name}")
    time.sleep(1.5)
    if name not in title(pane):
        submit(pane, name)
    wait(lambda: name in title(pane), f"{pane} title showing {name!r}", 20, pane)


def thread_named(name):
    index = CODEX_HOME / "session_index.jsonl"
    found = None
    for line in index.read_text().splitlines() if index.exists() else ():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if record.get("thread_name") == name:
            found = record.get("id")
    require(found, f"no thread named {name!r} in the session index")
    return found


def tui_pid(pane):
    table = processes()
    tree = descendants(pane_pids()[pane], table)
    clients = [pid for pid in tree if os.path.basename(table[pid][1].split()[0]) == "codex"
               and "app-server" not in table[pid][1]]
    innermost = [pid for pid in clients if not any(table[other][0] == pid for other in clients)]
    require(len(innermost) == 1, f"{pane} has no single Codex TUI: {clients}")
    return innermost[0]


def expect_frame(pane, session_id, agent_pid, label):
    value = frame(pane)
    note(f"{pane} {label}: session={value.get('sessionId')!r} agentPid={value.get('agentPid')} event={value.get('event')}")
    require(value.get("sessionId") == session_id and value.get("agentPid") == agent_pid,
            f"{pane} {label}: expected session {session_id!r} under {agent_pid}, got {value}")


def configure(port):
    (CODEX_HOME / "config.toml").write_text(f'''model = "gpt-6-sol"
model_provider = "mock"
model_catalog_json = "{SOURCE / 'codex-model-catalog.json'}"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
check_for_update_on_startup = false

[model_providers.mock]
name = "Mock"
base_url = "http://127.0.0.1:{port}/v1"
wire_api = "responses"
env_key = "MOCK_OPENAI_KEY"
supports_websockets = false
stream_idle_timeout_ms = 600000
request_max_retries = 0
stream_max_retries = 0

[projects."{WORK}"]
trust_level = "trusted"

[tui]
screen_reader_detection_done = true
''')
    command = run([str(DUMPER), "install-command"]).stdout
    status = run(["/bin/sh", "-c", command], env=private_env(), timeout=90).stdout
    (EVIDENCE / "production-install-status.txt").write_text(status)
    require("TESSERA_AGENT_INTEGRATION_STATUS current" in status,
            f"production hook install did not verify: {status[-1500:]}")


def start_mock():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    with (EVIDENCE / "mock-server.txt").open("w") as output:
        process = subprocess.Popen([sys.executable, "-u", str(SOURCE / "mock_responses.py"), str(port),
                                    str(SOURCE / "codex-model-catalog.json"), "240",
                                    str(EVIDENCE / "mock-prompts.jsonl")],
                                   env=private_env(), stdout=output, stderr=subprocess.STDOUT)
    mock.append(process)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        require(process.poll() is None, "mock exited on startup")
        try:
            with urlopen(f"http://127.0.0.1:{port}/", timeout=0.5):
                return port
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("mock could not bind")


def launch(new_window, arguments=(), program=None):
    # tmux runs this through its shell, which expands this private server's
    # TMUX and the pane's TMUX_PANE; without them the hooks would query the
    # caller's default tmux server.
    values = " ".join(f"{key}={shlex.quote(value)}" for key, value in private_env().items())
    words = " ".join(shlex.quote(word) for word in [program or CODEX, *arguments])
    command = f'exec env -i TMUX="$TMUX" TMUX_PANE="$TMUX_PANE" {values} {words}'
    if new_window:
        # The first window is named after Codex too; the colon names the session.
        tmux("new-window", "-t", "shared:", "-c", str(WORK), command)
    else:
        tmux("new-session", "-d", "-s", "shared", "-x", "120", "-y", "36", "-c", str(WORK), command)


def main():
    require(CODEX, "codex is not installed")
    for directory in (HOME, CODEX_HOME, WORK, EVIDENCE):
        directory.mkdir(parents=True, exist_ok=True)
    configure(start_mock())
    note(f"{run([CODEX, '--version']).stdout.strip()}; production hooks installed in a disposable home")
    launch(False)
    wait(lambda: composer_ready(FIRST), "the first composer", 90, FIRST)
    # The hook trust dialog can follow the first composer.
    settle = time.monotonic() + 4
    while time.monotonic() < settle:
        wait(lambda: composer_ready(FIRST), "the first composer to settle", 30, FIRST)
        time.sleep(0.5)
    launch(True)
    second = next(pane for pane in pane_pids() if pane != FIRST)
    wait(lambda: composer_ready(second), "the second composer", 90, second)
    servers = wait(lambda: [pid for pid, (_, args) in processes().items()
                            if " app-server --listen " in args and lane_owned(pid)], "the shared app-server", 15)
    require(len(servers) == 1, f"expected one shared app-server, found {servers}")
    clients = {FIRST: tui_pid(FIRST), second: tui_pid(second)}
    note(f"server {servers[0]}; TUIs {clients}")

    for pane, name in ((FIRST, "Alpha shared thread"), (second, "Beta shared thread")):
        prompt(pane, f"first prompt for the {name}")
        rename(pane, name)
    alpha, beta = thread_named("Alpha shared thread"), thread_named("Beta shared thread")
    # Both threads' hooks now run in the one server.
    for pane in (FIRST, second):
        prompt(pane, "a prompt after naming")
    time.sleep(2)
    expect_frame(FIRST, alpha, clients[FIRST], "after a turn")
    expect_frame(second, beta, clients[second], "after a turn")
    marks = sorted(path.name for path in (HOME / ".config/tessera/agent-runtime-state").glob("*.shared-server"))
    require(marks == sorted(f"{pid}.shared-server" for pid in clients.values()), f"marks: {marks}")
    observers = [pid for pid, (_, args) in processes().items() if "--watch-shared" in args and lane_owned(pid)]
    note(f"bound clients {marks}; shared observers running: {len(observers)}")

    # No hook runs for an idle /new until the next prompt.
    submit(FIRST, "/new")
    started = time.monotonic()
    wait(lambda: frame(FIRST).get("sessionId") == "", "the observer to clear the first pane", 15)
    note(f"/new cleared {FIRST} after {time.monotonic() - started:.1f}s")
    expect_frame(FIRST, "", clients[FIRST], "after /new")
    expect_frame(second, beta, clients[second], "while the first pane starts over")
    prompt(FIRST, "a prompt in the fresh thread")
    rename(FIRST, "Gamma shared thread")
    gamma = thread_named("Gamma shared thread")
    started = time.monotonic()
    wait(lambda: frame(FIRST).get("sessionId") == gamma, "the observer to adopt the renamed thread", 15)
    note(f"{FIRST} adopted the renamed thread after {time.monotonic() - started:.1f}s")
    expect_frame(FIRST, gamma, clients[FIRST], "after the rename")
    expect_frame(second, beta, clients[second], "after the rename")

    # A thread resumed while idle runs no hook before its first turn. The
    # shim's observer finds the client unbound and adopts the thread its
    # title shows; no other pane shows Alpha now.
    shim = HOME / ".config/tessera/bin/codex"
    require(shim.is_file(), "the production install left no codex shim")
    panes = set(pane_pids())
    launch(True, ["resume", alpha], str(shim))
    third = wait(lambda: next(iter(set(pane_pids()) - panes), None), "the third pane", 15)
    wait(lambda: composer_ready(third) and "Alpha shared thread" in title(third), f"{third} to show the resumed thread", 90, third)
    clients[third] = tui_pid(third)
    started = time.monotonic()
    wait(lambda: frame(third).get("sessionId") == alpha, "the observer to adopt the resumed thread", 30, third)
    note(f"{third} adopted the idle resumed thread after {time.monotonic() - started:.1f}s")
    expect_frame(third, alpha, clients[third], "after an idle resume")
    expect_frame(FIRST, gamma, clients[FIRST], "at the end")
    expect_frame(second, beta, clients[second], "at the end")
    marks = sorted(path.name for path in (HOME / ".config/tessera/agent-runtime-state").glob("*.shared-server"))
    require(marks == sorted(f"{pid}.shared-server" for pid in clients.values()), f"marks after the resume: {marks}")
    ignored = [line for line in (HOME / ".config/tessera/agent-lifecycle-diagnostics.log").read_text().splitlines()
               if "phase=ignored source=shared-server" in line]
    # The hook leaves these to the binder, which publishes the newest of
    # each thread once a pane shows it.
    note(f"events the hook left to the binder before their thread was named: {len(ignored)}")


def stop_lane_processes():
    """SIGTERM, then SIGKILL, each only to a process whose environment still
    shows it belongs to the lane; returns what is left."""
    for number, grace in ((signal.SIGTERM, 3.0), (signal.SIGKILL, 1.0)):
        owned = [pid for pid in processes() if lane_owned(pid)]
        for pid in owned:
            if lane_owned(pid):
                try:
                    os.kill(pid, number)
                except OSError:
                    pass
        deadline = time.monotonic() + grace
        while owned and time.monotonic() < deadline:
            time.sleep(0.1)
            owned = [pid for pid in owned if lane_owned(pid)]
        if not owned:
            return []
    return [pid for pid in processes() if lane_owned(pid)]


def cleanup():
    if cleaned:
        return True
    cleaned.append(True)
    try:
        for pane in pane_pids():
            (EVIDENCE / f"screen-{pane.lstrip('%')}.txt").write_text(capture(pane))
    except Exception:
        pass
    run(["tmux", "-S", SOCKET, "kill-server"], check=False)
    for process in mock:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    # The managed daemon left the tmux server by setsid; observers exit with
    # their client.
    left = stop_lane_processes()
    if left:
        note(f"FAIL: lane processes survived SIGKILL: {left}")
    diagnostics = HOME / ".config/tessera/agent-lifecycle-diagnostics.log"
    if diagnostics.exists():
        shutil.copyfile(diagnostics, EVIDENCE / "agent-lifecycle-diagnostics.log")
    (EVIDENCE / "lane.log").write_text("\n".join(transcript) + "\n")
    return not left


def interrupted(number, _frame):
    raise KeyboardInterrupt(f"signal {number}")


for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signal_number, interrupted)
passed = False
try:
    main()
    passed = True
except BaseException as error:
    note(f"FAIL: {error or type(error).__name__}")
finally:
    # A second signal must not cut cleanup short.
    for signal_number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(signal_number, signal.SIG_IGN)
    passed = cleanup() and passed
if passed:
    note("codex shared server: each pane kept its own thread; /new, a later name and an idle resume followed without a hook")
sys.exit(0 if passed else 1)
