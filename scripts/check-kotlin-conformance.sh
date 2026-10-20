#!/bin/sh
set -eu

expected_kotlin_version="2.2.21"
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
source_file="$repository_root/KotlinConformance/src/main/kotlin/tessera/conformance/Main.kt"
vector_root="$repository_root/ProtocolVectors"

fail() {
  echo "Kotlin conformance gate failed: $*" >&2
  exit 1
}

if [ -n "${KOTLINC:-}" ]; then
  kotlin_compiler=$KOTLINC
else
  kotlin_compiler=$(command -v kotlinc 2>/dev/null || true)
fi

[ -n "$kotlin_compiler" ] || fail \
  "kotlinc $expected_kotlin_version is required; set KOTLINC to the standalone compiler executable"
[ -x "$kotlin_compiler" ] || fail "KOTLINC is not executable: $kotlin_compiler"
[ -f "$source_file" ] || fail "missing Kotlin conformance source: $source_file"
[ -d "$vector_root" ] || fail "missing protocol-vector directory: $vector_root"

compiler_version=$("$kotlin_compiler" -version 2>&1) || fail "unable to run KOTLINC"
case "$compiler_version" in
  "info: kotlinc-jvm $expected_kotlin_version ("*) ;;
  *) fail "expected kotlinc-jvm $expected_kotlin_version, got: $compiler_version" ;;
esac

if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  java_bin="$JAVA_HOME/bin/java"
else
  java_bin=$(command -v java 2>/dev/null || true)
fi
[ -n "$java_bin" ] || fail "JDK 17 or newer is required; set JAVA_HOME"

java_version=$($java_bin -version 2>&1) || fail "unable to run Java from: $java_bin"
java_major=$(printf '%s\n' "$java_version" | sed -n '1s/.*version "\([0-9][0-9]*\).*/\1/p')
[ -n "$java_major" ] || fail "unable to parse Java version: $java_version"
[ "$java_major" -ge 17 ] || fail "JDK 17 or newer is required, got Java $java_major"

scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/tessera-kotlin-conformance.XXXXXX")
cleanup() {
  rm -rf "$scratch_root"
}
exit_cleanup() {
  status=$?
  # macOS /bin/sh is bash 3.2, which enters this trap with $? = 0 after a
  # `set -u` abort under `set -e`; only a completed run may exit 0.
  if [ "$status" -eq 0 ] && [ "${script_completed:-0}" != 1 ]; then
    printf '%s\n' "${0##*/}: aborted before completion (bash set -u abort?)" >&2
    status=1
  fi
  cleanup
  exit "$status"
}
trap exit_cleanup EXIT
trap cleanup HUP INT TERM

output_jar="$scratch_root/tessera-kotlin-conformance.jar"
"$kotlin_compiler" \
  "$source_file" \
  -jvm-target 17 \
  -Werror \
  -include-runtime \
  -d "$output_jar"

"$java_bin" -jar "$output_jar" "$vector_root"
script_completed=1
