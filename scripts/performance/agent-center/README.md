# Agent Center transcript performance suite

The transcript benchmark is a host-only investigation, not a replacement
projector: it needs no simulator, SSH server, model invocation, session resume,
host install, or credentials. The separate **opt-in Claude hook probe** below
does invoke the provider using new synthetic sessions and existing authentication.
Neither lane installs hooks or changes production app/helper behavior.

## Synthetic long-history acceptance

`Tools/AgentHost/tests/test_synthetic_history.py` drives the real native helper's
`window.read` and `window.ack` protocol using streamed synthetic sources. Its
normal CTest lane covers the former 19,999/20,000/20,001 boundary for Claude,
Codex, Pi and Kimi, branch/revision/undo selection, bounded backward/forward
paging, 32-file Codex ancestry, interrupted reads/reconnection, and warm
interior structural rewrites followed by append. Expected order and text come from fixture formulas, not
the production reducer. The source count includes headers and revisions;
selected canonical records and authored messages are reported separately.

For the opt-in large corpus, build the native helper first, then run:

```sh
python3 scripts/performance/agent-center/synthetic_history_stress.py \
  --binary /absolute/build/tessera-agent-host \
  --output /tmp/tessera-synthetic-history-new \
  --counts 19999 20000 20001 100000 1000000 --traverse --interrupt
```

Use `--shape branches --providers claude pi`, `--shape revisions --providers
claude codex`, or `--shape undo --providers kimi` for dependency-heavy cases.
`--shape lineage --providers codex` partitions the selected messages across 32
physical files; adding `--opaque-bytes` exercises resumed ancestry reads.
`--rewrite --providers claude codex` mutates graph membership/ownership in place
and appends, then checks complete traversal. `--padding 1024` varies displayed
body size. `--opaque-bytes 10000 --counts 1000000` creates sources above 10 GB;
that expensive case is optional and needs sufficient temporary disk space.
All fixtures are owned temporary files removed even after failure. The helper
has an empty executable search path, so this lane cannot launch a provider.

Initial loading validates the latest page plus two older pages, ACKing each
immediately. Full traversal retains at most four page descriptors and one
decoded response at a time; it does not keep an all-history oracle or result
list in RAM. The runner records first-page and three-page-ready timing,
older-page total/max latency, actual native read bytes, wire bytes, helper
high-water RSS and sampled helper RSS, plus binary/harness digests. Each case
has an independent watchdog and memory guard. Sampling may miss short peaks;
the helper-reported high-water figure covers successful page endpoints, and
neither measurement is a kernel memory cap. Failed cases remain in results and
make the command fail. The normal lane must be green after the implementation;
capacity errors are never accepted as successful truncation.

This is local helper/protocol acceptance, not iOS/Android rendering, SSH/Mosh,
physical lock/network transitions, or Send first-write latency. Those remain
separate integration gates. Run performance measurements without competing
builds/benchmarks; filesystem caches are not purged.

## Native hook and service probes

See [the hook report](../../../docs/research/agent-center-claude-hooks-2026-09-12.md)
for the decision, real-provider observations, limits, and commands. Native code
and deterministic synthetic socket tests live in `Tools/AgentHost/`.

`benchmark_hook_sender.py --sender BINARY` measures native launch-to-local-hook
receipt/exit and child peak RSS without a provider. `claude_hook_probe.py` is
gated by `TESSERA_RUN_CLAUDE_HOOK_PROBE=1`; it exercises synchronous/async/tool
hooks, optionally interactive streaming and the actual native shared service.
Its raw artifacts stay private outside git. Interactive probes create new
synthetic provider transcripts and a dedicated test-owned tmux server; they do
not attach to existing panes. Failures return nonzero and retain private evidence.

### Sustained shared-service capacity

Run on a disposable Linux integration fixture, never the user's Mac as a test
host:

```sh
scripts/integration/run-native-agent-host-tests.sh stable 1800
```

