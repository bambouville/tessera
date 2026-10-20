# tmux buffer of record, shared: the render ledger

_Planning document, 2026-09-02. High-level design plus implementation guide for
ending cross-window / cross-pane scrollback contamination on Android and iOS with
one shared implementation. Supporting research (file:line evidence for every
claim below) lives in `docs/research/tmux-render-ledger/` (A: iOS fix history,
B: Android today, C: shared-core surface, D: mosh paths)._

---

## 1. Summary

**The bug.** On Android, scrolling up in one tmux window or pane shows other
windows' and panes' history, and it gets worse after every switch and reconnect.
iOS had the identical bug and fixed it on 2026-06-11 (`dca6f2a`) with one rule:

> tmux is the buffer of record. The client buffer is a cache rebuilt from the
> server at every continuity break. Replay into an empty buffer, never append.

**Why Android still has it.** Everything that makes that rule *hold* on iOS
(when to clear, what to capture, how to stage, how to drop late replies) lives in
the Apple-only `TmuxController.swift`. The shared core only exports the byte
assembler, and even that in a degraded form. Android re-implemented the swap in
Kotlin and never adopted the rule: it never empties the scrollback anywhere,
paints every window and pane of a session into one emulator with a screen-only
clear, fetches no server history on a switch, and treats reconnect as a
non-event for the buffer. This is the same drift pattern the shared-core survey
attributes ~20 of ~35 Android-era fixes to: policy left in the Apple half gets
rewritten, wrongly, on the Kotlin side.

**The fix, in one sentence.** Make buffer ownership a property of the shared
core and of a tiny per-platform seam, so contamination becomes impossible by
construction on both platforms rather than a matter of careful sequencing in
two controllers.

Concretely:

1. **Surface ownership invariant** (section 3): a terminal surface holds rows
   from exactly one `RenderOwner = (window, pane, epoch)` at a time. Binding a
   new owner empties the surface before the first byte. Feeds tagged with any
   other owner are dropped at the seam and counted. Two enforcement layers: the
   shared planner decides owners; the platform surface refuses foreign feeds.
2. **`TmuxRenderLedger`** (section 4): a pure reducer in `TmuxControlCore`,
   composed next to the existing `TmuxRuntimeEngine` under the same handle,
   consuming wire-ordered control-mode events plus platform facts and emitting
   ordered effects (`sendCommand`, `bindSurface`, `feed`, timers, ...). It is
   the iOS swap state machine (stages, generations, guards, retry, watchdog,
   pause, size-epoch atomicity) extracted unchanged, plus the mosh scrollback
   policy (epoch, depth ladder, single-flight, freeze-on-output) folded in as a
   transport *profile* rather than a fork.
3. **One transport branch point** (section 4.4): `inline` (SSH+tmux, the
   controller paints) vs `sideChannel` (mosh+tmux, mosh paints, the ledger only
   synthesises history). Plain SSH and plain mosh have no tmux and a single
   owner for the life of the session; the ledger is idle.
4. **Both controllers become effect executors** (section 6). iOS adopts the
   ledger first, under its own test suite (478 TmuxControl tests today), which is the only complete spec
   of the swap behaviour. Android adopts second and deletes its Kotlin twins.
5. **Proof, not hope** (section 8): checked-in vectors (`ProtocolVectors/tmux/
   render-ledger-v1.json`), seam tests on both emulators, and a marker-based
   live isolation gate on all four transports on both platforms.

Phasing (section 7): Phase 1 stops the Android bleeding in days with the seam
alone; Phase 2 extracts the ledger and proves it under iOS; Phase 3 moves
Android onto it and deletes the duplicates; Phase 4 brings Android's mosh
multi-pane scrollback to iOS parity.

---

## 2. Problem statement with evidence

### 2.1 What Android does today

`SC` = `android/feature-session/src/main/kotlin/com/bambouville/tessera/feature/session/SshSessionController.kt`.

| Event | Sent to tmux | Local buffer effect |
|---|---|---|
| Attach / hydrate | hydration queries, subscriptions, then per pane `display-message` + viewport `capture-pane -p -e -N` (`SC:1531-1543`, `:2374-2380`); deep `-S -N` only on the authority claim (`SC:1630-1645`) | append (`ESC[2J` + rows) |
| Window switch | `select-window` (`SC:1018`) | viewport-only recapture appended into the same transcript (`SC:1859-1861`, `:1535`, `:2382-2400`) |
| Pane focus switch | `select-pane` (`SC:1019`) | identical to window switch (detected only as "activePaneId changed", `SC:1859`) |
| `%layout-change` | nothing | nothing (`SC:2560-2615` is peer detection and diagnostics only) |
| Reconnect / reattach | `clearTmuxTransport()` resets controller latches (`SC:3293-3363`) | nothing; the emulator and its whole transcript survive; new viewport captures append on top |
| `%pause` / `%continue` | hydration ends with `refresh-client -f pause-after=5`; the shared ledger handles `%pause` and resumes only after the exact refresh terminal outcome | n/a |
| Mosh window change | `select-window` only; side channel is render-inert (`SC:2239`, `:1370`) | nothing (iOS clears here, `Tessera/SessionView.swift:4735`) |
| Mosh scrollback seed | deep `capture-pane -S -<1000..50000>` once per pane (`SC:2402-2409`, `:1786`) | appended straight into the live mosh terminal (`SC:1791-1830`), then `forceFullRepaint()` |

The only erase Android ever emits is the shared assembler's `ESC[2J`
(`Packages/TmuxControl/Sources/TmuxControlCore/RepaintAssembly.swift:185`),
which Termux implements as a visible-rows block clear
(`android/terminal/src/main/java/com/termux/terminal/TerminalEmulator.java:1591-1594`).
`mActiveTranscriptRows` is never touched. There is no `clearScrollback`, no
`ESC[3J`, no `clearTranscript()` call in any production Android path.

Buffer model: on a phone there is exactly **one** `TermuxTerminalSurface` for the
whole session (`SshSessionScreen.kt:259-267`), across every window, pane and
reconnect. On a tablet the shared surface is still the renderer whenever the
active window has one pane; only the multi-pane grid mounts per-pane surfaces
(`SshSessionScreen.kt:2167-2176`).

### 2.2 The contamination paths (from report B)

- **C1** one shared emulator, cleared only to the top of the visible screen.
- **C2** live `%output` for whichever pane is focused accumulates into that
  same transcript across switches (`SC:1524`).
- **C3** SSH+tmux never fetches deep history on a switch, so the contaminated
  local pile *is* the only scrollback the user can reach.
- **C4** reconnect re-appends without any reset.
- **C5** mosh deep capture of one pane is appended into a whole-window live
  terminal with no clear and no epoch, so a resize or re-focus stacks
  differently wrapped history.
- **C6** (unconfirmed) snapshot `activeWindow` falls back to the first window
  while `activeWindowId` is unknown (`SharedTmuxRuntime.kt:81-85`), so early
  `%output` from that window can satisfy the active-pane check.

### 2.3 What iOS does today, and where it lives

