#!/usr/bin/env bash
# Runs Gradle for a checkout on a remote x86_64 Linux host, inside the
# container scripts/android/remote/Dockerfile pins, and brings the reports,
# test results and outputs back.
#
#   TESSERA_ANDROID_REMOTE_HOST=user@host \
#     scripts/android/remote-build.sh [--source <checkout>] <gradle args...>
#
# The checkout (default: the one containing the current directory) is copied
# as its tracked and untracked, not ignored, files, plus submodules and the
# hydrated LFS files. Uncommitted changes go with it. docs/ and qa/ stay
# behind. On the host it lives in <root>/src/<checkout name>; files deleted
# here are deleted there, and build outputs stay for incremental builds.
# Results land in <checkout>/.build/android-remote/. Signing, Play uploads and
# emulator tests stay on the Mac: the image is x86_64 and the app arm64-only.
#
# Environment:
#   TESSERA_ANDROID_REMOTE_HOST    ssh destination (required)
#   TESSERA_ANDROID_REMOTE_ROOT    directory under the host's home (default tessera-android-build)
#   TESSERA_ANDROID_REMOTE_CPUS    container CPU limit (default 32)
#   TESSERA_ANDROID_REMOTE_MEMORY  container memory limit, no swap (default 32g)
#   TESSERA_ANDROID_REMOTE_HEAP    Gradle daemon heap (default 8g; the Kotlin daemon keeps 4g)
set -euo pipefail

fail() {
  echo "remote build: $*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$PWD"
if [[ "${1:-}" == "--source" ]]; then
  [[ $# -ge 2 ]] || fail "--source needs a directory"
  source_dir="$2"
  shift 2
fi
[[ $# -ge 1 ]] || fail "usage: $0 [--source <checkout>] <gradle args...>"

host="${TESSERA_ANDROID_REMOTE_HOST:-}"
[[ -n "$host" ]] || fail "set TESSERA_ANDROID_REMOTE_HOST to the build host's ssh destination"
remote_root="${TESSERA_ANDROID_REMOTE_ROOT:-tessera-android-build}"
cpus="${TESSERA_ANDROID_REMOTE_CPUS:-32}"
memory="${TESSERA_ANDROID_REMOTE_MEMORY:-32g}"
heap="${TESSERA_ANDROID_REMOTE_HEAP:-8g}"
[[ "$remote_root" =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ && "$remote_root" != *..* ]] \
  || fail "TESSERA_ANDROID_REMOTE_ROOT must be a plain path under the host's home"
[[ "$cpus" =~ ^[1-9][0-9]*$ ]] || fail "TESSERA_ANDROID_REMOTE_CPUS must be a whole number"
[[ "$memory" =~ ^[1-9][0-9]*[kmg]$ ]] || fail "TESSERA_ANDROID_REMOTE_MEMORY must look like 32g"
[[ "$heap" =~ ^[1-9][0-9]*[kmg]$ ]] || fail "TESSERA_ANDROID_REMOTE_HEAP must look like 8g"

checkout="$(git -C "$source_dir" rev-parse --show-toplevel)" || fail "$source_dir is not a git checkout"
name="$(basename "$checkout")"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "checkout name $name has characters the host paths don't allow"

if git -C "$checkout" submodule status --recursive | grep -q '^-'; then
  fail "submodules are not initialised; run git submodule update --init --recursive"
fi
lfs_paths="$(git -C "$checkout" lfs ls-files --name-only)" || fail "git lfs is required"
while IFS= read -r lfs_path; do
  case "$lfs_path" in
    "" | docs/* | qa/*) continue ;;
  esac
  if head -c 64 "$checkout/$lfs_path" 2>/dev/null | grep -q '^version https://git-lfs'; then
    fail "$lfs_path is an LFS pointer; run git lfs pull"
  fi
done <<<"$lfs_paths"

work="$(mktemp -d /tmp/tessera-remote.XXXXXX)"
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto
  -o "ControlPath=$work/cm" -o ControlPersist=120)
cleanup() {
  local status=$?
  # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
  # `set -e`; only a run that reached script_completed=1 may exit 0.
  if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
    echo "remote build: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  ssh "${ssh_opts[@]}" -O exit "$host" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

# The files to send, NUL-separated and relative to the checkout.
keep() {
  local prefix="$1" path
  while IFS= read -r -d '' path; do
    path="$prefix$path"
    case "$path" in
      docs/* | qa/* | .release-* | */.release-* | scripts/integration/secrets/*) continue ;;
    esac
    [[ -f "$checkout/$path" || -L "$checkout/$path" ]] || continue
    printf '%s\0' "$path"
  done
}
manifest="$work/stage/manifests/$name"
mkdir -p "$work/stage/manifests" "$work/stage/tool"
{
  git -C "$checkout" ls-files -z --cached --others --exclude-standard | keep ""
  while IFS= read -r -d '' submodule; do
    git -C "$checkout/$submodule" ls-files -z --cached --others --exclude-standard | keep "$submodule/"
  done < <(git -C "$checkout" submodule foreach --quiet --recursive 'printf "%s\0" "$displaypath"')
} > "$manifest"
cp "$script_dir/remote/Dockerfile" "$script_dir/remote/host-run.sh" "$work/stage/tool/"

echo "remote build: copying $name to $host:$remote_root/src/$name" >&2
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --no-acls -cf - -C "$work/stage" manifests tool \
  | ssh "${ssh_opts[@]}" "$host" "mkdir -p $remote_root && tar -xf - -C $remote_root"
(cd "$checkout" && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --no-acls --null -T "$manifest" -cf -) \
  | ssh "${ssh_opts[@]}" "$host" \
    "mkdir -p $remote_root/src/$name && tar --warning=no-unknown-keyword -xf - -C $remote_root/src/$name"

set +e
ssh "${ssh_opts[@]}" "$host" "bash $remote_root/tool/host-run.sh $remote_root $name $cpus $memory $heap $(printf '%q ' "$@")"
status=$?
set -e

# Test results and reports this run wrote, and the current outputs.
results="$checkout/.build/android-remote"
rm -rf "$results"
mkdir -p "$results"
ssh "${ssh_opts[@]}" "$host" "cd ~/$remote_root/src/$name/android && \
  { find . -path '*/build/outputs/*' \( -type f -o -type l \) -print0; \
    find . \( -path '*/build/reports/*' -o -path '*/build/test-results/*' \) -type f \
      -newer ~/$remote_root/manifests/$name.started -print0; } \
  | tar --null -T - -cf -" | tar -xf - -C "$results" || echo "remote build: could not fetch results" >&2

find "$results" -name 'TEST-*.xml' -print0 > "$work/test-results"
[[ -s "$work/test-results" ]] && xargs -0 awk '
  FNR == 1 { module = FILENAME; sub(/^.*\/android-remote\//, "", module); sub(/^\.\//, "", module); sub(/\/build\/.*$/, "", module) }
  /<testsuite / {
    for (i = 1; i <= NF; i++) if (split($i, kv, "=") == 2) { gsub(/"/, "", kv[2]); field[kv[1]] = kv[2] }
    tests[module] += field["tests"]; failed[module] += field["failures"] + field["errors"]
    skipped[module] += field["skipped"]; nextfile
  }
  END {
    for (m in tests) { printf "  %-28s %5d tests %3d failed %3d skipped\n", m, tests[m], failed[m], skipped[m]
      total += tests[m]; bad += failed[m] }
    if (total) printf "  %-28s %5d tests %3d failed\n", "total", total, bad
  }' < "$work/test-results" | sort >&2
echo "remote build: results in $results (gradle exit $status)" >&2
script_completed=1
exit "$status"
