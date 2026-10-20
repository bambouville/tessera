#!/usr/bin/env bash
# Own the two disposable review devices for the full interactive capture run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
run_dir="$1"
mkdir -p "$run_dir"
export TESSERA_INTEGRATION_SIMULATOR_STATE_DIR="$run_dir/ios"
export TESSERA_INTEGRATION_SIMULATOR_NAME="Tessera QR Review"
export TESSERA_INTEGRATION_SIMULATOR_RUN_ID="qr-$(date -u +%Y%m%dT%H%M%SZ)-$$"
export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
sdk_root="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
export ANDROID_AVD_HOME="$run_dir/avd"
avd_name="tessera-qr-review-$$"
serial=emulator-5580
emulator_pid=''
owns_simulator_state=0
owns_avd=0
cleanup() {
  if [[ "$owns_simulator_state" == 1 ]]; then
    delete_owned_test_simulator "$run_dir/ios/simulator_udid" || true
  fi
  if [[ -n "$emulator_pid" ]]; then
    "$sdk_root/platform-tools/adb" -s "$serial" emu kill >/dev/null 2>&1 || true
    for ((attempt=0; attempt<10; attempt++)); do
      kill -0 "$emulator_pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$emulator_pid" 2>/dev/null; then
      kill -TERM "$emulator_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$emulator_pid" 2>/dev/null || true
    fi
    wait "$emulator_pid" || true
  fi
  if [[ "$owns_avd" == 1 ]]; then
    "$sdk_root/cmdline-tools/latest/bin/avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1 || true
  fi
}
trap 'fail_closed_trap cleanup' EXIT
trap 'exit 130' INT TERM
if lsof -nP -iTCP:5580 -sTCP:LISTEN >/dev/null 2>&1; then
  die "QR review port 5580 is already in use"
fi
[[ ! -e "$run_dir/ios/simulator_udid" ]] || die "QR review output already owns a simulator; use a fresh output directory"
[[ ! -e "$ANDROID_AVD_HOME/$avd_name.avd" ]] || die "QR review AVD already exists; use a fresh output directory"
owns_simulator_state=1
"$HERE/ensure-test-simulator.sh"
camera_args=(-camera-back emulated)
if [[ -n "${TESSERA_QR_CAMERA_FILE:-}" ]]; then
  # The driver captures a fresh offer from this owned iPad before starting the
  # Android camera. Only pixels cross this boundary; no decoded QR is injected.
  echo "Waiting for the fresh iPad QR camera image: $TESSERA_QR_CAMERA_FILE"
  # A fresh worktree can still be building while the source offer is prepared.
  for ((attempt=0; attempt<1800; attempt++)); do
    [[ -s "$TESSERA_QR_CAMERA_FILE" ]] && break
    sleep 1
  done
  [[ -s "$TESSERA_QR_CAMERA_FILE" ]] || die "QR camera image was not supplied"
  camera_args=(-camera-back "imagefile:$TESSERA_QR_CAMERA_FILE")
fi
mkdir -p "$ANDROID_AVD_HOME"
owns_avd=1
"$sdk_root/cmdline-tools/latest/bin/avdmanager" create avd --name "$avd_name" --package 'system-images;android-36;default;arm64-v8a' --device pixel_tablet <<<no
"$sdk_root/emulator/emulator" -avd "$avd_name" -port 5580 -no-audio -no-snapshot -no-boot-anim -crash-report-mode never "${camera_args[@]}" >"$run_dir/emulator.log" 2>&1 &
emulator_pid=$!
printf '%s\n' "$serial" >"$run_dir/android-serial"
echo "Review devices active; send a newline to finish and delete them."
read -r _
script_completed=1
