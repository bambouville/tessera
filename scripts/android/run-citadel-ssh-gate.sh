#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f "$repo_root/android/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" | head -n 1)"
fi
[[ -n "$sdk_root" ]] || { echo "Android Citadel gate failed: set ANDROID_SDK_ROOT" >&2; exit 1; }

java_home="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
ndk_root="${TESSERA_ANDROID_NDK_ROOT:-$sdk_root/ndk/28.2.13676358}"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
emulator="$sdk_root/emulator/emulator"
adb="$sdk_root/platform-tools/adb"
system_image="system-images;android-36;default;arm64-v8a"
fixture_config="${TESSERA_FIXTURE_CONFIG:-$repo_root/scripts/integration/fixture.env}"

[[ -x "$java_home/bin/java" ]] || { echo "missing JDK 17 at $java_home" >&2; exit 1; }
[[ -x "$swift_bin" ]] || { echo "missing Swift 6.3.3 at $swift_bin" >&2; exit 1; }
[[ -f "$fixture_config" ]] || { echo "missing fixture config: $fixture_config" >&2; exit 1; }
for command in "$avdmanager" "$emulator" "$adb"; do
  [[ -x "$command" ]] || { echo "missing Android tool: $command" >&2; exit 1; }
done
[[ -d "$sdk_root/system-images/android-36/default/arm64-v8a" ]] || {
  echo "missing installed system image: $system_image" >&2
  exit 1
}

export TESSERA_FIXTURE_CONFIG="$fixture_config"
export TESSERA_INTEGRATION_FIXTURE_STATE_DIR="${TESSERA_INTEGRATION_FIXTURE_STATE_DIR:-$(dirname "$fixture_config")/.state}"
# shellcheck source=../integration/lib.sh
# shellcheck disable=SC1091
source "$repo_root/scripts/integration/lib.sh"
load_fixture_config
ensure_fixture_credentials
fixture_host="$TESSERA_FIXTURE_STABLE_HOST"
fixture_port="$TESSERA_FIXTURE_APP_PORT"
fixture_user="$TESSERA_FIXTURE_USER"
fixture_secret="$(fixture_password)"