The optional second argument selects a 40–7,200 second soak instead of the
short regression lanes. The default acceptance duration is 1,800 seconds;
short smoke runs are not that acceptance gate. Two real stdio relays share one
real native service and a **synthetic Codex protocol child**, alongside actual
Claude-shaped JSONL files. The active half exercises four fast and fifty slow
subscriptions, mutating at 17.3-second intervals to vary phase against polling.
The idle half reconnects both clients to the same service epoch with fifty slow
subscriptions. Exact provider identity, sequence-tagged content, complete page
transactions and all fifty changed summaries are checked before accepting
latency samples. This does not measure real Codex child resource use, SSH RTT,
native UI paint, or repeated foreground/background churn.

Content-free JSON output records binary/script digests, raw update latencies,
five-second simultaneous process-tree RSS/descriptor samples and CPU counters.
Idle `(PID, starttime)` sets must remain identical: replacement children cannot
vanish from the CPU denominator. RSS is a sampled maximum, not a continuous
allocation bound or OOM proof. The controller is excluded. Native supervision
samples its owned Codex process group every 50 ms during reads and every second
while idle. The runner removes its exact remote temporary directory; the soak
also checks that sampled run-owned process identities exited after teardown.

## Run

From the worktree root (Python 3.10+; macOS or Linux with `/bin/ps`):

```sh
python3 scripts/performance/agent-center/test_benchmark.py
python3 scripts/performance/agent_center_benchmark.py \
  --output /tmp/tessera-agent-perf-new-run --top 3 --repeats 5 --timeout 600
python3 scripts/performance/agent-center/summarize.py /tmp/tessera-agent-perf-new-run/results.json
```

The output directory must not already exist. Defaults scan `~/.codex/sessions`,
`~/.codex/archived_sessions`, and `~/.claude/projects`, including subdirectories.
Use repeatable `--codex-root PATH` / `--claude-root PATH` to override each provider.
Selection is by descending byte size across all supplied roots, not modification
time. Inodes are deduplicated and symlink files/directories are not followed.
Inventory counts and inaccessible-root/directory/file counts are reported.

Largest *local discoverable* files are not necessarily the largest on another
host. Scan errors must be accounted for before calling a corpus representative.
Files changing while copied are rejected. Each snapshot drops a partial final
JSONL record and records its size; the original file is never modified.

The runner measures one source at a time in an automatically cleaned private
temporary directory; retained snapshots need about twice the selected corpus size. Replayed
updates are a contiguous suffix of real complete records fitting 32 KiB. A final
record larger than that budget causes an explicit failure, not a synthetic
substitution. Replay covers controlled append, not concurrent provider writes.

Results contain provider/rank labels, sizes, hashes, counts, timings and RSS;
no source paths, thread titles, prompts, completions, tool output or attachments.
SHA-256 fingerprints identify local corpus versions without publishing content.

## Measurement lanes

### Native relay cold start

`native_first_page.py --host-entry context-relay` starts the packaged stdio
relay, captures the roots of an already-running synthetic provider-context
process, starts a fresh scoped helper, discovers the whole finite catalog,
and consumes the first page in the actual shared model. `--host-entry relay`
uses the carrier roots; the default `service` retains the direct-helper
baseline. These are separate boundaries, not interchangeable cold-start
numbers. Use `--trials 20`, a private snapshot manifest and an output outside
Git; private transcripts and captured protocol frames must never be committed.

Relay lanes currently require canonical JSONL fallback (no `--native-store`).
They use a 100 ms helper idle grace for isolated trial cleanup; apps retain the
30-second default. Cleanup happens after all latency endpoints. The synthetic
context's setup and RSS are excluded, like an existing provider process; the
relay and detached helper trees are included in sampled ingestion RSS. The
shared consumer's peak is reported separately, never added as a simultaneous
peak. Helper self high-water RSS and sampled tree RSS each have a 256 MiB
budget; consumer peak has a 128 MiB budget. These are guards, not kernel caps
or OOM proofs. The controller, kernel cache, SSH and native view paint remain
outside this lane.

An authenticated helper PID must have an actual RSS sample, followed by a
final full-tree sample. Sampling waits occur after measured endpoints, although
background observation still has overhead. Missing coverage fails the trial.
Detached PID/argv census is observation only, never signal authority: cleanup
closes the owned relay input, waits for its exec supervisor, then checks normal
helper idle exit. Memory guard failures immediately close the relay input.
Both helpers and consumer start fresh; OS filesystem caches remain warm.

