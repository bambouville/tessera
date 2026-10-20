#!/usr/bin/env python3
"""Hermetic semantic checks for the embedded Agent Center projector.

Usage: test-agent-conversation-projector.py /path/to/dumped-projector.sh
"""

import base64
import atexit
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from typing import Optional
import unittest
from unittest import mock


if len(sys.argv) == 2:
    PROJECTOR = Path(sys.argv[1]).resolve()
elif len(sys.argv) == 1:
    # Direct hermetic invocation: extract the embedded raw shell script without
    # running Swift, installing anything, or accessing a real transcript.
    swift = (Path(__file__).resolve().parents[2] /
             "Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift").read_text()
    marker = 'public static let projectorScript = #"""'
    start = swift.index(marker) + len(marker)
    shell = swift[start:swift.index('"""#', start)].lstrip("\n")
    temporary = tempfile.TemporaryDirectory(prefix="tessera-projector-tests-")
    atexit.register(temporary.cleanup)
    PROJECTOR = Path(temporary.name) / "projector.sh"
    PROJECTOR.write_text(shell)
    PROJECTOR.chmod(0o700)
else:
    raise SystemExit("usage: test-agent-conversation-projector.py [/path/to/dumped-projector.sh]")
START_MARKER = 'exec "$tessera_python" -c \'\n'
END_MARKER = '\ntry:\n    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)'


def projector_functions(path: Path) -> dict[str, object]:
    shell = path.read_text(encoding="utf-8")
    start = shell.index(START_MARKER) + len(START_MARKER)
    end = shell.index(END_MARKER, start)
    namespace: dict[str, object] = {"__name__": "tessera_projector_functions"}
    exec(compile(shell[start:end], str(path), "exec"), namespace)
    return namespace


def response_item(payload: dict[str, object]) -> dict[str, object]:
    return {"type": "response_item", "payload": payload}


def proto_field(number: int, payload: bytes) -> bytes:
    def varint(value: int) -> bytes:
        data = bytearray()
        while value >= 128:
            data.append((value & 127) | 128)
            value >>= 7
        data.append(value)
        return bytes(data)
    return varint(number * 8 + 2) + varint(len(payload)) + payload


def kind_signature(kind: str) -> str:
    return base64.b64encode(proto_field(2, proto_field(1, proto_field(8, kind.encode())))).decode()


class ProjectorFunctionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.projector = projector_functions(PROJECTOR)

    def test_large_codex_images_keep_following_prose_and_exact_source_hash(self) -> None:
        content = [
            {"type": "input_text", "text": "<image name=[Image #1] path=\"/tmp/a.png\">"},
            {"type": "input_image", "image_url": "data:image/png;base64," + "QUJD" * 262_144},
            {"type": "input_text", "text": "</image>"},
            {"type": "input_text", "text": "Describe this image\n[Image #1]"},
        ]
        raw = json.dumps(response_item({"type": "message", "role": "user", "content": content})).encode()
        with tempfile.TemporaryDirectory(prefix="tessera-image-projector-") as temporary:
            path = Path(temporary) / "images.jsonl"
            path.write_bytes(raw + b"\n")
            descriptor = os.open(path, os.O_RDONLY)
            info = os.fstat(descriptor)
            try:
                source_hash = [None]
                digest = hashlib.sha256()
                rows = list(self.projector["lines"](descriptor, 0, complete_only=True, end_offset=info.st_size,
                    digest=digest, redact_images=True, source_hash=source_hash))
                self.assertEqual(len(rows), 1)
                offset, retained, truncated = rows[0]
                self.assertEqual(offset, len(raw) + 1)
                self.assertFalse(truncated)
                self.assertLess(len(retained), 1024)
                self.assertEqual(source_hash[0], hashlib.sha256(raw).hexdigest())
                self.assertEqual(digest.hexdigest(), hashlib.sha256(raw + b"\n").hexdigest())
                record = self.projector["normalized"]("codex", retained, truncated)
                self.assertEqual(record["blocks"][1], {"type": "attachment", "name": "Image", "mediaType": "image"})
                # Adjacent input_text fragments join exactly, as in the native host.
                self.assertEqual(record["blocks"][-1]["text"], content[-2]["text"] + content[-1]["text"])
                frames = []
                with mock.patch.dict(self.projector, {"emit": lambda value, state: frames.append(value)}):
                    self.projector["receipt_boundary"](descriptor, "codex", self.projector["jsonl_identity"]("codex", info), info)
                self.assertEqual(frames[1]["record"], record)
                self.assertEqual(frames[1]["sourceHash"], hashlib.sha256(raw).hexdigest())
                self.assertEqual(frames[1]["sourceOffset"], 0)
            finally:
                os.close(descriptor)

    def test_image_lexer_preserves_escaped_prose_and_handles_every_chunk_boundary(self) -> None:
        value = {"text": "literal \"image_url\": \"data:image/png;base64,QUJD\" and \\ path café",
                 "content": [{"type": "input_image", "image_url": "data:image/png;base64,QUJD"},
                             {"type": "input_text", "text": "after café"}]}
        raw = json.dumps(value, ensure_ascii=False).encode()
        expected = dict(value, content=[dict(value["content"][0], image_url="tessera:image"), value["content"][1]])
        for stride in [1, 2, 3, 7, 64, 8192]:
            line = self.projector["ImageLine"]()
            for index in range(0, len(raw), stride): line.feed(raw[index:index + stride])
            self.assertFalse(line.truncated)
            self.assertEqual(json.loads(line.retained), expected)
            self.assertLessEqual(len(line.retained), self.projector["MAX_PREFIX"])
        huge_prose = json.dumps({"text": "x" * 100_000}).encode()
        line = self.projector["ImageLine"](); line.feed(huge_prose)
        self.assertTrue(line.truncated)
        self.assertEqual(len(line.retained), self.projector["MAX_PREFIX"])

    def test_unrecognized_image_urls_do_not_become_attachment_evidence(self) -> None:
        for url in ["data:text/plain;base64,QUJD", "data:image/png,missing-base64", "data:image/png;base64,bad value", "data:image/png;base64,\\q", "data:image/png;base64,", "data:image/png;base64,not_base64", "data:image/png;base64,QUJD;:-", "data:image/png;base64,QUJ", "data:image/png;base64,====", "data:image/png;base64,QUJD=AAA"]:
            raw = json.dumps(response_item({"type": "message", "role": "user", "content": [{"type": "input_image", "image_url": url}]})).encode()
            line = self.projector["ImageLine"](); line.feed(raw)
            record = self.projector["normalized"]("codex", bytes(line.retained), False)
            self.assertFalse(any(block["type"] == "attachment" for block in record["blocks"]))

    def test_redacted_image_strings_preserve_malformed_json_rejection(self) -> None:
        for invalid in [b"bad\x01value", b"bad\xffvalue", b"bad\\q", b"bad\\u12xx", b"\xc3\\n\xa9"]:
            raw = b'{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_image","image_url":"data:image/png;base64,' + invalid + b'"}]}}'
            for stride in [1, 7, 8192]:
                line = self.projector["ImageLine"]()
                for index in range(0, len(raw), stride): line.feed(raw[index:index + stride])
                record = self.projector["normalized"]("codex", line.value(), False)
                self.assertTrue(record.get("malformed"), (invalid, stride, record))

    def test_base64_padding_is_validated_across_chunk_boundaries(self) -> None:
        for payload in [b"QUJD", b"QQ==", b"QUI="]:
            for stride in [1, 2, 3, 7]:
                validator = self.projector["ImageURL"]()
                value = b"data:image/png;base64," + payload
                for index in range(0, len(value), stride): validator.feed(value[index:index + stride])
                self.assertTrue(validator.verified(), (payload, stride))

    def test_inventory_image_probe_cannot_read_past_its_source_byte_budget(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-inventory-image-") as temporary:
            root = Path(temporary) / ".codex" / "sessions"
            root.mkdir(parents=True)
            path = root / "image.jsonl"
            path.write_text(json.dumps(response_item({"type": "message", "role": "user", "content": [
                {"type": "input_image", "image_url": "data:image/png;base64," + "QUJD" * 262_144}
            ]})) + "\n")
            frames = []
            with mock.patch.dict(os.environ, {"HOME": temporary}), mock.patch.dict(self.projector, {"emit": lambda value, state: frames.append(value)}), mock.patch.object(os, "read", wraps=os.read) as reads:
                self.projector["inventory"]({"provider": "codex", "limitRecords": 100})
                self.assertLessEqual(sum(call.args[1] for call in reads.call_args_list), 65536)
            self.assertFalse(any(frame.get("kind") == "inventory" for frame in frames))

    def test_codex_image_schema_changes_identity_without_changing_other_providers(self) -> None:
        with tempfile.TemporaryFile() as file:
            info = os.fstat(file.fileno())
            old = "%x:%x:%x:%x" % (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
            self.assertEqual(self.projector["jsonl_identity"]("claude", info), old)
            self.assertEqual(self.projector["jsonl_identity"]("codex", info), "codex-images1:" + old)

    def test_receipt_boundary_reads_only_bounded_tail_and_hashes_exact_anchor(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-receipt-boundary-") as temporary:
            path = Path(temporary) / "large.jsonl"
            anchor = json.dumps({"type": "event_msg", "payload": {"type": "task_complete", "last_agent_message": "ready"}}).encode()
            with path.open("wb") as target:
                target.seek(676_172_858)
                target.write(b"\n" + anchor + b"\n" + b'{"partial":')
            descriptor = os.open(path, os.O_RDONLY)
            info = os.fstat(descriptor)
            frames = []
            try:
                with mock.patch.dict(self.projector, {"emit": lambda frame, state: frames.append(frame)}), mock.patch.object(os, "read", wraps=os.read) as reads:
                    self.projector["receipt_boundary"](descriptor, "codex", "identity", info)
                    self.assertLessEqual(sum(call.args[1] for call in reads.call_args_list), 98_304)
                self.assertEqual(frames[0]["summary"]["receiptByteOffset"], str(info.st_size))
                self.assertEqual(frames[1]["sourceOffset"], 676_172_859)
                self.assertEqual(frames[1]["sourceHash"], hashlib.sha256(anchor).hexdigest())
                self.assertFalse(frames[-1]["hasMore"])
            finally:
                os.close(descriptor)

    def test_receipt_boundary_rejects_oversized_anchor_before_emitting(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-receipt-oversized-") as temporary:
            path = Path(temporary) / "large.jsonl"
            path.write_bytes(b"{}\n" + b"x" * 60_000 + b"\n")
            descriptor = os.open(path, os.O_RDONLY)
            frames = []
            try:
                with mock.patch.dict(self.projector, {"emit": lambda frame, state: frames.append(frame)}):
                    with self.assertRaises(self.projector["ProjectionError"]):
                        self.projector["receipt_boundary"](descriptor, "codex", "identity", os.fstat(descriptor))
                self.assertEqual(frames, [])
            finally:
                os.close(descriptor)

    def test_large_windows_sized_transcript_keeps_title_and_latest_message_without_copy(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-large-project-") as temporary:
            transcript = Path(temporary) / "large.jsonl"
            # Sparse oversized legacy record: only a bounded prefix is retained.
            # Its size matches the actual Pixel diagnostic (676 MB), not a mock stat.
            with transcript.open("wb") as destination:
                destination.write(json.dumps({"type": "session_meta", "payload": {"cwd": "/project"}}).encode() + b"\n")
                destination.write(json.dumps(response_item({"type": "message", "role": "user", "content": [{"type": "input_text", "text": "Opening title survives"}]})).encode() + b"\n")
                destination.write(b'{"type":"legacy","huge":"')
                destination.seek(676_172_858)
                destination.write(b'"}\n')
                destination.write(json.dumps(response_item({"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Latest message survives"}]})).encode() + b"\n")
            descriptor = os.open(transcript, os.O_RDONLY)
            info = os.fstat(descriptor)
            identity = "%x:%x:%x:%x" % (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
            frames = []
            with mock.patch.dict(self.projector, {
                "validate_source": lambda *args: (descriptor, identity, info),
                "emit": lambda frame, state: frames.append(frame),
            }), mock.patch.object(tempfile, "TemporaryFile", side_effect=AssertionError("projection must not copy the whole transcript")):
                self.projector["project"]({"provider": "codex", "transcriptRef": "fixture", "limitRecords": 2})
            self.assertEqual(frames[0]["summary"]["openingPrompt"], "Opening title survives")
            self.assertIn("Latest message survives", json.dumps(frames))
            self.assertEqual(frames[-1]["kind"], "end")
            self.assertTrue(frames[-1]["hasMore"])

    def test_rewrite_during_projection_is_rejected_without_emitting_partial_page(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-rewrite-project-") as temporary:
            transcript = Path(temporary) / "live.jsonl"
            transcript.write_text(json.dumps({"type": "user", "message": {"role": "user", "content": "first"}}) + "\n")
            descriptor = os.open(transcript, os.O_RDONLY)
            info = os.fstat(descriptor)
            identity = "%x:%x:%x:%x" % (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
            normalize = self.projector["normalized"]
            frames = []
            def rewrite_then_normalize(*args):
                transcript.write_text(transcript.read_text().replace("first", "other") + "{}\n")
                return normalize(*args)
            with mock.patch.dict(self.projector, {
                "validate_source": lambda *args: (descriptor, identity, info),
                "normalized": rewrite_then_normalize,
                "emit": lambda frame, state: frames.append(frame),
            }):
                with self.assertRaises(self.projector["ProjectionError"]):
                    self.projector["project"]({"provider": "claude", "transcriptRef": "fixture"})
            self.assertEqual(frames, [])

    def test_unexpected_legacy_field_shape_does_not_hide_thread(self) -> None:
        for provider, source in [
            ("codex", {"type": "turn_context", "payload": {"model": {"unexpected": "shape"}}}),
            ("claude", {"type": "assistant", "message": {"content": 42, "model": ["legacy"]}}),
        ]:
            record = self.projector["normalized"](provider, json.dumps(source).encode(), False)
            self.assertIsInstance(record, dict)
        with mock.patch.dict(self.projector, {"codex_record": mock.Mock(side_effect=TypeError("private contents"))}):
            record = self.projector["normalized"]("codex", b'{"type":"turn_context"}', False)
        self.assertTrue(record["malformed"])
        self.assertNotIn("private", json.dumps(record))

    def test_transcript_write_permissions_are_user_controlled(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-permission-") as temporary:
            transcript = Path(temporary) / "private-session.jsonl"
            transcript.write_text("private transcript", encoding="utf-8")
            ref = base64.b64encode(str(transcript).encode()).decode()
            with mock.patch.dict(self.projector, {"provider_roots": lambda provider: [str(Path(temporary).resolve())]}):
                for mode in (0o600, 0o644, 0o664, 0o666):
                    with self.subTest(mode=oct(mode)):
                        transcript.chmod(mode)
                        descriptor, _, _ = self.projector["validate_source"]("codex", ref)
                        try:
                            self.assertEqual(os.read(descriptor, 64), b"private transcript")
                        finally:
                            os.close(descriptor)
                        self.assertEqual(transcript.stat().st_mode & 0o777, mode)

    def test_read_access_denial_still_reports_private_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-permission-") as temporary:
            transcript = Path(temporary) / "private-session.jsonl"
            transcript.write_text("private transcript", encoding="utf-8")
            transcript.chmod(0o664)
            ref = base64.b64encode(str(transcript).encode()).decode()
            with mock.patch.dict(self.projector, {"provider_roots": lambda provider: [str(Path(temporary).resolve())]}), mock.patch.object(os, "open", side_effect=PermissionError(13, "denied")):
                with self.assertRaises(self.projector["ProjectionError"]) as caught:
                    self.projector["validate_source"]("codex", ref)
            self.assertEqual(caught.exception.code, "permissionDenied")
            self.assertEqual(caught.exception.diagnostics["reason"], "openDenied")
            self.assertEqual(caught.exception.diagnostics["mode"], "0664")
            self.assertEqual(caught.exception.diagnostics["errno"], "13")
            self.assertNotIn(temporary, json.dumps(caught.exception.diagnostics))
            self.assertNotIn("private", json.dumps(caught.exception.diagnostics))

    def test_writable_database_and_wal_sidecars_can_be_snapshotted(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-writable-database-") as temporary:
            path = str(Path(temporary) / "transcripts.db")
            writer = sqlite3.connect(path)
            try:
                writer.execute("PRAGMA journal_mode=WAL")
                writer.execute("CREATE TABLE messages (body TEXT)")
                writer.execute("INSERT INTO messages VALUES (?)", ("fixture",))
                writer.commit()
                for suffix in ("", "-wal", "-shm"):
                    Path(path + suffix).chmod(0o666)
                database, descriptor, _, snapshot_dir, _ = self.projector["open_snapshot_database"](
                    path, "fixture", 1048576, {"messages": {"body"}})
                try:
                    self.assertEqual(database.execute("SELECT body FROM messages").fetchone()[0], "fixture")
                finally:
                    database.close()
                    os.close(descriptor)
                    shutil.rmtree(snapshot_dir)
                for suffix in ("", "-wal", "-shm"):
                    self.assertEqual(Path(path + suffix).stat().st_mode & 0o777, 0o666)
            finally:
                writer.close()

    def test_writable_pi_transcript_and_directories_can_be_read(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-writable-pi-") as temporary:
            home = Path(temporary)
            root = home / ".pi" / "agent" / "sessions"
            root.mkdir(parents=True)
            source = root / "fixture.jsonl"
            source.write_text("fixture", encoding="utf-8")
            source.chmod(0o666)
            for directory in (root, root.parent, root.parent.parent):
                directory.chmod(0o777)
            with mock.patch.dict(os.environ, {"HOME": temporary}):
                _, descriptor, _, _ = self.projector["pi_secure_session_path"]("fixture.jsonl")
                try:
                    self.assertEqual(os.read(descriptor, 64), b"fixture")
                finally:
                    os.close(descriptor)

    def test_pi_directory_swap_cannot_escape_the_session_root(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-pi-directory-race-") as temporary:
            home = Path(temporary).resolve()
            project = home / ".pi" / "agent" / "sessions" / "project"
            project.mkdir(parents=True)
            (project / "fixture.jsonl").write_text("inside", encoding="utf-8")
            outside = home / "outside"
            outside.mkdir()
            (outside / "fixture.jsonl").write_text("outside", encoding="utf-8")
            original_lstat, original_open = os.lstat, os.open
            swapped = False
            def swap():
                nonlocal swapped
                if not swapped:
                    swapped = True
                    project.rename(project.with_name("original"))
                    project.symlink_to(outside, target_is_directory=True)
            def stat_then_swap(path, *args, **kwargs):
                result = original_lstat(path, *args, **kwargs)
                if str(path) == str(project): swap()
                return result
            def open_after_swap(path, *args, **kwargs):
                # For descriptor-relative traversal, swap the pathname after
                # its directory FD is acquired but before opening the leaf.
                if path == "fixture.jsonl" and "dir_fd" in kwargs: swap()
                return original_open(path, *args, **kwargs)
            with mock.patch.dict(os.environ, {"HOME": str(home)}), mock.patch.object(os, "lstat", stat_then_swap), mock.patch.object(os, "open", open_after_swap):
                try:
                    _, descriptor, _, _ = self.projector["pi_secure_session_path"]("project/fixture.jsonl")
                except self.projector["ProjectionError"]:
                    pass
                else:
                    try:
                        self.assertEqual(os.read(descriptor, 64), b"inside")
                    finally:
                        os.close(descriptor)
            self.assertTrue(swapped, "the test must actually perform the adversarial swap")

    def test_writable_kimi_session_index_can_be_read(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-writable-kimi-") as temporary:
            root = Path(temporary).resolve()
            index = root / "session_index.jsonl"
            index.write_text(json.dumps({"sessionId": "session_fixture", "sessionDir": str(root / "sessions" / "project" / "session_fixture")}) + "\n", encoding="utf-8")
            index.chmod(0o666)
            result = self.projector["load_kimi_index"](str(root))
            self.assertIsNotNone(result)
            self.assertIn("sessions/project/session_fixture", result[1])

    def test_pi_inventory_metadata_comes_from_the_protected_read(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-pi-inventory-race-") as temporary:
            home = Path(temporary).resolve()
            project = home / ".pi" / "agent" / "sessions" / "project"
            project.mkdir(parents=True)
            source = project / "fixture.jsonl"
            source.write_text("inside", encoding="utf-8")
            source_stat = source.stat()
            outside = home / "outside"
            outside.mkdir()
            (outside / "fixture.jsonl").write_text("outside metadata must not be used", encoding="utf-8")
            frames = []
            def load_then_swap(*args):
                project.rename(project.with_name("original"))
                project.symlink_to(outside, target_is_directory=True)
                return "protected", {"sessionID": "inside-session"}, None, source_stat
            with mock.patch.dict(os.environ, {"HOME": str(home)}), mock.patch.dict(self.projector, {
                "pi_load_session": load_then_swap,
                "emit": lambda frame, state: frames.append(frame),
            }):
                self.projector["pi_inventory"]({})
            entry = next(frame for frame in frames if frame["kind"] == "inventory")
            self.assertEqual(entry["providerSessionID"], "inside-session")
            self.assertEqual(entry["size"], len("inside"))
            self.assertEqual(entry["lastActivityNs"], source_stat.st_mtime_ns)

    def test_windows_path_refusal_reports_path_kind_not_path(self) -> None:
        ref = base64.b64encode(b"C:\\Users\\private\\session.jsonl").decode()
        with mock.patch.dict(self.projector, {"provider_roots": lambda provider: ["/unrelated-root"]}):
            with self.assertRaises(self.projector["ProjectionError"]) as caught:
                self.projector["validate_source"]("codex", ref)
        self.assertEqual(caught.exception.diagnostics["pathKind"], "windowsDrive")
        self.assertEqual(caught.exception.diagnostics["reason"], "outsideAllowedRoot")
        self.assertNotIn("private", json.dumps(caught.exception.diagnostics))

    def test_live_append_during_normalization_keeps_a_complete_snapshot(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-live-snapshot-") as temporary:
            transcript = Path(temporary) / "live.jsonl"
            first = {"type": "assistant", "message": {"role": "assistant", "content": "first"}}
            transcript.write_text(json.dumps(first) + "\n", encoding="utf-8")
            descriptor = os.open(transcript, os.O_RDONLY)
            source_stat = os.fstat(descriptor)
            identity = "%x:%x:%x:%x" % (source_stat.st_dev, source_stat.st_ino, source_stat.st_size, source_stat.st_mtime_ns)
            frames = []
            normalize = self.projector["normalized"]
            appended = False
            def append_then_normalize(*args):
                nonlocal appended
                if not appended:
                    appended = True
                    with transcript.open("a") as destination:
                        destination.write(json.dumps(first) + "\n")
                return normalize(*args)
            with mock.patch.dict(self.projector, {
                "validate_source": lambda *args: (descriptor, identity, source_stat),
                "normalized": append_then_normalize,
                "emit": lambda frame, state: frames.append(frame),
            }):
                self.projector["project"]({"provider": "claude", "transcriptRef": "fixture"})
            self.assertEqual(frames[-1]["kind"], "end")
            self.assertEqual(len([frame for frame in frames if frame["kind"] == "record"]), 1)

    def test_appending_output_preserves_existing_record_identity(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-stable-records-") as temporary:
            transcript = Path(temporary) / "live.jsonl"
            first = {"type": "assistant", "message": {"role": "assistant", "content": "first"}}
            transcript.write_text(json.dumps(first) + "\n", encoding="utf-8")
            def collect():
                descriptor = os.open(transcript, os.O_RDONLY)
                info = os.fstat(descriptor)
                identity = "%x:%x:%x:%x" % (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                frames = []
                with mock.patch.dict(self.projector, {
                    "validate_source": lambda *args: (descriptor, identity, info),
                    "emit": lambda frame, state: frames.append(frame),
                }):
                    self.projector["project"]({"provider": "claude", "transcriptRef": "fixture"})
                return frames
            before = collect()
            with transcript.open("a") as destination:
                destination.write(json.dumps(first) + "\n")
            after = collect()
            self.assertNotEqual(before[0]["sourceIdentity"], after[0]["sourceIdentity"])
            self.assertEqual(before[1]["recordID"], after[1]["recordID"])
            self.assertNotEqual(after[1]["recordID"], after[2]["recordID"])

    def test_history_cursor_survives_append_but_rejects_rewritten_prefix(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-live-history-") as temporary:
            transcript = Path(temporary) / "live.jsonl"
            rows = [{"type": "assistant", "message": {"role": "assistant", "content": str(n)}} for n in range(5)]
            transcript.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

            def collect(**options):
                descriptor = os.open(transcript, os.O_RDONLY)
                info = os.fstat(descriptor)
                identity = "%x:%x:%x:%x" % (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                frames = []
                with mock.patch.dict(self.projector, {
                    "validate_source": lambda *args: (descriptor, identity, info),
                    "emit": lambda frame, state: frames.append(frame),
                }):
                    self.projector["project"]({"provider": "claude", "transcriptRef": "fixture", "limitRecords": 2, **options})
                return frames

            first = collect()
            cursor = first[-1]["cursor"]
            with transcript.open("a") as destination:
                destination.write(json.dumps(rows[-1]) + "\n")
            older = collect(cursor=cursor)
            self.assertEqual([r["sequence"] for r in older if r["kind"] == "record"], [1, 2])
            self.assertEqual(older[0]["summary"]["continuedFrom"], first[0]["sourceIdentity"])
            latest = collect(continuationCursor=cursor)
            self.assertEqual(latest[0]["summary"]["continuedFrom"], first[0]["sourceIdentity"])
            with transcript.open("r+") as destination:
                text = destination.read().replace('"content": "0"', '"content": "X"', 1)
                destination.seek(0)
                destination.write(text)
            with self.assertRaises(self.projector["ProjectionError"]):
                collect(cursor=cursor)
            replaced = collect(continuationCursor=cursor)
            self.assertNotIn("continuedFrom", replaced[0]["summary"])

    def test_subagent_model_cannot_replace_main_agent_metadata(self) -> None:
        for provider, source in [
            ("claude", {"type": "assistant", "isSidechain": True, "message": {"model": "child-model", "content": "child work"}}),
            ("codex", {"type": "turn_context", "isSidechain": True, "payload": {"model": "child-model"}}),
        ]:
            with self.subTest(provider=provider):
                summary = {"type": "metadata", "model": "main-model"}
                record = self.projector["normalized"](provider, json.dumps(source).encode(), False)
                self.projector["update_projection_summary"](summary, record)
                self.assertEqual(summary["model"], "main-model")

    def test_partial_live_json_record_waits_for_newline(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-partial-snapshot-") as temporary:
            transcript = Path(temporary) / "live.jsonl"
            transcript.write_bytes(b'{"type":"assistant"}\n{"type":')
            descriptor = os.open(transcript, os.O_RDONLY)
            try:
                rows = list(self.projector["lines"](descriptor, 0, complete_only=True))
            finally:
                os.close(descriptor)
            self.assertEqual(len(rows), 1)

    def claude_usage_record(self, usage, **fields):
        source = {"type": "assistant", "uuid": "main", "parentUuid": "parent",
                  "message": {"role": "assistant", "content": "Reply", "model": "claude", "usage": usage}}
        source.update(fields)
        return self.projector["claude_record"](source, False)

    def test_claude_usage_sums_all_four_fields_without_accumulating(self) -> None:
        usage = {"input_tokens": 1000, "cache_creation_input_tokens": 2000,
                 "cache_read_input_tokens": 3000, "output_tokens": 400}
        self.assertEqual(self.claude_usage_record(usage)["used_tokens"], 6400)
        self.assertEqual(self.claude_usage_record({"output_tokens": 42})["used_tokens"], 42)
        self.assertEqual(self.claude_usage_record({"input_tokens": (1 << 53) - 1})["used_tokens"], (1 << 53) - 1)

    def test_claude_usage_omits_synthetic_and_zero(self) -> None:
        synthetic = {"model": "<synthetic>", "content": "Interrupted", "usage": {"input_tokens": 100}}
        for record in [self.claude_usage_record({}), self.claude_usage_record({"input_tokens": 0}),
                       self.claude_usage_record(None), self.claude_usage_record([]),
                       self.claude_usage_record(None, message=synthetic)]:
            self.assertNotIn("used_tokens", record)

    def test_claude_usage_rejects_malformed_fields_and_unsafe_sum(self) -> None:
        for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"):
            for bad in (-1, True, False, 1.0, "1", None, [], {}):
                with self.subTest(key=key, bad=bad):
                    self.assertNotIn("used_tokens", self.claude_usage_record({"input_tokens": 100, key: bad}))
        for usage in ({"input_tokens": 1 << 53}, {"input_tokens": (1 << 53) - 1, "output_tokens": 1}):
            self.assertNotIn("used_tokens", self.claude_usage_record(usage))

    def test_claude_usage_only_main_chain_non_child_assistants(self) -> None:
        for fields in ({"type": "user"}, {"type": "system"}, {"isSidechain": True}, {"isSubagent": True},
                       {"isMeta": True}, {"teamName": "team"}, {"teamName": []}, {"uuid": ""},
                       {"uuid": 1}, {"uuid": "x" * 257}, {"parentUuid": 1}, {"isMeta": 1}, {"isSidechain": "false"},
                       {"payload": {"isSidechain": True}}, {"payload": {"source": {"subagent": "child"}}}):
            with self.subTest(fields=fields):
                self.assertNotIn("used_tokens", self.claude_usage_record({"input_tokens": 100}, **fields))

    def test_claude_compact_boundary_preserves_reset_subtype(self) -> None:
        record = self.projector["claude_record"]({"type": "system", "subtype": "compact_boundary"}, False)
        self.assertEqual(record["subtype"], "compact_boundary")
        self.assertEqual(record["role"], "system")
        self.assertNotIn("used_tokens", record)

    def test_standalone_claude_context_attachments_are_not_conversation_files(self) -> None:
        record = self.projector["claude_record"]({
            "type": "attachment", "attachment": {"type": "prompt_snapshot", "systemPrompt": "private injected instructions"},
        }, False)
        self.assertEqual(record["type"], "system")
        self.assertEqual(record["text"], "Provider context: prompt_snapshot")
        self.assertNotIn("attachment", record)
        self.assertNotIn("private injected instructions", json.dumps(record))

    def test_claude_narration_signature_classification_and_bounds(self) -> None:
        narration = kind_signature("narration")
        def block(signature: str, text: str = "Between calls", provider: str = "claude") -> list[dict[str, object]]:
            content = [{"type":"thinking", "thinking":text, "signature":signature}]
            if provider != "claude": return self.projector["normalized_blocks"](content)
            return self.projector["claude_record"]({"type":"assistant", "message":{"content":content}}, False)["blocks"]
        self.assertEqual(block(narration), [{"type":"text", "text":"Between calls", "truncated":False}])
        self.assertEqual(block(narration, " \t\n "), [])
        self.assertEqual(self.projector["normalized_blocks"](
            [{"type":"thinking", "text":"Fallback text", "signature":narration}], claude=True)[0]["type"], "thinking")
        bad = [
            kind_signature("summary"), "legacy", "garbage!", "A" * 65537,
            base64.b64encode(proto_field(2, proto_field(1, proto_field(8, b"narration"))[:5])).decode(),
            base64.b64encode(proto_field(2, proto_field(1, proto_field(8, b"narration"))) + b"\x80").decode(),
        ]
        for signature in bad:
            with self.subTest(signature=signature[:24]):
                self.assertEqual(block(signature)[0]["type"], "thinking")
        self.assertEqual(block(narration, provider="codex")[0]["type"], "thinking")
        self.assertEqual(block(narration, provider="pi")[0]["type"], "thinking")
        first_summary = proto_field(2, proto_field(1, proto_field(8, b"summary")))
        last_narration = proto_field(2, proto_field(1, proto_field(8, b"narration")))
        self.assertEqual(block(base64.b64encode(first_summary + last_narration).decode())[0]["type"], "text")
        self.assertEqual(block(base64.b64encode(last_narration + first_summary).decode())[0]["type"], "thinking")
        spaced = " \n".join(narration[index:index + 4] for index in range(0, len(narration), 4))
        self.assertEqual(block(spaced)[0]["type"], "text")
        unpadded = narration.rstrip("=")
        self.assertEqual(block(unpadded)[0]["type"], "text")
        # atob rejects a vertical tab but skips a form feed.
        self.assertEqual(block(narration[:4] + "\v" + narration[4:])[0]["type"], "thinking")
        self.assertEqual(block(narration[:4] + "\f" + narration[4:])[0]["type"], "text")
        # The native host clips oversized-record strings at 16 KiB and never
        # classifies a signature that long.
        def padded(size: int) -> str:
            return base64.b64encode(proto_field(2, proto_field(1, proto_field(8, b"narration") + proto_field(9, b"x" * size)))).decode()
        self.assertGreaterEqual(len(padded(12500)), 16384)
        self.assertEqual(block(padded(12500))[0]["type"], "thinking")
        self.assertEqual(block(padded(9000))[0]["type"], "text")
        self.assertEqual(block(narration, " " * 20000 + "late")[0]["type"], "text")

    def test_claude_narration_survives_tool_block_pressure(self) -> None:
        content = [{"type":"tool_use", "name":"Synthetic", "input":"x" * 2000} for _ in range(70)]
        content.append({"type":"thinking", "thinking":"Keep this prose", "signature":kind_signature("narration")})
        record = self.projector["claude_record"]({"type":"assistant", "message":{"content":content}}, False)
        blocks = record["blocks"]
        self.assertEqual(len(blocks), 64)
        self.assertEqual(blocks[-1]["type"], "text")
        self.assertEqual(blocks[-1]["text"], "Keep this prose")
        # Omitted whole blocks must reach the app's shortened-preview notice.
        self.assertTrue(record["truncated"])
        self.assertFalse(self.projector["claude_record"]({"type":"assistant", "message":{"content":content[:64]}}, False)["truncated"])

    def test_block_discriminators_and_input_fragments_match_the_native_host(self) -> None:
        blocks = self.projector["normalized_blocks"]
        # A non-string type reads as absent instead of failing the record.
        queued = self.projector["claude_record"]({"type":"attachment", "attachment":{
            "type":"queued_command", "prompt":[{"type":["future"], "text":"Kept"}]}}, False)
        self.assertEqual((queued["type"], queued["blocks"]), ("message", [{"type":"text", "text":"Kept", "truncated":False}]))
        self.assertEqual(blocks([{"type":"input_text", "text":"Hel"}, {"type":"input_text", "text":"lo"},
                                 {"type":"input_image", "image_url":"tessera:image"}, {"type":"input_text", "text":" again"}]),
                         [{"type":"text", "text":"Hello", "truncated":False},
                          {"type":"attachment", "name":"Image", "mediaType":"image"},
                          {"type":"text", "text":" again", "truncated":False}])

    def test_claude_queued_command_human_prompt_and_context_filters(self) -> None:
        record = self.projector["claude_record"]
        envelope = {"type":"attachment", "uuid":"queued", "parentUuid":"previous", "timestamp":"synthetic-time",
                    "sessionId":"synthetic-session", "gitBranch":"synthetic-branch", "cwd":"/synthetic/project"}
        def with_attachment(attachment: dict[str, object]) -> dict[str, object]:
            return record(dict(envelope, attachment=attachment), False)
        human = with_attachment({"type":"queued_command", "commandMode":"prompt", "origin":{"kind":"human"}, "prompt":"Typed during turn"})
        self.assertEqual(human["type"], "message")
        self.assertEqual(human["role"], "user")
        self.assertEqual(human["blocks"], [{"type":"text", "text":"Typed during turn", "truncated":False}])
        self.assertFalse(human["isMeta"])
        self.assertEqual((human["timestamp"], human["sessionID"], human["turnID"]),
                         ("synthetic-time", "synthetic-session", "queued"))
        self.assertEqual(with_attachment({"type":"queued_command", "prompt":[
            {"type":"text", "text":"Look here"}, {"type":"image", "source":{"type":"base64", "data":"synthetic"}}]})["blocks"],
            [{"type":"text", "text":"Look here", "truncated":False},
             {"type":"attachment", "name":"Image", "mediaType":"image"}])
        self.assertEqual(with_attachment({"type":"queued_command", "prompt":"No mode or origin"})["role"], "user")
        self.assertEqual(with_attachment({"type":"queued_command", "prompt":[{"type":"tool_result", "content":"Synthetic tool output"}]})["role"], "tool")
        for attachment in [
            {"type":"queued_command", "commandMode":"prompt", "origin":{"kind":"peer", "name":"synthetic-peer"}, "prompt":"Peer"},
            {"type":"queued_command", "commandMode":"task-notification", "origin":{"kind":"human"}, "prompt":"Task"},
            {"type":"queued_command", "commandMode":"prompt", "origin":{"kind":"task-notification"}, "prompt":"Task"},
            {"type":"queued_command", "commandMode":"prompt", "origin":{"kind":"unclassified"}, "forwardedIntent":True, "prompt":"Forwarded"},
            {"type":"queued_command", "commandMode":"prompt", "origin":{"kind":"human"}, "isMeta":True, "prompt":"Meta"},
        ]:
            with self.subTest(attachment=attachment):
                context = with_attachment(attachment)
                self.assertEqual(context["type"], "system")
                self.assertEqual(context["text"], "Provider context: queued_command")
                self.assertNotIn("blocks", context)

    def test_claude_internal_wrappers_and_real_human_message(self) -> None:
        record = self.projector["claude_record"]

        injected = record({
            "type": "user",
            "isMeta": True,
            "message": {"role": "user", "content": "hidden setup"},
        }, False)
        self.assertEqual(injected["type"], "message")
        self.assertEqual(injected["role"], "system")
        self.assertTrue(injected["isMeta"])

        caveat = record({
            "type": "user",
            "message": {"role": "user", "content": "<local-command-caveat>internal"},
        }, False)
        self.assertEqual(caveat["role"], "system")

        clear = record({
            "type": "user",
            "message": {"role": "user", "content": "<command-name>/clear</command-name>"},
        }, False)
        self.assertEqual(clear["role"], "system")

        notification = record({
            "type": "user",
            "message": {"role": "user", "content": "<task-notification>worker finished</task-notification>"},
        }, False)
        self.assertEqual(notification["role"], "system")

        human = record({
            "type": "user",
            "message": {"role": "user", "content": "Please inspect this change."},
        }, False)
        self.assertEqual(human["role"], "user")
        self.assertFalse(human["isMeta"])
        self.assertEqual(human["blocks"], [{"type": "text", "text": "Please inspect this change.", "truncated": False}])

        quoted_notification = record({
            "type": "user",
            "message": {"role": "user", "content": "The literal <task-notification> tag belongs in our docs."},
        }, False)
        self.assertEqual(quoted_notification["role"], "user")

    def test_claude_compact_summary_is_not_the_human_speaking(self) -> None:
        summary_text = (
            "This session is being continued from a previous conversation that ran out of context.\n\nSummary:\n1."
        )
        record = self.projector["claude_record"]({
            "type": "user",
            "isCompactSummary": True,
            "isVisibleInTranscriptOnly": True,
            "message": {"role": "user", "content": summary_text},
        }, False)
        self.assertEqual(record["type"], "message")
        self.assertEqual(record["role"], "system")
        self.assertTrue(record["isCompactSummary"])
        self.assertEqual(record["blocks"], [{"type": "compact-summary", "text": summary_text, "truncated": False}])

        # The compaction boundary must never seed the thread's opening prompt;
        # the first message the human actually typed still does.
        summary: dict[str, object] = {}
        self.projector["update_projection_summary"](summary, record)
        self.assertNotIn("openingPrompt", summary)
        self.assertIsNone(self.projector["record_search_text"](record))

        human = self.projector["claude_record"]({
            "type": "user",
            "message": {"role": "user", "content": "Keep going on the parser."},
        }, False)
        self.projector["update_projection_summary"](summary, human)
        self.assertEqual(summary["openingPrompt"], "Keep going on the parser.")

    def test_pi_uses_fixed_candidate_when_path_is_missing(self) -> None:
        pi_binary = self.projector["pi_binary"]
        with tempfile.TemporaryDirectory() as temporary:
            candidate = Path(temporary) / "pi"
            candidate.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            candidate.chmod(0o700)
            with mock.patch.object(self.projector["shutil"], "which", return_value=None), mock.patch.object(
                self.projector["os"].path, "expanduser", return_value=str(candidate)
            ):
                self.assertEqual(pi_binary(), str(candidate.resolve()))

    def test_pi_accepts_the_owners_executable_whatever_its_mode(self) -> None:
        # A umask 0002 host leaves the launcher group-writable; the owner
        # decides its mode. A file nobody can execute is still no launcher.
        pi_binary = self.projector["pi_binary"]
        projection_error = self.projector["ProjectionError"]
        with tempfile.TemporaryDirectory() as temporary:
            candidate = Path(temporary) / "pi"
            candidate.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            candidate.chmod(0o777)
            patches = lambda: (mock.patch.object(self.projector["shutil"], "which", return_value=str(candidate)),
                               mock.patch.object(self.projector["os"].path, "expanduser", return_value=str(Path(temporary) / "missing")))
            which, expanduser = patches()
            with which, expanduser:
                self.assertEqual(pi_binary(), str(candidate.resolve()))
            candidate.chmod(0o666)
            which, expanduser = patches()
            with which, expanduser:
                with self.assertRaises(projection_error) as raised:
                    pi_binary()
            self.assertEqual(raised.exception.args, ("permissionDenied",))

    def test_pi_node_launcher_uses_bounded_node_resolution(self) -> None:
        pi_argv = self.projector["pi_argv"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pi = root / "pi"
            node = root / "node"
            pi.write_text("#!/usr/bin/env node\n", encoding="utf-8")
            node.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            pi.chmod(0o700)
            node.chmod(0o700)
            def which(name: str) -> Optional[str]:
                return str(node) if name == "node" else None
            with mock.patch.object(self.projector["shutil"], "which", side_effect=which):
                self.assertEqual(pi_argv(str(pi), "/tmp/snapshot.jsonl"), [
                    str(node.resolve()), str(pi), "--mode", "rpc", "--session", "/tmp/snapshot.jsonl",
                    "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files",
                ])

    def test_pi_snapshot_repairs_only_deleted_cwd_in_the_copy(self) -> None:
        snapshot = self.projector["pi_snapshot_session"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            deleted_cwd = root / "already-deleted"
            header = {"type": "session", "id": "pi-session-1", "version": 3, "cwd": str(deleted_cwd)}
            payload = b'{"type":"message","text":"keep these bytes"}\nsecond payload\n'
            source = root / "source.jsonl"
            source_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8") + b"\n" + payload
            source.write_bytes(source_bytes)
            descriptor = os.open(source, os.O_RDONLY)
            created = None
            try:
                info = os.fstat(descriptor)
                identity = "pi:%x:%x:%x:%x" % (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                created = Path(snapshot(descriptor, identity))
                copied_header, separator, copied_payload = created.read_bytes().partition(b"\n")
                self.assertEqual(separator, b"\n")
                self.assertEqual(copied_payload, payload)
                self.assertEqual(source.read_bytes(), source_bytes)
                repaired = json.loads(copied_header)
                self.assertEqual(repaired["cwd"], str(created.parent))
                self.assertEqual(repaired["id"], header["id"])
                self.assertEqual(repaired["version"], header["version"])
                self.assertFalse(deleted_cwd.exists())
            finally:
                os.close(descriptor)
                if created is not None:
                    created.unlink(missing_ok=True)

    def test_pi_snapshot_leaves_existing_cwd_and_bytes_untouched(self) -> None:
        snapshot = self.projector["pi_snapshot_session"]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            header = {"type": "session", "id": "pi-session-2", "version": 2, "cwd": str(root)}
            source_bytes = json.dumps(header, separators=(",", ":")).encode("utf-8") + b"\nunchanged payload\n"
            source = root / "source.jsonl"
            source.write_bytes(source_bytes)
            descriptor = os.open(source, os.O_RDONLY)
            created = None
            try:
                info = os.fstat(descriptor)
                identity = "pi:%x:%x:%x:%x" % (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
                created = Path(snapshot(descriptor, identity))
                self.assertEqual(created.read_bytes(), source_bytes)
                self.assertEqual(source.read_bytes(), source_bytes)
                self.assertTrue(root.is_dir())
            finally:
                os.close(descriptor)
                if created is not None:
                    created.unlink(missing_ok=True)

    def test_claude_internal_host_records_stay_outside_conversation_projection(self) -> None:
        record = self.projector["claude_record"]
        for source_type in ("bridge-session", "file-history-snapshot"):
            projected = record({"type": source_type, "text": "host state"}, False)
            self.assertEqual(projected["type"], source_type)
            self.assertEqual(projected["provider"], "claude")
            self.assertNotEqual(projected["type"], "message")

    def test_content_array_tool_results_are_plain_joined_text(self) -> None:
        blocks = self.projector["normalized_blocks"]([
            {
                "type": "tool_result",
                "content": [
                    {"type": "text", "text": "first line"},
                    {"type": "text", "text": "second line"},
                ],
            }
        ])
        self.assertEqual(blocks[0]["type"], "tool_result")
        self.assertEqual(blocks[0]["preview"], "first line\nsecond line")
        self.assertNotIn("{", blocks[0]["preview"])

    def test_search_text_uses_canonical_human_blocks_not_record_envelopes(self) -> None:
        search_text = self.projector["record_search_text"]
        pi = self.projector["pi_record"]("pi-session", 0, {
            "role": "assistant", "content": [{"type": "text", "text": "Pi search phrase"}],
        })
        claude = self.projector["claude_record"]({
            "type": "assistant", "message": {"role": "assistant", "content": "Claude search phrase"},
        }, False)
        codex = self.projector["codex_record"](response_item({
            "type": "agent_message", "role": "assistant", "content": [{"type": "output_text", "text": "Codex search phrase"}],
        }), False)
        for record, phrase in ((pi, "Pi search phrase"), (claude, "Claude search phrase"), (codex, "Codex search phrase")):
            excerpt = search_text(record)
            self.assertEqual(excerpt, phrase)
            self.assertNotIn('"role"', excerpt)
            self.assertNotIn('"blocks"', excerpt)

    def test_search_text_skips_metadata_and_keeps_tool_previews_readable(self) -> None:
        search_text = self.projector["record_search_text"]
        self.assertIsNone(search_text({"type": "message", "role": "system", "blocks": [{"type": "text", "text": "hidden"}]}))
        self.assertIsNone(search_text({"type": "message", "role": "user", "isMeta": True, "blocks": [{"type": "text", "text": "hidden"}]}))
        self.assertIsNone(search_text({"type": "metadata", "summary": "hidden"}))
        self.assertIsNone(search_text({"type": "unknown", "sourceType": "hidden"}))
        self.assertEqual(search_text({
            "type": "message", "role": "tool", "blocks": [
                {"type": "tool_call", "preview": "rg search-target"},
                {"type": "tool_result", "output": "search-target found"},
            ],
        }), "rg search-target\nsearch-target found")

    def test_opencode_search_text_extracts_part_content_without_json_envelope(self) -> None:
        search_text = self.projector["opencode_search_text"]
        self.assertEqual(search_text(json.dumps({"type": "tool_result", "output": "OpenCode search phrase"}).encode()), "OpenCode search phrase")
        self.assertEqual(search_text(json.dumps({"type": "step-finish", "reason": "completed cleanly"}).encode()), "completed cleanly")
        self.assertIsNone(search_text(json.dumps({"type": "step-start", "metadata": "hidden"}).encode()))

    def test_codex_modern_user_metadata_filters_internal_items(self) -> None:
        record = self.projector["codex_record"]

        internal = record(response_item({
            "type": "user_message",
            "role": "user",
            "content": [
                {"type": "input_text", "text": "instructions"},
                {"type": "input_text", "text": "environment"},
            ],
            "internal_chat_message_metadata_passthrough": {
                "content_item_kinds": ["agents_md.instructions", "environments.environment_context"],
            },
        }), False)
        self.assertEqual(internal["role"], "system")

        human = record(response_item({
            "type": "user_message",
            "role": "user",
            "content": [{"type": "input_text", "text": "Write the focused test."}],
            "internal_chat_message_metadata_passthrough": {"content_item_kinds": ["user.text"]},
        }), False)
        self.assertEqual(human["role"], "user")

        mixed = record(response_item({
            "type": "user_message",
            "role": "user",
            "content": [
                {"type": "input_text", "text": "agent instructions"},
                {"type": "input_text", "text": "actual request"},
                {"type": "input_text", "text": "environment context"},
            ],
            "internal_chat_message_metadata_passthrough": {
                "content_item_kinds": ["agents_md.instructions", "user.text", "environments.environment_context"],
            },
        }), False)
        self.assertEqual(mixed["role"], "user")
        self.assertEqual(mixed["blocks"], [{"type": "text", "text": "actual request", "truncated": False}])

    def test_codex_reasoning_summary_array_is_plain_thinking_without_empty_entries(self) -> None:
        record = self.projector["codex_record"]
        reasoning = record(response_item({
            "type": "reasoning",
            "summary": [
                {"type": "summary_text", "text": ""},
                {"type": "summary_text", "text": "Checked the projector path."},
            ],
        }), False)
        self.assertEqual(reasoning["role"], "assistant")
        self.assertEqual(reasoning["blocks"], [{
            "type": "thinking",
            "text": "Checked the projector path.",
            "truncated": False,
        }])

    def test_codex_token_count_uses_last_request_not_cumulative_usage(self) -> None:
        record = self.projector["codex_record"]
        tokens = record({
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": 100,
                        "output_tokens": 25,
                        "cached_input_tokens": 50,
                        "reasoning_output_tokens": 5,
                    },
                    "total_token_usage": {"input_tokens": 900, "output_tokens": 200},
                    "model_context_window": 128000,
                },
            },
        }, False)
        self.assertEqual(tokens["type"], "cost-state")
        self.assertEqual(tokens["used_tokens"], 125)
        self.assertEqual(tokens["max_tokens"], 128000)

    def test_codex_session_meta_uses_payload_id_for_title_lookup(self) -> None:
        seen: list[str] = []

        def fake_title(session_id: str) -> str:
            seen.append(session_id)
            return "Projector title"

        self.projector["codex_title"] = fake_title
        record = self.projector["codex_record"]
        meta = record({
            "type": "session_meta",
            "payload": {"id": "session-from-payload-id"},
        }, False)
        self.assertEqual(seen, ["session-from-payload-id"])
        self.assertEqual(meta["title"], "Projector title")


class ProjectorSubprocessFixtureTests(unittest.TestCase):
    def test_writable_transcript_is_discovered_and_projected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-writable-projector-") as temporary:
            home = Path(temporary)
            transcript = self.write_claude_transcript(home, [{
                "type": "user", "sessionId": "fixture-session",
                "message": {"role": "user", "content": "fixture prompt"},
            }])
            for mode in (0o664, 0o666):
                with self.subTest(mode=oct(mode)):
                    transcript.chmod(mode)
                    projected = self.project(home, transcript)
                    self.assertEqual(projected.returncode, 0, projected.stdout)
                    self.assertEqual(self.frames(projected)[-1]["kind"], "end")
                    discovered = subprocess.run([str(PROJECTOR)], input=json.dumps({
                        "v": 1, "kind": "inventory", "provider": "claude",
                    }).encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        env=dict(os.environ, HOME=str(home)), check=False)
                    self.assertEqual(discovered.returncode, 0, discovered.stdout)
                    self.assertIn(b"fixture-session", discovered.stdout)
                    self.assertEqual(transcript.stat().st_mode & 0o777, mode)

    def write_claude_transcript(self, home: Path, rows: list[dict[str, object]]) -> Path:
        transcript = home / ".claude" / "projects" / "fixture" / "conversation.jsonl"
        transcript.parent.mkdir(parents=True, exist_ok=True)
        transcript.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        transcript.chmod(0o600)
        return transcript

    def project(self, home: Path, transcript: Path, *, cursor: Optional[str] = None, limit_bytes: int = 262144, limit_records: int = 100) -> subprocess.CompletedProcess:
        reference = base64.urlsafe_b64encode(str(transcript).encode("utf-8")).decode("ascii").rstrip("=")
        request: dict[str, object] = {
            "v": 1,
            "kind": "project",
            "provider": "claude",
            "transcriptRef": reference,
            "limitBytes": limit_bytes,
            "limitRecords": limit_records,
        }
        if cursor is not None:
            request["cursor"] = cursor
        environment = os.environ.copy()
        environment["HOME"] = str(home)
        return subprocess.run(
            [str(PROJECTOR)],
            input=json.dumps(request).encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            env=environment,
        )

    def frames(self, completed: subprocess.CompletedProcess) -> list[dict[str, object]]:
        return [json.loads(line) for line in completed.stdout.splitlines()]

    def test_small_claude_fixture_projects_through_the_host_executable(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-projector-test-") as temporary:
            home = Path(temporary)
            transcript = self.write_claude_transcript(home, [{
                "type": "user",
                "sessionId": "fixture-session",
                "message": {"role": "user", "content": "fixture prompt"},
            }])
            completed = self.project(home, transcript, limit_records=10)
            self.assertEqual(completed.returncode, 0, completed.stderr.decode("utf-8", "replace"))
            frames = self.frames(completed)
            records = [frame["record"] for frame in frames if frame.get("kind") == "record"]
            self.assertEqual(records, [{
                "type": "message",
                "provider": "claude",
                "role": "user",
                "blocks": [{"type": "text", "text": "fixture prompt", "truncated": False}],
                "isMeta": False,
                "truncated": False,
                "sessionID": "fixture-session",
            }])
            self.assertEqual(frames[-1]["kind"], "end")

    def test_backward_pages_keep_a_full_header_summary_and_no_sequence_gaps(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-projector-pages-") as temporary:
            home = Path(temporary)
            rows: list[dict[str, object]] = [
                {"type": "user", "message": {"role": "user", "content": "The authoritative opening prompt."}},
                {"type": "ai-title", "aiTitle": "Latest native title"},
                {"type": "assistant", "message": {"role": "assistant", "model": "latest-model", "content": "assistant 2"}},
            ]
            rows.extend(
                {"type": "assistant", "message": {"role": "assistant", "content": f"assistant {index}"}}
                for index in range(3, 250)
            )
            rows.append({"type": "assistant", "message": {"role": "assistant", "content": "assistant 250"}})
            self.assertEqual(len(rows), 251)
            transcript = self.write_claude_transcript(home, rows)

            completed_pages: list[subprocess.CompletedProcess] = []
            first = self.project(home, transcript, limit_records=100)
            self.assertEqual(first.returncode, 0, first.stderr.decode("utf-8", "replace"))
            completed_pages.append(first)
            first_frames = self.frames(first)
            first_end = first_frames[-1]

            second = self.project(home, transcript, cursor=first_end["cursor"], limit_records=100)
            self.assertEqual(second.returncode, 0, second.stderr.decode("utf-8", "replace"))
            completed_pages.append(second)
            second_frames = self.frames(second)
            second_end = second_frames[-1]

            third = self.project(home, transcript, cursor=second_end["cursor"], limit_records=100)
            self.assertEqual(third.returncode, 0, third.stderr.decode("utf-8", "replace"))
            completed_pages.append(third)

            expected_pages = [list(range(151, 251)), list(range(51, 151)), list(range(0, 51))]
            page_sequences: list[list[int]] = []
            for completed, expected in zip(completed_pages, expected_pages):
                frames = self.frames(completed)
                headers = [frame for frame in frames if frame.get("kind") == "page"]
                self.assertEqual(len(headers), 1)
                header = headers[0]
                self.assertEqual(header["summary"]["openingPrompt"], "The authoritative opening prompt.")
                self.assertEqual(header["summary"]["title"], "Latest native title")
                self.assertEqual(header["summary"]["model"], "latest-model")
                sequences = [frame["sequence"] for frame in frames if frame.get("kind") == "record"]
                self.assertEqual(sequences, expected)
                self.assertEqual(sequences, sorted(sequences))
                page_sequences.append(sequences)

            self.assertEqual([self.frames(page)[-1]["hasMore"] for page in completed_pages], [True, True, False])
            all_sequences = [sequence for page in page_sequences for sequence in page]
            self.assertEqual(len(all_sequences), len(set(all_sequences)))
            self.assertEqual(sorted(all_sequences), list(range(251)))

    def test_cursor_rejects_a_replaced_source(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-projector-source-change-") as temporary:
            home = Path(temporary)
            transcript = self.write_claude_transcript(home, [
                {"type": "user", "message": {"role": "user", "content": "before replacement"}},
                {"type": "assistant", "message": {"role": "assistant", "content": "before replacement reply"}},
            ])
            initial = self.project(home, transcript, limit_records=1)
            self.assertEqual(initial.returncode, 0, initial.stderr.decode("utf-8", "replace"))
            cursor = self.frames(initial)[-1]["cursor"]
            self.write_claude_transcript(home, [{
                "type": "user",
                "message": {"role": "user", "content": "after replacement"},
            }])

            replaced = self.project(home, transcript, cursor=cursor, limit_records=1)
            self.assertNotEqual(replaced.returncode, 0)
            frames = self.frames(replaced)
            self.assertEqual(len(frames), 1)
            self.assertEqual(frames[0]["error"], "sourceChanged")
            self.assertNotIn("path", frames[0].get("diagnostics", {}))

    def test_large_tool_line_drains_and_small_pages_keep_the_newest_contiguous_suffix(self) -> None:
        with tempfile.TemporaryDirectory(prefix="tessera-projector-drain-") as temporary:
            home = Path(temporary)
            transcript = self.write_claude_transcript(home, [
                {"type": "user", "message": {"role": "user", "content": "opening"}},
                {"type": "tool_result", "text": "x" * 1_048_577},
                {"type": "assistant", "message": {"role": "assistant", "content": "trailing final prose"}},
            ])
            drained = self.project(home, transcript, limit_records=10)
            self.assertEqual(drained.returncode, 0, drained.stderr.decode("utf-8", "replace"))
            drained_records = [frame["record"] for frame in self.frames(drained) if frame.get("kind") == "record"]
            self.assertEqual(drained_records[-1]["blocks"][0]["text"], "trailing final prose")

            compact_rows = [
                {"type": "assistant", "message": {"role": "assistant", "content": f"{index:03d}-" + ("m" * 1_000)}}
                for index in range(40)
            ]
            compact = self.write_claude_transcript(home, compact_rows)
            bounded = self.project(home, compact, limit_bytes=8_192, limit_records=100)
            self.assertEqual(bounded.returncode, 0, bounded.stderr.decode("utf-8", "replace"))
            self.assertLessEqual(len(bounded.stdout), 8_192)
            sequences = [frame["sequence"] for frame in self.frames(bounded) if frame.get("kind") == "record"]
            self.assertTrue(sequences)
            self.assertLess(sequences[0], 39)
            self.assertEqual(sequences, list(range(sequences[0], 40)))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
