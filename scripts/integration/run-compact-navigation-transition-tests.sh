#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || {
  printf 'usage: run-compact-navigation-transition-tests.sh RUN_DIR [--without-building]\n' >&2
  exit 2
}
BUILD_ACTION=test
if [[ "${2:-}" == --without-building ]]; then
  BUILD_ACTION=test-without-building
elif [[ -n "${2:-}" ]]; then
  printf 'unknown option: %s\n' "$2" >&2
  exit 2
fi

udid=''
derived_data="${TESSERA_INTEGRATION_DERIVED_DATA:-$FIXTURE_STATE/DerivedData}"
result_bundle="$RUN_DIR/programmatic/compact-navigation-transition.xcresult"
mkdir -p "$derived_data" "$(dirname "$result_bundle")"
rm -rf "$result_bundle"

cleanup() {
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid" || true
  fi
}
trap cleanup EXIT

udid="$("$HERE/ensure-test-simulator.sh" | tail -n 1)"

xcodebuild "$BUILD_ACTION" \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -parallel-testing-enabled NO \
  -only-testing:TesseraTests/CompactNavigationPresentationTests \
  -only-testing:TesseraUITests/CompactNavigationTransitionHarnessTests
