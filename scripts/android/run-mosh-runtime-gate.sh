#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f "$repo_root/android/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" | head -n 1)"
fi
[[ -n "$sdk_root" ]] || {
  echo "Android Mosh runtime gate failed: set ANDROID_SDK_ROOT" >&2
  exit 1
}

java_home="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
ndk_root="${TESSERA_ANDROID_NDK_ROOT:-$sdk_root/ndk/28.2.13676358}"
openssl_archive="${TESSERA_ANDROID_OPENSSL_ARCHIVE:-}"
swiftpm_cache="${TESSERA_SWIFTPM_OFFLINE_CACHE_ROOT:-$repo_root/Packages/TesseraCore/.build}"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
emulator="$sdk_root/emulator/emulator"
adb="$sdk_root/platform-tools/adb"
system_image="system-images;android-36;default;arm64-v8a"

[[ -x "$java_home/bin/java" ]] || { echo "missing JDK 17 at $java_home" >&2; exit 1; }
[[ -x "$swift_bin" ]] || { echo "missing Swift 6.3.3 at $swift_bin" >&2; exit 1; }
[[ -f "$openssl_archive" ]] || {
  echo "set TESSERA_ANDROID_OPENSSL_ARCHIVE to the reviewed OpenSSL 3.5.7 archive" >&2
  exit 1
}
[[ -d "$swiftpm_cache/repositories" ]] || {
  echo "hydrate the TesseraCore SwiftPM cache or set TESSERA_SWIFTPM_OFFLINE_CACHE_ROOT" >&2
  exit 1
}
for command in "$avdmanager" "$emulator" "$adb"; do
  [[ -x "$command" ]] || { echo "missing Android tool: $command" >&2; exit 1; }
done
[[ -d "$sdk_root/system-images/android-36/default/arm64-v8a" ]] || {
  echo "missing installed system image: $system_image" >&2
  exit 1
}

run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-android-mosh.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-mosh-$(date -u +%Y%m%dT%H%M%SZ)-$$"
emulator_pid=''
serial=''

cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  if [[ -n "$serial" ]]; then
    "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
  fi
  if [[ -n "$emulator_pid" ]]; then
    wait "$emulator_pid" >/dev/null 2>&1 || true
  fi
  JAVA_HOME="$java_home" "$avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1 || true
  case "$run_root" in
    "${TMPDIR:-/tmp}"/tessera-android-mosh.*) rm -rf -- "$run_root" ;;
    *) echo "refusing to remove unexpected Mosh runtime directory: $run_root" >&2 ;;
  esac
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

JAVA_HOME="$java_home" "$avdmanager" create avd \
  --force \
  --name "$avd_name" \
  --package "$system_image" \
  --device pixel_tablet \
  <<<"no" >/dev/null

for port in $(seq 5682 2 5780); do
  console_port_busy=0
  adb_port_busy=0
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && console_port_busy=1
    lsof -nP -iTCP:"$((port + 1))" -sTCP:LISTEN >/dev/null 2>&1 && adb_port_busy=1
  fi
  if [[ "$console_port_busy" -eq 0 && "$adb_port_busy" -eq 0 ]] \
      && ! "$adb" devices | awk 'NR > 1 {print $1}' | grep -qx "emulator-$port"; then
    serial="emulator-$port"
    "$emulator" \
      -avd "$avd_name" \
      -port "$port" \
      -no-window \
      -no-audio \
      -no-boot-anim \
      -no-snapshot \
      -wipe-data \
      >"$run_root/emulator.log" 2>&1 &
    emulator_pid=$!
    break
  fi
done
[[ -n "$serial" ]] || { echo "no free Android emulator port" >&2; exit 1; }

booted=0
for _ in {1..240}; do
  if ! kill -0 "$emulator_pid" >/dev/null 2>&1; then
    echo "Android emulator exited during boot" >&2
    tail -80 "$run_root/emulator.log" >&2 || true
    exit 1
  fi
  if [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
    booted=1
    break
  fi
  sleep 1
done
[[ "$booted" -eq 1 ]] || {
  echo "Android emulator did not finish booting" >&2
  exit 1
}

SWIFT_ANDROID_SWIFT="$swift_bin" \
TESSERA_ANDROID_NDK_ROOT="$ndk_root" \
TESSERA_ANDROID_OPENSSL_ARCHIVE="$openssl_archive" \
TESSERA_SWIFTPM_OFFLINE_CACHE_ROOT="$swiftpm_cache" \
TESSERA_ANDROID_RUNTIME_SERIAL="$serial" \
TESSERA_ANDROID_ADB="$adb" \
  "$repo_root/scripts/check-shared-core-android.sh"

echo "Android Mosh runtime gate passed on $serial; disposable AVD cleanup follows"
script_completed=1
