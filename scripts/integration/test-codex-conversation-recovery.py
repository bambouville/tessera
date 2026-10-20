#!/usr/bin/env python3
"""Hermetic semantic checks for the embedded Codex recovery executable.

Usage: test-codex-conversation-recovery.py /path/to/dumped-recovery.sh
"""

import contextlib
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from typing import Optional
import unittest
from unittest import mock


if len(sys.argv) != 2:
    raise SystemExit("usage: test-codex-conversation-recovery.py /path/to/dumped-recovery.sh")


RECOVERY = Path(sys.argv[1]).resolve()
START_MARKER = "python3 -c '"
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


class RecoveryFunctionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.recovery = recovery_functions(RECOVERY)

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
                self.assertIsNone(root_candidate(9_999_999, str(sessions)))
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
            self.assertIsNone(
                self.recovery["root_candidate"](9_999_999, str(sessions)),
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

        # Not our descendant, another user's process, or one without a start
        # token never gets an observer.
        events.clear()
        with mock.patch("os.fork") as fork:
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


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