The iOS swap (report A, section c) is a three-stage state machine on top of the
shared runtime engine:

- `.viewport` on every window/pane switch: `display-message` (22-field
  metadata) then `capture-pane -p -e -N`, `displayWillSwap` clears the scrollback
  via the SwiftTerm `changeScrollback(0) -> changeScrollback(limit)` toggle
  one statement before the feed, then a chained `.deep` stage
  (`capture-pane -S -2000`) rebuilds history asynchronously.
- `.deep` as a single stage on attach/reconnect and on `%pause` of the rendered
  pane; the launch overlay stays up until it completes.
- `.viewportOnly` for foreground restore of the same window+pane+alt-state: no
  clear, no history replay, no 1049 toggle (`6e1c9c0`).
- Every continuation re-checks generation, control path and active window;
  the size epoch must not move between metadata and capture; a zero-row
  capture is never authoritative; `%output` for the rendered pane is dropped
  while a swap is in flight; per-window kitty and bracketed-paste modes are
  saved and restored at the swap.

Shared today (`TmuxControlCore`, crosses the C ABI): parser, frame correlation
with the `flags` bit0 rule, topology and routing (`TmuxRuntimeEngine`, which
both controllers already drive: `TmuxController.swift:459`, `:1232`,
`SC:1483`), the rendered-pane metadata parser, the repaint assembler with seam
neutralisation, client-size replay, hydration queries.

Apple-only (`Packages/TmuxControl/Sources/TmuxControl/TmuxController.swift`):
`RenderStage`, `refreshRenderedWindow`, `captureRenderedWindow` and the
capture command strings, the 22-field metadata format string, generation
guarding, `pendingRenderRefresh` and the `%output` gate, attach latch and
watchdog, abort/retry, `clientSizeEpoch` atomicity, `%pause` policy,
foreground coalescing, the per-pane grid path, and the hooks
(`feedTerminal`, `displayWillSwap`, `displayDidSwap`, `terminalIsInAltScreen`).
The mosh scrollback policy (epoch, depth ladder, single-flight, freeze) is in
`Tessera/SessionView.swift`, inside a SwiftUI view, and is not unit-testable.

The C ABI's repaint export hard-codes `historyLines: []`,
`savedPrimaryLines: []`, `altScreenLines: nil`
(`Packages/TesseraCore/Sources/TesseraCoreABI/TmuxRepaintABI.swift:32-39`), so
Android could not express the alt-screen ladder even if it wanted to.

### 2.4 Why "port it to Kotlin" is not the answer

It was already tried in the small: the viewport capture (`f69ecf4`), then the two
deep captures (`f3807d1`), then compact geometry, then authority. Each time the
Kotlin twin diverged until that area moved into the core
(`docs/ios-android-shared-core-survey.md:19-25`). The swap is the largest
remaining tmux policy outside the core and the survey does not even list it
(report C, section a). A Kotlin port of the ~2k-line iOS state machine would be
the third implementation of this rule, pinned by Kotlin-only tests, with no
cross-language gate.

---

## 3. The invariant: surface ownership

**Definition.** A *render surface* is one emulator buffer pair (primary +
alternate) with its scrollback. A `RenderOwner` is
`(windowId, paneId, epoch: UInt64)`. At every instant a surface is *bound* to at
most one owner.

**Rules.**

1. `bind(owner)` on a surface with a different owner empties the scrollback,
   resets the per-window terminal modes the platform tracks (kitty flags,
   bracketed paste), and leaves the grid size intact. The next feed is
   authoritative for the visible screen. `bind` with the same owner is a no-op.
2. Every feed into a bound surface carries an owner. A feed whose owner differs
   from the bound owner is **dropped at the seam** and counted in diagnostics.
   It is never fed, never queued.
3. An *untagged* feed is allowed only from the surface's *painter*: the PTY on
   plain SSH and plain mosh, mosh SSP on mosh+tmux. On inline `-CC` there is no
   painter; every byte comes from the ledger (repaints) or from `%output` that
   the ledger routes with the owner it belongs to.
4. The `epoch` is bumped by the ledger at every continuity break that does not
   change `(window, pane)` (section 4.2), so a reconnect to the same pane still
   rebinds and empties.

**Why this is "once and for all".** Contamination is, by definition, a feed of
rows from owner X into a surface bound to owner Y. Rule 2 makes that a dropped
feed with a diagnostic, whatever the planner did. Rule 1 makes a late reply
from a previous owner land in an emptied surface, never on top of stale rows.
The planner's job reduces to *choosing owners correctly and early*; a planner
bug produces a missing repaint (visible, recoverable, counted), never a mixed
buffer. iOS has the planner today but not the seam; Android has neither. Both
get both.

**What the invariant deliberately does not promise.** Scroll position is not
preserved per window across switches (the cost of a server-authoritative
rebuild, accepted on iOS since `dca6f2a`). On mosh the visible screen is mosh's,
so a window change can only *empty* the local scrollback; history is
re-synthesised on demand.

---

## 4. Design

### 4.1 Components

```
                 wire bytes (SSH -CC channel, inline or side channel)
                              |
      +-----------------------v------------------------+
      |  TmuxRuntimeEngine (shared, unchanged)          |   parser, frames, topology,
      |  feed(bytes) -> TmuxRuntimeBatch.orderedEvents  |   routing, authority, snapshot
      +-----------------------+------------------------+
                              |  ordered events + snapshot
      +-----------------------v------------------------+
      |  TmuxRenderLedger (shared, NEW)                 |   owners, stages, generations,
      |  reduce(.wire(event) | .fact(fact)) -> [Effect] |   FIFO purposes, epochs, timers,
      |  uses TmuxRepaintAssembly, RenderCommands       |   mosh depth/freeze policy
      +-----------------------+------------------------+
                              |  [RenderEffect] in order
      +-----------------------v------------------------+
      |  Platform executor (thin)                       |   iOS: TmuxController + SessionView
      |  runs effects synchronously, in order           |   Android: SshSessionController
      +---------+--------------------------+-----------+
                |                          |
      +---------v---------+      +---------v-----------+
      | Transport         |      | RenderSurface seam  |   iOS: TerminalBox over SwiftTerm
      | write(commands)   |      | bind / feed(owner)  |   Android: TermuxTerminalSurface
      +-------------------+      +---------------------+
```

The ledger is a value type with a `mutating reduce`. It owns no channel, clock,
timer, surface or view state, exactly like `TmuxGridAuthorityLifecycleReducer`
(`Packages/TmuxControl/Sources/TmuxControlCore/AuthorityLifecycleReducer.swift:3-8`).
It is composed with the engine, not inside it: the ABI handle `CTmuxABIRuntime`
and the iOS `TmuxController` both hold `engine` and `ledger` and feed the
ledger the engine's `orderedEvents` under the same lock. `TmuxRuntimeEngine`
stays extract-unchanged (the mitigation the protocol architecture names for
"tmux refactor becomes a rewrite").

### 4.2 RenderOwner, epochs and continuity breaks

