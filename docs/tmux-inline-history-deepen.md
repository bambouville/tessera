# SSH+tmux scrollback depth: inline history ladder

Status: implemented 2026-09-22. Shared ledger design; both platforms consume it.

## Symptom

On an Android phone attached over SSH+tmux to a Claude Code pane, scrolling up
ends long before the tmux pane's history does. Measured on the reporting host
(tmux 3.6a, `history-limit 10000`):

| pane | size | `history_size` | app scrollback after attach |
| --- | --- | --- | --- |
| `%16` (Claude Code) | 56x45 | 7009 | 2000 |
| `%35` (zsh) | 56x45 | 9460 | 2000 |
| `%15` (bash) | 166x54 | 8092 | 2000 |

The scrollback preference on both platforms defaults to 10 000 lines, and the
mosh+tmux side channel already deepens to `max(240, scrollbackLimit)` on the
first scroll-up. Inline (SSH+tmux) never went past the attach capture.

## Root cause

`TmuxRenderLedger` captures inline history once, at
`min(deepHistoryDepth = 2000, scrollbackLimit)`, for every `.deep` stage
(attach, window switch chain, layout change, `%pause`). The
`scrollbackRequested` and `findOpened` facts are routed exclusively to
`requestSideChannelHistory`, which is a no-op for the inline profile, so no
gesture can ever fetch the remaining history. iOS and Android share this code
through `TmuxControlCore`, so both platforms stop at 2000 lines on SSH+tmux.

Full-depth captures are affordable: `capture-pane -p -e -N -S -10000` of the
three panes above weighs 470–680 KB. The former 1 MiB render ceilings
(`Configuration.maximumRenderBytes`, `SharedABI.maximumInputBytes` on the
render-bytes path, the Android pre-layout buffer) sat right at the size of a
dense 10 000-line capture and are raised to 8 MiB for render bytes only.

## Design

The inline profile gets the same ladder the side channel has, expressed with
the existing `.deep` stage so every repaint invariant (metadata → capture →
settled scrub, FIFO cut, post-capture output replay) is reused unchanged.

### Ledger (`TmuxControlCore`)

- `PendingRefresh.historyDepth: Int?` — nil keeps today's
  `inlineHistoryDepth`; the deepen sets the full depth.
- `fullInlineDepth = scrollbackLimit > 0 ? max(inlineHistoryDepth, scrollbackLimit) : deepHistoryDepth`.
- Per surface `InlineHistoryState { creditedDepth, historySize, canDeepen }`,
  reset whenever the surface's owner identity (window/pane) changes or the
  transport is lost.
- On every inline `.deep` completion (after the `.feed(.deepRepaint)`):
  `historySize = metadata.historySize ?? max(0, captureLines.count - rows)`,
  `depth = pending.historyDepth ?? inlineHistoryDepth`,
  `creditedDepth = historySize <= depth ? fullInlineDepth : depth`,
  `canDeepen = creditedDepth < fullInlineDepth && historySize > creditedDepth`.
  Emit `.inlineHistorySettled(surfaceID, owner, depth: creditedDepth,
  historySize, canDeepen)` after the feed and scrub effects.
- `scrollbackRequested` / `findOpened` on the inline profile: if the surface
  is owned, has no pending refresh and `canDeepen`, request
  `requestRefresh(stage: .deep, reason: "scrollback-deepen" | "find-deepen",
  continuityBreak: true, historyDepth: fullInlineDepth)`. The continuity break
  allocates a new owner epoch, so the platform bind clears the local
  transcript before the full capture replays into it. If the request is
  ignored (exhausted, pending, unowned) re-emit `.inlineHistorySettled` with
  the current state so a platform gesture never waits forever.
- Inline `.deep` abort/give-up also emits `.inlineHistorySettled` with the
  current state. A transport boundary (`transportLost`, `transportAttached`)
  that discards a pending deepen, or a refresh carrying a latched gesture,
  settles it too, with the reset state (`depth 0`, `canDeepen true`): the
  one-settle promise does not depend on the platforms' own boundary resets.
- A frame paints only into the grid it was captured for. The metadata reply
  ends with `pane_width`/`pane_height`. When the surface reports other rows,
  the ledger asks for its state again every 40 ms for up to 400 ms
  (`render-ledger surface-grid-wait`, then `surface-grid-settled`). An iPad
  split pane commits a new grid only after its layout settles (0.12 s). A
  deep frame painted into a grid one row taller left the newest history row
  on screen above the pane. The grid scrub erased that row, and the shrink
  then dropped the blank bottom row, so one row went missing at the seam.
  If a row pair outlasts the wait (`surface-grid-wait-expired`), it paints
  at once from then on, until the client size or the transport changes.
  Linefeeds for the surplus rows still put the history in scrollback. A
  recapture forced by output overflow spends only the rest of the wait.
- `scrollbackLimit == 0` means no ladder: the first fill is already the full
  depth, so the surface is exhausted at once and nothing is deepened.
- `scrollbackReturnedToTail`, `historyPresented`,
  `historyPresentationFailed`, `userInput` stay side-channel only.

Wire shape (ABI JSON, same encoder as `historyReady`):

