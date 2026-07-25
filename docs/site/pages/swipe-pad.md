---
title: swipe pad
nav: 9
description: A floating thumb-zone puck with radial macros and on-device dictation (experimental).
---

# Swipe pad

The swipe pad is a floating thumb-zone puck for working without a hardware
keyboard: flick it to fire per-app macros, double-tap to dictate. It's
**experimental** and off by default — enable it in
**settings → experimental → swipe pad**.

## The puck

- **default corner** — where the puck sits at cold launch, until you move it;
  the last position is remembered and re-clamped when the orientation or
  screen size changes.
- **puck size** — compact (44 pt), standard (52 pt), or large (64 pt).
- **long press** picks the puck up; it stays where you drop it (kept fully
  on-screen).

## Gestures

Three discrete gestures:

- **tap, hold & drag** — opens the radial menu around the puck. Release on a
  direction to fire that macro; release in the dead zone to cancel.
- **double tap** — starts [dictation](#dictation).
- **long press** — moves the puck.

## Profiles

Radial petals come from **profiles** matched against the foreground process of
the active pane (via tmux's `pane_current_command`, or `ps` snapshots on plain
ssh). Profiles are evaluated top to bottom; the first match wins.

Built-in profiles:

| profile | right | left | up |
| --- | --- | --- | --- |
| **claude code** | `1↵` approve | `2↵` deny | `3↵` always |
| **codex cli** | `y` | `esc` | `p` |
| **fallback** (always on) | — | — | — |

The fallback matches everything and binds nothing — dictation still works.

Custom profiles get a process matcher (literal text or a `regex:` pattern) and
can declare **agent detection** rules — blocking/idle prompt regexes, a
menu-option regex, and response templates with `{index}` / `{shortcut}`
placeholders — which also feed the [agent center](agent-center.md). A profile
with invalid rules degrades to "status unavailable".

Petal labels follow the agent-prompt roles — right = approve, left = deny,
up = always, down = down; unbound petals are hidden.

## The macro language

Macros are written in a small spec:

- literal characters are sent as-is,
- `↵` for Enter,
- `esc`, `\e`, or `\x1b` for Escape,
- `\t` (or `tab`), `\r`, `\n`,
- `\xNN` for an arbitrary byte in hex.

## Dictation

Double-tap the puck to dictate into the terminal. Recognition happens
**on-device** (SFSpeechRecognizer) — no audio leaves the iPad. It uses your
device language, falling back to en-US when on-device recognition isn't
available for it, and requires microphone and speech-recognition permissions.
While dictating, the
puck morphs into a mic pill with a live waveform and an elapsed timer; tap to
commit, ✕ to cancel.

Options (settings → experimental):

- **commit on silence** — auto-send after 1.2 s of quiet,
- **append return** — end with Enter,
- **live waveform on the puck**.
