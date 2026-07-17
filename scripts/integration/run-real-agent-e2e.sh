#!/bin/sh

# Credentialed release gate for Agent Center. Runs the actual locally installed
# Codex and Claude Code TUIs in isolated tmux servers, submits prompts using
# Tessera's exact staged hex transport through the production PATH shims, and
# requires provider lifecycle hooks
# to prove idle, working, waiting-for-approval, resumed-working, and completed
# states. It does not touch Tessera's normal tmux server or shell configuration.
set -eu

if [ "${TESSERA_RUN_REAL_AGENT_E2E:-0}" != "1" ]; then
    printf '%s\n' "set TESSERA_RUN_REAL_AGENT_E2E=1 to run the credentialed Codex/Claude gate" >&2
    exit 64
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
INSTALLER_SOURCE="$REPO_ROOT/Tessera/AgentCenter/RemoteAgentLifecycleIntegrationInstaller.swift"
DUMP_SOURCE="$SCRIPT_DIR/AgentIntegrationSourceDump.swift"
TMUX_BIN=$(command -v tmux || true)
CODEX_BIN=$(command -v codex || true)
CLAUDE_BIN=$(command -v claude || true)
SWIFTC_BIN=$(command -v swiftc || true)

for required in "$TMUX_BIN" "$CODEX_BIN" "$CLAUDE_BIN" "$SWIFTC_BIN"; do
    if [ -z "$required" ] || [ ! -x "$required" ]; then
        printf '%s\n' "real Agent Center gate requires tmux, codex, and claude" >&2
        exit 1
    fi
done
for source in "$INSTALLER_SOURCE" "$DUMP_SOURCE"; do
    if [ ! -r "$source" ]; then
        printf 'missing production integration source: %s\n' "$source" >&2
        exit 1
    fi
done

RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tessera-real-agent-e2e.XXXXXX")
PRODUCTION_HOME="$RUN_DIR/home"
DUMPER="$RUN_DIR/dump-agent-integration"
SOCKET="tessera-agent-e2e-$$"
INTEGRATION_VERSION=8

cleanup() {
    outcome=$?
    trap - EXIT HUP INT TERM
    "$TMUX_BIN" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
    if [ -r "$PRODUCTION_HOME/.config/tessera/agent-lifecycle-diagnostics.log" ]; then
        cp "$PRODUCTION_HOME/.config/tessera/agent-lifecycle-diagnostics.log" \
            "$RUN_DIR/provider-lifecycle-diagnostics.log" 2>/dev/null || true
    fi
    if [ -r "$PRODUCTION_HOME/.config/tessera/codex-readiness-diagnostics.log" ]; then
        cp "$PRODUCTION_HOME/.config/tessera/codex-readiness-diagnostics.log" \
            "$RUN_DIR/codex-readiness-diagnostics.log" 2>/dev/null || true
    fi
    rm -rf "$PRODUCTION_HOME" "$RUN_DIR/swift-module-cache"
    rm -f "$DUMPER"
    if [ "$outcome" -ne 0 ]; then
        printf 'real Agent Center E2E failed; preserved artifacts=%s\n' "$RUN_DIR" >&2
    fi
    exit "$outcome"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$PRODUCTION_HOME/.codex" "$PRODUCTION_HOME/.claude"
# Copy only authentication/trust inputs into the disposable home. Symlinking
# whole provider homes lets an E2E mutate real history, sessions, and caches.
if [ -f "$HOME/.codex/auth.json" ]; then
    cp -p "$HOME/.codex/auth.json" "$PRODUCTION_HOME/.codex/auth.json"
fi
if [ -f "$HOME/.claude/.credentials.json" ]; then
    cp -p "$HOME/.claude/.credentials.json" "$PRODUCTION_HOME/.claude/.credentials.json"
fi
if [ -f "$HOME/.claude.json" ]; then
    cp -p "$HOME/.claude.json" "$PRODUCTION_HOME/.claude.json"
fi
"$SWIFTC_BIN" -module-cache-path "$RUN_DIR/swift-module-cache" -O \
    "$INSTALLER_SOURCE" "$DUMP_SOURCE" -o "$DUMPER"
INSTALL_COMMAND=$("$DUMPER" install-command)
INSTALL_OUTPUT=$(HOME="$PRODUCTION_HOME" SHELL=/bin/zsh \
    CODEX_HOME="$PRODUCTION_HOME/.codex" \
    CLAUDE_CONFIG_DIR="$PRODUCTION_HOME/.claude" \
    /bin/sh -c "$INSTALL_COMMAND")
if ! printf '%s\n' "$INSTALL_OUTPUT" | grep -q 'TESSERA_AGENT_INTEGRATION_STATUS current'; then
    printf 'production Agent Center installation did not verify:\n%s\n' "$INSTALL_OUTPUT" >&2
    exit 1
fi
printf '%s\n' "$INSTALL_OUTPUT" > "$RUN_DIR/production-install-status.txt"

# Reject malformed generated artifacts before invoking either real provider.
for generated_script in \
    agent-lifecycle-hook.sh agent-launch.sh agent-codex-readiness.sh \
    bin/claude bin/codex; do
    /bin/sh -n "$PRODUCTION_HOME/.config/tessera/$generated_script"
done
python3 -m json.tool \
    "$PRODUCTION_HOME/.config/tessera/claude-agent-hooks.json" >/dev/null
if ! grep -Fq 'claude SessionStart idle session-start' \
    "$PRODUCTION_HOME/.config/tessera/claude-agent-hooks.json"; then
    printf 'legacy Claude compatibility settings were not installed\n' >&2
    exit 1
fi

# Exercise the same install -> source -> immediate process-identity proof that
# drives the physical iPad warning. This is the exact production status
# command against an interactive zsh on the private tmux server.
"$TMUX_BIN" -L "$SOCKET" new-session -d -s activation -x 100 -y 30 \
    "env HOME='$PRODUCTION_HOME' SHELL=/bin/zsh CODEX_HOME='$PRODUCTION_HOME/.codex' CLAUDE_CONFIG_DIR='$PRODUCTION_HOME/.claude' /bin/zsh -f"
"$TMUX_BIN" -L "$SOCKET" send-keys -l -t activation:0.0 \
    '. "$HOME/.config/tessera/agent-lifecycle.sh"'
"$TMUX_BIN" -L "$SOCKET" send-keys -t activation:0.0 Enter
attempts=0
ACTIVATION_PID=""
while [ -z "$ACTIVATION_PID" ] && [ "$attempts" -lt 40 ]; do
    for marker in "$PRODUCTION_HOME/.config/tessera/active-shells"/*; do
        [ -f "$marker" ] || continue
        candidate=${marker##*/}
        case "$candidate" in *[!0-9]*) continue ;; esac
        ACTIVATION_PID=$candidate
        break
    done
    attempts=$((attempts + 1))
    [ -n "$ACTIVATION_PID" ] || sleep 0.05
