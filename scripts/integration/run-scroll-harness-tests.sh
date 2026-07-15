#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-scroll-harness-tests.sh RUN_DIR\n' >&2; exit 2; }
BUILD_ACTION=test
if [[ "${2:-}" == --without-building ]]; then
  BUILD_ACTION=test-without-building
elif [[ -n "${2:-}" ]]; then
  printf 'unknown option: %s\n' "$2" >&2
  exit 2
fi

udid="$($HERE/ensure-test-simulator.sh | tail -n 1)"
derived_data="$FIXTURE_STATE/DerivedData"
result_bundle="$RUN_DIR/programmatic/terminal-scroll-harness.xcresult"
mkdir -p "$derived_data" "$(dirname "$result_bundle")"
rm -rf "$result_bundle"

cleanup() {
  xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_SCROLL_CAPTURE \
    >/dev/null 2>&1 || true
  xcrun simctl spawn "$udid" launchctl unsetenv TESSERA_SCROLL_HARNESS \
    >/dev/null 2>&1 || true
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

xcrun simctl spawn "$udid" launchctl setenv TESSERA_SCROLL_CAPTURE 1
xcrun simctl spawn "$udid" launchctl setenv TESSERA_SCROLL_HARNESS 1

TESSERA_SCROLL_CAPTURE=1 xcodebuild "$BUILD_ACTION" \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:TesseraUITests/TerminalScrollHarnessTests/testPrimaryScrollMovesIntoHistoryAndBackToBottom
