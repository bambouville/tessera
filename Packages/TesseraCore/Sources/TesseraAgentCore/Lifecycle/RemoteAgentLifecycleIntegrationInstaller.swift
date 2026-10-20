import Foundation

public enum AgentLifecycleIntegrationInstallError: LocalizedError {
    case verificationFailed(String)
    /// The host holds a newer app's integration. Retrying cannot help; the
    /// caller re-reads the host, which reports current or requires an update.
    case newerInstalled

    public var errorDescription: String? {
        switch self {
        case .verificationFailed:
            // Remote output is untrusted and can contain terminal/transcript
            // content. Diagnostics deliberately expose only a local code.
            #if os(Android)
            return "Could not verify Agent Center integration."
            #else
            return String(localized: "Could not verify Agent Center integration.", comment: "Agent Center hook verification failed")
            #endif
        case .newerInstalled:
            #if os(Android)
            return "A newer Tessera manages this host's Agent Center integration."
            #else
            return String(
                localized: "A newer Tessera manages this host's Agent Center integration.",
                comment: "Agent Center install refused because a newer app version installed the host integration"
            )
            #endif
        }
    }
}

public enum AgentLifecycleHostInstallation: Equatable, Sendable {
    case missing
    /// This app's installation, or a newer one that still admits this app.
    case current
    /// Older than this app, or this app's version with damaged content.
    case outdated(version: Int?)
    /// A newer Tessera installed an integration this app is too old to
    /// operate. Nothing may be written: the fix is updating the app.
    case requiresAppUpdate(version: Int?)
}

/// Why an install run that reached the host still did not install.
///
/// A bounded vocabulary, safe to render: it names which half of the contract
/// the host broke and never quotes the host back.
public enum AgentLifecycleInstallFailureReason: String, Equatable, Sendable {
    /// The program never reported a completed installation.
    case notVerified
    /// The program completed, but the status probe still did not read current.
    case notCurrent
    /// The host already runs a newer integration; the program wrote nothing.
    case newerInstalled
}

/// What one run of the install program means.
///
/// Only `configurationRace` may be retried: a provider settings file moved
/// underneath the compare-and-swap, so re-reading and re-merging can still
/// succeed. Every other answer is terminal and must be reported as itself
/// rather than as a race that never happened.
public enum AgentLifecycleInstallOutcome: Equatable, Sendable {
    case completed
    case configurationRace
    /// `detail` is untrusted remote output kept for local diagnostics only and
    /// must never be shown; `reason` is the bounded fact a platform may render.
    case failed(reason: AgentLifecycleInstallFailureReason, detail: String)
}

/// Opt-in remote integration for authoritative Claude Code, Codex, and Kimi states.
/// It installs a transport-neutral lifecycle hook plus optional interactive
/// provider shims. Existing aliases and functions are never rewritten. Tessera
/// merges only its handler groups into both providers' documented user config
/// layers with compare-and-swap protection, preserving unrelated settings,
/// hooks, profiles, and symlink-managed files.
/// Portable, versioned source of truth for the Agent Center remote integration.
///
/// Platform adapters execute the generated commands over their own authenticated
/// terminal transport. They must never recreate the installation shell script
/// or provider-config merge policy locally.
public enum RemoteAgentLifecycleIntegrationInstaller {
    /// Version of the installed bytes. Every change to any installed script,
    /// provider hook block, or bundled native host must bump it: apps compare
    /// it to decide who may write, so two different installations sharing one
    /// number would overwrite each other forever. `integrationReleases` and
    /// its tests (AgentIntegrationVersioningTests, and test_artifacts.py for a
    /// rebuilt native host) make forgetting the bump a test failure.
    ///
    /// A host is shared by every Tessera build that reaches it. An app never
    /// replaces an installation newer than its own: it uses one whose
    /// `integrationCompatibleFrom` admits it and otherwise asks for an app
    /// update, so an older and a newer device cannot flip the host back and
    /// forth.
    public static let integrationVersion = 25
    /// Oldest app `integrationVersion` that can operate against an installation
    /// of this version (its shell markers, shims, hook payloads, and native
    /// host). Raise it only for a deliberate break; older apps then show an
    /// app-update notice instead of downgrading the host.
    public static let integrationCompatibleFrom = 10
    /// Oldest `integrationVersion` whose loaded shell this installation still
    /// serves. Sourcing agent-lifecycle.sh leaves only environment, PATH and
    /// markers in a running shell; the shims and hooks it reaches are files
    /// every install replaces in place. A shell loaded by an older release
    /// therefore stays active until the script itself changes, instead of
    /// every open shell reporting inactive after each release. When
    /// `shellIntegration(version:)` changes, raise this to `integrationVersion`
    /// (AgentIntegrationVersioningTests pins the script to this floor).
    public static let shellIntegrationCompatibleFrom = 10
    /// Wire schema of the lifecycle event the hook emits. Independent of
    /// `integrationVersion`, so script-only updates stay readable by apps that
    /// accept this schema.
    public static let lifecycleEventVersion = AgentLifecycleEnvelope.currentVersion
    /// What each released `integrationVersion` installs. Entries are
    /// append-only: editing one instead of adding a new version reintroduces
    /// the overwrite loop this table exists to prevent.
    static let integrationReleases: [Int: IntegrationRelease] = [
        10: .init(fingerprint: "2631599b20df3f5d28b61d88d2c831de953dfdd4f523af3b7ae31f37ab028df9", eventVersion: 9, nativeRevision: "302a2b31753c5c3ec89da0da4d62ef9dcdeab51bd81c1eb94a4a4ef6024b1cbf"),
        11: .init(fingerprint: "b22e20526cfa378b824006136ad4377c3d889e3ab0ff3876fc1bdc3e460ebc8b", eventVersion: 9, nativeRevision: "58005872a9b1c133a4949f04a798fcab25d89d70e86895cf7edd47df48a5952a"),
        12: .init(fingerprint: "38a255485d449544e6ef2de2462e3b063954bd29aa6a7c5d2a65ebf7a237c680", eventVersion: 9, nativeRevision: "58005872a9b1c133a4949f04a798fcab25d89d70e86895cf7edd47df48a5952a"),
        13: .init(fingerprint: "a6436b113c4fcf310ecb2215d1bc5c8ddc4e2e29e90da241c4bf545e09cdee76", eventVersion: 9, nativeRevision: "58005872a9b1c133a4949f04a798fcab25d89d70e86895cf7edd47df48a5952a"),
        14: .init(fingerprint: "db733f568b27dbfade292153848877699e38018b584ad2ad8388903138052c09", eventVersion: 9, nativeRevision: "937529dd5c5ffba767ef916c3362dbba84eeaafce1683e885665faab6beb8fb8"),
        15: .init(fingerprint: "bf609f57e69d382eaa11a0176855ae6531a8b0bd1d39b53e9c719ee35715aa35", eventVersion: 9, nativeRevision: "c99a6270af17a3be6338e0e851ec4d7fa40c60aa70436a653399c3fde88b8bc2"),
        16: .init(fingerprint: "3ba4a4e7584be97d9ca7879e395f5d535e936e6235172461a223852d7ecd011b", eventVersion: 9, nativeRevision: "a3828f6d43a0f645c1e9f04797929c5d26307b5b11908c06364134c28a422657"),
        17: .init(fingerprint: "e5f82a7c3339f43d6ad8c32bd67f8ba76fd3ae693384389ee004424cff7e0991", eventVersion: 9, nativeRevision: "fa653ab0af2d5680f751926813066ab9dc3ed580ae15ebdfb23827d9be740999"),
        18: .init(fingerprint: "984d8be22be78359b2436918c48ff9c171f901a596b57ed217a18f7127f17948", eventVersion: 9, nativeRevision: "b622fb0b86a2db3ef4e6f11bc04b0717cbf3803cd2d5cebac35aff5a9de3fff8"),
        19: .init(fingerprint: "15d9f1a966284e6087f417668a89f32ab6e2ae31549196481dc1a69f3c883507", eventVersion: 9, nativeRevision: "14896c4b73688844bb27c048716907223db04da0a92f5dfdf69ca2c463447838"),
        20: .init(fingerprint: "930b438fc41ccf1d130d469c7094b54273100922988e334f11fd0d796ab5e813", eventVersion: 9, nativeRevision: "5fb999fcca4237b8c45472437ae33f91c5dfab252c058253e68bf59e2ebf18c0"),
        21: .init(fingerprint: "e3000c3f6a44da5389b4064817385b1d6f0a9d9af5ef5f4708ed4dd41251d2ba", eventVersion: 9, nativeRevision: "5fb999fcca4237b8c45472437ae33f91c5dfab252c058253e68bf59e2ebf18c0"),
        22: .init(fingerprint: "e2b7f4cee488dda46264c8c7b37b8cc40f77c059ad4e1ba7d4c3f85b92666333", eventVersion: 9, nativeRevision: "048d13911700bae2ba595af7283bb1e6a7fa1d47bc05c014c6e4ed9ae3cfe302"),
        23: .init(fingerprint: "0fb591ba7e7541bbe2b6f8fa782d2409d647c54e3fcdfce331aa59be0bbcb234", eventVersion: 9, nativeRevision: "048d13911700bae2ba595af7283bb1e6a7fa1d47bc05c014c6e4ed9ae3cfe302"),
        24: .init(fingerprint: "f0e44b42be0a3a474af8a6990ebe55e3ca81f53b345295305fa0c53c35e162d3", eventVersion: 9, nativeRevision: "048d13911700bae2ba595af7283bb1e6a7fa1d47bc05c014c6e4ed9ae3cfe302"),
        25: .init(fingerprint: "25fc92be0bfa76135e5299d4a9f2684ffaa1f89efda9557ca8358bb1e56eb31e", eventVersion: 9, nativeRevision: "41665a520740272537ce0c30023728e781cd90207ddfb938897f5dd0ab2e094a"),
    ]

    struct IntegrationRelease: Equatable {
        /// SHA-256 of the installed content (`integrationContentFingerprint`
        /// in AgentIntegrationVersioningTests).
        let fingerprint: String
        /// The hook's event schema. An app older than it cannot read its
        /// events, so the compatibility floor must move up with it.
        let eventVersion: Int
        /// `AgentHostBuildRevision.sourceSHA256` of the bundled native host,
        /// so the native build can check its version was bumped without Swift.
        let nativeRevision: String
    }

    public static let newerInstallationMarker = "TESSERA_AGENT_INTEGRATION_NEWER_INSTALLED"
    public static let verificationMarker = "TESSERA_AGENT_INTEGRATION_INSTALLED"
    public static let statusMarker = "TESSERA_AGENT_INTEGRATION_STATUS"
    public static let installationDiagnosticMarker = "TESSERA_AGENT_INSTALL_DIAG"
    public static let shellStatusMarker = "TESSERA_AGENT_SHELL_STATUS"
    public static let shellDiagnosticMarker = "TESSERA_AGENT_SHELL_DIAG"
    public static let hostDiagnosticMarker = "TESSERA_AGENT_HOST_DIAG"
    public static let codexHooksSnapshotMarker = "TESSERA_AGENT_CODEX_HOOKS"
    public static let codexHooksRaceMarker = "TESSERA_AGENT_CODEX_HOOKS_CHANGED"
    public static let claudeSettingsSnapshotMarker = "TESSERA_AGENT_CLAUDE_SETTINGS"
    public static let claudeSettingsRaceMarker = "TESSERA_AGENT_CLAUDE_SETTINGS_CHANGED"
    public static let kimiConfigSnapshotMarker = "TESSERA_AGENT_KIMI_CONFIG"
    public static let kimiConfigRaceMarker = "TESSERA_AGENT_KIMI_CONFIG_CHANGED"
    public static let kimiHooksStartMarker = "# TESSERA-AGENT-CENTER-KIMI-HOOKS-BEGIN"
    public static let kimiHooksEndMarker = "# TESSERA-AGENT-CENTER-KIMI-HOOKS-END"
    public static let rcMarker = "TESSERA-AGENT-LIFECYCLE"
    public static let rcMarkerLine = #"[ -r "$HOME/.config/tessera/agent-lifecycle.sh" ] && . "$HOME/.config/tessera/agent-lifecycle.sh" # TESSERA-AGENT-LIFECYCLE"#
    public static let bashLoginMarkerLine = #"[ -n "${BASH_VERSION:-}" ] && [ -r "$HOME/.config/tessera/agent-lifecycle.sh" ] && . "$HOME/.config/tessera/agent-lifecycle.sh" # TESSERA-AGENT-LIFECYCLE"#
    public static let applyToCurrentShellCommand = #". "$HOME/.config/tessera/agent-lifecycle.sh""#
    public static var persistAndApplyToCurrentShellCommand: String {
        let rcLine = shellQuote(rcMarkerLine)
        let bashLoginLine = shellQuote(bashLoginMarkerLine)
        return ##"( _tessera_agent_rc_ok=1; _tessera_agent_append() { _tessera_agent_file="$1"; _tessera_agent_line="$2"; mkdir -p "${_tessera_agent_file%/*}" 2>/dev/null || return 1; touch "$_tessera_agent_file" 2>/dev/null || return 1; grep -qFx "$_tessera_agent_line" "$_tessera_agent_file" 2>/dev/null && return 0; if [ -s "$_tessera_agent_file" ] && [ "$(tail -c 1 "$_tessera_agent_file" 2>/dev/null | wc -l | tr -d '[:space:]')" = 0 ]; then printf '\n' >> "$_tessera_agent_file" || return 1; fi; printf '%s\n' "$_tessera_agent_line" >> "$_tessera_agent_file"; }; if [ -n "${ZSH_VERSION:-}" ]; then _tessera_agent_append "${ZDOTDIR:-$HOME}/.zshrc" \##(rcLine) || _tessera_agent_rc_ok=0; elif [ -n "${BASH_VERSION:-}" ]; then _tessera_agent_append "$HOME/.bashrc" \##(rcLine) || _tessera_agent_rc_ok=0; _tessera_agent_login=''; for _tessera_agent_candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do if [ -e "$_tessera_agent_candidate" ]; then _tessera_agent_login="$_tessera_agent_candidate"; break; fi; done; [ -n "$_tessera_agent_login" ] || _tessera_agent_login="$HOME/.bash_profile"; _tessera_agent_append "$_tessera_agent_login" \##(bashLoginLine) || _tessera_agent_rc_ok=0; else _tessera_agent_rc_ok=0; fi; [ "$_tessera_agent_rc_ok" -eq 1 ] ) && . "$HOME/.config/tessera/agent-lifecycle.sh""##
    }

    public static let hookScript = #"""
#!/bin/sh

# Tessera Agent Center lifecycle bridge — remove with ~/.config/tessera/agent-uninstall.sh.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=\#(integrationVersion)
TESSERA_AGENT_INTEGRATION_COMPATIBLE_FROM=\#(integrationCompatibleFrom)
TESSERA_AGENT_EVENT_VERSION=\#(lifecycleEventVersion)
# Native reader bundle: \#(AgentHostBuildRevision.sourceSHA256)

provider="${1:-}"
event="${2:-}"
state="${3:-}"
reason="${4:-}"

case "$provider" in claude|codex|kimi) ;; *) exit 0 ;; esac
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
agent_type=""
root_agent_id=""
transcript_ref=""
question_marker=""
if command -v python3 >/dev/null 2>&1; then
    # Let Python consume the hook pipe directly. Provider payloads can contain
    # large prompts/tool inputs; copying those bytes through a shell variable
    # first made every lifecycle event needlessly expensive. A resumed Claude
    # session can live in another project: when its transcript path is absent
    # or gone, recover only one exact, user-owned transcript within the
    # configured projects root, in this same process.
    metadata="$(TESSERA_AGENT_PROVIDER="$provider" python3 -c 'import json,os,sys,time
try: data=json.load(sys.stdin)
except Exception: data={}
print(time.time_ns())
print(str(data.get("session_id", "")).replace("\n", ""))
print(str(data.get("turn_id", "")).replace("\n", ""))
print(str(data.get("notification_type", "")).replace("\n", ""))
print(str(data.get("permission_mode", "")).replace("\n", ""))
print(str(data.get("agent_id", data.get("agent_name", ""))).replace("\n", ""))
print(str(data.get("agent_type", data.get("agent_name", ""))).replace("\n", ""))
print(str(data.get("root_agent_id", "")).replace("\n", ""))
path=data.get("transcript_path")
path=path.replace("\n", "") if isinstance(path,str) else ""
session_id=str(data.get("session_id", "")).replace("\n", "")
if os.environ.get("TESSERA_AGENT_PROVIDER") == "claude" and session_id:
 try:
  if not path or not os.path.isfile(path):
   import glob,stat
   root=os.path.realpath(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),"projects"))
   matches=glob.glob(os.path.join(root,"*",session_id+".jsonl"))
   if len(matches) == 1:
    candidate=matches[0]; info=os.lstat(candidate); real=os.path.realpath(candidate)
    if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and os.path.commonpath([real,root]) == root: path=real
 except Exception: pass
if path:
 import base64
 print(base64.urlsafe_b64encode(path.encode()).decode().rstrip("="))
else: print("")
tool=data.get("tool_name")
tool_input=data.get("tool_input") if isinstance(data.get("tool_input"),dict) else {}
if tool=="request_user_input_async" or tool=="AskUserQuestion" and tool_input.get("background") is True: print("deferred-question")
elif tool in ("AskUserQuestion","request_user_input"): print("question")
else: print("")' 2>/dev/null || true)"
    timestamp_ns="$(printf '%s\n' "$metadata" | sed -n '1p')"
    session_id="$(printf '%s\n' "$metadata" | sed -n '2p')"
    turn_id="$(printf '%s\n' "$metadata" | sed -n '3p')"
    notification_type="$(printf '%s\n' "$metadata" | sed -n '4p')"
    permission_mode="$(printf '%s\n' "$metadata" | sed -n '5p')"
    agent_id="$(printf '%s\n' "$metadata" | sed -n '6p')"
    agent_type="$(printf '%s\n' "$metadata" | sed -n '7p')"
    root_agent_id="$(printf '%s\n' "$metadata" | sed -n '8p')"
    transcript_ref="$(printf '%s\n' "$metadata" | sed -n '9p')"
    question_marker="$(printf '%s\n' "$metadata" | sed -n '10p')"
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
[ -n "$agent_type" ] || agent_type="$(printf '%s' "$input" | sed -n 's/.*"agent_type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
[ -n "$root_agent_id" ] || root_agent_id="$(printf '%s' "$input" | sed -n 's/.*"root_agent_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
if [ -z "$question_marker" ] && [ -n "$input" ]; then
    case "$(printf '%s' "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)" in
        request_user_input_async) question_marker=deferred-question ;;
        request_user_input) question_marker=question ;;
        AskUserQuestion)
            if printf '%s' "$input" | grep -q '"background"[[:space:]]*:[[:space:]]*true'; then
                question_marker=deferred-question
            else
                question_marker=question
            fi
            ;;
    esac
fi
# A question tool shows its prompt in the terminal without a permission
# event (Codex request_user_input and its async variant, Kimi
# AskUserQuestion). Its boundaries carry this content-free marker as the
# reason, so the app captures the terminal for the prompt.
case "$event:$question_marker" in
    PreToolUse:question|PreToolUse:deferred-question|PostToolUse:question|PostToolUse:deferred-question)
        reason="$question_marker"
        ;;
esac
session_id="$(printf '%s' "$session_id" | tr -cd 'A-Za-z0-9._:-')"
turn_id="$(printf '%s' "$turn_id" | tr -cd 'A-Za-z0-9._:-')"
notification_type="$(printf '%s' "$notification_type" | tr -cd 'A-Za-z0-9._:-')"
permission_mode="$(printf '%s' "$permission_mode" | tr -cd 'A-Za-z0-9._:-')"
agent_id="$(printf '%s' "$agent_id" | tr -cd 'A-Za-z0-9._:-')"
agent_type="$(printf '%s' "$agent_type" | tr -cd 'A-Za-z0-9._:-')"
root_agent_id="$(printf '%s' "$root_agent_id" | tr -cd 'A-Za-z0-9._:-')"
transcript_ref="$(printf '%s' "$transcript_ref" | tr -cd 'A-Za-z0-9_-')"
session_id="$(printf '%.256s' "$session_id")"
turn_id="$(printf '%.256s' "$turn_id")"
notification_type="$(printf '%.64s' "$notification_type")"
permission_mode="$(printf '%.64s' "$permission_mode")"
agent_id="$(printf '%.256s' "$agent_id")"
agent_type="$(printf '%.64s' "$agent_type")"
root_agent_id="$(printf '%.256s' "$root_agent_id")"
transcript_ref="$(printf '%.4096s' "$transcript_ref")"
[ -n "$timestamp_ns" ] || timestamp_ns="$(date +%s)000000000"

# Kimi hooks identify the session but do not publish a transcript path. Resolve
# the exact main-agent wire only through Kimi Code's bounded session index.
if [ "$provider" = kimi ] && [ -n "$session_id" ] && [ -z "$transcript_ref" ] && command -v python3 >/dev/null 2>&1; then
    transcript_ref="$(TESSERA_KIMI_SESSION_ID="$session_id" TESSERA_KIMI_EVENT="$event" python3 -c 'import base64,json,os,re,stat,time
root=os.path.realpath(os.environ.get("KIMI_CODE_HOME") or os.path.expanduser("~/.kimi-code"))
index=os.path.join(root,"session_index.jsonl")
session_id=os.environ.get("TESSERA_KIMI_SESSION_ID","")
def resolve():
 try:
  st=os.lstat(index)
  if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > 1048576: raise ValueError()
  with open(index,"rb") as source: lines=source.read(1048577).splitlines()
  if sum(len(line)+1 for line in lines) > 1048576: raise ValueError()
  for line in reversed(lines[-4096:]):
   if len(line)>8192: continue
   record=json.loads(line)
   if record.get("sessionId") != session_id: continue
   session_dir=os.path.realpath(os.path.abspath(os.path.expanduser(record.get("sessionDir", ""))))
   sessions_root=os.path.realpath(os.path.join(root,"sessions"))
   if os.path.commonpath([session_dir,sessions_root]) != sessions_root or os.path.basename(session_dir) != session_id: raise ValueError()
   wire=os.path.join(session_dir,"agents","main","wire.jsonl")
   wire_real=os.path.realpath(wire)
   if os.path.commonpath([wire_real,session_dir]) != session_dir: raise ValueError()
   return base64.urlsafe_b64encode(wire_real.encode()).decode().rstrip("=")
 except Exception: pass
 return ""
for attempt in range(5 if os.environ.get("TESSERA_KIMI_EVENT") == "SessionStart" else 1):
 if attempt: time.sleep(0.2)
 locator=resolve()
 if locator: print(locator); break' 2>/dev/null || true)"
    transcript_ref="$(printf '%s' "$transcript_ref" | tr -cd 'A-Za-z0-9_-')"
    transcript_ref="$(printf '%.4096s' "$transcript_ref")"
fi

# Minimal hosts have only a seconds clock. Use this hook process's PID for
# the otherwise unknown fraction so two invocations in one second still
# have distinct retained-event identities. Clients never use it for ordering.
case "$timestamp_ns" in ''|*[!0-9]*) timestamp_ns="$(date +%s)$(printf '%09d' "$$")" ;; esac

agent_pid=""
# A process-owned observer is reparented after its launching native hook ends.
# Independently revalidate its exact provider lifetime and open root before
# accepting its PID; the delivery path also compares the native claim epoch.
if [ "${TESSERA_AGENT_OBSERVER:-}" = 1 ]; then
    agent_pid="$("${0%/*}/agent-codex-recover.sh" --verify-observation "${TESSERA_AGENT_OBSERVED_PROVIDER_PID:-}" "${TESSERA_AGENT_OBSERVED_PROCESS_START:-}" "$session_id" 2>/dev/null || true)"
    case "$agent_pid" in ''|*[!0-9]*) exit 0 ;; esac
    [ "$provider:$event" = codex:SessionStart ] || exit 0
fi
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
# The Tessera wrapper reporting its provider's exit is this hook's direct
# parent. Its arguments name the provider, so it must never be mistaken for a
# live provider: the search for one starts above it.
wrapper_pid=""
if [ "$event" = WrapperExit ] && [ "$PPID" -gt 1 ] 2>/dev/null; then
    wrapper_pid="$PPID"
fi
# Bind provider-owned hook events to the matching live provider ancestor.
if [ -z "$agent_pid" ] && command -v ps >/dev/null 2>&1; then
    if [ -n "$wrapper_pid" ]; then
        ancestor_pid="$(ps -o ppid= -p "$wrapper_pid" 2>/dev/null | tr -d '[:space:]')"
    else
        ancestor_pid="$PPID"
    fi
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
            kimi)
                case "$ancestor_comm" in *kimi*|*Kimi*) matches_provider=1 ;; esac
                case "$ancestor_args" in */kimi*) matches_provider=1 ;; esac
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
# A provider invoked as a tool inside another provider cannot end that outer
# conversation when its CLI helper exits. The real interactive provider has
# already exited at this point, so a matching live ancestor above the wrapper
# is an outer one. Otherwise the wrapper is the last live member of the pane's
# foreground job and carries the pane-bound PID for this final event.
if [ "$event" = WrapperExit ]; then
    if [ -n "$agent_pid" ]; then
        tessera_agent_diagnostic ignored source=nested-wrapper
        exit 0
    fi
    agent_pid="$wrapper_pid"
fi
agent_pid_json="${agent_pid:-null}"

