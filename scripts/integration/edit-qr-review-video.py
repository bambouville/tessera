#!/usr/bin/env python3
"""Edit real two-device QR review captures; never synthesizes app screens."""
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

# Cuts omit operator pauses. The last two segments explicitly use still
# captures where Android's three-minute recorder ended before the receipt.
segments = [
    ("QR offer and manual-entry fallback", 0, 12, "android-delivery.mp4", 0, False),
    ("Compare the same six digits on both devices", 96, 24, "android-delivery.mp4", 85, False),
    ("Choose which hosts to copy", 123, 31, "android-delivery.mp4", 112, False),
    ("Choose optional data - off by default", 155, 23, "android-delivery.mp4", 144, False),
    ("Review before sending", 179, 18, "android-success-waiting.png", 0, True),
    ("Receiver reviews the three selected hosts", 200, 12, "android-delivery-import.png", 0, True),
    ("Clear results - fixture grants intentionally skipped", 234, 8, "android-delivery-result.png", 0, True),
]
paths = []
for index, (caption, start, duration, android, android_start, still) in enumerate(segments):
    speed = 1 if index in (0, 5, 6) else 2
    args = (["-loop", "1", "-t", duration, "-i", root / "ios-delivery-result.png"] if index == 6 else
            ["-ss", start, "-t", duration, "-i", root / "ios-delivery.mp4"])
    if still:
        args += ["-loop", "1", "-t", duration, "-i", root / android]
    else:
        args += ["-ss", android_start, "-t", duration, "-i", root / android]
    overlay = Image.new("RGBA", (1920, 1080), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    title_font = ImageFont.truetype(font, 30)
    small_font = ImageFont.truetype(font, 20)
    draw.text((58, 45), "iPad - sender", font=title_font, fill="white")
    draw.text((990, 45), "Android - receiver", font=title_font, fill="white")
    draw.text((960, 996), caption, font=title_font, fill="white", anchor="mt")
    disclosure = "Real device captures - cropped; pauses shortened. Public fixture; no remote access."
    if still:
        disclosure = "Receiver shown as a captured still. Public fixture; no remote access."
    if index == 6:
        disclosure = "Both receipts shown as captured stills. Fixture remote grants intentionally skipped."
    draw.text((960, 1043), disclosure, font=small_font, fill="#aaaaaa", anchor="mt")
    overlay_path = out / f"titles-{index}.png"
    overlay.save(overlay_path)
    args += ["-loop", "1", "-i", overlay_path]
    # iOS Simulator stores a portrait framebuffer with landscape content.
    android_frame = ("scale=930:-2,pad=930:860:0:(oh-ih)/2:0xf7f7fa" if index == 0 else
                     "crop=1360:1320:600:140,scale=-2:860,pad=930:860:(ow-iw)/2:0:0xf7f7fa")
    graph = (
        f"[0:v]transpose=1,crop=1360:1760:696:40,scale=-2:860,setsar=1,setpts=(PTS-STARTPTS)/{speed},fps=30,pad=930:860:(ow-iw)/2:0:black[l];"
        f"[1:v]{android_frame},setsar=1,setpts=(PTS-STARTPTS)/{speed},fps=30[r];"
        "[l][r]hstack,pad=1920:1080:30:110:0x15171b[body];[body][2:v]overlay=0:0"
    )
    path = out / f"segment-{index}.mp4"
    run(*args, "-filter_complex", graph, "-t", duration / speed, "-an", "-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", path)
    paths.append(path)

concat = out / "video-segments.txt"
concat.write_text("".join(f"file '{path}'\n" for path in paths))
run("-f", "concat", "-safe", "0", "-i", concat, "-c", "copy", "-movflags", "+faststart", root / "qr-bootstrap-two-device.mp4")

images = []
for name in ["ios-success-hosts", "ios-success-include", "ios-delivery-result", "ios-success-waiting"]:
    path = out / f"{name}.png"
    run("-i", root / f"{name}.png", "-vf", "transpose=1,scale=1650:-1", "-frames:v", "1", path)
    images.append(path)
for name in ["android-success-waiting", "android-delivery-sas", "android-delivery-import", "android-delivery-result"]:
    path = out / f"{name}.png"
    run("-i", root / f"{name}.png", "-vf", "scale=1650:-1", "-frames:v", "1", path)
    images.append(path)
preview = out / "edited-video-contact-sheet.png"
run("-i", root / "qr-bootstrap-two-device.mp4", "-vf", "fps=1/12,scale=960:-1,tile=2x3", "-frames:v", "1", preview)
images.append(preview)
(out / "image-list.txt").write_text("".join(f"{p}\n" for p in images))
(out / "aggregate-manifest.json").write_text(json.dumps({"cases": [
    {"id": "QR-guided-bootstrap", "invariants": ["Three selected host rows; Archive visibly unselected", "All optional-data categories readable and off by default", "No clipped controls or illegible primary copy"], "artifacts": [str(p) for p in images[:2]], "scope": "Real iPad production pairing UI with .invalid public-only fixture. Landscape normalized."},
    {"id": "QR-receiver-guidance", "invariants": ["Security code fits one line", "Waiting guidance directs selection to sender", "Recipient checklist contains Development, Build server, Staging but not Archive"], "artifacts": [str(p) for p in images[4:7]], "scope": "Real Android emulator UI. Not physical camera proof."},
    {"id": "QR-partial-receipt", "invariants": ["iPad says setup copied and access still needed, not ready", "Android clearly distinguishes copied metadata from incomplete access", "No success claim for unverified grants"], "artifacts": [str(images[2]), str(images[7])], "scope": "Fixture intentionally skips all remote grants; partial outcome is expected."},
    {"id": "QR-edited-video", "invariants": ["Sender and receiver labels and explanatory captions are readable", "Both pairing surfaces are visible without cropping meaningful controls", "Fixture and edit boundaries disclosed"], "artifacts": [str(preview)], "scope": "Edited two-device bootstrap evidence only. Does not prove remote continuation or physical camera scanning."}
]}, indent=2) + "\n")
