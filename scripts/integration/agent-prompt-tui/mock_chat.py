#!/usr/bin/env python3
"""Scripted OpenAI-compatible Chat Completions API for driving the Kimi Code TUI."""
import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOG = Path(sys.argv[3])
WORK = sys.argv[2] if len(sys.argv) > 2 else ""

SCRIPTS = {
    "ask1": ("AskUserQuestion", {"questions": [{
        "question": "Which database should the service use for the new ledger?",
        "header": "Database",
        "options": [{"label": "Postgres", "description": "Mature and transactional."},
                    {"label": "SQLite", "description": "Embedded file."}]}]}),
    "ask2": ("AskUserQuestion", {"questions": [
        {"question": "Which database should the service use?", "header": "Database",
         "options": [{"label": "Postgres", "description": "Transactional."},
                     {"label": "SQLite", "description": "Embedded."}]},
        {"question": "Which features should ship first?", "header": "Features", "multi_select": True,
         "options": [{"label": "Search", "description": "Full-text search."},
                     {"label": "Export", "description": "CSV export."}]}]}),
    "askbg": ("AskUserQuestion", {"background": True, "questions": [{
        "question": "Which region should host the ledger?", "header": "Region",
        "options": [{"label": "eu-west-1", "description": "Ireland."}, {"label": "us-east-1", "description": "Virginia."}]}]}),
    # A review taller than the panel's old 24-row reach at phone width.
    "askreview": ("AskUserQuestion", {"questions": [
        {"question": "Which lever should the importer try first? The nightly import now spends 71% of its time "
                     "re-reading the same vendor table, and the cache that would fix it doubles peak memory to about "
                     "3.2 GB on the smallest worker. Batching the vendor reads keeps memory flat but only saves about a "
                     "third of the time. Which one should I try first?",
         "header": "Import lever",
         "options": [{"label": "Batch the vendor reads", "description": "Flat memory, about a third faster."},
                     {"label": "Add the vendor cache", "description": "Fastest, but 3.2 GB peak."}]},
        {"question": "The release branch test suite passes on release/2026-09-ledger. All 14 suites pass and the "
                     "parity audit reports 0 failures. Fast-forward main to it now?",
         "header": "Release",
         "options": [{"label": "Fast-forward", "description": "Move main to the release tip."},
                     {"label": "Wait for review", "description": "Leave main where it is."}]},
        {"question": "A vendor payment is checked for currency, limits and funds, but not for the holiday calendar, "
                     "so a payment due on a bank holiday is dropped at the cut-off. Both ledgers agree, but the "
                     "published total is optimistic. Fix it?",
         "header": "Audit check",
         "options": [{"label": "Fix it now", "description": "Check the calendar before settling."},
                     {"label": "Log it", "description": "Record it for the next round."}]}]}),
    # Four long questions: at phone width the review outgrows the pane.
    "tallreview": ("AskUserQuestion", {"questions": [
        {"question": "Which lever should the importer try first? The nightly import (src/…/import/ledger_job.py, 400 "
                     "rows per batch) now spends 71% of its time re-reading the same vendor table, and the cache that "
                     "would fix it doubles peak memory to about 3.2 GB on the smallest worker. Batching the vendor "
                     "reads keeps memory flat but only saves about a third of the time, and it changes the order the "
                     "audit log sees. Which one should I try first, keeping the audit order stable?",
         "header": "Import lever",
         "options": [{"label": "Batch the vendor reads", "description": "Flat memory."},
                     {"label": "Add the vendor cache", "description": "Fastest."}]},
        {"question": "The release branch test suite passes on release/2026-09-ledger (tip 4c1e9a7b2). All 14 suites "
                     "pass, the parity audit reports 0 failures, and the output is identical to the current main. "
                     "Fast-forward main to it now?",
         "header": "Release",
         "options": [{"label": "Fast-forward", "description": "Move main."},
                     {"label": "Wait for review", "description": "Leave main."}]},
        {"question": "Open item from the last round: a vendor payment is checked for currency, limits and funds, but "
                     "not for the holiday calendar. A payment due on a bank holiday reads settle_early=true, then gets "
                     "dropped when the batch closes at the cut-off. Both ledgers agree, so parity holds, but the "
                     "published total is optimistic. Fix it?",
         "header": "Audit check",
         "options": [{"label": "Fix it now", "description": "Check the calendar."},
                     {"label": "Log it", "description": "Record it."}]},
        {"question": "If the fast-forward goes wrong, should the rollback restore the previous main tip and replay "
                     "the three ledger migrations in reverse, or keep main and ship a revert commit? Replaying takes "
                     "about twenty minutes and needs the ledger writer stopped; a revert commit is instant but leaves "
                     "the migrations applied until the next release, which the parity audit would then flag nightly.",
         "header": "Rollback",
         "options": [{"label": "Replay in reverse", "description": "Restore the tip."},
                     {"label": "Revert commit", "description": "Revert on top."}]}]}),
    "bash": ("Bash", {"command": "python3 hello.py"}),
    "bash2": ("Bash", {"command": "python3 hello.py"}),
    "plan": ("ExitPlanMode", {"plan": "1. Add a ledger table.\n2. Write the migration."}),
}


