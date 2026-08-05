#!/usr/bin/env bash
# install-sims.sh — build, install, and launch Tessera on the usual manual
# iPad and iPhone simulators.
#
# Usage:
#   scripts/install-sims.sh
#   IPAD_SIMULATOR='My iPad' IPHONE_SIMULATOR='My iPhone' scripts/install-sims.sh
#   BUNDLE_ID=com.you.Tessera NO_LAUNCH=1 scripts/install-sims.sh
#   scripts/install-sims.sh --find-only
#
# This script only uses existing simulators. It never creates, erases,
# uninstalls, or resets either target, so their manual-testing state remains
# intact. The project builds a universal iPhone/iPad simulator app once, then
# installs that same fresh bundle on both targets.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Tessera.xcodeproj"
SCHEME="Tessera"
CONFIG="${CONFIG:-Debug}"
BUNDLE_ID="${BUNDLE_ID:-com.bambouville.TesseraApp}"

# These are the persistent simulators used for normal manual testing. Override
# either name in the environment if it is renamed or replaced.
IPAD_SIMULATOR="${IPAD_SIMULATOR:-iPad Pro 13-inch (M4)}"
IPHONE_SIMULATOR="${IPHONE_SIMULATOR:-Tessera iPhone Testing}"

find_only="${FIND_ONLY:-}"
if [[ "${1:-}" == "--find-only" ]]; then
  find_only=1
  shift
fi
if (($#)); then
  echo "usage: $0 [--find-only]" >&2
  exit 2
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

require_command xcrun
require_command jq

devices_json="$(xcrun simctl list devices available -j)"

find_simulator() {
  local name="$1"
  local expected_family="$2"
  local udid

  udid="$(jq -r --arg name "$name" --arg family "$expected_family" '
    [
      .devices[][]
      | select(.isAvailable == true and .name == $name)
      | select(
          if $family == "iPad" then
            (.deviceTypeIdentifier | contains("iPad"))
          else
            (.deviceTypeIdentifier | contains("iPhone"))
          end
        )
    ]
    | if length == 1 then .[0].udid else empty end
  ' <<<"$devices_json")"

  if [[ -z "$udid" ]]; then
    echo "error: could not find exactly one available $expected_family simulator named '$name'." >&2
    echo "       Set ${expected_family^^}_SIMULATOR to its exact Simulator.app name." >&2
    echo "       Available simulators:" >&2
    jq -r '
      .devices[][]
      | select(.isAvailable == true)
      | "         \(.name) [\(.udid)]"
    ' <<<"$devices_json" >&2
    exit 1
  fi

  printf '%s\n' "$udid"
}

ipad_udid="$(find_simulator "$IPAD_SIMULATOR" iPad)"
iphone_udid="$(find_simulator "$IPHONE_SIMULATOR" iPhone)"

if [[ -n "$find_only" ]]; then
  printf 'iPad:   %s [%s]\n' "$IPAD_SIMULATOR" "$ipad_udid"
  printf 'iPhone: %s [%s]\n' "$IPHONE_SIMULATOR" "$iphone_udid"
  exit 0
fi

echo "==> booting iPad: $IPAD_SIMULATOR"
xcrun simctl boot "$ipad_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$ipad_udid" -b

echo "==> booting iPhone: $IPHONE_SIMULATOR"
xcrun simctl boot "$iphone_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$iphone_udid" -b

build_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-install-sims.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT

echo "==> building $SCHEME ($CONFIG) for iPhone and iPad simulators..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "platform=iOS Simulator,id=$ipad_udid" \
  -derivedDataPath "$build_root" \
  build

app_path="$build_root/Build/Products/$CONFIG-iphonesimulator/$SCHEME.app"
if [[ ! -d "$app_path" ]]; then
  echo "error: built app not found at $app_path" >&2
  exit 1
fi

install_and_launch() {
  local name="$1"
  local udid="$2"

  echo "==> installing on $name..."
  xcrun simctl install "$udid" "$app_path"

  if [[ -z "${NO_LAUNCH:-}" ]]; then
    echo "==> launching $BUNDLE_ID on $name..."
    xcrun simctl launch --terminate-running-process "$udid" "$BUNDLE_ID" >/dev/null
  fi
}

install_and_launch "$IPAD_SIMULATOR" "$ipad_udid"
install_and_launch "$IPHONE_SIMULATOR" "$iphone_udid"

if [[ -z "${NO_OPEN_SIMULATOR:-}" ]]; then
  open -a Simulator
fi

echo "==> done."
