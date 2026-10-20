#!/usr/bin/env python3
"""Cold-start endpoint correctness; only private deterministic fixtures."""
import importlib.util
import json
from pathlib import Path
import subprocess
import shlex
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("benchmark", Path(__file__).resolve().parents[1] / "agent_center_benchmark.py")
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)
CONSUMER = str(Path(sys.argv.pop()).resolve())


def frames():
    return [{"v": 1, "kind": "page", "sourceIdentity": "fixture"},
            {"v": 1, "kind": "record", "sequence": 1, "recordID": "1", "sourceOffset": 0,
             "record": {"type": "message", "role": "assistant", "blocks": [{"type": "text", "text": "hello"}]}},
            {"v": 1, "kind": "end", "hasMore": False}]


def consume(values, exit_status=0):
    payload = b"".join(json.dumps(value, ensure_ascii=False).encode() + b"\n" for value in values)
    return subprocess.run([CONSUMER, "codex", str(exit_status)], input=payload, capture_output=True, timeout=10)


class FirstPageTests(unittest.TestCase):
    def test_complete_page_is_applied_and_exposes_message(self):
        result = consume(frames())
        self.assertEqual(result.returncode, 0, result.stderr)
        row = json.loads(result.stdout)
        self.assertEqual(row["renderable_records"], 1)
        self.assertEqual(row["renderable_messages"], 1)
        self.assertGreater(row["consumer_peak_rss_bytes"], 0)

    def test_header_or_record_without_end_is_not_renderable(self):
        for count in [1, 2]:
            with self.subTest(count=count):
                result = consume(frames()[:count])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")

    def test_nonzero_exit_is_not_renderable(self):
        result = consume(frames(), 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")

    def test_complete_end_frame_does_not_finish_timer_before_helper_exit(self):
        payload = "".join(json.dumps(value) + "\n" for value in frames())
        script = ("import sys,time,json; "
                  f"sys.stdout.write({payload!r}); sys.stdout.flush(); time.sleep(0.2); "
                  "sys.stderr.write(json.dumps({'peak_rss_bytes':1,'cpu_ms':0}))")
        shell = shlex.quote(sys.executable) + " -c " + shlex.quote(script)
        with tempfile.TemporaryDirectory() as folder:
            row = bench.shell_trial(shell, Path(folder) / "unused.jsonl", "codex", 5,
                                    phase="initial", consumer=CONSUMER)
        self.assertEqual(row["status"], "ok")
        self.assertGreaterEqual(row["helper_wall_ms"], 200)
        self.assertGreater(row["page_renderable_ms"], row["helper_wall_ms"])

    def test_invalid_or_oversized_page_is_not_renderable(self):
        variants = [frames() + [frames()[1]], frames() * 2,
                    [frames()[0]] + [frames()[1]] * 101 + [frames()[2]]]
        for values in variants:
            with self.subTest(size=len(values)):
                self.assertNotEqual(consume(values).returncode, 0)

    def test_frame_split_and_utf8_across_transport_chunks(self):
        values = frames()
        values[1]["record"]["blocks"][0]["text"] = "é😀" * 1000
        self.assertEqual(consume(values).returncode, 0)

    def test_real_helper_cold_request_has_renderable_endpoint_and_no_cursor(self):
        for provider in ["codex", "claude"]:
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / "fixture.jsonl"
                value = ({"type": "response_item", "payload": {"type": "message", "role": "assistant",
                          "content": [{"type": "output_text", "text": "cold message"}]}} if provider == "codex" else
                         {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "cold message"}]}})
                path.write_text(json.dumps(value) + "\n")
                rows = bench.worker({"path": str(path), "mode": "cold", "provider": provider,
                                     "repeats": 3, "timeout": 10, "first_page_consumer": CONSUMER})
                self.assertEqual(len(rows), 1)
                row = rows[0]
                self.assertEqual(row["renderable_messages"], 1)
                self.assertEqual(row["renderable_records"], row["records"])
                self.assertFalse(row["continued"])
                self.assertEqual(row["append_bytes"], 0)
                self.assertGreater(row["page_renderable_ms"], row["helper_wall_ms"])
                self.assertEqual(row["wall_ms"], row["page_renderable_ms"])


if __name__ == "__main__":
    unittest.main()