The ledger keeps, per surface: `boundOwner`, `renderedStage`, `generation`,
`pendingRefresh`, `sizeEpoch`, and for the side-channel profile `depth`,
`historySize`, `frozen`, `inFlight`, `pendingPresentationOwner`, and
`outputWhilePresentationPending`. A completed side-channel capture is *staged*,
not yet revealed: it has earned its depth credit and emitted its bytes, but it
does not become synthesised history until the adapter acknowledges that the
exact owner was actually fed into the terminal surface.

Events that change the owner or bump the epoch (both profiles unless noted):

| Break | inline | sideChannel |
|---|---|---|
| `%session-window-changed` (own session only) | new `(window, pane)`; `.viewport` then `.deep` | new key; **clear only** (bind to the new key, no repaint), latched against `nil` so reattach-to-same-window and roams never fire |
| `%window-pane-changed` on the active window | new key; `.viewport` then `.deep` | new key; clear only if the live buffer held synthesised history |
| rendered window closed | new key | new key |
| transport attached / reattached / rehydrated | epoch++ ; single `.deep` | epoch++ ; parked history invalidated (output during the outage arrives via SSP with no `%output`) |
| `%pause` of the rendered pane | epoch++ ; `.deep` | n/a (side channel is render-inert) |
| client size changed between metadata and capture | frame discarded, re-run, bounded 3 | epoch++ ; history invalidated (wrap width baked into the capture) |
| app foreground, same window+pane+alt-state | same owner; `.viewportOnly` in place | no change |
| app foreground, identity changed | new key | no change |
| grid <-> single-pane presentation change | surfaces re-declared by the platform; new owners | epoch++ |
| user input on the pane (mosh) | no change | epoch++ (parked capture is stale) |
| output from the rendered pane while a mosh capture is staged | n/a | remember dirty output; do not freeze or invalidate before the exact presentation acknowledgement |
| output from the rendered pane while history is revealed (mosh) | n/a | **freeze**: owner unchanged, all further fetches refused until the reader returns to the live tail |

Plain SSH and plain mosh: the ledger never leaves its idle state and the
surface remains unbound, so the PTY retains painter ownership. Reconnect on
plain transports keeps appending, which is correct: there is no server buffer
of record to rebuild from, the local scrollback *is* the record.

### 4.3 Stages and triggers (inherited from iOS, unchanged)

`RenderStage = .viewport | .viewportOnly | .deep` with the exact trigger table
in report A, section c.1, and the exact guard chain in c.2 and c.5:

- inline only; defer while `awaitingAppForegroundRefresh`; bail for pane-grid
  windows in favour of per-surface refresh (now: the same ledger with N
  surfaces, see 4.7); `pendingRefresh` latch; bounded wait for the command
  FIFO to drain before an established non-deep refresh; snapshot `sizeEpoch`.
- metadata reply: generation, profile, active-window guards; tab-less reply
  latches `commandRepliesSanitized` (fail closed, no capture may paint);
  `.viewportOnly` promoted to `.viewport` when window/pane/alt-state disagree.
- capture reply: `CaptureBodyPolicy.requiredGrid` rejects zero rows;
  supplemental alt-history and `-a -q` bodies are optional.
- finish: size-epoch atomicity; `.viewportOnly` replays coalesced foreground
  output first; `bindSurface` (the clear) is emitted **adjacent** to the feed,
  never at request time; assemble; feed; ghost scrub from a fresh chained
  viewport capture (never a suffix slice of the deep capture); mark initial
  render ready; resume a paused pane; restore per-window modes; chain `.deep`.
- `%output` for the rendered pane is dropped while a `.viewport` or `.deep`
  refresh is pending (the FIFO cut: everything before the capture reply is in
  the capture; everything after is applied live). It keeps flowing during
  `.viewportOnly`.

All sixteen failure modes in report A, section g, become reducer tests
(section 8.1). The byte order produced by `TmuxRepaintAssembly` does not change;
the existing golden vector `ProtocolVectors/tmux/repaint-v1.json` stays valid.

### 4.4 Transport profiles: the single branch point

`RenderProfile` is set by the `transportAttached` fact. The ledger has exactly
these profile-dependent behaviours (report D, section 6); everything else is
common.

| Aspect | `.inline` (SSH+tmux) | `.sideChannel` (mosh+tmux) |
|---|---|---|
| viewport stage | client repaints from `capture-pane` (+ alt-screen ladder) | **disabled**; mosh SSP paints |
| history stage | `capture-pane -p -e -N -S -<depth>` into the emptied live surface, chained after viewport | one capture `-S -<depth>` **including** the live viewport rows (no `-E`), into the target surface |
| trigger | every observed swap, attach, reconnect, pause | scroll-up reveal, find-open, optional prefetch; `.viewport` never |
| alt-screen pane | rebuilt (history -> saved primary -> `?1049h` -> alt) | **refused**; `.skipped(.alternateScreen)`, state cached for routing |
| clear on window change | bind + repaint | bind (clear) only, latched |
| render target | the live surface (or per-pane surfaces on a grid) | `.live` for single-pane windows; `.detached(pane)` overlay for multi-pane windows (platform binding, see 4.7) |
| post-feed | none | `requestTransportFullFrame` effect (mosh re-syncs the viewport); iOS single-pane may omit it, Android must not. `historyReady` is only a staging hint: the adapter sends `historyPresented` only after the exact owner has passed the feed seam and its terminal/overlay presentation is published. |
| depth | `deepRepaintHistoryDepth = 2000`, capped by the user's scrollback limit | first fill one page (240), any deepen jumps to `max(240, scrollbackLines)`; `historySize <= requested` credits full depth |
| single-flight | one refresh pending per surface, retry policy | one capture in flight per pane, plus a 4 s owner/generation-correlated repaint-receipt watchdog after `requestTransportFullFrame`; it retries the repaint receipt only, never the already staged capture |

Design decision: Android's current mosh seed (`-S -<1000..50000>`, one shot,
never invalidated) is replaced by the ledger's page-then-parity ladder. A 50k
line capture on a phone link is seconds of stall; the ladder is what iOS ships.

### 4.5 Effects and facts

Effects, emitted in order, executed synchronously by the platform in that order:

```swift
public enum RenderEffect: Equatable, Codable {
    case sendCommand(String)                                   // ledger-originated; write to the transport now
    case commandReply(tag: UInt64, success: Bool, lines: [String]) // answer to a platform-originated command
    case bindSurface(SurfaceId, owner: RenderOwner)            // empty scrollback + reset modes; no-op if same owner
    case feed(SurfaceId, owner: RenderOwner, bytes: RenderBytesRef, source: FeedSource)
    case saveWindowModes(SurfaceId, window: WindowId)          // kitty / bracketed paste hook (no-op where unsupported)
    case restoreWindowModes(SurfaceId, window: WindowId, paneInAltScreen: Bool)
    case resolveSurfaceState(SurfaceId, request: UInt64)       // platform answers with .surfaceState in the same turn
    case armTimer(token: UInt64, milliseconds: Int)
    case cancelTimer(token: UInt64)
    case initialRenderReady
    case requestTransportFullFrame                             // mosh only
    case historyReady(SurfaceId, owner: RenderOwner, depth: Int, historySize: Int, placement: Placement) // mosh presentation hint
    case refreshCompleted(SurfaceId, owner: RenderOwner, stage: RenderStage, correlation: UInt64)
    case refreshFailed(SurfaceId, correlation: UInt64, reason: String)
    case diagnostic(String)                                    // privacy-safe, routed to TmuxDiagnostics.sink
}
```

