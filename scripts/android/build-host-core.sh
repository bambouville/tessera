#!/usr/bin/env bash
# Builds the shared Swift core and its JNI shim for the build machine, so
# Gradle's JVM unit tests run the same core the app links. Android devices
# use build-swift-core.sh; this host build is for tests only.
#
#   scripts/android/build-host-core.sh <output-directory>
#
# Output: libTesseraCoreAndroid and libtessera_core_jni (.dylib on macOS,
# .so on Linux) for java.library.path.
#
# Environment:
#   TESSERA_HOST_SWIFT_SCRATCH  SwiftPM scratch path (default: beside the output)
#   JAVA_HOME                   JDK whose jni.h the shim compiles against
set -euo pipefail

fail() {
  echo "Host core build failed: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || fail "usage: $0 <output-directory>"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_root="$1"
scratch_path="${TESSERA_HOST_SWIFT_SCRATCH:-$(dirname "$output_root")/hostSwiftScratch}"
mkdir -p "$output_root"

case "$(uname -s)" in
  Darwin)
    # The host toolchain links the OS Swift runtime; the Android toolchain
    # in SWIFT_ANDROID_SWIFT does not target macOS.
    swift_bin="$(xcrun --find swift)"
    cxx_bin="$(xcrun --find clang++)"
    sdk_flags=(-isysroot "$(xcrun --sdk macosx --show-sdk-path)")
    library_suffix=dylib
    jni_platform=darwin
    shared_flags=(-dynamiclib)
    ;;
  Linux)
    swift_bin="$(command -v swift || true)"
    cxx_bin="$(command -v clang++ || command -v g++ || true)"
    library_suffix=so
    jni_platform=linux
    shared_flags=(-shared -fPIC)
    sdk_flags=()
    ;;
  *) fail "unsupported host $(uname -s)" ;;
esac
[[ -x "$swift_bin" ]] || fail "no host swift"
[[ -x "$cxx_bin" ]] || fail "no host C++ compiler"

java_home="${JAVA_HOME:-}"
if [[ -z "$java_home" && "$(uname -s)" == Darwin ]]; then
  java_home="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
fi
[[ -f "$java_home/include/jni.h" ]] || fail "set JAVA_HOME to a JDK with include/jni.h"

"$swift_bin" build \
  --package-path "$repo_root/Packages/TesseraCore" \
  --product TesseraCoreAndroid \
  --configuration debug \
  --scratch-path "$scratch_path"

core_library="$("$swift_bin" build \
  --package-path "$repo_root/Packages/TesseraCore" \
  --configuration debug \
  --scratch-path "$scratch_path" \
  --show-bin-path)/libTesseraCoreAndroid.$library_suffix"
[[ -f "$core_library" ]] || fail "SwiftPM did not produce $core_library"
cp "$core_library" "$output_root/libTesseraCoreAndroid.$library_suffix"

# The shim dlopens the core by file name. On the device the loader finds the
# APK's copy; here the absolute path names the copy staged beside it.
"$cxx_bin" -std=c++17 -O1 -Wall -Wextra -Werror "${shared_flags[@]}" ${sdk_flags[@]+"${sdk_flags[@]}"} \
  -I"$java_home/include" -I"$java_home/include/$jni_platform" \
  -DTESSERA_CORE_LIBRARY_FILE="\"$output_root/libTesseraCoreAndroid.$library_suffix\"" \
  "$repo_root/android/core-bridge/src/main/cpp/tessera_core_jni.cpp" \
  -o "$output_root/libtessera_core_jni.$library_suffix"

echo "Host core ready: $output_root"