# /resume and /clear can omit transcript_path. Accept only the exact durable
# root session held open by this provider process; never guess from recency.
# Internal helper IDs intentionally fail this same shared proof.
if [ "$provider" = codex ] && [ -z "$transcript_ref" ] && [ -n "$session_id" ]; then
    if [ -n "$agent_pid" ]; then
        transcript_ref="$("${0%/*}/agent-codex-recover.sh" --resolve-root "$agent_pid" "$session_id" 2>/dev/null || true)"
        transcript_ref="$(printf '%.4096s' "$transcript_ref" | tr -cd 'A-Za-z0-9_-')"
    fi
    if [ -z "$transcript_ref" ]; then
        tessera_agent_diagnostic ignored source=non-durable
        exit 0
    fi
fi

# Track dedicated child lifecycle events. Generic hooks now carry agent_id
# on both providers; only explicitly attributed child callbacks are neutral.
# A concurrently running child must never suppress the root's completion.
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
                # Current Codex hooks identify child callbacks explicitly.
                # A marker only says a child exists; it does not make a root
                # PostToolUse or Stop a child event. Suppressing those strands
                # an auto-approved PermissionRequest in the retained state.
                if [ "$provider" = "codex" ] && [ -n "$agent_id" ]; then
                    exit 0
                fi
                ;;
        esac
        ;;
esac

payload="$(printf '{"version":%s,"provider":"%s","event":"%s","state":"%s","reason":"%s","timestampNs":"%s","sessionId":"%s","turnId":"%s","notificationType":"%s","permissionMode":"%s","agentPid":%s,"transcriptRef":"%s","agentId":"%s","agentType":"%s","rootAgentId":"%s"}' "$TESSERA_AGENT_EVENT_VERSION" "$provider" "$event" "$state" "$reason" "$timestamp_ns" "$session_id" "$turn_id" "$notification_type" "$permission_mode" "$agent_pid_json" "$transcript_ref" "$agent_id" "$agent_type" "$root_agent_id")"

# A nested background provider shares its parent's pane. Preserve a different
# live foreground holder, but publish as usual when either proof is unknown.
tessera_agent_foreground_status() {
    foreground_stat_file="${TESSERA_AGENT_PROC_ROOT:-/proc}/$1/stat"
    if [ -e "$foreground_stat_file" ]; then
        foreground_stat=""
        if [ ! -r "$foreground_stat_file" ] || ! IFS= read -r foreground_stat < "$foreground_stat_file"; then
            printf unknown; return
        fi
        # Linux comm can contain spaces and parentheses: strip the last ') '.
        foreground_fields="${foreground_stat##*) }"
        set -- $foreground_fields
        if [ "$#" -lt 6 ]; then printf unknown; return; fi
        foreground_pgrp="$3"; foreground_tpgid="$6"
        case "$foreground_pgrp:$foreground_tpgid" in
            *[!0-9:-]*|:*|*:) printf unknown; return ;;
        esac
        if [ "$foreground_tpgid" -gt 0 ] 2>/dev/null && [ "$foreground_tpgid" -eq "$foreground_pgrp" ] 2>/dev/null; then
            printf foreground
        else
            printf background
        fi
    else
        foreground_stat="$(ps -o stat= -p "$1" 2>/dev/null)" || { printf unknown; return; }
        case "$foreground_stat" in
            *+*) printf foreground ;;
            *[![:space:]]*) printf background ;;
            *) printf unknown ;;
        esac
    fi
}
pane="${TMUX_PANE:-}"

# Codex does not emit a native boundary hook for every /clear or /resume.
# Serialize its accepted claim and transport publication with the process-
# owned observer. An observer can publish only if no newer native event has
# replaced the exact claim it inspected. Pane writers always take the pane
# lock before the Codex PID lock, through both retained and OSC publication.
if { [ -n "$pane" ] || { [ "$provider" = codex ] && [ -n "$agent_pid" ]; }; } && command -v python3 >/dev/null 2>&1; then
    delivery_status="$(TESSERA_AGENT_DELIVERY_PARENT="$PPID" TESSERA_AGENT_DELIVERY_PAYLOAD="$payload" python3 -c 'import base64,fcntl,hashlib,json,os,stat,subprocess,sys,time
def command(arguments):
 try:
  result=subprocess.run(arguments,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=1)
  return result.stdout if result.returncode == 0 else None
 except Exception: return None
def safe_open(path, create=False):
 flags=os.O_RDWR if create else os.O_RDONLY
 flags |= getattr(os,"O_NOFOLLOW",0) | getattr(os,"O_CLOEXEC",0)
 if create: flags |= os.O_CREAT
 fd=os.open(path,flags,0o600)
 info=os.fstat(fd)
 if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
  os.close(fd); raise ValueError()
 if create: os.fchmod(fd,0o600)
 return fd
def exclusive(path):
 fd=safe_open(path,True)
 deadline=time.monotonic()+2
 while True:
  try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB); return fd
  except BlockingIOError:
   if time.monotonic() >= deadline: os.close(fd); return None
   time.sleep(0.01)
def foreground(pid):
 if not isinstance(pid,int) or isinstance(pid,bool) or pid <= 1: return None
 path=os.path.join(os.environ.get("TESSERA_AGENT_PROC_ROOT","/proc"),str(pid),"stat")
 if os.path.exists(path):
  try:
   with open(path) as source: raw=source.read(4096)
   end=raw.rfind(")"); fields=raw[end+2:].split()
   if end < 0 or len(fields) < 6: return None
   return int(fields[5]) > 0 and int(fields[2]) == int(fields[5])
  except Exception: return None
 raw=command(["ps","-o","stat=","-p",str(pid)])
 if raw is None or not raw.strip(): return None
 return b"+" in raw
def timestamp(value):
 try: return int(value.get("timestampNs",0))
 except Exception: return 0
def codex_child(frame):
 return frame.get("provider") == "codex" and bool(frame.get("agentId"))
def obsolete_end(value,held):
 if not isinstance(held,dict) or value.get("event") != "SessionEnd" or codex_child(value) or codex_child(held): return False
 if held.get("provider") != value.get("provider") or held.get("event") in ("SessionEnd","WrapperExit"): return False
 if value.get("agentPid") is None or held.get("agentPid") != value.get("agentPid"): return False
 return bool(value.get("sessionId")) and bool(held.get("sessionId")) and value.get("sessionId") != held.get("sessionId")
locks=[]
try:
 payload=os.environ["TESSERA_AGENT_DELIVERY_PAYLOAD"]
 value=json.loads(payload); pid=value["agentPid"]
 directory=os.path.join(os.path.expanduser("~"),".config","tessera","agent-runtime-state")
 os.makedirs(directory,mode=0o700,exist_ok=True)
 info=os.lstat(directory)
 if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid(): raise ValueError()
 pane=os.environ.get("TMUX_PANE","")
 pane_lock="not-applicable"
 if pane:
  try:
   server=command(["tmux","display-message","-p","-t",pane,"#{pid}:#{socket_path}"])
   if server is None or not server.strip(): raise ValueError()
   key=hashlib.sha256(server.strip()+b":"+pane.encode()).hexdigest()
   lock=exclusive(os.path.join(directory,"pane-"+key+".delivery.lock"))
   pane_lock="held" if lock is not None else "timeout"
   if lock is not None: locks.append(lock)
  except Exception: pane_lock="unavailable"
 if value["provider"] == "codex" and pid is not None:
  lock=exclusive(os.path.join(directory,str(pid)+".delivery.lock"))
  if lock is None: raise ValueError()
  locks.append(lock)
  path=os.path.join(directory,str(pid)+".json")
  previous=None
  try:
   with os.fdopen(safe_open(path),"rb") as source:
    encoded=source.read(16385)
   if len(encoded)>16384: raise ValueError()
   previous=json.loads(encoded)
  except FileNotFoundError: pass
  expected=os.environ.get("TESSERA_AGENT_OBSERVED_TIMESTAMP_NS")
  if expected is not None:
   if expected == "":
    if previous is not None: sys.exit(3)
   elif previous is None or str(previous.get("timestampNs")) != expected: sys.exit(3)
  newer_claim=timestamp(value) < timestamp(previous) <= time.time_ns()+600000000000
  if expected is not None and newer_claim: sys.exit(3)
  if not newer_claim and not obsolete_end(value,previous):
   import tempfile
   temporary=None
   try:
    with tempfile.NamedTemporaryFile(mode="w",encoding="utf-8",dir=directory,prefix=str(pid)+".",delete=False) as destination:
     temporary=destination.name; destination.write(payload)
    os.replace(temporary,path); temporary=None
   finally:
    if temporary is not None: os.unlink(temporary)
 retained={}
 if pane:
  try:
   retained=json.loads(command(["tmux","show-options","-pqv","-t",pane,"@tessera_agent_state"]) or b"{}")
   if not isinstance(retained,dict): retained={}
  except Exception: pass
 holder=retained.get("agentPid")
 defer_pane=foreground(pid) is False and holder != pid and foreground(holder) is True if pane else False
 stale=timestamp(value) < timestamp(retained) <= time.time_ns()+600000000000 or obsolete_end(value,retained)
 terminal=""; tmux_state="not-applicable"
 if pane:
  raw=command(["tmux","display-message","-p","-t",pane,"#{pane_tty}"])
  if raw is not None: terminal=raw.decode("utf-8","strict").strip()
  if defer_pane: tmux_state="deferred"
  elif stale: tmux_state="stale"
  else: tmux_state="written" if command(["tmux","set-option","-p","-t",pane,"@tessera_agent_state",payload]) is not None else "failed"
 else:
  terminal=os.environ.get("TESSERA_AGENT_TTY","")
  if not terminal:
   terminal="/dev/tty"
 if not terminal and value["provider"] != "codex":
  ancestor=os.environ.get("TESSERA_AGENT_DELIVERY_PARENT","")
  for _ in range(8):
   if not ancestor.isdigit() or int(ancestor) <= 1: break
   raw=command(["ps","-o","tty=","-p",ancestor])
   tty=raw.decode().strip() if raw is not None else ""
   if tty and tty not in {"?","??"}: terminal="/dev/"+tty; break
   raw=command(["ps","-o","ppid=","-p",ancestor])
   ancestor=raw.decode().strip() if raw is not None else ""
 emission="absent"
 if defer_pane: emission="deferred"
 elif terminal:
  try:
   fd=os.open(terminal,os.O_WRONLY|os.O_NOCTTY|os.O_NONBLOCK)
   try:
    if not os.isatty(fd): raise ValueError()
    wire=b"\x1b]1337;TesseraAgentState="+base64.b64encode(payload.encode("utf-8"))+b"\x07"
    emission="written" if os.write(fd,wire)==len(wire) else "failed"
   finally: os.close(fd)
  except Exception: emission="unwritable"
 print(tmux_state,emission,"present" if pane else "absent","present" if terminal else "absent",pane_lock)
 for lock in reversed(locks): os.close(lock)
 locks=[]
 pruned=0
 for name in os.listdir(directory):
  head=name.split(".",1)[0]
  if pruned>=64 or not head.isdigit() or int(head)==pid: continue
  try: os.kill(int(head),0)
  except ProcessLookupError:
   try:
    os.unlink(os.path.join(directory,name)); pruned+=1
   except Exception: pass
  except Exception: pass
except Exception:
 sys.exit(3)
finally:
 for lock in reversed(locks): os.close(lock)' 2>/dev/null)" || exit 0
    set -- $delivery_status
    case "$5" in timeout|unavailable) tessera_agent_diagnostic publication "paneLock=$5" ;; esac
    agent_pid_presence=absent
    [ -z "$agent_pid" ] || agent_pid_presence=present
    tessera_agent_diagnostic resolved "agentPid=$agent_pid_presence pane=$3 terminal=$4 tmuxState=$1 terminalEmission=$2"
    case "$provider:$agent_pid:$event:${TESSERA_AGENT_OBSERVER:-}" in
        codex:?*:SessionStart:|codex:?*:UserPromptSubmit:)
            "${0%/*}/agent-codex-recover.sh" --watch-root "$agent_pid" </dev/null >/dev/null 2>&1 || true
            ;;
    esac
    exit 0
fi

defer_pane=0
if [ -n "$pane" ] && [ -n "$agent_pid" ] && command -v tmux >/dev/null 2>&1; then
    if [ "$(tessera_agent_foreground_status "$agent_pid")" = background ]; then
        pane_state="$(tmux show-options -pqv -t "$pane" @tessera_agent_state 2>/dev/null || true)"
        holder_pid="$(printf '%s' "$pane_state" | sed -n 's/.*"agentPid":\([0-9][0-9]*\)[,}].*/\1/p')"
        if [ -n "$holder_pid" ] && [ "$holder_pid" != "$agent_pid" ] && [ "$(tessera_agent_foreground_status "$holder_pid")" = foreground ]; then
            defer_pane=1
        fi
    fi
fi

terminal_path=""
tmux_state=not-applicable
if [ -n "$pane" ] && command -v tmux >/dev/null 2>&1; then
    terminal_path="$(tmux display-message -p -t "$pane" '#{pane_tty}' 2>/dev/null || true)"
    if [ "$defer_pane" -eq 1 ]; then
        tmux_state=deferred
    elif tmux set-option -p -t "$pane" @tessera_agent_state "$payload" >/dev/null 2>&1; then
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
if [ "$defer_pane" -eq 1 ]; then
    terminal_emission=deferred
elif [ -n "$terminal_path" ]; then
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
    public static let launcherScript = #"""
#!/bin/sh

# Tessera Agent Center provider launcher — remove with ~/.config/tessera/agent-uninstall.sh.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=\#(integrationVersion)
provider="${1:-}"
shift || exit 64
case "$provider" in claude|codex) ;; *) exit 64 ;; esac
[ "$#" -gt 0 ] || exit 64

# Codex does not create a thread at its empty composer, so its documented
# SessionStart hook may not fire until the first prompt; a resumed or forked
# thread fires none before its first turn either. The shim independently
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

    /// Provider-neutral, read-only projection entry point. The request is
    /// canonical JSON on stdin and the response is bounded NDJSON. Raw paths
    /// and transcript contents never appear in typed errors.
    public static let projectorScript = #"""
#!/bin/sh

# Tessera Agent Center transcript projector v1 — remove with ~/.config/tessera/agent-uninstall.sh.
set -u

# macOS ships /usr/bin/python3 3.9, which has no tomllib, and a
# non-interactive PATH finds it before any newer interpreter the user
# installed. Prefer the first candidate that can read TOML so Kimi hook
# verification stays available; otherwise keep the first interpreter found.
# Also check the standard package-manager locations: a non-interactive SSH
# shell may omit them even when the provider and its TOML support are installed.
tessera_python=''
for tessera_candidate in python3 python3.13 python3.12 python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    command -v "$tessera_candidate" >/dev/null 2>&1 || continue
    [ -n "$tessera_python" ] || tessera_python="$tessera_candidate"
    if "$tessera_candidate" -c 'import sys,importlib.util as u; sys.exit(0 if (u.find_spec("tomllib") or u.find_spec("tomli")) else 1)' >/dev/null 2>&1; then
        tessera_python="$tessera_candidate"
        break
    fi
done

if [ -z "$tessera_python" ]; then
    printf '%s\n' '{"v":1,"kind":"error","error":"unsupported","detail":"pythonUnavailable"}'
    exit 69
fi

exec "$tessera_python" -c '
import base64, codecs, hashlib, json, os, re, secrets, select, shutil, sqlite3, stat, subprocess, sys, tempfile, time, urllib.parse
from collections import deque

MAX_REQUEST = 65536
MAX_FRAME = 65536
MAX_PAGE = 262144
MAX_RECORDS = 100
MAX_RESULT = 16384
MAX_QUERY = 512
PROJECTION_DIAGNOSTICS = {"stage":"request"}
MAX_PREFIX = 49152
MAX_INVENTORY_DIRECTORIES = 256
MAX_INVENTORY_FILES = 2048
MAX_INVENTORY_BYTES = 8 * 1024 * 1024
MAX_INVENTORY_SECONDS = 3.0
MAX_PI_SESSION_BYTES = 8 * 1024 * 1024
MAX_PI_RPC_SECONDS = 2.0
MAX_PI_RPC_LINES = 512
MAX_OPENCODE_DB_BYTES = 512 * 1024 * 1024
OPENCODE_SESSION = re.compile(r"^[A-Za-z0-9_.-]{1,256}$")
MAX_CODEX_DB_BYTES = 256 * 1024 * 1024
CODEX_THREAD = re.compile(r"^[A-Za-z0-9_.-]{1,256}$")
# Codex keeps the LLM-written session title in its own state database, never
# in the rollout transcript. `name` is that title; `title` is the raw first
# user message the thread was opened with.
CODEX_REQUIRED = {"threads": {"id", "name", "title"}}
# A `title` longer than this is not a title. Codex stores the whole opening
# message there, and some of those are multi-kilobyte internal prompts whose
# first 512 characters read as noise -- worse than no title at all.
MAX_CODEX_FALLBACK_TITLE = 200
CODEX_TITLES = {}
PI_SESSION_COMPONENT = re.compile(r"^[A-Za-z0-9_.-]{1,256}$")
PI_SESSION_ID = re.compile(r"^[A-Za-z0-9-]{1,128}$")
OPENCODE_REQUIRED = {
    "session": {"id", "title", "directory", "version", "time_created", "time_updated"},
    "message": {"id", "session_id", "time_created", "time_updated", "data"},
    "part": {"id", "message_id", "session_id", "time_created", "time_updated", "data"},
}

class ProjectionError(Exception):
    def __init__(self, code, diagnostics=None):
        self.code = code
        self.diagnostics = diagnostics or {}

def emit(value, state):
    data = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(data) + 1 > MAX_FRAME: raise ProjectionError("malformed", dict(PROJECTION_DIAGNOSTICS, stage="encode", reason="frameTooLarge", frameBytes=str(len(data) + 1), limitBytes=str(MAX_FRAME)))
    if state[0] + len(data) + 1 > MAX_PAGE: raise ProjectionError("malformed", dict(PROJECTION_DIAGNOSTICS, stage="encode", reason="pageTooLarge", frameBytes=str(state[0] + len(data) + 1), limitBytes=str(MAX_PAGE)))
    sys.stdout.buffer.write(data + b"\n")
    state[0] += len(data) + 1

def fail(code, diagnostics=None):
    value = {"v":1,"kind":"error","error":code}
    if diagnostics: value["diagnostics"] = diagnostics
    data = json.dumps(value, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(data + b"\n")

def bounded_string(value, limit):
    if not isinstance(value, str): value = str(value) if value is not None else ""
    value = "".join(ch for ch in value if ch in "\n\t" or (ord(ch) >= 32 and not 0x202A <= ord(ch) <= 0x202E and not 0x2066 <= ord(ch) <= 0x2069))
    data = value.encode("utf-8", "replace")
    if len(data) <= limit: return value, False
    return data[:limit].decode("utf-8", "ignore"), True

def decode_ref(value):
    if not isinstance(value, str) or not value or len(value) > 4096: raise ProjectionError("malformed")
    try:
        raw = base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4)).decode("utf-8")
    except Exception: raise ProjectionError("malformed")
    if "\x00" in raw: raise ProjectionError("permissionDenied")
    return raw

def inventory_cursor_decode(value, provider, identity):
    if value is None: return 0
    try:
        decoded = json.loads(base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4)))
        offset = int(decoded["offset"])
        if decoded.get("provider") != provider or decoded.get("identity") != identity or offset < 0:
            raise ProjectionError("sourceChanged")
        return offset
    except ProjectionError: raise
    except Exception: raise ProjectionError("malformed")

def inventory_cursor_encode(provider, identity, offset):
    raw = json.dumps({"provider":provider,"identity":identity,"offset":offset}, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

def provider_roots(provider):
    home = os.path.realpath(os.environ.get("HOME") or os.path.expanduser("~"))
    kimi_home_raw = os.environ.get("KIMI_CODE_HOME") or os.path.join(home, ".kimi-code")
    if not isinstance(kimi_home_raw, str) or not kimi_home_raw or "\x00" in kimi_home_raw or len(kimi_home_raw.encode()) > 1024:
        raise ProjectionError("permissionDenied")
    kimi_home = os.path.expanduser(kimi_home_raw)
    if not os.path.isabs(kimi_home): raise ProjectionError("permissionDenied")
    roots = {
        "claude": [os.path.join(home, ".claude", "projects")],
        "codex": [os.path.join(home, ".codex", "sessions")],
        # Kimi index lives beside sessions; wire sources are resolved only
        # from session_index.jsonl -> sessions/<wd>/<id>/agents/*/wire.jsonl.
        "kimi": [kimi_home],
        # OpenCode uses one read-only SQLite database.  Session IDs, never
        # filesystem paths, are accepted as transcript references.
        "opencode": [os.path.join(home, ".local", "share", "opencode")],
        "pi": [os.path.join(home, ".pi", "agent", "sessions")],
    }.get(provider)
    if roots is None: raise ProjectionError("unsupported")
    return [os.path.realpath(path) for path in roots]

def opencode_database():
    return os.path.join(provider_roots("opencode")[0], "opencode.db")

def codex_state_database():
    # Codex versions this file (state_1..state_N) and keeps only the newest.
    # `provider_roots("codex")` is deliberately the sessions directory and must
    # stay that narrow, so the state database is resolved separately rather
    # than by widening the transcript root.
    home = os.path.realpath(os.environ.get("HOME") or os.path.expanduser("~"))
    root = os.path.join(home, ".codex")
    try: entries = os.listdir(root)
    except OSError: raise ProjectionError("sourceMissing")
    best = None
    for entry in entries:
        matched = re.fullmatch(r"state_(\d{1,4})\.sqlite", entry)
        if matched is None: continue
        version = int(matched.group(1))
        if best is None or version > best[0]: best = (version, entry)
    if best is None: raise ProjectionError("sourceMissing")
    return os.path.realpath(os.path.join(root, best[1]))

def codex_title(session_id):
    """The LLM-written title for a codex thread, or None.

    Codex writes it to its state database, never to the rollout transcript the
    projector streams, so a codex row showed "Untitled" no matter how much of
    the transcript had been read. Absence is normal -- an untitled thread, a
    codex too old to have the column, no state database at all -- and must
    never fail the projection that carries the rest of the record.
    """
    if not isinstance(session_id, str) or CODEX_THREAD.fullmatch(session_id) is None:
        return None
    try: candidate = codex_state_database()
    except ProjectionError: return None
    try: current = os.stat(candidate, follow_symlinks=False)
    except OSError: return None
    stamp = (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns)
    cached = CODEX_TITLES.get(session_id)
    if cached is not None and cached[0] == stamp: return cached[1]
    title = None
    try:
        database, descriptor, identity, snapshot_dir, verified_sources = open_snapshot_database(
            candidate, "codex", MAX_CODEX_DB_BYTES, CODEX_REQUIRED
        )
        try:
            row = database.execute("SELECT name,title FROM threads WHERE id = ? LIMIT 1", (session_id,)).fetchone()
        finally:
            close_snapshot_database(database, descriptor, identity, snapshot_dir, verified_sources, candidate, "codex")
        if row is not None:
            name, raw = row
            if isinstance(name, str) and name.strip():
                title = name.strip()
            elif isinstance(raw, str) and raw.strip() and len(raw) <= MAX_CODEX_FALLBACK_TITLE:
                # Only a short `title` is worth showing: it is the opening user
                # message, and a long one is a pasted log or an internal prompt.
                title = raw.strip()
    except ProjectionError:
        title = None
    except Exception:
        title = None
    if title is not None:
        title, _ = bounded_string(title, 512)
    # Cache the miss too: a thread that has no title yet is the common case and
    # must not re-snapshot the database for every page of its transcript.
    if len(CODEX_TITLES) > 256: CODEX_TITLES.clear()
    CODEX_TITLES[session_id] = (stamp, title)
    return title

def opencode_session_ref(session_id):
    if not isinstance(session_id, str) or OPENCODE_SESSION.fullmatch(session_id) is None:
        raise ProjectionError("malformed")
    return base64.urlsafe_b64encode(("opencode:" + session_id).encode("ascii")).decode("ascii").rstrip("=")

def decode_opencode_session_ref(value):
    decoded = decode_ref(value)
    if not decoded.startswith("opencode:"):
        raise ProjectionError("permissionDenied")
    session_id = decoded[len("opencode:"):]
    if OPENCODE_SESSION.fullmatch(session_id) is None:
        raise ProjectionError("malformed")
    return session_id

def open_snapshot_database(candidate, label, maximum, required):
    # The database location is compiled into the adapter.  It is never
    # received from the app, and its filesystem identity is checked around the
    # SQLite snapshot so an attacker cannot swap in a different database.
    #
    # Shared by every SQLite-backed provider. The opencode conversation store
    # and the codex thread state both need the same WAL-sidecar-complete
    # snapshot and the same identity re-checks, and a second copy of this would
    # be a second place for those checks to drift.
    #
    # This whole script is embedded in a shell single-quoted string, so it must
    # contain no apostrophe anywhere -- not even in a comment.
    try: before = os.lstat(candidate)
    except FileNotFoundError: raise ProjectionError("sourceMissing")
    except OSError: raise ProjectionError("permissionDenied")
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise ProjectionError("permissionDenied")
    if before.st_uid != os.getuid():
        raise ProjectionError("permissionDenied")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: descriptor = os.open(candidate, flags)
    except FileNotFoundError: raise ProjectionError("sourceMissing")
    except OSError: raise ProjectionError("permissionDenied")
    database = None
    snapshot_dir = None
    try:
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise ProjectionError("sourceChanged")
        if after.st_size > maximum:
            raise ProjectionError("permissionDenied")
        snapshot_dir = tempfile.mkdtemp(prefix=".tessera-" + label + "-")
        os.chmod(snapshot_dir, 0o700)
        snapshot_path = os.path.join(snapshot_dir, label + ".db")
        verified_sources = []

        def source_identity(sources):
            fields = []
            for source, expected in sources:
                # Not `label`: that name holds the provider passed to this
                # function, and shadowing it here made the identity prefix the
                # last sidecar seen ("shm") instead of the provider, so every
                # close-time re-check failed as `sourceChanged`.
                field = "db" if source == candidate else "wal" if source.endswith("-wal") else "shm"
                if expected is None:
                    fields.append(field + ":missing")
                else:
                    fields.append(field + ":%x:%x:%x:%x" % expected)
            return label + ":" + ";".join(fields)

        def copy_descriptor(source_fd, destination, maximum):
            target = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0), 0o600)
            os.lseek(source_fd, 0, os.SEEK_SET)
            copied = 0
            try:
                while True:
                    chunk = os.read(source_fd, min(1048576, maximum + 1 - copied))
                    if not chunk: break
                    copied += len(chunk)
                    if copied > maximum: raise ProjectionError("permissionDenied")
                    view = memoryview(chunk)
                    while view:
                        written = os.write(target, view)
                        if written <= 0: raise ProjectionError("channelUnavailable")
                        view = view[written:]
                os.fsync(target)
            finally:
                os.close(target)

        copy_descriptor(descriptor, snapshot_path, maximum)
        copied_source = os.fstat(descriptor)
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (copied_source.st_dev, copied_source.st_ino, copied_source.st_size, copied_source.st_mtime_ns):
            raise ProjectionError("sourceChanged")
        verified_sources.append((candidate, (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)))

        # WAL-mode databases require the matching sidecars for a current,
        # transactionally consistent snapshot. Copy each from a verified FD,
        # then recheck every source identity after the set is complete.
        for suffix in ("-wal", "-shm"):
            source = candidate + suffix
            try: side_before = os.lstat(source)
            except FileNotFoundError:
                verified_sources.append((source, None))
                continue
            except OSError: raise ProjectionError("permissionDenied")
            if stat.S_ISLNK(side_before.st_mode) or not stat.S_ISREG(side_before.st_mode) or side_before.st_uid != os.getuid() or side_before.st_size > maximum:
                raise ProjectionError("permissionDenied")
            try: side_fd = os.open(source, flags)
            except OSError: raise ProjectionError("sourceChanged")
            try:
                side_after = os.fstat(side_fd)
                side_identity = (side_after.st_dev, side_after.st_ino, side_after.st_size, side_after.st_mtime_ns)
                if (side_before.st_dev, side_before.st_ino, side_before.st_size, side_before.st_mtime_ns) != side_identity:
                    raise ProjectionError("sourceChanged")
                copy_descriptor(side_fd, snapshot_path + suffix, maximum)
                side_latest = os.fstat(side_fd)
                if (side_latest.st_dev, side_latest.st_ino, side_latest.st_size, side_latest.st_mtime_ns) != side_identity:
                    raise ProjectionError("sourceChanged")
                verified_sources.append((source, side_identity))
            finally:
                os.close(side_fd)
        for source, expected in verified_sources:
            if expected is None:
                try: os.lstat(source)
                except FileNotFoundError: continue
                except OSError: raise ProjectionError("sourceChanged")
                raise ProjectionError("sourceChanged")
            else:
                try: latest = os.stat(source, follow_symlinks=False)
                except OSError: raise ProjectionError("sourceChanged")
                if (latest.st_dev, latest.st_ino, latest.st_size, latest.st_mtime_ns) != expected:
                    raise ProjectionError("sourceChanged")

        # SQLite reads only the owner-private, WAL-complete snapshot. The
        # mutable provider pathname is never reopened by SQLite.
        uri = "file:" + urllib.parse.quote(snapshot_path) + "?mode=ro"
        database = sqlite3.connect(uri, uri=True, timeout=1.0)
        database.execute("PRAGMA query_only=ON")
        database.execute("BEGIN")
        validate_schema(database, required)
        identity = source_identity(verified_sources)
        return database, descriptor, identity, snapshot_dir, verified_sources
    except ProjectionError:
        if database is not None: database.close()
        if snapshot_dir is not None: shutil.rmtree(snapshot_dir, ignore_errors=True)
        os.close(descriptor); raise
    except Exception:
        if database is not None: database.close()
        if snapshot_dir is not None: shutil.rmtree(snapshot_dir, ignore_errors=True)
        os.close(descriptor); raise ProjectionError("adapterOutdated")

