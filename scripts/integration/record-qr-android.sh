#!/usr/bin/env bash
# Capture consecutive native screenrecord segments; stop with Ctrl-C. The
# segment manifest records real start/end times and any rollover gaps.
set -euo pipefail
out="$1"
serial="$2"
[[ "$(<"$out/android-serial")" == "$serial" ]] || exit 2
adb="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}/platform-tools/adb"
run="qr-video-$(date -u +%Y%m%dT%H%M%SZ)-$$"
part=0
remote=''
recorder=''
cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  trap - EXIT INT TERM
  if [[ -n "$recorder" ]]; then
    pid="$($adb -s "$serial" shell cat "/sdcard/$run.pid" 2>/dev/null | tr -d '\r')"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then "$adb" -s "$serial" shell kill -2 "$pid" || true; fi
    wait "$recorder" || true
    "$adb" -s "$serial" pull "$remote" "$out/android-part$part.mp4" || true
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
while :; do
  part=$((part + 1))
  remote="/sdcard/$run-$part.mp4"
  printf '%s start %s\n' "$part" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$out/android-recording-times.txt"
  "$adb" -s "$serial" shell "screenrecord --time-limit 180 '$remote' & echo \$! > '/sdcard/$run.pid'; wait" &
  recorder=$!
  wait "$recorder"
  recorder=''
  printf '%s end %s\n' "$part" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$out/android-recording-times.txt"
  "$adb" -s "$serial" pull "$remote" "$out/android-part$part.mp4"
done
script_completed=1
