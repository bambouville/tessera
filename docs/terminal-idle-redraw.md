# Idle terminal redraw and split-color repaint regression

Tessera must retain a reader's history position when a terminal application redraws its prompt, including when the application has no active agent turn. This applies to touch and pointer input on iPhone/iPad and Android; it requires no synchronized device preference.

## Research and diagnosis (2026-09-11)

Official [Codex TUI configuration](https://learn.chatgpt.com/docs/config-file/config-advanced#tui-options) documents animations/shimmer and an alternate-screen setting. These explain why rendering policy and agent work state are separate concerns. The documentation does not specify an idle redraw interval or establish the exact byte stream in the supplied logs. No claim about a particular Codex release's redraw implementation relies on those docs.

The supplied iOS diagnostics (`paste-20260911-215505-75bc.log`) show accepted primary-history gestures followed by incoming feeds returning the viewport to the bottom: an offset of 16582.5 becomes 17136. Android diagnostics (`paste-20260911-215610-6765.log`) show prompt decoration changing. The latest diagnostics (`paste-20260911-220328-4782.log`) also show foreground/window repaint activity near the reported literal color suffix.

Two terminal-side failures were reproduced:

1. SwiftTerm's iOS synchronized-output notification called an unconditional bottom-setting scroller update. A native regression moved from offset 2015 to 2415 on an idle synchronized frame. Android's `TerminalView.onScreenUpdated()` unconditionally set `mTopRow` to zero; its native regression failed with expected -12, actual 0.
2. A synthetic tmux repaint inserted between the live prefix `ESC[38;2;58;58;` and suffix `58;48;2;0;0;30mX` produced exactly `prompt58;48;2;0;0;30mX`. This is an independently reproduced explanation for the screenshot's suffix; the supplied diagnostics do not contain a complete raw-byte trace proving that precise boundary occurred on the user's connection.

The [tmux manual](https://man.openbsd.org/tmux.1#capture-pane) explicitly distinguishes pending incomplete escape output (`capture-pane -P`) from a captured screen. A screen capture therefore cannot substitute for a partial live parser instruction. The implementation preserves live CSI framing locally without adding a network query or delaying ordinary printable output.

## Implementation

- SwiftTerm retains the actual iOS history offset across synchronized snapshot begin/end and timeout, follows new output when already at the live tail, and handles alternate-screen exit. Discarded history rows rebase both the viewport and Tessera's retained scroll anchor, including fractional offsets and consecutive frames.
- Android retains the same transcript content across screen updates and appended lines. A primary-history counter excludes horizontal-margin redraws. Actual typing, key commands, paste, and autofill return to the cursor; terminal auto-replies do not.
- The shared tmux render ledger holds only incomplete live ESC/CSI prefixes per pane, before capture gating can discard them. Completed instructions cross cooperative iOS feed boundaries atomically. Parser state is cleared on transport generations, removed panes, and terminal owner changes. Strings stream without an unbounded payload reserve; malformed unbounded CSI is discarded through its terminator.
- Live regression review also exposed queued, capped wheel steps surviving an ended gesture or a direction reversal. The iOS dispatcher discards stale whole steps at these boundaries while retaining fractional steps for small discrete wheel clicks. Android dispatches these events directly and has no equivalent capped queue.

| Transport | Scroll handling | Repaint framing |
| --- | --- | --- |
| SSH | Platform terminal viewport | No synthetic tmux repaint |
| SSH + tmux | Platform terminal viewport | Shared inline render ledger, used by both platforms |
| Mosh | Existing visible-state painter/history routing; synchronized viewport remains stable | Existing painter frame ownership |
| Mosh + tmux | Existing side-channel history overlay and live painter routing | Existing painter frame ownership; inline framer is not applied to state snapshots |

## Regression lanes

- `swift test --package-path Packages/TmuxControl`: render ledger initial/foreground capture boundaries, every SGR split, cooperative slicing, UTF-8/C1, control cancellation, and bounded malformed sequences.
- `swift test --package-path Packages/ScrollDispatcher`: capped mouse/arrow motion reverses immediately, within and between gestures; fractional wheel accumulation remains covered.
- `GITHUB_ACTIONS=true swift test --package-path ../SwiftTerm`: dependency's supported CI configuration (excludes optional local benchmark tooling).
- `TerminalScrollbackOracleTests` and `TerminalBoxOwnershipTests`: actual iOS renderer plus production coordinator; idle frames, timeout, live tail, alternate exit, bounded history overflow, ownership, and exact `promptX` preservation.
- `scripts/integration/run-scroll-harness-tests.sh`: pointer and touch routing plus idle/color checks on disposable landscape iPad and portrait iPhone.
- `scripts/integration/visual-cases/s7-idle-redraw.sh`: differential leaked/fixed color screenshots and continuous idle-redraw videos, captured with simctl to include the Metal layer.
- `scripts/integration/visual-cases/s1-s6-live-scroll-transports.sh`: continuous primary → htop → Vim runs on all four transports; the normal single aggregate visual review grades all evidence together.
- `TESSERA_ANDROID_RUNTIME_FOCUS=terminal scripts/android/run-runtime-gate.sh`: native Android terminal tests. `TESSERA_ANDROID_RUNTIME_CAPTURE_DIR` retains native Canvas captures at actual window geometry before the run-owned emulator is deleted.

Local investigation artifacts and the final validation receipt are under `qa/codex-scroll-20260911/`. Physical trackpad feel, deep Mosh paging, and plain-Mosh Vim remain the established human checks.

## Validation receipt (2026-09-11)

The native iOS regressions first failed on history offset and the exact numeric suffix, then passed with the fetched SwiftTerm revision `677725183d1ce4093a56b37eb689a0212cebe069`. Android likewise failed at expected history row -12 versus actual 0 before its fix. Final focused results: 735 tmux tests, 42 dispatcher tests, 40 SwiftTerm XCTest plus 396 Swift Testing tests, 73 native iOS tests, and 25 native Android terminal tests passed. The native iOS suite skipped one opt-in performance audit; 19 live transport integration tests passed with one opt-in Release performance audit skipped.

The first aggregate visual review passed idle redraw/color cases but caught SSH+tmux Vim failing to reverse. After the capped-step fix, the fresh `reversal-validation/visual/codex-review.json` passed all cases: primary and htop on four transports, Vim on the three graded transports, and idle redraw on iPad/iPhone/Android. All 26 milestone images were reviewed; this does not claim inspection of every intervening video frame.

Final pointer/UI checks passed five tests on iPad. The iPhone runner initially omitted the idle/color opt-in flag; after correcting its simulator environment, all three iPhone tests passed with zero skips (`final-phone.log`). Run-owned simulators and Android emulators were deleted; unrelated workspace changes were preserved.

## Markdown preview dismissal (2026-09-12)

The later black gaps in the gray prompt have a separate, preexisting cause. Tessera debounced host resize notifications for 120 ms, but its native terminal emulator changed rows immediately on each layout. A brief modal dismissal pulse could therefore shrink and restore the local grid while the host continued sending cursor-addressed patches for the original grid. Tab switching repaired the screen by repainting it from the host. This ordering predates the idle-redraw fixes.

The iOS baseline regression failed at 37 local rows versus 40 committed rows after a 32 pt pulse; Android failed at 24 versus 25. A native iPad recording reproduced the screenshot's black prompt-background gaps with a 52 → 50 → 52 local grid and an unchanged 52-row host. The stripped simulator harness's ordinary modal alone did not emit that geometry pulse. The recording presents and dismisses the real Markdown Quick View, then injects the measured two-frame pulse to make the timing deterministic. This verifies the mechanism without claiming an exact reproduction of the user's device layout timing.

Both platforms now settle physical layout before changing the emulator, then notify the host from the committed grid without a second debounce. Initial layout remains immediate. A return to the previous dimensions cancels a transient proposal; a lasting resize commits after 120 ms. Explicit grid ownership cancels pending layout, font changes supersede stale proposals, and Android reattachment resumes an interrupted layout proposal without replacing an otherwise authoritative grid. Android also resizes its emulator before invoking the external resize callback, so a synchronous host response sees the correct grid.

The layout policy is shared by SSH, SSH+tmux, Mosh, and Mosh+tmux. Existing compact tmux viewport authority retains its separate transport proposal logic. iPhone uses the same protection in portrait, including software-keyboard geometry; iPad is exercised in landscape. No device synchronization or persistent state is added.

SwiftTerm revision `f349904294fb95bb5b6a2b18d98f41221495c6bb` exposes the iOS layout proposal hook; its default behavior is unchanged for other consumers. The app pins the published revision and final builds use a clean fetched checkout. `TerminalScrollbackOracleTests` covers transient/lasting layout, font changes, explicit grid ownership, and exact prompt/background preservation. Android instrumentation covers native layout, reattachment, callback ordering, explicit resize, and close cancellation. `s9-preview-resize.sh` adds popup/fullscreen Markdown captures on both iPad and iPhone to the existing aggregate visual review; the native scroll harness also asserts the dismissal result on both devices.

Separately, commit `9fac56cb` defaults iOS working-agent scroll locks to false for both Codex and Claude Code. Explicit stored settings remain respected.

Final validation passed the 84-test native iOS lane (one opt-in performance audit skipped), then reran the transient oracle after making its wire fixture independent of the DEBUG harness. Native UI lanes passed six iPad and four iPhone tests. The live iOS transport lane passed 19 tests with one opt-in Release audit skipped. The single aggregate visual review passed all 29 images, including the intentionally broken baseline and the four clean Markdown dismissal captures. SwiftTerm passed 40 XCTest and 396 Swift Testing tests. Android passed the focused 27-test terminal and two-test session lanes, then the full native SSH/Mosh gate, including all four transports, history, fresh grids, pane isolation, and reconnect with zero foreign-owner drops. Five unrelated opt-in Android session cases were skipped; exact test counts and names are in `qa/prompt-artifacts-20260911/validation.json`.

One iOS Mosh+tmux visual attempt failed the existing frozen-history motion check; its retry passed. The rejected attempt's diagnostics show same-pane ownership epochs changing while history is presented, without a layout resize during the gesture. Its evidence remains under `integration/visual/failed-attempts/` and `diagnostics/` in that QA directory. This preview fix does not claim to resolve that intermittent ownership failure. All six owned iOS simulators and the run-owned Android emulators were deleted; physical trackpad feel, deep Mosh paging, and plain-Mosh Vim remain human checks.
