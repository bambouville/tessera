#!/usr/bin/env bash
# Native debug-only view fixtures. Never calls a production pairing coordinator.
set -euo pipefail
root="${1:?owned QR run directory}"
out="${2:?capture output directory}"
[[ "$(<"$root/android-serial")" == emulator-5580 ]] || exit 2
adb="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}/platform-tools/adb"
helper="$(dirname "$0")/qr-android-step.py"
font="$($adb -s emulator-5580 shell settings get system font_scale | tr -d '\r')"
cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  "$adb" -s emulator-5580 shell wm size reset || true
  "$adb" -s emulator-5580 shell wm density reset || true
  "$adb" -s emulator-5580 shell settings put system font_scale "$font" || true
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$out"
capture() { "$adb" -s emulator-5580 exec-out screencap -p >"$out/$1.png"; }
launch() {
  "$adb" -s emulator-5580 shell am start -S -n com.bambouville.tessera.debug/com.bambouville.tessera.TesseraHarnessActivity -e scene "$1" -e theme light >/dev/null
  python3 "$helper" "$root" >"$out/$2-ui.txt"
}
launch setup-verify tablet-verify
capture tablet-verify
python3 "$helper" "$root" 'codes match' >"$out/tablet-hosts-ui.txt"
capture tablet-hosts
python3 "$helper" "$root" 'next: choose data' 'trusted server keys' >"$out/tablet-include-ui.txt"
capture tablet-include
"$adb" -s emulator-5580 shell input swipe 1720 1190 1720 540 450
python3 "$helper" "$root" 'next: review transfer' >"$out/tablet-review-ui.txt"
grep -F '1 public-key grant selected' "$out/tablet-review-ui.txt"
grep -F '1 optional data category selected' "$out/tablet-review-ui.txt"
capture tablet-review
launch setup-receipt tablet-receipt
capture tablet-receipt
launch setup-progress tablet-progress
capture tablet-progress
# Adapt the owned tablet emulator to a compact native Android viewport.
"$adb" -s emulator-5580 shell wm size 1080x2400
"$adb" -s emulator-5580 shell wm density 420
launch setup-verify compact-verify
capture compact-verify
python3 "$helper" "$root" 'they differ' >"$out/compact-mismatch-ui.txt"
capture compact-mismatch
python3 "$helper" "$root" 'start again' >"$out/compact-retry-ui.txt"
capture compact-retry
"$adb" -s emulator-5580 shell settings put system font_scale 1.6
launch setup-receipt compact-large-receipt
capture compact-large-receipt
launch setup-progress compact-large-progress
capture compact-large-progress
echo 'Native Android surfaces captured; no remote effects.'
script_completed=1