| Lane | Work measured | Interpretation |
|---|---|---|
| `cold` (requires Swift consumer) | Fresh real helper through real Apple decoding, shared reducer application and first conversation snapshot | First page **model-ready**, with no cursor/index/loaded conversation; not screen paint |
| `fresh` | Real generated shell, interpreter selection, Python process, production request dispatch/project/encoding | Current local helper cost; excludes SSH/native UI and title DB |
| `project` | Same production projector in one resident Python interpreter | Isolates process reuse without changing scan algorithm |
| `offset` | Same lexer and normalizer, retained last 100 records, saved offset | Trusted append-only control, not a production implementation |
| `raw` | Standard `json.loads`, full DOM per JSONL line, discard immediately | Parser/I/O lower-level baseline, not Tessera semantics |
| `reads` | Production resident projector with counted `os.read` | Byte/read amplification; instrumentation timings kept separate |
| `profile` | One production projection under cProfile | CPU attribution; profiled wall time must not be compared as latency |
| `simdjson` (optional) | C++ simdjson DOM per full JSONL line | Native parser baseline, not Tessera normalization |
| `shell_receipt` | Fresh real shell + bounded receipt request | Startup calibration with small useful work |

Production latency lanes perform initial newest page, repeated unchanged refreshes,
repeated append refreshes, one older page and one receipt. The `reads` diagnostic
uses just initial/one unchanged/one append to avoid redundant scans. The `offset` control
performs initial/unchanged/append. Raw/native lanes run in independent processes.
The same OS filesystem cache is warm throughout; these are **not cold-disk**
numbers. Initial means first request/process, not evicted disk cache.

All production source comes from the current Swift raw literal, not a copied
implementation. Only provider roots and Codex's external title database lookup
are substituted for fixture isolation. The projection algorithm, image lexer,
normalizers, prefix proof, cursor logic and page limits remain intact. Verify
extraction against `AgentIntegrationSourceDump` (the integration dumper compiles
the actual Swift installer); rerun `scripts/integration/run-agent-integration-script-tests.sh`
for the affected host integration target.

`project.first_frame_ms` is time to first encoded frame in a local sink. The
actual helper's stdout buffering, SSH delivery and complete-page application add
cost; this is not device-visible first-token latency. `fresh.wall_ms` includes
local process launch through complete response. Parent supervisor timing is
reported separately, never substituted for per-operation wall time.

RSS uses `getrusage(RUSAGE_SELF).ru_maxrss`: bytes on macOS, KiB converted to
bytes on Linux. Resident rows have a lifetime high-water mark; do not subtract
two peaks and call that per-request allocation. Baseline interpreter peak is
included. Fresh helper rows use the child helper's own high-water RSS, excluding
the controller and the separate short interpreter-selection probe. The
supervisor additionally samples summed process-tree RSS every 100 ms with a
default 512 MiB kill budget. This is a sampled guard, not a kernel hard cap;
short spikes can exceed it. Each scenario has a total timeout (default 600s).
Completed rows are retained if a later operation times out. Only its owned process group is killed. Cases are
sequential; do not run builds or other benchmarks concurrently for clean numbers.

The offset control excludes metadata reconstruction, full-prefix rewrite
verification, persisted history index, watch notifications, wire encoding and
transport. It proves the cost of incremental normalization; it does not prove
production correctness or an end-to-end speedup. Its final newest canonical
records/positions must match the real projector's newest page. Deterministic
tests cover incomplete lines, UTF-8, unchanged reads, append amplification,
rewrite rejection, corpus ranking, snapshots crossing 1 MiB boundaries,
timeout cleanup/evidence preservation and stderr privacy.
The summary also checks fresh/resident semantic equality and raw/native
valid/invalid record counts. A latency over the current 5s budget is reported,
not hidden as a correctness failure; timeout, guard failures, child failures,
and semantic mismatches fail validation. Five samples are not a credible p99;
the summary deliberately gives median and observed min/max instead.

## Cold start to first renderable page

Build the optimized host consumer once, outside the measurement window:

