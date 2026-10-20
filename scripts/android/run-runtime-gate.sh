#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f "$repo_root/android/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" | head -n 1)"
fi
[[ -n "$sdk_root" ]] || {
  echo "Android runtime gate failed: set ANDROID_SDK_ROOT" >&2
  exit 1
}

java_home="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
swift_bin="${SWIFT_ANDROID_SWIFT:-$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift}"
avdmanager="$sdk_root/cmdline-tools/latest/bin/avdmanager"
emulator="$sdk_root/emulator/emulator"
adb="$sdk_root/platform-tools/adb"
system_image="system-images;android-36;default;arm64-v8a"
device_profile="${TESSERA_ANDROID_RUNTIME_DEVICE:-pixel_tablet}"

[[ -x "$java_home/bin/java" ]] || { echo "missing JDK 21 at $java_home" >&2; exit 1; }
[[ -x "$swift_bin" ]] || { echo "missing Swift 6.3.3 at $swift_bin" >&2; exit 1; }
for command in "$avdmanager" "$emulator" "$adb"; do
  [[ -x "$command" ]] || { echo "missing Android tool: $command" >&2; exit 1; }
done
[[ -d "$sdk_root/system-images/android-36/default/arm64-v8a" ]] || {
  echo "missing installed system image: $system_image" >&2
  exit 1
}

run_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-android-runtime.XXXXXX")"
export ANDROID_AVD_HOME="$run_root/avd"
mkdir -p "$ANDROID_AVD_HOME"
avd_name="tessera-runtime-$(date -u +%Y%m%dT%H%M%SZ)-$$"
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
    if [[ -n "${TESSERA_ANDROID_RUNTIME_CAPTURE_DIR:-}" ]]; then
      mkdir -p "$TESSERA_ANDROID_RUNTIME_CAPTURE_DIR"
      "$adb" -s "$serial" logcat -d > "$TESSERA_ANDROID_RUNTIME_CAPTURE_DIR/logcat-dbg.txt" 2>&1 || true
      "$adb" -s "$serial" pull /sdcard/Pictures/tessera-idle-redraw \
        "$TESSERA_ANDROID_RUNTIME_CAPTURE_DIR/" >/dev/null 2>&1 || true
      "$adb" -s "$serial" pull \
        /sdcard/Pictures/tessera-window-ordering \
        "$TESSERA_ANDROID_RUNTIME_CAPTURE_DIR/" >/dev/null 2>&1 || true
    fi
    "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
  fi
  if [[ -n "$emulator_pid" ]]; then
    wait "$emulator_pid" >/dev/null 2>&1 || true
  fi
  JAVA_HOME="$java_home" "$avdmanager" delete avd -n "$avd_name" >/dev/null 2>&1 || true
  case "$run_root" in
    "${TMPDIR:-/tmp}"/tessera-android-runtime.*) rm -rf -- "$run_root" ;;
    *) echo "refusing to remove unexpected runtime directory: $run_root" >&2 ;;
  esac
  return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

JAVA_HOME="$java_home" "$avdmanager" create avd \
  --force \
  --name "$avd_name" \
  --package "$system_image" \
  --device "$device_profile" \
  <<<"no" >/dev/null

for port in $(seq 5580 2 5680); do
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
      -crash-report-mode never \
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
  [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && break
  sleep 1
done
if [[ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
  booted=1
fi
[[ "$booted" -eq 1 ]] || {
  echo "Android emulator did not finish booting" >&2
  exit 1
}

runtime_focus="${TESSERA_ANDROID_RUNTIME_FOCUS:-all}"
runtime_test_filter="${TESSERA_ANDROID_RUNTIME_TEST_FILTER:-}"
test_filters=()
case "$runtime_focus" in
  all)
    test_tasks=(
      :core-bridge:connectedDebugAndroidTest
      :data:connectedDebugAndroidTest
      :security:connectedDebugAndroidTest
      :terminal:connectedDebugAndroidTest
      :feature-pairing:connectedDebugAndroidTest
      :feature-agent-center:connectedDebugAndroidTest
      :feature-session:connectedDebugAndroidTest
      :app:connectedDebugAndroidTest
    )
    ;;
  app)
    test_tasks=(:app:connectedDebugAndroidTest)
    ;;
  restore)
    # Session restore, end to end: the shared rules as they actually come back
    # over JNI, then the wiring around them driven through real Activity
    # lifecycle edges. The wiring tests write to the real host database and the
    # real restore stores, so they belong on this disposable AVD and nowhere
    # near a device someone uses.
    test_tasks=(
      :core-bridge:connectedDebugAndroidTest
      :app:connectedDebugAndroidTest
    )
    if [[ -z "$runtime_test_filter" ]]; then
      test_filters=(
        "com.bambouville.tessera.core.bridge.SharedRestoreDecisionVectorInstrumentedTest"
        "com.bambouville.tessera.SessionRestoreLifecycleInstrumentedTest"
      )
    fi
    ;;
  core-bridge)
    # The shared Swift core as it answers over JNI on Android's Foundation.
    test_tasks=(:core-bridge:connectedDebugAndroidTest)
    ;;
  pairing)
    test_tasks=(:feature-pairing:connectedDebugAndroidTest)
    ;;
  terminal)
    test_tasks=(:terminal:connectedDebugAndroidTest)
    ;;
  agent-center)
    test_tasks=(:feature-agent-center:connectedDebugAndroidTest)
    ;;
  session)
    test_tasks=(:feature-session:connectedDebugAndroidTest)
    if [[ -z "$runtime_test_filter" ]]; then
      runtime_test_filter="com.bambouville.tessera.feature.session.AgentSessionIntegrationChromeInstrumentedTest,com.bambouville.tessera.feature.session.TmuxWindowOrderingUiInstrumentedTest"
    fi
    ;;
  *)
    echo "unknown TESSERA_ANDROID_RUNTIME_FOCUS: $runtime_focus" >&2
    exit 1
    ;;
