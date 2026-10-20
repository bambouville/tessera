#!/usr/bin/env bash
# install-android.sh — build, install, and launch Tessera on a physical Android device.
#
# Usage:
#   scripts/install-android.sh                         # auto-pick the first authorized phone
#   scripts/install-android.sh <SERIAL>                # target a specific adb serial
#   ANDROID_SERIAL=<SERIAL> scripts/install-android.sh # same, via environment
#   scripts/install-android.sh --find-only             # list physical devices and exit
#   FIND_ONLY=1 scripts/install-android.sh              # same, via environment
#   scripts/install-android.sh --no-build              # install the existing debug APK
#   NO_BUILD=1 scripts/install-android.sh               # same, via environment
#   NO_LAUNCH=1 scripts/install-android.sh              # build + install only
#
# Wireless (no USB cable):
#   scripts/install-android.sh --go-wireless             # switch the USB device over, print its addresses
#   scripts/install-android.sh --go-wireless tailscale   # ...preferring its tailnet address
#   scripts/install-android.sh --go-wireless HOST        # ...or an address / MagicDNS name you name
#   scripts/install-android.sh --wireless                # thereafter: reconnect and install
#   scripts/install-android.sh --wireless HOST[:PORT]    # same, naming the endpoint
#   scripts/install-android.sh --pair HOST:PORT CODE     # Android 11+ pairing, instead of a cable
#   TESSERA_ADB_ENDPOINT=HOST[:PORT] scripts/install-android.sh --wireless
#
# The last endpoint that worked is remembered in .git/tessera-adb-endpoint, so
# after the first --go-wireless a bare --wireless is enough. The port defaults
# to 5555. `adb tcpip` makes adbd listen on every interface, so one --go-wireless
# serves both the LAN and a Tailscale address; only what you connect to differs.
#
# Prerequisites:
#   * Developer options and USB debugging are enabled on the device.
#   * The unlocked device is connected over USB (or paired wireless adb), and
#     this Mac has been accepted in the device's "Allow USB debugging" prompt.
#   * The pinned Android/JDK/Swift toolchains from android/README.md are
#     installed. The script resolves this checkout's standard macOS locations.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_ROOT="$REPO_ROOT/android"
APK_PATH="${APK_PATH:-$ANDROID_ROOT/app/build/outputs/apk/debug/app-debug.apk}"
PACKAGE_ID="${PACKAGE_ID:-com.bambouville.tessera.debug}"
MAIN_ACTIVITY="${MAIN_ACTIVITY:-com.bambouville.tessera.MainActivity}"

FIND_ONLY="${FIND_ONLY:-}"
NO_BUILD="${NO_BUILD:-}"
DEVICE_SERIAL=""
WIRELESS=""
GO_WIRELESS=""
GO_WIRELESS_VIA=""
PAIR_ENDPOINT=""
PAIR_CODE=""
ADB_ENDPOINT="${TESSERA_ADB_ENDPOINT:-}"
ENDPOINT_MEMO=""

