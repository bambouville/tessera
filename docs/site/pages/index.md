---
title: overview
nav: 1
group: start
description: Tessera is an SSH, Mosh, and tmux terminal for iPad — fast, keyboard-first, and private by design.
---

# Tessera docs

**Tessera is an SSH, Mosh, and tmux terminal for iPad** — fast, keyboard-first,
and private by design. It connects directly to servers you own or control;
there is no Tessera backend, no account, and no data collection.

- [Tessera on the App Store](https://apps.apple.com/us/app/tessera-ssh-terminal/id6779869388) — requires iPadOS 17 or later (iPad only)
- [Source code (GPL-3.0)](https://github.com/bambouville/tessera)
- [Support & bug reports](https://github.com/bambouville/tessera/issues)

Mosh and tmux features require `mosh-server` / `tmux` installed on the server.

## What Tessera does

- **SSH and Mosh.** Password and key authentication; Mosh keeps your session
  alive across Wi-Fi ↔ cellular roaming and sleep/wake.
- **tmux integration.** Native control mode — auto-attach on connect so a
  dropped connection never loses your work; windows and panes are real UI.
- **Secure by design.** Keys live in the iOS Keychain; Secure Enclave–backed
  P-256 keys never leave the device and can require Face ID to use. Host-key
  verification with a persistent known-hosts store, plus an app lock.
- **Local port forwarding** to reach services behind your server.
- **Files beside your shell.** A remote file panel that tracks your shell's
  directory, over SSH and mosh alike.
- **Agent center.** Watch and answer Claude Code and Codex sessions across all
  your connections from one page (experimental).
- **Built for iPad.** First-class hardware-keyboard support, a configurable
  swipe pad for the touch screen, Stage Manager / Split View, session restore,
  find-in-terminal, themes, and optional on-device dictation.

## The guide

- [getting started](getting-started.md) — install, first host, first connection
- [hosts & connections](connections.md) — transports, launch modes, jump hosts
- [tmux](tmux.md) — windows, panes, and why your work survives drops
- [keys](keys.md) — generate, import, protect, install, recover
- [host key verification](host-keys.md) — trust on first use, known hosts
- [port forwarding](port-forwarding.md) — tunnels to services behind your server
- [keyboard & input](keyboard.md) — shortcuts and the accessory bar
- [swipe pad](swipe-pad.md) — radial macros and dictation (experimental)
- [files](files.md) — browse, transfer, and share remote files
- [agent center](agent-center.md) — Claude Code and Codex oversight (experimental)
- [appearance & themes](appearance.md) — make it yours
- [security & app lock](security.md) — locking, biometrics, diagnostics
- [notifications](notifications.md) — bells and agent attention
- [troubleshooting](troubleshooting.md) — common snags
- [privacy policy](privacy.md) — the short version: no data collection
