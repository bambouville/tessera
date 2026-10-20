#!/usr/bin/env python3
"""Content-free, host-only Agent Center benchmarks. See agent-center/README.md.

Production code is extracted from the Swift raw literal (checked against the
Swift dumper by the integration gate). Only fixture roots and title DB lookup
are substituted; project/lines/normalization/cursor/encoding remain unchanged.
"""
import argparse
import base64
from collections import deque
import cProfile
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import resource
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import types

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Packages/TesseraCore/Sources/TesseraAgentCore/Lifecycle/RemoteAgentLifecycleIntegrationInstaller.swift"
START = 'exec "$tessera_python" -c \'\n'
END = '\ntry:\n    raw = sys.stdin.buffer.read(MAX_REQUEST + 1)'
MIB = 1024 * 1024


def production_shell():
    source = SOURCE.read_text()
    start = source.index('public static let projectorScript = #"""\n')
    start = source.index('\n', start) + 1
    return source[start:source.index('\n"""#', start)] + '\n'


def namespace(fixture_root):
    shell = production_shell()
    start = shell.index(START) + len(START)
    scope = {"__name__": "benchmark_projector"}
    exec(compile(shell[start:shell.index(END, start)], "projector.py", "exec"), scope)
    scope["provider_roots"] = lambda provider: [str(fixture_root.resolve())]
    scope["codex_title"] = lambda session_id: None
    return scope


def rss_bytes(usage):
    return usage.ru_maxrss * (1 if sys.platform == "darwin" else 1024)


def discover(roots, top):
    """Rank regular non-symlink JSONL files by bytes, not recency; dedupe inodes."""
    found, seen, errors = [], set(), 0
    for root in roots:
        if not root.is_dir():
            errors += 1
            continue
        def onerror(error):
            nonlocal errors
            errors += 1
        for directory, _, files in os.walk(root, onerror=onerror):
            for name in files:
                if not name.endswith(".jsonl"):
                    continue
                path = Path(directory) / name
                try:
                    if path.is_symlink() or not path.is_file():
                        continue
                    info = path.stat()
                    key = info.st_dev, info.st_ino
                    if key in seen:
                        continue
                    seen.add(key)
                    found.append((info.st_size, str(path)))
                except OSError:
                    errors += 1
    found.sort(key=lambda item: (-item[0], item[1]))
    return found[:top], {"files": len(found), "total_bytes": sum(x[0] for x in found), "scan_errors": errors}


def snapshot(source, target):
    """Copy a finite, stable prefix with bounded memory. Never edit real sessions."""
    digest = hashlib.sha256()
    length = max_line = complete = last_complete = count = 0
    with open(source, "rb") as reader, target.open("xb") as writer:
        before = os.fstat(reader.fileno())
        remaining = before.st_size
        while remaining:
            chunk = reader.read(min(MIB, remaining))
            if not chunk:
                raise RuntimeError("source_truncated_during_snapshot")
            writer.write(chunk)
            digest.update(chunk)
            remaining -= len(chunk)
            parts = chunk.split(b"\n")
            for part in parts[:-1]:
                length += len(part)
                max_line = max(max_line, length)
                complete += 1
                count += len(part) + 1
                last_complete = count
                length = 0
            count += len(parts[-1])
            length += len(parts[-1])
        after = os.fstat(reader.fileno())
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise RuntimeError("source_changed_during_snapshot_retry_with_stable_session")
    # Drop only an incomplete last line from the PRIVATE snapshot.
    if last_complete < before.st_size:
        with target.open("r+b") as writer:
            writer.truncate(last_complete)
    return {"source_bytes": before.st_size, "snapshot_bytes": last_complete,
            "source_sha256": digest.hexdigest(), "complete_lines": complete,
            "max_complete_line_bytes": max_line, "partial_tail_bytes": before.st_size - last_complete}


def replay_suffix(path, budget=32768):
    """Contiguous real complete records fitting 32 KiB; no fabricated conversation."""
    with path.open("rb") as file:
        size = file.seek(0, 2)
        file.seek(max(0, size - budget))
        data = file.read(budget)
    if size > budget:
        marker = data.find(b"\n")
        data = data[marker + 1:] if marker >= 0 else b""
    if not data or not data.endswith(b"\n"):
        raise RuntimeError("no_complete_record_in_append_budget")
    return data