def open_opencode_database():
    return open_snapshot_database(opencode_database(), "opencode", MAX_OPENCODE_DB_BYTES, OPENCODE_REQUIRED)

def validate_schema(database, schema):
    for table, required in schema.items():
        rows = database.execute("PRAGMA table_info(" + table + ")").fetchall()
        columns = {row[1] for row in rows if len(row) > 1}
        if not required.issubset(columns): raise ProjectionError("adapterOutdated")

def close_snapshot_database(database, descriptor, identity, snapshot_dir, verified_sources, candidate, label):
    try:
        database.rollback()
        after = os.fstat(descriptor)
        if not verified_sources or verified_sources[0][1] != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ProjectionError("sourceChanged")
        fields = []
        for source, expected in verified_sources:
            field = "db" if source == candidate else "wal" if source.endswith("-wal") else "shm"
            if expected is None:
                try: os.lstat(source)
                except FileNotFoundError:
                    fields.append(field + ":missing")
                    continue
                except OSError: raise ProjectionError("sourceChanged")
                raise ProjectionError("sourceChanged")
            try: current = os.stat(source, follow_symlinks=False)
            except OSError: raise ProjectionError("sourceChanged")
            current_identity = (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns)
            if current_identity != expected: raise ProjectionError("sourceChanged")
            fields.append(field + ":%x:%x:%x:%x" % expected)
        if label + ":" + ";".join(fields) != identity:
            raise ProjectionError("sourceChanged")
    finally:
        database.close()
        os.close(descriptor)
        shutil.rmtree(snapshot_dir, ignore_errors=True)

def close_opencode_database(database, descriptor, identity, snapshot_dir, verified_sources):
    close_snapshot_database(database, descriptor, identity, snapshot_dir, verified_sources, opencode_database(), "opencode")

def opencode_cursor_decode(value, identity, session_id):
    if value is None: return 0, "", 0
    try:
        decoded = json.loads(base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4)))
        if decoded.get("identity") != identity or decoded.get("session") != session_id:
            raise ProjectionError("sourceChanged")
        created, part_id, sequence = int(decoded["time"]), decoded["part"], int(decoded["sequence"])
        if created < 0 or sequence < 0 or not isinstance(part_id, str) or (part_id and OPENCODE_SESSION.fullmatch(part_id) is None):
            raise ValueError()
        return created, part_id, sequence
    except ProjectionError: raise
    except Exception: raise ProjectionError("malformed")

