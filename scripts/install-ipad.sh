#!/usr/bin/env bash
# install-ipad.sh — build, install, and launch Tessera on a physical iPad.
#
# Usage:
#   scripts/install-ipad.sh                       # auto-pick the first connected iPad
#   scripts/install-ipad.sh <UDID>                # target a specific device
#   scripts/install-ipad.sh --release [<UDID>]    # optimized Release build
#   scripts/install-ipad.sh --debug [<UDID>]      # Debug build (default)
#   IPAD_UDID=<UDID> scripts/install-ipad.sh      # same, via env var
#   BUNDLE_ID=com.you.Tessera scripts/install-ipad.sh
#   NO_LAUNCH=1 scripts/install-ipad.sh           # build + install only
#   scripts/install-ipad.sh --find-only           # list paired iPads and exit (no build)
#   FIND_ONLY=1 scripts/install-ipad.sh           # same, via env var
#   scripts/install-ipad.sh --tailscale           # iPad away from home, reached over Tailscale
#   scripts/install-ipad.sh --tailscale=<peer|ip> # ... naming the Tailscale peer explicitly
#     (one-time setup, on the same network as the iPad:
#        scripts/ipad-tailscale-bridge.sh capture)
#   SKIP_KEYCHAIN_UNLOCK=1 scripts/install-ipad.sh  # never touch the keychain
#   KEYCHAIN=<path> scripts/install-ipad.sh        # override the login keychain
#
# Prereqs:
#   * Xcode 15+ (for `xcrun devicectl`).
#   * An Apple ID that belongs to the signing team is added in Xcode >
#     Settings > Accounts. `-allowProvisioningUpdates` needs it to talk to
#     the Apple Developer portal; the script then auto-registers the device
#     and generates the profile on first build (no manual Xcode step).
#   * iPad has Developer Mode enabled and the dev profile trusted.
#   * iPad is reachable via USB or paired Wi-Fi -- or, with --tailscale, over
#     Tailscale from anywhere (see scripts/ipad-tailscale-bridge.sh; the iPad
#     must be unlocked and awake the first time the bridge pairs).
#   * The login keychain must be UNLOCKED so codesign can reach the
#     signing key. Over SSH it usually is not; the script detects that
#     and prompts (see the keychain block below).

set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)/Tessera.xcodeproj"
SCHEME="Tessera"
CONFIG="Debug"
BUNDLE_ID="${BUNDLE_ID:-com.bambouville.TesseraApp}"

FIND_ONLY="${FIND_ONLY:-}"
USE_TAILSCALE="${USE_TAILSCALE:-}"
TAILSCALE_PEER="${TAILSCALE_PEER:-}"
DEVICE_UDID=""
CONFIG_FLAG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tailscale)
      USE_TAILSCALE=1
      ;;
    --tailscale=*)
      USE_TAILSCALE=1
      TAILSCALE_PEER="${1#*=}"
      ;;
    --release)
      if [[ -n "$CONFIG_FLAG" && "$CONFIG_FLAG" != "Release" ]]; then
        echo "error: --release and --debug cannot be used together." >&2
        exit 2
      fi
      CONFIG="Release"
      CONFIG_FLAG="Release"
      ;;
    --debug)
      if [[ -n "$CONFIG_FLAG" && "$CONFIG_FLAG" != "Debug" ]]; then
        echo "error: --release and --debug cannot be used together." >&2
        exit 2
      fi
      CONFIG="Debug"
      CONFIG_FLAG="Debug"
      ;;
    --find-only)
      FIND_ONLY=1
      ;;
    --*)
      echo "error: unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$DEVICE_UDID" ]]; then
        echo "error: only one device UDID may be supplied." >&2
        exit 2
      fi
      DEVICE_UDID="$1"
      ;;
  esac
  shift
done

# --find-only path: enumerate iPads with enough detail to tell whether
# the device is reachable over USB, local Wi-Fi, or a Tailscale/WAN link.
# CoreDevice discovers devices over Bonjour, which Tailscale does not carry,
# so an iPad that is away shows up here as paired-but-unavailable even though
# it is perfectly reachable; --tailscale bridges that discovery gap (see
# scripts/ipad-tailscale-bridge.sh). This mode is the cheap way to confirm
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
    if hw.get("reality") == "simulated":
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
        print("  >>> CoreDevice discovers over Bonjour, which does not")
        print("  >>> traverse Tailscale/VPN routes. Either put the iPad on")
        print("  >>> the same Wi-Fi as this host, or re-run the install")
        print("  >>> with --tailscale to bridge discovery over the tailnet.")
    print()
'
  exit 0
fi

# Unlock the login keychain if it is locked.
#
# An SSH session (e.g. Tessera on the iPad -> this Mac) lands in the launchd
# "Background" session, not "Aqua" -- check with `launchctl managername`.
# securityd cannot draw an unlock or "allow access?" prompt there, so a locked
# login keychain does not fail loudly. It fails a full device build later,
# inside codesign, as the near-unsearchable:
#
#     <app>: errSecInternalComponent
#
# The trap is that every step *before* signing still looks healthy:
# `security find-identity -v -p codesigning` cheerfully lists the identities,
# because enumerating certificates only reads public data. Only the
# private-key fetch needs the keychain open. Likewise -allowProvisioningUpdates
# reads its Apple ID token from the same locked keychain. So probe it here,
# before spending a minute building something that cannot be signed.
#
# `security show-keychain-info` is the probe: rc 0 = unlocked, rc 36
# ("User interaction is not allowed") = locked.
KEYCHAIN="${KEYCHAIN:-$(security default-keychain -d user 2>/dev/null \
  | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//')}"
