#!/usr/bin/env bash
# Focused driver for SwipePad's automation-quiescence gate: launches the
# dictation harness (real repeatForever pulse) with TESSERA_STATIC_RINGS and
# proves ordinary XCUITest taps complete without idle stalls.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || {
  printf 'usage: run-swipepad-quiescence-tests.sh RUN_DIR\n' >&2
  exit 2
}

udid=''
derived_data="$FIXTURE_STATE/SwipePadQuiescenceDerivedData"
result_dir="$RUN_DIR/programmatic"
result_bundle="$result_dir/swipepad-quiescence.xcresult"
mkdir -p "$derived_data" "$result_dir"
rm -rf "$result_bundle"

cleanup() {
  delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid" || true
}
trap cleanup EXIT

udid="$("$HERE/ensure-test-simulator.sh" | tail -n 1)"

xcodebuild test \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  -only-testing:TesseraUITests/SwipePadQuiescenceHarnessTests/testStandardTapsCompleteWithStaticRings
