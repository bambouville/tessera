#!/usr/bin/env python3
"""Opt-in real Claude hook probe; synthetic prompts, private artifacts, no install.

Uses existing provider authentication but disables user/project settings, MCP,
and skills for newly created sessions. Never resumes or sends input to an
existing user session. Raw outputs stay in an owned directory outside git.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import selectors
import shlex
import signal
import socket
import stat
import struct
import subprocess
import tempfile
import threading
import time
import uuid

EVENTS = ["SessionStart", "UserPromptSubmit", "MessageDisplay", "PreToolUse",
          "PostToolUse", "PostToolBatch", "Stop", "StopFailure", "SessionEnd"]


def stop_owned_process(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


class Collector:
    def __init__(self, directory):
        self.path = directory / "events.sock"
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(self.path))
        self.path.chmod(0o600)
        self.server.listen(64)
        self.server.settimeout(0.1)
        self.events = []
        self.errors = []
        self.finished = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def run(self):
        while not self.finished.is_set():
            try:
                connection, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with connection:
                connection.settimeout(0.25)
                data = bytearray()
                try:
                    while chunk := connection.recv(8192):
                        data.extend(chunk)
                        if len(data) > 65540:
                            raise ValueError("oversized")
                    if not data:
                        continue
                    if len(data) < 4 or struct.unpack("!I", data[:4])[0] != len(data) - 4:
                        raise ValueError("incomplete")
                    event = json.loads(data[4:])
                    self.events.append({"received_ns": time.monotonic_ns(), "input": event})
                except (ValueError, OSError) as error:
                    self.errors.append(type(error).__name__)

    def close(self):
        self.finished.set()
        if self.thread.ident is not None:
            self.thread.join(1)
        self.server.close()


class NativeCollector:
    """Exercise the actual native service, not just a Python socket listener."""
    def __init__(self, directory, sender, session):
        runtime = directory / "r"
        self.path = runtime / "hooks.sock"
        self.process = subprocess.Popen([str(sender), "serve", "--runtime", str(runtime), "--idle-ms", "1000"],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.events, self.errors = [], []
        self.closed = False
        self.finished = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.connection.settimeout(.2)
        try:
            deadline = time.monotonic() + 3
            while not self.path.exists():
                if time.monotonic() > deadline or self.process.poll() is not None:
                    raise RuntimeError("native service startup failed")
                time.sleep(.01)
            self.connection.connect(str(runtime / "client.sock"))
            self.buffer = bytearray()
            self.send({"kind": "hello", "v": 3, "id": "hello"})
            if self.receive()["kind"] != "hello":
                raise RuntimeError("native handshake failed")
            self.send({"kind": "subscribe", "id": "sub", "session_id": session, "interest": "fast"})
            if self.receive()["kind"] != "subscribed":
                raise RuntimeError("native subscribe failed")
        except BaseException:
            self.connection.close()
            stop_owned_process(self.process)
            raise

    def send(self, value):
        data = json.dumps(value).encode()
        self.connection.sendall(struct.pack("!I", len(data)) + data)

    def receive(self):
        while True:
            if len(self.buffer) >= 4:
                length, = struct.unpack("!I", self.buffer[:4])
                if not 0 < length <= 65536:
                    raise ValueError("bad native frame")
                if len(self.buffer) >= length + 4:
                    value = json.loads(self.buffer[4:length + 4])
                    del self.buffer[:length + 4]
                    return value
            chunk = self.connection.recv(8192)
            if not chunk:
                raise EOFError("native service disconnected")
            self.buffer.extend(chunk)

    def run(self):
        heartbeat = time.monotonic()
        while not self.finished.is_set():
            try:
                if time.monotonic() - heartbeat > 10:
                    self.send({"kind": "heartbeat", "id": "beat"})
                    heartbeat = time.monotonic()
                value = self.receive()
                if value.get("kind") == "hookPreview":
                    self.events.append({"received_ns": time.monotonic_ns(), "input": value["event"]})
                elif value.get("kind") != "ack":
                    self.errors.append(value.get("kind", "unknown_native_response"))
            except socket.timeout:
                continue
            except (ValueError, OSError, EOFError) as error:
                self.errors.append(type(error).__name__)
                break

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.finished.set()
        if self.thread.ident is not None:
            self.thread.join(1)
        self.connection.close()
        try:
            if self.process.wait(timeout=3) != 0:
                self.errors.append("native_exit_failed")
        except subprocess.TimeoutExpired:
            self.errors.append("native_idle_exit_failed")
            stop_owned_process(self.process)


def private_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
    path.chmod(0o600)


def transcript_evidence(inputs, session_id, case):
    """Read only this run's newly generated synthetic transcript; publish no IDs/text."""
    starts = [value for value in inputs if value.get("hook_event_name") == "SessionStart"]
    if not starts:
        return {"available": False}
    start = starts[0]
    path = Path(start.get("transcript_path", ""))
    if (start.get("session_id") != session_id or Path(start.get("cwd", "")).resolve() != case or
            path.stem != session_id or not path.exists()):
        return {"available": False}
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024 * 1024:
        return {"available": False, "reason": "synthetic_transcript_limit"}
    records = [json.loads(line) for line in path.read_text().splitlines() if line]
    assistants = [value for value in records if value.get("type") == "assistant"]
    display = [value for value in inputs if value.get("hook_event_name") == "MessageDisplay"]
    canonical_text = "".join(block.get("text", "") for value in assistants
                              for block in value.get("message", {}).get("content", [])
                              if block.get("type") == "text")
    canonical_ids = {value.get("uuid") for value in assistants} | {
        value.get("message", {}).get("id") for value in assistants}
    return {"available": True, "records": len(records), "assistant_records": len(assistants),
            "display_matches_text": bool(display) and "".join(value["delta"] for value in display) == canonical_text,
            "display_matches_id": bool({value.get("message_id") for value in display} & (canonical_ids - {None})),
            "record_types": sorted({value.get("type", "unknown") for value in records})}


