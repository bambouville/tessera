#!/usr/bin/env bash
# Builds the Play upload bundle and checks it before it leaves the machine:
# arm64 only (the core and Mosh exist for no other ABI) with both libraries
# present, free of Google's telemetry uploader (the privacy policy rules it
# out), and signed entirely by the upload key.
#
# Usage: scripts/android/bundle-release.sh            build, then check
#        scripts/android/bundle-release.sh --check AAB check an existing bundle
#
# One-time setup (see android/README.md):
#   keytool -genkeypair -keystore ~/.android-keys/tessera-upload.jks -alias upload ...
#   security add-generic-password -a "$USER" -s tessera-android-upload -w
#
# The password goes from the Keychain to one Gradle run through the
# environment; no daemon or configuration cache outlives the build with it.
set -euo pipefail

fail() {
  echo "release bundle: $*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bundle="$repo_root/android/app/build/outputs/bundle/release/app-release.aab"
build=1
if [[ "${1:-}" == "--check" ]]; then
  [[ $# -eq 2 ]] || fail "usage: $0 [--check BUNDLE]"
  bundle="$2"
  build=0
elif [[ $# -ne 0 ]]; then
  fail "usage: $0 [--check BUNDLE]"
fi

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
# The SDK is found the way check-environment.sh finds it, then handed to Gradle.
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -f "$repo_root/android/local.properties" ]]; then
  sdk_root="$(sed -n 's/^sdk\.dir=//p' "$repo_root/android/local.properties" | head -n 1)"
fi
if [[ -z "$sdk_root" ]]; then
  for candidate in "$HOME/Library/Android/sdk" /opt/homebrew/share/android-commandlinetools; do
    [[ -d "$candidate" ]] && { sdk_root="$candidate"; break; }
  done
fi
[[ -n "$sdk_root" && -d "$sdk_root" ]] || fail "no Android SDK found; set ANDROID_SDK_ROOT"
export ANDROID_SDK_ROOT="$sdk_root"
store="${TESSERA_UPLOAD_STORE_FILE:-$HOME/.android-keys/tessera-upload.jks}"
[[ -f "$store" ]] || fail "no upload keystore at $store"
# Gradle resolves a relative path against android/app; hand it an absolute one.
TESSERA_UPLOAD_STORE_FILE="$(cd "$(dirname "$store")" && pwd)/$(basename "$store")"
export TESSERA_UPLOAD_STORE_FILE
export TESSERA_UPLOAD_KEY_ALIAS="${TESSERA_UPLOAD_KEY_ALIAS:-upload}"
TESSERA_UPLOAD_STORE_PASSWORD="$(security find-generic-password -a "$USER" -s tessera-android-upload -w)" \
  || fail "no Keychain password (service tessera-android-upload)"
export TESSERA_UPLOAD_STORE_PASSWORD

if [[ $build -eq 1 ]]; then
  (cd "$repo_root/android" && ./gradlew --no-daemon --no-configuration-cache --console=plain :app:bundleRelease) \
    || fail "gradle failed"
fi
[[ -f "$bundle" ]] || fail "missing $bundle"

work="$(mktemp -d "${TMPDIR:-/tmp}/tessera-bundle.XXXXXX")"
cleanup() {
  local status=$?
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

# Each check reads a file, never a live pipe, so an unzip failure stops the
# script instead of reading as "nothing found".
unzip -Z1 "$bundle" > "$work/entries" || fail "cannot list $bundle"
other_abis="$(grep '^base/lib/' "$work/entries" | grep -v '^base/lib/arm64-v8a/' || true)"
[[ -z "$other_abis" ]] || fail "native libraries outside arm64-v8a: $other_abis"
# Without these the app still installs, but cannot open any session, or a Mosh one.
for lib in libTesseraCoreAndroid.so libtessera_core_jni.so libtessera_mosh_jni.so; do
  grep -x -F "base/lib/arm64-v8a/$lib" "$work/entries" > /dev/null || fail "missing native library $lib"
done

unzip -q "$bundle" 'base/dex/*' 'base/manifest/AndroidManifest.xml' -d "$work/x" || fail "cannot extract $bundle"
[[ -f "$work/x/base/manifest/AndroidManifest.xml" ]] || fail "bundle has no base manifest"
# The manifest names classes with dots, dex descriptors with slashes.
for marker in com.google.android.datatransport com.google.mlkit com.google.firebase; do
  status=0
  LC_ALL=C grep -a -r -F -e "$marker" -e "${marker//.//}" "$work/x/base" > /dev/null || status=$?
  case $status in
    0) fail "contains $marker" ;;
    1) ;;
    *) fail "cannot inspect the bundle for $marker" ;;
  esac
done

# JCA creates a provider's services by reflection, which R8 cannot see. Tessera's
# host-key factories, registered by class name, came out of R8 as empty abstract
# shells, and host keys fell through to AndroidKeyStore, which refuses them. A
# crypto SPI subclass left without a constructor can never be instantiated.
dexdump="$ANDROID_SDK_ROOT/build-tools/36.0.0/dexdump"
[[ -x "$dexdump" ]] || fail "no dexdump at $dexdump (Build Tools 36.0.0)"
for dex in "$work"/x/base/dex/*.dex; do
  "$dexdump" "$dex" >> "$work/dexdump" 2> /dev/null || fail "cannot read $dex"
done
awk '
  /^Class #/ { section = "" }
  $1 == "Class" && $2 == "descriptor" { cls = $4; gsub(/\047/, "", cls); classes[cls] = 1 }
  $1 == "Superclass" { s = $3; gsub(/\047/, "", s); parent[cls] = s }
  /^  (Static fields|Instance fields|Virtual methods) / { section = "" }
  /^  Direct methods / { section = "direct" }
  section == "direct" && $1 == "name" && $3 == "\047<init>\047" { constructors[cls]++ }
  END {
    for (c in classes) {
      s = parent[c]
      for (depth = 0; depth < 32 && s != ""; depth++) {
        # KeyPairGenerator, MessageDigest and Signature are SPIs themselves.
        if (s ~ /^Ljavax?\/(security|crypto)\/[A-Za-z]*Spi;$/ ||
            s ~ /^Ljava\/security\/(KeyPairGenerator|MessageDigest|Signature);$/) {
          if (!constructors[c]) print c
          break
        }
        s = parent[s]
      }
    }
  }
' "$work/dexdump" > "$work/stripped" || fail "cannot inspect the bundle's crypto classes"
grep -c '^Class #' "$work/dexdump" > /dev/null || fail "dexdump listed no classes"
[[ ! -s "$work/stripped" ]] \
  || fail "crypto SPI classes without a constructor (stripped by R8): $(sort "$work/stripped" | tr '\n' ' ')"

# Native code calls back into these methods by name (GetMethodID in
# tessera_core_jni.cpp and tessera_mosh_jni.cpp), which R8 cannot see either.
# Without them Agent Center could not start and every Mosh connect aborted.
cat > "$work/callbacks" <<'CALLBACKS'
Lcom/bambouville/tessera/core/bridge/NativeEventSink; onEvent (Ljava/nio/ByteBuffer;)V
Lcom/bambouville/tessera/core/bridge/NativeAgentEventSink; onEvent (Ljava/nio/ByteBuffer;)V
Lcom/bambouville/tessera/networking/mosh/JniMoshNativeClient; onNativeOutput ([B)V
CALLBACKS
awk '
  NR == FNR { wanted[$0] = 1; next }
  $1 == "Class" && $2 == "descriptor" { cls = $4; gsub(/\047/, "", cls) }
  $1 == "name" { name = $3; gsub(/\047/, "", name) }
  $1 == "type" { type = $3; gsub(/\047/, "", type); found[cls " " name " " type] = 1 }
  END { for (w in wanted) if (!(w in found)) print w }
' "$work/callbacks" "$work/dexdump" > "$work/missing" || fail "cannot inspect the bundle's JNI callbacks"
[[ ! -s "$work/missing" ]] \
  || fail "JNI callbacks renamed or removed by R8: $(sort "$work/missing" | tr '\n' ';')"

# ART never compiles a method over 10,000 dex code units, so it would always
# run interpreted; a Compose screen reaches that by inlining alone.
"$repo_root/scripts/android/check-huge-methods.sh" "$work"/x/base/dex/*.dex \
  || fail "methods too large for ART to compile (listed above)"

# -strict with the keystore and alias fails on unsigned entries, entries signed
# by any other key, and broken signatures; a self-signed upload key is fine.
"$JAVA_HOME/bin/jarsigner" -verify -strict -keystore "$TESSERA_UPLOAD_STORE_FILE" \
  -storepass:env TESSERA_UPLOAD_STORE_PASSWORD "$bundle" "$TESSERA_UPLOAD_KEY_ALIAS" > "$work/verify" 2>&1 \
  || fail "not signed entirely by the upload key: $(grep -E '^(This jar|jarsigner)' "$work/verify" | tr '\n' ' ')"
unset TESSERA_UPLOAD_STORE_PASSWORD
"$JAVA_HOME/bin/keytool" -printcert -jarfile "$bundle" > "$work/cert" || fail "cannot read the signer certificate"
signer="$(awk '/SHA256:/ && !n++ { print $2 }' "$work/cert")"

echo "bundle: $bundle"
echo "upload key SHA-256: $signer"
script_completed=1
