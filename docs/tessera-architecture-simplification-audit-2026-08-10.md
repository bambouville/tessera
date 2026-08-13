# Tessera architecture simplification audit

Date: 2026-08-10

Audited checkout: `<repo root>`

Branch: `main`

Commit: `efae0c36d6f6ef1339359520d0df84a357d25b54`

Upstream base: `origin/main` at `772dd280149feef6c19a53c1cff62f0eb27a36fa`

## Executive conclusion

Tessera's highest-value simplification is to make a live session a stable,
process-owned runtime object instead of a value copied between `ContentView`,
`SessionRegistry`, transport-specific views, and restore/continuity helpers.
That one change makes the other major simplifications possible:

1. one owner for identity, transport replacement, tmux, health, retry, and
   restore state;
2. one input/command router through which every terminal, pane, accessory,
   SwipePad, Files, and Agent Center send must pass;
3. one typed health/failure model, with one retry supervisor, instead of
   strings, booleans, nested retry loops, and UI-specific projections;
4. one common session presentation with small capability adapters for the few
   differences that are real; and
5. one transactional viewport/render contract so size, authority, capture,
   cursor, and repaint data cannot come from different epochs.

The code is not large because Tessera supports four transports. It is large
because the same session concerns are owned at several layers and then kept in
sync through callbacks, Combine publishers, one-shot tokens, copied values,
and view-owned tasks. Git history shows that this has repeatedly produced
restore duplication, replay loops, input-gate bypasses, and render/geometry
races.

This is a static-analysis and history audit, not an implementation. No app or
dependency source was changed. The only new repository file is this report.

## Ranked recommendations

| Rank | Change | Value | Main risk | Recommended order |
| --- | --- | --- | --- | --- |
| 1 | Make a stable `LiveSessionController` the sole live-session owner | Very high | Lifecycle migration | First architectural milestone |
| 2 | Route all input and commands through one `SessionCommandRouter` | Very high | Missing a legacy send source | Immediately after stable ownership |
| 3 | Introduce typed session health/failures and one retry supervisor | Very high | Incorrect domain-error mapping | Can begin before rank 1 |
| 4 | Replace the duplicate SSH/Mosh views with one session scene plus composed capabilities | Very high | Creating a new mega-protocol | After ranks 1-3 |
| 5 | Make viewport/repaint work transactional and split `TmuxController` behind its facade | High | Rendering regressions | After characterization coverage |
| 6 | Extract mosh history into one explicit coordinator/state machine | High | Gesture and placement regressions | After common session scene |
| 7 | Share the duplicated SSH PTY channel machinery | Medium-high | Teardown ordering | Independent, after typed failures |
| 8 | Move debug harnesses out of production source files/target | Medium | Test discovery/build plumbing | Low-risk parallel cleanup |
| 9 | Quarantine compatibility fields and delete proven-dead states/APIs | Medium | Persistence compatibility | Incremental, with narrow tests |

The ranking is about long-term defect and change cost, not ease of editing.
Ranks 1-4 should be treated as one coherent direction, delivered in small
behavior-preserving milestones rather than a rewrite.

## Scope and method

Included:

- Tessera app source under `Tessera/`;
- Tessera-owned packages, especially `Packages/TmuxControl` where app session
  behavior is implemented;
- current four-path behavior: SSH, SSH+tmux, mosh, and mosh+tmux;
- current `main`, including the performance changes through `efae0c3`;
- source history on `main`, commit messages/bodies, blame, and file growth;
- focused unit tests that pin current behavior.

Excluded:

- third-party dependency internals, including SwiftTerm, Citadel's upstream
  implementation, NIO, and mosh/protobuf vendor code;
- performance measurement, which is covered by the separate performance
  audit;
- live SSH, VPS, integration, visual, or physical-device testing;
- any production-code modification.

Pre-existing unrelated worktree changes were left untouched:

- `Tessera.xcodeproj/xcshareddata/xcschemes/Tessera.xcscheme`;
- `scripts/integration/jump/remote-provision-jump.sh`;
- `qa/`; and
- `review-top-three-commits.md`.

## Current architecture in one view

The four product paths are two primary transports crossed with two launch
modes:

| Path | Primary terminal bytes | tmux control | History mechanism | Genuine difference |
| --- | --- | --- | --- | --- |
| SSH | One SSH PTY | None; `TmuxController` remains passthrough | SwiftTerm/local primary history | Ordered byte stream and PTY resize |
| SSH+tmux | Same SSH PTY carries terminal bytes and inline `-CC` frames | Inline | Local pane/window model and captures | Control and visible bytes share a channel |
| mosh | Mosh SSP/UDP visible-state stream after SSH bootstrap | None | No tmux control-plane history | Primary stream is a state synchronizer, not an ordered PTY byte stream |
| mosh+tmux | Mosh SSP/UDP remains the visible stream | A second SSH PTY runs `tmux -CC` | Server `capture-pane` snapshots shown through a separate history surface | Visible and control planes are deliberately separate |

These are real differences. Files, find, launch overlay, background, lock,
bell, keyboard/accessory UI, command palette, Files injection, theme, status
presentation, selection actions, and most lifecycle behavior are not.

