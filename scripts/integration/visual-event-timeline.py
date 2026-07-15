#!/usr/bin/env python3
"""Map XCUITest visual event epochs onto a simctl recording timeline."""

from __future__ import annotations

import argparse
import json
import pathlib
import re


EVENT = re.compile(r"TESSERA_VISUAL_EVENT ([^ ]+) epoch=([0-9.]+)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("recording_start", type=pathlib.Path)
    parser.add_argument("xctest_log", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument(
        "--required",
        action="append",
        help="event name required in the log (repeatable); defaults to F12 events",
    )
    args = parser.parse_args()

    recording_start = float(args.recording_start.read_text().strip())
    offsets: dict[str, float] = {}
    for match in EVENT.finditer(args.xctest_log.read_text(errors="replace")):
        offsets[match.group(1)] = max(0.0, float(match.group(2)) - recording_start)

    required = set(args.required or [
        "before-long-press",
        "menu-presented",
        "menu-dismissed",
        "post-dismiss-settled",
    ])
    missing = sorted(required - offsets.keys())
    if missing:
        raise SystemExit(f"missing visual events: {', '.join(missing)}")

    args.output.write_text(json.dumps(offsets, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
