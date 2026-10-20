#!/usr/bin/env bash
# Runs the live jump-host transport tests (TesseraTests/
# JumpHostTransportIntegrationTests) on the dedicated integration simulator
# against the disposable two-droplet jump test bed. Mirrors
# run-app-transport-tests.sh; opt-in via the env-injected config.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "$HERE/../lib.sh"
# shellcheck source=lib-jump.sh
source "$HERE/lib-jump.sh"

load_jump_config
ensure_jump_credentials
require_command() { command -v "$1" >/dev/null 2>&1 || jump_die "required command is missing: $1"; }
require_command jq
require_command xcodebuild
require_command xcrun

REPO_ROOT="$(cd "$INTEGRATION_DIR/../.." && pwd)"
BUILD_ACTION=test
INGESTION_ONLY=0
TEST_SELECTION="TesseraTests/JumpHostTransportIntegrationTests"
if [[ "${1:-}" == --without-building ]]; then
  BUILD_ACTION=test-without-building
elif [[ "${1:-}" == --ingestion-only ]]; then
  INGESTION_ONLY=1
  TEST_SELECTION+='/test_jumpNativeIngestionSharesServiceAcrossIndependentSSHAndTmuxCarriers'
elif [[ -n "${1:-}" ]]; then
  printf 'usage: run-jump-transport-tests.sh [--without-building|--ingestion-only]\n' >&2
  exit 2
fi
if [[ "$INGESTION_ONLY" == 1 ]]; then
  # Direct target access and per-hop identity isolation must be proven afresh,
  # not assumed from an older fixture setup or another optional test case.
  bash "$HERE/verify-jump-fixtures.sh"
fi
udid=''
udp_opened=0
# Shares the suite-wide prebuilt Debug product; a standalone run builds into
# the same tree rather than a jump-private DerivedData.
derived_data="$(integration_derived_data)"
result_dir="$(mktemp -d "$JUMP_STATE/transport-run.XXXXXXXX")"
result_bundle="$result_dir/jump-transports.xcresult"
mkdir -p "$derived_data"

config_json="$(
  jq -cn \
    --arg bastionHost "$TESSERA_JUMP_BASTION_HOST" \
    --arg bastionPrivate "$TESSERA_JUMP_BASTION_PRIVATE" \
    --arg targetHost "$TESSERA_JUMP_TARGET_HOST" \
    --argjson port "$TESSERA_JUMP_APP_PORT" \
    --argjson innerPort "$TESSERA_JUMP_INNER_PORT" \
    --arg pwUser "$TESSERA_JUMP_PW_USER" \
    --arg bastionPassword "$(jump_password bastion)" \
    --arg targetPassword "$(jump_password target)" \
    --argjson echoPort 18080 \
    --argjson localForwardPort 39181 \
    '{bastionHost: $bastionHost, bastionPrivate: $bastionPrivate,
      targetHost: $targetHost, port: $port, innerPort: $innerPort,
      pwUser: $pwUser, bastionPassword: $bastionPassword,
      targetPassword: $targetPassword, echoPort: $echoPort,
      localForwardPort: $localForwardPort, moshUDPAllowed: false}'
)"
config_b64="$(printf '%s' "$config_json" | base64 | tr -d '\n')"

cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  trap - EXIT
  if [[ -n "$udid" ]]; then
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_JUMP_HOST_CONFIG_B64 \
      >/dev/null 2>&1 || true
  fi
  # The UDP-blocked fallback test necessarily strands a mosh-server per
  # run (bootstrap succeeds, client contact never arrives) — reap them.
  if [[ "$udp_opened" == 1 ]]; then
    jump_control_ssh "$TESSERA_JUMP_TARGET_HOST" /usr/local/sbin/tessera-jump-mosh block >/dev/null 2>&1 || status=1
  fi
  if [[ "$INGESTION_ONLY" != 1 ]]; then
    jump_control_ssh "$TESSERA_JUMP_TARGET_HOST" \
    "/usr/local/sbin/tessera-jump-mosh block; pkill -u '$TESSERA_JUMP_PW_USER' mosh-server 2>/dev/null; pkill -u '$TESSERA_JUMP_KEY_USER' mosh-server 2>/dev/null; true" \
      >/dev/null 2>&1 || true
  fi
  delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid" || status=1
  printf 'Jump transport evidence: %s\n' "$result_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

