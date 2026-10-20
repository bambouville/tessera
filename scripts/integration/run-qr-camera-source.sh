#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
run_dir="${1:?usage: run-qr-camera-source.sh FRESH_OUTPUT_DIRECTORY}"
[[ ! -e "$run_dir/simulator_udid" && ! -e "$run_dir/simulator_udid.owned" ]] || die "output already owns a simulator; use a fresh output directory"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$run_dir"
export TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera QR Camera Source'
cleanup() { delete_owned_test_simulator "$run_dir/simulator_udid" || true; }
trap 'fail_closed_trap cleanup' EXIT
trap 'exit 130' INT TERM
"$HERE/ensure-test-simulator.sh"
echo 'Camera-source simulator active; send newline to delete this device.'
read -r _
script_completed=1
