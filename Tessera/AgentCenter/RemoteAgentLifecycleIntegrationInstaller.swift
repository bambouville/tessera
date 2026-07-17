import Foundation

enum AgentLifecycleIntegrationInstallError: LocalizedError {
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Could not verify Agent Center integration."
                : "Could not verify Agent Center integration: \(detail)"
        }
    }
}

enum AgentLifecycleHostInstallation: Equatable, Sendable {
    case missing
    case current
    case outdated(version: Int?)
}

/// Opt-in remote integration for authoritative Claude Code and Codex states.
/// It installs a transport-neutral lifecycle hook plus optional interactive
/// provider shims. Existing aliases and functions are never rewritten. Tessera
/// merges only its handler groups into both providers' documented user config
/// layers with compare-and-swap protection, preserving unrelated settings,
/// hooks, profiles, and symlink-managed files.
enum RemoteAgentLifecycleIntegrationInstaller {
    static let integrationVersion = 8
    static let verificationMarker = "TESSERA_AGENT_INTEGRATION_INSTALLED"
    static let statusMarker = "TESSERA_AGENT_INTEGRATION_STATUS"
    static let installationDiagnosticMarker = "TESSERA_AGENT_INSTALL_DIAG"
    static let shellStatusMarker = "TESSERA_AGENT_SHELL_STATUS"
    static let shellDiagnosticMarker = "TESSERA_AGENT_SHELL_DIAG"
    static let hostDiagnosticMarker = "TESSERA_AGENT_HOST_DIAG"
    static let codexHooksSnapshotMarker = "TESSERA_AGENT_CODEX_HOOKS"
    static let codexHooksRaceMarker = "TESSERA_AGENT_CODEX_HOOKS_CHANGED"
    static let claudeSettingsSnapshotMarker = "TESSERA_AGENT_CLAUDE_SETTINGS"
    static let claudeSettingsRaceMarker = "TESSERA_AGENT_CLAUDE_SETTINGS_CHANGED"
    static let rcMarker = "TESSERA-AGENT-LIFECYCLE"
    static let rcMarkerLine = #"[ -r "$HOME/.config/tessera/agent-lifecycle.sh" ] && . "$HOME/.config/tessera/agent-lifecycle.sh" # TESSERA-AGENT-LIFECYCLE"#
    static let bashLoginMarkerLine = #"[ -n "${BASH_VERSION:-}" ] && [ -r "$HOME/.config/tessera/agent-lifecycle.sh" ] && . "$HOME/.config/tessera/agent-lifecycle.sh" # TESSERA-AGENT-LIFECYCLE"#
    static let applyToCurrentShellCommand = #". "$HOME/.config/tessera/agent-lifecycle.sh""#
    static var persistAndApplyToCurrentShellCommand: String {
        let rcLine = shellQuote(rcMarkerLine)
        let bashLoginLine = shellQuote(bashLoginMarkerLine)
        return ##"( _tessera_agent_rc_ok=1; _tessera_agent_append() { _tessera_agent_file="$1"; _tessera_agent_line="$2"; mkdir -p "${_tessera_agent_file%/*}" 2>/dev/null || return 1; touch "$_tessera_agent_file" 2>/dev/null || return 1; grep -qFx "$_tessera_agent_line" "$_tessera_agent_file" 2>/dev/null && return 0; if [ -s "$_tessera_agent_file" ] && [ "$(tail -c 1 "$_tessera_agent_file" 2>/dev/null | wc -l | tr -d '[:space:]')" = 0 ]; then printf '\n' >> "$_tessera_agent_file" || return 1; fi; printf '%s\n' "$_tessera_agent_line" >> "$_tessera_agent_file"; }; if [ -n "${ZSH_VERSION:-}" ]; then _tessera_agent_append "${ZDOTDIR:-$HOME}/.zshrc" \##(rcLine) || _tessera_agent_rc_ok=0; elif [ -n "${BASH_VERSION:-}" ]; then _tessera_agent_append "$HOME/.bashrc" \##(rcLine) || _tessera_agent_rc_ok=0; _tessera_agent_login=''; for _tessera_agent_candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do if [ -e "$_tessera_agent_candidate" ]; then _tessera_agent_login="$_tessera_agent_candidate"; break; fi; done; [ -n "$_tessera_agent_login" ] || _tessera_agent_login="$HOME/.bash_profile"; _tessera_agent_append "$_tessera_agent_login" \##(bashLoginLine) || _tessera_agent_rc_ok=0; else _tessera_agent_rc_ok=0; fi; [ "$_tessera_agent_rc_ok" -eq 1 ] ) && . "$HOME/.config/tessera/agent-lifecycle.sh""##
    }

    static let hookScript = #"""
#!/bin/sh

# Tessera Agent Center lifecycle bridge — safe to delete.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=8

provider="${1:-}"
event="${2:-}"
state="${3:-}"
reason="${4:-}"

case "$provider" in claude|codex) ;; *) exit 0 ;; esac
case "$event" in
    SessionStart|SubagentStart|SubagentStop|UserPromptSubmit|PreToolUse|PostToolUse|PermissionRequest|Notification|Stop|StopFailure|SessionEnd|WrapperExit) ;;
    *) exit 0 ;;
esac
case "$state" in waitingForInput|working|idle|unavailable) ;; *) exit 0 ;; esac
reason="$(printf '%s' "$reason" | tr -cd 'A-Za-z0-9._:-')"
reason="$(printf '%.64s' "$reason")"

# Content-free, bounded host-side breadcrumbs make real-device failures
# diagnosable without recording prompts, commands, hook payloads, paths, or
# terminal output. They are useful when a provider reports a configured hook
# but the terminal never receives its OSC frame.
diagnostic_file="$HOME/.config/tessera/agent-lifecycle-diagnostics.log"
tessera_agent_diagnostic() {
    diagnostic_phase="${1:-unknown}"
    diagnostic_detail="${2:-none}"
    mkdir -p "$HOME/.config/tessera" 2>/dev/null || return
    (umask 077; printf '%s provider=%s event=%s state=%s reason=%s phase=%s %s\n' \
        "$(date +%s 2>/dev/null || printf 0)" "$provider" "$event" "$state" \
        "$reason" "$diagnostic_phase" "$diagnostic_detail" >> "$diagnostic_file") 2>/dev/null || return
    chmod 600 "$diagnostic_file" 2>/dev/null || true
    diagnostic_size="$(wc -c < "$diagnostic_file" 2>/dev/null | tr -d '[:space:]')"
    case "$diagnostic_size" in ''|*[!0-9]*) return ;; esac
    if [ "$diagnostic_size" -gt 65536 ]; then
        diagnostic_temp="$diagnostic_file.trim.$$"
        tail -n 200 "$diagnostic_file" > "$diagnostic_temp" 2>/dev/null \
            && chmod 600 "$diagnostic_temp" 2>/dev/null \
            && mv -f "$diagnostic_temp" "$diagnostic_file" 2>/dev/null || true
    fi
}
if [ "$event" != SubagentStop ]; then
    tessera_agent_diagnostic received input=redacted
fi

input=""
session_id=""
turn_id=""
notification_type=""
permission_mode=""
agent_id=""
if command -v python3 >/dev/null 2>&1; then
    # Let Python consume the hook pipe directly. Provider payloads can contain
    # large prompts/tool inputs; copying those bytes through a shell variable
    # first made every lifecycle event needlessly expensive.
    metadata="$(python3 -c 'import json,sys,time
try: data=json.load(sys.stdin)
except Exception: data={}
print(time.time_ns())
print(str(data.get("session_id", "")).replace("\n", ""))
print(str(data.get("turn_id", "")).replace("\n", ""))
print(str(data.get("notification_type", "")).replace("\n", ""))
print(str(data.get("permission_mode", "")).replace("\n", ""))
print(str(data.get("agent_id", "")).replace("\n", ""))' 2>/dev/null || true)"
    timestamp_ns="$(printf '%s\n' "$metadata" | sed -n '1p')"
    session_id="$(printf '%s\n' "$metadata" | sed -n '2p')"
    turn_id="$(printf '%s\n' "$metadata" | sed -n '3p')"
    notification_type="$(printf '%s\n' "$metadata" | sed -n '4p')"
    permission_mode="$(printf '%s\n' "$metadata" | sed -n '5p')"
    agent_id="$(printf '%s\n' "$metadata" | sed -n '6p')"
else
    # Minimal hosts get a bounded, conservative fallback. Missing metadata is
    # safer than retaining an arbitrarily large or partial provider payload.
    if command -v dd >/dev/null 2>&1; then
        input="$( { dd bs=4096 count=16 2>/dev/null; cat >/dev/null 2>&1; } )"
    else
        cat >/dev/null 2>&1 || true
    fi
    if command -v perl >/dev/null 2>&1; then
        timestamp_ns="$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000000000' 2>/dev/null || true)"
    else
        timestamp_ns=""
    fi
fi
# Keep subagent attribution functional on minimal hosts without Python. Hook
# payload identifiers are simple JSON strings; this conservative fallback is
# only used for fields the full JSON parser did not provide.
[ -n "$session_id" ] || session_id="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$turn_id" ] || turn_id="$(printf '%s' "$input" | sed -n 's/.*"turn_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$notification_type" ] || notification_type="$(printf '%s' "$input" | sed -n 's/.*"notification_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$permission_mode" ] || permission_mode="$(printf '%s' "$input" | sed -n 's/.*"permission_mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$agent_id" ] || agent_id="$(printf '%s' "$input" | sed -n 's/.*"agent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
session_id="$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._:-')"
turn_id="$(printf '%s' "$turn_id" | tr -cd 'A-Za-z0-9._:-')"
notification_type="$(printf '%s' "$notification_type" | tr -cd 'A-Za-z0-9._:-')"
permission_mode="$(printf '%s' "$permission_mode" | tr -cd 'A-Za-z0-9._:-')"
agent_id="$(printf '%s' "$agent_id" | tr -cd 'A-Za-z0-9._:-')"
session_id="$(printf '%.256s' "$session_id")"
turn_id="$(printf '%.256s' "$turn_id")"
notification_type="$(printf '%.64s' "$notification_type")"
permission_mode="$(printf '%.64s' "$permission_mode")"
agent_id="$(printf '%.256s' "$agent_id")"
[ -n "$timestamp_ns" ] || timestamp_ns="$(date +%s)000000000"

case "$timestamp_ns" in ''|*[!0-9]*) timestamp_ns="$(date +%s)000000000" ;; esac

