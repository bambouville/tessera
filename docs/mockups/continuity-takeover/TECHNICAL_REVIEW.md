# Technical review: continuity takeover proposal

Date: 2026-08-03  
Reviewed against: `main` at `8dd6809` and the attached diagnostics log  
Scope: terminal geometry and repaint behavior; this is not an Agent Center issue

## Verdict

The mockup covers the visible continuity experience that was being proposed: it makes device handoff explicit, gives the displaced device a take-back action, and models iPhone and iPad symmetrically.

It does **not** safely cover the terminal-sizing fix. The UI can be retained as a product direction, but the authority protocol and reclaim mechanism should not be implemented as written.

The central problem is that the proposal creates an app-level authority stamp while tmux continues to choose geometry from its own client-activity state. Those two authorities can disagree. The proposed SSH reclaim then uses `resize-window` as a force, which can introduce another resize/repaint race and still does not make the reclaiming iPad tmux's latest active client.

## Context from the reported failure

The affected foreground program was Claude Code in an SSH+tmux session. Claude Code is not involved in the sizing decision; it simply exposes the bad pane geometry clearly.

The expected behavior is:

1. When the iPhone is actively using the shared session, the iPhone should win and the tmux window should use the phone grid.
2. When the user returns to or interacts with the iPad, the iPad should become authoritative again and the same tmux window should return to the iPad grid.
3. Neither handoff should require detaching the other client or permanently choosing the largest device.

The diagnostics log shows the handback failure directly. On iPad foreground, Tessera advertises `166x54`, sends `refresh-client -C`, receives the command acknowledgement and layout notifications, and then captures only a narrow server grid:

- At `03:15:26`, local/client geometry is `166x54`, while the repaint capture is only `105x31`.
- At `03:30:23` and again at `03:30:29`, local/client geometry is `166x54`, while the repaint capture remains `118x35`.

This means the renderer is not merely failing to stretch or redraw a correct 166-column model. It is receiving and faithfully repainting a tmux pane that is still narrow. A local SwiftTerm refresh cannot repair that server-side mismatch.

The non-deterministic appearance comes from event ordering: a later tmux client activity or layout event can sometimes repair the grid, while foreground `refresh-client -C` by itself does not reliably transfer `window-size latest` ownership back to the iPad.

## What the mockup gets right

- It recognizes that iPhone takeover is valid behavior, not the bug.
- It makes reclaim symmetric between devices.
- It distinguishes tmux-backed continuation from a fresh custom-command shell.
- It keeps reconnecting and ended states above the continuity presentation.
- It waits for server confirmation before exposing a resized terminal.
- It treats mosh+tmux as a genuinely different topology rather than assuming its repaint path is identical to inline SSH+tmux.

Those are useful UI and state-machine ideas. The problems below are with the proposed source of truth and resize operation.

## Problems in the plan

### 1. The authority stamp and tmux geometry can disagree

The proposal treats `@tessera_authority` as the authoritative fact, but tmux still sizes a normal shared window using its own `window-size latest` client state. Writing:

```text
set -w @tessera_authority iPad:g6
refresh-client -C 166,54
```

does not necessarily make the iPad the latest active client for that window. The stamp can say “iPad” while tmux still selects the phone as its sizing client. A stamp acknowledgement therefore cannot be the success condition for terminal geometry.

Calling the commands a “batch” does not make the option value, client activity, window layout, and repaint one atomic state transition. They remain separate server mutations and notifications that can interleave with the other attached client.

### 2. Extending the mosh `resize-window` force to inline SSH is unsafe

The existing `forceWindowSizesToClientSize` helper is deliberately side-channel-only. It exists for the mosh+tmux topology, where the sizing control client is separate and the visible clients can be excluded by `ignore-size`.

The helper also loops over every hydrated window and performs:

```text
resize-window -x <cols> -y <rows> -t <window>
set-option -w -u -t <window> window-size
```

`resize-window` temporarily stamps `window-size` as `manual`; unsetting it immediately returns tmux to its calculated policy. On inline SSH with two normal visible clients, that recalculation can choose the still-latest phone again. The result can be a force-to-iPad followed by an immediate snap back to phone geometry, with extra `%layout-change` and repaint churn in between.

Applying that helper to every window also broadens a single visible-window reclaim into server-wide resize activity. That is exactly the kind of resize/repaint burst that has caused prior terminal artifacts and races.

### 3. The plan contains two false assumptions about current code

The transport note says both real clients already attach with `-f ignore-size`. That is no longer true for normal SSH+tmux. Commit `8d9f447` intentionally changed iPhone to `.resizeTmux`, and the current `AutoTmuxScript.command` call uses its default `preserveExistingGeometry: false`. This is correct for the expected “active device wins” behavior.

The implementation note also says `forceRefreshTerminal()` already performs `resize-window` force for SSH. It does not. On SSH it redraws locally, replays the local PTY/tmux size, and requests a foreground capture. The direct `resize-window` force remains side-channel-only.

Building the new state machine on either assumption would reintroduce geometry-preserving phone behavior that the current product requirement explicitly rejected.

### 4. The mockup models the wrong visual artifact

