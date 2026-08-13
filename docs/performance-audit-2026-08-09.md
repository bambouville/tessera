# Tessera and SwiftTerm performance audit

Date: 2026-08-09
Tessera baseline: `772dd280149feef6c19a53c1cff62f0eb27a36fa`
Tessera branch: `codex/performance-audit`
SwiftTerm baseline: `d135aeb10108a3c11fb897aad656ea345545184c`
SwiftTerm branch: `codex/tessera-performance-audit`
SwiftTerm candidate: `2e7665f3852cd1082a59dd9e4f1585c8ccb8bbcb`

## Executive summary

The audit found and implemented five low-risk improvements without changing terminal, transport, diagnostics, or date-format behavior:

1. Tessera's terminal contrast filter now borrows printable-only byte slices instead of copying and rebuilding them.
2. Default-off scroll diagnostics no longer snapshot terminal state before every synchronous SSH-family output chunk.
3. Diagnostics reuse their six regular expressions and ISO-8601 formatter.
4. Known Hosts reuses its fixed date formatter.
5. SwiftTerm resize work now scales with materialized lines rather than configured scrollback capacity, and terminal reset no longer installs a retain cycle.

The largest app component result was the in-process contrast filter over payload/chunking captured from a real SSH connection: median filter time for approximately 16 MiB fell from 35.777 ms to 7.815 ms, a 78.16% reduction (4.58x). Network, session ingest, SwiftTerm parsing/rendering, and frame latency were outside that timer. The final dependency result for an empty-buffer resize pair with 50,000-line configured scrollback fell from 14.243250 ms to 0.008958 ms, a 1,590x speedup, while also resizing materialized overflow lines that margin-mode IL/DL can reach beyond the logical line count. Before the SwiftTerm reset fix, 100 of 100 reset terminals remained retained after external references were dropped; none remained afterward.

No system allocator was installed or changed. SwiftTerm's optional package-benchmark dependency mentions jemalloc, but none of these results or fixes requires a local jemalloc installation.

## Measurement rules

- Performance numbers use optimized code only. App/XCTest measurements used Xcode's Release configuration with `-O` and whole-module optimization; the opt-in test seam also enables testability and `DEBUG`-gated APIs, so it is not a bit-for-bit App Store binary. A separate stock Release product was built as the final compile gate. Pure Foundation component benchmarks were compiled with `swiftc -O`.
- Baseline and candidate used separate worktrees and DerivedData directories. The live contrast-filter comparison used the same harness source and provisioned stable VPS.
- Contrast-filter measurements used five samples per checkout and report the median and maximum. Each live checkout made one real SSH capture and replayed that captured chunk array five times in one XCTest process; these samples quantify replay noise, not independent connection, network, process-launch, or simulator variance. The validation compared every output byte with its input outside the timed samples.
- SwiftTerm resize results are the median of five independent Release test processes. Baseline/candidate order alternated by run; each process contained a cold pair and 50 warm `80 -> 81 -> 80` column resize pairs.
- Every contrast-filter/resize benchmark checked the output byte count or final visible lines, cursor position, dimensions, and materialized-line count.
- Simulator values are regression evidence, not claims about physical-device CPU, energy, or absolute latency.
- Environment: Xcode 26.0.1 (17A400), Apple Swift 6.2, macOS 26.5.2. The refreshed performance simulator runtime was iOS 26.0.1 (23A8464).

## Reproduction and evidence

The optimized Foundation component benchmark is checked in and includes exact-output preconditions for sanitization and Known Hosts dates:

```sh
swiftc -O scripts/performance/FoundationHotPathBenchmarks.swift \
  -o /tmp/tessera-foundation-hot-path-benchmarks
/tmp/tessera-foundation-hot-path-benchmarks
```

The contrast-filter XCTest benchmark is opt-in via `TESSERA_RUN_PERFORMANCE_AUDIT=1`. The real-host runner accepts `TESSERA_INTEGRATION_BUILD_CONFIGURATION=Release`, external fixture/state paths, a distinct DerivedData path, and this focused filter:

```text
TesseraTests/RealHostTransportIntegrationTests/test_liveSSHPrintableContrastFilterPerformanceAudit
```

The candidate invocation was:

```sh
TESSERA_FIXTURE_CONFIG="$PWD"/scripts/integration/fixture.env \
TESSERA_INTEGRATION_FIXTURE_STATE_DIR="$PWD"/scripts/integration/.state \
TESSERA_INTEGRATION_SIMULATOR_STATE_DIR=/private/tmp/tessera-performance-live-release-rerun-sim \
TESSERA_INTEGRATION_DERIVED_DATA=/private/tmp/tessera-performance-live-release/DerivedData \
TESSERA_INTEGRATION_BUILD_CONFIGURATION=Release \
TESSERA_RUN_PERFORMANCE_AUDIT=1 \
./scripts/integration/run-app-transport-tests.sh \
  /private/tmp/tessera-performance-live-release-rerun \
  TesseraTests/RealHostTransportIntegrationTests/test_liveSSHPrintableContrastFilterPerformanceAudit
```

The baseline used the identical command from the instrumented baseline worktree, substituting `baseline` for `release` in the three `/private/tmp` paths. The 64 MiB lane used the same setup with filter `TesseraTests/TerminalScrollbackOracleTests`; the three exact behavior oracles ran in the same selected test class.

The same harness source was applied to the baseline worktree (`772dd28` plus instrumented-baseline commit `026d7352f5c1fd49c53bf94d5cba760de1f76757`) and the candidate worktree. For independent source identity, both used `RealHostTransportIntegrationTests.swift` blob `cfdd9690987e606fe824984029acb0659147762f` and runner blob `716dfe705dec57a00bf946e90fd7c65250029cd6`. Each result bundle records Swift `-O`, whole-module optimization, `-DDEBUG`, and `-enable-testing`. Final refreshed result bundles are retained at:

```text
/private/tmp/tessera-performance-live-baseline-rerun/programmatic/real-host-transports.xcresult
/private/tmp/tessera-performance-live-release-rerun/programmatic/real-host-transports.xcresult
```

Durable raw contrast-filter samples (milliseconds, sorted as logged by XCTest) are preserved here so the summary does not depend on `/private/tmp` surviving:

| Lane | Baseline samples | Candidate samples |
|---|---|---|
| Live-SSH-derived replay | 35.733, 35.773, 35.777, 35.782, 35.792 | 7.605, 7.618, 7.815, 7.888, 8.127 |
| 64 MiB, 128-byte chunks | 198.489, 200.126, 200.206, 200.799, 201.627 | 38.854, 39.489, 39.725, 39.858, 40.382 |
| 64 MiB, 1 KiB chunks | 154.227, 154.973, 155.118, 155.459, 155.832 | 30.708, 30.720, 30.735, 30.961, 32.087 |
| 64 MiB, 8 KiB chunks | 144.864, 145.973, 146.303, 146.436, 147.636 | 30.015, 30.055, 30.091, 30.150, 30.189 |

The checked-in Foundation benchmark prints all five samples. The final samples used by this report were:

- 153-byte diagnostic: before 1,104.760, 1,074.327, 1,072.413, 1,075.356, 1,073.516; after 639.936, 634.383, 634.257, 633.571, 630.577.
- 99-byte diagnostic: before 694.527, 692.190, 693.435, 689.126, 692.045; after 247.470, 247.511, 246.732, 245.818, 247.588.
- 119-byte diagnostic: before 889.058, 891.108, 889.645, 890.373, 891.301; after 437.213, 431.153, 430.994, 430.939, 430.880.
- ISO-8601 timestamp: before 2,775.178, 2,772.422, 2,771.629, 2,760.022, 2,765.528; after 28.199, 28.082, 27.936, 27.856, 27.937.
- Known Hosts dates, 100: before 5.585, 5.506, 5.516, 5.529, 5.826; after 0.081, 0.085, 0.081, 0.078, 0.091.
- Known Hosts dates, 1,000: before 55.355, 55.164, 55.492, 55.344, 54.936; after 0.801, 0.809, 0.804, 0.808, 0.792.
- Known Hosts dates, 10,000: before 576.682, 551.965, 551.077, 550.998, 551.250; after 8.119, 8.089, 7.993, 7.977, 8.046.
- Scroll-position-shaped proxy: 518.655, 518.164, 518.924, 519.037, 524.424.

SwiftTerm resize and retention commands use the isolated branch and Release package build:

```sh
GITHUB_ACTIONS=true SWIFTTERM_PERF_SCROLLBACK=50000 \
  SWIFTTERM_PERF_POPULATED_LINES=0 SWIFTTERM_PERF_ITERATIONS=50 \
  swift test -c release --filter measureResizeAgainstScrollbackCapacity

GITHUB_ACTIONS=true SWIFTTERM_PERF_SCROLLBACK=50000 \
  SWIFTTERM_PERF_TERMINALS=100 \
  swift test -c release --filter measureResetRetention

GITHUB_ACTIONS=true swift build -c release --target SwiftTerm \
  --triple arm64-apple-ios17.0-simulator \
  --sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.0.sdk \
  --build-path /private/tmp/swiftterm-performance-ios-release-clean
```

The SwiftTerm baseline was production commit `d135aeb` plus harness-enabling commit `5451b6ec2031f1a94e80ebd46921857effe08aa6`; the initial candidate was `a746405`, followed by safety commits `85b9ee1` and `2e7665f`. Baseline and the initial candidate used identical `PerformanceTest.swift` blob `77fe9cd67b3827ebb29aafc297f0ce3d8079c24d` and the same compile-only iOS conditional-guard repair (`iOSTerminalView.swift` blob `e8d9948b2dd09486d2752d5935ceae9059d350f3`). Baseline measured production `Buffer.swift` and `Terminal.swift` remained byte-identical to `d135aeb`. The benchmark prints its cold pair, p50, nearest-rank p95, maximum, configured capacity, populated count, and materialized count; correctness assertions run in the same process. `swift test -c release` is Release-optimized macOS coverage. The separate cross-compiled library command compiled the iOS-only renderer/view sources in Release mode and completed successfully.

The final comprehensive correctness command was:

```sh
TESSERA_INTEGRATION_OUTPUT_DIR=/private/tmp/tessera-r3-final-integration-2 \
./scripts/integration/run-integration-tests.sh
```

Its report is `/private/tmp/tessera-r3-final-integration-2/20260813T003842Z-4403/report.json`: all 29 deterministic lanes and all 9 aggregate visual cases passed against final SwiftTerm `2e7665f`.

## Implemented Tessera improvements

### 1. Zero-copy printable terminal output

`TerminalOutputContrastFilter` previously copied every input slice into a new input array, allocated an output array, scanned the bytes, and appended every byte even when the chunk contained no control sequence. Printable-only chunks now return the caller's `ArraySlice` directly when the streaming parser has no pending control prefix. ESC and C1 CSI bytes keep the complete existing parser path.

Release simulator benchmark, 64 MiB per sample:

| Chunk size | Before median | After median | Reduction | Before maximum | After maximum |
|---:|---:|---:|---:|---:|---:|
| 128 B | 200.206 ms | 39.725 ms | 80.16% | 201.627 ms | 40.382 ms |
| 1 KiB | 155.118 ms | 30.735 ms | 80.19% | 155.832 ms | 32.087 ms |
| 8 KiB | 146.303 ms | 30.091 ms | 79.43% | 147.636 ms | 30.189 ms |

Release-optimized in-process filter A/B using payload and chunk boundaries captured from the stable fixture over real SSH:

| Workload | Before | After | Reduction |
|---|---:|---:|---:|
| Filter median, approximately 16 MiB | 35.777 ms | 7.815 ms | 78.16% |
| Filter maximum of five, approximately 16 MiB | 35.792 ms | 8.127 ms | 77.29% |

The baseline received 16,777,512 bytes in 4,268 real SSH chunks; the candidate received 16,777,569 bytes in 4,278 chunks. The small difference is natural transport framing. Each exact checkout used one capture replayed five times in-process and validated every filtered chunk byte-for-byte against its input outside the timed region. Both checkouts used the Release optimization pipeline but ran through a DEBUG/testability XCTest seam, so these are optimized simulator component timings rather than end-to-end renderer or bit-for-bit App Store-binary measurements. The timer excludes the network, SSH ingest, session feed, SwiftTerm parser/renderer, Metal/CoreGraphics, and frame latency.

Correctness oracles cover a non-zero-based printable slice, a split ESC sequence, and C1 truecolor SGR rewriting. The existing ANSI/OSC behavior remains on the original path.