class CountedOS:
    def __init__(self):
        self.bytes = 0
        self.calls = 0

    def __getattr__(self, name):
        return getattr(os, name)

    def read(self, descriptor, count):
        value = os.read(descriptor, count)
        self.bytes += len(value)
        self.calls += 1
        return value


def measure(operation):
    cpu = time.process_time()
    started = time.perf_counter()
    result = operation()
    result["wall_ms"] = (time.perf_counter() - started) * 1000
    result["cpu_ms"] = (time.process_time() - cpu) * 1000
    result["peak_rss_bytes"] = rss_bytes(resource.getrusage(resource.RUSAGE_SELF))
    return result


def projected(scope, path, provider, cursor=None, phase="initial"):
    request = {"v": 1, "kind": "project", "provider": provider,
               "transcriptRef": base64.urlsafe_b64encode(str(path.resolve()).encode()).decode().rstrip("="),
               "limitRecords": 100, "limitBytes": 262144}
    if cursor:
        request["cursor" if phase == "older" else "continuationCursor"] = cursor
    if phase == "receipt":
        request["receiptBoundaryOnly"] = True
    output = io.BytesIO()
    real_stdout, real_emit = sys.stdout, scope["emit"]
    first, started = [], time.perf_counter()

    def emit(frame, state):
        real_emit(frame, state)
        if not first:
            first.append((time.perf_counter() - started) * 1000)

    sys.stdout = types.SimpleNamespace(buffer=output)
    scope["emit"] = emit
    try:
        scope["project"](request)
    finally:
        sys.stdout, scope["emit"] = real_stdout, real_emit
    payload = output.getvalue()
    frames = [json.loads(line) for line in payload.splitlines()]
    records = [frame for frame in frames if frame["kind"] == "record"]
    # Hash canonical records + byte positions, excluding inode-dependent IDs.
    canonical = [[frame["sourceOffset"], frame["record"]] for frame in records]
    return {"first_frame_ms": first[0] if first else None, "output_bytes": len(payload),
            "records": len(records), "semantic_sha256": hashlib.sha256(json.dumps(canonical, sort_keys=True).encode()).hexdigest(),
            "continued": "continuedFrom" in frames[0].get("summary", {}),
            "cursor": frames[-1].get("cursor")}


class OffsetControl:
    """Benchmark-only trusted append control. NOT a rewrite-safe production adapter.

    Uses the SAME bounded lexer + normalizer. Omits full-prefix verification,
    metadata/page framing, history index, filesystem watch and remote transport.
    """
    def __init__(self, scope, path, provider):
        self.scope, self.path, self.provider = scope, path, provider
        self.offset = 0
        self.records = deque(maxlen=100)

    def update(self):
        descriptor = os.open(self.path, os.O_RDONLY)
        count = 0
        try:
            size = os.fstat(descriptor).st_size
            start = self.offset
            for offset, raw, truncated in self.scope["lines"](
                descriptor, start, complete_only=True, end_offset=size,
                redact_images=self.provider == "codex"
            ):
                record = self.scope["normalized"](self.provider, raw, truncated)
                self.records.append((self.offset, record))
                self.offset = offset
                count += 1
        finally:
            os.close(descriptor)
        return {"new_records": count, "retained_records": len(self.records),
                "offset": self.offset, "bytes_scanned": size - start}


def raw_decode(path):
    valid = invalid = source_bytes = 0
    with path.open("rb") as file:
        # Intentionally uncapped per-line baseline, one DOM at a time, NEVER
        # json.load(entire history). Supervisor enforces the RSS/time budgets.
        for line in file:
            source_bytes += len(line)
            try:
                value = json.loads(line)
                valid += 1
                del value
            except (ValueError, RecursionError):
                invalid += 1
    return {"valid_records": valid, "invalid_records": invalid, "bytes_scanned": source_bytes}


