# User-visible unimplemented UI audit — 2026-08-12

Audited production SwiftUI surfaces for dead actions, placeholder status,
unshipped promises, misleading copy, and disabled controls that do not become
functional. The scan covered Hosts, Keys, Known Hosts, sessions and tmux,
Settings, onboarding/bootstrap, purchases, Remote Files, forwarding, Agent
Center, Swipe Pad, and compact iPhone variants.

## Fixed

| Surface | Finding | Resolution |
| --- | --- | --- |
| Keys | `share` only displayed `share ships later` | Implemented the native share sheet for the exact OpenSSH public-key line. No private material is read or shared. |
| Known Hosts | `export` and `import` buttons had empty action closures | Implemented interoperable OpenSSH `known_hosts` file export and user-selected file import. Import shows parsed additions, replacements, unchanged pins, and rejected lines for explicit confirmation before changing trust records. |
| Experimental | `active profile · auto-detected` always showed the first configured profile as green `matching` | Removed the false live-status card. Runtime resolution still occurs at Swipe Pad use. |
| Keyboard | Shortcut legend promised per-user remapping `on the roadmap` | Removed the unshipped promise and retained the working read-only legend. |
| Keyboard | The legend advertised `Command-Return` Connect, but Host Details did not register it | Implemented the shortcut on the real iPad Connect control. |
| Keyboard | The shortcut legend omitted the shipped terminal refresh and Agent Center chords | Added `Command-R` and `Command-Shift-A` to the reference. |
| Keys | Every key displayed `last used —`; no usage field or tracker existed | Implemented a device-local timestamp after server-accepted private-key authentication and live-policy revalidation; existing keys say `not recorded` until their next accepted use. |
| Hosts | Every table row displayed `last seen —`; no last-seen tracker existed | Implemented device-local successful-session timestamps and restored real relative values on iPad and iPhone. |
| Hosts | `recent` displayed the first three manual-sort-order hosts, not recently used hosts | Restored the working cards using successful saved-session timestamps, newest first; failed and never-connected hosts do not appear. |
| Hosts | Notes claimed to appear in tooltips, but no tooltip consumes them | Corrected the subtitle to describe stored free-form notes. |
| tmux | During degraded mosh+tmux synchronization, iPad tab selection and new-window controls remained enabled but controller passthrough made them no-ops | Disabled tab selection and new-window actions in the strip and overflow list until synchronization returns, with accessibility explanations. |

## Reviewed and retained

- Diagnostics export/upload/clear is disabled only when the log is empty.
- StoreKit purchase controls are disabled only while product/access state is
  unavailable, pending, or in flight; retry and restore paths are implemented.
- Agent notifications require Agent Center; on-device dictation is capability
  gated by the installed recognizer.
- Remote Files controls are connection/destination gated. Preview, download,
  share, upload, and path handling are wired through the shared SSH side channel
  for SSH, SSH+tmux, mosh, and mosh+tmux.
- Bootstrap grant rows reject only credential-ineligible routes and explain why.
- Legacy RSA, Secure Enclave export, key-integrity, host-key, tmux-unavailable,
  and SFTP/cwd unavailable states are deliberate fail-closed or capability
  states rather than unfinished UI.
- Onboarding claims for key installation, Remote Files sharing, screenshot
  upload, tmux, Agent Center, Swipe Pad, and continuity have production handlers.

## Upgrade verification

A real install-over rehearsal upgraded the public `v0.1.2` build to this build
on one disposable iPad simulator without uninstalling or erasing the app. The
old build created its shipped V1 SwiftData store and Keychain state: three
hosts, one identity, and one stored key. The raw DEBUG seed was then removed so
the new build could not recreate a missing Keychain item and produce a false
pass.

After installing and launching the new build over the same app container:

- exact before/after comparisons preserved every host, identity, key UUID, and
  persisted value;
- current key reconciliation reported `metadataOnly=0 orphaned=0
  invalidAccounts=0`, with no rejected material or repair failure;
- all three old hosts rendered normally, with no onboarding interruption;
- `Recent` remained hidden and old host/key activity rendered as `not recorded`
  because older releases never collected those device-local timestamps; and
- no activity record was synthesized during migration or ordinary app launch.

The new activity store is a versioned UserDefaults value rather than a
SwiftData model change. Existing SwiftData schemas therefore migrate exactly as
before, avoiding the iOS 26 array-column migration hazard on `PersistedHost`.

## Non-UI markers

The remaining `not implemented` match is an inert `StoredKey.agentForwarding`
schema-compatibility field that is explicitly not exposed. A few source-file
headers still contain old `stub` wording even though those implementations are
complete and wired; none is user-visible.