```sh
python3 scripts/performance/agent-center/build_first_page_consumer.py /tmp/tessera-first-page-consumer
python3 scripts/performance/agent-center/test_first_page.py /tmp/tessera-first-page-consumer
python3 scripts/performance/agent_center_benchmark.py \
  --output /tmp/tessera-agent-cold-page-new --top 3 --repeats 3 \
  --timeout 120 --modes cold --first-page-consumer /tmp/tessera-first-page-consumer
python3 scripts/performance/agent-center/summarize.py /tmp/tessera-agent-cold-page-new/results.json
```

Requires Swift and the repository's shared sources. This build was verified on
macOS; Linux execution is not verified. Rebuild the consumer after changing any
decoder/shared-core source. The evidence fingerprints the compiled binary.
The host integration gate builds it and runs its deterministic tests too.

Every repetition is an independent initial request: a fresh helper, fresh Swift
consumer and empty `AgentCenterRuntime`, with no prior cursor, persisted index
or loaded conversation. Source selection and snapshot copying happen before
the timer. This is **application-state cold, filesystem-cache warm**; no global
cache purge is performed. It does not simulate reboot, disk-cache misses or
provider discovery.

`page_renderable_ms` (also `cold.wall_ms`) starts immediately before spawning
the real helper. It ends after the real Apple page decoder and channel bounds
checks accept the complete response, the shared reducer applies the page, and
the first `AgentThreadSnapshot` is available. The snapshot's message count is
reported, including zero if the valid page contains no displayable messages.
An incomplete page, failed exit, invalid frame or rejected application cannot
produce a successful readiness sample.

The shipping Apple decoder waits for stdout EOF and a successful exit before
decoding; receiving a page header or `end` line alone is not the endpoint.
The harness therefore captures the real helper's completed response and passes
it in 4,093-byte chunks through the real decoder/channel into the reducer.
The only production Apple-source transformation is removing its module import
when compiling those same shared sources together. Transport input and the
diagnostic sink are fixture implementations; decode/reduce logic is not copied
or approximated in Python. No SSH connection is opened.

The cross-process endpoint uses `CLOCK_MONOTONIC` on both sides. Consumer process
startup and local response handoff are included; consumer teardown is excluded.
`helper_wall_ms` isolates launch-to-helper-exit; `consumer_work_ms` measures
consumer setup, decode, bounds checks, reducer and snapshot work after input is
received. These components need not sum to the endpoint because process startup
and handoff add time. Helper and Swift-consumer peak RSS are reported separately,
alongside the supervisor's sampled process-tree peak. Do not sum lifetime peaks
and call that simultaneous memory usage.

This is a host **renderable-model** boundary, not measured pixels: SSH RTT,
device CPU, SwiftUI/Compose layout and drawing, external title lookup and the
platform presenter's additional requests are excluded. Android's native decoder
is not exercised; the shared reducer is. The main summary reports every sample
over five seconds without enforcing the app's five-second timeout, so slow
first pages remain measurable. A timeout/memory/error is a failure, not a fast
or empty-page success.

## Full-history type coverage (required for ingestion compatibility)

JSON decoding success and latency are not compatibility gates. The native
refactor has additional private-snapshot lanes:

- `normalization_corpus.py`: every physical Codex/Claude JSONL record, compared
  with the independent legacy projector plus strict input/output vocabulary
  and field-shape checks. Requires the native `agent-normalization-driver`,
  the Swift installer containing the reference projector, and the private
  all-file manifest produced by `full_corpus.py`. Use `--metadata` too.
- `codex_window_corpus.py`: all populated native histories, backward/forward
  pagination, identity/order, revision/ACKs and normalized type coverage.
- `native_schema_corpus.py`: every stored native item against the pinned
  official generated App Server schema, including nested required fields and
  tagged unions. Uses a private SQLite backup and does not start Codex.
- `codex_event_text_corpus.py`: legacy Codex user-event text against native
  response-item rendering, independently of the old projector. Requires the
  private manifest, previous full coverage report and normalization driver.
- `codex_completed_projection_corpus.py`: physical completed CoreTurnItem
  snapshots versus exact owner/turn/item references from a finite native-store
  backup, using separate native Core/public converters. Reports revisions and
  missing references as unresolved, not successful comparisons. SQLite item
  bodies stream through a byte-bounded BLOB interface and deadline-bound pipes.
