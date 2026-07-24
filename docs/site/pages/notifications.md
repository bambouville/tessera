---
title: notifications
nav: 14
description: Terminal bells — sound, flash, and background banners — plus agent attention alerts.
---

# notifications

Tessera turns the terminal bell (BEL) into something useful, in three
independent channels under **settings → terminal → bell**:

- **sound** — a soft tink when the terminal emits BEL. It mixes with your
  music, and only plays when the belling pane is off-screen or the app is
  backgrounded.
- **visual flash** — an accent glow plus a dot on the tmux tab pill that
  bell'd; foreground only.
- **notify when backgrounded** — a real iOS banner ("\<host\> · \<pane\>") so a
  long-running job can call you back. Enabling it triggers the iOS
  notification-permission prompt; if you deny it, Tessera shows a sheet that
  deep-links to the Settings app.

A **test bell** button previews the sound and the visual flash. Bells are rate-limited to one event
per source (session or tmux window) per 2 seconds.

Over [tmux](tmux.md), control-mode wiring is what tells Tessera which window
bell'd, so the flash and the banner point at the right tab.

## agent attention

If you use the [agent center](agent-center.md), its **attention
notifications** are a separate, more precise channel: banners when a Claude
Code or Codex session needs input or just finished, routed to the exact pane
when tapped. Enabling agent attention notifications turns the bell's
background banners off once — the agent channel carries the same information
with less noise.

iPadOS may suspend long background sessions, so background delivery is
best-effort for very long-running work.
