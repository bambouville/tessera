#!/usr/bin/env bash
# Runs the live jump-host transport tests (TesseraTests/
# JumpHostTransportIntegrationTests) on the dedicated integration simulator
# against the disposable two-droplet jump test bed. Mirrors
# run-app-transport-tests.sh; opt-in via the env-injected config.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-jump.sh
source "$HERE/lib-jump.sh"

load_jump_config
ensure_jump_credentials
require_command() { command -v "$1" >/dev/null 2>&1 || jump_die "required command is missing: $1"; }
require_command jq
require_command xcodebuild
require_command xcrun

REPO_ROOT="$(cd "$INTEGRATION_DIR/../.." && pwd)"
udid=''
derived_data="$JUMP_STATE/DerivedData"
result_bundle="$JUMP_STATE/jump-transports.xcresult"
mkdir -p "$derived_data"
rm -rf "$result_bundle"

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
  if [[ -n "$udid" ]]; then
    xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_JUMP_HOST_CONFIG_B64 \
      >/dev/null 2>&1 || true
  fi
  # The UDP-blocked fallback test necessarily strands a mosh-server per
  # run (bootstrap succeeds, client contact never arrives) — reap them.
  jump_control_ssh "$TESSERA_JUMP_TARGET_HOST" \
    "/usr/local/sbin/tessera-jump-mosh block; pkill -u '$TESSERA_JUMP_PW_USER' mosh-server 2>/dev/null; pkill -u '$TESSERA_JUMP_KEY_USER' mosh-server 2>/dev/null; true" \
    >/dev/null 2>&1 || true
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid" || true
  fi
}
trap cleanup EXIT

udid="$("$INTEGRATION_DIR/ensure-test-simulator.sh" | tail -n 1)"

xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_JUMP_HOST_CONFIG_B64 "$config_b64"

xcodebuild test \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:"TesseraTests/JumpHostTransportIntegrationTests"

# A second, focused pass opens the target's UDP range long enough to prove
# plain mosh and the mosh+tmux SSH side channel. The full pass above keeps UDP
# blocked so the automatic SSH fallback remains deterministic.
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
allowed_result_bundle="$JUMP_STATE/jump-mosh-allowed.xcresult"
rm -rf "$allowed_result_bundle"
xcodebuild test \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$allowed_result_bundle" \
  -only-testing:"TesseraTests/JumpHostTransportIntegrationTests/test_jumpMosh_connectsWhenUDPIsReachable" \
  -only-testing:"TesseraTests/JumpHostTransportIntegrationTests/test_jumpMoshTmux_sideChannelTraversesChain"
jump_control_ssh "$TESSERA_JUMP_TARGET_HOST" \
  /usr/local/sbin/tessera-jump-mosh block

jump_note "jump transport tests complete"
