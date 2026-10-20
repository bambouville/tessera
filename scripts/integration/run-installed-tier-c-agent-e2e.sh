#!/bin/sh
set -eu

# Read-only release gate for the exact locally installed OpenCode, Pi, and
# Kimi adapters. OpenCode and Kimi are projected from their provider-owned
# stores without copying transcript content into the repository. Pi creates an
# offline RPC session in a disposable HOME and proves the same
# nonce-correlated get_state/get_messages path used by Agent Center.
if [ "${TESSERA_RUN_REAL_AGENT_E2E:-0}" != "1" ]; then
    printf '%s\n' "set TESSERA_RUN_REAL_AGENT_E2E=1 to run the installed Tier-C provider gate" >&2
    exit 64
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
INSTALLER_SOURCE="$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift"
DUMP_SOURCE="$SCRIPT_DIR/AgentIntegrationSourceDump.swift"
DUMPER_BUILDER="$SCRIPT_DIR/build-agent-integration-dumper.sh"
AUTHENTICATED_HOME=$HOME
OPENCODE_BIN=$(command -v opencode || true)
PI_BIN=$(command -v pi || true)
KIMI_BIN=$(command -v kimi || true)
SWIFTC_BIN=$(command -v swiftc || true)

for required in "$OPENCODE_BIN" "$PI_BIN" "$KIMI_BIN" "$SWIFTC_BIN"; do
    if [ -z "$required" ] || [ ! -x "$required" ]; then
        printf '%s\n' "installed Tier-C gate requires opencode, pi, kimi, and swiftc" >&2
        exit 1
    fi
done

RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tessera-tier-c-e2e.XXXXXX")
DUMPER="$RUN_DIR/dump-agent-integration"
PROJECTOR="$RUN_DIR/tessera-agent-project"
cleanup() {
    outcome=$?
    # macOS /bin/sh is bash 3.2, which enters this trap with $? = 0 after a
    # `set -u` abort under `set -e`; only a completed run may exit 0.
    if [ "$outcome" -eq 0 ] && [ "${script_completed:-0}" != 1 ]; then
        printf '%s\n' "${0##*/}: aborted before completion (bash set -u abort?)" >&2
        outcome=1
    fi
    trap - EXIT HUP INT TERM
    # Inventory and projection files can contain provider-owned transcript
    # records. Remove the run directory on success and failure; this gate must
    # never leave user content behind in a failure artifact.
    rm -rf "$RUN_DIR"
    if [ "$outcome" -ne 0 ]; then
        printf '%s\n' 'installed Tier-C E2E failed; sensitive run artifacts removed' >&2
    fi
    exit "$outcome"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

SWIFTC_BIN="$SWIFTC_BIN" sh "$DUMPER_BUILDER" "$DUMPER" "$RUN_DIR/module-cache"
"$DUMPER" projector >"$PROJECTOR"
chmod 700 "$PROJECTOR"

inventory_and_project() {
    provider=$1
    home=$2
    inventory="$RUN_DIR/$provider-inventory.ndjson"
    projection="$RUN_DIR/$provider-projection.ndjson"
    HOME="$home" PI_CODING_AGENT_DIR="$home/.pi/agent" PI_OFFLINE=1 \
        PATH="${OPENCODE_BIN%/*}:${PI_BIN%/*}:${KIMI_BIN%/*}:/usr/bin:/bin" \
        "$PROJECTOR" >"$inventory" <<EOF
{"v":1,"kind":"inventory","provider":"$provider","limitBytes":262144,"limitRecords":100}
EOF
    ref=$(python3 - "$inventory" "$provider" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    frame = json.loads(line)
    if frame.get("kind") == "inventory" and frame.get("provider") == sys.argv[2]:
        print(frame["transcriptRef"])
        break
PY
    )
    if [ -z "$ref" ]; then
        printf 'installed %s adapter returned no provider-owned sessions\n' "$provider" >&2
        exit 1
    fi
    provider_session_id=$(python3 - "$inventory" "$provider" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    frame = json.loads(line)
    if frame.get("kind") == "inventory" and frame.get("provider") == sys.argv[2]:
        print(frame["providerSessionID"])
        break
PY
    )
    if [ -z "$provider_session_id" ]; then
        printf 'installed %s adapter returned an invalid session identity\n' "$provider" >&2
        exit 1
    fi
    HOME="$home" PI_CODING_AGENT_DIR="$home/.pi/agent" PI_OFFLINE=1 \
        PATH="${OPENCODE_BIN%/*}:${PI_BIN%/*}:${KIMI_BIN%/*}:/usr/bin:/bin" \
        "$PROJECTOR" >"$projection" <<EOF
{"v":1,"kind":"project","provider":"$provider","transcriptRef":"$ref","limitBytes":262144,"limitRecords":100}
EOF
    python3 - "$inventory" "$projection" "$provider" "$provider_session_id" <<'PY'
import json, sys
inventory = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
projection = [json.loads(line) for line in open(sys.argv[2], encoding="utf-8") if line.strip()]
assert any(frame.get("kind") == "inventory" and frame.get("provider") == sys.argv[3] for frame in inventory)
assert inventory[-1].get("kind") == "end"
assert projection[0].get("kind") == "page"
assert isinstance(projection[0].get("sourceIdentity"), str) and projection[0]["sourceIdentity"]
assert projection[-1].get("kind") == "end"
records = [frame for frame in projection if frame.get("kind") == "record"]
assert records, f"{sys.argv[3]} projection returned no records"
for frame in records:
    assert isinstance(frame.get("sequence"), int) and frame["sequence"] >= 0
    assert isinstance(frame.get("recordID"), str) and frame["recordID"]
    record = frame.get("record")
    assert isinstance(record, dict) and record.get("provider") == sys.argv[3]
    if sys.argv[3] in {"opencode", "pi"}:
        assert frame["recordID"].startswith(sys.argv[3] + "-")
        assert record.get("sessionID") == sys.argv[4]
PY
}

# The locally installed CLIs must recognize their own current stores before
# the product adapter reads them. No prompt is submitted and no user content
# is printed by this gate.
"$OPENCODE_BIN" session list >/dev/null
"$KIMI_BIN" doctor >/dev/null
inventory_and_project opencode "$AUTHENTICATED_HOME"
inventory_and_project kimi "$AUTHENTICATED_HOME"

PI_HOME="$RUN_DIR/pi-home"
PI_SESSIONS="$PI_HOME/.pi/agent/sessions"
mkdir -p "$PI_SESSIONS"
PI_SESSIONS=$(CDPATH= cd -- "$PI_SESSIONS" && pwd -P)
HOME="$PI_HOME" PI_CODING_AGENT_DIR="$PI_HOME/.pi/agent" PI_OFFLINE=1 \
python3 - "$PI_BIN" "$PI_SESSIONS" "$RUN_DIR/pi-rpc.ndjson" "$RUN_DIR/pi-rpc.stderr" <<'PY'
import json, os, subprocess, sys, time
process = subprocess.Popen([
    sys.argv[1], "--offline", "--mode", "rpc", "--session-dir", sys.argv[2],
    "--session-id", "01234567-89ab-4def-8123-456789abcdef",
    "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files",
], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(sys.argv[4], "wb"), env=os.environ.copy(), text=True)
commands = [
    {"type":"bash","id":"00112233445566778899aabbccddeeff","command":"printf TESSERA_PI_E2E_OK","excludeFromContext":False},
    {"type":"set_session_name","id":"fedcba9876543210fedcba9876543210","name":"Tessera Tier-C E2E"},
    {"type":"get_state","id":"0123456789abcdef0123456789abcdef"},
]
with open(sys.argv[3], "w", encoding="utf-8") as output:
    for command in commands:
        process.stdin.write(json.dumps(command, separators=(",", ":")) + "\n")
        process.stdin.flush()
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            line = process.stdout.readline()
            if not line: raise RuntimeError("Pi RPC closed before acknowledgement")
            output.write(line); output.flush()
            frame = json.loads(line)
            if frame.get("type") == "response" and frame.get("id") == command["id"]:
                if frame.get("success") is not True: raise RuntimeError("Pi RPC command failed")
                break
        else: raise RuntimeError("Pi RPC acknowledgement timed out")
process.stdin.close()
if process.wait(timeout=10) != 0: raise RuntimeError("Pi RPC exited unsuccessfully")
PY
grep -Fq '"command":"get_state","success":true' "$RUN_DIR/pi-rpc.ndjson"
grep -Fq 'TESSERA_PI_E2E_OK' "$RUN_DIR/pi-rpc.ndjson"
PI_SESSION_FILE=$(python3 - "$RUN_DIR/pi-rpc.ndjson" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    frame = json.loads(line)
    if frame.get("type") == "response" and frame.get("command") == "get_state":
        print(frame["data"]["sessionFile"])
        break
PY
)
case "$PI_SESSION_FILE" in "$PI_SESSIONS"/*.jsonl) ;; *) printf '%s\n' 'Pi returned an out-of-root session file' >&2; exit 1 ;; esac
# Pi may not persist a tool-only session. Materialize its documented v3 header
# and one deterministic user record when no message was persisted; the product
# projector must then reopen and decode that immutable snapshot through the
# real installed Pi get_state/get_messages RPC codec.
python3 - "$PI_SESSION_FILE" "$RUN_DIR" <<'PY'
import json, sys
path, cwd = sys.argv[1:]
entries = []
try:
    with open(path, encoding="utf-8") as source:
        entries = [json.loads(line) for line in source if line.strip()]
except FileNotFoundError:
    pass
if not entries:
    entries.append({"type":"session", "version":3, "id":"01234567-89ab-4def-8123-456789abcdef", "timestamp":"2026-08-31T00:00:00.000Z", "cwd":cwd})
if not any(entry.get("type") == "message" for entry in entries):
    entries.append({
        "type":"message", "id":"00112233445566778899aabbccddeeff",
        "parentId":None, "timestamp":"2026-08-31T00:00:01.000Z",
        "message":{"role":"user", "content":[{"type":"text", "text":"TESSERA_PI_E2E_OK"}], "timestamp":1788134401000},
    })
with open(path, "w", encoding="utf-8") as output:
    for entry in entries:
        output.write(json.dumps(entry, separators=(",", ":")) + "\n")
PY
chmod 600 "$PI_SESSION_FILE"
inventory_and_project pi "$PI_HOME"

printf '%s\n' 'installed Tier-C providers: OpenCode inventory/projection, Pi RPC/inventory/projection, and Kimi hooks/inventory/projection passed'
script_completed=1