The current abstraction boundary does not reflect that split:

- `TerminalSession` exposes a useful common byte/lifecycle surface, but
  `Session` branches into concrete `SSHSession`/`MoshSession` at every SwiftUI
  observation site (`TerminalSession.swift:20-55`, `Session.swift:1-29`).
- `ContentView` owns `[LiveSession]` as `@State` (`ContentView.swift:145`).
- `SessionRegistry` explicitly says it does **not** own that array; it mirrors
  value snapshots pushed from the view (`SessionRegistry.swift:4-18,
  36-44,91-105`).
- The two large view implementations start at `SessionView.swift:61` and
  `SessionView.swift:2177`.
- Their common terminal bridge, `TerminalSurfaceBound`, currently accepts 36
  configuration/action properties (`SessionView.swift:10943-11052`).

The target boundary should instead be:

```text
SessionRegistry (sole process owner)
  -> LiveSessionController (stable identity and state)
       -> PrimaryTransport (SSH or mosh)
       -> TmuxControlPath (none, inline, or side channel)
       -> HistoryProvider (local, remote capture, or unavailable)
       -> SessionCommandRouter
       -> SessionHealth / SessionFailure / RetrySupervisor
  -> SessionScene (shared presentation)
```

This model does not pretend the transports are identical. It localizes the
differences instead of letting them fork the whole session feature.

## Quantitative evidence

### Current concentration

| File | Lines at audited commit | Commits touching file on `main` | Historical line churn (additions + deletions) |
| --- | ---: | ---: | ---: |
| `Tessera/SessionView.swift` | 12,897 | 149 | 17,347 |
| `Packages/TmuxControl/Sources/TmuxControl/TmuxController.swift` | 7,686 | 64 | 10,344 |
| `Tessera/ContentView.swift` | 5,013 | 84 | 6,987 |
| `Tessera/TesseraApp.swift` | 2,737 | — | — |
| `Tessera/MoshSession.swift` | 1,939 | 29 | 2,583 |
| `Tessera/SSHSession.swift` | 539 | 26 | — |
| `Tessera/Navigation/SessionRegistry.swift` | 197 | 5 | — |

Additional structural counts at `efae0c3`:

- the SSH view has 48 reactive wrappers and the mosh view has 73;
- a conservative member-name comparison finds 45 common view members, even
  before counting semantically identical members with `mosh` prefixes;
- `ContentView` contains 26 direct `.ssh`/`.mosh` case branches;
- `SessionView.swift` contains 30 direct routing calls to `session.send`,
  `tmux.sendInput`, or the mosh tmux channel;
- the four core files contain about 250 diagnostics references; and
- `ContentView`/`SessionView` own 14 `Task` handles in SwiftUI state.

The duplicate member set includes theme, launch phase/subtitle/failure,
Files setup/drop/selection, pending path injection, authority mirroring,
switcher routing, agent scroll policy, SwipePad refresh, scroll diagnostics,
and terminal-position helpers. These are session concerns, not transport
implementations.

### Accretion over history

Line counts from historical blobs show where the missing boundary absorbed
features:

| Commit | Milestone | `SessionView` | `ContentView` | `MoshSession` |
| --- | --- | ---: | ---: | ---: |
| `413908e` | Introduced `TerminalSession`/`Session` | 978 | 216 | — |
| `ca94db0` | Added mosh tmux side channel | 1,109 | 250 | 500 |
| `199228c` | Added saved-session restore | 2,954 | 882 | 1,430 |
| `d4c0cdf` | Added mosh primary scrollback | 3,875 | 1,475 | 1,430 |
| `78de7e0` | Advanced mosh+tmux scroll | 7,637 | 2,384 | 1,509 |
| `78b14be` | Added continuity/iPhone work | 10,071 | 4,065 | 1,825 |
| `1309331` | Added continuity takeover | 12,160 | 4,966 | 1,876 |
| `efae0c3` | Audited state | 12,897 | 5,013 | 1,939 |

Growth alone is not a defect. The important signal is that product features
which should attach to a session runtime instead attached to two view trees and
the root navigation view.

## What git history says the recurring traps are

The following subject-match counts are descriptive and overlap; they are not
claimed as unique defect totals. On `main`, 46 commit subjects explicitly
mention render/scroll/geometry concepts, 22 mention restore/reconnect/lifecycle,
14 mention mosh+tmux or its side channel, and 11 explicitly mention a race,
stale state, duplication, freezing, desynchronization, replay, FIFO, or
correlation.

### Trap 1: view-owned state creates duplicate universes and replay loops

Representative history:

- `199228c` added saved-session restore;
- `1db1ea6` repaired foreground restore recovery;
- `1c6412f` preserved snapshots through foreground wake;
- `777feff` found that each new scene created a new `ContentView @State`
  universe, restored the same sessions again, and polluted the shared restore
  document; its commit body explicitly says multi-window requires sessions to
  move to a process-wide store;
- `007c674` repaired restored mosh+tmux launch completion; and
- `141425b` repaired a continuation overlay loop caused by a publisher rebuilt
  during every `ContentView` evaluation replaying `.connected` and repeatedly
  cancelling/restarting its dismissal task.

