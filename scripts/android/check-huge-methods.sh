#!/usr/bin/env bash
# Fails when an APK or dex file holds a method too large for ART to compile.
# ART's compiler skips any method over 10,000 dex code units (its huge-method
# threshold), so that method always runs interpreted, in debug and release
# alike. Compose reaches it easily: layout content lambdas and remember blocks
# are inlined into the composable that calls them.
#
# Usage: scripts/android/check-huge-methods.sh <apk-or-dex>...
#
# Only the third-party classes in the allowlist below may exceed the limit.
set -euo pipefail

fail() {
  echo "huge methods: $*" >&2
  exit 1
}

[[ $# -ge 1 ]] || fail "usage: $0 <apk-or-dex>..."

limit=10000
# A dex class descriptor prefix. zxing's PDF417 symbol table is one array
# initializer in a library we ship but do not change.
allowlist='Lcom/google/zxing/'

dexdump=""
sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -n "$sdk_root" && -x "$sdk_root/build-tools/36.0.0/dexdump" ]]; then
  dexdump="$sdk_root/build-tools/36.0.0/dexdump"
else
  # The glob sorts by version, so the last match is the newest.
  for candidate in /opt/homebrew/share/android-commandlinetools/build-tools/*/dexdump; do
    [[ -x "$candidate" ]] && dexdump="$candidate"
  done
fi
[[ -n "$dexdump" ]] || fail "no dexdump; set ANDROID_SDK_ROOT (Build Tools 36.0.0)"

work="$(mktemp -d "${TMPDIR:-/tmp}/tessera-huge-methods.XXXXXX")"
cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

# Each dex is dumped to a file and measured from it, never from a live pipe,
# so a dexdump or unzip failure stops the script instead of reading as
# "nothing found". A dump that lists no classes or no code fails as well.
total_dex=0
total_methods=0
: > "$work/found"
measure() {
  local dex="$1" label="$2" counts classes methods
  "$dexdump" "$dex" > "$work/dump" 2> "$work/dump.err" \
    || fail "cannot read $label: $(head -n 3 "$work/dump.err" | tr '\n' ' ')"
  LC_ALL=C awk -v limit="$limit" -v allow="$allowlist" -v label="$label" '
    /^Class #/ { classes++ }
    $1 == "Class" && $2 == "descriptor" { cls = $4; gsub(/\047/, "", cls) }
    $1 == "name" && $2 == ":" { name = $0; sub(/^[^\047]*\047/, "", name); sub(/\047[^\047]*$/, "", name) }
    $1 == "insns" && $2 == "size" {
      methods++
      if ($4 + 0 > limit) {
        kind = index(cls, allow) == 1 ? "allowed" : "huge"
        printf "%s %d %s.%s (%s)\n", kind, $4, cls, name, label
      }
    }
    END { printf "count %d %d\n", classes, methods }
  ' "$work/dump" > "$work/measured" || fail "cannot measure $label"
  counts="$(awk '$1 == "count" { print $2, $3 }' "$work/measured")" || fail "cannot read the counts for $label"
  classes="${counts%% *}"
  methods="${counts##* }"
  [[ "$classes" =~ ^[0-9]+$ && "$methods" =~ ^[0-9]+$ ]] || fail "no counts for $label"
  [[ "$classes" -gt 0 && "$methods" -gt 0 ]] || fail "dexdump listed no classes or no code in $label"
  awk '$1 != "count"' "$work/measured" >> "$work/found" || fail "cannot record the findings for $label"
  total_dex=$((total_dex + 1))
  total_methods=$((total_methods + methods))
}

apk_count=0
for input in "$@"; do
  [[ -f "$input" ]] || fail "no such file: $input"
  case "$input" in
    *.dex)
      measure "$input" "$input"
      ;;
    *.apk)
      apk_count=$((apk_count + 1))
      extracted="$work/apk$apk_count"
      unzip -Z1 "$input" > "$work/entries" || fail "cannot list $input"
      awk '/^classes[0-9]*\.dex$/' "$work/entries" > "$work/dexes" || fail "cannot read the entries of $input"
      [[ -s "$work/dexes" ]] || fail "$input has no classes*.dex"
      mkdir "$extracted"
      unzip -q "$input" 'classes*.dex' -d "$extracted" || fail "cannot extract $input"
      while IFS= read -r entry; do
        [[ -f "$extracted/$entry" ]] || fail "$entry missing from the extraction of $input"
        measure "$extracted/$entry" "$input!$entry"
      done < "$work/dexes"
      ;;
    *)
      fail "not an .apk or .dex: $input"
      ;;
  esac
done

allowed="$(awk '$1 == "allowed" { n++ } END { print n + 0 }' "$work/found")" || fail "cannot read the findings"
huge="$(awk '$1 == "huge" { n++ } END { print n + 0 }' "$work/found")" || fail "cannot read the findings"
if [[ "$allowed" -gt 0 ]]; then
  echo "allowed third-party methods over $limit code units:"
  awk '$1 == "allowed" { sub(/^allowed /, ""); print }' "$work/found" | sort -nr || fail "cannot list the findings"
fi
if [[ "$huge" -gt 0 ]]; then
  echo "methods over $limit code units, which ART will not compile:" >&2
  awk '$1 == "huge" { sub(/^huge /, ""); print }' "$work/found" | sort -nr >&2 || fail "cannot list the findings"
  fail "$huge method(s) over the limit"
fi
echo "huge methods: $total_methods methods with code in $total_dex dex files, none of ours over $limit code units"
script_completed=1