agent_pid=""
# This override is private to the verified Codex empty-composer launch path.
# It is accepted only from this hook's direct parent, which immediately execs
# the provider with the same PID. An inherited or user-supplied environment
# variable therefore cannot bind an unrelated process to a lifecycle event.
case "$provider:$event:$reason:${TESSERA_AGENT_VERIFIED_PROVIDER_PID:-}" in
    codex:SessionStart:verified-trusted-empty-composer:"$PPID"|\
    codex:SessionStart:verified-configured-empty-composer:"$PPID")
        if [ "$PPID" -gt 1 ] 2>/dev/null; then agent_pid="$PPID"; fi
        ;;
esac
# Bind provider-owned hook events to the matching live provider ancestor.
if [ -z "$agent_pid" ] && command -v ps >/dev/null 2>&1; then
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
agent_pid_json="${agent_pid:-null}"

# Claude labels generic subagent hooks with agent_id; Codex currently does
# not, so bracket Codex subagent activity with its dedicated start/stop
# events. While a Codex subagent is active, ambiguous generic events are not
# allowed to overwrite the root pane state or acknowledge a root prompt.
subagent_dir="$HOME/.config/tessera/active-subagents/${agent_pid:-unknown}"
subagent_key="$(printf '%s' "$agent_id" | tr -cd 'A-Za-z0-9._-')"
[ -n "$subagent_key" ] || [ "$provider" != "codex" ] || subagent_key=active
case "$event" in
    SessionStart|SessionEnd|WrapperExit)
        # A root lifecycle boundary invalidates files left by a killed
        # subagent or a previous process that reused this PID.
        if [ -z "$agent_id" ]; then
            rm -rf "$subagent_dir" 2>/dev/null || true
        fi
        ;;
    SubagentStart)
        if [ -n "$agent_pid" ] && [ -n "$subagent_key" ]; then
            mkdir -p "$subagent_dir" 2>/dev/null || true
            chmod 700 "$HOME/.config/tessera/active-subagents" "$subagent_dir" 2>/dev/null || true
            : > "$subagent_dir/$subagent_key" 2>/dev/null || true
        fi
        ;;
    SubagentStop)
        if [ -n "$subagent_key" ]; then
            rm -f "$subagent_dir/$subagent_key" 2>/dev/null || true
        fi
        # SubagentStop describes only the child. Claude may deliver it after
        # the root Stop event, so publishing its nominal working state would
        # overwrite an authoritative idle pane state. Marker cleanup is the
        # whole side effect; preserve both the retained pane state and the last
        # pane-level diagnostic used by Tessera's content-free host probe.
        exit 0
        ;;
    *)
        # Approval/elicitation events describe a pane-level user action even
        # when a subagent raised it, so they must remain visible. Other
        # subagent lifecycle events are ambiguous with the root turn and must
        # not acknowledge or terminate a root submission.
        case "$event:$state" in
            PermissionRequest:*|Notification:waitingForInput) ;;
            *)
                if [ "$provider" = "claude" ] && [ -n "$agent_id" ]; then
                    exit 0
                fi
                if [ "$provider" = "codex" ] \
                   && [ -d "$subagent_dir" ] \
                   && find "$subagent_dir" -type f -print -quit 2>/dev/null | grep -q .; then
                    exit 0
                fi
                ;;
        esac
        ;;
esac

payload="$(printf '{"version":%s,"provider":"%s","event":"%s","state":"%s","reason":"%s","timestampNs":"%s","sessionId":"%s","turnId":"%s","notificationType":"%s","permissionMode":"%s","agentPid":%s}' "$TESSERA_AGENT_INTEGRATION_VERSION" "$provider" "$event" "$state" "$reason" "$timestamp_ns" "$session_id" "$turn_id" "$notification_type" "$permission_mode" "$agent_pid_json")"

terminal_path=""
pane="${TMUX_PANE:-}"
tmux_state=not-applicable
if [ -n "$pane" ] && command -v tmux >/dev/null 2>&1; then
    terminal_path="$(tmux display-message -p -t "$pane" '#{pane_tty}' 2>/dev/null || true)"
    if tmux set-option -p -t "$pane" @tessera_agent_state "$payload" >/dev/null 2>&1; then
        tmux_state=written
    else
        tmux_state=failed
    fi
fi
if [ -z "$terminal_path" ]; then
    terminal_path="$(tty 2>/dev/null || true)"
    case "$terminal_path" in ""|"not a tty") terminal_path="" ;; esac
fi
if [ -z "$terminal_path" ] && command -v ps >/dev/null 2>&1; then
    ancestor_pid="$PPID"
    ancestor_depth=0
    while [ -n "$ancestor_pid" ] && [ "$ancestor_pid" -gt 1 ] 2>/dev/null && [ "$ancestor_depth" -lt 8 ]; do
        ancestor_tty="$(ps -o tty= -p "$ancestor_pid" 2>/dev/null | tr -d '[:space:]')"
        case "$ancestor_tty" in
            ""|"??"|"?") ;;
            *) terminal_path="/dev/$ancestor_tty"; break ;;
        esac
        ancestor_pid="$(ps -o ppid= -p "$ancestor_pid" 2>/dev/null | tr -d '[:space:]')"
        ancestor_depth=$((ancestor_depth + 1))
    done
fi

terminal_emission=absent
if [ -n "$terminal_path" ]; then
    if [ ! -w "$terminal_path" ]; then
        terminal_emission=unwritable
    else
        encoded_payload=""
        if command -v base64 >/dev/null 2>&1; then
            encoded_payload="$(printf '%s' "$payload" | base64 2>/dev/null | tr -d '\n')"
        elif command -v openssl >/dev/null 2>&1; then
            encoded_payload="$(printf '%s' "$payload" | openssl base64 2>/dev/null | tr -d '\n')"
        elif command -v python3 >/dev/null 2>&1; then
            encoded_payload="$(printf '%s' "$payload" | python3 -c 'import base64,sys; sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())' 2>/dev/null || true)"
        fi
        if [ -z "$encoded_payload" ]; then
            terminal_emission=encoding-missing
        elif printf '\033]1337;TesseraAgentState=%s\007' "$encoded_payload" > "$terminal_path" 2>/dev/null; then
            terminal_emission=written
        else
            terminal_emission=failed
        fi
    fi
fi

[ -n "$agent_pid" ] && diagnostic_agent_pid=present || diagnostic_agent_pid=absent
[ -n "$pane" ] && diagnostic_pane=present || diagnostic_pane=absent
[ -n "$terminal_path" ] && diagnostic_terminal=present || diagnostic_terminal=absent
tessera_agent_diagnostic resolved \
    "agentPid=$diagnostic_agent_pid pane=$diagnostic_pane terminal=$diagnostic_terminal tmuxState=$tmux_state terminalEmission=$terminal_emission"

exit 0
"""#

    /// Runs as the provider child process and replaces itself with the real
    /// TUI without changing terminal/job-control behavior. Availability is
    /// published only by a provider hook or, for Codex's empty composer, by an
    /// exact enabled-handler hooks/list proof whose trust grade is retained in
    /// the bootstrap reason. Launcher execution alone cannot establish
    /// availability.
    static let launcherScript = #"""
#!/bin/sh

# Tessera Agent Center provider launcher — safe to delete.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=8
provider="${1:-}"
shift || exit 64
case "$provider" in claude|codex) ;; *) exit 64 ;; esac
[ "$#" -gt 0 ] || exit 64

# Codex does not create a thread at its empty composer, so its documented
# SessionStart hook may not fire until the first prompt. The shim independently
# verifies Tessera's exact enabled handler through Codex's hooks/list API.
# Trust controls whether Codex invokes the handler; it does not change the
# app-server proof that this is Codex with Tessera's exact configuration. Both
# proof grades authorize a distinct pre-exec bootstrap event whose PID becomes
# the real provider PID on the following exec. Native hooks supersede it.
support_dir="${0%/*}"
bootstrap_reason=""
case "$provider:${TESSERA_AGENT_CODEX_BOOTSTRAP_PROOF:-}" in
    codex:"$TESSERA_AGENT_INTEGRATION_VERSION":trusted)
        bootstrap_reason=verified-trusted-empty-composer
        ;;
    codex:"$TESSERA_AGENT_INTEGRATION_VERSION":configured)
        bootstrap_reason=verified-configured-empty-composer
        ;;
esac
unset TESSERA_AGENT_CODEX_BOOTSTRAP_PROOF
if [ -n "$bootstrap_reason" ]; then
    TESSERA_AGENT_VERIFIED_PROVIDER_PID="$$" \
        "$support_dir/agent-lifecycle-hook.sh" \
        codex SessionStart idle "$bootstrap_reason" </dev/null
fi

exec "$@"
"""#

    static let codexReadinessScript = #"""
#!/bin/sh

# Tessera Agent Center Codex readiness verifier — safe to delete.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=8
provider_path="${1:-}"
shift || exit 64
[ -x "$provider_path" ] || exit 1