usage() {
  sed -n '2,34s/^# \{0,1\}//p' "$0"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

resolve_sdk_root() {
  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    printf '%s\n' "$ANDROID_SDK_ROOT"
    return
  fi
  if [[ -n "${ANDROID_HOME:-}" ]]; then
    printf '%s\n' "$ANDROID_HOME"
    return
  fi
  if [[ -f "$ANDROID_ROOT/local.properties" ]]; then
    local configured_root
    configured_root="$(sed -n 's/^sdk\.dir=//p' "$ANDROID_ROOT/local.properties" | head -n 1)"
    if [[ -n "$configured_root" ]]; then
      printf '%s\n' "$configured_root"
      return
    fi
  fi

  if [[ "$(uname -s)" == "Darwin" ]]; then
    local candidate
    for candidate in \
      "$HOME/Library/Android/sdk" \
      "/opt/homebrew/share/android-commandlinetools" \
      "/usr/local/share/android-commandlinetools"; do
      if [[ -d "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return
      fi
    done
  fi

  fail "Android SDK not found; set ANDROID_SDK_ROOT or add sdk.dir to android/local.properties"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --find-only)
      FIND_ONLY=1
      ;;
    --no-build)
      NO_BUILD=1
      ;;
    --wireless)
      WIRELESS=1
      # An optional HOST:PORT may follow; anything else is the next flag.
      # A bare host is fine; the default adb port is supplied.
      if [[ $# -ge 2 && "$2" != --* ]]; then
        ADB_ENDPOINT="$2"
        shift
      fi
      ;;
    --go-wireless)
      GO_WIRELESS=1
      # Optional: lan, tailscale, or an explicit address/hostname.
      if [[ $# -ge 2 && "$2" != --* ]]; then
        GO_WIRELESS_VIA="$2"
        shift
      fi
      ;;
    --pair)
      [[ $# -ge 3 ]] || { echo "error: --pair needs HOST:PORT and a pairing code" >&2; exit 2; }
      PAIR_ENDPOINT="$2"
      PAIR_CODE="$3"
      WIRELESS=1
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -n "$DEVICE_SERIAL" ]]; then
        echo "error: only one device serial may be supplied." >&2
        exit 2
      fi
      DEVICE_SERIAL="$1"
      ;;
  esac
  shift
done

ANDROID_SDK_ROOT="$(resolve_sdk_root)"
export ANDROID_SDK_ROOT

resolve_adb() {
  if [[ -n "${ADB:-}" ]]; then
    [[ -x "$ADB" ]] || fail "ADB is not executable: $ADB"
    printf '%s\n' "$ADB"
    return
  fi

  local command_adb
  command_adb="$(command -v adb 2>/dev/null || true)"
  if [[ -n "$command_adb" && -x "$command_adb" ]]; then
    printf '%s\n' "$command_adb"
    return
  fi

  local sdk_root="$ANDROID_SDK_ROOT"
  [[ -x "$sdk_root/platform-tools/adb" ]] || fail \
    "adb not found; install Android SDK Platform-Tools or set ADB=/path/to/adb"
  printf '%s\n' "$sdk_root/platform-tools/adb"
}

ADB_BIN="$(resolve_adb)"

# Ask adb to initialize before discovery so any startup failure is reported at
# the device boundary rather than after a potentially expensive native build.
"$ADB_BIN" start-server >/dev/null

print_devices() {
  local found=0
  local serial state
  echo "==> physical Android devices visible to adb:"
  while IFS=$' \t' read -r serial state _; do
    [[ -n "$serial" ]] || continue
    [[ "$serial" == "List" ]] && continue
    [[ "$serial" == emulator-* ]] && continue
    found=1
    printf '  serial : %s\n' "$serial"
    printf '  state  : %s\n' "${state:-unknown}"
    if [[ "${state:-}" == "device" ]]; then
      local manufacturer model android_version api_level abi_list
      manufacturer="$("$ADB_BIN" -s "$serial" shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r')"
      model="$("$ADB_BIN" -s "$serial" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
      android_version="$("$ADB_BIN" -s "$serial" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
      api_level="$("$ADB_BIN" -s "$serial" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
      abi_list="$("$ADB_BIN" -s "$serial" shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r')"
      printf '  model  : %s %s\n' "$manufacturer" "$model"
      printf '  Android: %s (API %s)\n' "$android_version" "$api_level"
      printf '  ABIs   : %s\n' "$abi_list"
    elif [[ "${state:-}" == "unauthorized" ]]; then
      echo "  >>> unlock the phone and accept the Allow USB debugging prompt."
    else
      echo "  >>> reconnect the phone and confirm USB debugging is enabled."
    fi
    echo
  done < <("$ADB_BIN" devices -l)

  if [[ $found -eq 0 ]]; then
    echo "  (no physical devices visible)"
  fi
}

if [[ -n "$FIND_ONLY" ]]; then
  print_devices
  exit 0
fi

ENDPOINT_MEMO="$REPO_ROOT/.git/tessera-adb-endpoint"

remember_endpoint() {
  # Inside .git so it is durable per checkout and never tracked or published.
  [[ -d "$REPO_ROOT/.git" ]] || return 0
  printf '%s\n' "$1" >"$ENDPOINT_MEMO" 2>/dev/null || true
}

recall_endpoint() {
  [[ -f "$ENDPOINT_MEMO" ]] || return 1
  local remembered
  remembered="$(head -n 1 "$ENDPOINT_MEMO" | tr -d '\r')"
  [[ -n "$remembered" ]] || return 1
  printf '%s\n' "$remembered"
}

# Accepts a bare host (Tailscale MagicDNS names included) and supplies the
# default adb port, so `--wireless phone.tailnet.ts.net` is enough.
normalize_endpoint() {
  local value="$1"
  [[ "$value" == *:* ]] || value="$value:5555"
  printf '%s\n' "$value"
}

validate_endpoint() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+:[0-9]{1,5}$ ]] || fail \
    "expected HOST or HOST:PORT, got: $1"
}

