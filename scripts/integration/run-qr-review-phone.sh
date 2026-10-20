#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
out="$1"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$out/phone"
export TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera QR Recipient iPhone"
export TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
export TESSERA_INTEGRATION_SIMULATOR_RUN_ID="qr-phone-$(date -u +%Y%m%dT%H%M%SZ)-$$"
[[ ! -e "$out/phone/simulator_udid" ]] || die 'use a fresh phone output directory'
trap 'fail_closed_trap delete_owned_test_simulator "$out/phone/simulator_udid"' EXIT
trap 'exit 130' INT TERM
"$HERE/ensure-test-simulator.sh"
echo 'Phone active; send newline to delete only this owned simulator.'
read -r _
script_completed=1
