# Tessera

**Tessera is an SSH, Mosh, and tmux terminal for iPad** — fast, keyboard-first,
and private by design. It connects directly to servers you own or control;
there is no Tessera backend, no account, and no data collection.

## Features

- **SSH and Mosh.** Password and key authentication; Mosh keeps your session
  alive across Wi-Fi ↔ cellular roaming and sleep/wake.
- **tmux integration.** Auto-attach to a tmux session on connect so a dropped
  connection never loses your work; tmux control-mode wiring drives
  terminal-bell notifications.
- **Secure by design.** Keys live in the iOS Keychain; Secure Enclave–backed
  P256 keys never leave the device and can require Face ID to use. Host-key
  verification with a persistent known-hosts store, plus an app lock (Face ID /
  passcode) on launch, background return, and idle timeout.
- **Local port forwarding** to reach services behind your server.
- **Built for iPad.** First-class hardware-keyboard support with a shortcut
  legend (hold ⌘), a configurable swipe pad for arrows/Esc/Ctrl on the touch
  screen, Stage Manager / Split View, session restore, find-in-terminal,
  themes, and optional on-device dictation.

Requires iPadOS 17 or later (iPad only). Mosh and tmux features require
`mosh-server` / `tmux` installed on the server.

## Documentation

User guide: [bambouville.com/docs](https://bambouville.com/docs/) — getting
started, keys, tmux, port forwarding, files, the agent center, and more. The
Markdown source lives in [`docs/site/pages/`](docs/site/pages/) and is
published automatically to Cloudflare on every push to `main` (see
[`.github/workflows/docs.yml`](.github/workflows/docs.yml)).

## Privacy

Tessera collects no data — no analytics, no tracking, no telemetry. Everything
you enter stays on your device, and connections go directly from your iPad to
your machines. See the [privacy policy](https://bambouville.com/docs/privacy/).

## Building from source

You need a Mac with Xcode 26 or later.

```sh
git clone --recurse-submodules https://github.com/bambouville/tessera.git
cd tessera
open Tessera.xcodeproj
```

Select your own development team for signing, then build the `Tessera` scheme
for an iPad (or iPad simulator) destination. The mosh and protobuf runtimes are
vendored as git submodules under `Packages/MoshBridge/Vendor/` and compiled
from source — no other toolchain is needed.

### Project layout

| Path | Contents |
| --- | --- |
| `Tessera/` | The app: sessions, hosts, keys, settings, terminal UI |
| `Packages/MoshBridge/` | Mosh client core + vendored mosh/protobuf-lite |
| `Packages/TmuxControl/` | tmux control-mode (`-CC`) protocol handling |
| `Packages/PortForwarding/` | Local port-forwarding listeners |
| `Packages/ScrollDispatcher/` | Terminal scroll-gesture routing |
| `TesseraTests/` | Unit tests |

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
[BigInt](https://github.com/attaswift/BigInt) (MIT),
[Mosh](https://mosh.org) (GPL-3.0), and
[Protocol Buffers](https://protobuf.dev) (BSD-3-Clause).

## Support

Bug reports and questions: [GitHub Issues](https://github.com/bambouville/tessera/issues).
