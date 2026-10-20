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

python3 -c 'import base64
import calendar
import datetime
import json
import os
import re
import select
import stat
import subprocess
import sys
import time

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

def run(argv, limit=MAX_OUTPUT, env=None):
    process = None
    try:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        deadline = time.monotonic() + 2
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
    if pid <= 1:
        return False
    owner = current_uid(pid)
    if owner != os.getuid():
        return False
    return command_name(pid) in CODEX_COMMANDS

def is_codex_launcher(pid):
    if current_uid(pid) != os.getuid() or command_name(pid) not in NODE_COMMANDS:
        return False
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as source:
            arguments = source.read(65536).decode("utf-8", "strict").split("\0")[1:]
    except Exception:
        raw = run(["ps", "-o", "args=", "-p", str(pid)], 65536)
        if raw is None:
            return False
        try:
            arguments = raw.decode("utf-8", "strict").split()[1:]
        except Exception:
            return False
    return any("@openai/codex" in argument or os.path.basename(argument) == "codex.js" for argument in arguments)

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
                if command_name(child) in CODEX_COMMANDS and is_codex(child):
                    token = process_start_token(child)
                    if token is not None:
                        candidates.append((child, token))
                break
            if ancestor is None or ancestor <= 1:
                break
    if len(candidates) != 1:
        return None
    child, token = candidates[0]
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
        if child is None or child <= 1:
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
        flags = os.O_RDONLY
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

def linux_open_files_strict(pid, sessions_root):
    directory = "/proc/%d/fd" % pid
    try:
        entries = sorted(os.listdir(directory), key=lambda value: int(value))
    except Exception:
        return None
    if len(entries) > MAX_FDS:
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
            return None
    return result

def linux_open_files(pid, sessions_root):
    result = linux_open_files_strict(pid, sessions_root)
    return result if result is not None else []

def mac_open_files_strict(pid, sessions_root):
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
            return None
    return result

def mac_open_files(pid, sessions_root):
    result = mac_open_files_strict(pid, sessions_root)
    return result if result is not None else []

def root_metadata(path, identity):
    try:
        flags = os.O_RDONLY
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
    files = linux_open_files(pid, sessions_root) if os.path.isdir("/proc/%d/fd" % pid) else mac_open_files(pid, sessions_root)
    unique = {}
    for path, identity in files:
        session_id = root_metadata(path, identity)
        if session_id is not None:
            unique[identity] = (path, identity, session_id)
    if len(unique) != 1:
        return None
    return next(iter(unique.values()))

def strict_root_inventory(pid, sessions_root):
    files = linux_open_files_strict(pid, sessions_root) if os.path.isdir("/proc/%d/fd" % pid) else mac_open_files_strict(pid, sessions_root)
    if files is None:
        return None
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
        flags = os.O_RDONLY
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
    checked = safe_file(path, SESSIONS_ROOT, identity)
    if checked is None:
        return False
    if os.path.isdir("/proc/%d/fd" % pid):
        return any(item_identity == identity for _, item_identity in linux_open_files(pid, SESSIONS_ROOT))
    return any(item_identity == identity for _, item_identity in mac_open_files(pid, SESSIONS_ROOT))

def resolve_root(pid_text, session_id):
    if not isinstance(pid_text, str) or not re.fullmatch(r"[1-9][0-9]{0,9}", pid_text):
        return None
    if not isinstance(session_id, str) or not TOKEN.fullmatch(session_id):
        return None
    try:
        pid = int(pid_text)
    except Exception:
        return None
    if pid <= 1 or not is_codex(pid):
        return None
    candidate = root_candidate(pid, SESSIONS_ROOT)
    if candidate is None:
        return None
    path, identity, resolved_session_id = candidate
    if resolved_session_id != session_id:
        return None
    if not is_codex(pid) or not still_open(pid, path, identity):
        return None
    return base64.urlsafe_b64encode(path.encode("utf-8")).decode("ascii").rstrip("=")

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

def observer_lock(pid):
    directory = runtime_state_directory()
    if directory is None or not hasattr(os, "O_NOFOLLOW"):
        return None
    path = os.path.join(directory, "%d.observer.lock" % pid)
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid():
            os.close(descriptor)
            return None
        import fcntl
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return descriptor
    except Exception:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except Exception:
                pass
        return None