done
if [ -z "$ACTIVATION_PID" ]; then
    printf 'production Agent Center shell did not publish an activation marker\n' >&2
    exit 1
fi
SHELL_STATUS_COMMAND=$("$DUMPER" shell-status "$ACTIVATION_PID")
SHELL_STATUS_OUTPUT=$(HOME="$PRODUCTION_HOME" \
    CODEX_HOME="$PRODUCTION_HOME/.codex" \
    CLAUDE_CONFIG_DIR="$PRODUCTION_HOME/.claude" \
    /bin/sh -c "$SHELL_STATUS_COMMAND")
if ! printf '%s\n' "$SHELL_STATUS_OUTPUT" | grep -q \
    'TESSERA_AGENT_SHELL_DIAG proof=process-identity'; then
    printf 'production Agent Center shell-identity diagnostic failed:\n%s\n' \
        "$SHELL_STATUS_OUTPUT" >&2
    exit 1
fi
if ! printf '%s\n' "$SHELL_STATUS_OUTPUT" | grep -q \
    'TESSERA_AGENT_SHELL_STATUS active'; then
    printf 'production Agent Center shell activation did not verify:\n%s\n' \
        "$SHELL_STATUS_OUTPUT" >&2
    exit 1
fi
printf '%s\n' "$SHELL_STATUS_OUTPUT" > "$RUN_DIR/production-shell-status.txt"
"$TMUX_BIN" -L "$SOCKET" kill-session -t activation

wait_for_event() {
    raw_output=$1
    file=$2
    provider=$3
    event=$4
    state=$5
    minimum_count=$6
    label=$7
    attempts=0
    while [ "$attempts" -lt 240 ]; do
        write_osc_events "$raw_output" "$provider" "$file"
        count=0
        if [ -r "$file" ]; then
            count=$(jq -s --arg provider "$provider" --arg event "$event" --arg state "$state" \
                '[.[] | select(.provider == $provider and .event == $event and .state == $state)] | length' \
                "$file" 2>/dev/null || printf '0')
        fi
        if [ "$count" -ge "$minimum_count" ] 2>/dev/null; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    printf 'timed out waiting for %s\n' "$label" >&2
    [ ! -r "$file" ] || tail -80 "$file" >&2
    return 1
}

wait_for_successful_event() {
    raw_output=$1
    file=$2
    target=$3
    provider=$4
    event=$5
    state=$6
    minimum_count=$7
    label=$8
    failure_screen=$9
    attempts=0
    while [ "$attempts" -lt 240 ]; do
        write_osc_events "$raw_output" "$provider" "$file"
        count=0
        failure_count=0
        if [ -r "$file" ]; then
            count=$(jq -s --arg provider "$provider" --arg event "$event" --arg state "$state" \
                '[.[] | select(.provider == $provider and .event == $event and .state == $state)] | length' \
                "$file" 2>/dev/null || printf '0')
            failure_count=$(jq -s --arg provider "$provider" \
                '[.[] | select(.provider == $provider and .event == "StopFailure")] | length' \
                "$file" 2>/dev/null || printf '0')
        fi
        if [ "$count" -ge "$minimum_count" ] 2>/dev/null; then
            return 0
        fi
        if [ "$failure_count" -gt 0 ] 2>/dev/null; then
            capture_screen "$target" "$failure_screen"
            printf '%s reported StopFailure while waiting for %s\n' "$provider" "$label" >&2
            tail -80 "$file" >&2
            printf '%s provider screen:\n' "$provider" >&2
            cat "$failure_screen" >&2
            return 1
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    printf 'timed out waiting for %s\n' "$label" >&2
    [ ! -r "$file" ] || tail -80 "$file" >&2
    return 1
}

