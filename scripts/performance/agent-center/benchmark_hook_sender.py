#!/usr/bin/env python3
"""Synthetic native hook launch-to-receipt/exit benchmark. No provider needed."""
import argparse
import json
from pathlib import Path
import resource
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time


def distribution(values):
    ordered = sorted(values)
    return {"count": len(values), "p50_ms": ordered[len(ordered) // 2],
            "p95_ms": ordered[min(len(ordered) - 1, int(len(ordered) * .95))],
            "max_ms": ordered[-1]}


def validate_receipt(data, expected):
    if len(data) < 4 or struct.unpack("!I", data[:4])[0] != len(data) - 4:
        raise ValueError("bad frame")
    if data[4:] != expected:
        raise ValueError("payload mismatch")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sender", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=200)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 10000:
        parser.error("iterations must be 1..10000")
    sender = str(args.sender.resolve(strict=True))
    with tempfile.TemporaryDirectory(prefix="thb-", dir="/tmp") as temporary:
        root = Path(temporary).resolve()
        path = root / "s"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(str(path))
            path.chmod(0o600)
            listener.listen(16)
            listener.settimeout(1)
            receipt_ns = []
            errors = []
            expected_payload = None
            finished = threading.Event()
            def receive():
                while not finished.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(1)
                        data = bytearray()
                        try:
                            while chunk := connection.recv(8192):
                                data.extend(chunk)
                                if len(data) > 65540:
                                    raise ValueError("oversize")
                            received_at = time.monotonic_ns()
                            validate_receipt(data, expected_payload)
                            receipt_ns.append(received_at)
                        except (ValueError, OSError):
                            errors.append("receive_failed")
            thread = threading.Thread(target=receive)
            thread.start()
            cases = []
            try:
                for size in (1024, 65536):
                    payload = json.dumps({"hook_event_name": "MessageDisplay", "delta": "x" * (size - 60)}).encode()
                    expected_payload = payload
                    exits, receipts = [], []
                    for _ in range(args.iterations):
                        previous = len(receipt_ns)
                        started = time.monotonic_ns()
                        result = subprocess.run([sender, "hook", "--socket", str(path)], input=payload,
                                                capture_output=True, timeout=2)
                        ended = time.monotonic_ns()
                        if (result.returncode, result.stdout, result.stderr) != (0, b'', b''):
                            raise RuntimeError("sender contract failed")
                        deadline = time.monotonic() + 1
                        while len(receipt_ns) == previous and time.monotonic() < deadline:
                            time.sleep(.001)
                        if len(receipt_ns) != previous + 1:
                            raise RuntimeError("hook not received")
                        exits.append((ended - started) / 1e6)
                        receipts.append((receipt_ns[-1] - started) / 1e6)
                    cases.append({"payload_bytes": len(payload), "launch_to_receipt": distribution(receipts),
                                  "launch_to_exit": distribution(exits)})
                absent = []
                for _ in range(args.iterations):
                    started = time.monotonic_ns()
                    result = subprocess.run([sender, "hook", "--socket", str(root / "absent")],
                                            input=b'{}', capture_output=True, timeout=2)
                    if (result.returncode, result.stdout, result.stderr) != (0, b'', b''):
                        raise RuntimeError("absent sender contract failed")
                    absent.append((time.monotonic_ns() - started) / 1e6)
                peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
                print(json.dumps({"iterations_per_case": args.iterations, "filesystem_cache": "warm",
                    "cases": cases, "absent_launch_to_exit": distribution(absent),
                    "peak_sender_rss_bytes": peak if sys.platform == "darwin" else peak * 1024,
                    "collector_errors": errors}, indent=2))
            finally:
                finished.set()
                thread.join(2)
            if errors:
                raise SystemExit(1)


if __name__ == '__main__':
    main()