def opencode_cursor_encode(identity, session_id, created, part_id, sequence):
    value = {"identity":identity, "session":session_id, "time":created, "part":part_id, "sequence":sequence}
    data = json.dumps(value, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

def load_kimi_index(root):
    # Kimi Code 0.31+ stores an absolute sessionDir together with the exact
    # sessionId/workDir. Never search serialized JSON by substring: unrelated
    # content is not authority.
    index = os.path.join(root, "session_index.jsonl")
    try:
        before = os.lstat(index)
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_size > 1048576:
            return None
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(index, flags)
        try:
            after = os.fstat(descriptor)
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                return None
            data = os.read(descriptor, 1048577)
        finally:
            os.close(descriptor)
        if len(data) > 1048576: return None
        allowed = set()
        for line in data.splitlines()[:4096]:
            if len(line) > 8192: continue
            try: record = json.loads(line)
            except Exception: continue
            if not isinstance(record, dict): continue
            session_id = record.get("sessionId")
            session_dir = record.get("sessionDir")
            if not isinstance(session_id, str) or re.fullmatch(r"session_[A-Za-z0-9-]{1,128}", session_id) is None:
                continue
            if not isinstance(session_dir, str) or "\x00" in session_dir:
                continue
            resolved = os.path.realpath(os.path.abspath(os.path.expanduser(session_dir)))
            sessions_root = os.path.realpath(os.path.join(root, "sessions"))
            try:
                if os.path.commonpath([resolved, sessions_root]) != sessions_root: continue
            except ValueError:
                continue
            relative = os.path.relpath(resolved, root)
            if re.fullmatch(r"sessions/[^/]+/" + re.escape(session_id), relative):
                allowed.add(relative)
        return ((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns), frozenset(allowed))
    except OSError:
        return None

def validate_kimi_hook_configuration(root):
    candidate = os.path.join(root, "config.toml")
    try:
        before = os.lstat(candidate)
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_size > 1048576:
            return False
        descriptor = os.open(candidate, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
        try:
            after = os.fstat(descriptor)
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                return False
            data = os.read(descriptor, 1048577)
        finally:
            os.close(descriptor)
        if len(data) > 1048576: return False
        text = data.decode("utf-8")
        start_marker = "# TESSERA-AGENT-CENTER-KIMI-HOOKS-BEGIN"
        end_marker = "# TESSERA-AGENT-CENTER-KIMI-HOOKS-END"
        if text.count(start_marker) != 1 or text.count(end_marker) != 1: return False
        start = text.index(start_marker) + len(start_marker)
        end = text.index(end_marker)
        if start >= end: return False
        try:
            try:
                import tomllib
            except ImportError:
                import tomli as tomllib
            document = tomllib.loads(text)
            owned = tomllib.loads(text[start:end])
        except Exception:
            return False
        expected = [
            {"event":"SessionStart", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi SessionStart idle session-start"},
            {"event":"SubagentStart", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi SubagentStart working subagent-start"},
            {"event":"SubagentStop", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi SubagentStop working subagent-stop"},
            {"event":"UserPromptSubmit", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi UserPromptSubmit working agent-turn"},
            {"event":"PreToolUse", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi PreToolUse working agent-turn"},
            {"event":"PostToolUse", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi PostToolUse working agent-turn"},
            {"event":"PermissionRequest", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi PermissionRequest waitingForInput permission"},
            {"event":"Stop", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi Stop idle turn-stopped"},
            {"event":"StopFailure", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi StopFailure unavailable turn-failed"},
            {"event":"SessionEnd", "command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi SessionEnd unavailable session-ended"},
        ]
        if not isinstance(document, dict) or set(owned.keys()) != {"hooks"} or owned.get("hooks") != expected:
            return False
        hooks = document.get("hooks")
        if not isinstance(hooks, list) or len(hooks) < len(expected) or hooks[-len(expected):] != expected:
            return False
        owned_commands = {hook["command"] for hook in expected}
        return sum(
            1 for hook in hooks
            if isinstance(hook, dict) and hook.get("command") in owned_commands
        ) == len(expected)
    except (OSError, UnicodeError, ValueError):
        return False

def kimi_index_allows(relative, cached_index):
    matched = re.fullmatch(r"(sessions/[^/]+/[^/]+)/agents/[^/]+/wire\.jsonl", relative)
    return matched is not None and cached_index is not None and matched.group(1) in cached_index[1]

def pi_open_sessions_root():
    home = os.path.realpath(os.environ.get("HOME") or os.path.expanduser("~"))
    current = home
    directory = None
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        directory = os.open(home, flags)
        for component in (".pi", "agent", "sessions"):
            current = os.path.join(current, component)
            child = os.open(component, flags, dir_fd=directory)
            os.close(directory)
            directory = child
            info = os.fstat(directory)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                raise ProjectionError("permissionDenied")
        opened = directory
        directory = None
        return current, opened
    except FileNotFoundError: raise ProjectionError("sourceMissing")
    except ProjectionError: raise
    except OSError: raise ProjectionError("permissionDenied")
    finally:
        if directory is not None: os.close(directory)

def pi_sessions_root():
    root, directory = pi_open_sessions_root()
    os.close(directory)
    return root

def pi_relative_path(value):
    if not isinstance(value, str) or not value or len(value.encode()) > 1024: raise ProjectionError("malformed")
    parts = value.split("/")
    if len(parts) not in {1, 2} or any(PI_SESSION_COMPONENT.fullmatch(part) is None or part in {".", ".."} for part in parts):
        raise ProjectionError("malformed")
    if not parts[-1].endswith(".jsonl"): raise ProjectionError("malformed")
    return "/".join(parts)

def pi_session_ref(relative):
    return base64.urlsafe_b64encode(("pi:" + pi_relative_path(relative)).encode("ascii")).decode("ascii").rstrip("=")

def decode_pi_session_ref(value):
    decoded = decode_ref(value)
    if not decoded.startswith("pi:"): raise ProjectionError("permissionDenied")
    return pi_relative_path(decoded[3:])

def pi_secure_session_path(relative):
    relative = pi_relative_path(relative)
    root, directory = pi_open_sessions_root()
    components = relative.split("/")
    candidate = os.path.join(root, *components)
    descriptor = None
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        # Anchor each lookup to its already-open directory, not a re-resolved
        # pathname. User-chosen writable directories may be renamed while a
        # read is in flight, but an intermediate symlink must never redirect it.
        for component in components[:-1]:
            child = os.open(component, flags | getattr(os, "O_DIRECTORY", 0), dir_fd=directory)
            os.close(directory)
            directory = child
            info = os.fstat(directory)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
                raise ProjectionError("permissionDenied")
        descriptor = os.open(components[-1], flags | getattr(os, "O_NONBLOCK", 0), dir_fd=directory)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_size > MAX_PI_SESSION_BYTES:
            raise ProjectionError("permissionDenied")
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
            raise ProjectionError("sourceChanged")
        identity = "pi:%x:%x:%x:%x" % (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        opened = descriptor
        descriptor = None
        return candidate, opened, identity, after
    except FileNotFoundError: raise ProjectionError("sourceMissing")
    except ProjectionError: raise
    except OSError: raise ProjectionError("permissionDenied")
    finally:
        os.close(directory)
        if descriptor is not None: os.close(descriptor)

def pi_session_header(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    retained = bytearray()
    while len(retained) <= MAX_PREFIX:
        chunk = os.read(descriptor, min(8192, MAX_PREFIX + 1 - len(retained)))
        if not chunk: break
        marker = chunk.find(b"\n")
        retained.extend(chunk if marker < 0 else chunk[:marker])
        if marker >= 0: break
    if not retained or len(retained) > MAX_PREFIX: raise ProjectionError("adapterOutdated")
    first = bytes(retained)
    try: header = json.loads(first.decode("utf-8"))
    except Exception: raise ProjectionError("adapterOutdated")
    if not isinstance(header, dict) or header.get("type") != "session": raise ProjectionError("adapterOutdated")
    session_id = header.get("id")
    if not isinstance(session_id, str) or PI_SESSION_ID.fullmatch(session_id) is None: raise ProjectionError("adapterOutdated")
    version = header.get("version", 1)
    if not isinstance(version, int) or version not in {1, 2, 3}: raise ProjectionError("adapterOutdated")
    cwd = header.get("cwd")
    if not isinstance(cwd, str) or not cwd or len(cwd.encode()) > 2048 or "\x00" in cwd: raise ProjectionError("adapterOutdated")
    return session_id

def pi_snapshot_session(descriptor, identity):
    # Pi has migration support and is therefore never pointed at user-owned
    # source JSONL.  Its RPC child reads an owner-only immutable snapshot; any
    # source change during copying invalidates the operation.
    temporary = None; path = None; rewritten = None; rewritten_path = None
    try:
        temporary, path = tempfile.mkstemp(prefix="tessera-pi-", suffix=".jsonl")
        os.fchmod(temporary, 0o600)
        os.lseek(descriptor, 0, os.SEEK_SET)
        copied = 0
        while True:
            chunk = os.read(descriptor, 8192)
            if not chunk: break
            copied += len(chunk)
            if copied > MAX_PI_SESSION_BYTES: raise ProjectionError("permissionDenied")
            view = memoryview(chunk)
            while view:
                written = os.write(temporary, view)
                if written <= 0: raise ProjectionError("channelUnavailable")
                view = view[written:]
        latest = os.fstat(descriptor)
        latest_identity = "pi:%x:%x:%x:%x" % (latest.st_dev, latest.st_ino, latest.st_size, latest.st_mtime_ns)
        if latest_identity != identity: raise ProjectionError("sourceChanged")
        # Pi print-mode headers can retain a temporary working directory after
        # it has been deleted. Its RPC loader refuses those sessions before it
        # reads the copied transcript, so repair only the snapshot header.
        os.lseek(temporary, 0, os.SEEK_SET)
        prefix = os.read(temporary, min(MAX_PREFIX + 1, copied))
        marker = prefix.find(b"\n")
        if marker >= 0 and marker <= MAX_PREFIX:
            try:
                header = json.loads(prefix[:marker].decode("utf-8"))
                cwd = header.get("cwd") if isinstance(header, dict) else None
            except Exception:
                header = None; cwd = None
            if isinstance(cwd, str) and not os.path.isdir(cwd):
                header["cwd"] = os.path.dirname(path)
                replacement = json.dumps(header, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
                if len(replacement) - 1 > MAX_PREFIX: raise ProjectionError("adapterOutdated")
                if copied - marker - 1 + len(replacement) > MAX_PI_SESSION_BYTES: raise ProjectionError("permissionDenied")
                rewritten, rewritten_path = tempfile.mkstemp(prefix="tessera-pi-", suffix=".jsonl")
                os.fchmod(rewritten, 0o600)
                def write_all(target, value):
                    view = memoryview(value)
                    while view:
                        written = os.write(target, view)
                        if written <= 0: raise ProjectionError("channelUnavailable")
                        view = view[written:]
                write_all(rewritten, replacement)
                os.lseek(temporary, marker + 1, os.SEEK_SET)
                while True:
                    chunk = os.read(temporary, 8192)
                    if not chunk: break
                    write_all(rewritten, chunk)
                os.close(temporary); temporary = None
                os.unlink(path); path = None
                os.close(rewritten); rewritten = None
                return rewritten_path
        os.close(temporary); temporary = None
        return path
    except Exception:
        if temporary is not None: os.close(temporary)
        if rewritten is not None: os.close(rewritten)
        for candidate in (path, rewritten_path):
            if candidate is not None:
                try: os.unlink(candidate)
                except OSError: pass
        raise

def pi_executable(name):
    # The dumped projector does not inherit an interactive login shell.  Prefer
    # the current PATH for normal installations, then use the three supported
    # non-interactive locations rather than trying a shell or broadening PATH.
    candidates = [
        shutil.which(name),
        os.path.expanduser("~/.local/bin/" + name),
        "/opt/homebrew/bin/" + name,
        "/usr/local/bin/" + name,
    ]
    for candidate in candidates:
        if not candidate: continue
        try:
            resolved = os.path.realpath(candidate)
            info = os.stat(resolved, follow_symlinks=False)
        except FileNotFoundError:
            continue
        except OSError:
            raise ProjectionError("unsupported")
        if not stat.S_ISREG(info.st_mode) or not (info.st_mode & 0o111) or info.st_uid not in {0, os.getuid()}:
            raise ProjectionError("permissionDenied")
        return resolved
    raise ProjectionError("unsupported")

def pi_binary():
    return pi_executable("pi")

def pi_argv(binary, snapshot):
    try:
        with open(binary, "rb") as executable:
            interpreter = executable.readline(128).rstrip(b"\r\n")
    except OSError:
        raise ProjectionError("unsupported")
    arguments = ["--mode", "rpc", "--session", snapshot, "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-context-files"]
    # The JavaScript launcher for Pi deliberately uses env so it can be installed
    # across platforms. Resolve node under the same bounded executable policy
    # before launching it; all other native or test executables stay direct.
    if interpreter == b"#!/usr/bin/env node":
        return [pi_executable("node"), binary] + arguments
    return [binary] + arguments

def pi_rpc(snapshot, commands, deadline):
    # A fixed argv vector, pipe-only stdio, and a total deadline make this a
    # read-side probe, not a shell bridge. Pi remains alive after commands, so
    # the child is explicitly terminated once all nonce-correlated responses
    # arrive.
    binary = pi_binary()
    if not isinstance(commands, list) or not commands: raise ProjectionError("malformed")
    expected = set()
    payload = bytearray()
    for command in commands:
        if not isinstance(command, dict) or command.get("type") not in {"get_state", "get_messages"}:
            raise ProjectionError("malformed")
        request_id = command.get("id")
        if not isinstance(request_id, str) or not re.fullmatch(r"[0-9a-f]{32}", request_id): raise ProjectionError("malformed")
        if request_id in expected: raise ProjectionError("malformed")
        expected.add(request_id)
        encoded = json.dumps(command, separators=(",", ":")).encode("utf-8")
        if len(encoded) + 1 > MAX_FRAME: raise ProjectionError("malformed")
        payload.extend(encoded + b"\n")
    if len(payload) > MAX_REQUEST: raise ProjectionError("malformed")
    process = None
    try:
        process = subprocess.Popen(pi_argv(binary, snapshot), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, close_fds=True)
        # Keep stdin open while reading: RPC mode is a persistent command loop,
        # and EOF is not a protocol acknowledgement for either request.
        process.stdin.write(bytes(payload)); process.stdin.flush()
        results = {}; buffered = bytearray(); bytes_seen = 0; lines_seen = 0
        descriptor = process.stdout.fileno()
        while expected - set(results):
            remaining = min(MAX_PI_RPC_SECONDS, deadline - time.monotonic())
            if remaining <= 0: raise ProjectionError("channelUnavailable")
            readable, _, _ = select.select([descriptor], [], [], remaining)
            if not readable: raise ProjectionError("channelUnavailable")
            chunk = os.read(descriptor, 8192)
            if not chunk: raise ProjectionError("channelUnavailable")
            bytes_seen += len(chunk)
            if bytes_seen > MAX_PAGE: raise ProjectionError("channelUnavailable")
            buffered.extend(chunk)
            while b"\n" in buffered:
                raw, _, buffered = buffered.partition(b"\n")
                lines_seen += 1
                if lines_seen > MAX_PI_RPC_LINES or len(raw) > MAX_FRAME: raise ProjectionError("channelUnavailable")
                if raw.endswith(b"\r"): raw = raw[:-1]
                if not raw or b"\r" in raw: raise ProjectionError("adapterOutdated")
                try: frame = json.loads(raw.decode("utf-8"))
                except Exception: raise ProjectionError("adapterOutdated")
                if not isinstance(frame, dict): raise ProjectionError("adapterOutdated")
                if frame.get("type") != "response": continue
                request_id = frame.get("id")
                if request_id not in expected: raise ProjectionError("adapterOutdated")
                if frame.get("success") is not True: raise ProjectionError("adapterOutdated")
                command = next(item for item in commands if item["id"] == request_id)
                if frame.get("command") != command["type"] or request_id in results: raise ProjectionError("adapterOutdated")
                results[request_id] = frame
        return results
    except ProjectionError: raise
    except Exception: raise ProjectionError("channelUnavailable")
    finally:
        if process is not None:
            try: process.stdin.close()
            except Exception: pass
            try: process.terminate(); process.wait(timeout=0.5)
            except Exception:
                try: process.kill(); process.wait(timeout=0.5)
                except Exception: pass

def pi_state(frame, expected_session_id, snapshot):
    data = frame.get("data")
    if not isinstance(data, dict) or not isinstance(data.get("isStreaming"), bool): raise ProjectionError("adapterOutdated")
    session_id = data.get("sessionId")
    session_file = data.get("sessionFile")
    message_count = data.get("messageCount")
    pending = data.get("pendingMessageCount")
    if not isinstance(session_id, str) or PI_SESSION_ID.fullmatch(session_id) is None or session_id != expected_session_id:
        raise ProjectionError("adapterOutdated")
    if not isinstance(session_file, str) or os.path.realpath(session_file) != os.path.realpath(snapshot): raise ProjectionError("adapterOutdated")
    if not isinstance(message_count, int) or isinstance(message_count, bool) or message_count < 0 or message_count > 100000:
        raise ProjectionError("adapterOutdated")
    if not isinstance(pending, int) or isinstance(pending, bool) or pending < 0 or pending > 100000:
        raise ProjectionError("adapterOutdated")
    # pi names a session only when a reader asks it to, through -n or /name, so
    # absence is the common case and not an error. It is still the strongest
    # title pi can offer: a person chose it.
    #
    # A name of the wrong type counts as no name rather than as a dead adapter.
    # The title is one tier of a waterfall that falls back to an on-device
    # summary and then to the opening prompt, and both of those are built from
    # the transcript this same call carries: failing the whole projection over
    # a decorative field would take the material for its own fallbacks with it.
    # Every other provider already treats an unreadable title this way.
    name = data.get("sessionName")
    if not isinstance(name, str):
        name = None
    else:
        name, _ = bounded_string(name.strip(), 512)
        name = name or None
    return {"sessionID":session_id, "isStreaming":data["isStreaming"], "messageCount":message_count, "pendingMessageCount":pending, "sessionName":name}

def pi_load_session(relative, include_messages, deadline):
    path, descriptor, identity, source_stat = pi_secure_session_path(relative)
    snapshot = None
    try:
        header_id = pi_session_header(descriptor)
        snapshot = pi_snapshot_session(descriptor, identity)
        state_id = secrets.token_hex(16)
        commands = [{"id":state_id, "type":"get_state"}]
        messages_id = None
        if include_messages:
            messages_id = secrets.token_hex(16)
            commands.append({"id":messages_id, "type":"get_messages"})
        responses = pi_rpc(snapshot, commands, deadline)
        state = pi_state(responses[state_id], header_id, snapshot)
        messages = None
        if messages_id is not None:
            data = responses[messages_id].get("data")
            if not isinstance(data, dict) or not isinstance(data.get("messages"), list) or len(data["messages"]) != state["messageCount"] or len(data["messages"]) > MAX_RECORDS * 16:
                raise ProjectionError("adapterOutdated")
            messages = data["messages"]
        return identity, state, messages, source_stat
    finally:
        os.close(descriptor)
        if snapshot is not None:
            try: os.unlink(snapshot)
            except OSError: pass

def validate_source(provider, ref, kimi_index=None):
    decoded = decode_ref(ref)
    candidate = os.path.realpath(os.path.abspath(os.path.expanduser(decoded)))
    roots = provider_roots(provider)
    # Fixed labels and numeric facts only: no transcript bytes, paths, user
    # names or environment values enter the exported device diagnostics.
    path_kind = "windowsDrive" if re.match(r"^[A-Za-z]:[\\/]", decoded) else "unc" if decoded.startswith("\\\\") else "posix" if decoded.startswith("/") else "relative"
    facts = {"provider":provider, "pathKind":path_kind, "effectiveUID":str(os.geteuid())}
    def deny(reason, stage, error=None, source=None):
        details = dict(facts, reason=reason, stage=stage)
        if error is not None and error.errno is not None: details["errno"] = str(error.errno)
        if source is not None:
            details.update(ownerUID=str(source.st_uid), ownerGID=str(source.st_gid), mode=format(stat.S_IMODE(source.st_mode), "04o"))
        raise ProjectionError("permissionDenied", details)
    if not any(os.path.commonpath([candidate, root]) == root for root in roots): deny("outsideAllowedRoot", "sourceRoot")
    try: before = os.lstat(candidate)
    except FileNotFoundError: raise ProjectionError("sourceMissing")
    except OSError as error: deny("statDenied", "sourceStat", error=error)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode): deny("notRegularFile", "sourcePolicy", source=before)
    if before.st_uid != os.getuid(): deny("ownerMismatch", "sourcePolicy", source=before)
    # Transcript data may be group/world-writable by user choice. Reading it
    # does not authorize terminal actions; those require a fresh route proof.
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try: descriptor = os.open(candidate, flags)
    except FileNotFoundError: raise ProjectionError("sourceMissing")
    except OSError as error: deny("openDenied", "sourceOpen", error=error, source=before)
    after = os.fstat(descriptor)
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        os.close(descriptor); raise ProjectionError("sourceChanged")
    # Any rewrite, truncation, or append changes this identity. Restarting is
    # conservative but prevents a cursor continuing on substituted bytes.
    identity = jsonl_identity(provider, after)
    if provider == "kimi":
        root = provider_roots(provider)[0]
        relative = os.path.relpath(candidate, root)
        cached_index = kimi_index if kimi_index is not None else load_kimi_index(root)
        if not kimi_index_allows(relative, cached_index):
            os.close(descriptor); raise ProjectionError("permissionDenied")
    return descriptor, identity, after

def cursor_decode(value, identity, descriptor=None, source_stat=None):
    if value is None: return 0, 0
    try:
        decoded = json.loads(base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4)))
        if decoded.get("identity") != identity:
            previous = decoded.get("identity", "").split(":")
            current = identity.split(":")
            # Old helpers have no prefix proof: they retain their strict
            # invalidation behavior. New cursors survive append only after
            # verifying every byte of the earlier snapshot, including bytes
            # outside the currently visible page.
            expected = decoded.get("prefixHash")
            if descriptor is None or source_stat is None or len(previous) != len(current) or previous[:-2] != current[:-2] or not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
                raise ProjectionError("sourceChanged")
            size = int(previous[-2], 16)
            if size > source_stat.st_size: raise ProjectionError("sourceChanged")
            os.lseek(descriptor, 0, os.SEEK_SET)
            digest = hashlib.sha256(); remaining = size
            while remaining:
                chunk = os.read(descriptor, min(65536, remaining))
                if not chunk: raise ProjectionError("sourceChanged")
                digest.update(chunk); remaining -= len(chunk)
            if digest.hexdigest() != expected: raise ProjectionError("sourceChanged")
        offset, sequence = int(decoded["offset"]), int(decoded["sequence"])
        if offset < 0 or sequence < 0: raise ValueError()
        return offset, sequence
    except ProjectionError: raise
    except Exception: raise ProjectionError("malformed")

def cursor_encode(identity, offset, sequence, prefix_hash=None):
    data = json.dumps({"identity":identity,"offset":offset,"sequence":sequence,"prefixHash":prefix_hash}, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

class ImageURL:
    def __init__(self):
        self.header = bytearray()
        self.started = False
        self.valid = True
        self.count = 0
        self.padding = 0

    def feed(self, data):
        if not self.valid: return
        if not self.started:
            marker = data.find(b",")
            piece = data if marker < 0 else data[:marker + 1]
            if len(self.header) + len(piece) > 128:
                self.valid = False; return
            self.header.extend(piece)
            if marker < 0: return
            self.started = True
            self.valid = re.fullmatch(br"data:image/[A-Za-z0-9.+-]+;base64,", self.header) is not None
            data = data[marker + 1:]
        if not self.valid or not data: return
        if re.fullmatch(br"[A-Za-z0-9+/]*={0,2}", data) is None or (self.padding and data.strip(b"=")):
            self.valid = False; return
        self.count += len(data)
        self.padding += data.count(b"=")
        if self.padding > 2: self.valid = False

    def verified(self):
        return self.valid and self.started and self.count >= 4 and self.count % 4 == 0


class ImageLine:
    # Incremental JSON string lexer. Keep the original document except image
    # URL values, so text after a multi-megabyte base64 image stays available.
    # JSON parsing still validates the entire retained envelope afterward.
    special = re.compile(br"[\\\"]")

    def __init__(self):
        self.retained = bytearray()
        self.truncated = False
        self.in_string = False
        self.escaped = False
        self.image = False
        self.image_url = ImageURL()
        self.malformed = False
        self.unicode_digits = 0
        self.image_decoder = None
        self.token = bytearray()
        self.last_string = None
        self.pending_key = None

    def append(self, value):
        room = MAX_PREFIX - len(self.retained)
        self.retained.extend(value[:room])
        if len(value) > room: self.truncated = True

    def token_append(self, value):
        if len(self.token) < 65: self.token.extend(value[:65 - len(self.token)])

    def value(self):
        return b"\x00" if self.malformed else bytes(self.retained)

    def image_piece(self, piece):
        self.image_url.feed(piece)
        try: self.image_decoder.decode(piece)
        except UnicodeDecodeError: self.malformed = True
        if re.search(br"[\x00-\x1f]", piece): self.malformed = True

    def feed(self, data):
        index = 0
        while index < len(data):
            if self.in_string:
                if self.image and self.unicode_digits:
                    value = data[index:index + 1]; index += 1
                    if value not in b"0123456789abcdefABCDEF": self.malformed = True
                    self.unicode_digits -= 1
                    continue
                if self.escaped:
                    piece = data[index:index + 1]
                    if self.image:
                        if piece not in b"\"\\/bfnrtu": self.malformed = True
                        if piece == b"u": self.unicode_digits = 4
                    self.token_append(piece)
                    if not self.image: self.append(piece)
                    self.escaped = False; index += 1
                    continue
                match = self.special.search(data, index)
                end = match.start() if match else len(data)
                piece = data[index:end]
                self.token_append(piece)
                if self.image: self.image_piece(piece)
                if not self.image: self.append(piece)
                index = end
                if match is None: continue
                value = data[index:index + 1]; index += 1
                self.token_append(value)
                if not self.image: self.append(value)
                if value == b"\\":
                    self.escaped = True
                    if self.image:
                        self.image_url.valid = False
                        # An escape is an ASCII boundary in the original JSON;
                        # it cannot join two otherwise invalid UTF-8 fragments.
                        try: self.image_decoder.decode(b"", final=True)
                        except UnicodeDecodeError: self.malformed = True
                        self.image_decoder = codecs.getincrementaldecoder("utf-8")("strict")
                else:
                    self.in_string = False
                    if self.image:
                        try: self.image_decoder.decode(b"", final=True)
                        except UnicodeDecodeError: self.malformed = True
                        verified = self.image_url.verified() and not self.malformed
                        self.append(b"\"tessera:image\"" if verified else b"\"tessera:unverified-image\"")
                        self.last_string = None
                    else:
                        try: self.last_string = json.loads(self.token) if len(self.token) < 65 else None
                        except Exception: self.last_string = None
            else:
                value = data[index:index + 1]; index += 1
                if value == b"\"":
                    self.in_string = True; self.escaped = False
                    self.image = self.pending_key == "image_url"
                    self.image_url = ImageURL()
                    self.image_decoder = codecs.getincrementaldecoder("utf-8")("strict")
                    self.unicode_digits = 0
                    self.token = bytearray(value)
                    self.pending_key = None; self.last_string = None
                    if not self.image: self.append(value)
                else:
                    self.append(value)
                    if value == b":": self.pending_key = self.last_string
                    elif value not in b" \t\r": self.pending_key = None
                    if value not in b" \t\r": self.last_string = None


def jsonl_identity(provider, source_stat):
    identity = "%x:%x:%x:%x" % (source_stat.st_dev, source_stat.st_ino, source_stat.st_size, source_stat.st_mtime_ns)
    # Namespace this projection schema: old cached unknown image records must
    # never be merged with new attachment records at the same source position.
    return "codex-images1:" + identity if provider == "codex" else identity


def lines(descriptor, offset, complete_only=False, end_offset=None, digest=None, redact_images=False, source_hash=None):
    os.lseek(descriptor, offset, os.SEEK_SET)
    retained = bytearray()
    image_line = ImageLine() if redact_images else None
    line_digest = hashlib.sha256()
    absolute = offset
    truncated = False
    read_offset = offset
    while True:
        remaining = 8192 if end_offset is None else min(8192, end_offset - read_offset)
        chunk = os.read(descriptor, remaining) if remaining > 0 else b""
        if not chunk:
            if end_offset is not None and read_offset < end_offset: raise ProjectionError("sourceChanged")
            if not complete_only and (retained or truncated or (image_line and image_line.retained)):
                if source_hash is not None: source_hash[0] = line_digest.hexdigest()
                yield absolute, image_line.value() if image_line else bytes(retained), image_line.truncated if image_line else truncated
            return
        read_offset += len(chunk)
        if digest is not None: digest.update(chunk)
        start = 0
        while True:
            end = chunk.find(b"\n", start)
            piece = chunk[start:] if end < 0 else chunk[start:end]
            line_digest.update(piece)
            if image_line is not None:
                image_line.feed(piece)
            elif len(retained) < MAX_PREFIX:
                room = MAX_PREFIX - len(retained)
                retained.extend(piece[:room])
                if len(piece) > room: truncated = True
            elif piece: truncated = True
            if end < 0:
                absolute += len(chunk) - start
                break
            absolute += end - start + 1
            if source_hash is not None: source_hash[0] = line_digest.hexdigest()
            yield absolute, image_line.value() if image_line else bytes(retained), image_line.truncated if image_line else truncated
            retained.clear(); truncated = False; start = end + 1
            image_line = ImageLine() if redact_images else None
            line_digest = hashlib.sha256()

def preview(value, limit=MAX_RESULT):
    if isinstance(value, (dict, list)): value = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    return bounded_string(value, limit)

def content_text(value):
    # Provider content arrays contain prose plus attachments. Project only
    # their documented text fields, never JSON-serialize the container into
    # a conversation bubble or tool output.
    if isinstance(value, str): return value
    if isinstance(value, list):
        return "\n".join(text for item in value[:64] if isinstance(item, (str, dict)) for text in [content_text(item)] if text)
    if isinstance(value, dict):
        return content_text(value.get("text") or value.get("thinking") or value.get("content") or "")
    return ""

def claude_narration_signature(signature):
    # The native host never classifies a signature it may have clipped.
    if not isinstance(signature, str) or not signature or len(signature) >= 16384: return False
    # atob accepts ASCII whitespace (not a vertical tab) and optional padding.
    # Reject every other spelling before decoding.
    clean = "".join(char for char in signature if char not in " \t\n\r\f")
    if not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", clean): return False
    body = clean.rstrip("=")
    pads = len(clean) - len(body)
    if len(body) % 4 == 1 or (pads and (len(clean) % 4 or len(body) % 4 != 4 - pads)): return False
    try: data = base64.b64decode(body + "=" * ((-len(body)) % 4), validate=True)
    except (ValueError, base64.binascii.Error): return False

    def last_bytes(data, wanted):
        pos, found = 0, None
        def varint(pos):
            value = 0
            for index in range(10):
                if pos >= len(data): return None
                byte = data[pos]; pos += 1
                if index == 9 and byte & 0xfe: return None
                value |= (byte & 127) << (7 * index)
                if not byte & 128: return value, pos
            return None
        while pos < len(data):
            key = varint(pos)
            if key is None: return None
            field, wire, pos = key[0] >> 3, key[0] & 7, key[1]
            if wire == 0:
                value = varint(pos)
                if value is None: return None
                pos = value[1]
            elif wire in (1, 5):
                width = 8 if wire == 1 else 4
                if width > len(data) - pos: return None
                pos += width
            elif wire == 2:
                length = varint(pos)
                if length is None or length[0] > len(data) - length[1]: return None
                pos = length[1]
                if field == wanted: found = data[pos:pos + length[0]]
                pos += length[0]
            else: return None
        return found

    second = last_bytes(data, 2)
    first = last_bytes(second, 1) if second is not None else None
    kind = last_bytes(first, 8) if first is not None else None
    return kind is not None and kind.decode("utf-8", "replace") == "narration"

CLAUDE_TRIM_SPACE = " \t\n\v\f\r\u00a0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a\u2028\u2029\u202f\u205f\u3000\ufeff"

def normalized_blocks(content, claude=False, evicted=None):
    if isinstance(content, str): content = [{"type":"text","text":content}]
    if not isinstance(content, list): content = [content]
    # Responses input_text arrays may be token-sized fragments of one user
    # input. Like the native host, join adjacent fragments exactly, with no
    # invented separators, before applying the block limit.
    joined = []
    for item in content:
        if isinstance(item, dict) and item.get("type") == "input_text" and isinstance(item.get("text"), str):
            if joined and joined[-1][0]: joined[-1][1].append(item["text"])
            else: joined.append((True, [item["text"]]))
        else: joined.append((False, item))
    content = [{"type":"text","text":"".join(value)} if fragments else value for fragments, value in joined]
    result = []
    for item in content:
        if isinstance(item, str): item = {"type":"text","text":item}
        if not isinstance(item, dict): continue
        # A non-string discriminator is not a new block kind; the native host
        # reads it as absent. It must not fail the whole record.
        kind = item.get("type") if isinstance(item.get("type"), str) and item.get("type") else "text"
        if claude and len(result) >= 64:
            # A dropped block shortens the record; the caller reports it.
            if evicted is not None: evicted[0] = True
            prose = kind in {"text", "input_text", "output_text"} or (kind == "thinking" and
                claude_narration_signature(item.get("signature")) and isinstance(item.get("thinking"), str) and item["thinking"].strip(CLAUDE_TRIM_SPACE))
            if not prose: continue
            victim = next((index for index, block in enumerate(result) if block["type"] not in {"text", "compact-summary"}), 0)
            result.pop(victim)
        if kind in {"text", "input_text", "output_text"}:
            value, cut = preview(item.get("text", "")); result.append({"type":"text","text":value,"truncated":cut})
        elif kind in {"thinking", "reasoning"}:
            value, cut = preview(content_text(item.get("thinking") or item.get("text") or item.get("summary") or ""))
            narration = claude and kind == "thinking" and isinstance(item.get("thinking"), str) and claude_narration_signature(item.get("signature"))
            if value and (not narration or item["thinking"].strip(CLAUDE_TRIM_SPACE)):
                result.append({"type":"text" if narration else "thinking","text":value,"truncated":cut})
        elif kind in {"tool_use", "function_call", "custom_tool_call"}:
            value, cut = preview(item.get("input") or item.get("arguments") or ""); result.append({"type":"tool_call","name":str(item.get("name") or "Tool")[:256],"preview":value,"truncated":cut})
        elif kind in {"tool_result", "function_call_output", "custom_tool_call_output"}:
            value, cut = preview(content_text(item.get("content") or item.get("output") or "")); result.append({"type":"tool_result","preview":value,"truncated":cut})
        elif kind == "attachment":
            result.append({"type":"attachment","name":str(item.get("name") or "attachment")[:512],"mediaType":str(item.get("media_type") or item.get("mime_type") or "")[:128]})
        elif kind == "image":
            result.append({"type":"attachment","name":"Image","mediaType":"image"})
        elif kind == "input_image" and isinstance(item.get("image_url"), str) and (item["image_url"] == "tessera:image" or (item["image_url"].startswith("data:image/") and ";base64," in item["image_url"][:128])):
            result.append({"type":"attachment","name":"Image","mediaType":"image"})
        else:
            result.append({"type":"unknown","sourceType":str(kind)[:128]})
        if len(result) >= 64 and not claude: break
    return result

def claude_record(source, truncated):
    source_type = source.get("type") or "unknown"
    if source_type in {"user", "assistant", "system"}:
        message = source.get("message") if isinstance(source.get("message"), dict) else {}
        content = message.get("content", source.get("content", source.get("text", "")))
        role = "system" if source.get("isMeta") is True else message.get("role") or source_type
        if isinstance(content, str) and content.lstrip().startswith(("<local-command-caveat>", "<command-name>", "<local-command-stdout>", "<task-notification>")):
            role = "system"
        evicted = [False]
        blocks = normalized_blocks(content, claude=True, evicted=evicted)
        truncated = truncated or evicted[0]
        if role == "user" and blocks and all(block.get("type") == "tool_result" for block in blocks): role = "tool"
        # Claude replays the summary of a compacted conversation as a `user`
        # record carrying `isCompactSummary`. The human never typed it, so it
        # must not become a user bubble, an opening prompt, or a title seed.
        # It marks where the compaction happened, and its own block type keeps
        # that visible without impersonating either speaker.
        compacted = source.get("isCompactSummary") is True
        if compacted:
            role = "system"
            blocks = [dict(block, type="compact-summary") if block.get("type") == "text" else block for block in blocks]
        result = {"type":"message","provider":"claude","role":role,"blocks":blocks,"isMeta":source.get("isMeta") is True,"truncated":truncated}
        if compacted: result["isCompactSummary"] = True
        if source_type == "system" and source.get("subtype") == "compact_boundary": result["subtype"] = "compact_boundary"
        result["model"] = message.get("model") or source.get("model")
        # Match native Claude occupancy, including both cache families. Keep
        # malformed, child and synthetic usage from replacing main context.
        payload = source.get("payload") if isinstance(source.get("payload"), dict) else {}
        origin = payload.get("source")
        main = (source_type == "assistant" and source.get("isSidechain") is not True and
                source.get("isMeta") is not True and source.get("isSubagent") is not True and
                payload.get("isSidechain") is not True and not (isinstance(origin, dict) and origin.get("subagent") is not None) and
                source.get("teamName") in (None, "") and
                ("uuid" not in source or (isinstance(source["uuid"], str) and 0 < len(source["uuid"].encode()) <= 256)) and
                (source.get("parentUuid") is None or (isinstance(source["parentUuid"], str) and len(source["parentUuid"].encode()) <= 256)) and
                all(key not in source or type(source[key]) is bool for key in ("isSidechain", "isMeta")))
        usage = message.get("usage")
        if main and isinstance(usage, dict) and message.get("model") != "<synthetic>":
            counts = [usage[key] for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens") if key in usage]
            if all(type(count) is int and count >= 0 for count in counts):
                tokens = sum(counts)
                if 0 < tokens <= (1 << 53) - 1: result["used_tokens"] = tokens
    elif source_type == "ai-title":
        # Claude names this field `aiTitle`; `title`/`text` never appear. The
        # old fallback turned every real title into the string "Untitled".
        title = source.get("aiTitle") or source.get("title") or source.get("text")
        result = {"type":"ai-title","provider":"claude","truncated":truncated}
        if title: result["title"] = title
    elif source_type == "attachment":
        # Standalone Claude attachments are injected provider context (model,
        # tools, environment, token reminders), not user file attachments. The
        # exception is a prompt the human typed while a turn was running:
        # Claude persists it as a `queued_command`, never as a `user` record.
        # Peer, task-notification and meta commands remain provider context.
        attachment = source.get("attachment")
        kind = attachment.get("type") if isinstance(attachment, dict) else "context"
        if (isinstance(attachment, dict) and kind == "queued_command" and
                attachment.get("commandMode", "prompt") == "prompt" and attachment.get("isMeta") is not True and
                ("origin" not in attachment or (isinstance(attachment["origin"], dict) and attachment["origin"].get("kind") == "human")) and
                isinstance(attachment.get("prompt"), (str, list))):
            evicted = [False]
            blocks = normalized_blocks(attachment["prompt"], claude=True, evicted=evicted)
            truncated = truncated or evicted[0]
            role = "tool" if blocks and all(block.get("type") == "tool_result" for block in blocks) else "user"
            result = {"type":"message", "provider":"claude", "role":role,
                      "blocks":blocks, "isMeta":False, "truncated":truncated}
        else:
            result = {"type":"system", "provider":"claude", "text":"Provider context: " + str(kind or "context")[:128], "truncated":truncated}
    elif source_type in {"permission-mode", "mode", "queue-operation", "cost-state"}:
        result = dict(source); result["provider"] = "claude"; result["truncated"] = truncated
    else:
        value, cut = preview(source.get("text") or source.get("content") or "")
        result = {"type":str(source_type)[:64],"provider":"claude","text":value,"truncated":bool(truncated or cut)}
    result["timestamp"] = source.get("timestamp")
    result["sessionID"] = source.get("sessionId") or source.get("session_id")
    result["turnID"] = source.get("uuid") or source.get("turn_id")
    result["branch"] = source.get("gitBranch") or source.get("branch")
    cwd = source.get("cwd")
    if isinstance(cwd, str): result["project"] = os.path.basename(cwd.rstrip("/"))
    result["permissionMode"] = source.get("permission_mode") or source.get("permissionMode")
    return {key:value for key,value in result.items() if value is not None}

def codex_record(source, truncated):
    envelope = source.get("type") or "unknown"
    payload = source.get("payload") if isinstance(source.get("payload"), dict) else {}
    payload_type = payload.get("type") or envelope
    if envelope == "response_item":
        if payload_type in {"user_message", "agent_message", "message"}:
            role = payload.get("role") or ("user" if payload_type == "user_message" else "assistant")
            content = payload.get("content", payload.get("message", payload.get("text", "")))
            metadata = payload.get("internal_chat_message_metadata_passthrough")
            kinds = metadata.get("content_item_kinds") if isinstance(metadata, dict) else None
            if role == "user" and isinstance(kinds, list) and kinds:
                if isinstance(content, list) and len(content) == len(kinds):
                    human = [item for item, kind in zip(content, kinds) if isinstance(kind, str) and kind.startswith("user.")]
                    if human: content = human
                    else: role = "system"
                elif not any(isinstance(kind, str) and kind.startswith("user.") for kind in kinds):
                    role = "system"
            result = {"type":"message","provider":"codex","role":role,"blocks":normalized_blocks(content),"truncated":truncated}
        elif payload_type in {"reasoning"}:
            result = {"type":"message","provider":"codex","role":"assistant","blocks":normalized_blocks([{"type":"thinking","text":payload.get("text") or payload.get("summary") or ""}]),"truncated":truncated}
        elif payload_type in {"custom_tool_call", "function_call"}:
            result = {"type":"message","provider":"codex","role":"tool","blocks":normalized_blocks([{"type":"tool_use","name":payload.get("name"),"input":payload.get("arguments") or payload.get("input")}]),"truncated":truncated}
        elif payload_type in {"custom_tool_call_output", "function_call_output"}:
            result = {"type":"message","provider":"codex","role":"tool","blocks":normalized_blocks([{"type":"tool_result","output":payload.get("output") or payload.get("content")}]),"truncated":truncated}
        else: result = {"type":"unknown","provider":"codex","sourceType":str(payload_type)[:128],"truncated":truncated}
    elif envelope == "event_msg" and payload_type in {"task_complete", "task_completed"}:
        value, cut = preview(payload.get("last_agent_message") or payload.get("message") or "")
        result = {"type":"completion","provider":"codex","summary":value,"truncated":bool(truncated or cut)}
    elif envelope == "event_msg" and payload_type == "token_count":
        info = payload.get("info") if isinstance(payload.get("info"), dict) else payload
        # Total usage accumulates every request in a turn; cached input and
        # reasoning are subsets, not extra context. The most recent request
        # is the provider evidence for current context-window occupancy.
        usage = info.get("last_token_usage") or info.get("total_token_usage") or info
        if not isinstance(usage, dict): usage = {}
        used = int(usage.get("input_tokens") or 0) + int(usage.get("output_tokens") or 0)
        result = {"type":"cost-state","provider":"codex","used_tokens":used,"max_tokens":info.get("model_context_window"),"model":info.get("model"),"truncated":truncated}
    elif envelope in {"session_meta", "turn_context"}:
        cwd = payload.get("cwd")
        git = payload.get("git") if isinstance(payload.get("git"), dict) else {}
        # `session_meta` is the first line of a rollout and the only one
        # carrying the session id, so this is where the title can be attached.
        # `turn_context` repeats through the file and has no id.
        title = codex_title(payload.get("session_id") or payload.get("id")) if envelope == "session_meta" else None
        result = {"type":envelope,"provider":"codex","title":title,"project":os.path.basename(cwd.rstrip("/")) if isinstance(cwd,str) else None,"branch":git.get("branch") or payload.get("branch"),"model":payload.get("model"),"permissionMode":payload.get("approval_policy"),"truncated":truncated}
    else:
        result = {"type":"unknown","provider":"codex","sourceType":str(payload_type)[:128],"truncated":truncated}
    result["timestamp"] = source.get("timestamp")
    return {key:value for key,value in result.items() if value is not None}

def kimi_record(source, truncated):
    envelope = str(source.get("type") or "unknown")
    if envelope == "turn.prompt":
        result = {"type":"message","provider":"kimi","role":"user","blocks":normalized_blocks(source.get("input") or ""),"truncated":truncated}
    elif envelope == "context.append_message":
        message = source.get("message") if isinstance(source.get("message"), dict) else {}
        result = {"type":"message","provider":"kimi","role":message.get("role") or "user","blocks":normalized_blocks(message.get("content") or ""),"truncated":truncated}
    elif envelope == "context.append_loop_event":
        event = source.get("event") if isinstance(source.get("event"), dict) else {}
        event_type = str(event.get("type") or "unknown")
        if event_type == "content.part":
            part = event.get("part") if isinstance(event.get("part"), dict) else {}
            kind = part.get("type")
            block = {"type":"thinking" if kind == "think" else "text","text":part.get("think") if kind == "think" else part.get("text", "")}
            result = {"type":"message","provider":"kimi","role":"assistant","blocks":normalized_blocks([block]),"truncated":truncated}
        elif event_type == "tool.call":
            result = {"type":"message","provider":"kimi","role":"tool","blocks":normalized_blocks([{"type":"tool_use","name":event.get("name"),"input":event.get("args") or ""}]),"truncated":truncated}
        elif event_type == "tool.result":
            tool_result = event.get("result") if isinstance(event.get("result"), dict) else {}
            result = {"type":"message","provider":"kimi","role":"tool","blocks":normalized_blocks([{"type":"tool_result","output":tool_result.get("output") or "","is_error":tool_result.get("isError") is True}]),"truncated":truncated}
        elif event_type == "step.end":
            usage = event.get("usage") if isinstance(event.get("usage"), dict) else {}
            used = sum(int(usage.get(key) or 0) for key in ("inputOther", "inputCacheRead", "inputCacheCreation", "output"))
            result = {"type":"cost-state","provider":"kimi","used_tokens":used,"truncated":truncated}
        else:
            result = {"type":"unknown","provider":"kimi","sourceType":event_type[:128],"truncated":truncated}
    elif envelope == "usage.record":
        usage = source.get("usage") if isinstance(source.get("usage"), dict) else {}
        used = sum(int(usage.get(key) or 0) for key in ("inputOther", "inputCacheRead", "inputCacheCreation", "output"))
        result = {"type":"cost-state","provider":"kimi","used_tokens":used,"model":source.get("model"),"truncated":truncated}
    elif envelope == "config.update":
        result = {"type":"metadata","provider":"kimi","model":source.get("modelAlias"),"truncated":truncated}
    elif envelope == "permission.set_mode":
        result = {"type":"permission-mode","provider":"kimi","mode":source.get("mode"),"truncated":truncated}
    elif envelope == "turn.cancel":
        result = {"type":"completion","provider":"kimi","summary":"Cancelled","truncated":truncated}
    else:
        result = {"type":"unknown","provider":"kimi","sourceType":envelope[:128],"truncated":truncated}
    result["timestamp"] = source.get("time") or source.get("created_at")
    return {key:value for key,value in result.items() if value is not None}

def normalized(provider, raw, truncated):
    try: source = json.loads(raw.decode("utf-8"))
    except Exception:
        return {"type":"unknown","provider":provider,"truncated":truncated,"malformed":True}
    if not isinstance(source, dict): return {"type":"unknown","provider":provider,"truncated":truncated,"malformed":True}
    try:
        if provider == "claude": record = claude_record(source, truncated)
        elif provider == "codex": record = codex_record(source, truncated)
        elif provider == "kimi": record = kimi_record(source, truncated)
        else: record = {"type":"unknown","provider":provider,"truncated":truncated}
    except (TypeError, ValueError, OverflowError, RecursionError):
        # One legacy/unsupported record must not hide a whole live thread.
        # Ownership/path/identity failures are checked outside normalization
        # and are deliberately not swallowed here.
        return {"type":"unknown","provider":provider,"truncated":truncated,"malformed":True}
    payload = source.get("payload") if isinstance(source.get("payload"), dict) else {}
    origin = payload.get("source") or source.get("source")
    if source.get("isSidechain") is True or source.get("isSubagent") is True or payload.get("isSidechain") is True or (isinstance(origin, dict) and "subagent" in origin):
        record["isSidechain"] = True
        # Child content remains inspectable, but it cannot set the main
        # agent header, context meter, cost, branch, or permission mode.
        for key in ("model", "title", "project", "branch", "permissionMode", "used_tokens", "max_tokens", "context_percent", "totalCostUSD", "cost"):
            record.pop(key, None)
    return record

def projection_record_id(identity, position, record):
    # The page/cursor identity still changes on append for source validation.
    # Presentation IDs use the file identity and record content, so appending
    # a token does not destroy and recreate every existing native view.
    file_identity = ":".join(identity.split(":")[:-2])
    content = json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256((file_identity + ":" + str(position) + ":" + content).encode("utf-8")).hexdigest()[:32]

def record_search_text(record):
    # Search operates on the canonical projection, never its JSON envelope.
    # That keeps roles, source types, and provider bookkeeping out of iOS
    # excerpts while still making prose and tool evidence discoverable.
    if not isinstance(record, dict): return None
    kind = record.get("type")
    if kind == "message":
        if record.get("isMeta") is True or record.get("role") in {"system", "developer"}: return None
        blocks = record.get("blocks")
        if not isinstance(blocks, list): return None
        values = []
        for block in blocks[:64]:
            if not isinstance(block, dict): continue
            block_type = block.get("type")
            if block_type in {"text", "thinking"}:
                value = content_text(block.get("text"))
                if value: values.append(value)
            elif block_type in {"tool_call", "tool_result"}:
                for field in ("preview", "input", "output", "text"):
                    value = content_text(block.get(field))
                    if value: values.append(value)
        text, _ = bounded_string("\n".join(values), MAX_PREFIX)
        return text or None
    if kind == "completion":
        text, _ = bounded_string(content_text(record.get("summary")), MAX_PREFIX)
        return text or None
    if kind in {"session-title", "ai-title"}:
        text, _ = bounded_string(content_text(record.get("title")), MAX_PREFIX)
        return text or None
    return None

def pi_blocks(content):
    if isinstance(content, str): content = [{"type":"text", "text":content}]
    if not isinstance(content, list): return []
    blocks = []
    for item in content[:64]:
        if not isinstance(item, dict): continue
        kind = item.get("type")
        if kind == "text":
            text, cut = preview(item.get("text") or "")
            blocks.append({"type":"text", "text":text, "truncated":cut})
        elif kind == "thinking":
            text, cut = preview(item.get("thinking") or item.get("text") or "")
            blocks.append({"type":"thinking", "text":text, "truncated":cut})
        elif kind == "toolCall":
            name, name_cut = bounded_string(item.get("name") or "Tool", 256)
            arguments, cut = preview(item.get("arguments") or "")
            blocks.append({"type":"tool_call", "name":name, "preview":arguments, "truncated":bool(name_cut or cut)})
        elif kind == "image":
            blocks.append({"type":"attachment", "name":"image", "mediaType":str(item.get("mimeType") or "")[:128]})
        else:
            blocks.append({"type":"unknown", "sourceType":str(kind or "unknown")[:128]})
    return blocks

def pi_record(session_id, index, source):
    if not isinstance(source, dict): raise ProjectionError("adapterOutdated")
    role = source.get("role")
    if not isinstance(role, str) or len(role.encode()) > 64: raise ProjectionError("adapterOutdated")
    record = {"provider":"pi", "sessionID":session_id}
    if role in {"user", "assistant", "system"}:
        record.update({"type":"message", "role":role, "blocks":pi_blocks(source.get("content"))})
        model = source.get("model")
        if isinstance(model, str): record["model"], _ = bounded_string(model, 256)
    elif role == "toolResult":
        name, name_cut = bounded_string(source.get("toolName") or "Tool", 256)
        content = pi_blocks(source.get("content"))
        # A tool result has no separate provider message text; expose only a
        # bounded preview of its documented text blocks.
        previews = [block.get("text", "") for block in content if block.get("type") == "text"]
        preview, cut = preview("\n".join(previews))
        record.update({"type":"message", "role":"tool", "blocks":[{"type":"tool_result", "name":name, "preview":preview, "truncated":bool(name_cut or cut or source.get("isError") is True)}]})
    elif role in {"branchSummary", "compactionSummary"}:
        summary, cut = preview(source.get("summary") or "")
        record.update({"type":"metadata", "summary":summary, "truncated":cut})
    else:
        record.update({"type":"unknown", "sourceType":"pi-role-" + role[:96]})
    timestamp = source.get("timestamp")
    if isinstance(timestamp, str): record["timestamp"], _ = bounded_string(timestamp, 128)
    return record

def pi_cursor_decode(value, identity, session_id):
    if value is None: return 0
    try:
        decoded = json.loads(base64.urlsafe_b64decode(value + "=" * ((4 - len(value) % 4) % 4)))
        index = int(decoded["index"])
        if decoded.get("identity") != identity or decoded.get("session") != session_id or index < 0: raise ProjectionError("sourceChanged")
        return index
    except ProjectionError: raise
    except Exception: raise ProjectionError("malformed")

def pi_cursor_encode(identity, session_id, index):
    raw = json.dumps({"identity":identity, "session":session_id, "index":index}, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=").replace("=", "")

def pi_inventory(request):
    root = pi_sessions_root()
    deadline = time.monotonic() + MAX_INVENTORY_SECONDS
    candidates = []
    directories = 0; files_seen = 0
    try:
        root_stat = os.lstat(root)
    except FileNotFoundError: raise ProjectionError("sourceMissing")
    except OSError: raise ProjectionError("permissionDenied")
    if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid != os.getuid():
        raise ProjectionError("permissionDenied")
    for base, dirs, files in os.walk(root, followlinks=False):
        directories += 1
        if directories > MAX_INVENTORY_DIRECTORIES or time.monotonic() >= deadline: raise ProjectionError("channelUnavailable")
        depth = len(os.path.relpath(base, root).split(os.sep)) if base != root else 0
        if depth > 1:
            dirs[:] = []
            continue
        dirs[:] = [name for name in dirs if depth == 0 and PI_SESSION_COMPONENT.fullmatch(name) is not None and not os.path.islink(os.path.join(base, name))]
        for name in files:
            files_seen += 1
            if files_seen > MAX_INVENTORY_FILES or time.monotonic() >= deadline: raise ProjectionError("channelUnavailable")
            if not name.endswith(".jsonl") or PI_SESSION_COMPONENT.fullmatch(name) is None: continue
            relative = os.path.relpath(os.path.join(base, name), root)
            try:
                relative = pi_relative_path(relative)
                _, state, _, source_stat = pi_load_session(relative, False, deadline)
            except ProjectionError: raise
            except OSError: raise ProjectionError("permissionDenied")
            candidates.append((source_stat.st_mtime_ns, relative, source_stat.st_size, state["sessionID"]))
    if not candidates: raise ProjectionError("sourceMissing")
    candidates.sort(key=lambda item: (item[0], item[1]), reverse=True)
    inventory_identity = hashlib.sha256(json.dumps(candidates, separators=(",", ":")).encode()).hexdigest()
    offset = inventory_cursor_decode(request.get("cursor"), "pi", inventory_identity)
    if offset > len(candidates): raise ProjectionError("sourceChanged")
    limit = min(max(int(request.get("limitRecords", MAX_RECORDS)), 1), MAX_RECORDS)
    page = candidates[offset:offset + limit]
    state = [0]
    for sequence, (modified, relative, size, session_id) in enumerate(page):
        emit({"v":1,"kind":"inventory","sequence":sequence,"provider":"pi","providerSessionID":session_id,"transcriptRef":pi_session_ref(relative),"lastActivityNs":modified,"size":size}, state)
    next_offset = offset + len(page)
    emit({"v":1,"kind":"end","cursor":inventory_cursor_encode("pi", inventory_identity, next_offset),"hasMore":next_offset<len(candidates),"warnings":[]}, state)

def pi_project(request):
    relative = decode_pi_session_ref(request.get("transcriptRef"))
    identity, state_info, messages, _ = pi_load_session(relative, True, time.monotonic() + MAX_PI_RPC_SECONDS)
    session_id = state_info["sessionID"]
    index = pi_cursor_decode(request.get("cursor"), identity, session_id)
    if index > len(messages): raise ProjectionError("sourceChanged")
    limit_bytes = min(max(int(request.get("limitBytes", MAX_PAGE)), 1), MAX_PAGE)
    limit_records = min(max(int(request.get("limitRecords", MAX_RECORDS)), 1), MAX_RECORDS)
    output = [0]
    start = pi_cursor_encode(identity, session_id, index)
    emit({"v":1,"kind":"page","sourceIdentity":identity,"from":start,"to":None}, output)
    count = 0; current = index
    # Sequence 0 is reserved for the session title on every pi source, named or
    # not, so message N always lands on sequence N+1. A slot that shifted with
    # the presence of a name would renumber the whole transcript the moment a
    # reader typed /name, and the reducer would reject the next page.
    if index == 0 and state_info.get("sessionName"):
        title_record = {"type":"session-title", "provider":"pi", "sessionID":session_id, "title":state_info["sessionName"]}
        emit({"v":1,"kind":"record","sequence":0,"recordID":"pi-title-" + projection_record_id(identity, "title", title_record),"record":title_record}, output)
    for position, message in enumerate(messages[index:], start=index):
        record = pi_record(session_id, position, message)
        frame = {"v":1,"kind":"record","sequence":position + 1,"recordID":"pi-" + projection_record_id(identity, position, record),"record":record}
        encoded = json.dumps(frame, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if count and (output[0] + len(encoded) + 256 > limit_bytes or count >= limit_records): break
        emit(frame, output)
        count += 1; current = position + 1
        if output[0] >= limit_bytes or count >= limit_records: break
    emit({"v":1,"kind":"end","cursor":pi_cursor_encode(identity, session_id, current),"hasMore":current < len(messages),"warnings":[]}, output)

def pi_search(request):
    query, was_truncated = bounded_string(request.get("query", ""), MAX_QUERY)
    if not query: raise ProjectionError("malformed")
    relative = decode_pi_session_ref(request.get("transcriptRef"))
    identity, state_info, messages, _ = pi_load_session(relative, True, time.monotonic() + MAX_PI_RPC_SECONDS)
    state = [0]; count = 0
    limit = min(max(int(request.get("limitRecords", MAX_RECORDS)), 1), MAX_RECORDS)
    for index, message in enumerate(messages):
        record = pi_record(state_info["sessionID"], index, message)
        haystack = record_search_text(record)
        if not haystack: continue
        position = haystack.casefold().find(query.casefold())
        if position < 0: continue
        excerpt, cut = bounded_string(haystack[max(0, position - 128):position + len(query) + 384], 1024)
        emit({"v":1,"kind":"searchResult","sourceIdentity":identity,"recordID":"pi-" + projection_record_id(identity, index, record),"excerpt":excerpt,"truncated":bool(record.get("truncated") or cut or was_truncated)}, state)
        count += 1
        if count >= limit: break
    emit({"v":1,"kind":"end","cursor":None,"hasMore":False,"warnings":[]}, state)

def opencode_record(session_id, part_id, message_data, part_data, truncated):
    # Storage payloads are provider data. Only the small documented part
    # vocabulary becomes a UI record; a future type remains visibly unknown.
    try:
        message = json.loads(message_data)
        part = json.loads(part_data)
    except Exception:
        return {"type":"unknown","provider":"opencode","sessionID":session_id,"truncated":True,"malformed":True}
    if not isinstance(message, dict) or not isinstance(part, dict):
        return {"type":"unknown","provider":"opencode","sessionID":session_id,"truncated":True,"malformed":True}
    kind = part.get("type")
    if not isinstance(kind, str) or not kind or len(kind.encode()) > 128:
        return {"type":"unknown","provider":"opencode","sessionID":session_id,"truncated":True,"malformed":True}
    role = message.get("role") if isinstance(message.get("role"), str) else "assistant"
    role, role_cut = bounded_string(role, 32)
    if kind == "text":
        text, cut = preview(part.get("text") or "")
        result = {"type":"message","provider":"opencode","sessionID":session_id,"role":role,"blocks":[{"type":"text","text":text,"truncated":cut}],"truncated":bool(truncated or role_cut or cut)}
    elif kind == "reasoning":
        text, cut = preview(part.get("text") or "")
        result = {"type":"message","provider":"opencode","sessionID":session_id,"role":"assistant","blocks":[{"type":"thinking","text":text,"truncated":cut}],"truncated":bool(truncated or cut)}
    elif kind in {"tool", "tool_result"}:
        name, name_cut = bounded_string(part.get("tool") or part.get("name") or "Tool", 256)
        output, cut = preview(part.get("output") or part.get("text") or "")
        block = {"type":"tool_call" if kind == "tool" else "tool_result","name":name,"preview":output,"truncated":bool(name_cut or cut)}
        result = {"type":"message","provider":"opencode","sessionID":session_id,"role":"tool","blocks":[block],"truncated":bool(truncated or name_cut or cut)}
    elif kind == "step-finish":
        summary, cut = preview(part.get("reason") or "")
        result = {"type":"completion","provider":"opencode","sessionID":session_id,"summary":summary,"truncated":bool(truncated or cut)}
    elif kind == "step-start":
        result = {"type":"metadata","provider":"opencode","sessionID":session_id,"truncated":truncated}
    else:
        result = {"type":"unknown","provider":"opencode","sessionID":session_id,"sourceType":kind,"truncated":truncated}
    timestamp = part.get("time")
    if timestamp is not None: result["timestamp"] = timestamp
    return result

def opencode_search_text(data):
    try: part = json.loads(data)
    except Exception: return None
    if not isinstance(part, dict): return None
    kind = part.get("type")
    if kind in {"text", "reasoning"}:
        value = part.get("text")
    elif kind in {"tool", "tool_result"}:
        value = part.get("output") or part.get("text")
    elif kind == "step-finish":
        value = part.get("reason")
    else:
        return None
    text, _ = bounded_string(content_text(value), MAX_PREFIX)
    return text or None

def opencode_project(request):
    session_id = decode_opencode_session_ref(request.get("transcriptRef"))
    database, descriptor, identity, snapshot_dir, verified_sources = open_opencode_database()
    try:
        exists = database.execute("SELECT title FROM session WHERE id = ? LIMIT 1", (session_id,)).fetchone()
        if exists is None: raise ProjectionError("sourceMissing")
        created, part_id, sequence = opencode_cursor_decode(request.get("cursor"), identity, session_id)
        limit_bytes = min(max(int(request.get("limitBytes", MAX_PAGE)), 1), MAX_PAGE)
        limit_records = min(max(int(request.get("limitRecords", MAX_RECORDS)), 1), MAX_RECORDS)
        state = [0]
        start = opencode_cursor_encode(identity, session_id, created, part_id, sequence)
        emit({"v":1,"kind":"page","sourceIdentity":identity,"from":start,"to":None}, state)
        # opencode writes its own session title and keeps it on the session row,
        # never in the part stream, so it is emitted once at the head of the
        # first page. The running sequence absorbs it, which keeps the reducer
        # contiguity rule satisfied without renumbering later pages.
        if created == 0 and not part_id and isinstance(exists[0], str) and exists[0].strip():
            opencode_title, _ = bounded_string(exists[0].strip(), 512)
            title_record = {"type":"session-title", "provider":"opencode", "sessionID":session_id, "title":opencode_title}
            emit({"v":1,"kind":"record","sequence":sequence,"recordID":"opencode-title-" + session_id,"record":title_record}, state)
            sequence += 1
        rows = database.execute(
            "SELECT p.id,p.time_created,length(CAST(m.data AS BLOB)),substr(CAST(m.data AS BLOB),1,?),length(CAST(p.data AS BLOB)),substr(CAST(p.data AS BLOB),1,?) FROM part p JOIN message m ON m.id=p.message_id AND m.session_id=p.session_id WHERE p.session_id=? AND (p.time_created>? OR (p.time_created=? AND p.id>?)) ORDER BY p.time_created,p.id LIMIT ?",
            (MAX_PREFIX, MAX_PREFIX, session_id, created, created, part_id, limit_records + 1)
        ).fetchall()
        count = 0
        current_created, current_part = created, part_id
        has_more = len(rows) > limit_records
        for row in rows[:limit_records]:
            candidate_id, candidate_created, message_size, message_data, part_size, part_data = row
            if not isinstance(candidate_id, str) or OPENCODE_SESSION.fullmatch(candidate_id) is None or not isinstance(candidate_created, int) or not isinstance(message_size, int) or not isinstance(part_size, int) or message_size < 0 or part_size < 0:
                raise ProjectionError("adapterOutdated")
            record = opencode_record(session_id, candidate_id, message_data, part_data, message_size > MAX_PREFIX or part_size > MAX_PREFIX)
            frame = {"v":1,"kind":"record","sequence":sequence,"recordID":"opencode-" + candidate_id,"record":record}
            encoded = json.dumps(frame, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            if count and state[0] + len(encoded) + 256 > limit_bytes:
                has_more = True; break
            emit(frame, state)
            count += 1; sequence += 1; current_created, current_part = candidate_created, candidate_id
            if state[0] >= limit_bytes: has_more = True; break
        cursor = opencode_cursor_encode(identity, session_id, current_created, current_part, sequence)
        emit({"v":1,"kind":"end","cursor":cursor,"hasMore":has_more,"warnings":[]}, state)
    finally:
        close_opencode_database(database, descriptor, identity, snapshot_dir, verified_sources)

def opencode_inventory(request):
    database, descriptor, identity, snapshot_dir, verified_sources = open_opencode_database()
    try:
        # Inventory exposes only thread identity/activity metadata, never the
        # database directory, title, or transcript payload.
        offset = inventory_cursor_decode(request.get("cursor"), "opencode", identity)
        limit = min(max(int(request.get("limitRecords", MAX_RECORDS)), 1), MAX_RECORDS)
        rows = database.execute("SELECT id,time_updated FROM session WHERE time_archived IS NULL ORDER BY time_updated DESC,id DESC LIMIT ? OFFSET ?", (limit + 1, offset)).fetchall()
        state = [0]
        page = rows[:limit]
        for sequence, row in enumerate(page):
            session_id, updated = row
            if not isinstance(session_id, str) or OPENCODE_SESSION.fullmatch(session_id) is None or not isinstance(updated, int):
                raise ProjectionError("adapterOutdated")
            emit({"v":1,"kind":"inventory","sequence":sequence,"provider":"opencode","providerSessionID":session_id,"transcriptRef":opencode_session_ref(session_id),"lastActivityNs":updated,"size":0}, state)
        next_offset = offset + len(page)
        emit({"v":1,"kind":"end","cursor":inventory_cursor_encode("opencode", identity, next_offset),"hasMore":len(rows)>limit,"warnings":[]}, state)
    finally:
        close_opencode_database(database, descriptor, identity, snapshot_dir, verified_sources)

def opencode_search(request):
    query, was_truncated = bounded_string(request.get("query", ""), MAX_QUERY)
    if not query: raise ProjectionError("malformed")
    session_id = decode_opencode_session_ref(request.get("transcriptRef"))
    database, descriptor, identity, snapshot_dir, verified_sources = open_opencode_database()
    try:
        # Parameter binding keeps a search string from becoming SQLite syntax.
        rows = database.execute("SELECT id,substr(CAST(data AS BLOB),1,?) FROM part WHERE session_id=? AND data LIKE ? ORDER BY time_created,id LIMIT ?", (MAX_PREFIX, session_id, "%" + query + "%", min(int(request.get("limitRecords", MAX_RECORDS)), MAX_RECORDS))).fetchall()
        state = [0]
        for part_id, data in rows:
            if not isinstance(part_id, str) or OPENCODE_SESSION.fullmatch(part_id) is None or not isinstance(data, bytes):
                raise ProjectionError("adapterOutdated")
            text = opencode_search_text(data)
            if not text: continue
            position = text.casefold().find(query.casefold())
            if position < 0: continue
            excerpt, cut = bounded_string(text[max(0, position - 128):position + len(query) + 384], 1024)
            emit({"v":1,"kind":"searchResult","sourceIdentity":identity,"recordID":"opencode-" + part_id,"excerpt":excerpt,"truncated":bool(cut or was_truncated)}, state)
        emit({"v":1,"kind":"end","cursor":None,"hasMore":False,"warnings":[]}, state)
    finally:
        close_opencode_database(database, descriptor, identity, snapshot_dir, verified_sources)

def update_projection_summary(summary, record):
    if record.get("isSidechain") is True: return
    for key in ("title", "model", "project", "branch", "permissionMode"):
        value = record.get(key)
        if isinstance(value, str) and value:
            summary[key], _ = bounded_string(value, 512)
    if record.get("type") == "message" and record.get("role") == "user" and not record.get("isMeta") and "openingPrompt" not in summary:
        text = "\n".join(block.get("text", "") for block in record.get("blocks", []) if block.get("type") == "text")
        if text.strip(): summary["openingPrompt"], _ = bounded_string(text, 4096)
    if record.get("type") == "cost-state":
        for key in ("used_tokens", "max_tokens", "context_percent"):
            value = record.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool): summary[key] = value

def verify_projection_prefix(descriptor, source_stat, digest):
    # Retain only bounded normalized records, not a second on-disk copy of a
    # potentially multi-gigabyte transcript. Nothing is emitted until the
    # finite prefix has been checked. Concurrent appends remain supported;
    # replacement, truncation, and rewrites of captured bytes do not.
    after = os.fstat(descriptor)
    if (after.st_dev, after.st_ino) != (source_stat.st_dev, source_stat.st_ino) or after.st_size < source_stat.st_size:
        raise ProjectionError("sourceChanged")
    if (after.st_size, after.st_mtime_ns) != (source_stat.st_size, source_stat.st_mtime_ns):
        os.lseek(descriptor, 0, os.SEEK_SET)
        check = hashlib.sha256(); remaining = source_stat.st_size
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if not chunk: raise ProjectionError("sourceChanged")
            check.update(chunk); remaining -= len(chunk)
        if check.digest() != digest.digest(): raise ProjectionError("sourceChanged")

def receipt_boundary(descriptor, provider, identity, source_stat):
    # Locate only the final complete record. Codex image data is discarded by
    # the streaming lexer; even its receipt anchor has bounded retained memory.
    size = source_stat.st_size
    cursor = size
    end = None
    start = None
    budget = 32 * 1024 * 1024 if provider == "codex" else MAX_PREFIX * 2
    while cursor and size - cursor < budget:
        count = min(8192, cursor, budget - (size - cursor))
        cursor -= count
        os.lseek(descriptor, cursor, os.SEEK_SET)
        data = os.read(descriptor, count)
        if len(data) != count: raise ProjectionError("sourceChanged")
        search_end = len(data)
        if end is None:
            marker = data.rfind(b"\n")
            if marker < 0: continue
            end = cursor + marker
            search_end = marker
        marker = data.rfind(b"\n", 0, search_end)
        if marker >= 0:
            start = cursor + marker + 1
            break
        if cursor == 0: start = 0
    if size and (start is None or end is None):
        raise ProjectionError("channelUnavailable", {"stage":"receiptBoundary", "reason":"anchorUnavailable"})
    record = None
    source_hash = [None]
    if size:
        rows = list(lines(descriptor, start, complete_only=True, end_offset=end + 1, redact_images=provider == "codex", source_hash=source_hash))
        if len(rows) != 1 or rows[0][2]:
            raise ProjectionError("channelUnavailable", {"stage":"receiptBoundary", "reason":"anchorUnavailable"})
        record = normalized(provider, rows[0][1], False)
    current = os.fstat(descriptor)
    if (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns) != (source_stat.st_dev, source_stat.st_ino, size, source_stat.st_mtime_ns):
        raise ProjectionError("sourceChanged")
    output = [0]
    emit({"v":1,"kind":"page","sourceIdentity":identity,"from":None,"to":None,"summary":{"receiptByteOffset":str(size)}}, output)
    if size:
        emit({"v":1,"kind":"record","sequence":0,"sourceOffset":start,"sourceHash":source_hash[0],"recordID":projection_record_id(identity, start, record),"record":record}, output)
    emit({"v":1,"kind":"end","cursor":None,"hasMore":False,"warnings":[]}, output)

def project(request):
    provider = request.get("provider")
    if provider == "opencode": return opencode_project(request)
    if provider == "pi": return pi_project(request)
    descriptor, identity, source_stat = validate_source(provider, request.get("transcriptRef"))
    PROJECTION_DIAGNOSTICS.update(provider=provider, stage="snapshot", sourceBytes=str(source_stat.st_size))
    try:
        if request.get("receiptBoundaryOnly") is True:
            return receipt_boundary(descriptor, provider, identity, source_stat)
        before_offset, before_sequence = cursor_decode(request.get("cursor"), identity, descriptor, source_stat) if request.get("cursor") else (source_stat.st_size, None)
        continued_from = None
        continuation = request.get("cursor") or request.get("continuationCursor")
        if continuation:
            try:
                if not request.get("cursor"):
                    cursor_decode(continuation, identity, descriptor, source_stat)
                continued_from = json.loads(base64.urlsafe_b64decode(continuation + "=" * ((4 - len(continuation) % 4) % 4)))["identity"]
            except (ProjectionError, ValueError, KeyError, TypeError):
                if request.get("cursor"): raise
                # A newest refresh can replace a rewritten file atomically.
                # Do not claim continuity when its old prefix no longer exists.
                continued_from = None
        if before_offset > source_stat.st_size: raise ProjectionError("sourceChanged")
        limit_bytes = min(max(int(request.get("limitBytes", MAX_PAGE)), 1), MAX_PAGE)
        limit_records = min(max(int(request.get("limitRecords", MAX_RECORDS)), 1), MAX_RECORDS)
        # Initial projection is the current conversation, with the cursor
        # pointing backward. Drain source records in append order with bounded
        # retained prefixes; even a multi-megabyte tool result cannot prevent
        # later messages from reaching the live view.
        retained = deque(maxlen=limit_records)
        summary = {"type":"metadata"}
        current = 0; sequence = 0
        digest = hashlib.sha256()
        source_hash = [None]
        for next_offset, raw, truncated in lines(descriptor, 0, complete_only=True, end_offset=source_stat.st_size, digest=digest, redact_images=provider == "codex", source_hash=source_hash):
            PROJECTION_DIAGNOSTICS.update(stage="normalize", recordSequence=str(sequence))
            canonical = normalized(provider, raw, truncated)
            update_projection_summary(summary, canonical)
            if next_offset <= before_offset:
                retained.append((sequence, current, canonical, source_hash[0] if not truncated else None))
            current = next_offset; sequence += 1
        verify_projection_prefix(descriptor, source_stat, digest)
        if before_sequence is not None and retained and retained[-1][0] + 1 != before_sequence:
            raise ProjectionError("sourceChanged")
        selected = []
        used = len(json.dumps(summary, ensure_ascii=False).encode("utf-8")) + 1536
        for ordinal, offset, record, source_hash in reversed(retained):
            record_id = projection_record_id(identity, offset, record)
            frame = {"v":1,"kind":"record","sequence":ordinal,"sourceOffset":offset,"sourceHash":source_hash,"recordID":record_id,"record":record}
            size = len(json.dumps(frame, ensure_ascii=False, separators=(",", ":")).encode("utf-8")) + 1
            if used + size > limit_bytes:
                if not selected: raise ProjectionError("malformed", dict(PROJECTION_DIAGNOSTICS, stage="encode", reason="recordExceedsPage", frameBytes=str(size), limitBytes=str(limit_bytes)))
                break
            selected.append((offset, frame)); used += size
        selected.reverse()
        first_offset = selected[0][0] if selected else 0
        first_sequence = selected[0][1]["sequence"] if selected else 0
        cursor = cursor_encode(identity, first_offset, first_sequence, digest.hexdigest())
        if continued_from is not None: summary["continuedFrom"] = continued_from
        state = [0]
        emit({"v":1,"kind":"page","sourceIdentity":identity,"from":request.get("cursor"),"to":None,"summary":summary}, state)
        for _, frame in selected: emit(frame, state)
        emit({"v":1,"kind":"end","cursor":cursor,"hasMore":first_sequence > 0,"warnings":[]}, state)
    finally:
        os.close(descriptor)

def inventory(request):
    provider = request.get("provider")
    if provider == "opencode": return opencode_inventory(request)
    if provider == "pi": return pi_inventory(request)
    roots = provider_roots(provider)
    records = []
    deadline = time.monotonic() + MAX_INVENTORY_SECONDS
    directories = 0; files_seen = 0; bytes_seen = 0; bounded = False
    kimi_index = load_kimi_index(roots[0]) if provider == "kimi" else None
    if provider == "kimi" and (kimi_index is None or not validate_kimi_hook_configuration(roots[0])):
        raise ProjectionError("adapterOutdated")
    for root in roots:
        if time.monotonic() >= deadline: bounded = True; break
        if not os.path.isdir(root): continue
        for base, dirs, files in os.walk(root, followlinks=False):
            directories += 1
            if directories > MAX_INVENTORY_DIRECTORIES or time.monotonic() >= deadline:
                dirs[:] = []; bounded = True; break
            dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(base, name))]
            for name in files:
                files_seen += 1
                if files_seen > MAX_INVENTORY_FILES or time.monotonic() >= deadline:
                    bounded = True; break
                path = os.path.join(base, name)
                kimi_session_match = None
                if provider == "kimi":
                    relative = os.path.relpath(path, root)
                    kimi_session_match = re.fullmatch(r"sessions/[^/]+/(session_[A-Za-z0-9-]{1,128})/agents/[^/]+/wire\.jsonl", relative)
                    if kimi_session_match is None: continue
                elif not name.endswith((".jsonl", ".json")):
                    continue
                if os.path.islink(path): continue
                try: source_stat = os.stat(path, follow_symlinks=False)
                except OSError: continue
                if source_stat.st_uid != os.getuid(): continue
                bytes_seen += min(max(source_stat.st_size, 0), 65536)
                if bytes_seen > MAX_INVENTORY_BYTES:
                    bounded = True; break
                ref = base64.urlsafe_b64encode(path.encode()).decode().rstrip("=")
                descriptor = None
                provider_session_id = None
                try:
                    descriptor, _, _ = validate_source(provider, ref, kimi_index)
                    if provider == "kimi":
                        # Kimi canonical wire does not repeat the session ID
                        # in each envelope. The already-validated session index
                        # and exact source path are the authoritative identity.
                        provider_session_id = kimi_session_match.group(1)
                    else:
                        for consumed, raw, truncated in lines(descriptor, 0, end_offset=min(source_stat.st_size, 65536), redact_images=provider == "codex"):
                            record = normalized(provider, raw, truncated)
                            candidate = record.get("sessionID")
                            if isinstance(candidate, str) and 0 < len(candidate.encode()) <= 256:
                                provider_session_id = candidate
                                break
                            if consumed >= 65536: break
                except Exception:
                    provider_session_id = None
                finally:
                    if descriptor is not None: os.close(descriptor)
                if provider_session_id is None: continue
                records.append((source_stat.st_mtime_ns, ref, source_stat.st_size, provider_session_id))
                if len(records) >= MAX_RECORDS * 4:
                    bounded = True; break
            if bounded or len(records) >= MAX_RECORDS * 4: break
        if bounded or len(records) >= MAX_RECORDS * 4: break
    if bounded: raise ProjectionError("channelUnavailable")
    records.sort(key=lambda item: (item[0], item[1]), reverse=True)
    inventory_identity = hashlib.sha256(json.dumps(records, separators=(",", ":")).encode()).hexdigest()
    offset = inventory_cursor_decode(request.get("cursor"), provider, inventory_identity)
    if offset > len(records): raise ProjectionError("sourceChanged")
    limit = min(max(int(request.get("limitRecords", MAX_RECORDS)), 1), MAX_RECORDS)
    page = records[offset:offset + limit]
    state = [0]
    for sequence, (modified, ref, size, provider_session_id) in enumerate(page):
        emit({"v":1,"kind":"inventory","sequence":sequence,"provider":provider,"providerSessionID":provider_session_id,"transcriptRef":ref,"lastActivityNs":modified,"size":size}, state)
    warnings = ["inventoryBounded"] if bounded else []
    next_offset = offset + len(page)
    emit({"v":1,"kind":"end","cursor":inventory_cursor_encode(provider, inventory_identity, next_offset),"hasMore":next_offset<len(records),"warnings":warnings}, state)

def search(request):
    query, was_truncated = bounded_string(request.get("query", ""), MAX_QUERY)
    if not query: raise ProjectionError("malformed")
    request = dict(request); request["limitRecords"] = min(int(request.get("limitRecords", MAX_RECORDS)), MAX_RECORDS)
    provider = request.get("provider")
    if provider == "opencode": return opencode_search(request)
    if provider == "pi": return pi_search(request)
    descriptor, identity, source_stat = validate_source(provider, request.get("transcriptRef"))
    state = [0]; count = 0
    try:
        offset = 0
        for next_offset, raw, truncated in lines(descriptor, 0, redact_images=provider == "codex"):
            record_offset = offset; offset = next_offset
            record = normalized(provider, raw, truncated)
            text = record_search_text(record)
            if not text: continue
            position = text.casefold().find(query.casefold())
            if position < 0: continue
            excerpt, excerpt_truncated = bounded_string(text[max(0, position-128):position+len(query)+384], 1024)
            emit({"v":1,"kind":"searchResult","sourceIdentity":identity,"recordID":projection_record_id(identity, record_offset, record),"excerpt":excerpt,"truncated":bool(record.get("truncated") or excerpt_truncated or was_truncated)}, state)
            count += 1
            if count >= request["limitRecords"]: break
        latest = os.fstat(descriptor)
        latest_identity = jsonl_identity(provider, latest)
        if latest_identity != identity: raise ProjectionError("sourceChanged")
        emit({"v":1,"kind":"end","cursor":None,"hasMore":False,"warnings":[]}, state)
    finally: os.close(descriptor)

try:
    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
    if not raw or len(raw) > MAX_REQUEST: raise ProjectionError("malformed")
    request = json.loads(raw)
    if request.get("v") != 1: raise ProjectionError("adapterOutdated")
    kind = request.get("kind")
    if kind == "project": project(request)
    elif kind == "inventory": inventory(request)
    elif kind == "search": search(request)
    else: raise ProjectionError("unsupported")
except ProjectionError as error: fail(error.code, error.diagnostics or PROJECTION_DIAGNOSTICS); sys.exit(1)
except Exception as error:
    category = type(error).__name__
    if category not in {"TypeError", "ValueError", "OverflowError", "RecursionError", "UnicodeDecodeError", "UnicodeEncodeError", "OSError"}: category = "Other"
    fail("malformed", dict(PROJECTION_DIAGNOSTICS, reason="adapterException", exception=category)); sys.exit(1)
'
"""#

    /// Separate semantic launcher. It accepts a bounded JSON request and uses
    /// argument-vector process APIs; it never evals or interpolates a shell
    /// command. Tmux placement remains owned by the live control client.
    public static let semanticLaunchScript = #"""
#!/bin/sh

# Tessera Agent Center semantic launcher v1 — remove with ~/.config/tessera/agent-uninstall.sh.
set -u

if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' '{"v":1,"kind":"error","error":"unsupported","detail":"pythonUnavailable"}'
    exit 69
fi

exec python3 -c '
import base64, json, os, re, subprocess, sys

MAX_REQUEST = 65536
SAFE_PROVIDER = {"claude", "codex"}
SAFE_BRANCH = re.compile(r"^(?![-./])(?!.*(?:\.\.|//|@\{|\\))[A-Za-z0-9._/-]{1,128}(?<![./])$")

def fail(code):
    print(json.dumps({"v":1,"kind":"error","error":code}, separators=(",", ":")))
    sys.exit(1)

try:
    if sys.argv[1:] == ["--request-base64-stdin"]:
        encoded = sys.stdin.buffer.read((MAX_REQUEST * 2) + 1)
        if not encoded or len(encoded) > MAX_REQUEST * 2: fail("malformed")
        # `tmux show-buffer` terminates its display with a newline. Remove only
        # that transport delimiter and retain strict alphabet validation.
        encoded = encoded.rstrip(b"\r\n")
        if not encoded: fail("malformed")
        raw = base64.b64decode(encoded, validate=True)
    elif len(sys.argv) == 1:
        raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
    else:
        fail("malformed")
    if not raw or len(raw) > MAX_REQUEST: fail("malformed")
    request = json.loads(raw)
except Exception: fail("malformed")

if request.get("v") != 1: fail("adapterOutdated")
request_id = request.get("requestID")
if not isinstance(request_id, str) or re.fullmatch(r"[0-9a-f-]{36}", request_id) is None: fail("malformed")
provider = request.get("provider")
task = request.get("task")
directory = request.get("directory")
kind = request.get("kind")
if provider not in SAFE_PROVIDER or kind not in {"spawn", "fork"}: fail("unsupported")
if not isinstance(task, str) or not task.strip() or len(task.encode()) > 32768: fail("invalidTask")
if not isinstance(directory, str) or "\x00" in directory: fail("invalidPath")
directory = os.path.realpath(os.path.expanduser(directory))
if not os.path.isdir(directory): fail("invalidPath")

isolation = request.get("isolation") or {"kind":"current"}
launch_directory = directory
worktree = None
if isolation.get("kind") == "worktree":
    branch = isolation.get("branch")
    if not isinstance(branch, str) or SAFE_BRANCH.fullmatch(branch) is None: fail("invalidBranch")
    root = subprocess.run(["git", "-C", directory, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if root.returncode != 0: fail("notRepository")
    repository = root.stdout.strip()
    worktree_root = os.path.join(os.path.dirname(repository), ".tessera-worktrees")
    os.makedirs(worktree_root, mode=0o700, exist_ok=True)
    worktree = os.path.join(worktree_root, branch.rsplit("/", 1)[-1])
    result = subprocess.run(["git", "-C", repository, "worktree", "add", "-b", branch, worktree], capture_output=True)
    if result.returncode != 0: fail("worktreeFailed")
    launch_directory = worktree

arguments = [provider]
if kind == "fork":
    source = request.get("source") or {}
    session_id = source.get("providerSessionID")
    if provider != "claude" or not isinstance(session_id, str) or not re.fullmatch(r"[A-Za-z0-9._:-]{1,256}", session_id): fail("unsupported")
    arguments += ["--resume", session_id, "--fork-session"]
arguments += [task]

receipt = {"v":1,"kind":"launchReceipt","requestID":request_id,"provider":provider,"pid":None,"worktreeCreated":worktree is not None,"worktreeName":os.path.basename(worktree) if worktree else None}
pane = os.environ.get("TMUX_PANE")
if pane and re.fullmatch(r"%[0-9]+", pane):
    stored = subprocess.run(["tmux", "set-option", "-p", "-t", pane, "@tessera_agent_launch_receipt", json.dumps(receipt, separators=(",", ":"))], capture_output=True)
    if stored.returncode != 0: fail("receiptFailed")
sys.stdout.write(json.dumps(receipt, separators=(",", ":")) + "\n")
sys.stdout.flush()
os.chdir(launch_directory)
os.execvp(arguments[0], arguments)
' "$@"
"""#

    /// Fresh process-ancestry proof used by native platform endpoints. The
    /// caller supplies either an authoritative tmux pane root PID or a random
    /// per-PTY marker that the SSH server acknowledged before starting the
    /// shell. Lifecycle-reported PIDs never authorize themselves.
    public static let processProofScript = #"""
#!/bin/sh

# Tessera Agent Center process proof v1 — remove with ~/.config/tessera/agent-uninstall.sh.
set -u

if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' '{"v":1,"valid":false,"error":"unsupported"}'
    exit 69
fi

exec python3 -c '
import json, os, re, subprocess, sys

MAX_REQUEST = 4096
MARKER = re.compile(r"^[A-Fa-f0-9-]{36}$")

def fail(code):
    print(json.dumps({"v":1,"valid":False,"error":code}, separators=(",", ":")))
    sys.exit(1)

def parent(pid):
    stat = "/proc/%d/stat" % pid
    try:
        raw = open(stat, "rb").read(4096).decode("utf-8", "replace")
        end = raw.rfind(")")
        fields = raw[end + 2:].split()
        return int(fields[1]) if end >= 0 and len(fields) > 1 else 0
    except Exception:
        try:
            result = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True, timeout=2)
            return int(result.stdout.strip()) if result.returncode == 0 else 0
        except Exception:
            return 0

def has_marker(pid, marker):
    needle = ("LC_TESSERA_ROUTE=" + marker).encode()
    try:
        values = open("/proc/%d/environ" % pid, "rb").read(262144).split(b"\0")
        return needle in values
    except Exception:
        try:
            result = subprocess.run(["ps", "eww", "-p", str(pid)], capture_output=True, text=True, timeout=2)
            return result.returncode == 0 and re.search(r"(?:^|\\s)" + re.escape(needle.decode()) + r"(?:\\s|$)", result.stdout) is not None
        except Exception:
            return False

def process_identity(pid):
    try:
        comm = open("/proc/%d/comm" % pid, "rb").read(256).decode("utf-8", "replace").strip()
        argv = [item.decode("utf-8", "replace") for item in open("/proc/%d/cmdline" % pid, "rb").read(65536).split(b"\0") if item]
        return comm, argv
    except Exception:
        try:
            result = subprocess.run(["ps", "-o", "comm=", "-o", "args=", "-p", str(pid)], capture_output=True, text=True, timeout=2)
            if result.returncode != 0: return "", []
            line = result.stdout.strip()
            if not line: return "", []
            parts = line.split(None, 1)
            return parts[0], parts[1].split() if len(parts) == 2 else [parts[0]]
        except Exception:
            return "", []

def process_start(pid):
    try:
        raw = open("/proc/%d/stat" % pid, "rb").read(4096).decode("utf-8", "replace")
        end = raw.rfind(")")
        fields = raw[end + 2:].split()
        # /proc/<pid>/stat field 22 is the kernel start time. `fields` begins
        # at field 3 after removing the parenthesised command.
        if end >= 0 and len(fields) > 19 and fields[19].isdigit():
            return "proc:" + fields[19]
    except Exception:
        pass
    try:
        import ctypes, sys
        if sys.platform == "darwin":
            class ProcBSDInfo(ctypes.Structure):
                _fields_ = [
                    ("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32),
                    ("pbi_xstatus", ctypes.c_uint32), ("pbi_pid", ctypes.c_uint32),
                    ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
                    ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32),
                    ("pbi_rgid", ctypes.c_uint32), ("pbi_svuid", ctypes.c_uint32),
                    ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
                    ("pbi_comm", ctypes.c_char * 17), ("pbi_name", ctypes.c_char * 33),
                    ("pbi_nfiles", ctypes.c_uint32), ("pbi_pgid", ctypes.c_uint32),
                    ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
                    ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32),
                    ("pbi_start_tvsec", ctypes.c_uint64), ("pbi_start_tvusec", ctypes.c_uint64),
                ]
            info = ProcBSDInfo()
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            size = libproc.proc_pidinfo(int(pid), 3, 0, ctypes.byref(info), ctypes.sizeof(info))
            if size == ctypes.sizeof(info) and info.pbi_pid == int(pid) and info.pbi_start_tvsec > 0:
                return "darwin:%d:%d" % (info.pbi_start_tvsec, info.pbi_start_tvusec)
    except Exception:
        pass
    try:
        result = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=2)
        value = result.stdout.strip() if result.returncode == 0 else ""
        if value and len(value) <= 96 and all(ord(character) >= 32 for character in value):
            return "ps:" + value
    except Exception:
        pass
    return ""

def foreground(pid):
    try:
        raw = open("/proc/%d/stat" % pid, "rb").read(4096).decode("utf-8", "replace")
        end = raw.rfind(")")
        fields = raw[end + 2:].split()
        if end < 0 or len(fields) < 6: return None
        pgid, tpgid = int(fields[2]), int(fields[5])
    except Exception:
        try:
            result = subprocess.run(["ps", "-o", "pgid=", "-o", "tpgid=", "-p", str(pid)], capture_output=True, text=True, timeout=2)
            if result.returncode != 0: return None
            pgid, tpgid = map(int, result.stdout.split())
        except Exception:
            return None
    return pgid == tpgid if pgid > 0 and tpgid > 0 else None

def exact_provider_process(pid, provider):
    comm, argv = process_identity(pid)
    command = os.path.basename(comm).lower()
    executable = os.path.basename(argv[0]).lower() if argv else ""
    arguments = "\0".join(argv[1:]).lower()
    # The official Claude self-updater executes a semver-named binary at this
    # exact private installation location. A bare `1.2.3` comm is never enough:
    # require the unnormalised absolute argv[0] shape as well, so a forged
    # descendant renamed to a version number cannot satisfy process proof.
    versioned_claude = False
    if argv and argv[0].startswith("/") and os.path.normpath(argv[0]) == argv[0]:
        versioned_claude = re.fullmatch(
            r"/(?:[^/]+/)*\.local/share/claude/versions/[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?",
            argv[0],
        ) is not None
    if provider == "claude":
        return command in {"claude", "claude-code"} or executable in {"claude", "claude-code"} or \
            versioned_claude or (command in {"node", "nodejs"} and "@anthropic-ai/claude-code" in arguments)
    if provider == "codex":
        return command in {"codex", "codex-cli"} or executable in {"codex", "codex-cli"} or \
            (command in {"node", "nodejs"} and "@openai/codex" in arguments)
    if provider == "kimi":
        return command in {"kimi", "kimi-code"} or executable in {"kimi", "kimi-code"} or \
            (command in {"node", "nodejs"} and ("/kimi" in arguments or "@moonshotai/kimi" in arguments))
    return False

try:
    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)
    if not raw or len(raw) > MAX_REQUEST: fail("malformed")
    request = json.loads(raw)
except Exception:
    fail("malformed")

if request.get("v") != 1: fail("adapterOutdated")
claimed = request.get("claimedPID")
root = request.get("rootPID")
marker = request.get("routeMarker")
provider = request.get("provider")
if not isinstance(claimed, int) or claimed <= 1: fail("invalidProcess")
if root is not None and (not isinstance(root, int) or root <= 1): fail("invalidRoot")
if marker is not None and (not isinstance(marker, str) or MARKER.fullmatch(marker) is None): fail("invalidMarker")
if (root is None) == (marker is None): fail("malformed")
if provider not in {"claude", "codex", "kimi"}: fail("invalidProvider")

chain = []
seen = set()
pid = claimed
while pid > 1 and pid not in seen and len(chain) < 128:
    seen.add(pid)
    chain.append(pid)
    if root is not None and pid == root: break
    pid = parent(pid)

valid = root in chain if root is not None else any(has_marker(candidate, marker) for candidate in chain)
if not valid: fail("unrelatedProcess")
if not exact_provider_process(claimed, provider): fail("providerMismatch")
start = process_start(claimed)
if not start: fail("processIdentityUnavailable")
is_foreground = foreground(claimed)
if request.get("requireForeground") is True and is_foreground is False: fail("backgroundProcess")
print(json.dumps({"v":1,"valid":True,"provider":provider,"processIDs":chain,"processStart":start,"foreground":is_foreground}, separators=(",", ":")))
'
"""#

    public static let codexReadinessScript = #"""
#!/bin/sh

# Tessera Agent Center Codex readiness verifier — remove with ~/.config/tessera/agent-uninstall.sh.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=\#(integrationVersion)
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
# `codex resume` and `codex fork` open an existing thread at an empty composer
# and, like a fresh start, fire no native SessionStart before the first turn.
# They take the same pre-exec bootstrap; the root observer then publishes the
# thread's identity from the rollout the provider process holds open.
launch_mode=composer
subcommand_positionals=0
selects_last_thread=0
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
        --last|--all|--include-non-interactive)
            # Thread selection flags of resume and fork. They are not
            # app-server options, so the probe omits them. fork has no
            # --include-non-interactive; Codex rejects it at once.
            case "$launch_mode:$argument" in
                resume:*|fork:--last|fork:--all) ;;
                *) interactive_empty_composer=0 ;;
            esac
            [ "$argument" != --last ] || selects_last_thread=1
            ;;
        -*) interactive_empty_composer=0 ;;
        *)
            if [ "$launch_mode" = composer ] && [ "$subcommand_positionals" -eq 0 ]; then
                case "$argument" in
                    resume|fork) launch_mode="$argument" ;;
                    *) subcommand_positionals=1; interactive_empty_composer=0 ;;
                esac
            elif [ "$subcommand_positionals" -eq 0 ]; then
                # `codex resume <session>`: an id or name selects the thread
                # and the composer is still empty.
                subcommand_positionals=1
            else
                # A prompt argument starts a turn; the native hooks cover it.
                interactive_empty_composer=0
            fi
            ;;
    esac
done
# With --last, resume and fork read their only positional as the prompt and
# start a turn at once, so that launch stays with the native hooks.
if [ "$launch_mode" != composer ] && [ "$selects_last_thread" -eq 1 ] && [ "$subcommand_positionals" -gt 0 ]; then
    interactive_empty_composer=0
fi

diagnostic_file="$HOME/.config/tessera/codex-readiness-diagnostics.log"
codex_readiness_diagnostic() {
    result="$1"
    [ -n "$profile" ] && profile_state=present || profile_state=absent
    [ "$cwd_override_requested" -eq 1 ] && cwd_override=present || cwd_override=absent
    mkdir -p "$HOME/.config/tessera" 2>/dev/null || return
    (umask 077; printf '%s result=%s profile=%s cwdOverride=%s launch=%s\n' \
        "$(date +%s 2>/dev/null || printf 0)" "$result" "$profile_state" "$cwd_override" "$launch_mode" \
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
    public static let claudeShimScript = #"""
#!/bin/sh

# Tessera Agent Center Claude shim — remove with ~/.config/tessera/agent-uninstall.sh.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=\#(integrationVersion)
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
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
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

    public static let codexShimScript = #"""
#!/bin/sh

# Tessera Agent Center Codex shim — remove with ~/.config/tessera/agent-uninstall.sh.
set -u

TESSERA_AGENT_INTEGRATION_VERSION=\#(integrationVersion)
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
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
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

# Non-interactive CLI tools do not own terminal lifecycle. In particular a
# nested `codex --version` must not write WrapperExit into its parent pane.
# Explicit user hook policy wins over Tessera's convenience integration.
expect=''
for argument in "$@"; do
    if [ -n "$expect" ]; then
        case "$expect" in
            disable) [ "$argument" != hooks ] || exec "$provider_path" "$@" ;;
            config)
                normalized_config="$(printf '%s' "$argument" | tr -d '[:space:]')"
                [ "$normalized_config" != features.hooks=false ] || exec "$provider_path" "$@"
                ;;
        esac
        expect=''; continue
    fi
    case "$argument" in
        --) break ;;
        --disable) expect=disable ;;
        -c|--config) expect=config ;;
        --disable=hooks) exec "$provider_path" "$@" ;;
        --config=*|-c?*)
            case "$argument" in --config=*) value="${argument#--config=}" ;; *) value="${argument#-c}" ;; esac
            normalized_config="$(printf '%s' "$value" | sed 's/^=//' | tr -d '[:space:]')"
            [ "$normalized_config" != features.hooks=false ] || exec "$provider_path" "$@"
            ;;
        -m|--model|-p|--profile|-C|--cd|-s|--sandbox|-a|--ask-for-approval|--enable|--add-dir|--local-provider|-i|--image)
            expect=skip ;;
    esac
