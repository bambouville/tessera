#!/usr/bin/env bash
# Capture public-docs screenshots from the real app.
#
# Drives TesseraUITests/DocShotsProbe against the two disposable fixtures and
# takes Metal-aware simctl screenshots at the probe's TESSERA_VISUAL_EVENT
# marks — the same external-recorder pattern as visual-cases/*.sh, because
# SwiftTerm renders through CAMetalLayer and XCUIScreenshot sees a black
# surface.
#
# Authentication is key-based end to end: the probe generates an Ed25519 key
# through Tessera's own Keys UI, this script reads the resulting
# authorized_keys line out of the app's SwiftData store and installs it on both
# fixtures over the root control key. Nothing types a password — a host with no
# identity has no persisted credential, and the editor's transient password
# state does not survive the SwiftData writes this flow performs.
#
# Usage:
#   ./scripts/integration/capture-doc-screenshots.sh [RUN_DIR]
#
# Requires fixture.env (see README) plus jq and sqlite3.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"
load_fixture_config
ensure_fixture_credentials
require_command jq
require_command sqlite3
require_command sips

RUN_DIR="${1:-$FIXTURE_OUT/docshots-$(date -u +%Y%m%dT%H%M%SZ)}"
SHOTS="$RUN_DIR/docshots"
BUNDLE_ID=com.bambouville.TesseraApp
PROJECT="$REPO_ROOT/Tessera.xcodeproj"
STABLE="$TESSERA_FIXTURE_STABLE_HOST"
CHAOS="$TESSERA_FIXTURE_CHAOS_HOST"
APP_PORT="$TESSERA_FIXTURE_APP_PORT"
mkdir -p "$SHOTS"

note "run dir  -> $RUN_DIR"
note "shots    -> $SHOTS"

# ── Simulator + build ─────────────────────────────────────────────
# ensure-test-simulator.sh pins one iOS runtime; when Xcode ships a newer one
# that pin fails, so fall back to the newest installed runtime rather than
# making every future release re-diagnose "Invalid runtime".
ensure_visual_simulator() {
  local udid_file="$FIXTURE_STATE/visual_simulator_udid"
  local name="Tessera Visual Integration Tests"
  local udid=''
  if [[ -f "$udid_file" ]]; then
    IFS= read -r udid <"$udid_file"
    xcrun simctl list devices -j \
      | jq -e --arg u "$udid" '[.devices[][] | select(.udid == $u and .isAvailable)] | length == 1' \
        >/dev/null || udid=''
  fi
  if [[ -z "$udid" ]]; then
    udid="$(xcrun simctl list devices -j \
      | jq -r --arg n "$name" '.devices[][] | select(.name == $n and .isAvailable) | .udid' \
      | sed -n '1p')"
  fi
  if [[ -z "$udid" ]]; then
    local runtime device
    runtime="$(xcrun simctl list runtimes -j \
      | jq -r '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")))] | last | .identifier')"
    device="$(xcrun simctl list devicetypes -j \
      | jq -r '[.devicetypes[] | select(.name | test("iPad Pro 13-inch"))] | last | .identifier')"
    [[ -n "$runtime" && -n "$device" ]] || die "no iPad simulator runtime/device type available"
    note "creating $name on $runtime"
    udid="$(xcrun simctl create "$name" "$device" "$runtime")"
  fi
  printf '%s\n' "$udid" >"$udid_file"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  printf '%s' "$udid"
}

UDID="$(ensure_visual_simulator)"
DERIVED_DATA="$FIXTURE_STATE/VisualDerivedData"
mkdir -p "$DERIVED_DATA"
note "simulator -> $UDID"

note "building for testing"
xcodebuild build-for-testing \
  -project "$PROJECT" -scheme Tessera -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED_DATA" \
  >"$RUN_DIR/build-for-testing.log" 2>&1 \
  || { tail -20 "$RUN_DIR/build-for-testing.log"; die "build failed"; }
APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Tessera.app"
[[ -d "$APP_PATH" ]] || die "build did not produce $APP_PATH"

# ── Helpers ───────────────────────────────────────────────────────
take_shot() {
  # simctl screenshots of a Metal surface can come back partially composited;
  # take three and keep the largest (most complete) frame.
  local output="$1" best='' best_size=0 candidate size attempt
  for attempt in 1 2 3; do
    candidate="$output.$attempt.png"
    xcrun simctl io "$UDID" screenshot "$candidate.raw.png" >/dev/null 2>&1
    sips -r 270 "$candidate.raw.png" --out "$candidate" >/dev/null
    rm "$candidate.raw.png"
    size="$(stat -f %z "$candidate")"
    if ((size > best_size)); then best="$candidate"; best_size="$size"; fi
    sleep 0.15
  done
  cp "$best" "$output"
  rm -f "$output".1.png "$output".2.png "$output".3.png
  note "captured $(basename "$output")"
}

