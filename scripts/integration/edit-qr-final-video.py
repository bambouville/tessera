#!/usr/bin/env python3
"""Edit final image-file-camera, live-VPS QR continuation evidence."""
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

# iOS derivative starts at 22:09:20 UTC, CFR 15. Its earlier clockwise
# transpose is corrected here with a half-turn. Android clips are actual
# sequential screenrecord parts. Cuts align workflow stages, not latency.
segments = [
    ("Scan the iPad QR with Android's camera", 65, "android-part4.mp4", 0, 8, 1, "pair"),
    ("Compare the same six digits: 590465", 95, "android-part4.mp4", 5, 12, 1, "pair"),
    ("Choose the host, then opt in to trusted host keys", 148.5, "android-part4.mp4", 65, 18, 1/3, "pair"),
    ("Review the exact selection and approve transfer", 223, "android-part4.mp4", 141, 18, 1, "pair"),
    ("Android reviews the approved host before importing", 287, "android-part5.mp4", 12, 20, 1, "pair"),
    ("Enter the password locally on Android; it was not transferred", 342, "android-part5.mp4", 66, 12, 1, "pair"),
    ("Android resumes the same shell: PID 222561", 354, "android-part5.mp4", 78, 12, 1, "receipt"),
    ("Setup complete; password-on-first-connect is reported correctly", 385, "android-part5.mp4", 110, 10, 1, "receipt"),
    ("Automatic handoff: iPad yields; Android executes QR_FINAL_OK", 422, "android-part5.mp4", 147, 20, 1, "terminal"),
    ("The continued terminal is interactive; no extra takeover tap", 450, "android-terminal.mp4", 1, 14, 1, "terminal"),
]
paths = []
for index, (caption, ios_start, android_file, android_start, duration, speed, mode) in enumerate(segments):
    overlay = Image.new("RGBA", (1920, 1080))
    draw = ImageDraw.Draw(overlay)
    title = ImageFont.truetype(font, 28)
    small = ImageFont.truetype(font, 20)
    draw.text((58, 42), "iPad · source", font=title, fill="white")
    draw.text((990, 42), "Android · recipient", font=title, fill="white")
    draw.text((960, 982), caption, font=title, fill="white", anchor="mt")
    foot = "Stage-aligned, pauses cut; not timing evidence · emulator image-file camera · live SSH + tmux"
    if speed != 1:
        foot = "iPad selection slowed to one-third speed for readability; Android plays at normal speed."
    draw.text((960, 1030), foot, font=small, fill="#b9bcc2", anchor="mt")
    title_path = out / f"final-title-{index}.png"
    overlay.save(title_path)
    left = "crop=640:940:365:0,scale=-2:840,pad=930:840:(ow-iw)/2:0:white"
    right = "crop=1320:1320:620:80,scale=-2:840,pad=930:840:(ow-iw)/2:0:0xf7f7fa"
    if mode == "terminal":
        left = "crop=720:720:328:156,scale=840:840,pad=930:840:45:0:0x15171b"
    if mode in ("terminal", "receipt"):
        right = "crop=1700:1500:0:0,scale=930:820,pad=930:840:0:0:black"
    graph = (
        f"[0:v]hflip,vflip,{left},setsar=1,setpts=(PTS-STARTPTS)/{speed},fps=30[l];"
        f"[1:v]fps=30,trim=start={android_start}:duration={duration},{right},setsar=1,setpts=PTS-STARTPTS[r];"
        "[l][r]hstack,pad=1920:1080:30:110:0x15171b[body];[body][2:v]overlay=0:0"
    )
    path = out / f"final-segment-{index}.mp4"
    run("-ss", ios_start, "-i", root / "ios-final-window.mp4",
        "-i", root / android_file, "-loop", "1", "-i", title_path,
        "-filter_complex", graph, "-t", duration, "-an", "-c:v", "libx264",
        "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", path)
    paths.append(path)
concat = out / "final-segments.txt"
concat.write_text("".join(f"file '{p}'\n" for p in paths))
video = root / "qr-final-two-device.mp4"
run("-f", "concat", "-safe", "0", "-i", concat, "-c", "copy", "-movflags", "+faststart", video)
preview = out / "final-video-contact-sheet.jpg"
sheet = Image.new("RGB", (2880, 2160), "#15171b")
for index, path in enumerate(paths):
    frame = out / f"final-stage-{index}.png"
    run("-ss", segments[index][4] / 2, "-i", path, "-vf", "scale=960:540", "-frames:v", "1", frame)
    with Image.open(frame) as capture:
        sheet.paste(capture, ((index % 3) * 960, (index // 3) * 540))
sheet.save(preview, quality=95)
receipt = out / "ios-receipt-detail.png"
peer = out / "ios-peer-detail.png"
run("-ss", 385, "-i", root / "ios-final-window.mp4", "-vf", "hflip,vflip,crop=640:800:365:0", "-frames:v", "1", receipt)
run("-ss", 450, "-i", root / "ios-final-window.mp4", "-vf", "hflip,vflip,crop=720:720:328:156", "-frames:v", "1", peer)
cases = [
    {"id": "QR-final-edited-flow", "invariants": ["All device captures upright", "Captions and device labels readable", "Pairing cards and actions not clipped", "Matching SAS 590465 on both devices", "Host and optional-data selection visible", "Recipient review and local password prompt visible", "Receipt reports password on first connect, not a failed grant"], "artifacts": [str(preview), str(receipt)], "scope": "Real latest-build captures. Cropped and stage-aligned; operator pauses removed. iPad selection only slowed 3x and disclosed. Not protocol latency evidence. Full-resolution receipt supplied because contact-sheet text is small."},
    {"id": "QR-final-live-control", "invariants": ["Android shows shell PID 222561 before marker input", "Android shows echo QR_FINAL_OK and its returned output", "iPad shows continued on another device"], "artifacts": [str(root / "android-auto-takeover.png"), str(root / "android-marker-full.png"), str(peer), str(preview)], "scope": "Actual camera scan and authenticated VPS SSH+tmux continuation. No Android Take Back Control action was used. Source diagnostics independently record Android-Tablet authority. Full-resolution source status supplied for legibility."},
]
(out / "aggregate-manifest.json").write_text(json.dumps({"cases": cases}, indent=2) + "\n")
(out / "image-list.txt").write_text("".join(f"{p}\n" for p in dict.fromkeys(p for c in cases for p in c["artifacts"])))