def read_observer_claim(pid):
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
        if event not in {"SessionStart", "SubagentStart", "SubagentStop", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Notification", "Stop", "StopFailure"}:
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

def invoke_observed_hook(pid, start_token, session_id, path, stamp):
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
        process = subprocess.Popen([hook, "codex", "SessionStart", "idle", "session-start"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
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
    return is_codex(pid) and process_start_token(pid) == start_token

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
    while watcher_live(pid, start_token):
        claim = read_observer_claim(pid)
        if claim is None and bootstrap:
            # A node launcher has no native child claim before the first
            # prompt. The empty epoch permits only an absent claim under the
            # delivery lock; a racing native hook always wins.
            claim = ("", "")
        if claim is not None:
            watch_once(pid, start_token, claim)
        time.sleep(1)

def observer_target(pid):
    # The launcher publishes the bootstrap SessionStart under its own PID and
    # execs Codex under that PID only after the hook returns, so the target
    # may still be the launcher shell here. Bind to PID plus start token,
    # which survives exec, and let the detached observer wait for the exec.
    # Nothing is published before watcher_live proves Codex under that exact
    # identity, so a launcher that never becomes Codex only idles an observer.
    if pid <= 1 or current_uid(pid) != os.getuid() or not descendant(os.getpid(), pid):
        return None
    return process_start_token(pid)

def await_codex(pid, start_token, timeout):
    deadline = time.monotonic() + timeout
    interval = 0.05
    while time.monotonic() < deadline:
        if process_start_token(pid) != start_token:
            return None
        name = command_name(pid)
        if name in CODEX_COMMANDS and is_codex(pid):
            return pid, start_token
        if name in NODE_COMMANDS:
            if not is_codex_launcher(pid):
                return None
            target = native_codex_child(pid, start_token)
            if target is not None:
                return target
        time.sleep(interval)
        interval = min(interval * 2, 1.0)
    return None

def watch_root(pid_text):
    if not isinstance(pid_text, str) or not re.fullmatch(r"[1-9][0-9]{0,9}", pid_text):
        return
    try:
        pid = int(pid_text)
    except Exception:
        return
    start_token = observer_target(pid)
    if start_token is None:
        return
    lock = observer_lock(pid)
    if lock is None:
        return
    try:
        child = os.fork()
    except Exception:
        try:
            os.close(lock)
        except Exception:
            pass
        return
    if child != 0:
        try:
            os.close(lock)
        except Exception:
            pass
        return
    try:
        null = os.open(os.devnull, os.O_RDWR)
        os.dup2(null, 0)
        os.dup2(null, 1)
        os.dup2(null, 2)
        if null > 2:
            os.close(null)
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

def repair():
    raw = run(["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{pane_pid}\t#{@tessera_agent_state}"], MAX_OUTPUT)
    repaired = 0
    if raw is None:
        print("TESSERA_AGENT_CODEX_RECOVERY repaired=0")
        return
    for line in raw.splitlines()[:MAX_PANES]:
        try:
            pane, pane_pid, state = line.decode("utf-8", "strict").split("\t", 2)
            pane_pid = int(pane_pid)
        except Exception:
            continue
        agent_pid = legacy_frame(state)
        if agent_pid is None or pane_pid <= 1:
            continue
        pane_owner = current_uid(pane_pid)
        if pane_owner != os.getuid():
            continue
        if not is_codex(agent_pid) or not descendant(agent_pid, pane_pid):
            continue
        candidate = root_candidate(agent_pid, SESSIONS_ROOT)
        if candidate is None:
            continue
        path, identity, session_id = candidate
        authority = latest_authority(path, identity)
        if authority is None:
            continue
        if not is_codex(agent_pid) or not descendant(agent_pid, pane_pid) or not still_open(agent_pid, path, identity):
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
    global SESSIONS_ROOT
    home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    SESSIONS_ROOT = os.path.realpath(os.path.join(home, "sessions"))
    arguments = sys.argv[1:]
    if not arguments:
        repair()
        return
    if len(arguments) == 2 and arguments[0] == "--watch-root":
        if re.fullmatch(r"[1-9][0-9]{0,9}", arguments[1]):
            watch_root(arguments[1])
        return
    if len(arguments) == 4 and arguments[0] == "--verify-observation":
        verified = verify_observation(arguments[1], arguments[2], arguments[3])
        if verified is not None:
            print(verified)
        return
    if len(arguments) != 3 or arguments[0] != "--resolve-root":
        return
    resolved = resolve_root(arguments[1], arguments[2])
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
