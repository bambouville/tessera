# Tmux render ledger — manual verification checklist

Use this checklist after the automated reducer/vector/seam gates and the live
fixture isolation lanes. It covers visual, input, and lifecycle observations
that those gates cannot establish. It replaces the historical local
`buffer-fix-verification-checklist.md`.

## Test setup

- Use only the disposable integration fixtures. Do not connect the test build
  to a personal host or alter a user's tmux server.
- Test in landscape. Cover iPad and iPhone simulators, plus an Android tablet
  and phone emulator. A physical iPad with a trackpad is required for the
  physical-feel items below.
- Start the platform's in-app diagnostics capture before connecting. Record the
  session's `render_surface` and `render_ledger_summary` lines, including the
  final `dropped_foreign=0` summary.
- Exercise all four transports: SSH, SSH+tmux, mosh, and mosh+tmux. The tmux
  fixture should provide window W1, window W2, and split-pane P2b markers.

## A. Ownership and history isolation

1. On SSH+tmux, create distinct long histories in W1, W2, and P2b. After each
   window and pane switch, scroll and search for the fixture markers. Only the
   displayed owner may be present; at least one of its older rows must be
   reachable.
2. Repeat the switch from a scrolled position. The destination opens at the
   live edge; it must not inherit the prior window's scroll offset or rows.
3. On an iPad/Android tablet grid, verify each visible pane has only its own
   history. Collapse or zoom the grid, then restore it; no stale pane rows may
   appear.
4. On iPhone/Android phone compact mode, verify the single focused-pane
   surface: switch W1/W2 and P2b, rotate or resize once, then scroll and
   search. The compact projection may pan the whole mosh window, but history
   remains keyed to the focused pane.

## B. Attach, reconnect, and late output

1. Reconnect SSH+tmux while W2 or P2b is producing output. The launch overlay
   remains until the rebuilt pane is coherent; it must not flash W1 or append
   pre-disconnect rows.
2. Repeat with a chatty background pane and a quiet foreground pane. The first
   settled foreground frame is the quiet pane, and its history is scrollable.
3. Force the fixture control-channel drop during mosh+tmux while the UDP mosh
   painter is live. Confirm the live pane continues updating, then request
   history after the side channel recovers. The rebuilt history has a fresh
   owner epoch and contains no old-owner markers.
4. If the inline watchdog fires, it may fail open with a recoverable frame, but
   it must not leave an indefinite launch overlay or a mixed transcript.

## C. Surface transitions and the compact story

1. Move between single, split-grid, and zoomed presentation on iPad and
   Android tablet. Each declaration change clears/rebuilds only its applicable
   surface; controls, focus, and typing remain with the visible pane.
2. On iPhone and Android phone, exercise the same server topology in compact
   mode. There is one focused terminal surface, not a tablet pane grid; ensure
   keyboard and software-keyboard occlusion do not hide the live edge.
3. Change client size during a switch or reconnect. Wait for the settled
   capture: no stale-width rows, old screen fragments, or half-width repaint
   artifacts may remain.

## D. Alternate-screen and terminal modes

1. Run htop in one tmux pane and a shell in another. Switching to the shell
   exposes local shell history; switching back preserves htop and routes wheel
   and click input to it.
2. Repeat with Vim. Switch away and back, exit with `:q`, and confirm no scroll
   region or alternate-screen bytes corrupt another pane.
3. Verify kitty/bracketed-paste behavior across a switch: a previous window's
   keyboard mode must not leak into the current shell.
4. In mosh+tmux, an alternate-screen pane refuses synthesized local history;
   wheel input continues to follow the terminal's normal mouse/copy-mode route.

## E. Mosh history and roaming

1. For a single-pane mosh+tmux window, scroll up to request synthesized
   history, then return to the live tail. The primary mosh painter remains the
   visible source until the history reader is shown.
2. For a split mosh+tmux window on tablet, scroll P2b. Its detached overlay is
   framed to P2b, reveals only after `historyReady`, scrolls natively, and is
   parked at the live tail without disturbing the whole-window mosh painter.
3. On phone compact mode, confirm the focused pane's history uses the single
   history target; it must never mount a tablet-style pane grid over the mosh
   canvas.
4. A mosh+tmux window change clears synthesized local history before a new
   request. A side-channel reattach, including to the same active pane,
   invalidates parked history and rebuilds it under a fresh epoch on demand.
   A normal UDP roam with no side-channel reattach must not create a spurious
   clear.
5. While a mosh reader is revealed, produce pane output. The reader freezes;
   it is not yanked to live output. Returning to the tail unfreezes and permits
   the next history request. Page deeply enough to validate the depth ladder.

## F. Pause, flow control, and bells

1. Let a background tmux pane flood long enough for `pause-after` to engage.
   A bell from that pane still produces the expected notification state.
2. Switch into the paused pane. It rebuilds from tmux truth, resumes only the
   rendered pane, and continues live output without a permanent freeze.
3. Reconnect after a previously belled or paused pane. No stale bell repeats,
   and no background pane resumes merely because another pane was rendered.

## G. Regression sweep and evidence

1. Check fresh SSH+tmux attach, window close/create/rename, OSC title updates,
   find refresh after a switch, and a mid-session scrollback-limit change.
2. Check plain SSH and plain mosh remain normal transport-painter sessions:
   their local history is retained across their own reconnect behavior and no
   tmux ownership clear is injected.
3. Export diagnostics for every platform/form-factor run. Treat a nonzero
   `dropped_foreign` counter as a failure even if the visible transcript looks
   clean.
4. Physical-only: verify trackpad feel/latency, deep mosh paging continuity,
   and plain-mosh Vim mouse behavior on a real iPad. These are not claimed by
   simulator or fixture automation.