The present design still has the root cause: `ContentView` owns the array,
`SessionRegistry` mirrors it, per-session controllers live in view subtrees,
and publisher trees are rebuilt from the array.

### Trap 2: identity changes are used as a lifecycle control mechanism

`attemptMoshJumpFallback` replaces a mosh `LiveSession` with a newly initialized
SSH `LiveSession` so SwiftUI remounts the view (`ContentView.swift:4040-4077`).
The replacement preserves most metadata but gets a new default UUID. Restore,
selection, MRU, readiness, grid-authority mirrors, and continuity then all need
lineage/deduplication logic to understand that the new value represents the
same user session.

Likewise, `updateEffectiveLaunchMode` mutates a copied `LiveSession` value
without changing its ID (`ContentView.swift:4241-4252`), while registry sync is
triggered only by `activeSessions.map(\.id)` (`ContentView.swift:508-509`). A
palette/switcher reader of the registry can therefore observe stale copied
metadata even though the root array is current.

Stable identity should be data, not a request to SwiftUI to reconstruct a
subtree.

### Trap 3: policy at call sites is inevitably bypassed

Continuity takeover initially gated the obvious terminal paths. The adversarial
follow-up `c25d136` found that per-pane `onSend` still bypassed the yielded
guard and Page Up/Down could still send through mosh while another device owned
the shared grid. That was not an exotic protocol failure; it was a consequence
of enforcing one rule at many send closures.

The current `SessionView.swift` still contains 30 direct transport/tmux send
call sites, spanning terminal input, pane input, Files path injection,
SwipePad, shell probes, alt-screen scrolling, and shortcuts. The next policy
(lock, continuation, ownership, rate limit, or future read-only mode) must be
remembered at all of them unless input is centralized.

### Trap 4: render data from different epochs is assembled as one frame

Representative history:

- `f8c8203` repaired foreground/window repaint races;
- `a21c55f` found cursor metadata and capture output separated by a size replay,
  so they described different grids;
- `c60bc2f` repaired a mosh+tmux window frozen at a transient phone keyboard
  size;
- `802ed98` added a full mosh repaint when tmux layout changes left SwiftTerm
  and the SSP framebuffer divergent;
- `4523920` repaired a stale cursor after continuation; and
- `579d00a` repaired compact continuation cursor settlement.

The fixes are legitimate and tested, but their accumulation shows that size,
window, pane, capture, cursor, authority, and repaint are still coordinated by
adjacent mutable fields and callback fences rather than one explicit
transaction value.

### Trap 5: live framebuffer and historical snapshot are different products

`cbdeb2f` attempted to backfill mosh scrollback by feeding `capture-pane` data
into the live model and was reverted because it desynchronized mosh state.
Subsequent work correctly moved history to a separate overlay
(`d4c0cdf`, `d0b0bf1`, `67f276c`, `78de7e0`, `d2c9b12`), but the state machine
now lives as more than 20 loose `@State` values and a roughly 1,900-line method
region in `MoshSessionView` (`SessionView.swift:4412-6331`).

The historical lesson is not to delete mosh history. It is to make the
live-versus-history boundary a named type that cannot be crossed accidentally.

### Trap 6: failure is repeatedly confused with absence or presentation text

`6f5c14e` fixed Agent Center by distinguishing an unavailable probe from an
authoritative empty result; previously a transient failure erased valid state.
The same distinction should be systematic across sessions.

Current session code still exposes `SessionState.failed(String)`, determines a
cancelled launch by searching for `"connection cancelled"`, and classifies
mosh disconnects by searching lowercased error text for `closed`, `shutdown`,
`end of file`, or `eof` (`TerminalSession.swift:7-18`,
`SessionLaunchOverlay.swift:26-37`, `MoshSession.swift:917-964`). Focused tests
pin those strings today; they do not make the representation robust.

### Trap 7: recovery has more than one owner

Mosh currently has three retry layers:

- bootstrap recursively retries connection failures after 3 and 10 seconds
  (`MoshSession.swift:192,430-445`);
- `TmuxControlChannel` retries attach up to 10 times at 500 ms
  (`MoshSession.swift:1416-1417,1634-1680`); and
- `MoshSessionView` discards/recreates the whole channel forever on a
  1/2/4/8/15-second backoff (`SessionView.swift:4044-4184,6638-6642`).

The layers have different counters, cancellation conditions, state labels, and
error strings. Commits `c064ad3`, `7722242`, and `007c674` are successive
recovery/launch repairs in this area. Recovery policy belongs with the stable
session runtime, not in both the channel and the SwiftUI view.

### A pattern that worked: centralize a decision with explicit waiters

`f9856c9` fixed duplicate host-key prompts by introducing a shared,
single-settlement/coalescing decision path rather than adding more sheet guards.
The focused host-key suite now covers coalesced continuations, cancellation,
promptless/prompted races, stale challenges, and first-decision-wins behavior.

That is the model to copy: make one owner authoritative, give each caller a
typed request/waiter, and settle once. Session retry, input permission, restore,
and viewport ownership should follow the same shape.

## Detailed recommendations

### 1. Make `SessionRegistry` the sole owner of stable session runtimes

#### Evidence

