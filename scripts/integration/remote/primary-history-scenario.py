#!/usr/bin/env python3
"""Primary-screen history with a live heartbeat, for the S13 visual case.

Prints --count numbered rows in the fixture probe's scroll-scenario format (the
app's DEBUG row readout parses both), then redraws TESSERA_TICK_nnnnn on the
cursor's line every half second without scrolling, like Claude Code's status
line, so a reader who has returned to the live tail can prove that output
reaches the screen again. The numbered rows stay intact.

With --burst-lines N, once the lane creates <trigger>.burst (while the reader
is in history), the next N ticks each end their line, like Claude Code
finishing messages: N rows scroll into history above the reader's page. Like
Claude Code's frames, each is a synchronized update (DEC mode 2026), which a
terminal applies at once without moving a reader of its history; mosh
relays only the resulting screen. The scenario then creates
<trigger>.burst.done.
The lane uploads this file per run instead of provisioning it; --trigger also
names the run-scoped path cleanup matches to end the process.
"""
import argparse
import os
import sys
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("--count", type=int, required=True)
    parser.add_argument("--trigger", required=True)
    parser.add_argument("--delay", type=float, default=0.001)
    parser.add_argument("--seconds", type=int, default=900)
    parser.add_argument("--burst-lines", type=int, default=0)
    args = parser.parse_args()

    burst = args.trigger + ".burst"
    # A retried attempt must not start with its predecessor's burst.
    for stale in (burst, burst + ".done"):
        try:
            os.remove(stale)
        except FileNotFoundError:
            pass

    for index in range(1, args.count + 1):
        print(
            f"TESSERA_SCROLL_{args.label}_{index:05d} | "
            "0123456789abcdef0123456789abcdef",
            flush=True,
        )
        if args.delay > 0:
            time.sleep(args.delay)
    print(f"TESSERA_SCROLL_{args.label}_BOTTOM_READY", flush=True)

    deadline = time.monotonic() + args.seconds
    tick = 0
    burst_left = args.burst_lines
    while time.monotonic() < deadline:
        tick += 1
        if burst_left > 0 and os.path.exists(burst):
            sys.stdout.write(f"\x1b[?2026h\rTESSERA_TICK_{tick:05d}\r\n\x1b[?2026l")
            burst_left -= 1
            if burst_left == 0:
                sys.stdout.flush()
                open(burst + ".done", "w").close()
        else:
            # Redraw the cursor's line in place: nothing scrolls.
            sys.stdout.write(f"\rTESSERA_TICK_{tick:05d}")
        sys.stdout.flush()
        time.sleep(0.5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