### 2. Gate default-off scroll snapshots before work

The synchronous SSH-family feed path captured a terminal scroll-position structure before checking whether scroll diagnostics were enabled. The snapshot reads terminal/UIKit state and creates `String(describing: mouseMode)`. The check now occurs first; diagnostics-on behavior and emitted comparisons are unchanged. The equivalent mosh path deliberately remains unchanged because its cooperative feed can yield: enabling diagnostics during that await must retain the old before/after logging semantics.

An optimized synthetic proxy shaped like the snapshot allocation measured 1,000,000 operations at a median 518.924 ms. The default-off path therefore avoids directionally about 0.519 microseconds of snapshot-shaped work per delivered chunk. This does not call UIKit or production `terminalScrollPosition` and is not an in-app latency measurement. The separate `UserDefaults` lookup remains and is not included as a claimed improvement.

### 3. Cache diagnostics regular expressions and timestamps

The diagnostic queue compiled six `NSRegularExpression` instances and configured one `ISO8601DateFormatter` per emitted line. These are now reused. Production diagnostic formatting is serialized by `app.tessera.diagnostic-log`, and the benchmark's sanitized outputs matched exactly before and after.

Optimized macOS benchmark medians:

| Workload | Repetitions | Before | After | Reduction |
|---|---:|---:|---:|---:|
| 153-byte diagnostic | 10,000 | 1,074.327 ms | 634.257 ms | 40.96% |
| 99-byte diagnostic | 10,000 | 692.190 ms | 247.470 ms | 64.25% |
| 119-byte diagnostic | 10,000 | 890.373 ms | 430.994 ms | 51.59% |
| ISO-8601 timestamp | 25,000 | 2,771.629 ms | 27.937 ms | 98.99% |

The table reports the upper median of five AB/BA-ordered runs. The sanitizer cases isolate the six changed regex compilations/replacements and intentionally omit the unchanged leading `SensitiveDataRedactor`; they are not end-to-end `sanitize` or simulator latency.

### 4. Cache the Known Hosts date formatter

Known Hosts previously constructed and configured a `DateFormatter` for every rendered date. The fixed Gregorian/POSIX `yyyy-MM-dd` formatter is now shared on the main actor. All formatted strings matched exactly.

Optimized macOS benchmark medians over five runs:

| Dates formatted | Before | After | Reduction |
|---:|---:|---:|---:|
| 100 | 5.529 ms | 0.081 ms | 98.53% |
| 1,000 | 55.344 ms | 0.804 ms | 98.55% |
| 10,000 | 551.250 ms | 8.046 ms | 98.54% |

## Implemented SwiftTerm improvements

Tessera now uses the bambouville fork at exact revision `2e7665f`. The dependency work was developed from its prior `d135aeb` pin rather than from upstream `main`.

### 1. Resize only materialized circular-buffer lines

Three resize/reflow loops walked `lines.maxLength`, materializing every empty scrollback slot. The final implementation visits only logically active lines plus the already-materialized overflow fringe reachable by margin-mode IL/DL; it never materializes empty scrollback slots. The initial `lines.count` backport of upstream `c6e35fde9fe9ab0442a57e1c6212a2dc9657e496` was hardened by `85b9ee1` and narrowed by `2e7665f` because ED3 and `pop()` can retain materialized objects immediately outside the logical count, while unrelated retired ring slots are not reachable terminal state.

Release results, 50 resize pairs per run and five runs:

| Configured scrollback | Populated history | Before p50 | After p50 | Speedup |
|---:|---:|---:|---:|---:|
| 1,000 | empty | 0.196917 ms | 0.008708 ms | 22.6x |
| 10,000 | empty | 2.248834 ms | 0.008667 ms | 259.5x |
| 50,000 | empty | 14.243250 ms | 0.008958 ms | 1,590x |
| 50,000 | 2,000 lines | 19.891708 ms | 0.596291 ms | 33.4x |

For the final empty-buffer implementation with 50,000-line configured scrollback, the median nearest-rank p95 fell from 16.445166 ms to 0.009292 ms and the median cold resize pair fell from 24.998000 ms to 0.023458 ms. The final candidate values come from five independent Release processes at `2e7665f`; visible content, cursor position, final 80x24 dimensions, and materialized count matched after every run. Two focused Release regressions additionally fill and rotate the complete ring, issue ED3, grow the width, and prove both the first retained overflow line and the subsequent DECLRMM/DECSLRM IL/DL path use the new width.

