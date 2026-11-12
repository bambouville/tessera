#!/usr/bin/env bash
# Keeps the Android third-party notices in step with the release build: every
# library Gradle resolves for the release runtime classpath must be listed, at
# its resolved version, in the notices file's Maven inventory, and the
# inventory must list nothing the build no longer ships.
#
# Usage: scripts/android/check-third-party-notices.sh            run Gradle
#        scripts/android/check-third-party-notices.sh LISTING    read a saved
#          `:app:dependencies --configuration releaseRuntimeClasspath` listing
#
# TESSERA_NOTICES_FILE overrides the notices file (for testing this script).
#
# A failure names each coordinate to add or remove. Add the library's license
# and any NOTICE file it distributes along with the inventory line.
set -euo pipefail

fail() {
  echo "third-party notices: $*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
notices="${TESSERA_NOTICES_FILE:-$repo_root/android/app/src/main/assets/ThirdPartyNotices.txt}"
[[ -f "$notices" ]] || fail "missing $notices"
[[ $# -le 1 ]] || fail "usage: $0 [DEPENDENCY_LISTING]"

work="$(mktemp -d "${TMPDIR:-/tmp}/tessera-notices.XXXXXX")"
cleanup() {
  local status=$?
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

listing="$work/listing"
if [[ $# -eq 1 ]]; then
  [[ -f "$1" ]] || fail "missing listing $1"
  cp "$1" "$listing"
else
  export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
  (cd "$repo_root/android" && ./gradlew --console=plain -q :app:dependencies --configuration releaseRuntimeClasspath) \
    > "$listing" || fail "gradle failed"
fi

# FAILED is a dependency that did not resolve; (n) one Gradle never tried to,
# as in a listing of a declaration-only configuration such as implementation.
status=0
grep -n -e 'FAILED' -e ' (n)$' "$listing" > "$work/unresolved" || status=$?
case $status in
  0) fail "the listing has unresolved dependencies: $(tr '\n' ' ' < "$work/unresolved")" ;;
  1) ;;
  *) fail "cannot read the listing" ;;
esac

# Tree lines look like `|    +--- group:artifact:1.0 -> 1.1 (*)`. Keep what
# Gradle selected: a new version, or a whole substituted module
# (`a:b:1.0 -> c:d:2.0`). Skip project modules and constraint-only (c) entries.
# awk reads the whole file, so nothing upstream can be cut short.
awk '
  {
    line = $0
    if (!sub(/^[| ]*[+\\]--- /, "", line)) next
    if (line ~ /^project /) next
    if (line ~ / \(c\)$/) next
    sub(/ \(\*\)$/, "", line)
    split(line, parts, " -> ")
    count = split(parts[1], field, ":")
    if (count < 2 || count > 3) next
    group = field[1]; artifact = field[2]; version = (count == 3) ? field[3] : ""
    if (2 in parts) {
      selected = split(parts[2], target, ":")
      if (selected == 3) { group = target[1]; artifact = target[2]; version = target[3] }
      else if (selected == 1) version = parts[2]
      else next
    }
    if (version == "") next
    print group ":" artifact ":" version
  }
' "$listing" | LC_ALL=C sort -u > "$work/resolved"
[[ -s "$work/resolved" ]] || fail "no dependencies found in the listing"

grep -n -x -e 'BEGIN MAVEN INVENTORY' -e 'END MAVEN INVENTORY' "$notices" > "$work/markers" \
  || fail "no BEGIN/END MAVEN INVENTORY markers in $notices"
awk '
  $0 == "BEGIN MAVEN INVENTORY" { inside = 1; begun++; next }
  $0 == "END MAVEN INVENTORY" { inside = 0; ended++; next }
  inside && $0 !~ /^[ \t]*(#|$)/ { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print }
  END { if (begun != 1 || ended != 1 || inside) exit 3 }
' "$notices" > "$work/inventory.raw" || fail "the inventory markers in $notices are unbalanced"
LC_ALL=C sort -u "$work/inventory.raw" > "$work/listed"

LC_ALL=C comm -23 "$work/resolved" "$work/listed" > "$work/missing"
LC_ALL=C comm -13 "$work/resolved" "$work/listed" > "$work/stale"
if [[ -s "$work/missing" || -s "$work/stale" ]]; then
  if [[ -s "$work/missing" ]]; then
    echo "third-party notices: resolved but not listed in $notices:" >&2
    sed 's/^/  /' "$work/missing" >&2
  fi
  if [[ -s "$work/stale" ]]; then
    echo "third-party notices: listed but no longer resolved:" >&2
    sed 's/^/  /' "$work/stale" >&2
  fi
  exit 1
fi

echo "third-party notices: $(wc -l < "$work/resolved" | tr -d ' ') release dependencies listed"
script_completed=1
