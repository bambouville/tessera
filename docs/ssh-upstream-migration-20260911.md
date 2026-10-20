# Citadel migration to Apple SwiftNIO SSH

## Scope and cause

Work started on primary `main` at `f760bceabed6a7c3804f0a3f43ca72871314fd8f`.
This fixes the physical iPad crash in `SSHChildChannel.deliverSingleRead` →
`ChildChannelStateMachine.sendChannelWindowAdjust`, with the assertion
`Sent channel window adjust on channel in invalid state`. This is **not** a claim
that every previously reported typing/rendering/Agent Center issue is resolved.

The previous dependency was Wellz26/swift-nio-ssh 0.3.6,
`a05e6bbe6b141ee68da3030e00275504c0595d4d`. It lacked Apple's local-close guard:

- [Upstream issue #143](https://github.com/apple/swift-nio-ssh/issues/143)
- [Upstream fix, 7733e7e8](https://github.com/apple/swift-nio-ssh/commit/7733e7e8ffb68eb83fedf35550c29882d8fda404)

Citadel now directly requires Apple/swift-nio-ssh **0.15.0**,
`3ec281496f28a3b6581afd946b759e2642f5cd8d`. Both Citadel and Xcode lockfiles
retain SwiftNIO **2.101.3** and Swift Crypto **3.15.1** to isolate the SSH change.
BigInt is no longer needed. This changes the production dependency, not just
diagnostics.

## Minimal executable reproduction

`Packages/Citadel/Tests/SSHDependencyRegressionTests/SSHChannelCloseRegressionTests.swift`
uses two real encrypted SSH pipelines connected through `EmbeddedChannel`.
It requires no network, device, simulator, timing sleeps, or dependency internals.

1. Open a session child with automatic reads disabled.
2. Fill its actual advertised receive window. The fork and upstream use
   different window sizes, so the fixture observes writability instead of
   assuming a constant.
3. Send local close but hold it on the wire, leaving the child locally closed
   without a peer acknowledgement.
4. Read buffered stdout/stderr. The old dependency tries to replenish the
   receive window after local close and traps. Upstream drains output without
   sending that illegal update.
5. Check byte count, ordered payload hash, stream type and absence of errors.
   An open-channel control must still emit a window update.

The wire pump is bounded; channel creation reports a test failure instead of
waiting indefinitely. Cleanup deliberately closes the parent pipelines without
the withheld peer close acknowledgement. This tests buffered-read/local-close
behavior, not the complete graceful peer-acknowledgement lifecycle.

### Before/after evidence

The same final test source was executed against both dependencies, SHA-256:
`89f03108830cf5135ba81bd47afed6cc832526198f3e7418286cd6809f19b345`.

| Dependency | Open-channel control | Local-close buffered stdout |
| --- | --- | --- |
| Wellz26 0.3.6 | Pass | SIGTRAP / signal 5, exact iPad assertion |
| Apple 0.15.0 | Pass | Pass; buffered stderr also passes |

Local evidence:

- `/tmp/tessera-ssh-final-baseline-control.log`
- `/tmp/tessera-ssh-final-baseline-crash.log`
- `/tmp/tessera-ssh-final-upstream.log` (9 tests, 0 failures)

Run from the repository root:

```sh
swift test --package-path Packages/Citadel
```

The comprehensive programmatic integration runner now executes this package as
`ssh_dependency_and_citadel_adapters`. To reproduce the red baseline in an
isolated checkout, change only the SSH dependency URL/version to Wellz26 0.3.6
and run `--filter SSHChannelCloseRegressionTests.testBufferedStdoutDrainsAfterLocalCloseWithoutWindowAdjust`.
That command is expected to terminate with signal 5; run the control separately.
Do not mix baseline dependency resolution with an active Xcode build.

## Adaptation and compatibility

Tessera's common `SSHConnectionChain` constructs default `SSHClientSettings`.
The custom algorithm registrations were compiled, but not enabled by production
settings. Removed code comprises unused AES128CTR, group14 SHA1/SHA256, custom
RSA signature/key registration and RSA authentication/import helpers. Tessera
already rejects RSA import and authentication. Do not present this vendored
variant as API-compatible with external consumers of those removed APIs.

Password, Ed25519, software P256 and Secure Enclave P256 authentication continue
to use upstream-supported constructors. The application's policy-aware custom
authentication delegates remain unchanged. Encrypted Ed25519 import and
Ed25519 export remain intact. General SSH string writers were moved out of
the deleted algorithm files; the composite writer now grows its length prefix
safely even with a zero-capacity input buffer.

Citadel's server support also used fork-only `NIOSSHHandler.username`. It now
wraps authentication per parent connection, latching the first successful
username **before** forwarding the decision to NIOSSH. Concurrent or late
authentication decisions cannot replace/clear that identity. Child subsystem,
exec, direct-channel and remote-forwarding contexts receive that connection's
identity, never server-global mutable identity. Six adapter tests cover identity
ordering/isolation/late decisions, string encoding and Ed25519 round trips.

The shared connection path serves plain SSH, SSH+tmux, Mosh bootstrap and
Mosh+tmux side channels, Files and port forwarding, on both iPad and iPhone.
There is no device-specific UI or state migration. Production Android uses
SSHJ, not Citadel/NIOSSH; it therefore cannot hit this Swift assertion. The
experimental `CitadelAndroidSmoke` executable is not Android's app transport.

## Native verification

Native app build and affected live/unit lanes passed through
`scripts/integration/`, with run-owned simulators and disposable VPS fixtures.
No physical-device install, profiling, connection or state mutation was part of
this migration verification.

| Gate | Result |
| --- | --- |
| Citadel dependency/adapter package | 9 passed |
| TmuxControl package | 716 passed |
| PortForwarding package | 29 passed |
| Native simulator build-for-testing | Passed, arm64 + x86_64 |
| Fixture contract, tmux 3.4 and 3.6a | Passed on rerun; token-argument correction below |
| RealHostTransportIntegrationTests | 19 passed; 1 opt-in Release performance audit skipped |
| KeyStoreSecurityTests | 58 passed, including encrypted Ed25519 import and RSA rejection |
| AppleSessionCommandFacadeTests | 38 passed |
| SSHAuthenticationPolicyRaceTests | 17 passed (Swift Testing, not the empty XCTest summary) |
| JumpHostTransportIntegrationTests | 8 passed in UDP-blocked pass; 2 intentionally skipped there then passed in UDP-allowed pass |

The live four-transport case recorded:
`TESSERA_IOS_TMUX_ISOLATION_OK ssh=1 sshTmux=1 mosh=1 moshTmux=1 reconnect=1 sideChannelDrop=1 dropped_foreign=0`.
Other live cases verified Ed25519 key installation/authentication, password/TOFU
and mismatch rejection, byte-exact large raw input, EOF tail, Files round trips,
mode/symlink preservation, forwarding and phone/iPad viewport changes.

Native build evidence: `/tmp/tessera-ssh-upstream-native-build2.log`.
Xcode's actual checkout was verified at Apple SSH `3ec281496f28a3b6581afd946b759e2642f5cd8d`.
The repository remains in Swift 5 language mode; Citadel emits Sendable and
deprecation warnings. This change does not claim Swift 6 language-mode readiness.

Native result bundles and JSON summaries are under each of:

- `/tmp/tessera-ssh-upstream-live/programmatic/`
- `/tmp/tessera-ssh-upstream-keys/programmatic/`
- `/tmp/tessera-ssh-upstream-facade/programmatic/`
- `/tmp/tessera-ssh-upstream-auth/programmatic/`
- `scripts/integration/.state/jump/jump-transports.xcresult`
- `scripts/integration/.state/jump/jump-mosh-allowed.xcresult`

The previous jump-transports result was preserved at
`/tmp/tessera-ssh-preserved-previous-jump-20260911.xcresult` before running that lane.
Both run-owned simulator UDIDs (`F6529E12-6926-4E29-B0AC-7F29874747D0` and
`6E8FCEFB-4D67-448A-AD30-6D9024A5E2F8`) were confirmed absent from CoreSimulator
after their cleanup traps completed. Persistent testing simulators were untouched.

### Failure accounting

- The original dependency's signal-5 crash is the expected red regression result.
- While building the fixture, assuming the same window size in both libraries
  made the first control invalid; the final fixture discovers the actual window.
- The small-buffer adapter test exposed the moved writer's old unchecked
  writer-index advance; replacing it with a real UInt32 prefix write fixes growth.
- The first VPS preflight failed with `--token: expected one argument`.
  URL-safe random tokens can start with `-`; an isolated parser check confirms
  `--token=-12345abc` preserves that value. Both the preflight and app transport
  fixture calls now use the equals form. The corrected preflight and all native
  lanes passed. Evidence: `/tmp/tessera-ssh-upstream-fixtures.log` and
  `/tmp/tessera-ssh-upstream-fixtures2.log`.

These are affected transport gates, **not** a full aggregate visual/UI or Android
release-suite run. No scrolling/rendering implementation changed in this migration.

### Rerunning native gates

Use the checked-in integration scripts with a unique
`TESSERA_INTEGRATION_SIMULATOR_RUN_ID` and private
`TESSERA_INTEGRATION_SIMULATOR_STATE_DIR`, retaining the scripts' owned-simulator
cleanup. Build once with `ensure_integration_build` from `scripts/integration/lib.sh`,
then use:

```sh
scripts/integration/verify-fixtures.sh
scripts/integration/run-app-transport-tests.sh RUN_DIR --without-building
scripts/integration/run-app-transport-tests.sh KEY_RUN_DIR TesseraTests/KeyStoreSecurityTests --without-building
scripts/integration/run-app-transport-tests.sh FACADE_RUN_DIR TesseraTests/AppleSessionCommandFacadeTests --without-building
scripts/integration/run-app-transport-tests.sh AUTH_RUN_DIR TesseraTests/SSHAuthenticationPolicyRaceTests --without-building
scripts/integration/jump/run-jump-transport-tests.sh --without-building
```

Secure Enclave hardware signing cannot be exercised by a simulator. Physical
installation and confirmation of on-device behavior remain a user test after
the deterministic crash reproduction and native transport gates pass.