connect_endpoint() {
  local endpoint
  endpoint="$(normalize_endpoint "$1")"
  validate_endpoint "$endpoint"
  # Progress goes to stderr: stdout carries the resolved endpoint alone, so the
  # caller can capture it without swallowing the messages meant for the user.
  echo "==> connecting to $endpoint..." >&2
  # A connection entry made before adbd restarted survives as "already
  # connected" while the device itself sits in `offline` — which is how this
  # used to report success and then fail the readiness check one line later.
  # Drop any stale entry, and treat only a device that reaches `device` state
  # as connected.
  "$ADB_BIN" disconnect "$endpoint" >/dev/null 2>&1 || true
  local attempt output state
  for attempt in $(seq 1 "${TESSERA_ADB_CONNECT_ATTEMPTS:-20}"); do
    output="$("$ADB_BIN" connect "$endpoint" 2>&1 || true)"
    case "$output" in
      *"connected to"*)
        state="$("$ADB_BIN" -s "$endpoint" get-state 2>/dev/null | tr -d '\r')"
        if [[ "$state" == "device" ]]; then
          remember_endpoint "$endpoint"
          printf '%s\n' "$endpoint"
          return 0
        fi
        # `offline` here means adbd is still coming back up after `tcpip`.
        "$ADB_BIN" disconnect "$endpoint" >/dev/null 2>&1 || true
        ;;
    esac
    sleep 1
  done
  echo "$output" >&2
  echo "error: $endpoint never reached adb 'device' state" >&2
  return 1
}

connect_endpoint_or_fail() {
  local resolved
  resolved="$(connect_endpoint "$1")" || fail \
    "could not reach $1 over adb.
       If this is the first wireless use on Android 11+, pair once:
         scripts/install-android.sh --pair HOST:PORT CODE
       Over Tailscale, check the phone is up on the tailnet:
         tailscale status | grep <device>"
  printf '%s\n' "$resolved"
}

# A bounded TCP probe. `adb connect` to an unroutable address blocks for its own
# timeout, which made scanning several candidates take minutes; a phone that is
# actually listening answers this immediately.
port_is_open() {
  local host="${1%:*}" port="${1##*:}" pid waited=0
  ( exec 3<>"/dev/tcp/$host/$port" ) >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && (( waited < 20 )); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  wait "$pid" 2>/dev/null
}

# Try each candidate briefly and keep the first that actually reaches `device`.
# A phone can report addresses that do not route — Android's 464XLAT address,
# or a tailnet address left over from a network it is no longer on — and the
# only reliable test is connecting.
first_reachable_endpoint() {
  local endpoint probe resolved attempt
  for endpoint in "$@"; do
    probe="$(normalize_endpoint "$endpoint")"
    # adbd needs a moment to bind after `tcpip`, so give each candidate a few
    # seconds before writing it off.
    for attempt in 1 2 3 4 5; do
      port_is_open "$probe" && break
      [[ "$attempt" == 5 ]] && probe=""
      sleep 1
    done
    if [[ -z "$probe" ]]; then
      echo "==> $endpoint is not listening on adb; trying the next address" >&2
      continue
    fi
    if resolved="$(TESSERA_ADB_CONNECT_ATTEMPTS=6 connect_endpoint "$endpoint" 2>/dev/null)"; then
      printf '%s\n' "$resolved"
      return 0
    fi
    echo "==> $endpoint did not come up; trying the next address" >&2
  done
  return 1
}

