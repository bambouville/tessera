# Tessera

**Tessera is an SSH, Mosh, and tmux terminal for iPhone, iPad, and Android** —
fast, keyboard-first, and private by design. It connects directly to servers
you own or control; there is no Tessera backend, no account, and no data
collection.

- [Tessera on the App Store](https://apps.apple.com/us/app/tessera-ssh-terminal/id6779869388)
- [User guide](https://bambouville.com/docs/)
- [Support & bug reports](https://github.com/bambouville/tessera/issues)

## Features

- **SSH and Mosh.** Password and key authentication, jump hosts, and
  per-host launch options. Mosh keeps your session alive across
  Wi-Fi ↔ cellular roaming and sleep/wake, reconnects quickly, and finds
  `mosh-server` installed by Homebrew or Nix.
- **Native tmux.** Tessera drives tmux control mode, so windows and panes are
  real tabs and splits. Auto-attach on connect means a dropped connection never
  loses your work. Drag tabs to reorder windows, long-press a tab to split it,
  jump between windows and panes with ⌘K on iPad, and scroll a pane's full
  history with your finger. Copying in tmux reaches the iOS clipboard.
- **Agent Center (experimental).** Follow the Claude Code and Codex sessions
  running on your servers in one list. Read and search full conversations,
  reply with text, photos, files, or dictation, answer an agent's questions
  without opening the terminal, and start a new agent in a tmux window or
  split. With your approval, it installs a small helper on each host.
- **Program status.** Scripts and tools can report "needs input",
  "finished", or "failed" (OSC 7501), shown on tabs, the session list, and the
  switcher.
- **Files beside your shell.** A remote file panel that follows your shell's
  directory over SSH and Mosh alike, with SFTP transfers, Quick Look and
  Markdown previews, and a Share extension for uploading photos, videos, and
  files.
- **Port forwarding.** Local tunnels to services behind your server, a
  built-in browser for forwarded web pages, and a live indicator that shows
  when the far end answers.
- **Pair by QR code.** Copy your setup to another device, even one on a
  different Apple Account, or continue a session there. You choose which hosts
  to copy; passwords and private keys never leave the device.
- **Secure by design.** Keys live in the iOS Keychain; Secure Enclave–backed
  P-256 keys never leave the device and can require Face ID to use. Host-key
  verification with a persistent known-hosts store, an app lock (Face ID /
  passcode), and an option to hide content in the app switcher.
- **Keyboard-first.** Remappable hardware-keyboard shortcuts with a legend
  (hold ⌘), custom shortcuts that send your own text or key sequences, an
  accessory bar on iPhone, a configurable swipe pad, Stage Manager / Split
  View, session restore, find-in-terminal, ten terminal fonts, themes, and
  optional on-device dictation.
- **Seven languages.** English, French, German, Spanish, Japanese, Simplified
  Chinese, and Traditional Chinese.

Requires iOS or iPadOS 17 or later. The Android app (Android 13 or later) is
built from the same repository. Mosh and tmux features require `mosh-server` /
`tmux` installed on the server.

## Privacy

Tessera collects no data — no analytics, no tracking, no telemetry. Everything
you enter stays on your device, and connections go directly from your device to
your machines. See the [privacy policy](docs/privacy-policy.md).

## Building from source

Clone with submodules and hydrate the Git LFS objects (`brew install git-lfs`):

```sh
git clone --recurse-submodules https://github.com/bambouville/tessera.git
cd tessera
git lfs install --local
git lfs pull
```

Bundled Agent Host executables use Git LFS; run `git lfs pull` before building
an existing checkout, too. Unhydrated LFS pointers are not usable binaries.

### iPhone and iPad

You need a Mac with Xcode 26 or later. Open `Tessera.xcodeproj`, select your
own development team for signing, and build the `Tessera` scheme for an iPhone
or iPad (or a simulator). The mosh and protobuf runtimes are vendored as git
submodules under `Packages/MoshBridge/Vendor/` and compiled from source — no
other toolchain is needed.

### Android

You need JDK 21 and the Android SDK and NDK listed in
[`android/README.md`](android/README.md), which also covers the native Mosh
setup. Then, from `android/`:

```sh
./gradlew :app:assembleDebug
```

### Project layout

| Path | Contents |
| --- | --- |
| `Tessera/` | The iPhone and iPad app: sessions, hosts, keys, settings, terminal UI |
| `TesseraShareExtension/` | Share-sheet uploads into remote Files |
| `android/` | The Android app (Kotlin / Jetpack Compose) |
| `Packages/TesseraCore/` | Shared runtime used by both platforms |
| `Packages/Citadel/` | SSH client, built on Apple's SwiftNIO SSH |
| `Packages/MoshBridge/` | Mosh client core + vendored mosh/protobuf-lite |
| `Packages/TmuxControl/` | tmux control-mode (`-CC`) protocol handling |
| `Packages/PortForwarding/` | Port-forwarding listeners |
| `Packages/ScrollDispatcher/` | Terminal scroll-gesture routing |
| `Tools/AgentHost/` | The Agent Center host helper |
| `TesseraBridge/` | Experimental macOS companion for continuing sessions |
| `SharedAssets/` | Fonts and binaries shipped by both platforms |
| `l10n/` | Translations |
| `TesseraTests/`, `TesseraUITests/`, `scripts/integration/` | Unit, UI, and integration tests |
| `docs/site/` | The user guide |

## License

Copyright (C) 2026 Bambouville Inc.

Tessera is free software, licensed under the
[GNU GPL v3](LICENSE). Distribution through the App Store is covered by the
additional permissions in [`COPYING.iOS`](COPYING.iOS) (mosh's iOS exception,
extended with Tessera's own App Store distribution exception, granted by
Bambouville Inc.). See [`COPYRIGHT`](COPYRIGHT) for the full notice.
"Tessera" and the Tessera icon are trademarks of Bambouville Inc. (not
licensed under the GPL).

Tessera builds on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT),
[Citadel](https://github.com/orlandos-nl/Citadel) (MIT),
[SwiftNIO SSH](https://github.com/apple/swift-nio-ssh) (Apache-2.0),
[Swift Markdown](https://github.com/swiftlang/swift-markdown) (Apache-2.0),
[Mosh](https://mosh.org) (GPL-3.0),
[Protocol Buffers](https://protobuf.dev) (BSD-3-Clause), and, on Android,
[SSHJ](https://github.com/hierynomus/sshj) (Apache-2.0). Bundled fonts and the
remaining components are listed in
[`Tessera/Resources/ThirdPartyNotices.txt`](Tessera/Resources/ThirdPartyNotices.txt).

## Support

Bug reports and questions: [GitHub Issues](https://github.com/bambouville/tessera/issues).
