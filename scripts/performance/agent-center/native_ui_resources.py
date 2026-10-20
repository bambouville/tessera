#!/usr/bin/env python3
"""Read-only macOS simulator app RSS/CPU census, scoped to one owned device.

No UI automation, connections, installs or process termination. RSS is not
physical footprint or retained-model allocation. No process arguments/IDs leave
the census; output contains only aggregate resource counts and timing.
"""
import argparse
import json
from pathlib import Path
import re
import signal
import subprocess
import time


def census(output, device):
    marker = '/CoreSimulator/Devices/' + device + '/'
    selected = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4: continue
        pid, rss, cpu, command = fields
        if marker not in command or not re.search(r'/Tessera\.app/Tessera(?:\s|$)', command): continue
        minutes, seconds = cpu.split(':')
        selected[int(pid)] = (int(rss) * 1024, int(minutes) * 60 + float(seconds))
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=float, default=180)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-F0-9]{8}(?:-[A-F0-9]{4}){3}-[A-F0-9]{12}', args.device): parser.error('expected exact simulator UUID')
    output = args.output.resolve()
    if any((parent / '.git').exists() for parent in [output, *output.parents]): parser.error('measurement output must be outside Git')
    if not 1 <= args.seconds <= 600 or output.exists(): parser.error('invalid duration or existing output')
    start = time.monotonic(); peak = 0; samples = 0; cpu = {}; first_seen = None; last_seen = None
    stopped = False
    def stop(_signal, _frame):
        nonlocal stopped
        stopped = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while not stopped and time.monotonic() - start < args.seconds:
        raw = subprocess.check_output(['/bin/ps', '-axo', 'pid=,rss=,time=,command='], text=True, timeout=5)
        current = census(raw, args.device)
        if current:
            now = time.monotonic() - start
            if first_seen is None: first_seen = now
            last_seen = now; samples += 1
            peak = max(peak, sum(value[0] for value in current.values()))
            for pid, (_, usage) in current.items(): cpu[pid] = max(cpu.get(pid, 0), usage)
        time.sleep(.25)
    report = dict(stage='simulator_app_resource_census_not_device_footprint', samples=samples,
                  observed_app_processes=len(cpu), peak_sampled_rss_bytes=peak,
                  cumulative_observed_process_cpu_seconds=sum(cpu.values()),
                  first_seen_seconds=first_seen, last_seen_seconds=last_seen,
                  wall_seconds=time.monotonic() - start, interval_seconds=.25)
    with output.open('x') as stream: stream.write(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))
    return int(not samples)


if __name__ == '__main__': raise SystemExit(main())