wait_ev() {
  # The mosh flow needs several minutes per stage; the loop exits early when
  # the test process dies, so a long ceiling costs nothing.
  local log="$1" event="$2" pid="$3"
  for _ in {1..6000}; do
    if [[ -f "$log" ]] && grep -Fq "TESSERA_VISUAL_EVENT $event " "$log"; then
      return 0
    fi
    kill -0 "$pid" >/dev/null 2>&1 || { note "test process died waiting for $event"; return 1; }
    sleep 0.2
  done
  note "timeout waiting for $event"
  return 1
}

run_probe() {
  local method="$1" log="$2" result="$3"
  rm -rf "$result"
  TESSERA_VISUAL_CAPTURE=1 \
  xcodebuild test-without-building \
    -project "$PROJECT" -scheme Tessera -configuration Debug \
    -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$result" \
    -only-testing:"TesseraUITests/DocShotsProbe/$method" \
    >"$log" 2>&1
}

# Pre-seed the app's known-hosts store. Tessera's ~10s connect timeout keeps
# running while the trust-on-first-use sheet waits, and XCUITest's idle-wait
# makes the Accept tap land too late — so the sheet is captured separately
# rather than fought with here.
seed_known_hosts() {
  local out="$1" host entry keyline fingerprint first=1
  printf '{\n' >"$out"
  for host in "$STABLE" "$CHAOS"; do
    keyline="$(ssh-keyscan -p "$APP_PORT" -t ed25519 "$host" 2>/dev/null \
      | grep -v '^#' | head -1)"
    [[ -n "$keyline" ]] || die "ssh-keyscan found no ed25519 key on $host:$APP_PORT"
    entry="$(printf '%s' "$keyline" | cut -d' ' -f2-)"
    fingerprint="$(printf '%s\n' "$keyline" | ssh-keygen -lf - | awk '{print $2}')"
    [[ $first -eq 1 ]] || printf ',\n' >>"$out"
    first=0
    printf '  "%s:%s": {"fingerprint":"%s","firstSeen":"%s","keyString":"%s","lastSeen":"%s"}' \
      "$host" "$APP_PORT" "$fingerprint" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$entry" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$out"
  done
  printf '\n}\n' >>"$out"
}

# Read the authorized_keys line the app generated (same value its "copy public
# key" button emits) and install it on both fixtures. simctl pbpaste does not
# reliably return the simulator pasteboard, so read SwiftData directly.
install_app_key() {
  local line store
  store="$(find "$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Shared/AppGroup" \
    -path '*/Library/Application Support/default.store' 2>/dev/null | head -1)"
  [[ -n "$store" ]] || { note "SwiftData store not found"; return 1; }
  line="$(sqlite3 "$store" \
    "select ZAUTHORIZEDKEYSLINE from ZSTOREDKEY order by ZCREATEDAT desc limit 1;" \
    2>/dev/null | tr -d '\r' | head -1)"
  case "$line" in
    ssh-ed25519*|ecdsa-sha2-nistp256*) ;;
    *) note "no public key in the store: ${line:0:40}"; return 1 ;;
  esac
  note "installing app-generated key: ${line:0:32}..."
  local host
  for host in "$STABLE" "$CHAOS"; do
    control_ssh "$host" \
      "install -d -m 700 -o $TESSERA_FIXTURE_USER -g $TESSERA_FIXTURE_USER /home/$TESSERA_FIXTURE_USER/.ssh; \
       grep -qxF '$line' /home/$TESSERA_FIXTURE_USER/.ssh/authorized_keys 2>/dev/null \
         || printf '%s\n' '$line' >> /home/$TESSERA_FIXTURE_USER/.ssh/authorized_keys; \
       chown $TESSERA_FIXTURE_USER:$TESSERA_FIXTURE_USER /home/$TESSERA_FIXTURE_USER/.ssh/authorized_keys; \
       chmod 600 /home/$TESSERA_FIXTURE_USER/.ssh/authorized_keys" \
      >/dev/null || { note "key install failed on $host"; return 1; }
  done
  note "key installed on both fixtures"
}

find_tessera_session() {
  fixture_ssh "$STABLE" "tmux list-sessions -F '#{session_name}'" \
    | grep '^tessera-' | head -1
}

# Demo content for the terminal, pane, and files captures. projects/nebula is
# created by provision-fixtures.sh.
stage_tmux() {
  local sess="$1"
  fixture_ssh "$STABLE" \
    "tmux send-keys -t '$sess' 'cd ~/projects/nebula && clear && git log --oneline -6 && ls' Enter" || true
  sleep 1
  fixture_ssh "$STABLE" \
    "tmux split-window -h -t '$sess' -c /home/$TESSERA_FIXTURE_USER/projects/nebula htop" || true
  sleep 1
  fixture_ssh "$STABLE" \
    "tmux new-window -d -t '$sess' -n logs 'cd ~/projects/nebula && git --no-pager log --graph --decorate --oneline --color=always; exec bash'" || true
}