def worker(config):
    path, mode = Path(config["path"]), config["mode"]
    scope = namespace(path.parent)
    counted = CountedOS()
    if config.get("instrument"):
        scope["os"] = counted
    baseline_rss = rss_bytes(resource.getrusage(resource.RUSAGE_SELF))
    rows, cursor = [], None
    control = OffsetControl(scope, path, config["provider"])
    suffix = b"" if mode in {"raw", "profile", "cold"} else replay_suffix(path)
    phases = (["initial"] if mode in {"raw", "profile", "cold"} else
              ["initial"] + ["unchanged"] * config["repeats"] + ["append"] * config["repeats"])
    if mode in {"project", "fresh"}:
        phases += ["older", "receipt"]
    for phase in phases:
        if phase == "append":
            with path.open("ab") as file:
                file.write(suffix)
        counted.bytes = counted.calls = 0
        if mode in {"fresh", "cold"}:
            row = shell_trial(production_shell(), path, config["provider"], config["timeout"], cursor, phase,
                              consumer=config.get("first_page_consumer") if mode == "cold" else None)
            if row.pop("status") != "ok":
                raise RuntimeError("fresh_projector_failed")
        elif mode == "raw":
            row = measure(lambda: raw_decode(path))
        elif mode == "offset":
            row = measure(control.update)
        elif mode == "profile":
            profiler = cProfile.Profile()
            profiler.enable()
            row = measure(lambda: projected(scope, path, config["provider"]))
            profiler.disable()
            entries = []
            for entry in profiler.getstats():
                code = entry.code
                name = code if isinstance(code, str) else code.co_name
                if name in {"project", "lines", "feed", "normalized", "loads", "bounded_string", "update_projection_summary", "cursor_decode"}:
                    entries.append({"function": name, "qualname": getattr(code, "co_qualname", name), "calls": entry.callcount, "self_ms": entry.inlinetime * 1000,
                                    "cumulative_ms": entry.totaltime * 1000})
            row["profile"] = sorted(entries, key=lambda x: -x["cumulative_ms"])
        else:
            row = measure(lambda: projected(scope, path, config["provider"], cursor, phase))
        cursor = row.pop("cursor", cursor)
        if config.get("instrument"):
            row.update(read_bytes=counted.bytes, read_calls=counted.calls)
        row.update(phase=phase, append_bytes=len(suffix) if phase == "append" else 0,
                   baseline_rss_bytes=baseline_rss)
        rows.append(row)
        if config.get("progress"):
            print(json.dumps({"progress": row}), flush=True)
    # Compare a trusted incremental retained tail to production newest page.
    if mode == "offset":
        expected = projected(scope, path, config["provider"])
        tail = list(control.records)[-expected["records"]:]
        digest = hashlib.sha256(json.dumps(tail, sort_keys=True).encode()).hexdigest()
        if digest != expected["semantic_sha256"]:
            raise RuntimeError("offset_control_does_not_match_production_tail")
    return rows


def supervised(argv, data, timeout, memory_mib):
    """One process group per trial. Kill only that owned group on timeout/RSS.

    /bin/ps gives a sampled aggregate RSS guard (not a kernel hard cap). Exact
    per-process high-water RSS comes from getrusage in each measured worker.
    """
    started = time.monotonic()
    process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    process.stdin.write(data)
    process.stdin.close()
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "out")
    selector.register(process.stderr, selectors.EVENT_READ, "err")
    buffers = {"out": bytearray(), "err": bytearray()}
    reason, sampled = None, 0
    next_sample = 0
    progress_count = 0
    def decoded_rows():
        rows = []
        for line in buffers["out"].splitlines():
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, list):
                return value
            if isinstance(value, dict) and "progress" in value:
                rows.append(value["progress"])
        return rows
    try:
        while selector.get_map():
            now = time.monotonic()
            if now - started > timeout:
                reason = "timeout"
            if now >= next_sample and process.poll() is None:
                ps = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,rss="], capture_output=True, text=True, timeout=5)
                if ps.returncode:
                    reason = "rss_guard_unavailable"
                else:
                    entries = [tuple(map(int, line.split())) for line in ps.stdout.splitlines() if len(line.split()) == 3]
                    owned = {process.pid}
                    while True:
                        grown = owned | {pid for pid, parent, _ in entries if parent in owned}
                        if grown == owned:
                            break
                        owned = grown
                    current = sum(rss * 1024 for pid, _, rss in entries if pid in owned)
                    sampled = max(sampled, current)
                    if current > memory_mib * MIB:
                        reason = "memory_budget"
                next_sample = now + 0.1
            if reason:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
                return {"status": reason, "sampled_tree_peak_bytes": sampled, "completed_rows": decoded_rows()}
            for key, _ in selector.select(0.02):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                else:
                    buffers[key.data].extend(chunk)
                    if key.data == "out":
                        ready = decoded_rows()
                        for row in ready[progress_count:]:
                            print(f'    {row.get("phase", "receipt")}: {row.get("wall_ms", 0):.2f} ms; peak {row.get("peak_rss_bytes", 0) / MIB:.1f} MiB', flush=True)
                        progress_count = len(ready)
                    if len(buffers[key.data]) > 4 * MIB:
                        reason = "output_budget"
        process.wait()
        if process.returncode:
            return {"status": "worker_failed", "exit_code": process.returncode, "completed_rows": decoded_rows()}
        rows = decoded_rows()
        return {"status": "ok" if rows and all(row.get("status", "ok") == "ok" for row in rows) else "invalid_worker_result", "rows": rows,
                "process_wall_ms": (time.monotonic() - started) * 1000,
                "sampled_tree_peak_bytes": sampled}
    finally:
        selector.close()
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        process.stdout.close()
        process.stderr.close()


