#!/usr/bin/env python3
"""Scripted Anthropic Messages API for driving the real Claude Code TUI.

The newest user turn selects the script: a prompt containing a SCRIPT:<name>
token answers with that tool call; a tool_result answers with plain text.
Only the last prompt/tool result is appended to a run-private JSONL log.
"""
import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOG = Path(sys.argv[3])

LEVER = {"question": "Which lever should the importer try first? The nightly import (src/…/import/ledger_job.py, 400 rows "
                     "per batch) now spends 71% of its time re-reading the same vendor table, and the cache that would "
                     "fix it doubles peak memory to about 3.2 GB on the smallest worker. Batching the vendor reads keeps "
                     "memory flat but only saves about a third of the time, and it changes the order the audit log sees. "
                     "Which one should I try first, keeping the audit order stable?",
         "header": "Import lever", "multiSelect": False,
         "options": [{"label": "Batch the vendor reads", "description": "Flat memory, about a third faster."},
                     {"label": "Add the vendor cache", "description": "Fastest, but 3.2 GB peak on small workers."}]}
RELEASE = {"question": "The release branch test suite passes on release/2026-09-ledger (tip 4c1e9a7b2). All 14 suites "
                       "pass, the parity audit reports 0 failures, and the output is identical to the current main. "
                       "Fast-forward main to it now?",
           "header": "Release", "multiSelect": False,
           "options": [{"label": "Fast-forward", "description": "Move main to the release tip."},
                       {"label": "Wait for review", "description": "Leave main where it is."}]}
AUDIT = {"question": "Open item from the last round: a vendor payment is checked for currency, limits and funds, but not "
                     "for the holiday calendar. A payment due on a bank holiday reads settle_early=true, then gets "
                     "dropped when the batch closes at the cut-off. Both ledgers agree, so parity holds, but the "
                     "published total is optimistic. Fix it?",
         "header": "Audit check", "multiSelect": False,
         "options": [{"label": "Fix it now", "description": "Check the holiday calendar before settling."},
                     {"label": "Log it", "description": "Record it for the next round."}]}
ROLLBACK = {"question": "If the fast-forward goes wrong, should the rollback restore the previous main tip and replay the "
                        "three ledger migrations in reverse, or keep main and ship a revert commit? Replaying takes about "
                        "twenty minutes and needs the ledger writer stopped; a revert commit is instant but leaves the "
                        "migrations applied until the next release, which the parity audit would then flag every night.",
            "header": "Rollback", "multiSelect": False,
            "options": [{"label": "Replay in reverse", "description": "Restore the previous tip."},
                        {"label": "Revert commit", "description": "Keep main, revert on top."}]}

SCRIPTS = {
    "ask1": ("AskUserQuestion", {"questions": [{
        "question": "Which database should the service use for the new ledger?",
        "header": "Database",
        "multiSelect": False,
        "options": [
            {"label": "Postgres (Recommended)", "description": "Mature, transactional, already deployed."},
            {"label": "SQLite", "description": "Embedded file, zero operations."},
            {"label": "DynamoDB", "description": "Managed key-value store."},
        ],
    }]}),
    "ask3": ("AskUserQuestion", {"questions": [
        {"question": "Which database should the service use?", "header": "Database", "multiSelect": False,
         "options": [{"label": "Postgres", "description": "Transactional."},
                     {"label": "SQLite", "description": "Embedded."}]},
        {"question": "Which features should ship first?", "header": "Features", "multiSelect": True,
         "options": [{"label": "Search", "description": "Full-text search."},
                     {"label": "Export", "description": "CSV export."},
                     {"label": "Sharing", "description": "Share links."}]},
        {"question": "Should I open a pull request when done?", "header": "PR", "multiSelect": False,
         "options": [{"label": "Yes", "description": "Open a draft PR."},
                     {"label": "No", "description": "Leave the branch."}]},
    ]}),
    # A long question over long options, as a real planning question reads:
    # Claude draws it behind a quote rail, and a phone-width pane wraps the
    # rows and the key hints.
    "askwide": ("AskUserQuestion", {"questions": [
        {"question": "Which plan should the next run use? The last run of the ledger import (src/…/import/batch_job.py, "
                     "120 rows per batch) finished in 244 s against a 164–190 s budget, and the retry pass after it took "
                     "62.6 s for 33,945 rows. The fast path is about 1.7× quicker than the current one, but it skips the "
                     "checksum pass, so a corrupt batch would only show up in the nightly audit. Which trade-off do you want?",
         "header": "Run plan", "multiSelect": False,
         "options": [{"label": "Keep the current plan (safe)",
                      "description": "Run the same batches with the checksum pass on every batch, and report the timing "
                                     "against the 164–190 s budget again so the regression is visible: −23.63% → about −13%."},
                     {"label": "Switch to the fast path",
                      "description": "Skip the checksum pass for this run, keep a copy of every batch, and rely on the "
                                     "nightly audit to catch a corrupt one."},
                     {"label": "Stop and report", "description": "Stop now and report the partial timings."}]},
        {"question": "Should I post the report to the team channel?", "header": "Report", "multiSelect": False,
         "options": [{"label": "Yes", "description": "Post it."}, {"label": "No", "description": "Keep it local."}]},
    ]}),
    # Reviews taller than 30 rows at phone width: three long questions, the
    # last answered in its text row; then four, taller than a 48-row pane.
    "askreview": ("AskUserQuestion", {"questions": [LEVER, RELEASE, AUDIT]}),
    "tallreview": ("AskUserQuestion", {"questions": [LEVER, RELEASE, AUDIT, ROLLBACK]}),
    "plan": ("ExitPlanMode", {"plan": "## Plan\n\n1. Add a ledger table.\n2. Write the migration.\n3. Add tests."}),
    "bash": ("Bash", {"command": "python3 hello.py", "description": "Run hello.py"}),
    "edit": ("Edit", {"file_path": "__WORK__/hello.py", "old_string": "print('hello')", "new_string": "print('hello, world')"}),
    "write": ("Write", {"file_path": "__WORK__/new_file.txt", "content": "fresh file\n"}),
}