def choose(body):
    messages = body.get("messages", [])
    last = messages[-1] if messages else {}
    if last.get("role") == "tool":
        return ("text", "Tool result: " + str(last.get("content"))[:300])
    if last.get("role") == "user" and "<notification " in str(last.get("content", "")):
        return ("text", "Notification received.")
    users = [m for m in messages if m.get("role") == "user"]
    texts = [m.get("content") if isinstance(m.get("content"), str) else json.dumps(m.get("content")) for m in users]
    text = next((t for t in reversed(texts) if "SCRIPT:" in (t or "")), "")
    for name, script in SCRIPTS.items():
        if f"SCRIPT:{name}" in (text or ""):
            return ("tool", script[0], json.dumps(script[1]))
    return ("text", "OK.")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_json(self, payload):
        out = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        self.send_json({"data": [{"id": "mock-model", "object": "model"}]})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}
        with LOG.open("a") as log:
            last = (body.get("messages") or [None])[-1]
            log.write(json.dumps({"path": self.path, "last": last}, ensure_ascii=False) + "\n")
        plan = choose(body)
        cid = "chatcmpl-" + uuid.uuid4().hex[:12]
        model = body.get("model", "mock-model")
        if not body.get("stream"):
            message = {"role": "assistant", "content": plan[1] if plan[0] == "text" else None}
            if plan[0] == "tool":
                message["tool_calls"] = [{"id": "call_" + uuid.uuid4().hex[:10], "type": "function",
                                          "function": {"name": plan[1], "arguments": plan[2]}}]
            self.send_json({"id": cid, "object": "chat.completion", "model": model, "choices": [
                {"index": 0, "message": message, "finish_reason": "tool_calls" if plan[0] == "tool" else "stop"}],
                "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("connection", "close")
        self.end_headers()

        def chunk(delta, finish=None):
            payload = {"id": cid, "object": "chat.completion.chunk", "model": model,
                       "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

        chunk({"role": "assistant"})
        if plan[0] == "tool":
            chunk({"tool_calls": [{"index": 0, "id": "call_" + uuid.uuid4().hex[:10], "type": "function",
                                   "function": {"name": plan[1], "arguments": plan[2]}}]})
            chunk({}, "tool_calls")
        else:
            chunk({"content": plan[1]})
            chunk({}, "stop")
        usage = {"id": cid, "object": "chat.completion.chunk", "model": model, "choices": [],
                 "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}
        self.wfile.write(f"data: {json.dumps(usage)}\n\ndata: [DONE]\n\n".encode())
        self.wfile.flush()
        self.close_connection = True


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
