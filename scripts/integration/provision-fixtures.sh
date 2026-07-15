#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

load_fixture_config
ensure_fixture_credentials
require_command base64
require_command scp
require_command ssh

password="$(fixture_password)"
password_hash="$(printf '%s' "$password" | openssl passwd -6 -stdin)"
password_hash_b64="$(printf '%s' "$password_hash" | base64 | tr -d '\n')"
public_key_b64="$(fixture_public_key | base64 | tr -d '\n')"

provision_one() {
  local role="$1"
  local host="$2"
  note "provisioning $role fixture at $host"
  control_scp "$HERE/remote/tessera-fixture-probe.py" "$host" /tmp/tessera-fixture-probe.py
  control_scp "$HERE/remote/tessera-fixture-admin" "$host" /tmp/tessera-fixture-admin
  control_ssh "$host" \
    bash -s -- \
    "$role" \
    "$TESSERA_FIXTURE_USER" \
    "$TESSERA_FIXTURE_NOTMUX_USER" \
    "$TESSERA_FIXTURE_APP_PORT" \
    "$password_hash_b64" \
    "$public_key_b64" \
    <"$HERE/remote/provision.sh"
}

provision_one stable "$TESSERA_FIXTURE_STABLE_HOST" &
stable_pid=$!
provision_one chaos "$TESSERA_FIXTURE_CHAOS_HOST" &
chaos_pid=$!

status=0
wait "$stable_pid" || status=1
wait "$chaos_pid" || status=1
[[ $status -eq 0 ]] || die "one or more fixtures failed to provision"

note "fixture provisioning complete"
"$HERE/verify-fixtures.sh"