def capture_tmux(command, environment, case, collector, timeout):
    """Own an independent tmux server; never address the user's tmux socket."""
    base = ["tmux", "-f", "/dev/null", "-S", str(case / "tmux.sock")]
    started = time.monotonic_ns()
    outputs = {"stdout": bytearray(), "stderr": bytearray()}
    collector.partial_outputs = outputs
    trust_accepted = False
    trust_seen_at = None
    stop_at = None
    timed_out = False
    def tmux(*arguments):
        return subprocess.run(base + list(arguments), env=environment, capture_output=True, timeout=5)
    collector.thread.start()
    try:
        result = tmux("new-session", "-d", "-s", "probe", "-x", "120", "-y", "40",
                      "-c", str(case), "exec " + shlex.join(command))
        if result.returncode:
            return result.returncode, False, started, time.monotonic_ns(), outputs, []
        while (time.monotonic_ns() - started) / 1e9 < timeout:
            screen = tmux("capture-pane", "-p", "-S", "-2000", "-t", "probe:0.0")
            if screen.returncode:
                break
            outputs["stdout"] = bytearray(screen.stdout)
            path = case / "private-screen.txt"
            path.write_bytes(screen.stdout)
            path.chmod(0o600)
            text = screen.stdout.decode("utf-8", errors="replace")
            if not trust_accepted and "Yes, I trust this folder" in text:
                # Current Claude defaults to No. Accept only this generated
                # synthetic directory, never an existing user workspace.
                trust_seen_at = trust_seen_at or time.monotonic()
                if time.monotonic() - trust_seen_at > 0.75:
                    if "❯ Yes, I trust this folder" in text:
                        tmux("send-keys", "-t", "probe:0.0", "Enter")
                        trust_accepted = True
                    else:
                        tmux("send-keys", "-t", "probe:0.0", "Down")
                        time.sleep(0.15)
            if any(event["input"].get("hook_event_name") == "Stop" for event in collector.events):
                stop_at = stop_at or time.monotonic()
                if time.monotonic() - stop_at > 1:
                    tmux("send-keys", "-l", "-t", "probe:0.0", "/exit")
                    tmux("send-keys", "-t", "probe:0.0", "Enter")
                    time.sleep(0.5)
                    break
            time.sleep(0.1)
        else:
            timed_out = True
        return 0 if stop_at else 1, timed_out, started, time.monotonic_ns(), outputs, []
    finally:
        try:
            tmux("kill-server")
        except (OSError, subprocess.TimeoutExpired):
            # Retry only the exact owned socket. Never kill a guessed PID or
            # fall back to the user's default tmux server.
            try:
                tmux("kill-server")
            except (OSError, subprocess.TimeoutExpired):
                collector.errors.append("tmux_cleanup_failed")
        finally:
            collector.close()


def capture_headless(command, environment, case, collector, timeout):
    started = time.monotonic_ns()
    process = None
    selector = selectors.DefaultSelector()
    outputs = {"stdout": bytearray(), "stderr": bytearray()}
    collector.partial_outputs = outputs
    stream_events = []
    collector.partial_stream_events = stream_events
    line_buffer = bytearray()
    timed_out = False
    try:
        process = subprocess.Popen(command, cwd=case, env=environment, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        collector.thread.start()
        while selector.get_map():
            if time.monotonic_ns() - started > timeout * 1e9:
                timed_out = True
                break
            for key, _ in selector.select(0.1):
                chunk = os.read(key.fileobj.fileno(), 16384)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                outputs[key.data].extend(chunk)
                if len(outputs[key.data]) > 4 * 1024 * 1024:
                    raise RuntimeError("probe output limit exceeded")
                if key.data == "stdout":
                    line_buffer.extend(chunk)
                    while b'\n' in line_buffer:
                        line, _, remaining = line_buffer.partition(b'\n')
                        line_buffer = bytearray(remaining)
                        try:
                            stream_events.append({"received_ns": time.monotonic_ns(), "input": json.loads(line)})
                        except ValueError:
                            pass
        if timed_out:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
        ended = time.monotonic_ns()
        time.sleep(0.25)
        return process.returncode, timed_out, started, ended, outputs, stream_events
    finally:
        try:
            if process is not None and process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=3)
        finally:
            selector.close()
            if process is not None:
                process.stdout.close()
                process.stderr.close()
            collector.close()