profile=""
probe_cwd=""
cwd_override_requested=0
expect=""
expect_option=""
hooks_enabled=1
interactive_empty_composer=1
trust_bypassed=0
probe_arguments_started=0
for argument in "$@"; do
    # `for ... in "$@"` expands the original list before the first iteration.
    # Reuse the process positional parameters as a safely quoted argv builder
    # for the app-server probe; no eval or shell-string reconstruction occurs.
    if [ "$probe_arguments_started" -eq 0 ]; then
        set --
        probe_arguments_started=1
    fi
    if [ -n "$expect" ]; then
        case "$expect" in
            profile) profile="$argument"; set -- "$@" "$expect_option" "$argument" ;;
            cwd) probe_cwd="$argument"; cwd_override_requested=1; set -- "$@" "$expect_option" "$argument" ;;
            enable)
                [ "$argument" = hooks ] && hooks_enabled=1
                set -- "$@" "$expect_option" "$argument"
                ;;
            disable)
                [ "$argument" = hooks ] && hooks_enabled=0
                set -- "$@" "$expect_option" "$argument"
                ;;
            config)
                normalized_config="$(printf '%s' "$argument" | tr -d '[:space:]')"
                case "$normalized_config" in
                    features.hooks=false) hooks_enabled=0 ;;
                    features.hooks=true) hooks_enabled=1 ;;
                esac
                set -- "$@" "$expect_option" "$argument"
                ;;
            unsupported) interactive_empty_composer=0 ;;
            neutral) set -- "$@" "$expect_option" "$argument" ;;
        esac
        expect=""
        expect_option=""
        continue
    fi
    case "$argument" in
        --) interactive_empty_composer=0; break ;;
        -p|--profile) expect=profile; expect_option="$argument" ;;
        --profile=*) profile="${argument#--profile=}"; set -- "$@" "$argument" ;;
        -C|--cd) expect=cwd; expect_option="$argument" ;;
        --cd=*) probe_cwd="${argument#--cd=}"; cwd_override_requested=1; set -- "$@" "$argument" ;;
        --enable) expect=enable; expect_option="$argument" ;;
        --enable=*)
            [ "${argument#--enable=}" = hooks ] && hooks_enabled=1
            set -- "$@" "$argument"
            ;;
        --disable) expect=disable; expect_option="$argument" ;;
        --disable=*)
            [ "${argument#--disable=}" = hooks ] && hooks_enabled=0
            set -- "$@" "$argument"
            ;;
        -c|--config) expect=config; expect_option="$argument" ;;
        -c=*|--config=*)
            normalized_config="$(printf '%s' "${argument#*=}" | tr -d '[:space:]')"
            case "$normalized_config" in
                features.hooks=false) hooks_enabled=0 ;;
                features.hooks=true) hooks_enabled=1 ;;
            esac
            set -- "$@" "$argument"
            ;;
        -m|--model|-s|--sandbox|-a|--ask-for-approval|--local-provider|--add-dir)
            expect=neutral; expect_option="$argument"
            ;;
        --model=*|--sandbox=*|--ask-for-approval=*|--local-provider=*|--add-dir=*)
            set -- "$@" "$argument"
            ;;
        --oss|--search|--no-alt-screen|--dangerously-bypass-approvals-and-sandbox)
            set -- "$@" "$argument"
            ;;
        --strict-config|--full-auto) set -- "$@" "$argument" ;;
        --dangerously-bypass-hook-trust)
            trust_bypassed=1
            set -- "$@" "$argument"
            ;;
        -p?*) profile="${argument#-p}"; set -- "$@" "$argument" ;;
        -C?*) probe_cwd="${argument#-C}"; cwd_override_requested=1; set -- "$@" "$argument" ;;
        -c?*)
            normalized_config="$(printf '%s' "${argument#-c}" | sed 's/^=//' | tr -d '[:space:]')"
            case "$normalized_config" in
                features.hooks=false) hooks_enabled=0 ;;
                features.hooks=true) hooks_enabled=1 ;;
            esac
            set -- "$@" "$argument"
            ;;
        -m?*|-s?*|-a?*) set -- "$@" "$argument" ;;
        -i|--image|--remote|--remote-auth-token-env)
            expect=unsupported; expect_option="$argument"
            ;;
        -i?*|--image=*|--remote=*|--remote-auth-token-env=*|-h|--help|-V|--version)
            interactive_empty_composer=0
            ;;
        -*) interactive_empty_composer=0 ;;
        *) interactive_empty_composer=0 ;;
    esac
done

diagnostic_file="$HOME/.config/tessera/codex-readiness-diagnostics.log"
codex_readiness_diagnostic() {
    result="$1"
    [ -n "$profile" ] && profile_state=present || profile_state=absent
    [ "$cwd_override_requested" -eq 1 ] && cwd_override=present || cwd_override=absent
    mkdir -p "$HOME/.config/tessera" 2>/dev/null || return
    (umask 077; printf '%s result=%s profile=%s cwdOverride=%s\n' \
        "$(date +%s 2>/dev/null || printf 0)" "$result" "$profile_state" "$cwd_override" \
        >> "$diagnostic_file") 2>/dev/null || return
    chmod 600 "$diagnostic_file" 2>/dev/null || true
    size="$(wc -c < "$diagnostic_file" 2>/dev/null | tr -d '[:space:]')"
    case "$size" in ''|*[!0-9]*) return ;; esac
    if [ "$size" -gt 32768 ]; then
        temporary="$diagnostic_file.trim.$$"
        tail -n 100 "$diagnostic_file" > "$temporary" 2>/dev/null \
            && chmod 600 "$temporary" 2>/dev/null \
            && mv -f "$temporary" "$diagnostic_file" 2>/dev/null || true
    fi
}

if [ "$hooks_enabled" -ne 1 ]; then
    codex_readiness_diagnostic disabled-by-arguments
    exit 1
fi
if [ -n "$expect" ]; then
    codex_readiness_diagnostic invalid-arguments
    exit 1
fi
if [ "$interactive_empty_composer" -ne 1 ]; then
    codex_readiness_diagnostic deferred-to-provider-hook
    exit 1
fi

if [ -n "$probe_cwd" ]; then
    if ! probe_cwd="$(CDPATH= cd -- "$probe_cwd" 2>/dev/null && pwd -P)"; then
        codex_readiness_diagnostic invalid-cwd
        exit 1
    fi
else
    probe_cwd="$(pwd -P 2>/dev/null || pwd)"
fi

probe_root="${TMPDIR:-/tmp}"
probe_dir="$probe_root/tessera-codex-readiness.$$"
probe_input="$probe_dir/input"
probe_output="$probe_dir/output"
probe_pid=""
probe_fd_open=0
codex_readiness_cleanup() {
    if [ "$probe_fd_open" -eq 1 ]; then
        exec 3>&-
        probe_fd_open=0
    fi
    if [ -n "$probe_pid" ]; then
        kill "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
    fi
    rm -rf "$probe_dir" 2>/dev/null || true
}
trap codex_readiness_cleanup EXIT HUP INT TERM
if ! (umask 077; mkdir "$probe_dir" && mkfifo "$probe_input" && : > "$probe_output"); then
    codex_readiness_diagnostic probe-setup-failed
    exit 1
fi
(
    cd "$probe_cwd" || exit 1
    "$provider_path" --enable hooks "$@" app-server --stdio
) < "$probe_input" > "$probe_output" 2>/dev/null &
probe_pid=$!
if ! exec 3> "$probe_input"; then
    codex_readiness_diagnostic app-server-start-failed
    exit 1
fi
probe_fd_open=1

codex_wait_for_response() {
    response_id="$1"
    response_attempt=0
    while [ "$response_attempt" -lt 50 ]; do
        if grep -Eq "^[[:space:]]*\\{\"id\"[[:space:]]*:[[:space:]]*$response_id([,}])" "$probe_output" 2>/dev/null; then
            return 0
        fi
        if ! kill -0 "$probe_pid" 2>/dev/null; then
            return 2
        fi
        response_attempt=$((response_attempt + 1))
        sleep 0.05 2>/dev/null || sleep 1
    done
    return 1
}

printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"tessera-agent-center","version":"7"}}}' >&3
codex_wait_for_response 1
response_status=$?
if [ "$response_status" -ne 0 ]; then
    if [ "$response_status" -eq 2 ]; then
        codex_readiness_diagnostic app-server-start-failed
    else
        codex_readiness_diagnostic initialize-timeout
    fi
    exit 1
fi
printf '%s\n' '{"method":"initialized"}' '{"id":2,"method":"hooks/list","params":{}}' >&3
codex_wait_for_response 2
response_status=$?
if [ "$response_status" -ne 0 ]; then
    if [ "$response_status" -eq 2 ]; then
        codex_readiness_diagnostic app-server-start-failed
    else
        codex_readiness_diagnostic hooks-list-timeout
    fi
    exit 1
fi
request_output="$(cat "$probe_output" 2>/dev/null || true)"

session_record="$(printf '%s\n' "$request_output" | awk '
{
    remaining = $0
    while ((start = index(remaining, "{\"key\":")) > 0) {
        remaining = substr(remaining, start)
        finish = index(remaining, "}")
        if (finish == 0) break
        record = substr(remaining, 1, finish)
        if (index(record, "agent-lifecycle-hook.sh") > 0 \
            && index(record, "codex SessionStart idle session-start") > 0) {
            print record
            exit
        }
        remaining = substr(remaining, finish + 1)
    }
}')"
if [ -z "$session_record" ] \
   || ! printf '%s\n' "$session_record" \
        | grep -Fq '"command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex SessionStart idle session-start"'; then
    codex_readiness_diagnostic handler-missing
    exit 1
fi
if ! printf '%s\n' "$session_record" | grep -Eq '"eventName"[[:space:]]*:[[:space:]]*"(sessionStart|session_start)"' \
   || ! printf '%s\n' "$session_record" | grep -Eq '"matcher"[[:space:]]*:[[:space:]]*"startup\|resume\|clear\|compact"'; then
    codex_readiness_diagnostic handler-mismatch
    exit 1
fi
if ! printf '%s\n' "$session_record" | grep -Eq '"enabled"[[:space:]]*:[[:space:]]*true'; then
    codex_readiness_diagnostic handler-disabled
    exit 1
fi
if printf '%s\n' "$session_record" \
    | grep -Eq '"trustStatus"[[:space:]]*:[[:space:]]*"(trusted|managed)"|"isManaged"[[:space:]]*:[[:space:]]*true'; then
    codex_readiness_diagnostic trusted
    exit 0
fi
if [ "$trust_bypassed" -eq 1 ]; then
    codex_readiness_diagnostic explicitly-bypassed
    exit 0
fi

codex_readiness_diagnostic handler-untrusted
exit 2
"""#

    /// PATH-level provider shims let ordinary commands and self-referential
    /// aliases/functions keep their exact behavior while still injecting the
    /// provider's documented hook configuration. Each invocation resolves the
    /// real executable against the live PATH while skipping path aliases and
    /// stale Tessera shim copies from other homes. Version-manager changes made
    /// after the shell was activated therefore work without recursion or a
    /// reload.
    static let claudeShimScript = #"""
#!/bin/sh

# Tessera Agent Center Claude shim — safe to delete.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=8
shim_path="$0"
case "$shim_path" in /*) ;; *) shim_path="$(pwd -P)/$shim_path" ;; esac
shim_link_depth=0
while [ -L "$shim_path" ]; do
    shim_link_depth=$((shim_link_depth + 1))
    if [ "$shim_link_depth" -gt 40 ]; then
        printf '%s\n' 'Tessera: Claude integration shim has a cyclic symlink.' >&2
        exit 126
    fi
    shim_target="$(readlink "$shim_path" 2>/dev/null || true)"
    [ -n "$shim_target" ] || break
    case "$shim_target" in
        /*) shim_path="$shim_target" ;;
        *) shim_path="${shim_path%/*}/$shim_target" ;;
    esac
done
shim_dir="${shim_path%/*}"
shim_dir="$(CDPATH= cd -- "$shim_dir" 2>/dev/null && pwd -P)" || exit 126
shim_path="$shim_dir/claude"
support_dir="${shim_dir%/*}"
TESSERA_AGENT_SUPPORT_DIR="$support_dir"
export TESSERA_AGENT_SUPPORT_DIR
provider_path=""
remaining_path="${PATH:-}"
while :; do
    case "$remaining_path" in
        *:*) path_entry="${remaining_path%%:*}"; remaining_path="${remaining_path#*:}"; path_more=1 ;;
        *) path_entry="$remaining_path"; path_more=0 ;;
    esac
    search_dir="${path_entry:-.}"
    candidate="$search_dir/claude"
    if [ -x "$candidate" ]; then
        candidate_is_tessera_shim=0
        if [ -r "$candidate" ] \
           && dd if="$candidate" bs=512 count=1 2>/dev/null \
                | LC_ALL=C grep -Fq 'Tessera Agent Center Claude shim'; then
            candidate_is_tessera_shim=1
        fi
        if [ "$candidate" = "$shim_path" ] \
           || [ "$candidate" -ef "$shim_path" ] 2>/dev/null \
           || [ "$candidate_is_tessera_shim" -eq 1 ]; then
            :
        else
            case "$candidate" in
                /*) provider_path="$candidate" ;;
                *)
                    candidate_dir="${candidate%/*}"
                    candidate_name="${candidate##*/}"
                    provider_path="$(CDPATH= cd -- "$candidate_dir" 2>/dev/null && pwd -P)/$candidate_name"
                    ;;
            esac
            break
        fi
    fi
    [ "$path_more" -eq 1 ] || break
