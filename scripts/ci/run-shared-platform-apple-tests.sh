#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
run_token="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-$$"
run_token="${run_token//[^A-Za-z0-9._-]/-}"
device_name="Tessera Shared Platform CI $run_token"
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/tessera-shared-apple-ci.XXXXXX")"
result_bundle="$derived_data/TestResults.xcresult"
device_udid=""

cleanup() {
  if [[ -n "$device_udid" ]]; then
    xcrun simctl shutdown "$device_udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$device_udid" >/dev/null 2>&1 || true
  fi
  case "$derived_data" in
    "${TMPDIR:-/tmp}"/tessera-shared-apple-ci.*) rm -rf "$derived_data" ;;
    *) echo "refusing to remove unexpected DerivedData path: $derived_data" >&2 ;;
  esac
}
exit_cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  cleanup
  exit "$status"
}
trap exit_cleanup EXIT
trap cleanup HUP INT TERM

runtime_inventory="$(xcrun simctl list runtimes -j)"
runtime_id="$(
  jq -r '[.runtimes[] | select(.isAvailable and (.name | startswith("iOS ")))] | sort_by(.version) | last | .identifier' \
    <<< "$runtime_inventory"
)"
device_type_id="$(
  jq -r '
    [.runtimes[] | select(.isAvailable and (.name | startswith("iOS ")))]
    | sort_by(.version)
    | last
    | (
        [.supportedDeviceTypes[]? | select(.identifier == "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB")]
        + [.supportedDeviceTypes[]? | select(.productFamily == "iPad")]
      )
    | first
    | .identifier // empty
  ' <<< "$runtime_inventory"
)"
if [[ -z "$runtime_id" || "$runtime_id" == "null" ]]; then
  echo "no available iOS simulator runtime" >&2
  exit 1
fi
if [[ -z "$device_type_id" || "$device_type_id" == "null" ]]; then
  echo "no available iPad Pro simulator device type" >&2
  exit 1
fi

device_udid="$(xcrun simctl create "$device_name" "$device_type_id" "$runtime_id")"
xcrun simctl boot "$device_udid"
xcrun simctl bootstatus "$device_udid" -b

test_status=0
xcodebuild \
  -project "$repo_root/Tessera.xcodeproj" \
  -scheme Tessera \
  -destination "platform=iOS Simulator,id=$device_udid" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_bundle" \
  -disableAutomaticPackageResolution \
  -quiet \
  test \
  -only-testing:TesseraTests/AppleSessionCommandFacadeTests \
  -only-testing:TesseraTests/ContinuityFoundationTests \
  -only-testing:TesseraTests/ContinuityLifecycleTests \
  -only-testing:TesseraTests/EnrollmentCoordinatorTests \
  -only-testing:TesseraTests/EnrollmentServiceTests \
  -only-testing:TesseraTests/BootstrapNearbyHandshakeTests \
  -only-testing:TesseraTests/BootstrapManifestTests \
  -only-testing:TesseraTests/BootstrapCoordinatorTests \
  -only-testing:TesseraTests/BootstrapManifestAdapterTests \
  -only-testing:TesseraTests/BootstrapWireSchemaTests \
  -only-testing:TesseraTests/BootstrapNearbyTransferServiceTests \
  || test_status=$?

if (( test_status != 0 )); then
  if [[ -d "$result_bundle" ]]; then
    xcrun xcresulttool get test-results summary --path "$result_bundle" || true
  fi
  exit "$test_status"
fi
script_completed=1
