#!/usr/bin/env python3
"""Export timestamped during-gesture evidence from the ordering runner's video."""
import argparse
import datetime as dt
import json
import math
import pathlib
import re
import subprocess
import tempfile
from PIL import Image, ImageDraw


def landscape_video_filter(video):
    metadata = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
        'stream=width,height:stream_side_data=rotation', '-of', 'json', str(video)]))
    stream = metadata['streams'][0]
    width, height = stream['width'], stream['height']
    if width <= 0 or height <= 0:
        raise ValueError('Cannot read video dimensions')
    rotation = next((side['rotation'] for side in stream.get('side_data_list', [])
                     if 'rotation' in side), 0)
    if float(rotation) % 360 in (90, 270):
        width, height = height, width
    return 'transpose=cclock,' if height > width else ''


parser = argparse.ArgumentParser()
parser.add_argument('run_directory', type=pathlib.Path)
parser.add_argument('--phone', action='store_true')
args = parser.parse_args()
root = args.run_directory
video = root / 'interaction.mp4'
metadata = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format_tags=creation_time', '-of', 'json', str(video)]))
created = dt.datetime.fromisoformat(metadata['format']['tags']['creation_time'].replace('Z', '+00:00'))
markers = {}
for line in (root / 'xctest.log').read_text().splitlines():
    match = re.match(r'(\S+) (\S+).*TESSERA_WINDOW_ORDER_CAPTURE (\S+)', line)
    if match:
        markers[match[3]] = (dt.datetime.fromisoformat(match[1] + 'T' + match[2]) - created).total_seconds()
pairs = [('compact-before', 'compact-after', 'compact')] if args.phone else [('before-drag', 'after-drag', 'popover'), ('strip-before', 'strip-after', 'strip')]
summary = []
rotate = '' if args.phone else landscape_video_filter(video)
for first, last, label in pairs:
    start, end = markers[first], markers[last]
    assert 0 <= start < end, (first, last, start, end)
    fps = 5 if label == 'strip' else 2
    crop = 'crop=iw:ih*0.65:0:0,' if args.phone else ('crop=iw:160:0:0,' if label == 'strip' else 'crop=800:1100:iw-800:0,')
    with tempfile.TemporaryDirectory(prefix='tessera-order-frames-') as temporary:
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(video), '-vf', f'trim=start={start}:end={end},setpts=PTS-STARTPTS,' + rotate + crop + f'fps={fps},scale=320:-1', str(pathlib.Path(temporary) / '%04d.png')], check=True)
        paths = sorted(pathlib.Path(temporary).glob('*.png'))
        assert paths, label
        with Image.open(paths[0]) as first_image:
            width, height = first_image.size
        sheet = Image.new('RGB', (width * 4, (height + 22) * math.ceil(len(paths)/4)), '#303030')
        draw = ImageDraw.Draw(sheet)
        for index, path in enumerate(paths):
            x, y = index % 4 * width, index // 4 * (height + 22)
            with Image.open(path) as frame:
                sheet.paste(frame.convert('RGB'), (x, y + 22))
            draw.text((x + 4, y + 3), f'{start + index/fps:.2f}s', fill='white')
        sheet.save(root / 'screenshots' / (label + '-motion.png'))
        summary.append({'gesture':label, 'videoSeconds':[start,end], 'sampledFrames':len(paths), 'samplesPerSecond':fps, 'timestampNote':'Approximate video offsets from wall-clock markers and MP4 creation time; static VFR spans may contain fewer frames.'})
(root / 'motion-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