# Every inet address the device holds, as "kind address" lines. Tailscale hands
# out 100.64.0.0/10 (CGNAT), which is what makes a phone reachable from another
# network entirely — the reason to support more than wlan0 here.
#
# Dropped: loopback, 169.254/16 link-local, and 192.0.0.0/24, which on Android
# is the 464XLAT translation address. All three get reported; none is reachable.
device_addresses() {
  local serial="$1"
  "$ADB_BIN" -s "$serial" shell ip -o -f inet addr show 2>/dev/null \
    | awk '{ iface = $2; split($4, a, "/"); addr = a[1];
             if (addr == "" || addr ~ /^127\./) next
             if (addr ~ /^192\.0\.0\./ || addr ~ /^169\.254\./) next
             if (addr ~ /^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./)
               print "tailscale " addr;
             else print "lan " addr }' \
    | tr -d '\r'
}

if [[ -n "$PAIR_ENDPOINT" ]]; then
  validate_endpoint "$PAIR_ENDPOINT"
  [[ "$PAIR_CODE" =~ ^[0-9]{6}$ ]] || fail "pairing code must be six digits"
  echo "==> pairing with $PAIR_ENDPOINT..."
  # The pairing port is shown on the phone and differs from the connect port,
  # so pairing never establishes the connection by itself.
  "$ADB_BIN" pair "$PAIR_ENDPOINT" "$PAIR_CODE" || fail \
    "pairing failed; re-open Wireless debugging > Pair device with pairing code for a fresh code"
  echo "==> paired. Use the 'IP address & Port' shown on the Wireless debugging"
  echo "    screen (not the pairing port) for --wireless."
fi

if [[ -n "$GO_WIRELESS" ]]; then
  usb_serial="${DEVICE_SERIAL:-${ANDROID_SERIAL:-}}"
  if [[ -z "$usb_serial" ]]; then
    while IFS=$' \t' read -r candidate state _; do
      [[ -n "$candidate" ]] || continue
      [[ "$candidate" == "List" ]] && continue
      [[ "$candidate" == emulator-* ]] && continue
      [[ "$candidate" == *:* ]] && continue
      if [[ "${state:-}" == "device" ]]; then
        usb_serial="$candidate"
        break
      fi
    done < <("$ADB_BIN" devices -l)
  fi
  [[ -n "$usb_serial" ]] || fail \
    "--go-wireless needs the device connected over USB once; none is visible"

  addresses="$(device_addresses "$usb_serial")"
  [[ -n "$addresses" ]] || fail \
    "could not read any address from the device; is it on Wi-Fi or a tailnet?"
  echo "==> addresses reported by $usb_serial:"
  printf '%s\n' "$addresses" | while read -r kind addr; do
    printf '  %-10s %s\n' "$kind" "$addr"
  done

  candidates=""
  case "$GO_WIRELESS_VIA" in
    "")
      # LAN first — the lower-latency path when both ends share a network —
      # then the tailnet, which is the only option when they do not.
      candidates="$(printf '%s\n' "$addresses" | awk '$1 == "lan" { print $2 }')
$(printf '%s\n' "$addresses" | awk '$1 == "tailscale" { print $2 }')"
      ;;
    lan|tailscale)
      candidates="$(printf '%s\n' "$addresses" \
        | awk -v want="$GO_WIRELESS_VIA" '$1 == want { print $2 }')"
      [[ -n "${candidates//[[:space:]]/}" ]] || fail \
        "the device reports no $GO_WIRELESS_VIA address"
      ;;
    *)
      # An explicit address or hostname, which is how a MagicDNS name gets used.
      candidates="$GO_WIRELESS_VIA"
      ;;
  esac

  echo "==> restarting adbd on port 5555 for $usb_serial..."
  # adbd listens on every interface, so this one restart serves the LAN and the
  # tailnet alike; only the address you connect to differs.
  "$ADB_BIN" -s "$usb_serial" tcpip 5555 >/dev/null

  candidate_list=""
  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    candidate_list="$candidate_list $candidate"
  done <<<"$candidates"
  # shellcheck disable=SC2086
  DEVICE_SERIAL="$(first_reachable_endpoint $candidate_list)" || fail \
    "none of these addresses reached adb:$candidate_list"
  ADB_ENDPOINT="$DEVICE_SERIAL"
  echo "==> connected on $DEVICE_SERIAL — you can unplug the cable now."