capture_screen() {
    target=$1
    destination=$2
    "$TMUX_BIN" -L "$SOCKET" capture-pane -p -e -N -t "$target" >"$destination"
}

write_state_trace() {
    events=$1
    provider=$2
    destination=$3
    jq -s --arg provider "$provider" '
        [.[] | select(.provider == $provider) | {
            provider, event, state, reason,
            notificationType,
            agentPidPresent: (.agentPid | type == "number")
        }]
    ' "$events" >"$destination"
}

write_osc_events() {
    raw_output=$1
    provider=$2
    destination=$3
    python3 - "$raw_output" "$provider" "$destination" <<'PY'
import base64
import json
import re
import sys

raw_path, expected_provider, destination = sys.argv[1:]
data = open(raw_path, "rb").read()
frames = re.findall(
    rb"\x1b\]1337;TesseraAgentState=([A-Za-z0-9+/=]+)\x07",
    data,
)
accepted = 0
with open(destination, "w", encoding="utf-8") as output:
    for encoded in frames:
        try:
            event = json.loads(base64.b64decode(encoded, validate=True))
        except Exception:
            continue
        if event.get("provider") != expected_provider:
            continue
        output.write(json.dumps(event, separators=(",", ":")) + "\n")
        accepted += 1
PY
}

finish_osc_capture() {
    target=$1
    provider=$2
    probe_dir=$3
    raw_output="$probe_dir/raw-output.bin"
    osc_events="$probe_dir/osc-events.jsonl"
    "$TMUX_BIN" -L "$SOCKET" pipe-pane -t "$target"
    sleep 0.1
    write_osc_events "$raw_output" "$provider" "$osc_events"
    if [ ! -s "$osc_events" ]; then
        printf 'no %s lifecycle OSC frames captured\n' "$provider" >&2
        return 1
    fi
    assert_state_sequence "$osc_events" "$provider"
    write_state_trace "$osc_events" "$provider" "$probe_dir/osc-state-trace.json"
    rm -f "$raw_output" "$osc_events" "$probe_dir/events.jsonl" \
        "$probe_dir/permission-screen.txt" "$probe_dir/final-screen.txt" \
        "$probe_dir/start-provider"
}

wait_for_retained_state() {
    target=$1
    provider=$2
    event=$3
    state=$4
    label=$5
    attempts=0
    while [ "$attempts" -lt 240 ]; do
        retained=$("$TMUX_BIN" -L "$SOCKET" display-message -p -t "$target" '#{@tessera_agent_state}' 2>/dev/null || true)
        if printf '%s\n' "$retained" | jq -e \
            --argjson version "$INTEGRATION_VERSION" \
            --arg provider "$provider" --arg event "$event" --arg state "$state" \
            '.version == $version and .provider == $provider and .event == $event and .state == $state and (.agentPid | type == "number")' \
            >/dev/null 2>&1; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    printf 'timed out waiting for %s retained state\n' "$label" >&2
    printf '%s\n' "$retained" >&2
    return 1
}

wait_for_screen_pattern() {
    target=$1
    pattern=$2
    label=$3
    attempts=0
    while [ "$attempts" -lt 240 ]; do
        screen=$("$TMUX_BIN" -L "$SOCKET" capture-pane -p -e -N -t "$target" 2>/dev/null || true)
        if printf '%s\n' "$screen" | grep -Eq "$pattern"; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    printf 'timed out waiting for %s\n' "$label" >&2
    printf '%s\n' "$screen" >&2
    return 1
}

wait_for_screen_occurrences() {
    target=$1
    needle=$2
    minimum_count=$3
    label=$4
    attempts=0
    while [ "$attempts" -lt 240 ]; do
        screen=$("$TMUX_BIN" -L "$SOCKET" capture-pane -p -e -N -t "$target" 2>/dev/null || true)
        count=$(printf '%s\n' "$screen" | grep -Fo "$needle" | wc -l | tr -d '[:space:]')
        if [ "$count" -ge "$minimum_count" ] 2>/dev/null; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    printf 'timed out waiting for %s (found %s occurrences)\n' "$label" "$count" >&2
    printf '%s\n' "$screen" >&2
    return 1
}

