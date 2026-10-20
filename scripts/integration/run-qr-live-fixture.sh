#!/usr/bin/env bash
# Own one disposable VPS tmux session while the two-device QR UI is exercised.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
run_dir="$1"
udid="$2"
[[ "$(<"$run_dir/ios/simulator_udid.owned")" == "$udid" ]] || die "not this run's owned simulator"
load_fixture_config
session="tessera-qr-live-$(date -u +%Y%m%dT%H%M%SZ)-$$"
created=0
cleanup() {
  [[ "$created" == 1 ]] || return 0
  local status=0 fingerprint
  # Fingerprints are recorded before approval, so interruption immediately
  # after installation cannot leave an untracked recipient grant.
  local fingerprints=()
  if [[ -s "$run_dir/source.pub" ]]; then
    fingerprints+=("$(ssh-keygen -lf "$run_dir/source.pub" | awk '{print $2}')")
  fi
  if [[ -s "$run_dir/recipient-fingerprint" ]]; then
    fingerprints+=("$(<"$run_dir/recipient-fingerprint")")
  fi
  if [[ -s "$run_dir/recipient-fingerprints" ]]; then
    while IFS= read -r fingerprint; do fingerprints+=("$fingerprint"); done <"$run_dir/recipient-fingerprints"
  fi
  # Stop the source before revocation so a pending native installer cannot
  # outlive the key absence check. This is only this run's recorded simulator.
  xcrun simctl terminate "$udid" com.bambouville.TesseraApp >/dev/null 2>&1 || true
  for fingerprint in ${fingerprints[@]+"${fingerprints[@]}"}; do
    [[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] || { status=1; continue; }
    if ! control_ssh "$TESSERA_FIXTURE_STABLE_HOST" python3 - --user \
      "$TESSERA_FIXTURE_USER" "$fingerprint" \
      <"$HERE/remote/revoke-qr-fixture-key.py" >>"$run_dir/cleanup.log" 2>&1; then
      status=1
    fi
  done
  if ! control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$session" >>"$run_dir/cleanup.log" 2>&1 <<'REMOTE'
set -eu
fixture_user="$1"
owned_session="$2"
# Grouped views inherit this uniquely named owner group. Never touch any other
# fixture sessions, users, tmux sockets, or the user's personal hosts.
runuser -u "$fixture_user" -- tmux list-sessions -F '#{session_name}|#{session_group}' 2>/dev/null |
while IFS='|' read -r name group; do
  if [ "$name" = "$owned_session" ] || [ "$group" = "$owned_session" ]; then
    runuser -u "$fixture_user" -- tmux kill-session -t "=$name"
    echo "removed owned tmux session: $name"
  fi
done
REMOTE
  then status=1; fi
  printf 'cleanup_status=%s\n' "$status" >>"$run_dir/cleanup.log"
  return "$status"
}
trap 'fail_closed_trap cleanup' EXIT
trap 'exit 130' INT TERM
control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$session" <<'REMOTE'
set -eu
runuser -u "$1" -- tmux new-session -d -s "$2" -x 120 -y 32
REMOTE
created=1
printf '%s\n' "$session" >"$run_dir/live-session"
control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$session" <<'REMOTE'
set -eu
runuser -u "$1" -- tmux send-keys -t "$2:0.0" "printf '\\nQR LIVE CONTINUITY - same remote shell before and after handoff\\n'; export QR_HANDOFF_MARKER='$2'; printf 'Shell PID: %s\\n' \"\$\$\"" Enter
REMOTE
if [[ "${TESSERA_QR_AUTH:-password}" == publicKey ]]; then
  verified_pin="$(control_ssh "$TESSERA_FIXTURE_STABLE_HOST" cat /opt/tessera-fixture/ssh/ssh_host_ed25519_key.pub)"
  config_json="$(jq -cn --arg name 'QR live VPS' --arg user "$TESSERA_FIXTURE_USER" \
    --arg address "$TESSERA_FIXTURE_STABLE_HOST" --argjson port "$TESSERA_FIXTURE_APP_PORT" \
    --arg tmux "$session" --arg pin "$verified_pin" \
    '{name:$name,user:$user,address:$address,port:$port,generateSourceKey:true,injectDescriptor:false,verifiedFixtureHostKey:$pin,transport:"ssh",launchMode:"pinnedTmux",tmuxSessionName:$tmux}')"
else
  config_json="$(jq -cn --arg name 'QR live VPS' --arg user "$TESSERA_FIXTURE_USER" \
  --arg address "$TESSERA_FIXTURE_STABLE_HOST" --argjson port "$TESSERA_FIXTURE_APP_PORT" \
  --arg password "$(fixture_password)" --arg tmux "$session" \
  '{name:$name,user:$user,address:$address,port:$port,password:$password,transport:"ssh",launchMode:"pinnedTmux",tmuxSessionName:$tmux}')"
fi
config="$(printf '%s' "$config_json" | base64 | tr -d '\n')"
xcrun simctl terminate "$udid" com.bambouville.TesseraApp >/dev/null 2>&1 || true
# Seed only first-open markers on this disposable device. Do not change the
# user's connection-restore policy or touch their persistent testing devices.
xcrun simctl spawn "$udid" defaults write com.bambouville.TesseraApp tessera.nearbyBootstrap.completed.v1 -bool YES
xcrun simctl spawn "$udid" defaults write com.bambouville.TesseraApp tessera.pref.hasSeenWelcome -bool YES
SIMCTL_CHILD_TESSERA_CONTINUITY_LIVE_HARNESS="$config" xcrun simctl launch "$udid" com.bambouville.TesseraApp
if [[ "${TESSERA_QR_AUTH:-password}" == publicKey ]]; then
  container="$(xcrun simctl get_app_container "$udid" com.bambouville.TesseraApp data)"
  for ((attempt=0; attempt<60; attempt++)); do
    [[ -s "$container/Documents/qr-live-source.pub" ]] && break
    sleep 1
  done
  [[ -s "$container/Documents/qr-live-source.pub" ]] || die "source key generation did not finish"
  cp "$container/Documents/qr-live-source.pub" "$run_dir/source.pub"
  public_blob="$(awk '{print $2}' "$run_dir/source.pub")"
  [[ "$public_blob" =~ ^[A-Za-z0-9+/=]+$ ]] || die "invalid source public key"
  control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$public_blob" "$session" <<'REMOTE_KEY'
set -eu
user_home="$(getent passwd "$1" | cut -d: -f6)"
printf 'ssh-ed25519 %s %s-source\n' "$2" "$3" >>"$user_home/.ssh/authorized_keys"
REMOTE_KEY
  config="$(printf '%s' "$config_json" | jq '.injectDescriptor = true' | base64 | tr -d '\n')"
  xcrun simctl terminate "$udid" com.bambouville.TesseraApp
  SIMCTL_CHILD_TESSERA_CONTINUITY_LIVE_HARNESS="$config" xcrun simctl launch "$udid" com.bambouville.TesseraApp
  echo 'Public-key fixture: no password supplied; source private key remains in device Keychain.'
fi
echo 'Live fixture active. Send newline after capture to remove only this run-owned tmux group.'
read -r _
script_completed=1
