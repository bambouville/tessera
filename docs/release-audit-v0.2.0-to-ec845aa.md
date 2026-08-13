# Release audit: v0.2.0 to ec845aa

- Date: 2026-08-04
- Baseline: `v0.2.0^{}` = `d041a95acb0d643420d90ecad7f63aae5f7ce568`
- Audited head: `ec845aa492f732de50efd292c743296af1b56742`

Scope: production changes in `v0.2.0^{}..ec845aa`, with focused review of diagnostic volume, diagnostic privacy, periodic/background work, and unfinished user-facing UI.

## Executive summary

No P0/P1 issue was found. The audit found four P2 issues worth fixing before the next public release and two P3 hardening opportunities:

1. A new nearby-bootstrap error log can defeat the exported-log field redactor when peer-controlled text contains an apostrophe or quote.
2. Plain-mosh SwipePad sidecar failures can write routine failure lines to the user-shareable diagnostics file every 1–5 seconds for as long as the visible session remains in that state.
3. Every app foreground activation starts a new, uncoalesced full StoreKit product and entitlement refresh.
4. Nearby Setup retains every accepted connection wrapper until the whole setup service stops, including connections immediately rejected while another handshake is active.
5. New tmux paired-capture tracing pays diagnostic interpolation, queueing, and sanitization cost even when standard diagnostics later discards the trace.
6. Some new exported diagnostics retain non-secret but share-sensitive metadata such as jump-hop ports, session/pane correlation, agent provider, and key-authentication posture.

No new production log directly records a password, passphrase, private-key body, Keychain value, token, terminal output, command text, hostname/IP address, username, remote path, or bootstrap/enrollment payload body. No unfinished or inert user-facing UI was found. The previously added unavailable iCloud-sync panel was removed by `00850f1` before the audited head.

## Severity convention

- **P0/P1:** release blocker; likely critical security, data-loss, or pervasive correctness failure.
- **P2:** moderate release risk; fix before public release unless explicitly accepted with evidence.
- **P3:** low-risk hardening or bounded overhead; fix opportunistically or document acceptance.

## Findings

### P2 — Quoted error fields can escape exported-log redaction

`DiagnosticLogStore` sanitizes `error='...'` and `error="..."` using a non-greedy regular expression in `Tessera/Settings/SettingsPageView.swift:651-655`. The match ends at the first quote of the same kind and does not understand escaping or embedded punctuation.

Post-tag commit `35207952` added a nearby-bootstrap diagnostic at `Tessera/Bootstrap/BootstrapCoordinator.swift:1645-1669` that formats `String(describing: error)` into a single-quoted `error='...'` field. Unknown JSON object keys are copied into `BootstrapManifestError.unknownField` at `Tessera/Bootstrap/BootstrapManifest.swift:934-943`, so a nearby peer controls part of that description. The local helper removes control characters and caps the value at 400 characters, but it does not escape apostrophes or quotes.

For example, a value shaped like `error='unknown x' password=hunter2'` causes the central pattern to redact only `error='unknown x'`; the remaining text survives because `password` is not one of the sanitizer's content-bearing field names. The demonstrated path leaks peer-supplied text, not a locally retrieved device secret, but the same fragile boundary is also applied to opaque framework/localized errors at other new callsites.

**Recommendation:** do not log arbitrary error descriptions at this boundary. Emit a stable enum/error code and error type. If support needs selected detail, structurally escape it or pass it through a dedicated value redactor before message construction. Add adversarial tests covering embedded straight/curly quotes, `password=`, PEM material, paths, and endpoints.

### P2 — Plain-mosh SwipePad probe failures can spam shared diagnostics

The 1-second/5-second SwipePad polling loop predates v0.2.0. The post-tag regression is narrower: commit `fcbb4a58` added a plain-mosh SSH-sidecar process probe at `Tessera/SessionView.swift:3029-3064`, including a standard failure log at lines 3060-3063.

When neither lifecycle nor shell-integration state supplies a process name, each poll connects/executes through the sidecar. A persistent failure emits `provider mosh source=ssh-sidecar failed ...`. Standard diagnostics retains any SwipePad message containing `failed` (`Tessera/Settings/SettingsPageView.swift:613-626`). The loop sleeps five seconds on the fallback profile, or one second while a previously matched custom profile remains selected (`Tessera/SwipePad/SwipePadOverlay.swift:181-203`).

That yields about 12 exported lines per minute indefinitely in the usual failure state, or attempts enough writes to reach the 18-lines-per-signature/minute limiter in the 1-second state. Each accepted line is sanitized and appended through a file open/seek/write/close cycle.