wait_for_composer() {
    target=$1
    provider_pattern=$2
    label=$3
    attempts=0
    ready_samples=0
    while [ "$attempts" -lt 240 ]; do
        screen=""
        cursor_y=$("$TMUX_BIN" -L "$SOCKET" display-message -p -t "$target" '#{cursor_y}' 2>/dev/null || true)
        case "$cursor_y" in
        ''|*[!0-9]*) cursor_line="" ;;
        *)
            screen=$("$TMUX_BIN" -L "$SOCKET" capture-pane -p -N -t "$target" 2>/dev/null || true)
            cursor_line=$(printf '%s\n' "$screen" | sed -n "$((cursor_y + 1))p")
            ;;
        esac
        # Codex can paint a provider-owned model-switch reminder immediately
        # after Stop. It is deliberately detected by Agent Center as a
        # blocking numbered prompt; the credentialed harness dismisses it so
        # the next scenario is sent only after the real composer owns input.
        if printf '%s\n' "$screen" | grep -Eqi 'Approaching rate limits' \
            && printf '%s\n' "$screen" | grep -Eqi 'lower credit usage'; then
            if [ ! -e "$RUN_DIR/codex/rate-limit-screen.txt" ]; then
                capture_screen "$target" "$RUN_DIR/codex/rate-limit-screen.txt"
            fi
            "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" Escape
            ready_samples=0
            attempts=$((attempts + 1))
            sleep 0.25
            continue
        fi
        # A provider name can appear in startup warnings and trust dialogs. The
        # live composer is distinguished by owning the cursor on a prompt row
        # that is not a numbered menu option.
        if printf '%s\n' "$screen" | grep -Eqi "$provider_pattern" \
            && printf '%s\n' "$cursor_line" | grep -Eq '^[[:space:]]*[›❯>]' \
            && ! printf '%s\n' "$cursor_line" | grep -Eq '^[[:space:]]*[›❯>][[:space:]]*[0-9]+[.)]' \
            && ! printf '%s\n' "$screen" | grep -Eqi 'Booting|model:[[:space:]]+loading|esc to interrupt|tab to queue message'; then
            ready_samples=$((ready_samples + 1))
            # Startup paints an apparently usable composer before provider
            # services begin booting. Require two quiet seconds so that short
            # pre-boot gap cannot accept the prompt prematurely.
            if [ "$ready_samples" -ge 8 ]; then
                return 0
            fi
        else
            ready_samples=0
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    printf 'timed out waiting for %s composer\n' "$label" >&2
    printf 'cursor row: %s\n%s\n' "$cursor_line" "${screen:-}" >&2
    return 1
}

accept_workspace_trust_if_present() {
    target=$1
    label=$2
    attempts=0
    theme_choices=0
    while [ "$attempts" -lt 80 ]; do
        screen=$("$TMUX_BIN" -L "$SOCKET" capture-pane -p -N -t "$target" 2>/dev/null || true)
        # This gate deliberately gives the provider a disposable HOME. Current
        # Claude releases can therefore show their text-theme chooser before
        # workspace trust even when authentication is available.
        # Accept the provider's already-highlighted default exactly once, then
        # continue waiting for SessionStart or the trust boundary.
        if printf '%s\n' "$screen" | grep -Eqi \
            'Choose the text style that looks best with your terminal|Syntax theme:'; then
            theme_choices=$((theme_choices + 1))
            if [ "$theme_choices" -gt 1 ]; then
                printf '%s text-theme chooser did not advance after Enter\n' "$label" >&2
                printf '%s\n' "$screen" >&2
                return 1
            fi
            capture_screen "$target" "$RUN_DIR/claude/theme-onboarding-screen.txt"
            "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" Enter
            attempts=0
            sleep 0.5
            continue
        fi
        if printf '%s\n' "$screen" | grep -Eqi \
            'Do you trust the contents of this directory|Do you trust files in this (folder|directory)|trust this (folder|directory)'; then
            "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" -H 31
            sleep 0.05
            "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" Enter
            WORKSPACE_TRUST_ACCEPTED=1
            return 0
        fi
        retained=$("$TMUX_BIN" -L "$SOCKET" display-message -p -t "$target" '#{@tessera_agent_state}' 2>/dev/null || true)
        if printf '%s\n' "$retained" | jq -e \
            --argjson version "$INTEGRATION_VERSION" \
            '.version == $version and .event == "SessionStart"' >/dev/null 2>&1 \
            && printf '%s\n' "$screen" | grep -Eqi \
                'Hooks need review|Use /skills to list available skills|Claude Code'; then
            return 0
        fi
        attempts=$((attempts + 1))
        sleep 0.1
    done
    printf '%s did not reach SessionStart or a recognized workspace-trust dialog\n' "$label" >&2
    printf '%s\n' "$screen" >&2
    return 1
}

assert_permission_cursor_row() {
    target=$1
    label=$2
    cursor_y=$("$TMUX_BIN" -L "$SOCKET" display-message -p -t "$target" '#{cursor_y}')
    case "$cursor_y" in ''|*[!0-9]*)
        printf 'invalid cursor row for %s: %s\n' "$label" "$cursor_y" >&2
        return 1
        ;;
    esac
    screen=$("$TMUX_BIN" -L "$SOCKET" capture-pane -p -N -t "$target")
    cursor_line=$(printf '%s\n' "$screen" | sed -n "$((cursor_y + 1))p")
    # Codex may park the terminal cursor on a blank row while its selected
    # option and confirmation footer are rendered immediately above it. This
    # matches AgentPromptParser's deliberately inconclusive blank-row branch;
    # the caller has already required an exact visible permission pattern.
    if printf '%s\n' "$cursor_line" | grep -Eq '^[[:space:]]*$'; then
        return 0
    fi
    if ! printf '%s\n' "$cursor_line" | grep -Eqi \
        '^[[:space:]]*[›❯>]?[[:space:]]*[0-9]+\.|press enter|enter to (confirm|continue)|esc to (cancel|go back)'; then
        printf '%s cursor row does not own its visible permission menu: %s\n' \
            "$label" "$cursor_line" >&2
        printf '%s\n' "$screen" >&2
        return 1
    fi
}

