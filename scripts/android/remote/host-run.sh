#!/usr/bin/env bash
# Host half of scripts/android/remote-build.sh, uploaded with the Dockerfile on
# every run. Prunes the copied checkout to the files the Mac sent, builds the
# image when the Dockerfile changes, and runs Gradle in a container. One build
# runs per host at a time.
#
#   host-run.sh <root under $HOME> <checkout name> <cpus> <memory> <heap> <gradle args...>
set -euo pipefail

fail() {
  echo "remote build: $*" >&2
  exit 1
}

[[ $# -ge 6 ]] || fail "usage: $0 <root> <name> <cpus> <memory> <heap> <gradle args...>"
root="$HOME/$1"
name="$2"
cpus="$3"
memory="$4"
heap="$5"
shift 5

src="$root/src/$name"
manifest="$root/manifests/$name"
[[ -d "$src" && -f "$manifest" ]] || fail "missing $src or its manifest"

# Delete what the checkout no longer has. Build outputs and caches stay, so
# Gradle and SwiftPM build incrementally.
(
  cd "$src"
  find . \( -name build -o -name .build -o -name .gradle -o -name .cxx -o -name .kotlin \) -prune \
    -o \( -type f -o -type l \) -print0 | sed -z 's|^\./||' | LC_ALL=C sort -z > "$manifest.have"
  LC_ALL=C sort -z "$manifest" > "$manifest.want"
  LC_ALL=C comm -z -23 "$manifest.have" "$manifest.want" | xargs -0 -r rm -f --
)
rm -f "$manifest.have" "$manifest.want"

exec 9>"$root/build.lock"
if ! flock -n 9; then
  echo "remote build: waiting for another build on this host..." >&2
  flock 9
fi

uid="$(id -u)"
gid="$(id -g)"
tag="tessera-android-build:$({ cat "$root/tool/Dockerfile"; echo "$uid:$gid"; } | sha256sum | cut -c1-12)"
if ! docker image inspect "$tag" >/dev/null 2>&1; then
  echo "remote build: building $tag (first run after a Dockerfile change)..." >&2
  docker build --force-rm --build-arg BUILDER_UID="$uid" --build-arg BUILDER_GID="$gid" \
    -t "$tag" - < "$root/tool/Dockerfile"
  docker image ls --format '{{.Repository}}:{{.Tag}}' tessera-android-build \
    | grep -vx "$tag" | xargs -r docker image rm >/dev/null || true
fi

mkdir -p "$root/cache/gradle" "$root/cache/swiftpm"
container="tessera-android-$name-$$"
# The Mac's ssh closing makes docker's client exit; take the container with it.
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM PIPE

# Results the Mac pulls back are the ones written after this stamp.
touch "$manifest.started"
# gradle.properties' 4 GB heap suits a laptop. With one worker per CPU here, a
# --rerun-tasks build merges every androidTest APK's library dex at once, and D8
# runs inside the daemon: it ran out of heap merging six. The Kotlin daemon
# would inherit the larger heap; it keeps the 4 GB it had.
docker run --rm --init --name "$container" \
  --cpus "$cpus" --memory "$memory" --memory-swap "$memory" \
  -v "$src:/work/src" \
  -v "$root/cache/gradle:/home/builder/.gradle" \
  -v "$root/cache/swiftpm:/home/builder/.cache" \
  -e TESSERA_ANDROID_BUILD_JOBS="$cpus" \
  -w /work/src/android \
  "$tag" ./gradlew --no-watch-fs "-Dorg.gradle.jvmargs=-Xmx$heap -Dfile.encoding=UTF-8" \
    "-Pkotlin.daemon.jvmargs=-Xmx4g" "$@"
