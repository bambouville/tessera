#!/usr/bin/env python3
"""Compress ffmpeg signalstats to a complete, model-friendly frame series."""

from __future__ import annotations

import argparse
import json
import pathlib
import re


FRAME = re.compile(r"^frame:(\d+)\s+pts:.*pts_time:([0-9.\-]+)")
VALUE = re.compile(r"^lavfi\.signalstats\.(YAVG|YDIF|SATAVG)=([0-9.\-]+)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()

    frames = []
    current = None
    for line in args.source.read_text(encoding="utf-8").splitlines():
        if match := FRAME.match(line):
            current = {"frame": int(match.group(1)), "time": float(match.group(2))}
            frames.append(current)
        elif current is not None and (match := VALUE.match(line)):
            current[match.group(1).lower()] = float(match.group(2))

    yavg = [frame["yavg"] for frame in frames if "yavg" in frame]
    ydif = [frame["ydif"] for frame in frames if "ydif" in frame]
    summary = {
        "format": "tessera-signalstats-summary-v1",
        "frame_count": len(frames),
        "yavg_min": min(yavg) if yavg else None,
        "yavg_max": max(yavg) if yavg else None,
        "ydif_max": max(ydif) if ydif else None,
        "frames": frames,
    }
    args.destination.write_text(
        json.dumps(summary, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
