#!/usr/bin/env python3
"""Summarize content-free JSON evidence; never read source conversations."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import statistics


def summarize(report):
    groups = defaultdict(list)
    errors = []
    for trial in report["results"]:
        if trial["status"] != "ok":
            errors.append({key: trial.get(key) for key in ("corpus", "mode", "status")})
            continue
        for row in trial["rows"]:
            if row.get("status", "ok") != "ok":
                errors.append({"corpus": trial["corpus"], "mode": trial["mode"], "status": row["status"]})
                continue
            groups[trial["corpus"], trial["mode"], row.get("phase", "receipt")].append(row)
    summary = []
    for (corpus, mode, phase), rows in groups.items():
        times = [row["wall_ms"] for row in rows]
        summary.append({"corpus": corpus, "mode": mode, "phase": phase, "samples": len(times),
                        "median_ms": statistics.median(times), "min_ms": min(times), "max_ms": max(times),
                        "peak_rss_mib": max(row["peak_rss_bytes"] for row in rows) / 1048576,
                        "over_5s": sum(value > 5000 for value in times)})
    # Independent process and resident executions must emit identical records
    # at the same replay positions. Cursors/identities differ by fixture inode.
    for corpus in {trial["corpus"] for trial in report["results"]}:
        cold = groups.get((corpus, "cold", "initial"), [])
        if cold:
            if len({row["semantic_sha256"] for row in cold}) != 1 or any(
                row["renderable_records"] != row["records"] or row["continued"] or row["append_bytes"] or
                row["page_renderable_ms"] < row["helper_wall_ms"] or row["consumer_work_ms"] < 0
                for row in cold
            ):
                errors.append({"corpus": corpus, "status": "cold_readiness_mismatch"})
            fresh = groups.get((corpus, "fresh", "initial"), [])
            if fresh and cold[0]["semantic_sha256"] != fresh[0]["semantic_sha256"]:
                errors.append({"corpus": corpus, "status": "cold_fresh_semantic_mismatch"})
        for phase in ("initial", "unchanged", "append", "older", "receipt"):
            fresh = groups.get((corpus, "fresh", phase), [])
            resident = groups.get((corpus, "project", phase), [])
            if fresh and resident and [x["semantic_sha256"] for x in fresh] != [x["semantic_sha256"] for x in resident]:
                errors.append({"corpus": corpus, "phase": phase, "status": "fresh_resident_semantic_mismatch"})
        raw, native = groups.get((corpus, "raw", "initial"), []), groups.get((corpus, "simdjson", "initial"), [])
        counts = {(row["valid_records"], row["invalid_records"], row["bytes_scanned"])
                  for row in raw + native}
        if raw and native and len(counts) != 1:
            errors.append({"corpus": corpus, "status": "parser_counts_mismatch"})
    cold_summary = []
    for (corpus, mode, phase), rows in groups.items():
        if mode == "cold":
            cold_summary.append({"corpus": corpus,
                "page_renderable_median_ms": statistics.median(row["page_renderable_ms"] for row in rows),
                "helper_median_ms": statistics.median(row["helper_wall_ms"] for row in rows),
                "consumer_work_median_ms": statistics.median(row["consumer_work_ms"] for row in rows),
                "consumer_peak_mib": max(row["consumer_peak_rss_bytes"] for row in rows) / 1048576,
                "messages": [row["renderable_messages"] for row in rows]})
    return {"summary": summary, "cold_start": cold_summary, "errors": errors}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path)
    args = parser.parse_args()
    result = summarize(json.loads(args.results.read_text()))
    print("| Corpus | Lane | Phase | n | Median ms | Range ms | Peak MiB | >5s |")
    print("|---|---|---|---:|---:|---:|---:|---:|")
    for row in result["summary"]:
        print(f'| {row["corpus"]} | {row["mode"]} | {row["phase"]} | {row["samples"]} | {row["median_ms"]:.3f} | {row["min_ms"]:.3f}–{row["max_ms"]:.3f} | {row["peak_rss_mib"]:.1f} | {row["over_5s"]} |')
    if result["cold_start"]:
        print("\nCold-start endpoint details:", json.dumps(result["cold_start"], indent=2))
    print("\nValidation errors:", json.dumps(result["errors"]))
    raise SystemExit(bool(result["errors"]))
