#!/usr/bin/env bash
set -euo pipefail

# Runs the focused Agent Center Mosh lane on a disposable arm64 AVD. The test
# starts the production AndroidMoshTransport against the disposable fixture's
# mosh-server, then verifies both raw-Mosh bootstrap-root discovery and the
# Mosh+tmux SSH control side channel.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
openssl_root="${TESSERA_ANDROID_MOSH_OPENSSL_ROOT:-$repo_root/.build/android-deps/openssl-3.5.7-arm64-api28}"

if [[ ! -f "$openssl_root/include/openssl/evp.h" || ! -f "$openssl_root/lib/libcrypto.a" ]]; then
  openssl_root="$(TESSERA_ANDROID_OPENSSL_ROOT="$openssl_root" "$repo_root/scripts/android/prepare-mosh-openssl.sh")"
fi

TESSERA_ANDROID_AGENT_CENTER_MOSH=1 \
TESSERA_ANDROID_MOSH_OPENSSL_ROOT="$openssl_root" \
  exec "$repo_root/scripts/android/run-native-ssh-gate.sh"
