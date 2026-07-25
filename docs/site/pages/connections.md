---
title: hosts & connections
nav: 3
group: connecting
description: Host entries, ssh vs mosh, launch modes, jump hosts, sessions, and restore.
---

# Hosts & connections

## The host editor

Press **⌘N** for a new host, or tap an existing host to edit it. The editor has
four tabs — **connection**, **advanced**, **forwarding**, **snippets** — and a
**connect** bar.

The connection tab holds the basics: **name**, **address**, **port**
(1–65535), **user**, **identity** (a key from your [keys](keys.md) page), and
**password**. Passwords are session-scoped: they're kept only for the live
session and never persisted.

<figure>
<a href="/docs/assets/img/host-editor.png" aria-label="Enlarge screenshot">
<img src="/docs/assets/img/host-editor.png" alt="The host editor showing its four tabs — connection, advanced, forwarding, snippets — with the connection fields and the connect bar." loading="lazy" width="1500" height="1125">
</a>
<figcaption>Four tabs across the top, and a connect bar pinned to the bottom of every tab.</figcaption>
</figure>


## Transport: SSH or Mosh

Each host picks one transport:

- **ssh** — a single SSH connection; tmux tabs stay on the main session.
- **mosh** — a mosh terminal over UDP. Mosh keeps your session alive across
  Wi-Fi ↔ cellular roaming and sleep/wake, and feels snappier on lossy links.
  It requires `mosh-server` installed on the host. tmux tabs use a second SSH
  side channel.

Mosh's UDP traffic cannot traverse bastions: if you use mosh through a
[jump host](#jump-hosts) and the mosh server is unreachable, Tessera tells you
("mosh is unreachable through the jump chain…") and reconnects over SSH.

## Launch modes

- **auto-tmux** — attach to (or create) a per-host tmux session with a
  deterministic `tessera-XXXXXXXX` name, remembered across app reinstalls.
  The default, and the one that makes dropped connections harmless.
- **named tmux** — attach to a tmux session name you choose; names with
  invalid characters fall back to the auto-derived one.
- **custom** — a verbatim launch command. Over ssh it's sent to the login
  shell; over mosh it's run by `mosh-server new -- <command>`.

See [tmux](tmux.md) for what the tmux modes give you, and
[port forwarding](port-forwarding.md#mosh-and-forwarding) for how the launch
mode interacts with tunnels.

## Jump hosts

Any saved host can be used as an SSH bastion (ProxyJump): pick it in the host
editor. Chains nest — the jump host's own jump host extends the chain — and the
editor shows the resulting path ("a → b → host") with warnings for broken
chains. Jump-host passwords are kept only for the live session.

## Advanced tab

- **os logo** — auto-detected on connect, or set manually (macos, ubuntu,
  debian, alpine, linux, raspbian).
- **tags** and **notes** — for your own organization.
- **environment variables** — one `KEY=value` per line, passed verbatim to the
  remote side.
- **terminal background** — a per-host override of the global
  [background](appearance.md).

> Environment variables and startup snippets only run when the tmux session
> starts. If you change them for a host whose tmux session already exists,
> kill that session on the server to pick up the changes.

## Snippets

The snippets tab holds a **startup snippet**: commands sent immediately after
connecting (the same tmux caveat above applies).

## Sessions

Tessera keeps multiple concurrent sessions open to any hosts. Auto-tmux hosts
are singletons — one tmux control session per host (per host and session name
for named tmux) — while custom-command hosts can have several ("name #2",
"name #3"). The sidebar's **active** section
lists every session, labeled "name (tmux)", "name (tmux: session-name)", or
"name #N", each with a disconnect button.

Switch between sessions by tapping them, walking neighbors with **⌘⇧K** /
**⌘⇧J**, or opening the **⌘K** quick-switch palette: type to filter sessions
(most-recent first) and agents — prefix the query with `@` to scope to agents.

## Session restore

**settings → terminal → startup → previous connections** controls what happens
on a fresh launch:

- **ask** — shows a "reopen previous connections" sheet with
  "always reopen" / "reopen" / "not now".
- **always** — reconnects silently.
- **never** — starts clean.

Only saved-host sessions with intact key material are restorable. Tessera is
deliberately single-window (no multi-scene on iPadOS); the sidebar and the
palette are how you move around.