- `codex_history_corpus.py`: canonical paginated item selection, initial ordinal
  and latest-revision ordinal versus the native store. Requires
  `agent-codex-history-driver`. Reports missing references after the native
  watermark separately; even those keep the gate red until reference refresh.
  Legacy files are accounted for, not claimed as canonical equivalence passes.
  These two new lanes accept `--driver`, `--manifest`, `--native-db` and
  `--output`; all outputs must remain outside Git. They pin their driver and
  database snapshot. Neither substitutes for selected-content/live-replay proof.
  Pass a finite `thread_history_1.sqlite` backup, not `state_5.sqlite` or a live
  store. Schema is checked before scanning. Legacy files are counted separately;
  native items newer than the selected transcript tail are reported separately
  from count gaps within that range. The strict total-count gate remains red
  on any reference difference, including a newer reference tail.
- `opencode_corpus.py --snapshot PRIVATE_BACKUP --driver
  /path/to/agent-opencode-store-driver --output PRIVATE_FRESH_DIRECTORY`:
  every session in a finite OpenCode SQLite backup, including archived sessions.
  Independent ordered SQL identity iteration is compared with all native pages;
  missing/duplicate/out-of-order rows and unknown/unparsed normalized records
  fail. Current sequence-ordered messages and legacy message headers/parts are
  separate reference branches. Native lifetime RSS complements sampled RSS,
  with a 256 MiB worker gate. Input/session/frame/hash memory is bounded; no
  message bodies or session IDs enter the content-free report. This does not
  assert independent full-payload equivalence. All backups remain outside Git.
- Add `--history-driver /path/to/agent-codex-history-driver` to
  `codex_completed_projection_corpus.py` to compare only the latest canonical
  paginated revisions. Equal content with different envelope truncation flags,
  missing references and legacy histories still keep this strict gate red.
- `source_layout_corpus.py`: all original Claude file paths plus synthetic
  edge cases against the pinned SDK's actual session/subagent file collectors
  and the native catalog-layout test driver. Separately accounts for non-session
  JSONL sidecars; does not assert SDK title visibility or content semantics.
  New manifests retain `source_root`. For old or remote-host manifests, supply
  `--claude-projects-root` explicitly to this lane and `native_first_page.py`
  when it differs from the current host's configured Claude projects root.

`native_ui_resources.py --device <owned-simulator-UUID> --output <private.json>`
samples the exact simulator's Tessera processes at 250 ms intervals. It reports
sampled RSS and cumulative process CPU, not physical-device footprint or only
the retained transcript model. SIGTERM ends sampling and writes the report;
the integration window runner owns that process and the disposable simulator.
No sampling command opens a host connection or modifies another app/device.

Example schema lane (the only lane here with an optional external Python
dependency, pinned in its uv script metadata):

```sh
uv run --script scripts/performance/agent-center/native_schema_corpus.py --self-test
uv run --script scripts/performance/agent-center/native_schema_corpus.py \
  --schema /private/tmp/codex-schema/codex_app_server_protocol.schemas.json \
  --snapshot /private/tmp/private-codex-snapshot/thread_history_1.sqlite \
  --fixtures Tools/AgentHost/tests/fixtures/codex-schema-only-items.json \
  --output /private/tmp/tessera-native-schema-new
```

Use a schema generated by the tested Codex CLI version and record its version
and digest. These paths are examples; never silently substitute live databases
for finite snapshots. All runners reject in-repository private output. Review
`docs/research/agent-center-type-coverage-2026-09-12.md` for actual evidence and
remaining failures. An explicit unknown marker is safe runtime degradation,
**not a passing compatibility result**. Agreement between two unknown markers
also fails. New schema types absent from the corpus require synthetic fixtures.

These lanes do not replace tool-relationship, branch-selection, canonical
payload, all-file live-replay or actual native-render checks.

## Actual upstream Codex semantic references

`build_codex_history_oracle.py --source CODEX_CHECKOUT --cargo PINNED_CARGO
--output PRIVATE_BUILD` builds a **test-only** bridge against the actual
upstream protocol/history crates. Select the toolchain required by that checkout
in an isolated environment; this explicit build may fetch build dependencies.
Nothing is shipped in the app or installed on a user's host. The checkout must
have no tracked modifications. Evidence pins its revision, bridge, resulting
lockfile and executable hashes. `--target-dir PRIVATE_CACHE` can reuse a build.

