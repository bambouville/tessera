#!/usr/bin/env python3
"""Build one complete manifest for the single aggregate Codex review."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import struct
from typing import Any


IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}
INLINE_TEXT_SUFFIXES = {".json", ".csv", ".txt", ".log"}
MAX_INLINE_TEXT_BYTES = 128 * 1024


def digest(path: pathlib.Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def artifact(root: pathlib.Path, path: pathlib.Path) -> dict[str, Any]:
    relative = path.relative_to(root).as_posix()
    result: dict[str, Any] = {
        "path": relative,
        "bytes": path.stat().st_size,
        "sha256": digest(path),
        "kind": "image" if path.suffix.lower() in IMAGE_SUFFIXES else "file",
    }
    if (
        path.suffix.lower() in INLINE_TEXT_SUFFIXES
        and path.stat().st_size <= MAX_INLINE_TEXT_BYTES
    ):
        result["content"] = path.read_text(encoding="utf-8", errors="replace")
    if path.suffix.lower() == ".png":
        with path.open("rb") as stream:
            header = stream.read(24)
        if header[:8] == b"\x89PNG\r\n\x1a\n" and len(header) == 24:
            result["pixel_width"], result["pixel_height"] = struct.unpack(
                ">II", header[16:24]
            )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("visual_root", type=pathlib.Path)
    args = parser.parse_args()
    visual_root = args.visual_root.resolve()
    case_root = visual_root / "cases"
    if not case_root.is_dir():
        raise SystemExit(f"missing visual case directory: {case_root}")

    cases: list[dict[str, Any]] = []
    image_paths: list[str] = []
    for directory in sorted(path for path in case_root.iterdir() if path.is_dir()):
        definition_path = directory / "case.json"
        if not definition_path.is_file():
            raise SystemExit(f"missing case.json: {directory}")
        definition = json.loads(definition_path.read_text(encoding="utf-8"))
        if definition.get("id") != directory.name:
            raise SystemExit(f"case id/path mismatch: {directory}")

        artifacts = []
        for path in sorted(directory.rglob("*")):
            if not path.is_file() or path == definition_path:
                continue
            item = artifact(visual_root, path)
            artifacts.append(item)
            if item["kind"] == "image":
                image_paths.append(str(path.resolve()))

        cases.append({
            "id": definition["id"],
            "title": definition["title"],
            "matrix_ids": definition.get("matrix_ids", []),
            "invariants": definition["invariants"],
            "capture_notes": definition.get("capture_notes", ""),
            "deterministic_precheck": definition.get(
                "deterministic_precheck", {"verdict": "not-run"}
            ),
            "artifacts": artifacts,
        })

    if not cases:
        raise SystemExit("no visual cases were captured")
    if not image_paths:
        raise SystemExit("visual cases contain no image evidence")

    manifest = {
        "format": "tessera-aggregate-visual-evidence-v1",
        "case_count": len(cases),
        "image_count": len(image_paths),
        "cases": cases,
    }
    manifest_path = visual_root / "aggregate-manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    image_list_path = visual_root / "image-list.txt"
    image_list_path.write_text("\n".join(image_paths) + "\n", encoding="utf-8")
    print(manifest_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
