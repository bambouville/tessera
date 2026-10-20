#!/usr/bin/env python3
"""Exact-label native taps for an explicitly owned QR review emulator.

Reads the current hierarchy before every tap; never guesses screen positions.
Pass run directory followed by labels in order. No arguments just inspects.
"""
import os
from pathlib import Path
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import re

out = Path(sys.argv[1])
serial = (out / "android-serial").read_text().strip()
if serial != "emulator-5580":
    raise SystemExit("not the scoped QR review emulator")
adb = os.environ.get("ANDROID_SDK_ROOT", "/opt/homebrew/share/android-commandlinetools") + "/platform-tools/adb"

def command(*args):
    return subprocess.check_output([adb, "-s", serial, *args], text=True, timeout=25)

def hierarchy():
    for attempt in range(3):
        path = f"/data/local/tmp/qr-step-{os.getpid()}-{time.monotonic_ns()}.xml"
        result = command("shell", "uiautomator", "dump", path)
        if "dumped to:" in result:
            return ET.fromstring(command("shell", "cat", path))
        time.sleep(0.3)
    raise SystemExit("native hierarchy unavailable; no stale XML was used")

for label in sys.argv[2:]:
    deadline = time.monotonic() + 12
    while True:
        tree = hierarchy()
        matches = [node for node in tree.iter("node")
                   if label in (node.get("text"), node.get("content-desc"))
                   and node.get("enabled") == "true"]
        if matches:
            node = matches[0]
            parents = {child: parent for parent in tree.iter() for child in parent}
            # Compose setting labels are not tappable; their sibling native
            # Switch is. Resolve that current hierarchy relationship instead
            # of claiming a successful toggle after tapping inert text.
            candidate = node
            while candidate.get("clickable") != "true" and candidate in parents:
                candidate = parents[candidate]
                switches = [child for child in candidate.iter("node") if child.get("checkable") == "true"]
                if len(switches) == 1:
                    candidate = switches[0]
                    break
                if len(switches) > 1:
                    # Compose may omit non-semantic Row nodes. In that case
                    # require one Switch aligned with this label's row, to its
                    # right, not any checkbox in the whole screen.
                    bounds = list(map(int, re.findall(r"\d+", node.get("bounds"))))
                    aligned = []
                    for switch in switches:
                        box = list(map(int, re.findall(r"\d+", switch.get("bounds"))))
                        if box[0] >= bounds[2] and abs((box[1]+box[3]-bounds[1]-bounds[3])/2) < 160:
                            aligned.append(switch)
                    if len(aligned) != 1:
                        raise SystemExit("ambiguous non-interactive label: " + label)
                    candidate = aligned[0]
                    break
            if candidate.get("clickable") != "true":
                raise SystemExit("label has no native action: " + label)
            node = candidate
            package = node.get("package", "")
            if package not in ("com.bambouville.tessera.debug", "com.android.permissioncontroller"):
                raise SystemExit("target is outside the test app/permission dialog")
            x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
            command("shell", "input", "tap", str((x1+x2)//2), str((y1+y2)//2))
            print("Tapped:", label, flush=True)
            break
        if time.monotonic() >= deadline:
            raise SystemExit("missing visible control: " + label)
        time.sleep(0.2)

for node in hierarchy().iter("node"):
    if node.get("password") == "true":
        continue
    label = node.get("text") or node.get("content-desc")
    if label:
        print(label, node.get("bounds"))