esac

(
  cd "$repo_root/android"
  # Instrumentation packages share one emulator and must not race each other's
  # activities, permissions, Keystore, or package lifecycle.
  for index in "${!test_tasks[@]}"; do
    test_task="${test_tasks[$index]}"
    # A per-task default, for a focus that runs more than one module. An
    # explicit TESSERA_ANDROID_RUNTIME_TEST always wins.
    task_filter="${runtime_test_filter:-${test_filters[$index]:-}}"
    if [[ "$runtime_focus" == all \
        && "$test_task" == :feature-session:connectedDebugAndroidTest \
        && -z "$task_filter" ]]; then
      # The session module also owns VPS-backed endpoint tests. The host-free
      # runtime gate exercises only native session chrome; run-native-ssh-gate
      # supplies credentials and runs the endpoint/install cases separately.
      task_filter="com.bambouville.tessera.feature.session.AgentSessionIntegrationChromeInstrumentedTest,com.bambouville.tessera.feature.session.TmuxWindowOrderingUiInstrumentedTest"
    fi
    if [[ -n "$task_filter" ]]; then
      ANDROID_SERIAL="$serial" \
        JAVA_HOME="$java_home" \
        SWIFT_ANDROID_SWIFT="$swift_bin" \
        ./gradlew --no-daemon "$test_task" \
          "-Pandroid.testInstrumentationRunnerArguments.class=$task_filter"
    else
      ANDROID_SERIAL="$serial" \
        JAVA_HOME="$java_home" \
        SWIFT_ANDROID_SWIFT="$swift_bin" \
        ./gradlew --no-daemon "$test_task"
    fi
  done
  if [[ "$runtime_focus" != all ]]; then
    exit 0
  fi
  ANDROID_SERIAL="$serial" \
    JAVA_HOME="$java_home" \
    SWIFT_ANDROID_SWIFT="$swift_bin" \
    ./gradlew --no-daemon :app:installDebug
)

if [[ "$runtime_focus" != all ]]; then
  echo "TESSERA_ANDROID_RUNTIME_FOCUSED_OK focus=$runtime_focus"
  script_completed=1
  exit 0
fi

if ! "$adb" -s "$serial" shell am force-stop com.bambouville.tessera.debug; then
  echo "Android host shell could not be stopped before the normal-launch check" >&2
  exit 1
fi
start_output=''
if ! start_output="$("$adb" -s "$serial" shell am start -W \
    -n com.bambouville.tessera.debug/com.bambouville.tessera.MainActivity 2>&1)"; then
  echo "Android host shell failed its normal launch" >&2
  echo "$start_output" >&2
  "$adb" -s "$serial" logcat -d -t 200 '*:E' >&2 || true
  exit 1
fi
window_dump=''
for _ in {1..15}; do
  if "$adb" -s "$serial" shell uiautomator dump /data/local/tmp/tessera-window.xml \
      >/dev/null 2>&1; then
    if window_dump="$("$adb" -s "$serial" shell cat /data/local/tmp/tessera-window.xml 2>/dev/null)"; then
      if [[ "$window_dump" == *"no hosts yet"* && "$window_dump" == *"Add host"* ]]; then
        break
      fi
    fi
  fi
  sleep 1
done
if [[ "$window_dump" != *"no hosts yet"* || "$window_dump" != *"Add host"* ]]; then
  echo "Android host shell did not reach its empty-state milestone" >&2
  echo "$window_dump" >&2
  exit 1
fi
echo "TESSERA_ANDROID_HOST_SHELL_OK empty=1 add=1"

"$adb" -s "$serial" logcat -d \
  -s TesseraCoreBridge:I TesseraKeystore:I TesseraTerminal:I '*:S'
script_completed=1
