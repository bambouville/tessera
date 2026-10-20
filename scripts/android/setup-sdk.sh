#!/usr/bin/env bash
set -euo pipefail

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && "$(uname -s)" == "Darwin" ]]; then
  sdk_root="$HOME/Library/Android/sdk"
fi
if [[ -z "$sdk_root" ]]; then
  echo "Set ANDROID_SDK_ROOT before running this script." >&2
  exit 1
fi

sdkmanager=""
for candidate in \
  "$sdk_root/cmdline-tools/latest/bin/sdkmanager" \
  "$sdk_root/cmdline-tools/bin/sdkmanager" \
  "$sdk_root/tools/bin/sdkmanager"; do
  if [[ -x "$candidate" ]]; then
    sdkmanager="$candidate"
    break
  fi
done
if [[ -z "$sdkmanager" ]]; then
  echo "Android SDK Command-line Tools are required under $sdk_root." >&2
  exit 1
fi

echo "Installing Tessera's pinned Android SDK packages into $sdk_root"
"$sdkmanager" \
  "platform-tools" \
  "platforms;android-37.0" \
  "build-tools;36.0.0" \
  "ndk;28.2.13676358"

echo "SDK packages installed. Run scripts/android/check-environment.sh to verify."