`upstream_core_corpus.py` takes `--driver` (agent-codex-history-driver),
`--public-driver` (agent-normalization-driver), `--oracle`, `--oracle-evidence`,
`--manifest`, and a fresh private `--output`. It compares production-selected
Core inputs through actual upstream conversion. Optional paired `--native-db`
and `--schema` independently check completed subagent activity and agent questions
missing from the older source checkout: the captured native row must have the
same owner/turn/item and exact update ordinal, and its projection must match.
Missing native rows remain failures, never guessed conversions.

`codex_private_materialization_probe.py` is an **offline test-only investigation**
for stale finite native references, never a production fallback. It requires a
completed private native-store audit, matching finite corpus manifest/ordinal,
exact local Codex binary, compiled `Tools/AgentHost/tests/private_probe_isolation.c`
via `--isolation-checker`, and fresh `/private/tmp/tessera-native-reference-*`
output. It copies stable no-follow regular files (including SQLite WAL), verifies
manifest identity, pins the executable, removes copied enrollment rows and
redirects every copied database path into its private workspace. No auth or
configuration files are copied. macOS Seatbelt denies non-runtime file contents,
all Mach services, network access, fork and spawning even the allowed executable;
a mandatory synthetic negative checker verifies these boundaries before Codex
starts. The child gets a fixed minimal environment, private temporary directory,
file-only credential storage and the verified remote-control-disable marker.
Only initialize, metadata read, one-item bounded history read and exact-private-copy
resume are allowed; never turn/start. Fork ancestors are copied only from the
same manifest and loaded oldest-first when required by the installed parent
ownership rule. Failed previous probes cannot serve as snapshot provenance.
Exact returned ID/path, measurable materialization advancement,
memory sampling and verified child exit are mandatory success conditions.
Failures are not reference-equivalence passes. The upstream corpus runner copies
the entire stable private native database/WAL and recovers only its new copy.
This macOS probe does not justify resuming or mutating any live provider session.

`legacy_authored_corpus.py` takes `--manifest`, `--selection-report` (the above
complete report for the exact same manifest), `--history-driver`, `--driver`,
`--oracle`, `--oracle-evidence`, and fresh private `--output`. It audits every
legacy file identified by that selection run. Authored user/assistant block
content and order must match the actual upstream legacy reducer. It separately
reports validated current token-usage metadata absent from the older upstream
union. Typed reasoning/tool displays retained by Tessera are not claimed as
upstream-authored-message equivalence. Both runners pin binaries/scripts and
enforce bounded frames, deadlines and worker-memory checks.

The direct projected-item bridge deliberately avoids a second transport cut
after upstream transforms an already bounded input. These checks do **not**
prove unbounded-source equality, transport-read parity, full legacy replay,
turn/tool relationships, receipts or performance. The physical corpus report's
layout breakdown separates non-session workflow logs but does not remove them
from its strict all-files gate.

## Private native iOS first-page display

`scripts/integration/run-native-agent-paint-tests.sh PRIVATE_MANIFEST FRESH_OUTPUT
[--phone]` builds a DEBUG app on a uniquely owned simulator and deletes that
device on success, failure or interruption. Use a short output path beginning
`/private/tmp/tessera-native-paint-`. Never point the runner at a user simulator.
The manifest must contain finite private snapshots, not live provider stores.

Defaults: 20 sequential trials per provider, largest valid Codex and Claude
conversation, full corpus cloned into each fresh helper environment, 50 ms
round-trip arrival delay over protected Unix streams. By default no SSH/TCP
connection is involved. No user-host session, provider credentials or provider
control is used in either mode. Every session-layout source is checked by exact
source-set digest, not just row count; non-session sidecars remain in the
physical snapshots but are not falsely counted as conversations.

`TESSERA_NATIVE_PAINT_DISCOVERY_ORDER=inventory-first` completes the full catalog
before resolving/opening the selected thread. `selected-first` resolves and
bootstraps a known authorized transcript location first, then completes the
same inventory, potentially overlapping first display. Report these as different
critical paths, never as interchangeable timings. Navigation starts before
the asynchronous page read, matching the real app's selection behavior.

