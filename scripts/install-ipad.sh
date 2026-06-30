#!/usr/bin/env bash
# install-ipad.sh — build, install, and launch Tessera on a physical iPad.
#
# Usage:
#   scripts/install-ipad.sh                       # auto-pick the first connected iPad
#   scripts/install-ipad.sh <UDID>                # target a specific device
#   IPAD_UDID=<UDID> scripts/install-ipad.sh      # same, via env var
#   BUNDLE_ID=com.you.Tessera scripts/install-ipad.sh
#   NO_LAUNCH=1 scripts/install-ipad.sh           # build + install only
#   scripts/install-ipad.sh --find-only           # list paired iPads and exit (no build)
#   FIND_ONLY=1 scripts/install-ipad.sh           # same, via env var
#
# Prereqs:
#   * Xcode 15+ (for `xcrun devicectl`).
#   * An Apple ID that belongs to the signing team is added in Xcode >
#     Settings > Accounts. `-allowProvisioningUpdates` needs it to talk to
#     the Apple Developer portal; the script then auto-registers the device
#     and generates the profile on first build (no manual Xcode step).
#   * iPad has Developer Mode enabled and the dev profile trusted.
#   * iPad is reachable via USB or paired Wi-Fi.

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

# --find-only path: enumerate iPads with enough detail to tell whether
# the device is reachable over USB, local Wi-Fi, or a Tailscale/WAN link.
# devicectl normally uses Bonjour/AWDL for wireless pairing, neither of
# which traverses Tailscale; this mode is the cheap way to confirm
# *before* spending a minute on xcodebuild.
if [[ -n "$FIND_ONLY" ]]; then
  echo "==> scanning for iPads via xcrun devicectl..."
  xcrun devicectl list devices --json-output - 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
devices = data.get("result", {}).get("devices", [])
ipads = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("deviceType") != "iPad":
        continue
    ipads.append(d)
if not ipads:
    print("  (no iPads visible to devicectl)")
    sys.exit(0)
for d in ipads:
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
        print("  >>> devicectl uses Bonjour/AWDL on the local link; it")
        print("  >>> does not traverse Tailscale/VPN routes. Get the")
        print("  >>> iPad onto the same Wi-Fi as this host, then retry.")
    print()
'
  exit 0
fi

# Resolve DEVELOPMENT_TEAM, preferring (in order):
#   1. env var (TEAM_ID or DEVELOPMENT_TEAM)
#   2. DEVELOPMENT_TEAM persisted in project.pbxproj (set via Xcode's
#      Signing & Capabilities tab)
#   3. The single keychain codesigning identity (last-resort guess)
#
# Picking the project value over the keychain guess matters: a stale
# keychain cert may name a different team than the one Xcode is
# actually signed into, and overriding with the cert-team breaks the
# build with "No Account for Team …".
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

# 1. Resolve the iPad UDID.
#
# Tricky: `xcrun devicectl list devices` (text mode) prints the *CoreDevice*
# identifier (a UUID), but xcodebuild needs the hardware UDID
# (00008xxx-xxxxxxxxxxxxxxxx). devicectl accepts both forms, so we always
# resolve to the hardware UDID and use it for both tools.
UDID="${1:-${IPAD_UDID:-}}"
if [[ -z "$UDID" ]]; then
  UDID="$(xcrun devicectl list devices --json-output - 2>/dev/null \
    | python3 -c '
import json, sys
data = json.load(sys.stdin)
for d in data.get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("deviceType") != "iPad":
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
  echo "error: no paired iPad found and no UDID supplied." >&2
  echo "       run: xcrun devicectl list devices" >&2
  echo "       or pass the hardware UDID (00008xxx-...) as the first arg." >&2
  exit 1
fi
echo "==> target device: $UDID"

# 2. Build for the device.
#
# Two provisioning flags are required, not one:
#   -allowProvisioningUpdates           lets xcodebuild create/refresh
#                                       profiles, app IDs, and certs.
#   -allowProvisioningDeviceRegistration lets it register a NEW device on
#                                       the portal. This flag only takes
#                                       effect when -allowProvisioningUpdates
#                                       is also passed.
# The first flag alone will NOT register an unknown device; it fails with
# "Device '…' isn't registered in your developer account" and then "No
# profiles for '<bundle id>' were found" because the profile can't include
# an unregistered device. This bites whenever the signing TEAM changes
# (e.g. the App Store switch to the paid org team in cf95f39): the iPad was
# registered under the old team but not the new one, so it must be
# re-registered on first build under the new team.
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

# 3. Locate the freshly built .app.
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

# 4. Install.
echo "==> installing on device..."
xcrun devicectl device install app --device "$UDID" "$APP_PATH"

# 5. Launch (unless suppressed).
if [[ -z "${NO_LAUNCH:-}" ]]; then
  echo "==> launching $BUNDLE_ID..."
  xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"
fi

echo "==> done."