WORK = sys.argv[2] if len(sys.argv) > 2 else ""


def last_user_content(body):
    for message in reversed(body.get("messages", [])):
        if message.get("role") == "user":
            return message.get("content")
    return None


def choose(body):
    content = last_user_content(body)
    blocks = content if isinstance(content, list) else [{"type": "text", "text": content or ""}]
    text = " ".join(b.get("text", "") for b in blocks if isinstance(b, dict) and b.get("type") == "text")
    if "SCRIPT:" not in text and any(b.get("type") == "tool_result" for b in blocks if isinstance(b, dict)):
        result = next(b for b in blocks if isinstance(b, dict) and b.get("type") == "tool_result")
        return ("text", "Tool result received: " + json.dumps(result.get("content"))[:300])
    text = " ".join(b.get("text", "") for b in blocks if isinstance(b, dict) and b.get("type") == "text")
    for name, script in SCRIPTS.items():
        if f"SCRIPT:{name}" in text:
            tool, payload = script
            raw = json.dumps(payload).replace("__WORK__", WORK)
            return ("tool", tool, raw)
    return ("text", "OK.")


def sse(handler, event, data):
    handler.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
    handler.wfile.flush()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        raw = self.rfile.read(length)
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}
        content = last_user_content(body)
        with LOG.open("a") as log:
            log.write(json.dumps({"path": self.path, "model": body.get("model"),
                                  "last": content}, ensure_ascii=False) + "\n")
        if "count_tokens" in self.path:
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"input_tokens": 10}')
            return
        plan = choose(body)
        model = body.get("model", "claude-sonnet-5-5")
        message_id = "msg_" + uuid.uuid4().hex[:24]
        usage = {"input_tokens": 10, "output_tokens": 5}
        if not body.get("stream"):
            if plan[0] == "tool":
                content = [{"type": "tool_use", "id": "toolu_" + uuid.uuid4().hex[:20], "name": plan[1], "input": json.loads(plan[2])}]
                stop = "tool_use"
            else:
                content = [{"type": "text", "text": plan[1]}]
                stop = "end_turn"
            out = json.dumps({"id": message_id, "type": "message", "role": "assistant", "model": model,
                              "content": content, "stop_reason": stop, "usage": usage}).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(out)))
            self.end_headers()
            self.wfile.write(out)
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        sse(self, "message_start", {"type": "message_start", "message": {
            "id": message_id, "type": "message", "role": "assistant", "model": model, "content": [],
            "stop_reason": None, "stop_sequence": None, "usage": usage}})
        if plan[0] == "tool":
            sse(self, "content_block_start", {"type": "content_block_start", "index": 0, "content_block": {
                "type": "tool_use", "id": "toolu_" + uuid.uuid4().hex[:20], "name": plan[1], "input": {}}})
            sse(self, "content_block_delta", {"type": "content_block_delta", "index": 0,
                                              "delta": {"type": "input_json_delta", "partial_json": plan[2]}})
            stop = "tool_use"
        else:
            sse(self, "content_block_start", {"type": "content_block_start", "index": 0,
                                              "content_block": {"type": "text", "text": ""}})
            sse(self, "content_block_delta", {"type": "content_block_delta", "index": 0,
                                              "delta": {"type": "text_delta", "text": plan[1]}})
            stop = "end_turn"
        sse(self, "content_block_stop", {"type": "content_block_stop", "index": 0})
        sse(self, "message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                    "usage": {"output_tokens": 5}})
        sse(self, "message_stop", {"type": "message_stop"})


if __name__ == "__main__":
    port = int(sys.argv[1])
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