- `ContentView` owns `[LiveSession]` (`ContentView.swift:145`).
- `SessionRegistry` mirrors it and explicitly declines ownership
  (`SessionRegistry.swift:4-18`).
- Render readiness and grid-authority presentation are separately mirrored into
  the registry because the real controllers are view-owned
  (`SessionRegistry.swift:45-63`).
- Palette tmux actions use incrementing one-shot request tokens that travel
  from the registry back down to the matching view-owned controller
  (`SessionRegistry.swift:64-72,145-196`).
- Dynamic publishers in `ContentView` branch on both concrete transports for
  host-key prompts, OS hints, cwd, and state (`ContentView.swift:1297-1407`).
- Mosh-to-SSH fallback changes the live ID to remount a view.

#### Proposed shape

Create one main-actor observable reference type, provisionally:

```swift
@MainActor @Observable
final class LiveSessionController: Identifiable {
    let id: UUID
    let persistedHostID: UUID?
    let requestedRoute: SessionRoute

    private(set) var effectiveRoute: SessionRoute
    private(set) var health: SessionHealth
    private(set) var transport: SessionTransport

    let tmux: TmuxController
    let commands: SessionCommandRouter
    let retry: RetrySupervisor
}
```

The concrete transport may remain an internal enum. The important point is
that SwiftUI observes one stable controller, so it never needs to bind an
`ObservableObject` existential directly. This avoids the limitation documented
in `TerminalSession.swift` without scattering enum switches.

`SessionRegistry` should own `[LiveSessionController]`, selection/MRU, and
lookup. `ContentView` should render registry state, not maintain and mirror a
second array. Tmux controllers, readiness, and authority live on the session
controller; palette actions call the controller directly after stable-ID
lookup. The request-token bus disappears.

Mosh-to-SSH fallback becomes `controller.replacePrimaryTransport(with: .ssh)`
and keeps the same ID, selection, MRU, restore lineage, command endpoint, and
presentation objects.

#### Simplification unlocked

- Delete `syncActiveSessions` and copied session snapshots.
- Delete registry tmux request tokens and per-view `.onChange` consumers.
- Replace four rebuilt `Publishers.MergeMany` trees with direct observation or
  stable controller event streams.
- Make restore/reconnect act on an existing controller instead of creating and
  reconciling “corpses.”
- Keep session state alive independently of whether its SwiftUI subtree is
  mounted.
- Preserve identity across fallback and retry.

#### Boundary to preserve

Cold-launch restore policy and credential eligibility remain. A process-owned
session store does not imply automatic multi-window support; it merely removes
the architectural blocker recorded by `777feff`.

### 2. Put every input and command behind `SessionCommandRouter`

#### Evidence

The current send sites decide independently whether to use raw session bytes,
inline tmux `send-keys`, or the mosh side channel. They also repeat launch,
authority, active-surface, and overlay gates. History has already found bypasses
in pane and hardware-key paths.

#### Proposed shape

Define commands by meaning, not wire path:

```swift
enum SessionCommand {
    case terminalBytes(ArraySlice<UInt8>, source: InputSource)
    case paneBytes([UInt8], pane: PaneId, source: InputSource)
    case resize(cols: Int, rows: Int)
    case injectPath(String)
    case tmux(TmuxMutation)
}

enum CommandDisposition {
    case sent
    case rejected(SessionCommandRejection)
}
```

The router owns the route choice:

- raw SSH/mosh bytes for passthrough;
- inline `TmuxController` input for SSH+tmux;
- side-channel pane/tmux commands for mosh+tmux;
- the current input-permission gate (locked, launching, yielded, ending, or
  no active pane); and
- consistent diagnostics/rejection feedback.

Terminal surfaces, pane grids, accessory buttons, SwipePad, Files injection,
Agent Center, page keys, mouse/wheel semantics, and future automation call the
router. No view should call `session.send`, `tmux.sendInput`, or
`TmuxControlChannel.send` directly.

Do not make the router a UI singleton. It belongs to one live session and
depends only on session state/capabilities. This keeps tests deterministic and
prevents cross-session routing.

### 3. Use typed session health/failures and one retry supervisor

#### Evidence

Current representations overlap:

- `SessionState` has five cases and carries raw failure text.
- `MoshTransportState` separately represents the UDP transport.
- `MoshSideChannelState` has six cases.
- `MoshTcpControlStatus` reduces that to three cases.
- `SessionConnectionStatus` recombines SSH or mosh session/transport/control
  state for presentation (`SessionView.swift:7655-7889`).
- Sidebar, compact rows, and top bar separately map these states to labels and
  colors (`SessionSidebar.swift:316-350`, `ContentView.swift:4777-4795`,
  `SessionView.swift:7810-7889,9535-9576`).

There are also two strong dead-state findings:

- `MoshSideChannelState.failed` has no assignment anywhere in the audited tree,
  and history search finds no prior `tmuxSideChannelState = .failed` assignment.
- `.degraded` is assigned only after `runTmuxControlReconnectLoop` exits. Under
  current tmux-mode call sites and predicates, an uncancelled current-generation
  loop exits only when `shouldMaintainTmuxControlChannel` is false; that cannot
  coexist with its final `session.state == .connected && isActive` test. It is
  therefore statically unreachable under the current policy.

