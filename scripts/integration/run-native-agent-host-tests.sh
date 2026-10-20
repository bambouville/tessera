#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
python3 "$REPO_ROOT/Tools/AgentHost/validate_artifacts.py" "$REPO_ROOT/SharedAssets/agent-host"
load_fixture_config
role="${1:-stable}"
soak_seconds="${2:-}"
if [[ -n "$soak_seconds" ]]; then
  [[ "$soak_seconds" =~ ^[0-9]+$ ]] && (( soak_seconds >= 40 && soak_seconds <= 7200 )) || die 'soak duration must be 40..7200 seconds'
fi
case "$role" in stable) host="$TESSERA_FIXTURE_STABLE_HOST" ;; chaos) host="$TESSERA_FIXTURE_CHAOS_HOST" ;; *) die 'expected stable or chaos fixture' ;; esac
arch="$(fixture_ssh "$host" uname -m)"
case "$arch" in x86_64|aarch64) ;; *) die 'unsupported fixture architecture' ;; esac
artifact="$REPO_ROOT/SharedAssets/agent-host/tessera-agent-host-linux-$arch"
[[ -f "$artifact" ]] || die 'missing precompiled host artifact'
remote="$(fixture_ssh "$host" 'mktemp -d /tmp/tessera-native-integration.XXXXXXXX')"
[[ "$remote" =~ ^/tmp/tessera-native-integration\.[A-Za-z0-9]{8}$ ]] || die 'invalid run directory'
cleanup() { fixture_ssh "$host" "rm -rf -- '$remote'"; }
trap 'fail_closed_trap cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
copy() {
  scp -q -i "$FIXTURE_STATE/client_ed25519" -P "$TESSERA_FIXTURE_APP_PORT" \
    -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=yes \
    -o "UserKnownHostsFile=$TESSERA_FIXTURE_APP_KNOWN_HOSTS" \
    "$1" "$TESSERA_FIXTURE_USER@$host:$remote/$2"
}
fixture_ssh "$host" "mkdir -p '$remote/Tools/AgentHost/tests' '$remote/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle' '$remote/Packages/TesseraCore/Tests/TesseraAgentCoreTests/Vectors'"
copy "$artifact" tessera-agent-host
copy "$REPO_ROOT/Tools/AgentHost/tests/native_mock.py" Tools/AgentHost/tests/native_mock.py
copy "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentHostDeployment.swift" Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/AgentHostDeployment.swift
# test_deployment.py stamps requests with the installer's integration version.
copy "$REPO_ROOT/Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift" Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift
copy "$REPO_ROOT/Packages/TesseraCore/Tests/TesseraAgentCoreTests/Vectors/pi-native-session.json" Packages/TesseraCore/Tests/TesseraAgentCoreTests/Vectors/pi-native-session.json
copy "$REPO_ROOT/Packages/TesseraCore/Tests/TesseraAgentCoreTests/Vectors/kimi-native-wire.json" Packages/TesseraCore/Tests/TesseraAgentCoreTests/Vectors/kimi-native-wire.json
for name in hook_sender service service_soak jsonl_reader pi_reader opencode_reader kimi_reader canonical_search codex_server deployment; do
  copy "$REPO_ROOT/Tools/AgentHost/tests/test_$name.py" "Tools/AgentHost/tests/test_$name.py"
done
fixture_ssh "$host" "chmod 700 '$remote/tessera-agent-host'; '$remote/tessera-agent-host' --version"
if [[ -n "$soak_seconds" ]]; then
  note "native $role fixture: $soak_seconds second capacity soak"
  fixture_ssh "$host" "python3 '$remote/Tools/AgentHost/tests/test_service_soak.py' '$remote/tessera-agent-host' '$soak_seconds'"
  note 'capacity soak passed; removing run-owned fixture files'
  script_completed=1
  exit 0
fi
for name in hook_sender service jsonl_reader pi_reader opencode_reader kimi_reader canonical_search codex_server; do
  note "native $role fixture: $name"
  fixture_ssh "$host" "python3 '$remote/Tools/AgentHost/tests/test_$name.py' '$remote/tessera-agent-host'"
done
if fixture_ssh "$host" 'sudo -n true' >/dev/null 2>&1; then
  note "native $role fixture: owned namespace and cross-UID context rejection"
  fixture_ssh "$host" "sudo -n python3 '$remote/Tools/AgentHost/tests/test_service.py' '$remote/tessera-agent-host' ServiceTests.test_context_rejects_same_uid_foreign_filesystem_root ServiceTests.test_context_rejects_foreign_uid_before_environment_capture"
else
  note 'SKIP privileged context rejection: fixture has no passwordless sudo'
fi
fixture_ssh "$host" "python3 '$remote/Tools/AgentHost/tests/test_deployment.py'"
note "native $role fixture tests passed; removing run-owned fixture files"
script_completed=1
