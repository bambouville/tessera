#!/usr/bin/env bash
# Disposable VPS-only, credential-free Codex TUI for lifecycle scroll checks.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/integration/lib.sh"
load_fixture_config
action="${1:-prepare}"
case "$action" in
  cleanup)
    fixture_root="${2:?supply the root printed by prepare}"
    [[ "$fixture_root" =~ ^/tmp/tessera-codex-[A-Za-z0-9_-]+$ ]] || die 'invalid Codex fixture root'
    control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$fixture_root" <<'REMOTE'
set -eu
test "$(cat "$1/.tessera-codex-mouse-fixture")" = 'codex-0.160.0'
rm -rf -- "$1"
REMOTE
    script_completed=1
    exit 0
    ;;
  prepare) ;;
  *) die 'usage: prepare-codex-mouse-fixture.sh [prepare | cleanup ROOT]' ;;
esac
local_root="$(mktemp -d "${TMPDIR:-/tmp}/tessera-codex-download.XXXXXX")"
fixture_root=''
cleanup() {
  local result=$?
  fail_closed_status "$result" || result=1
  trap - EXIT
  rm -rf -- "$local_root"
  if [[ "$result" -ne 0 && -n "$fixture_root" ]]; then
    control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$fixture_root" <<'REMOTE' || true
set -eu
rm -rf -- "$1"
REMOTE
  fi
  exit "$result"
}
trap cleanup EXIT
archive="${TESSERA_CODEX_FIXTURE_ARCHIVE:-$local_root/codex.tar.gz}"
if [[ -z "${TESSERA_CODEX_FIXTURE_ARCHIVE:-}" ]]; then
  curl --fail --location --silent --show-error \
    'https://github.com/openai/codex/releases/download/rust-v0.160.0/codex-x86_64-unknown-linux-musl.tar.gz' \
    --output "$archive"
fi
expected_sha='306865417d4ee7a927785852910a527f41e1e159add390ac5ae3accb67d44a13'
[[ "$(shasum -a 256 "$archive" | awk '{print $1}')" == "$expected_sha" ]] || die 'Codex 0.160.0 archive checksum mismatch'
tar -xzf "$archive" -C "$local_root"
binary="$local_root/codex-x86_64-unknown-linux-musl"
[[ -f "$binary" ]] || die 'Codex binary missing from pinned archive'
run_token="$(date -u +%Y%m%dT%H%M%SZ)-$$"
fixture_root="$(control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$run_token" <<'REMOTE'
set -euo pipefail
root="$(mktemp -d "/tmp/tessera-codex-$2-XXXXXXXX")"
trap 'rm -rf -- "$root"' EXIT
chown "$1:$1" "$root"
printf '%s\n' "$root"
trap - EXIT
REMOTE
)"
[[ "$fixture_root" =~ ^/tmp/tessera-codex-[A-Za-z0-9_-]+$ ]] || die 'unexpected fixture root'
control_scp "$binary" "$TESSERA_FIXTURE_STABLE_HOST" "$fixture_root/codex-x86_64-unknown-linux-musl"
control_scp "$repo_root/scripts/integration/seed-codex-mouse-fixture.py" "$TESSERA_FIXTURE_STABLE_HOST" "$fixture_root/seed.py"
control_ssh "$TESSERA_FIXTURE_STABLE_HOST" bash -s -- "$TESSERA_FIXTURE_USER" "$fixture_root" <<'REMOTE'
set -eu
chown "$1:$1" "$2/codex-x86_64-unknown-linux-musl" "$2/seed.py"
chmod 755 "$2/codex-x86_64-unknown-linux-musl"
printf 'codex-0.160.0\n' >"$2/.tessera-codex-mouse-fixture"
runuser -u "$1" -- python3 "$2/seed.py" "$2" >/dev/null
REMOTE
printf '%s\n' "$fixture_root"
script_completed=1