#### Proposed shape

Keep domain errors local. Do **not** create one global enum containing every
Citadel, mosh, tmux, Files, and persistence error. At the session boundary map
them into a small typed value:

```swift
struct SessionFailure: Error, Equatable {
    enum Category {
        case cancelled, authentication, hostTrust, network
        case remoteBootstrap, protocolFailure, controlChannel, unsupportedRoute
        case unknown
    }

    enum Phase {
        case policy, connecting, bootstrap, primaryTransport
        case controlChannel, rendering
    }

    let category: Category
    let phase: Phase
    let userMessage: String
    let diagnosticSummary: String
    let recovery: RecoveryDisposition
}
```

Pair it with compositional health:

```swift
struct SessionHealth: Equatable {
    var primary: LinkHealth
    var control: LinkHealth?       // nil when not required
    var render: RenderHealth
    var input: InputAvailability
}
```

One presentation adapter derives dot color, compact label, overlay phase,
warning visibility, retry text, and actions. Cancellation is a category, not a
substring. A remote EOF is an end reason, not text reparsed by a view.

One `RetrySupervisor` owns retryability, attempt count, backoff, cancellation,
and next action. A `TmuxControlChannel` should perform one connection/attach
attempt, or at most a bounded protocol handshake; it should not run a private
10-attempt policy beneath an unbounded view supervisor.

This also generalizes a successful Agent Center lesson: health must distinguish
“authoritatively absent” from “temporarily unavailable.”

### 4. Build one `SessionScene` from composed capabilities

#### Evidence

The SSH and mosh views duplicate most presentation and app integration. The
generic `ActiveSessionRowBody<S: ObservableObject & TerminalSession>` and
`CompactSessionRowBody` already prove that a narrow generic seam works
(`SessionSidebar.swift:301`, `ContentView.swift:4686`).

The common `TerminalBox` also already provides a useful renderer boundary
(`SessionView.swift:7211-7419`). The problem is that the outer feature remains
duplicated and feeds `TerminalSurfaceBound` a 36-property closure/configuration
bag.

#### Proposed shape

After stable session ownership, create one session presentation that owns:

- top bar/status/launch/continuation overlays;
- Files panel, selection actions, drag/drop, and pending path injection;
- find controller;
- theme/background/bell;
- app lock and user-activity notifications;
- keyboard/accessory/SwipePad/Agent Center entry points;
- compact/iPad layout selection; and
- shared terminal surface configuration.

Compose the real differences instead of building a protocol with dozens of
optional methods:

```text
PrimaryByteTransport   send / output / resize / lifecycle
TmuxControlPath        none / inline / sideChannel
HistoryProvider        local / remoteCapture / unavailable
RemoteExecProvider     SSH chain lease when available
CwdProvider            OSC / tmux metadata / bounded probe
```

`SessionScene` consumes those capabilities. Mosh history remains a separate
surface/coordinator plugged in through `HistoryProvider`; it does not infect
the plain SSH view. Inline versus side-channel tmux stays inside
`TmuxControlPath`; it does not fork Files, find, keyboard, or overlay code.

Replace `TerminalSurfaceBound`'s flat callback bag with two values:

- immutable `TerminalSurfaceConfiguration`; and
- a stable `TerminalSurfaceActions` object/protocol.

That reduces closure identity churn and makes it possible to enforce shared
policies at one adapter.

Avoid a big-bang generic view. First extract exact common components with the
existing two views, then switch both to the same `SessionScene`, then delete the
duplicates.

### 5. Make viewport and repaint a transaction, then split `TmuxController`

#### Evidence

`TmuxController` currently combines:

- DCS detection and tmux message parsing;
- command/FIFO correlation;
- window and pane model hydration;
- inline repaint/capture/cursor assembly;
- side-channel semantics;
- client sizing and compact sizing roles;
- continuity grid authority and reverse-attach cede;
- scrollback capture;
- keyboard mode/title/metadata observation; and
- recovery/watchdogs/coalescing.

The file is 7,686 lines, has been touched by 64 commits, and has accumulated
10,344 changed lines. The many generation counters and fences are necessary
symptoms of real races, but the invariants are distributed.

#### Proposed shape

First introduce a value that proves a render is coherent:

```swift
struct ViewportTransactionID: Hashable {
    let sessionGeneration: Int
    let clientSizeEpoch: Int
    let windowID: WindowId
    let paneID: PaneId?
}

struct TerminalFrame {
    let transaction: ViewportTransactionID
    let grid: CellRect
    let bytes: [UInt8]
    let cursor: CursorSnapshot
}
```

Metadata, capture, cursor, authority confirmation, and final feed must all
either match the transaction or be discarded/retried as a unit. Resize and
takeover create a new transaction. The view consumes only complete frames.

Then retain `TmuxController` as the public facade while extracting internal
collaborators:

- `TmuxProtocolEngine` — parser, FIFO, structured replies;
- `TmuxWindowModel` — windows/panes/metadata;
- `ViewportCoordinator` — size, authority, epoch, claims;
- `InlineRenderCoordinator` — capture/frame assembly; and
- `TmuxHistoryProvider` — scrollback capture.

