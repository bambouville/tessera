#!/usr/bin/env bash
# Real UIKit key presses with settled, Metal-aware captures on owned devices.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="${1:?supply the aggregate run directory}"
CASE_DIR="$RUN_DIR/visual/cases/K1-hardware-keyboard-focus"
mkdir -p "$CASE_DIR"
for surface in ipad iphone; do
  evidence="$RUN_DIR/keyboard-$surface"
  if [[ "$surface" == iphone ]]; then
    TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro \
      TESSERA_INTEGRATION_SIMULATOR_NAME='Tessera Hardware Keyboard iPhone' \
      bash "$HERE/run-hardware-keyboard-tests.sh" "$evidence"
  else
    bash "$HERE/run-hardware-keyboard-tests.sh" "$evidence"
  fi
  for stage in background-cleanup mouse-focus foreground; do
    cp "$evidence/$stage.png" "$CASE_DIR/$surface-$stage.png"
  done
done
cp "$HERE/visual-cases/k1-hardware-keyboard-focus.json" "$CASE_DIR/case.json"
