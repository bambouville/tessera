---
title: tmux
nav: 4
description: Native tmux control mode — windows as tabs, real panes, and sessions that survive drops.
---

# tmux

Tessera speaks tmux's control mode (`tmux -CC`) natively: windows and panes
are first-class interface elements, not a text passthrough. It requires `tmux`
installed on the server.

## why tmux

With a tmux-backed session, the shell lives on the server. Close Tessera, lose
Wi-Fi, switch to cellular, put the iPad to sleep — none of it kills your work.
Reconnect and you're exactly where you left off.

## attaching

The **auto-tmux** launch mode attaches to (or creates) a per-host session with
a deterministic `tessera-XXXXXXXX` name, remembered across app reinstalls.
**named tmux** attaches to a session name you choose. Both are set per host in
the [host editor](connections.md#launch-modes).

## windows

tmux windows appear as tabs in the session's top bar.

| shortcut | action |
| --- | --- |
| **⌘T** | new window |
| **⇧⌘W** | close pane / window |
| **⇧⌘[** / **⇧⌘]** | previous / next window |
| **⌘1** – **⌘9** | jump to window 1–9 |

## panes

Panes are real tmux panes, driven through control mode.

| shortcut | action |
| --- | --- |
| **⌘D** | split side by side |
| **⇧⌘D** | split stacked |
| **⌘[** / **⌘]** | cycle panes |
| **⇧⌘↩** | zoom / unzoom pane |

## mosh + tmux

Over mosh, the terminal runs on UDP while the tmux tabs ride a second SSH side
channel. That side channel is also what carries
[port forwarding](port-forwarding.md#mosh-and-forwarding) for mosh hosts.

## bells

tmux control-mode wiring is what lets Tessera route terminal bells to
[notifications](notifications.md) — per window, with the belling tab marked.

## gotchas

- Environment variables and startup snippets only run when the tmux session
  starts. After changing them, kill the session on the server
  (`tmux kill-session`) to pick up the changes.
- Attaching from Tessera and from another client at the same time works, but
  both clients share the same windows — that's tmux, not a bug.
