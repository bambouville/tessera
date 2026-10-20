# Tessera Bridge

This directory contains the macOS 14+ continuity origin described in
`docs/refactor/tessera-mac-iterm2-extension-after-shared-refactor.md`.

## Current milestone

The bidirectional feasibility milestone is in progress. The current app provides a human-testable
surface that:

- imports the existing `TesseraAppleContinuity` publisher;
- creates the unchanged secret-free `ContinuationDescriptorV1` through
  `TesseraBridgeCore`;
- constrains Mac-origin activities to SSH, pinned tmux, and no bastion route;
- rejects loopback, wildcard, whitespace-containing endpoints, and unsafe tmux
  names;
- advertises continuation-stream support and records stream arrival without
  attempting enrollment;
- publishes explicitly for five minutes and supports immediate invalidation;
- remains eligible to publish while iTerm2 is the foreground application;
- receives the same v1 Handoff activity from Tessera on iPhone or iPad;
- keeps the Mac endpoint identity in a device-only Keychain item and migrates
  the Phase 0 preference value once;
- classifies an incoming endpoint as this Mac by stable host identity, or by
  local endpoint plus SSH host-key fingerprint when the devices saved the host
  independently;
- verifies the local account and exact tmux session before opening it as an
  iTerm2 tmux integration window, without SSHing to localhost; and
- binds the transaction to tmux's immutable session ID, requires a new iTerm2
  control client plus a one-time receipt, and only then stamps that session
  with Tessera's shared authority grammar.

The reverse path currently targets the default local tmux socket and an exact
session name. It does not yet open remote-host continuations, inspect Remote
Login, install credentials, or provide cross-account discovery and pairing.
Those remain later phases. The mobile UI remains shared on iPhone and iPad;
this slice adds no device-specific mobile UI or transport fork.

## Build and test

```sh
swift test --package-path Packages/TesseraBridgeCore --disable-sandbox

xcodebuild \
  -project TesseraBridge.xcodeproj \
  -scheme TesseraBridge \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/tessera-bridge-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Debug builds also accept `TESSERA_BRIDGE_REVERSE_HARNESS_SESSION=<name>`.
Launching the app executable with that environment value exercises the same
descriptor receiver and local attach path as the debug button, against only the
named disposable tmux session. If an ad-hoc test build cannot access Keychain,
only this explicit DEBUG harness uses a fixed ephemeral Mac identity.

The package test includes the Mac encode → released mobile v1 decode golden
gate. The Xcode project defaults to bundle identifier
`com.bambouville.TesseraBridge`, development team `9ZW4K2PQ8X`, hardened
runtime, and the shared Handoff activity type.

The first reverse continuation asks for macOS Automation permission because
Bridge uses iTerm2's bundled `it2run` launcher. The hardened target declares the
Apple Events entitlement and purpose string; denying that permission fails the
attach without changing tmux authority.

## Physical Handoff gate

An unsigned or ad-hoc-signed build is enough for local UI verification but is
not evidence that cross-device Handoff works. Before marking Phase 0 complete:

1. Sign the Bridge with the same Apple developer team as the Tessera mobile
   build and provision `com.bambouville.TesseraBridge` for the shared activity.
2. Run Bridge on the Mac and Tessera on a physical iPhone and iPad signed by
   that team and logged into the same Apple account.
3. Enter a reachable Mac SSH endpoint and an existing tmux session, then choose
   **Publish for Handoff**.
4. Put iTerm2 in the foreground and confirm the activity remains discoverable
   on each mobile device.
5. Accept the activity and confirm the existing mobile continuation receiver
   decodes the v1 payload and targets the exact SSH/tmux coordinates.
6. Exercise a continuation-stream request and confirm Bridge increments its
   stream count, then stops cleanly because enrollment is intentionally not
   implemented in Phase 0.
7. Start that host's exact tmux session in Tessera on iPhone or iPad, continue
   it to the Mac, and confirm Bridge opens a new iTerm2 tmux integration window
   attached directly to the local session rather than making an SSH connection.
8. Confirm a different local account, mismatched SSH host-key hint, bastion
   route, missing session name, and nonexistent tmux session all fail closed.

Do not call the physical gate passed based only on the package tests, local UI,
the debug reverse-continuation button, or ad-hoc signing. Handoff requires the
Mac and mobile device to use the same Apple account; the documented Pairing v1
transport is the cross-account and Android path planned for the next milestone.
