#!/usr/bin/env bash
# Capture only the public key identified on the authenticated pairing review.
# The owner tracks fingerprints before any grant can start, across retries.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
run_dir="${1:?run output directory}"
fingerprint="${2:?recipient SHA256 fingerprint from pairing review}"
[[ -s "$run_dir/source.pub" && -s "$run_dir/live-session" ]] || die "not a key-only QR fixture run"
[[ "$fingerprint" =~ ^SHA256:[A-Za-z0-9+/]+$ ]] || die "invalid fingerprint"
source_fingerprint="$(ssh-keygen -lf "$run_dir/source.pub" | awk '{print $2}')"
[[ "$fingerprint" != "$source_fingerprint" ]] || die "recipient reused source key"
# Call with --stage from the authenticated recipient-key review BEFORE the
# approval tap; the EXIT cleanup then also covers an interrupted installation.
if ! grep -Fx "$fingerprint" "$run_dir/recipient-fingerprints" >/dev/null 2>&1; then
  printf '%s\n' "$fingerprint" >>"$run_dir/recipient-fingerprints"
fi
printf '%s\n' "$fingerprint" >"$run_dir/recipient-fingerprint"
if [[ "${3:-}" == --stage ]]; then
  echo 'Recorded recipient cleanup identity before approval.'
  exit 0
fi
load_fixture_config
control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$fingerprint" <<'REMOTE' >"$run_dir/recipient.pub"
set -euo pipefail
user_home="$(getent passwd "$1" | cut -d: -f6)"
found=0
while IFS= read -r line; do
  actual="$(printf '%s\n' "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')" || continue
  if [[ "$actual" == "$2" ]]; then
    printf '%s\n' "$line"
    found=$((found + 1))
  fi
done <"$user_home/.ssh/authorized_keys"
[[ "$found" == 1 ]]
REMOTE
[[ "$(ssh-keygen -lf "$run_dir/recipient.pub" | awk '{print $2}')" == "$fingerprint" ]] || die "recipient key proof mismatch"
control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$source_fingerprint" "$fingerprint" <<'REMOTE' >"$run_dir/public-key-authentication.log"
set -euo pipefail
journalctl -u tessera-fixture-sshd --since=-2hours --no-pager |
  grep -F "Accepted publickey for $1 " |
  grep -F -e "$2" -e "$3"
REMOTE
grep -F "$source_fingerprint" "$run_dir/public-key-authentication.log" >/dev/null
grep -F "$fingerprint" "$run_dir/public-key-authentication.log" >/dev/null
printf 'Verified distinct source and recipient public-key authentication.\n'
