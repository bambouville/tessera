#!/usr/bin/env python3
"""Package native setup captures for the suite's single aggregate review."""
from pathlib import Path
import hashlib
import json
import math
import subprocess
import sys
from PIL import Image, ImageDraw, ImageFont

run = Path(sys.argv[1]).resolve()
visual = run / "visual"
qa = run.parent
out = visual / "review"
out.mkdir(parents=True, exist_ok=True)
cases, images = [], []
font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 19)

def attachments(folder, match):
    folder = visual / folder
    manifest = json.loads((folder / "manifest.json").read_text())
    return [(a["suggestedHumanReadableName"].split("_0_")[0], folder / a["exportedFileName"])
            for test in manifest for a in test["attachments"]
            if match in a["suggestedHumanReadableName"] and a["exportedFileName"].endswith(".png")]

def sheet(name, entries):
    assert entries, name
    canvas = Image.new("RGB", (1600, math.ceil(len(entries) / 3) * 430), "#e5e7eb")
    draw = ImageDraw.Draw(canvas)
    for index, (label, path) in enumerate(entries):
        with Image.open(path) as source:
            frame = source.convert("RGB")
            frame.thumbnail((520, 390))
            x, y = (index % 3) * 533, (index // 3) * 430
            canvas.paste(frame, (x + (520 - frame.width) // 2, y + 32))
            draw.text((x + 5, y + 6), label[:47], font=font, fill="black")
    target = out / (name + ".jpg")
    canvas.save(target, quality=95)
    return target

def add(identifier, invariants, entries, full=(), notes=""):
    evidence = [sheet(identifier, entries), *full]
    images.extend(evidence)
    cases.append({"id": identifier, "invariants": invariants, "notes": notes,
                  "images": [str(p) for p in evidence],
                  "originals": [{"label": label, "path": str(path)} for label, path in entries]})

for mode in ("nearby", "qr"):
    entries = [(idiom + " " + label, path) for idiom, folder in (
        ("iPhone", "phone-surfaces-final"), ("iPad landscape", "ipad-surfaces-final"))
        for label, path in attachments(folder, f"setup-{mode}-standard")]
    full = [p for label, p in entries if "review" in label or "receipt" in label]
    add("ios-" + mode, "Native verification, host/data/review, receipt and configure-later stay usable on compact iPhone and landscape iPad. Nearby zero grants still copies hosts; QR selection means hosts copied. Do not require identical consent semantics.", entries, full,
        "Host-free fixtures using production shared SwiftUI components; not network proof. Standard sizes. Vertical scrolling is expected.")

large = attachments("phone-surfaces-final", "setup-nearby-accessibility")
add("ios-large-text", "Compare the diagnostic before image with final verification: no mid-word stage label fragmentation after the fix. Current stage is readable; code and review actions remain reachable through scrolling.",
    [("BEFORE diagnostic", visual / "ios-large-before.png"), *large],
    [p for label, p in large if "verify" in label or "review" in label or "receipt" in label],
    "Accessibility3, compact iPhone. The BEFORE image is expected to contain the fixed bug; do not grade it as current UI. Harness scroll position can leave prior content above the viewport.")

android = visual / "android-surfaces"
native = [(p.stem, p) for p in sorted(android.glob("*.png")) if "large" not in p.stem]
add("android-native", "Native tablet and compact flow: clear code comparison, host/data/review navigation, explicit 1 grant and 1 optional category in tablet review; mismatch/retry actions and truthful per-host receipt.",
    native, [android / "tablet-review.png", android / "tablet-receipt.png", android / "compact-mismatch.png"],
    "Host-free production Compose components. Compact is a phone-sized viewport on the same owned tablet AVD, not a physical phone.")
add("android-large-text", "The final 1.6 font-scale compact progress/receipt shows one readable current-stage label, without the mid-word fragmentation in BEFORE. Authorized and password-on-first-connect remain distinct.",
    [("BEFORE diagnostic", visual / "android-large-before.png"), ("AFTER receipt", android / "compact-large-receipt.png"), ("AFTER progress", android / "compact-large-progress.png")],
    [android / "compact-large-receipt.png", android / "compact-large-progress.png"])

forward = qa / "unified-key-20260911" / "retry"
rotated = out / "forward-ios-receipt-landscape.png"
with Image.open(forward / "ios-receipt.png") as frame:
    frame.transpose(Image.Transpose.ROTATE_90).save(rotated)
add("live-ios-to-android", "Live native stages agree on SAS 488018. Review identifies recipient key, completed receipt says AUTHORIZED, Android shell has QR_UNIFIED_KEY_OK. Video stage cuts must be coherent; no claim of real-time latency or physical optics.",
    [(f"video stage {n}", visual / "key-video" / f"stage-{n}.png") for n in range(8)],
    [rotated, forward / "android-receipt.png", forward / "android-live-control-final.png"],
    "Actual CameraX image-file camera decoded native iPad QR pixels; real VPS key installation/authentication. Forward video precedes the final minor iOS progress-heading wording change and adaptive large-text headers.")
reverse = qa / "unified-reverse-20260911" / "fixed"
add("live-android-to-ios", "After the fix, native import proceeds to both AUTHORIZED receipts and iPhone shell QR_REVERSE_KEY_OK, PID 399448; Android yields. The before cancellation is diagnostic, not expected final behavior. Edited reverse stages must match their captions.",
    [(f"reverse video stage {n}", visual / "final-video" / f"reverse-stage-{n}.png") for n in range(5)],
    [reverse / "ios-receipt.png", reverse / "ios-live-control.png", reverse / "android-receipt.png", reverse / "android-yielded.png"],
    "Native Android QR decoded from displayed pixels, then native iOS manual entry; DEBUG simulator-only emulator port bridge. Actual generated iPhone key and live VPS grant/authentication. Source was Android's distinct generated key from the forward run.")

rejection = [(folder + " " + path.stem, path)
             for folder in ("bootstrap-network-rejection", "bootstrap-network-rejection-reversed")
             for path in sorted((run / "programmatic" / folder).glob("*.png"))]
add("nearby-rejection", "Untouched peer receives an explicit code-rejection alert and can return to a fresh verification attempt in both directions; preserve the acknowledgement action.", rejection,
    notes="Real Bonjour/encrypted channel harness; in-memory grant installer, not live SSH enrollment.")
keyboard = [(idiom + " " + label, path) for idiom, folder in (("iPad", "continuity-ipad"), ("iPhone", "continuity-phone"))
            for label, path in attachments(folder, "QR")]
add("qr-keyboard-and-offer", "On native iPad and iPhone, offer guidance/cancel remain visible and invalid manual entry remains usable with software keyboard; no clipped or inaccessible primary actions.", keyboard,
    [p for label, p in keyboard if "keyboard" in label], "Host-free production coordinator/scanner UI; keyboard test provides invalid input, not a fake successful transfer.")

video = visual / "final-video" / "private-key-sync-both-directions.mp4"
metadata = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "json", str(video)]))
manifest = {"cases": cases, "video": {"path": str(video), "sha256": hashlib.sha256(video.read_bytes()).hexdigest(), **metadata},
            "limitations": ["Native screenshots/contact sheets, not generated UI mockups.", "No physical Secure Enclave/StrongBox or optical-camera claim.", "VoiceOver/TalkBack spoken output and physical reduced-motion feel not established by screenshots.", "Judge only the stated invariants; raw logs establish authentication, not screenshots alone."]}
(visual / "aggregate-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
(visual / "image-list.txt").write_text("".join(str(p) + "\n" for p in dict.fromkeys(images)))
print(f"Prepared {len(cases)} cases and {len(set(images))} attached native evidence images")
