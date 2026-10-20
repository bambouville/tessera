# Agent Center native ingestion: delivery evidence

> Installed-flow correction: the Android build cherry-picked to `main` exposed
> a production binding-serialization failure and missing Codex title metadata.
> The lower-level evidence below did **not** cover detected lifecycle events
> through Android's presenter ownership handoff. Its completion statement was
> too broad. The installed-flow regression report records the defects,
> corrections, and replacement acceptance coverage.

Worktree: `.worktrees/agent-center-performance`; branch:
`codex/agent-center-performance`. Rebased onto `main` at `d930411d`.
This report supersedes historical "remaining work" entries in the
implementation ledger.
Implementation and the automated validation described below are complete.
This is an unshipped branch handoff, not a blanket release/performance approval;
measured target misses and coverage exceptions remain explicit.

## Delivered design

C++17/simdjson helper binaries for macOS arm64/x86_64 and Linux aarch64/x86_64;
one leased service per destination user/host-session context, shared by app
clients. No public listener or account service. Authenticated SSH carries the
duplex protocol, including through jump hosts and the SSH side channel used by
Mosh. Private local sockets additionally verify peer/context ownership.
Background/expiry detaches one client's demand without terminating another's;
the last lease allows owned processes to exit.

Bootstrap, ranged history, slow summaries and fast opened-thread updates use
the same bounded protocol. Each displayed window owns its acknowledged ranges;
live head updates do not overwrite detached history. Search uses the native
connection too, without repeated Python projector processes.

Codex supports canonical legacy/paginated history and structured App Server
fallback for native-only sessions. An independently started App Server is not
assumed to subscribe to another CLI's live process. Claude and Pi use
branch-aware JSONL history; Claude hooks are optional wakeups, not the
authoritative message feed. OpenCode uses bounded SQLite history/WAL wakeups;
Kimi follows its wire-history display reducer. Unsupported formats and
unknown/unparsed content remain explicit diagnostics.

The research conclusion was to reuse native parsing technology and provider
semantics, not embed Omnigent's server/database platform. Omnigent's durable
ingestion, cursors and subscriptions informed the design, but do not remove
bootstrap costs or guarantee attachment to arbitrary existing CLI processes.
See [original market research and pinned source links](agent-center-ingestion-2026-09-11.md),
[implementation/security plan](../agent-center-ingestion-implementation-plan.md),
and [chat-follow behavior contract](../agent-center-chat-scroll-behavior.md).

## Cold start to visible content

Twenty sequential trials per provider/device; largest finite Codex snapshot
376,861,178 bytes and Claude snapshot 46,453,911 bytes. Each trial decodes the
full 1,273-conversation inventory, verified by exact inventory digest, then
renders the selected detail. All completed distributions below have zero trial
errors. Times are milliseconds; percentile is the suite's nearest-rank p95.

| Simulator/emulator | Provider | Helper start to render candidate p95 | Cold app launch to captured pixels p95 / max | App incremental RSS upper bound, bytes |
|---|---|---:|---:|---:|
| iPhone | Codex | 1,719.664 | 3,199.828 / 4,061.035 | 30,457,856 |
| iPhone | Claude | 1,095.407 | 2,285.695 / 2,330.979 | 28,540,928 |
| Landscape iPad | Codex | 1,494.495 | 2,895.204 / 4,012.099 | 21,086,208 |
| Landscape iPad | Claude | 954.905 | 2,201.801 / 2,319.210 | 26,705,920 |
| Android phone | Codex | 1,773.651 | 3,472.586 / 4,435.590 | 36,749,312 |
| Android phone | Claude | 1,282.257 | 3,191.707 / 3,220.855 | 47,296,512 |
| Landscape Android tablet | Codex | 2,002.207 | 4,570.142 / 4,634.180 | 28,086,272 |
| Landscape Android tablet | Claude | 1,272.276 | 3,984.320 / 4,393.808 | 30,117,888 |

Landscape Android tablet completed 40 error-free trials, but the first batch
missed the Codex helper-candidate target (p95 2,192.597 ms, max 3,723.167 ms).
A broad temporary-file listing may have overlapped the run. That complete
distribution is retained as diagnostic. The table uses the full quiet repeat,
not selected trials. Its Codex candidate p95 still misses the proposed 2 s
target by 2.207 ms; the target is not relaxed or rounded into a pass.