send_staged_prompt() {
    target=$1
    prompt=$2
    # Tessera sends pasted UTF-8 and Return as distinct tmux send-keys frames.
    # od produces whitespace-separated byte pairs accepted by send-keys -H.
    hex=$(LC_ALL=C printf '%s' "$prompt" | od -An -v -tx1)
    # Deliberate field splitting: every pair is one tmux hex key argument.
    # shellcheck disable=SC2086
    "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" -H $hex
    # Real Codex and Claude composers briefly remain in their paste/input
    # transition after the bytes render. This transport-level gate uses a
    # conservative fixed delay before one semantic Enter; the app's E2E/unit
    # coverage separately verifies its live-composer readiness boundary.
    sleep 0.4
    "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" Enter
}

approve_option() {
    target=$1
    provider=$2
    # Exercise the built-in Agent Center response macros, including Claude's
    # staged numeric choice + semantic Enter and Codex's single-key shortcut.
    case "$provider" in
    claude)
        "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" -H 31
        sleep 0.4
        "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" Enter
        ;;
    codex)
        "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" -H 79
        ;;
    *) return 64 ;;
    esac
}

trust_codex_hooks() {
    target=$1
    probe_dir=$2
    wait_for_screen_pattern "$target" 'Hooks need review|Use /skills to list available skills' "Codex hook review or composer"
    screen=$("$TMUX_BIN" -L "$SOCKET" capture-pane -p -N -t "$target")
    if printf '%s\n' "$screen" | grep -Fq 'Hooks need review'; then
        capture_screen "$target" "$probe_dir/hook-review-screen.txt"
        # The startup trust gate owns the cursor on option 1. Choose Codex's
        # explicit “Trust all and continue” option using the same staged
        # numeric choice + semantic Enter path as Agent Center.
        "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" -H 32
        sleep 0.4
        "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" Enter
        wait_for_composer "$target" 'OpenAI Codex|codex' "Codex after hook trust"
    else
        # Retained trust can survive when this helper is used outside the
        # disposable gate. Confirm the built-in browser has no pending review.
        wait_for_composer "$target" 'OpenAI Codex|codex' "Codex before hook review"
        send_staged_prompt "$target" "/hooks"
        wait_for_screen_pattern "$target" 'Hooks|Lifecycle hooks from config and enabled plugins' "Codex hook browser"
        if printf '%s\n' "$("$TMUX_BIN" -L "$SOCKET" capture-pane -p -N -t "$target")" | grep -Eqi 'hooks? need(s)? review'; then
            "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" -H 74
            sleep 0.5
        fi
    fi
    capture_screen "$target" "$probe_dir/hook-trusted-screen.txt"

    # Prove the persisted trust state with Codex's own status table; merely
    # reaching the composer does not prove which startup choice was applied.
    send_staged_prompt "$target" "/hooks"
    wait_for_screen_pattern "$target" 'Lifecycle hooks from config and enabled plugins' "Codex active hook table"
    capture_screen "$target" "$probe_dir/hook-active-screen.txt"
    screen=$("$TMUX_BIN" -L "$SOCKET" capture-pane -p -N -t "$target")
    if ! printf '%s\n' "$screen" | grep -Eq 'SessionStart[[:space:]]+1[[:space:]]+1'; then
        printf 'Codex SessionStart hook was not active after trust\n%s\n' "$screen" >&2
        return 1
    fi
    "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" Escape
    wait_for_composer "$target" 'OpenAI Codex|codex' "Codex after active hook verification"
}

verify_codex_hooks_active_after_relaunch() {
    target=$1
    destination=$2
    wait_for_composer "$target" 'OpenAI Codex|codex' "Codex trusted relaunch"
    send_staged_prompt "$target" "/hooks"
    wait_for_screen_pattern "$target" 'Lifecycle hooks from config and enabled plugins' "Codex relaunched hook table"
    capture_screen "$target" "$destination"
    screen=$("$TMUX_BIN" -L "$SOCKET" capture-pane -p -N -t "$target")
    if ! printf '%s\n' "$screen" | grep -Eq 'SessionStart[[:space:]]+1[[:space:]]+1'; then
        printf 'Codex SessionStart hook was not active after relaunch\n%s\n' "$screen" >&2
        return 1
    fi
    "$TMUX_BIN" -L "$SOCKET" send-keys -t "$target" Escape
}

assert_state_sequence() {
    events=$1
    provider=$2
    jq -s -e --arg provider "$provider" '
        [to_entries[] | select(.value.provider == $provider)] as $events
        | ([ $events[] | select(.value.event == "SessionStart" and .value.state == "idle") ][0].key) as $start
        | ([ $events[] | select(.value.event == "UserPromptSubmit" and .value.state == "working") ][0].key) as $firstSubmit
        | ([ $events[] | select(.value.event == "Stop" and .value.state == "idle") ][0].key) as $firstStop
        | ([ $events[] | select(.value.event == "UserPromptSubmit" and .value.state == "working") ][1].key) as $secondSubmit
        | ([ $events[] | select(.value.event == "PermissionRequest" and .value.state == "waitingForInput") ][0].key) as $permission
        | ([ $events[] | select(.value.event == "PostToolUse" and .value.state == "working") ][0].key) as $postTool
        | ([ $events[] | select(.value.event == "Stop" and .value.state == "idle") ][1].key) as $secondStop
        | ($start < $firstSubmit and $firstSubmit < $firstStop
            and $firstStop < $secondSubmit and $secondSubmit < $permission
            and $permission < $postTool and $postTool < $secondStop)
    ' "$events" >/dev/null
}