def shell_trial(shell, path, provider, timeout, cursor=None, phase="receipt", consumer=None):
    # Run the REAL shell startup/interpreter probe + request dispatch. Inject
    # only private fixture roots, disabled external title lookup, and an atexit
    # resource report. No changes to parsing/projection logic.
    setup = '\nprovider_roots = lambda provider: [os.environ["TESSERA_BENCH_ROOT"]]\ncodex_title = lambda session_id: None\n'
    setup += 'import atexit, resource\natexit.register(lambda: sys.stderr.write(json.dumps({"peak_rss_bytes":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == "darwin" else 1024), "cpu_ms":1000 * (resource.getrusage(resource.RUSAGE_SELF).ru_utime + resource.getrusage(resource.RUSAGE_SELF).ru_stime)}) + "\\n"))\n'
    patched = shell.replace(END, setup + END)
    request = {"v": 1, "kind": "project", "provider": provider, "receiptBoundaryOnly": phase == "receipt",
               "transcriptRef": base64.urlsafe_b64encode(str(path).encode()).decode().rstrip("=")}
    if cursor:
        request["cursor" if phase == "older" else "continuationCursor"] = cursor
    env = dict(os.environ, TESSERA_BENCH_ROOT=str(path.parent.resolve()))
    cold_started_ns = time.clock_gettime_ns(time.CLOCK_MONOTONIC)
    started = time.perf_counter()
    result = subprocess.run(["/bin/sh", "-c", patched], input=json.dumps(request).encode(),
                            capture_output=True, env=env, timeout=timeout)
    elapsed = (time.perf_counter() - started) * 1000
    readiness = {}
    if consumer:
        # The shipping Apple decoder waits for EOF + successful exit, then
        # validates the page. Run it and the real shared reducer/snapshot path
        # in a fresh optimized Swift process, with no prior conversation state.
        consumed = subprocess.run([consumer, provider, str(result.returncode)], input=result.stdout,
                                  capture_output=True, timeout=timeout)
        if consumed.returncode:
            return {"status": "page_not_renderable"}
        readiness = json.loads(consumed.stdout)
        readiness["page_renderable_ms"] = (readiness.pop("ready_monotonic_ns") - cold_started_ns) / 1_000_000
        readiness["helper_wall_ms"] = elapsed
    frames = [json.loads(line) for line in result.stdout.splitlines()]
    if result.returncode or not frames or frames[-1].get("kind") != "end":
        return {"status": "shell_failed"}
    records = [frame for frame in frames if frame["kind"] == "record"]
    canonical = [[frame["sourceOffset"], frame["record"]] for frame in records]
    return {"status": "ok", "wall_ms": readiness.get("page_renderable_ms", elapsed), **json.loads(result.stderr), **readiness,
            "output_bytes": len(result.stdout), "records": len(records),
            "semantic_sha256": hashlib.sha256(json.dumps(canonical, sort_keys=True).encode()).hexdigest(),
            "continued": "continuedFrom" in frames[0].get("summary", {}),
            "cursor": frames[-1].get("cursor")}