The poll is correctly limited to the selected, foreground session when no lifecycle hook is active, and concurrent refreshes are coalesced. The concern is repeated failure reporting and sidecar retry cost, not an all-session background loop.

**Recommendation:** record the first failure, state transitions, and recovery in standard diagnostics; make identical per-poll failures verbose-only. Add exponential backoff or a failure cooldown to the sidecar probe.

### P2 — Foreground activation starts overlapping full StoreKit scans

Commit `50c4174e` added an every-foreground call at `Tessera/TesseraApp.swift:195-201`. `HostAccessStore.applicationDidBecomeActive()` creates an untracked `Task { await refresh() }` at `Tessera/Purchases/HostAccessStore.swift:114-121`.

`refresh()` always runs both product and access scans. The production path calls `Product.products(for:)`, iterates `Transaction.currentEntitlements`, and awaits `AppTransaction.shared` (`Tessera/Purchases/StoreKitClient.swift:95-121,138-152`). There is no in-flight task guard, debounce, cancellation, or freshness window. Rapid active/inactive churn can overlap StoreKit calls. Revision counters prevent stale state publication but do not prevent duplicate work.

The stated foreground requirement is to recover Ask-to-Buy declines and ownership changes; reloading product metadata for every user on every foreground edge is not necessary for that purpose.

**Recommendation:** coalesce refreshes behind one stored task or actor gate and apply a freshness window. On ordinary foreground activation, refresh access truth only when purchase state is pending or entitlement state is stale. Keep product metadata loading at app start, visible purchase UI, or explicit retry.

### P2 — Nearby Setup retains rejected connections until service teardown

The post-tag nearby-transfer service owns `acceptedConnections` at `Tessera/Bootstrap/NearbyTransferService.swift:205`. Every inbound Bonjour TCP connection is wrapped and appended at lines 314-325. If one handshake is already active, the coordinator rejects and cancels later connections at `Tessera/Bootstrap/BootstrapCoordinator.swift:828-846`, but the service never removes those wrappers individually. The array is cleared only by service-wide `stop()` at `Tessera/Bootstrap/NearbyTransferService.swift:341-352`.

Normal exposure is limited: offering is user-initiated and stops on cancel, background, or failure. However, handshake receives have no deadline. A LAN peer can keep the first handshake stalled and repeatedly connect, growing the retained array and scheduling a MainActor task per connection until the user leaves the flow. Cancelled `NWConnection` objects should release transport resources, so the retained wrapper cost is probably modest, but the count is unbounded.

**Recommendation:** stop or suspend the listener once one handshake begins, enforce a small accepted-connection cap, remove cancelled/terminal wrappers immediately, and add handshake receive deadlines.

### P3 — Routine tmux paired-capture traces are sanitized before being discarded

Commit `45239207` introduced `enqueueControlCommandPair` and routine tracing at `Packages/TmuxControl/Sources/TmuxControl/TmuxController.swift:1636-1692`. The helper is used by settled metadata/capture stages during pane repaint and continuation reconciliation.

`TmuxController.logDiagnostic` eagerly constructs the message whenever the app-installed sink exists (`Packages/TmuxControl/Sources/TmuxControl/TmuxController.swift:7510-7512`). `DiagnosticLogStore.append` then queues the message, runs the shared sanitizer and regular expressions, and only afterward applies the standard tmux filter (`Tessera/Settings/SettingsPageView.swift:327-331,421-428,629-637`). Routine pair/transmit lines are therefore discarded from standard exports only after paying that work. They are render-refresh-bound, not per-byte or timer-driven, so the expected impact is low.

**Recommendation:** separate verbose trace and warning/error sinks before interpolation and queueing. Only send ordinary command-pair traces when verbose diagnostics is enabled.

### P3 — Exported diagnostics retain non-secret privacy metadata

The following post-tag logs do not expose credentials, but they disclose details a user may not expect in a support artifact:

- `Tessera/SSHConnectionChain.swift:178-181` records each SSH/jump-hop port.
- `Tessera/AgentCenter/AgentCenter.swift:2296-2298,2487-2489` and `Tessera/SessionView.swift:1937-1941` record short session identifiers, pane identifiers, and whether the active provider is Codex or Claude.
- `Tessera/Keys/KeysPageView.swift:1629-1645` records the resulting Secure Enclave app-authentication setting.

These details can reveal network topology, usage, and security posture even though the central sanitizer removes endpoints, full UUIDs, commands, paths, environments, and other content-bearing fields.