`RenderBytesRef` is an opaque id. In-process (iOS) the batch carries the bytes
alongside. Over the ABI the platform pulls them with a two-pass raw copy
(section 4.8), so capture payloads never inflate into the event JSON.

Facts, submitted by the platform:

```swift
public enum RenderFact: Equatable, Codable {
    case transportAttached(RenderProfile), transportLost
    case surfacesDeclared([SurfaceDeclaration])   // which surfaces exist and which pane each presents (single, grid, overlay)
    case clientSize(columns: Int, rows: Int)      // ledger bumps sizeEpoch and emits the shared client-size replay
    case surfaceState(SurfaceId, request: UInt64, altScreen: Bool, mouseMode: MouseMode, columns: Int, rows: Int)
    case appForeground, appBackground
    case timerFired(token: UInt64)
    case scrollbackRequested(SurfaceId, pointsY: Double, isInertial: Bool)   // mosh reveal / deepen
    case scrollbackReturnedToTail(SurfaceId)      // mosh: unfreeze, re-arm
    case findOpened(SurfaceId)
    case userInput                                // mosh: invalidate parked history
    case historyPresented(SurfaceId, owner: RenderOwner) // mosh: exact owner was fed and made presentable by the adapter
    case historyPresentationFailed(SurfaceId, owner: RenderOwner) // mosh: exact staged owner can no longer be presented
    case refreshRequested(SurfaceId, stage: RenderStage, reason: String)
    case correlatedRefreshRequested(SurfaceId, stage: RenderStage, reason: String, correlation: UInt64)
}
```

`correlatedRefreshRequested` is for platform transactions that need a precise
answer, such as an authority reclaim. It produces exactly one terminal outcome
for that correlation: `refreshCompleted` carries the bound owner and completed
stage; `refreshFailed` carries the refusal reason. Uncorrelated refreshes keep
the ordinary asynchronous path.

`historyReady` and `historyPresented` intentionally form a two-phase mosh
delivery contract. On a successful capture the ledger emits the owned feed,
`requestTransportFullFrame`, and `historyReady`, then records the owner as
*staged*. The adapter may mount or park an overlay and must submit
`historyPresented(surface, owner)` only after the feed has passed the ownership
seam and that surface has actually been updated/published. The reducer accepts
the acknowledgement only when both the surface's current owner and its staged
owner exactly equal the fact's `(window, pane, epoch)`; a stale, missing, or
foreign acknowledgement is diagnosed and changes nothing.

If the physical view disappears, its owner changes, the feed seam refuses the
bytes, or placement cannot complete, the adapter instead submits
`historyPresentationFailed(surface, owner)`. Only the exact staged owner may
release that latch; stale failures are diagnosed and ignored. A matching
failure discards the staged bytes and depth credit so a later deliberate
gesture starts a fresh capture rather than remaining permanently wedged.

While staged, later `%output` is remembered as dirty but cannot cancel the
capture or freeze a surface which has not yet presented it. A matching
`historyPresented` makes the history revealed and, if dirty output was
remembered, freezes immediately. Thus a late presentation cannot expose an
apparently live historical buffer, and an output race never turns a successful
capture into a silent loss. Rebind, epoch invalidation, return-to-tail, loss,
or surface removal clears the staged acknowledgement requirement; no delayed
fact may revive it.

`resolveSurfaceState` replaces iOS's `terminalIsInAltScreen?()` read at finish
time. It is a one-turn hop: the ledger emits it when a capture reply lands, the
platform answers synchronously, the ledger emits `bindSurface` + `feed`. This
keeps the core free of any emulator query while preserving the load-bearing
"emit `?1049l` only when actually on the alt buffer" rule.

### 4.6 Command FIFO ownership

tmux answers control commands in send order, so correlation is a FIFO. Today
there are two FIFOs per platform (iOS `pendingCommands` with completion
closures, `TmuxController.swift:473`; Android `pendingTmuxResponses.poll()`,
`SC:1529`) and the ledger's captures must interleave with platform commands
(`select-window`, resize replays, authority stamps, agent-center queries) on
the same channel. The only sane owner of that FIFO is the engine side.

- `engine.enqueue(command) -> tag` records `(tag, purpose: .platform)`; the
  platform writes the text to the transport immediately.
- Ledger-originated commands are enqueued internally with `purpose: .ledger`
  and surface as `.sendCommand(text)` effects; the platform writes them in
  effect order. Because both enqueue paths run under the same lock and the
  platform writes in the same order, the FIFO stays aligned.
- The existing correlator pops only on client-response frames (`flags` bit0,
  guard-matched). Platform-purpose replies come back as `.commandReply(tag, ...)`.
  Ledger-purpose replies are consumed internally and never cross the ABI.
- iOS `sendControlCommand(_:completion:)` becomes a `[tag: completion]` map over
  `.commandReply`. Android's `TmuxResponsePurpose` enum shrinks to the
  platform-only purposes (authority, window-size policy, cwd probe, ...).
- The ledger reads FIFO depth for its bounded "drain before an established
  swap" wait, so `sendBackgroundControlQuery`'s "skip while an authoritative
  refresh is pending" rule moves into the ledger too.

### 4.7 Surface set

A session presents a *set* of surfaces, declared by the platform via
`surfacesDeclared`:

- **single**: one surface presenting the focused pane of the active window
  (phone always; tablet when the active window has one pane or is zoomed).
- **grid**: one surface per pane of the active window (iPad SSH grid; Android
  tablet `PANE_GRID`). The ledger runs the same stage machine per surface; this
  unifies iOS's separate `refreshPane`/`capturePane`/`finishPaneRefresh` path.
- **overlay** (`.detached(pane)`): a second surface framed to a pane rect, used
  by the side-channel profile on multi-pane windows for synthesised history.

The declaration changes on layout change, zoom, rotation, or a grid/single
collapse; the ledger rebinds owners accordingly. Owner keys include the pane,
so a compact device that pans a whole mosh window to the focused pane still
keys history per pane. A declaration or bind that removes or changes a
side-channel surface also discards any staged presentation for its old owner;
an acknowledgement may never make a newly declared surface reveal old bytes.

### 4.8 C ABI additions (mirroring existing patterns)

Handle family: extend `tessera_tmux_runtime_*` (report C, section b, item 12).

```c
int64_t tessera_tmux_runtime_send_command(void *h, const uint8_t *text, size_t n);      // -> tag, or -1/-2
int32_t tessera_tmux_runtime_submit_fact(void *h, const uint8_t *json, size_t n);       // 0 / -1 / -2
int32_t tessera_tmux_runtime_take_render_bytes(void *h, uint64_t bytes_ref,
                                               uint8_t *out, size_t capacity);          // two-pass copy-out
```

