#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
# Gradle invokes this without a login shell, so fall back to the checkout's own
# SDK pointer and then the standard macOS location before giving up.
if [[ -z "$sdk_root" && -f "$repo_root/android/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" | head -n 1)"
fi
if [[ -z "$sdk_root" && "$(uname -s)" == "Darwin" ]]; then
  # Same candidate order as scripts/install-android.sh:resolve_sdk_root.
  for candidate in \
    "$HOME/Library/Android/sdk" \
    "/opt/homebrew/share/android-commandlinetools" \
    "/usr/local/share/android-commandlinetools"; do
    if [[ -d "$candidate" ]]; then
      sdk_root="$candidate"
      break
    fi
  done
fi
[[ -n "$sdk_root" ]] || { echo "Android SDK root is required" >&2; exit 1; }
ndk_root="${TESSERA_ANDROID_NDK_ROOT:-$sdk_root/ndk/28.2.13676358}"
[[ -f "$ndk_root/source.properties" ]] || {
  echo "Android NDK 28.2.13676358 is required at $ndk_root" >&2
  exit 1
}

version="3.5.7"
expected_sha="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"
dependency_root="$repo_root/.build/android-deps"
archive="${TESSERA_ANDROID_OPENSSL_ARCHIVE:-$dependency_root/openssl-$version.tar.gz}"
prefix="${TESSERA_ANDROID_OPENSSL_ROOT:-$dependency_root/openssl-$version-arm64-api28}"
mkdir -p "$dependency_root"

# This script replaces a generated prefix after a verified source build. A
# typo in an environment override must fail before reaching the replacement
# rm; never allow it to target an arbitrary user directory.
case "$prefix" in
  "$dependency_root"/*) ;;
  *) echo "TESSERA_ANDROID_OPENSSL_ROOT must be inside $dependency_root" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$prefix")"
dependency_root="$(cd -P "$dependency_root" && pwd)"
prefix_parent="$(cd -P "$(dirname "$prefix")" && pwd)"
prefix="$prefix_parent/$(basename "$prefix")"
case "$prefix" in
  "$dependency_root"/*) ;;
  *) echo "TESSERA_ANDROID_OPENSSL_ROOT resolves outside $dependency_root" >&2; exit 1 ;;
esac
marker="$prefix/.tessera-source-sha256"

# curl truncates the target as the transfer starts, so an interrupted download leaves a
# short file behind. Treat a checksum mismatch as "fetch again" rather than a hard stop,
# or the prefix can never be built again without deleting the file by hand.
if [[ -f "$archive" ]] \
  && [[ "$(shasum -a 256 "$archive" | awk '{print $1}')" != "$expected_sha" ]]; then
  echo "==> discarding incomplete OpenSSL archive and refetching..." >&2
  rm -f "$archive"
fi
if [[ ! -f "$archive" ]]; then
  command -v curl >/dev/null 2>&1 || { echo "curl is required to fetch OpenSSL" >&2; exit 1; }
  echo "==> downloading reviewed OpenSSL $version source..." >&2
  curl --fail --location --proto '=https' --tlsv1.2 \
    "https://github.com/openssl/openssl/releases/download/openssl-$version/openssl-$version.tar.gz" \
    --output "$archive"
fi

actual_sha="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual_sha" == "$expected_sha" ]] || {
  echo "OpenSSL $version archive checksum mismatch" >&2
  exit 1
}
if [[ -f "$marker" && "$(tr -d '\r\n' < "$marker")" == "$expected_sha" \
   && -f "$prefix/include/openssl/evp.h" && -f "$prefix/lib/libcrypto.a" ]]; then
  printf '%s\n' "$prefix"
  exit 0
fi

scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-openssl-android.XXXXXX")"
cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  case "$scratch_root" in
    "${TMPDIR:-/tmp}"/tessera-openssl-android.*) rm -rf "$scratch_root" ;;
    *) echo "refusing to remove unexpected scratch path: $scratch_root" >&2 ;;
  esac
  exit "$status"
}
trap cleanup EXIT
source_root="$scratch_root/source"
build_prefix="$scratch_root/prefix"
mkdir -p "$source_root" "$build_prefix"
tar -xzf "$archive" -C "$source_root" --strip-components=1
[[ -x "$source_root/Configure" ]] || { echo "OpenSSL Configure script is missing" >&2; exit 1; }
ndk_bin="$(find "$ndk_root/toolchains/llvm/prebuilt" -path '*/bin/clang' -print -quit | xargs dirname)"
[[ -d "$ndk_bin" ]] || { echo "Android NDK clang toolchain is missing" >&2; exit 1; }
echo "==> building reviewed OpenSSL $version for Android arm64 (one-time)..." >&2
(
  export ANDROID_NDK_ROOT="$ndk_root"
  export PATH="$ndk_bin:$PATH"
  cd "$source_root"
  ./Configure android-arm64 no-shared no-module no-tests no-apps no-legacy \
    --prefix="$build_prefix" --openssldir="$build_prefix/ssl" --libdir=lib >/dev/null
  make -s -j"${TESSERA_ANDROID_BUILD_JOBS:-4}" build_sw >/dev/null
  make -s install_sw >/dev/null
)
[[ -f "$build_prefix/include/openssl/evp.h" && -f "$build_prefix/lib/libcrypto.a" ]] || {
  echo "Android OpenSSL prefix is incomplete" >&2
  exit 1
}
rm -rf -- "$prefix"
mv "$build_prefix" "$prefix"
printf '%s\n' "$expected_sha" > "$marker"
printf '%s\n' "$prefix"
script_completed=1
