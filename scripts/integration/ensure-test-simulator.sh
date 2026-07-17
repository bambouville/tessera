#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

mkdir -p "$FIXTURE_STATE"
require_command jq
require_command xcrun

DEVICE_NAME="${TESSERA_INTEGRATION_SIMULATOR_NAME:-Tessera Integration Tests}"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-0"
UDID_FILE="${TESSERA_INTEGRATION_SIMULATOR_UDID_FILE:-$FIXTURE_STATE/simulator_udid}"
mkdir -p "$(dirname "$UDID_FILE")"

udid=''
if [[ -f "$UDID_FILE" ]]; then
  IFS= read -r udid <"$UDID_FILE"
  if ! xcrun simctl list devices -j \
    | jq -e --arg udid "$udid" \
      '[.devices[][] | select(.udid == $udid and .isAvailable == true)] | length == 1' \
      >/dev/null; then
    udid=''
  fi
fi

if [[ -z "$udid" ]]; then
  udid="$(
    xcrun simctl list devices -j \
      | jq -r --arg name "$DEVICE_NAME" \
        '.devices[][] | select(.name == $name and .isAvailable == true) | .udid' \
      | sed -n '1p'
  )"
fi

if [[ -z "$udid" ]]; then
  note "creating dedicated simulator: $DEVICE_NAME"
  udid="$(xcrun simctl create "$DEVICE_NAME" "$DEVICE_TYPE" "$RUNTIME")"
fi

printf '%s\n' "$udid" >"$UDID_FILE"
xcrun simctl boot "$udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$udid" -b
printf '%s\n' "$udid"