- The existing callback event (`TmuxABIEvent`) gains `renderEffects: [...]` in
  wire order, alongside `orderedEvents`. `responseFrames` shrinks: frames the
  ledger consumed are no longer emitted, which removes the only place the 1 MiB
  ceiling is silently exceeded today (report C, section b, item 14).
- Once a callback promises a render-byte ref, the handle retains it until the
  adapter takes it, the transport is lost, or the handle is destroyed. Newer
  owner/generation work never revokes an already delivered ref; bounded
  resource exhaustion rejects the new batch instead. `take` honours
  `SharedABI.maximumInputBytes` on the copy.
- `tessera_tmux_assemble_repaint` is kept for compatibility and marked legacy;
  the ledger calls the assembler internally with all five inputs, so the
  alt-screen ladder reaches Android without a new pure export.
- `TmuxRenderedPaneStateParser`'s 22-field format string moves into the core
  as `RenderCommands.renderedPaneMetadataFormat`; the capture command builders
  (`viewport`, `deepPrimary`, `deepAltHistory`, `savedPrimary`, `moshHistory`)
  join it. Android deletes `SC:3575-3583` and every inline `capture-pane`
  string.
- Version: bump `TESSERA_CORE_ABI_VERSION` to 2 (the event schema changes),
  with the downgrade/rejection test the branch contract requires.
  `scripts/check-abi-header.sh` makes the header side mechanical. The v2 core,
  C header/JNI shim, and Kotlin bridge ship from the same source revision as one
  artifact; they are not independently versioned components, so mixed
  core/bridge pairs are rejected rather than tolerated as ABI skew.
- Threading: the callback stays borrowed-bytes, serialized, no UI affinity. The
  Android executor must drain one batch's `renderEffects` in **one**
  `Dispatchers.Main.immediate` block, not one `launch` per effect, so effects
  stay ordered relative to each other and to `%output` in the same batch
  (today `paneOutputs` and `responseFrames` are dispatched as separate
  launches, `SC:1516-1560`, which is itself an ordering bug).

### 4.9 Platform seam contract (`RenderSurface`)

```swift
protocol RenderSurface {
    var boundOwner: RenderOwner? { get }
    func bind(owner: RenderOwner)               // empties scrollback, resets tracked modes, keeps grid; no-op if same owner
    func feed(owner: RenderOwner?, _ bytes: ArraySlice<UInt8>)  // nil = painter; foreign owner -> drop + count
    func resize(columns: Int, rows: Int)
    var state: SurfaceState { get }             // altScreen, mouseMode, columns, rows
    var droppedForeignFeeds: Int { get }        // diagnostics
}
```

**iOS** (`TerminalBox`, `Tessera/SessionView.swift:8526`): `bind` calls the
existing `clearScrollback(restoringLimit:)` toggle (`:8697-8701`) and the
`KittyWindowModeStore` save/restore; `feed` gains the owner check. The mosh
overlay box and per-pane grid boxes are the same type, so the seam covers all
three surface kinds. `CSI 3 J` stays forbidden as the clear primitive for the
documented reason (`358796e`): the toggle is the only trim that keeps
`contentOffset` correct on every fork revision.

**Android** (`TermuxTerminalSurface`, `android/terminal/src/main/kotlin/.../TerminalSurface.kt`):

- fork addition `TerminalEmulator.clearScrollback()` =
  `mMainBuffer.clearTranscript()` (`TerminalBuffer.java:487-495`, already
  present, currently unreachable from Kotlin because `mMainBuffer` is private
  and `getScreen()` returns the alt buffer while a TUI owns the screen). It
  targets the main buffer so it is correct during alt screen, unlike
  `emulator.screen.clearTranscript()`.
- `bind` = `clearScrollback()` + `TerminalView.mTopRow = 0` + invalidate. The
  view's `onScreenUpdated` already clamps `mTopRow` to the remaining history
  (`TerminalView.java:848-882`), so no black-screen analogue of the SwiftTerm
  `[3J` bug exists here; verify with the seam test in 8.2.
- `feed(owner, bytes)` performs the owner check before `session.write`.
- `state.altScreen` already exists (`TerminalSurfaceState.alternateScreen`);
  add `mouseMode` and grid size.
- No kitty keyboard protocol in the Termux fork today: `save/restoreWindowModes`
  are no-ops until it gains one.

---

## 5. Transport matrix

What the user sees after the plan, per transport and event. "Rebuild" means
bind (empty) then repaint from the server; "history" means server scrollback
via `capture-pane`.

| Event | plain SSH | SSH+tmux (inline) | plain mosh | mosh+tmux (side channel) |
|---|---|---|---|---|
| window switch | n/a | rebuild viewport now, history chained | n/a | mosh paints; local scrollback emptied (latched); history re-synthesised on scroll-up |
| pane focus switch | n/a | rebuild (same as window) | n/a | empty only if the live buffer held synthesised history; overlay keyed per pane |
| split / layout change | n/a | surfaces re-declared; per-surface rebuild | n/a | epoch++, full mosh frame requested |
| reconnect | append (local scrollback is the record) | epoch++, single deep rebuild under the launch overlay | mosh resumes; no local change | side-channel reattach: epoch++, parked history invalidated; mosh roam: nothing |
| resize | reflow/none (emulator) | client-size replay with the latest fence; frame discarded and re-run if the epoch moved mid-frame | mosh reflow | epoch++ (wrap width baked into captures) |
| `%pause` | n/a | epoch++, deep rebuild; background panes resumed on swap-in | n/a | n/a |
| alt-screen app (htop, vim) | native | rebuilt with the 1049 ladder; kitty flags restored only if still on alt | native | history refused; wheel forwarded; scroll proxy stays platform-side |
| foreground restore | none | `.viewportOnly` in place when identity matches | none | none |
| find | local | re-run after every swap | local | full-depth seed into the current target surface |

The only rows where mosh differs from inline are exactly the profile table in
4.4; the ledger has no other transport conditionals.

---

## 6. Code-sharing map

### 6.1 Moves into `TmuxControlCore` (new files)

