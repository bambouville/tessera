#!/usr/bin/env python3
"""Run real provider TUIs against local scripted APIs in disposable tmux servers."""

import json
import os
from pathlib import Path
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
from urllib.request import urlopen


RUN = Path(sys.argv[1]).resolve()
REPO = Path(sys.argv[2]).resolve()
DUMPER = Path(sys.argv[3]).resolve()
DRIVER = Path(sys.argv[4]).resolve()
SOCKET_PREFIX = sys.argv[5]
# Pane geometry: a desktop terminal, or a phone's (the apps size the tmux
# window to the device, and a narrow pane wraps the dialogs' rows).
SIZE = os.environ.get("TESSERA_AGENT_PROMPT_TUI_SIZE", "110x40")
COLUMNS, ROWS = SIZE.split("x")
SOURCE = Path(__file__).resolve().parent
HOME = RUN / "home"
EVIDENCE = RUN / "evidence"
DIAGNOSTICS = HOME / ".config/tessera/agent-lifecycle-diagnostics.log"
MOCK_KEY = "sk-ant-mock-probe"
# The caller may have Tessera's real-home PATH shims ahead of the CLI binaries.
# Do not invoke those shims from a disposable lane.
PROVIDER_PATH = os.pathsep.join(part for part in os.environ.get("PATH", "").split(os.pathsep)
                                if part and not part.rstrip("/").endswith("/.config/tessera/bin"))
PROVIDERS = {name: shutil.which(name, path=PROVIDER_PATH)
             for name in ("claude", "codex", "kimi")}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(args, *, env=None, cwd=None, check=True, timeout=30):
    result = subprocess.run(args, env=env, cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stdout[-2500:]}")
    return result