Durable raw values below are milliseconds in run-number order. Every outlier is retained; each line is `cold; p50; p95; maximum`:

- 1k empty baseline: `[0.223750, 0.223083, 0.224166, 0.228875, 0.224375]`; `[0.196333, 0.202584, 0.196917, 0.196875, 0.200500]`; `[0.213792, 0.230417, 0.211708, 0.211167, 0.219292]`; `[0.252792, 0.240959, 0.316167, 0.273959, 0.254042]`.
- 1k empty final candidate: `[0.018167, 0.018125, 0.017834, 0.022750, 0.028792]`; `[0.008625, 0.008708, 0.008708, 0.008500, 0.008916]`; `[0.009667, 0.008834, 0.013292, 0.014250, 0.010292]`; `[0.012584, 0.009250, 0.019000, 0.029208, 0.018042]`.
- 10k empty baseline: `[2.804167, 2.864833, 3.134459, 5.212333, 2.599458]`; `[2.248834, 2.116667, 2.177125, 6.122417, 6.506666]`; `[2.579167, 2.304833, 2.589042, 11.396333, 10.385375]`; `[2.725750, 2.382083, 2.622209, 13.344208, 12.062417]`.
- 10k empty final candidate: `[0.017292, 0.021542, 0.020209, 0.017625, 0.017833]`; `[0.008666, 0.008667, 0.008917, 0.008875, 0.008542]`; `[0.012583, 0.011375, 0.009084, 0.009000, 0.009084]`; `[0.016542, 0.012250, 0.015250, 0.009166, 0.013833]`.
- 50k empty baseline: `[31.399667, 24.998000, 25.378042, 22.511333, 21.070667]`; `[25.637250, 14.243250, 15.088167, 13.430750, 13.959875]`; `[41.829709, 16.445166, 24.997792, 16.114583, 15.199083]`; `[90.534625, 18.091708, 37.334250, 18.881917, 16.876333]`.
- 50k empty final candidate: `[0.024792, 0.022875, 0.023458, 0.018458, 0.029291]`; `[0.008666, 0.009000, 0.008459, 0.008958, 0.008958]`; `[0.008792, 0.009292, 0.008708, 0.009500, 0.009375]`; `[0.009042, 0.009666, 0.009083, 0.009750, 0.009666]`.
- 50k/2k populated baseline: `[25.285125, 37.975542, 34.803167, 29.032458, 26.607166]`; `[17.651792, 25.606250, 24.085541, 19.891708, 19.575250]`; `[20.040041, 46.511333, 45.910958, 23.345333, 23.449375]`; `[28.580000, 64.175250, 63.403208, 28.156041, 27.508333]`.
- 50k/2k populated final candidate: `[0.645500, 0.644917, 0.667250, 0.728625, 0.632833]`; `[0.606333, 0.598541, 0.594958, 0.596167, 0.596291]`; `[0.740959, 0.789708, 0.788958, 0.819125, 0.805458]`; `[0.752542, 0.863792, 0.927875, 0.875458, 0.907208]`.

### 2. Break the reset retain cycle

`resetNormalBuffer()` assigned a method reference to `normalBuffer.scroll`, creating `Terminal -> Buffer -> closure -> Terminal`; `resetToInitialState()` reaches that assignment through `setup(isReset: true)`. The callback now captures the terminal weakly. This is a minimal backport of upstream `1da8e026c09109e6dabbddc4be6a1a87bd895e06`.

Release retention oracle, 100 terminals configured with 50,000-line scrollback capacity:

| Result immediately after each autoreleasepool exits | Before | After |
|---|---:|---:|
| Retained terminals | 100 | 0 |
| Released terminals | 0 | 100 |
The one-shot runner duration was 1.387 s before and 0.086 s after; this is setup/teardown context, not a repeated performance statistic. Two strict retain-cycle tests pass, and the complete SwiftTerm Release suite passed after the safety follow-up: 38 XCTest tests plus 394 Swift Testing tests in 36 suites.

### 3. Conditional-compilation repair included in the dependency commit