assert_session_pid_is_live_provider() {
    events=$1
    provider=$2
    pid=$(jq -r --arg provider "$provider" \
        'select(.provider == $provider and .event == "SessionStart") | .agentPid' \
        "$events" | tail -1)
    case "$pid" in ''|null|*[!0-9]*)
        printf 'invalid %s SessionStart PID: %s\n' "$provider" "$pid" >&2
        return 1
        ;;
    esac
    if ! ps -p "$pid" -o command= 2>/dev/null | grep -Eqi "$provider|codex|claude|[0-9]+\.[0-9]+\.[0-9]+"; then
        printf '%s SessionStart PID %s is not the live provider\n' "$provider" "$pid" >&2
        return 1
    fi
}

assert_event_reason() {
    events=$1
    provider=$2
    event=$3
    reason=$4
    jq -s -e \
        --arg provider "$provider" \
        --arg event "$event" \
        --arg reason "$reason" \
        'any(.[]; .provider == $provider and .event == $event and .reason == $reason)' \
        "$events" >/dev/null
}

run_codex() {
    probe_dir="$RUN_DIR/codex"
    mkdir -p "$probe_dir"
    target="codex:0.0"
    start_gate="$probe_dir/start-provider"
    command="while [ ! -f '$start_gate' ]; do sleep 0.01; done; exec env HOME='$PRODUCTION_HOME' SHELL=/bin/zsh CODEX_HOME='$PRODUCTION_HOME/.codex' CLAUDE_CONFIG_DIR='$PRODUCTION_HOME/.claude' /bin/zsh -f -c '. \"\$HOME/.config/tessera/agent-lifecycle.sh\"; exec codex --ask-for-approval untrusted --sandbox workspace-write -C \"$REPO_ROOT\"'"
    # The disposable provider home intentionally has no copied runtime state.
    # Accept this known repository's real workspace-trust dialog explicitly;
    # only the subsequent provider hook may establish availability.
    "$TMUX_BIN" -L "$SOCKET" new-session -d -s codex -x 120 -y 40 -c "$REPO_ROOT" "$command"
    "$TMUX_BIN" -L "$SOCKET" pipe-pane -t "$target" "/bin/cat > '$probe_dir/raw-output.bin'"
    : > "$start_gate"

    raw_output="$probe_dir/raw-output.bin"
    events="$probe_dir/events.jsonl"
    # Before any trust interaction or first prompt, Codex's app-server must
    # prove the exact enabled Tessera handler and the PATH shim must publish a
    # PID-bound configured bootstrap. This is the physical-iPad startup race:
    # native hook trust can settle later, but the agent is already real.
    wait_for_event "$raw_output" "$events" codex SessionStart idle 1 \
        "Codex configured empty-composer bootstrap"
    assert_event_reason \
        "$events" codex SessionStart verified-configured-empty-composer
    assert_session_pid_is_live_provider "$events" codex
    wait_for_retained_state "$target" codex SessionStart idle \
        "Codex configured empty composer"
    capture_screen "$target" "$probe_dir/configured-bootstrap-screen.txt"
    WORKSPACE_TRUST_ACCEPTED=0
    accept_workspace_trust_if_present "$target" "Codex"
    if [ "$WORKSPACE_TRUST_ACCEPTED" = 1 ]; then
        # SessionStart occurs before a newly accepted project layer is
        # activated. Relaunch inside the now-trusted disposable home and arm
        # capture before releasing the provider gate.
        rm -f "$start_gate"
        "$TMUX_BIN" -L "$SOCKET" pipe-pane -t "$target"
        "$TMUX_BIN" -L "$SOCKET" respawn-pane -k -t "$target" "$command"
        "$TMUX_BIN" -L "$SOCKET" pipe-pane -t "$target" "/bin/cat > '$raw_output'"
        : > "$start_gate"
    fi
    # A fresh isolated home must review the exact hooks.json definitions
    # through Codex's supported UI. The gate deliberately tests the real user
    # trust path, then relaunches so the pre-thread readiness proof is exercised.
    trust_codex_hooks "$target" "$probe_dir"
    rm -f "$start_gate"
    "$TMUX_BIN" -L "$SOCKET" pipe-pane -t "$target"
    : > "$raw_output"
    "$TMUX_BIN" -L "$SOCKET" respawn-pane -k -t "$target" "$command"
    "$TMUX_BIN" -L "$SOCKET" pipe-pane -t "$target" "/bin/cat > '$raw_output'"
    : > "$start_gate"
    verify_codex_hooks_active_after_relaunch "$target" "$probe_dir/hook-active-after-relaunch-screen.txt"
    wait_for_event "$raw_output" "$events" codex SessionStart idle 1 "Codex SessionStart idle state"
    assert_event_reason "$events" codex SessionStart verified-trusted-empty-composer
    assert_session_pid_is_live_provider "$events" codex
    wait_for_retained_state "$target" codex SessionStart idle "Codex initial idle"
    wait_for_composer "$target" 'OpenAI Codex|codex' "Codex"
    send_staged_prompt "$target" "Reply exactly TESSERA_CODEX_E2E_OK. Do not use tools."
    wait_for_event "$raw_output" "$events" codex UserPromptSubmit working 1 "Codex working state"
    wait_for_successful_event "$raw_output" "$events" "$target" codex Stop idle 1 \
        "Codex completed idle state" "$probe_dir/provider-failure-screen.txt"
    wait_for_screen_occurrences "$target" 'TESSERA_CODEX_E2E_OK' 2 "Codex response"
    wait_for_retained_state "$target" codex Stop idle "Codex completed idle"

    wait_for_composer "$target" 'OpenAI Codex|codex' "Codex before permission turn"
    send_staged_prompt "$target" "Use the shell tool to run exactly: python3 -c 'print(\"TESSERA_CODEX_PERMISSION_OK\")'. Do not do anything else."
    wait_for_event "$raw_output" "$events" codex UserPromptSubmit working 2 "Codex permission-turn working state"
    wait_for_event "$raw_output" "$events" codex PermissionRequest waitingForInput 1 "Codex waiting-for-permission state"
    wait_for_retained_state "$target" codex PermissionRequest waitingForInput "Codex waiting-for-permission"
    wait_for_screen_pattern "$target" 'Would you like|Do you want to proceed|Yes, and|Press enter to confirm' "Codex permission UI"
    assert_permission_cursor_row "$target" "Codex permission UI"
    capture_screen "$target" "$probe_dir/permission-screen.txt"
    approve_option "$target" codex
    wait_for_event "$raw_output" "$events" codex PostToolUse working 1 "Codex resumed-working state"
    wait_for_successful_event "$raw_output" "$events" "$target" codex Stop idle 2 \
        "Codex post-approval idle state" "$probe_dir/provider-failure-screen.txt"
    wait_for_screen_occurrences "$target" 'TESSERA_CODEX_PERMISSION_OK' 2 "Codex approved command"
    wait_for_retained_state "$target" codex Stop idle "Codex post-approval idle"
    assert_state_sequence "$events" codex
    capture_screen "$target" "$probe_dir/final-screen.txt"

    # Codex does not currently expose its final plan-approval dialog as a
    # distinct lifecycle hook. Exercise the real supported /plan flow and
    # preserve both sides of the correlation Agent Center relies on: the Stop
    # boundary and the cursor-owned approval menu painted immediately after it.
    wait_for_composer "$target" 'OpenAI Codex|codex' "Codex before plan turn"
    send_staged_prompt "$target" "/plan Propose a concise two-step plan to add a harmless comment to README.md. The request is fully specified: do not ask questions, do not use tools, and return a final plan ready for approval."
    wait_for_event "$raw_output" "$events" codex UserPromptSubmit working 3 "Codex plan-turn working state"
    wait_for_successful_event "$raw_output" "$events" "$target" codex Stop idle 3 \
        "Codex plan-turn Stop boundary" "$probe_dir/provider-failure-screen.txt"
    wait_for_screen_pattern "$target" 'Yes, implement this plan|stay in Plan mode' "Codex plan approval UI"
    assert_permission_cursor_row "$target" "Codex plan approval UI"
    wait_for_retained_state "$target" codex Stop idle "Codex plan approval retained Stop"
    capture_screen "$target" "$probe_dir/plan-approval-screen.txt"
    write_state_trace "$events" codex "$probe_dir/state-trace.json"
    finish_osc_capture "$target" codex "$probe_dir"
}

