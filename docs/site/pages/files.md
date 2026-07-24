---
title: files
nav: 10
description: A remote file panel that tracks your shell's directory — over SSH and mosh alike.
---

# files

The **files** panel slides out beside the terminal and shows the remote
directory your shell is sitting in. Open it with **⌘⇧E** or the folder glyph
in the session's top bar.

File operations always run over a dedicated, lazily-opened SSH+SFTP **bridge**
per host — never the terminal transport — so the panel works identically for
ssh and mosh sessions. The bridge closes itself when idle.

## following your shell

The panel tracks the shell's current directory via OSC 7 escape sequences. If
your shell doesn't emit them, the panel offers **Enable follow — install shell
integration**, which installs `~/.config/tessera/osc7.sh` on the server and
hooks it into `.zshrc` / `.bashrc` (marked with `# TESSERA-OSC7`). It takes
effect on the next shell login — run `exec $SHELL` or reconnect.

You can also turn following off per panel and browse freely.

## browsing

The panel's breadcrumb bar shows the current path with a follow toggle.
Actions:

- **upload here**, **new folder**,
- hidden-file toggle, sort, refresh,
- **filter this directory**,
- **open by path** with tab-completion suggestions,
- a recents list.

Each file's context menu offers **Quick Look** (downloads to preview),
**Download**, **Share…** (the iOS share sheet), and **Send Path to Terminal**.
Transfers show up in a progress strip, and errors are explicit — for example:
"This host's key isn't trusted yet. Open a terminal session to it first to
review the key, then retry." (see
[host key verification](host-keys.md#first-connection)).

## uploading

Three ways in:

- **Upload here** in the panel.
- **Drag and drop** a file onto the terminal — it's uploaded and its remote
  path is typed for you.
- **Share into Tessera** from other apps — images through the iOS share
  sheet, other file types through "open in Tessera". The *Upload to host*
  sheet picks the host and a
  destination — **session cwd** or **temp folder** (`~/.cache/tessera`) — with
  a **Paste path into active session** toggle. Hosts that aren't connected show
  "connect & upload".

The paste-path flow is built for agent workflows: paste or share a screenshot
and Claude Code / Codex pick the file up from the typed path.

Tessera also appears under "On My iPad" in the Files app, so downloads are
easy to reach from other apps.

## housekeeping

Under **settings → files**:

- **temp file cleanup** — a reaper deletes `paste-*` files in the temp folder
  on connect: off, 1 day, 7 days (default), or 30 days.
- **default upload destination** — session cwd or temp folder, remembered per
  host.
