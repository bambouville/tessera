#!/usr/bin/env python3
"""Edit real QR/VPS captures; captions disclose cuts and post-capture fixes."""
import json
from pathlib import Path
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFont

root = Path(sys.argv[1]).resolve()
out = root / "visual"
out.mkdir(exist_ok=True)
font = "/System/Library/Fonts/Supplemental/Arial.ttf"

def run(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True)

# ios-final-window is a CFR, clockwise-rotated 1376x1032 derivative of
# ios-live, starting at original second 2780. Android timestamps are local
# to each recorder part. Editorial cuts do not establish protocol latency.
segments = [
    ("Scan the iPad QR with Android's native camera", 136, 83, 10, 8, False),
    ("Verify the same six-digit code on both devices", 155, 102, 10, 8, False),
    ("Choose which hosts to copy", 207, 154, 12, 8, False),
    ("Choose optional data; passwords and private keys are never copied", 235, 4, 10, 9, False),
    ("Review and approve the selected setup", 270, 10, 12, 9, False),
    ("Android reviews and imports the approved host", 315, 56, 18, 9, False),
    ("Enter the fixture password locally on Android", 350, 91, 14, 9, False),
    ("Live-run gap: Android needed one extra Take Back Control action", 365, 118, 7, 9, False),
    ("Same shell PID 187204; Android executes echo QR_LIVE_OK", 5, 6, 25, 10, True),
]
paths = []
for index, (caption, ios_start, android_start, duration, part, terminal) in enumerate(segments):
    overlay = Image.new("RGBA", (1920, 1080))
    draw = ImageDraw.Draw(overlay)
    title = ImageFont.truetype(font, 30)
    small = ImageFont.truetype(font, 20)
    draw.text((58, 42), "iPad - source" + (" (before handoff)" if terminal else ""), font=title, fill="white")
    draw.text((990, 42), "Android - recipient" + (" (after handoff)" if terminal else ""), font=title, fill="white")
    draw.text((960, 984), caption, font=title, fill="white", anchor="mt")
    foot = "Real captures, cropped; pauses cut. Emulator image-file camera; live SSH + tmux VPS."
    if index >= 7:
        foot = "Receipt wording and automatic QR control takeover were refined after this recording; final live recheck is pending."
    draw.text((960, 1034), foot, font=small, fill="#b9bcc2", anchor="mt")
    overlay_path = out / f"live-titles-{index}.png"
    overlay.save(overlay_path)
    left = "crop=900:810:0:0,scale=930:837,pad=930:840:0:0:black" if terminal else "crop=640:940:365:0,scale=-2:840,pad=930:840:(ow-iw)/2:0:white"
    right = "crop=1700:1500:0:0,scale=930:820,pad=930:840:0:0:black" if terminal else "crop=1320:1320:620:80,scale=-2:840,pad=930:840:(ow-iw)/2:0:0xf7f7fa"
    # Only the already-normalized iPad derivative uses input seeking.
    graph = (
        f"[0:v]{left},setsar=1,setpts=PTS-STARTPTS,fps=30[l];"
        f"[1:v]fps=30,trim=start={android_start}:duration={duration},{right},setsar=1,setpts=PTS-STARTPTS[r];"
        "[l][r]hstack,pad=1920:1080:30:110:0x15171b[body];[body][2:v]overlay=0:0"
    )
    path = out / f"live-segment-{index}.mp4"
    run("-ss", ios_start, "-i", root / "ios-final-window.mp4",
        "-i", root / f"android-part{part}.mp4", "-loop", "1", "-i", overlay_path,
        "-filter_complex", graph, "-t", duration, "-an", "-c:v", "libx264",
        "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", path)
    paths.append(path)
concat = out / "live-segments.txt"
concat.write_text("".join(f"file '{p}'\n" for p in paths))
video = root / "qr-live-two-device.mp4"
run("-f", "concat", "-safe", "0", "-i", concat, "-c", "copy", "-movflags", "+faststart", video)
preview = out / "live-video-contact-sheet.jpg"
run("-i", video, "-vf", "fps=1/14,scale=960:-1,tile=3x3", "-frames:v", "1", preview)
cases = [
    {"id": "QR-live-edited-evidence", "invariants": ["Device labels and captions readable", "Pairing cards fit without clipping their actions", "Same SAS 910695 appears on both devices", "Captions disclose post-recording fixes and before/after terminal comparison"], "artifacts": [str(preview)], "scope": "Edited real iPad and Android recordings; real CameraX image-file camera and live VPS SSH+tmux. Cropped views and operator pauses removed, not latency evidence. Automatic takeover and revised password receipt were implemented after this recording and are NOT claimed live-verified."},
    {"id": "QR-live-terminal-proof", "invariants": ["Android shows shell PID 187204", "Android shows echo QR_LIVE_OK and the returned QR_LIVE_OK output"], "artifacts": [str(root / "android-marker-proof.png")], "scope": "Actual Android framebuffer after manually accepting native Take Back Control. Earlier ho command-not-found was an operator input-focus attempt and remains visible, not edited out."},
]
(out / "aggregate-manifest.json").write_text(json.dumps({"cases": cases}, indent=2) + "\n")
(out / "image-list.txt").write_text("".join(f"{p}\n" for p in dict.fromkeys(p for case in cases for p in case["artifacts"])))