def private_env():
    # In particular, do not inherit provider credentials, auth environment,
    # XDG paths, shell startup locations, or the caller's HOME.
    result = {"HOME": str(HOME), "PATH": PROVIDER_PATH or "/usr/bin:/bin",
              "SHELL": "/bin/zsh", "TERM": "xterm-256color",
              "LANG": os.environ.get("LANG", "en_US.UTF-8"),
              "CODEX_HOME": str(RUN / "codex-home"),
              "KIMI_CODE_HOME": str(RUN / "kimi-home"),
              "CLAUDE_CONFIG_DIR": str(HOME / ".claude"),
              "MOCK_OPENAI_KEY": "mock", "ANTHROPIC_API_KEY": MOCK_KEY,
              "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}
    return result


def pick_port():
    try:
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            return sock.getsockname()[1]
    except PermissionError as error:
        raise RuntimeError(f"loopback bind denied by this environment: {error}") from error


def start_mock(provider, port, work):
    log = EVIDENCE / provider / "mock-prompts.jsonl"
    script = {"claude": "mock_anthropic.py", "codex": "mock_responses.py",
              "kimi": "mock_chat.py"}[provider]
    args = [sys.executable, "-u", str(SOURCE / script), str(port)]
    if provider == "claude" or provider == "kimi":
        args += [str(work), str(log)]
    else:
        args += [str(SOURCE / "codex-model-catalog.json"), "240", str(log)]
    with (EVIDENCE / provider / "mock-server.txt").open("w") as output:
        process = subprocess.Popen(args, env=private_env(), stdout=output,
                                   stderr=subprocess.STDOUT)
    with (RUN / "mock-pids").open("a") as pids:
        pids.write(str(process.pid) + "\n")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        require(process.poll() is None, f"{provider} mock exited on startup")
        try:
            with urlopen(f"http://127.0.0.1:{port}/", timeout=0.5):
                return log
        except PermissionError as error:
            raise RuntimeError(f"loopback access denied by this environment: {error}") from error
        except OSError:
            time.sleep(0.1)
    raise RuntimeError(f"{provider} mock could not bind 127.0.0.1:{port}")


def configure(ports):
    HOME.mkdir()
    (HOME / ".claude").mkdir()
    (RUN / "codex-home").mkdir()
    (RUN / "kimi-home").mkdir()
    for provider in PROVIDERS:
        (RUN / f"{provider}-work").mkdir()
        (EVIDENCE / provider).mkdir(parents=True)
    work = RUN / "claude-work"
    (work / "hello.py").write_text("print('TESSERA_HELLO_PY_RAN')\n")
    claude_config = json.dumps({
        "hasCompletedOnboarding": True,
        "projects": {str(work): {"hasTrustDialogAccepted": True}},
        "customApiKeyResponses": {"approved": [MOCK_KEY[-20:]], "rejected": []},
        "theme": "dark", "installMethod": "native", "numStartups": 1,
    })
    # With CLAUDE_CONFIG_DIR set, Claude Code reads its global config from
    # that directory instead of $HOME.
    for config in (HOME / ".claude.json", HOME / ".claude/.claude.json"):
        config.write_text(claude_config)
    codex_work = RUN / "codex-work"
    (RUN / "codex-home/config.toml").write_text(f'''model = "gpt-6-sol"
model_provider = "mock"
model_catalog_json = "{SOURCE / 'codex-model-catalog.json'}"
approval_policy = "on-request"
sandbox_mode = "workspace-write"
check_for_update_on_startup = false

[model_providers.mock]
name = "Mock"
base_url = "http://127.0.0.1:{ports['codex']}/v1"
wire_api = "responses"
env_key = "MOCK_OPENAI_KEY"
supports_websockets = false
stream_idle_timeout_ms = 600000
request_max_retries = 0
stream_max_retries = 0

[projects."{codex_work}"]
trust_level = "trusted"

[tui]
screen_reader_detection_done = true
''')


def configure_kimi(ports):
    # The production installer writes config.toml only when it finds the file
    # it expects (compare-and-swap), so the mock provider is merged in after
    # the hooks. A top-level key must precede every table.
    target = RUN / "kimi-home/config.toml"
    installed = target.read_text() if target.exists() else ""
    target.write_text(f'''default_model = "mock/mock-model"

{installed}
[providers.mock]
type = "kimi"
api_key = "mock"
base_url = "http://127.0.0.1:{ports['kimi']}/v1"

[models."mock/mock-model"]
provider = "mock"
model = "mock-model"
max_context_size = 262144
capabilities = [ "tool_use" ]
display_name = "Mock"
''')


def install_hooks():
    command = run([str(DUMPER), "install-command"]).stdout
    result = run(["/bin/sh", "-c", command], env=private_env(), timeout=90)
    (EVIDENCE / "production-install-status.txt").write_text(result.stdout)
    require("TESSERA_AGENT_INTEGRATION_STATUS current" in result.stdout,
            f"production hook install did not verify: {result.stdout[-2000:]}")
    # The app uploads the bundled Agent Host beside the hooks; Claude's native
    # transcript hook runs it.
    system = {"Darwin": "darwin", "Linux": "linux"}.get(os.uname().sysname)
    machine = {"arm64": "arm64" if system == "darwin" else "aarch64", "aarch64": "aarch64",
               "x86_64": "x86_64"}.get(os.uname().machine)
    host = REPO / f"SharedAssets/agent-host/tessera-agent-host-{system}-{machine}"
    require(system and machine and host.is_file() and host.stat().st_size > 1_000_000,
            f"hydrated Agent Host binary missing (git lfs pull): {host}")
    target = HOME / ".config/tessera/tessera-agent-host"
    shutil.copyfile(host, target)
    target.chmod(0o755)


class Session:
    def __init__(self, provider, port, mock_log):
        self.provider = provider
        self.hooks_trusted = False
        self.folder_trusted = False
        self.socket = str(RUN / f"{SOCKET_PREFIX}-{provider}.sock")
        self.target = f"{provider}:0.0"
        self.work = RUN / f"{provider}-work"
        self.evidence = EVIDENCE / provider
        self.mock_log = mock_log
        self.env = private_env()
        if provider == "claude":
            self.env["ANTHROPIC_BASE_URL"] = f"http://127.0.0.1:{port}"
            args = [PROVIDERS[provider], "--model", "claude-sonnet-5-5",
                    "--permission-mode", "default"]
        elif provider == "codex":
            args = [PROVIDERS[provider], "--no-daemon"]
        else:
            args = [PROVIDERS[provider]]
        # tmux starts the command through its shell. Every value here is a
        # generated private path or the read-only executable discovered on PATH.
        command = "exec env -i " + " ".join(
            f"{key}={shlex.quote(value)}" for key, value in self.env.items()
        ) + " " + " ".join(shlex.quote(str(value)) for value in args)
        run(["tmux", "-S", self.socket, "new-session", "-d", "-s", provider,
             "-x", COLUMNS, "-y", ROWS, "-c", str(self.work), command], env=self.env)

    def answer_setup_dialog(self, screen):
        """Answers the one-time dialogs a disposable home shows for the lane's
        own installed hooks and work folder. Any other first-run dialog fails."""
        if self.provider == "codex" and "Hooks need review" in screen and not self.hooks_trusted:
            # "2. Trust all and continue" for the production hooks just installed.
            self.capture("hook-review")
            self.tmux("send-keys", "-t", self.target, "-H", "32")
            time.sleep(0.4)
            self.tmux("send-keys", "-t", self.target, "Enter")
            self.hooks_trusted = True
        elif self.provider == "kimi" and "Trust this folder?" in screen and not self.folder_trusted:
            # The cursor rests on "Trust this folder".
            self.capture("folder-trust")
            self.tmux("send-keys", "-t", self.target, "Enter")
            self.folder_trusted = True
        else:
            return False
        time.sleep(0.5)
        return True

    def tmux(self, *args, check=True):
        return run(["tmux", "-S", self.socket, *args], env=self.env, check=check)

    def capture(self, label):
        path = self.evidence / f"{label}.txt"
        path.write_text(self.tmux("capture-pane", "-p", "-t", self.target).stdout)
        return path.read_text()

    def keep_screen(self, label):
        """Keeps the screen a step waited for as the apps capture it: styles
        kept (`-e -N`), under its cursor's row:column:visible."""
        name = re.sub(r"[^A-Za-z0-9]+", "-", label).strip("-").lower()
        cursor = self.tmux("display-message", "-p", "-t", self.target,
                           "#{cursor_y}:#{cursor_x}:#{cursor_flag}").stdout.strip()
        text = self.tmux("capture-pane", "-p", "-e", "-N", "-t", self.target).stdout
        (self.evidence / f"screen-{name}.styled.txt").write_text(f"{cursor}\n{text}")

    def observe(self):
        result = run([str(DRIVER), self.provider, self.socket, self.target, "observe"],
                     env=self.env, check=False)
        require(result.returncode == 0, f"{self.provider} observe failed: {result.stdout}")
        return result.stdout

    def wait(self, needle, label, timeout=60):
        deadline = time.monotonic() + timeout
        last = ""
        while time.monotonic() < deadline:
            last = self.observe()
            if needle in last:
                self.keep_screen(label)
                return last
            screen = self.capture("poll-latest")
            if self.answer_setup_dialog(screen):
                continue
            if re.search(r"(Choose a theme|Select a theme|Log in|Welcome to Claude Code|Trust this folder|Trust this project|Do you trust)", screen, re.I):
                raise RuntimeError(f"{self.provider} first-run dialog while waiting for {label}: {screen[-1500:]}")
            time.sleep(0.25)
        raise RuntimeError(f"timed out waiting for {label}; observe={last}; screen={self.capture('timeout')[-1800:]}")

    def wait_composer(self, timeout=80):
        deadline = time.monotonic() + timeout
        previous = ""
        stable = 0
        while time.monotonic() < deadline:
            observation = self.observe()
            screen = self.capture("poll-latest")
            if self.answer_setup_dialog(screen):
                continue
            if re.search(r"(Choose a theme|Select a theme|Log in|Welcome to Claude Code|Trust this folder|Trust this project|Do you trust)", screen, re.I):
                raise RuntimeError(f"{self.provider} first-run dialog: {screen[-1500:]}")
            y = self.tmux("display-message", "-p", "-t", self.target, "#{cursor_y}").stdout.strip()
            rows = screen.splitlines()
            cursor = rows[int(y)] if y.isdigit() and int(y) < len(rows) else ""
            marker = {"claude": r"^\s*❯\s*($|[^0-9])",
                      "codex": r"^\s*›\s*($|[^0-9])",
                      # Kimi 2.1 boxes its composer: "│ >".
                      "kimi": r"^\s*(│\s*)?[✨❯>]"}[self.provider]
            # Kimi's composer may hide its cursor during a quiet repaint.
            ready = ("no prompt" in observation and
                     (re.search(marker, cursor) is not None or
                      self.provider == "kimi" and
                      re.search(r"(?m)^\s*✨\s*$", "\n".join(rows[-8:])) is not None))
            if ready and screen == previous:
                stable += 1
            else:
                stable = 0
            if stable >= 6:
                return
            previous = screen
            time.sleep(0.25)
        raise RuntimeError(f"timed out waiting for {self.provider} composer: {self.capture('timeout')[-1800:]}")

    def action(self, kind, value):
        observation = self.observe()
        token = re.search(r"\btoken=(\S+)", observation)
        require(token, f"no prompt before {kind} {value}: {observation}")
        result = run([str(DRIVER), self.provider, self.socket, self.target,
                      "--expect", token.group(1), kind, value], env=self.env,
                     check=False, timeout=45)
        with (self.evidence / "driver-output.txt").open("a") as output:
            output.write(f"ACTION {kind} {value}\n{result.stdout}\n")
        require(result.returncode == 0,
                f"{self.provider} driver {kind} {value} exited {result.returncode}: {result.stdout}")
        require("done after" in result.stdout, f"{self.provider} driver did not finish: {result.stdout}")
        return result.stdout

    def send_prompt(self, script):
        self.wait_composer()
        self.tmux("send-keys", "-l", "-t", self.target, f"SCRIPT:{script}")
        # Kimi treats a single send-keys call with text and Enter as a newline.
        time.sleep(0.3)
        self.tmux("send-keys", "-t", self.target, "Enter")

    def scenario(self, name, body):
        self.capture(f"{name}-before")
        try:
            body()
            print(f"PASS {self.provider}/{name}", flush=True)
        finally:
            self.capture(f"{name}-after")

    def records(self):
        if not self.mock_log.exists():
            return []
        return [json.loads(line) for line in self.mock_log.read_text().splitlines() if line]

    def assert_mock(self, start, expected, label, timeout=45):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            text = "\n".join(json.dumps(record, ensure_ascii=False)
                             for record in self.records()[start:])
            if all(fragment in text for fragment in expected):
                return
            time.sleep(0.25)
        raise RuntimeError(f"{self.provider} mock missing {label}: {expected}; recent={text[-2000:]}")

    def assert_hook(self, reason, label, start=0, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            content = DIAGNOSTICS.read_text() if DIAGNOSTICS.exists() else ""
            if re.search(rf"provider={self.provider}\b.*event=(PreToolUse|PermissionRequest|Notification)\b.*reason={re.escape(reason)}\b", content[start:]):
                return
            time.sleep(0.25)
        raise RuntimeError(f"{self.provider} lifecycle hook missing {label} reason={reason}")


def claude_cases(s):
    def ask3():
        start = len(s.records())
        diag = DIAGNOSTICS.stat().st_size if DIAGNOSTICS.exists() else 0
        s.send_prompt("ask3")
        s.wait("q=Which database should the service use?", "Claude database question")
        s.action("text", "CockroachDB")
        s.wait("q=Which features should ship first?", "Claude features question")
        s.action("option", "2")
        s.wait("q=Which features should ship first?", "Claude features after Export")
        s.action("option", "3")
        s.wait("q=Which features should ship first?", "Claude features after Sharing")
        s.action("control", "next")
        s.wait("q=Should I open a pull request when done?", "Claude PR question")
        s.action("option", "2")
        s.wait("kind=review", "Claude review")
        s.action("option", "1")
        s.assert_mock(start, ['Which database should the service use?', 'CockroachDB',
                              'Export, Sharing', 'No'], "AskUserQuestion tool result")
        s.assert_hook("question", "AskUserQuestion PreToolUse", diag)
    s.scenario("ask3", ask3)

    def askwide():
        start = len(s.records())
        s.send_prompt("askwide")
        s.wait("q=Which plan should the next run use?", "Claude long question")
        s.action("option", "2")
        s.wait("q=Should I post the report to the team channel?", "Claude report question")
        s.action("option", "2")
        s.wait("kind=review", "Claude long question review")
        s.action("option", "1")
        s.assert_mock(start, ["Which plan should the next run use?", "Switch to the fast path",
                              "Should I post the report to the team channel?", "No"],
                      "long AskUserQuestion tool result")
    s.scenario("askwide", askwide)

    def askreview(script, questions):
        # A review taller than 30 rows, or than the pane: it has no key
        # hints, so its top rule (or its "Ready to submit" row) anchors it.
        start = len(s.records())
        s.send_prompt(script)
        s.wait("q=Which lever should the importer try first?", "Claude lever question")
        s.action("option", "1")
        s.wait("q=The release branch test suite passes", "Claude release question")
        s.action("option", "1")
        s.wait("q=Open item from the last round", "Claude audit question")
        s.action("text", "can payments settle a day late?")
        if questions == 4:
            s.wait("q=If the fast-forward goes wrong", "Claude rollback question")
            s.action("option", "2")
        s.wait("kind=review", f"Claude {script} review")
        s.action("option", "1")
        s.assert_mock(start, ["Which lever should the importer try first?", "Batch the vendor reads",
                              "Fast-forward", "can payments settle a day late?"]
                      + (["Revert commit"] if questions == 4 else []), f"{script} tool result")
    s.scenario("askreview", lambda: askreview("askreview", 3))
    s.scenario("tallreview", lambda: askreview("tallreview", 4))

    def bash():
        start = len(s.records())
        diag = DIAGNOSTICS.stat().st_size if DIAGNOSTICS.exists() else 0
        s.send_prompt("bash")
        s.wait("kind=permission", "Claude Bash permission")
        s.action("option", "4")
        # "No" interrupts the turn: Claude asks what to do instead and sends
        # the model nothing until the user replies.
        deadline = time.monotonic() + 30
        while "Interrupted" not in s.capture("bash-denied"):
            require(time.monotonic() < deadline, "Claude did not show the denied command as interrupted")
            time.sleep(0.25)
        recent = json.dumps(s.records()[start:], ensure_ascii=False)
        require("TESSERA_HELLO_PY_RAN" not in recent, "denied Bash command produced output")
        s.assert_hook("permission", "Bash permission hook", diag)
    s.scenario("bash", bash)

    def stale():
        s.send_prompt("ask1")
        before = s.wait("q=Which database should the service use for the new ledger?", "stale question")
        token = re.search(r"\btoken=(\S+)", before).group(1)
        s.tmux("send-keys", "-t", s.target, "-H", "32")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline and f"token={token}" in s.observe():
            time.sleep(0.1)
        require(f"token={token}" not in s.observe(), "direct terminal input did not change prompt signature")
        result = run([str(DRIVER), "claude", s.socket, s.target, "--expect", token,
                      "option", "1"], env=s.env, check=False)
        (s.evidence / "stale-driver-output.txt").write_text(result.stdout)
        require(result.returncode == 2 and "refused stalePrompt" in result.stdout
                and "\nsend " not in result.stdout,
                f"old signature was not refused before writing: {result.returncode} {result.stdout}")
    s.scenario("stale", stale)


def codex_cases(s):
    # Shift+Tab toggles Plan mode. The footer is an independent TUI assertion.
    s.wait_composer()
    s.tmux("send-keys", "-t", s.target, "BTab")
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        footer = "\n".join(s.capture("plan-mode").splitlines()[-4:])
        if "Plan mode" in footer:
            break
        time.sleep(0.25)
    else:
        raise RuntimeError("Codex footer did not enter Plan mode after BTab")

    def rui_option():
        start = len(s.records())
        s.send_prompt("rui")
        s.wait("q=Which database should we use?", "Codex Plan question")
        s.action("option", "2")
        s.assert_mock(start, ["SQLite"], "request_user_input answer")
    s.scenario("rui-option", rui_option)

    def rui_text():
        start = len(s.records())
        s.send_prompt("rui")
        s.wait("q=Which database should we use?", "Codex notes question")
        s.action("text", "CockroachDB with a replica")
        s.assert_mock(start, ["user_note: CockroachDB with a replica"],
                      "request_user_input free text")
    s.scenario("rui-text", rui_text)

    s.wait_composer()
    s.tmux("send-keys", "-t", s.target, "BTab")
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        footer = "\n".join(s.capture("default-mode").splitlines()[-4:])
        if "default" in footer and "Plan mode" not in footer:
            break
        time.sleep(0.25)
    else:
        raise RuntimeError("Codex footer did not leave Plan mode")

    def async2():
        start = len(s.records())
        diag = DIAGNOSTICS.stat().st_size if DIAGNOSTICS.exists() else 0
        s.send_prompt("async2")
        s.wait("kind=deferred", "Codex deferred card")
        output = s.action("control", "open")
        require("hex=1b5b313b3244" in output,
                "Codex open control did not send shift-left sequence")
        s.wait("q=Which database should the service use?", "Codex deferred database")
        s.action("option", "2")
        s.wait("q=Describe the rollout window you prefer.", "Codex deferred free text")
        s.action("text", "Weekday mornings, UTC")
        # Codex queues async answers until the running turn's next tool call.
        deadline = time.monotonic() + 30
        while True:
            screen = s.capture("async2-queued")
            if "Messages to be submitted" in screen and "SQLite" in screen and "Weekday mornings, UTC" in screen:
                break
            require(time.monotonic() < deadline, "Codex did not queue both async answers")
            time.sleep(0.25)
        (s.evidence / "release-hold").touch()
        s.assert_mock(start, ["SQLite", "Weekday mornings, UTC"],
                      "queued follow-ups delivered to Responses", timeout=65)
        s.assert_hook("deferred-question", "async hook", diag)
    s.scenario("async2", async2)


def kimi_cases(s):
    def askbg_option():
        start = len(s.records())
        diag = DIAGNOSTICS.stat().st_size if DIAGNOSTICS.exists() else 0
        s.send_prompt("askbg")
        s.wait("q=Which region should host the ledger?", "Kimi background region")
        s.action("option", "2")
        s.wait("kind=review", "Kimi background review")
        s.action("option", "1")
        s.assert_mock(start, ["<notification", "us-east-1"],
                      "background answer notification")
        s.assert_hook("deferred-question", "background question hook", diag)
    s.scenario("askbg-option", askbg_option)

    def askbg_cancel():
        start = len(s.records())
        s.send_prompt("askbg")
        s.wait("q=Which region should host the ledger?", "Kimi background region again")
        s.action("text", "ap-south-1 (Mumbai)")
        s.wait("kind=review", "Kimi background text review")
        s.action("control", "cancel")
        s.assert_mock(start, ["<notification", "dismissed"],
                      "background cancellation notification")
    s.scenario("askbg-cancel", askbg_cancel)

    def ask1():
        start = len(s.records())
        s.send_prompt("ask1")
        s.wait("q=Which database should the service use for the new ledger?", "Kimi blocking question")
        s.action("option", "1")
        s.wait("kind=review", "Kimi blocking review")
        s.action("option", "1")
        s.assert_mock(start, ["Postgres"], "blocking AskUserQuestion tool result")
    s.scenario("ask1", ask1)

    def askreview():
        # Three long questions: the review outgrows the panel's old reach.
        start = len(s.records())
        s.send_prompt("askreview")
        s.wait("q=Which lever should the importer try first?", "Kimi lever question")
        s.action("option", "1")
        s.wait("q=The release branch test suite passes", "Kimi release question")
        s.action("option", "1")
        s.wait("q=A vendor payment is checked", "Kimi audit question")
        s.action("option", "2")
        s.wait("kind=review", "Kimi long review")
        s.action("option", "1")
        s.assert_mock(start, ["Batch the vendor reads", "Fast-forward", "Log it"], "long AskUserQuestion tool result")
    s.scenario("askreview", askreview)

    def tallreview():
        # Four long questions: at phone width the review's top rule scrolls off.
        start = len(s.records())
        s.send_prompt("tallreview")
        s.wait("q=Which lever should the importer try first?", "Kimi tall lever question")
        s.action("option", "1")
        s.wait("q=The release branch test suite passes", "Kimi tall release question")
        s.action("option", "1")
        s.wait("q=Open item from the last round", "Kimi tall audit question")
        s.action("option", "2")
        s.wait("q=If the fast-forward goes wrong", "Kimi tall rollback question")
        s.action("option", "2")
        s.wait("kind=review", "Kimi tall review")
        s.action("option", "1")
        s.assert_mock(start, ["Batch the vendor reads", "Fast-forward", "Log it", "Revert commit"],
                      "tall AskUserQuestion tool result")
    s.scenario("tallreview", tallreview)


def main():
    # Optional, for diagnosing one provider: TESSERA_AGENT_PROMPT_TUI_PROVIDERS=kimi
    only = {name for name in os.environ.get("TESSERA_AGENT_PROMPT_TUI_PROVIDERS", "").split(",") if name}
    available = [name for name, path in PROVIDERS.items() if path and (not only or name in only)]
    for name in PROVIDERS:
        if name not in available:
            print(f"SKIP {name}: {'CLI missing' if not PROVIDERS[name] else 'not selected'}", flush=True)
    require(available, "no Claude, Codex, or Kimi CLI is available")
    EVIDENCE.mkdir()
    ports = {}
    for name in available:
        port = pick_port()
        while port in ports.values():
            port = pick_port()
        ports[name] = port
    # Config files for missing providers still need syntactically valid URLs:
    # the production installer merges all three hook configurations.
    ports.update({name: ports.get(name, 1) for name in PROVIDERS})
    configure(ports)
    install_hooks()
    configure_kimi(ports)
    for provider in available:
        work = RUN / f"{provider}-work"
        log = start_mock(provider, ports[provider], work)
        session = Session(provider, ports[provider], log)
        if provider == "claude":
            claude_cases(session)
        elif provider == "codex":
            codex_cases(session)
        else:
            kimi_cases(session)
    if DIAGNOSTICS.exists():
        shutil.copyfile(DIAGNOSTICS, EVIDENCE / "agent-lifecycle-diagnostics.log")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL agent prompt TUI: {error}", file=sys.stderr, flush=True)
        if DIAGNOSTICS.exists():
            shutil.copyfile(DIAGNOSTICS, EVIDENCE / "agent-lifecycle-diagnostics.log")
        sys.exit(1)