def run(args):
    args.output.mkdir(parents=True, exist_ok=False)
    roots = {"codex": args.codex_root or [Path.home() / ".codex/sessions", Path.home() / ".codex/archived_sessions"],
             "claude": args.claude_root or [Path.home() / ".claude/projects"]}
    report = {"schema": 1, "platform": platform.platform(), "machine": platform.machine(),
              "python": sys.version, "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "projector_sha256": hashlib.sha256(production_shell().encode()).hexdigest(),
              "repeats": args.repeats, "timeout_seconds": args.timeout, "memory_budget_mib": args.memory_mib,
              "cache": "warm filesystem cache; no cache purge", "corpora": [], "results": []}
    if "cold" in args.modes.split(","):
        report["cold_start"] = {"state": "fresh helper and Swift consumer; no cursor, index, or loaded conversation",
                                "endpoint": "real Apple page decoder + shared reducer + first conversation snapshot",
                                "excludes": "discovery, title DB, SSH/network, device UI layout/paint; disk cache is warm",
                                "consumer_sha256": hashlib.sha256(args.first_page_consumer.read_bytes()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix="tessera-agent-benchmark-") as temporary:
        scratch = Path(temporary)
        for provider, locations in roots.items():
            files, inventory = discover(locations, args.top)
            report.setdefault("inventory", {})[provider] = inventory
            if not files:
                raise RuntimeError("no_sessions_for_" + provider)
            for rank, (_, original) in enumerate(files, 1):
                label = f"{provider}-{rank}"
                master = scratch / (label + "-master.jsonl")
                metadata = snapshot(original, master)
                metadata.update(id=label, provider=provider)
                report["corpora"].append(metadata)
                print(f'{label}: {metadata["source_bytes"] / MIB:.2f} MiB, {metadata["complete_lines"]} lines', flush=True)
                for mode in args.modes.split(","):
                    trials = args.repeats if mode in {"raw", "cold"} else 1
                    for trial in range(trials):
                        working = scratch / (label + "-working.jsonl")
                        shutil.copyfile(master, working)
                        config = {"mode": mode, "path": str(working), "provider": provider, "timeout": args.timeout,
                                  "repeats": 1 if mode == "reads" else args.repeats, "instrument": mode == "reads", "progress": True,
                                  "first_page_consumer": str(args.first_page_consumer.resolve()) if args.first_page_consumer else None}
                        result = supervised([sys.executable, str(Path(__file__).resolve()), "--worker"],
                                            json.dumps(config).encode(), args.timeout, args.memory_mib)
                        result.update(corpus=label, mode=mode, trial=trial)
                        report["results"].append(result)
                        print(f'  {mode}: {result["status"]}', flush=True)
                        (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
                if args.native:
                    for trial in range(args.repeats):
                        result = supervised([str(args.native.resolve()), str(master)], b"", args.timeout, args.memory_mib)
                        result.update(corpus=label, mode="simdjson", trial=trial)
                        report["results"].append(result)
                # Startup calibration on bounded receipt, under the same watchdog.
                config = {"mode": "shell", "path": str(master), "provider": provider,
                          "repeats": args.repeats, "timeout": args.timeout}
                result = supervised([sys.executable, str(Path(__file__).resolve()), "--worker"],
                                    json.dumps(config).encode(), args.timeout, args.memory_mib)
                result.update(corpus=label, mode="shell_receipt")
                report["results"].append(result)
                (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    failures = [x for x in report["results"] if x["status"] != "ok"]
    print(f'Results: {args.output / "results.json"}; failed trials: {len(failures)}')
    return bool(failures)


def main():
    if sys.argv[1:] == ["--worker"]:
        config = json.load(sys.stdin)
        try:
            if config["mode"] == "shell":
                rows = [shell_trial(production_shell(), Path(config["path"]), config["provider"], config["timeout"])
                        for _ in range(config["repeats"])]
                for row in rows:
                    row.pop("cursor", None)
            else:
                rows = worker(config)
            print(json.dumps(rows))
        except Exception as error:
            # Do not leak real transcript contents, paths, or exception strings.
            print(type(error).__name__, file=sys.stderr)
            return 1
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new results directory")
    parser.add_argument("--codex-root", type=Path, action="append")
    parser.add_argument("--claude-root", type=Path, action="append")
    parser.add_argument("--top", type=int, default=3)
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--memory-mib", type=int, default=512)
    parser.add_argument("--modes", default="fresh,project,offset,raw,reads,profile")
    parser.add_argument("--native", type=Path)
    parser.add_argument("--first-page-consumer", type=Path, help="compiled Swift consumer, required for --modes cold")
    args = parser.parse_args()
    if args.top < 1 or args.repeats < 1 or args.timeout <= 0 or args.memory_mib < 32:
        parser.error("positive counts/time and at least 32 MiB required")
    if set(args.modes.split(",")) - {"fresh", "project", "offset", "raw", "reads", "profile", "cold"}:
        parser.error("unknown mode")
    if "cold" in args.modes.split(",") and (not args.first_page_consumer or not args.first_page_consumer.is_file()):
        parser.error("cold mode requires --first-page-consumer pointing to the compiled Swift consumer")
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
