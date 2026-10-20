---
title: Tessera Privacy Policy
permalink: /privacy-policy
---

# Tessera Privacy Policy

_Last updated: October 19, 2026_

Tessera is an SSH, Mosh, and tmux terminal for iPad, iPhone, and Android. This policy explains what
data Tessera handles. The short version: **Tessera has no automatic data
collection.**

## No data collection

Tessera has no backend servers, no accounts, no analytics, no tracking, no
advertising, and no third-party data-collection SDKs. The developers do not
automatically receive information about you or your use of the app. You can
choose to send a diagnostic log or other information when contacting us for
support.

## Data stored on your device

Connection settings and other app data are stored on your device. Some data may
also be included in your device or iCloud backups, depending on your settings
and the type of data:

- Host connection details (addresses, ports, usernames) you enter.
- SSH keys you generate or import, and saved passwords. On iOS, these are
  stored in the Keychain. Secure Enclave–backed private keys never leave the
  device.
- Known-host fingerprints, app preferences, and per-host settings.
- Local copies of files you select for upload or share with Tessera, and files
  you download from your hosts.

Tessera does not use iCloud to sync hosts or credentials. iCloud device backups
are separate and depend on your system settings; iOS SSH keys are not marked
for iCloud Keychain synchronization.

Tessera does not automatically transmit this data to the developers. SSH and
Mosh connections go to the servers you specify, including any jump hosts you
configure — there is no Tessera infrastructure in between, because none exists.

## Network connections

Your credentials, keystrokes, and session data are sent to your configured
hosts, not through any Tessera-operated service.

Files panel uploads, Share-extension uploads, and Agent Center photo/file
attachments send the content you select over SSH/SFTP to your chosen host.
These features use system file and photo pickers or content you explicitly
share with Tessera. Tessera does not request photo-library access. Uploaded
files are stored on your host, subject to cleanup or deletion there.

Nearby setup transfer uses Bonjour discovery on your local network. QR pairing
also connects devices over the local network. After you verify the devices and
approve the transfer, Tessera sends selected host settings and other setup data
over an encrypted device-to-device connection. Passwords and private keys are
not copied; you can separately approve installing the receiving device's public
key on selected hosts to grant access.

On Apple devices, optional Handoff publishes session connection details through
Apple's Handoff system so you can continue on another device. These details can
include host names, addresses, usernames, ports, jump hosts, and tmux session
names, but not passwords or private keys.

The in-app tunnel browser opens web services through a forwarded port on your
device's localhost, carried over SSH to the configured destination. It uses a
nonpersistent WebKit data store for cookies and website data. Pages you open
can load external resources or navigate to other sites; those requests may
connect directly to those sites outside the tunnel. Those services handle data
you submit under their own policies.

On iOS, purchases and restores use Apple's StoreKit and App Store services.
Tessera checks purchase entitlements on-device; it has no purchase-validation
server and does not receive your payment details. Apple's handling of purchase
data is governed by Apple's policies.

## Agent Center (optional)

Agent Center reads agent transcripts from the servers you connect to, over your
SSH connection. Transcripts may contain source code, tool output, credentials,
and other sensitive text. Transcript bodies are cached in memory on the device;
Tessera does not upload them to a developer service or persist them as a local
transcript database. Thread metadata may be stored locally; on iOS, composer
drafts are held in memory. Optional title generation uses an on-device model
when available.

Agent Center also lets you send prompts, answers, and attachments to AI coding
agent processes, such as Claude Code and Codex, running on your own remote
host. In tmux sessions, Tessera delivers input through tmux; attachments are
uploaded over your SSH connection. The agents execute on that host and may
forward content to their own providers under your accounts and the providers'
terms and privacy policies. Tessera has no server in that path.

When you explicitly install integration, Tessera uploads a bundled native helper
and scripts to `~/.config/tessera` on that host, adds shell startup lines, and
merges hooks into the supported providers' configuration files. The Agent Host
helper runs on your user-controlled host, reads supported agents' local
transcripts and session metadata, and receives hook events. Integration scripts
also inspect agent processes and terminal/tmux state to identify sessions and
deliver input. The helper uses local Unix sockets; it does not expose a network
listener or send data to a Tessera service. These remote files remain if you
uninstall the mobile app. To remove integration, close running agents, run
`~/.config/tessera/agent-uninstall.sh` on that host, and restart your
shells. Removal preserves unrelated provider settings and hooks. Provider
transcripts remain under your control in the providers' own storage.

Dictation requires an available on-device recognizer; Tessera does not fall back
to cloud speech recognition. Code copied through Agent Center's copy button on
iOS is marked local-only to prevent Universal Clipboard synchronization.
Settings → security → hide content in app switcher hides Tessera's
app-switcher (Android: Recents) preview on this device. It is
off by default and always on while app lock is enabled. On Android it also blocks
screenshots and screen sharing while Agent Center is open, including its dialogs;
normal capture resumes when you leave Agent Center.

## Permissions Tessera may request

- **Local Network** — to reach SSH/Mosh servers on your local network and to
  forward local ports to them, and for Bonjour discovery, nearby setup transfer,
  and QR pairing between devices.
- **Camera** (optional) — to scan a Tessera pairing QR code displayed on a
  nearby device when transferring setup or continuing a session. QR codes are
  decoded on-device; Tessera does not save camera images or send camera frames
  off the device.
- **Face ID / biometrics** — to unlock biometric-protected SSH keys and the
  app lock, and to approve setup transfers and device-access grants.
  The operating system evaluates authentication on-device; Tessera never sees
  your biometric data.
- **Microphone & Speech Recognition** (optional) — used only if you enable
  Tessera's dictation into the terminal or an Agent Center draft. An on-device
  recognizer is required; there is no cloud-recognition fallback. Speech audio
  is processed on-device and is not uploaded by Tessera. Text you send is
  handled like other terminal input or agent prompts.
- **Notifications** (optional) — local notifications for the terminal bell /
  turn-complete signal and Agent Center attention, generated on-device.

## Diagnostic logs

Tessera can write a local diagnostic log (Settings → Diagnostics) to help with
troubleshooting. This log is stored on your device. You can explicitly export it
using the system share sheet, upload it to a host you choose, or use “send to
developer” to compose an email with the log attached. The email includes the
app version, device model, and OS version, and is sent only if you choose to
send it. If you send it to the developer, the developer receives the information
you choose to share. Tessera never uploads diagnostics automatically.

## Data retention & deletion

Retention and deletion are under your control on your devices and hosts:

- Hosts, identities, preferences, and known-host fingerprints persist on-device
  until you delete them in the app (or delete the app). Diagnostic logs are
  bounded and rotated; you can clear them in Settings → Diagnostics.
- **SSH keys are stored in the iOS Keychain.** iOS may retain Keychain items
  even after an app is uninstalled. Some software keys can be included in
  encrypted device backups. To remove local keys, delete
  them in the app (Keys page) **before** uninstalling Tessera.
- Uploaded files and remote integration data are managed on your hosts;
  deleting Tessera does not remove them.
- No deletion request to the developers is needed for data that stays on your
  devices or hosts. If you choose to send a support report, you can contact us
  about that report.

## Children's privacy

Tessera does not automatically collect data from anyone, including children.

## Changes to this policy

If this policy changes, the updated version will be posted at this page.

## Contact

Questions about this policy? Open an issue at
<https://github.com/bambouville/tessera/issues>.
