#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || {
  printf 'usage: run-system-presentation-tests.sh RUN_DIR [--without-building]\n' >&2
  exit 2
}
if [[ "${2:-}" != --without-building ]]; then
  [[ -z "${2:-}" ]] || { printf 'unknown option: %s\n' "$2" >&2; exit 2; }
  ensure_integration_build "$RUN_DIR/programmatic/system-presentation-build.log"
fi
require_command jq
require_command ssh-keygen

ipad_udid=''
iphone_udid=''
key_dir=''
derived_data="$(integration_derived_data)"
result_dir="$RUN_DIR/programmatic"
mkdir -p "$result_dir"

cleanup() {
  [[ -z "$key_dir" ]] || rm -rf "$key_dir"
  # The iPhone is private to this lane; only the shared iPad may outlive it
  # when the parent runner keeps it booted.
  delete_owned_test_simulator "$SIMULATOR_STATE/system_presentation_iphone_simulator_udid" || true
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid" || true
  fi
}
trap 'fail_closed_trap cleanup' EXIT

# The hosted SystemPresentationTests (12) and the picker UI tests (2) all
# ran and passed: a skip (the seeded-file variable missing) or a test that
# stopped being selected must not read as green.
expected_tests=24
require_presentation_results() {
  local bundle="$1" summary
  summary="$(xcrun xcresulttool get test-results summary --path "$bundle" --compact)" || return 1
  jq -e --argjson expected "$expected_tests" \
    '.result == "Passed" and .failedTests == 0 and .skippedTests == 0 and .passedTests == $expected' \
    <<<"$summary" >/dev/null || {
    printf '%s: expected %s passing tests and no skips: %s\n' \
      "$(basename "$bundle")" "$expected_tests" "$summary" >&2
    return 1
  }
}

# The picker has to choose a real file. A throwaway unencrypted key in the
# app's Documents appears in Files under On My iPhone/iPad › Tessera; it is
# named like a default OpenSSH key, with no extension.
seeded_file=tessera-import-test
key_dir="$(mktemp -d)"
ssh-keygen -q -t ed25519 -N '' -C tessera-picker-test -f "$key_dir/$seeded_file"

run_presentation_tests() {
  local name="$1" udid="$2" bundle documents
  bundle="$result_dir/system-presentation-$name.xcresult"
  rm -rf "$bundle"
  xcrun simctl install "$udid" "$(integration_app_path)"
  documents="$(xcrun simctl get_app_container "$udid" com.bambouville.TesseraApp data)/Documents"
  mkdir -p "$documents"
  cp "$key_dir/$seeded_file" "$documents/$seeded_file"
  TEST_RUNNER_TESSERA_KEY_IMPORT_SEEDED_FILE="$seeded_file" xcodebuild test-without-building \
    -project "$REPO_ROOT/Tessera.xcodeproj" \
    -scheme Tessera \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$bundle" \
    -parallel-testing-enabled NO \
    -only-testing:TesseraTests/SystemPresentationTests \
    -only-testing:TesseraUITests/KeyImportPickerHarnessTests
  require_presentation_results "$bundle"
}

# iPad and the Mac show popovers, iPhone sheets; iPad's picker browses from
# a sidebar, iPhone's from a Browse tab. The Mac ("Designed for iPad") cannot
# run UI tests, and xcodebuild leaves its hosted test runner suspended: run
# SystemPresentationTests there from Xcode.
ipad_udid="$("$HERE/ensure-test-simulator.sh" | tail -n 1)"
run_presentation_tests ipad "$ipad_udid"
iphone_udid="$(
  TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera System Presentation Integration iPhone" \
  TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" \
  TESSERA_INTEGRATION_SIMULATOR_UDID_FILE="$SIMULATOR_STATE/system_presentation_iphone_simulator_udid" \
    "$HERE/ensure-test-simulator.sh" | tail -n 1
)"
run_presentation_tests iphone "$iphone_udid"
script_completed=1