done

skip_option_value=0
for argument in "$@"; do
    if [ "$skip_option_value" -eq 1 ]; then skip_option_value=0; continue; fi
    case "$argument" in
        -c|--config|-m|--model|-p|--profile|-C|--cd|-s|--sandbox|-a|--ask-for-approval|--enable|--disable|--add-dir|--local-provider|-i|--image)
            skip_option_value=1
            ;;
        -h|--help|-V|--version|exec|e|app-server|mcp|mcp-server|login|logout|completion|debug|review)
            exec "$provider_path" "$@"
            ;;
    esac
done

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

    public static let codexHooks = #"""
{"hooks":{"SessionStart":[{"matcher":"startup|resume|clear|compact","hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex SessionStart idle session-start"}]}],"SubagentStart":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex SubagentStart working subagent-start"}]}],"SubagentStop":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex SubagentStop working subagent-stop"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex UserPromptSubmit working agent-turn"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex PreToolUse working agent-turn"}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex PostToolUse working agent-turn"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex PermissionRequest waitingForInput permission"}]}],"Stop":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" codex Stop idle turn-stopped"}]}]}}
"""#

    private static let claudeLifecycleSettings = #"""
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude SessionStart idle session-start"}]}],"SubagentStart":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude SubagentStart working subagent-start"}]}],"SubagentStop":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude SubagentStop working subagent-stop"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude UserPromptSubmit working agent-turn"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude PreToolUse working agent-turn"}]}],"PostToolUse":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude PostToolUse working agent-turn"}]}],"PermissionRequest":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude PermissionRequest waitingForInput permission"}]}],"Notification":[{"matcher":"permission_prompt|elicitation_dialog","hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude Notification waitingForInput permission"}]},{"matcher":"idle_prompt","hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude Notification idle idle-prompt"}]}],"Stop":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude Stop idle turn-stopped"}]}],"StopFailure":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude StopFailure unavailable turn-failed"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" claude SessionEnd unavailable session-ended"}]}]}}
"""#

    public static let nativeClaudeHookCommand = #""$HOME/.config/tessera/tessera-agent-host" hook --runtime-base "$HOME/.config/tessera/agent-host""#

    /// Hooks accelerate observations but do not replace canonical JSONL reads.
    /// Only the explicit install flow merges these owned handler groups.
    public static let claudeSettings: String = {
        var root = try! JSONSerialization.jsonObject(with: Data(claudeLifecycleSettings.utf8)) as! [String: Any]
        var hooks = root["hooks"] as! [String: [[String: Any]]]
        for event in ["MessageDisplay", "SessionStart", "UserPromptSubmit", "PostToolUse", "Stop", "SessionEnd"] {
            hooks[event, default: []].append(["hooks": [["type": "command", "command": nativeClaudeHookCommand, "timeout": 1]]])
        }
        root["hooks"] = hooks
        return String(decoding: try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), as: UTF8.self)
    }()

    /// Kimi Code's official TOML hook layer. The marker-delimited block is
    /// replaced atomically while every unrelated byte of config.toml remains
    /// in place. Kimi receives the same content-free lifecycle bridge as the
    /// JSON-configured providers; no prompt or tool payload is retained.
    public static let kimiHooksBlock = #"""