elif [[ -n "$WIRELESS" ]]; then
  if [[ -z "$ADB_ENDPOINT" ]]; then
    ADB_ENDPOINT="$(recall_endpoint || true)"
    [[ -n "$ADB_ENDPOINT" ]] || fail \
      "no wireless endpoint known; pass --wireless HOST:PORT, or run --go-wireless once over USB"
    echo "==> using remembered endpoint $ADB_ENDPOINT"
  fi
  DEVICE_SERIAL="$(connect_endpoint_or_fail "$ADB_ENDPOINT")"
fi

device_state() {
  local wanted="$1"
  local serial state
  while IFS=$' \t' read -r serial state _; do
    if [[ "$serial" == "$wanted" ]]; then
      printf '%s\n' "${state:-unknown}"
      return
    fi
  done < <("$ADB_BIN" devices -l)
}

SERIAL="${DEVICE_SERIAL:-${ANDROID_SERIAL:-}}"
if [[ -z "$SERIAL" ]]; then
  while IFS=$' \t' read -r candidate state _; do
    [[ -n "$candidate" ]] || continue
    [[ "$candidate" == "List" ]] && continue
    [[ "$candidate" == emulator-* ]] && continue
    if [[ "${state:-}" == "device" ]]; then
      SERIAL="$candidate"
      break
    fi
  done < <("$ADB_BIN" devices -l)
fi

# adb forgets a wireless device once its connection drops (the phone restarted
# or left the network) and never reconnects it on its own, so a bare run after
# that saw no device at all. Try the remembered endpoint before giving up.
REMEMBERED_ENDPOINT=""
if [[ -z "$SERIAL" ]] && REMEMBERED_ENDPOINT="$(recall_endpoint)"; then
  if port_is_open "$(normalize_endpoint "$REMEMBERED_ENDPOINT")"; then
    echo "==> no device attached; reconnecting the remembered endpoint $REMEMBERED_ENDPOINT"
    SERIAL="$(TESSERA_ADB_CONNECT_ATTEMPTS=6 connect_endpoint "$REMEMBERED_ENDPOINT")" || SERIAL=""
  fi
fi

if [[ -z "$SERIAL" ]]; then
  print_devices >&2
  if [[ -n "$REMEMBERED_ENDPOINT" ]]; then
    fail "no device attached, and the remembered endpoint $REMEMBERED_ENDPOINT is not answering adb.
       A phone restart turns off adb over TCP: connect USB once and run
         scripts/install-android.sh --go-wireless
       (or pair with --pair HOST:PORT CODE). Over Tailscale, check the phone is
       up: tailscale status | grep <device>"
  fi
  fail "no authorized physical Android device found; run scripts/install-android.sh --find-only"
fi

STATE="$(device_state "$SERIAL")"
if [[ -z "$STATE" ]]; then
  fail "Android device $SERIAL is not visible to adb"
fi
if [[ "$STATE" == "unauthorized" ]]; then
  fail "Android device $SERIAL is unauthorized; unlock it and accept Allow USB debugging"
fi
if [[ "$STATE" != "device" ]]; then
  fail "Android device $SERIAL is not ready (adb state: $STATE)"
fi
if [[ "$SERIAL" == emulator-* ]] || \
   [[ "$("$ADB_BIN" -s "$SERIAL" shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r')" == "1" ]]; then
  fail "$SERIAL is an emulator; this installer targets physical devices only"
fi

MODEL="$("$ADB_BIN" -s "$SERIAL" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
API_LEVEL="$("$ADB_BIN" -s "$SERIAL" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
ABI_LIST="$("$ADB_BIN" -s "$SERIAL" shell getprop ro.product.cpu.abilist 2>/dev/null | tr -d '\r')"
if [[ ! "$API_LEVEL" =~ ^[0-9]+$ ]] || (( API_LEVEL < 33 )); then
  fail "$MODEL reports API ${API_LEVEL:-unknown}; Tessera requires Android 13 / API 33 or newer"
