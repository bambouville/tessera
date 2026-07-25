---
title: getting started
nav: 2
description: Install Tessera, add your first host, and connect — in about two minutes.
---

# Getting started

## What you need

- An iPad running **iPadOS 17 or later**.
- A server you can already reach over SSH — any Linux, BSD, or macOS machine
  with an SSH server.
- Optional, on the server: `tmux` for the tmux integration, and `mosh-server`
  for mosh connections.

## Install

Get Tessera on the
[App Store](https://apps.apple.com/us/app/tessera-ssh-terminal/id6779869388).

## The tour

On first launch Tessera offers a short tour of the interface — adding hosts,
keys, tmux, the swipe pad, files, and the keyboard shortcuts. You can skip it;
to see it again later, go to **settings → about → replay walkthrough**.

## Add your first host

1. Press **⌘N** (or tap the add-host button) to open the host editor.
2. Fill in **name**, **address**, **port** (22 unless yours differs), and
   **user**.
3. Set authentication on the connection tab: pick a saved key in the
   **identity** field (the better default — see [keys](keys.md)), or type a
   **password**. Passwords are kept only for the live session and never
   stored.
4. Tap **connect**.

The full set of host options — transports, launch modes, jump hosts, snippets —
is covered in [hosts & connections](connections.md).

<figure>
<a href="/docs/assets/img/host-editor.png" aria-label="Enlarge screenshot">
<img src="/docs/assets/img/host-editor.png" alt="The Tessera host editor, connection tab: name, address, port, user, identity, password, transport, jump host, and launch mode, with the connect bar at the bottom." loading="lazy" width="1500" height="1125">
</a>
<figcaption>The host editor. The connection tab holds everything needed for a first connection; the connect bar sits at the bottom.</figcaption>
</figure>


## Trust the host key

The first time you connect to a server, Tessera stops with an **Unknown Host**
sheet showing the server's SHA-256 fingerprint and key type. Verify the
fingerprint against a source you trust (your provider's dashboard, or
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the server itself), then
tap **Accept New Key**. Details in [host key verification](host-keys.md).

<figure>
<a href="/docs/assets/img/unknown-host.png" aria-label="Enlarge screenshot">
<img src="/docs/assets/img/unknown-host.png" alt="The Unknown Host sheet showing the server address, its SHA-256 fingerprint, the key type ssh-ed25519, and Accept New Key and Reject buttons." loading="lazy" width="1500" height="1125">
</a>
<figcaption>First connection to a new server: compare the fingerprint, then accept or reject.</figcaption>
</figure>


## Set up a key

Passwords work, but a key is safer and less typing:

1. Open **keys** in the sidebar and tap **+ generate**.
2. Choose **Ed25519** (the fast, modern default).
3. Open the key, tap **copy to host…**, and pick the host you just connected
   to. Tessera appends the public key to `~/.ssh/authorized_keys` on the server.
4. Back in the host editor, select the key as the host's **identity**.

Everything about keys — Secure Enclave keys, biometrics, recovery files — is in
[keys](keys.md).

## The local network permission

iPadOS will ask for **Local Network** permission the first time you connect to
an address on your LAN. Tessera needs it to reach SSH/Mosh servers on your
local network and to forward local ports to them. If you denied it by mistake,
re-enable it in the iPadOS **Settings** app under Tessera.
