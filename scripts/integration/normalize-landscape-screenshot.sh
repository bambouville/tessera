#!/usr/bin/env bash
# Accept either simctl framebuffer shape and normalize to upright landscape.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: ${0##*/} RAW OUT" >&2
  exit 2
fi

raw="$1"
out="$2"
dimensions="$(sips -g pixelWidth -g pixelHeight "$raw")"
width="$(awk '$1 == "pixelWidth:" {print $2}' <<< "$dimensions")"
height="$(awk '$1 == "pixelHeight:" {print $2}' <<< "$dimensions")"
if [[ ! "$width" =~ ^[1-9][0-9]*$ || ! "$height" =~ ^[1-9][0-9]*$ ]]; then
  echo "Cannot read PNG dimensions: $raw" >&2
  exit 1
fi

if ((height > width)); then
  sips -r 270 "$raw" --out "$out" >/dev/null
elif [[ "$out" != "$raw" ]]; then
  cp "$raw" "$out"
fi
