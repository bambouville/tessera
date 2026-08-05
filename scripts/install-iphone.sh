#!/usr/bin/env bash
# install-iphone.sh — build, install, and launch Tessera on a physical iPhone.
#
# Usage:
#   scripts/install-iphone.sh                       # auto-pick the first connected iPhone
#   scripts/install-iphone.sh <UDID>                # target a specific device
#   IPHONE_UDID=<UDID> scripts/install-iphone.sh    # same, via env var
#   BUNDLE_ID=com.you.Tessera scripts/install-iphone.sh
#   NO_LAUNCH=1 scripts/install-iphone.sh           # build + install only
#   scripts/install-iphone.sh --find-only           # list paired iPhones and exit (no build)
#   FIND_ONLY=1 scripts/install-iphone.sh            # same, via env var
#
# Prereqs:
#   * Xcode 15+ (for `xcrun devicectl`).
#   * An Apple ID that belongs to the signing team is added in Xcode >
#     Settings > Accounts. `-allowProvisioningUpdates` needs it to talk to
#     the Apple Developer portal; the script then auto-registers the device
#     and generates the profile on first build (no manual Xcode build needed).
#   * iPhone has been paired with this Mac, has Developer Mode enabled, and
#     trusts this computer.
#   * iPhone is reachable via USB or paired Wi-Fi.

set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)/Tessera.xcodeproj"
SCHEME="Tessera"
CONFIG="Debug"
BUNDLE_ID="${BUNDLE_ID:-com.bambouville.TesseraApp}"

FIND_ONLY="${FIND_ONLY:-}"
if [[ "${1:-}" == "--find-only" ]]; then
  FIND_ONLY=1
  shift
fi

# Enumerate iPhones without building or installing. This is especially useful
# during first-time pairing: the device should report pairing=paired before the
# normal install path is attempted.
if [[ -n "$FIND_ONLY" ]]; then
  echo "==> scanning for iPhones via xcrun devicectl..."
  xcrun devicectl list devices --json-output - 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
if data.get("info", {}).get("outcome") == "failed" or "error" in data:
    description = (
        data.get("error", {})
        .get("userInfo", {})
        .get("NSLocalizedDescription", {})
        .get("string", "devicectl failed while scanning for devices")
    )
    print(f"error: {description}", file=sys.stderr)
    sys.exit(1)
devices = data.get("result", {}).get("devices", [])
iphones = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("deviceType") != "iPhone":
        continue
    iphones.append(d)
if not iphones:
    print("  (no iPhones visible to devicectl)")
    sys.exit(0)
for d in iphones:
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    name = d.get("deviceProperties", {}).get("name", "?")
    model = hw.get("marketingName") or hw.get("productType", "?")
    udid = hw.get("udid", "?")
    pairing = conn.get("pairingState", "?")
    transport = conn.get("transportType", "?")
    tunnel = conn.get("tunnelState", "?")
    addrs = conn.get("localHostnames", []) or []
    print(f"  name      : {name}")
    print(f"  model     : {model}")
    print(f"  udid      : {udid}")
    print(f"  pairing   : {pairing}")
    print(f"  transport : {transport}")
    print(f"  tunnel    : {tunnel}")
    if addrs:
        print(f"  hostnames : {addrs}")
    if pairing == "paired" and tunnel != "connected":
        print("  >>> paired but tunnel down: install will fail.")
        print("  >>> Keep the iPhone connected over USB, or put it on")
        print("  >>> the same local Wi-Fi as this Mac, then retry.")
    print()
'
  exit 0
fi

# Resolve DEVELOPMENT_TEAM, preferring:
#   1. TEAM_ID or DEVELOPMENT_TEAM from the environment
#   2. DEVELOPMENT_TEAM persisted in project.pbxproj
#   3. The single keychain code-signing identity
TEAM_ID="${TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(grep -E "^[[:space:]]*DEVELOPMENT_TEAM = " "$PROJECT/project.pbxproj" \
    | head -n 1 \
    | sed -E 's/.*DEVELOPMENT_TEAM = ([A-Z0-9]{10}).*/\1/')"
fi
if [[ -z "$TEAM_ID" ]]; then
  TEAM_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -nE 's/.*\(([A-Z0-9]{10})\)".*/\1/p' | head -n 1)"
fi
if [[ -z "$TEAM_ID" ]]; then
  echo "error: could not resolve a signing team." >&2
  echo "       set Team via Xcode > project > Signing & Capabilities," >&2
  echo "       or export TEAM_ID=<10-char-team-id> before re-running." >&2
  exit 1
fi
echo "==> team: $TEAM_ID"

# Resolve the hardware UDID. Text-mode devicectl displays a CoreDevice
# identifier, while xcodebuild needs the hardware UDID, so parse JSON.
UDID="${1:-${IPHONE_UDID:-}}"
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun devicectl list devices --json-output - 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
for d in data.get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("deviceType") != "iPhone":
        continue
    if conn.get("pairingState") != "paired":
        continue
    udid = hw.get("udid")
    if udid:
        print(udid)
        break
')"
fi
if [[ -z "$UDID" ]]; then
  echo "error: no paired iPhone found and no UDID supplied." >&2
  echo "       connect and trust the iPhone, then run:" >&2
  echo "       scripts/install-iphone.sh --find-only" >&2
  exit 1
fi
echo "==> target device: $UDID"

# Both flags are needed on a first install: one permits provisioning changes,
# and the other permits Xcode to register a new device with the selected team.
echo "==> building $SCHEME ($CONFIG) for device..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "id=$UDID" \
  -configuration "$CONFIG" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  build

APP_PATH="$(xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination "id=$UDID" \
  -showBuildSettings build 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR / { print $2; exit }')/$SCHEME.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: built app not found at $APP_PATH" >&2
  exit 1
fi
echo "==> app bundle: $APP_PATH"

echo "==> installing on device..."
xcrun devicectl device install app --device "$UDID" "$APP_PATH"

if [[ -z "${NO_LAUNCH:-}" ]]; then
  echo "==> launching $BUNDLE_ID..."
  xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"
fi

echo "==> done."