# TESSERA-AGENT-CENTER-KIMI-HOOKS-BEGIN
[[hooks]]
event = "SessionStart"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi SessionStart idle session-start"

[[hooks]]
event = "SubagentStart"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi SubagentStart working subagent-start"

[[hooks]]
event = "SubagentStop"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi SubagentStop working subagent-stop"

[[hooks]]
event = "UserPromptSubmit"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi UserPromptSubmit working agent-turn"

[[hooks]]
event = "PreToolUse"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi PreToolUse working agent-turn"

[[hooks]]
event = "PostToolUse"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi PostToolUse working agent-turn"

[[hooks]]
event = "PermissionRequest"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi PermissionRequest waitingForInput permission"

[[hooks]]
event = "Stop"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi Stop idle turn-stopped"

[[hooks]]
event = "StopFailure"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi StopFailure unavailable turn-failed"

[[hooks]]
event = "SessionEnd"
command = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" kimi SessionEnd unavailable session-ended"
# TESSERA-AGENT-CENTER-KIMI-HOOKS-END
"""#

    public static let shellIntegration = shellIntegration(version: integrationVersion)

    /// agent-lifecycle.sh as a given release installs it. Only the version
    /// it records differs between releases that share a shell floor.
    static func shellIntegration(version: Int) -> String {
        #"""
