#!/usr/bin/env python3
"""Scripted OpenAI Responses API for driving the real Codex TUI.

A user message containing SCRIPT:<name> answers with that function call.
The follow-up after a request_user_input_async output holds the stream open
(HOLD seconds, or until the lane releases it) so the turn keeps running and
the async question stays pending.
"""
import json
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOG = Path(sys.argv[4])
# The lane creates this once Codex has queued the async answers, ending the
# held turn so Codex submits them in its next request.
RELEASE = LOG.with_name("release-hold")
CATALOG = Path(sys.argv[2]) if len(sys.argv) > 2 else None
HOLD = float(sys.argv[3]) if len(sys.argv) > 3 else 240

SCRIPTS = {
    "async1": ("request_user_input_async", {"questions": [{
        "title": "Which database should the service use for the new ledger?",
        "options": ["Postgres", "SQLite", "DynamoDB"]}]}),
    "async2": ("request_user_input_async", {"questions": [
        {"title": "Which database should the service use?", "options": ["Postgres", "SQLite"]},
        {"title": "Describe the rollout window you prefer."}]}),
    "asyncfree": ("request_user_input_async", {"questions": [{"title": "What should the release be called?"}]}),
    "rui": ("request_user_input", {"questions": [{
        "id": "database", "header": "Database", "question": "Which database should we use?",
        "options": [{"label": "Postgres (Recommended)", "description": "Transactional and deployed."},
                    {"label": "SQLite", "description": "Embedded, zero operations."}]}]}),
    "shell": ("shell_command", {"command": "python3 hello.py", "workdir": None}),
    "exec": ("exec_command", {"cmd": "python3 hello.py", "sandbox_permissions": "require_escalated", "justification": "Run the hello script outside the sandbox"}),
}


def input_items(body):
    items = body.get("input")
    return items if isinstance(items, list) else []


def choose(body):
    items = input_items(body)
    last = items[-1] if items else {}
    if last.get("type") in ("function_call_output", "custom_tool_call_output"):
        output = str(last.get("output"))
        if "accepted" in output:
            return ("hold", "Continuing while you think about it.")
        return ("text", "Tool output: " + output[:200])
    texts = []
    for item in items:
        if item.get("type") == "message" and item.get("role") == "user":
            for part in item.get("content", []):
                if isinstance(part, dict) and part.get("text"):
                    texts.append(part["text"])
    newest = texts[-1] if texts else ""
    for name, (tool, payload) in SCRIPTS.items():
        if f"SCRIPT:{name}" in newest:
            return ("tool", tool, json.dumps(payload))
    return ("text", "OK.")


def event(handler, data):
    handler.wfile.write(f"event: {data['type']}\ndata: {json.dumps(data)}\n\n".encode())
    handler.wfile.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply_json(self, payload):
        out = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_GET(self):
        if self.path.startswith("/v1/models") and CATALOG:
            self.reply_json(json.loads(CATALOG.read_text()))
        else:
            self.reply_json({})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("content-length", 0)))
        try:
            body = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            body = {}
        items = input_items(body)
        prompts = []
        for item in items:
            if item.get("type") in ("function_call_output", "custom_tool_call_output"):
                prompts.append({"type": item["type"], "output": item.get("output")})
            elif item.get("type") == "message" and item.get("role") == "user":
                prompts.append({"type": "user", "content": item.get("content")})
        with LOG.open("a") as log:
            log.write(json.dumps({"path": self.path, "model": body.get("model"),
                                  "prompts": prompts[-20:]}, ensure_ascii=False) + "\n")
        if not self.path.startswith("/v1/responses"):
            self.reply_json({})
            return
        plan = choose(body)
        response_id = "resp_" + uuid.uuid4().hex[:16]
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()
        event(self, {"type": "response.created", "response": {"id": response_id}})
        if plan[0] == "tool":
            item = {"type": "function_call", "id": "fc_" + uuid.uuid4().hex[:12], "name": plan[1],
                    "arguments": plan[2], "call_id": "call_" + uuid.uuid4().hex[:12]}
            event(self, {"type": "response.output_item.added", "output_index": 0, "item": item})
            event(self, {"type": "response.output_item.done", "output_index": 0, "item": item})
        else:
            if plan[0] == "hold":
                deadline = time.time() + HOLD
                # Codex's title request repeats the held turn's input, so the
                # release stays in place for every hold.
                while time.time() < deadline and not RELEASE.exists():
                    time.sleep(0.25)
            item = {"type": "message", "role": "assistant", "id": "msg_" + uuid.uuid4().hex[:12],
                    "content": [{"type": "output_text", "text": plan[1], "annotations": []}]}
            event(self, {"type": "response.output_item.added", "output_index": 0, "item": item})
            event(self, {"type": "response.output_item.done", "output_index": 0, "item": item})
        event(self, {"type": "response.completed", "response": {"id": response_id, "usage": {
            "input_tokens": 10, "input_tokens_details": None, "output_tokens": 5,
            "output_tokens_details": None, "total_tokens": 15}}})
        self.close_connection = True


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