This split is valuable only if state ownership becomes clearer. Moving methods
to files while they continue to mutate one shared 200-field object would be
cosmetic and should not be counted as simplification.

Do not remove existing generation guards, zero-row rejection, deep repaint,
authority arbitration, or frame-correlation behavior until the new contracts
prove equivalent. The history demonstrates that those cases are real.

### 6. Extract `MoshRemoteHistoryCoordinator`

#### Evidence

Mosh history/pane-overlay logic spans approximately
`SessionView.swift:4412-6331` and is controlled by more than 20 view-state
properties around `SessionView.swift:2225-2283`. It coordinates:

- active versus dormant overlay runtimes;
- freshness epochs;
- per-pane depth and in-flight capture;
- prefetch/deepen scheduling;
- alt-screen interaction probing and proxy scrolling;
- native scroll settle/placement;
- output invalidation and frozen-history behavior; and
- find seeding.

These are state-machine concerns. SwiftUI should render their output, not own
their tasks and transition tokens individually.

#### Proposed shape

Create one observable coordinator with explicit state and events:

```text
State: inactive | prefetched | revealing | visible | deepening | frozen | failed
Events: paneChanged, outputArrived, gestureBegan, gestureEnded,
        captureSucceeded, captureFailed, reachedBoundary, returnedToBottom
```

The coordinator owns capture tokens, tasks, placement, depth, and freshness.
Its only renderer output is a snapshot model and requested placement. Its only
protocol dependency is `HistoryProvider`.

This preserves the distinct historical surface that fixed the reverted
live-model approach. It also makes plain mosh, mosh+tmux, and future history
capabilities explicit instead of relying on scattered mode checks.

### 7. Share SSH PTY channel mechanics without coupling connection lifetimes

#### Evidence

`SSHSession` and `TmuxControlChannel` each own:

- input/output/control `AsyncStream`s;
- an SSH chain/client;
- PTY request and cached size replay;
- output, input, and resize task-group drains;
- cancellation/close cleanup; and
- error-to-state/termination mapping
  (`SSHSession.swift:73-115,404-468`; `MoshSession.swift:1423-1476,1590-1840`).

The tmux variant adds command-on-open and attach statistics/retry, but the PTY
mechanics are the same.

#### Proposed shape

Extract a scoped `SSHPTYChannel` actor/service that performs exactly one PTY
run and returns typed termination. Configuration supplies:

- initial size;
- optional command to write after open;
- stdout/stderr policy;
- input/control streams; and
- port-forward attach/detach hooks.

`SSHSession` and the mosh tmux control adapter become policy owners around that
primitive. Do **not** automatically pool one physical `SSHClient` across
terminal, Files, installers, and side channels. Those consumers have different
lifetimes and teardown behavior; share chain creation, policy resolution, and
error mapping, not necessarily the socket.

### 8. Move debug harnesses out of production source files and preferably into a harness target

#### Evidence

A syntactic inventory finds about 4,600 lines under DEBUG-gated branches in
the app source tree, concentrated in:

| File | DEBUG-gated lines (approx.) |
| --- | ---: |
| `TesseraApp.swift` | 2,249 |
| `SessionView.swift` | 1,058 |
| `BootstrapNetworkHarness.swift` | 459 |
| `ContentView.swift` | 338 |
| `AgentCenterPage.swift` | 213 |

These lines do not bloat the Release binary. They do bloat production source
files, increase compile/test graph coupling, create legacy seams, and make
ownership harder to see.

#### Proposed shape

- Keep the harnesses; history shows they are valuable for hard rendering and
  lifecycle bugs.
- Move harness views and fixture builders into a dedicated source group and,
  preferably, a `TesseraHarnesses` app/target that links the app modules.
- Leave one tiny DEBUG bootstrap selector in the production app entry point.
- Require harnesses to use the same public production seams as the app.

One concrete cleanup becomes possible afterward: production app code uses
`TmuxController.feedTerminalWithContext`, while the legacy `feedTerminal`
callback is used by tests and a DEBUG harness. Migrate those consumers and
remove the dual callback fallback rather than carrying both APIs indefinitely.

### 9. Quarantine compatibility fields and remove proven-dead states

#### Persisted launch mode

`PersistedHost` stores both legacy `autoTmux` and `launchModeRaw`, and its typed
setter keeps them synchronized (`PersistedHost.swift:43-68,151-158`). `Host`
and `LiveSession` carry runtime boolean shims as well (`Host.swift:36-40`,
`LiveSession.swift:37`). This makes inconsistent combinations representable.

Do not delete the persisted SwiftData column in a mechanical cleanup. History
and migration tests document load-bearing schema constraints, especially the
`[String]` attribute on `PersistedHost` (`b937ed7`, `d73d74d`). Instead:

1. retain `PersistedHost.autoTmux` as a deprecated migration/compatibility
   field;
2. derive all runtime behavior exclusively from `HostLaunchMode`;
3. remove the boolean from `Host`, `LiveSession`, UI decisions, and transport
   factories; and
4. update the legacy field only at the persistence adapter boundary.

#### Mosh side-channel state

