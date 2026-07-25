---
title: troubleshooting
nav: 15
description: Common snags — RSA, mosh, jump hosts, ports, tmux, permissions.
---

# Troubleshooting

## RSA keys are not supported

Tessera can't generate or import RSA keys: the current SSH stack can only
offer the deprecated RSA/SHA-1 signature. Generate an
[Ed25519 key](keys.md#generating-a-key) instead — every modern OpenSSH server
accepts it. RSA keys left over from older versions are shown disabled.

## Mosh won't connect

- Is `mosh-server` installed on the server?
- Can UDP reach the server? Some firewalls and most NATs block it; mosh needs
  UDP ports 60000–61000 by default.
- Over a [jump host](connections.md#jump-hosts): mosh's UDP can't traverse
  bastions. Tessera warns ("mosh is unreachable through the jump chain…") and
  falls back to SSH.

## Forwarding refuses a local port

The iOS sandbox can't bind ports below 1024 — pick a higher local port. Local
ports also can't repeat within one host. See [port forwarding](port-forwarding.md).

## Forwarding is disabled on a Mosh host

With transport mosh and **custom** launch mode there is no SSH connection to
carry forwards. Switch the launch mode to **auto-tmux** or **named tmux** —
those keep an SSH side channel that forwarding rides on.

## tmux didn't pick up my changes

Environment variables and startup snippets only run when the tmux session
starts. Kill the session on the server (`tmux kill-session`) and reconnect.

## The files panel says the host key isn't trusted

The files bridge is a separate SSH connection with the same trust rules. Open
a terminal session to the host, review the
[Unknown Host sheet](host-keys.md#first-connection), and accept the key — then
reopen the panel.

## The files panel doesn't follow my shell

Directory following needs OSC 7 from your shell. Use the panel's **Enable
follow — install shell integration** button, then `exec $SHELL` or reconnect.
Details in [files](files.md#following-your-shell).

## Local network connections fail

iPadOS gates LAN access behind the **Local Network** permission. If you denied
it, re-enable it in the Settings app under Tessera.

## Notifications don't arrive

Check the iOS notification permission (the bell settings sheet deep-links to
it). Remember that background delivery is best-effort: iPadOS may suspend long
background sessions. See [notifications](notifications.md).

## Known hosts export/import buttons do nothing

They're present in the interface but not wired up yet.

## Something else

Capture a diagnostics log (**settings → diagnostics → export log**) and file
an issue at [GitHub Issues](https://github.com/bambouville/tessera/issues).
The log is redacted and only leaves your device when you share it.
