# Claude hook probe and implementation decision

Date: 2026-09-12. Installed Claude Code: **2.1.269**. Worktree:
`.worktrees/agent-center-performance`, branch `codex/agent-center-performance`.
These are local macOS probes, not Linux, SSH, mobile-render, or full-corpus results.

## Decision

Use **async native hooks for provisional fast updates, with canonical transcript
tail reconciliation**. Keep bounded JSONL bootstrap and ranged history. Hooks
are an acceleration path, not a complete or durable conversation database.

The current official reference documents interactive `MessageDisplay` line
batches and headless completed-message delivery. Display IDs cannot be equated
with transcript IDs. Async execution avoids waiting for the hook, but pending
hooks may be cancelled at headless teardown. The sender therefore stays bounded
and silent, and canonical recovery remains mandatory.
[Claude hook reference](https://code.claude.com/docs/en/hooks)

## Probe isolation

`scripts/performance/agent-center/claude_hook_probe.py` creates new synthetic
sessions, disables user/project settings, MCP, skills, Chrome, and auto-updates,
and bypasses Tessera's existing Claude wrapper. It uses the existing provider
authentication without copying credentials. It does not resume, interrupt, or
send input to an existing pane/session, or install user hooks.

Interactive runs use a dedicated tmux socket and generated trusted test folder.
The harness kills only its own tmux server. Raw hook payloads, terminal captures,
and provider outputs stay in private directories outside git. Newly generated
interactive transcripts remain in provider storage; no existing transcript is
modified. Only content-free measurements and schema field names are reported.

## Observed results

Each successful row is one real model request, not a statistical reliability
claim. All successful runs had zero collector errors.

| Probe | Observed hooks | Text/ordering check |
|---|---|---|
| Headless synchronous | SessionStart, prompt, MessageDisplay, Stop, SessionEnd: one each | Display was one completed batch; Stop matched final result |
| Headless async | Same five events, one each | Final message and SessionEnd reached the socket in this run |
| Headless Read tool | Above plus PreToolUse, PostToolUse, PostToolBatch | Tool-call-only assistant response did not emit display text; final Stop matched result |
| Interactive synchronous | 11 display batches plus lifecycle/prompt/Stop | Indices 0–10; exactly one final; joined deltas matched Stop and saved assistant text |
| Interactive async | 8 display batches plus lifecycle/prompt/Stop | Indices 0–7; exactly one final; joined deltas matched Stop and saved assistant text |
| Interactive async through native service | 9 display batches through framed native subscription | Indices 0–8; exactly one final; joined deltas matched Stop and saved assistant text; service exited after disconnect/grace |
| Strict native-service repeat, user tmux config disabled | 12 display batches; all required lifecycle hooks | Indices 0–11; final batch last; exact Stop/transcript equality; first display arrived 1.896 s before Stop |
| Final native-service repeat with reviewed cleanup/exit checks | 12 display batches; all required hooks; successful service exit | Exact terminal-final/order/Stop/transcript checks; first display arrived 2.530 s before Stop; no failures |

The five interactive synthetic transcripts each contained 20 records and one
assistant record. In each, the display ID matched neither the transcript UUID
nor the API message ID. The headless API/stream identifiers also differed.
This makes a separate provisional overlay and explicit reconciliation necessary;
using display IDs as canonical bubble IDs would duplicate content.

Observed additional payload fields include `prompt_id` on prompt, display,
tool, and Stop events. Do not depend on this undocumented observation as the
sole reconciliation key. `PostToolBatch` included actual model-facing tool
results; `PostToolUse` used its own structured tool response representation.

Initial interactive harness attempts failed before hook execution: one PTY
cleanup failure, then trust-dialog handling errors. Their timeouts are **not**
Claude hook latency measurements. The dedicated tmux harness now waits for the
trust dialog to become input-ready and verifies the affirmative selection
before confirming only its synthetic folder. Failed cases return nonzero.
Adversarial review subsequently tightened verdicts to require all expected
hook types, exact reconstructed text, contiguous indices, one terminal final
batch, and synthetic transcript equality. The strict repeat above passed these
checks. The final harness disables user tmux configuration; earlier dedicated-
socket runs did not explicitly disable that configuration.

## Native sender overhead

Current binary: C++17 release build, statically linked simdjson 4.6.4; benchmark
uses a private synthetic socket listener with exact payload equality checks.
200 launches per case, filesystem cache warm, no simultaneous model request/build
during the measurement. Binary SHA-256:
`8a471cc5a0f5b95b1890e1a41aa920555118b0821c3bc567e7eb0a2c87a702d6`.

| Payload | Launch → receipt p50 / p95 | Launch → exit p95 |
|---|---|---|
| 1,014 bytes | 2.172 / 2.493 ms | 2.700 ms |
| 65,526 bytes | 2.582 / 2.933 ms | 3.172 ms |
| Service absent | Not applicable | 2.838 ms |

Peak child RSS across the sender-only launches: **1,425,408 bytes (1.36 MiB)**.
This excludes the listener, persistent service, provider, SSH relays, and apps.
It is not their aggregate memory budget. Launch-to-receipt includes OS process
startup, stdin delivery, and local socket delivery; it excludes Claude's own
hook scheduling and shell-launch overhead, SSH, reducers, and rendering.

Earlier exploratory samples used a different binary or weaker receipt checks.
Use the final exact-payload-validated run above, not a mixture of those samples;
small run-to-run differences are not evidence of a performance regression.

The sender has a 64 KiB payload cap and a 100 ms work deadline after native
entry. It produces no stdout/stderr and returns success when absent/unavailable.
Oversized input produces a small reconciliation hint, not truncated JSON.
It never starts the service, extends a client lease, or writes a disk spool.
The deadline cannot bound time before the OS schedules the process or arbitrary
filesystem stalls; no hard real-time guarantee is claimed.

## Implementation started

`Tools/AgentHost/` contains the native sender, shared private-socket service,
and persistent duplex stdio relay. The service holds an exclusive singleton
lock, verifies same-UID peers, uses private runtime/socket permissions, limits
frames/queues/connections, and expires independent client leases. Hooks do not
keep it alive. Slow interest coalesces invalidations while fast interest receives
hook previews; these are not yet canonical summary/history readers.

The experimental handshake advertises only `claude.hookPreview`, not bootstrap,
history, complete normalized updates, or product readiness. The app installer
and platform endpoints are not switched by this milestone. Local source builds
require an already installed exact simdjson dependency; cross-compiled bundled
artifact packaging remains required before user-host deployment.

## Reproduce

```sh
cmake -S Tools/AgentHost -B /tmp/tessera-agent-host-build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/tessera-agent-host-build
ctest --test-dir /tmp/tessera-agent-host-build --output-on-failure
python3 scripts/performance/agent-center/benchmark_hook_sender.py \
  --sender /tmp/tessera-agent-host-build/tessera-agent-host --iterations 200
TESSERA_RUN_CLAUDE_HOOK_PROBE=1 python3 scripts/performance/agent-center/claude_hook_probe.py \
  --sender /tmp/tessera-agent-host-build/tessera-agent-host \
  --claude /absolute/path/to/native/claude --cases sync async tools
TESSERA_RUN_CLAUDE_HOOK_PROBE=1 python3 scripts/performance/agent-center/claude_hook_probe.py \
  --sender /tmp/tessera-agent-host-build/tessera-agent-host \
  --claude /absolute/path/to/native/claude --interactive --native-service --cases async
```

Unix-socket tests need an environment permitting local socket creation. Provider
probes are explicitly opt-in and consume model usage. The harness must not be
pointed at a wrapper that installs/resumes existing user sessions.

## Gates still required

### Checks completed for the initial host-tool implementation

- Native release: 10 sender tests and 17 service/relay tests passed. Includes
  exact-size and oversized payloads, backpressure, private paths, malformed and
  fragmented frames, half-close draining, independent client leases, simultaneous
  cold relay startup sharing one service epoch/PID, final idle exit, and stalled
  consumer isolation. The new `agent_host_native` aggregate lane also runs 12
  deterministic probe-verdict, benchmark-integrity, and failure-cleanup tests.
- The same 27 native tests passed with UndefinedBehaviorSanitizer.
- `run-agent-integration-script-tests.sh` passed: generated script syntax,
  isolated installation/lifecycle/action checks, 47 projector tests, 10
  benchmark tests, 7 cold-page consumer tests, and 15 recovery tests. This
  preserves baseline historical regression coverage; it is **not** a claim that
  the future replacement reader already passes the full host corpus.
- Two adversarial reviewers examined transport/security and probe evidence.
  A half-close data-loss defect was independently reproduced and fixed, then
  verified by focused tests and review. Probe false-green, tmux configuration,
  exact benchmark payload validation, and failure cleanup findings were fixed
  with negative regression tests.
- **AddressSanitizer is blocked on this toolchain/OS.** All sanitizer cases
  timed out at startup; even `--version` hung. A system stack sample showed
  recursive ASan initialization spinning in `StaticSpinMutex::LockSlow` through
  `InitializeShadowMemory` and malloc/dyld initialization, before application
  `main`. The exact owned diagnostic process was terminated and reaped. This is
  not an ASan pass, and UBSan does not replace its coverage. Re-run ASan on a
  functioning runtime/toolchain before claiming that gate.

### Remaining product gates

Lost/duplicated/reordered batches, restart and canonical overlay retirement;
interruption/errors, subagents, empty final batches, oversized tools/images;
older Claude capability behavior; all-host Codex/Claude corpus and historical
regression coverage; bounded native canonical readers; multi-subscription and
client reconnection semantics; security adversarial review and wrong-UID tests;
Linux/macOS release artifacts; iOS/Android and all four transports including
jump routes; actual cold-start-to-renderable-model and first-paint measurements.
No successful hook sample waives any of these gates.