The SwiftTerm candidate also moves one `#endif` in `iOSTerminalView.swift`. This is not a performance change: it keeps the fork's `UIEditMenuInteractionDelegate` conformance inside the existing iOS/visionOS platform guard, fixes cross-platform compilation of that fork patch, and changes no iOS/visionOS runtime behavior. Because the normal SwiftPM Release suite runs on macOS, the candidate was additionally compiled as the `SwiftTerm` library for an arm64 iOS 17 simulator target; that Release compile passed and included the iOS-only source.

### Integration status

SwiftTerm candidate commits `a746405`, `85b9ee1`, and `2e7665f` were published as fast-forwards of the bambouville fork's `tessera-csi-t-v113` branch. Tessera's project and resolved dependency are pinned to `2e7665f`; these are targeted backports, not a move to upstream `main`. The Tessera promotion remains local on `main` and has not been pushed.

## Deferred opportunities

These findings are evidence-backed enough to prioritize, but not low-risk enough to include without dedicated behavioral instrumentation:

| Candidate | Evidence / expected benefit | Why deferred |
|---|---|---|
| SwiftTerm DEC 2026 synchronized output | `beginSynchronizedOutput` snapshots every current `BufferLine` on each fresh block; upstream complete fix is `9446f60557ed1bbea1b4720bd5884c2b3d3428be`. | Paint suppression changes atomic-frame timing. Needs deep-scrollback Release A/B plus visual atomicity checks. |
| Coalesce SwiftTerm scroll callbacks within one feed | Every newline can update UIKit scroller state and notify the Tessera delegate before `feedFinish`. | Delegate timing semantics can affect scroll/UI state. Measure callback count, main-thread CPU, final offset, and screenshots. |
| CoreGraphics row/CTLine cache | Tessera never enables SwiftTerm's Metal renderer; the CoreGraphics path rebuilds attributed strings and CTLines for every visible row on each draw. | Invalidation must cover selection, links, themes, fonts, images, and cursor state. |
| Disabled SwipePad output refresh | With SwipePad off, continuous output can still schedule a delayed task and mutate a session-level state token about once per cooldown window. | Work count is clear, but no trustworthy Release wall-time or body-evaluation measurement was collected, so it was not changed. |
| Color-query responder printable fast path | An optimized 256 MiB component test suggested 16-61% lower scanner time depending on chunk size. | Needs the full split-query/poisoned-tail oracle and a Release in-app A/B before inclusion. |
| Gate routine tmux diagnostic construction | Routine strings are constructed and sanitized before default diagnostics decides to discard them. | Reordering the security boundary or lazily constructing messages needs exact diagnostics-on/off equivalence tests. |

Do not repin SwiftTerm wholesale to current upstream. Upstream `main` is about 70 commits beyond the fork point, none of Tessera's six fork patches is patch-equivalent, and it still lacks several Tessera correctness invariants (ED3 viewport notification, saved-row trim handling, circular-list clamp handling, bounded CSI T behavior, and Tessera keyboard/menu APIs). Targeted backports are safer.

## Validation

- Tessera stock Release simulator build passed.
- Release-optimized contrast-filter benchmark and three contrast-filter correctness oracles passed.
- Release-optimized live SSH A/B passed against a provisioned VPS with byte counts and exact output-to-input comparisons.
- SwiftTerm full Release suite passed: 432 tests total across XCTest and Swift Testing.
- Final comprehensive Debug correctness run `20260813T003842Z-4403`: all 29 of 29 deterministic lanes passed, including jump-host transports, pointer/touch terminal scroll wiring, and live app transport/tmux/files/forwarding coverage.
- Final aggregate visual review: 9 of 9 cases passed with no inconclusive verdicts, including primary/htop live scroll on SSH, SSH+tmux, mosh, and mosh+tmux; Vim on SSH, SSH+tmux, and mosh+tmux; and the iPhone keyboard/iPad tmux geometry case.
- Every run-scoped disposable simulator was shut down and deleted. The persistent `Tessera iPad Testing` and `Tessera iPhone Testing` simulators were not erased, reset, uninstalled, or deleted.

The contrast-filter optimization is shared by SSH, SSH+tmux, mosh, and mosh+tmux. Snapshot gating is intentionally SSH-family only; formatter changes are transport-neutral. None requires a compact-width variant.
