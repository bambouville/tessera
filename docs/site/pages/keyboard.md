---
title: keyboard & input
nav: 8
group: using tessera
description: Hardware-keyboard shortcuts, the on-screen accessory bar, and text editing.
---

# keyboard & input

Tessera is keyboard-first. The tables below are the full reference; a
condensed legend lives in **settings → keyboard & input → shortcuts**.

## global

| shortcut | action |
| --- | --- |
| **⌘N** | new host |
| **⌘↩** | connect (in the host editor) |
| **⌘K** | quick-switch palette (sessions and agents; prefix `@` for agents) |
| **⌘,** | settings |

## sessions

| shortcut | action |
| --- | --- |
| **⌘⇧K** / **⌘⇧J** | previous / next session |
| **⌘⇧E** | files panel |
| **⌘⇧A** | agent center |

## tmux

| shortcut | action |
| --- | --- |
| **⌘T** | new window |
| **⇧⌘W** | close pane / window |
| **⇧⌘[** / **⇧⌘]** | previous / next window |
| **⌘1** – **⌘9** | jump to window |
| **⌘D** / **⇧⌘D** | split side by side / stacked |
| **⌘[** / **⌘]** | cycle panes |
| **⇧⌘↩** | zoom pane |

See [tmux](tmux.md) for details.

## find in terminal

**⌘F** (or the magnifier) opens the scrollback find bar: case-sensitive (Aa),
whole-word ([w]), and regex (.\*) toggles, a match counter, and
**↑** / **↓** or **↩** / **⇧↩** to move between matches. **esc** closes.

| shortcut | action |
| --- | --- |
| **⌘F** | open find |
| **⌘G** / **⇧⌘G** | next / previous match |
| **↩** / **⇧↩** | next / previous match |
| **esc** | close find |

## text editing

With **natural text editing** enabled (settings → keyboard & input), the
mac-style editing chords work in shells:

| shortcut | action |
| --- | --- |
| **⌥←** / **⌥→** | move by word |
| **⌘←** / **⌘→** | line start / end |
| **⌥⌫** | delete word |
| **⌘⌫** | delete to line start |

## the accessory bar

The on-screen **accessory bar** sits above the software keyboard and gives you
the keys a glass keyboard lacks. Default chips:
`esc ^ ⌥ ⇥ ← ↓ ↑ → | ~`.

Under **settings → keyboard & input**:

- **show accessory bar** — toggle it,
- the layout editor — long-press and drag chips to reorder, or pull in more
  from the palette (navigation, modifiers, F1–F12, symbols such as
  `/ \ $ { } [ ] < >`), with **restore defaults** to undo,
- **modifier behavior** — one-shot (applies to the next key) or sticky.

## the swipe pad

If you work without a hardware keyboard, the experimental
[swipe pad](swipe-pad.md) adds radial macros and dictation under your thumb.