send_bell() {
  local sess="$1" win
  win="$(fixture_ssh "$STABLE" "tmux list-windows -t '$sess' -F '#{window_index} #{window_name}'" \
    | awk '$2 != "logs" {print $1; exit}')"
  [[ -n "$win" ]] || return 1
  fixture_ssh "$STABLE" "tmux send-keys -t '$sess:$win' 'printf \"\\a\"' Enter" || true
}

cleanup() {
  xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_DOCSHOT_STABLE >/dev/null 2>&1 || true
  xcrun simctl spawn "$UDID" launchctl unsetenv TESSERA_DOCSHOT_CHAOS >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── Fresh app state ───────────────────────────────────────────────
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP_PATH"
xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" tessera.pref.hasSeenWelcome -bool YES
xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" tessera.pref.sessionRestorePolicy -string never

APP_DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
mkdir -p "$APP_DATA/Library/Application Support"
seed_known_hosts "$APP_DATA/Library/Application Support/known_hosts.json"

# The in-simulator test runner reads env through the simulator's launchd, not
# xcodebuild's process environment.
xcrun simctl spawn "$UDID" launchctl setenv TESSERA_VISUAL_CAPTURE 1
xcrun simctl spawn "$UDID" launchctl setenv TESSERA_DOCSHOT_STABLE "$STABLE"
xcrun simctl spawn "$UDID" launchctl setenv TESSERA_DOCSHOT_CHAOS "$CHAOS"
xcrun simctl status_bar "$UDID" override \
  --time "9:41" --batteryLevel 100 --batteryState charged --wifiBars 3 \
  >/dev/null 2>&1 || true

fixture_ssh "$STABLE" "tmux kill-server" >/dev/null 2>&1 || true
fixture_ssh "$CHAOS" "tmux kill-server" >/dev/null 2>&1 || true

# ── Flow A: saturn over SSH ───────────────────────────────────────
LOG_A="$SHOTS/saturn.log"
: >"$LOG_A"
run_probe testDocShotsSaturnFlow "$LOG_A" "$SHOTS/saturn.xcresult" &
PID_A=$!

wait_ev "$LOG_A" keys-page "$PID_A" && take_shot "$SHOTS/keys-page.png"
wait_ev "$LOG_A" pubkey-copied "$PID_A" && install_app_key
wait_ev "$LOG_A" host-editor "$PID_A" && take_shot "$SHOTS/host-editor.png"
wait_ev "$LOG_A" forwarding-rule "$PID_A" && take_shot "$SHOTS/forwarding-rule.png"
if wait_ev "$LOG_A" connected "$PID_A"; then
  SESS="$(find_tessera_session)"
  note "staging tmux content in $SESS"
  stage_tmux "$SESS"
fi
wait_ev "$LOG_A" tmux-panes "$PID_A" && take_shot "$SHOTS/tmux-panes.png"
wait_ev "$LOG_A" bell-stage "$PID_A" && send_bell "${SESS:-}"
wait_ev "$LOG_A" tmux-bell "$PID_A" && take_shot "$SHOTS/tmux-bell.png"
wait_ev "$LOG_A" files-panel "$PID_A" && take_shot "$SHOTS/files-panel.png"
if wait_ev "$LOG_A" tunnels-stage "$PID_A"; then
  for _ in $(seq 1 12); do
    curl -s -m 2 "http://127.0.0.1:8080/" >/dev/null 2>&1 || true
    sleep 0.3
  done
fi
wait_ev "$LOG_A" tunnels-page "$PID_A" && take_shot "$SHOTS/tunnels-page.png"
wait "$PID_A" || note "flow A exited non-zero (see $LOG_A)"

# ── Flow B: atlas over mosh, plus known hosts and the swipe pad ───
LOG_B="$SHOTS/atlas.log"
: >"$LOG_B"
run_probe testDocShotsAtlasAndExtras "$LOG_B" "$SHOTS/atlas.xcresult" &
PID_B=$!

wait_ev "$LOG_B" known-hosts "$PID_B" && take_shot "$SHOTS/known-hosts.png"
if wait_ev "$LOG_B" swipe-pad "$PID_B"; then
  sleep 2.5
  take_shot "$SHOTS/swipe-pad-radial.png"
fi
wait "$PID_B" || note "flow B exited non-zero (see $LOG_B)"

# ── Agent Center (the app's built-in demo harness) ────────────────
# Connection-free and populated with representative agents. Any screenshot
# taken from it must be disclosed as demo data, not a live session.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
SIMCTL_CHILD_TESSERA_AGENT_CENTER_HARNESS=1 \
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
sleep 5
take_shot "$SHOTS/agent-center.png"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true

note "done"
ls -la "$SHOTS"/*.png 2>/dev/null || true
