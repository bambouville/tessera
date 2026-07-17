#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || {
  printf 'usage: run-agent-integration-script-tests.sh RUN_DIR\n' >&2
  exit 2
}

WORK_DIR="$(mktemp -d "$RUN_DIR/agent-integration-scripts.XXXXXX")"
DUMPER="$WORK_DIR/dump-agent-integration"
MODULE_CACHE="$WORK_DIR/module-cache"
mkdir -p "$MODULE_CACHE"

swiftc -O -module-cache-path "$MODULE_CACHE" \
  "$REPO_ROOT/Tessera/AgentCenter/RemoteAgentLifecycleIntegrationInstaller.swift" \
  "$HERE/AgentIntegrationSourceDump.swift" \
  -o "$DUMPER"

# Syntax-check every generated executable and both supported interactive-shell
# source paths before exercising their behavior.
for source_name in hook launcher codex-readiness claude-shim codex-shim; do
  "$DUMPER" "$source_name" | /bin/sh -n
done
"$DUMPER" shell | /bin/bash -n
"$DUMPER" shell | /bin/zsh -n

install_in_home() {
  local home="$1"
  local login_shell="$2"
  local zdotdir="${3:-}"
  local install_output="$home/install-output.txt"
  local status_output="$home/status-output.txt"

  mkdir -p "$home"
  HOME="$home" SHELL="$login_shell" ZDOTDIR="$zdotdir" \
    CODEX_HOME="$home/.codex" CLAUDE_CONFIG_DIR="$home/.claude" \
    /bin/sh -c "$("$DUMPER" install-command)" >"$install_output"
  grep -Fq 'TESSERA_AGENT_INTEGRATION_INSTALLED' "$install_output"

  HOME="$home" SHELL="$login_shell" ZDOTDIR="$zdotdir" \
    CODEX_HOME="$home/.codex" CLAUDE_CONFIG_DIR="$home/.claude" \
    /bin/sh -c "$("$DUMPER" status-command)" >"$status_output"
  grep -Fq 'TESSERA_AGENT_INTEGRATION_STATUS current' "$status_output"
  grep -Fq 'claudeLegacy=match' "$status_output"
  python3 -m json.tool \
    "$home/.config/tessera/claude-agent-hooks.json" >/dev/null
  grep -Fq 'claude SessionStart idle session-start' \
    "$home/.config/tessera/claude-agent-hooks.json"
}

ZSH_HOME="$WORK_DIR/zsh-home"
ZDOTDIR="$ZSH_HOME/custom-zdot"
install_in_home "$ZSH_HOME" /bin/zsh "$ZDOTDIR"
HOME="$ZSH_HOME" SHELL=/bin/zsh ZDOTDIR="$ZDOTDIR" \
  /bin/zsh -f -c \
    '_tessera_agent_rc_ok=preserved; _tessera_agent_append() { printf preserved; }; eval "$("$1" persist-shell)"; [[ "$_tessera_agent_rc_ok" == preserved ]]; [[ "$(_tessera_agent_append)" == preserved ]]; eval "$("$1" persist-shell)"' \
  _ "$DUMPER"
[[ "$(grep -cF 'TESSERA-AGENT-LIFECYCLE' "$ZDOTDIR/.zshrc")" == 1 ]]
[[ ! -e "$ZSH_HOME/.zshrc" ]]

BASH_HOME="$WORK_DIR/bash-home"
install_in_home "$BASH_HOME" /bin/bash
HOME="$BASH_HOME" SHELL=/bin/bash \
  /bin/bash --noprofile --norc -c \
    '_tessera_agent_rc_ok=preserved; _tessera_agent_append() { printf preserved; }; eval "$("$1" persist-shell)"; [[ "$_tessera_agent_rc_ok" == preserved ]]; [[ "$(_tessera_agent_append)" == preserved ]]; eval "$("$1" persist-shell)"' \
  _ "$DUMPER"
[[ "$(grep -cF 'TESSERA-AGENT-LIFECYCLE' "$BASH_HOME/.bashrc")" == 1 ]]
[[ "$(grep -cF 'TESSERA-AGENT-LIFECYCLE' "$BASH_HOME/.bash_profile")" == 1 ]]

# A deterministic app-server double exercises the same machine-readable
# hooks/list contract as a real Codex install. It keeps this critical bootstrap
# gate available in CI without credentials or provider network access.
FAKE_BIN="$WORK_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/codex" <<'SH'
#!/bin/sh
app_server=0
for argument in "$@"; do
  [ "$argument" = app-server ] && app_server=1