# Tessera Agent Center integration version \#(version) — remove with ~/.config/tessera/agent-uninstall.sh.

TESSERA_AGENT_INTEGRATION_VERSION=\#(version)
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
    TESSERA_AGENT_SHIM_VERSION=\#(version)
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
    }

    public static var confirmationText: String {
        """
        Installs Tessera-owned lifecycle scripts and optional PATH shims under ~/.config/tessera, then adds guarded source lines to the selected bash/zsh interactive and login startup files, including zsh's ZDOTDIR when configured. The sourced script publishes a PID-and-process-start marker without installing signal traps, so user shell behavior remains unchanged and child programs inherit activation. Existing aliases and functions remain unchanged. Provider hooks are merged into the official ${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json, ${CODEX_HOME:-~/.codex}/hooks.json, and ${KIMI_CODE_HOME:-~/.kimi-code}/config.toml user layers, so aliases, functions, absolute executable paths, version managers, and user arguments do not depend on Tessera intercepting the command. A Tessera-owned ~/.config/tessera/claude-agent-hooks.json compatibility copy keeps older explicit Claude aliases working without injecting a competing --settings option into normal launches. Only Tessera-owned handlers are replaced; unrelated settings and hooks remain intact, including symlink-managed files, using atomic compare-and-swap updates. Kimi's marker-delimited TOML hook block is syntax-checked before replacement. The PATH shims add immediate Codex empty-composer verification and prompt exit state when used. Original provider arguments are preserved. Codex may ask you to review and trust Tessera's groups on its first integrated launch; until that native trust settles, Tessera reports only its separately verified provider/configuration bootstrap state.
        """
    }

    public static var disclosedSource: String {
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

        ${KIMI_CODE_HOME:-~/.kimi-code}/config.toml (the marker-delimited Tessera block is merged; all other TOML is preserved)
        ------------------------------------------------------------
        \(kimiHooksBlock)

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

    public static func probe(
        execute: (String) async throws -> String,
        diagnostic: ((String) -> Void)? = nil
    ) async throws -> AgentLifecycleHostInstallation {
        let output = try await execute(makeStatusCommand(requireNativeHost: true))
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

    public enum ProviderConfigSnapshot: Equatable {
        case missing
        case present(String)
    }
    public typealias CodexHooksSnapshot = ProviderConfigSnapshot

    public static func makeCodexHooksReadCommand() -> String {
        makeProviderConfigReadCommand(
            pathAssignment: "tessera_provider_config=\"${CODEX_HOME:-$HOME/.codex}/hooks.json\"",
            marker: codexHooksSnapshotMarker
        )
    }

    public static func makeClaudeSettingsReadCommand() -> String {
        makeProviderConfigReadCommand(
            pathAssignment: "tessera_provider_config=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\"",
            marker: claudeSettingsSnapshotMarker
        )
    }

    public static func makeKimiConfigReadCommand() -> String {
        makeProviderConfigReadCommand(
            pathAssignment: "tessera_provider_config=\"${KIMI_CODE_HOME:-$HOME/.kimi-code}/config.toml\"",
            marker: kimiConfigSnapshotMarker
        )
    }

    private static func makeProviderConfigReadCommand(pathAssignment: String, marker: String) -> String {
        let quotedMarker = shellQuote(marker)
        return "\(pathAssignment); if [ -L \"$tessera_provider_config\" ] && [ ! -e \"$tessera_provider_config\" ]; then printf '%s error:dangling-symlink\\n' \(quotedMarker); elif [ ! -e \"$tessera_provider_config\" ]; then printf '%s missing\\n' \(quotedMarker); elif [ ! -f \"$tessera_provider_config\" ] || [ ! -r \"$tessera_provider_config\" ]; then printf '%s error:not-readable-file\\n' \(quotedMarker); else tessera_provider_config_size=\"$(wc -c < \"$tessera_provider_config\" 2>/dev/null | tr -d '[:space:]')\"; case \"$tessera_provider_config_size\" in ''|*[!0-9]*) printf '%s error:size-unavailable\\n' \(quotedMarker) ;; *) if [ \"$tessera_provider_config_size\" -gt 1048576 ]; then printf '%s error:too-large\\n' \(quotedMarker); else tessera_provider_config_base64=\"$(base64 < \"$tessera_provider_config\" 2>/dev/null | tr -d '\\n')\"; printf '%s present:%s\\n' \(quotedMarker) \"$tessera_provider_config_base64\"; fi ;; esac; fi"
    }

    public static func parseCodexHooksSnapshot(_ output: String) -> ProviderConfigSnapshot? {
        parseProviderConfigSnapshot(output, marker: codexHooksSnapshotMarker)
    }

    public static func parseClaudeSettingsSnapshot(_ output: String) -> ProviderConfigSnapshot? {
        parseProviderConfigSnapshot(output, marker: claudeSettingsSnapshotMarker)
    }

    public static func parseKimiConfigSnapshot(_ output: String) -> ProviderConfigSnapshot? {
        parseProviderConfigSnapshot(output, marker: kimiConfigSnapshotMarker)
    }

    public static func parseProviderConfigSnapshots(
        _ output: String
    ) -> (codex: ProviderConfigSnapshot, claude: ProviderConfigSnapshot, kimi: ProviderConfigSnapshot)? {
        guard output.utf8.count <= 8_388_608,
              let codex = parseProviderConfigSnapshot(output, marker: codexHooksSnapshotMarker),
              let claude = parseProviderConfigSnapshot(output, marker: claudeSettingsSnapshotMarker),
              let kimi = parseProviderConfigSnapshot(output, marker: kimiConfigSnapshotMarker)
        else { return nil }
        return (codex, claude, kimi)
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
                  let data = Data(base64Encoded: String(payload.dropFirst("present:".count)), options: []),
                  data.count <= 1_048_576,
                  let contents = String(data: data, encoding: .utf8)
            else { return nil }
            return .present(contents)
        }
        return nil
    }

    public static func mergeCodexHooks(existing: String?) throws -> String {
        try mergeProviderHooks(
            existing: existing,
            canonical: codexHooks,
            provider: "codex",
            configLabel: "Codex hooks.json"
        )
    }

    public static func mergeClaudeSettings(existing: String?) throws -> String {
        try mergeProviderHooks(
            existing: existing,
            canonical: claudeSettings,
            provider: "claude",
            configLabel: "Claude settings.json"
        )
    }

    public static func mergeKimiConfig(existing: String?) throws -> String {
        let original = existing ?? ""
        guard !original.contains("\0"), original.utf8.count <= 1_048_576 else {
            throw AgentLifecycleIntegrationInstallError.verificationFailed("Kimi config.toml is not a bounded text file")
        }
        let lines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var retained: [String] = []
        var insideOwnedBlock = false
        var sawStart = false
        var sawEnd = false
        for line in lines {
            if line == kimiHooksStartMarker {
                guard !insideOwnedBlock, !sawStart else {
                    throw AgentLifecycleIntegrationInstallError.verificationFailed("Kimi config.toml contains ambiguous Tessera hook markers")
                }
                insideOwnedBlock = true
                sawStart = true
                continue
            }
            if line == kimiHooksEndMarker {
                guard insideOwnedBlock, !sawEnd else {
                    throw AgentLifecycleIntegrationInstallError.verificationFailed("Kimi config.toml contains ambiguous Tessera hook markers")
                }
                insideOwnedBlock = false
                sawEnd = true
                continue
            }
            if !insideOwnedBlock { retained.append(line) }
        }
        guard !insideOwnedBlock, sawStart == sawEnd else {
            throw AgentLifecycleIntegrationInstallError.verificationFailed("Kimi config.toml contains an incomplete Tessera hook block")
        }
        while retained.last?.isEmpty == true { retained.removeLast() }
        let prefix = retained.joined(separator: "\n")
        return prefix.isEmpty ? kimiHooksBlock + "\n" : prefix + "\n\n" + kimiHooksBlock + "\n"
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
                        !isOwnedLifecycleHandler(handler, provider: provider, event: event)
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

    /// A provider config entry belongs to Tessera only when it is the exact
    /// fixed hook invocation shape. User wrappers that quote, log, chain, or
    /// otherwise mention the Tessera executable remain user-owned.
    private static func isOwnedLifecycleHandler(
        _ handler: [String: Any],
        provider: String,
        event: String
    ) -> Bool {
        guard handler["type"] as? String == "command",
              let command = handler["command"] as? String
        else { return false }
        if provider == "claude", command == nativeClaudeHookCommand { return true }
        let prefix = "\"$HOME/.config/tessera/agent-lifecycle-hook.sh\" \(provider) \(event) "
        guard command.hasPrefix(prefix) else { return false }
        let fields = command.dropFirst(prefix.count).split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2,
              ["waitingForInput", "working", "idle", "unavailable"].contains(String(fields[0]))
        else { return false }
        return fields[1].range(of: #"^[a-z][a-z-]{0,63}$"#, options: .regularExpression) != nil
    }

    /// How many times the installer may re-read, re-merge, and retry before it
    /// gives up. Only a compare-and-swap race consumes an attempt.
    public static let maximumInstallAttempts = 3

    /// Classifies one run of the install program.
    ///
    /// This is the whole retry policy, and both platforms must read it from
    /// here. Deciding it locally is how an Android install reported every
    /// failure — a broken verification included — as "provider settings changed
    /// during installation", pointing away from the real cause for a full
    /// release cycle.
    public static func classifyInstallOutput(_ output: String) -> AgentLifecycleInstallOutcome {
        if output.contains(codexHooksRaceMarker)
            || output.contains(claudeSettingsRaceMarker)
            || output.contains(kimiConfigRaceMarker) {
            return .configurationRace
        }
        if output.split(whereSeparator: \.isNewline).contains(where: {
            $0.hasPrefix("\(newerInstallationMarker) ")
        }) {
            return .failed(reason: .newerInstalled, detail: output)
        }
        guard output.contains(verificationMarker) else {
            return .failed(reason: .notVerified, detail: output)
        }
        guard parseStatus(output) == .current else {
            return .failed(reason: .notCurrent, detail: output)
        }
        return .completed
    }

    public static func install(
        execute: (String) async throws -> String
    ) async throws {
        var lastOutput = ""
        for _ in 0..<maximumInstallAttempts {
            let snapshotOutput = try await execute(
                "\(makeCodexHooksReadCommand()); \(makeClaudeSettingsReadCommand()); \(makeKimiConfigReadCommand())"
            )
            guard let codexSnapshot = parseCodexHooksSnapshot(snapshotOutput),
                  let claudeSnapshot = parseClaudeSettingsSnapshot(snapshotOutput),
                  let kimiSnapshot = parseKimiConfigSnapshot(snapshotOutput)
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
            let existingKimiConfig: String?
            switch kimiSnapshot {
            case .missing: existingKimiConfig = nil
            case .present(let contents): existingKimiConfig = contents
            }
            let mergedCodexHooks: String
            let mergedClaudeSettings: String
            let mergedKimiConfig: String
            do {
                mergedCodexHooks = try mergeCodexHooks(existing: existingCodexHooks)
                mergedClaudeSettings = try mergeClaudeSettings(existing: existingClaudeSettings)
                mergedKimiConfig = try mergeKimiConfig(existing: existingKimiConfig)
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
                    expectedClaudeSettings: existingClaudeSettings,
                    mergedKimiConfig: mergedKimiConfig,
                    expectedKimiConfig: existingKimiConfig
                )
            )
            lastOutput = output
            switch classifyInstallOutput(output) {
            case .configurationRace:
                continue
            case .failed(.newerInstalled, _):
                throw AgentLifecycleIntegrationInstallError.newerInstalled
            case let .failed(_, detail):
                throw AgentLifecycleIntegrationInstallError.verificationFailed(detail)
            case .completed:
                return
            }
        }
        throw AgentLifecycleIntegrationInstallError.verificationFailed(
            lastOutput.isEmpty
                ? {
                    #if os(Android)
                    return "Provider hook settings kept changing during installation."
                    #else
                    return String(
                    localized: "Provider hook settings kept changing during installation.",
                    comment: "Agent Center install gave up because the remote settings file kept moving"
                    )
                    #endif
                }()
                : lastOutput
        )
    }

    public static func makeInstallCommand() -> String {
        makeInstallCommand(
            mergedCodexHooks: codexHooks,
            expectedCodexHooks: nil,
            mergedClaudeSettings: claudeSettings,
            expectedClaudeSettings: nil,
            mergedKimiConfig: kimiHooksBlock + "\n",
            expectedKimiConfig: nil
        )
    }

    public static func makeInstallCommand(
        mergedCodexHooks: String,
        expectedCodexHooks: String?,
        mergedClaudeSettings: String,
        expectedClaudeSettings: String?,
        mergedKimiConfig: String,
        expectedKimiConfig: String?
    ) -> String {
        let hook = shellQuote(hookScript)
        let launcher = shellQuote(launcherScript)
        let projector = shellQuote(projectorScript)
        let semanticLauncher = shellQuote(semanticLaunchScript)
        let processProof = shellQuote(processProofScript)
        let codexReadiness = shellQuote(codexReadinessScript)
        let codexRecovery = shellQuote(codexConversationRecoveryScript)
        let claudeShim = shellQuote(claudeShimScript)
        let codexShim = shellQuote(codexShimScript)
        let installedCodexHooks = shellQuote(mergedCodexHooks)
        let installedClaudeSettings = shellQuote(mergedClaudeSettings)
        let installedKimiConfig = shellQuote(mergedKimiConfig)
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
        let writeKimiConfig = makeAtomicKimiConfigWriteCommand(
            mergedContents: installedKimiConfig,
            expectedContents: expectedKimiConfig
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
            atomicSupportWrite(quotedContents: shellQuote(uninstallScript), path: "$HOME/.config/tessera/agent-uninstall.sh", mode: 700),
            atomicSupportWrite(
                quotedContents: codexRecovery,
                path: "$HOME/.config/tessera/agent-codex-recover.sh",
                mode: 700
            ),
            atomicSupportWrite(
                quotedContents: launcher,
                path: "$HOME/.config/tessera/agent-launch.sh",
                mode: 700
            ),
            atomicSupportWrite(
                quotedContents: projector,
                path: "$HOME/.config/tessera/tessera-agent-project",
                mode: 700
            ),
            atomicSupportWrite(
                quotedContents: semanticLauncher,
                path: "$HOME/.config/tessera/tessera-agent-launch",
                mode: 700
            ),
            atomicSupportWrite(
                quotedContents: processProof,
                path: "$HOME/.config/tessera/tessera-agent-prove",
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
            // Last support file: the hook is the installation's manifest, so
            // a version is declared only once every support file exists, and
            // still before the provider configs that run it. It is re-checked
            // as it is written: a newer app that installed since this run's
            // first probe keeps its manifest and its provider configs. (A
            // manifest this run already judged untrusted is repaired.)
            "{ \(installedVersionProbe); if [ \"$tessera_installed_newer\" = 1 ] && [ \"$tessera_installed_version\" != \"$tessera_probed_version\" ]; then printf '%s %s\\n' \(shellQuote(newerInstallationMarker)) \"$tessera_installed_version\"; false; else \(atomicSupportWrite(quotedContents: hook, path: "$HOME/.config/tessera/agent-lifecycle-hook.sh", mode: 700)); fi; }",
        ].joined(separator: " && ")
        let writeFiles = "mkdir -p \"$HOME/.config/tessera/bin\" && chmod 700 \"$HOME/.config/tessera\" \"$HOME/.config/tessera/bin\" && \(supportWrites) && rm -f \"$HOME/.config/tessera/codex-hooks-installed.json\""
        let append = "tessera_rc_ok=1; tessera_append_line() { tessera_append_file=\"$1\"; tessera_append_value=\"$2\"; grep -qFx \"$tessera_append_value\" \"$tessera_append_file\" 2>/dev/null && return 0; if [ -s \"$tessera_append_file\" ] && [ \"$(tail -c 1 \"$tessera_append_file\" 2>/dev/null | wc -l | tr -d '[:space:]')\" = 0 ]; then printf '\\n' >> \"$tessera_append_file\" || return 1; fi; printf '%s\\n' \"$tessera_append_value\" >> \"$tessera_append_file\"; }; tessera_zshrc=\"${ZDOTDIR:-$HOME}/.zshrc\"; case \"${SHELL##*/}\" in zsh) tessera_primary_rc=\"$tessera_zshrc\" ;; *) tessera_primary_rc=\"$HOME/.bashrc\" ;; esac; for tessera_rc in \"$HOME/.bashrc\" \"$tessera_zshrc\"; do if [ -e \"$tessera_rc\" ] || [ \"$tessera_rc\" = \"$tessera_primary_rc\" ]; then mkdir -p \"${tessera_rc%/*}\" 2>/dev/null || tessera_rc_ok=0; touch \"$tessera_rc\" 2>/dev/null || tessera_rc_ok=0; tessera_append_line \"$tessera_rc\" \(line) || tessera_rc_ok=0; fi; done; tessera_bash_login=''; for tessera_candidate in \"$HOME/.bash_profile\" \"$HOME/.bash_login\" \"$HOME/.profile\"; do if [ -e \"$tessera_candidate\" ]; then tessera_bash_login=\"$tessera_candidate\"; break; fi; done; if [ -z \"$tessera_bash_login\" ] && [ \"${SHELL##*/}\" = bash ]; then tessera_bash_login=\"$HOME/.bash_profile\"; fi; if [ -n \"$tessera_bash_login\" ]; then touch \"$tessera_bash_login\" 2>/dev/null || tessera_rc_ok=0; tessera_append_line \"$tessera_bash_login\" \(bashLoginLine) || tessera_rc_ok=0; fi; [ \"$tessera_rc_ok\" -eq 1 ]"
        // Publish every executable/support file atomically before activating
        // provider configuration that references it. An interrupted update
        // can leave a checksum-detectable mixture of complete versions, but
        // never a hook or shim truncated halfway through a shell program.
        // A newer installation is never replaced, whatever led here: an older
        // app's stale decision must not undo a newer app's install.
        let install = "\(writeFiles) && \(writeCodexHooks) && \(writeClaudeSettings) && \(writeKimiConfig) && \(append) && \"$HOME/.config/tessera/agent-codex-recover.sh\" && \(makeStatusCommand()) && echo \(report)"
        return "\(installedVersionProbe); tessera_probed_version=\"$tessera_installed_version\"; if [ \"$tessera_installed_newer\" = 1 ]; then printf '%s %s\\n' \(shellQuote(newerInstallationMarker)) \"$tessera_installed_version\"; else \(install); fi"
    }

    /// Resolves a Python interpreter that can parse TOML, and defines
    /// `tessera_toml_valid` over it.
    ///
    /// macOS ships `/usr/bin/python3` 3.9, which has no `tomllib`, and a
    /// non-interactive SSH environment resolves `python3` there long before any
    /// newer interpreter the user installed. Treating that as a parse failure
    /// reported every correct Kimi configuration as corrupt, so the status
    /// probe answered `outdated` forever and the installer never published the
    /// merged config — Install and Update could not converge on such a host.
    ///
    /// A missing parser is therefore `unavailable`, never `mismatch`:
    /// `tessera_toml_valid` succeeds when nothing can check the file, and
    /// verifies it whenever something can. `tessera_toml` records which of the
    /// two happened for the installation diagnostic.
    private static let tomlValidatorSetup = #"tessera_toml_python=''; for tessera_toml_candidate in python3 python3.13 python3.12 python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3; do command -v "$tessera_toml_candidate" >/dev/null 2>&1 || continue; "$tessera_toml_candidate" -c 'import sys,importlib.util as u; sys.exit(0 if (u.find_spec("tomllib") or u.find_spec("tomli")) else 1)' >/dev/null 2>&1 || continue; tessera_toml_python="$tessera_toml_candidate"; break; done; if [ -n "$tessera_toml_python" ]; then tessera_toml=available; else tessera_toml=unavailable; fi; tessera_toml_valid() { [ -n "$tessera_toml_python" ] || return 0; "$tessera_toml_python" -c 'import sys,importlib.util as u; __import__("tomllib" if u.find_spec("tomllib") else "tomli").load(open(sys.argv[1],"rb"))' "$1" >/dev/null 2>&1; }"#

    // Deployment publishes hash-verified immutable artifacts under their SHA.
    // Check that identity independently of hook bytes: another app can replace
    // the native link while this app is publishing lifecycle scripts.
    static var nativeHostCurrencyCheck: String {
        let cases = AgentHostBuildRevision.artifacts.sorted { $0.key < $1.key }.map {
            let target = $0.key.hasPrefix("darwin-")
                ? $0.key.replacingOccurrences(of: "darwin-", with: "Darwin-")
                : $0.key.replacingOccurrences(of: "linux-", with: "Linux-")
            return "\(target)) tessera_expected_native=agent-host-versions/\($0.value) ;;"
        }.joined(separator: " ")
        let verify = #"""
import hashlib,os,stat,sys
root=os.path.expanduser('~/.config/tessera')
expected=sys.argv[1]
if os.readlink(root+'/tessera-agent-host')!=expected: sys.exit(1)
fd=os.open(root+'/'+expected,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
try:
    info=os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.geteuid() or info.st_nlink!=1 or not info.st_mode&stat.S_IXUSR or not 0<info.st_size<=16777216: sys.exit(1)
    digest=hashlib.sha256()
    remaining=info.st_size
    while remaining:
        chunk=os.read(fd,min(65536,remaining))
        if not chunk: sys.exit(1)
        digest.update(chunk); remaining-=len(chunk)
    sys.exit(0 if digest.hexdigest()==expected.rsplit('/',1)[-1] else 1)
finally: os.close(fd)
"""#
        return "(tessera_expected_native=''; case \"$(uname -s)-$(uname -m)\" in \(cases) esac; [ -n \"$tessera_expected_native\" ] && python3 -c \(shellQuote(verify)) \"$tessera_expected_native\" 2>/dev/null)"

    }

    /// Reads the installed hook's version and compatibility floor into
    /// `tessera_installed_version`, `tessera_installed_floor`, and
    /// `tessera_installed_newer` (1 when newer than this app). The hook is the
    /// installation's manifest, the last support file every install run
    /// writes. A hook without a floor admits only its own version, so an
    /// unexpected layout asks for an app update rather than a downgrade.
    ///
    /// Only the owner's own regular-file manifest may claim a newer version:
    /// a symlinked hook is this app's to repair. Mode bits are never a
    /// criterion (a umask 0002 host writes everything group-writable).
    /// Versions above 65535 are implausible and read as unversioned.
    static var installedVersionProbe: String {
        #"tessera_hook_file="$HOME/.config/tessera/agent-lifecycle-hook.sh"; tessera_installed_version="$(sed -n 's/^TESSERA_AGENT_INTEGRATION_VERSION=\([0-9]\{1,5\}\)$/\1/p' "$tessera_hook_file" 2>/dev/null | head -n 1)"; tessera_installed_floor="$(sed -n 's/^TESSERA_AGENT_INTEGRATION_COMPATIBLE_FROM=\([0-9]\{1,5\}\)$/\1/p' "$tessera_hook_file" 2>/dev/null | head -n 1)"; [ -n "$tessera_installed_floor" ] || tessera_installed_floor="$tessera_installed_version"; tessera_installed_newer=0; if [ -n "$tessera_installed_version" ] && [ "$tessera_installed_version" -le 65535 ] && [ "$tessera_installed_version" -gt \#(integrationVersion) ] && [ -f "$tessera_hook_file" ] && [ ! -L "$tessera_hook_file" ] && [ -O "$tessera_hook_file" ]; then tessera_installed_newer=1; fi"#
    }

    /// Every Tessera-owned support file an install publishes, as the status
    /// probe verifies it: (probe variable, diagnostic key, path, contents,
    /// executable).
    static var ownedFiles: [(String, String, String, String, Bool)] {
        [
            ("uninstaller", "uninstaller", "$HOME/.config/tessera/agent-uninstall.sh", uninstallScript, true),
            ("hook", "hook", "$HOME/.config/tessera/agent-lifecycle-hook.sh", hookScript, true),
            ("launcher", "launcher", "$HOME/.config/tessera/agent-launch.sh", launcherScript, true),
            ("projector", "projector", "$HOME/.config/tessera/tessera-agent-project", projectorScript, true),
            ("codex_recovery", "codexRecovery", "$HOME/.config/tessera/agent-codex-recover.sh", codexConversationRecoveryScript, true),
            ("semantic_launcher", "semanticLauncher", "$HOME/.config/tessera/tessera-agent-launch", semanticLaunchScript, true),
            ("process_proof", "processProof", "$HOME/.config/tessera/tessera-agent-prove", processProofScript, true),
            ("codex_readiness", "codexReadiness", "$HOME/.config/tessera/agent-codex-readiness.sh", codexReadinessScript, true),
            ("claude_shim", "claudeShim", "$HOME/.config/tessera/bin/claude", claudeShimScript, true),
            ("codex_shim", "codexShim", "$HOME/.config/tessera/bin/codex", codexShimScript, true),
            ("integration", "integration", "$HOME/.config/tessera/agent-lifecycle.sh", shellIntegration, false),
            ("claude_legacy", "claudeLegacy", "$HOME/.config/tessera/claude-agent-hooks.json", claudeSettings, false),
        ]
    }

    public static func makeStatusCommand(requireNativeHost: Bool = false) -> String {
        let prefix = shellQuote(statusMarker)
        let diagnosticPrefix = shellQuote(installationDiagnosticMarker)
        let line = shellQuote(rcMarkerLine)
        let bashLoginLine = shellQuote(bashLoginMarkerLine)
        let staticFiles = ownedFiles
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
        }.joined(separator: " && ") + (requireNativeHost ? " && \(nativeHostCurrencyCheck)" : "")
        let checksumArguments = staticFiles.map { "\($0.1)=%s" }.joined(separator: " ")
        let checksumValues = staticFiles.map { "\"$tessera_\($0.0)\"" }.joined(separator: " ")
        let codexSignatures = ownedHookCommands(canonical: codexHooks).map {
            "grep -Fq \(shellQuote(jsonStringContents(hookStatusSignature($0)))) \"$codex_hooks_target\" || tessera_codex_hooks=mismatch"
        }.joined(separator: "; ")
        let claudeSignatures = ownedHookCommands(canonical: claudeSettings).map {
            let signature = jsonStringContents(hookStatusSignature($0))
            // Native forwarding has a second quoted path after the executable,
            // unlike lifecycle commands. Accept either valid JSON slash spelling.
            return "grep -Fq -e \(shellQuote(signature)) -e \(shellQuote(signature.replacingOccurrences(of: "/", with: "\\/"))) \"$claude_settings_target\" || tessera_claude_hooks=mismatch"
        }.joined(separator: "; ")
        let kimiStart = shellQuote(kimiHooksStartMarker)
        let kimiEnd = shellQuote(kimiHooksEndMarker)
        return "\(makeHostDiagnosticCommand()); \(fileBindings); codex_hooks_target=\"${CODEX_HOME:-$HOME/.codex}/hooks.json\"; claude_settings_target=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json\"; kimi_config_target=\"${KIMI_CODE_HOME:-$HOME/.kimi-code}/config.toml\"; tessera_zshrc=\"${ZDOTDIR:-$HOME}/.zshrc\"; rc_ok=1; case \"${SHELL##*/}\" in zsh) tessera_primary_rc=\"$tessera_zshrc\" ;; *) tessera_primary_rc=\"$HOME/.bashrc\" ;; esac; grep -qFx \(line) \"$tessera_primary_rc\" 2>/dev/null || rc_ok=0; tessera_bash_login=''; if [ \"${SHELL##*/}\" = bash ]; then for tessera_candidate in \"$HOME/.bash_profile\" \"$HOME/.bash_login\" \"$HOME/.profile\"; do if [ -e \"$tessera_candidate\" ]; then tessera_bash_login=\"$tessera_candidate\"; break; fi; done; [ -n \"$tessera_bash_login\" ] || tessera_bash_login=\"$HOME/.bash_profile\"; grep -qFx \(bashLoginLine) \"$tessera_bash_login\" 2>/dev/null || rc_ok=0; fi; if [ \"$rc_ok\" -eq 1 ]; then tessera_rc=current; else tessera_rc=missing; fi; if command -v cksum >/dev/null 2>&1; then tessera_cksum=available; else tessera_cksum=unavailable; fi; tessera_checksum() { cksum \"$1\" 2>/dev/null | awk '{print $1 \":\" $2}'; }; \(checksumProbes); if [ -r \"$codex_hooks_target\" ] && [ -r \"$claude_settings_target\" ] && [ -r \"$kimi_config_target\" ]; then tessera_configs=present; else tessera_configs=missing; fi; tessera_codex_hooks=match; [ -r \"$codex_hooks_target\" ] || tessera_codex_hooks=mismatch; \(codexSignatures); tessera_codex_resume=match; grep -Fq 'startup|resume|clear|compact' \"$codex_hooks_target\" || tessera_codex_resume=mismatch; tessera_claude_hooks=match; [ -r \"$claude_settings_target\" ] || tessera_claude_hooks=mismatch; \(claudeSignatures); \(tomlValidatorSetup); tessera_kimi_hooks=match; [ -r \"$kimi_config_target\" ] || tessera_kimi_hooks=mismatch; [ \"$(grep -cFx \(kimiStart) \"$kimi_config_target\" 2>/dev/null)\" = 1 ] || tessera_kimi_hooks=mismatch; [ \"$(grep -cFx \(kimiEnd) \"$kimi_config_target\" 2>/dev/null)\" = 1 ] || tessera_kimi_hooks=mismatch; tessera_toml_valid \"$kimi_config_target\" || tessera_kimi_hooks=mismatch; grep -Fq 'agent-lifecycle-hook.sh\\\" kimi SessionStart' \"$kimi_config_target\" || tessera_kimi_hooks=mismatch; grep -Fq 'agent-lifecycle-hook.sh\\\" kimi Stop idle' \"$kimi_config_target\" || tessera_kimi_hooks=mismatch; if \(missingFiles); then tessera_files=missing; else tessera_files=present; fi; printf '%s files=%s configs=%s rc=%s cksum=%s \(checksumArguments) codexHooks=%s codexResume=%s claudeHooks=%s kimiHooks=%s kimiToml=%s\\n' \(diagnosticPrefix) \"$tessera_files\" \"$tessera_configs\" \"$tessera_rc\" \"$tessera_cksum\" \(checksumValues) \"$tessera_codex_hooks\" \"$tessera_codex_resume\" \"$tessera_claude_hooks\" \"$tessera_kimi_hooks\" \"$tessera_toml\"; \(installedVersionProbe); if [ \"$tessera_installed_newer\" = 1 ]; then if [ \"$tessera_installed_floor\" -le \(integrationVersion) ] && [ \"$tessera_files\" = present ] && [ \"$tessera_configs\" = present ] && [ \"$tessera_rc\" = current ]; then printf '%s newer:%s\\n' \(prefix) \"$tessera_installed_version\"; else printf '%s unsupported:%s\\n' \(prefix) \"$tessera_installed_version\"; fi; elif [ \"$tessera_files\" != present ] || [ \"$tessera_configs\" != present ] || [ \"$tessera_rc\" != current ]; then printf '%s missing\\n' \(prefix); elif \(checksumChecks) && [ \"$tessera_codex_hooks\" = match ] && [ \"$tessera_codex_resume\" = match ] && [ \"$tessera_claude_hooks\" = match ] && [ \"$tessera_kimi_hooks\" = match ]; then printf '%s current\\n' \(prefix); else printf '%s outdated:%s\\n' \(prefix) \"$tessera_installed_version\"; fi"
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

    private static func makeAtomicKimiConfigWriteCommand(
        mergedContents: String,
        expectedContents: String?
    ) -> String {
        let expectedCheck: String
        if let expectedContents {
            let expectedBase64 = Data(expectedContents.utf8).base64EncodedString()
            expectedCheck = #"[ -r "$tessera_kimi_config_target" ] && [ "$(base64 < "$tessera_kimi_config_target" 2>/dev/null | tr -d '\n')" = \#(shellQuote(expectedBase64)) ]"#
        } else {
            expectedCheck = #"[ ! -e "$tessera_kimi_config_target" ] && [ ! -L "$tessera_kimi_config_target" ]"#
        }
        let race = shellQuote(kimiConfigRaceMarker)
        let error = shellQuote("TESSERA_AGENT_KIMI_CONFIG_ERROR")
        return #"\#(tomlValidatorSetup); tessera_kimi_config_home="${KIMI_CODE_HOME:-$HOME/.kimi-code}"; tessera_kimi_config_target="$tessera_kimi_config_home/config.toml"; if ! { \#(expectedCheck); }; then printf '%s\n' \#(race); exit 0; fi; mkdir -p "$tessera_kimi_config_home" || exit 1; tessera_kimi_config_destination="$tessera_kimi_config_target"; if [ -L "$tessera_kimi_config_target" ]; then if command -v realpath >/dev/null 2>&1; then tessera_kimi_config_destination="$(realpath "$tessera_kimi_config_target" 2>/dev/null || true)"; elif readlink -f "$tessera_kimi_config_target" >/dev/null 2>&1; then tessera_kimi_config_destination="$(readlink -f "$tessera_kimi_config_target" 2>/dev/null || true)"; else printf '%s %s\n' \#(error) symlink-resolution-unavailable; exit 0; fi; fi; if [ -z "$tessera_kimi_config_destination" ]; then printf '%s %s\n' \#(error) invalid-destination; exit 0; fi; tessera_kimi_config_temp="$tessera_kimi_config_destination.tessera.$$"; if (umask 077; printf '%s\n' \#(mergedContents) > "$tessera_kimi_config_temp") && tessera_toml_valid "$tessera_kimi_config_temp" && chmod 600 "$tessera_kimi_config_temp"; then mv -f "$tessera_kimi_config_temp" "$tessera_kimi_config_destination"; else rm -f "$tessera_kimi_config_temp"; printf '%s %s\n' \#(error) merge-not-valid-toml; exit 0; fi"#
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

    public static func posixChecksumAndLength(_ value: String) -> String {
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
        return "tessera_readiness=none; tessera_readiness_line=\"$(tail -n 1 \"$HOME/.config/tessera/codex-readiness-diagnostics.log\" 2>/dev/null || true)\"; tessera_readiness_value=\"$(printf '%s\\n' \"$tessera_readiness_line\" | sed -n 's/.* result=\\([A-Za-z-]*\\).*/\\1/p')\"; case \"$tessera_readiness_value\" in trusted|not-trusted|explicitly-bypassed|disabled-by-arguments|invalid-arguments|deferred-to-provider-hook|invalid-cwd|probe-setup-failed|app-server-start-failed|initialize-timeout|hooks-list-timeout|handler-missing|handler-mismatch|handler-disabled|handler-untrusted) tessera_readiness=\"$tessera_readiness_value\" ;; esac; tessera_lifecycle_provider=none; tessera_lifecycle_event=none; tessera_lifecycle_state=none; tessera_lifecycle_reason=none; tessera_lifecycle_phase=none; tessera_agent_pid=none; tessera_pane=none; tessera_terminal=none; tessera_tmux_state=none; tessera_terminal_emission=none; tessera_lifecycle_line=\"$(tail -n 1 \"$HOME/.config/tessera/agent-lifecycle-diagnostics.log\" 2>/dev/null || true)\"; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* provider=\\([A-Za-z]*\\).*/\\1/p')\"; case \"$tessera_value\" in claude|codex|kimi) tessera_lifecycle_provider=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* event=\\([A-Za-z]*\\).*/\\1/p')\"; case \"$tessera_value\" in SessionStart|SubagentStart|SubagentStop|UserPromptSubmit|PreToolUse|PostToolUse|PermissionRequest|Notification|Stop|StopFailure|SessionEnd|WrapperExit) tessera_lifecycle_event=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* state=\\([A-Za-z]*\\).*/\\1/p')\"; case \"$tessera_value\" in waitingForInput|working|idle|unavailable) tessera_lifecycle_state=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* reason=\\([A-Za-z-]*\\).*/\\1/p')\"; case \"$tessera_value\" in session-start|verified-trusted-empty-composer|verified-configured-empty-composer|subagent-start|subagent-stop|agent-turn|permission|question|deferred-question|idle-prompt|turn-stopped|turn-failed|session-ended) tessera_lifecycle_reason=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* phase=\\([A-Za-z]*\\).*/\\1/p')\"; case \"$tessera_value\" in received|resolved) tessera_lifecycle_phase=\"$tessera_value\" ;; esac; for tessera_field in agentPid pane terminal; do tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n \"s/.* $tessera_field=\\([A-Za-z]*\\).*/\\1/p\")\"; case \"$tessera_value\" in present|absent) case \"$tessera_field\" in agentPid) tessera_agent_pid=\"$tessera_value\" ;; pane) tessera_pane=\"$tessera_value\" ;; terminal) tessera_terminal=\"$tessera_value\" ;; esac ;; esac; done; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* tmuxState=\\([A-Za-z-]*\\).*/\\1/p')\"; case \"$tessera_value\" in written|failed|not-applicable|deferred|stale) tessera_tmux_state=\"$tessera_value\" ;; esac; tessera_value=\"$(printf '%s\\n' \"$tessera_lifecycle_line\" | sed -n 's/.* terminalEmission=\\([A-Za-z-]*\\).*/\\1/p')\"; case \"$tessera_value\" in written|failed|unwritable|absent|encoding-missing|deferred) tessera_terminal_emission=\"$tessera_value\" ;; esac; printf '%s readiness=%s lifecycleProvider=%s lifecycleEvent=%s lifecycleState=%s lifecycleReason=%s lifecyclePhase=%s agentPid=%s pane=%s terminal=%s tmuxState=%s terminalEmission=%s\\n' \(prefix) \"$tessera_readiness\" \"$tessera_lifecycle_provider\" \"$tessera_lifecycle_event\" \"$tessera_lifecycle_state\" \"$tessera_lifecycle_reason\" \"$tessera_lifecycle_phase\" \"$tessera_agent_pid\" \"$tessera_pane\" \"$tessera_terminal\" \"$tessera_tmux_state\" \"$tessera_terminal_emission\""
    }

    /// Checks whether one of the exact foreground shell PIDs loaded an
    /// integration whose shell script this one still serves (see
    /// `shellIntegrationCompatibleFrom`). The marker includes the process
    /// start identity from Linux `/proc` or `ps lstart`, preventing a stale
    /// file from matching a later process that reused the same PID.
    public static func makeShellStatusCommand(
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
        // A shell counts once it loaded any release since the shell floor: an
        // older one left the same environment this script would, and a newer
        // app's shell integration keeps serving this app while the installed
        // floor admits it, which the installation probe decides separately.
        let versionHelpers = #"tessera_loaded_ok() { case "$1" in ''|*[!0-9]*|??????*) return 1 ;; esac; [ "$1" -ge \#(shellIntegrationCompatibleFrom) ]; }; tessera_env_version() { sed -n 's/^'"$1"'=\([0-9]\{1,5\}\)$/\1/p' | head -n 1; }; "#
        func environmentCheck(tokenize: Bool) -> String {
            let source = tokenize
                ? #"printf '%s\n' "$tessera_environment" | tr ' \t' '\n\n'"#
                : #"printf '%s\n' "$tessera_environment""#
            return #"tessera_iv="$(\#(source) | tessera_env_version TESSERA_AGENT_INTEGRATION_VERSION)"; tessera_sv="$(\#(source) | tessera_env_version TESSERA_AGENT_SHIM_VERSION)"; if tessera_loaded_ok "$tessera_iv" && [ "$tessera_iv" = "$tessera_sv" ]; then active=1; tessera_proof=inherited-environment; break; fi; "#
        }
        let inheritedChecks = allowInheritedEnvironment
            ? #"if [ -r "/proc/$tessera_pid/environ" ]; then tessera_environment="$(tr '\000' '\n' < "/proc/$tessera_pid/environ" 2>/dev/null)"; \#(environmentCheck(tokenize: false))fi; tessera_environment="$(ps eww -p "$tessera_pid" -o args= 2>/dev/null)"; \#(environmentCheck(tokenize: true))"#
            : ""
        let identityCheck = #"if [ -r "$marker" ]; then tessera_markers=$((tessera_markers + 1)); tessera_marker_value="$(cat "$marker" 2>/dev/null)"; tessera_marker_version="${tessera_marker_value%%[|]*}"; if [ "$start" != 'ps:' ] && [ "$tessera_marker_value" = "$tessera_marker_version|$start|$tessera_marker_version" ] && tessera_loaded_ok "$tessera_marker_version"; then tessera_identities=$((tessera_identities + 1)); active=1; tessera_proof=process-identity; break; fi; fi; "#
        return "\(versionHelpers)active=0; tessera_candidates=0; tessera_markers=0; tessera_identities=0; tessera_proof=none; for tessera_pid in \(pidList); do tessera_candidates=$((tessera_candidates + 1)); \(inheritedChecks)marker=\"$HOME/.config/tessera/active-shells/$tessera_pid\"; start=''; if [ -r \"/proc/$tessera_pid/stat\" ]; then start=\"proc:$(sed 's/^.*) //' \"/proc/$tessera_pid/stat\" 2>/dev/null | awk '{print $20}')\"; fi; if [ -z \"$start\" ] || [ \"$start\" = 'proc:' ]; then start=\"ps:$(ps -o lstart= -p \"$tessera_pid\" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')\"; fi; \(identityCheck)done; printf '%s proof=%s candidates=%s markers=%s identities=%s\\n' \(diagnosticPrefix) \"$tessera_proof\" \"$tessera_candidates\" \"$tessera_markers\" \"$tessera_identities\"; if [ \"$active\" -eq 1 ]; then printf '%s active\\n' \(prefix); else printf '%s inactive\\n' \(prefix); fi"
    }

    public static func parseShellStatus(_ output: String) -> Bool? {
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

    public static func parseShellDiagnostic(_ output: String) -> String? {
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

    public static func parseHostDiagnostic(_ output: String) -> String? {
        let pattern = #"^readiness=(none|trusted|not-trusted|explicitly-bypassed|disabled-by-arguments|invalid-arguments|deferred-to-provider-hook|invalid-cwd|probe-setup-failed|app-server-start-failed|initialize-timeout|hooks-list-timeout|handler-missing|handler-mismatch|handler-disabled|handler-untrusted) lifecycleProvider=(none|claude|codex|kimi) lifecycleEvent=(none|SessionStart|SubagentStart|SubagentStop|UserPromptSubmit|PreToolUse|PostToolUse|PermissionRequest|Notification|Stop|StopFailure|SessionEnd|WrapperExit) lifecycleState=(none|waitingForInput|working|idle|unavailable) lifecycleReason=(none|session-start|verified-trusted-empty-composer|verified-configured-empty-composer|subagent-start|subagent-stop|agent-turn|permission|question|deferred-question|idle-prompt|turn-stopped|turn-failed|session-ended) lifecyclePhase=(none|received|resolved) agentPid=(none|present|absent) pane=(none|present|absent) terminal=(none|present|absent) tmuxState=(none|written|failed|not-applicable|deferred|stale) terminalEmission=(none|written|failed|unwritable|absent|encoding-missing|deferred)$"#
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

    public static func parseInstallationDiagnostic(_ output: String) -> String? {
        // Mirrors the status command's printf, field for field: the per-file
        // components come from the same table so adding a file cannot desync
        // the parser again (it once silently rejected every real line).
        let component = #"(match|mismatch|missing|unavailable)"#
        let fileFields = ownedFiles.map { "\($0.1)=\(component)" }.joined(separator: " ")
        let pattern = #"^files=(present|missing) configs=(present|missing) rc=(current|missing) cksum=(available|unavailable) "# + fileFields + #" codexHooks=(match|mismatch) codexResume=(match|mismatch) claudeHooks=(match|mismatch) kimiHooks=(match|mismatch) kimiToml=(available|unavailable)$"#
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

    /// A version read from a host manifest; anything implausible is unknown.
    private static func reportedVersion(_ text: Substring) -> Int? {
        guard (1...5).contains(text.count),
              text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), (1...65_535).contains(value)
        else { return nil }
        return value
    }

    public static func parseStatus(_ output: String) -> AgentLifecycleHostInstallation? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "\(statusMarker) "
            guard value.hasPrefix(prefix) else { continue }
            let status = String(value.dropFirst(prefix.count))
            if status == "current" { return .current }
            if status == "missing" { return .missing }
            if status.hasPrefix("outdated:") {
                return .outdated(version: reportedVersion(status.dropFirst("outdated:".count)))
            }
            // Written by a newer app whose floor admits this one: usable as is.
            if status.hasPrefix("newer:") { return .current }
            if status.hasPrefix("unsupported:") {
                return .requiresAppUpdate(version: reportedVersion(status.dropFirst("unsupported:".count)))
            }
        }
        return nil
    }

    /// One fixed, content-free process inventory program. Platform adapters
    /// contribute only an already-validated carrier marker or owned root PID;
    /// Core owns every executable, parser field, and foreground heuristic.
    public static func makeProcessDiscoveryCommand(scope: AgentIntegrationProcessDiscoveryScope) -> String {
        let rootSetup: String
        switch scope {
        case let .rootProcess(processID):
            rootSetup = "roots=' \(processID)'"
        case let .routeMarker(marker):
            let quotedMarker = shellQuote("LC_TESSERA_ROUTE=\(marker)")
            rootSetup = """
            roots=''
            if [ -d /proc ]; then
              for tessera_env in /proc/[0-9]*/environ; do
                [ -r "$tessera_env" ] || continue
                if tr '\\000' '\\n' < "$tessera_env" 2>/dev/null | grep -qFx \(quotedMarker); then
                  tessera_pid=${tessera_env#/proc/}; tessera_pid=${tessera_pid%/environ}
                  case "$tessera_pid" in ''|*[!0-9]*) ;; *) roots="$roots $tessera_pid" ;; esac
                fi
              done
            else
              roots=" $(ps eww -axo pid=,command= 2>/dev/null | awk -v needle=\(quotedMarker) 'index($0, needle) { print $1 }')"
            fi
            """
        }
        return """
        set -eu
        \(rootSetup)
        case "$roots" in *[0-9]*) ;; *) exit 1 ;; esac
        printf '%s ' 'TESSERA_AGENT_PROCESS_DISCOVERY'
        tessera_processes="$(ps -eo pid=,ppid=,pgid=,tpgid=,comm= 2>/dev/null || ps -axo pid=,ppid=,pgid=,tpgid=,comm= 2>/dev/null || ps -axo pid=,ppid=,pgid=,stat=,comm= 2>/dev/null | awk '{ tpgid = index($4, "+") ? $3 : -1; print $1, $2, $3, tpgid, $5 }')"
        printf '%s\\n' "$tessera_processes" | awk -v roots="$roots" '
        BEGIN { count=split(roots, seed, " "); for (i=1;i<=count;i++) if (seed[i] ~ /^[0-9]+$/) keep[seed[i]]=1 }
        { pid[NR]=$1; ppid[NR]=$2; pgid[NR]=$3; tpgid[NR]=$4; exe[NR]=$5 }
        END {
          for (round=0;round<128;round++) {
            changed=0
            for (i=1;i<=NR;i++) if (!keep[pid[i]] && keep[ppid[i]]) { keep[pid[i]]=1; changed=1 }
            if (!changed) break
          }
          printf "{\\\"v\\\":1,\\\"kind\\\":\\\"processDiscovery\\\",\\\"processes\\\":["
          emitted=0
          for (i=1;i<=NR && emitted<128;i++) if (keep[pid[i]] && exe[i] ~ /^[A-Za-z0-9._+@:\\/-]+$/) {
            if (emitted) printf ","
            foreground=(tpgid[i] > 0 && pgid[i] == tpgid[i]) ? "true" : "false"
            printf "{\\\"pid\\\":%d,\\\"ppid\\\":%d,\\\"executable\\\":\\\"%s\\\",\\\"foreground\\\":%s}", pid[i], ppid[i], exe[i], foreground
            emitted++
          }
          printf "]}\\n"
        }'
        """.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Parses exactly one bounded discovery frame and reduces foreground
    /// semantics through Core's shell/provider registry.
    public static func parseProcessDiscovery(
        _ output: String,
        scope: AgentIntegrationProcessDiscoveryScope? = nil
    ) -> AgentIntegrationProcessDiscoveryResult? {
        guard output.utf8.count <= 65_536 else { return nil }
        let prefix = "TESSERA_AGENT_PROCESS_DISCOVERY "
        let frames = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : nil
        }
        guard frames.count == 1,
              let data = frames[0].data(using: .utf8),
              let frame = try? JSONDecoder().decode(ProcessDiscoveryFrame.self, from: data),
              frame.version == 1, frame.kind == "processDiscovery", frame.processes.count <= 128
        else { return nil }
        let processes = frame.processes
        guard Set(processes.map(\.processID)).count == processes.count else { return nil }
        if case .some(.routeMarker(_)) = scope, processes.isEmpty { return nil }
        if case let .some(.rootProcess(root)) = scope {
            let parents = Dictionary(uniqueKeysWithValues: processes.map { ($0.processID, $0.parentProcessID) })
            guard parents[root] != nil else { return nil }
            for process in processes where process.processID != root {
                var candidate = process.processID
                var visited: Set<Int> = []
                var reachesRoot = false
                while candidate != root, visited.insert(candidate).inserted, visited.count <= 128 {
                    guard let parent = parents[candidate] ?? nil else { break }
                    candidate = parent
                }
                reachesRoot = candidate == root
                guard reachesRoot else { return nil }
            }
        }

        let foregroundProcesses = processes.filter(\.foreground)
        let classification = AgentIntegrationForegroundClassifier.classify(
            executables: foregroundProcesses.map(\.executable)
        )
        let shellIDs = foregroundProcesses.compactMap { process in
            AgentIntegrationForegroundClassifier.isSupportedShell(process.executable)
                ? process.processID
                : nil
        }
        let providerProcessIDs = foregroundProcesses.compactMap { process in
            let matched = AgentProviderRegistry.builtIn.providers(matching: [AgentProcessDescriptor(executableName: process.executable)!])
            return matched.isEmpty ? nil : process.processID
        }
        let hookProviders: Set<AgentProviderID> = [.claude, .codex, .kimi]
        let lifecycleProviderProcessIDs = foregroundProcesses.compactMap { process in
            let matched = AgentProviderRegistry.builtIn.providers(matching: [AgentProcessDescriptor(executableName: process.executable)!])
            return matched.contains(where: { hookProviders.contains($0) }) ? process.processID : nil
        }
        return .init(
            processes: processes,
            foreground: classification.foreground,
            foregroundShellProcessIDs: shellIDs.sorted(),
            foregroundProviderProcessIDs: providerProcessIDs.sorted(),
            foregroundLifecycleProviderProcessIDs: lifecycleProviderProcessIDs.sorted(),
            foregroundRequiresLifecycleHook: !lifecycleProviderProcessIDs.isEmpty
        )
    }

    private struct ProcessDiscoveryFrame: Decodable {
        let version: Int
        let kind: String
        let processes: [AgentIntegrationDiscoveredProcess]
        enum CodingKeys: String, CodingKey { case version = "v", kind, processes }
    }

    private static func shellQuote(_ string: String) -> String {
        "'\(string.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
