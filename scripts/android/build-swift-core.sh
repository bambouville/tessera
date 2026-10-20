#!/usr/bin/env bash
set -euo pipefail

swift_version="6.3.3"
swift_sdk_id="swift-6.3.3-RELEASE_android"
target_triple="aarch64-unknown-linux-android28"
android_abi="arm64-v8a"
expected_ndk="28.2.13676358"

fail() {
  echo "Swift Android core build failed: $*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  fail "usage: $0 <jni-libs-output-directory>"
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_root="$1"

swift_bin="${SWIFT_ANDROID_SWIFT:-$(command -v swift || true)}"
[[ -x "$swift_bin" ]] || fail "Swift $swift_version is required; set SWIFT_ANDROID_SWIFT"
swift_version_output="$($swift_bin --version)"
grep -q "Swift version $swift_version" <<<"$swift_version_output" || fail \
  "expected Swift $swift_version, found: ${swift_version_output%%$'\n'*}"
"$swift_bin" sdk list | grep -qx "$swift_sdk_id" || fail \
  "missing Swift SDK $swift_sdk_id; see android/README.md"

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f "$repo_root/android/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" | head -n 1)"
fi
if [[ -z "$sdk_root" && "$(uname -s)" == "Darwin" ]]; then
  sdk_root="$HOME/Library/Android/sdk"
fi
[[ -n "$sdk_root" ]] || fail "set ANDROID_SDK_ROOT to the pinned Android SDK"

ndk_root="${TESSERA_ANDROID_NDK_ROOT:-$sdk_root/ndk/$expected_ndk}"
[[ -f "$ndk_root/source.properties" ]] || fail "missing Android NDK at $ndk_root"
actual_ndk="$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$ndk_root/source.properties")"
[[ "$actual_ndk" == "$expected_ndk" ]] || fail \
  "expected NDK $expected_ndk, found $actual_ndk"

static_resource_dir="${SWIFT_ANDROID_STATIC_RESOURCE_DIR:-}"
if [[ -z "$static_resource_dir" ]]; then
  shopt -s nullglob
  candidates=(
    "$HOME/Library/org.swift.swiftpm/swift-sdks/$swift_sdk_id.artifactbundle/swift-android/swift-resources/usr/lib/swift_static-aarch64"
    "$HOME/.swiftpm/swift-sdks/$swift_sdk_id.artifactbundle/swift-android/swift-resources/usr/lib/swift_static-aarch64"
    "$HOME/.local/share/swiftpm/swift-sdks/$swift_sdk_id.artifactbundle/swift-android/swift-resources/usr/lib/swift_static-aarch64"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      static_resource_dir="$candidate"
      break
    fi
  done
fi
[[ -d "$static_resource_dir" ]] || fail \
  "cannot locate the $swift_sdk_id static resource directory; set SWIFT_ANDROID_STATIC_RESOURCE_DIR"

prebuilt_roots=("$ndk_root/toolchains/llvm/prebuilt"/*)
[[ ${#prebuilt_roots[@]} -eq 1 ]] || fail "cannot identify the NDK host toolchain"
ndk_prebuilt="${prebuilt_roots[0]}"
strip_bin="$ndk_prebuilt/bin/llvm-strip"
libcxx="$ndk_prebuilt/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so"
[[ -x "$strip_bin" ]] || fail "missing NDK llvm-strip"
[[ -f "$libcxx" ]] || fail "missing NDK libc++_shared.so"

scratch_path="${TESSERA_ANDROID_SWIFT_SCRATCH:-$(dirname "$output_root")/swiftScratch}"
install_path="$output_root/$android_abi"
mkdir -p "$install_path"

"$swift_bin" build \
  --package-path "$repo_root/Packages/TesseraCore" \
  --product TesseraCoreAndroid \
  --configuration release \
  --swift-sdk "$target_triple" \
  --disable-sandbox \
  --scratch-path "$scratch_path" \
  -Xswiftc -static-stdlib \
  -Xswiftc -resource-dir \
  -Xswiftc "$static_resource_dir"

built_library="$scratch_path/$target_triple/release/libTesseraCoreAndroid.so"
[[ -f "$built_library" ]] || fail "SwiftPM did not produce $built_library"
"$strip_bin" --strip-unneeded -o "$install_path/libTesseraCoreAndroid.so" "$built_library"
cp "$libcxx" "$install_path/libc++_shared.so"

echo "Swift Android core ready: $install_path/libTesseraCoreAndroid.so"