done
if [ -z "$provider_path" ]; then
    printf '%s\n' 'Tessera: could not resolve the Claude executable outside its integration shim.' >&2
    exit 127
fi

"$support_dir/agent-launch.sh" claude "$provider_path" "$@"
status=$?
"$support_dir/agent-lifecycle-hook.sh" claude WrapperExit unavailable session-ended </dev/null
exit "$status"
"""#

    static let codexShimScript = #"""
#!/bin/sh

# Tessera Agent Center Codex shim — safe to delete.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=8
shim_path="$0"
case "$shim_path" in /*) ;; *) shim_path="$(pwd -P)/$shim_path" ;; esac
shim_link_depth=0
while [ -L "$shim_path" ]; do
    shim_link_depth=$((shim_link_depth + 1))
    if [ "$shim_link_depth" -gt 40 ]; then
        printf '%s\n' 'Tessera: Codex integration shim has a cyclic symlink.' >&2
        exit 126
    fi
    shim_target="$(readlink "$shim_path" 2>/dev/null || true)"
    [ -n "$shim_target" ] || break
    case "$shim_target" in
        /*) shim_path="$shim_target" ;;
        *) shim_path="${shim_path%/*}/$shim_target" ;;
    esac
done
shim_dir="${shim_path%/*}"
shim_dir="$(CDPATH= cd -- "$shim_dir" 2>/dev/null && pwd -P)" || exit 126
shim_path="$shim_dir/codex"
support_dir="${shim_dir%/*}"
TESSERA_AGENT_SUPPORT_DIR="$support_dir"
export TESSERA_AGENT_SUPPORT_DIR
provider_path=""
remaining_path="${PATH:-}"
while :; do
    case "$remaining_path" in
        *:*) path_entry="${remaining_path%%:*}"; remaining_path="${remaining_path#*:}"; path_more=1 ;;
        *) path_entry="$remaining_path"; path_more=0 ;;
    esac
    search_dir="${path_entry:-.}"
    candidate="$search_dir/codex"
    if [ -x "$candidate" ]; then
        candidate_is_tessera_shim=0
        if [ -r "$candidate" ] \
           && dd if="$candidate" bs=512 count=1 2>/dev/null \
                | LC_ALL=C grep -Fq 'Tessera Agent Center Codex shim'; then
            candidate_is_tessera_shim=1
        fi
        if [ "$candidate" = "$shim_path" ] \
           || [ "$candidate" -ef "$shim_path" ] 2>/dev/null \
           || [ "$candidate_is_tessera_shim" -eq 1 ]; then
            :
        else
            case "$candidate" in
                /*) provider_path="$candidate" ;;
                *)
                    candidate_dir="${candidate%/*}"
                    candidate_name="${candidate##*/}"
                    provider_path="$(CDPATH= cd -- "$candidate_dir" 2>/dev/null && pwd -P)/$candidate_name"
                    ;;
            esac
            break
        fi
    fi
    [ "$path_more" -eq 1 ] || break
done
if [ -z "$provider_path" ]; then
    printf '%s\n' 'Tessera: could not resolve the Codex executable outside its integration shim.' >&2
    exit 127
fi

readiness_status=0
"$support_dir/agent-codex-readiness.sh" "$provider_path" "$@" || readiness_status=$?
case "$readiness_status" in
    0) TESSERA_AGENT_CODEX_BOOTSTRAP_PROOF="$TESSERA_AGENT_INTEGRATION_VERSION:trusted" ;;
    2) TESSERA_AGENT_CODEX_BOOTSTRAP_PROOF="$TESSERA_AGENT_INTEGRATION_VERSION:configured" ;;
    *) unset TESSERA_AGENT_CODEX_BOOTSTRAP_PROOF ;;
esac
export TESSERA_AGENT_CODEX_BOOTSTRAP_PROOF

"$support_dir/agent-launch.sh" codex "$provider_path" --enable hooks "$@"
status=$?
"$support_dir/agent-lifecycle-hook.sh" codex WrapperExit unavailable session-ended </dev/null
exit "$status"
"""#

    static let codexHooks = #"""
{"hooks":{"SessionStart":[{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex SessionStart idle session-start"}]}],"SubagentStart":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex SubagentStart working subagent-start"}]}],"SubagentStop":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex SubagentStop working subagent-stop"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex UserPromptSubmit working agent-turn"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex PreToolUse working agent-turn"}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex PostToolUse working agent-turn"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex PermissionRequest waitingForInput permission"}]}],"Stop":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex Stop idle turn-stopped"}]}]}}
"""#

    static let claudeSettings = #"""
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude SessionStart idle session-start"}]}],"SubagentStart":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude SubagentStart working subagent-start"}]}],"SubagentStop":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude SubagentStop working subagent-stop"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude UserPromptSubmit working agent-turn"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude PreToolUse working agent-turn"}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude PostToolUse working agent-turn"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude PermissionRequest waitingForInput permission"}]}],"Notification":[{"matcher":"permission_prompt|elicitation_dialog","hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude Notification waitingForInput permission"}]},{"matcher":"idle_prompt","hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude Notification idle idle-prompt"}]}],"Stop":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude Stop idle turn-stopped"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude StopFailure unavailable turn-failed"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude SessionEnd unavailable session-ended"}]}]}}
"""#

    static let shellIntegration = #"""
# Tessera Agent Center integration version 8 — safe to delete.

TESSERA_AGENT_INTEGRATION_VERSION=8
export TESSERA_AGENT_INTEGRATION_VERSION

# Hooks live in each provider's official user configuration, so aliases,
# functions, absolute executable paths, version managers, and user arguments
# do not depend on interception. The PATH shims only add immediate Codex
# empty-composer verification and a prompt exit breadcrumb when they are used.
_tessera_agent_previous_claude_wrapper_version="${TESSERA_AGENT_CLAUDE_WRAPPER_VERSION:-}"
_tessera_agent_previous_codex_wrapper_version="${TESSERA_AGENT_CODEX_WRAPPER_VERSION:-}"
unset TESSERA_AGENT_CLAUDE_WRAPPER_VERSION TESSERA_AGENT_CODEX_WRAPPER_VERSION
unset TESSERA_AGENT_SHIM_VERSION TESSERA_AGENT_SHIM_DIR

_tessera_agent_support_dir="$HOME/.config/tessera"
if _tessera_agent_support_dir="$(CDPATH= cd -- "$_tessera_agent_support_dir" 2>/dev/null && pwd -P)"; then
    TESSERA_AGENT_SUPPORT_DIR="$_tessera_agent_support_dir"
    export TESSERA_AGENT_SUPPORT_DIR
fi
_tessera_agent_bin_dir="$_tessera_agent_support_dir/bin"

# Recompute from the live PATH every source. Remove every literal copy of the
# Tessera bin entry, preserve empty entries, then prepend exactly one copy.
_tessera_agent_remaining_path="${PATH:-}"
_tessera_agent_clean_path=""
_tessera_agent_clean_path_started=0
while :; do
    case "$_tessera_agent_remaining_path" in
        *:*)
            _tessera_agent_path_entry="${_tessera_agent_remaining_path%%:*}"
            _tessera_agent_remaining_path="${_tessera_agent_remaining_path#*:}"
            _tessera_agent_path_more=1
            ;;
        *)
            _tessera_agent_path_entry="$_tessera_agent_remaining_path"
            _tessera_agent_path_more=0
            ;;
    esac
    if [ "$_tessera_agent_path_entry" != "$_tessera_agent_bin_dir" ]; then
        if [ "$_tessera_agent_clean_path_started" -eq 0 ]; then
            _tessera_agent_clean_path="$_tessera_agent_path_entry"
            _tessera_agent_clean_path_started=1
        else
            _tessera_agent_clean_path="$_tessera_agent_clean_path:$_tessera_agent_path_entry"
        fi
    fi
    [ "$_tessera_agent_path_more" -eq 1 ] || break
done
if [ -x "$_tessera_agent_bin_dir/claude" ] \
   && [ -x "$_tessera_agent_bin_dir/codex" ]; then
    if [ "$_tessera_agent_clean_path_started" -eq 1 ]; then
        # A deliberately empty PATH is one empty entry (the current directory),
        # so retain its trailing separator after prepending Tessera's shims.
        PATH="$_tessera_agent_bin_dir:$_tessera_agent_clean_path"
    else
        PATH="$_tessera_agent_bin_dir"
    fi
    TESSERA_AGENT_SHIM_VERSION=8
    TESSERA_AGENT_SHIM_DIR="$_tessera_agent_bin_dir"
    export PATH TESSERA_AGENT_SHIM_VERSION TESSERA_AGENT_SHIM_DIR
fi

# Versions 4 and 5 created Tessera-owned provider functions. Remove only their
# exact wrapper shapes during upgrade; arbitrary user functions stay intact.
case "$_tessera_agent_previous_claude_wrapper_version" in
    4|5)
        _tessera_agent_existing_function="$(typeset -f claude 2>/dev/null || true)"
        case "$_tessera_agent_existing_function" in
            *agent-launch.sh*claude-agent-hooks.json*WrapperExit*|*".config/tessera/bin/claude"*)
                unset -f claude
                ;;
        esac
        ;;
esac
case "$_tessera_agent_previous_codex_wrapper_version" in
    4|5)
        _tessera_agent_existing_function="$(typeset -f codex 2>/dev/null || true)"
        case "$_tessera_agent_existing_function" in
            *agent-launch.sh*--enable*hooks*WrapperExit*|*".config/tessera/bin/codex"*)
                unset -f codex
                ;;
        esac
        ;;
esac
unset _tessera_agent_existing_function