After adding a narrow policy test proving loop exits, remove the never-produced
`.failed` and unreachable `.degraded` cases. `isControlUnavailable`,
`showsPersistentWarning`, and `blocksTmuxCommands` currently repeat the same
case grouping; replace them with one semantic property or, preferably, the
typed health projection from recommendation 3.

#### Duplicate session factories and status formatting

- Quick connect and saved-host connect each switch on transport to construct a
  concrete session (`ContentView.swift:3999-4011,4194-4207`). Use one factory
  returning a stable controller/transport adapter.
- Sidebar, compact rows, and top bar each map session state to labels/colors.
  Use one `SessionHealthPresentation` value.
- Once debug/test consumers migrate, remove the legacy tmux terminal-feed
  callback.

These are the safest early deletions because they remove representations and
APIs, not behavior.

## Simplifications that should **not** be made

### Do not assume mosh through a jump host always fails

The mosh jump fallback is substantial, but it is not dead code.
`JumpHostTransportIntegrationTests` explicitly covers both outcomes:

- blocked UDP must produce an SSH fallback recommendation
  (`JumpHostTransportIntegrationTests.swift:399-437`); and
- reachable direct UDP must establish mosh through the same jump-auth setup
  (`JumpHostTransportIntegrationTests.swift:439-471`).

The suite also proves the mosh+tmux SSH control side channel traverses the jump
chain (`JumpHostTransportIntegrationTests.swift:473-520`). A blanket
“jump chain means SSH” rule would remove tested functionality. Simplify its
ownership by making fallback a typed recovery action on the stable session; do
not delete it.

### Do not merge mosh history bytes into the live terminal model

History already records that approach as a revert (`cbdeb2f`). The live SSP
framebuffer and a historical capture are different authorities. Keep a
separate history surface/coordinator.

### Do not delete continuity/grid-authority hardening because cases look rare

The late claim, foreign stamp, bare tmux client, same-grid peer, yielded input,
and stale geometry cases were found on real flows and are heavily unit-tested.
Centralize them; do not replace them with a size heuristic or UI-only veil.

### Do not weaken host-key request coalescing/cancellation

Duplicate prompts and continuation settlement are real concurrency cases. The
current shared decision model is a good architecture, not accidental bloat.

### Do not delete restore credential eligibility or snapshot deduplication

The focused restore tests demonstrate legitimate distinctions between
restorable keys/passwords, transient Keychain failures, deleted hosts, custom
command duplicates, and singleton tmux modes. Stable ownership should make
foreground recovery simpler, but cold-launch policy and safety must stay.

### Do not remove persisted SwiftData fields without a migration plan

Quarantine compatibility state at the persistence boundary. Do not reshape the
shipped model merely to make runtime types cleaner.

### Do not count moving code into files as architecture work

File splitting is useful after ownership changes. It is not simplification if
the new files continue to share the same mutable state and callback graph.

## Proposed migration sequence

Each milestone should preserve all four transports and both iPhone/iPad
presentations. Stop after a human-testable behavior-preserving boundary, not
halfway through a new ownership model.

### Milestone 0: characterize current contracts

- Add pure tests for the statically unreachable mosh side-channel states and
  current reconnect-exit policy.
- Inventory every direct input source and add a route matrix test.
- Pin stable session identity across retry, restore, and mosh-to-SSH fallback.
- Keep the existing restore, host-key, grid-authority, scroll, and live visual
  suites as non-negotiable behavior contracts.

### Milestone 1: typed status without ownership change

- Add `SessionFailure`, `SessionHealth`, and one presentation projection.
- Map SSH/mosh/control errors once at transport boundaries.
- Preserve existing user-facing strings initially.
- Replace cancellation/EOF substring decisions internally.
- Remove duplicate label/color mappings.

This is independently testable and reduces semantic drift before structural
movement.

### Milestone 2: stable session controller and registry ownership

- Introduce `LiveSessionController` around the existing `Session` enum.
- Move tmux/readiness/health/retry objects to the controller.
- Make `SessionRegistry` own controllers.
- Change `ContentView` to observe the registry.
- Replace fallback in place while preserving the UUID.
- Remove registry snapshot sync and request-token buses.

Keep the two existing session views temporarily; both receive the stable
controller. This contains migration risk.

### Milestone 3: central input and connection factories

- Introduce `SessionCommandRouter` and route every current send source through
  it.
- Add a test that forbids direct transport sends outside adapters/router.
- Centralize quick-connect, saved-connect, restore, continuation, and fallback
  construction in one factory.
- Make input denial/recovery typed and observable.

### Milestone 4: common session presentation

- Extract immutable terminal configuration and stable actions.
- Move Files/find/background/bell/keyboard/overlays/top bar into
  `SessionScene`.
- Plug in SSH and mosh capabilities.
- Delete the duplicate helpers only after both paths render through the same
  scene.
- Decide compact presentation inside shared presentation components, not by
  duplicating transport views.

### Milestone 5: retry and PTY consolidation

- Move all reconnect policy into the controller's `RetrySupervisor`.
- Reduce `TmuxControlChannel` to one attempt/bounded handshake.
- Extract one-run `SSHPTYChannel` mechanics.
- Preserve separate physical connections where lifetimes differ.

### Milestone 6: isolate mosh history

