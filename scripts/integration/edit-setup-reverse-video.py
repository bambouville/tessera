#!/usr/bin/env python3
"""Append the successful native reverse test to the forward evidence film."""
from pathlib import Path
import json
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFont

source, forward, out = (Path(p).resolve() for p in sys.argv[1:4])
out.mkdir(parents=True, exist_ok=True)
segments = [
    ("Reverse direction: compare code 424168", 82, 1, 85, 18, False),
    ("Android reviews the iPhone's own public key and selected host", 163, 1, 166, 13, False),
    ("iPhone imports; Android installs and verifies only its public key", 210, 2, 32, 30, False),
    ("Both devices confirm AUTHORIZED; no private keys transferred", 237, 2, 59, 14, False),
    ("Android yields; iPhone controls the same shell, PID 399448", 308, 2, 110, 19, True),
]

def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True, timeout=180)

paths = []
for index, (caption, ios, part, android, duration, yielded) in enumerate(segments):
    overlay = out / f"reverse-title-{index}.png"
    layer = Image.new("RGBA", (1920, 1080))
    draw = ImageDraw.Draw(layer)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 27)
    foot = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 19)
    draw.text((55, 38), "Android · sender · its own P-256 key", font=font, fill="white")
    draw.text((995, 38), "iPhone · recipient · local Ed25519 key", font=font, fill="white")
    draw.text((960, 978), caption, font=font, fill="white", anchor="mt")
    draw.text((960, 1028), "Native recordings · stage-aligned cuts, not latency evidence · iOS manual QR fallback + emulator port bridge",
              font=foot, fill="#bdc4ce", anchor="mt")
    layer.save(overlay)
    android_filter = "crop=1320:1400:620:60,scale=-2:840,pad=930:840:(ow-iw)/2:0:white"
    if yielded:
        android_filter = "scale=930:-2,pad=930:840:0:0:white"
    graph = (f"[0:v]{android_filter},setsar=1,setpts=PTS-STARTPTS,fps=30,tpad=stop_mode=clone:stop_duration={duration}[a];"
             f"[1:v]scale=-2:840,pad=930:840:(ow-iw)/2:0:0x15171b,setsar=1,setpts=PTS-STARTPTS,fps=30,tpad=stop_mode=clone:stop_duration={duration}[i];"
             "[a][i]hstack,pad=1920:1080:30:105:0x15171b[b];[b][2:v]overlay=0:0")
    target = out / f"reverse-segment-{index}.mp4"
    ffmpeg("-ss", android, "-i", source / f"android-part{part}.mp4", "-ss", ios, "-i", source / "ios-raw.mov",
           "-loop", 1, "-i", overlay, "-filter_complex", graph, "-t", duration, "-an", "-c:v", "libx264",
           "-preset", "fast", "-crf", 20, "-pix_fmt", "yuv420p", target)
    paths.append(target)
    ffmpeg("-ss", duration / 2, "-i", target, "-frames:v", 1, out / f"reverse-stage-{index}.png")
concat = out / "all-segments.txt"
concat.write_text("".join(f"file '{p}'\n" for p in [forward, *paths]))
ffmpeg("-f", "concat", "-safe", 0, "-i", concat, "-c", "copy", "-movflags", "+faststart", out / "private-key-sync-both-directions.mp4")
(out / "reverse-edit-decision-list.json").write_text(json.dumps(segments, indent=2) + "\n")
