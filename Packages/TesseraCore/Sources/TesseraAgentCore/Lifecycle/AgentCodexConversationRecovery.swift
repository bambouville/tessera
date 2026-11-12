import Foundation

extension RemoteAgentLifecycleIntegrationInstaller {
    /// Repairs only the legacy Codex `transcript_path: null` frame. The hook
    /// installed by current versions ignores that event, so this is deliberately
    /// a one-way, bounded migration rather than a general state reconciler.
    public static let codexConversationRecoveryScript = #"""
#!/bin/sh

# Tessera Agent Center Codex conversation recovery — safe to delete.
set -u

command -v python3 >/dev/null 2>&1 || exit 0
if [ "$#" -eq 0 ] && ! command -v tmux >/dev/null 2>&1; then exit 0; fi
TESSERA_AGENT_RECOVERY_SUPPORT_DIR="${0%/*}"
export TESSERA_AGENT_RECOVERY_SUPPORT_DIR

python3 -I -c 'import base64
import calendar
import datetime
import hashlib
import json
import os
import pwd
import re
import select
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata

MAX_PANES = 128
MAX_DEPTH = 128
MAX_FDS = 512
MAX_HEADER = 262144
MAX_TAIL = 262144
MAX_OUTPUT = 1048576
TOKEN = re.compile(r"^[A-Za-z0-9._:-]{1,256}$")
CODEX_COMMANDS = {"codex", "codex-cli"}
# The npm launcher keeps the native binary in a child process; its own PID
# stays node for the whole session.
NODE_COMMANDS = {"node", "nodejs"}
# Resolved once at import so every entry point (and the hermetic function
# tests, which never call main) shares one sessions root; main re-resolves it.
SESSIONS_ROOT = os.path.realpath(os.path.join(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"), "sessions"))
SESSION_INDEX = os.path.join(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"), "session_index.jsonl")
# A shared server holds every hosted thread and its tools; its clients are
# looked up among all panes.
MAX_SERVER_FDS = 8192
MAX_SHARED_PANES = 1024
MAX_TREE = 4096
MAX_INDEX = 8388608
MAX_TITLE = 240
SHARED_DEADLINE = 0.75
# What binding leaves of that deadline to hand an event it could not bind
# to a binder.
SHARED_HANDOFF = 0.15
# A thread whose events ran before any pane could show it, as when a turn
# ends before Codex names the thread, binds once one does: within the
# window after its newest such event. A binder tries an unchanged title
# again up to every SHARED_LATER_RETRY seconds; past its ceiling, as while a
# thread no pane shows keeps running tools, it tries only every
# SHARED_LATER_SLOW seconds, whatever changed.
SHARED_LATER = 60
SHARED_LATER_CEILING = 300
SHARED_LATER_DEADLINE = 5
SHARED_LATER_RETRY = 8
SHARED_LATER_SLOW = 30
# Events a bound binder publishes in a row before it waits again.
SHARED_REPLAYS = 4
# How long the child of a hook that could not read the open files of its
# Codex waits for them, to publish the event of the hook.
NATIVE_LATER = 60
# A hook and a binder hold the record of a thread only briefly.
PENDING_WAIT = 0.5
# The events a binder may publish late: the latest one of a root thread.
SHARED_LATER_EVENTS = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure"}
SHARED_LATER_STATES = {"waitingForInput", "working", "idle"}
# What a claim can record: a published event, or an ending a binder
# publishes past.
CLAIM_EVENTS = {"SessionStart", "SubagentStart", "SubagentStop", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure"}
ENDED_EVENTS = {"SessionEnd", "WrapperExit"}
# While set, every command ends by then: the hook waits on the binder.
RUN_DEADLINE = None
# What a ps that failed to fork or answered late left undecided, a caller
# that would otherwise give up asks again for up to this long.
SETTLE = 5
CODEX_CONFIGS = (os.path.join(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"), "config.toml"), "/etc/codex/config.toml", "/etc/codex/managed_config.toml")
MAX_CONFIG = 1048576
# Title items that show a thread by its name or ID only, or no text.
PLAIN_TITLE_ITEMS = {"activity", "spinner", "thread-name", "thread-title", "thread", "project-name", "project", "thread-id", "session-id"}
# A Codex profile name, which names its config file.
PROFILE_NAME = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
# The activity item can show these as an item of its own.
ACTIVITY_ITEMS = {"[ ! ] Action Required", "[ . ] Action Required"}
# A longer value whose cut cannot be told decides nothing.
MAX_CUT = 256
# A title that more roots can be read in decides nothing.
MAX_SHOWN = 4
INDEX_ID = re.compile(rb"\"id\"\s*:\s*\"([A-Za-z0-9._:-]{1,256})\"")
INDEX_CACHE = {}
HEADER_CACHE = {}
# Root options that take a value, as the hook and the shim read them.
CODEX_VALUE_OPTIONS = {"-c", "--config", "--enable", "--disable", "-m", "--model", "-p", "--profile", "-C", "--cd", "-s", "--sandbox", "-a", "--ask-for-approval", "--add-dir", "--local-provider", "--remote", "--remote-auth-token-env"}
TITLE_HIDDEN = {0x00AD, 0x034F, 0x061C, 0x180E, 0xFEFF}
TITLE_HIDDEN_RANGES = ((0x200B, 0x200F), (0x202A, 0x202E), (0x2060, 0x206F), (0xFE00, 0xFE0F), (0xFFF9, 0xFFFB), (0x1BCA0, 0x1BCA3), (0xE0100, 0xE01EF))
SCREEN_GLYPHS = {"\u280b": "|", "\u283c": "|", "\u2807": "|", "\u2819": "/", "\u2834": "/", "\u280f": "/", "\u2839": "-", "\u2826": "-", "\u2838": "\\", "\u2827": "\\", "\u25cf": "*"}
# Spinner frames and the microphone dot, also as GNU screen shows them.
TITLE_GLYPHS = re.compile("[\u2800-\u28ff\u25cf]+|[|/*\\\\-]")

# Set by the last run whose command was present but could not start, as on a
# failed fork: its answer decides nothing about the command.
RUN_UNSTARTED = False

def run(argv, limit=MAX_OUTPUT, env=None):
    global RUN_UNSTARTED
    RUN_UNSTARTED = False
    process = None
    try:
        deadline = time.monotonic() + 2
        if RUN_DEADLINE is not None:
            deadline = min(deadline, RUN_DEADLINE)
            if deadline <= time.monotonic():
                return None
        try:
            process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        except FileNotFoundError:
            return None
        except OSError:
            RUN_UNSTARTED = True
            return None
        output = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError()
            readable, _, _ = select.select([process.stdout], [], [], remaining)
            if not readable:
                raise TimeoutError()
            chunk = os.read(process.stdout.fileno(), min(65536, limit + 1 - len(output)))
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > limit:
                return None
        if process.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
            return None
        return bytes(output)
    except Exception:
        return None
    finally:
        if process is not None and process.poll() is None:
            try:
                process.kill()
                process.wait(timeout=0.1)
            except Exception:
                pass
        if process is not None and process.stdout is not None:
            try:
                process.stdout.close()
            except Exception:
                pass

def current_uid(pid):
    try:
        if os.path.isdir("/proc"):
            return os.stat("/proc/%d" % pid).st_uid
    except Exception:
        pass
    raw = run(["ps", "-o", "uid=", "-p", str(pid)], 128)
    if raw is None:
        return None
    try:
        return int(raw.decode("ascii", "strict").strip())
    except Exception:
        return None

def parent_pid(pid):
    try:
        with open("/proc/%d/stat" % pid, "rb") as source:
            stat_line = source.read(4096).decode("ascii", "strict")
        close = stat_line.rfind(")")
        fields = stat_line[close + 2:].split()
        return int(fields[1])
    except Exception:
        pass
    raw = run(["ps", "-o", "ppid=", "-p", str(pid)], 128)
    if raw is None:
        return None
    try:
        return int(raw.decode("ascii", "strict").strip())
    except Exception:
        return None

def command_name(pid):
    try:
        with open("/proc/%d/comm" % pid, "rb") as source:
            value = source.read(256).decode("utf-8", "strict").strip()
        return os.path.basename(value)
    except Exception:
        pass
    raw = run(["ps", "-o", "comm=", "-p", str(pid)], 4096)
    if raw is None:
        return None
    try:
        return os.path.basename(raw.decode("utf-8", "strict").strip())
    except Exception:
        return None

def is_codex(pid):
    # Whether the process is a Codex of this user; None when a ps that
    # failed to fork or answered late, which on macOS reads the owner and
    # the command, could not tell. A caller that needs a yes takes that as
    # a no; one that would give up on it waits for a definite answer.
    if pid <= 1:
        return False
    owner = current_uid(pid)
    if owner is not None and owner != os.getuid():
        return False
    name = command_name(pid)
    if name is not None and name not in CODEX_COMMANDS:
        return False
    return None if owner is None or name is None else True

def is_codex_launcher(pid):
    # Whether a node process of this user runs the npm launcher of Codex;
    # None when a ps that failed to fork or answered late could not tell.
    owner = current_uid(pid)
    if owner is not None and owner != os.getuid():
        return False
    name = command_name(pid)
    if name is not None and name not in NODE_COMMANDS:
        return False
    if owner is None or name is None:
        return None
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as source:
            arguments = source.read(65536).decode("utf-8", "strict").split("\0")[1:]
    except Exception:
        raw = run(["ps", "-o", "args=", "-p", str(pid)], 65536)
        if raw is None:
            return None
        try:
            arguments = raw.decode("utf-8", "strict").split()[1:]
        except Exception:
            return False
    if any("@openai/codex" in argument or os.path.basename(argument) == "codex.js" for argument in arguments):
        return True
    # A global npm install runs the launcher through a bin symlink, such as
    # ~/.local/bin/codex, and node keeps the path it was given.
    script = next((argument for argument in arguments if not argument.startswith("-")), "")
    if not script.startswith("/"):
        return False
    try:
        script = os.path.realpath(script)
    except Exception:
        return False
    return "/@openai/codex/" in script or os.path.basename(script) == "codex.js"

def native_codex_child(pid, start_token):
    raw = run(["ps", "-axo", "pid=,ppid="])
    if raw is None:
        return None
    try:
        parents = dict(tuple(map(int, line.split())) for line in raw.decode("ascii", "strict").splitlines())
    except Exception:
        return None
    candidates = []
    for child in parents:
        ancestor = child
        for _ in range(3):
            ancestor = parents.get(ancestor)
            if ancestor == pid:
                # A child a ps could not tell, as one that failed to fork
                # or answered late, leaves the answer to the next poll
                # rather than to the candidates told.
                name = command_name(child)
                if name is None:
                    return None
                if name in CODEX_COMMANDS:
                    codex = is_codex(child)
                    token = process_start_token(child) if codex else None
                    if codex is None or (codex and token is None):
                        return None
                    if codex:
                        candidates.append((child, token))
                break
            if ancestor is None or ancestor <= 1:
                break
    # The first TUI starts the shared server as its child; neither the server
    # nor a tool it runs is the TUI. A Codex whose arguments cannot be read
    # stays a candidate.
    servers = {child for child, _ in candidates if codex_server(child)}
    clients = []
    for child, token in candidates:
        ancestor = child
        for _ in range(4):
            if ancestor == pid or ancestor in servers:
                break
            ancestor = parents.get(ancestor)
        if ancestor == pid:
            clients.append((child, token))
    if len(clients) != 1:
        return None
    child, token = clients[0]
    ancestor = child
    for _ in range(3):
        ancestor = parent_pid(ancestor)
        if ancestor == pid:
            if process_start_token(pid) == start_token and is_codex_launcher(pid) and watcher_live(child, token):
                return child, token
            break
        if ancestor is None or ancestor <= 1 or current_uid(ancestor) != os.getuid():
            break
    return None

def descendant(child, ancestor):
    # None when a parent could not be read, as from a ps that failed to
    # fork or answered late.
    if child <= 1 or ancestor <= 1:
        return False
    seen = set()
    for _ in range(MAX_DEPTH):
        if child in seen:
            return False
        seen.add(child)
        if child == ancestor:
            return True
        child = parent_pid(child)
        if child is None:
            return None
        if child <= 1:
            return False
    return False

def safe_file(path, sessions_root, expected=None):
    try:
        if not os.path.isabs(path):
            return None
        real = os.path.realpath(path)
        if os.path.commonpath([real, sessions_root]) != sessions_root:
            return None
        listed = os.lstat(path)
        if stat.S_ISLNK(listed.st_mode) or not stat.S_ISREG(listed.st_mode):
            return None
        # The owner sets the mode of their own transcript; umask 0002 hosts
        # leave every rollout group-writable and it is still theirs.
        if listed.st_uid != os.getuid():
            return None
        # A FIFO that replaced it after the lstat never holds the open.
        flags = os.O_RDONLY | os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        identity = (opened.st_dev, opened.st_ino)
        if identity != (listed.st_dev, listed.st_ino):
            return None
        if expected is not None and identity != expected:
            return None
        return real, identity
    except Exception:
        return None

def session_jsonl_path(path, sessions_root):
    try:
        if not os.path.isabs(path):
            return False
        real = os.path.realpath(path)
        return os.path.commonpath([real, sessions_root]) == sessions_root and real.endswith(".jsonl")
    except Exception:
        return False

def linux_open_files_strict(pid, sessions_root, limit=MAX_FDS):
    # The session files the process holds open: False when it holds one
    # that is unsafe, None when they could not be read, as when a file
    # closed meanwhile.
    directory = "/proc/%d/fd" % pid
    try:
        entries = sorted(os.listdir(directory), key=lambda value: int(value))
    except Exception:
        return None
    if len(entries) > limit:
        return None
    result = []
    for entry in entries:
        link = directory + "/" + entry
        try:
            path = os.readlink(link)
            fd_stat = os.stat(link)
        except Exception:
            return None
        checked = safe_file(path, sessions_root, (fd_stat.st_dev, fd_stat.st_ino))
        if checked is not None:
            result.append((checked[0], checked[1]))
        elif session_jsonl_path(path, sessions_root):
            return False
    return result

def linux_open_files(pid, sessions_root):
    # Unsafe files read as none; None still means unread.
    result = linux_open_files_strict(pid, sessions_root)
    return [] if result is False else result

def mac_open_files_strict(pid, sessions_root):
    # As on Linux; None too when lsof failed to fork or answered late.
    raw = run(["lsof", "-a", "-p", str(pid), "-Fn"], MAX_OUTPUT)
    if raw is None:
        return None
    result = []
    for line in raw.splitlines():
        if not line.startswith(b"n"):
            continue
        try:
            path = line[1:].decode("utf-8", "strict")
        except Exception:
            continue
        checked = safe_file(path, sessions_root)
        if checked is not None:
            result.append((checked[0], checked[1]))
        elif session_jsonl_path(path, sessions_root):
            return False
    return result

def mac_open_files(pid, sessions_root):
    result = mac_open_files_strict(pid, sessions_root)
    return [] if result is False else result

def root_metadata(path, identity):
    header = root_header(path, identity)
    return None if header is None else header[0]

def root_header(path, identity):
    payload = rollout_header(path, identity)
    session_id = None if payload is None else root_fields(path, payload)
    return None if session_id is None else (session_id, payload)

def rollout_header(path, identity):
    # A rollout never rewrites its first line, so an observer reads it once.
    key = (path, identity)
    if key in HEADER_CACHE:
        return HEADER_CACHE[key]
    try:
        flags = os.O_RDONLY | os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) != identity:
                return None
            if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid():
                return None
            with os.fdopen(descriptor, "rb", closefd=False) as source:
                header = source.readline(MAX_HEADER + 1)
        finally:
            os.close(descriptor)
        if not header or len(header) > MAX_HEADER:
            return None
        record = json.loads(header.decode("utf-8", "strict"))
        if not isinstance(record, dict) or record.get("type") != "session_meta":
            return None
        payload = record.get("payload")
        if not isinstance(payload, dict):
            return None
    except Exception:
        return None
    if len(HEADER_CACHE) >= 4096:
        HEADER_CACHE.clear()
    HEADER_CACHE[key] = payload
    return payload

def root_fields(path, payload):
    try:
        source = payload.get("source")
        if source not in {"cli", "vscode"}:
            return None
        thread_source = payload.get("thread_source")
        if thread_source not in {None, "user"}:
            return None
        session_id = payload.get("session_id")
        if not isinstance(session_id, str):
            session_id = payload.get("id")
        if not isinstance(session_id, str) or not TOKEN.fullmatch(session_id):
            return None
        if not os.path.basename(path).endswith(session_id + ".jsonl"):
            return None
        return session_id
    except Exception:
        return None

def root_candidate(pid, sessions_root):
    # The one root rollout the process holds open: False when it holds no
    # root, or several; None when its open files could not be read.
    files = linux_open_files(pid, sessions_root) if os.path.isdir("/proc/%d/fd" % pid) else mac_open_files(pid, sessions_root)
    if files is None:
        return False if process_gone(pid) else None
    unique = {}
    for path, identity in files:
        session_id = root_metadata(path, identity)
        if session_id is not None:
            unique[identity] = (path, identity, session_id)
    if len(unique) != 1:
        return False
    return next(iter(unique.values()))

def strict_root_inventory(pid, sessions_root):
    files = linux_open_files_strict(pid, sessions_root) if os.path.isdir("/proc/%d/fd" % pid) else mac_open_files_strict(pid, sessions_root)
    if files is None or files is False:
        return files
    unique = {}
    unsafe = False
    for path, identity in files:
        session_id = root_metadata(path, identity)
        if session_id is not None:
            unique[identity] = (path, identity, session_id)
        elif path.endswith(".jsonl"):
            unsafe = True
    if unsafe or len(unique) > 1:
        return False
    return list(unique.values())

def timestamp_ns(value):
    if not isinstance(value, str) or len(value) > 64:
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            return None
        return calendar.timegm(parsed.utctimetuple()) * 1000000000 + parsed.microsecond * 1000
    except Exception:
        return None

def latest_authority(path, identity):
    try:
        checked = safe_file(path, SESSIONS_ROOT, identity)
        if checked is None:
            return None
        flags = os.O_RDONLY | os.O_NONBLOCK
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        try:
            if (os.fstat(descriptor).st_dev, os.fstat(descriptor).st_ino) != identity:
                return None
            size = os.fstat(descriptor).st_size
            start = max(0, size - MAX_TAIL)
            os.lseek(descriptor, start, os.SEEK_SET)
            with os.fdopen(descriptor, "rb", closefd=False) as source:
                data = source.read(MAX_TAIL)
        finally:
            os.close(descriptor)
        if start:
            boundary = data.find(b"\n")
            if boundary < 0:
                return None
            data = data[boundary + 1:]
        for line in reversed(data.splitlines()):
            try:
                record = json.loads(line.decode("utf-8", "strict"))
            except Exception:
                continue
            if not isinstance(record, dict) or record.get("type") != "event_msg":
                continue
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue
            kind = payload.get("type")
            if kind not in {"task_complete", "task_completed", "task_started"}:
                continue
            converted = timestamp_ns(record.get("timestamp"))
            if converted is None:
                continue
            turn_id = payload.get("turn_id")
            if not isinstance(turn_id, str) or not TOKEN.fullmatch(turn_id):
                turn_id = ""
            if kind in {"task_complete", "task_completed"}:
                return "Stop", "idle", "turn-stopped", converted, turn_id
            return "UserPromptSubmit", "working", "agent-turn", converted, turn_id
    except Exception:
        return None
    return None

def frame(session_id, path, agent_pid, authority):
    event, state, reason, stamp, turn_id = authority
    transcript = base64.urlsafe_b64encode(path.encode("utf-8")).decode("ascii").rstrip("=")
    value = {"version": 9, "provider": "codex", "event": event, "state": state, "reason": reason, "timestampNs": str(stamp), "sessionId": session_id, "turnId": turn_id, "notificationType": "", "permissionMode": "", "agentPid": agent_pid, "transcriptRef": transcript, "agentId": "", "agentType": "", "rootAgentId": ""}
    return json.dumps(value, separators=(",", ":"), ensure_ascii=True)

def legacy_frame(raw):
    try:
        value = json.loads(raw)
        if not isinstance(value, dict):
            return None
        if value.get("version") != 9 or value.get("provider") != "codex":
            return None
        if value.get("transcriptRef") != "Tm9uZQ":
            return None
        agent_pid = value.get("agentPid")
        if not isinstance(agent_pid, int) or isinstance(agent_pid, bool) or agent_pid <= 1:
            return None
        return agent_pid
    except Exception:
        return None

def still_open(pid, path, identity):
    # None when the open files of the process could not be read.
    checked = safe_file(path, SESSIONS_ROOT, identity)
    if checked is None:
        return False
    files = linux_open_files(pid, SESSIONS_ROOT) if os.path.isdir("/proc/%d/fd" % pid) else mac_open_files(pid, SESSIONS_ROOT)
    if files is None:
        return False if process_gone(pid) else None
    return any(item_identity == identity for _, item_identity in files)

def resolve_root(pid_text, session_id, pending=None):
    if not isinstance(pid_text, str) or not re.fullmatch(r"[1-9][0-9]{0,9}", pid_text):
        return None
    if not isinstance(session_id, str) or not TOKEN.fullmatch(session_id):
        return None
    try:
        pid = int(pid_text)
    except Exception:
        return None
    if pid <= 1 or not settled(lambda: live_codex(pid)):
        return None
    # Open files that lsof, or a race, left unread are read again; still
    # unread, the root observer publishes the root, and a child the event,
    # once they read.
    candidate = settled(lambda: root_candidate(pid, SESSIONS_ROOT))
    if candidate is None:
        hand_off(pid_text, session_id, pending)
        return None
    if not candidate:
        return None
    path, identity, resolved_session_id = candidate
    if resolved_session_id != session_id or not settled(lambda: live_codex(pid)):
        return None
    opened = settled(lambda: still_open(pid, path, identity))
    if opened is None:
        hand_off(pid_text, session_id, pending)
    if not opened:
        return None
    return base64.urlsafe_b64encode(path.encode("utf-8")).decode("ascii").rstrip("=")

def hand_off(pid_text, session_id, pending):
    if pending is not None and replay_later(int(pid_text), session_id, pending):
        return
    watch_root(pid_text)

def replay_later(pid, session_id, event):
    # True in the detached child, which publishes the event of a hook that
    # could not read the open files of its Codex once they read, at the
    # time the hook ran, so that any later event wins over it: while the
    # same process lives and holds the root of the thread, until a claim
    # as new as the event, and for a window. The hook returns at once.
    global RUN_DEADLINE
    if not valid_pending(event) or not detach(None):
        return False
    RUN_DEADLINE = None
    deadline = time.monotonic() + NATIVE_LATER
    start_token = settled(lambda: codex_start(pid), deadline)
    delay = 1
    while start_token and time.monotonic() < deadline:
        if watcher_ended(pid, start_token):
            break
        candidate = root_candidate(pid, SESSIONS_ROOT)
        if candidate is False or (candidate and candidate[2] != session_id):
            break
        opened = still_open(pid, candidate[0], candidate[1]) if candidate else None
        if opened is False:
            break
        # The claim the hook replaces, read last: an event published
        # meanwhile, this one too, ends the wait.
        epoch = client_epoch(pid) if opened else None
        if epoch and int(epoch) >= int(event[3]):
            break
        if epoch is not None and watcher_live(pid, start_token):
            invoke_observed_hook(pid, start_token, session_id, candidate[0], epoch, None, event[:3], event[3])
            # One the hook turned away, as when it could not read the files
            # in turn, is tried again, less often each time.
            time.sleep(delay)
            delay *= 2
            continue
        time.sleep(1)
    return True

def runtime_state_directory():
    directory = os.path.expanduser("~/.config/tessera/agent-runtime-state")
    try:
        listed = os.lstat(directory)
        if stat.S_ISLNK(listed.st_mode) or not stat.S_ISDIR(listed.st_mode):
            return None
        if listed.st_uid != os.getuid():
            return None
        return directory
    except Exception:
        return None

def lock_path(directory, pid, kind):
    return os.path.join(directory, "%d.%s.lock" % (pid, kind))

def held_at(path, descriptor):
    # Whether the path still names the file the descriptor holds.
    try:
        held = os.fstat(descriptor)
        listed = os.lstat(path)
    except Exception:
        return False
    return (listed.st_dev, listed.st_ino) == (held.st_dev, held.st_ino)

def observer_lock(pid, kind="observer", wait=0):
    # Held by one process at a time; a lock held only briefly is waited for
    # up to wait seconds. A binder unlinks the locks of its thread only
    # while it holds them, so a lock taken on a file the path no longer
    # names is taken again on the file there now.
    directory = runtime_state_directory()
    if directory is None or not hasattr(os, "O_NOFOLLOW"):
        return None
    path = lock_path(directory, pid, kind)
    descriptor = None
    try:
        import fcntl
        deadline = time.monotonic() + wait
        while True:
            if descriptor is None:
                descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                opened = os.fstat(descriptor)
                if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid():
                    os.close(descriptor)
                    return None
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if held_at(path, descriptor):
                    return descriptor
                os.close(descriptor)
                descriptor = None
            except BlockingIOError:
                pass
            if time.monotonic() >= deadline:
                raise BlockingIOError()
            time.sleep(0.01)
    except Exception:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except Exception:
                pass
        return None

def read_observer_claim(pid, ended=False):
    # The thread and time of the event a client last published, or None.
    # An ending counts only when asked for: observers then hold no claim.
    directory = runtime_state_directory()
    if directory is None or not hasattr(os, "O_NOFOLLOW"):
        return None
    path = os.path.join(directory, "%d.json" % pid)
    descriptor = None
    try:
        listed = os.lstat(path)
        if stat.S_ISLNK(listed.st_mode) or not stat.S_ISREG(listed.st_mode):
            return None
        if listed.st_uid != os.getuid() or listed.st_size > 16384:
            return None
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (listed.st_dev, listed.st_ino):
            return None
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid() or opened.st_size > 16384:
            return None
        data = os.read(descriptor, 16385)
        if len(data) > 16384:
            return None
        value = json.loads(data.decode("utf-8", "strict"))
        if not isinstance(value, dict) or value.get("provider") != "codex":
            return None
        agent_pid = value.get("agentPid")
        if not isinstance(agent_pid, int) or isinstance(agent_pid, bool) or agent_pid != pid:
            return None
        event = value.get("event")
        if event not in CLAIM_EVENTS and not (ended and event in ENDED_EVENTS):
            return None
        session_id = value.get("sessionId")
        if not isinstance(session_id, str) or (session_id and not TOKEN.fullmatch(session_id)):
            return None
        stamp = value.get("timestampNs")
        if not isinstance(stamp, str) or not re.fullmatch(r"[1-9][0-9]{0,19}", stamp):
            return None
        transcript = value.get("transcriptRef")
        if not isinstance(transcript, str) or len(transcript) > 4096 or not re.fullmatch(r"[A-Za-z0-9_-]*", transcript):
            return None
        return session_id, stamp
    except Exception:
        return None
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except Exception:
                pass

def watch_transition(claim_session_id, inventory):
    if inventory is None or inventory is False:
        return None
    if len(inventory) == 0:
        session_id = ""
        path = None
    elif len(inventory) == 1:
        path, _, session_id = inventory[0]
    else:
        return None
    if session_id == claim_session_id:
        return None
    return session_id, path

def invoke_observed_hook(pid, start_token, session_id, path, stamp, pane=None, event=("SessionStart", "idle", "session-start"), event_stamp=None):
    try:
        support_dir = os.environ.get("TESSERA_AGENT_RECOVERY_SUPPORT_DIR")
        if not isinstance(support_dir, str) or not os.path.isabs(support_dir):
            return
        support_dir = os.path.realpath(support_dir)
        hook = os.path.join(support_dir, "agent-lifecycle-hook.sh")
        payload = json.dumps({"session_id": session_id, "transcript_path": path}, separators=(",", ":")).encode("utf-8")
        environment = os.environ.copy()
        environment["TESSERA_AGENT_OBSERVED_TIMESTAMP_NS"] = stamp
        environment["TESSERA_AGENT_OBSERVER"] = "1"
        environment["TESSERA_AGENT_OBSERVED_PROVIDER_PID"] = str(pid)
        environment["TESSERA_AGENT_OBSERVED_PROCESS_START"] = start_token
        if pane is not None:
            # The client of a shared server publishes to its bound pane.
            environment["TMUX_PANE"] = pane
            environment["TESSERA_AGENT_OBSERVED_SHARED"] = "1"
        environment.pop("TESSERA_AGENT_OBSERVED_REPLAY", None)
        environment.pop("TESSERA_AGENT_OBSERVED_EVENT_NS", None)
        if event_stamp is not None:
            # A binder publishing the event a shared server ran before the
            # thread could be bound, at the time the server ran it: any
            # event the server ran later wins over it.
            environment["TESSERA_AGENT_OBSERVED_REPLAY"] = "1"
            environment["TESSERA_AGENT_OBSERVED_EVENT_NS"] = event_stamp
        process = subprocess.Popen([hook, "codex"] + list(event), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
        try:
            process.communicate(payload, timeout=3)
        except Exception:
            try:
                process.kill()
                process.wait(timeout=0.1)
            except Exception:
                pass
    except Exception:
        pass

def process_start_token(pid):
    try:
        if os.path.isdir("/proc"):
            with open("/proc/%d/stat" % pid, "rb") as source:
                value = source.read(4096).decode("ascii", "strict")
            close = value.rfind(")")
            if close < 0:
                return None
            fields = value[close + 2:].split()
            token = fields[19]
            return token if re.fullmatch(r"[1-9][0-9]{0,31}", token) else None
    except Exception:
        return None
    # The token is parsed as English; a localized ps would yield no token and
    # therefore no observer at all.
    raw = run(["ps", "-o", "lstart=", "-p", str(pid)], 128, env=dict(os.environ, LC_ALL="C"))
    if raw is None:
        return None
    try:
        token = raw.decode("ascii", "strict").strip()
        return token if re.fullmatch(r"[A-Za-z]{3} [A-Za-z]{3} [ 0-9][0-9] [0-9:]{8} [0-9]{4}", token) else None
    except Exception:
        return None

def watcher_live(pid, start_token):
    # Whether the process is surely the Codex observed: what is published
    # waits for it.
    return is_codex(pid) and process_start_token(pid) == start_token

def process_gone(pid):
    # Whether no process is left under the PID, which no ps is asked.
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except Exception:
        pass
    return False

def process_ended(pid, start_token):
    # Only a definite answer ends a binder or an observer: a start of the
    # process that was read and differs, or no process left. A ps that
    # failed to fork or answered late, which on macOS reads the start, the
    # owner and the command, tells nothing.
    if pid <= 1:
        return True
    token = process_start_token(pid)
    if token is not None:
        return token != start_token
    return process_gone(pid)

def watcher_ended(pid, start_token):
    # An observer ends too once the process surely is no Codex of this
    # user, as after an exec.
    return process_ended(pid, start_token) or is_codex(pid) is False

def settled(decide, until=None):
    # The first answer of decide other than None, asked again until SETTLE
    # has passed, or until the time given; then None.
    deadline = time.monotonic() + SETTLE if until is None else until
    while True:
        answer = decide()
        if answer is not None or time.monotonic() >= deadline:
            return answer
        time.sleep(0.2)

def live_codex(pid):
    # is_codex, where no process left is a definite no.
    codex = is_codex(pid)
    return False if codex is None and process_gone(pid) else codex

def live_start(pid):
    # The start of the process: False once no process is left, None when a
    # ps that failed to fork or answered late could not tell.
    token = process_start_token(pid)
    return False if token is None and process_gone(pid) else token

def codex_start(pid):
    # The start of a Codex of this user, False when the process surely is
    # none, None when that cannot be told yet.
    codex = live_codex(pid)
    return live_start(pid) if codex else codex

def legacy_agent(agent_pid, pane_pid):
    # Whether the agent is a Codex of this user under a pane of this user;
    # None when a ps that failed to fork or answered late could not tell.
    owner = current_uid(pane_pid)
    if owner is not None and owner != os.getuid():
        return False
    codex = live_codex(agent_pid)
    if codex is False:
        return False
    below = descendant(agent_pid, pane_pid) if codex else None
    if below is False:
        return False
    return None if owner is None or codex is None or below is None else True

def watch_once(pid, start_token, claim):
    inventory = strict_root_inventory(pid, SESSIONS_ROOT)
    transition = watch_transition(claim[0], inventory)
    if transition is None:
        return None
    rechecked_inventory = strict_root_inventory(pid, SESSIONS_ROOT)
    rechecked_claim = read_observer_claim(pid)
    if (rechecked_claim or ("", "")) == claim and rechecked_inventory == inventory and watcher_live(pid, start_token):
        invoke_observed_hook(pid, start_token, transition[0], transition[1], claim[1])
        return transition[0]
    return None

def valid_start_token(value):
    if not isinstance(value, str):
        return False
    return re.fullmatch(r"[1-9][0-9]{0,31}", value) is not None or re.fullmatch(r"[A-Za-z]{3} [A-Za-z]{3} [ 0-9][0-9] [0-9:]{8} [0-9]{4}", value) is not None

def verify_observation(pid_text, start_token, session_id):
    if not isinstance(pid_text, str) or not re.fullmatch(r"[1-9][0-9]{0,9}", pid_text):
        return None
    if not valid_start_token(start_token):
        return None
    if not isinstance(session_id, str) or (session_id and not TOKEN.fullmatch(session_id)):
        return None
    try:
        pid = int(pid_text)
    except Exception:
        return None
    if not watcher_live(pid, start_token):
        return None
    shared = shared_client(pid, start_token)
    if shared is not None:
        # A bound client holds no rollout: its title decides, as for its
        # observer, against the claim the delivery then requires. A node
        # launcher left the native client no claim, which only the empty
        # epoch can then meet.
        claim = read_observer_claim(pid) or ("", "")
        target = shared_target(shared[0], shared[1], claim[0], pid)
        if target is None or target[0] != session_id or not watcher_live(pid, start_token):
            return None
        return str(pid)
    inventory = strict_root_inventory(pid, SESSIONS_ROOT)
    if inventory is None or inventory is False:
        return None
    if session_id == "":
        accepted = len(inventory) == 0
    else:
        accepted = len(inventory) == 1 and inventory[0][2] == session_id
    if not accepted:
        return None
    if not watcher_live(pid, start_token) or strict_root_inventory(pid, SESSIONS_ROOT) != inventory:
        return None
    return str(pid)

def watch_loop(pid, start_token, bootstrap=False):
    adoption = (None, 0.0, 2)
    while not watcher_ended(pid, start_token):
        if shared_client(pid, start_token) is not None:
            # The title observer has a lock of its own: an observer from
            # before an upgrade can hold this one for the client lifetime.
            lock = observer_lock(pid, "shared-observer")
            if lock is not None:
                try:
                    watch_shared(pid, start_token, bootstrap)
                finally:
                    os.close(lock)
            return
        claim = read_observer_claim(pid)
        if claim is None and bootstrap:
            # A node launcher has no native child claim before the first
            # prompt. The empty epoch permits only an absent claim under the
            # delivery lock; a racing native hook always wins.
            claim = ("", "")
        if claim is not None and watch_once(pid, start_token, claim) is None and not claim[0]:
            # A client with no thread of its own can show one a shared
            # server hosts, as when resumed while idle, before any hook
            # runs. Each try scans every process, so the same title is
            # tried less often each time.
            title = own_title()
            now = time.monotonic()
            if title != adoption[0] or now >= adoption[1]:
                delay = adoption[2] if title == adoption[0] else 2
                adopted = adopt_shared(pid, start_token)
                if adopted is not None and mark_shared_client(pid, start_token, adopted[0], adopted[1]):
                    continue
                adoption = (title, now + delay, min(delay * 2, 60))
        time.sleep(1)

def observer_target(pid):
    # The launcher publishes the bootstrap SessionStart under its own PID and
    # execs Codex under that PID only after the hook returns, so the target
    # may still be the launcher shell here. Bind to PID plus start token,
    # which survives exec, and let the detached observer wait for the exec.
    # Nothing is published before watcher_live proves Codex under that exact
    # identity, so a launcher that never becomes Codex only idles an observer.
    # False when the process surely is none of this user that the hook runs
    # under; None when a ps that failed to fork or answered late could not
    # tell.
    if pid <= 1:
        return False
    owner = current_uid(pid)
    if owner is not None and owner != os.getuid():
        return False
    below = descendant(os.getpid(), pid)
    if below is False:
        return False
    if owner is None or below is None:
        return False if process_gone(pid) else None
    return live_start(pid)

def await_codex(pid, start_token, timeout):
    # Only a definite answer gives up before the timeout: no process left,
    # another start under the PID, or a node process that surely runs no
    # Codex launcher. A poll a ps that failed to fork or answered late
    # could not decide is followed by the next.
    deadline = time.monotonic() + timeout
    interval = 0.05
    while time.monotonic() < deadline:
        start = live_start(pid)
        if start is False or (start is not None and start != start_token):
            return None
        name = command_name(pid) if start else None
        if name in CODEX_COMMANDS and is_codex(pid):
            return pid, start_token
        if name in NODE_COMMANDS:
            launcher = is_codex_launcher(pid)
            if launcher is False:
                return None
            target = native_codex_child(pid, start_token) if launcher else None
            if target is not None:
                return target
        time.sleep(interval)
        interval = min(interval * 2, 1.0)
    return None

def detach(lock):
    # True in the forked observer, which keeps the lock, if any; the
    # caller, a hook, returns at once.
    try:
        child = os.fork()
    except Exception:
        child = None
    if child == 0:
        try:
            null = os.open(os.devnull, os.O_RDWR)
            os.dup2(null, 0)
            os.dup2(null, 1)
            os.dup2(null, 2)
            if null > 2:
                os.close(null)
            return True
        except Exception:
            pass
    if lock is not None:
        try:
            os.close(lock)
        except Exception:
            pass
    return False

def watch_root(pid_text):
    if not isinstance(pid_text, str) or not re.fullmatch(r"[1-9][0-9]{0,9}", pid_text):
        return
    try:
        pid = int(pid_text)
    except Exception:
        return
    start_token = settled(lambda: observer_target(pid))
    if not start_token:
        return
    lock = observer_lock(pid)
    if lock is None or not detach(lock):
        return
    try:
        # Forked before the exec so the hook, and with it the launcher,
        # return at once; the wait happens here, detached.
        target = await_codex(pid, start_token, 60)
        if target is not None:
            child_pid, child_start = target
            if child_pid != pid:
                child_lock = observer_lock(child_pid)
                if child_lock is None:
                    return
                os.close(lock)
                lock = child_lock
            # Native hooks choose the nearest Codex ancestor: the native
            # child, rather than the node launcher, owns this same claim.
            watch_loop(child_pid, child_start, bootstrap=child_pid != pid)
    finally:
        try:
            os.close(lock)
        except Exception:
            pass

# A Codex TUI can attach to a shared app-server that hosts the threads of
# several panes and runs every hook with the environment of the TUI that
# started it; no hook field names the client. A hosted thread binds only to
# the one pane whose own Codex shows the thread in the title it set: by its
# ID, or by its name when no other thread of the server and no project can
# read the same.
def title_text(value, screen):
    # Codex sanitize_terminal_title. GNU screen gets ASCII only.
    text = []
    pending = False
    for character in value:
        if character.isspace() and not "\x1c" <= character <= "\x1f":
            pending = bool(text)
            continue
        point = ord(character)
        if unicodedata.category(character) == "Cc" or point in TITLE_HIDDEN or any(low <= point <= high for low, high in TITLE_HIDDEN_RANGES):
            continue
        if screen and point > 127:
            character = SCREEN_GLYPHS.get(character, "?")
        if pending and MAX_TITLE - len(text) > 1:
            text.append(" ")
            pending = False
        if len(text) >= MAX_TITLE:
            break
        text.append(character)
    return "".join(text)

PREPEND_RANGES = ((0x0600, 0x0605), (0x06DD, 0x06DD), (0x070F, 0x070F), (0x0890, 0x0891), (0x08E2, 0x08E2), (0x0D4E, 0x0D4E), (0x110BD, 0x110BD), (0x110CD, 0x110CD), (0x111C2, 0x111C3), (0x1193F, 0x1193F), (0x11941, 0x11941), (0x11A3A, 0x11A3A), (0x11A84, 0x11A89), (0x11D46, 0x11D46), (0x11F02, 0x11F02))

def single_cluster(character):
    # A character that is a grapheme cluster of its own wherever it stands,
    # as UAX #29 has it: no mark, control, format or unassigned character,
    # Hangul jamo, regional indicator, emoji modifier or prepended letter,
    # and none of the letters that extend or space a cluster.
    point = ord(character)
    category = unicodedata.category(character)
    if category[0] in "MC" or category in {"Zl", "Zp"}:
        return False
    if 0x1100 <= point <= 0x11FF or 0xA960 <= point <= 0xA97F or 0xD7B0 <= point <= 0xD7FF:
        return False
    if 0x1F1E6 <= point <= 0x1F1FF or 0x1F3FB <= point <= 0x1F3FF or point in {0x0E33, 0x0EB3, 0xFF9E, 0xFF9F}:
        return False
    return not any(low <= point <= high for low, high in PREPEND_RANGES)

def title_cuts(value, limit):
    # Codex cuts an item of more than limit grapheme clusters to limit - 3
    # of them and "...". Where a cluster can span characters every cut it
    # could make counts; None when a long value leaves too many.
    if len(value) <= limit:
        return {value}
    if (value.isascii() and value.isprintable()) or all(single_cluster(character) for character in value):
        return {value[:limit - 3] + "..."}
    if len(value) > MAX_CUT:
        return None
    return {value} | {value[:end] + "..." for end in range(limit - 3, len(value))}

def title_edge(text, before):
    # Title items are joined by " | ", and the activity glyphs join their
    # neighbours with a space. GNU screen shows the glyphs as ASCII, which an
    # item can hold too, so past those only " | " or the title end counts.
    spinner = False
    while text:
        if text.endswith(" | ") if before else text.startswith(" | "):
            return True
        if not (text.endswith(" ") if before else text.startswith(" ")):
            return False
        if spinner:
            return True
        if before:
            text = text[:-1]
            token = text.rsplit(" ", 1)[-1]
        else:
            text = text[1:]
            token = text.split(" ", 1)[0]
        if not TITLE_GLYPHS.fullmatch(token):
            return False
        spinner = ord(token[0]) > 127
        text = text[:len(text) - len(token)] if before else text[len(token):]
    return True

def title_shows(title, item):
    # A title at the length cap may have cut its last item short.
    if not item:
        return False
    capped = len(title) >= MAX_TITLE - 1
    start = title.find(item)
    while start >= 0:
        end = start + len(item)
        if (end < len(title) or not capped) and title_edge(title[:start], True) and title_edge(title[end:], False):
            return True
        start = title.find(item, start + 1)
    return False

def thread_names(ids):
    # The index is append-only: the last entry for a thread wins, and an
    # empty name clears it. Incomplete when its read was cut and missed a
    # thread, which may then share a name.
    if not ids or not hasattr(os, "O_NOFOLLOW"):
        return {}, True
    descriptor = None
    try:
        descriptor = os.open(SESSION_INDEX, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid():
            return {}, False
        key = (SESSION_INDEX, opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns, frozenset(ids))
        if INDEX_CACHE.get("key") == key:
            return INDEX_CACHE["value"]
        start = max(0, opened.st_size - MAX_INDEX)
        os.lseek(descriptor, start, os.SEEK_SET)
        data = b""
        while len(data) < MAX_INDEX:
            chunk = os.read(descriptor, min(1048576, MAX_INDEX - len(data)))
            if not chunk:
                break
            data += chunk
    except FileNotFoundError:
        return {}, True
    except Exception:
        return {}, False
    finally:
        if descriptor is not None:
            os.close(descriptor)
    names = {}
    wanted = {value.encode("utf-8") for value in ids}
    # One pass over the ID keys stays linear however many threads are hosted.
    for match in INDEX_ID.finditer(data):
        if match.group(1) not in wanted:
            continue
        begin = data.rfind(b"\n", 0, match.start()) + 1
        if begin == 0 and start:
            continue
        end = data.find(b"\n", match.end())
        try:
            record = json.loads(data[begin:end if end >= 0 else len(data)].decode("utf-8", "strict"))
        except Exception:
            continue
        if not isinstance(record, dict):
            continue
        thread = record.get("id")
        name = record.get("thread_name")
        if thread in ids and isinstance(name, str):
            names[thread] = name.strip()
    result = names, start == 0 or len(names) == len(ids)
    # An observer asks again each time the title changes.
    INDEX_CACHE["key"] = key
    INDEX_CACHE["value"] = result
    return result

def project_names(cwds):
    # The project item names the git root, project folder or cwd of a thread:
    # the cwd or one of its ancestors. None when a name can be cut in too
    # many ways.
    names = set()
    for cwd in cwds:
        path = cwd.rstrip("/")
        for _ in range(MAX_DEPTH):
            base = os.path.basename(path)
            if not base:
                break
            cuts = title_cuts(base, 24)
            if cuts is None:
                return None
            names.update(cuts)
            path = os.path.dirname(path)
    return names

def project_items(projects):
    # The project items as Codex and as GNU screen show them.
    items = {title_text(project, screen) for project in projects for screen in (False, True)}
    items.discard("")
    return items

def thread_items(session_id, names):
    # Every item that can show a thread: its whole ID, as thread-title shows
    # it, and the ID thread-id cuts to 32, then its name as Codex and as GNU
    # screen show it. None when the name can show in too many ways.
    cuts = title_cuts(names.get(session_id, ""), 48)
    if cuts is None:
        return None
    named = {title_text(cut, screen) for cut in cuts for screen in (False, True)}
    named.discard("")
    return {session_id} | title_cuts(session_id, 32), named

def title_items(session_id, rendered, projects, plain):
    # The items that show this thread alone: its ID, and its name under a
    # plain layout, when no item of another hosted thread, no project item
    # and no activity text reads the same, shows it or is shown within it,
    # since a name can spell anything.
    ids, named = rendered[session_id]
    rivals = set(projects) | ACTIVITY_ITEMS
    for thread, (other_ids, other_named) in rendered.items():
        if thread != session_id:
            rivals.update(other_ids)
            rivals.update(other_named)
    candidates = ids | named if plain else ids
    return {item for item in candidates if not any(title_shows(rival, item) or title_shows(item, rival) for rival in rivals)}

def title_layout_plain(paths):
    # Names count only under a title of thread, project and activity items,
    # as these configs set it. A client given one with -c is never bound; one
    # set for a session with /title, or by an admin or cloud layer, goes
    # unseen. A config that is no file, as a FIFO or a device another user
    # put in a folder above a project, or a link to one, is never waited on:
    # it is unreadable.
    for path in dict.fromkeys(paths):
        descriptor = None
        try:
            if not stat.S_ISREG(os.stat(path).st_mode):
                return False
            descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOCTTY", 0))
            if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                return False
            data = b""
            while len(data) <= MAX_CONFIG:
                chunk = os.read(descriptor, MAX_CONFIG + 1 - len(data))
                if not chunk:
                    break
                data += chunk
        except (FileNotFoundError, NotADirectoryError):
            continue
        except Exception:
            return False
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if len(data) > MAX_CONFIG:
            return False
        if b"terminal_title" not in data:
            continue
        try:
            items = title_setting(data.decode("utf-8"))
        except Exception:
            return False
        if items is not None and not (isinstance(items, list) and all(isinstance(item, str) and item in PLAIN_TITLE_ITEMS for item in items)):
            return False
    return True

def title_setting(text):
    # The tui.terminal_title a config sets, or None. Python before 3.11 has
    # no tomllib: without tomli only the one-line array Codex writes is read,
    # and any other mention raises.
    try:
        import tomllib
    except ImportError:
        try:
            import tomli as tomllib
        except ImportError:
            tomllib = None
    if tomllib is not None:
        tui = tomllib.loads(text).get("tui")
        return tui.get("terminal_title") if isinstance(tui, dict) else None
    items = None
    table = ""
    for line in text.splitlines():
        header = re.fullmatch(r"\s*\[\s*([A-Za-z0-9_.-]+)\s*\]\s*(#.*)?", line)
        if header:
            table = header.group(1)
            continue
        if re.match(r"\s*\[", line):
            table = None
        if "terminal_title" not in line or re.match(r"\s*#", line):
            continue
        setting = re.fullmatch(r"\s*(tui\.)?terminal_title\s*=\s*\[((?:\s*\x22[a-z-]+\x22\s*,)*(?:\s*\x22[a-z-]+\x22)?\s*,?\s*)\]\s*(#.*)?", line)
        if setting is None or items is not None or table != ("" if setting.group(1) else "tui"):
            raise ValueError("terminal_title")
        items = re.findall(r"\x22([a-z-]+)\x22", setting.group(2))
    return items

def past_deadline():
    return RUN_DEADLINE is not None and time.monotonic() > RUN_DEADLINE

def server_threads(pid):
    # The roots a server holds, with rollout and cwd, and every thread it
    # holds, subagents too. None when a held rollout is unreadable: a thread
    # of unknown name can share a name.
    if os.path.isdir("/proc/%d/fd" % pid):
        files = linux_open_files_strict(pid, SESSIONS_ROOT, MAX_SERVER_FDS)
    else:
        files = mac_open_files_strict(pid, SESSIONS_ROOT)
    if files is None or files is False:
        return None
    roots = {}
    hosted = set()
    for path, identity in files:
        payload = rollout_header(path, identity)
        if payload is None or past_deadline():
            return None
        thread = payload.get("id")
        if not isinstance(thread, str) or not TOKEN.fullmatch(thread):
            return None
        hosted.add(thread)
        session_id = root_fields(path, payload)
        if session_id is None:
            continue
        if roots.get(session_id, (path, identity))[1] != identity:
            return None
        cwd = payload.get("cwd")
        roots[session_id] = (path, identity, cwd if isinstance(cwd, str) else "")
    hosted.update(roots)
    return roots, hosted

def server_evidence(server, claim=""):
    # The roots a server holds, and the items each thread it holds, and the
    # claim, can show, rendered once. None when a thread or its name is
    # unknown, since an unknown thread can read as any other.
    threads = server_threads(server)
    if threads is None:
        return None
    roots, hosted = threads
    ids = hosted | {claim} if claim else hosted
    names, complete = thread_names(ids)
    if not complete:
        return None
    rendered = {}
    for thread in ids:
        items = thread_items(thread, names)
        if items is None or past_deadline():
            return None
        rendered[thread] = items
    return roots, rendered

def process_table():
    parents = {}
    names = {}
    # Reading /proc takes a quarter of the time ps does on a busy host.
    if os.path.isdir("/proc/%d" % os.getpid()):
        try:
            entries = os.listdir("/proc")
        except Exception:
            return None
        for entry in entries:
            if not entry.isdigit():
                continue
            try:
                with open("/proc/%s/stat" % entry, "rb") as source:
                    line = source.read(4096).decode("utf-8", "replace")
                begin = line.index("(")
                end = line.rindex(")")
                parents[int(entry)] = int(line[end + 2:].split()[1])
                names[int(entry)] = line[begin + 1:end]
            except Exception:
                continue
        return parents, names
    raw = run(["ps", "-axo", "pid=,ppid=,comm="])
    if raw is None:
        return None
    for line in raw.decode("utf-8", "replace").splitlines():
        fields = line.split(None, 2)
        if not fields:
            continue
        try:
            pid = int(fields[0])
            parents[pid] = int(fields[1])
        except Exception:
            return None
        names[pid] = os.path.basename(fields[2].strip()) if len(fields) == 3 else ""
    return parents, names

def codex_server(pid):
    arguments = process_arguments(pid)
    return None if arguments is None else server_command(arguments[1:])

def server_command(arguments):
    # The first command decides, past root options and their values; an
    # image option takes every value up to the next option.
    skip = images = False
    for argument in arguments:
        if skip:
            skip = False
        elif argument == "--":
            return False
        elif argument in CODEX_VALUE_OPTIONS:
            skip = True
            images = False
        elif argument in {"-i", "--image"}:
            images = True
        elif argument.startswith("-"):
            images = False
        elif not images:
            return argument == "app-server"
    return False

def mac_process_strings(pid):
    # macOS gives the owner of a process its arguments and environment,
    # each whole, through the KERN_PROCARGS2 sysctl.
    if sys.platform != "darwin":
        return None
    try:
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        mib = (ctypes.c_int * 3)(1, 49, pid)
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not 4 < size.value <= 2 * MAX_OUTPUT:
            return None
        buffer = ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
            return None
        data = buffer.raw[:size.value]
        count = int.from_bytes(data[:4], sys.byteorder)
        # The executable path and its padding come before the arguments.
        strings = data[data.index(b"\0", 4):].lstrip(b"\0").split(b"\0")
        if not 0 < count < len(strings):
            return None
        environment = []
        for value in strings[count:]:
            if not value:
                break
            environment.append(value)
        return [value.decode("utf-8", "strict") for value in strings[:count]], environment
    except Exception:
        return None

def process_arguments(pid):
    # Each argument whole: Linux keeps them so, and macOS gives them to the
    # owner. ps joins them with spaces, so elsewhere none are known.
    if not os.path.isdir("/proc/%d" % pid):
        strings = mac_process_strings(pid)
        return None if strings is None else strings[0]
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as source:
            data = source.read(65537)
        if len(data) > 65536:
            return None
        return [value.decode("utf-8", "strict") for value in data.rstrip(b"\0").split(b"\0")]
    except Exception:
        return None

def process_environment(pid):
    # The environment a process started with, for its owner.
    if not os.path.isdir("/proc/%d" % pid):
        strings = mac_process_strings(pid)
        return None if strings is None else strings[1]
    try:
        with open("/proc/%d/environ" % pid, "rb") as source:
            data = source.read(MAX_OUTPUT + 1)
    except Exception:
        return None
    return None if len(data) > MAX_OUTPUT else data.split(b"\0")

def client_program(pid, arguments=None):
    # A wrapper script runs as its interpreter, which it names first.
    arguments = process_arguments(pid) if arguments is None else arguments
    return bool(arguments) and bool(arguments[0]) and os.path.basename(arguments[0]) in CODEX_COMMANDS

def client_cwd(pid):
    if os.path.isdir("/proc/%d" % pid):
        try:
            return os.readlink("/proc/%d/cwd" % pid)
        except Exception:
            return None
    raw = run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"], 65536)
    for line in (raw or b"").splitlines():
        if line.startswith(b"n/"):
            try:
                return line[1:].decode("utf-8", "strict")
            except Exception:
                return None
    return None

CLIENT_OPTIONS = {"-C": "--cd", "--cd": "--cd", "-p": "--profile", "--profile": "--profile", "--remote": "--remote"}

def client_scope(pid, arguments):
    # What a client can show beside its thread, and where its title layout
    # comes from: the projects of its cwd, which may not be the one a
    # resumed thread started in, and of -C, and the configs of its home,
    # its profile and the folders it works in. None for a client of another
    # server, or one given its own title layout.
    cwd = client_cwd(pid)
    if not arguments or cwd is None:
        return None
    found = {"--cd": [], "--profile": [], "--remote": []}
    option = None
    for argument in arguments[1:]:
        if option is not None:
            found[option].append(argument)
            option = None
        elif argument == "--":
            break
        elif "terminal_title" in argument:
            return None
        elif argument in CLIENT_OPTIONS:
            option = CLIENT_OPTIONS[argument]
        elif argument.startswith("--") and argument.partition("=")[0] in found:
            found[argument.partition("=")[0]].append(argument.partition("=")[2])
        elif argument[:2] in {"-C", "-p"}:
            found[CLIENT_OPTIONS[argument[:2]]].append(argument[2:].lstrip("="))
    # A bare unix:// is the server of the client home.
    if option is not None or any(remote != "unix://" for remote in found["--remote"]):
        return None
    configs = list(CODEX_CONFIGS)
    for profile in found["--profile"]:
        if not PROFILE_NAME.fullmatch(profile):
            return None
        configs.append(os.path.join(os.path.dirname(CODEX_CONFIGS[0]), profile + ".config.toml"))
    directories = [cwd] + [os.path.join(cwd, directory) for directory in found["--cd"]]
    projects = project_names(directories)
    return None if projects is None else (projects, configs + project_configs(directories))

def project_configs(directories):
    # Codex reads .codex/config.toml from a project folder and its ancestors,
    # for the cwd of each thread too.
    configs = []
    for directory in directories:
        if not directory or not os.path.isabs(directory):
            continue
        path = os.path.normpath(directory)
        for _ in range(MAX_DEPTH):
            configs.append(os.path.join(path, ".codex", "config.toml"))
            parent = os.path.dirname(path)
            if parent == path:
                break
            path = parent
    return configs

def client_home(pid):
    # A client of another Codex home talks to another server, which can
    # host a thread of the same name.
    environment = process_environment(pid)
    if environment is None:
        return False
    found = {}
    for entry in environment:
        key, separator, value = entry.partition(b"=")
        if separator and key in {b"CODEX_HOME", b"HOME"} and key not in found:
            found[key] = value
    try:
        home = found.get(b"CODEX_HOME", b"").decode("utf-8", "strict")
        if not home:
            base = found.get(b"HOME", b"").decode("utf-8", "strict") or pwd.getpwuid(os.getuid()).pw_dir
            home = os.path.join(base, ".codex")
    except Exception:
        return False
    # Two homes can share one sessions folder but not one control socket.
    return os.path.isabs(home) and os.path.realpath(home) == os.path.realpath(os.path.dirname(CODEX_CONFIGS[0]))

def home_server(pid):
    # The server of the control socket of this home listens on a bare
    # unix://; one on another socket, or on stdio, serves clients that show
    # its threads elsewhere.
    arguments = process_arguments(pid)
    if not arguments or not server_command(arguments[1:]):
        return False
    return "--listen=unix://" in arguments or ("--listen", "unix://") in zip(arguments, arguments[1:])

def process_children(parents):
    children = {}
    for child, parent in parents.items():
        children.setdefault(parent, []).append(child)
    return children

def pane_client(pane_pid, server, parents, names, children):
    # The one innermost Codex of the pane outside the server and its
    # descendants; an app-server is never a client.
    members = set()
    pending = [pane_pid]
    while pending:
        pid = pending.pop()
        if pid in members or pid == server:
            continue
        members.add(pid)
        if len(members) > MAX_TREE:
            return None
        pending.extend(children.get(pid, ()))
    clients = []
    for pid in members:
        if names.get(pid) not in CODEX_COMMANDS:
            continue
        server_process = codex_server(pid)
        if server_process is None:
            return None
        if not server_process:
            clients.append(pid)
    outer = set()
    for pid in clients:
        ancestor = parents.get(pid)
        for _ in range(MAX_DEPTH):
            if ancestor not in members:
                break
            outer.add(ancestor)
            if ancestor == pane_pid:
                break
            ancestor = parents.get(ancestor)
    innermost = [pid for pid in clients if pid not in outer]
    return innermost[0] if len(innermost) == 1 else None

def verified_client(client, pane_pid, server):
    # A client that holds rollouts hosts its own threads and hooks; a
    # wrapper script, or a client of another Codex home or server, is no
    # client of this server. Its start token, the projects it can show and
    # the configs of its title layout.
    if os.path.isdir("/proc/%d/fd" % client):
        held = linux_open_files_strict(client, SESSIONS_ROOT)
    else:
        held = mac_open_files_strict(client, SESSIONS_ROOT)
    if held is None or held is False or held:
        return None
    arguments = process_arguments(client)
    if current_uid(pane_pid) != os.getuid() or not is_codex(client) or not client_program(client, arguments) or not client_home(client):
        return None
    scope = client_scope(client, arguments)
    if scope is None or not descendant(client, pane_pid) or descendant(client, server) is not False:
        return None
    start_token = process_start_token(client)
    return None if start_token is None else (start_token,) + scope

def shared_panes():
    raw = run(["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}\t#{pane_title}"], MAX_OUTPUT)
    if raw is None:
        return None
    lines = raw.splitlines()
    if len(lines) > MAX_SHARED_PANES:
        return None
    # Grouped sessions list a shared pane once for each session.
    panes = {}
    for line in lines:
        try:
            pane, pane_pid, title = line.decode("utf-8", "strict").split("\t", 2)
            pane_pid = int(pane_pid)
        except Exception:
            continue
        if re.fullmatch(r"%[0-9]{1,9}", pane) and pane_pid > 1 and pane not in panes:
            panes[pane] = (pane_pid, title_text(title, False))
    return panes

def shared_client(pid, start_token):
    # The server and pane a client was bound to, for this process only.
    directory = runtime_state_directory()
    if directory is None or not hasattr(os, "O_NOFOLLOW"):
        return None
    descriptor = None
    try:
        descriptor = os.open(os.path.join(directory, "%d.shared-server" % pid), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid():
            return None
        lines = os.read(descriptor, 512).decode("ascii", "strict").split("\n")
        if len(lines) != 4 or lines[3] or lines[0] != start_token:
            return None
        if not re.fullmatch(r"[1-9][0-9]{0,9}", lines[1]) or not re.fullmatch(r"%[0-9]{1,9}", lines[2]):
            return None
        return int(lines[1]), lines[2]
    except Exception:
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)

def mark_shared_client(pid, start_token, server, pane):
    # The client holds no transcript, so its observer follows the pane
    # title instead. The mark lasts for this process only.
    try:
        os.makedirs(os.path.expanduser("~/.config/tessera/agent-runtime-state"), mode=0o700, exist_ok=True)
    except Exception:
        return False
    directory = runtime_state_directory()
    if directory is None:
        return False
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="ascii", dir=directory, prefix="%d." % pid, delete=False) as destination:
            temporary = destination.name
            destination.write("%s\n%d\n%s\n" % (start_token, server, pane))
        os.replace(temporary, os.path.join(directory, "%d.shared-server" % pid))
        temporary = None
        return True
    except Exception:
        return False
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except Exception:
                pass

def bind_shared(server_text, session_id, pending=None):
    global RUN_DEADLINE
    if not isinstance(server_text, str) or not re.fullmatch(r"[1-9][0-9]{0,9}", server_text):
        return None
    if not isinstance(session_id, str) or not TOKEN.fullmatch(session_id):
        return None
    # The hook waits for this, and with it the turn: binding, and handing
    # an event it could not bind to a binder, end by one deadline.
    deadline = time.monotonic() + SHARED_DEADLINE
    found = {}
    RUN_DEADLINE = deadline if pending is None else deadline - SHARED_HANDOFF
    try:
        bound = bound_pane(int(server_text), session_id, RUN_DEADLINE, found)
        RUN_DEADLINE = deadline
        # No pane shows the thread yet: its name can come after a whole
        # turn. A binder waits for one, and the event, to publish.
        if bound is None and pending is not None:
            bind_later(int(server_text), session_id, pending, found, deadline)
    finally:
        RUN_DEADLINE = None
    if bound is None:
        return None
    pane, client, _, path, observe = bound
    return "%s %d %s %d" % (pane, client, base64.urlsafe_b64encode(path.encode("utf-8")).decode("ascii").rstrip("="), observe)

def thread_key(session_id):
    return hashlib.sha256(session_id.encode("utf-8")).hexdigest()[:32]

def pending_name(server, session_id):
    # Named after the server, so the hook prunes it once the server exits.
    return "%d.shared-pending.%s" % (server, thread_key(session_id))

def pending_lock(server, session_id, wait=None):
    # Held while a hook replaces the record of a thread and while a binder
    # removes the one it read or lets its own lock go. A hook waits for it
    # only until its deadline.
    wait = PENDING_WAIT if wait is None else wait
    if RUN_DEADLINE is not None:
        wait = min(wait, max(0, RUN_DEADLINE - time.monotonic()))
    return observer_lock(server, "shared-pending." + thread_key(session_id), wait)

def valid_pending(event):
    return (isinstance(event, (list, tuple)) and len(event) == 4 and event[0] in SHARED_LATER_EVENTS
            and event[1] in SHARED_LATER_STATES and isinstance(event[2], str) and re.fullmatch(r"[A-Za-z0-9._:-]{1,64}", event[2]) is not None
            and isinstance(event[3], str) and re.fullmatch(r"[1-9][0-9]{0,18}", event[3]) is not None)

def pending_expired(event, timed=None):
    # Past the window after the newest event recorded for the thread: by
    # the wall clock that stamped it, or, timed as (event, when), by the
    # monotonic clock of a binder since it first read that event, so a wall
    # clock set back stretches no wait.
    if time.time_ns() - int(event[3]) > SHARED_LATER * 1000000000:
        return True
    return timed is not None and timed[0] == event and time.monotonic() - timed[1] > SHARED_LATER

def read_pending(server, server_token, session_id):
    # The latest event the server ran for the thread, (event, state, reason,
    # timestamp), when it was recorded for this server process.
    directory = runtime_state_directory()
    if directory is None or not hasattr(os, "O_NOFOLLOW"):
        return None
    descriptor = None
    try:
        descriptor = os.open(os.path.join(directory, pending_name(server, session_id)), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid():
            return None
        lines = os.read(descriptor, 1024).decode("ascii", "strict").split("\n")
        if len(lines) != 7 or lines[6] or lines[0] != server_token or lines[1] != session_id:
            return None
        event = tuple(lines[2:6])
        return event if valid_pending(event) else None
    except Exception:
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)

def record_pending(server, server_token, session_id, event):
    # Keeps the newer event, under the record lock: a binder removes only
    # the record it read, and lets its own lock go only while no newer one
    # waits.
    try:
        os.makedirs(os.path.expanduser("~/.config/tessera/agent-runtime-state"), mode=0o700, exist_ok=True)
    except Exception:
        return False
    directory = runtime_state_directory()
    if directory is None:
        return False
    guard = pending_lock(server, session_id)
    if guard is None:
        return False
    temporary = None
    try:
        held = read_pending(server, server_token, session_id)
        if held is not None and int(held[3]) > int(event[3]):
            return True
        with tempfile.NamedTemporaryFile(mode="w", encoding="ascii", dir=directory, prefix="%d." % server, delete=False) as destination:
            temporary = destination.name
            destination.write("%s\n%s\n%s\n%s\n%s\n%s\n" % ((server_token, session_id) + tuple(event)))
        os.replace(temporary, os.path.join(directory, pending_name(server, session_id)))
        temporary = None
        return True
    except Exception:
        return False
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except Exception:
                pass
        os.close(guard)

def pane_titles():
    # Every pane title as an observer reads it: the spinner turning, or the
    # action prefix blinking, shows no thread.
    raw = run(["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_title}"], MAX_OUTPUT)
    if raw is None:
        return None
    keys = []
    for line in raw.splitlines():
        pane, _, title = line.partition(b"\t")
        keys.append(pane + b"\t" + title_key(title).encode("utf-8"))
    return hashlib.sha256(b"\n".join(keys)).digest()

def tmux_listed(panes, deadline):
    # Whether the tmux server a binder polls listed its panes: False when
    # tmux answered before the deadline without them, as where none is
    # installed or no server runs, on plain SSH or mosh, or where too many
    # panes run to tell; None when the deadline cut it short or tmux could
    # not start.
    if panes is not None:
        return True
    return False if time.monotonic() < deadline and not RUN_UNSTARTED else None

def bind_later(server, session_id, event, found, deadline):
    # One binder a thread: a later event only replaces the record it reads.
    # Only a thread of the server of this home that it holds as a root, or
    # holds no rollout of yet, as a new one, gets one, and only where tmux
    # lists panes, as bound_pane found by the deadline of the hook. tmux is
    # asked last, if bound_pane stopped before: a slow one can take the rest
    # of the deadline. A server bound_pane could not tell, or a start of it
    # that could not be read, in time, as from a ps that failed to fork or
    # answered late, loses no event: a detached child asks again with no
    # deadline, then records the event and becomes the binder, or leaves
    # it to the one there is.
    global RUN_DEADLINE
    if not valid_pending(event) or found.get("server", False) is False or found.get("helper"):
        return
    server_token = process_start_token(server) if found["server"] else None
    detached = server_token is None
    if detached:
        if not detach(None):
            return
        RUN_DEADLINE = None
        # tmux, if bound_pane did not ask it, answers in time of its own.
        deadline = time.monotonic() + 2
        if found["server"] is None:
            if not settled(lambda: live_codex(server)) or not home_server(server):
                return
            evidence = server_evidence(server)
            if evidence is not None and session_id not in evidence[0] and session_id in evidence[1]:
                return
        server_token = settled(lambda: live_start(server))
        if not server_token:
            return
    if "tmux" not in found:
        found["tmux"] = tmux_listed(shared_panes(), deadline)
    if found["tmux"] is False or not record_pending(server, server_token, session_id, event):
        return
    lock = observer_lock(server, "shared-binder." + thread_key(session_id))
    if lock is None or not (detached or detach(lock)):
        return
    # Detached, the binder keeps the priority of the hooks it runs, which
    # hold the locks a native hook waits for, and deadlines of its own.
    RUN_DEADLINE = None
    try:
        lock = wait_for_binding(server, server_token, session_id, lock)
    finally:
        if lock is not None:
            try:
                os.close(lock)
            except Exception:
                pass

def client_epoch(pid):
    # The time of the claim a client holds, an ending too, or "" when it
    # never published; None when that cannot be told.
    claim = read_observer_claim(pid, ended=True)
    if claim is not None:
        return claim[1]
    directory = runtime_state_directory()
    if directory is None:
        return None
    try:
        os.lstat(os.path.join(directory, "%d.json" % pid))
    except FileNotFoundError:
        return ""
    except Exception:
        return None
    return None

def publish_pending(server, server_token, session_id, client, client_token, path, pane):
    # Publishes to the bound client the newest event recorded for the
    # thread, then one recorded meanwhile, each at the time the server ran
    # it and against the claim the client holds, whatever thread that
    # names. A client that published after the event, as a native hook does
    # once the title shows the thread, keeps its claim; the delivery lock
    # decides a race. A client that moved on from another thread, as after
    # /new, takes the event of the one it shows now. False while an event
    # is still owed.
    for _ in range(SHARED_REPLAYS):
        event = read_pending(server, server_token, session_id)
        if event is None:
            return True
        epoch = client_epoch(client)
        if epoch is None:
            return False
        if epoch and int(epoch) >= int(event[3]):
            return True
        invoke_observed_hook(client, client_token, session_id, path, epoch, pane, event[:3], event[3])
        epoch = client_epoch(client)
        if not epoch or int(epoch) < int(event[3]):
            return False
    return False

def release_binder(server, server_token, session_id, lock, client=None, final=False, timed=None):
    # Lets the binder lock go under the record lock, so a hook that records
    # an event afterwards finds no binder and starts one. Keeps it while the
    # record lock cannot be had, and, unless final, while the record holds
    # an event in its window that the bound client has not published past.
    # A record published, or past its window, goes, and with no record left
    # the lock files of the thread go too, while both are held. A final
    # binder, whose server ended, waits longer for the record lock and then
    # lets its lock go anyway: that server runs no hook that records more.
    # Returns the lock still held.
    guard = pending_lock(server, session_id, SHARED_LATER_DEADLINE if final else None)
    if guard is None and not final:
        return lock
    try:
        event = read_pending(server, server_token, session_id)
        directory = runtime_state_directory()
        if event is not None:
            expired = pending_expired(event, timed)
            epoch = client_epoch(client) if client is not None else None
            published = bool(epoch) and int(epoch) >= int(event[3])
            if not (final or expired or published):
                return lock
            if guard is not None and directory is not None and (expired or published):
                try:
                    os.unlink(os.path.join(directory, pending_name(server, session_id)))
                except Exception:
                    pass
        if guard is not None and directory is not None and not os.path.lexists(os.path.join(directory, pending_name(server, session_id))):
            # A hook that opened either before then takes it again on the
            # file the path names after.
            key = thread_key(session_id)
            for kind, held in (("shared-binder." + key, lock), ("shared-pending." + key, guard)):
                path = lock_path(directory, server, kind)
                if held_at(path, held):
                    try:
                        os.unlink(path)
                    except Exception:
                        pass
        os.close(lock)
        return None
    finally:
        if guard is not None:
            os.close(guard)

def wait_for_binding(server, server_token, session_id, lock):
    # Tries whenever a pane title changes, the way a name shows, and again
    # less often with the title as is: what kept the thread unbound, as a
    # name the index does not hold yet or a slow host, can pass. Past its
    # ceiling it tries only every SHARED_LATER_SLOW seconds, an event
    # recorded meanwhile too, since the hook of that event found this binder
    # and started none. It waits out the window of the newest event, and the
    # record goes with it. Bound, the client publishes what it never did,
    # and this binder becomes its title observer unless one runs. Returns
    # the lock it still holds.
    global RUN_DEADLINE
    ceiling = time.monotonic() + SHARED_LATER_CEILING
    seen = timed = None
    retry = delay = 0
    while True:
        time.sleep(1)
        if process_ended(server, server_token):
            return release_binder(server, server_token, session_id, lock, final=True)
        event = read_pending(server, server_token, session_id)
        if event is not None and (timed is None or timed[0] != event):
            timed = (event, time.monotonic())
        if event is None or pending_expired(event, timed):
            lock = release_binder(server, server_token, session_id, lock, timed=timed)
            if lock is None:
                return None
            continue
        now = time.monotonic()
        if now >= ceiling:
            if now < retry:
                continue
            retry = now + SHARED_LATER_SLOW
        else:
            titles = pane_titles()
            now = time.monotonic()
            if titles is None or (titles == seen and now < retry):
                continue
            delay = min(delay * 2, SHARED_LATER_RETRY) if titles == seen else 2
            seen, retry = titles, now + delay
        RUN_DEADLINE = time.monotonic() + SHARED_LATER_DEADLINE
        try:
            bound = bound_pane(server, session_id, RUN_DEADLINE)
        finally:
            RUN_DEADLINE = None
        if bound is None:
            continue
        pane, client, client_token, path, _ = bound
        if not publish_pending(server, server_token, session_id, client, client_token, path, pane):
            continue
        observer = observer_lock(client, "shared-observer")
        lock = release_binder(server, server_token, session_id, lock, client, timed=timed)
        if lock is not None:
            # An event recorded meanwhile is still owed.
            if observer is not None:
                os.close(observer)
            retry = 0
            continue
        if observer is not None:
            try:
                watch_shared(client, client_token, bootstrap=True)
            finally:
                os.close(observer)
        return None

def bound_pane(server, session_id, deadline, found=None):
    # found, when given, learns what decides whether a binder could do
    # better: the server is the one of this home, it holds the thread as no
    # root, as a subagent or a helper, and tmux lists panes at all.
    found = {} if found is None else found
    # None when a ps that failed to fork or answered late could not tell.
    found["server"] = server > 1 and is_codex(server) and home_server(server)
    if not found["server"]:
        return None
    evidence = server_evidence(server)
    if evidence is not None and session_id not in evidence[0]:
        found["helper"] = session_id in evidence[1]
    if evidence is None or session_id not in evidence[0]:
        return None
    roots, rendered = evidence
    header = project_names(root[2] for root in roots.values())
    if header is None:
        return None
    # A resumed thread reads the project config of its own cwd.
    thread_configs = project_configs([root[2] for root in roots.values()])
    plain = title_layout_plain(list(CODEX_CONFIGS) + thread_configs)
    items = title_items(session_id, rendered, project_items(header), plain)
    table = process_table()
    panes = shared_panes()
    found["tmux"] = tmux_listed(panes, deadline)
    if not items or table is None or panes is None or time.monotonic() > deadline:
        return None
    parents, commands = table
    children = process_children(parents)
    matches = {}
    for pane, (pane_pid, title) in panes.items():
        if not any(title_shows(title, item) for item in items):
            continue
        client = pane_client(pane_pid, server, parents, commands, children)
        if client is not None:
            matches[pane] = (pane_pid, client, title)
    if len(matches) != 1 or time.monotonic() > deadline:
        return None
    pane, (pane_pid, client, title) = next(iter(matches.items()))
    verified = verified_client(client, pane_pid, server)
    if verified is None or not is_codex(server):
        return None
    start_token, local, configs = verified
    # The project items and the title layout follow the client.
    items = title_items(session_id, rendered, project_items(header | local), plain and title_layout_plain(configs))
    if not any(title_shows(title, item) for item in items):
        return None
    rechecked = server_threads(server)
    if rechecked is None or rechecked[0].get(session_id) != roots[session_id] or time.monotonic() > deadline:
        return None
    if not mark_shared_client(client, start_token, server, pane):
        return None
    # The first event bound can come during a turn, as when the prompt is an
    # argument; the hook then starts the observer the client lacks.
    lock = observer_lock(client, "shared-observer")
    if lock is not None:
        os.close(lock)
    return pane, client, start_token, roots[session_id][0], int(lock is not None)

def shared_target(server, pane, claim, client):
    # The thread a bound client shows now, with its rollout: the one root
    # that this pane alone shows by an item only that root can show, or ""
    # when the title shows no thread the server holds. A title that still
    # shows the claimed thread that way keeps it; a title showing a thread
    # other than a root, as when the TUI opens a subagent, an unclear one,
    # or a pane the client no longer holds alone, decides nothing.
    evidence = server_evidence(server, claim)
    panes = shared_panes()
    table = process_table()
    if evidence is None or panes is None or table is None or pane not in panes:
        return None
    pane_pid, own = panes[pane]
    # A Codex started after the client, as when it was suspended, shows its
    # own title in the pane.
    if pane_client(pane_pid, server, table[0], table[1], process_children(table[0])) != client:
        return None
    roots, rendered = evidence
    scope = client_scope(client, process_arguments(client))
    header = project_names(root[2] for root in roots.values())
    if scope is None or header is None:
        return None
    projects = project_items(header | scope[0])
    plain = title_layout_plain(scope[1] + project_configs([root[2] for root in roots.values()]))
    if claim and any(title_shows(own, item) for item in title_items(claim, rendered, projects, plain)):
        return claim, roots.get(claim, (None,))[0]
    # Each root weighed is weighed against every other thread, so only a
    # few the title can be read in are.
    showing = [thread for thread in roots if any(title_shows(own, item) for item in rendered[thread][0] | rendered[thread][1])]
    if len(showing) > MAX_SHOWN:
        return None
    shown = []
    for session_id in showing:
        items = title_items(session_id, rendered, projects, plain)
        if not any(title_shows(own, item) for item in items):
            continue
        if any(title_shows(title, item) for other, (_, title) in panes.items() if other != pane for item in items):
            return None
        shown.append(session_id)
    if len(shown) == 1:
        return shown[0], roots[shown[0]][0]
    # The claim alone showing a name it can no longer prove, as one that
    # reads as the project, no longer holds the pane; under a layout of
    # other items no title shows that no thread is open.
    if shown or not plain or any(title_shows(own, item) for thread, (ids, named) in rendered.items() if thread != claim for item in ids | named):
        return None
    return "", None

def title_key(raw):
    # The spinner, also as GNU screen shows it, and the blinking action
    # prefix change with no change of thread. Only a leading ASCII frame
    # folds: elsewhere the same characters can be part of a name.
    title = re.sub("[\u2800-\u28ff]", "", title_text(raw.decode("utf-8", "replace"), False))
    title = re.sub(r"^(\* )?[|/\\-](?= |$)", r"\1|", title)
    return title.replace("[ . ] Action Required", "[ ! ] Action Required")

def watch_shared(pid, start_token, bootstrap=False):
    # A bound client holds no rollout, so its observer follows the pane
    # title and the claim. A change is decided twice, a second apart, before
    # the claim follows it; an unclear title keeps the claim. An undecided
    # state, or one whose publication left the claim, is tried again, less
    # often each time: what made it unclear can pass with the title as is.
    # A node launcher leaves its native client no claim before the first
    # prompt; the empty epoch then permits only an absent claim.
    def current_claim():
        claim = read_observer_claim(pid)
        return ("", "") if claim is None and bootstrap else claim
    settled = pending = retry = None
    while not watcher_ended(pid, start_token):
        shared = shared_client(pid, start_token)
        if shared is None:
            return
        server, pane = shared
        claim = current_claim()
        raw = run(["tmux", "display-message", "-p", "-t", pane, "#{pane_title}"], 4096)
        if claim is not None and raw is not None:
            state = (server, pane, title_key(raw), claim)
            now = time.monotonic()
            if state != settled and (retry is None or retry[0] != state or now >= retry[1]):
                target = shared_target(server, pane, claim[0], pid)
                if target is not None and target[0] == claim[0]:
                    settled = state
                    pending = retry = None
                elif target is not None and pending != (state, target):
                    pending = (state, target)
                else:
                    if target is not None and current_claim() == claim and watcher_live(pid, start_token):
                        invoke_observed_hook(pid, start_token, target[0], target[1], claim[1], pane)
                    pending = None
                    delay = min(retry[2] * 2, 60) if retry is not None and retry[0] == state else 2
                    retry = (state, now + delay, delay)
        time.sleep(1)

def watch_shared_root(pid_text):
    # Started by a bound event; the mark, not the process tree, ties the
    # client to this observer.
    if not isinstance(pid_text, str) or not re.fullmatch(r"[1-9][0-9]{0,9}", pid_text):
        return
    pid = int(pid_text)
    start_token = settled(lambda: codex_start(pid))
    if not start_token or shared_client(pid, start_token) is None:
        return
    lock = observer_lock(pid, "shared-observer")
    if lock is None or not detach(lock):
        return
    try:
        watch_shared(pid, start_token)
    finally:
        try:
            os.close(lock)
        except Exception:
            pass

def own_title():
    # The title of the pane the observer was started in, which only says
    # when to try again: adopt_shared finds the pane itself.
    pane = os.environ.get("TMUX_PANE", "")
    if not re.fullmatch(r"%[0-9]{1,9}", pane):
        return None
    raw = run(["tmux", "display-message", "-p", "-t", pane, "#{pane_title}"], 4096)
    return None if raw is None else title_key(raw)

def adopt_shared(pid, start_token):
    # The one server of this home and the one pane whose client is this
    # one, when that pane shows a thread the server hosts as only it can.
    table = process_table()
    if table is None:
        return None
    parents, names = table
    servers = []
    for server, name in names.items():
        if name not in CODEX_COMMANDS or server == pid or not home_server(server):
            continue
        owner = current_uid(server)
        if owner is None:
            # A ps that failed to fork or answered late: not one server too
            # few, but the next try.
            return None
        if owner == os.getuid() and client_home(server):
            servers.append(server)
    if len(servers) != 1:
        return None
    server = servers[0]
    panes = shared_panes()
    if panes is None:
        return None
    children = process_children(parents)
    held = [pane for pane, (pane_pid, _) in panes.items() if pane_client(pane_pid, server, parents, names, children) == pid]
    if len(held) != 1:
        return None
    pane = held[0]
    verified = verified_client(pid, panes[pane][0], server)
    if verified is None or verified[0] != start_token:
        return None
    target = shared_target(server, pane, "", pid)
    if target is None or not target[0]:
        return None
    return server, pane

def repair():
    raw = run(["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}\t#{@tessera_agent_state}"], MAX_OUTPUT)
    repaired = 0
    if raw is None:
        print("TESSERA_AGENT_CODEX_RECOVERY repaired=0")
        return
    # What a ps could not tell of a pane is asked again, within one SETTLE
    # for every pane.
    until = time.monotonic() + SETTLE
    # Grouped sessions list a shared pane once for each session.
    seen = set()
    for line in raw.splitlines():
        try:
            pane, pane_pid, state = line.decode("utf-8", "strict").split("\t", 2)
            pane_pid = int(pane_pid)
        except Exception:
            continue
        if pane in seen:
            continue
        if len(seen) == MAX_PANES:
            break
        seen.add(pane)
        agent_pid = legacy_frame(state)
        if agent_pid is None or pane_pid <= 1:
            continue
        if not settled(lambda: legacy_agent(agent_pid, pane_pid), until):
            continue
        candidate = settled(lambda: root_candidate(agent_pid, SESSIONS_ROOT), until)
        if not candidate:
            continue
        path, identity, session_id = candidate
        authority = latest_authority(path, identity)
        if authority is None:
            continue
        if not settled(lambda: legacy_agent(agent_pid, pane_pid), until) or not settled(lambda: still_open(agent_pid, path, identity), until):
            continue
        now = run(["tmux", "show-option", "-p", "-v", "-t", pane, "@tessera_agent_state"], MAX_OUTPUT)
        if now is None:
            continue
        try:
            if now.rstrip(b"\n").decode("utf-8", "strict") != state:
                continue
        except Exception:
            continue
        payload = frame(session_id, path, agent_pid, authority)
        if run(["tmux", "set-option", "-p", "-t", pane, "@tessera_agent_state", payload], MAX_OUTPUT) is not None:
            repaired += 1
    print("TESSERA_AGENT_CODEX_RECOVERY repaired=%d" % repaired)

def main():
    global SESSIONS_ROOT, SESSION_INDEX, CODEX_CONFIGS
    home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    SESSIONS_ROOT = os.path.realpath(os.path.join(home, "sessions"))
    SESSION_INDEX = os.path.join(home, "session_index.jsonl")
    CODEX_CONFIGS = (os.path.join(home, "config.toml"),) + CODEX_CONFIGS[1:]
    arguments = sys.argv[1:]
    if not arguments:
        repair()
        return
    if len(arguments) == 2 and arguments[0] == "--watch-root":
        if re.fullmatch(r"[1-9][0-9]{0,9}", arguments[1]):
            watch_root(arguments[1])
        return
    if len(arguments) == 2 and arguments[0] == "--watch-shared":
        watch_shared_root(arguments[1])
        return
    if len(arguments) == 4 and arguments[0] == "--verify-observation":
        verified = verify_observation(arguments[1], arguments[2], arguments[3])
        if verified is not None:
            print(verified)
        return
    if len(arguments) in (3, 7) and arguments[0] == "--bind-shared":
        # With the event, a thread no pane shows yet binds later.
        bound = bind_shared(arguments[1], arguments[2], tuple(arguments[3:]) if len(arguments) == 7 else None)
        if bound is not None:
            print(bound)
        return
    if len(arguments) not in (3, 7) or arguments[0] != "--resolve-root":
        return
    # With the event, one whose open files could not be read yet is
    # published once they read.
    resolved = resolve_root(arguments[1], arguments[2], tuple(arguments[3:]) if len(arguments) == 7 else None)
    if resolved is not None:
        print(resolved)

try:
    main()
except Exception:
    if len(sys.argv) == 1:
        print("TESSERA_AGENT_CODEX_RECOVERY repaired=0")' "$@"
exit 0
"""#
}
