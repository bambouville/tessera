# Android product gaps after terminal parity

Status: 2026-08-30, Android phone baseline on `main`.

## In-scope parity now implemented

- Plain SSH, SSH+tmux, Mosh, and Mosh+tmux use one shared session command/event ABI and the same terminal presentation path.
- Compact tmux shows one pane full-screen without changing the server grid. Peer ownership blurs and blocks the local surface until an ordered take-control resize/repaint fence completes.
- Terminal chrome, software keyboard control, and the iPhone-order accessory bar are present in the compact phone UI. The live row scrolls horizontally with a fixed keyboard toggle; Settings supports wrapped key categories, tap removal, long-press reorder, an intentionally empty row, restore defaults, and one-shot Control/Option/Shift modifiers. Configurable scrollback, find, launch/retry/edit/back recovery, quick-open Files, and share-in/share-out are also present.
- The keyboard viewport follows the iOS 0.3.6 caret policy. With terminal resizing off, opening the keyboard preserves the server grid and counter-shifts only enough to keep the live cursor visible from the first row through the last row; alternate-screen and mouse-reporting applications remain geometry-stable. With resizing on, settled viewport changes resize plain terminals and wide tmux grids through the shared coalesced path. Compact tmux stays presentation-only and never changes the server layout.
- A tmux pane becomes the input target synchronously when tapped, so terminal input, paste, accessory keys, find, cursor following, and blink ownership cannot lag onto the previously selected pane.
- Terminal appearance includes the iOS solid-color themes, configurable font size, block/bar/underline cursor with optional blink, and an app-owned custom background image with fill/fit, dim, and bounded blur. The global background is applied to the primary surface, every tmux pane, and compact-tmux margins without changing remote geometry. Native selection actions can reveal a selected remote path in Files or quick-open a selected file; relative paths use OSC 7 when available, a fresh tmux pane path, or an authenticated action-time shell-directory probe for plain SSH and both Mosh transports.
- Smooth scrolling matches the iPhone default, speed range, and primary-scrollback eligibility. Momentum is cancelled on direct touch, output reset, mode changes, or preference disable and remains discrete in alternate-screen and mouse-reporting applications.
- Port forwarding has secret-free per-host rules, local/remote/dynamic validation and persistence, live start/stop/status controls, SSHJ listeners, and a dedicated authenticated SSH side channel for both Mosh transports. Host-file export/import round-trips rules; cross-device bootstrap transfers the frozen portable local-rule subset without erasing Android-only rules.
- Advanced continuity persists a secret-free multi-session restore document and selected session, implements ask/always/never policy with the phone default matching iPhone, restores SSH and Mosh sessions after process death, and safely reopens an interrupted verified continuation without reconstructing the expired pairing transaction.
- Bells share tmux event detection with iOS, handle plain-terminal BEL, rate-limit per source, route sound/visual/unread/background notification behavior from the same preferences, and expose Android permission denial plus a settings recovery route.
- Lock/background uses a foreground service while transports are active. Explicit task removal closes transports and removes the notification truthfully; process death restores from the saved document. A shell/tmux command that reports remote exit, or a Mosh native shutdown completion, retires its restore record and removes the ended session from the list. Socket EOF without a remote exit status remains reconnectable.

## UI parity statement

For the first Android phone release, the terminal screen now has feature parity with the iPhone terminal surface for the in-scope transport, input, keyboard-occlusion, tmux, selection, Files, continuity, and recovery fundamentals above. This is functional parity, not a claim of pixel-identical platform rendering. Navigation is adapted to compact Android: forwarding is reachable from the host menu and the connected-session tunnel panel rather than iPad's global sidebar page. Platform-specific system surfaces (Android notification settings, document picker, sharesheet, and foreground-service notification) intentionally keep native Android presentation.

## Remaining product gaps

| Area | Remaining Android gap | Release impact |
|---|---|---|
| Agent Center | Not implemented on Android; explicitly outside this work. | Deferred product area, not a terminal-baseline blocker. |
| Swipe Pad and dictation | Not implemented on Android; explicitly outside this work. | Deferred product area, not a terminal-baseline blocker. |
| Per-host terminal backgrounds | Android v1 has the full global image/fill/dim/blur path but does not yet expose iOS per-host background overrides. | Visual-customization follow-up; all transports and panes share the global presentation correctly. |
| Advanced accessory behaviors | Android v1 uses one-shot modifiers and fixed symbol notation. iOS sticky-modifier/notation controls and user-authored shortcut chips are not yet present. | Follow-up beyond the requested software-bar layout editor; built-in key customization and software modifiers are complete. |
| Hardware-keyboard customization | Intentionally outside Android v1. iPad's remappable command set, natural text-editing policy, and shortcut editor do not yet have Android tablet/Chromebook equivalents. | Follow-up for large-screen hardware-keyboard parity; the customizable phone software-accessory bar is complete. |
| Multiple simultaneous sessions to one saved host | Android's compact session collection currently has one live slot per saved host. | Follow-up for power users; multiple different hosts and full restore cohorts are supported. |
| In-app capture | Android uses the OS screenshot and screen-recording controls. Tessera accepts resulting images/videos through share-in and diagnostics through the same upload flow, but has no in-app capture editor. | Does not block the issue-reporting cycle. |

## Validation boundaries

Deterministic unit/ABI coverage exercises forwarding lifecycle and codecs, restore policy and expiry, SSH exit classification, Mosh reachability versus native shutdown, bell policy, shared tmux bell routing, Files/share contracts, host import/export, keyboard viewport policy, resize coalescing, shell-directory probing, path selection, current-path hydration, accessory persistence/encoding, and smooth-scroll policy. The shared tmux package passes 494 tests. Android connected instrumentation passes 7 terminal/background/momentum cases and all 10 current settings/session harness cases.

Computer Use validation on a disposable API 36 phone emulator covered portrait and landscape production-shaped terminal layouts plus the shipping terminal-background, smooth-scroll, and accessory-editor settings surfaces. The cursor remained visible immediately above the keyboard/accessory surface at both fresh-screen and scrollback-tail positions, and the landscape accessory remained horizontally scrollable. This validation did not require the user's Pixel and did not automate opening a user-owned SSH/Mosh connection.

Live acceptance still requires a user-initiated session for real tunnel traffic, background BEL delivery from a host, Android-to-iPad tmux authority transfer, and four-transport reconnect behavior. The comprehensive integration script was intentionally not run at the user's request.