def run_case(args, directory, label, asynchronous, tools):
    case = directory / label
    case.mkdir(mode=0o700)
    session_id = str(uuid.uuid4())
    collector = NativeCollector(case, args.sender, session_id) if args.native_service else Collector(case)
    try:
        return run_owned_case(args, label, asynchronous, tools, case, session_id, collector)
    except BaseException as error:
        private_json(case / "capture-failure.json", {"error_type": type(error).__name__})
        raise
    finally:
        try:
            collector.close()
        finally:
            # Includes setup/launch/output-limit/cancellation failures. Raw
            # evidence stays private even when no successful summary exists.
            private_json(case / "private-events.json", collector.events)
            private_json(case / "private-stream.json", getattr(collector, "partial_stream_events", []))
            for kind, data in getattr(collector, "partial_outputs", {}).items():
                target = case / f"private-{kind}.bin"
                target.write_bytes(data)
                target.chmod(0o600)


def run_owned_case(args, label, asynchronous, tools, case, session_id, collector):
    sender = f"{shlex.quote(str(args.sender))} hook --socket {shlex.quote(str(collector.path))}"
    hooks = {event: [{"hooks": [{"type": "command", "command": sender,
                                  "async": asynchronous, "timeout": 1}]}]
             for event in EVENTS}
    settings = case / "settings.json"
    private_json(settings, {"hooks": hooks, "autoUpdatesChannel": "stable"})
    fixture = case / "probe.txt"
    fixture.write_text("TESSERA_SYNTHETIC_HOOK_FIXTURE\n", encoding="utf-8")
    fixture.chmod(0o600)
    prompt = ("Read probe.txt using Read exactly once, then write exactly 12 numbered lines "
              "describing the numbers one through twelve. No other tools." if tools else
              "Write exactly 12 numbered lines describing the numbers one through twelve. No tools.")
    command = [str(args.claude), "--setting-sources", "",
               "--settings", str(settings), "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
               "--disable-slash-commands", "--no-chrome", "--session-id", session_id,
               "--tools", "Read" if tools else "", "--allowedTools", "Read" if tools else "",
               "--model", args.model, "--effort", "low",
               "--system-prompt", "You are participating in an isolated synthetic hook test. Follow the user request exactly."]
    if not args.interactive:
        command += ["--print", "--verbose", "--output-format", "stream-json",
                    "--include-partial-messages", "--include-hook-events", "--max-budget-usd", "1"]
        if not args.persist:
            command.append("--no-session-persistence")
    command.append(prompt)
    environment = dict(os.environ)
    for key in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "TMUX", "TMUX_PANE"):
        environment.pop(key, None)
    environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    environment["DISABLE_AUTOUPDATER"] = "1"
    environment["CLAUDE_CODE_ENABLE_TELEMETRY"] = "0"
    if args.config_dir:
        environment["CLAUDE_CONFIG_DIR"] = str(args.config_dir)
    capture = capture_tmux if args.interactive else capture_headless
    exit_code, timed_out, started, ended, outputs, stream_events = capture(
        command, environment, case, collector, args.timeout)
    inputs = [entry["input"] for entry in collector.events]
    count = collections.Counter(value.get("hook_event_name", "unknown") for value in inputs)
    fields = {name: sorted({key for value in inputs if value.get("hook_event_name") == name for key in value})
              for name in count}
    display = [value for value in inputs if value.get("hook_event_name") == "MessageDisplay"]
    api_assistants = [entry["input"] for entry in stream_events if entry["input"].get("type") == "assistant"]
    result = next((entry["input"] for entry in reversed(stream_events)
                   if entry["input"].get("type") == "result"), {})
    message_ids = {value.get("message_id") for value in display}
    api_ids = {value.get("message", {}).get("id") for value in api_assistants}
    output_ids = {value.get("uuid") for value in api_assistants}
    final_text = result.get("result", "")
    stop = [value for value in inputs if value.get("hook_event_name") == "Stop"]
    display_times = [entry["received_ns"] for entry in collector.events if entry["input"].get("hook_event_name") == "MessageDisplay"]
    stop_times = [entry["received_ns"] for entry in collector.events if entry["input"].get("hook_event_name") == "Stop"]
    summary = {"case": label, "async": asynchronous, "tools": tools, "interactive": args.interactive,
               "native_service": args.native_service,
               "exit_code": exit_code, "timed_out": timed_out,
               "wall_ms": (ended - started) / 1e6, "result_is_error": result.get("is_error"),
               "result_subtype": result.get("subtype"), "hook_counts": dict(count),
               "hook_fields": fields, "collector_errors": collector.errors,
               "display_batches": [{"index": value.get("index"), "final": value.get("final"),
                                     "delta_bytes": len(value.get("delta", "").encode())} for value in display],
               "display_matches_api_id": bool((message_ids - {None}) & (api_ids - {None})),
               "display_matches_stream_uuid": bool((message_ids - {None}) & (output_ids - {None})),
               "display_matches_stop": bool(display and stop and
                   "".join(value.get("delta", "") for value in display) == stop[-1].get("last_assistant_message")),
               "display_indices_contiguous": [value.get("index") for value in display] == list(range(len(display))),
               "display_final_count": sum(value.get("final") is True for value in display),
               "first_display_before_stop_ms": (stop_times[-1] - display_times[0]) / 1e6 if display_times and stop_times else None,
               "stop_matches_final_result": bool(stop and final_text and stop[-1].get("last_assistant_message") == final_text),
               "first_hook_ms": (collector.events[0]["received_ns"] - started) / 1e6 if inputs else None,
               "stream_type_counts": dict(collections.Counter(entry["input"].get("type", "unknown") for entry in stream_events))}
    if args.interactive or args.persist:
        summary["synthetic_transcript"] = transcript_evidence(inputs, session_id, case)
    private_json(case / "summary.json", summary)
    return summary


