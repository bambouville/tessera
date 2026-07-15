#!/bin/sh

# Disposable real-agent probe for Agent Center lifecycle semantics. The hook
# records the provider event and publishes one normalized JSON value on the
# current tmux pane. When TESSERA_AGENT_PROBE_OSC=1, it also writes a private
# OSC frame directly to the controlling terminal so the probe can prove the
# immediate transport path independently of tmux's retained pane metadata.
# It intentionally writes nothing to stdout because both Claude Code and Codex
# treat hook stdout as protocol data.

set -u

provider="${1:-unknown}"
event="${2:-unknown}"
probe_dir="${TESSERA_AGENT_PROBE_DIR:-/tmp/tessera-agent-state-probe}"
mkdir -p "$probe_dir"
chmod 700 "$probe_dir" 2>/dev/null || true

input="$(cat 2>/dev/null || true)"
state=""
reason=""

case "$event" in
    SessionStart)
        state="idle"
        reason="session-start"
        ;;
    SubagentStart|SubagentStop|UserPromptSubmit|PreToolUse|PostToolUse)
        state="working"
        reason="agent-turn"
        ;;
    PermissionRequest)
        state="waitingForInput"
        reason="permission"
        ;;
    Notification)
        notification_type="$(printf '%s' "$input" | jq -r '.notification_type // empty' 2>/dev/null)"
        case "$notification_type" in
            permission_prompt|elicitation_dialog)
                state="waitingForInput"
                reason="$notification_type"
                ;;
            idle_prompt)
                state="idle"
                reason="idle-prompt"
                ;;
        esac
        ;;
    Stop)
        running_background="$(printf '%s' "$input" | jq -r '[.background_tasks[]? | select(.status == "running")] | length' 2>/dev/null)"
        if [ "${running_background:-0}" -gt 0 ] 2>/dev/null; then
            state="working"
            reason="background-task"
        else
            state="idle"
            reason="turn-stopped"
        fi
        ;;
    StopFailure)
        state="unavailable"
        reason="turn-failed"
        ;;
    SessionEnd)
        state="unavailable"
        reason="session-ended"
        ;;
esac

timestamp_ns="$(python3 -c 'import time; print(time.time_ns())' 2>/dev/null || date +%s000000000)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
turn_id="$(printf '%s' "$input" | jq -r '.turn_id // empty' 2>/dev/null)"
notification_type="$(printf '%s' "$input" | jq -r '.notification_type // empty' 2>/dev/null)"
permission_mode="$(printf '%s' "$input" | jq -r '.permission_mode // empty' 2>/dev/null)"
pane="${TMUX_PANE:-}"

agent_pid=""
if command -v ps >/dev/null 2>&1; then
    ancestor_pid="$PPID"
    ancestor_depth=0
    while [ -n "$ancestor_pid" ] && [ "$ancestor_pid" -gt 1 ] 2>/dev/null && [ "$ancestor_depth" -lt 8 ]; do
        ancestor_comm="$(ps -o comm= -p "$ancestor_pid" 2>/dev/null | tr -d '[:space:]')"
        ancestor_args="$(ps -o args= -p "$ancestor_pid" 2>/dev/null || true)"
        matches_provider=0
        case "$provider" in
            claude)
                case "$ancestor_comm" in *claude*|*Claude*|[0-9]*.[0-9]*.[0-9]*) matches_provider=1 ;; esac
                case "$ancestor_args" in */claude*|*@anthropic-ai/claude-code*) matches_provider=1 ;; esac
                ;;
            codex)
                case "$ancestor_comm" in *codex*|*Codex*) matches_provider=1 ;; esac
                case "$ancestor_args" in */codex*) matches_provider=1 ;; esac
                ;;
        esac
        if [ "$matches_provider" -eq 1 ]; then
            agent_pid="$ancestor_pid"
            break
        fi
        ancestor_pid="$(ps -o ppid= -p "$ancestor_pid" 2>/dev/null | tr -d '[:space:]')"
        ancestor_depth=$((ancestor_depth + 1))
    done
