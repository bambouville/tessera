#!/usr/bin/env python3
"""Edit the successful generated-key run; native pixels only, no UI mockups.

Usage: edit-setup-key-video.py qa/unified-key-20260911/retry OUTPUT
Cuts align stages, not wall-clock latency. Selected clips play at 40% speed.
"""
from pathlib import Path
import json
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFont

source, out = map(lambda p: Path(p).resolve(), sys.argv[1:3])
out.mkdir(parents=True, exist_ok=True)
font = "/System/Library/Fonts/Supplemental/Arial.ttf"
segments = [
    ("Android camera decodes the QR displayed by iPad", 235, 1, 77, 15, 1, "pair"),
    ("Compare all six digits on both screens: 488018", 250, 1, 96, 10, 1, "pair"),
    ("Choose hosts and optional data; private keys stay local", 283.2, 1, 128, 20, .4, "pair"),
    ("Review Android's new public key, then approve", 294, 1, 151, 20, 1, "pair"),
    ("Android reviews the approved host before importing", 347, 2, 16, 8, .4, "pair"),
    ("Setup copied; wait for public-key installation and verification", 350, 2, 22, 16, 1, "pair"),
    ("Verified key access; Android resumes the same shell (PID 399448)", 375, 2, 48, 16, 1, "receipt"),
    ("iPad yields; Android runs echo QR_UNIFIED_KEY_OK", 430, 2, 100, 20, 1, "terminal"),
]

def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True)

paths = []
for index, (caption, ios, part, android, duration, speed, mode) in enumerate(segments):
    layer = Image.new("RGBA", (1920, 1080))
    draw = ImageDraw.Draw(layer)
    title, foot = ImageFont.truetype(font, 27), ImageFont.truetype(font, 19)
    draw.text((55, 38), "iPad · sender · local Ed25519 key", font=title, fill="white")
    draw.text((995, 38), "Android · recipient · new P-256 key", font=title, fill="white")
    draw.text((960, 978), caption, font=title, fill="white", anchor="mt")
    note = "Native recordings · stage-aligned cuts; not latency evidence · image-file camera · live VPS SSH + tmux"
    if speed != 1:
        note = "iPad selection slowed to 40% speed for readability; Android plays at normal speed."
    draw.text((960, 1028), note, font=foot, fill="#bdc4ce", anchor="mt")
    overlay = out / f"title-{index}.png"
    layer.save(overlay)
    left = "transpose=2,crop=1320:1750:716:0,scale=-2:840,pad=930:840:(ow-iw)/2:0:white"
    if index == 2:
        left = "transpose=2,crop=1320:2000:716:0,scale=-2:840,pad=930:840:(ow-iw)/2:0:white"
    right = "crop=1320:1320:620:80,scale=840:840,pad=930:840:45:0:0xf5f8f8"
    if mode in ("receipt", "terminal"):
        right = "crop=1900:1500:0:0,scale=930:-2,pad=930:840:0:0:black"
    if mode == "terminal":
        left = "transpose=2,crop=1400:1200:676:450,scale=930:-2,pad=930:840:0:0:0x25282c"
    right_speed = .4 if index == 4 else 1
    if index == 4:
        draw.rectangle((0, 1020, 1920, 1080), fill=(0, 0, 0, 0))
        draw.text((960, 1028), "Both approval clips slowed to 40% speed for readability; pauses cut.", font=foot, fill="#bdc4ce", anchor="mt")
        layer.save(overlay)
    graph = (f"[0:v]{left},setsar=1,setpts=(PTS-STARTPTS)/{speed},fps=30[l];"
             f"[1:v]{right},setsar=1,setpts=(PTS-STARTPTS)/{right_speed},fps=30[r];"
             "[l][r]hstack,pad=1920:1080:30:105:0x15171b[body];[body][2:v]overlay=0:0")
    target = out / f"segment-{index}.mp4"
    ffmpeg("-ss", ios, "-i", source / "ios-raw.mov", "-ss", android, "-i", source / f"android-part{part}.mp4",
           "-loop", 1, "-i", overlay, "-filter_complex", graph, "-t", duration,
           "-an", "-c:v", "libx264", "-preset", "fast", "-crf", 20, "-pix_fmt", "yuv420p", target)
    paths.append(target)
concat = out / "segments.txt"
concat.write_text("".join(f"file '{p}'\n" for p in paths))
ffmpeg("-f", "concat", "-safe", 0, "-i", concat, "-c", "copy", "-movflags", "+faststart", out / "private-key-bootstrap-and-continuation.mp4")
sheet = Image.new("RGB", (1920, 2160), "#15171b")
for index, path in enumerate(paths):
    frame = out / f"stage-{index}.png"
    ffmpeg("-ss", segments[index][4] / 2, "-i", path, "-vf", "scale=960:540", "-frames:v", 1, frame)
    with Image.open(frame) as capture:
        sheet.paste(capture, ((index % 2) * 960, (index // 2) * 540))
sheet.save(out / "video-contact-sheet.jpg", quality=95)
(out / "edit-decision-list.json").write_text(json.dumps(segments, indent=2) + "\n")
