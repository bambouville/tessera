#!/bin/bash
set -euo pipefail

source_dir="${SRCROOT}/SharedAssets/agent-host"
output_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/agent-host"
mkdir -p "$output_dir"
for target in darwin-arm64 darwin-x86_64 linux-aarch64 linux-x86_64; do
    input="$source_dir/tessera-agent-host-$target"
    output="$output_dir/tessera-agent-host-$target.lzfse"
    if [[ "$(/usr/bin/head -c 23 "$input")" == 'version https://git-lfs' ]]; then
        echo "error: Agent Host helper $input is an unhydrated Git LFS pointer; run git lfs pull." >&2
        exit 1
    fi
    /usr/bin/compression_tool -encode -a lzfse -i "$input" -o "$output"
    chmod 644 "$output"
done
for file in manifest.json THIRD-PARTY-NOTICES.txt; do
    cp "$source_dir/$file" "$output_dir/$file"
    chmod 644 "$output_dir/$file"
done