```json
{"kind":"inlineHistorySettled","surfaceID":"live","owner":{...},
 "depth":10000,"historySize":7009,"canDeepen":false}
```

### What is shared, and why

Every stateful decision lives in `TmuxControlCore` so the platforms cannot
drift: depth ladder, exhaustion, single-flight, identity reset and the
settling signal are ledger reducer state; the only gesture rule the
platforms evaluate is the stateless `TmuxInlineHistoryGate.shouldRequest`
(iOS calls it directly, Android through
`tessera_tmux_inline_history_should_request`, the same shape as
`tessera_input_scroll_route`). A platform keeps exactly two facts per
surface, `canDeepen` from the last settle and a request-in-flight latch, and
feeds view geometry (rows hidden above the viewport, visible rows, whether
the gesture crossed the oldest row). A platform-local watchdog is
unnecessary: the ledger settles every terminal outcome, including ignored
requests, aborts and give-ups, and a transport loss clears the platform
record with the surface bind.

The same shape should absorb the mosh `shouldRequestDeeperHistory` rule
that Android (`MoshPaneHistoryOverlay.kt`) and iOS each hold today; that
migration is a follow-up, not part of this change.

### Platforms

- Trigger: on each local scroll frame near the oldest row, evaluate the gate
  with the surface's record; when it answers yes, latch `requestInFlight`,
  record the distance from the bottom, and submit `scrollbackRequested`.
  Find opening submits `findOpened` as it already does for mosh. Every input
  must produce those frames. Android's draw listener sees each `topRow`
  change, whatever moved it. On iOS the trackpad/wheel recognizer reports
  through `onPrimaryScrollbackUnderflow`, and UIScrollView's own finger pan
  and deceleration through `onNativeScrollFrame` (KVO on `contentOffset`).
  SwiftTerm's `scrolled` delegate reports output only; until 2026-09-28 iOS
  relied on it for fingers, and a touch reader stopped at the first fill.
- Placement: the bind that precedes the deep feed resets the view to the
  tail. On `inlineHistorySettled` the platform restores the distance from the
  bottom it recorded when it submitted the request (Android:
  `beginHistoryScroll` / `completeHistoryScroll`; iOS:
  `takeScrollPositionBeforeRebind` like the mosh
  `.preserveDistanceFromBottom` branch), clears the latch and stores
  `canDeepen`. A settle without a pending gesture only updates the record.
- Placement fails closed in two cases. A window/pane switch that overtakes an
  in-flight request cancels the recorded placement (Android
  `cancelHistoryScroll` at the identity-changing bind; iOS
  `placementInvalidated` on the record), so the reader lands on the new
  pane's tail as after any window switch, and the settle still releases the
  latch. On iOS the placement retry loop re-checks the box's bound owner on
  every attempt, as the mosh presentation path does, so a rebind during the
  convergence window never scrolls the pane that replaced it.
- Grid panes are surfaces of their own (`pane:<n>`, spelled by
  `TmuxController.inlinePaneSurfaceID` on both sides) with independent
  records; iOS retires a pane's record when the grid unmounts or prunes it,
  Android when its physical surface is replaced or detached.

## Validation

- `TmuxControlCore` ledger tests: initial credit, deepen command depth and new
  epoch bind, exhaustion, small-history exhaustion at first fill, ignore while
  pending, identity reset, find deepen, mosh unchanged, abort settles.
- `RenderLedgerSurfaceGridTests` run the grid wait, its expiry and its memo,
  and feed the frames through a small screen model, which also shrinks the
  grid the way SwiftTerm does. Each history row must end up in scrollback
  once. Live, the S13 split variant's `rows_contiguous` covers the same seam.
- ABI round-trip test for the new effect and the raised render byte ceiling.
- Android JVM tests for the request policy and Kotlin effect parsing.
- iOS unit tests for the request policy and placement arithmetic.
- Live SSH+tmux check against a pane with more history than the first fill:
  Android `TmuxRenderLedgerIsolationInstrumentedTest.liveInlineTmuxHistoryDeepensToScrollbackLimit`
  (`scripts/integration/run-android-live-scroll-tests.sh`, method selected
  with `TESSERA_LIVE_SCROLL_TEST_METHOD`) and iOS
  `RealHostTransportIntegrationTests.test_liveInlineTmuxHistoryDeepensToScrollbackLimit`
  (`scripts/integration/run-app-transport-tests.sh`). Both attach to a
  6000-line pane, assert the first fill stops near 2000 rows, deepen, and
  assert the oldest row is present once, the row count covers the whole
  history, `canDeepen` is false and live output still flows.
- The same depth reached by fingers alone: Android
  `liveInlineTmuxFingerFlicksDeepenToOldestRow` mounts the production
  controller and flings to row 1; the iOS visual case
  `s13-touch-deep-history.sh` flicks an SSH+tmux pane with 6 000 rows to row
  1 and requires the gesture's request and its settle in the app log; the
  host-free touch harness requires UIScrollView's finger frames, through the
  glide, to reach the host hook.
- Manual: scroll feel across the deepen on a physical phone and iPad, the
  iPad split grid, and a deepen over a slow cellular link.
