#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-app-transport-tests.sh RUN_DIR\n' >&2; exit 2; }
TEST_FILTER="${2:-TesseraTests/RealHostTransportIntegrationTests}"

load_fixture_config
ensure_fixture_credentials
require_command base64
require_command jq
require_command xcodebuild
require_command xcrun

udid="$($HERE/ensure-test-simulator.sh | tail -n 1)"
derived_data="$FIXTURE_STATE/DerivedData"
result_bundle="$RUN_DIR/programmatic/real-host-transports.xcresult"
mkdir -p "$derived_data" "$(dirname "$result_bundle")"
rm -rf "$result_bundle"

password="$(fixture_password)"
config_json="$(
  jq -cn \
    --arg stableHost "$TESSERA_FIXTURE_STABLE_HOST" \
    --arg chaosHost "$TESSERA_FIXTURE_CHAOS_HOST" \
    --argjson port "$TESSERA_FIXTURE_APP_PORT" \
    --arg user "$TESSERA_FIXTURE_USER" \
    --arg password "$password" \
    --argjson echoPort 18080 \
    --argjson localForwardPort 39081 \
    '{stableHost: $stableHost, chaosHost: $chaosHost, port: $port, user: $user, password: $password, echoPort: $echoPort, localForwardPort: $localForwardPort}'
)"
config_b64="$(printf '%s' "$config_json" | base64 | tr -d '\n')"

cleanup() {
  xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_REAL_HOST_CONFIG_B64 \
    >/dev/null 2>&1 || true
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

xcrun simctl spawn "$udid" launchctl setenv \
  TESSERA_REAL_HOST_CONFIG_B64 "$config_b64"

xcodebuild test \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:"$TEST_FILTER"
