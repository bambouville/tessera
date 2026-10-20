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
# A simulator that never finishes booting must fail the lane, not hang the
# suite. CoreSimulator has stalled a fresh device for minutes under load; the
# bound is generous because two devices may be booting at once.
BOOT_TIMEOUT="${TESSERA_INTEGRATION_SIMULATOR_BOOT_TIMEOUT:-300}"
case "$BOOT_TIMEOUT" in
  ''|0|*[!0-9]*) die "TESSERA_INTEGRATION_SIMULATOR_BOOT_TIMEOUT must be positive integer seconds" ;;
esac
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
trap 'fail_closed_trap cleanup_failed_creation' EXIT
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
if [[ "${TESSERA_INTEGRATION_SOFTWARE_KEYBOARD:-0}" == 1 ]]; then
  # This run's device only; the Simulator-wide setting and persistent devices
  # are untouched. UIKit's native Hide behaves differently with Mac input attached.
  defaults write com.apple.iphonesimulator DevicePreferences -dict-add "$udid" \
    '{ConnectHardwareKeyboard = 0;}'
  touch "${UDID_FILE}.software-keyboard"
fi
xcrun simctl boot "$udid" >/dev/null 2>&1 || true
if ! simctl_bounded "$((10#$BOOT_TIMEOUT * 1000))" bootstatus "$udid" -b; then
  # The EXIT trap deletes a device this invocation created; a reused device
  # remains recorded so the owning lane's cleanup still removes it.
  die "simulator $udid did not finish booting within ${BOOT_TIMEOUT}s"
fi
created_udid=''
trap - EXIT
printf '%s\n' "$udid"
script_completed=1
