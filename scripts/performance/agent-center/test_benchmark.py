#!/usr/bin/env python3
"""Deterministic benchmark validity tests; no real sessions, hosts or models."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location("benchmark", Path(__file__).resolve().parents[1] / "agent_center_benchmark.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)
DUMP = Path(sys.argv.pop()) if len(sys.argv) == 2 and sys.argv[-1].endswith(".sh") else None


def record(provider, text):
    if provider == "codex":
        value = {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}}
    else:
        value = {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}
    return json.dumps(value).encode() + b"\n"


class BenchmarkTests(unittest.TestCase):
    @unittest.skipUnless(DUMP, "Swift dumper comparison runs in host integration gate")
    def test_extraction_is_exact_swift_output(self):
        self.assertEqual(bench.production_shell().encode(), DUMP.read_bytes())

    def test_discovery_ranks_size_deduplicates_and_ignores_symlinks(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "small.jsonl").write_bytes(b"{}\n")
            (root / "big.jsonl").write_bytes(b"{}\n" * 9)
            (root / "ignore.json").write_bytes(b"x" * 100)
            (root / "link.jsonl").symlink_to(root / "big.jsonl")
            ranked, inventory = bench.discover([root, root], 1)
            self.assertEqual(ranked, [(27, str(root / "big.jsonl"))])
            self.assertEqual(inventory["files"], 2)

    def test_snapshot_large_lines_and_partial_tail(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "source.jsonl"
            data = b"x" * (bench.MIB + 15) + b"\n{}\npartial"
            source.write_bytes(data)
            meta = bench.snapshot(source, root / "snapshot.jsonl")
            self.assertEqual(meta["max_complete_line_bytes"], bench.MIB + 15)
            self.assertEqual(meta["complete_lines"], 2)
            self.assertEqual(meta["partial_tail_bytes"], 7)
            self.assertEqual((root / "snapshot.jsonl").read_bytes(), data[:-7])
            self.assertEqual(source.read_bytes(), data)

    def test_replay_suffix_starts_at_record_boundary(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.jsonl"
            path.write_bytes(b"a" * 100 + b"\n{}\n{\"a\":1}\n")
            self.assertEqual(bench.replay_suffix(path, 15), b"{}\n{\"a\":1}\n")

    def test_production_and_offset_semantics_and_read_amplification(self):
        for provider in ["codex", "claude"]:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "fixture.jsonl"
                path.write_bytes(b"".join(record(provider, str(i)) for i in range(130)))
                scope = bench.namespace(path.parent)
                counted = bench.CountedOS()
                scope["os"] = counted
                initial = bench.projected(scope, path, provider)
                self.assertEqual(initial["records"], 100)
                self.assertEqual(counted.bytes, path.stat().st_size)
                counted.bytes = 0
                unchanged = bench.projected(scope, path, provider, initial["cursor"])
                self.assertEqual(unchanged["semantic_sha256"], initial["semantic_sha256"])
                self.assertEqual(counted.bytes, path.stat().st_size)
                old_size = path.stat().st_size
                with path.open("ab") as file:
                    file.write(record(provider, "new"))
                counted.bytes = 0
                updated = bench.projected(scope, path, provider, unchanged["cursor"])
                self.assertTrue(updated["continued"])
                self.assertEqual(counted.bytes, old_size + path.stat().st_size)
                rows = bench.worker({"path": str(path), "provider": provider, "mode": "offset", "repeats": 2})
                self.assertEqual(rows[1]["new_records"], 0)
                self.assertEqual(rows[1]["bytes_scanned"], 0)
                self.assertEqual(rows[3]["bytes_scanned"], rows[3]["append_bytes"])

    def test_offset_buffers_partial_record_until_newline(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.jsonl"
            data = record("codex", "café")
            path.write_bytes(data[:-2])
            control = bench.OffsetControl(bench.namespace(path.parent), path, "codex")
            self.assertEqual(control.update()["new_records"], 0)
            with path.open("ab") as file:
                file.write(data[-2:])
            self.assertEqual(control.update()["new_records"], 1)
            self.assertEqual(control.offset, len(data))

    def test_rewrite_is_not_claimed_as_continuation(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.jsonl"
            path.write_bytes(record("codex", "before"))
            scope = bench.namespace(path.parent)
            first = bench.projected(scope, path, "codex")
            path.write_bytes(record("codex", "rewrite"))
            second = bench.projected(scope, path, "codex", first["cursor"])
            self.assertFalse(second["continued"])

    def test_raw_baseline_counts_invalid_records(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "fixture.jsonl"
            path.write_bytes(b"{}\ninvalid\n[]\n")
            result = bench.raw_decode(path)
            self.assertEqual(result["valid_records"], 2)
            self.assertEqual(result["invalid_records"], 1)

    def test_timeout_preserves_completed_rows(self):
        script = 'import json,time; print(json.dumps({"progress":{"phase":"initial","wall_ms":1,"peak_rss_bytes":1}}),flush=True); time.sleep(10)'
        with mock.patch.object(bench.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="")):
            result = bench.supervised([sys.executable, "-c", script], b"", 0.3, 32)
        self.assertEqual(result["status"], "timeout")
        self.assertEqual(len(result["completed_rows"]), 1)

    def test_failed_worker_never_exports_stderr_content(self):
        script = 'import sys; print("private transcript",file=sys.stderr); sys.exit(1)'
        with mock.patch.object(bench.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout="")):
            result = bench.supervised([sys.executable, "-c", script], b"", 2, 32)
        self.assertEqual(result["status"], "worker_failed")
        self.assertNotIn("private transcript", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
