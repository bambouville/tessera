# Termux terminal fork provenance

The Java sources under `src/main/java/com/termux/terminal` and
`src/main/java/com/termux/view`, plus the selection-handle resources under
`src/main/res`, were copied from the official `termux/termux-app` repository:

- tag: `v0.118.3`
- commit: `5b657c6adf4304e5198951ce815fe0205dcac29c`
- source paths: `terminal-emulator/src/main` and `terminal-view/src/main`
- upstream: <https://github.com/termux/termux-app>

The upstream root `LICENSE.md` identifies `terminal-emulator` and
`terminal-view` as the Apache License 2.0 exception to the repository's GPLv3
license. Tessera itself is GPLv3 with its App Store exception.

Tessera's Phase A fork changes `TerminalSession.java` to add an external-session
constructor and callbacks so a remote transport can feed output, receive input,
and own resize without launching a local Android subprocess or loading Termux's
PTY JNI library. The two text-selection classes import the containing Tessera
module's generated `R` class. Tessera-specific Kotlin remains under
`com.bambouville.tessera.terminal`. Two narrow lint adaptations add an explicit
locale to a diagnostic and acknowledge upstream API guards made redundant by
Tessera's API 33 floor; the unused upstream local-PTY reflection is explicitly
suppressed and its JNI library is not packaged.

Before updating the snapshot, review the upstream diff from the commit above,
reapply the narrow external-session patch, rerun the Android terminal device
gate, and update this file and the dependency/SBOM record together.