if [[ -z "$KEYCHAIN" ]]; then
  KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
fi

if [[ -n "${SKIP_KEYCHAIN_UNLOCK:-}" ]]; then
  echo "==> keychain: check skipped (SKIP_KEYCHAIN_UNLOCK set)"
elif security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
  echo "==> keychain: unlocked ($KEYCHAIN)"
else
  echo "==> keychain: LOCKED ($KEYCHAIN)"
  echo "    codesign would fail with errSecInternalComponent after the build."
  # security reads the passphrase from the controlling terminal, not stdin,
  # so /dev/tty -- not `[[ -t 0 ]]` -- is the correct gate. This matters when
  # the script is run under a pipe or a harness that redirects stdin.
  # Order matters: 2>/dev/null must precede </dev/tty, because redirections
  # apply left to right and a failing input redirect aborts the command before
  # a later 2>/dev/null can take effect -- leaking a raw "Device not
  # configured" line above the clean message below.
  if ! : 2>/dev/null < /dev/tty; then
    echo "error: no terminal available to prompt for the keychain password." >&2
    echo "       unlock it first, then re-run:" >&2
    echo "         security unlock-keychain \"$KEYCHAIN\"" >&2
    exit 1
  fi
  echo "==> unlocking; password prompt follows (not echoed, not stored)..."
  if ! security unlock-keychain "$KEYCHAIN" < /dev/tty; then
    echo "error: could not unlock $KEYCHAIN." >&2
    exit 1
  fi
  # Re-probe rather than trusting the exit status.
  if ! security show-keychain-info "$KEYCHAIN" >/dev/null 2>&1; then
    echo "error: $KEYCHAIN still reports locked after unlocking." >&2
    exit 1
  fi
  echo "==> keychain unlocked."
  # Residual case: if codesign still returns errSecInternalComponent now, the
  # signing key's ACL partition list excludes the calling tool. Widen it once:
  #   security set-key-partition-list -S apple-tool:,apple:,codesign: \
  #     -s -k <password> "$KEYCHAIN"
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

# 0. Optional Tailscale bridge.
#
# CoreDevice only talks to devices it discovered over Bonjour, and Tailscale
# carries no multicast, so an iPad that is away reads as paired-but-unavailable
# even though its pairing port is perfectly reachable. The bridge publishes a
# loopback-only advert plus a local relay so CoreDevice dials the device over
# the tailnet; scripts/ipad-tailscale-bridge.sh explains why the advert has to
# be loopback-scoped (Network.framework pins Bonjour endpoints to the interface
# the advert arrived on).
#
# The EXIT trap tears the bridge down on every path, including failure, so no
# mDNS record or relay process is left behind.
BRIDGE="$(cd "$(dirname "$0")" && pwd)/ipad-tailscale-bridge.sh"
BRIDGE_UDID=""
bridge_down_on_exit() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  "$BRIDGE" down >/dev/null 2>&1 || true
  exit "$status"
}
if [[ -n "$USE_TAILSCALE" ]]; then
  [[ -x "$BRIDGE" ]] || { echo "error: $BRIDGE is missing or not executable." >&2; exit 1; }
  trap bridge_down_on_exit EXIT
  # No `devicectl manage pair` here: the bridge replays the device's captured
  # advert identity, so CoreDevice recognises the peer, does PairVerify against
  # the pairing it already has, and raises the tunnel on its own.
  if ! "$BRIDGE" up "$TAILSCALE_PEER"; then
    echo "error: could not bring the iPad up over Tailscale." >&2
    echo "       First time? Run this ONCE while the iPad is on the same" >&2
    echo "       network as this Mac, then --tailscale works from anywhere:" >&2
    echo "         $BRIDGE capture" >&2
    exit 1
  fi
  BRIDGE_UDID="$(cat "${TMPDIR:-/tmp}/tessera-ipad-bridge/udid.txt" 2>/dev/null || true)"
fi

# 1. Resolve the iPad UDID.
#
# Tricky: `xcrun devicectl list devices` (text mode) prints the *CoreDevice*
# identifier (a UUID), but xcodebuild needs the hardware UDID
# (00008xxx-xxxxxxxxxxxxxxxx). devicectl accepts both forms, so we always
# resolve to the hardware UDID and use it for both tools.
#
# Newer CoreDevice (installed by a newer Xcode's first launch) also lists
# simulators as paired devices (reality "simulated", transport "sameMachine").
# Without the filter below, an iPad simulator that sorts first is picked, the
# build goes to Debug-iphonesimulator, and the install fails with
# "The capability “Install Application” is not supported by this device."
UDID="${DEVICE_UDID:-${IPAD_UDID:-}}"
if [[ -z "$UDID" && -n "$BRIDGE_UDID" ]]; then
  # The bridge already waited for the tunnel and recorded which iPad came up;
  # prefer that over the generic scan below, which would happily pick a
  # different paired iPad.
  UDID="$BRIDGE_UDID"
  echo "==> tailscale: bridged iPad reports UDID $UDID"
fi
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
    if hw.get("reality") == "simulated":
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
script_completed=1
