#!/usr/bin/env bash
# Private finite-corpus native paint benchmark; optional owned loopback SSH.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
[[ $# -ge 2 && $# -le 3 ]] || die 'usage: run-native-agent-paint-tests.sh PRIVATE_MANIFEST FRESH_OUTPUT [--phone]'
PAINT_MANIFEST="$1"
PAINT_OUTPUT="$2"
PAINT_RUN="$(mktemp -d /private/tmp/tessera-paint-run.XXXXXXXX)"
export TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera Native Paint iPad'
if [[ "${3:-}" == --phone ]]; then
  export TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
  export TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera Native Paint iPhone'
elif [[ -n "${3:-}" ]]; then die 'expected --phone'; fi
export TESSERA_INTEGRATION_SIMULATOR_RUN_ID="paint-$(date -u +%Y%m%dT%H%M%SZ)-$$"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$PAINT_RUN/simulator"
export TESSERA_INTEGRATION_FIXTURE_STATE_DIR="$PAINT_RUN/state"
export TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$PAINT_RUN/simulator/simulator_udid"
cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  trap - EXIT
  delete_owned_test_simulator "$TESSERA_INTEGRATION_SIMULATOR_UDID_FILE" || status=1
  printf 'Native paint runner evidence: %s\n' "$PAINT_RUN"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"$HERE/ensure-test-simulator.sh" >"$PAINT_RUN/simulator.log" 2>&1
IFS= read -r PAINT_DEVICE <"$TESSERA_INTEGRATION_SIMULATOR_UDID_FILE"
integration_xcodebuild build -project "$REPO_ROOT/Tessera.xcodeproj" -scheme Tessera \
  -destination "platform=iOS Simulator,id=$PAINT_DEVICE" -derivedDataPath /private/tmp/tessera-ingestion-derived \
  -quiet >"$PAINT_RUN/build.log" 2>&1
if [[ "${3:-}" != --phone ]]; then
  integration_xcodebuild test -project "$REPO_ROOT/Tessera.xcodeproj" -scheme Tessera \
    -destination "platform=iOS Simulator,id=$PAINT_DEVICE" -derivedDataPath /private/tmp/tessera-ingestion-derived \
    -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 60 \
    -only-testing:TesseraUITests/VisualCaptureProbe/testSetPrivatePaintSimulatorLandscape \
    -resultBundlePath "$PAINT_RUN/orientation.xcresult" >"$PAINT_RUN/orientation.log" 2>&1
fi
paint_options=()
if [[ "${TESSERA_NATIVE_PAINT_SSH:-0}" == 1 ]]; then paint_options+=(--ssh); fi
if [[ "${TESSERA_NATIVE_PAINT_LAUNCH:-0}" == 1 ]]; then paint_options+=(--launch-inclusive); fi
python3 "$REPO_ROOT/scripts/performance/agent-center/native_paint.py" ${paint_options[@]+"${paint_options[@]}"} \
  --binary "$REPO_ROOT/SharedAssets/agent-host/tessera-agent-host-darwin-arm64" \
  --app /private/tmp/tessera-ingestion-derived/Build/Products/Debug-iphonesimulator/Tessera.app \
  --manifest "$PAINT_MANIFEST" --output "$PAINT_OUTPUT" \
  --owned-device-file "$TESSERA_INTEGRATION_SIMULATOR_UDID_FILE" \
  --trials "${TESSERA_NATIVE_PAINT_TRIALS:-20}" --rtt-ms "${TESSERA_NATIVE_PAINT_RTT_MS:-50}" \
  --discovery-order "${TESSERA_NATIVE_PAINT_DISCOVERY_ORDER:-inventory-first}"
script_completed=1