def case_failures(summary):
    failures = []
    if summary["exit_code"] or summary["timed_out"] or summary["result_is_error"]:
        failures.append("provider_failed")
    if summary["collector_errors"]:
        failures.append("collector_failed")
    required = ["SessionStart", "UserPromptSubmit", "MessageDisplay", "Stop", "SessionEnd"]
    if summary["tools"]:
        required += ["PreToolUse", "PostToolUse", "PostToolBatch"]
    if any(not summary["hook_counts"].get(event) for event in required):
        failures.append("missing_required_hook")
    if not summary["display_matches_stop"]:
        failures.append("display_text_mismatch")
    if (not summary["display_indices_contiguous"] or summary["display_final_count"] != 1 or
            not summary.get("display_batches") or summary["display_batches"][-1].get("final") is not True):
        failures.append("display_sequence_mismatch")
    if not summary["interactive"] and not summary["stop_matches_final_result"]:
        failures.append("final_result_mismatch")
    if summary["interactive"]:
        transcript = summary.get("synthetic_transcript", {})
        if not transcript.get("available") or not transcript.get("display_matches_text"):
            failures.append("canonical_text_mismatch")
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sender", type=Path, required=True)
    parser.add_argument("--claude", type=Path, required=True)
    parser.add_argument("--model", default="sonnet")
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--config-dir", type=Path)
    parser.add_argument("--persist", action="store_true", help="Allow newly created synthetic sessions to persist in provider storage")
    parser.add_argument("--interactive", action="store_true", help="Run a new private PTY session; synthetic transcript persists, no existing pane is used")
    parser.add_argument("--native-service", action="store_true", help="Collect through the actual native shared service and framed subscription")
    parser.add_argument("--cases", nargs="+", choices=["sync", "async", "tools"], default=["sync", "async", "tools"])
    args = parser.parse_args()
    if not 5 <= args.timeout <= 300:
        parser.error("timeout must be 5..300 seconds")
    if os.environ.get("TESSERA_RUN_CLAUDE_HOOK_PROBE") != "1":
        parser.error("set TESSERA_RUN_CLAUDE_HOOK_PROBE=1 to authorize synthetic model requests")
    args.sender = args.sender.resolve(strict=True)
    args.claude = args.claude.resolve(strict=True)
    directory = Path(tempfile.mkdtemp(prefix="tch-", dir="/tmp")).resolve()
    print(json.dumps({"private_artifacts": str(directory)}), flush=True)
    summaries = []
    for label in args.cases:
        summary = run_case(args, directory, label, label == "async", label == "tools")
        summary["failures"] = case_failures(summary)
        summaries.append(summary)
        print(json.dumps(summary), flush=True)
        if summary["failures"]:
            break
    private_json(directory / "summary.json", {"sender_sha256": hashlib.sha256(args.sender.read_bytes()).hexdigest(),
                                               "cases": summaries})
    if any(value["failures"] for value in summaries):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