[[ "$fixture_host" =~ ^[A-Za-z0-9.:_-]+$ ]] || { echo "fixture host contains unsupported characters" >&2; exit 1; }
[[ "$fixture_port" =~ ^[1-9][0-9]{0,4}$ ]] || { echo "invalid fixture port" >&2; exit 1; }
(( fixture_port <= 65535 )) || { echo "fixture port is out of range" >&2; exit 1; }
[[ "$fixture_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "invalid fixture user" >&2; exit 1; }

run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-android-citadel.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
export XDG_CACHE_HOME="$run_root/xdg-cache"
export CLANG_MODULE_CACHE_PATH="$run_root/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$run_root/module-cache/swiftpm"
mkdir -p "$ANDROID_AVD_HOME" "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
avd_name="tessera-citadel-$(date -u +%Y%m%dT%H%M%SZ)-$$"
emulator_pid=''
serial=''
runtime_directory="/data/local/tmp/tessera-citadel-runtime-$$"

cleanup() {
  local status=$?
  fail_closed_status "$status" || status=1
  fixture_secret=''
  if [[ -n "$serial" ]]; then
    "$adb" -s "$serial" shell rm -rf "$runtime_directory" >/dev/null 2>&1 || true
    "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
  fi
  if [[ -n "$emulator_pid" ]]; then
    wait "$emulator_pid" >/dev/null 2>&1 || true
  fi
  JAVA_HOME="$java_home" "$avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1 || true
  case "$run_root" in
    "${TMPDIR:-/tmp}"/tessera-android-citadel.*) rm -rf -- "$run_root" ;;
    *) echo "refusing to remove unexpected Citadel runtime directory: $run_root" >&2 ;;
  esac
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! "$swift_bin" build \
    --disable-sandbox \
    --package-path "$repo_root/Packages/Citadel" \
    --product CitadelAndroidSmoke \
    --configuration release \
    --swift-sdk aarch64-unknown-linux-android28 \
    --static-swift-stdlib \
    --skip-update \
    --force-resolved-versions \
    >"$run_root/build.log" 2>&1; then
  tail -120 "$run_root/build.log" >&2
  exit 1
fi

binary="$repo_root/Packages/Citadel/.build/aarch64-unknown-linux-android28/release/CitadelAndroidSmoke"
[[ -f "$binary" ]] || { echo "Citadel Android executable was not produced" >&2; exit 1; }
llvm_readelf="$(find "$ndk_root/toolchains/llvm/prebuilt" -path '*/bin/llvm-readelf' -print -quit)"
llvm_strip="$(find "$ndk_root/toolchains/llvm/prebuilt" -path '*/bin/llvm-strip' -print -quit)"
libcxx_shared="$(find "$ndk_root/toolchains/llvm/prebuilt" \
  -path '*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so' -print -quit)"
for file in "$llvm_readelf" "$llvm_strip" "$libcxx_shared"; do
  [[ -f "$file" ]] || { echo "missing pinned NDK runtime tool: $file" >&2; exit 1; }
done
"$llvm_readelf" -h "$binary" | rg -q 'Machine:[[:space:]]+AArch64' || {
  echo "Citadel smoke is not an AArch64 ELF" >&2
  exit 1
}
"$llvm_readelf" -d "$binary" | rg -q 'Shared library: \[libc\+\+_shared\.so\]' || {
  echo "Citadel smoke has an unexpected C++ runtime contract" >&2
  exit 1
}
"$llvm_strip" --strip-unneeded -o "$run_root/CitadelAndroidSmoke" "$binary"

JAVA_HOME="$java_home" "$avdmanager" create avd \
  --force --name "$avd_name" --package "$system_image" --device pixel_tablet \
  <<<"no" >/dev/null

for port in $(seq 5782 2 5880); do
  console_port_busy=0
  adb_port_busy=0
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && console_port_busy=1
    lsof -nP -iTCP:"$((port + 1))" -sTCP:LISTEN >/dev/null 2>&1 && adb_port_busy=1
  fi
  if [[ "$console_port_busy" -eq 0 && "$adb_port_busy" -eq 0 ]] \
      && ! "$adb" devices | awk 'NR > 1 {print $1}' | grep -qx "emulator-$port"; then
    serial="emulator-$port"
    "$emulator" -avd "$avd_name" -port "$port" -no-window -no-audio \
      -no-boot-anim -no-snapshot -wipe-data >"$run_root/emulator.log" 2>&1 &
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
[[ "$booted" -eq 1 ]] || { echo "Android emulator did not finish booting" >&2; exit 1; }

"$adb" -s "$serial" shell mkdir "$runtime_directory"
"$adb" -s "$serial" push "$run_root/CitadelAndroidSmoke" \
  "$runtime_directory/CitadelAndroidSmoke" >/dev/null
"$adb" -s "$serial" push "$libcxx_shared" \
  "$runtime_directory/libc++_shared.so" >/dev/null
"$adb" -s "$serial" shell chmod 0700 "$runtime_directory/CitadelAndroidSmoke"
runtime_output="$(printf '%s\n' "$fixture_secret" | "$adb" -s "$serial" shell \
  "cd '$runtime_directory' && LD_LIBRARY_PATH='$runtime_directory' ./CitadelAndroidSmoke '$fixture_host' '$fixture_port' '$fixture_user'")"
fixture_secret=''
if [[ "$runtime_output" != *"TESSERA_CITADEL_ANDROID_SSH_OK"* ]]; then
  echo "Citadel Android real-SSH proof did not report its success marker" >&2
  echo "$runtime_output" >&2
  exit 1
fi
echo "$runtime_output"
echo "Android Citadel real-SSH gate passed on $serial; disposable AVD cleanup follows"
script_completed=1
