#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The Android link smoke below validates symbols after Swift has already
# compiled for arm64. Keep the exported-Swift/header symmetry check here, at
# the shared-core gate entrypoint, so an ABI declaration drift fails before
# the expensive cross-platform build starts.
"$repo_root/scripts/check-abi-header.sh"
swift_bin="${SWIFT_ANDROID_SWIFT:-swift}"
swift_sdk="${SWIFT_ANDROID_SDK:-aarch64-unknown-linux-android28}"
openssl_archive="${TESSERA_ANDROID_OPENSSL_ARCHIVE:-}"
ndk_root="${TESSERA_ANDROID_NDK_ROOT:-}"
runtime_serial="${TESSERA_ANDROID_RUNTIME_SERIAL:-}"
adb_bin="${TESSERA_ANDROID_ADB:-adb}"
swiftpm_cache_seed="${TESSERA_SWIFTPM_OFFLINE_CACHE_ROOT:-}"
build_jobs="${TESSERA_ANDROID_BUILD_JOBS:-4}"
scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-shared-android.XXXXXX")"

cleanup() {
  case "$scratch_root" in
    "${TMPDIR:-/tmp}"/tessera-shared-android.*) rm -rf "$scratch_root" ;;
    *) echo "refusing to remove unexpected scratch path: $scratch_root" >&2 ;;
  esac
}
exit_cleanup() {
  local status=$? step
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  for step in "$@"; do "$step"; done
  exit "$status"
}
trap 'exit_cleanup cleanup' EXIT

# Keep compiler, manifest, and package-manager caches inside the run-scoped
# scratch tree. The installed Swift SDK is still discovered from the caller's
# real home directory; only writable cache locations are redirected.
export XDG_CACHE_HOME="$scratch_root/xdg-cache"
export CLANG_MODULE_CACHE_PATH="$scratch_root/module-cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch_root/module-cache/swiftpm"
mkdir -p \
  "$XDG_CACHE_HOME" \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFTPM_MODULECACHE_OVERRIDE"

swift_version="$($swift_bin --version)"
sdk_list="$($swift_bin sdk list)"

if [[ "$swift_version" != *"Swift version 6.3.3"* ]]; then
  echo "Swift Android gate requires the matching open-source Swift 6.3.3 toolchain" >&2
  echo "$swift_version" >&2
  exit 1
fi

if [[ "$sdk_list" != *"swift-6.3.3-RELEASE_android"* ]]; then
  echo "missing Swift 6.3.3 Android SDK" >&2
  echo "$sdk_list" >&2
  exit 1
fi

if [[ "$swift_sdk" != "aarch64-unknown-linux-android28" ]]; then
  echo "Android gate target must be aarch64-unknown-linux-android28" >&2
  exit 1
fi

if [[ -z "$swiftpm_cache_seed" \
   || ! -d "$swiftpm_cache_seed/repositories" ]]; then
  echo "Android gate requires TESSERA_SWIFTPM_OFFLINE_CACHE_ROOT with hydrated repository mirrors" >&2
  exit 1
fi