| File | Content | Source it replaces |
|---|---|---|
| `RenderLedger.swift` | `TmuxRenderLedger`, `RenderOwner`, `RenderStage`, `RenderProfile`, `SurfaceId`, `RenderEffect`, `RenderFact`, `CaptureBodyPolicy`, retry/watchdog constants | `TmuxController.swift:144-160`, `:770-1033` (constants and latches), `:4723-4731`, `:4980-5129`, `:5785-5862`, `:6501-6543`, `:7623-8440` |
| `RenderCommands.swift` | 22-field metadata format, `viewport`/`deepPrimary`/`deepAltHistory`/`savedPrimary`/`moshHistory` capture builders, `pause-after` and `continue` commands | `TmuxController.swift:889-912`, `:7867`, `:7897`, `:8025`, `:8110`, `:6540`; `SC:1535`, `:1635`, `:1786`, `:3575-3583` |
| `RenderCommandQueue.swift` | tag-purpose FIFO over `TmuxCommandResponseCorrelator`, bounded-drain query | `TmuxController.swift:473-1900` (queue parts); `SC:1529` |
| `MoshScrollbackPolicy.swift` (inside the ledger's side-channel profile) | epoch, page/parity depth, credit rule, single-flight + watchdog, freeze-on-output, invalidation set | `Tessera/SessionView.swift:6343-7440` (policy parts only) |
| `WindowModeStore.swift` | per-window kitty / bracketed-paste bookkeeping with the alt-guarded restore rule | `Tessera/SessionView.swift:8760-8802` |

`TmuxRuntimeEngine`, `TmuxRepaintAssembly`, `TmuxControlParser`,
`CommandCorrelation`, `ClientSizeReplay` are unchanged.

### 6.2 ABI and Kotlin facade

- `TesseraCoreABI/TmuxRuntimeABI.swift`: compose the ledger into
  `CTmuxABIRuntime`; add the three exports; extend `TmuxABIEvent`.
- `TesseraCoreCABIHeaders/include/TesseraCoreABI.h`: prototypes, version 2.
- `android/core-bridge/.../SharedTmuxRuntime.kt`: `RenderEffect` /
  `RenderFact` data classes (field-for-field mirror, sorted keys, absent
  optionals omitted), `sendCommand`, `submitFact`, `takeRenderBytes`.
- `android/core-bridge/src/main/cpp/tessera_core_jni.cpp`: three thunks.

### 6.3 Platform adapters after adoption

**iOS `TmuxController.swift`** keeps: transport I/O, the `@Observable`
projection of the snapshot, foreground/inactivity plumbing, PTY sentinel
scanning, agent-center query surface, diagnostics. Deletes the render section
listed in 6.1 (roughly 2k lines) in favour of a ~300-line effect executor.
`SessionView.swift` keeps all mosh *presentation* (overlay mounting, opacity
gating, `.bottomMinus` placement, dormant parking, native scroll plumbing,
settle poll, alt-screen scroll proxy) and submits facts instead of running
policy; its two duplicated fetch/apply paths (`:7076` overlay vs `:7293`
underflow) collapse into one executor of `historyReady`. It submits
`historyPresented` only after the owner-tagged feed is admitted to the live
terminal or the deferred overlay is actually positioned and revealed;
creating an overlay, queueing work, or merely receiving `historyReady` is not
an acknowledgement. Failed or abandoned placement submits the exact-owner
`historyPresentationFailed` fact.

**Android `SshSessionController.kt`** deletes `capturedPanes`, `capturePane`,
`recapturePane`, `feedTmuxRepaint`, `seedMoshScrollback`,
`moshScrollbackSeededPane`, the `PaneMetadata` / `CapturePane` /
`MoshScrollbackMetadata` / `MoshScrollbackCapture` purposes and every inline
capture string; gains an effect executor and fact submission on the same
`Main.immediate` hop it already uses. `SshSessionScreen.kt` declares surfaces
(single / grid / overlay) to the controller instead of the controller
inferring them. Android retains each owned, staged mosh delivery until the
matching terminal feed succeeds, the terminal view applies its top row, and
only then submits `historyPresented`. Its mosh
full-frame fence is correlated to that exact owner and transport generation:
if the requested target repaint is absent or no matching receipt arrives within
4 s, it re-arms only that repaint fence and retries the full-frame request.
It retains the staged bytes and depth credit, never sends another
`capture-pane`, and discards the retry when the owner, generation, or surface
is no longer current. A missing/rebound surface, refused feed, or stale posted
view callback submits `historyPresentationFailed` for that exact staged owner.

### 6.4 Stays platform, by design

Emulator internals, the clear primitive, kitty support, scroll physics, hit
testing, overlay mounting cost, launch overlay UI, localisation of any
user-facing wording, diagnostics sinks.

---

## 7. Implementation guide (phases and milestones)

Each phase ends at a point the user can exercise in the simulator or on a
device. Phase ordering rationale: the seam stops the Android bleeding in days;
the ledger is then proven where the only complete behavioural spec lives (the
iOS test suite) before the platform without a spec adopts it.

### Phase 1: seam on both platforms; Android stops bleeding

Goal: contamination impossible on all four Android transports; iOS gains the
seam check it never had. No shared-core changes yet.

1. Termux fork: add `TerminalEmulator.clearScrollback()` (main buffer
   transcript clear); expose through `TerminalSession`.
2. `TerminalSurface`: add `bind(owner)`, owner-checked `feed`, `boundOwner`,
   `droppedForeignFeeds`, `state.mouseMode`. Implement on
   `TermuxTerminalSurface`; the debug harness surface mirrors it.
3. `SshSessionController`: derive an interim owner locally as
   `(activeWindowId, activePaneId, tmuxTransportGeneration)`; call `bind`
   immediately before every `feedTmuxRepaint` and before the mosh seed; tag
   `%output` feeds with `(window(paneId), paneId, generation)`; on mosh, mirror
   iOS's latched window-change clear (`lastScrollbackWindowId`). This ~40-line
   derivation is temporary and is deleted in Phase 3; the seam is permanent.
4. iOS `TerminalBox`: add `bind(owner)` wrapping `clearScrollback(restoringLimit:)`
   and the kitty store; owner-checked `feed`; tag feeds from
   `feedTerminalWithContext` with `(windowId, paneId, stateGeneration)` from
   the existing `TerminalFeedContext`.
5. Diagnostics on both platforms: `render_surface bind owner=... previous=...`
   and a `dropped_foreign=N` counter in the periodic summary, visible in
   Settings > Diagnostics.
6. Tests: seam tests (8.2). Android instrumented marker isolation case (8.4)
   against the fixtures, SSH+tmux and mosh+tmux.

Milestone check (Pixel + iPad): sections A and B from
[`tmux-render-ledger-verification-checklist.md`](tmux-render-ledger-verification-checklist.md)
on Android. Known interim limitation to
state in the handoff: after a switch on SSH+tmux, Android's scrollback is
empty until Phase 3 (today it is contaminated; there was never server history).

### Phase 2: extract the ledger; iOS adopts it

Goal: `TmuxRenderLedger` exists, is pure, is vector-tested, and the iOS app runs
on it with its full existing test suite green.

1. Create `RenderLedger.swift`, `RenderCommands.swift`,
   `RenderCommandQueue.swift`, `WindowModeStore.swift` in `TmuxControlCore`.
   Port the iOS state machine **verbatim in semantics**: same stages, same
   guards, same constants (`deepRepaintHistoryDepth`, `renderCommandQueueMaxWait`,
   watchdog 4 s, resync bound 3, deep retry 1). Every closure continuation
   becomes a FIFO purpose; every `Task.sleep` becomes `armTimer`.
2. Reducer tests: port the scenarios in 8.1 from `TmuxControllerTests` as
   pure `reduce` sequences with expected effect lists.
3. Vectors: `ProtocolVectors/tmux/render-ledger-v1.json` (8.3), consumed by
   `TmuxControlCoreTests` alongside `repaint-v1.json`.
4. `TmuxController.swift`: compose `ledger` next to `runtimeEngine`; route
   `orderedEvents` through it; replace the render section with the effect
   executor; move `sendControlCommand` onto the engine FIFO. Keep every public
   hook name so `SessionView.swift` needs no change beyond `bind`.
5. Run the full `TmuxControlTests` suite (478 tests today) unchanged. Any red test is an
   extraction mistake, not a test to edit.
6. Add the mosh side-channel profile to the ledger (epoch, depth ladder,
   single-flight, staged-vs-presented delivery, freeze). `SessionView.swift`
   submits `scrollbackRequested`, `findOpened`, `userInput`,
   `scrollbackReturnedToTail`, and the exact-owner `historyPresented` fact;
   it executes `historyReady` without treating it as presentation completion.
   Delete the duplicated fetch/apply logic. Presentation stays.
7. Portability gate: `scripts/check-shared-core-portability.sh` and
   `testPortableTargetHasNoForbiddenImports` must pass (no `Observation`, no
   `AsyncStream`, no timers in the core).

Milestone check (iPad sim, all four transports): checklist A-G, `s1-s6`
visual lane, then the full `./scripts/integration/run-integration-tests.sh`.

### Phase 3: Android adopts the ledger; delete the Kotlin twins

Goal: Android runs the same stage machine, gains deep history on switch,
reconnect rebuild, `%pause` handling, size-epoch resync and the alt-screen
ladder; the Phase 1 interim owner derivation is deleted.

1. ABI: three exports, `renderEffects` in the event, version 2, header gate,
   downgrade test, `check-abi-header.sh` green.
2. Kotlin facade and JNI thunks; instrumented test feeds
   `render-ledger-v1.json` through the real engine and compares effects (8.3).
3. `SshSessionController`: replace the capture orchestration with the effect
   executor (one `Main.immediate` block per batch, `transportGeneration` and
   connection identity re-checked once at the top); submit facts on attach,
   size, foreground, surfaces declared; route platform commands through
   `sendCommand`. For mosh history, retain the owned delivery until the feed
   seam succeeds, submit `historyPresented` for that exact owner, and run the
   4 s target-receipt watchdog described in 6.3. A watchdog retry is a new
   full-frame request for the same owner/generation, not a new capture. Delete
   the purposes and strings listed in 6.3.
4. `SshSessionScreen`: declare surfaces (single / grid) from the presentation
   decision it already makes (`compactTmux`, `usesTmuxPaneGrid`).
5. Hydration always ends with `refresh-client -f pause-after=5`, sourced from
   the shared command export; `%pause` is handled by the shared ledger.
6. Live gate: extend `scripts/android/run-native-ssh-gate.sh` with the
   isolation case emitting
   `TESSERA_ANDROID_TMUX_ISOLATION_OK windows=1 panes=1 reconnect=1 mosh=1 sharedCore=1`.

Milestone check (Pixel, all four transports): checklist A-F; deep history
visible after a switch on SSH+tmux; reconnect under the launch overlay; mosh
single-pane history on scroll-up; multi-pane mosh windows: history refused with
a diagnostic (Phase 4 adds the overlay).

### Phase 4: Android mosh multi-pane parity

Goal: synthesised scrollback for a focused pane inside a multi-pane mosh window
without disturbing the mosh-painted whole-window surface.

1. `SshSessionScreen`: mount a detached `TermuxTerminalSurface` framed to the
   focused pane's rect (the compact canvas projection already yields the rect)
   and declare it as `.overlay(pane)`.
2. Presentation: stage on `historyReady`, feed the owner-tagged bytes, then
   reveal and submit `historyPresented` only after the overlay is actually
   updated; native scroll on the overlay, dismiss at the live tail, park
   dormant across dismissals (iOS model, report D section 1b),
   `requestTransportFullFrame` on dismiss.
3. Tests: `TermuxTerminalSurfaceInstrumentedTest` overlay reveal/dismiss with
   fed captures; marker isolation case extended to a split mosh window.

Milestone check (Pixel, mosh+tmux, split window): scroll-up reveals only the
focused pane's history; switching panes swaps the overlay; output while
revealed freezes rather than yanks.

---

## 8. Verification plan

### 8.1 Reducer tests (Swift, `TmuxControlCoreTests/RenderLedgerTests.swift`)

Port these from `TmuxControllerTests.swift` as pure reduce sequences; each name
maps to a failure mode in report A, section g:

- fast switch drops the late first refresh; deep stage aborts on generation change
- chatty attach suppresses output until the hydrated deep capture; watchdog fails open
- pause mid-swap does not resume the old pane and the swap completes; background pane pause waits for swap-in
- hook frames (`flags`=0) never pop the FIFO; mismatched `%end` numbers stay in frame
- client resize between metadata and capture discards the frame and resyncs, bounded
- empty viewport capture never clears an established surface
- deep scrub paints from a fresh viewport capture, never a suffix slice
- foreground refresh in place: no clear, no history, no 1049 toggle; falls back to deep when identity changed
- `displayWillSwap` reports the transition and alt state before the feed; preserved across an aborted retry
- kitty restore skipped when the pane left the alt screen
- side channel: window change clears only, latched against nil; pane focus change stays inert; alt-screen pane never captures; zero-row grid fails closed
- side channel: epoch bump on input/resize/reattach drops the in-flight reply; freeze refuses every fetch until return-to-tail; deepen credit when `historySize <= requested`
- side channel: `historyReady` stages but does not reveal; a stale-owner `historyPresented` is rejected; output between staging and the matching acknowledgement is remembered and freezes immediately after presentation
- side channel: an exact `historyPresentationFailed` releases staged state and permits a later fresh request; a stale-owner failure cannot disturb the current staged delivery

### 8.2 Seam tests

- iOS `TesseraTests/TerminalBoxOwnershipTests`: a feed with a foreign owner
  never reaches the `TerminalView`; `bind` empties history and keeps the
  viewport; `bind` with the same owner is a no-op; counter increments.
- Android `TermuxTerminalSurfaceInstrumentedTest`:
  `bindEmptiesTranscriptKeepsScreenAndResetsTopRow`,
  `bindDuringAlternateScreenClearsMainTranscript`,
  `foreignOwnerFeedNeverReachesTheEmulator`,
  `painterFeedRemainsAllowedWhenSideChannelHistoryHasAnOwner`, and
  `painterFeedAdmissionRejectsUntaggedBytesWithoutAffectingOwnedRepaints`.
  The assertions require painter admission for plain transports and the mosh
  SSP while it is explicitly admitted, including alongside side-channel
  history; inline/grid/overlay paths reject untagged bytes.
- Android mosh delivery tests retain a staged capture across a target-null
  full-frame result and across a missing receipt; after the exact 4 s
  owner/generation watchdog retry, they require delivery of only the current
  owner and prove that no second capture command was sent. Owner, generation,
  or surface loss must discard the retry rather than deliver stale bytes.

### 8.3 Cross-language vectors

`ProtocolVectors/tmux/render-ledger-v1.json`: scripted inputs (wire lines and
facts, in order) and the expected ordered effect list, with feed payloads as
`(length, sha256)` so the vector stays small. Consumers:

- Swift `TmuxControlCoreTests` (direct reduce).
- Android `CoreRuntimeInstrumentedTest` (through JNI and the real engine;
  compares decoded `renderEffects`).
- `KotlinConformance` checks schema decode and the effect ordering contract;
  it does not re-derive the state machine (that would be the duplication this
  plan removes).

### 8.4 Live isolation gate (both platforms, four transports)

Marker protocol on the VPS fixtures: window 1 prints `TESSERA-W1-<token>` on
300 lines; window 2 prints `TESSERA-W2-<token>`; split window 2 and print
`TESSERA-P2b-<token>` in the second pane. Then: switch, scroll up, dump the
surface transcript, assert only the bound owner's markers are present and that
at least one of them is (history really arrived). Repeat after a forced
reconnect (fixture kills the SSH session) and, on mosh+tmux, after a
side-channel drop with the UDP session alive.

- Android: new `feature-session` instrumented case against the fixtures,
  driven by `SshSessionController` with a real `TermuxTerminalSurface`
  (precedent: `AgentSessionEndpointNativeInstrumentedTest`), wired into
  `run-native-ssh-gate.sh`.
- iOS: new programmatic case in `scripts/integration/run-app-transport-tests.sh`
  using the existing live-scroll harness plumbing, asserting via the find
  controller's match count (checklist A3) and a transcript dump; the `s1-s6`
  visual lane is unchanged.
- Both: the `dropped_foreign` counter must be zero in the diagnostics after
  the run. A non-zero value with a clean transcript means the seam caught a
  planner bug; fail the run.
- The mosh+tmux reconnect leg also records the staged owner, transport
  generation, full-frame receipt retry, and final `historyPresented` owner.
  Recovery may replay only that exact tuple; a new capture after a target-null
  or timed-out receipt is a failure.

### 8.5 Manual

[`tmux-render-ledger-verification-checklist.md`](tmux-render-ledger-verification-checklist.md)
sections A-G on the iPad and iPhone simulators and on Android tablet and phone
emulators, in landscape, with diagnostics capture started first. Physical
trackpad feel, deep mosh paging and plain-mosh Vim remain human checks per
`CLAUDE.md`.

---

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| iOS regresses during extraction of a mature 8.5k-line controller | extract-unchanged semantics; adapter keeps every hook; the 478 existing TmuxControl tests run unmodified; vectors; `s1-s6`; full VPS suite before commit |
| effect ordering on Android relative to `%output` | one `Main.immediate` block per batch; ordering pinned by the vector test through JNI |
| capture payloads vs the 1 MiB ABI ceiling | bytes pulled raw by ref with the two-pass contract; the event JSON shrinks because ledger frames no longer cross |
| Termux `clearTranscript` while the view is scrolled into history | `mTopRow` reset in `bind` plus the existing `onScreenUpdated` clamp; seam test covers it |
| phone stalls on deep captures | shared depth policy: 2000-line deep default capped by the user's limit; mosh page-then-parity ladder replaces the 50k one-shot |
| `%pause` newly enabled on Android surfaces flow-control edge cases | identical policy to iOS, already pinned by five pause tests; `%extended-output` is parsed by the shared parser today |
| ABI version bump breaks a stale APK against a newer core | v2 core, header/JNI shim, and Kotlin bridge are one shipped artifact from one source revision; the downgrade test rejects a mismatch loudly rather than allowing skew |
| scope creep into mosh presentation | presentation stays in `SessionView` / `SshSessionScreen`; the ledger emits `historyReady`, consumes the exact-owner `historyPresented` fact, and owns no view lifecycle |
| a view disappears after bytes are staged | both adapters submit exact-owner `historyPresentationFailed`; the ledger clears only that staged delivery and stale callbacks remain inert |

---

## 10. Decisions taken and open questions

Taken in this plan (re-litigate only with new evidence):

- Single shared buffer per surface with rebuild, not per-window buffer
  instances (rejected on iOS in the bleed report: cannot fix reconnect, drops
  off-screen output, ~49 MB per window).
- The ledger is composed next to the engine under one handle, not a second
  handle: it needs wire order and must keep capture bytes in-core.
- The engine owns the command FIFO on both platforms.
- The clear primitive stays platform-specific (`changeScrollback` toggle on
  iOS, `clearScrollback()` on the Termux fork); `CSI 3 J` is not used as the
  primitive on either.
- iOS adopts the ledger before Android does.
- Scroll position is not preserved across window switches.

Open for the user:

1. **Phase 1 as an interim release?** It stops contamination but leaves
   Android's post-switch scrollback empty on SSH+tmux until Phase 3. My
   recommendation: ship it if a release is due; otherwise run Phases 1-3
   back to back.
2. **Single-pane mosh+tmux with tmux `mouse on`** has no local scrollback on
   either platform today (the shared routing rule sends the wheel to tmux
   copy-mode). Keep as is, or add a "local history wins on primary screen"
   preference later? Not changed by this plan.
3. **Lazy history on inline.** iOS eagerly chains the deep stage after every
   switch. On cellular a reveal-triggered deep (the mosh ladder) would save
   bandwidth. The profile table makes this a one-line policy change later;
   this plan keeps eager for parity.
4. **Android mosh multi-pane before Phase 4**: refuse history with a
   diagnostic (recommended, no contamination, no geometry mismatch) or keep
   today's live-buffer feed under the ownership discipline (history at pane
   width above a window-width screen).

