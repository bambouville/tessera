# Split pane notification ordering

Cmd-D could create the remote pane while leaving the original terminal full
width. Switching away and back then displayed only the new pane; reconnecting
rehydrated the correct split. The September 19 recording and diagnostics show
the remote focus notification followed by a two-pane layout notification, so
the split command itself succeeded.

## Cause and fix

`TmuxRuntimeEngine.feed` reduces a complete socket read before the Apple
controller consumes its ordered callbacks. The callback for
`%window-pane-changed` updated the controller's active-pane metadata and wrote
the controller's whole window snapshot back into the runtime. That snapshot
still contained the old single-pane layout. It overwrote the runtime's newer
split layout and pane membership. Final snapshot projection restored the
stale layout to the UI. Separating the notifications into different reads
avoided the layout loss but could still lose the new active pane.

The controller now publishes through `ingestWindowPresentation`. This merges
titles, command and terminal-mode metadata into existing panes while retaining
the runtime's layout, visible layout, zoom, pane membership and focus. Initial
pane discovery may fill an absent active pane only when the authoritative
layout permits it. No transport-specific workaround or reconnect is needed.

Both SSH+tmux inline control and mosh+tmux side-channel control use the corrected
controller. Plain SSH and mosh remain passthrough sessions without local tmux
split commands. iPad continues to display the pane grid; iPhone continues to
display the focused pane while retaining the remote split.

## Regression coverage

- `PaneCommandTests` exercises synchronous/cooperative ingestion, both control
  paths, batched/separate notifications, immediate input to the new pane,
  nested newer layouts, pane removal after an OSC title and window-details
  responses preceding newer split/close notifications.
- `SplitBatchHarnessView` uses the production controller, pane grid and terminal
  views with a host-free synthetic wire. `VisualCaptureProbe` checks split and
  window-return state. `p2-split-notification-batch.sh` records the actual terminal
  layers with simctl and adds the evidence to the aggregate visual review.
- The native four-transport render-isolation integration test additionally
  creates new horizontal/vertical splits, checks input destination and window
  return, zooms/unzooms and closes a pane on both tmux transports.

The investigation evidence, recordings, result bundles and final validation
report are kept locally under `qa/split-pane-20260919/`. The host-free fixture
uses fixed terminal dimensions: its captures prove pane visibility and focus,
not exhaustive viewport geometry or physical keyboard behavior.
