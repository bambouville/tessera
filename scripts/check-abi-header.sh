#!/usr/bin/env bash
#
# The C header is the ONLY thing the Android JNI shim compiles against, but
# nothing links it to the Swift `@_cdecl` exports: a function added on one side
# and forgotten on the other fails at `dlsym` time, on a device, in whatever
# feature happened to call it first. Five `tessera_tmux_runtime_*` prototypes
# had already drifted out of the header that way.
#
# This gate compares the two lists and fails on any asymmetry.
#
#   scripts/check-abi-header.sh
#
# Exit codes: 0 in sync, 1 mismatch, 2 the inputs could not be read.

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sources_directory="$repository_root/Packages/TesseraCore/Sources/TesseraCoreABI"
header_path="$repository_root/Packages/TesseraCore/Sources/TesseraCoreCABIHeaders/include/TesseraCoreABI.h"

if [ ! -d "$sources_directory" ]; then
    echo "check-abi-header: missing ABI sources at $sources_directory" >&2
    exit 2
fi
if [ ! -f "$header_path" ]; then
    echo "check-abi-header: missing header at $header_path" >&2
    exit 2
fi

work_directory="$(mktemp -d)"
cleanup() {
    local status=$?
    # bash 3.2 enters this trap with $? = 0 after a `set -u` abort under
    # `set -e`; only a run that reached script_completed=1 may exit 0.
    if [[ "$status" -eq 0 && "${script_completed:-0}" != 1 ]]; then
        echo "${0##*/}: aborted before completion (bash set -u abort?)" >&2
        status=1
    fi
    rm -rf "$work_directory"
    exit "$status"
}
trap cleanup EXIT

# Swift side: every exported C symbol is an `@_cdecl("…")`.
grep -ho '@_cdecl("[A-Za-z0-9_]*")' "$sources_directory"/*.swift \
    | sed 's/@_cdecl("//; s/")//' \
    | sort -u > "$work_directory/swift.txt"

# Header side: a declared function is `tessera_<name>(`, after comments are
# stripped so prose naming a function is not mistaken for a prototype. Function
# POINTER typedefs (`typedef void (*tessera_…_callback)(…)`) are types, not
# exports, and are excluded by requiring the paren to follow the name directly.
perl -0pe 's{/\*.*?\*/}{ }gs; s{//[^\n]*}{}g' "$header_path" \
    | grep -o '\btessera_[a-z0-9_]*(' \
    | sed 's/($//; s/(//' \
    | sort -u > "$work_directory/header.txt"

if [ ! -s "$work_directory/swift.txt" ]; then
    echo "check-abi-header: found no @_cdecl exports — is the source path right?" >&2
    exit 2
fi
if [ ! -s "$work_directory/header.txt" ]; then
    echo "check-abi-header: found no prototypes — is the header path right?" >&2
    exit 2
fi

missing_from_header="$(comm -23 "$work_directory/swift.txt" "$work_directory/header.txt")"
missing_from_swift="$(comm -13 "$work_directory/swift.txt" "$work_directory/header.txt")"

status=0
if [ -n "$missing_from_header" ]; then
    echo "Exported by Swift but NOT declared in TesseraCoreABI.h:" >&2
    echo "$missing_from_header" | sed 's/^/  - /' >&2
    status=1
fi
if [ -n "$missing_from_swift" ]; then
    echo "Declared in TesseraCoreABI.h but NOT exported by Swift:" >&2
    echo "$missing_from_swift" | sed 's/^/  - /' >&2
    status=1
fi

if [ "$status" -ne 0 ]; then
    echo >&2
    echo "The C ABI header and the Swift @_cdecl exports disagree." >&2
    echo "Every ABI function must exist in all four layers: Swift, this header," >&2
    echo "tessera_core_jni.cpp, and a core-bridge Kotlin wrapper." >&2
    exit 1
fi

echo "check-abi-header: $(wc -l < "$work_directory/swift.txt" | tr -d ' ') functions in sync"
script_completed=1
