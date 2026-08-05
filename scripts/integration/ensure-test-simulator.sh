#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

mkdir -p "$FIXTURE_STATE"
require_command jq
require_command xcrun

DEVICE_NAME="${TESSERA_INTEGRATION_SIMULATOR_NAME:-Tessera Integration Tests}"
DEVICE_TYPE="${TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB}"
RUNTIME="${TESSERA_INTEGRATION_SIMULATOR_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-0}"
UDID_FILE="${TESSERA_INTEGRATION_SIMULATOR_UDID_FILE:-$SIMULATOR_STATE/simulator_udid}"
OWNER_FILE="${UDID_FILE}.owned"
RUN_ID_FILE="${UDID_FILE}.run-id"
RUN_ID="${TESSERA_INTEGRATION_SIMULATOR_RUN_ID:-standalone-$(date -u +%Y%m%dT%H%M%SZ)-$PPID-$RANDOM}"
mkdir -p "$(dirname "$UDID_FILE")"

udid=''
created_udid=''
cleanup_failed_creation() {
  [[ -n "$created_udid" ]] || return 0
  if [[ -f "$UDID_FILE" && -f "$OWNER_FILE" ]]; then
    delete_owned_test_simulator "$UDID_FILE" || true
  else
    xcrun simctl shutdown "$created_udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$created_udid" >/dev/null 2>&1 || true
  fi
}
trap cleanup_failed_creation EXIT
recorded_run_id=''
if [[ -f "$RUN_ID_FILE" ]]; then
  IFS= read -r recorded_run_id <"$RUN_ID_FILE"
fi
if [[ "$recorded_run_id" == "$RUN_ID" && -f "$UDID_FILE" && -f "$OWNER_FILE" ]]; then
  IFS= read -r udid <"$UDID_FILE"
  IFS= read -r owned_udid <"$OWNER_FILE"
  [[ "$udid" == "$owned_udid" ]] || die "simulator ownership mismatch: $UDID_FILE"
  if ! xcrun simctl list devices -j \
    | jq -e --arg udid "$udid" \
      '[.devices[][] | select(.udid == $udid and .isAvailable == true)] | length == 1' \
      >/dev/null; then
    udid=''
  fi
fi

if [[ -z "$udid" ]]; then
  if [[ -f "$OWNER_FILE" ]]; then
    delete_owned_test_simulator "$UDID_FILE" \
      || die "could not remove the previous disposable simulator"
  else
    rm -f "$UDID_FILE" "$RUN_ID_FILE"
  fi
  unique_name="$DEVICE_NAME — $RUN_ID"
  note "creating run-scoped simulator: $unique_name"
  udid="$(xcrun simctl create "$unique_name" "$DEVICE_TYPE" "$RUNTIME")"
  created_udid="$udid"
  printf '%s\n' "$udid" >"$UDID_FILE"
  printf '%s\n' "$udid" >"$OWNER_FILE"
  printf '%s\n' "$RUN_ID" >"$RUN_ID_FILE"
fi

printf '%s\n' "$udid" >"$UDID_FILE"
xcrun simctl boot "$udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$udid" -b
created_udid=''
trap - EXIT
printf '%s\n' "$udid"
