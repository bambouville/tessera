---
title: privacy policy
nav: 16
group: legal
description: Tessera collects no data — no analytics, no tracking, no telemetry.
---

# Tessera privacy policy

_Last updated: May 29, 2026_

Tessera is an SSH, Mosh, and tmux terminal for iPad. This policy explains what
data Tessera handles. The short version: **Tessera does not collect any
personal data.**

## No data collection

Tessera has no backend servers, no analytics, no tracking, no advertising, and
no third-party data-collection SDKs. The developers do not receive any
information about you or your use of the app.

## Data stored on your device

Everything you enter or create stays on your device (and in your own device or
iCloud backups, if you have those enabled):

- Host connection details (addresses, ports, usernames) you enter.
- SSH keys you generate or import. Keys are stored in the iOS Keychain. Secure
  Enclave–backed keys never leave the device.
- Known-host fingerprints, app preferences, and per-host settings.

This data is never transmitted to the developers. SSH and Mosh connections go
**directly** from your device to the servers you specify — there is no Tessera
infrastructure in between, because none exists.

## Network connections

Tessera connects only to the servers you configure, and connects to them
directly. Your credentials, keystrokes, and session data are not routed through
any Tessera-operated service.

## Permissions Tessera may request

- **Local Network** — to reach SSH/Mosh servers on your local network and to
  forward local ports to them.
- **Face ID / biometrics** — to unlock biometric-protected SSH keys and the
  app lock. Evaluated on-device by iOS; Tessera never sees your biometric data.
- **Microphone & Speech Recognition** (optional) — used only if you enable
  on-device dictation into the terminal. Speech is processed on-device; audio
  is not sent to the developers or any third party.
- **Notifications** (optional) — local notifications for the terminal bell /
  turn-complete signal, generated on-device.

## Diagnostic logs

Tessera can write a local diagnostic log (Settings → Diagnostics) to help with
troubleshooting. This log is stored on your device. It leaves your device only
if you explicitly export it — through the system share sheet, or to one of
your own servers via the upload sheet — and choose a destination yourself.
Tessera never uploads it automatically, and it is never sent to the
developers.

## Data retention & deletion

All data Tessera handles lives only on your device, so retention and deletion
are entirely under your control:

- Hosts, identities, preferences, known-host fingerprints, and the diagnostic
  log persist on-device until you delete them in the app (or delete the app).
- **SSH keys are stored in the iOS Keychain.** iOS may retain Keychain items
  even after an app is uninstalled, and (for non–Secure-Enclave keys) they can
  be carried into encrypted device backups. To remove keys completely, delete
  them in the app (Keys page) **before** uninstalling Tessera.
- No deletion request to the developers is possible or necessary: the
  developers hold no data about you.

## Children's privacy

Tessera does not collect data from anyone, including children.

## Changes to this policy

If this policy changes, the updated version will be posted at this page.

## Contact

Questions about this policy? Open an issue at
<https://github.com/bambouville/tessera/issues>.
