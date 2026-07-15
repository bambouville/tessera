#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-offline-oracle-tests.sh RUN_DIR\n' >&2; exit 2; }

udid="$($HERE/ensure-test-simulator.sh | tail -n 1)"
derived_data="$FIXTURE_STATE/DerivedData"
result_bundle="$RUN_DIR/programmatic/offline-oracles.xcresult"
mkdir -p "$derived_data" "$(dirname "$result_bundle")"
rm -rf "$result_bundle"

cleanup() {
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# These are the new matrix-derived, host-free boundaries. The repository's
# ordinary unit/package suite remains the fast per-change CI lane; this target
# deliberately avoids paying to rerun all ~660 tests during a live-host sweep.
xcodebuild test \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:TesseraTests/AgentCenterSafetyTests \
  -only-testing:TesseraTests/RemoteShellIntegrationInstallerTests \
  -only-testing:TesseraTests/TesseraMigrationTests \
  -only-testing:TesseraTests/TerminalScrollbackOracleTests \
  -only-testing:TesseraTests/HostLaunchPrologueTests