# Capture this shell's process identity without installing or invoking a signal
# trap. PID plus kernel/process start identity rejects stale files after PID
# reuse, remains valid while the shell waits on a child such as Vim, and does
# not interfere with any user or framework-owned WINCH behavior.
_tessera_agent_shell_dir="$_tessera_agent_support_dir/active-shells"
_tessera_agent_shell_start=""
if [ -r "/proc/$$/stat" ]; then
    _tessera_agent_shell_start="proc:$(sed 's/^.*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $20}')"
fi
if [ -z "$_tessera_agent_shell_start" ]; then
    _tessera_agent_shell_start="ps:$(ps -o lstart= -p $$ 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

# Shell readiness proves only that this shell loaded the current integration
# and can reach the current shims. Provider hooks independently prove runtime
# availability regardless of the command spelling that launched the provider.
if [ "${TESSERA_AGENT_SHIM_VERSION:-}" = "$TESSERA_AGENT_INTEGRATION_VERSION" ] \
   && [ "$_tessera_agent_shell_start" != "ps:" ] \
   && [ "$_tessera_agent_shell_start" != "proc:" ]; then
    mkdir -p "$_tessera_agent_shell_dir" 2>/dev/null || true
    chmod 700 "$_tessera_agent_shell_dir" 2>/dev/null || true
    printf '%s|%s|%s\n' \
        "$TESSERA_AGENT_INTEGRATION_VERSION" \
        "$_tessera_agent_shell_start" \
        "$TESSERA_AGENT_SHIM_VERSION" \
        > "$_tessera_agent_shell_dir/$$" 2>/dev/null || true
    chmod 600 "$_tessera_agent_shell_dir/$$" 2>/dev/null || true
    if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
        tmux set-option -p -t "$TMUX_PANE" @tessera_agent_shell \
            "$TESSERA_AGENT_INTEGRATION_VERSION:$$:$TESSERA_AGENT_SHIM_VERSION" \
            >/dev/null 2>&1 || true
    fi
else
    rm -f "$_tessera_agent_shell_dir/$$" 2>/dev/null || true
    if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
        _tessera_agent_pane_marker="$(tmux show-options -pv -t "$TMUX_PANE" @tessera_agent_shell 2>/dev/null || true)"
        case "$_tessera_agent_pane_marker" in
            "$TESSERA_AGENT_INTEGRATION_VERSION:$$:"*)
                tmux set-option -pu -t "$TMUX_PANE" @tessera_agent_shell >/dev/null 2>&1 || true
                ;;
        esac
        unset _tessera_agent_pane_marker
    fi