- Move mosh history state/tasks into `MoshRemoteHistoryCoordinator`.
- Expose explicit state/events and a snapshot model.
- Keep the current live-versus-history separation and gesture behavior.
- Replace view token/task fields with coordinator state.

### Milestone 7: transactional rendering and controller decomposition

- Introduce viewport transaction IDs and complete terminal frames.
- Move size/authority/epoch into `ViewportCoordinator`.
- Extract protocol/window/render/history collaborators behind the existing
  facade.
- Remove superseded flags only after the current grid/continuity/render suites
  pass unchanged.

### Milestone 8: harness and compatibility cleanup

- Move DEBUG harnesses into a separate target/source group.
- Migrate legacy callback users and remove old APIs.
- Quarantine `autoTmux` at persistence only.
- Remove proven-dead states and redundant projections.

## Definition of done for the architecture work

The simplification is successful when:

- exactly one object owns each live session and its stable ID;
- transport replacement/retry never changes that ID;
- `ContentView` no longer mirrors or reconstructs transport publishers;
- `SessionRegistry` no longer mirrors `ContentView` state or buses commands to
  view-owned controllers;
- no UI/input feature calls concrete transport send APIs directly;
- one typed failure/health value drives overlay, sidebar, compact row, and top
  bar;
- one retry supervisor owns attempts and backoff per failing subsystem;
- SSH and mosh share one session presentation, with transport differences
  expressed through composed capabilities;
- mosh history is a separate typed coordinator, not loose SwiftUI state;
- render/cursor/capture/geometry values carry the same transaction identity;
- debug harnesses do not dominate production source files; and
- every existing four-transport, restore, continuity, scroll, Files, input,
  host-key, and compact-device behavior remains covered.

## Validation performed for this audit

### Tessera-owned tmux package

Command:

```sh
swift test --package-path Packages/TmuxControl
```

Result: 436 tests passed, 0 failed. This includes 42 grid-authority tests and
222 `TmuxControllerTests`. It establishes that the current hardening is green;
it is not evidence that the proposed refactor has been implemented.

### Focused iOS app tests

Executed on a uniquely named disposable iPhone 17 Pro simulator running iOS
26.0.1, with derived data under `/private/tmp`. The simulator was shut down and
deleted after the run.

Selected suites:

- `SessionRestoreResolverTests`;
- `HostKeyVerificationRequestTests`;
- `MoshSessionFailureClassificationTests`;
- `MoshSessionFailureMessageTests`; and
- `HostTransportModelTests`.

Result: 41 tests passed, 0 failed.

The mosh failure tests confirm the current string-based behavior. They should
become mapping tests for typed failures during migration, retaining the same
user-facing messages.

### No dynamic transport validation

No SSH connection, VPS fixture, transport integration suite, visual run, or
physical-device run was performed. That is intentional: this deliverable was
authorized as static analysis plus targeted unit tests only.

## Secondary static findings outside the ranking

The focused iOS build succeeded but emitted existing migration/availability
warnings worth tracking separately:

- `KnownHostsStore` calls actor-isolated `loadFromDisk()` from initialization
  contexts that Swift 6 will reject, and assigns `Date.init` to an `@Sendable`
  closure (`KnownHostsStore.swift:104-113`).
- `PortForwarder`'s `Identifiable` conformance crosses its main-actor isolation
  and will be an error in Swift 6 (`Forwarding/PortForwarder.swift:10-18`).
- `SessionView` and `PaneGridView` use `CGRect` as a `Hashable` identity even
  though that conformance is available only from iOS 18, while Tessera's
  deployment target is iOS 17 (`SessionView.swift:6599-6616`,
  `PaneGridView.swift:743-831`).
- Several terminal menu/focus APIs are deprecated or have ignored return
  values.

These are not the high-value architectural changes requested here, but they
should be resolved before a Swift 6 language-mode migration and the `CGRect`
identity should be checked on the minimum supported OS.

## Reproduction notes

Representative static/history commands:

```sh
wc -l Tessera/SessionView.swift \
  Packages/TmuxControl/Sources/TmuxControl/TmuxController.swift \
  Tessera/ContentView.swift Tessera/TesseraApp.swift \
  Tessera/MoshSession.swift Tessera/SSHSession.swift \
  Tessera/Navigation/SessionRegistry.swift

git log main --pretty=format:'%H' -- Tessera/SessionView.swift
git log main --numstat --format= -- Tessera/SessionView.swift
git show 78de7e0:Tessera/SessionView.swift | wc -l

rg -n 'case \.ssh|case \.mosh' Tessera/ContentView.swift
rg -n 'session\.send\(|tmux\.sendInput|tmuxControlBox\.channel\?\.send' \
  Tessera/SessionView.swift
rg -n 'tmuxSideChannelState = \.failed|tmuxSideChannelState = \.degraded' \
  Tessera/SessionView.swift

git log main --date=short \
  --pretty=format:'%h%x09%ad%x09%s' -- \
  Tessera/SessionView.swift Tessera/MoshSession.swift \
  Tessera/ContentView.swift Tessera/Navigation/SessionRegistry.swift
```

History claims in this report are based on current `main` ancestry, not every
duplicated branch/cherry-pick in `--all`.