The helper clock starts immediately before a fresh helper, after app setup.
It ends after real shared-core reduction, visible transcript tail layout and
two display-link ticks. This is a **paint candidate**, not precise first paint.
Every trial also captures original compositor pixels immediately after the
candidate; screenshot completion is a conservative visibility upper bound,
subject to readability verification. First-trial videos and all screenshots
remain private. The
report separately records whole-inventory completion, model readiness, helper
process-tree sampled peak, app baseline/lifetime peak and a conservative
incremental app-RSS upper bound. Filesystem cache is warm; simulator DEBUG RSS
is not physical-device RSS. Independent process lifetime peaks are not added.

The app bundle/helper and Python source dependencies are pinned before trials;
the actual `Tessera.debug.dylib` code hash is recorded, not merely its executable
loader. The stream proxy delays arrivals, not each serialized chunk, and caps
each direction at sixteen 64 KiB queued chunks. Cleanup closes accepted streams
before waiting for the listener and attempts all owned resource teardown even
if another operation fails. Host-free regressions cover those invariants.
`TESSERA_NATIVE_PAINT_TRIALS` and `TESSERA_NATIVE_PAINT_RTT_MS` configure diagnostic
runs. Fewer than twenty trials are explicitly insufficient for the p95 gate.
Physical-device checks remain separate.

For a fresh DEBUG app process plus authenticated SSH, set
`TESSERA_RUN_MAC_AGENT_LIVE=1 TESSERA_NATIVE_PAINT_SSH=1
TESSERA_NATIVE_PAINT_LAUNCH=1` before either native runner. The Mac opt-in is
required: an owned loopback sshd accepts only its generated ephemeral key and
one forced attach-only native relay command. No global SSH configuration,
authorized keys, or provider credentials change. Setup/key generation is outside
the measured boundary; each trial's fresh local SSH authentication is inside.
The injected RTT applies to post-authentication application streams, **not**
network packets or the SSH handshake. Apps still use their DEBUG Unix adapter;
the separate jump integration lane exercises production native SSH carriers.

The report distinguishes `coldHelperToPaintCandidateMS`,
`coldAppToPaintCandidateMS`, `coldAppToCapturedPixelsUpperMS`, and
`coldHelperToCapturedPixelsUpperMS`. Launch-inclusive mode removes the default
500 ms empty-fixture settling delay. The app clock starts before `simctl launch`
(or Android `am instrument`); Android includes instrumentation startup, not
release-app startup. The existing `candidateLatencyTargetMet` tests only the
helper-to-candidate boundary, not launch-to-captured-pixels.

SSH client tree and server/relay tree RSS are sampled and labeled separately
from helper RSS. These independent peaks must not be added as a simultaneous
total. Sampling never authorizes signaling a discovered PID; teardown uses
direct owned process handles, verifies sampler completion, and removes keys.

## Private native Android first-page display

`scripts/integration/run-android-agent-paint-tests.sh PRIVATE_MANIFEST FRESH_OUTPUT
[pixel_tablet|pixel_7]` reuses the integration runner's disposable-AVD lifecycle.
Use a short fresh path beginning `/private/tmp/tessera-android-paint-` and the
same finite private snapshot manifest as the iOS lane. The test-only fixture
uses the real ingestion connection, shared Core/JNI and Compose detail pane.
It never connects to a user host. Tablet runs assert landscape configuration.

Defaults and discovery-order settings match the iOS lane: twenty trials per
provider, 50 ms arrival RTT, fresh helper/model and resident empty native app,
with exact full-inventory completion and mandatory post-inventory RSS readings.
The stream uses a per-run authenticated adb reverse to a private Unix socket;
adb's own emulator transport is not a production SSH measurement. Five clock
round trips establish a host/device offset interval; results report conservative
latency upper bounds and reject imprecise or inconsistent calibration. Visible
tail plus two Choreographer frames is a paint candidate. The timestamp directly
after `UiAutomation.takeScreenshot()` provides a separate calibrated capture
upper bound; it is not an exact first-visible frame timestamp.
Android emulator DEBUG RSS is not physical-device RSS.

