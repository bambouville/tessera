#!/usr/bin/env python3
"""Join deterministic and one-shot Codex review results into one run report."""

from __future__ import annotations

import argparse
import json
import pathlib


def load(path: pathlib.Path):
    return json.loads(path.read_text(encoding="utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=pathlib.Path)
    parser.add_argument("--ai-requested", action="store_true")
    parser.add_argument("--programmatic-exit", type=int, required=True)
    parser.add_argument("--ai-exit", type=int)
    args = parser.parse_args()

    run_dir = args.run_dir.resolve()
    deterministic_path = run_dir / "programmatic" / "results.json"
    deterministic = load(deterministic_path) if deterministic_path.exists() else []
    ai_path = run_dir / "visual" / "codex-review.json"
    ai = load(ai_path) if ai_path.exists() else None

    report = {
        "format": "tessera-integration-report-v1",
        "run_id": run_dir.name,
        "deterministic": {
            "exit_code": args.programmatic_exit,
            "cases": deterministic,
        },
        "ai_visual": {
            "requested": args.ai_requested,
            "exit_code": args.ai_exit,
            "review": ai,
        },
    }
    report_path = run_dir / "report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    deterministic_failures = [
        case["id"] for case in deterministic if case["verdict"] != "pass"
    ]
    visual_failures = []
    visual_inconclusive = []
    if ai:
        visual_failures = [
            case["id"] for case in ai["cases"] if case["verdict"] == "fail"
        ]
        visual_inconclusive = [
            case["id"] for case in ai["cases"] if case["verdict"] == "inconclusive"
        ]

    print(f"report: {report_path}")
    print(f"deterministic failures: {deterministic_failures or 'none'}")
    if args.ai_requested:
        if ai is None:
            print(f"AI visual review unavailable: exit_code={args.ai_exit}")
        else:
            print(f"AI visual failures: {visual_failures or 'none'}")
            print(f"AI visual inconclusive: {visual_inconclusive or 'none'}")

    if args.programmatic_exit != 0:
        return 1
    if args.ai_requested and (args.ai_exit != 0 or visual_failures or visual_inconclusive):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