validated_repository=""
validate_cached_repository() {
  local identity="$1"
  local expected_url="$2"
  local expected_revision="$3"
  local repositories=("$swiftpm_cache_seed/repositories/${identity}-"*)
  if (( ${#repositories[@]} != 1 )) || [[ ! -d "${repositories[0]}" ]] \
      || [[ -L "${repositories[0]}" ]]; then
    echo "offline SwiftPM cache must contain exactly one real $identity repository" >&2
    exit 1
  fi
  local repository="${repositories[0]}"
  local actual_url
  actual_url="$(git --git-dir="$repository" config --get remote.origin.url || true)"
  if [[ "$actual_url" != "$expected_url" ]]; then
    echo "offline SwiftPM $identity mirror has unexpected origin '$actual_url'" >&2
    exit 1
  fi
  if ! git --git-dir="$repository" cat-file -e "$expected_revision^{commit}"; then
    echo "offline SwiftPM $identity mirror is missing locked revision $expected_revision" >&2
    exit 1
  fi
  validated_repository="$repository"
}

validate_cached_repository \
  swift-crypto \
  https://github.com/apple/swift-crypto.git \
  95ba0316a9b733e92bb6b071255ff46263bbe7dc
swift_crypto_repository="$validated_repository"
validate_cached_repository \
  swift-asn1 \
  https://github.com/apple/swift-asn1.git \
  a9a5efd40eaf558a2bcd48d64b1d1646be686008
swift_asn1_repository="$validated_repository"

# Copy only the two exact, revision-validated bare mirrors. SwiftPM may write
# cache metadata during resolution, so the caller's reviewed cache remains
# read-only input and every mutation stays inside this run's scratch tree.
swiftpm_cache_root="$scratch_root/swiftpm-cache"
mkdir -p "$swiftpm_cache_root/repositories"
cp -R \
  "$swift_crypto_repository" \
  "$swift_asn1_repository" \
  "$swiftpm_cache_root/repositories/"

if [[ -z "$openssl_archive" || ! -f "$openssl_archive" ]]; then
  echo "Android gate requires TESSERA_ANDROID_OPENSSL_ARCHIVE for provenance verification" >&2
  exit 1
fi
expected_openssl_sha256="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"
actual_openssl_sha256="$(shasum -a 256 "$openssl_archive" | awk '{print $1}')"
if [[ "$actual_openssl_sha256" != "$expected_openssl_sha256" ]]; then
  echo "Android OpenSSL archive SHA256 does not match reviewed 3.5.7 source" >&2
  exit 1
fi

if [[ -z "$ndk_root" ]]; then
  echo "Android Mosh gate requires TESSERA_ANDROID_NDK_ROOT for ELF symbol verification" >&2
  exit 1
fi
ndk_properties="$ndk_root/source.properties"
if [[ ! -f "$ndk_properties" ]]; then
  echo "Android NDK is missing source.properties" >&2
  exit 1
fi
ndk_revision="$(sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$ndk_properties" | head -n 1)"
IFS=. read -r ndk_major ndk_minor ndk_build _ <<< "$ndk_revision"
if [[ ! "$ndk_major" =~ ^[0-9]+$ || ! "$ndk_minor" =~ ^[0-9]+$ \
   || ! "$ndk_build" =~ ^[0-9]+$ ]] \
   || (( ndk_major < 27 )) \
   || (( ndk_major == 27 && ndk_minor < 3 )) \
   || (( ndk_major == 27 && ndk_minor == 3 && ndk_build < 13750724 )); then
  echo "Android gate requires NDK r27d (27.3.13750724) or newer; found '$ndk_revision'" >&2
  exit 1
fi
llvm_nm="$(find "$ndk_root/toolchains/llvm/prebuilt" -path '*/bin/llvm-nm' -print -quit)"
llvm_readelf="$(find "$ndk_root/toolchains/llvm/prebuilt" -path '*/bin/llvm-readelf' -print -quit)"
if [[ -z "$llvm_nm" || -z "$llvm_readelf" ]]; then
  echo "Android NDK is missing llvm-nm or llvm-readelf" >&2
  exit 1
fi
if [[ ! "$build_jobs" =~ ^[1-9][0-9]*$ ]] || (( build_jobs > 64 )); then
  echo "TESSERA_ANDROID_BUILD_JOBS must be an integer from 1 through 64" >&2
  exit 1
fi

# Build the only accepted Android libcrypto from the archive whose digest was
# verified above. A separately supplied prefix cannot satisfy this release
# gate: headers and the archive members linked below share this run-scoped,
# source-derived prefix.
openssl_source_root="$scratch_root/openssl-source"
openssl_root="$scratch_root/openssl-prefix"
mkdir -p "$openssl_source_root" "$openssl_root"
tar -xzf "$openssl_archive" \
  -C "$openssl_source_root" \
  --strip-components=1
if [[ ! -x "$openssl_source_root/Configure" ]]; then
  echo "reviewed OpenSSL archive did not contain an executable Configure script" >&2
  exit 1
fi
ndk_bin="$(dirname "$llvm_nm")"
echo "building reviewed OpenSSL 3.5.7 for Android arm64" >&2
(
  export ANDROID_NDK_ROOT="$ndk_root"
  export PATH="$ndk_bin:$PATH"
  cd "$openssl_source_root"
  ./Configure \
    android-arm64 \
    -D__ANDROID_API__=28 \
    no-shared \
    no-module \
    no-tests \
    no-apps \
    no-legacy \
    --prefix="$openssl_root" \
    --openssldir="$openssl_root/ssl" \
    --libdir=lib
  make -s -j"$build_jobs" build_sw
  make -s install_sw
)
if [[ ! -f "$openssl_root/include/openssl/evp.h" \
   || ! -f "$openssl_root/include/openssl/opensslv.h" \
   || ! -f "$openssl_root/lib/libcrypto.a" ]]; then
  echo "source-built Android OpenSSL prefix is incomplete" >&2
  exit 1
fi
if ! rg -q '^# *define +OPENSSL_VERSION_STR +"3\.5\.7"$' \
    "$openssl_root/include/openssl/opensslv.h"; then
  echo "source-built Android OpenSSL does not identify exact version 3.5.7" >&2
  exit 1
fi

common=(
  --swift-sdk "$swift_sdk"
  --static-swift-stdlib
  --disable-sandbox
  --cache-path "$swiftpm_cache_root"
  --skip-update
  --disable-prefetching
  --force-resolved-versions
)

# The portable import smoke is deliberately distinct from the macOS-only
# AppleContinuityImportSmoke target. An accidental Apple import must fail here
# before the Android compiler is invoked.
if rg -n 'TesseraAppleContinuity' \
    "$repo_root/Packages/SharedPlatformImportSmoke/Sources/SharedPlatformImportSmoke"; then
  echo "Android import smoke must not depend on TesseraAppleContinuity" >&2
  exit 1
fi
if rg -n 'TesseraAppleContinuity' \
    "$repo_root/Packages/TesseraCore/Sources/TesseraCore/TesseraCore.swift"; then
  echo "portable TesseraCore umbrella must not export TesseraAppleContinuity" >&2
  exit 1
fi

"$swift_bin" build \
  --package-path "$repo_root/Packages/TesseraCore" \
  --target TesseraCore \
  --scratch-path "$scratch_root/core" \
  "${common[@]}"

"$swift_bin" build \
  --package-path "$repo_root/Packages/SharedPlatformImportSmoke" \
  --product SharedPlatformCABILinkSmoke \
  --scratch-path "$scratch_root/shared-smoke" \
  "${common[@]}"

"$swift_bin" build \
  --package-path "$repo_root/Packages/TmuxControl" \
  --target TmuxControlCore \
  --scratch-path "$scratch_root/tmux" \
  "${common[@]}"

TESSERA_ANDROID_OPENSSL_ROOT="$openssl_root" "$swift_bin" build \
  --package-path "$repo_root/Packages/MoshBridge" \
  --product MoshCABILinkSmoke \
  --configuration release \
  --scratch-path "$scratch_root/mosh" \
  "${common[@]}"

"$swift_bin" build \
  --package-path "$repo_root/Packages/SharedPlatformImportSmoke" \
  --target SharedPlatformImportSmoke \
  --scratch-path "$scratch_root/shared-smoke" \
  "${common[@]}"

mosh_executable="$scratch_root/mosh/$swift_sdk/release/MoshCABILinkSmoke"
core_abi_executable="$scratch_root/shared-smoke/$swift_sdk/debug/SharedPlatformCABILinkSmoke"
if [[ ! -f "$core_abi_executable" ]]; then
  echo "Tessera Core C ABI did not produce a linked Android arm64 executable" >&2
  exit 1
fi
core_abi_file_report="$scratch_root/core-abi-file.txt"
core_abi_nm_report="$scratch_root/core-abi-nm.txt"
file "$core_abi_executable" > "$core_abi_file_report"
"$llvm_nm" "$core_abi_executable" > "$core_abi_nm_report"
if ! rg -q 'ELF 64-bit.*ARM aarch64' "$core_abi_file_report"; then
  echo "Tessera Core C ABI link smoke is not an Android arm64 ELF executable" >&2
  exit 1
fi
for symbol in \
  tessera_core_abi_version \
  tessera_core_abi_max_payload_bytes \
  tessera_core_runtime_create \
  tessera_core_runtime_send \
  tessera_core_runtime_emit \
  tessera_core_runtime_destroy \
  tessera_tmux_runtime_create \
  tessera_tmux_runtime_feed \
  tessera_tmux_runtime_send_command \
  tessera_tmux_runtime_queue_command \
  tessera_tmux_runtime_submit_fact \
  tessera_tmux_runtime_take_render_bytes \
  tessera_tmux_runtime_destroy \
  tessera_cross_device_abi_version \
  tessera_cross_device_abi_max_payload_bytes \
  tessera_cross_device_runtime_create \
  tessera_cross_device_runtime_send \
  tessera_cross_device_runtime_destroy; do
  if ! rg -q " [Tt] $symbol$" "$core_abi_nm_report"; then
    echo "linked Android Core ABI smoke is missing $symbol" >&2
    exit 1
  fi
done

if [[ ! -f "$mosh_executable" ]]; then
  echo "Mosh C ABI did not produce a linked Android arm64 executable" >&2
  exit 1
fi
mosh_file_report="$scratch_root/mosh-file.txt"
mosh_nm_report="$scratch_root/mosh-nm.txt"
mosh_undefined_report="$scratch_root/mosh-undefined-nm.txt"
mosh_dynamic_report="$scratch_root/mosh-dynamic.txt"
file "$mosh_executable" > "$mosh_file_report"
"$llvm_nm" "$mosh_executable" > "$mosh_nm_report"
"$llvm_nm" -u "$mosh_executable" > "$mosh_undefined_report"
"$llvm_readelf" -d "$mosh_executable" > "$mosh_dynamic_report"
if ! rg -q 'ELF 64-bit.*ARM aarch64' "$mosh_file_report"; then
  echo "Mosh C ABI link smoke is not an Android arm64 ELF executable" >&2
  exit 1
fi

for symbol in \
  tessera_mosh_abi_version \
  tessera_mosh_max_output_batch_bytes \
  tessera_mosh_client_create \
  tessera_mosh_client_start \
  tessera_mosh_client_tick \
  tessera_mosh_client_inject_bytes \
  tessera_mosh_client_resize \
  tessera_mosh_client_force_full_repaint \
  tessera_mosh_client_shutdown \
  tessera_mosh_client_socket_fd \
  tessera_mosh_client_copy_socket_fds \
  tessera_mosh_client_is_connected \
  tessera_mosh_client_is_transport_reachable \
  tessera_mosh_client_is_shutdown_complete \
  tessera_mosh_client_application_mode_cursor_keys \
  tessera_mosh_client_retains_bootstrap_key_material \
  tessera_mosh_client_copy_last_error \
  tessera_mosh_client_destroy; do
  if ! rg -q " [Tt] $symbol$" "$mosh_nm_report"; then
    echo "linked Android Mosh smoke is missing $symbol" >&2
    exit 1
  fi
done

if rg -q 'EVP_|MoshClient|google.*protobuf' "$mosh_undefined_report"; then
  echo "linked Android Mosh smoke retains unresolved crypto/core/protobuf symbols" >&2
  exit 1
fi

if ! rg -q 'Shared library: \[libz\.so\]' "$mosh_dynamic_report"; then
  echo "linked Android Mosh smoke did not retain its Android zlib dependency" >&2
  exit 1
fi
if rg -q 'Shared library: \[libcrypto\.so' "$mosh_dynamic_report"; then
  echo "linked Android Mosh smoke unexpectedly depends on a platform libcrypto.so" >&2
  exit 1
fi

if [[ -n "$runtime_serial" ]]; then
  if ! command -v "$adb_bin" >/dev/null 2>&1; then
    echo "Android Mosh runtime requested but adb is unavailable: $adb_bin" >&2
    exit 1
  fi
  runtime_directory="/data/local/tmp/tessera-mosh-runtime-$$"
  "$adb_bin" -s "$runtime_serial" shell mkdir "$runtime_directory"
  runtime_cleanup() {
    "$adb_bin" -s "$runtime_serial" shell rm -rf "$runtime_directory" \
      >/dev/null 2>&1 || true
  }
  trap 'exit_cleanup runtime_cleanup cleanup' EXIT
  libcxx_shared="$(find "$ndk_root/toolchains/llvm/prebuilt" \
    -path '*/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so' \
    -print -quit)"
  if [[ -z "$libcxx_shared" || ! -f "$libcxx_shared" ]]; then
    echo "Android NDK libc++_shared.so is unavailable for the Mosh runtime" >&2
    exit 1
  fi
  "$adb_bin" -s "$runtime_serial" push \
    "$mosh_executable" \
    "$runtime_directory/MoshCABILinkSmoke" >/dev/null
  "$adb_bin" -s "$runtime_serial" push \
    "$libcxx_shared" \
    "$runtime_directory/libc++_shared.so" >/dev/null
  "$adb_bin" -s "$runtime_serial" shell chmod 0700 \
    "$runtime_directory/MoshCABILinkSmoke"
  runtime_output="$($adb_bin -s "$runtime_serial" shell \
    "cd '$runtime_directory' && LD_LIBRARY_PATH='$runtime_directory' ./MoshCABILinkSmoke")"
  if [[ "$runtime_output" != *"TESSERA_MOSH_ANDROID_RUNTIME_OK"* ]]; then
    echo "Android Mosh runtime did not report its success marker" >&2
    echo "$runtime_output" >&2
    exit 1
  fi
  echo "$runtime_output"
  runtime_cleanup
fi

echo "shared-core Android arm64 compile and link checks passed"
script_completed=1