run_claude() {
    probe_dir="$RUN_DIR/claude"
    mkdir -p "$probe_dir"
    target="claude:0.0"
    start_gate="$probe_dir/start-provider"
    command="while [ ! -f '$start_gate' ]; do sleep 0.01; done; exec env HOME='$PRODUCTION_HOME' SHELL=/bin/zsh CODEX_HOME='$PRODUCTION_HOME/.codex' /bin/zsh -f -c 'unset CLAUDE_CONFIG_DIR; . \"\$HOME/.config/tessera/agent-lifecycle.sh\"; exec claude --permission-mode manual --tools Bash'"
    # Use a known repository and explicitly accept a real workspace-trust
    # dialog if the copied authentication input does not carry that choice.
    "$TMUX_BIN" -L "$SOCKET" new-session -d -s claude -x 120 -y 40 -c "$REPO_ROOT" "$command"
    "$TMUX_BIN" -L "$SOCKET" pipe-pane -t "$target" "/bin/cat > '$probe_dir/raw-output.bin'"
    : > "$start_gate"

    raw_output="$probe_dir/raw-output.bin"
    events="$probe_dir/events.jsonl"
    WORKSPACE_TRUST_ACCEPTED=0
    accept_workspace_trust_if_present "$target" "Claude"
    if [ "$WORKSPACE_TRUST_ACCEPTED" = 1 ]; then
        rm -f "$start_gate"
        "$TMUX_BIN" -L "$SOCKET" pipe-pane -t "$target"
        "$TMUX_BIN" -L "$SOCKET" respawn-pane -k -t "$target" "$command"
        "$TMUX_BIN" -L "$SOCKET" pipe-pane -t "$target" "/bin/cat > '$raw_output'"
        : > "$start_gate"
    fi
    wait_for_event "$raw_output" "$events" claude SessionStart idle 1 "Claude SessionStart idle state"
    assert_session_pid_is_live_provider "$events" claude
    wait_for_retained_state "$target" claude SessionStart idle "Claude initial idle"
    wait_for_composer "$target" 'Claude Code|claude' "Claude"
    send_staged_prompt "$target" "Reply exactly TESSERA_CLAUDE_E2E_OK. Do not use tools."
    wait_for_event "$raw_output" "$events" claude UserPromptSubmit working 1 "Claude working state"
    wait_for_successful_event "$raw_output" "$events" "$target" claude Stop idle 1 \
        "Claude completed idle state" "$probe_dir/provider-failure-screen.txt"
    wait_for_screen_occurrences "$target" 'TESSERA_CLAUDE_E2E_OK' 2 "Claude response"
    wait_for_retained_state "$target" claude Stop idle "Claude completed idle"
    # Claude can finish a child hook after its root Stop. Give that ordering
    # window time to settle and prove SubagentStop did not regress idle back to
    # working in the retained pane state.
    sleep 2
    wait_for_retained_state "$target" claude Stop idle \
        "Claude idle after late subagent cleanup"

    wait_for_composer "$target" 'Claude Code|claude' "Claude before permission turn"
    send_staged_prompt "$target" "Use Bash to run exactly: python3 -c 'print(\"TESSERA_CLAUDE_PERMISSION_OK\")'. Do not do anything else."
    wait_for_event "$raw_output" "$events" claude UserPromptSubmit working 2 "Claude permission-turn working state"
    wait_for_event "$raw_output" "$events" claude PermissionRequest waitingForInput 1 "Claude waiting-for-permission state"
    wait_for_retained_state "$target" claude PermissionRequest waitingForInput "Claude waiting-for-permission"
    wait_for_screen_pattern "$target" 'Would you like|Do you want to proceed|Yes, and|Allow Bash|Esc to cancel' "Claude permission UI"
    assert_permission_cursor_row "$target" "Claude permission UI"
    capture_screen "$target" "$probe_dir/permission-screen.txt"
    approve_option "$target" claude
    wait_for_event "$raw_output" "$events" claude PostToolUse working 1 "Claude resumed-working state"
    wait_for_successful_event "$raw_output" "$events" "$target" claude Stop idle 2 \
        "Claude post-approval idle state" "$probe_dir/provider-failure-screen.txt"
    wait_for_screen_occurrences "$target" 'TESSERA_CLAUDE_PERMISSION_OK' 2 "Claude approved command"
    wait_for_retained_state "$target" claude Stop idle "Claude post-approval idle"
    sleep 2
    wait_for_retained_state "$target" claude Stop idle \
        "Claude post-approval idle after late subagent cleanup"
    assert_state_sequence "$events" claude
    capture_screen "$target" "$probe_dir/final-screen.txt"
    write_state_trace "$events" claude "$probe_dir/state-trace.json"
    finish_osc_capture "$target" claude "$probe_dir"
}

