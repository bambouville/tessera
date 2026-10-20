#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-offline-oracle-tests.sh RUN_DIR [--without-building]\n' >&2; exit 2; }
BUILD_ACTION=test
if [[ "${2:-}" == --without-building ]]; then
  BUILD_ACTION=test-without-building
elif [[ -n "${2:-}" ]]; then
  printf 'unknown option: %s\n' "$2" >&2
  exit 2
fi

derived_data="$(integration_derived_data)"
result_bundle="$RUN_DIR/programmatic/offline-oracles.xcresult"
mkdir -p "$derived_data" "$(dirname "$result_bundle")"
rm -rf "$result_bundle"

cleanup() {
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid" || true
  fi
}
trap 'fail_closed_trap cleanup' EXIT

udid="$($HERE/ensure-test-simulator.sh | tail -n 1)"

# These are the new matrix-derived, host-free boundaries. The repository's
# ordinary unit/package suite remains the fast per-change CI lane; this target
# deliberately avoids paying to rerun all ~660 tests during a live-host sweep.
xcodebuild "$BUILD_ACTION" \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:TesseraTests/QuickLookPresenterTests \
  -only-testing:TesseraTests/AppleSessionCommandFacadeTests \
  -only-testing:TesseraTests/AgentCenterSafetyTests \
  -only-testing:TesseraTests/RemoteShellIntegrationInstallerTests \
  -only-testing:TesseraTests/TesseraMigrationTests \
  -only-testing:TesseraTests/TerminalScrollbackOracleTests \
  -only-testing:TesseraTests/HostLaunchPrologueTests
script_completed=1
