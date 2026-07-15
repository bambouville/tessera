#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-jump.sh
source "$HERE/lib-jump.sh"

load_jump_config
ensure_jump_credentials
write_jump_ssh_config

provision_one() {
  local role="$1" host="$2" allowed="$3"
  local password_hash pubkey
  password_hash="$(jump_password "$role" | openssl passwd -6 -stdin)"
  jump_note "provisioning $role at $host"
  jump_control_ssh "$host" \
    bash -s -- \
    "$role" \
    "$TESSERA_JUMP_KEY_USER" \
    "$TESSERA_JUMP_PW_USER" \
    "$TESSERA_JUMP_APP_PORT" \
    "$TESSERA_JUMP_INNER_PORT" \
    "$(printf '%s' "$password_hash" | base64 | tr -d '\n')" \
    "$(jump_public_key "$role" | base64 | tr -d '\n')" \
    "$allowed" \
    <"$HERE/remote-provision-jump.sh"
}

provision_one bastion "$TESSERA_JUMP_BASTION_HOST" "" &
bastion_pid=$!
provision_one target "$TESSERA_JUMP_TARGET_HOST" \
  "$TESSERA_JUMP_BASTION_HOST,$TESSERA_JUMP_BASTION_PRIVATE" &
target_pid=$!

status=0
wait "$bastion_pid" || status=1
wait "$target_pid" || status=1
[[ $status -eq 0 ]] || jump_die "one or more jump fixtures failed to provision"

jump_note "jump fixture provisioning complete"
"$HERE/verify-jump-fixtures.sh"
