#!/usr/bin/env python3
"""Hermetic semantic checks for the embedded Codex recovery executable.

Usage: test-codex-conversation-recovery.py /path/to/dumped-recovery.sh
"""

import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
from typing import Any, Optional
import unittest
from unittest import mock


if len(sys.argv) != 2:
    raise SystemExit("usage: test-codex-conversation-recovery.py /path/to/dumped-recovery.sh")


RECOVERY = Path(sys.argv[1]).resolve()
START_MARKER = "python3 -I -c '"
END_MARKER = "\ntry:\n    main()"


def recovery_functions(path: Path) -> dict[str, object]:
    shell = path.read_text(encoding="utf-8")
    start = shell.index(START_MARKER) + len(START_MARKER)
    end = shell.index(END_MARKER, start)
    namespace: dict[str, object] = {"__name__": "tessera_recovery_functions"}
    exec(compile(shell[start:end], str(path), "exec"), namespace)
    return namespace


def metadata(session_id: str, source: object = "cli", thread_source: object = "user") -> dict[str, object]:
    return {
        "type": "session_meta",
        "payload": {
            "source": source,
            "thread_source": thread_source,
            "session_id": session_id,
        },
    }


class Blocked(BaseException):
    """Raised past every except Exception the script has."""


class RecoveryFunctionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.recovery = recovery_functions(RECOVERY)

    @contextlib.contextmanager
    def never_blocks(self, seconds: int = 3):
        def expire(*_arguments: object) -> None:
            raise Blocked()
        previous = signal.signal(signal.SIGALRM, expire)
        signal.alarm(seconds)
        try:
            yield
        except Blocked:
            self.fail("blocked")
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous)

    def write_jsonl(self, root: Path, name: str, records: list[dict[str, object]]) -> Path:
        path = root / name
        path.write_text("".join(json.dumps(record) + "\n" for record in records), encoding="utf-8")
        path.chmod(0o600)
        return path

    def identity(self, path: Path) -> tuple[int, int]:
        value = path.stat()
        return value.st_dev, value.st_ino

    def test_legacy_frame_accepts_only_exact_null_sentinel(self) -> None:
        legacy_frame = self.recovery["legacy_frame"]

        self.assertEqual(legacy_frame(json.dumps({
            "version": 9,
            "provider": "codex",
            "transcriptRef": "Tm9uZQ",
            "agentPid": 42,
        })), 42)

        for frame in (
            {"version": 9, "provider": "codex", "transcriptRef": "L3Nlc3Npb25zL3Jvb3QuanNvbmw", "agentPid": 42},
            {"version": 9, "provider": "claude", "transcriptRef": "Tm9uZQ", "agentPid": 42},
            {"version": 8, "provider": "codex", "transcriptRef": "Tm9uZQ", "agentPid": 42},
            {"version": 9, "provider": "codex", "transcriptRef": "Tm9uZQ", "agentPid": True},
            {"version": 9, "provider": "codex", "transcriptRef": "Tm9uZQ", "agentPid": "42"},
            {"version": 9, "provider": "codex", "transcriptRef": "Tm9uZQ", "agentPid": 1},
            {"version": 9, "provider": "codex", "agentPid": 42},
        ):
            self.assertIsNone(legacy_frame(json.dumps(frame)))

    def test_root_metadata_requires_a_user_root_session_file(self) -> None:
        root_metadata = self.recovery["root_metadata"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-root-") as temporary:
            sessions = Path(temporary)
            session_id = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
            valid = self.write_jsonl(sessions, f"rollout-{session_id}.jsonl", [metadata(session_id)])
            self.assertEqual(root_metadata(str(valid), self.identity(valid)), session_id)

            guardian = self.write_jsonl(
                sessions,
                f"rollout-guardian-{session_id}.jsonl",
                [metadata(session_id, source="guardian_review")],
            )
            self.assertIsNone(root_metadata(str(guardian), self.identity(guardian)))

            subagent = self.write_jsonl(
                sessions,
                f"rollout-subagent-{session_id}.jsonl",
                [metadata(session_id, source={"kind": "cli"})],
            )
            self.assertIsNone(root_metadata(str(subagent), self.identity(subagent)))

            wrong_suffix = self.write_jsonl(sessions, "rollout-other.jsonl", [metadata(session_id)])
            self.assertIsNone(root_metadata(str(wrong_suffix), self.identity(wrong_suffix)))

            # The owner decides the mode of their own transcript: group- or
            # world-writable rollouts, as umask 0002 hosts create them, are
            # still theirs.
            safe_file = self.recovery["safe_file"]
            group_writable = self.write_jsonl(sessions, f"rollout-group-{session_id}.jsonl", [metadata(session_id)])
            for mode in (0o664, 0o666):
                group_writable.chmod(mode)
                self.assertEqual(root_metadata(str(group_writable), self.identity(group_writable)), session_id)
                self.assertEqual(safe_file(str(group_writable), str(sessions.resolve())),
                                 (str(group_writable.resolve()), self.identity(group_writable)))

            link = sessions / f"rollout-link-{session_id}.jsonl"
            os.symlink(valid, link)
            self.assertIsNone(root_metadata(str(link), self.identity(valid)))

            # A FIFO put where a held rollout was never holds the open.
            fifo = sessions / f"rollout-fifo-{session_id}.jsonl"
            os.mkfifo(fifo)
            with self.never_blocks():
                self.assertIsNone(self.recovery["rollout_header"](str(fifo), self.identity(valid)))
                self.assertIsNone(safe_file(str(fifo), str(sessions.resolve())))

    def test_root_candidate_accepts_exactly_one_distinct_root(self) -> None:
        root_candidate = self.recovery["root_candidate"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-candidate-") as temporary:
            sessions = Path(temporary)
            first_id = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
            second_id = "019c6e28-e55b-73d1-bc92-3e3c1bcc0022"
            root = self.write_jsonl(sessions, f"rollout-{first_id}.jsonl", [metadata(first_id)])
            guardian = self.write_jsonl(
                sessions,
                f"rollout-guardian-{first_id}.jsonl",
                [metadata(first_id, source="guardian_review")],
            )
            second = self.write_jsonl(sessions, f"rollout-{second_id}.jsonl", [metadata(second_id)])
            original = self.recovery["mac_open_files"]
            self.recovery["mac_open_files"] = lambda _pid, _root: [
                (str(root), self.identity(root)),
                (str(guardian), self.identity(guardian)),
            ]
            try:
                only_root = root_candidate(9_999_999, str(sessions))
                self.assertEqual(only_root, (str(root), self.identity(root), first_id))
                self.recovery["mac_open_files"] = lambda _pid, _root: [
                    (str(root), self.identity(root)),
                    (str(second), self.identity(second)),
                ]
                self.assertIs(root_candidate(9_999_999, str(sessions)), False)
            finally:
                self.recovery["mac_open_files"] = original

    def test_resolve_root_returns_only_the_exact_open_provider_root(self) -> None:
        resolve_root = self.recovery["resolve_root"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-resolve-") as temporary:
            sessions = Path(temporary)
            session_id = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
            root = self.write_jsonl(sessions, f"rollout-{session_id}.jsonl", [metadata(session_id)])
            identity = self.identity(root)
            self.recovery.update({
                "SESSIONS_ROOT": str(sessions.resolve()),
                "is_codex": lambda pid: pid == 42,
                "root_candidate": lambda pid, directory: (str(root), identity, session_id),
                "still_open": lambda pid, path, file_identity: path == str(root) and file_identity == identity,
            })
            resolved = resolve_root("42", session_id)
            self.assertIsNotNone(resolved)
            self.assertEqual(
                resolved,
                self.recovery["base64"].urlsafe_b64encode(str(root).encode("utf-8")).decode("ascii").rstrip("="),
            )

    def test_open_files_lsof_could_not_list_are_read_again_never_taken_for_none(self) -> None:
        resolve_root, clocks = self.recovery["resolve_root"], self.recovery["time"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-unread-") as temporary:
            sessions = Path(temporary)
            session_id = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
            root = self.write_jsonl(sessions, f"rollout-{session_id}.jsonl", [metadata(session_id)])
            # lsof that could not list is no answer; an unsafe session file
            # open is a definite one, which every reader rejects.
            unsafe = str(sessions.resolve() / "rollout-gone.jsonl")
            for output, expected in ((None, None), (f"p42\nn{unsafe}\n".encode(), False)):
                self.recovery["run"] = lambda argv, limit=0, env=None, output=output: output
                self.assertIs(self.recovery["mac_open_files_strict"](42, str(sessions.resolve())), expected)
                self.assertEqual(self.recovery["mac_open_files"](42, str(sessions.resolve())), None if output is None else [])
            for files in (None, False):
                self.recovery["linux_open_files_strict"] = lambda pid, root, limit=512, files=files: files
                self.recovery["mac_open_files_strict"] = lambda pid, root, files=files: files
                self.assertIs(self.recovery["strict_root_inventory"](42, str(sessions)), files)
                self.assertIsNone(self.recovery["server_threads"](42))
            held = [(str(root), self.identity(root))]
            expected = self.recovery["base64"].urlsafe_b64encode(str(root).encode("utf-8")).decode("ascii").rstrip("=")
            reads: list[float] = []
            unread: set[int] = set()
            clock = [0.0]

            def listed(pid: int, sessions_root: str, limit: int = 512) -> Optional[list[tuple[str, tuple[int, int]]]]:
                # An lsof that failed to fork or answered late, on the reads
                # numbered in unread.
                reads.append(clock[0])
                return None if len(reads) in unread else held

            def sleep(seconds: float) -> None:
                clock[0] += seconds
            observers: list[str] = []
            self.recovery.update({
                "SESSIONS_ROOT": str(sessions.resolve()),
                "is_codex": lambda pid: pid == 42,
                "linux_open_files_strict": listed,
                "mac_open_files_strict": listed,
                "watch_root": lambda pid_text: observers.append(pid_text),
            })
            patches = lambda **kill: (mock.patch.object(clocks, "sleep", side_effect=sleep),
                                      mock.patch.object(clocks, "monotonic", side_effect=lambda: clock[0]), mock.patch.object(os, "kill", **kill))
            # The hook asks again, briefly, for the root and then for its
            # descriptor, rather than taking an unread list for none.
            unread.update({1, 3})
            with contextlib.ExitStack() as stack:
                for patch in patches():
                    stack.enter_context(patch)
                self.assertEqual(resolve_root("42", session_id), expected)
            self.assertEqual((len(reads), observers), (4, []))
            # Still unread when the budget ends, the event goes to the root
            # observer, which publishes the root once the files read.
            reads.clear()
            unread.update(range(1, 100))
            clock[0] = 0.0
            with contextlib.ExitStack() as stack:
                for patch in patches():
                    stack.enter_context(patch)
                self.assertIsNone(resolve_root("42", session_id))
            self.assertEqual(observers, ["42"])
            self.assertGreaterEqual(clock[0], self.recovery["SETTLE"])
            # So does one whose root read, but not then its descriptor.
            reads.clear()
            observers.clear()
            unread.discard(1)
            clock[0] = 0.0
            with contextlib.ExitStack() as stack:
                for patch in patches():
                    stack.enter_context(patch)
                self.assertIsNone(resolve_root("42", session_id))
            self.assertEqual(observers, ["42"])
            # A process no longer there holds nothing, at once.
            reads.clear()
            observers.clear()
            unread.add(1)
            with contextlib.ExitStack() as stack:
                for patch in patches(side_effect=ProcessLookupError()):
                    stack.enter_context(patch)
                self.assertIsNone(resolve_root("42", session_id))
            self.assertEqual((len(reads), observers), (1, []))

        # Where an unread list already rejects, an unsafe one does too: a
        # client whose files could not be read, or that holds an unsafe
        # session file, is no client of a shared server.
        session = self.SESSION
        for files in (None, False):
            self.install_shared_host([("%2", 200, "Fix the parser | demo")], {session: "Fix the parser"})
            self.recovery["linux_open_files_strict"] = lambda pid, root, limit=512, files=files: files if pid == 202 else []
            self.recovery["mac_open_files_strict"] = lambda pid, root, files=files: files if pid == 202 else []
            self.assertIsNone(self.recovery["bind_shared"]("105", session), files)

    def test_an_event_whose_open_files_stay_unread_is_replayed_once_they_read(self) -> None:
        resolve_root, clocks = self.recovery["resolve_root"], self.recovery["time"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-replay-") as temporary:
            sessions = Path(temporary)
            session_id = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
            other_id = "019c6e28-e55b-73d1-bc92-3e3c1bcc0022"
            root = self.write_jsonl(sessions, f"rollout-{session_id}.jsonl", [metadata(session_id)])
            other = self.write_jsonl(sessions, f"rollout-{other_id}.jsonl", [metadata(other_id)])
            event = ("Stop", "idle", "turn-stopped", "1700000000000000000")
            clock = [0.0]
            reads: list[float] = []
            world: dict[str, Any] = {}
            replays: list[tuple[object, ...]] = []
            replayed_at: list[float] = []
            observers: list[str] = []
            detached: list[object] = []

            def listed(pid: int, sessions_root: str, limit: int = 512) -> Optional[list[tuple[str, tuple[int, int]]]]:
                reads.append(clock[0])
                if not world["readable"](len(reads), clock[0]):
                    return None
                if world["closed"] and world.get("served"):
                    return []
                if clock[0] >= 30 and not world.get("served"):
                    world["served"], world["served_at"] = True, clock[0]
                held = other if world["moved"] and clock[0] >= 30 else root
                return [(str(held), self.identity(held))]

            def sleep(seconds: float) -> None:
                clock[0] += seconds

            def kill(pid: int, signal: int) -> None:
                if clock[0] >= world["gone_at"]:
                    raise ProcessLookupError()

            def start(pid: int) -> Optional[str]:
                if clock[0] >= world["gone_at"]:
                    return None
                return "start-2" if clock[0] >= world["restart_at"] else "start-1"

            def invoke(pid: int, start_token: str, session: str, path: str, stamp: str, pane: Optional[str] = None,
                       replayed: tuple[str, str, str] = ("SessionStart", "idle", "session-start"), event_stamp: Optional[str] = None) -> None:
                replays.append((pid, start_token, session, path, stamp, pane, replayed, event_stamp))
                replayed_at.append(clock[0])
                if world["lands"]:
                    world["epoch"] = event_stamp

            self.recovery.update({
                "SESSIONS_ROOT": str(sessions.resolve()),
                "is_codex": lambda pid: None if world["codex_unknown"][0] <= clock[0] < world["codex_unknown"][1] else pid == 42,
                "process_start_token": start,
                "linux_open_files_strict": listed,
                "mac_open_files_strict": listed,
                "client_epoch": lambda pid: None if clock[0] < world["epoch_known_at"] else world["epoch"],
                "invoke_observed_hook": invoke,
                "watch_root": lambda pid_text: observers.append(pid_text),
                "detach": lambda lock: detached.append(lock) or world["child"],
            })

            def run(pending: Optional[tuple[str, ...]] = event, **overrides: Any) -> None:
                world.clear()
                world.update(readable=lambda number, now: now >= 30, moved=False, closed=False, gone_at=float("inf"), restart_at=float("inf"),
                             epoch="", epoch_known_at=0.0, codex_unknown=(0.0, 0.0), lands=True, child=True)
                world.update(overrides)
                clock[0] = 0.0
                for log in (reads, replays, replayed_at, observers, detached):
                    log.clear()
                with mock.patch.object(clocks, "sleep", side_effect=sleep), \
                        mock.patch.object(clocks, "monotonic", side_effect=lambda: clock[0]), \
                        mock.patch.object(os, "kill", side_effect=kill):
                    self.assertIsNone(resolve_root("42", session_id, pending))

            replayed = (42, "start-1", session_id, str(root), "", None, event[:3], event[3])
            # Unread through the settling of the hook, the root reads in the
            # child it leaves the event to: the event is published once, at
            # the time the hook ran, against the claim the process holds.
            run()
            self.assertEqual((replays, observers, detached), ([replayed], [], [None]))
            self.assertGreaterEqual(clock[0], 30)
            # As when the root read but its descriptor did not.
            run(readable=lambda number, now: number == 1 or now >= 30)
            self.assertEqual((replays, observers), ([replayed], []))
            # A claim that cannot be told yet is waited for; an older one is
            # replaced, against its own time.
            run(epoch_known_at=40.0)
            self.assertEqual(replays, [replayed])
            self.assertGreaterEqual(clock[0], 40)
            # So is a process not surely the Codex the hook ran under.
            run(codex_unknown=(25.0, 40.0))
            self.assertEqual(replays, [replayed])
            self.assertGreaterEqual(clock[0], 40)
            older = str(int(event[3]) - 1)
            run(epoch=older)
            self.assertEqual(replays, [replayed[:4] + (older,) + replayed[5:]])
            # The hook, which still answers at once, starts the root observer.
            run(child=False)
            self.assertEqual((replays, observers, detached), ([], ["42"], [None]))
            # Only an event a binder could publish is left to a child.
            for pending in (None, ("SubagentStart", "working", "subagent-start", event[3]), event[:3] + ("0" + event[3],)):
                run(pending)
                self.assertEqual((replays, observers, detached), ([], ["42"], []), pending)
            # No replay once a claim is as new as the event, the process is
            # gone or another, it holds the root of another thread or closed
            # it, or the window ends.
            for overrides in ({"epoch": event[3]}, {"epoch": str(int(event[3]) + 1)}, {"gone_at": 10.0},
                              {"restart_at": 10.0}, {"moved": True}, {"closed": True}):
                run(**overrides)
                self.assertEqual((replays, observers), ([], []), overrides)
                self.assertLess(clock[0], 40, overrides)
            # A closed root ends the wait at once.
            self.assertEqual(clock[0], world["served_at"])
            run(readable=lambda number, now: False)
            self.assertEqual(replays, [])
            self.assertGreaterEqual(clock[0], self.recovery["NATIVE_LATER"])
            self.assertLess(clock[0], self.recovery["SETTLE"] + self.recovery["NATIVE_LATER"] + 2)
            # A replay the hook turned away, as when it could not read the
            # files in turn, is tried again, less often each time, until the
            # window ends.
            run(lands=False)
            self.assertEqual(replays, [replayed] * len(replayed_at))
            gaps = [later - earlier for earlier, later in zip(replayed_at, replayed_at[1:])]
            self.assertEqual([round(gap, 6) for gap in gaps], [2.0 ** index for index in range(len(gaps))])
            self.assertGreaterEqual(len(gaps), 4)
            self.assertLess(replayed_at[-1], self.recovery["SETTLE"] + self.recovery["NATIVE_LATER"] + 0.5)

        # The hook passes its event; any other count of arguments resolves nothing.
        resolved: list[tuple[object, ...]] = []
        self.recovery["resolve_root"] = lambda pid, session, pending=None: resolved.append((pid, session, pending)) or "cmVm"
        for argv, expected in (
            (["recovery", "--resolve-root", "42", "root"], "cmVm\n"),
            (["recovery", "--resolve-root", "42", "root", "Stop", "idle", "turn-stopped", "100"], "cmVm\n"),
            (["recovery", "--resolve-root", "42", "root", "Stop", "idle"], ""),
        ):
            output = io.StringIO()
            with contextlib.redirect_stdout(output), mock.patch.object(sys, "argv", argv):
                self.recovery["main"]()
            self.assertEqual(output.getvalue(), expected, argv)
        self.assertEqual(resolved, [("42", "root", None), ("42", "root", ("Stop", "idle", "turn-stopped", "100"))])

    def test_resolve_root_rejects_internal_mismatched_ambiguous_and_closed_candidates(self) -> None:
        resolve_root = self.recovery["resolve_root"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-resolve-reject-") as temporary:
            sessions = Path(temporary)
            root_id = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
            helper_id = "019c6e28-e55b-73d1-bc92-3e3c1bcc0022"
            root = self.write_jsonl(sessions, f"rollout-{root_id}.jsonl", [metadata(root_id)])
            helper = self.write_jsonl(
                sessions,
                f"rollout-{helper_id}.jsonl",
                [metadata(helper_id, source="guardian_review")],
            )
            second = self.write_jsonl(sessions, f"rollout-second-{helper_id}.jsonl", [metadata(helper_id)])
            self.recovery["SESSIONS_ROOT"] = str(sessions.resolve())
            self.recovery["is_codex"] = lambda pid: pid == 42
            actual_root_candidate = self.recovery["root_candidate"]
            self.recovery["still_open"] = lambda _pid, _path, _identity: True
            self.recovery["mac_open_files"] = lambda _pid, _root: [
                (str(root), self.identity(root)),
                (str(helper), self.identity(helper)),
            ]
            self.recovery["root_candidate"] = lambda _pid, directory: actual_root_candidate(9_999_999, directory)
            self.assertIsNone(resolve_root("42", helper_id), "a helper or different session ID can never satisfy the root request")

            self.recovery["mac_open_files"] = lambda _pid, _root: [
                (str(root), self.identity(root)),
                (str(second), self.identity(second)),
            ]
            self.recovery["root_candidate"] = actual_root_candidate
            self.assertIs(
                self.recovery["root_candidate"](9_999_999, str(sessions)), False,
                "two provider root descriptors are deliberately ambiguous",
            )

            self.recovery["root_candidate"] = lambda pid, directory: (str(root), self.identity(root), root_id)
            self.recovery["still_open"] = lambda _pid, _path, _identity: False
            self.assertIsNone(resolve_root("42", root_id), "closed descriptors cannot establish a durable root")

    def test_resolve_root_rejects_malformed_arguments_and_needs_no_tmux(self) -> None:
        resolve_root = self.recovery["resolve_root"]
        main = self.recovery["main"]
        session_id = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
        self.recovery["is_codex"] = lambda _pid: self.fail("malformed PID must be rejected before process inspection")
        for pid in ("", "0", "1", "-2", "+2", "2.0", "0002", "99999999999"):
            self.assertIsNone(resolve_root(pid, session_id))
        self.assertIsNone(resolve_root("2", "invalid/session"))

        original_argv = sys.argv
        try:
            self.recovery["run"] = lambda *_args: self.fail("resolve mode must not invoke tmux")
            sys.argv = ["recovery", "--resolve-root", "bad", session_id]
            malformed_output = io.StringIO()
            with contextlib.redirect_stdout(malformed_output):
                main()
            self.assertEqual(malformed_output.getvalue(), "")

            path = "/safe/.codex/sessions/rollout.jsonl"
            identity = (1, 2)
            self.recovery.update({
                "is_codex": lambda pid: pid == 42,
                "root_candidate": lambda pid, directory: (path, identity, session_id),
                "still_open": lambda pid, candidate, file_identity: candidate == path and file_identity == identity,
            })
            sys.argv = ["recovery", "--resolve-root", "42", session_id]
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                main()
            expected = self.recovery["base64"].urlsafe_b64encode(path.encode("utf-8")).decode("ascii").rstrip("=")
            self.assertEqual(output.getvalue(), expected + "\n")
        finally:
            sys.argv = original_argv

    def test_watch_once_fails_closed_for_failed_ambiguous_and_partial_inventory(self) -> None:
        watch_once = self.recovery["watch_once"]
        calls: list[tuple[int, str, str, Optional[str], str]] = []
        self.recovery.update({
            "invoke_observed_hook": lambda pid, start, session_id, path, stamp: calls.append((pid, start, session_id, path, stamp)),
            "watcher_live": lambda _pid, _token: True,
            "read_observer_claim": lambda _pid: ("claimed", "100"),
        })
        for inventory in (None, False, [("/safe/one.jsonl", (1, 1), "one"), ("/safe/two.jsonl", (1, 2), "two")]):
            self.recovery["strict_root_inventory"] = lambda _pid, _root, value=inventory: value
            self.assertIsNone(watch_once(42, "start", ("claimed", "100")))
        self.assertEqual(calls, [])

    def test_watch_once_emits_empty_transition_for_an_exact_closed_root(self) -> None:
        watch_once = self.recovery["watch_once"]
        calls: list[tuple[int, str, str, Optional[str], str]] = []
        self.recovery.update({
            "strict_root_inventory": lambda _pid, _root: [],
            "read_observer_claim": lambda _pid: ("stale", "101"),
            "watcher_live": lambda _pid, _token: True,
            "invoke_observed_hook": lambda pid, start, session_id, path, stamp: calls.append((pid, start, session_id, path, stamp)),
        })
        self.assertEqual(watch_once(42, "start", ("stale", "101")), "")
        self.assertEqual(calls, [(42, "start", "", None, "101")])

    def test_watch_once_leaves_native_same_session_and_newer_claim_to_the_hook(self) -> None:
        watch_once = self.recovery["watch_once"]
        calls: list[tuple[int, str, str, Optional[str], str]] = []
        inventory = [("/safe/root.jsonl", (1, 1), "root")]
        self.recovery.update({
            "strict_root_inventory": lambda _pid, _root: inventory,
            "watcher_live": lambda _pid, _token: True,
            "invoke_observed_hook": lambda pid, start, session_id, path, stamp: calls.append((pid, start, session_id, path, stamp)),
        })
        self.recovery["read_observer_claim"] = lambda _pid: ("root", "102")
        self.assertIsNone(watch_once(42, "start", ("root", "102")))
        self.assertEqual(calls, [])

        self.recovery["read_observer_claim"] = lambda _pid: ("native-b", "103")
        self.assertEqual(watch_once(42, "start", ("native-b", "103")), "root")
        self.assertEqual(calls, [(42, "start", "root", "/safe/root.jsonl", "103")])
        calls.clear()

        claims = iter([("claimed", "103")])
        self.recovery["read_observer_claim"] = lambda _pid: next(claims)
        self.assertIsNone(watch_once(42, "start", ("claimed", "102")))
        self.assertEqual(calls, [])

    def test_watcher_live_rejects_a_provider_exit_or_pid_reuse(self) -> None:
        watcher_live = self.recovery["watcher_live"]
        self.recovery.update({
            "is_codex": lambda _pid: False,
            "process_start_token": lambda _pid: "same",
        })
        self.assertFalse(watcher_live(42, "same"))
        self.recovery.update({
            "is_codex": lambda _pid: True,
            "process_start_token": lambda _pid: "reused",
        })
        self.assertFalse(watcher_live(42, "same"))

    def test_verify_observation_requires_live_exact_unambiguous_fd_evidence(self) -> None:
        verify_observation = self.recovery["verify_observation"]
        main = self.recovery["main"]
        root = [("/safe/root.jsonl", (1, 1), "root")]
        self.recovery.update({
            "watcher_live": lambda pid, token: pid == 42 and token == "99",
            "strict_root_inventory": lambda _pid, _root: root,
        })
        self.assertEqual(verify_observation("42", "99", "root"), "42")
        self.assertIsNone(verify_observation("41", "99", "root"))
        self.assertIsNone(verify_observation("42", "98", "root"))
        self.assertIsNone(verify_observation("42", "99", "other"))
        self.recovery["strict_root_inventory"] = lambda _pid, _root: None
        self.assertIsNone(verify_observation("42", "99", "root"))
        self.recovery["strict_root_inventory"] = lambda _pid, _root: root + [("/safe/other.jsonl", (1, 2), "other")]
        self.assertIsNone(verify_observation("42", "99", "root"))
        self.recovery["strict_root_inventory"] = lambda _pid, _root: []
        self.assertEqual(verify_observation("42", "99", ""), "42")

        original_argv = sys.argv
        try:
            self.recovery["strict_root_inventory"] = lambda _pid, _root: root
            sys.argv = ["recovery", "--verify-observation", "42", "99", "root"]
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                main()
            self.assertEqual(output.getvalue(), "42\n")

            sys.argv = ["recovery", "--verify-observation", "42", "wrong", "root"]
            denied = io.StringIO()
            with contextlib.redirect_stdout(denied):
                main()
            self.assertEqual(denied.getvalue(), "")
        finally:
            sys.argv = original_argv

    def test_watch_root_rejects_malformed_arguments_without_starting_a_watcher(self) -> None:
        main = self.recovery["main"]
        original_argv = sys.argv
        try:
            self.recovery["watch_root"] = lambda _pid: self.fail("malformed watcher arguments must not start")
            for arguments in (
                ["recovery", "--watch-root"],
                ["recovery", "--watch-root", "0"],
                ["recovery", "--watch-root", "bad"],
                ["recovery", "--watch-root", "42", "extra"],
            ):
                sys.argv = arguments
                with contextlib.redirect_stdout(io.StringIO()):
                    main()
        finally:
            sys.argv = original_argv

    # The launcher publishes the bootstrap SessionStart under its own PID and
    # execs Codex under that PID only after the hook returns. The observer
    # must bind to that pre-exec identity instead of demanding a Codex image
    # that cannot exist yet, and must then wait for the exec, detached.
    def test_watch_root_binds_a_pre_exec_launcher_and_detaches_before_the_exec(self) -> None:
        events: list[object] = []
        self.recovery["current_uid"] = lambda pid: os.getuid()
        self.recovery["descendant"] = lambda child, ancestor: ancestor == 4242
        self.recovery["is_codex"] = lambda pid: False
        self.recovery["process_start_token"] = lambda pid: "1700000000"
        self.recovery["observer_lock"] = lambda pid: events.append(("lock", pid)) or 99
        self.recovery["await_codex"] = lambda pid, token, timeout: self.fail("the parent must not wait")
        with mock.patch("os.fork", return_value=31337) as fork, mock.patch("os.close") as close:
            self.recovery["watch_root"]("4242")
        self.assertEqual(events, [("lock", 4242)])
        fork.assert_called_once()
        close.assert_called_once_with(99)

        # Not our descendant, another user's process, or one no longer
        # there never gets an observer.
        events.clear()
        with mock.patch("os.fork") as fork, mock.patch.object(os, "kill", side_effect=ProcessLookupError()):
            self.recovery["watch_root"]("4243")
            self.recovery["current_uid"] = lambda pid: os.getuid() + 1
            self.recovery["watch_root"]("4242")
            self.recovery["current_uid"] = lambda pid: os.getuid()
            self.recovery["process_start_token"] = lambda pid: None
            self.recovery["watch_root"]("4242")
        self.assertEqual(events, [])
        fork.assert_not_called()

    def test_await_codex_waits_for_the_exec_under_the_same_process_identity(self) -> None:
        await_codex = self.recovery["await_codex"]
        names = iter(["sh", "sh", "codex"])
        self.recovery["command_name"] = lambda pid: next(names)
        self.recovery["is_codex"] = lambda pid: True
        self.recovery["process_start_token"] = lambda pid: "1700000000"
        with mock.patch("time.sleep") as sleep:
            self.assertTrue(await_codex(4242, "1700000000", 5))
        # Polling backs off: the exec normally lands within milliseconds.
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [0.05, 0.1])
        # The PID was reused by another process, or the launcher exited.
        self.recovery["command_name"] = lambda pid: "codex"
        self.recovery["process_start_token"] = lambda pid: "1700000001"
        self.assertFalse(await_codex(4242, "1700000000", 5))
        self.recovery["process_start_token"] = lambda pid: None
        with mock.patch.object(os, "kill", side_effect=ProcessLookupError()):
            self.assertFalse(await_codex(4242, "1700000000", 5))
        # A codex command name of another user is not Codex.
        self.recovery["is_codex"] = lambda pid: False
        self.recovery["process_start_token"] = lambda pid: "1700000000"
        with mock.patch("time.sleep"), mock.patch("time.monotonic", side_effect=[100.0, 100.0, 105.1]):
            self.assertFalse(await_codex(4242, "1700000000", 5))
        # A launcher that never becomes Codex times out without publishing.
        self.recovery["command_name"] = lambda pid: "sh"
        with mock.patch("time.sleep"), mock.patch("time.monotonic", side_effect=[100.0, 100.0, 104.9, 105.1]):
            self.assertFalse(await_codex(4242, "1700000000", 5))
        # An unrelated node process must not keep an observer waiting.
        self.recovery["command_name"] = lambda pid: "node"
        self.recovery["is_codex_launcher"] = lambda pid: False
        with mock.patch("time.sleep") as sleep:
            self.assertFalse(await_codex(4242, "1700000000", 5))
        sleep.assert_not_called()

    def test_node_launcher_requires_codex_arguments_and_the_same_uid(self) -> None:
        self.recovery["current_uid"] = lambda _pid: os.getuid()
        self.recovery["command_name"] = lambda _pid: "node"
        for arguments, accepted in (
            (b"/usr/bin/node /opt/lib/node_modules/@openai/codex/bin/codex.js resume --last\n", True),
            (b"/usr/bin/node /opt/codex.js fork\n", True),
            (b"/usr/bin/node /opt/other.js\n", False),
        ):
            self.recovery["run"] = lambda _argv, _limit: arguments
            with mock.patch("builtins.open", side_effect=FileNotFoundError()):
                self.assertEqual(self.recovery["is_codex_launcher"](4242), accepted)
        # A global npm install runs the launcher through a bin symlink.
        prefix = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(prefix)], check=False))
        package = prefix / "lib/node_modules/@openai/codex/bin"
        package.mkdir(parents=True)
        (package / "codex.js").write_text("")
        (prefix / "bin").mkdir()
        os.symlink("../lib/node_modules/@openai/codex/bin/codex.js", prefix / "bin/codex")
        os.symlink("../lib/node_modules/@openai/codex/bin/codex.js", prefix / "bin/other")
        (prefix / "bin/plain").write_text("")
        for arguments, accepted in (
            (f"/usr/bin/node {prefix}/bin/codex --enable hooks resume 019c\n".encode(), True),
            (f"/usr/bin/node --no-warnings {prefix}/bin/other\n".encode(), True),
            (f"/usr/bin/node {prefix}/bin/plain\n".encode(), False),
            (b"/usr/bin/node bin/codex\n", False),
        ):
            self.recovery["run"] = lambda _argv, _limit: arguments
            with mock.patch("builtins.open", side_effect=FileNotFoundError()):
                self.assertEqual(self.recovery["is_codex_launcher"](4242), accepted, arguments)
        self.recovery["current_uid"] = lambda _pid: os.getuid() + 1
        self.assertFalse(self.recovery["is_codex_launcher"](4242))

    def test_node_launcher_resolves_one_native_child_with_its_start_identity(self) -> None:
        parents = {4243: 4242, 4244: 4243}
        names = {4242: "node", 4243: "codex", 4244: "worker"}
        tokens = {4242: "100", 4243: "200"}
        self.recovery.update({
            "run": lambda _argv: "".join(f"{pid} {parent}\n" for pid, parent in parents.items()).encode(),
            "current_uid": lambda _pid: os.getuid(),
            "command_name": lambda pid: names.get(pid, "sh"),
            "parent_pid": lambda pid: parents.get(pid),
            "process_start_token": lambda pid: tokens.get(pid),
            "is_codex_launcher": lambda pid: pid == 4242,
            "codex_server": lambda pid: False,
        })
        resolve = self.recovery["native_codex_child"]
        self.assertEqual(resolve(4242, "100"), (4243, "200"))
        parents[9000] = 9001
        inspected: list[int] = []
        self.recovery["current_uid"] = lambda pid: inspected.append(pid) or os.getuid()
        self.assertEqual(resolve(4242, "100"), (4243, "200"))
        self.assertNotIn(9001, inspected)
        self.recovery["current_uid"] = lambda _pid: os.getuid()
        self.assertIsNone(resolve(4242, "reused"))
        tokens[4243] = None
        self.assertIsNone(resolve(4242, "100"))
        tokens[4243] = "200"
        self.recovery["current_uid"] = lambda pid: os.getuid() + (1 if pid == 4243 else 0)
        self.assertIsNone(resolve(4242, "100"))
        self.recovery["current_uid"] = lambda _pid: os.getuid()
        names[4244] = "codex"
        tokens[4244] = "201"
        self.assertIsNone(resolve(4242, "100"))
        names[4244] = "worker"
        self.recovery["parent_pid"] = lambda _pid: 9999
        self.assertIsNone(resolve(4242, "100"))
        self.recovery["parent_pid"] = lambda pid: parents.get(pid)
        parents.update({4243: 4245, 4245: 4246, 4246: 4247, 4247: 4242})
        self.assertIsNone(resolve(4242, "100"))

    def test_node_launcher_child_is_not_the_shared_server_it_started(self) -> None:
        # node -> TUI -> app-server -> a tool the server runs, all named codex.
        parents = {4243: 4242, 4248: 4243, 4249: 4248}
        servers: dict[int, Optional[bool]] = {4243: False, 4248: True, 4249: False}
        self.recovery.update({
            "run": lambda _argv: "".join(f"{pid} {parent}\n" for pid, parent in parents.items()).encode(),
            "current_uid": lambda _pid: os.getuid(),
            "command_name": lambda pid: "node" if pid == 4242 else "codex",
            "parent_pid": lambda pid: parents.get(pid),
            "process_start_token": lambda pid: {4242: "100"}.get(pid, f"start-{pid}"),
            "is_codex_launcher": lambda pid: pid == 4242,
            "codex_server": lambda pid: servers.get(pid, False),
        })
        resolve = self.recovery["native_codex_child"]
        self.assertEqual(resolve(4242, "100"), (4243, "start-4243"))
        # A Codex whose arguments cannot be read stays a candidate: alone it
        # is the TUI, beside another it decides nothing.
        servers[4248] = None
        self.assertIsNone(resolve(4242, "100"))
        del parents[4248], parents[4249]
        servers[4243] = None
        self.assertEqual(resolve(4242, "100"), (4243, "start-4243"))
        parents.update({4248: 4243, 4249: 4248})
        servers.update({4243: False, 4248: True})
        self.assertEqual(resolve(4242, "100"), (4243, "start-4243"))
        # A Codex the TUI runs that is no server is another candidate.
        servers[4248] = False
        self.assertIsNone(resolve(4242, "100"))

    def test_a_launcher_wait_gives_up_only_on_a_definite_answer(self) -> None:
        # One ps that failed to fork or answered late, which on macOS reads
        # the start, the owner, the command and the arguments, decides no
        # poll: the wait goes on, within its timeout.
        await_codex, clocks = self.recovery["await_codex"], self.recovery["time"]
        resolve = self.recovery["native_codex_child"]
        polls = [0]

        def poll(_seconds: float) -> None:
            polls[0] += 1
        # A launcher shell that execs Codex.
        self.recovery.update({
            "process_start_token": lambda pid: None if polls[0] == 0 else "100",
            "command_name": lambda pid: None if polls[0] == 1 else ("sh" if polls[0] < 3 else "codex"),
            "current_uid": lambda pid: os.getuid(),
        })
        with mock.patch.object(clocks, "sleep", side_effect=poll), mock.patch.object(os, "kill") as kill:
            self.assertEqual(await_codex(4242, "100", 60), (4242, "100"))
        self.assertEqual(polls[0], 3)
        kill.assert_called_once_with(4242, 0)
        # A node launcher: its owner, then its arguments, cannot be read
        # once; then its native child answers.
        polls[0] = 0
        children: list[int] = []
        launcher = b"/usr/bin/node /opt/lib/node_modules/@openai/codex/bin/codex.js\n"
        self.recovery.update({
            "process_start_token": lambda pid: "100",
            "command_name": lambda pid: "node",
            "current_uid": lambda pid: None if polls[0] == 0 else os.getuid(),
            "run": lambda argv, limit=0, env=None: None if polls[0] == 1 else launcher,
            "native_codex_child": lambda pid, start: children.append(polls[0]) or ((4243, "200") if polls[0] >= 3 else None),
        })
        with mock.patch.object(clocks, "sleep", side_effect=poll), mock.patch("builtins.open", side_effect=FileNotFoundError()):
            self.assertEqual(await_codex(4242, "100", 60), (4243, "200"))
        self.assertEqual(children, [2, 3])
        # Only a definite answer gives up at once: a node process that surely
        # runs no launcher, another start under the PID, or no process left.
        for label, start, arguments, gone in (("another program", "100", b"/usr/bin/node /opt/other.js\n", False),
                                              ("started again", "101", launcher, False), ("exited", None, launcher, True)):
            polls[0] = 0
            self.recovery.update({
                "process_start_token": lambda pid, start=start: start,
                "current_uid": lambda pid: os.getuid(),
                "run": lambda argv, limit=0, env=None, arguments=arguments: arguments,
                "native_codex_child": lambda pid, start: self.fail("a launcher that surely ended was polled"),
            })
            with mock.patch.object(clocks, "sleep", side_effect=poll), mock.patch("builtins.open", side_effect=FileNotFoundError()), \
                    mock.patch.object(os, "kill", side_effect=ProcessLookupError() if gone else None):
                self.assertIsNone(await_codex(4242, "100", 60), label)
            self.assertEqual(polls[0], 0, label)

        # A native child a ps could not tell leaves the choice to the next
        # poll, not to the children it could tell.
        parents = {4243: 4242, 4250: 4242}
        undecided = {4250}
        self.recovery.update({
            "run": lambda argv, limit=0, env=None: "".join(f"{pid} {parent}\n" for pid, parent in parents.items()).encode(),
            "current_uid": lambda pid: None if pid in undecided else os.getuid(),
            "command_name": lambda pid: "node" if pid == 4242 else "codex",
            "parent_pid": lambda pid: parents.get(pid),
            "process_start_token": lambda pid: {4242: "100"}.get(pid, f"start-{pid}"),
            "is_codex_launcher": lambda pid: pid == 4242,
            "codex_server": lambda pid: False,
        })
        self.assertIsNone(resolve(4242, "100"))
        # Told, two native children decide nothing either; one alone is it.
        undecided.clear()
        self.assertIsNone(resolve(4242, "100"))
        del parents[4250]
        self.assertEqual(resolve(4242, "100"), (4243, "start-4243"))

    def test_an_observer_starts_past_a_read_a_ps_could_not_make(self) -> None:
        clocks = self.recovery["time"]
        # A parent that could not be read decides no descent.
        descendant = self.recovery["descendant"]
        chain = {500: 400, 400: 300, 300: 1}
        self.recovery["parent_pid"] = lambda pid: chain.get(pid)
        self.assertTrue(descendant(500, 300))
        self.assertFalse(descendant(500, 200))
        del chain[400]
        self.assertIsNone(descendant(500, 300))

        # The hook of a launcher asks again, briefly, what one ps could not
        # tell: its owner, then whether the hook runs under it, then its
        # start. Then the observer starts.
        tries = [0]
        events: list[object] = []

        def again(_seconds: float) -> None:
            tries[0] += 1
        self.recovery.update({
            "current_uid": lambda pid: None if tries[0] == 0 else os.getuid(),
            "descendant": lambda child, ancestor: None if tries[0] == 1 else (child, ancestor) == (os.getpid(), 4242),
            "process_start_token": lambda pid: None if tries[0] == 2 else "1700000000",
            "observer_lock": lambda pid: events.append(("lock", pid)) or 99,
            "await_codex": lambda pid, token, timeout: self.fail("the parent must not wait"),
        })
        with mock.patch.object(clocks, "sleep", side_effect=again), mock.patch.object(os, "kill") as kill, \
                mock.patch("os.fork", return_value=31337) as fork, mock.patch("os.close"):
            self.recovery["watch_root"]("4242")
        self.assertEqual((tries[0], events), (3, [("lock", 4242)]))
        fork.assert_called_once()
        self.assertEqual(kill.call_args_list, [mock.call(4242, 0)] * 3)

        # So does the hook of a bound client, for its title observer.
        tries[0] = 0
        events.clear()
        lock = os.open(os.devnull, os.O_RDONLY)
        self.recovery.update({
            "current_uid": lambda pid: None if tries[0] == 0 else os.getuid(),
            "command_name": lambda pid: "codex",
            "process_start_token": lambda pid: None if tries[0] == 1 else "99",
            "shared_client": lambda pid, token: (105, "%2") if (pid, token) == (42, "99") else None,
            "observer_lock": lambda pid, kind="observer": events.append(("lock", pid, kind)) or lock,
            "detach": lambda descriptor: events.append(("detach", descriptor)) or True,
            "watch_shared": lambda pid, token, bootstrap=False: events.append(("watch", pid, token)),
        })
        with mock.patch.object(clocks, "sleep", side_effect=again), mock.patch.object(os, "kill"):
            self.recovery["watch_shared_root"]("42")
        self.assertEqual((tries[0], events), (2, [("lock", 42, "shared-observer"), ("detach", lock), ("watch", 42, "99")]))
        # A client no longer there starts none, at once.
        tries[0] = 0
        events.clear()
        self.recovery["current_uid"] = lambda pid: None
        with mock.patch.object(clocks, "sleep", side_effect=again), mock.patch.object(os, "kill", side_effect=ProcessLookupError()):
            self.recovery["watch_shared_root"]("42")
            self.recovery["watch_root"]("4242")
        self.assertEqual((tries[0], events), (0, []))

    def test_await_codex_waits_for_the_native_node_child_within_the_timeout(self) -> None:
        targets = iter([None, (4243, "200")])
        self.recovery.update({
            "command_name": lambda _pid: "node",
            "process_start_token": lambda _pid: "100",
            "is_codex_launcher": lambda _pid: True,
            "native_codex_child": lambda _pid, _start: next(targets),
        })
        with mock.patch("time.sleep") as sleep:
            self.assertEqual(self.recovery["await_codex"](4242, "100", 5), (4243, "200"))
        sleep.assert_called_once_with(0.05)
        self.recovery["native_codex_child"] = lambda _pid, _start: None
        with mock.patch("time.sleep"), mock.patch("time.monotonic", side_effect=[100.0, 100.0, 105.1]):
            self.assertIsNone(self.recovery["await_codex"](4242, "100", 5))
        self.recovery["process_start_token"] = lambda _pid: "reused"
        self.assertIsNone(self.recovery["await_codex"](4242, "100", 5))

    def test_node_observer_hands_its_lock_to_the_native_hook_pid(self) -> None:
        locks: list[int] = []
        watched: list[object] = []
        self.recovery.update({
            "observer_target": lambda _pid: "100",
            "observer_lock": lambda pid: locks.append(pid) or pid,
            "await_codex": lambda _pid, _start, _timeout: (4243, "200"),
            "watch_loop": lambda pid, start, bootstrap: watched.append((pid, start, bootstrap)),
        })
        with mock.patch("os.fork", return_value=0), mock.patch("os.open", return_value=7), \
             mock.patch("os.dup2"), mock.patch("os.close") as close:
            self.recovery["watch_root"]("4242")
        self.assertEqual(locks, [4242, 4243])
        self.assertEqual(watched, [(4243, "200", True)])
        self.assertIn(mock.call(4242), close.call_args_list)
        self.assertIn(mock.call(4243), close.call_args_list)

    def test_idle_node_child_publishes_session_start_without_a_prompt_and_exits_with_the_child(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-node-recovery-") as temporary:
            sessions = Path(temporary)
            source = self.write_jsonl(sessions, "rollout-idle-resume.jsonl", [metadata("idle-resume")])
            self.recovery["SESSIONS_ROOT"] = str(sessions)
            alive = [True]
            published: list[object] = []
            inventory = lambda pid, _root: [(str(source), self.identity(source))] if pid == 4243 else []
            self.recovery.update({
                "is_codex": lambda pid: pid == 4243 and alive[0],
                "watcher_ended": lambda pid, token: not (pid == 4243 and token == "200" and alive[0]),
                "process_start_token": lambda pid: "200" if pid == 4243 else "100",
                "linux_open_files_strict": inventory,
                "mac_open_files_strict": inventory,
                "read_observer_claim": lambda _pid: None,
            })
            def publish(pid: int, start: str, session_id: str, path: str, stamp: str) -> None:
                self.assertEqual(self.recovery["verify_observation"](str(pid), start, session_id), "4243")
                published.append((pid, start, session_id, path, stamp))
                alive[0] = False
            self.recovery["invoke_observed_hook"] = publish
            with source.open("rb"), mock.patch("time.sleep", side_effect=lambda _seconds: self.assertFalse(alive[0], "observer never published the open root")):
                self.recovery["watch_loop"](4243, "200", bootstrap=True)
            self.assertEqual(published, [(4243, "200", "idle-resume", str(source), "")])
            self.assertFalse(self.recovery["watcher_live"](4243, "200"))

    def test_node_bootstrap_cannot_replace_a_racing_native_claim(self) -> None:
        published: list[object] = []
        self.recovery.update({
            "strict_root_inventory": lambda _pid, _root: [("/safe/root.jsonl", (1, 2), "idle-resume")],
            "read_observer_claim": lambda _pid: ("native-newer", "100"),
            "watcher_live": lambda _pid, _start: True,
            "invoke_observed_hook": lambda *arguments: published.append(arguments),
        })
        self.assertIsNone(self.recovery["watch_once"](4243, "200", ("", "")))
        self.assertEqual(published, [])

    def test_latest_authority_uses_the_latest_valid_causal_event(self) -> None:
        latest_authority = self.recovery["latest_authority"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-authority-") as temporary:
            sessions = Path(temporary)
            self.recovery["SESSIONS_ROOT"] = str(sessions.resolve())
            timestamp = "2026-09-07T10:11:12.123456Z"
            completed = {
                "type": "event_msg",
                "timestamp": timestamp,
                "payload": {"type": "task_complete", "turn_id": "turn-complete"},
            }
            irrelevant = {"type": "event_msg", "timestamp": "2026-09-07T10:11:13Z", "payload": {"type": "token_count"}}
            source = self.write_jsonl(sessions, "rollout-fixture.jsonl", [completed, irrelevant])
            expected = 1_788_775_872_123_456_000
            self.assertEqual(latest_authority(str(source), self.identity(source)), ("Stop", "idle", "turn-stopped", expected, "turn-complete"))

            started = {
                "type": "event_msg",
                "timestamp": "2026-09-07T10:11:14Z",
                "payload": {"type": "task_started", "turn_id": "turn-started"},
            }
            source.write_text("".join(json.dumps(record) + "\n" for record in [completed, irrelevant, started]), encoding="utf-8")
            source.chmod(0o600)
            self.assertEqual(latest_authority(str(source), self.identity(source)), ("UserPromptSubmit", "working", "agent-turn", 1_788_775_874_000_000_000, "turn-started"))

            malformed = {"type": "event_msg", "timestamp": "not-a-time", "payload": {"type": "task_complete", "turn_id": "bad"}}
            incomplete = {"type": "event_msg", "payload": {"type": "task_complete"}}
            source.write_text("".join(json.dumps(record) + "\n" for record in [completed, malformed, incomplete]), encoding="utf-8")
            source.chmod(0o600)
            self.assertEqual(latest_authority(str(source), self.identity(source)), ("Stop", "idle", "turn-stopped", expected, "turn-complete"))

    def test_main_rechecks_metadata_before_mutation(self) -> None:
        old = json.dumps({"version": 9, "provider": "codex", "transcriptRef": "Tm9uZQ", "agentPid": 42}, separators=(",", ":"))
        calls: list[list[str]] = []

        def run(argv: list[str], limit: int) -> Optional[bytes]:
            calls.append(argv)
            if argv[1] == "list-panes":
                return f"%16\t100\t{old}\n".encode()
            if argv[1] == "show-option":
                return b'{"version":9,"provider":"codex","transcriptRef":"new"}\n'
            if argv[1] == "set-option":
                self.fail("changed pane metadata must not be set")
            return None

        self.recovery.update({
            "run": run,
            "is_codex": lambda _pid: True,
            "descendant": lambda _child, _parent: True,
            "root_candidate": lambda _pid, _root: ("/safe/sessions/rollout-root.jsonl", (1, 2), "root"),
            "latest_authority": lambda _path, _identity: ("Stop", "idle", "turn-stopped", 10, "turn"),
            "still_open": lambda _pid, _path, _identity: True,
            "current_uid": lambda _pid: os.getuid(),
        })
        output = io.StringIO()
        with contextlib.redirect_stdout(output), mock.patch.object(sys, "argv", [str(RECOVERY)]):
            self.recovery["main"]()
        self.assertEqual(output.getvalue(), "TESSERA_AGENT_CODEX_RECOVERY repaired=0\n")
        self.assertFalse(any(call[1] == "set-option" for call in calls))

    def test_main_repairs_a_pane_grouped_sessions_list_again_once(self) -> None:
        # A view session shares its owner's windows, so `list-panes -a` lists
        # each pane once per session. The cap counts panes, not lines.
        old = json.dumps({"version": 9, "provider": "codex", "transcriptRef": "Tm9uZQ", "agentPid": 42}, separators=(",", ":"))
        repaired: list[str] = []

        def run(argv: list[str], limit: int) -> Optional[bytes]:
            if argv[1] == "list-panes":
                return "".join(f"{pane}\t100\t{old}\n" for pane in ("%16", "%16", "%17", "%16", "%17", "%18")).encode()
            if argv[1] == "show-option":
                return f"{old}\n".encode()
            if argv[1] == "set-option":
                repaired.append(argv[4])
                return b""
            return None

        self.recovery.update({
            "MAX_PANES": 2,
            "run": run,
            "is_codex": lambda _pid: True,
            "descendant": lambda _child, _parent: True,
            "root_candidate": lambda _pid, _root: ("/safe/sessions/rollout-root.jsonl", (1, 2), "root"),
            "latest_authority": lambda _path, _identity: ("Stop", "idle", "turn-stopped", 10, "turn"),
            "still_open": lambda _pid, _path, _identity: True,
            "current_uid": lambda _pid: os.getuid(),
        })
        output = io.StringIO()
        with contextlib.redirect_stdout(output), mock.patch.object(sys, "argv", [str(RECOVERY)]):
            self.recovery["main"]()
        self.assertEqual(output.getvalue(), "TESSERA_AGENT_CODEX_RECOVERY repaired=2\n")
        self.assertEqual(repaired, ["%16", "%17"])

    def test_title_text_follows_codex_title_sanitizing(self) -> None:
        title_text = self.recovery["title_text"]
        self.assertEqual(title_text("  Fix\tthe \n parser  ", False), "Fix the parser")
        self.assertEqual(title_text("Fix​ the‮ parser\x07", False), "Fix the parser")
        self.assertEqual(title_text("a" * 300, False), "a" * 240)
        self.assertEqual(title_text("⠋ Résumé ●", True), "| R?sum? *")
        self.assertEqual(title_text("Fix\x1cparser", False), "Fixparser")

    def test_title_shows_only_whole_items_beside_activity_glyphs(self) -> None:
        title_shows = self.recovery["title_shows"]
        name = "Fix the parser"
        for title in (
            "Fix the parser",
            "⠋ Fix the parser | demo",
            "● ⠹ Fix the parser | demo",
            "demo | Fix the parser ⠋",
            "[ ! ] Action Required | Fix the parser | demo",
            "| Fix the parser | demo",
            "Fix the parser | Fix the parser v2",
            # Codex joins the activity item to both neighbours with a space.
            "demo ⠋ Fix the parser",
            "Fix the parser ⠋ demo",
            "demo ● Fix the parser",
        ):
            self.assertTrue(title_shows(title, name), title)
        for title in (
            "Fix the parser v2 | demo",
            "⠋ Fix the parser again",
            "Please Fix the parser | demo",
            "x Fix the parser",
            "demo",
            "",
            # As GNU screen shows a spinner, the glyph can be part of a name.
            "demo - Fix the parser",
            "Fix the parser / demo",
        ):
            self.assertFalse(title_shows(title, name), title)
        self.assertFalse(title_shows("anything", ""))
        # A title at the length cap may have cut its last item short.
        filler = "x" * (240 - len(" | Fix the parser"))
        self.assertFalse(title_shows(filler + " | Fix the parser", name))
        self.assertTrue(title_shows(filler[:-2] + " | Fix the parser", name))
        self.assertTrue(title_shows("Fix the parser | " + filler, name))

    def test_title_cuts_count_every_cut_a_cluster_can_make(self) -> None:
        title_cuts, single_cluster = self.recovery["title_cuts"], self.recovery["single_cluster"]
        self.assertEqual(title_cuts("short", 48), {"short"})
        self.assertEqual(title_cuts("x" * 48, 48), {"x" * 48})
        self.assertEqual(title_cuts("x" * 49, 48), {"x" * 45 + "..."})
        # Characters that each make a cluster cut at the limit.
        self.assertEqual(title_cuts("\u00e9" * 49, 48), {"\u00e9" * 45 + "..."})
        self.assertEqual(title_cuts("\uac00" * 49, 48), {"\uac00" * 45 + "..."})
        self.assertEqual(title_cuts("\U0001F680" * 49, 48), {"\U0001F680" * 45 + "..."})
        # Otherwise every cut Codex could make, and the whole value, count.
        for value in ("e\u0301" * 30, "\u1100\u1161" * 30, "\U0001F1EB\U0001F1F7" * 30, "\u0915\u094d\u0937" * 20,
                      "a\u200db" * 20, "\u0600x" * 30, "\u0e01\u0e33" * 30, "\U0001F44D\U0001F3FD" * 30, "\u1000\u102c" * 25):
            self.assertEqual(title_cuts(value, 48), {value} | {value[:end] + "..." for end in range(45, len(value))}, ascii(value[:6]))
        self.assertIsNone(title_cuts("e\u0301" * 129, 48))
        self.assertEqual(title_cuts("e" * 300, 48), {"e" * 45 + "..."})
        for character in "a\u00e9\uac00\u4e00\U0001F680 ":
            self.assertTrue(single_cluster(character), ascii(character))
        for character in "\u0301\u200d\u200c\u00ad\u1100\u1161\u11a8\U0001F1EB\U0001F3FD\u0e33\uff9e\u0d4e\u102c\r\u2028\U000E0001\U0010FFFF":
            self.assertFalse(single_cluster(character), ascii(character))

    def test_title_key_ignores_the_spinner_and_the_blinking_prefix(self) -> None:
        title_key = self.recovery["title_key"]
        self.assertEqual(title_key("⠋ Fix the parser | demo\n".encode("utf-8")), title_key("⠙ Fix the parser | demo".encode("utf-8")))
        self.assertEqual(title_key(b"[ . ] Action Required | Fix"), title_key(b"[ ! ] Action Required | Fix"))
        self.assertNotEqual(title_key(b"Fix the parser | demo"), title_key(b"Profile the cache | demo"))
        # GNU screen shows the frames as ASCII.
        frames = {title_key(frame + b" Fix the parser | demo") for frame in (b"|", b"/", b"-", b"\\")}
        self.assertEqual(len(frames), 1, frames)
        self.assertEqual(title_key(b"* - Fix the parser | demo"), title_key(b"* / Fix the parser | demo"))
        self.assertNotEqual(title_key(b"| Fix the parser | demo"), title_key(b"| Fix the cache | demo"))
        # Elsewhere the same characters can tell two names apart.
        self.assertNotEqual(title_key(b"Review - notes | demo"), title_key(b"Review / notes | demo"))
        self.assertNotEqual(title_key(b"demo \\"), title_key(b"demo /"))

    def test_thread_names_take_the_newest_entry_and_an_empty_name_clears(self) -> None:
        thread_names = self.recovery["thread_names"]
        first = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
        second = "019c6e28-e55b-73d1-bc92-3e3c1bcc0022"
        cleared = "019c6e29-e55b-73d1-bc92-3e3c1bcc0022"
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-names-") as temporary:
            index = self.write_jsonl(Path(temporary), "session_index.jsonl", [
                {"id": first, "thread_name": "Draft the parser", "updated_at": "2026-01-01T00:00:00Z"},
                {"id": second, "thread_name": "Profile the cache", "updated_at": "2026-01-01T00:00:01Z"},
                {"id": cleared, "thread_name": "Old name", "updated_at": "2026-01-01T00:00:02Z"},
                {"id": "unrelated", "thread_name": first, "updated_at": "2026-01-01T00:00:03Z"},
                {"id": first, "thread_name": "  Fix the parser ", "updated_at": "2026-01-01T00:00:04Z"},
                {"id": cleared, "thread_name": "", "updated_at": "2026-01-01T00:00:05Z"},
            ])
            with index.open("a", encoding="utf-8") as partial:
                partial.write('{"id": "%s", "thread_name": "Unfinish' % second)
            self.recovery["SESSION_INDEX"] = str(index)
            expected = ({first: "Fix the parser", second: "Profile the cache", cleared: ""}, True)
            self.assertEqual(thread_names({first, second, cleared, "unnamed"}), expected)
            self.assertEqual(thread_names(set()), ({}, True))

            # An unchanged index is read once; an appended name is read again.
            pattern = self.recovery["INDEX_ID"]
            self.recovery["INDEX_ID"] = self.recovery["re"].compile(b"(?!)")
            self.assertEqual(thread_names({first, second, cleared, "unnamed"}), expected)
            self.recovery["INDEX_ID"] = pattern
            with index.open("a", encoding="utf-8") as appended:
                appended.write('\n{"id": "%s", "thread_name": "Profile the cache again"}\n' % second)
            self.assertEqual(thread_names({first, second, cleared, "unnamed"}),
                             ({first: "Fix the parser", second: "Profile the cache again", cleared: ""}, True))

            # A cut read is complete only if it found every thread: a
            # thread named further back may share the name.
            data = index.read_bytes()
            self.recovery["MAX_INDEX"] = len(data) - data.index(b'{"id": "unrelated"') + 1
            self.assertEqual(thread_names({first, cleared}), ({first: "Fix the parser", cleared: ""}, True))
            self.assertEqual(thread_names({first, "unnamed"}), ({first: "Fix the parser"}, False))
            self.recovery["MAX_INDEX"] = 8388608

            self.recovery["SESSION_INDEX"] = str(Path(temporary) / "missing.jsonl")
            self.assertEqual(thread_names({first}), ({}, True))
            link = Path(temporary) / "linked.jsonl"
            os.symlink(index, link)
            self.recovery["SESSION_INDEX"] = str(link)
            self.assertEqual(thread_names({first}), ({}, False))
            # A FIFO in its place never blocks the hook.
            fifo = Path(temporary) / "fifo.jsonl"
            os.mkfifo(fifo)
            self.recovery["SESSION_INDEX"] = str(fifo)
            self.assertEqual(thread_names({first}), ({}, False))

    def test_title_items_drop_a_name_that_another_hosted_thread_shows(self) -> None:
        title_items, thread_items = self.recovery["title_items"], self.recovery["thread_items"]
        session = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
        other = "019c6e28-e55b-73d1-bc92-3e3c1bcc0022"
        ids = {session, session[:29] + "..."}
        projects = self.recovery["project_names"](["/home/u/projects/demo/src", "/srv/an-unusually-long-project-folder-name"])
        self.assertEqual(projects, {"src", "demo", "projects", "u", "home", "srv", "an-unusually-long-pro..."})
        shown_projects = self.recovery["project_items"](projects)

        def items(names: dict[str, str], plain: bool = True, threads: Optional[set[str]] = None) -> set[str]:
            rendered = {thread: thread_items(thread, names) for thread in threads or {session, other}}
            return title_items(session, rendered, shown_projects, plain)
        self.assertEqual(items({session: "Fix the parser", other: "Profile the cache"}), ids | {"Fix the parser"})
        self.assertEqual(items({session: "Fix the parser", other: "Fix  the parser"}), ids)
        self.assertEqual(items({session: "Fix the parser"}, plain=False), ids)
        self.assertEqual(items({session: "", other: "Profile the cache"}), ids)
        self.assertEqual(items({}), ids)
        # The project item reads the same as these names.
        self.assertEqual(items({session: "demo"}), ids)
        self.assertEqual(items({session: "an-unusually-long-pro..."}), ids)
        # Codex cuts a project item to 24 characters, so the whole folder name is no project item.
        self.assertEqual(items({session: "an-unusually-long-project-folder-name"}), ids | {"an-unusually-long-project-folder-name"})
        long_name = "Investigate the intermittent cache eviction stall on startup"
        self.assertEqual(items({session: long_name}), ids | {long_name[:45] + "..."})
        self.assertEqual(items({session: long_name, other: long_name[:45] + " and more words"}), ids)
        self.assertEqual(items({session: "R\u00e9sum\u00e9 draft"}), ids | {"R\u00e9sum\u00e9 draft", "R?sum? draft"})
        # Another name that shows this one as a whole item, or that this one
        # shows, takes it; a longer word does not.
        self.assertEqual(items({session: "Fix the parser", other: "Fix the parser | v2"}), ids)
        self.assertEqual(items({session: "Fix the parser | v2", other: "Fix the parser"}), ids)
        self.assertEqual(items({session: "Fix the parser", other: "Fix the parser v2"}), ids | {"Fix the parser"})
        self.assertEqual(items({session: "Fix demo build"}), ids | {"Fix demo build"})
        # Under GNU screen another name reads the same.
        self.assertEqual(items({session: "a?b c", other: "a\u00e9b c"}), ids)
        self.assertEqual(items({session: "a\u00e9b c", other: "a?b c"}), ids | {"a\u00e9b c"})
        # A thread whose ID cuts the same leaves only the whole ID.
        twin = session[:29] + "fffffff"
        self.assertEqual(items({}, threads={session, twin}), {session})
        # A name can spell another ID, and an ID another name.
        self.assertEqual(items({session: "Fix the parser", other: session}), {session[:29] + "...", "Fix the parser"})
        self.assertEqual(items({other: "x | " + session[:29] + "..."}), {session})
        self.assertEqual(items({session: other}), ids)
        self.assertEqual(items({session: other[:29] + "..."}), ids)
        # The activity item shows its own text.
        self.assertEqual(items({session: "[ ! ] Action Required"}), ids)
        self.assertEqual(items({session: "[ . ] Action Required | v2"}), ids)
        # Where clusters span characters, every cut of another name counts.
        self.assertEqual(items({session: "Fix the parser", other: "\u1100\u1161" * 20 + " | Fix the parser"}), ids)
        myanmar = "\u1000\u102c" * 25
        self.assertEqual(items({session: myanmar[:45] + "...", other: myanmar}), ids)
        self.assertIsNone(thread_items(other, {other: "e\u0301" * 129}))
        self.assertIsNone(self.recovery["project_names"](["/srv/" + "e\u0301" * 129]))
        # GNU screen shows a project too.
        rendered = {thread: thread_items(thread, {session: "r?sum?"}) for thread in (session, other)}
        self.assertEqual(title_items(session, rendered, self.recovery["project_items"]({"r\u00e9sum\u00e9"}), True), ids)

    def test_title_layout_counts_names_only_under_plain_items(self) -> None:
        title_layout_plain = self.recovery["title_layout_plain"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-layout-") as temporary:
            user, system = Path(temporary) / "config.toml", Path(temporary) / "system.toml"
            paths = (str(user), str(system), str(Path(temporary) / "missing" / ".codex" / "config.toml"), str(user / ".codex" / "config.toml"))
            self.assertTrue(title_layout_plain(paths))
            for text, expected in (
                ('model = "gpt"\n', True),
                ('[tui]\nterminal_title = ["activity", "thread-name", "project-name"]\n', True),
                ('[tui]\nterminal_title = ["spinner", "thread", "project", "thread-id"]\n', True),
                ('# terminal_title = ["git-branch"]\n', True),
                ('[tui]\nterminal_title = ["thread-name", "git-branch"]\n', False),
                ('[tui]\nterminal_title = "thread-name"\n', False),
                ('[tui]\nterminal_title = [\n', False),
                ('terminal_title = 1\n' + "#" * 1048576, False),
            ):
                user.write_text(text, encoding="utf-8")
                self.assertEqual(title_layout_plain(paths), expected, text[:64])
            user.write_text('model = "gpt"\n', encoding="utf-8")
            system.write_text('[tui]\nterminal_title = ["model"]\n', encoding="utf-8")
            self.assertFalse(title_layout_plain(paths))
            self.assertTrue(title_layout_plain(paths[:1]))
            # Without tomllib or tomli only the one-line array Codex writes is
            # read; any other mention of the setting is unclear.
            system.write_text('[tui]\nterminal_title = ["thread-name"]\n', encoding="utf-8")
            self.assertTrue(title_layout_plain(paths))
            with mock.patch.dict(sys.modules, {"tomllib": None, "tomli": None}):
                for text, expected in (
                    ('[tui]\nterminal_title = ["activity", "thread-name", "project-name"]\n', True),
                    ('[tui]  # display\nterminal_title=[ "thread", "project", ] # the default\n', True),
                    ('tui.terminal_title = ["thread-id"]\n[model]\nx = 1\n', True),
                    ('[tui]\nterminal_title = []\n', True),
                    ('[tui]\n# terminal_title = ["git-branch"]\n', True),
                    ('[tui]\nterminal_title = ["thread-name", "git-branch"]\n', False),
                    ('[tui]\nterminal_title = [\n  "thread-name",\n]\n', False),
                    ("[tui]\nterminal_title = [\x27thread-name\x27]\n", False),
                    ('[tui.notifications]\nterminal_title = ["thread-name"]\n', False),
                    ('tui = { terminal_title = ["git-branch"] }\n', False),
                    ('[[x]]\nterminal_title = ["thread-name"]\n', False),
                    ('[tui]\nterminal_title = ["thread"]\nterminal_title = ["thread"]\n', False),
                    ('[tui]\n[[x]]\nterminal_title = ["thread-name"]\n', False),
                ):
                    system.write_text(text, encoding="utf-8")
                    self.assertEqual(title_layout_plain(paths), expected, text)
            # tomli reads what tomllib would.
            system.write_text('[tui]\nterminal_title = ["thread-name"]\n', encoding="utf-8")
            tomli = types.SimpleNamespace(loads=lambda text: {"tui": {"terminal_title": ["git-branch"]}})
            with mock.patch.dict(sys.modules, {"tomllib": None, "tomli": tomli}):
                self.assertFalse(title_layout_plain(paths))
            system.unlink()
            system.mkdir()
            self.assertFalse(title_layout_plain(paths))

            # A FIFO or a device in a folder above a project, as another user
            # can put in /tmp, or a link to one, never holds the hook: it is
            # unreadable. A link to a config, as dotfile managers make, is
            # read.
            work = Path(temporary) / "shared" / "work"
            work.mkdir(parents=True)
            (work.parent / ".codex").mkdir()
            config = work.parent / ".codex" / "config.toml"
            fifo = Path(temporary) / "fifo"
            os.mkfifo(fifo)
            layout = Path(temporary) / "layout.toml"
            layout.write_text('[tui]\nterminal_title = ["git-branch"]\n', encoding="utf-8")
            configs = self.recovery["project_configs"]([str(work)])
            for target, expected in ((fifo, False), (Path("/dev/null"), False), (user, True), (layout, False)):
                config.unlink(missing_ok=True)
                config.symlink_to(target)
                with self.never_blocks():
                    self.assertEqual(title_layout_plain(configs), expected, target)
            config.unlink()
            os.mkfifo(config)
            with self.never_blocks():
                self.assertFalse(title_layout_plain(configs))

    def test_server_command_is_the_first_command(self) -> None:
        server_command = self.recovery["server_command"]
        for arguments in (["app-server"], ["app-server", "--listen", "unix://"], ["-c", "x=1", "--enable", "hooks", "app-server"],
                          ["--image", "a.png", "-m", "gpt", "app-server"]):
            self.assertTrue(server_command(arguments), arguments)
        for arguments in ([], ["resume", "app-server"], ["--", "app-server"], ["--image", "a.png", "app-server"],
                          ["-c", "app-server"], ["Explain app-server"], ["exec", "app-server"]):
            self.assertFalse(server_command(arguments), arguments)

    def proc_files(self, files: dict[str, Optional[bytes]]) -> None:
        def fake_open(path: object, mode: str = "r", *arguments: object, **options: object) -> object:
            if path in files:
                value = files[path]
                if value is None:
                    raise PermissionError(path)
                return io.BytesIO(value)
            return open(path, mode, *arguments, **options)
        self.recovery["open"] = fake_open

    def test_client_program_rejects_a_wrapper_script(self) -> None:
        client_program = self.recovery["client_program"]
        files: dict[str, Optional[bytes]] = {}
        self.proc_files(files)
        with mock.patch.object(os.path, "isdir", lambda path: True):
            for cmdline, expected in (
                (b"/usr/local/bin/codex\0resume\0", True),
                (b"codex\0", True),
                (b"/bin/sh\0/home/u/.config/tessera/bin/codex\0", False),
                (b"node\0/usr/lib/node_modules/@openai/codex/bin/codex.js\0", False),
                (b"\0", False),
                (None, False),
            ):
                files["/proc/42/cmdline"] = cmdline
                self.assertEqual(client_program(42), expected, cmdline)
        del files["/proc/42/cmdline"]
        with mock.patch.object(os.path, "isdir", lambda path: False):
            for strings, expected in (((["/opt/homebrew/bin/codex", "resume"], []), True), ((["/bin/sh", "/Users/u/bin/codex"], []), False), (None, False)):
                self.recovery["mac_process_strings"] = lambda pid, strings=strings: strings
                self.assertEqual(client_program(42), expected, strings)

    def test_process_arguments_keep_each_argument_whole(self) -> None:
        process_arguments, process_environment = self.recovery["process_arguments"], self.recovery["process_environment"]
        files: dict[str, Optional[bytes]] = {}
        self.proc_files(files)
        with mock.patch.object(os.path, "isdir", lambda path: True):
            for cmdline, expected in (
                (b"codex\0--remote\0unix://\0fix the --remote flag\0", ["codex", "--remote", "unix://", "fix the --remote flag"]),
                (b"codex", ["codex"]),
                (b"codex\0\xff\0", None),
                (b"codex\0" + b"x" * 65536, None),
                (None, None),
            ):
                files["/proc/42/cmdline"] = cmdline
                self.assertEqual(process_arguments(42), expected, cmdline[:32] if cmdline else cmdline)
            files["/proc/42/environ"] = b"HOME=/h\0A=b c\0"
            self.assertEqual(process_environment(42), [b"HOME=/h", b"A=b c", b""])
            files["/proc/42/environ"] = b"x" * 1048577
            self.assertIsNone(process_environment(42))
        # Elsewhere ps would join the arguments, so only macOS tells them.
        with mock.patch.object(os.path, "isdir", lambda path: False):
            self.recovery["mac_process_strings"] = lambda pid: (["/opt/homebrew/bin/codex", "-C", "/srv/a b"], [b"HOME=/h"]) if pid == 42 else None
            self.assertEqual(process_arguments(42), ["/opt/homebrew/bin/codex", "-C", "/srv/a b"])
            self.assertEqual(process_environment(42), [b"HOME=/h"])
            self.assertIsNone(process_arguments(43))
            self.assertIsNone(process_environment(43))

    def test_mac_process_strings_read_a_live_process(self) -> None:
        mac_process_strings = self.recovery["mac_process_strings"]
        if sys.platform != "darwin":
            self.assertIsNone(mac_process_strings(os.getpid()))
            return
        argv = [sys.executable, "-c", "import time; time.sleep(30)", "-C", "/srv/Fix the parser", "", "x"]
        child = subprocess.Popen(argv, env={"CODEX_HOME": "/srv/a b", "HOME": "/h"})
        try:
            deadline = self.recovery["time"].monotonic() + 5
            strings = None
            while self.recovery["time"].monotonic() < deadline:
                strings = mac_process_strings(child.pid)
                if strings is not None and strings[0][1:2] == ["-c"]:
                    break
                self.recovery["time"].sleep(0.05)
            self.assertIsNotNone(strings)
            self.assertEqual(strings[0][1:], argv[1:])
            self.assertIn(b"CODEX_HOME=/srv/a b", strings[1])
            self.assertIn(b"HOME=/h", strings[1])
        finally:
            child.kill()
            child.wait()
        self.assertIsNone(mac_process_strings(child.pid))
        self.assertIsNone(mac_process_strings(1))

    def test_client_scope_follows_the_cwd_and_refuses_another_server(self) -> None:
        client_scope = self.recovery["client_scope"]
        self.recovery["CODEX_CONFIGS"] = ("/home/u/.codex/config.toml", "/etc/codex/config.toml")
        self.recovery["client_cwd"] = lambda pid: "/home/u/projects/demo" if pid == 42 else None
        base = {"demo", "projects", "u", "home"}
        ancestors = ["/home/u/projects/demo/.codex/config.toml", "/home/u/projects/.codex/config.toml", "/home/u/.codex/config.toml",
                     "/home/.codex/config.toml", "/.codex/config.toml"]
        parser = ["/srv/parser/.codex/config.toml", "/srv/.codex/config.toml"]
        work = ["/home/u/.codex/work.config.toml"]

        def expect(projects: set[str], profiles: list[str] = [], extra: list[str] = []) -> tuple[set[str], list[str]]:
            return projects, list(dict.fromkeys(["/home/u/.codex/config.toml", "/etc/codex/config.toml"] + profiles + ancestors + extra))
        for arguments, expected in (
            (["codex"], expect(base)),
            (["codex", "resume", "--last"], expect(base)),
            (["codex", "-C", "/srv/parser"], expect(base | {"parser", "srv"}, extra=parser)),
            (["codex", "--cd=/srv/parser"], expect(base | {"parser", "srv"}, extra=parser)),
            (["codex", "-C/srv/parser"], expect(base | {"parser", "srv"}, extra=parser)),
            (["codex", "--cd", "sub"], expect(base | {"sub"}, extra=["/home/u/projects/demo/sub/.codex/config.toml"])),
            (["codex", "--remote", "unix://"], expect(base)),
            (["codex", "--remote=unix://"], expect(base)),
            (["codex", "-p", "work"], expect(base, profiles=work)),
            (["codex", "--profile=work"], expect(base, profiles=work)),
            (["codex", "-pwork", "resume"], expect(base, profiles=work)),
            (["codex", "--", "--remote", "ws://h:1", "terminal_title", "-p", "x/y"], expect(base)),
            (["codex", "--remote", "unix:///tmp/other.sock"], None),
            (["codex", "resume", "--remote=ws://127.0.0.1:9"], None),
            (["codex", "--remote"], None),
            (["codex", "-p"], None),
            (["codex", "--profile", "../work"], None),
            (["codex", "-c", 'tui.terminal_title=["git-branch"]'], None),
            ([], None),
        ):
            scope = client_scope(42, arguments)
            self.assertEqual(None if scope is None else (scope[0], list(dict.fromkeys(scope[1]))), expected, arguments)
        self.assertIsNone(client_scope(43, ["codex"]))

    def test_client_cwd_reads_the_process_cwd(self) -> None:
        client_cwd = self.recovery["client_cwd"]
        with mock.patch.object(os.path, "isdir", lambda path: True), \
                mock.patch.object(os, "readlink", lambda path: "/srv/parser" if path == "/proc/42/cwd" else (_ for _ in ()).throw(OSError(path))):
            self.assertEqual(client_cwd(42), "/srv/parser")
            self.assertIsNone(client_cwd(43))
        with mock.patch.object(os.path, "isdir", lambda path: False):
            for output, expected in ((b"p42\nfcwd\nn/srv/parser\n", "/srv/parser"), (b"p42\n", None), (None, None), (b"fcwd\nn/\xff\n", None)):
                self.recovery["run"] = lambda argv, limit=0, env=None, output=output: output if argv == ["lsof", "-a", "-p", "42", "-d", "cwd", "-Fn"] else None
                self.assertEqual(client_cwd(42), expected, output)

    def test_server_threads_fail_on_an_unreadable_rollout(self) -> None:
        server_threads = self.recovery["server_threads"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-server-") as temporary:
            root = Path(temporary)
            session, subagent = self.SESSION, self.SUBAGENT
            rollout = self.write_jsonl(root, f"rollout-{session}.jsonl", [{"type": "session_meta", "payload": {
                "source": "cli", "session_id": session, "id": session, "cwd": "/home/u/projects/demo"}}])
            child = self.write_jsonl(root, f"rollout-{subagent}.jsonl", [{"type": "session_meta", "payload": {
                "source": {"subagent": "review"}, "session_id": session, "id": subagent, "cwd": "/home/u/projects/demo",
                "base_instructions": "x" * 600}}])
            files = [(str(rollout), self.identity(rollout)), (str(child), self.identity(child))]
            self.recovery["linux_open_files_strict"] = lambda pid, sessions, limit=512: files
            self.recovery["mac_open_files_strict"] = lambda pid, sessions: files
            roots = {session: (str(rollout), self.identity(rollout), "/home/u/projects/demo")}
            self.assertEqual(server_threads(105), (roots, {session, subagent}))
            # Past the deadline of the hook no rollout is read.
            self.recovery["RUN_DEADLINE"] = self.recovery["time"].monotonic() - 1
            self.assertIsNone(server_threads(105))
            self.recovery["RUN_DEADLINE"] = None
            # A subagent too long to read could share a name.
            self.recovery["MAX_HEADER"] = 512
            self.recovery["HEADER_CACHE"].clear()
            self.assertIsNone(server_threads(105))
            self.recovery["MAX_HEADER"] = 262144
            self.write_jsonl(root, f"rollout-{subagent}.jsonl", [{"type": "session_meta", "payload": {"source": "cli"}}])
            files[1] = (str(child), self.identity(child))
            self.assertIsNone(server_threads(105))

    def test_home_server_listens_on_the_control_socket_of_the_home(self) -> None:
        home_server = self.recovery["home_server"]
        for arguments, expected in (
            (["codex", "app-server", "--listen", "unix://", "--analytics-default-enabled", "--managed-daemon"], True),
            (["/h/.codex/packages/app-server-daemon/releases/1/bin/codex", "app-server", "--listen=unix://"], True),
            (["codex", "-c", "x=1", "app-server", "--listen", "unix://"], True),
            (["codex", "app-server", "--listen", "unix:///tmp/other.sock"], False),
            (["codex", "app-server", "--listen", "ws://127.0.0.1:4500"], False),
            (["codex", "app-server"], False),
            (["codex", "exec", "--listen", "unix://"], False),
            (None, False),
        ):
            self.recovery["process_arguments"] = lambda pid, arguments=arguments: arguments
            self.assertEqual(home_server(105), expected, arguments)
        # Past the program, the first command decides whether a process serves.
        codex_server = self.recovery["codex_server"]
        for arguments, expected in ((["codex", "app-server"], True), (["codex", "resume", "app-server"], False), (["app-server"], False), (None, None)):
            self.recovery["process_arguments"] = lambda pid, arguments=arguments: arguments
            self.assertEqual(codex_server(105), expected, arguments)

    def test_client_home_must_hold_the_sessions_of_this_server(self) -> None:
        client_home = self.recovery["client_home"]
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-home-") as temporary:
            home = os.path.realpath(temporary).encode("utf-8")
            self.recovery["CODEX_CONFIGS"] = (os.path.join(os.path.realpath(temporary), ".codex", "config.toml"),)
            # Another home whose sessions folder links to this one has a
            # server of its own.
            other = Path(temporary) / "work"
            (Path(temporary) / ".codex" / "sessions").mkdir(parents=True)
            (other / ".codex").mkdir(parents=True)
            (other / ".codex" / "sessions").symlink_to(Path(temporary) / ".codex" / "sessions")
            files: dict[str, Optional[bytes]] = {}
            self.proc_files(files)
            with mock.patch.object(os.path, "isdir", lambda path: True):
                for environment, expected in (
                    (b"HOME=" + home + b"\0PATH=/bin\0", True),
                    (b"CODEX_HOME=" + home + b"/.codex\0HOME=/elsewhere\0", True),
                    (b"CODEX_HOME=\0HOME=" + home + b"\0", True),
                    (b"CODEX_HOME=/elsewhere/.codex\0HOME=" + home + b"\0", False),
                    (b"CODEX_HOME=" + home + b"/work/.codex\0", False),
                    (b"CODEX_HOME=" + home + b"/work/../.codex\0", True),
                    (b"CODEX_HOME=.codex\0HOME=" + home + b"\0", False),
                    (b"HOME=/elsewhere\0HOME=" + home + b"\0", False),
                    (b"HOME=" + home + b"\0" + b"x" * 1048576, False),
                    (None, False),
                ):
                    files["/proc/42/environ"] = environment
                    self.assertEqual(client_home(42), expected, environment[:64] if environment else environment)
            # macOS gives the owner the environment too.
            with mock.patch.object(os.path, "isdir", lambda path: False):
                for environment, expected in (([b"HOME=" + home], True), ([b"CODEX_HOME=/elsewhere/.codex"], False), (None, False)):
                    self.recovery["mac_process_strings"] = lambda pid, environment=environment: None if environment is None else (["codex"], environment)
                    self.assertEqual(client_home(42), expected, environment)

    def shared_host(self) -> dict[str, object]:
        """A synthetic host: one shared server and three panes.

        %1: bash 101 -> Tessera shim 102 (named codex) -> node 103 -> TUI 104,
            which also started the server 105 and its tool 106.
        %2: bash 201 -> TUI 202.
        %3: bash 301 -> a self-hosting TUI 302.
        """
        parents = {101: 100, 102: 101, 103: 102, 104: 103, 105: 104, 106: 105, 201: 200, 202: 201, 301: 300, 302: 301}
        names = {101: "bash", 102: "codex", 103: "node", 104: "codex", 105: "codex", 106: "codex", 201: "bash", 202: "codex", 301: "bash", 302: "codex"}
        arguments = {102: ["/home/u/.config/tessera/bin/codex"], 104: [], 105: ["app-server", "--listen", "unix://", "--managed-daemon"],
                     106: ["exec", "summarize"], 202: ["resume", "app-server"], 302: ["--no-daemon"]}
        return {"parents": parents, "names": names, "arguments": arguments}

    def test_pane_client_is_the_one_innermost_codex_outside_the_server(self) -> None:
        pane_client = self.recovery["pane_client"]
        host = self.shared_host()
        parents, names = host["parents"], host["names"]
        server_command = self.recovery["server_command"]
        self.recovery["codex_server"] = lambda pid: server_command(host["arguments"].get(pid, []))
        children: dict[int, list[int]] = {}
        for child, parent in parents.items():
            children.setdefault(parent, []).append(child)
        self.assertEqual(pane_client(100, 105, parents, names, children), 104)
        self.assertEqual(pane_client(200, 105, parents, names, children), 202)
        self.assertIsNone(pane_client(999, 105, parents, names, children))
        # Without the server excluded its tool would be the innermost Codex.
        self.assertEqual(pane_client(100, 1, parents, names, children), 106)
        # A second TUI in the pane, such as a background job, is ambiguous.
        parents2 = {**parents, 203: 201}
        names2 = {**names, 203: "codex"}
        children2 = {key: list(value) for key, value in children.items()}
        children2[201].append(203)
        self.assertIsNone(pane_client(200, 105, parents2, names2, children2))
        # An app-server is never the client, and unreadable arguments fail.
        self.recovery["codex_server"] = lambda pid: pid == 202
        self.assertIsNone(pane_client(200, 105, parents, names, children))
        self.recovery["codex_server"] = lambda pid: None
        self.assertIsNone(pane_client(200, 105, parents, names, children))

    SESSION = "019c6e27-e55b-73d1-bc92-3e3c1bcc0022"
    OTHER = "019c6e28-e55b-73d1-bc92-3e3c1bcc0022"
    SUBAGENT = "019c6e31-e55b-73d1-bc92-3e3c1bcc0022"

    def install_shared_host(self, titles: list[tuple[str, int, str]], index_names: dict[str, str],
                            complete: bool = True, hosted: tuple[str, ...] = (), readable: bool = True, layout: object = True,
                            arguments: Optional[dict[int, list[str]]] = None, cwds: Optional[dict[int, str]] = None,
                            crowd: tuple[str, ...] = (), observed: tuple[int, ...] = ()) -> dict[str, list[object]]:
        host = self.shared_host()
        roots = {thread: (f"/safe/sessions/rollout-{thread}.jsonl", (1, number), "/home/u/projects/demo")
                 for number, thread in enumerate((self.SESSION, self.OTHER) + crowd, 1)}
        server_command = self.recovery["server_command"]
        record: dict[str, list[object]] = {"marks": [], "tmux": [], "locks": []}

        def observer_lock(pid: int, kind: str = "observer", wait: float = 0) -> Optional[int]:
            record["locks"].append((pid, kind))
            return None if pid in observed else os.open(os.devnull, os.O_RDONLY)

        def run(argv: list[str], limit: int = 0, env: object = None) -> Optional[bytes]:
            record["tmux"].append(argv)
            if argv[:3] == ["tmux", "list-panes", "-a"]:
                return "".join(f"{pane}\t{pid}\t{title}\n" for pane, pid, title in titles).encode("utf-8")
            return None

        self.recovery.update({
            "run": run,
            "is_codex": lambda pid: pid in {104, 105, 202, 302},
            "server_threads": lambda pid: (dict(roots), set(roots) | set(hosted)) if pid == 105 and readable else None,
            "thread_names": lambda ids: ({key: value for key, value in index_names.items() if key in ids}, complete),
            "title_layout_plain": layout if callable(layout) else lambda paths: layout,
            "process_arguments": lambda pid: (arguments or {}).get(pid, ["codex"] + host["arguments"].get(pid, [])),
            "client_cwd": lambda pid: (cwds or {}).get(pid, "/home/u/projects/demo"),
            "process_table": lambda: (host["parents"], host["names"]),
            "codex_server": lambda pid: server_command(host["arguments"].get(pid, [])),
            "linux_open_files_strict": lambda pid, root, limit=512: [("/safe/sessions/own.jsonl", (1, 3))] if pid == 302 else [],
            "mac_open_files_strict": lambda pid, root: [("/safe/sessions/own.jsonl", (1, 3))] if pid == 302 else [],
            "current_uid": lambda pid: os.getuid(),
            "descendant": lambda child, ancestor: ancestor in {child, host["parents"].get(child)} or (
                ancestor == 100 and child in {101, 102, 103, 104, 105, 106}) or (ancestor == 200 and child in {201, 202}) or (
                ancestor == 300 and child in {301, 302}) or (ancestor == 105 and child == 106),
            "client_program": lambda pid, arguments=None: pid != 102,
            "client_home": lambda pid: True,
            "process_start_token": lambda pid: f"start-{pid}",
            "mark_shared_client": lambda pid, token, server, pane: record["marks"].append((pid, token, server, pane)) or True,
            "observer_lock": observer_lock,
        })
        return record

    def test_bind_shared_binds_the_one_pane_whose_client_shows_the_thread(self) -> None:
        bind_shared = self.recovery["bind_shared"]
        session, other = self.SESSION, self.OTHER
        transcript = self.recovery["base64"].urlsafe_b64encode(
            f"/safe/sessions/rollout-{session}.jsonl".encode("utf-8")).decode("ascii").rstrip("=")
        names = {session: "Fix the parser", other: "Profile the cache"}
        titles = [("%1", 100, "⠋ Profile the cache | demo"), ("%2", 200, "Fix the parser | demo"),
                  ("%2", 200, "Fix the parser | demo"), ("%3", 300, "demo")]
        record = self.install_shared_host(titles, names)
        self.assertEqual(bind_shared("105", session), f"%2 202 {transcript} 1")
        self.assertEqual(record["marks"], [(202, "start-202", 105, "%2")])
        self.assertEqual(record["locks"], [(202, "shared-observer")])
        self.assertTrue(bind_shared("105", other).startswith("%1 104 "))
        # A client whose title observer runs needs no other.
        self.install_shared_host(titles, names, observed=(202,))
        self.assertEqual(bind_shared("105", session), f"%2 202 {transcript} 0")

        # The thread-id item binds even when names collide.
        self.install_shared_host([("%1", 100, "Fix the parser | demo"), ("%2", 200, f"Fix the parser | {session[:29]}...")],
                                 {session: "Fix the parser", other: "Fix the parser"})
        self.assertTrue(bind_shared("105", session).startswith("%2 202 "))
        self.assertIsNone(bind_shared("105", other))

    def test_bind_shared_fails_closed(self) -> None:
        bind_shared = self.recovery["bind_shared"]
        session, other = self.SESSION, self.OTHER
        names = {session: "Fix the parser"}
        cases = {
            "two panes show it": [("%1", 100, "Fix the parser"), ("%2", 200, "Fix the parser")],
            "no pane shows it": [("%1", 100, "demo"), ("%2", 200, "⠋ demo")],
            "only a self-hosting client shows it": [("%3", 300, "Fix the parser | demo")],
            "only a pane without a client shows it": [("%9", 900, "Fix the parser")],
            "an incomplete index": [("%2", 200, "Fix the parser")],
            "a malformed pane": [("pane", 200, "Fix the parser")],
        }
        for label, titles in cases.items():
            record = self.install_shared_host(titles, names, complete=label != "an incomplete index")
            self.assertIsNone(bind_shared("105", session), label)
            self.assertEqual(record["marks"], [], label)

        titles = [("%2", 200, "Fix the parser")]
        self.install_shared_host(titles, {})
        self.assertIsNone(bind_shared("105", session), "unnamed")
        # Named like the project, the thread would bind to another thread's
        # project item.
        self.install_shared_host([("%1", 100, "Profile the cache | demo")], {session: "demo"})
        self.assertIsNone(bind_shared("105", session), "project name")
        # The pane shows another thread whose name holds this one.
        self.install_shared_host([("%1", 100, "Fix the parser | v2 | demo")], {session: "Fix the parser", other: "Fix the parser | v2"})
        self.assertIsNone(bind_shared("105", session), "inside another name")
        # A subagent the server holds can carry the name too.
        self.install_shared_host(titles, {session: "Fix the parser", self.SUBAGENT: "Fix the parser"}, hosted=(self.SUBAGENT,))
        self.assertIsNone(bind_shared("105", session), "a subagent name")
        self.install_shared_host(titles, names)
        self.recovery["client_program"] = lambda pid, arguments=None: False
        self.assertIsNone(bind_shared("105", session), "a wrapper script")
        self.install_shared_host(titles, names, arguments={202: ["codex", "--remote", "ws://127.0.0.1:9"]})
        self.assertIsNone(bind_shared("105", session), "a client of another server")
        self.install_shared_host(titles, names, arguments={202: ["codex", "-c", 'tui.terminal_title=["git-branch"]']})
        self.assertIsNone(bind_shared("105", session), "a client with its own title")
        # Named like the project a client resumed another thread in.
        resumed = [("%2", 200, "Profile the cache | parser")]
        self.install_shared_host(resumed, {session: "parser", other: "Profile the cache"})
        self.assertTrue(bind_shared("105", session).startswith("%2 202 "), "the control: only the cwd tells")
        self.install_shared_host(resumed, {session: "parser", other: "Profile the cache"}, cwds={202: "/srv/parser"})
        self.assertIsNone(bind_shared("105", session), "the project of the client cwd")
        self.install_shared_host(resumed, {session: "parser"}, cwds={202: "/srv/parser"}, arguments={202: ["codex", "-C", "/srv/x"]})
        self.assertIsNone(bind_shared("105", session), "the project of the client cwd, with -C")
        self.install_shared_host(resumed, {session: "parser"}, arguments={202: ["codex", "-C", "/srv/parser"]})
        self.assertIsNone(bind_shared("105", session), "the project of -C")
        self.install_shared_host(resumed, {session: "parser"}, cwds={})
        self.recovery["client_cwd"] = lambda pid: None
        self.assertIsNone(bind_shared("105", session), "an unreadable client cwd")
        # Under a layout of other items only the ID binds, also when the
        # layout is set for the profile of the client; where a thread or its
        # name is unknown nothing does.
        by_id = [("%2", 200, f"Fix the parser | {session[:29]}...")]
        profile = {202: ["codex", "--profile", "work"]}
        for label, options in (("a title layout of other items", {"layout": False}),
                               ("a layout of the client profile", {"arguments": profile, "layout": lambda paths: not any(
                                   path.endswith("/work.config.toml") for path in paths)})):
            self.install_shared_host(titles, names, **options)
            self.assertIsNone(bind_shared("105", session), label)
            self.install_shared_host(by_id, names, **options)
            self.assertTrue(bind_shared("105", session).startswith("%2 202 "), label)
        # Another pane can read as the name the layout keeps from counting.
        self.install_shared_host([("%1", 100, "Fix the parser | demo")] + by_id, names, layout=False)
        self.assertTrue(bind_shared("105", session).startswith("%2 202 "), "a name another layout shows")
        for label, options in (("an unreadable rollout", {"readable": False}), ("an incomplete index", {"complete": False})):
            self.install_shared_host(by_id, names, **options)
            self.assertIsNone(bind_shared("105", session), label)
        # A thread resumed in its own cwd reads the project config there.
        resumed_layout = {"cwds": {202: "/launch"}, "layout": lambda paths: "/home/u/projects/demo/.codex/config.toml" not in paths}
        self.install_shared_host(titles, names, **resumed_layout)
        self.assertIsNone(bind_shared("105", session), "the project layout of a thread cwd")
        self.install_shared_host(by_id, names, **resumed_layout)
        self.assertTrue(bind_shared("105", session).startswith("%2 202 "), "the project layout of a thread cwd, by ID")
        self.install_shared_host(by_id, {session: "Fix the parser", other: "e\u0301" * 129})
        self.assertIsNone(bind_shared("105", session), "a name of too many cuts")
        # Only the server of the home socket has clients that show its threads.
        for listener in (["app-server", "--listen", "unix:///tmp/other.sock"], ["app-server"], ["app-server", "--listen", "ws://127.0.0.1:9"]):
            self.install_shared_host(titles, names, arguments={105: ["codex"] + listener})
            self.assertIsNone(bind_shared("105", session), listener)
        self.install_shared_host(titles, names, arguments={105: ["codex", "app-server", "--listen=unix://"]})
        self.assertTrue(bind_shared("105", session).startswith("%2 202 "), "--listen=unix://")
        # A name that spells the ID another pane shows, or the activity text.
        self.install_shared_host([("%1", 100, f"{other} | demo")], {session: other})
        self.assertIsNone(bind_shared("105", session), "a name spelling another ID")
        self.install_shared_host([("%1", 100, "[ ! ] Action Required | demo")], {session: "[ ! ] Action Required"})
        self.assertIsNone(bind_shared("105", session), "a name spelling the activity text")
        self.install_shared_host(titles, names)
        self.recovery["client_home"] = lambda pid: False
        self.assertIsNone(bind_shared("105", session), "another Codex home")
        self.install_shared_host(titles, names)
        self.recovery["SHARED_DEADLINE"] = -1
        self.assertIsNone(bind_shared("105", session), "past the deadline")
        self.recovery["SHARED_DEADLINE"] = 0.75
        self.install_shared_host(titles, names)
        self.assertIsNone(bind_shared("105", "019c6e30-e55b-73d1-bc92-3e3c1bcc0022"), "not hosted")
        self.assertIsNone(bind_shared("104", session), "not the server")
        for server, thread in (("0105", session), ("105x", session), ("105", ""), ("105", "bad id")):
            self.assertIsNone(bind_shared(server, thread))
        self.recovery["linux_open_files_strict"] = lambda pid, root, limit=512: None
        self.recovery["mac_open_files_strict"] = lambda pid, root: None
        self.assertIsNone(bind_shared("105", session), "unreadable client files")
        self.install_shared_host(titles, names)
        self.recovery["mark_shared_client"] = lambda pid, token, server, pane: False
        self.assertIsNone(bind_shared("105", session), "unmarked client")
        self.install_shared_host(titles, names)
        self.recovery["run"] = lambda argv, limit=0, env=None: None
        self.assertIsNone(bind_shared("105", session), "no tmux")

    def test_bind_and_target_stay_fast_on_a_crowded_server(self) -> None:
        crowd = tuple(f"019c7{number:03d}-e55b-73d1-bc92-3e3c1bcc0022" for number in range(600))
        names = {thread: "Crowded thread" for thread in crowd}
        names[self.SESSION] = "Fix the parser"
        clock = self.recovery["time"]
        self.install_shared_host([("%2", 200, "Fix the parser | demo"), ("%1", 100, "Crowded thread | demo")], names, crowd=crowd)
        started = clock.monotonic()
        self.assertTrue(self.recovery["bind_shared"]("105", self.SESSION).startswith("%2 202 "))
        self.assertLess(clock.monotonic() - started, 0.5)
        # A title that many roots can be read in decides nothing, quickly:
        # no root is weighed against all the others.
        weighed: list[str] = []
        title_items = self.recovery["title_items"]
        self.recovery["title_items"] = lambda session_id, *rest: weighed.append(session_id) or title_items(session_id, *rest)
        started = clock.monotonic()
        self.assertIsNone(self.recovery["shared_target"](105, "%1", "", 104))
        self.assertLess(clock.monotonic() - started, 0.5)
        self.assertEqual(weighed, [])

    def test_bind_shared_bounds_every_command_by_its_deadline(self) -> None:
        record = self.install_shared_host([("%2", 200, "Fix the parser")], {self.SESSION: "Fix the parser"})
        listed = self.recovery["run"]
        seen: list[object] = []

        def run(argv: list[str], limit: int = 0, env: object = None) -> Optional[bytes]:
            seen.append(self.recovery["RUN_DEADLINE"])
            return listed(argv, limit, env)
        self.recovery["run"] = run
        started = self.recovery["time"].monotonic()
        self.assertTrue(self.recovery["bind_shared"]("105", self.SESSION).startswith("%2 202 "))
        self.assertTrue(seen and all(isinstance(value, float) and started < value <= started + 0.76 for value in seen), seen)
        self.assertIsNone(self.recovery["RUN_DEADLINE"])
        self.assertEqual(len(record["marks"]), 1)

    def test_run_ends_by_the_deadline(self) -> None:
        run, clock = self.recovery["run"], self.recovery["time"]
        self.assertEqual(run(["/bin/sh", "-c", "printf ok"]), b"ok")
        self.recovery["RUN_DEADLINE"] = clock.monotonic() - 1
        spawned: list[object] = []
        real = self.recovery["subprocess"]
        self.recovery["subprocess"] = mock.Mock(Popen=lambda *arguments, **options: spawned.append(arguments) or real.Popen(*arguments, **options),
                                                DEVNULL=real.DEVNULL, PIPE=real.PIPE)
        self.assertIsNone(run(["/bin/sh", "-c", "printf ok"]))
        self.assertEqual(spawned, [])
        self.recovery["subprocess"] = real
        self.recovery["RUN_DEADLINE"] = clock.monotonic() + 0.2
        started = clock.monotonic()
        self.assertIsNone(run(["/bin/sh", "-c", "sleep 5"]))
        self.assertLess(clock.monotonic() - started, 1)

    def test_a_bound_client_is_marked_with_its_server_and_pane(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-mark-") as temporary, \
                mock.patch.dict(os.environ, {"HOME": temporary}):
            mark = self.recovery["mark_shared_client"]
            marked = self.recovery["shared_client"]
            self.assertIsNone(marked(42, "99"))
            self.assertTrue(mark(42, "99", 105, "%2"))
            directory = Path(temporary) / ".config/tessera/agent-runtime-state"
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            self.assertEqual(sorted(path.name for path in directory.iterdir()), ["42.shared-server"])
            # The hook reads the start token from the first line.
            self.assertEqual((directory / "42.shared-server").read_text(encoding="ascii"), "99\n105\n%2\n")
            self.assertEqual(marked(42, "99"), (105, "%2"))
            self.assertIsNone(marked(42, "98"))
            self.assertIsNone(marked(43, "99"))
            self.assertTrue(mark(45, "Tue Oct 28 10:00:00 2026", 105, "%3"))
            self.assertEqual(marked(45, "Tue Oct 28 10:00:00 2026"), (105, "%3"))
            for content in ("99", "99\n105\n%2", "99\n105\n%2\nextra\n", "99\n0105\n%2\n", "99\n105\npane\n", "99\n105\n%2\n\n"):
                (directory / "46.shared-server").write_text(content, encoding="ascii")
                self.assertIsNone(marked(46, "99"), content)
            os.symlink(directory / "42.shared-server", directory / "44.shared-server")
            self.assertIsNone(marked(44, "99"))
            os.mkfifo(directory / "47.shared-server")
            self.assertIsNone(marked(47, "99"))

    def test_shared_target_follows_the_title_of_the_bound_pane(self) -> None:
        shared_target = self.recovery["shared_target"]
        session, other, subagent = self.SESSION, self.OTHER, self.SUBAGENT
        names = {session: "Fix the parser", other: "Profile the cache", subagent: "Review the parser"}

        def path(thread: str) -> str:
            return f"/safe/sessions/rollout-{thread}.jsonl"

        def target(title: str, claim: str = session, others: tuple[tuple[str, int, str], ...] = (("%1", 100, "demo"),),
                   complete: bool = True, pane: str = "%2", server: int = 105, index: Optional[dict[str, str]] = None,
                   **options: object) -> object:
            self.install_shared_host([("%2", 200, title), *others], names if index is None else index, complete, hosted=(subagent,), **options)
            return shared_target(server, pane, claim, 202)
        self.assertEqual(target("⠋ Fix the parser | demo"), (session, path(session)))
        self.assertEqual(target("[ . ] Action Required | Fix the parser | demo"), (session, path(session)))
        # An idle /resume shows another hosted root; /new and /clear show none.
        self.assertEqual(target("Profile the cache | demo"), (other, path(other)))
        self.assertEqual(target("Profile the cache | demo", claim=""), (other, path(other)))
        self.assertEqual(target("demo"), ("", None))
        self.assertEqual(target("demo", claim=""), ("", None))
        # A claimed thread the server no longer holds stays while shown.
        names["019c6e40-e55b-73d1-bc92-3e3c1bcc0022"] = "Old thread"
        self.assertEqual(target("Old thread | demo", claim="019c6e40-e55b-73d1-bc92-3e3c1bcc0022"),
                         ("019c6e40-e55b-73d1-bc92-3e3c1bcc0022", None))
        # Unclear titles decide nothing.
        for label, value in (
            ("a subagent opened in the TUI", target("Review the parser | demo")),
            ("another pane shows it too", target("Profile the cache | demo", others=(("%1", 100, "Profile the cache"),))),
            ("an incomplete index", target("demo", complete=False)),
            ("two roots", target("Fix the parser | Profile the cache", claim="")),
            ("a name that reads as the project", target("Profile the cache | demo", others=(("%1", 100, "codex"),),
                                                              index={session: "Fix the parser", other: "demo"})),
            ("an unknown pane", target("Profile the cache | demo", pane="%7")),
            ("a stopped server", target("Profile the cache | demo", server=106)),
            ("an unreadable rollout", target("Profile the cache | demo", readable=False)),
            ("an unreadable rollout, shown by ID", target(f"{other} | demo", readable=False)),
            ("a title layout of other items", target("Profile the cache | demo", layout=False)),
            ("a title of other items that shows no thread", target("codex | demo", layout=False)),
            ("the project layout of a thread cwd", target("Profile the cache | demo", cwds={202: "/launch"},
                                                          layout=lambda paths: "/home/u/projects/demo/.codex/config.toml" not in paths)),
            ("a layout of the client profile", target("Profile the cache | demo", arguments={202: ["codex", "-p", "work"]},
                                                      layout=lambda paths: not any(path.endswith("/work.config.toml") for path in paths))),
            ("a name that spells the ID shown", target(f"{session[:29]}... | demo", claim="", index={session: "", other: session[:29] + "..."})),
            ("a name that spells the activity text", target("[ ! ] Action Required | demo", claim="",
                                                            index={session: "Fix the parser", other: "[ ! ] Action Required"})),
            ("a client of another server", target("Profile the cache | demo", arguments={202: ["codex", "--remote", "ws://h:1"]})),
            ("a name that reads as the project of the client cwd", target("parser", claim="", index={session: "Fix the parser", other: "parser"},
                                                                           cwds={202: "/srv/parser"})),
        ):
            self.assertIsNone(value, label)
        # A Codex started in the pane after the client shows its own title.
        self.install_shared_host([("%2", 200, "Profile the cache | demo")], names, hosted=(subagent,))
        pane_client = self.recovery["pane_client"]
        self.recovery["pane_client"] = lambda pane_pid, server, parents, commands, children: 203
        self.assertIsNone(shared_target(105, "%2", session, 202), "another Codex in the pane")
        self.recovery["pane_client"] = pane_client
        # The control: without the client cwd the name would be adopted.
        self.assertEqual(target("parser", claim="", index={session: "Fix the parser", other: "parser"}), (other, path(other)))
        # A claim renamed to read as the project no longer holds the pane,
        # whether /new left the project alone or not.
        renamed = {session: "demo", other: "Profile the cache"}
        self.assertEqual(target("demo", index=renamed), ("", None))
        self.assertEqual(target("demo | demo", index=renamed), ("", None))
        self.assertEqual(target("Profile the cache | demo", index=renamed), (other, path(other)))
        # A thread ID shows the claim under any layout.
        self.assertEqual(target(f"{session} | demo", layout=False), (session, path(session)))

    def watch_steps(self, steps: list[tuple[str, Optional[tuple[str, str]], Optional[tuple[str, Optional[str]]]]],
                    bootstrap: bool = False) -> tuple[list[int], list[tuple[object, ...]]]:
        """Runs one observer poll per step: the title, the claim and the target."""
        state = {"step": 0}
        evaluated: list[int] = []
        published: list[tuple[object, ...]] = []

        def current() -> tuple[str, Optional[tuple[str, str]], Optional[tuple[str, Optional[str]]]]:
            return steps[state["step"]]
        self.recovery.update({
            "watcher_live": lambda pid, token: (pid, token) == (42, "99") and state["step"] < len(steps),
            "watcher_ended": lambda pid, token: (pid, token) != (42, "99") or state["step"] >= len(steps),
            "shared_client": lambda pid, token: (105, "%2"),
            "read_observer_claim": lambda pid: current()[1],
            "run": lambda argv, limit=0, env=None: current()[0].encode("utf-8") if argv == ["tmux", "display-message", "-p", "-t", "%2", "#{pane_title}"] else None,
            "shared_target": lambda server, pane, claim, client: evaluated.append(state["step"]) or current()[2],
            "invoke_observed_hook": lambda pid, token, session, path, stamp, pane=None: published.append((state["step"], session, path, stamp, pane)),
            "time": mock.Mock(sleep=lambda seconds: state.__setitem__("step", state["step"] + 1), monotonic=lambda: float(state["step"])),
        })
        self.recovery["watch_shared"](42, "99", bootstrap)
        return evaluated, published

    def test_watch_shared_follows_a_settled_change_of_title_or_claim(self) -> None:
        evaluated, published = self.watch_steps([
            ("⠋ T1", ("A", "100"), ("A", "/a")),
            ("⠙ T1", ("A", "100"), ("B", "/b")),
            ("T2", ("A", "100"), ("B", "/b")),
            ("T2", ("A", "100"), ("B", "/b")),
            ("T2", ("B", "101"), ("B", "/b")),
            ("T3", ("B", "101"), ("", None)),
            # A hook claims another thread before the change settles.
            ("T3", ("C", "102"), ("", None)),
            ("T3", ("C", "102"), ("", None)),
            # A newer claim of the same thread is decided again.
            ("T3", ("C", "103"), ("", None)),
        ])
        # The spinner changes nothing; each change is decided twice.
        self.assertEqual(evaluated, [0, 2, 3, 4, 5, 6, 7, 8])
        self.assertEqual(published, [(3, "B", "/b", "100", "%2"), (7, "", None, "102", "%2")])

        # An unclear decision, or one that flips, is not published.
        evaluated, published = self.watch_steps([
            ("T1", ("A", "100"), None),
            ("T1", ("A", "100"), ("B", "/b")),
            ("T2", ("A", "100"), ("B", "/b")),
            ("T2", ("A", "100"), ("C", "/c")),
            ("T2", ("A", "100"), None),
        ])
        self.assertEqual(evaluated, [0, 2, 3, 4])
        self.assertEqual(published, [])

        # Without tmux or a claim nothing is decided.
        evaluated, published = self.watch_steps([("T1", None, ("B", "/b")), ("T1", None, ("B", "/b"))])
        self.assertEqual((evaluated, published), ([], []))
        # A native client its node launcher left no claim has the empty one.
        evaluated, published = self.watch_steps([("T1", None, ("B", "/b")), ("T1", None, ("B", "/b"))], bootstrap=True)
        self.assertEqual((evaluated, published), ([0, 1], [(1, "B", "/b", "", "%2")]))

    def test_project_configs_follow_each_absolute_folder_to_the_root(self) -> None:
        self.assertEqual(self.recovery["project_configs"](["", "work", "/srv/a/../b/", "/"]),
                         ["/srv/b/.codex/config.toml", "/srv/.codex/config.toml", "/.codex/config.toml", "/.codex/config.toml"])

    def test_own_title_reads_only_the_pane_the_observer_started_in(self) -> None:
        calls: list[list[str]] = []
        self.recovery["run"] = lambda argv, limit=0, env=None: calls.append(argv) or "\u280b Fix the parser | demo".encode("utf-8")
        # The spinner folds away, so a working client does not try again.
        for pane, expected in (("%2", " Fix the parser | demo"), ("", None), ("2", None), ("%2;x", None)):
            calls.clear()
            with mock.patch.dict(os.environ, {"TMUX_PANE": pane}):
                self.assertEqual(self.recovery["own_title"](), expected, pane)
            self.assertEqual(calls, [["tmux", "display-message", "-p", "-t", pane, "#{pane_title}"]] if expected else [], pane)
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(self.recovery["own_title"]())

    def test_watch_shared_tries_an_undecided_or_unpublished_state_again(self) -> None:
        # Unclear, as when an inventory failed, the same state is tried after
        # 2, 4 and 8 seconds.
        evaluated, published = self.watch_steps([("T1", ("A", "100"), None)] * 16)
        self.assertEqual((evaluated, published), ([0, 2, 6, 14], []))
        # A publication the claim never followed is decided twice again.
        evaluated, published = self.watch_steps([("T1", ("A", "100"), ("B", "/b"))] * 12)
        self.assertEqual(evaluated, [0, 1, 3, 4, 8, 9])
        self.assertEqual([step for step, *_ in published], [1, 4, 9])

    def test_an_observer_ends_only_once_its_client_surely_did(self) -> None:
        # One ps that failed to fork or answered late, which on macOS reads
        # the start of the client, its owner and its command, tells nothing:
        # the observer goes on, and publishes what settles. Only a definite
        # answer ends it: no process left, another start under the PID, or a
        # process no Codex of this user.
        steps = [("T1", ("A", "100"), ("A", "/a")), ("T2", ("A", "100"), ("B", "/b")), ("T2", ("A", "100"), ("B", "/b")),
                 ("T2", ("A", "100"), ("B", "/b")), ("T2", ("B", "101"), ("B", "/b"))]
        # Each read fails once, at a poll of its own.
        failed = {"token": 1, "command": 3, "owner": 4}

        def observe(loop: str, end: dict[str, object]) -> tuple[list[int], list[tuple[object, ...]], list[int], list[int]]:
            state = {"step": 0}
            evaluated: list[int] = []
            published: list[tuple[object, ...]] = []
            watched: list[int] = []
            signalled: list[int] = []

            def read(kind: str, value: object) -> object:
                if state["step"] == failed.get(kind):
                    return None
                return end.get(kind, value) if state["step"] >= len(steps) else value

            def current() -> tuple[str, tuple[str, str], tuple[str, str]]:
                return steps[min(state["step"], len(steps) - 1)]

            def kill(pid: int, number: int) -> None:
                self.assertEqual((pid, number), (42, 0))
                signalled.append(state["step"])
                if state["step"] >= len(steps) and end.get("gone"):
                    raise ProcessLookupError()

            def sleep(_seconds: float) -> None:
                state["step"] += 1
                if state["step"] > len(steps):
                    raise Blocked()
            self.recovery.update({
                "process_start_token": lambda pid: read("token", "99"),
                "command_name": lambda pid: read("command", "codex"),
                "current_uid": lambda pid: read("owner", os.getuid()),
                "shared_client": lambda pid, token: (105, "%2") if loop == "title" else None,
                "read_observer_claim": lambda pid: current()[1],
                "watch_once": lambda pid, token, claim: watched.append(state["step"]) or claim[0],
                "run": lambda argv, limit=0, env=None: current()[0].encode("utf-8") if argv == ["tmux", "display-message", "-p", "-t", "%2", "#{pane_title}"] else None,
                "shared_target": lambda server, pane, claim, client: evaluated.append(state["step"]) or current()[2],
                "invoke_observed_hook": lambda pid, token, session, path, stamp, pane=None: published.append((state["step"], session, path, stamp, pane)),
                "time": mock.Mock(sleep=sleep, monotonic=lambda: float(state["step"])),
            })
            with mock.patch.object(os, "kill", side_effect=kill):
                try:
                    if loop == "title":
                        self.recovery["watch_shared"](42, "99")
                    else:
                        self.recovery["watch_loop"](42, "99")
                except Blocked:
                    self.fail("the observer outlived its client: %r" % (end,))
            return evaluated, published, watched, signalled

        for end in ({"gone": True, "token": None}, {"token": "reused"}, {"command": "bash"}, {"owner": os.getuid() + 1}):
            gone = [len(steps)] if end.get("gone") else []
            # The title observer of a bound client publishes the change it
            # decided twice, at the third poll, past each failed read.
            evaluated, published, watched, signalled = observe("title", end)
            self.assertEqual(evaluated, [0, 1, 2, 4], end)
            self.assertEqual(published, [(2, "B", "/b", "100", "%2")], end)
            self.assertEqual(signalled, [1] + gone, end)
            # The rollout observer polls every second until the end.
            evaluated, published, watched, signalled = observe("rollout", end)
            self.assertEqual(watched, list(range(len(steps))), end)
            self.assertEqual(signalled, [1] + gone, end)

    def test_observers_of_a_bound_client_follow_its_title(self) -> None:
        followed: list[tuple[int, str]] = []
        locks: list[tuple[int, str]] = []
        self.recovery.update({
            "watcher_live": lambda pid, token: True,
            "watcher_ended": lambda pid, token: False,
            "shared_client": lambda pid, token: (105, "%2") if pid == 42 else None,
            "watch_shared": lambda pid, token, bootstrap=False: followed.append((pid, token)),
            "observer_lock": lambda pid, kind="observer": locks.append((pid, kind)) or os.open(os.devnull, os.O_RDONLY),
            "strict_root_inventory": lambda pid, root: [],
            "read_observer_claim": lambda pid: ("A", "100"),
            "shared_target": lambda server, pane, claim, client: ("B", "/b") if (server, pane, claim, client) == (105, "%2", "A", 42) else None,
        })
        self.recovery["watch_loop"](42, "99")
        self.assertEqual(followed, [(42, "99")])
        self.assertEqual(locks, [(42, "shared-observer")])
        # A title observer that already runs keeps the client.
        self.recovery["observer_lock"] = lambda pid, kind="observer": None
        self.recovery["watch_loop"](42, "99")
        self.assertEqual(followed, [(42, "99")])

        verify_observation = self.recovery["verify_observation"]
        self.assertEqual(verify_observation("42", "99", "B"), "42")
        self.assertIsNone(verify_observation("42", "99", "A"))
        self.assertIsNone(verify_observation("42", "99", ""))
        # Without a mark the rollouts decide.
        self.assertEqual(verify_observation("43", "99", ""), "43")
        # A native client its node launcher left without a claim is weighed
        # as the empty claim, which only the empty epoch meets.
        self.recovery["read_observer_claim"] = lambda pid: None
        self.assertIsNone(verify_observation("42", "99", "B"))
        self.recovery["shared_target"] = lambda server, pane, claim, client: ("B", "/b") if claim == "" else None
        self.assertEqual(verify_observation("42", "99", "B"), "42")

    def test_a_shared_observation_publishes_to_the_bound_pane(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-recovery-invoke-") as temporary:
            support = Path(temporary)
            hook = support / "agent-lifecycle-hook.sh"
            hook.write_text('#!/bin/sh\n{ printf "%s\\n" "$*"; env | grep -E "^(TMUX_PANE|TESSERA_AGENT_OBSERVE[RD][A-Z_]*)=" | LC_ALL=C sort; cat; } > "${0%/*}/called"\n')
            hook.chmod(0o700)
            environment = {key: value for key, value in os.environ.items() if key != "TMUX_PANE" and not key.startswith("TESSERA_AGENT_OBSERVED")}
            environment["TESSERA_AGENT_RECOVERY_SUPPORT_DIR"] = str(support)
            with mock.patch.dict(os.environ, environment, clear=True):
                self.recovery["invoke_observed_hook"](42, "99", "B", "/b", "100", "%2")
                called = (support / "called").read_text().splitlines()
                self.assertEqual(called, ["codex SessionStart idle session-start", "TESSERA_AGENT_OBSERVED_PROCESS_START=99",
                                          "TESSERA_AGENT_OBSERVED_PROVIDER_PID=42", "TESSERA_AGENT_OBSERVED_SHARED=1",
                                          "TESSERA_AGENT_OBSERVED_TIMESTAMP_NS=100", "TESSERA_AGENT_OBSERVER=1", "TMUX_PANE=%2",
                                          '{"session_id":"B","transcript_path":"/b"}'])
                self.recovery["invoke_observed_hook"](42, "99", "", None, "100")
                called = (support / "called").read_text().splitlines()
                self.assertNotIn("TESSERA_AGENT_OBSERVED_SHARED=1", called)
                self.assertFalse(any(line.startswith("TMUX_PANE=") for line in called), called)
                # A binder publishes another event at the time the server ran
                # it, against the epoch it was given.
                self.recovery["invoke_observed_hook"](42, "99", "B", "/b", "", "%2", ("Stop", "idle", "turn-stopped"), "1234")
                called = (support / "called").read_text().splitlines()
                self.assertEqual(called, ["codex Stop idle turn-stopped", "TESSERA_AGENT_OBSERVED_EVENT_NS=1234",
                                          "TESSERA_AGENT_OBSERVED_PROCESS_START=99", "TESSERA_AGENT_OBSERVED_PROVIDER_PID=42",
                                          "TESSERA_AGENT_OBSERVED_REPLAY=1", "TESSERA_AGENT_OBSERVED_SHARED=1",
                                          "TESSERA_AGENT_OBSERVED_TIMESTAMP_NS=", "TESSERA_AGENT_OBSERVER=1", "TMUX_PANE=%2",
                                          '{"session_id":"B","transcript_path":"/b"}'])
            # An observation never passes on a replay it inherited.
            with mock.patch.dict(os.environ, dict(environment, TESSERA_AGENT_OBSERVED_REPLAY="1", TESSERA_AGENT_OBSERVED_EVENT_NS="1"), clear=True):
                self.recovery["invoke_observed_hook"](42, "99", "B", "/b", "100", "%2")
                called = (support / "called").read_text().splitlines()
                self.assertEqual(called[0], "codex SessionStart idle session-start")
                self.assertFalse(any(line.startswith(("TESSERA_AGENT_OBSERVED_REPLAY=", "TESSERA_AGENT_OBSERVED_EVENT_NS=")) for line in called), called)

    def test_watch_shared_root_starts_only_for_a_marked_client(self) -> None:
        watch_shared_root = self.recovery["watch_shared_root"]
        events: list[object] = []
        lock = os.open(os.devnull, os.O_RDONLY)
        self.recovery.update({
            "is_codex": lambda pid: pid in {42, 43},
            "process_start_token": lambda pid: "99",
            "shared_client": lambda pid, token: (105, "%2") if pid == 42 else None,
            "observer_lock": lambda pid, kind="observer": events.append(("lock", pid, kind)) or lock,
            "detach": lambda descriptor: events.append(("detach", descriptor)) or True,
            "watch_shared": lambda pid, token, bootstrap=False: events.append(("watch", pid, token)),
        })
        for argument in ("0", "42x", "", "43", "44"):
            watch_shared_root(argument)
        self.assertEqual(events, [])
        # Its lock is not the one an observer from before an upgrade holds.
        watch_shared_root("42")
        self.assertEqual(events, [("lock", 42, "shared-observer"), ("detach", lock), ("watch", 42, "99")])
        with self.assertRaises(OSError):
            os.close(lock)

        # A running observer holds the lock.
        events.clear()
        self.recovery["observer_lock"] = lambda pid, kind="observer": None
        watch_shared_root("42")
        self.assertEqual(events, [])

    def test_watch_loop_adopts_a_shared_thread_its_client_shows_before_any_hook(self) -> None:
        def run(steps: list[tuple[Optional[str], Optional[tuple[str, str]], Optional[tuple[int, str]]]],
                bootstrap: bool = False, published: Optional[str] = None) -> tuple[list[int], list[object]]:
            """One poll per step: the pane title, the claim and what adoption finds."""
            state = {"step": 0, "marked": False}
            tried: list[int] = []
            followed: list[object] = []

            def adopt(pid: int, token: str) -> Optional[tuple[int, str]]:
                tried.append(state["step"])
                return steps[state["step"]][2]

            def mark(pid: int, token: str, server: int, pane: str) -> bool:
                state["marked"] = (pid, token, server, pane) == (42, "99", 105, "%2")
                return True
            self.recovery.update({
                "watcher_live": lambda pid, token: (pid, token) == (42, "99") and state["step"] < len(steps),
                "watcher_ended": lambda pid, token: (pid, token) != (42, "99") or state["step"] >= len(steps),
                "shared_client": lambda pid, token: (105, "%2") if state["marked"] else None,
                "read_observer_claim": lambda pid: steps[state["step"]][1],
                "watch_once": lambda pid, token, claim: published,
                "own_title": lambda: steps[state["step"]][0],
                "adopt_shared": adopt,
                "mark_shared_client": mark,
                "observer_lock": lambda pid, kind="observer": os.open(os.devnull, os.O_RDONLY) if kind == "shared-observer" else None,
                "watch_shared": lambda pid, token, bootstrap=False: followed.append((state["step"], pid, token, bootstrap)),
                "time": mock.Mock(sleep=lambda seconds: state.__setitem__("step", state["step"] + 1), monotonic=lambda: float(state["step"])),
            })
            self.recovery["watch_loop"](42, "99", bootstrap)
            return tried, followed

        empty = ("", "100")
        # The same title is tried after 2, 4 and 8 seconds; a new one at once.
        tried, followed = run([("T1", empty, None)] * 16)
        self.assertEqual((tried, followed), ([0, 2, 6, 14], []))
        tried, followed = run([("T1", empty, None)] * 3 + [("T2", empty, None)] * 3 + [("T3", empty, None)])
        self.assertEqual((tried, followed), ([0, 2, 3, 5, 6], []))
        # An adopted client is followed by its title from then on.
        tried, followed = run([("T1", empty, None), ("T2", empty, (105, "%2")), ("T2", empty, None)])
        self.assertEqual((tried, followed), ([0, 1], [(1, 42, "99", False)]))
        # A node launcher left its native client no claim before the first
        # prompt; that client is the one a bootstrap observer follows.
        tried, followed = run([("T1", None, (105, "%2"))], bootstrap=True)
        self.assertEqual((tried, followed), ([0], [(0, 42, "99", True)]))
        # A client with a thread of its own, or no claim, adopts nothing.
        tried, followed = run([("T1", ("A", "100"), (105, "%2")), ("T2", None, (105, "%2"))])
        self.assertEqual((tried, followed), ([], []))
        # A publication of its own rollouts comes first.
        tried, followed = run([("T1", empty, (105, "%2"))], published="A")
        self.assertEqual((tried, followed), ([], []))

    def test_adopt_shared_needs_the_one_server_of_this_home_and_the_pane_alone_showing_its_thread(self) -> None:
        adopt_shared = self.recovery["adopt_shared"]
        session, other = self.SESSION, self.OTHER
        names = {session: "Fix the parser", other: "Profile the cache"}
        titles = [("%1", 100, "Profile the cache | demo"), ("%2", 200, "Fix the parser | demo"), ("%3", 300, "Fix the parser | demo")]
        self.install_shared_host(titles[:2], names)
        self.assertEqual(adopt_shared(202, "start-202"), (105, "%2"))
        self.assertEqual(adopt_shared(104, "start-104"), (105, "%1"))
        for label, pid, token in (("another start", 202, "start-1"), ("no pane client", 106, "start-106"), ("the server", 105, "start-105")):
            self.assertIsNone(adopt_shared(pid, token), label)
        for label, change in (
                ("a title of no thread", {"run": lambda argv, limit=0, env=None: b"%2\t200\tdemo\n" if argv[:3] == ["tmux", "list-panes", "-a"] else None}),
                ("two servers of this home", {"home_server": lambda pid: pid in {105, 106}}),
                ("a server of another home", {"client_home": lambda pid: pid != 105}),
                ("a server of another user", {"current_uid": lambda pid: os.getuid() + (pid == 105)}),
                ("a client that holds rollouts", {"linux_open_files_strict": lambda pid, root, limit=512: [("/safe/sessions/own.jsonl", (1, 3))],
                                                  "mac_open_files_strict": lambda pid, root: [("/safe/sessions/own.jsonl", (1, 3))]}),
                ("an exited client", {"is_codex": lambda pid: pid in {104, 105, 302}}),
                ("a client started again", {"process_start_token": lambda pid: "start-2" if pid == 202 else f"start-{pid}"}),
                ("no process table", {"process_table": lambda: None})):
            self.install_shared_host(titles[:2], names)
            saved = {key: self.recovery[key] for key in change}
            self.recovery.update(change)
            self.assertIsNone(adopt_shared(202, "start-202"), label)
            # Only the change refuses it.
            self.recovery.update(saved)
            self.assertEqual(adopt_shared(202, "start-202"), (105, "%2"), label)
        # Another pane shows the same thread.
        self.install_shared_host(titles, names)
        self.assertIsNone(adopt_shared(202, "start-202"))

    def test_main_prints_a_shared_binding_and_starts_a_shared_observer(self) -> None:
        pending: list[object] = []
        self.recovery["bind_shared"] = lambda server, session, later=None: pending.append(later) or (
            "%2 202 cmVm 1" if (server, session) == ("105", "root") else None)
        started: list[str] = []
        self.recovery["watch_shared_root"] = lambda pid: started.append(pid)
        for argv, expected in (
            (["recovery", "--bind-shared", "105", "root"], "%2 202 cmVm 1\n"),
            (["recovery", "--bind-shared", "105", "other"], ""),
            (["recovery", "--bind-shared", "105", "root", "Stop", "idle", "turn-stopped", "100"], "%2 202 cmVm 1\n"),
            (["recovery", "--bind-shared", "105", "root", "Stop", "idle"], ""),
            (["recovery", "--bind-shared", "105"], ""),
            (["recovery", "--watch-shared", "42"], ""),
            (["recovery", "--watch-shared", "42", "extra"], ""),
        ):
            output = io.StringIO()
            with contextlib.redirect_stdout(output), mock.patch.object(sys, "argv", argv):
                self.recovery["main"]()
            self.assertEqual(output.getvalue(), expected, argv)
        self.assertEqual(started, ["42"])
        self.assertEqual(pending, [None, None, ("Stop", "idle", "turn-stopped", "100")])

    def runtime_home(self) -> Path:
        home = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(home)], check=False))
        patcher = mock.patch.dict(os.environ, {"HOME": str(home)})
        patcher.start()
        self.addCleanup(patcher.stop)
        (home / ".config/tessera/agent-runtime-state").mkdir(parents=True, mode=0o700)
        return home / ".config/tessera/agent-runtime-state"

    def test_an_unbound_root_event_leaves_one_binder_with_the_newest_event(self) -> None:
        runtime = self.runtime_home()
        session = self.SESSION
        self.install_shared_host([("%1", 100, "demo"), ("%2", 200, "demo")], {})
        detached: list[int] = []
        self.recovery["detach"] = lambda lock: detached.append(lock) or os.close(lock) or False
        record_pending, read_pending = self.recovery["record_pending"], self.recovery["read_pending"]
        self.assertIsNone(self.recovery["bind_shared"]("105", session, ("UserPromptSubmit", "working", "agent-turn", "200")))
        self.assertEqual(len(detached), 1)
        self.assertEqual(read_pending(105, "start-105", session), ("UserPromptSubmit", "working", "agent-turn", "200"))
        # One thread a record, named after its server so the hook prunes it.
        self.assertEqual([path.name.split(".")[:2] for path in runtime.iterdir()], [["105", "shared-pending"]])
        # An older event never replaces a newer one; a newer one does.
        self.assertTrue(record_pending(105, "start-105", session, ("SessionStart", "idle", "session-start", "100")))
        self.assertEqual(read_pending(105, "start-105", session)[0], "UserPromptSubmit")
        self.assertTrue(record_pending(105, "start-105", session, ("Stop", "idle", "turn-stopped", "300")))
        self.assertEqual(read_pending(105, "start-105", session), ("Stop", "idle", "turn-stopped", "300"))
        # Another server process, another thread or a malformed record reads as none.
        self.assertIsNone(read_pending(105, "start-999", session))
        self.assertIsNone(read_pending(105, "start-105", self.OTHER))
        # A child callback, an ending or a malformed event starts no binder.
        for event in (("SessionEnd", "unavailable", "session-ended", "400"), ("Stop", "idle", "", "400"),
                      ("Stop", "unknown", "turn-stopped", "400"), ("Stop", "idle", "turn-stopped", "4x"),
                      ("Stop", "idle", "turn-stopped", "0400")):
            self.recovery["bind_later"](105, session, event, {"server": True, "tmux": True}, None)
        self.assertEqual(len(detached), 1)
        # A bound event needs none.
        self.install_shared_host([("%2", 200, "Fix the parser | demo")], {session: "Fix the parser"})
        self.assertTrue(self.recovery["bind_shared"]("105", session, ("Stop", "idle", "turn-stopped", "500")).startswith("%2 202 "))
        self.assertEqual(len(detached), 1)
        # A server bound_pane never binds, as one listening on another
        # socket, gets neither a record nor a binder.
        self.install_shared_host([("%1", 100, "demo")], {}, arguments={105: ["codex", "app-server", "--listen", "ws://127.0.0.1:9"]})
        self.assertIsNone(self.recovery["bind_shared"]("105", self.OTHER, ("Stop", "idle", "turn-stopped", "600")))
        self.assertEqual(len(detached), 1)
        self.assertIsNone(read_pending(105, "start-105", self.OTHER))

    def test_a_record_is_replaced_only_under_its_lock(self) -> None:
        runtime = self.runtime_home()
        session = self.SESSION
        self.recovery.update({
            "is_codex": lambda pid: True,
            "home_server": lambda pid: True,
            "process_start_token": lambda pid: f"start-{pid}",
        })
        detached: list[int] = []
        self.recovery["detach"] = lambda lock: detached.append(lock) or os.close(lock) or False
        self.recovery["PENDING_WAIT"] = 0.05
        record_pending, read_pending = self.recovery["record_pending"], self.recovery["read_pending"]
        guard = runtime / f"105.shared-pending.{self.recovery['thread_key'](session)}.lock"
        with open(guard, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            # A binder letting its lock go holds the record: a hook waits,
            # briefly, and then neither records nor starts a binder.
            self.assertFalse(record_pending(105, "start-105", session, ("Stop", "idle", "turn-stopped", "100")))
            self.recovery["bind_later"](105, session, ("Stop", "idle", "turn-stopped", "100"), {"server": True, "tmux": True}, None)
            self.assertEqual(detached, [])
        self.assertIsNone(read_pending(105, "start-105", session))
        self.recovery["bind_later"](105, session, ("Stop", "idle", "turn-stopped", "100"), {"server": True, "tmux": True}, None)
        self.assertEqual(len(detached), 1)
        self.assertEqual(read_pending(105, "start-105", session), ("Stop", "idle", "turn-stopped", "100"))

    def test_a_hook_hands_an_unbound_event_to_a_binder_by_its_deadline(self) -> None:
        runtime = self.runtime_home()
        session = self.SESSION
        observer_lock = self.recovery["observer_lock"]
        self.install_shared_host([("%1", 100, "demo")], {})
        self.recovery["observer_lock"] = observer_lock
        detached: list[int] = []
        self.recovery["detach"] = lambda lock: detached.append(lock) or os.close(lock) or False
        checked: list[str] = []
        for name in ("is_codex", "home_server"):
            self.recovery[name] = lambda pid, name=name, check=self.recovery[name]: checked.append(name) or check(pid)
        deadlines: dict[str, list[object]] = {"token": [], "tmux": []}
        self.recovery["process_start_token"] = lambda pid: deadlines["token"].append(self.recovery["RUN_DEADLINE"]) or f"start-{pid}"
        listed = self.recovery["run"]
        self.recovery["run"] = lambda argv, limit=0, env=None: deadlines["tmux"].append(self.recovery["RUN_DEADLINE"]) or listed(argv, limit, env)
        clock, key = self.recovery["time"], self.recovery["thread_key"](session)
        event = ("Stop", "idle", "turn-stopped", "100")
        # A binder holds the record lock: the hook waits for it only until
        # its own deadline, and binding left the hand-off its share of it.
        self.recovery["PENDING_WAIT"] = 5
        with open(runtime / f"105.shared-pending.{key}.lock", "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            started = clock.monotonic()
            self.assertIsNone(self.recovery["bind_shared"]("105", session, event))
            elapsed = clock.monotonic() - started
        self.assertLess(elapsed, 0.75 + 0.1)
        self.assertEqual(detached, [])
        self.assertIsNone(self.recovery["read_pending"](105, "start-105", session))
        self.assertTrue(deadlines["tmux"] and all(started < value <= started + 0.75 - 0.15 + 0.01 for value in deadlines["tmux"]), deadlines)
        self.assertEqual(len(deadlines["token"]), 1)
        self.assertTrue(started + 0.75 - 0.01 < deadlines["token"][0] <= started + 0.75 + 0.01, deadlines)
        # What binding proved of the server is not asked again.
        self.assertEqual(checked, ["is_codex", "home_server"])
        self.assertIsNone(self.recovery["RUN_DEADLINE"])
        # Free, the record and a binder follow at once.
        self.assertIsNone(self.recovery["bind_shared"]("105", session, event))
        self.assertEqual(len(detached), 1)
        self.assertEqual(self.recovery["read_pending"](105, "start-105", session), event)

    def test_no_binder_starts_for_a_thread_none_could_bind(self) -> None:
        self.runtime_home()
        session, subagent = self.SESSION, self.SUBAGENT
        fresh = "019c6e50-e55b-73d1-bc92-3e3c1bcc0022"
        event = ("UserPromptSubmit", "working", "agent-turn", "100")
        clock = self.recovery["time"]

        def started(thread: str, tmux: str = "up") -> tuple[bool, int]:
            """Whether a binder started, and how often tmux listed panes."""
            record = self.install_shared_host([("%1", 100, "demo")], {}, hosted=(subagent,))
            detached: list[int] = []
            self.recovery["detach"] = lambda lock: detached.append(lock) or os.close(lock) or False
            listed = self.recovery["run"]

            def run(argv: list[str], limit: int = 0, env: object = None) -> Optional[bytes]:
                if tmux in ("absent", "unstarted"):
                    record["tmux"].append(argv)
                    self.recovery["RUN_UNSTARTED"] = tmux == "unstarted"
                    return None
                if tmux == "slow":
                    while clock.monotonic() <= self.recovery["RUN_DEADLINE"]:
                        clock.sleep(0.01)
                    return None
                return listed(argv, limit, env)
            self.recovery["run"] = run
            self.assertIsNone(self.recovery["bind_shared"]("105", thread, event))
            return len(detached) == 1, sum(argv[:2] == ["tmux", "list-panes"] for argv in record["tmux"])
        # A root, and a thread the server holds no rollout of yet, as a new
        # one, get a binder where tmux lists panes.
        self.assertTrue(started(session)[0])
        self.assertTrue(started(fresh)[0])
        # A thread the server holds as a subagent or a helper never binds,
        # so tmux is not even asked.
        self.assertEqual(started(subagent), (False, 0))
        # Without a tmux server, as on plain SSH or mosh, none binds; tmux
        # is asked once, by bound_pane or for a new thread.
        for thread in (session, fresh):
            self.assertEqual(started(thread, "absent"), (False, 1), thread)
        # A tmux that could not start, as on a failed fork, decides nothing.
        for thread in (session, fresh):
            self.assertEqual(started(thread, "unstarted"), (True, 1), thread)
        # A tmux that answers only past the deadline decides nothing.
        self.recovery["SHARED_DEADLINE"], self.recovery["SHARED_HANDOFF"] = 0.3, 0.1
        for thread in (session, fresh):
            self.assertTrue(started(thread, "slow")[0], thread)

    def test_a_command_that_could_not_start_is_told_from_one_that_answered(self) -> None:
        run = self.recovery["run"]
        with tempfile.TemporaryDirectory() as directory:
            command = os.path.join(directory, "tmux")
            with open(command, "w") as handle:
                handle.write("#!/bin/sh\nexit 1\n")
            os.chmod(command, 0o600)
            self.assertIsNone(run([command]))
            self.assertTrue(self.recovery["RUN_UNSTARTED"], "present but not runnable")
            for argv in ([os.path.join(directory, "missing")], [command]):
                if argv == [command]:
                    os.chmod(command, 0o700)
                self.assertIsNone(run(argv))
                self.assertFalse(self.recovery["RUN_UNSTARTED"], argv)
            self.assertIsNone(self.recovery["tmux_listed"](None, self.recovery["time"].monotonic() - 1))

    def test_a_binder_leaves_no_files_once_nothing_is_pending(self) -> None:
        runtime = self.runtime_home()
        session = self.SESSION
        start = 1_800_000_000_000_000_000
        observer_lock = self.recovery["observer_lock"]
        clocks = self.recovery["time"]
        for label, bound in (("published", lambda now: self.BOUND), ("expired", lambda now: None)):
            clock, claims, published, observed, attempts = [0.0], {}, [], [], []
            self.install_binder(clock, claims, published, observed, attempts, bound)
            self.recovery["observer_lock"] = observer_lock
            # The hook detaches the binder, which runs here.
            self.recovery["detach"] = lambda lock: True
            with mock.patch.object(clocks, "sleep", side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                    mock.patch.object(clocks, "monotonic", side_effect=lambda: clock[0]), \
                    mock.patch.object(clocks, "time_ns", side_effect=lambda: start + int(clock[0] * 1000000000)), \
                    mock.patch.object(os, "nice") as nice:
                self.recovery["bind_later"](105, session, ("Stop", "idle", "turn-stopped", str(start - 5000000000)),
                                            {"server": True, "tmux": True}, None)
            # The hooks it runs hold the locks a native hook waits for, so
            # it keeps their priority.
            nice.assert_not_called()
            self.assertEqual(len(published), 1 if label == "published" else 0, label)
            self.assertEqual([path.name for path in runtime.iterdir() if path.name.startswith("105.")], [], label)
        # A record a binder cannot read, as of a server started again under
        # the same PID, keeps the locks of its thread.
        key = self.recovery["thread_key"](session)
        (runtime / f"105.shared-pending.{key}").write_text(f"start-999\n{session}\nStop\nidle\nturn-stopped\n100\n", encoding="ascii")
        binder = observer_lock(105, "shared-binder." + key)
        self.assertIsNone(self.recovery["release_binder"](105, "start-105", session, binder))
        self.assertEqual(sorted(path.name for path in runtime.iterdir() if path.name.startswith("105.")),
                         sorted([f"105.shared-pending.{key}", f"105.shared-pending.{key}.lock", f"105.shared-binder.{key}.lock"]))

    def test_a_lock_taken_on_a_file_since_removed_is_taken_again(self) -> None:
        runtime = self.runtime_home()
        observer_lock = self.recovery["observer_lock"]
        path = runtime / "105.shared-pending.x.lock"
        holder = observer_lock(105, "shared-pending.x")
        taken: list[Optional[int]] = []
        waiter = threading.Thread(target=lambda: taken.append(observer_lock(105, "shared-pending.x", 5)))
        waiter.start()
        # The hook opened the file and waits on it; the binder removes it
        # while it holds it, then lets it go.
        time.sleep(0.2)
        os.unlink(path)
        os.close(holder)
        waiter.join(5)
        self.assertTrue(taken and taken[0] is not None, taken)
        self.assertEqual(os.fstat(taken[0]).st_ino, path.stat().st_ino)
        # Each holder excludes the next, on the file there now.
        self.assertIsNone(observer_lock(105, "shared-pending.x"))
        os.close(taken[0])

    def test_a_binder_lets_its_lock_go_only_under_the_record_lock(self) -> None:
        runtime = self.runtime_home()
        session = self.SESSION
        key = self.recovery["thread_key"](session)
        observer_lock = self.recovery["observer_lock"]
        self.recovery["PENDING_WAIT"], self.recovery["SHARED_LATER_DEADLINE"] = 0.05, 0.2
        binder = observer_lock(105, "shared-binder." + key)
        clock = self.recovery["time"]
        with open(runtime / f"105.shared-pending.{key}.lock", "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            # A hook may be recording an event that would then find no
            # binder: the binder keeps its lock and tries again later.
            self.assertEqual(self.recovery["release_binder"](105, "start-105", session, binder), binder)
            self.assertIsNone(observer_lock(105, "shared-binder." + key))
            # One whose server ended waits longer, then lets it go: no hook
            # of that server records more.
            started = clock.monotonic()
            self.assertIsNone(self.recovery["release_binder"](105, "start-105", session, binder, final=True))
            self.assertGreaterEqual(clock.monotonic() - started, 0.2)
        again = observer_lock(105, "shared-binder." + key)
        self.assertIsNotNone(again)
        os.close(again)

    def test_pane_titles_change_only_with_what_a_title_shows(self) -> None:
        outputs: list[str] = []
        self.recovery["run"] = lambda argv, limit=0, env=None: outputs[-1].encode("utf-8")
        pane_titles = self.recovery["pane_titles"]

        def key(text: str) -> bytes:
            outputs.append(text)
            return pane_titles()

        working = key("%1\t⠋ Fix the parser | demo\n%2\tdemo\n")
        # The spinner turning, in braille or as GNU screen shows it, and the
        # action prefix blinking show no other thread.
        self.assertEqual(key("%1\t⠙ Fix the parser | demo\n%2\tdemo\n"), working)
        self.assertEqual(key("%1\t| Fix the parser | demo\n%2\tdemo\n"), key("%1\t/ Fix the parser | demo\n%2\tdemo\n"))
        self.assertEqual(key("%1\t[ . ] Action Required | demo\n"), key("%1\t[ ! ] Action Required | demo\n"))
        # A name showing, or moving to another pane, does.
        self.assertNotEqual(key("%1\t⠋ demo\n%2\tdemo\n"), working)
        self.assertNotEqual(key("%2\t⠋ Fix the parser | demo\n%1\tdemo\n"), working)
        self.recovery["run"] = lambda argv, limit=0, env=None: None
        self.assertIsNone(pane_titles())

    def install_binder(self, clock: list[float], claims: dict[int, str], published: list[object],
                       observed: list[object], attempts: list[float], bound) -> None:
        def invoke(pid, token, thread, path, stamp, pane=None, event=None, event_stamp=None):
            published.append((pid, thread, path, stamp, pane, event, event_stamp))
            # The delivery takes the event against the epoch it was given.
            if claims.get(pid, "") == stamp:
                claims[pid] = event_stamp

        self.recovery.update({
            "process_start_token": lambda pid: f"start-{pid}",
            "is_codex": lambda pid: True,
            "pane_titles": lambda: b"a",
            "bound_pane": lambda server, thread, deadline: attempts.append(clock[0]) or bound(clock[0]),
            "client_epoch": lambda pid: claims.get(pid, ""),
            "invoke_observed_hook": invoke,
            "observer_lock": lambda pid, kind="observer", wait=0: os.open(os.devnull, os.O_RDONLY),
            "watch_shared": lambda pid, token, bootstrap=False: observed.append((pid, token, bootstrap)),
        })

    def run_binder(self, clock: list[float], start: int, session: str, tick=None, wall=None) -> object:
        # Each sleep advances both clocks: monotonic seconds, and the wall
        # clock hook stamps are taken from, which wall can set apart. tick
        # sees each second pass, as hooks on a clock of their own do.
        clocks = self.recovery["time"]

        def sleep(seconds: float) -> None:
            clock[0] += seconds
            if tick is not None:
                tick(clock[0])
            if clock[0] > 7200:
                raise Blocked()

        def time_ns() -> int:
            return start + int((clock[0] if wall is None else wall(clock[0])) * 1000000000)

        with mock.patch.object(clocks, "sleep", side_effect=sleep), \
                mock.patch.object(clocks, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(clocks, "time_ns", side_effect=time_ns):
            try:
                return self.recovery["wait_for_binding"](105, "start-105", session, os.open(os.devnull, os.O_RDONLY))
            except Blocked:
                self.fail("the binder still waited two hours on")

    BOUND = ("%2", 202, "start-202", "/safe/rollout.jsonl", 1)

    def test_a_binder_publishes_the_newest_event_at_its_time_once_a_pane_shows_the_thread(self) -> None:
        self.runtime_home()
        session = self.SESSION
        start = 1_800_000_000_000_000_000
        stamp = lambda seconds: str(start + int(seconds * 1000000000))
        record_pending, read_pending = self.recovery["record_pending"], self.recovery["read_pending"]
        first = ("UserPromptSubmit", "working", "agent-turn", stamp(-5))
        clock, claims, published, observed, attempts = [0.0], {}, [], [], []
        self.install_binder(clock, claims, published, observed, attempts, lambda now: self.BOUND if now >= 3 else None)
        self.assertTrue(record_pending(105, "start-105", session, first))
        self.assertIsNone(self.run_binder(clock, start, session))
        # The title did not change: it was tried again two seconds later.
        self.assertEqual(attempts, [1.0, 3.0])
        # Published at the time the server ran it, against the empty epoch;
        # then the binder observes and the record goes.
        self.assertEqual(published, [(202, session, "/safe/rollout.jsonl", "", "%2", first[:3], first[3])])
        self.assertEqual(observed, [(202, "start-202", True)])
        self.assertIsNone(read_pending(105, "start-105", session))

        # A newer event recorded during the replay is published next,
        # against the claim the first made.
        later = ("Stop", "idle", "turn-stopped", stamp(1))
        clock[0], published[:], observed[:], attempts[:] = 0.0, [], [], []
        claims.clear()
        self.assertTrue(record_pending(105, "start-105", session, first))
        invoke = self.recovery["invoke_observed_hook"]

        def invoke_during_stop(*arguments, **options):
            invoke(*arguments, **options)
            if len(published) == 1:
                record_pending(105, "start-105", session, later)

        self.recovery["invoke_observed_hook"] = invoke_during_stop
        self.recovery["bound_pane"] = lambda server, thread, deadline: attempts.append(clock[0]) or self.BOUND
        self.assertIsNone(self.run_binder(clock, start, session))
        self.assertEqual([entry[3:] for entry in published], [("", "%2", first[:3], first[3]), (first[3], "%2", later[:3], later[3])])
        self.assertEqual(claims, {202: later[3]})
        self.assertEqual(observed, [(202, "start-202", True)])
        self.assertIsNone(read_pending(105, "start-105", session))

        # An event recorded after the last replay, before the binder lets
        # its lock go, keeps the binder: it publishes that one too.
        clock[0], published[:], observed[:], attempts[:] = 0.0, [], [], []
        claims.clear()
        self.recovery["invoke_observed_hook"] = invoke
        self.assertTrue(record_pending(105, "start-105", session, first))
        handed: list[str] = []

        def observer_lock(pid, kind="observer", wait=0):
            if kind == "shared-observer" and not handed:
                handed.append(kind)
                record_pending(105, "start-105", session, later)
            return os.open(os.devnull, os.O_RDONLY)

        self.recovery["observer_lock"] = observer_lock
        self.assertIsNone(self.run_binder(clock, start, session))
        self.assertEqual(attempts, [1.0, 2.0])
        self.assertEqual([entry[3:] for entry in published], [("", "%2", first[:3], first[3]), (first[3], "%2", later[:3], later[3])])
        self.assertEqual(observed, [(202, "start-202", True)])
        self.assertIsNone(read_pending(105, "start-105", session))

    def test_a_binder_publishes_only_past_the_claim_a_client_holds(self) -> None:
        self.runtime_home()
        session = self.SESSION
        start = 1_800_000_000_000_000_000
        stamp = lambda seconds: str(start + int(seconds * 1000000000))
        record_pending, read_pending = self.recovery["record_pending"], self.recovery["read_pending"]
        event = ("UserPromptSubmit", "working", "agent-turn", stamp(-5))
        for label, claim, replayed in (
                # A native hook published after the event: its claim stays.
                ("newer claim", stamp(-1), False),
                # After /new the client last published another thread, before
                # this event: the thread it shows now takes it, checked
                # against that claim under the delivery lock.
                ("older claim of another thread", stamp(-30), True)):
            clock, claims, published, observed, attempts = [0.0], {202: claim}, [], [], []
            self.install_binder(clock, claims, published, observed, attempts, lambda now: self.BOUND)
            self.assertTrue(record_pending(105, "start-105", session, event))
            self.assertIsNone(self.run_binder(clock, start, session))
            self.assertEqual([entry[3:] for entry in published], [(claim, "%2", event[:3], event[3])] if replayed else [], label)
            self.assertEqual(observed, [(202, "start-202", True)], label)
            self.assertIsNone(read_pending(105, "start-105", session), label)

        # A replay the delivery turned away, as when the title was unclear to
        # the hook, is tried again later rather than given up.
        clock, claims, published, observed, attempts = [0.0], {}, [], [], []
        self.install_binder(clock, claims, published, observed, attempts, lambda now: self.BOUND)
        invoke = self.recovery["invoke_observed_hook"]
        self.recovery["invoke_observed_hook"] = lambda *arguments, **options: published.append(None) if not published else invoke(*arguments, **options)
        self.assertTrue(record_pending(105, "start-105", session, event))
        self.assertIsNone(self.run_binder(clock, start, session))
        self.assertEqual(attempts, [1.0, 3.0])
        self.assertEqual(claims, {202: event[3]})
        self.assertEqual(observed, [(202, "start-202", True)])

        # A claim that cannot be read is never published past.
        clock, claims, published, observed, attempts = [0.0], {}, [], [], []
        self.install_binder(clock, claims, published, observed, attempts, lambda now: self.BOUND)
        self.recovery["client_epoch"] = lambda pid: None
        self.assertTrue(record_pending(105, "start-105", session, event))
        self.assertIsNone(self.run_binder(clock, start, session))
        self.assertEqual((published, observed), ([], []))
        self.assertIsNone(read_pending(105, "start-105", session))

    def test_a_binder_waits_out_the_window_of_the_newest_event(self) -> None:
        self.runtime_home()
        session = self.SESSION
        start = 1_800_000_000_000_000_000
        stamp = lambda seconds: str(start + int(seconds * 1000000000))
        record_pending, read_pending = self.recovery["record_pending"], self.recovery["read_pending"]
        clock, claims, published, observed, attempts = [0.0], {}, [], [], []
        self.install_binder(clock, claims, published, observed, attempts, lambda now: None)
        self.assertTrue(record_pending(105, "start-105", session, ("UserPromptSubmit", "working", "agent-turn", stamp(-5))))
        self.assertIsNone(self.run_binder(clock, start, session))
        # An unchanged title is tried again less often, up to every eight
        # seconds, until a minute after the event; the record then goes.
        self.assertEqual(attempts, [1.0, 3.0, 7.0, 15.0, 23.0, 31.0, 39.0, 47.0, 55.0])
        self.assertEqual(clock[0], 56.0)
        self.assertIsNone(read_pending(105, "start-105", session))

        # A later event extends the window from its own time.
        clock[0], attempts[:] = 0.0, []
        self.assertTrue(record_pending(105, "start-105", session, ("UserPromptSubmit", "working", "agent-turn", stamp(-5))))
        def stop_late(server, thread, deadline):
            attempts.append(clock[0])
            if clock[0] == 47.0:
                self.assertTrue(record_pending(105, "start-105", session, ("Stop", "idle", "turn-stopped", stamp(47))))

        self.recovery["bound_pane"] = stop_late
        self.assertIsNone(self.run_binder(clock, start, session))
        self.assertEqual(attempts, [1.0, 3.0, 7.0, 15.0, 23.0, 31.0, 39.0, 47.0, 55.0, 63.0, 71.0, 79.0, 87.0, 95.0, 103.0])
        self.assertEqual(clock[0], 108.0)
        self.assertIsNone(read_pending(105, "start-105", session))

        # Events that keep coming, on a clock of their own, as from a thread
        # no pane shows running tools for a quarter of an hour, keep a binder
        # trying at its full rate only up to its ceiling: past it, every
        # thirty seconds at most, a new event or not, until the window of
        # the newest ends; no record stays behind.
        clock[0], attempts[:] = 0.0, []
        self.recovery["bound_pane"] = lambda server, thread, deadline: attempts.append(clock[0]) or None
        self.assertTrue(record_pending(105, "start-105", session, ("UserPromptSubmit", "working", "agent-turn", stamp(0))))

        def tool_calls(now: float) -> None:
            if now % 5 == 0 and now <= 900:
                self.assertTrue(record_pending(105, "start-105", session, ("PostToolUse", "working", "agent-turn", stamp(now))))

        self.assertIsNone(self.run_binder(clock, start, session, tick=tool_calls))
        self.assertEqual([at for at in attempts if at < 300], [1.0, 3.0, 7.0] + [15.0 + 8 * step for step in range(36)])
        late = [at for at in attempts if at >= 300]
        self.assertLessEqual(len(late), (clock[0] - 300) // 30 + 1, late)
        self.assertEqual(late, [303.0 + 30 * step for step in range(22)])
        self.assertEqual(clock[0], 961.0)
        self.assertIsNone(read_pending(105, "start-105", session))
        self.assertEqual(published, [])

        # The Stop a hook records after the last look before the ceiling
        # found this binder and started none: the binder tries it at its
        # slower rate, and publishes it once a pane shows the thread.
        clock[0], attempts[:] = 0.0, []
        self.assertTrue(record_pending(105, "start-105", session, ("UserPromptSubmit", "working", "agent-turn", stamp(0))))
        stop = ("Stop", "idle", "turn-stopped", stamp(299))

        def titles() -> bytes:
            if clock[0] <= 299:
                self.assertTrue(record_pending(105, "start-105", session, stop if clock[0] == 299 else ("PostToolUse", "working", "agent-turn", stamp(clock[0]))))
            return b"a"

        self.recovery["pane_titles"] = titles
        self.recovery["bound_pane"] = lambda server, thread, deadline: attempts.append(clock[0]) or (self.BOUND if clock[0] >= 300 else None)
        self.assertIsNone(self.run_binder(clock, start, session))
        self.assertEqual(attempts[-2:], [295.0, 303.0])
        self.assertEqual([entry[5:] for entry in published], [(stop[:3], stop[3])])
        self.assertEqual(observed, [(202, "start-202", True)])
        self.assertIsNone(read_pending(105, "start-105", session))

    def test_a_binder_ends_only_once_its_server_surely_did(self) -> None:
        self.runtime_home()
        session = self.SESSION
        start = 1_800_000_000_000_000_000
        stamp = lambda seconds: str(start + int(seconds * 1000000000))
        record_pending, read_pending = self.recovery["record_pending"], self.recovery["read_pending"]
        event = ("Stop", "idle", "turn-stopped", stamp(-5))
        # A ps that failed to fork or answered late, which on macOS reads the
        # start of the server and its command, tells nothing: the binder
        # goes on and publishes once a pane shows the thread. So does a PID
        # the binder may not signal.
        for alive in (None, PermissionError()):
            clock, claims, published, observed, attempts = [0.0], {}, [], [], []
            self.install_binder(clock, claims, published, observed, attempts, lambda now: self.BOUND if now >= 3 else None)
            reads: list[float] = []
            self.recovery["process_start_token"] = lambda pid: reads.append(clock[0]) or (None if len(reads) % 2 else f"start-{pid}")
            self.recovery["is_codex"] = lambda pid: False
            self.assertTrue(record_pending(105, "start-105", session, event))
            with mock.patch.object(os, "kill", side_effect=[alive] * 2) as kill:
                self.assertIsNone(self.run_binder(clock, start, session))
            self.assertEqual(kill.call_args_list, [mock.call(105, 0)] * 2, alive)
            self.assertEqual(attempts, [1.0, 3.0], alive)
            self.assertEqual([entry[5:] for entry in published], [(event[:3], event[3])], alive)
            self.assertEqual(observed, [(202, "start-202", True)], alive)
            self.assertEqual(clock[0], 3.0, alive)
            self.assertIsNone(read_pending(105, "start-105", session), alive)

        # A start that was read and differs, as of a server that restarted
        # under the PID, or no process left, ends the wait with nothing
        # published.
        for token, alive in (("restarted", None), (None, ProcessLookupError())):
            clock, claims, published, observed, attempts = [0.0], {}, [], [], []
            self.install_binder(clock, claims, published, observed, attempts, lambda now: self.BOUND)
            self.recovery["process_start_token"] = lambda pid, token=token: token
            self.assertTrue(record_pending(105, "start-105", session, event))
            with mock.patch.object(os, "kill", side_effect=[alive]):
                self.assertIsNone(self.run_binder(clock, start, session))
            self.assertEqual((clock[0], attempts, published, observed), (1.0, [], [], []), token)

    def test_a_hook_that_could_not_read_the_server_start_loses_no_event(self) -> None:
        self.runtime_home()
        session = self.SESSION
        key = self.recovery["thread_key"](session)
        read_pending, observer_lock = self.recovery["read_pending"], self.recovery["observer_lock"]
        event = ("Stop", "idle", "turn-stopped", "100")
        clock = self.recovery["time"]
        self.recovery["PENDING_WAIT"] = 0.05
        listed: list[object] = []
        self.recovery["shared_panes"] = lambda: listed.append(self.recovery["RUN_DEADLINE"]) or None
        for label, child, found, held in (
                # The hook forks a child and returns at once.
                ("hook", False, {"server": True, "tmux": True}, False),
                # The child reads the start with no deadline, records the
                # event and becomes the binder.
                ("child", True, {"server": True, "tmux": True}, False),
                # A binder there takes the event from the record.
                ("binder there", True, {"server": True, "tmux": True}, True),
                # tmux, not asked by the hook, answers the child in its own
                # time: no tmux server runs, so none could bind.
                ("no tmux", True, {"server": True}, False)):
            reads: list[object] = []
            forks: list[object] = []
            binders: list[tuple[int, str, str]] = []
            self.recovery["process_start_token"] = lambda pid: reads.append(self.recovery["RUN_DEADLINE"]) or (f"start-{pid}" if len(reads) > 1 else None)
            self.recovery["detach"] = lambda lock: forks.append(lock) or child
            self.recovery["wait_for_binding"] = lambda server, token, thread, lock: binders.append((server, token, thread)) or os.close(lock)
            listed[:] = []
            binder = observer_lock(105, "shared-binder." + key) if held else None
            recorded = "tmux" in found
            deadline = clock.monotonic() + 0.6
            self.recovery["RUN_DEADLINE"] = deadline
            self.recovery["bind_later"](105, session, event, found, deadline)
            self.recovery["RUN_DEADLINE"] = None
            if binder is not None:
                os.close(binder)
            self.assertEqual(forks, [None], label)
            self.assertEqual(reads[:1], [deadline], label)
            if not child:
                self.assertEqual((len(reads), binders, read_pending(105, "start-105", session)), (1, [], None), label)
                continue
            self.assertEqual(reads[1:], [None], label)
            self.assertEqual(listed, [] if recorded else [None], label)
            self.assertEqual(read_pending(105, "start-105", session), event if recorded else None, label)
            self.assertEqual(binders, [(105, "start-105", session)] if recorded and not held else [], label)
            if recorded:
                os.unlink(Path(os.environ["HOME"]) / f".config/tessera/agent-runtime-state/105.shared-pending.{key}")

    def test_a_server_the_hook_could_not_tell_still_gets_its_event(self) -> None:
        self.runtime_home()
        session = self.SESSION
        event = ("Stop", "idle", "turn-stopped", "100")
        read_pending, clocks = self.recovery["read_pending"], self.recovery["time"]
        # One ps on the server failed in the hook: bound_pane could not tell
        # it, and the hook hands the event to a child at once.
        self.install_shared_host([("%1", 100, "demo")], {})
        forks: list[object] = []
        self.recovery["detach"] = lambda lock: forks.append(lock) or False
        self.recovery["is_codex"] = lambda pid: None if pid == 105 else pid in {104, 202, 302}
        self.assertIsNone(self.recovery["bind_shared"]("105", session, event))
        self.assertEqual(forks, [None])
        self.assertIsNone(read_pending(105, "start-105", session))
        # The child asks again with no deadline: a Codex of this home gets
        # the record and a binder; a thread it holds as a helper, or a server
        # that surely is no Codex, gets neither.
        path = Path(os.environ["HOME"]) / f".config/tessera/agent-runtime-state/105.shared-pending.{self.recovery['thread_key'](session)}"
        for label, answers, hosted, recorded in (("a Codex of this home", [None, True], {}, True),
                                                 ("a helper thread", [True], {session: ((), ())}, False),
                                                 ("no Codex", [None, False], {}, False)):
            binders: list[tuple[int, str, str]] = []
            self.recovery.update({
                "is_codex": lambda pid, answers=list(answers): answers.pop(0) if len(answers) > 1 else answers[0],
                "home_server": lambda pid: True,
                "server_evidence": lambda server, claim="", hosted=hosted: ({}, hosted),
                "process_start_token": lambda pid: f"start-{pid}",
                "detach": lambda lock: forks.append(lock) or True,
                "wait_for_binding": lambda server, token, thread, lock: binders.append((server, token, thread)) or os.close(lock),
            })
            with mock.patch.object(clocks, "sleep"), mock.patch.object(os, "kill"):
                self.recovery["bind_later"](105, session, event, {"server": None, "tmux": True}, None)
            self.assertEqual(read_pending(105, "start-105", session), event if recorded else None, label)
            self.assertEqual(binders, [(105, "start-105", session)] if recorded else [], label)
            if recorded:
                path.unlink()

        # A hook resolving the root of a Codex asks again, briefly, too.
        root = "/safe/.codex/sessions/rollout.jsonl"
        answers = [None, True]
        self.recovery.update({
            "is_codex": lambda pid: answers.pop(0) if len(answers) > 1 else answers[0],
            "root_candidate": lambda pid, directory: (root, (1, 2), session),
            "still_open": lambda pid, candidate, identity: candidate == root,
        })
        with mock.patch.object(clocks, "sleep") as sleep, mock.patch.object(os, "kill"):
            self.assertEqual(self.recovery["resolve_root"]("42", session),
                             self.recovery["base64"].urlsafe_b64encode(root.encode("utf-8")).decode("ascii").rstrip("="))
        sleep.assert_called_once()
        with mock.patch.object(clocks, "sleep") as sleep, mock.patch.object(os, "kill", side_effect=ProcessLookupError()):
            answers[:] = [None]
            self.assertIsNone(self.recovery["resolve_root"]("42", session))
        sleep.assert_not_called()

    def test_an_undecided_read_picks_no_client_and_no_server(self) -> None:
        session = self.SESSION
        # A client a ps could not place outside the server, which a tool the
        # server runs would be, is no client.
        self.install_shared_host([("%2", 200, "Fix the parser | demo")], {session: "Fix the parser"})
        self.assertTrue(self.recovery["bind_shared"]("105", session).startswith("%2 202 "))
        self.install_shared_host([("%2", 200, "Fix the parser | demo")], {session: "Fix the parser"})
        placed = self.recovery["descendant"]
        self.recovery["descendant"] = lambda child, ancestor: None if ancestor == 105 else placed(child, ancestor)
        self.assertIsNone(self.recovery["bind_shared"]("105", session))
        # Beside a second server of this home whose owner a ps could not
        # read, a client adopts no server: the next try tells.
        titles = [("%1", 100, "Profile the cache | demo"), ("%2", 200, "Fix the parser | demo")]
        names = {session: "Fix the parser", self.OTHER: "Profile the cache"}
        self.install_shared_host(titles, names)
        self.recovery["home_server"] = lambda pid: pid in {105, 106}
        self.recovery["current_uid"] = lambda pid: None if pid == 106 else os.getuid()
        self.assertIsNone(self.recovery["adopt_shared"](202, "start-202"))
        self.recovery["current_uid"] = lambda pid: os.getuid() + (pid == 106)
        self.assertEqual(self.recovery["adopt_shared"](202, "start-202"), (105, "%2"))

    def test_a_wall_clock_set_back_stretches_no_wait(self) -> None:
        self.runtime_home()
        session = self.SESSION
        start = 1_800_000_000_000_000_000
        stamp = lambda seconds: str(start + int(seconds * 1000000000))
        record_pending, read_pending = self.recovery["record_pending"], self.recovery["read_pending"]
        clock, claims, published, observed, attempts = [0.0], {}, [], [], []
        self.install_binder(clock, claims, published, observed, attempts, lambda now: None)
        self.assertTrue(record_pending(105, "start-105", session, ("Stop", "idle", "turn-stopped", stamp(-5))))
        # Ten seconds in, the wall clock steps back an hour: the binder still
        # waits at most the window from when it first read the event.
        self.assertIsNone(self.run_binder(clock, start, session, wall=lambda now: now if now < 10 else now - 3600))
        self.assertEqual(clock[0], 62.0)
        self.assertIsNone(read_pending(105, "start-105", session))

    def write_claim(self, runtime: Path, pid: int, stamp: str, event: str = "PostToolUse", **fields: object) -> None:
        value = {"version": 9, "provider": "codex", "agentPid": pid, "event": event, "sessionId": self.SESSION,
                 "timestampNs": stamp, "transcriptRef": "cm9sbG91dA"}
        value.update(fields)
        temporary = runtime.parent / f"{pid}.json.tmp"
        temporary.write_text(json.dumps(value), encoding="utf-8")
        temporary.chmod(0o600)
        os.replace(temporary, runtime / f"{pid}.json")

    def test_client_epoch_tells_a_client_that_never_published_from_an_unreadable_claim(self) -> None:
        runtime = self.runtime_home()
        client_epoch, read_observer_claim = self.recovery["client_epoch"], self.recovery["read_observer_claim"]
        claim = runtime / "202.json"
        # A client that never published holds no claim: the empty epoch.
        self.assertEqual(client_epoch(202), "")
        self.write_claim(runtime, 202, "1800000000000000000", "Stop")
        self.assertEqual(read_observer_claim(202), (self.SESSION, "1800000000000000000"))
        self.assertEqual(client_epoch(202), "1800000000000000000")
        # An ending is an epoch a binder publishes past, but observers hold
        # no claim for it.
        for ending in ("SessionEnd", "WrapperExit"):
            self.write_claim(runtime, 202, "1800000000000000001", ending)
            self.assertIsNone(read_observer_claim(202), ending)
            self.assertEqual(read_observer_claim(202, ended=True), (self.SESSION, "1800000000000000001"), ending)
            self.assertEqual(client_epoch(202), "1800000000000000001", ending)
        # A claim there that cannot be read, as of another client or
        # provider, an unknown event, a malformed stamp or file, or a link,
        # is never taken for none.
        for fields in ({"agentPid": 203}, {"provider": "claude"}, {"event": "Bogus"}, {"timestampNs": "0180"},
                       {"timestampNs": 1800000000000000000}, {"transcriptRef": "../x"}):
            self.write_claim(runtime, 202, "1800000000000000002", **fields)
            self.assertIsNone(read_observer_claim(202, ended=True), fields)
            self.assertIsNone(client_epoch(202), fields)
        claim.write_text("{", encoding="utf-8")
        self.assertIsNone(client_epoch(202))
        claim.unlink()
        self.write_claim(runtime, 203, "1800000000000000003", agentPid=202)
        claim.symlink_to(runtime / "203.json")
        self.assertIsNone(read_observer_claim(202, ended=True))
        self.assertIsNone(client_epoch(202))
        claim.unlink()
        self.assertEqual(client_epoch(202), "")
        # Nor is one in a state directory that cannot be trusted.
        moved = runtime.parent / "moved-state"
        runtime.rename(moved)
        runtime.symlink_to(moved)
        self.assertIsNone(client_epoch(202))

    def test_hooks_and_binders_racing_in_processes_publish_the_newest_event(self) -> None:
        # Forked hooks, real detach and real locks, on fixed seeds: hooks of
        # a thread no pane shows yet record their events and start binders,
        # some read no start of the server in time, and, once the title shows
        # the thread, some publish themselves. The client ends with the
        # newest event, and no record stays behind.
        import random
        session, bound = self.SESSION, self.BOUND
        real_sleep = time.sleep
        key = self.recovery["thread_key"](session)
        totals = {"late": 0, "binder": 0, "direct": 0}
        waiting = self.recovery["wait_for_binding"]
        for seed in range(12):
            runtime = self.runtime_home()
            scratch = runtime.parent
            rng = random.Random(seed)
            began = time.time()
            bind_at = began + rng.uniform(0.0, 0.5)
            missing = {"next": False, "late": False}

            def token(pid: int) -> Optional[str]:
                # A hook told to miss it reads no start; its child, the next
                # to read one, does.
                if missing["next"]:
                    missing["next"], missing["late"] = False, True
                    return None
                if missing["late"]:
                    missing["late"] = False
                    note("late")
                return f"start-{pid}"

            def note(text: str) -> None:
                with open(scratch / "log", "a", encoding="ascii") as handle:
                    handle.write("%d %s\n" % (os.getpid(), text))

            def claim_update(change) -> None:
                # The delivery: one at a time, against the claim it reads.
                with open(scratch / "claim.lock", "a") as guard:
                    fcntl.flock(guard, fcntl.LOCK_EX)
                    current = self.recovery["client_epoch"](202)
                    if current is None:
                        raise AssertionError("unreadable claim")
                    stamp = change(current)
                    if stamp is not None:
                        self.write_claim(runtime, 202, stamp)

            def invoke(pid, start_token, thread, path, stamp, pane=None, event=None, event_stamp=None) -> None:
                claim_update(lambda current: event_stamp if current == stamp and not (current and int(current) > int(event_stamp)) else None)

            def binder(*arguments):
                note("binder")
                return waiting(*arguments)

            self.recovery.update({
                "time": types.SimpleNamespace(sleep=lambda seconds: real_sleep(min(seconds, 0.02) if seconds >= 1 else seconds),
                                              monotonic=time.monotonic, time_ns=time.time_ns),
                "SHARED_LATER": 5, "SHARED_LATER_CEILING": 10, "SHARED_LATER_SLOW": 1, "PENDING_WAIT": 3,
                "process_start_token": token,
                "pane_titles": lambda: b"b" if time.time() >= bind_at else b"a",
                "bound_pane": lambda server, thread, deadline, found=None: bound if time.time() >= bind_at else None,
                "invoke_observed_hook": invoke,
                "watch_shared": lambda pid, start_token, bootstrap=False: None,
                "wait_for_binding": binder,
            })
            done, finished = os.pipe()
            hooks: list[int] = []
            stamps: list[str] = []
            for _ in range(rng.randint(6, 16)):
                real_sleep(rng.uniform(0, 0.15) if rng.random() < 0.2 else rng.uniform(0, 0.03))
                stamp = str(time.time_ns())
                stamps.append(stamp)
                late, direct = rng.random() < 0.3, rng.random() < 0.4
                pid = os.fork()
                if pid == 0:
                    # Every process of the hook, binders too, holds finished
                    # open until it exits.
                    status = 0
                    try:
                        os.close(done)
                        if direct and not late and time.time() >= bind_at:
                            note("direct")
                            claim_update(lambda current: stamp if not current or int(stamp) > int(current) else None)
                        else:
                            missing["next"] = late
                            self.recovery["RUN_DEADLINE"] = time.monotonic() + 3
                            self.recovery["bind_later"](105, session, ("PostToolUse", "working", "agent-turn", stamp),
                                                        {"server": True, "tmux": True}, None)
                    except BaseException as error:
                        status = 1
                        try:
                            note("error %r" % (error,))
                        except BaseException:
                            pass
                    finally:
                        os._exit(status)
                hooks.append(pid)
            os.close(finished)
            for pid in hooks:
                _, status = os.waitpid(pid, 0)
                self.assertEqual(status, 0, seed)
            # Binders and children of hooks run detached: they are done once
            # the last of them closes finished.
            with os.fdopen(done, "rb") as pipe:
                readable, _, _ = select.select([pipe], [], [], 15)
                ended = bool(readable) and pipe.read() == b""
            lines = (scratch / "log").read_text(encoding="ascii").splitlines() if (scratch / "log").exists() else []
            if not ended:
                for line in lines:
                    try:
                        os.kill(int(line.split()[0]), signal.SIGKILL)
                    except OSError:
                        pass
                self.fail("seed %d: a binder still runs" % seed)
            self.assertEqual([line for line in lines if " error " in line], [], seed)
            for kind in totals:
                totals[kind] += sum(line.split()[1] == kind for line in lines)
            self.assertEqual(self.recovery["client_epoch"](202), max(stamps, key=int), (seed, lines))
            self.assertIsNone(self.recovery["read_pending"](105, "start-105", session), seed)
            left = sorted(path.name for path in runtime.iterdir() if path.name.startswith("105."))
            self.assertTrue(set(left) <= {f"105.shared-binder.{key}.lock", f"105.shared-pending.{key}.lock"}, (seed, left))
            binder_lock = runtime / f"105.shared-binder.{key}.lock"
            if binder_lock.exists():
                with open(binder_lock, "a") as handle:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        # The seeds take every path: children of hooks that read no start in
        # time, binders, and hooks that published themselves.
        self.assertTrue(all(totals.values()), totals)

    def test_main_sets_only_the_exact_legacy_pane_and_prints_no_content(self) -> None:
        old = json.dumps({"version": 9, "provider": "codex", "transcriptRef": "Tm9uZQ", "agentPid": 42}, separators=(",", ":"))
        wrong = json.dumps({"version": 9, "provider": "codex", "transcriptRef": "c2FmZQ", "agentPid": 42}, separators=(",", ":"))
        calls: list[list[str]] = []

        def run(argv: list[str], limit: int) -> Optional[bytes]:
            calls.append(argv)
            if argv[1] == "list-panes":
                return f"%16\t100\t{old}\n%17\t101\t{wrong}\n".encode()
            if argv[1] == "show-option":
                self.assertEqual(argv[5], "%16")
                return (old + "\n").encode()
            if argv[1] == "set-option":
                self.assertEqual(argv[4], "%16")
                return b""
            return None

        self.recovery.update({
            "run": run,
            "is_codex": lambda _pid: True,
            "descendant": lambda _child, _parent: True,
            "root_candidate": lambda _pid, _root: ("/safe/sessions/rollout-root.jsonl", (1, 2), "root"),
            "latest_authority": lambda _path, _identity: ("Stop", "idle", "turn-stopped", 10, "turn"),
            "still_open": lambda _pid, _path, _identity: True,
            "current_uid": lambda _pid: os.getuid(),
        })
        output = io.StringIO()
        with contextlib.redirect_stdout(output), mock.patch.object(sys, "argv", [str(RECOVERY)]):
            self.recovery["main"]()
        self.assertEqual(output.getvalue(), "TESSERA_AGENT_CODEX_RECOVERY repaired=1\n")
        sets = [call for call in calls if call[1] == "set-option"]
        self.assertEqual(len(sets), 1)
        self.assertEqual(sets[0][4], "%16")
        self.assertNotIn("safe", output.getvalue())
        self.assertNotIn("root", output.getvalue())

        # A pane whose agent one ps could not tell is asked again, within one
        # budget for every pane, rather than left unrepaired.
        answers = [None, True]
        self.recovery["is_codex"] = lambda _pid: answers.pop(0) if len(answers) > 1 else answers[0]
        calls.clear()
        output = io.StringIO()
        with contextlib.redirect_stdout(output), mock.patch.object(sys, "argv", [str(RECOVERY)]), \
                mock.patch.object(self.recovery["time"], "sleep") as sleep, mock.patch.object(os, "kill"):
            self.recovery["main"]()
        self.assertEqual(output.getvalue(), "TESSERA_AGENT_CODEX_RECOVERY repaired=1\n")
        sleep.assert_called_once()
        # So is one whose open files lsof could not list once.
        candidates = [None, ("/safe/sessions/rollout-root.jsonl", (1, 2), "root")]
        self.recovery["is_codex"] = lambda _pid: True
        self.recovery["root_candidate"] = lambda _pid, _root: candidates.pop(0) if len(candidates) > 1 else candidates[0]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), mock.patch.object(sys, "argv", [str(RECOVERY)]), \
                mock.patch.object(self.recovery["time"], "sleep") as sleep:
            self.recovery["main"]()
        self.assertEqual(output.getvalue(), "TESSERA_AGENT_CODEX_RECOVERY repaired=1\n")
        sleep.assert_called_once()


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