done
[ "$app_server" -eq 1 ] || exit 0

while IFS= read -r request; do
  case "$request" in
    *'"id":1'*)
      printf '%s\n' '{"id":1,"result":{"serverInfo":{"name":"fake-codex"}}}'
      ;;
    *'"id":2'*)
      printf '{"id":2,"result":{"items":[{"key":"tessera-session-start","eventName":"sessionStart","matcher":"startup|resume|clear|compact","enabled":%s,"trustStatus":"%s","command":"\\"$HOME/.config/tessera/agent-lifecycle-hook.sh\\" codex SessionStart idle session-start"}]}}\n' \
        "${TESSERA_FAKE_CODEX_ENABLED:-true}" \
        "${TESSERA_FAKE_CODEX_TRUST_STATUS:-untrusted}"
      ;;
  esac
done
SH
chmod 700 "$FAKE_BIN/codex"

# A stale integration copy can remain earlier than a version-manager provider
# after HOME/PATH changes. Both production shims must skip any Tessera-owned
# copy, not merely the exact inode that is currently executing.
STALE_BIN="$WORK_DIR/stale-tessera-bin"
mkdir -p "$STALE_BIN"
cat >"$STALE_BIN/codex" <<'SH'
#!/bin/sh
# Tessera Agent Center Codex shim — stale test double.
exit 88
SH
cat >"$STALE_BIN/claude" <<'SH'
#!/bin/sh
# Tessera Agent Center Claude shim — stale test double.
exit 88
SH
cat >"$FAKE_BIN/claude" <<'SH'
#!/bin/sh
: >"$TESSERA_FAKE_CLAUDE_MARKER"
exit 0
SH
chmod 700 "$STALE_BIN/codex" "$STALE_BIN/claude" "$FAKE_BIN/claude"

READINESS="$ZSH_HOME/.config/tessera/agent-codex-readiness.sh"
set +e
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=untrusted \
  "$READINESS" "$FAKE_BIN/codex"
UNTRUSTED_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$READINESS" "$FAKE_BIN/codex"
TRUSTED_STATUS=$?
HOME="$ZSH_HOME" TESSERA_FAKE_CODEX_ENABLED=false \
  "$READINESS" "$FAKE_BIN/codex"
DISABLED_STATUS=$?
set -e
[[ "$UNTRUSTED_STATUS" == 2 ]]
[[ "$TRUSTED_STATUS" == 0 ]]
[[ "$DISABLED_STATUS" == 1 ]]
grep -Fq 'result=handler-untrusted' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log"
grep -Fq 'result=trusted' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log"
grep -Fq 'result=handler-disabled' \
  "$ZSH_HOME/.config/tessera/codex-readiness-diagnostics.log"

SHIM="$ZSH_HOME/.config/tessera/bin/codex"
HOME="$ZSH_HOME" \
  PATH="$ZSH_HOME/.config/tessera/bin:$STALE_BIN:$FAKE_BIN:/usr/bin:/bin" \
  TESSERA_FAKE_CODEX_TRUST_STATUS=untrusted \
  "$SHIM"
HOME="$ZSH_HOME" \
  PATH="$ZSH_HOME/.config/tessera/bin:$STALE_BIN:$FAKE_BIN:/usr/bin:/bin" \
  TESSERA_FAKE_CODEX_TRUST_STATUS=trusted \
  "$SHIM"
CLAUDE_MARKER="$WORK_DIR/fake-claude-invoked"
HOME="$ZSH_HOME" \
  PATH="$ZSH_HOME/.config/tessera/bin:$STALE_BIN:$FAKE_BIN:/usr/bin:/bin" \
  TESSERA_FAKE_CLAUDE_MARKER="$CLAUDE_MARKER" \
  "$ZSH_HOME/.config/tessera/bin/claude" --resume test-session
[[ -f "$CLAUDE_MARKER" ]]
grep -Fq 'reason=verified-configured-empty-composer' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log"
grep -Fq 'reason=verified-trusted-empty-composer' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log"
grep -Fq 'phase=resolved agentPid=present' \
  "$ZSH_HOME/.config/tessera/agent-lifecycle-diagnostics.log"

printf 'agent integration scripts: syntax, install, bash/zsh persistence, Claude compatibility, and Codex bootstrap passed\n'
