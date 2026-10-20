#!/usr/bin/env bash
set -euo pipefail

expected_java_major=21
expected_ndk="28.2.13676358"
expected_platform="android-37.0"
expected_build_tools="36.0.0"

fail() {
  echo "Android environment check failed: $*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
android_root="$repo_root/android"

if [[ -z "${JAVA_HOME:-}" ]] && [[ "$(uname -s)" == "Darwin" ]]; then
  JAVA_HOME="$(/usr/libexec/java_home -v "$expected_java_major" 2>/dev/null || true)"
fi
[[ -n "${JAVA_HOME:-}" ]] || fail "JDK $expected_java_major is required; set JAVA_HOME"
java_bin="$JAVA_HOME/bin/java"
[[ -x "$java_bin" ]] || fail "JAVA_HOME does not contain an executable java: $JAVA_HOME"
java_version="$($java_bin -version 2>&1)"
java_major="$(sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p' <<<"$java_version")"
[[ "$java_major" == "$expected_java_major" ]] || fail \
  "expected JDK $expected_java_major, found: ${java_version%%$'\n'*}"

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f "$android_root/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$android_root/local.properties" | head -n 1)"
fi
if [[ -z "$sdk_root" && "$(uname -s)" == "Darwin" ]]; then
  sdk_root="$HOME/Library/Android/sdk"
fi
[[ -n "$sdk_root" ]] || fail "set ANDROID_SDK_ROOT to an Android SDK installation"
[[ -d "$sdk_root" ]] || fail "Android SDK directory does not exist: $sdk_root"

[[ -d "$sdk_root/platforms/$expected_platform" ]] || fail \
  "missing SDK platform $expected_platform"
[[ -d "$sdk_root/build-tools/$expected_build_tools" ]] || fail \
  "missing SDK Build Tools $expected_build_tools"
[[ -x "$sdk_root/platform-tools/adb" ]] || fail "missing Android SDK Platform-Tools"

ndk_root="$sdk_root/ndk/$expected_ndk"
[[ -f "$ndk_root/source.properties" ]] || fail "missing Android NDK $expected_ndk"
actual_ndk="$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$ndk_root/source.properties")"
[[ "$actual_ndk" == "$expected_ndk" ]] || fail \
  "expected NDK $expected_ndk, found $actual_ndk"

[[ -x "$android_root/gradlew" ]] || fail "missing executable Gradle wrapper"
grep -Eq '^distributionSha256Sum=[0-9a-f]{64}$' \
  "$android_root/gradle/wrapper/gradle-wrapper.properties" || fail \
  "Gradle wrapper distribution must be checksum-pinned"

echo "Android environment ready"
echo "  JDK:      $java_major ($JAVA_HOME)"
echo "  SDK:      $sdk_root"
echo "  Platform: $expected_platform"
echo "  NDK:      $actual_ndk"