Reference: M2 Pro, 16 GiB RAM; DEBUG native apps/instrumentation; warm filesystem
finite snapshots, fresh app/helper state and fresh owned loopback SSH
authentication. Controlled 50 ms RTT is injected into post-authentication
application streams, not SSH handshake packets. The DEBUG adapter feeds the
real native decoder/Core/detail view; it does not time production host-list
navigation or an in-app Citadel/MINA handshake. Those carriers have separate
live jump-host tests. App launch includes simulator/instrumentation startup.
Screenshot completion is a conservative visible-pixels upper bound, not an
exact first-paint timestamp. No agent-triggered competing build/audit ran during these
measured trials. The earlier Android phone batch with brief build overlap is
retained as diagnostic and excluded wholesale, not filtered for outliers.

Helper tree maxima: iPhone 41,009,152 B, iPad 42,270,720 B, Android phone
40,943,616 B, Android tablet 41,926,656 B. SSH client and server/relay trees are measured separately; their
independent maxima must not be summed as simultaneous memory use. Allocator
accounting and sampled RSS are not an OOM proof or physical-device measurement.

The helper-to-render-candidate p95 target of 2 s passes seven of eight
provider/device distributions; Android tablet Codex is the exception above.
**Cold app launch to captured pixels is not below 2 s.** These boundaries must
not be interchanged. The original model-ready measurement was approximately
21.7 s for the largest Codex file and excluded network/native rendering; no
same-boundary speedup ratio is claimed. The older 60+ s observation also was
not this cold-app measurement. Original projection costs and exact boundaries
remain in the [baseline report](agent-center-cold-first-page-2026-09-11.md).

## Complete host-corpus audit, including unknown types

Private snapshots, transcripts, titles, session IDs, databases and screenshots
remain outside Git. Reports use counts, hashes and source ordinals.

| Gate | Result | Scope / exceptions |
|---|---|---|
| Physical Codex/Claude discovery | 1,277 files; zero read/discovery failures | 993 Codex + 284 Claude; no changed/deferred tails |
| Normalization and memory audit | All 1,277 measured; zero processing/resource failures | All 1,273 conversation-layout files have zero unknown/unparsed coverage issues |
| Non-conversation workflow files | Strict coverage failure retained | Four files contain the same 160 unknown/unclassified records; not silently omitted or counted twice |
| Claude official SDK selected history | 284/284 match | Pinned SDK pure reducer, plus corrected display policy |
| Append replay | 1,277/1,277 pass | Persistent vs fresh indexes at finite checkpoints; not independent upstream semantics |
| Codex native history identities | 148,540 identities/order/revisions match across 976 paginated files | 17 legacy files explicitly not compared by this lane; two store-count mismatches are 123 items after selected tails, zero within-range mismatch; strict failed status retained |
| OpenCode host SQLite store | Six sessions, 42 ordered selected records; zero failures or unknown types | Includes archived sessions; identity/taxonomy, not full-payload equivalence |
| Pi official selected offsets | Three historical files, 21 records; zero unknowns/mismatches | Plus credentialed live synthetic session |
| Kimi official display reducer | 74 files, 15,410 physical records, 7,568 selected tokens; zero mismatches/unknowns | No Kimi provider process resumed or prompted |

Maximum native Codex/Claude audit worker RSS: 23,740,416 B; independent Python
reference: 198,295,552 B. OpenCode native worker lifetime peak: 4,669,440 B.
These are separate workers, not simultaneous sums. Full physical corpus scan
took 33.068 s; it is an exhaustive audit, not user bootstrap latency.
Raw legacy-projector payload/metadata differences remain in private reports;
these scoped checks do not claim universal byte-for-byte equivalence.

## Live, UI, security and capacity evidence

Credentialed synthetic Codex, Claude, Pi and OpenCode sessions on the explicitly
authorized Mac pass through two authenticated SSH clients sharing one verified
helper each. Observed selected records per client: 7, 43, 13 and 42 respectively;
zero unknown/unparsed records. Claude's one explicit resync per client is
accounted for, not hidden. Existing user sessions were not resumed.

Chat-follow bug-present recordings demonstrated same-ID message growth leaving
the latest text offscreen. Fixed recordings and assertions cover initial tail
placement, same-ID growth, coalescing, detached reading, return-to-latest,
history paging, receipts and keyboard/composer resize. iPad/iPhone and Android
phone/tablet have native tests; the single aggregate synthetic visual review
passes eight cases / 42 images. Private real-transcript captures are inspected
locally, never submitted to that external review. Credentialed provider-wire,
real-corpus rendering and synthetic live-UI tests are separate lanes, not one
claimed continuous provider-to-device test.

