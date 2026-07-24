---
title: appearance & themes
nav: 12
group: reference
description: Themes, backgrounds, fonts, cursor, and scrollback.
---

# appearance & themes

Tessera's own chrome and the terminal are themed separately: the app's
appearance settings style the interface around the terminal, and terminal
themes style the terminal itself.

## app appearance

Under **settings → appearance**:

- **mode** — system, dark, or light. Applies to the app chrome only; the
  terminal uses its own theme.
- **chrome material** — Liquid Glass options where supported (unsupported ones
  are hidden).
- **accent color** — blue, green, amber, or a custom color.
- **terminal font size** — 10–20 pt with a live preview.
- **top bar height** — scales the tab strip and icons, with a live preview.

## terminal themes

**settings → themes** shows a preview-card grid of terminal themes: Void,
Graphite, Amber CRT, Paper, Dracula, and Nord.

### background

Each theme's background can be the theme color or a **custom image** with dim,
blur, and fill controls. The background applies to every session unless a host
overrides it (host editor →
[advanced](connections.md#advanced-tab)). Full-screen apps that set their own
colors (vim, htop) paint over the picture.

## terminal behavior

Under **settings → terminal**:

- **cursor style** — block, bar, or underline, with **cursor blink** and a
  live preview.
- **scrollback lines** — 1,000 to 50,000, in steps of 1,000.
- **smooth scrolling** and **glide speed** — trackpad momentum, in scrollback
  only.
- **startup → previous connections** — the
  [session restore](connections.md#session-restore) policy.
- the **bell** section — sound, visual flash, background banner, and a test
  button; see [notifications](notifications.md).