The “today's bug” switch renders a narrow terminal scaled up with a distorted aspect ratio. The reported image and diagnostics instead show a narrow remote pane/capture occupying a wider local terminal canvas. The important mismatch is remote columns versus local columns, not an intentional visual scale transform.

The blur would hide either artifact, but an inaccurate model can lead to the wrong acceptance test: the fix must prove that the server pane and capture reach the active device's dimensions, not merely that the stale result is obscured.

### 5. Peer-detach auto-reclaim is underspecified and can seize the grid incorrectly

`%client-detached` identifies a tmux client; the proposed stamp contains a display name and local generation. The plan does not define a durable mapping between those identities. Device names are not unique, generations can restart, and an app can miss the detach while offline.

Without a validated mapping, one background device can see a detach, assume the authority holder left, and resize the session while another live device is using it. A stale foreign stamp after a crash can also leave a device blurred indefinitely unless hydration first proves that the exact holder still exists.

### 6. Same-grid takeover and full input suppression are a separate product change

Yielding one iPad when another same-sized iPad attaches does not help the geometry bug. It introduces exclusive keyboard arbitration, disables scroll/find/tab interaction, and consumes the first reclaiming keystroke. That may be a desirable continuity feature, but it is not required for “the active device owns the grid” and should not be smuggled into the sizing fix.

If exclusive control is desired, it needs its own protocol requirements: stable per-client identity, stale-holder recovery, concurrent reclaim behavior, reconnect semantics, and interaction with non-Tessera tmux clients.

## Safer sizing architecture

Keep tmux's normal `window-size latest` policy as the geometry source of truth. Add one explicit operation to the shared controller: **claim the active viewport**.

For inline SSH+tmux, the claim should be serialized through the existing control-command acknowledgement queue:

1. Send `refresh-client -C <local-cols>,<local-rows>` and wait for its acknowledgement.
2. Send a no-op `select-window -t <current-window-id>` from the same control client and wait for its acknowledgement.
3. Confirm the active window layout/capture matches the local viewport, then perform one authoritative repaint.

A disposable tmux 3.4 fixture reproduced the current behavior and verified this sequence: `refresh-client -C 166,54` alone left the phone-sized pane in place, while the same size update followed by selecting the already-current window made the iPad client latest and restored the 166-column pane. No visible window switch, `resize-window`, manual sizing option, detach, or down/up resize burst was required.

The claim should be coalesced and triggered only at meaningful ownership boundaries:

- app foreground when this session is selected;
- switching to the session or tmux window;
- first local terminal interaction when the server grid differs from the viewport.

It should not run on every geometry callback or every keystroke. The operation must latch the controller generation and current window ID; if either changes before acknowledgement, cancel or retry against the new state before repainting.

For mosh+tmux, retain the existing side-channel-specific direct window force plus `forceFullRepaint()`. That branch is justified by the genuinely different topology. Plain SSH and plain mosh should not acquire tmux ownership behavior.

Do not use any of these as the general inline fix:

- persistent `ignore-size` for a visible phone client;
- `window-size manual`;
- `resize-window` across every window;
- `window-size largest`;
- a downsize/upsize repaint burst;
- the manual refresh button as the normal recovery mechanism.

## How the UI overhaul can fit safely

The overlay can remain, but it should observe the sizing protocol rather than define it.

- A short reclaiming veil can cover the interval between claim start and confirmed matching layout/repaint.
- A device-name stamp may be used as advisory copy such as “continued on iPhone,” but a stamp acknowledgement must not prove geometry ownership.
- If no geometry differs, ordinary last-active-device behavior can remain immediate unless the team separately approves exclusive input arbitration.
- The manual Refresh action can invoke the same claim-and-repaint operation as a recovery tool, but it should not be required after a normal handoff.

If the product decision is to enforce one Tessera keyboard owner even for identical grids, specify and test that as a separate continuity-control protocol. Do not couple its correctness to tmux sizing.

## Required acceptance checks

Before either the sizing fix or takeover UI ships:

- Repeated iPhone → iPad → iPhone handoff with both clients still attached; at least 20 cycles.
- Foreground return, in-app session selection, and first-touch/first-key reclaim paths.
- Claude Code, `htop`, and Vim, including alternate screen, cursor position, and heavy repaint output.
- Single-pane, split-pane, and multiple-window tmux sessions.
- SSH+tmux and mosh+tmux live checks; verify plain SSH and plain mosh are unchanged.
- Assert command ordering and that the confirmed server layout/capture equals the active local viewport before the veil lifts.
- Assert inline SSH never emits the side-channel `resize-window`/unset loop and leaves no `window-size manual` option behind.
- Verify a regular laptop tmux client still participates according to native tmux policy.
- Run the full integration suite because this is cross-device, cross-transport lifecycle and repaint work.

## Recommendation

Approve the mockup only as a presentation exploration. Revise its technical sections before implementation:

1. Replace stamp-defined sizing authority with the tmux-native viewport-claim sequence.
2. Keep the mosh direct-force workaround scoped to the side channel.
3. Correct the artifact model and current-code assumptions.
4. Decide separately whether Tessera should enforce exclusive input ownership on same-sized devices.

Until those changes are made, implementing the plan as written risks hiding the stale grid behind a polished overlay while preserving—or worsening—the underlying resize/repaint race.