The helper, installed APK and source dependencies are pinned. Every collector
adb operation rechecks the exact owned AVD name before addressing its serial.
Original screenshots and first-trial videos stay in private output. No corpus,
message bodies, screenshots or device logs belong in git. The host-free
`Tools/AgentHost/tests/test_android_native_paint.py` tests authentication-before-
backend access, clock bounds, stream cleanup and reused-serial rejection.

## Optional native decoder baseline

Use a locally installed simdjson. No dependencies are downloaded by this suite.
For the Homebrew installation used for the report:

```sh
clang++ -O3 -std=c++17 -I/opt/homebrew/include \
  scripts/performance/agent-center/simdjson_baseline.cpp \
  /opt/homebrew/lib/libsimdjson_static.a -o /tmp/tessera-simdjson-baseline
python3 scripts/performance/agent_center_benchmark.py \
  --output /tmp/tessera-agent-perf-with-native --timeout 600 \
  --native /tmp/tessera-simdjson-baseline
```

The C++ lane validates full documents (DOM, not a skipped-field On-Demand
shortcut), reuses its parser, and discards each document. Both raw lanes can
allocate proportional to the largest **line**, unlike the bounded production
lexer. JSON validity differences are surfaced by record counts. A native parser
alone is not an OOM guarantee. No vendor throughput claims are treated as local
benchmark results.

For a framing control, build `simdjson_chunked_baseline.cpp` with the same
flags/library and pass that binary with `--native`. It uses `fread` in 64 KiB
chunks and `memchr` rather than `std::getline`; the JSON DOM engine is unchanged.
Keep the results in a separate output directory and compare corpus hashes.
Validate both input readers with:

```sh
python3 scripts/performance/agent-center/test_native_baselines.py \
  /tmp/tessera-simdjson-baseline /tmp/tessera-simdjson-chunked
```

## Canonical authority header gate

After changes to native source selection, run every finite Codex snapshot
through the production prefix probe (not only the largest file):

```sh
python3 scripts/performance/agent-center/canonical_authority_corpus.py \
  --driver /path/to/agent-window-reader-driver \
  --manifest /private/path/private-manifest.json \
  --output /private/path/fresh-authority-results
```

This uses authorized private clones, disables provider executable discovery,
checks filename/header identity and supported history mode, and asserts physical
I/O stops in the header's last 64 KiB block. It retains content-free counts and
ordinal errors outside Git; copied transcript fixtures are removed after each
probe. Empty/unmarked sources are separate categories, not canonical successes.
Incomplete, duplicate-key, oversized, invalid or mismatched headers fail the
gate explicitly. This complements rather than replaces all-record unknown-type,
canonical history, relationship and replay gates.

## Private Pi persisted-branch and taxonomy gate

```sh
python3 scripts/performance/agent-center/pi_semantic.py \
  --root /private/path/to/pi/sessions \
  --reference /installed/pi/dist/core/session-manager.js \
  --build /private/path/to/native-test-build \
  --output /private/path/to/new-pi-evidence
```

The installed official session manager is digest-pinned. Only private finite
copies are opened by the SDK, since opening legacy sessions can migrate them.
No provider, credentials, extensions or user-session resume are involved.
The comparison checks exact persisted branch IDs, not normalized payload
equality. The independent all-record lane requires exact physical start-offset
coverage and the final byte boundary, then rejects unknown dispositions and
unparsed content. Empty normalizer output cannot pass as zero unknowns.

The SDK reference lane deliberately caps each file at 8 MiB / 3,200 entries;
larger cases fail explicitly. Its memory/timing numbers are audit-worker data,
not app cold-start or first-paint measurements. Evidence and copied transcripts
must stay outside Git. Supplement it with the native-to-Core wire gate in
`Tools/AgentHost/README.md` and the credentialed two-client Mac SSH probe:

```sh
TESSERA_RUN_MAC_AGENT_LIVE=1 python3 scripts/integration/mac-live-ingestion-probe.py \
  --host /absolute/path/to/tessera-agent-host --providers pi \
  --env-file /explicitly/authorized/private.env
```

That opt-in probe creates and resumes only its own synthetic Pi session and
reads only `DEEPSEEK_API_KEY` from the supplied file. It verifies authenticated
SSH reuse and live delivery, not app rendering or physical-device performance.