udid="$("$INTEGRATION_DIR/ensure-test-simulator.sh" | tail -n 1)"

xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_JUMP_HOST_CONFIG_B64 "$config_b64"

installer_selection=()
if [[ "$INGESTION_ONLY" == 1 ]]; then
  installer_selection=(-only-testing:TesseraTests/AppleAgentServicesTests/testInstallerRemoteFailureCodeSurvivesChannelTeardownWithoutLeakingTraceback
    -only-testing:TesseraTests/AppleAgentServicesTests/testInstallerCallerCancellationWinsQueuedSuccessAndRemoteFailure)
fi
xcodebuild "$BUILD_ACTION" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:"$TEST_SELECTION" ${installer_selection[@]+"${installer_selection[@]}"}

if [[ "$INGESTION_ONLY" == 1 ]]; then
  xcrun xcresulttool get test-results tests --path "$result_bundle" >"$result_dir/tests.json"
  jq -e --arg name 'test_jumpNativeIngestionSharesServiceAcrossIndependentSSHAndTmuxCarriers' '
    [.. | objects | select(.nodeType? == "Test Case" and ((.name? // "") | contains($name)))] |
    length == 1 and .[0].result == "Passed"
  ' "$result_dir/tests.json" >/dev/null || jump_die 'native ingestion case was skipped, missing or failed'
  jump_note 'SSH and SSH+tmux native ingestion jump gate complete; continuing with mosh'
fi

# A second, focused pass opens the target's UDP range long enough to prove
# plain mosh and the mosh+tmux SSH side channel. The full pass above keeps UDP
# blocked so the automatic SSH fallback remains deterministic.
udp_opened=1
jump_control_ssh "$TESSERA_JUMP_TARGET_HOST" \
  /usr/local/sbin/tessera-jump-mosh allow
allowed_config_b64="$(
  printf '%s' "$config_json" \
    | jq -c '.moshUDPAllowed = true' \
    | base64 \
    | tr -d '\n'
)"
xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_JUMP_HOST_CONFIG_B64 "$allowed_config_b64"
allowed_result_bundle="$result_dir/jump-mosh-allowed.xcresult"
allowed_selection=(-only-testing:"TesseraTests/JumpHostTransportIntegrationTests/test_jumpNativeIngestionSharesServiceAcrossMoshAndMoshTmuxCarriers")
if [[ "$INGESTION_ONLY" != 1 ]]; then
  allowed_selection+=(-only-testing:"TesseraTests/JumpHostTransportIntegrationTests/test_jumpMosh_connectsWhenUDPIsReachable"
    -only-testing:"TesseraTests/JumpHostTransportIntegrationTests/test_jumpMoshTmux_sideChannelTraversesChain")
fi
xcodebuild "$BUILD_ACTION" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$allowed_result_bundle" \
  "${allowed_selection[@]}"
xcrun xcresulttool get test-results tests --path "$allowed_result_bundle" >"$result_dir/mosh-tests.json"
jq -e --arg name 'test_jumpNativeIngestionSharesServiceAcrossMoshAndMoshTmuxCarriers' '
  [.. | objects | select(.nodeType? == "Test Case" and ((.name? // "") | contains($name)))] |
  length == 1 and .[0].result == "Passed"
' "$result_dir/mosh-tests.json" >/dev/null || jump_die 'native mosh ingestion case was skipped, missing or failed'
jump_control_ssh "$TESSERA_JUMP_TARGET_HOST" \
  /usr/local/sbin/tessera-jump-mosh block
udp_opened=0

jump_note "jump transport tests complete"
script_completed=1
