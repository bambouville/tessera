#!/usr/bin/env python3
"""Export timestamped during-gesture evidence from the ordering runner's video."""
import argparse
import bisect
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


def presentation_times(video):
    """Each decoded frame's PTS, in decoder output order.

    simctl recordings carry DTS about 20 s behind PTS, and ffmpeg's
    best-effort timestamp switches to DTS partway through, so a filter that
    trims by time takes frames from later in the video (the run that showed
    this sampled SpringBoard after the test had ended). Frames are chosen by
    index from their real PTS instead."""
    output = subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time',
        '-of', 'csv=p=0', str(video)], text=True)
    times = [float(line.split(',')[0]) for line in output.splitlines() if line.strip()]
    assert times and times == sorted(times), 'frame PTS must rise in output order'
    return times


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
times = presentation_times(video)
for first, last, label in pairs:
    start, end = markers[first], markers[last]
    assert 0 <= start < end <= times[-1] + 1, (first, last, start, end, times[-1])
    fps = 5 if label == 'strip' else 2
    crop = 'crop=iw:ih*0.65:0:0,' if args.phone else ('crop=iw:160:0:0,' if label == 'strip' else 'crop=800:1100:iw-800:0,')
    # The strip is a full-width band: one per row at half resolution keeps its
    # tabs and the drag gap legible.
    columns, scaled_width = (1, 1376) if label == 'strip' else (4, 320)
    # The recording is variable-rate: each sample shows the newest frame
    # presented by then, so a static span repeats one frame.
    samples = [start + step / fps for step in range(int((end - start) * fps) + 1)]
    picks = [max(bisect.bisect_right(times, sample) - 1, 0) for sample in samples]
    unique = sorted(set(picks))
    select = '+'.join(f'eq(n\\,{index})' for index in unique)
    with tempfile.TemporaryDirectory(prefix='tessera-order-frames-') as temporary:
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(video), '-fps_mode', 'passthrough', '-vf',
                        f'select={select},' + rotate + crop + f'scale={scaled_width}:-1',
                        str(pathlib.Path(temporary) / '%04d.png')], check=True)
        extracted = sorted(pathlib.Path(temporary).glob('*.png'))
        assert len(extracted) == len(unique), (label, len(extracted), len(unique))
        frames = dict(zip(unique, extracted))
        with Image.open(extracted[0]) as first_image:
            width, height = first_image.size
        sheet = Image.new('RGB', (width * columns, (height + 22) * math.ceil(len(samples) / columns)), '#303030')
        draw = ImageDraw.Draw(sheet)
        for position, (sample, index) in enumerate(zip(samples, picks)):
            x, y = position % columns * width, position // columns * (height + 22)
            with Image.open(frames[index]) as frame:
                sheet.paste(frame.convert('RGB'), (x, y + 22))
            draw.text((x + 4, y + 3), f'{sample:.2f}s (frame {times[index]:.2f}s)', fill='white')
        sheet.save(root / 'screenshots' / (label + '-motion.png'))
        summary.append({'gesture':label, 'videoSeconds':[start,end], 'sampledFrames':len(samples), 'distinctFrames':len(unique), 'samplesPerSecond':fps, 'timestampNote':'Approximate video offsets from wall-clock markers and MP4 creation time; frames are chosen by presentation timestamp, and a static VFR span repeats its frame.'})
(root / 'motion-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
