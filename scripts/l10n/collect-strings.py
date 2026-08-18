#!/usr/bin/env python3
"""Aggregate every localizable string Xcode extracted for the Tessera app target.

`xcodebuild` writes one .stringsdata per Swift file but never syncs them back
into the .xcstrings source file (only the Xcode IDE does that). Reading them
directly gives the authoritative corpus, with the source file and line for each
key so strings can be triaged by where they live.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

# Derived from this file rather than pinned to one checkout, so the corpus is
# read from whichever tree (main or a worktree) was just built.
ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "build/DD/Build/Intermediates.noindex/Tessera.build/Debug-iphonesimulator"
REPO = f"{ROOT}/"

# One arch is enough — the other is a byte-identical duplicate.
ARCH = "arm64"


def collect():
    keys = defaultdict(list)  # key -> [(relative source path, line)]
    for target in ("Tessera.build", "TesseraShareExtension.build"):
        root = BUILD / target / "Objects-normal" / ARCH
        if not root.is_dir():
            continue
        for path in sorted(root.glob("*.stringsdata")):
            try:
                data = json.loads(path.read_text())
            except (json.JSONDecodeError, OSError):
                continue
            source = data.get("source", "").replace(REPO, "")
            for table, entries in data.get("tables", {}).items():
                if table != "Localizable":
                    continue
                for entry in entries:
                    key = entry.get("key")
                    if key is None:
                        continue
                    line = entry.get("location", {}).get("startingLine", 0)
                    keys[key].append((source, line))
    return keys


def main():
    keys = collect()
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else None

    by_file = defaultdict(int)
    for sites in keys.values():
        for source, _ in sites:
            by_file[source] += 1

    print(f"=== distinct extracted keys: {len(keys)} ===\n")
    print("Top files by extracted-string count:")
    for source, count in sorted(by_file.items(), key=lambda kv: -kv[1])[:30]:
        print(f"  {count:4d}  {source}")

    if out:
        payload = {
            key: sorted({f"{s}:{l}" for s, l in sites})
            for key, sites in keys.items()
        }
        out.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
        print(f"\nwrote {out} ({len(payload)} keys)")


if __name__ == "__main__":
    main()
