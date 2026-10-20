# Cold start to first renderable Agent Center page

Date: 2026-09-11. Worktree: `.worktrees/agent-center-performance`.
Branch: `codex/agent-center-performance`; preceding benchmark commit:
`1503ec2b989a718a899a6d210e9c28306fcc503f`.
No production helper, app, provider session or user configuration changed.

## Endpoint and scope

The new `cold` lane measures **fresh helper launch → first usable conversation
snapshot**. Each repetition starts fresh helper and Swift-consumer processes,
with an empty shared runtime and no cursor, index or loaded conversation.

This is more than first output or JSON parsing: it executes the real Apple
projector decoder, channel page bounds, shared `AgentCenterRuntime.apply` and
`snapshot(for:)`. The Apple decoder waits for stdout EOF and successful helper
exit before accepting a page. A page header or even an early `end` frame is
not sufficient. Malformed/incomplete pages and rejected applications fail the
sample instead of recording an early success.

The timer uses the same `CLOCK_MONOTONIC` clock across Python and Swift. It
includes shell/interpreter startup, full projection and encoding, helper exit,
local response handoff, Swift process startup, page validation, reducer work
and snapshot construction. It stops at snapshot availability, before consumer
teardown. The consumer only exports counts, timing and RSS, never message text.

**Renderable means the model is available to the UI, not that pixels have
been drawn.** The benchmark runs on the Mac, not on an iPad or Android device.
It excludes SSH/network latency, device CPU, discovery of the transcript
reference, external title lookup, presenter's additional requests, and
SwiftUI/Compose layout/paint. The real Apple decoder and shared reducer run;
Android's native decoder does not. It is therefore a host model-readiness
measurement, not end-to-end user-perceived first paint.

“Cold” is **application-state cold, filesystem-cache warm**. Private snapshots
are prepared outside the timer. There is no global disk-cache purge, reboot,
or cold-storage emulation. Each repetition is independent; no steady-state
result is relabeled as cold start.

## Results

Apple M2 Pro, 16 GiB RAM, ARM64 macOS 26.6.2, Python 3.14.3; Swift consumer
compiled with `swiftc -O`. Three cold trials per source, run sequentially.
Harness compilation and the full integration build occurred outside the
benchmark window; this remains a development-machine observation, not a
quiet-host guarantee. All six corpus hashes and all 18 initial-page canonical
hashes match the [original baseline](agent-center-ingestion-2026-09-11.md).

| Corpus | MB | First model-ready s, median | Observed range s | Consumer work ms, median | Helper peak MiB | Consumer peak MiB | Displayable messages |
|---|---:|---:|---:|---:|---:|---:|---:|
| codex-1 | 376.9 | 21.743 | 21.656–21.766 | 14.33 | 37.9 | 11.5 | 25 |
| codex-2 | 263.8 | 16.193 | 16.186–16.337 | 15.84 | 38.4 | 11.7 | 32 |
| codex-3 | 180.7 | 5.050 | 5.048–5.064 | 14.15 | 37.6 | 11.8 | 28 |
| claude-1 | 46.5 | 0.254 | 0.253–0.262 | 16.55 | 36.0 | 12.0 | 38 |
| claude-2 | 23.5 | 0.751 | 0.747–0.751 | 19.05 | 36.7 | 11.8 | 51 |
| claude-3 | 20.9 | 0.303 | 0.299–0.308 | 16.64 | 36.0 | 11.8 | 39 |

All nine Codex cold-start trials exceeded five seconds. All nine Claude
trials were below one second. The largest Codex file took **21.743 seconds**
to a snapshot containing 25 displayable messages; its consumer setup,
decode/validation, reducer and snapshot work took only **14.33 ms** median.
The helper scan continues to dominate. Model construction is now measured
rather than assumed negligible.

The previous 29.528-second figure was one first-helper-request sample in a
different run. The new figure is a median of three runs with an extended
endpoint; it is **not a production optimization or a speedup claim**. No
production implementation changed.

Helper RSS peaked at 38.4 MiB and the separate Swift consumer at 12.0 MiB.
The supervisor's sampled owned-process-tree peak was 75.5 MiB, including the
Python controller worker. Lifetime peaks are not simultaneous allocations and
should not be added together. The 512 MiB sampled guard and 120-second
per-trial watchdog did not fire. Neither is a universal OOM guarantee.

## Reproduce and inspect

See the [suite's cold-start instructions](../../scripts/performance/agent-center/README.md#cold-start-to-first-renderable-page).
The consumer build compiles the exact Apple source with its module import
removed, alongside the actual shared-core sources. Only transport input and
the app diagnostic sink are fixtures; the decoder and reducer are not
reimplemented in Python.

```sh
python3 scripts/performance/agent-center/build_first_page_consumer.py /tmp/tessera-first-page-consumer
python3 scripts/performance/agent_center_benchmark.py \
  --output /tmp/tessera-agent-cold-page-new --top 3 --repeats 3 \
  --timeout 120 --modes cold --first-page-consumer /tmp/tessera-first-page-consumer
python3 scripts/performance/agent-center/summarize.py \
  docs/research/agent-center-cold-first-page-2026-09-11-results.json
```

[Content-free evidence](agent-center-cold-first-page-2026-09-11-results.json):
18 cold-start samples plus 18 separate bounded receipt calibration samples,
24 completed trial blocks, zero failures. Corpus and consumer-binary hashes,
per-trial helper/consumer timings, memory peaks and renderable message counts
are retained. Private transcript snapshots were automatically removed.

## Validation

Seven new deterministic tests pass: valid page → displayable message, incomplete
page rejection, nonzero exit rejection, malformed/oversized page rejection,
UTF-8/chunk boundaries, actual helper-to-snapshot operation for both providers,
and an early complete `end` frame followed by a deliberately delayed helper
exit. The last test ensures that “first output” cannot masquerade as readiness.

The summary validates stable cold-page semantics across repetitions, record
counts, absence of continuation/replayed append, and monotonic endpoint timing.
All original and new result summaries pass. The new tests are wired into
`run-agent-integration-script-tests.sh`.

The complete affected host integration gate passed: 47 projector tests,
10 original benchmark-validity tests, seven new cold-page tests, 15 recovery
tests, and the existing lifecycle/install/process-proof/launch assertions.
Process-inspection permission was enabled for the test-owned process checks.
The local log is
`/private/tmp/tessera-agent-perf-integration-20260911/gate-cold-page.log`.
`git diff --check` passed. No simulator, user host connection or provider run
was started; native layout/paint and live transport tests remain outside this
host-only measurement change.