fi
if [[ ",$ABI_LIST," != *",arm64-v8a,"* ]]; then
  fail "$MODEL does not report arm64-v8a support (ABIs: ${ABI_LIST:-unknown})"
fi
echo "==> target device: $MODEL ($SERIAL, API $API_LEVEL)"

resolve_java_home() {
  local candidate=""
  local candidates=()
  if [[ -n "${JAVA_HOME:-}" ]]; then
    candidates+=("$JAVA_HOME")
  fi
  if [[ "$(uname -s)" == "Darwin" ]]; then
    candidate="$(/usr/libexec/java_home -v 21 2>/dev/null || true)"
    [[ -n "$candidate" ]] && candidates+=("$candidate")
    candidates+=(
      "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home"
      "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    )
  fi

  local major
  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate/bin/java" ]] || continue
    major="$("$candidate/bin/java" -version 2>&1 | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')"
    if [[ "$major" == "21" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  fail "JDK 21 not found; install openjdk@21 or set JAVA_HOME"
}

resolve_swift() {
  local candidate=""
  local candidates=()
  if [[ -n "${SWIFT_ANDROID_SWIFT:-}" ]]; then
    candidates+=("$SWIFT_ANDROID_SWIFT")
  fi
  candidates+=(
    "$HOME/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin/swift"
  )
  candidate="$(command -v swift 2>/dev/null || true)"
  [[ -n "$candidate" ]] && candidates+=("$candidate")

  local version
  for candidate in "${candidates[@]}"; do
    [[ -x "$candidate" ]] || continue
    version="$("$candidate" --version 2>/dev/null || true)"
    if [[ "$version" == *"Swift version 6.3.3"* ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  fail "Swift 6.3.3 not found; install the pinned toolchain or set SWIFT_ANDROID_SWIFT"
}

if [[ -z "$NO_BUILD" ]]; then
  RESOLVED_JAVA_HOME="$(resolve_java_home)"
  RESOLVED_SWIFT="$(resolve_swift)"
  echo "==> checking the Android build environment..."
  JAVA_HOME="$RESOLVED_JAVA_HOME" "$REPO_ROOT/scripts/android/check-environment.sh"
  echo "==> preparing native Mosh support..."
  MOSH_OPENSSL_ROOT="$(
    JAVA_HOME="$RESOLVED_JAVA_HOME" \
      "$REPO_ROOT/scripts/android/prepare-mosh-openssl.sh"
  )"
  echo "==> building Tessera (Debug)..."
  (
    cd "$ANDROID_ROOT"
    JAVA_HOME="$RESOLVED_JAVA_HOME" \
      SWIFT_ANDROID_SWIFT="$RESOLVED_SWIFT" \
      ./gradlew --no-daemon \
        -Ptessera.enableMoshNative=true \
        -Ptessera.moshOpenSslRoot="$MOSH_OPENSSL_ROOT" \
        :app:assembleDebug
  )
fi

[[ -f "$APK_PATH" ]] || fail \
  "debug APK not found at $APK_PATH; remove --no-build or set APK_PATH"
echo "==> APK: $APK_PATH"

echo "==> installing $PACKAGE_ID (existing app data is preserved)..."
INSTALL_OUTPUT=""
if ! INSTALL_OUTPUT="$("$ADB_BIN" -s "$SERIAL" install -r "$APK_PATH" 2>&1)"; then
  echo "$INSTALL_OUTPUT" >&2
  if [[ "$INSTALL_OUTPUT" == *"INSTALL_FAILED_UPDATE_INCOMPATIBLE"* ]]; then
    echo "       The installed copy has a different signing key." >&2
    echo "       Uninstalling would erase Tessera's Android app data; this script will not do that." >&2
  fi
  exit 1
fi
echo "$INSTALL_OUTPUT"

if [[ -z "${NO_LAUNCH:-}" ]]; then
  echo "==> launching $PACKAGE_ID..."
  "$ADB_BIN" -s "$SERIAL" shell am start -n "$PACKAGE_ID/$MAIN_ACTIVITY"
fi

echo "==> done."