providers=" ${TESSERA_REAL_AGENT_PROVIDERS:-codex claude} "
ran_providers=""
case "$providers" in *" codex "*) run_codex; ran_providers="codex" ;; esac
case "$providers" in *" claude "*) run_claude; ran_providers="${ran_providers:+$ran_providers,}claude" ;; esac
if [ -z "$ran_providers" ]; then
    printf 'TESSERA_REAL_AGENT_PROVIDERS must include codex and/or claude\n' >&2
    exit 64
fi

FINAL_STATUS_COMMAND=$("$DUMPER" status-command)
HOME="$PRODUCTION_HOME" SHELL=/bin/zsh \
    CODEX_HOME="$PRODUCTION_HOME/.codex" \
    CLAUDE_CONFIG_DIR="$PRODUCTION_HOME/.claude" \
    /bin/sh -c "$FINAL_STATUS_COMMAND" \
    > "$RUN_DIR/final-host-status.txt"
if ! grep -Eq \
        'TESSERA_AGENT_HOST_DIAG readiness=(trusted|none) lifecycleProvider=(codex|claude) lifecycleEvent=(SessionStart|Stop) lifecycleState=idle lifecycleReason=(verified-trusted-empty-composer|session-start|turn-stopped) lifecyclePhase=resolved agentPid=present pane=present terminal=present tmuxState=written terminalEmission=written' \
    "$RUN_DIR/final-host-status.txt"; then
    printf 'final content-free host diagnostic was incomplete:\n' >&2
    cat "$RUN_DIR/final-host-status.txt" >&2
    exit 1
fi

printf 'real Agent Center E2E passed: codex=%s claude=%s artifacts=%s\n' \
    "$("$CODEX_BIN" --version 2>/dev/null | head -1)" \
    "$("$CLAUDE_BIN" --version 2>/dev/null | head -1)" \
    "$RUN_DIR"