---

## Appendix A: evidence map

| Claim | Where |
|---|---|
| iOS rule and its enforcement points | report A, section b |
| iOS swap sequence, byte order, guards | report A, sections c.1-c.8 |
| sixteen failure modes and their tests | report A, sections g-h |
| Android never empties the transcript; one emulator per session | report B, sections a, c |
| Termux primitives available (`clearTranscript`, ED 3) and missing | report B, section d |
| repaint ABI hard-codes history to empty | `TmuxRepaintABI.swift:32-39`; report C, section d |
| both controllers run on `TmuxRuntimeEngine` | `TmuxController.swift:459`, `:1232`; `SC:1483` |
| authority reducer as the template for a shared planner | report C, section e |
| ABI conventions, payload ceiling, callback contract | report C, section b |
| mosh overlay model, epoch, freeze, depth ladder | report D, sections 1a-1b, 3 |
| mosh unification and the seven branch points | report D, section 6 |

## Appendix B: glossary

- **surface**: one emulator buffer pair with scrollback (primary, per-pane, or overlay).
- **owner**: `(windowId, paneId, epoch)`; the server pane whose rows a surface holds.
- **epoch**: counter bumped at continuity breaks that keep the same window and pane.
- **stage**: `.viewport` (instant screen), `.deep` (history + screen), `.viewportOnly` (in-place repair).
- **profile**: `.inline` (SSH+tmux) or `.sideChannel` (mosh+tmux).
- **seam**: the platform `RenderSurface` that enforces ownership at the feed boundary.