**Recommendation:** retain only support-relevant classifications: hop count plus standard/nonstandard port, per-log random correlation IDs instead of persistent UUID prefixes, and generic policy-change success unless the resulting posture is required for diagnosis.

## Diagnostic sink and privacy boundary

Production `DiagnosticLogStore` entries are sanitized and written to the app-support `tessera-diagnostics.log`. The user can share that exact file through `ShareLink` at `Tessera/Settings/SettingsPageView.swift:791-813`, or stage it for upload to a selected remote host through `Tessera/ContentView.swift:2170-2178`.

Safe cases verified:

- No new production statement directly interpolates passwords, passphrases, private-key bytes, Keychain values, tokens, terminal output, command text, hostnames/IPs, usernames, remote paths, or bootstrap/enrollment payload bodies.
- New SSH endpoint diagnostics use `endpoint=`, which the central sanitizer redacts. Full UUIDs are replaced with `<uuid>`.
- Terminal-performance diagnostics contain counts and timing only. Collection is gated before work begins and requires verbose diagnostics.
- New nearby SAS/transcript/peer `NSLog` statements and continuity fixture logs are inside `#if DEBUG` harnesses. They do not ship in an App Store release and do not feed `tessera-diagnostics.log`.
- Vendored Citadel SwiftLog statements do not feed `DiagnosticLogStore`; no production `LoggingSystem.bootstrap` was found.

## Periodic and background work reviewed as safe

- SwipePad polling itself existed at the release baseline. Post-tag gating stops it for hidden sessions, backgrounded sessions, and sessions with lifecycle-hook proof; the plain-mosh failure behavior above is the specific new regression.
- The StoreKit `Transaction.updates` listener is event-driven, app-lifetime, duplicate-start guarded, and cancellation-aware.
- `ActivityBroadcaster` is event-driven, equality-gated, and active/unlocked-only.
- Nearby browse/advertise is lazy and user-screen-scoped; cancel, failure, and background stop the service. The retained-connection issue above is limited to an open offering flow.
- Enrollment continuation streams clean up on terminal events and have a five-second forced close after half-close.
- Share-inbox cleanup is event-triggered with one immediate and one 800 ms delayed pass, not a recurring sweep.
- New compact tmux retries are capped and generation/mode guarded. Grid-authority timeouts are one-shot.
- Existing Agent Center 30-second discovery/integration polls predate v0.2.0 and were excluded from release-diff findings.
- The new terminal-performance `CADisplayLink` exists only while verbose diagnostics is enabled and an output burst is active; it flushes after 0.5 seconds idle and bounds an aggregate to 10 seconds.

An initially suspected unbounded tmux foreground-repaint retry was rejected as out of scope after ancestry verification: commit `f8c82034` is already an ancestor of `v0.2.0^{}`.

## UI readiness audit

No unfinished, inert, “coming soon,” or unavailable user-facing surface introduced by this diff remains reachable in the audited head.

- Settings routes added since v0.2.0 are backed by production implementations: Handoff/nearby setup by `ActivityBroadcaster` and `BootstrapCoordinator`, and unlimited hosts by `HostAccessStore`/`LiveStoreKitClient`.
- The prior unavailable/design-ahead iCloud-sync panel was removed by `00850f1`.
- New bootstrap, compact navigation, continuity, purchase, keyboard, tmux, and SwipePad harness screens are guarded by `#if DEBUG` and/or test-only environment routing.
- Intentional iPhone adaptations that direct advanced editing to iPad are product decisions, not inert controls; compact forwarding and host editing retain working, scoped actions.
- The stale “Wave 1 stub” source comment in `TerminalSettingsView.swift` is not user-visible; the view body is fully implemented and wired.

## Release recommendation and verification gaps

Fix the four P2 issues before the public release, then add focused regression coverage for:

1. Adversarial diagnostic error values containing quotes and secret-shaped text.
2. Persistent plain-mosh sidecar failure, asserting one transition log plus bounded retry cadence.
3. Repeated foreground transitions, asserting at most one StoreKit refresh in flight and no unnecessary product reload.
4. Multiple inbound nearby connections during a stalled handshake, asserting a fixed retention limit and cleanup.

This was a static source/diff audit. No on-device profiling or long-duration log-volume run was performed, so the exact CPU, I/O, network, and retained-memory costs remain to be measured after fixes. The stated cadences and unboundedness follow directly from the task loops, scene callbacks, rate-limit policy, and ownership lifecycles in the audited code.
