#!/usr/bin/env python3
"""Edit captured camera bootstrap evidence; no reconstructed application screens."""
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

# Seconds in the original captures. The primary camera recording starts about
# seven seconds after the iPad recording. Later receipt footage is a second
# Android recording (the emulator recorder is limited to three minutes).
# Cuts are editorial, not frame-exact protocol timing evidence.
segments = [
    ("Open the native camera scanner", 34, 27, 6, 1, "android-fresh-camera.mp4"),
    ("Camera decodes the displayed QR - 4x slow motion", 40, 34, 2, 0.25, "android-fresh-camera.mp4"),
    ("Compare the same six digits on both devices", 67, 60, 18, 1.5, "android-fresh-camera.mp4"),
    ("Choose which hosts to copy", 92, 85, 16, 1, "android-fresh-camera.mp4"),
    ("Choose optional data - all off by default", 120, 113, 16, 1, "android-fresh-camera.mp4"),
    ("Review and approve the selected setup", 168, 161, 14, 1, "android-fresh-camera.mp4"),
    ("Receiver reviews, imports, and gets an honest receipt", 222, 0, 20, 1, "android-camera-receipt.mp4"),
]
paths = []
for index, (caption, ios_start, android_start, duration, speed, android) in enumerate(segments):
    overlay = Image.new("RGBA", (1920, 1080))
    draw = ImageDraw.Draw(overlay)
    title = ImageFont.truetype(font, 30)
    small = ImageFont.truetype(font, 20)
    draw.text((58, 42), "iPad - sender", font=title, fill="white")
    draw.text((990, 42), "Android - receiver", font=title, fill="white")
    draw.text((960, 984), caption, font=title, fill="white", anchor="mt")
    draw.text((960, 1034), "Real captures, cropped; pauses cut. Emulator image-file camera. Fixture grants skipped; no live handoff.",
              font=small, fill="#b9bcc2", anchor="mt")
    overlay_path = out / f"camera-titles-{index}.png"
    overlay.save(overlay_path)
    # This iPad capture is actually portrait, unlike the older landscape
    # framebuffer. Crop only empty margins around the complete pairing card.
    graph = (
        f"[0:v]fps=30,trim=start={ios_start}:duration={duration},crop=1260:1840:402:100,scale=-2:840,setsar=1,setpts=(PTS-STARTPTS)/{speed},fps=30,pad=930:840:(ow-iw)/2:0:black[l];"
        f"[1:v]fps=30,trim=start={android_start}:duration={duration},crop=1320:1320:620:80,scale=-2:840,setsar=1,setpts=(PTS-STARTPTS)/{speed},fps=30,pad=930:840:(ow-iw)/2:0:0xf7f7fa[r];"
        "[l][r]hstack,pad=1920:1080:30:110:0x15171b[body];[body][2:v]overlay=0:0"
    )
    path = out / f"camera-segment-{index}.mp4"
    run("-i", root / "ios-fresh-camera.mp4", "-i", root / android,
        "-loop", "1", "-i", overlay_path, "-filter_complex", graph,
        "-t", duration / speed, "-an", "-c:v", "libx264", "-preset", "fast", "-crf", "20",
        "-pix_fmt", "yuv420p", path)
    paths.append(path)
concat = out / "camera-segments.txt"
concat.write_text("".join(f"file '{p}'\n" for p in paths))
video = root / "qr-camera-two-device.mp4"
run("-f", "concat", "-safe", "0", "-i", concat, "-c", "copy", "-movflags", "+faststart", video)
preview = out / "camera-video-contact-sheet.jpg"
run("-i", video, "-vf", "fps=1/12,scale=960:-1,tile=3x3", "-frames:v", "1", preview)
scan = out / "android-camera-preview.png"
run("-i", root / "android-fresh-camera.mp4", "-vf", "fps=30,select=eq(n\\,1040)", "-frames:v", "1", scan)
hosts = out / "ios-host-review.png"
run("-i", root / "ios-fresh-camera.mp4", "-vf", "fps=30,select=eq(n\\,4920)", "-frames:v", "1", hosts)
cases = [
    {"id": "QR-camera-dialog", "invariants": ["Complete QR and all finder patterns visible in the native camera preview", "Heading, guidance and cancel action are visible and unclipped"], "artifacts": [str(scan)], "scope": "Actual Android CameraX preview of the iPad QR via emulator image-file camera; not a physical lens."},
    {"id": "QR-camera-selection-receipts", "invariants": ["Sender review lists Development, Build server and Staging, without Archive", "Optional categories are readable and off", "Both receipts distinguish copied setup from incomplete remote access"], "artifacts": [str(hosts), str(root / "ios-choose-data.png"), str(root / "ios-result.png"), str(root / "android-result-final.png")], "scope": "Actual portrait iPad and landscape Android captures. Public invalid fixture hosts intentionally skip all grants. Selection is established by the final review, not a frame of the earlier four-host default state."},
    {"id": "QR-camera-edited-video", "invariants": ["Both pairing surfaces and meaningful controls fit", "Device labels and captions readable", "Image-file camera and non-live fixture limits disclosed"], "artifacts": [str(preview)], "scope": "Edited recordings, no synthesized app screens. Operator pauses omitted; not protocol timing evidence."},
]
(out / "aggregate-manifest.json").write_text(json.dumps({"cases": cases}, indent=2) + "\n")
(out / "image-list.txt").write_text("".join(f"{p}\n" for p in dict.fromkeys(p for case in cases for p in case["artifacts"])))
