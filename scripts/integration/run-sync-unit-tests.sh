#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

RUN_DIR="${1:-}"
[[ -n "$RUN_DIR" ]] || { printf 'usage: run-sync-unit-tests.sh RUN_DIR [--without-building]\n' >&2; exit 2; }
BUILD_ACTION=test
if [[ "${2:-}" == --without-building ]]; then
  BUILD_ACTION=test-without-building
elif [[ -n "${2:-}" ]]; then
  printf 'unknown option: %s\n' "$2" >&2
  exit 2
fi

udid=''
derived_data="${TESSERA_INTEGRATION_DERIVED_DATA:-$FIXTURE_STATE/DerivedData}"
result_bundle="$RUN_DIR/programmatic/sync-unit-tests.xcresult"
mkdir -p "$derived_data" "$(dirname "$result_bundle")"
rm -rf "$result_bundle"

cleanup() {
  if [[ "${TESSERA_KEEP_TEST_SIM_BOOTED:-0}" != 1 ]]; then
    delete_owned_test_simulator "$SIMULATOR_STATE/simulator_udid" || true
  fi
}
trap cleanup EXIT

udid="$($HERE/ensure-test-simulator.sh | tail -n 1)"

# Keep every secret-bearing boundary, protocol state machine, migration
# ledger, and continuation route in the comprehensive regression gate. These
# classes are intentionally listed rather than relying on a broad test target:
# unrelated app tests may be optional or require their own external fixtures.
xcodebuild "$BUILD_ACTION" \
  -project "$REPO_ROOT/Tessera.xcodeproj" \
  -scheme Tessera \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -only-testing:TesseraTests/ContinuityFoundationTests \
  -only-testing:TesseraTests/ContinuityLifecycleTests \
  -only-testing:TesseraTests/SessionRestoreResolverTests \
  -only-testing:TesseraTests/EnrollmentMessagesTests \
  -only-testing:TesseraTests/EnrollmentServiceTests \
  -only-testing:TesseraTests/EnrollmentCoordinatorTests \
  -only-testing:TesseraTests/EnrollmentContinuationStreamTransportTests \
  -only-testing:TesseraTests/BootstrapCoordinatorTests \
  -only-testing:TesseraTests/BootstrapManifestAdapterTests \
  -only-testing:TesseraTests/BootstrapManifestTests \
  -only-testing:TesseraTests/BootstrapNearbyHandshakeTests \
  -only-testing:TesseraTests/BootstrapNearbyTransferServiceTests \
  -only-testing:TesseraTests/BootstrapWireSchemaTests \
  -only-testing:TesseraTests/RemoteInstallationLedgerTests \
  -only-testing:TesseraTests/RemoteAuthorizedKeysInstallerTests \
  -only-testing:TesseraTests/SyncClassificationTests \
  -only-testing:TesseraTests/HostKeyVerificationRequestTests \
  -only-testing:TesseraTests/MoshBootstrapTests \
  -only-testing:TesseraTests/KeyStoreSecurityTests/test_softwareKeyDefaultIsMigratableButNotSynchronizable \
  -only-testing:TesseraTests/KeyStoreSecurityTests/test_liveBootstrapRecipientKeyUsesAndReusesRecoverableSimulatorEd25519Material
