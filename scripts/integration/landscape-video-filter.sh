#!/usr/bin/env bash
# Rotate only frames still displayed in portrait after ffmpeg autorotation.
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: ${0##*/} VIDEO" >&2
  exit 2
fi

metadata="$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height:stream_side_data=rotation -of json "$1")"
python3 - "$metadata" <<'PY'
import json
import sys

stream = json.loads(sys.argv[1])['streams'][0]
width, height = stream['width'], stream['height']
if width <= 0 or height <= 0:
    raise ValueError('Cannot read video dimensions')
rotation = next((side['rotation'] for side in stream.get('side_data_list', [])
                 if 'rotation' in side), 0)
if float(rotation) % 360 in (90, 270):
    width, height = height, width
if height > width:
    print('transpose=cclock,')
PY