fi

payload="$(jq -cn \
    --argjson version 8 \
    --arg provider "$provider" \
    --arg event "$event" \
    --arg state "$state" \
    --arg reason "$reason" \
    --arg timestampNs "$timestamp_ns" \
    --arg sessionId "$session_id" \
    --arg turnId "$turn_id" \
    --arg pane "$pane" \
    --arg notificationType "$notification_type" \
    --arg permissionMode "$permission_mode" \
    --argjson agentPid "${agent_pid:-null}" \
    '{version:$version,provider:$provider,event:$event,state:$state,reason:$reason,timestampNs:$timestampNs,sessionId:$sessionId,turnId:$turnId,pane:$pane,notificationType:$notificationType,permissionMode:$permissionMode,agentPid:$agentPid}')"

printf '%s\n' "$payload" >> "$probe_dir/events.jsonl"
chmod 600 "$probe_dir/events.jsonl" 2>/dev/null || true

terminal_path=""
ancestor_trace=""
if [ -n "$pane" ] && command -v tmux >/dev/null 2>&1; then
    terminal_path="$(tmux display-message -p -t "$pane" '#{pane_tty}' 2>/dev/null || true)"
fi
if [ -z "$terminal_path" ]; then
    terminal_path="$(tty 2>/dev/null || true)"
    case "$terminal_path" in
        ""|"not a tty") terminal_path="" ;;
    esac
fi
if [ -z "$terminal_path" ] && command -v ps >/dev/null 2>&1; then
    ancestor_pid="$PPID"
    ancestor_depth=0
    while [ -n "$ancestor_pid" ] && [ "$ancestor_pid" -gt 1 ] 2>/dev/null && [ "$ancestor_depth" -lt 8 ]; do
        ancestor_tty="$(ps -o tty= -p "$ancestor_pid" 2>/dev/null | tr -d '[:space:]')"
        ancestor_trace="${ancestor_trace}${ancestor_pid}:${ancestor_tty},"
        case "$ancestor_tty" in
            ""|"??"|"?")
                ;;
            *)
                terminal_path="/dev/$ancestor_tty"
                break
                ;;
        esac
        ancestor_pid="$(ps -o ppid= -p "$ancestor_pid" 2>/dev/null | tr -d '[:space:]')"
        ancestor_depth=$((ancestor_depth + 1))
    done
fi

if [ "${TESSERA_AGENT_PROBE_DEBUG:-0}" = "1" ]; then
    jq -cn \
        --arg provider "$provider" \
        --arg event "$event" \
        --arg pid "$$" \
        --arg ppid "$PPID" \
        --arg pane "$pane" \
        --arg terminalPath "$terminal_path" \
        --arg ancestorTrace "$ancestor_trace" \
        '{provider:$provider,event:$event,pid:$pid,ppid:$ppid,pane:$pane,terminalPath:$terminalPath,ancestorTrace:$ancestorTrace}' \
        >> "$probe_dir/transport.jsonl"
fi

publishes_state=1
[ "$event" = SubagentStop ] && publishes_state=0

if [ "$publishes_state" -eq 1 ] && [ -n "$state" ] && [ "${TESSERA_AGENT_PROBE_OSC:-0}" = "1" ] && [ -n "$terminal_path" ] && [ -w "$terminal_path" ]; then
    encoded_payload="$(printf '%s' "$payload" | base64 | tr -d '\n')"
    printf '\033]1337;TesseraAgentState=%s\007' "$encoded_payload" > "$terminal_path" 2>/dev/null || true
fi

if [ "$publishes_state" -eq 1 ] && [ -n "$state" ] && [ -n "$pane" ] && command -v tmux >/dev/null 2>&1; then
    tmux set-option -p -t "$pane" @tessera_agent_state "$payload" >/dev/null 2>&1 || true
fi

exit 0