The final cold-render evidence has 160 error-free trials. First, last and
slowest-trial screenshots were inspected locally for each provider/device:
readable recent tail, bottom alignment and no composer/footer occlusion.
This is sampled visual verification, not an assertion that all 160 captures or
every video frame were reviewed. The per-trial raw reports remain immutable
with their original pending-visual marker; this paragraph records the later
review. First-trial videos and every-trial screenshots remain private.

Current jump-host matrix passes SSH, SSH+tmux, Mosh and Mosh+tmux, including
blocked direct target access and distinct per-hop wrong-key checks. Earlier
installer quota exhaustion was resolved by recoverably archiving six exact
unlocked, unpinned test binaries on the disposable target; current/rollback
versions stayed intact and no production quota changed.

The 30-minute two-client, four-fast/fifty-slow capacity soak passes: fast-update
p95 546.421 ms, idle CPU 0.811% of one core, peak simultaneous helper/child/relay
RSS 18,264,064 B, service RSS 4,239,360 B. All 5,100 measured slow updates
satisfy the 7 s bound (maximum 5,152.126 ms); 408 fast samples were measured;
all sampled owned process identities exited and the fixture directory was
removed. This is Linux local stdio, synthetic Claude and a protocol-shaped
Codex child, not real-model execution. Its corrected fixture explicitly asserts
native-only Codex App Server reads; the obsolete malformed canonical fixture
failed honestly before that correction.

All 66 strict audit harness tests and two new Pi cache-pressure regressions
pass. The suspected Pi pinning mismatch was disproved by tracing
`WindowSession::read`, which already stores the provider-prefixed key. No
production patch was needed. All 28 current native CTest groups pass (82.78 s).
All four artifacts match their source, architecture, integrity and licenses.
Current Linux ARM executes hook/service/JSONL/all-provider/deployment cases in
an unmounted disposable Debian VM; the two privileged context-isolation cases
pass separately under its root test identity. VM cleanup is verified. Intel
macOS passes hook/service/JSONL/all-provider suites under Rosetta. Its first
invocation exceeded the strict one-second hook launch assertion (1.918 s);
the complete unchanged repeat passes. This is retained as an observed initial
emulation/launch timing failure, not proof of physical Intel latency. The
Mac tests' two root-only skips are covered by the separate Linux ARM run.

## Reproduction and private evidence

See [suite commands](../../scripts/performance/agent-center/README.md) and
[native host tests](../../Tools/AgentHost/README.md). Final private roots:

- `/private/tmp/tessera-native-paint-ssh-phone-final`
- `/private/tmp/tessera-native-paint-ssh-ipad-final`
- `/private/tmp/tessera-android-paint-ssh-phone-final-b`
- `/private/tmp/tessera-android-paint-ssh-tablet-final-b`
- `/private/tmp/tessera-full-corpus-native-20260913-final`
- `/private/tmp/tessera-normalization-coverage-20260913-final`
- `/private/tmp/tessera-claude-semantic-20260913-final`
- `/private/tmp/tessera-append-replay-20260913-final`
- `/private/tmp/tessera-codex-history-20260913-final-e` (strict evidence refresh: zero resource/processing failures)
- `/private/tmp/tessera-opencode-corpus-20260913-final-b`
- `/private/tmp/tml-fosph5je` (credentialed synthetic provider gate)

Native-paint reports pin the manifest, helper, app artifact and collector
sources; strict Codex/OpenCode audit reports additionally identify their finite
database references. Provenance is narrower in the older Pi/Kimi semantic
lanes (reference hash or upstream revision); those reports do not hash every
executed collector/binary. Recordings are private temporary evidence, not
durable product assets. Owned test devices/VMs must be
deleted on exit; the user's persistent devices and unrelated work stay intact.

## Handoff and rollback

The change is on the worktree branch, not merged or pushed. Build the worktree's
`Tessera` simulator scheme or Android debug app to exercise Agent Center:
open a user-established host session, select a thread, scroll into history
while it updates, then return to latest. Phone layout is compact; landscape
tablet layout retains the wider navigation surfaces. Device installation and
physical touch/keyboard feel remain the user's steps.

No provider-history migration is involved. To abandon the unshipped rewrite,
build the unchanged `main` baseline in its existing checkout; do not reset this
worktree or user data. Helper deployment retains versioned executables and
current/rollback selection, while leases allow unused owned services to exit.
An incompatible protocol is reported explicitly rather than mixing readers.