fi
unset _tessera_agent_bin_dir _tessera_agent_remaining_path _tessera_agent_clean_path
unset _tessera_agent_clean_path_started _tessera_agent_path_entry _tessera_agent_path_more
unset _tessera_agent_shell_dir _tessera_agent_shell_start
unset _tessera_agent_previous_claude_wrapper_version _tessera_agent_previous_codex_wrapper_version
unset _tessera_agent_support_dir
"""#

    static var confirmationText: String {
        """
        Installs Tessera-owned lifecycle scripts and optional PATH shims under ~/.config/tessera, then adds guarded source lines to the selected bash/zsh interactive and login startup files, including zsh's ZDOTDIR when configured. The sourced script publishes a PID-and-process-start marker without installing signal traps, so user shell behavior remains unchanged and child programs inherit activation. Existing aliases and functions remain unchanged. Provider hooks are merged into the official ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json and ${CODEX_HOME:-~/.codex}/hooks.json user layers, so aliases, functions, absolute executable paths, version managers, and user arguments do not depend on Tessera intercepting the command. A Tessera-owned ~/.config/tessera/claude-agent-hooks.json compatibility copy keeps older explicit Claude aliases working without injecting a competing --settings option into normal launches. Only Tessera-owned handlers are replaced; unrelated settings and hooks remain intact, including symlink-managed files, using atomic compare-and-swap updates. The PATH shims add immediate Codex empty-composer verification and prompt exit state when used. Original provider arguments are preserved. Codex may ask you to review and trust Tessera's groups on its first integrated launch; until that native trust settles, Tessera reports only its separately verified provider/configuration bootstrap state.
        """
    }

    static var disclosedSource: String {
        """
        ~/.config/tessera/agent-lifecycle-hook.sh
        ------------------------------------------------------------
        \(hookScript)

        ~/.config/tessera/agent-launch.sh
        ------------------------------------------------------------
        \(launcherScript)

        ~/.config/tessera/agent-codex-readiness.sh
        ------------------------------------------------------------
        \(codexReadinessScript)

        ~/.config/tessera/bin/claude
        ------------------------------------------------------------
        \(claudeShimScript)

        ~/.config/tessera/bin/codex
        ------------------------------------------------------------
        \(codexShimScript)

        ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json (Tessera groups are merged; all other settings and hooks are preserved)
        ------------------------------------------------------------
        \(claudeSettings)

        ~/.config/tessera/claude-agent-hooks.json (Tessera-owned compatibility settings for existing explicit aliases)
        ------------------------------------------------------------
        \(claudeSettings)

        ${CODEX_HOME:-~/.codex}/hooks.json (Tessera groups are merged; other groups are preserved)
        ------------------------------------------------------------
        \(codexHooks)

        ~/.config/tessera/agent-lifecycle.sh
        ------------------------------------------------------------
        \(shellIntegration)

        Interactive shell startup line written once per selected bash/zsh file
        ------------------------------------------------------------
        \(rcMarkerLine)

        Bash login startup line written once to the selected login file
        ------------------------------------------------------------
        \(bashLoginMarkerLine)
        """
    }

    static func probe(
        using bridge: FileBridge,
        diagnostic: ((String) -> Void)? = nil
    ) async throws -> AgentLifecycleHostInstallation {
        try await probe(
            execute: { command in
                try await bridge.connect()
                return try await bridge.exec(command, inShell: true)
            },
            diagnostic: diagnostic
        )
    }

    static func probe(
        execute: (String) async throws -> String,
        diagnostic: ((String) -> Void)? = nil
    ) async throws -> AgentLifecycleHostInstallation {
        let output = try await execute(makeStatusCommand())
        if let detail = parseInstallationDiagnostic(output) {
            diagnostic?("installation \(detail)")
        }
        if let detail = parseHostDiagnostic(output) {
            diagnostic?("runtime \(detail)")
        }
        guard let status = parseStatus(output) else {
            throw AgentLifecycleIntegrationInstallError.verificationFailed(output)
        }
        return status
    }

    enum ProviderConfigSnapshot: Equatable {
        case missing
        case present(String)
    }
    typealias CodexHooksSnapshot = ProviderConfigSnapshot

    static func makeCodexHooksReadCommand() -> String {
        let marker = shellQuote(codexHooksSnapshotMarker)
        return "tessera_codex_hooks=\"${CODEX_HOME:-$HOME/.codex}/hooks.json\"; if [ -L \"$tessera_codex_hooks\" ] && [ ! -e \"$tessera_codex_hooks\" ]; then printf '%s error:dangling-symlink\\n' \(marker); elif [ ! -e \"$tessera_codex_hooks\" ]; then printf '%s missing\\n' \(marker); elif [ ! -f \"$tessera_codex_hooks\" ] || [ ! -r \"$tessera_codex_hooks\" ]; then printf '%s error:not-readable-file\\n' \(marker); else tessera_codex_hooks_base64=\"$(base64 < \"$tessera_codex_hooks\" 2>/dev/null | tr -d '\\n')\"; printf '%s present:%s\\n' \(marker) \"$tessera_codex_hooks_base64\"; fi"
    }

    static func makeClaudeSettingsReadCommand() -> String {
        let marker = shellQuote(claudeSettingsSnapshotMarker)
        return "tessera_claude_settings=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\"; if [ -L \"$tessera_claude_settings\" ] && [ ! -e \"$tessera_claude_settings\" ]; then printf '%s error:dangling-symlink\\n' \(marker); elif [ ! -e \"$tessera_claude_settings\" ]; then printf '%s missing\\n' \(marker); elif [ ! -f \"$tessera_claude_settings\" ] || [ ! -r \"$tessera_claude_settings\" ]; then printf '%s error:not-readable-file\\n' \(marker); else tessera_claude_settings_base64=\"$(base64 < \"$tessera_claude_settings\" 2>/dev/null | tr -d '\\n')\"; printf '%s present:%s\\n' \(marker) \"$tessera_claude_settings_base64\"; fi"
    }

    static func parseCodexHooksSnapshot(_ output: String) -> ProviderConfigSnapshot? {
        parseProviderConfigSnapshot(output, marker: codexHooksSnapshotMarker)
    }

    static func parseClaudeSettingsSnapshot(_ output: String) -> ProviderConfigSnapshot? {
        parseProviderConfigSnapshot(output, marker: claudeSettingsSnapshotMarker)
    }

    private static func parseProviderConfigSnapshot(
        _ output: String,
        marker: String
    ) -> ProviderConfigSnapshot? {
        let prefix = "\(marker) "
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix(prefix) else { continue }
            let payload = String(value.dropFirst(prefix.count))
            if payload == "missing" { return .missing }
            guard payload.hasPrefix("present:"),
                  let data = Data(base64Encoded: String(payload.dropFirst("present:".count))),
                  let contents = String(data: data, encoding: .utf8)
            else { return nil }
            return .present(contents)
        }
        return nil
    }

    static func mergeCodexHooks(existing: String?) throws -> String {
        try mergeProviderHooks(
            existing: existing,
            canonical: codexHooks,
            provider: "codex",
            configLabel: "Codex hooks.json"
        )
    }

    static func mergeClaudeSettings(existing: String?) throws -> String {
        try mergeProviderHooks(
            existing: existing,
            canonical: claudeSettings,
            provider: "claude",
            configLabel: "Claude settings.json"
        )
    }

    private static func mergeProviderHooks(
        existing: String?,
        canonical: String,
        provider: String,
        configLabel: String
    ) throws -> String {
        var root: [String: Any]
        if let existing {
            guard let data = existing.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed(
                    "the existing file is not a JSON object"
                )
            }
            root = object
        } else {
            root = [:]
        }

        var mergedHooks: [String: Any]
        if let value = root["hooks"] {
            guard let hooks = value as? [String: Any] else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed(
                    "the existing hooks field is not an object"
                )
            }
            mergedHooks = hooks
        } else {
            mergedHooks = [:]
        }

        guard let canonicalData = canonical.data(using: .utf8),
              let canonicalRoot = try JSONSerialization.jsonObject(with: canonicalData) as? [String: Any],
              let canonicalHooks = canonicalRoot["hooks"] as? [String: Any]
        else {
            throw AgentLifecycleIntegrationInstallError.verificationFailed(
                "Tessera's bundled \(configLabel) hook definition is invalid"
            )
        }

        let commandNeedle = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" \(provider) "
        for (event, canonicalValue) in canonicalHooks {
            guard let canonicalGroups = canonicalValue as? [[String: Any]] else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed(
                    "Tessera's \(event) hook groups are invalid"
                )
            }

            var preservedGroups: [[String: Any]] = []
            if let existingValue = mergedHooks[event] {
                guard let existingGroups = existingValue as? [[String: Any]] else {
                    throw AgentLifecycleIntegrationInstallError.verificationFailed(
                        "the existing \(event) hook groups are not an array of objects"
                    )
                }
                for var group in existingGroups {
                    guard let handlersValue = group["hooks"] else {
                        preservedGroups.append(group)
                        continue
                    }
                    guard let handlers = handlersValue as? [[String: Any]] else {
                        throw AgentLifecycleIntegrationInstallError.verificationFailed(
                            "an existing \(event) handler list is not an array of objects"
                        )
                    }
                    let preservedHandlers = handlers.filter { handler in
                        guard let command = handler["command"] as? String else { return true }
                        return !command.contains(commandNeedle)
                    }
                    if !preservedHandlers.isEmpty {
                        group["hooks"] = preservedHandlers
                        preservedGroups.append(group)
                    }
                }
            }
            preservedGroups.append(contentsOf: canonicalGroups)
            mergedHooks[event] = preservedGroups
        }
        root["hooks"] = mergedHooks

        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let merged = String(data: data, encoding: .utf8) else {
            throw AgentLifecycleIntegrationInstallError.verificationFailed(
                "the merged \(configLabel) is not UTF-8"
            )
        }
        return merged
    }

    static func install(using bridge: FileBridge) async throws {
        try await install { command in
            try await bridge.connect()
            return try await bridge.exec(command, inShell: true)
        }
    }

    static func install(
        execute: (String) async throws -> String
    ) async throws {
        var lastOutput = ""
        for _ in 0..<3 {
            let snapshotOutput = try await execute(
                "\(makeCodexHooksReadCommand()); \(makeClaudeSettingsReadCommand())"
            )
            guard let codexSnapshot = parseCodexHooksSnapshot(snapshotOutput),
                  let claudeSnapshot = parseClaudeSettingsSnapshot(snapshotOutput)
            else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed(snapshotOutput)
            }
            let existingCodexHooks: String?
            switch codexSnapshot {
            case .missing: existingCodexHooks = nil
            case .present(let contents): existingCodexHooks = contents
            }
            let existingClaudeSettings: String?
            switch claudeSnapshot {
            case .missing: existingClaudeSettings = nil
            case .present(let contents): existingClaudeSettings = contents
            }
            let mergedCodexHooks: String
            let mergedClaudeSettings: String
            do {
                mergedCodexHooks = try mergeCodexHooks(existing: existingCodexHooks)
                mergedClaudeSettings = try mergeClaudeSettings(existing: existingClaudeSettings)
            } catch {
                throw AgentLifecycleIntegrationInstallError.verificationFailed(
                    "Provider hook settings could not be merged safely: \(error.localizedDescription)"
                )
            }
            let output = try await execute(
                makeInstallCommand(
                    mergedCodexHooks: mergedCodexHooks,
                    expectedCodexHooks: existingCodexHooks,
                    mergedClaudeSettings: mergedClaudeSettings,
                    expectedClaudeSettings: existingClaudeSettings
                )
            )
            lastOutput = output
            if output.contains(codexHooksRaceMarker)
                || output.contains(claudeSettingsRaceMarker) {
                continue
            }
            guard output.contains(verificationMarker), parseStatus(output) == .current else {
                throw AgentLifecycleIntegrationInstallError.verificationFailed(output)
            }
            return
        }
        throw AgentLifecycleIntegrationInstallError.verificationFailed(
            lastOutput.isEmpty
                ? "Provider hook settings kept changing during installation."
                : lastOutput
        )
    }

    static func makeInstallCommand() -> String {
        makeInstallCommand(
            mergedCodexHooks: codexHooks,
            expectedCodexHooks: nil,
            mergedClaudeSettings: claudeSettings,
            expectedClaudeSettings: nil
        )
    }

    private static func makeInstallCommand(
        mergedCodexHooks: String,
        expectedCodexHooks: String?,
        mergedClaudeSettings: String,
        expectedClaudeSettings: String?
    ) -> String {
        let hook = shellQuote(hookScript)
        let launcher = shellQuote(launcherScript)
        let codexReadiness = shellQuote(codexReadinessScript)
        let claudeShim = shellQuote(claudeShimScript)
        let codexShim = shellQuote(codexShimScript)
        let installedCodexHooks = shellQuote(mergedCodexHooks)
        let installedClaudeSettings = shellQuote(mergedClaudeSettings)
        let legacyClaudeSettings = shellQuote(claudeSettings)
        let integration = shellQuote(shellIntegration)
        let line = shellQuote(rcMarkerLine)
        let bashLoginLine = shellQuote(bashLoginMarkerLine)
        let report = shellQuote(verificationMarker)
        let writeCodexHooks = makeAtomicConfigWriteCommand(
            variablePrefix: "tessera_codex_hooks",
            directoryExpression: "${CODEX_HOME:-$HOME/.codex}",
            filename: "hooks.json",
            mergedContents: installedCodexHooks,
            expectedContents: expectedCodexHooks,
            raceMarker: codexHooksRaceMarker,
            errorMarker: "TESSERA_AGENT_CODEX_HOOKS_ERROR"
        )
        let writeClaudeSettings = makeAtomicConfigWriteCommand(
            variablePrefix: "tessera_claude_settings",
            directoryExpression: "${CLAUDE_CONFIG_DIR:-$HOME/.claude}",
            filename: "settings.json",
            mergedContents: installedClaudeSettings,
            expectedContents: expectedClaudeSettings,
            raceMarker: claudeSettingsRaceMarker,
            errorMarker: "TESSERA_AGENT_CLAUDE_SETTINGS_ERROR"
        )
        func atomicSupportWrite(
            quotedContents: String,
            path: String,
            mode: Int
        ) -> String {
            let temporaryPath = "\(path).tessera.$$"
            return "(umask 077; printf '%s\\n' \(quotedContents) > \"\(temporaryPath)\") && chmod \(mode) \"\(temporaryPath)\" && mv -f \"\(temporaryPath)\" \"\(path)\""
        }
        let supportWrites = [
            atomicSupportWrite(
                quotedContents: hook,
                path: "$HOME/.config/tessera/agent-lifecycle-hook.sh",
                mode: 700
            ),
            atomicSupportWrite(
                quotedContents: launcher,
                path: "$HOME/.config/tessera/agent-launch.sh",
                mode: 700
            ),
            atomicSupportWrite(
                quotedContents: codexReadiness,
                path: "$HOME/.config/tessera/agent-codex-readiness.sh",
                mode: 700
            ),
            atomicSupportWrite(
                quotedContents: claudeShim,
                path: "$HOME/.config/tessera/bin/claude",
                mode: 700
            ),
            atomicSupportWrite(
                quotedContents: codexShim,
                path: "$HOME/.config/tessera/bin/codex",
                mode: 700
            ),
            atomicSupportWrite(
                quotedContents: integration,
                path: "$HOME/.config/tessera/agent-lifecycle.sh",
                mode: 600
            ),
            atomicSupportWrite(
                quotedContents: legacyClaudeSettings,
                path: "$HOME/.config/tessera/claude-agent-hooks.json",
                mode: 600
            ),
        ].joined(separator: " && ")
        let writeFiles = "mkdir -p \"$HOME/.config/tessera/bin\" && chmod 700 \"$HOME/.config/tessera\" \"$HOME/.config/tessera/bin\" && \(supportWrites) && rm -f \"$HOME/.config/tessera/codex-hooks-installed.json\""
        let append = "tessera_rc_ok=1; tessera_append_line() { tessera_append_file=\"$1\"; tessera_append_value=\"$2\"; grep -qFx \"$tessera_append_value\" \"$tessera_append_file\" 2>/dev/null && return 0; if [ -s \"$tessera_append_file\" ] && [ \"$(tail -c 1 \"$tessera_append_file\" 2>/dev/null | wc -l | tr -d '[:space:]')\" = 0 ]; then printf '\\n' >> \"$tessera_append_file\" || return 1; fi; printf '%s\\n' \"$tessera_append_value\" >> \"$tessera_append_file\"; }; tessera_zshrc=\"${ZDOTDIR:-$HOME}/.zshrc\"; case \"${SHELL##*/}\" in zsh) tessera_primary_rc=\"$tessera_zshrc\" ;; *) tessera_primary_rc=\"$HOME/.bashrc\" ;; esac; for tessera_rc in \"$HOME/.bashrc\" \"$tessera_zshrc\"; do if [ -e \"$tessera_rc\" ] || [ \"$tessera_rc\" = \"$tessera_primary_rc\" ]; then mkdir -p \"${tessera_rc%/*}\" 2>/dev/null || tessera_rc_ok=0; touch \"$tessera_rc\" 2>/dev/null || tessera_rc_ok=0; tessera_append_line \"$tessera_rc\" \(line) || tessera_rc_ok=0; fi; done; tessera_bash_login=''; for tessera_candidate in \"$HOME/.bash_profile\" \"$HOME/.bash_login\" \"$HOME/.profile\"; do if [ -e \"$tessera_candidate\" ]; then tessera_bash_login=\"$tessera_candidate\"; break; fi; done; if [ -z \"$tessera_bash_login\" ] && [ \"${SHELL##*/}\" = bash ]; then tessera_bash_login=\"$HOME/.bash_profile\"; fi; if [ -n \"$tessera_bash_login\" ]; then touch \"$tessera_bash_login\" 2>/dev/null || tessera_rc_ok=0; tessera_append_line \"$tessera_bash_login\" \(bashLoginLine) || tessera_rc_ok=0; fi; [ \"$tessera_rc_ok\" -eq 1 ]"
        // Publish every executable/support file atomically before activating
        // provider configuration that references it. An interrupted update
        // can leave a checksum-detectable mixture of complete versions, but
        // never a hook or shim truncated halfway through a shell program.
        return "\(writeFiles) && \(writeCodexHooks) && \(writeClaudeSettings) && \(append) && \(makeStatusCommand()) && echo \(report)"
    }

    static func makeStatusCommand() -> String {
        let prefix = shellQuote(statusMarker)
        let diagnosticPrefix = shellQuote(installationDiagnosticMarker)
        let line = shellQuote(rcMarkerLine)
        let bashLoginLine = shellQuote(bashLoginMarkerLine)
        let versionNeedle = shellQuote("TESSERA_AGENT_INTEGRATION_VERSION=")
        let staticFiles = [
            ("hook", "hook", "$HOME/.config/tessera/agent-lifecycle-hook.sh", hookScript, true),
            ("launcher", "launcher", "$HOME/.config/tessera/agent-launch.sh", launcherScript, true),
            ("codex_readiness", "codexReadiness", "$HOME/.config/tessera/agent-codex-readiness.sh", codexReadinessScript, true),
            ("claude_shim", "claudeShim", "$HOME/.config/tessera/bin/claude", claudeShimScript, true),
            ("codex_shim", "codexShim", "$HOME/.config/tessera/bin/codex", codexShimScript, true),
            ("integration", "integration", "$HOME/.config/tessera/agent-lifecycle.sh", shellIntegration, false),
            ("claude_legacy", "claudeLegacy", "$HOME/.config/tessera/claude-agent-hooks.json", claudeSettings, false),
        ]
        let fileBindings = staticFiles.map { "\($0.0)=\"\($0.2)\"" }.joined(separator: "; ")
        let missingFiles = staticFiles.map {
            $0.4 ? "[ ! -x \"$\($0.0)\" ]" : "[ ! -r \"$\($0.0)\" ]"
        }.joined(separator: " || ")
        let checksumProbes = staticFiles.map {
            let requiredTest = $0.4 ? "-x" : "-r"
            let expected = shellQuote(posixChecksumAndLength($0.3 + "\n"))
            return "tessera_\($0.0)=missing; if [ \(requiredTest) \"$\($0.0)\" ]; then tessera_\($0.0)=unavailable; if [ \"$tessera_cksum\" = available ]; then if [ \"$(tessera_checksum \"$\($0.0)\")\" = \(expected) ]; then tessera_\($0.0)=match; else tessera_\($0.0)=mismatch; fi; fi; fi"
        }.joined(separator: "; ")
        let checksumChecks = staticFiles.map {
            "[ \"$tessera_\($0.0)\" = match ]"
        }.joined(separator: " && ")
        let checksumArguments = staticFiles.map { "\($0.1)=%s" }.joined(separator: " ")
        let checksumValues = staticFiles.map { "\"$tessera_\($0.0)\"" }.joined(separator: " ")
        let codexSignatures = ownedHookCommands(canonical: codexHooks).map {
            "grep -Fq \(shellQuote(jsonStringContents(hookStatusSignature($0)))) \"$codex_hooks_target\" || tessera_codex_hooks=mismatch"
        }.joined(separator: "; ")
        let claudeSignatures = ownedHookCommands(canonical: claudeSettings).map {
            "grep -Fq \(shellQuote(jsonStringContents(hookStatusSignature($0)))) \"$claude_settings_target\" || tessera_claude_hooks=mismatch"
        }.joined(separator: "; ")
        return "\(makeHostDiagnosticCommand()); \(fileBindings); codex_hooks_target=\"${CODEX_HOME:-$HOME/.codex}/hooks.json\"; claude_settings_target=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\"; tessera_zshrc=\"${ZDOTDIR:-$HOME}/.zshrc\"; rc_ok=1; case \"${SHELL##*/}\" in zsh) tessera_primary_rc=\"$tessera_zshrc\" ;; *) tessera_primary_rc=\"$HOME/.bashrc\" ;; esac; grep -qFx \(line) \"$tessera_primary_rc\" 2>/dev/null || rc_ok=0; tessera_bash_login=''; if [ \"${SHELL##*/}\" = bash ]; then for tessera_candidate in \"$HOME/.bash_profile\" \"$HOME/.bash_login\" \"$HOME/.profile\"; do if [ -e \"$tessera_candidate\" ]; then tessera_bash_login=\"$tessera_candidate\"; break; fi; done; [ -n \"$tessera_bash_login\" ] || tessera_bash_login=\"$HOME/.bash_profile\"; grep -qFx \(bashLoginLine) \"$tessera_bash_login\" 2>/dev/null || rc_ok=0; fi; if [ \"$rc_ok\" -eq 1 ]; then tessera_rc=current; else tessera_rc=missing; fi; tessera_insecure_dir=\"$(find \"$HOME/.config/tessera\" \"$HOME/.config/tessera/bin\" -prune \\( -perm -020 -o -perm -002 \\) -print -quit 2>/dev/null)\"; if [ -n \"$tessera_insecure_dir\" ]; then tessera_permissions=insecure; else tessera_permissions=secure; fi; if command -v cksum >/dev/null 2>&1; then tessera_cksum=available; else tessera_cksum=unavailable; fi; tessera_checksum() { cksum \"$1\" 2>/dev/null | awk '{print $1 \":\" $2}'; }; \(checksumProbes); if [ -r \"$codex_hooks_target\" ] && [ -r \"$claude_settings_target\" ]; then tessera_configs=present; else tessera_configs=missing; fi; tessera_codex_hooks=match; [ -r \"$codex_hooks_target\" ] || tessera_codex_hooks=mismatch; \(codexSignatures); tessera_codex_resume=match; grep -Fq 'startup|resume|clear|compact' \"$codex_hooks_target\" || tessera_codex_resume=mismatch; tessera_claude_hooks=match; [ -r \"$claude_settings_target\" ] || tessera_claude_hooks=mismatch; \(claudeSignatures); if \(missingFiles); then tessera_files=missing; else tessera_files=present; fi; printf '%s files=%s configs=%s rc=%s permissions=%s cksum=%s \(checksumArguments) codexHooks=%s codexResume=%s claudeHooks=%s\\n' \(diagnosticPrefix) \"$tessera_files\" \"$tessera_configs\" \"$tessera_rc\" \"$tessera_permissions\" \"$tessera_cksum\" \(checksumValues) \"$tessera_codex_hooks\" \"$tessera_codex_resume\" \"$tessera_claude_hooks\"; if [ \"$tessera_files\" != present ] || [ \"$tessera_configs\" != present ] || [ \"$tessera_rc\" != current ] || [ \"$tessera_permissions\" != secure ]; then printf '%s missing\\n' \(prefix); elif \(checksumChecks) && [ \"$tessera_codex_hooks\" = match ] && [ \"$tessera_codex_resume\" = match ] && [ \"$tessera_claude_hooks\" = match ]; then printf '%s current\\n' \(prefix); else version=$(grep -F \(versionNeedle) \"$hook\" 2>/dev/null | head -n 1 | sed 's/.*=//'); printf '%s outdated:%s\\n' \(prefix) \"$version\"; fi"
    }

    private static func makeAtomicConfigWriteCommand(
        variablePrefix: String,
        directoryExpression: String,
        filename: String,
        mergedContents: String,
        expectedContents: String?,
        raceMarker: String,
        errorMarker: String
    ) -> String {
        let expectedCheck: String
        if let expectedContents {
            let expectedBase64 = Data(expectedContents.utf8).base64EncodedString()
            expectedCheck = "[ -r \"$\(variablePrefix)_target\" ] && [ \"$(base64 < \"$\(variablePrefix)_target\" 2>/dev/null | tr -d '\\n')\" = \(shellQuote(expectedBase64)) ]"
        } else {
            expectedCheck = "[ ! -e \"$\(variablePrefix)_target\" ] && [ ! -L \"$\(variablePrefix)_target\" ]"
        }
        return "\(variablePrefix)_home=\"\(directoryExpression)\"; \(variablePrefix)_target=\"$\(variablePrefix)_home/\(filename)\"; if ! { \(expectedCheck); }; then printf '%s\\n' \(shellQuote(raceMarker)); exit 0; fi; mkdir -p \"$\(variablePrefix)_home\" || exit 1; \(variablePrefix)_destination=\"$\(variablePrefix)_target\"; if [ -L \"$\(variablePrefix)_target\" ]; then if command -v realpath >/dev/null 2>&1; then \(variablePrefix)_destination=\"$(realpath \"$\(variablePrefix)_target\" 2>/dev/null || true)\"; elif readlink -f \"$\(variablePrefix)_target\" >/dev/null 2>&1; then \(variablePrefix)_destination=\"$(readlink -f \"$\(variablePrefix)_target\" 2>/dev/null || true)\"; else printf '%s %s\\n' \(shellQuote(errorMarker)) symlink-resolution-unavailable; exit 0; fi; fi; if [ -z \"$\(variablePrefix)_destination\" ]; then printf '%s %s\\n' \(shellQuote(errorMarker)) invalid-destination; exit 0; fi; \(variablePrefix)_temp=\"$\(variablePrefix)_destination.tessera.$$\"; (umask 077; printf '%s\\n' \(mergedContents) > \"$\(variablePrefix)_temp\") && chmod 600 \"$\(variablePrefix)_temp\" && mv -f \"$\(variablePrefix)_temp\" \"$\(variablePrefix)_destination\""
    }

    private static func ownedHookCommands(canonical: String) -> [String] {
        guard let data = canonical.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any]
        else { return [] }
        return hooks.keys.sorted().flatMap { event -> [String] in
            guard let groups = hooks[event] as? [[String: Any]] else { return [] }
            return groups.flatMap { group in
                (group["hooks"] as? [[String: Any]] ?? []).compactMap {
                    $0["command"] as? String
                }
            }
        }
    }

    private static func jsonStringContents(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// JSON serializers may spell path separators as either `/` or `\/`.
    /// Verify the exact Tessera-owned command after its stable executable
    /// basename so equivalent provider configuration does not look outdated.
    private static func hookStatusSignature(_ command: String) -> String {
        guard let start = command.range(of: "agent-lifecycle-hook.sh")?.lowerBound else {
            return command
        }
        return String(command[start...])
    }

    static func posixChecksumAndLength(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var checksum: UInt32 = 0
        func update(_ byte: UInt8, checksum: inout UInt32) {
            checksum ^= UInt32(byte) << 24
            for _ in 0..<8 {
                checksum = (checksum & 0x8000_0000) != 0
                    ? (checksum << 1) ^ 0x04C1_1DB7
                    : checksum << 1
            }
        }
        for byte in bytes { update(byte, checksum: &checksum) }
        var length = bytes.count
        while length > 0 {
            update(UInt8(length & 0xff), checksum: &checksum)
            length >>= 8
        }
        return "\(~checksum):\(bytes.count)"
    }

    private static func makeHostDiagnosticCommand() -> String {
        let prefix = shellQuote(hostDiagnosticMarker)
        return "tessera_readiness=none; tessera_readiness_line=\"$(tail -n 1 \"$HOME/.config/tessera/codex-readiness-diagnostics.log\" 2>/dev/null || true)\"; tessera_readiness_value=\"$(printf '%s\\n' \"$tessera_readiness_line\" | sed -n 's/.* result=\\([A-Za-z-]*\\).*/\\1/p')\"; case \"$tessera_readiness_value\" in trusted|not-trusted|explicitly-bypassed|disabled-by-arguments|invalid-arguments|deferred-to-provider-hook|invalid-cwd|probe-setup-failed|app-server-start-failed|initialize-timeout|hooks-list-timeout|handler-missing|handler-mismatch|handler-disabled|handler-untrusted) tessera_readiness=\"$tessera_readiness_value\" ;; esac; tessera_lifecycle_provider=none; tessera_lifecycle_event=none; tessera_lifecycle_state=none; tessera_lifecycle_reason=none; tessera_lifecycle_phase=none; tessera_agent_pid=none; tessera_pane=none; tessera_terminal=none; tessera_tmux_state=none; tessera_terminal_emission=none; tessera_lifecycle_line=\"$(tail -n 1 \"$HOME/.config/tessera/agent-lifecycle-diagnostics.log\" 2>/dev/null || true)\"; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* provider=\\([A-Za-z]*\\).*/\\1/p')\"; case \"$tessera_value\" in claude|codex) tessera_lifecycle_provider=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* event=\\([A-Za-z]*\\).*/\\1/p')\"; case \"$tessera_value\" in SessionStart|SubagentStart|SubagentStop|UserPromptSubmit|PreToolUse|PostToolUse|PermissionRequest|Notification|Stop|StopFailure|SessionEnd|WrapperExit) tessera_lifecycle_event=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* state=\\([A-Za-z]*\\).*/\\1/p')\"; case \"$tessera_value\" in waitingForInput|working|idle|unavailable) tessera_lifecycle_state=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* reason=\\([A-Za-z-]*\\).*/\\1/p')\"; case \"$tessera_value\" in session-start|verified-trusted-empty-composer|verified-configured-empty-composer|subagent-start|subagent-stop|agent-turn|permission|idle-prompt|turn-stopped|turn-failed|session-ended) tessera_lifecycle_reason=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* phase=\\([A-Za-z]*\\).*/\\1/p')\"; case \"$tessera_value\" in received|resolved) tessera_lifecycle_phase=\"$tessera_value\" ;; esac; for tessera_field in agentPid pane terminal; do tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n \"s/.* $tessera_field=\\([A-Za-z]*\\).*/\\1/p\")\"; case \"$tessera_value\" in present|absent) case \"$tessera_field\" in agentPid) tessera_agent_pid=\"$tessera_value\" ;; pane) tessera_pane=\"$tessera_value\" ;; terminal) tessera_terminal=\"$tessera_value\" ;; esac ;; esac; done; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* tmuxState=\\([A-Za-z-]*\\).*/\\1/p')\"; case \"$tessera_value\" in written|failed|not-applicable) tessera_tmux_state=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* terminalEmission=\\([A-Za-z-]*\\).*/\\1/p')\"; case \"$tessera_value\" in written|failed|unwritable|absent|encoding-missing) tessera_terminal_emission=\"$tessera_value\" ;; esac; printf '%s readiness=%s lifecycleProvider=%s lifecycleEvent=%s lifecycleState=%s lifecycleReason=%s lifecyclePhase=%s agentPid=%s pane=%s terminal=%s tmuxState=%s terminalEmission=%s\\n' \(prefix) \"$tessera_readiness\" \"$tessera_lifecycle_provider\" \"$tessera_lifecycle_event\" \"$tessera_lifecycle_state\" \"$tessera_lifecycle_reason\" \"$tessera_lifecycle_phase\" \"$tessera_agent_pid\" \"$tessera_pane\" \"$tessera_terminal\" \"$tessera_tmux_state\" \"$tessera_terminal_emission\""
    }

    /// Checks whether one of the exact foreground shell PIDs loaded the
    /// current integration. The marker includes the process start identity
    /// from Linux `/proc` or `ps lstart`, preventing a stale file from matching
    /// a later process that reused the same PID.
    static func makeShellStatusCommand(
        processIDs: Set<Int>,
        allowInheritedEnvironment: Bool = true
    ) -> String {
        let validPIDs = processIDs.filter { $0 > 1 }.sorted()
        let prefix = shellQuote(shellStatusMarker)
        let diagnosticPrefix = shellQuote(shellDiagnosticMarker)
        guard !validPIDs.isEmpty else {
            return "printf '%s proof=none candidates=0 markers=0 identities=0\\n' \(diagnosticPrefix); printf '%s inactive\\n' \(prefix)"
        }
        let pidList = validPIDs.map(String.init).joined(separator: " ")
        let versionPrefix = shellQuote("\(integrationVersion)|")
        let environmentNeedles = [
            "TESSERA_AGENT_INTEGRATION_VERSION=\(integrationVersion)",
            "TESSERA_AGENT_SHIM_VERSION=\(integrationVersion)",
        ]
        let procEnvironmentChecks = environmentNeedles.map {
            "printf '%s\\n' \"$tessera_environment\" | grep -qFx \(shellQuote($0))"
        }.joined(separator: " && ")
        let psEnvironmentChecks = environmentNeedles.map {
            "printf '%s\\n' \"$tessera_environment\" | grep -Eq '(^|[[:space:]])\($0)([[:space:]]|$)'"
        }.joined(separator: " && ")
        let inheritedChecks = allowInheritedEnvironment
            ? "if [ -r \"/proc/$tessera_pid/environ\" ]; then tessera_environment=\"$(tr '\\000' '\\n' < \"/proc/$tessera_pid/environ\" 2>/dev/null)\"; if \(procEnvironmentChecks); then active=1; tessera_proof=inherited-environment; break; fi; fi; tessera_environment=\"$(ps eww -p \"$tessera_pid\" -o args= 2>/dev/null)\"; if \(psEnvironmentChecks); then active=1; tessera_proof=inherited-environment; break; fi; "
            : ""
        let identityCheck = "if [ -r \"$marker\" ]; then tessera_markers=$((tessera_markers + 1)); if [ \"$start\" != 'ps:' ] && [ \"$(cat \"$marker\" 2>/dev/null)\" = \(versionPrefix)\"$start|\(integrationVersion)\" ]; then tessera_identities=$((tessera_identities + 1)); active=1; tessera_proof=process-identity; break; fi; fi; "
        return "active=0; tessera_candidates=0; tessera_markers=0; tessera_identities=0; tessera_proof=none; for tessera_pid in \(pidList); do tessera_candidates=$((tessera_candidates + 1)); \(inheritedChecks)marker=\"$HOME/.config/tessera/active-shells/$tessera_pid\"; start=''; if [ -r \"/proc/$tessera_pid/stat\" ]; then start=\"proc:$(sed 's/^.*) //' \"/proc/$tessera_pid/stat\" 2>/dev/null | awk '{print $20}')\"; fi; if [ -z \"$start\" ] || [ \"$start\" = 'proc:' ]; then start=\"ps:$(ps -o lstart= -p \"$tessera_pid\" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')\"; fi; \(identityCheck)done; printf '%s proof=%s candidates=%s markers=%s identities=%s\\n' \(diagnosticPrefix) \"$tessera_proof\" \"$tessera_candidates\" \"$tessera_markers\" \"$tessera_identities\"; if [ \"$active\" -eq 1 ]; then printf '%s active\\n' \(prefix); else printf '%s inactive\\n' \(prefix); fi"
    }

    static func parseShellStatus(_ output: String) -> Bool? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "\(shellStatusMarker) "
            guard value.hasPrefix(prefix) else { continue }
            switch value.dropFirst(prefix.count) {
            case "active": return true
            case "inactive": return false
            default: return nil
            }
        }
        return nil
    }

    static func parseShellDiagnostic(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "\(shellDiagnosticMarker) "
            guard value.hasPrefix(prefix) else { continue }
            let detail = String(value.dropFirst(prefix.count))
            guard !detail.isEmpty,
                  detail.range(
                    of: #"^[A-Za-z0-9=_ -]+$"#,
                    options: .regularExpression
                  ) != nil
            else { return nil }
            return detail
        }
        return nil
    }

    static func parseHostDiagnostic(_ output: String) -> String? {
        let pattern = #"^readiness=(none|trusted|not-trusted|explicitly-bypassed|disabled-by-arguments|invalid-arguments|deferred-to-provider-hook|invalid-cwd|probe-setup-failed|app-server-start-failed|initialize-timeout|hooks-list-timeout|handler-missing|handler-mismatch|handler-disabled|handler-untrusted) lifecycleProvider=(none|claude|codex) lifecycleEvent=(none|SessionStart|SubagentStart|SubagentStop|UserPromptSubmit|PreToolUse|PostToolUse|PermissionRequest|Notification|Stop|StopFailure|SessionEnd|WrapperExit) lifecycleState=(none|waitingForInput|working|idle|unavailable) lifecycleReason=(none|session-start|verified-trusted-empty-composer|verified-configured-empty-composer|subagent-start|subagent-stop|agent-turn|permission|idle-prompt|turn-stopped|turn-failed|session-ended) lifecyclePhase=(none|received|resolved) agentPid=(none|present|absent) pane=(none|present|absent) terminal=(none|present|absent) tmuxState=(none|written|failed|not-applicable) terminalEmission=(none|written|failed|unwritable|absent|encoding-missing)$"#
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "\(hostDiagnosticMarker) "
            guard value.hasPrefix(prefix) else { continue }
            let detail = String(value.dropFirst(prefix.count))
            guard detail.range(of: pattern, options: .regularExpression) != nil else {
                return nil
            }
            return detail
        }
        return nil
    }

    static func parseInstallationDiagnostic(_ output: String) -> String? {
        let component = #"(match|mismatch|missing|unavailable)"#
        let pattern = #"^files=(present|missing) configs=(present|missing) rc=(current|missing) permissions=(secure|insecure) cksum=(available|unavailable) hook=\#(component) launcher=\#(component) codexReadiness=\#(component) claudeShim=\#(component) codexShim=\#(component) integration=\#(component) claudeLegacy=\#(component) codexHooks=(match|mismatch) codexResume=(match|mismatch) claudeHooks=(match|mismatch)$"#
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "\(installationDiagnosticMarker) "
            guard value.hasPrefix(prefix) else { continue }
            let detail = String(value.dropFirst(prefix.count))
            guard detail.range(of: pattern, options: .regularExpression) != nil else {
                return nil
            }
            return detail
        }
        return nil
    }

    static func parseStatus(_ output: String) -> AgentLifecycleHostInstallation? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "\(statusMarker) "
            guard value.hasPrefix(prefix) else { continue }
            let status = String(value.dropFirst(prefix.count))
            if status == "current" { return .current }
            if status == "missing" { return .missing }
            if status.hasPrefix("outdated:") {
                return .outdated(version: Int(status.dropFirst("outdated:".count)))
            }
        }
        return nil
    }

    private static func shellQuote(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
