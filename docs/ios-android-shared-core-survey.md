# iOS ↔ Android shared-core survey — remaining high-value areas

Date: 2026-09-01, `main` @ `7eee832`. Survey inputs: full shared-core/ABI inventory, Android
Kotlin duplication map, iOS unshared-logic inventory (three parallel Opus surveys), plus a
root-cause classification of every fix commit since Android work began (2026-08-24).
Every file/symbol claim below names its location so it can be re-verified in the tree; the three
highest-leverage claims (Shift+Tab drift, the dangling TrustCore/DomainCore ABI deps, the
64-vs-59 header drift incl. all five missing `tessera_tmux_runtime_*` prototypes) were
independently re-verified against `main` before publication.

## Why this matters, in the repo's own words

- `fe0c104`: "Three Android reports from one diagnostics log, all three the same shape as the
  last round: **policy that only exists inside the Apple-only target, re-derived differently on
  the other side of the bridge**."
- `9625b04`: "**every policy left in the Apple half is invisible to Android and gets written a
  second time**."

Roughly **20 of ~35 fix commits in the Android era trace to duplicated/re-derived policy**.
Each time an area was actually moved into the shared core, its fix streak stopped:
`e9f925c` (tmux authority lifecycle), `9625b04` (compact geometry + auto-tmux commands),
`f826984` (agent session-integration policy). The pattern that works is proven: portable policy
in Swift core → C ABI → thin Kotlin adapter (the tmux, pairing-crypto, and agent-reducer stacks
are the model; `CanonicalCrossDeviceJson.kt`'s "retain validated raw JSON rather than decode and
reimplement" comment is the cleanest statement of the discipline).

## The structural reason drift stays invisible

All 23+ duplicated areas below are pinned by **Kotlin-only unit tests**, so drift stays green in
CI. Spot-checked proof: `AccessoryKeySequenceEncoderTest` has a case literally named "match
shared iOS encoder" but never tests Tab (so the missing Shift+Tab backtab passes);
`HostDraftValidatorTest` pins Android's own charset, not `TmuxSessionName`'s.
`KotlinConformance` + `ProtocolVectors` is the only real cross-language gate and covers
pairing/bootstrap/enrollment/continuation/tmux-topology — none of the drifted areas below except
the public-key descriptor. Notably, `ProtocolVectors/input/v1/terminal-input.json` **exists** and
is read by Swift only; the Kotlin conformance runner never opens it.

---

# Bucket A — duplicated today, drift confirmed (highest urgency)

Ranked by demonstrated bug cost × security relevance × extraction cheapness.

## A1. Terminal input encoding — expose `TesseraInputCore` through the ABI
- **Already in shared core, zero ABI.** `TerminalKeySequenceEncoder`, `TerminalModifiers`
  ("Command never reaches the wire"), `TerminalSoftwareModifierEncoder` (shift-punctuation +
  control tables), `TerminalMouseEncoding` (208 lines of SGR). Not even a dependency of
  `TesseraCoreABI`.
- **Kotlin twin:** `AccessoryKeySequenceEncoder.kt` — its own KDoc calls itself the "Android peer
  of TesseraInputCore's TerminalKeySequenceEncoder".
- **Confirmed drift:** Shift+Tab sends `0x09` on Android instead of backtab `ESC [ Z`. The whole
  software-modifier path (one-shot Ctrl over typed keys, `Ctrl+Space`, `Ctrl+?`) has **no Kotlin
  equivalent at all**; SGR mouse encoding has none either.
- **Work:** `@_cdecl` façade (a few functions), wire `input/v1` vectors into KotlinConformance,
  delete the Kotlin encoder. Terminal key bytes are the one thing a terminal app cannot get
  subtly wrong.

## A2. Session lifecycle policy cluster — restore cohort, reconnect/exit rules, resize coalescer
- **Restore cohort:** `ForegroundRestoreContinuity.kt` (~200 LOC) is a line-for-line port of
  `SessionRestoreCohort.swift`. Every rule is a crystallised bug fix (the 4 ms two-transport
  race, mosh staying `.connected` across network loss, the app-lock persist hole) — and review
  round `c2b02c9`'s fixes landed **Swift-side only**. Pure logic; seconds→ms is the only adaptation.
- **Reconnect eligibility + remote-exit classification:** the load-bearing invariant "socket EOF
  alone is not a remote exit" lives in three places, and the transient-error string tables differ
  between platforms. `0f93fa7` (close button didn't end the session) was exactly this class:
  re-derived end-state semantics. Natural home: a `retryDecision` command on the **existing**
  `SessionEngine` ABI — no new façade needed.
- **Resize coalescer:** confirmed drift — iOS sends the first size immediately (`.send`, "the
  session cannot start without it"), Kotlin schedules it; settle window 120 ms vs 80 ms; iOS's
  stale-timer guard has no Kotlin equivalent.

## A3. Host-key trust + known_hosts — give `TesseraTrustCore` an ABI, converge the codec
- **Three-way duplication, security-critical.** `TesseraTrustCore` is declared as a dependency of
  `TesseraCoreABI` **but no ABI source imports it** (a dangling dep that makes it look shared).
  Android reimplements trust with a different verdict vocabulary
  (`Unknown/Trusted/Changed/Reverted` vs core's three-outcome `KnownHostCheckResult`); iOS's own
  `KnownHostsStore` partially bypasses TrustCore with a second OpenSSH codec.
- **Confirmed Android defects:** export emits `host:22 …` — **not valid OpenSSH** and doesn't
  round-trip into iOS or `ssh(1)` for port 22; import can't handle comma host lists (trusts a
  bogus endpoint literally named `h1,h2,1.2.3.4`), ignores `@cert-authority`/`@revoked`/hashed
  hosts, and calls `trust()` in a loop with no plan/transaction so a malformed line leaves the
  store **partially mutated**. iOS builds a reviewable `importPlan` and applies on confirmation.
  Endpoint canonicalisation also differs, so a transferred trust record may not be recognised.
- **Product decision needed first:** does `Reverted` exist as a verdict (Android's idea is
  arguably better), and which endpoint canonical form wins. Then: ABI for policy + codec,
  fingerprint formatter (currently written three times), and the import-plan layer.

## A4. tmux session-name validation + agent branch validation — one-function fixes
- `TmuxSessionName` lives in `TmuxControlCore` — the package that **already has** `tessera_tmux_*`
  exports — yet Android hand-writes the charset **three times** with confirmed divergence:
  allows `:`, Unicode-aware `isLetterOrDigit()`, 100 chars vs 256 UTF-8 bytes. A pinned target
  authored on Android can fail `ContinuationDescriptorV1` validation on iOS → **cross-device
  continuation fails with no Android-side warning**. One `@_cdecl` closes it.
- Same shape in Agent Center: `validBranch` in `AgentCenterPresenter.kt` duplicates
  `AgentLaunchValidator.validBranch` which **already runs behind the ABI on the same launch
  path** — Unicode/UTF-16 drift means `café-fix` passes the Kotlin pre-check then dies in core as
  an opaque `invalidLaunch`. Fix is deletion (or call-through), not extraction.

## A5. Mosh bootstrap grammar + sensitive-data redaction
- `MoshBootstrap.kt` re-parses `MOSH CONNECT` **more leniently** than iOS (whitespace-split vs
  literal single-space prefix) — Android accepts banners iOS rejects. iOS carries
  `detectedOSHint`, path assessment, jump-hop count, preserved tmux geometry off the same hop;
  Android carries none, so future rules land one-platform.
- **Privacy gap today:** `SensitiveDataRedactor` (scrubs `MOSH CONNECT` lines and bare 22-char
  session keys from diagnostics) exists **only in Swift**. Android's diagnostic scrubber misses
  mosh keys entirely. Pure string logic; the UDP driver and SSH ride stay native.

## A6. Cross-device canonical strings — QR text codec, route identity, the hand-written canonical JSON
- Demonstrated HIGH failure already shipped: `456f32c` #1 — Kotlin hand-encoded lowercase UUIDs
  vs Swift's canonical uppercase, so **no Android-origin QR transfer could ever complete**.
- `PairingQRTextCodecV1` (canonical round-trip + strict base64url alphabet) is in shared core
  with no ABI; Kotlin's copy does neither check — a protocol-strictness asymmetry on a
  security-relevant input. Route identity/fingerprint derivation is re-derived in Kotlin;
  `CanonicalCrossDeviceJson.kt` reproduces Swift `JSONEncoder(.sortedKeys)` byte-for-byte by hand.
- **Consider the stronger fix:** typed ABI entry points (or core-side encoding of the whole
  command) so the Kotlin canonical-JSON writer ceases to exist. Also relevant to the six
  pairing/receipt fixes (`06389be`…`7eee832`): receipt/consent semantics re-implemented per
  platform above a shared ABI kept producing "claims it never earned" bugs.

## A7. Port-forwarding model — reconcile three incompatible models (lift from Android)
- iOS app package (local-only, `localPort >= 1024`, JSON codec) vs `TesseraDomainCore`
  (local/remote, no ABI) vs Android (LOCAL/REMOTE/DYNAMIC, bind/target endpoints, loopback
  policy, pipe+base64url codec). Android's model is the **superset** — the shared model should be
  lifted from Android into `TesseraDomainCore`, and iOS migrated onto it. Android's own comment
  already flags it: "dynamic rules stay Android-local until that contract grows a dynamic
  direction". Design/reconciliation work more than code motion.

## A8. Smaller confirmed-drift items (cheap, mechanical)
- **Remote cwd probe + selection path resolver:** pure command strings; Android is missing iOS's
  third discovery mode (`.tmuxSession` with the tmux-3.6a bare-target and Homebrew-PATH quirks —
  the exact class of bug as `a7aaaeb`); `RemoteSelectionPathResolver.kt` is a line-for-line fork.
- **Agent lifecycle OSC scanner:** producer is in shared core, the six-state consumer is
  transcribed twice (including the curly-quote 0x9D and skip-cap rules).
- **authorized_keys install/verify:** marker protocols and `&&` vs `;` chaining diverge; iOS has
  a revocation path Android lacks entirely.
- **Diagnostic redaction tables:** different scrub sets (Android: no endpoint scrub, no mosh-key
  scrub); the privacy boundary for user-submitted logs should be one authoritative list.
- **Settings defaults:** `agentCenterNotificationsEnabled` defaults **true on iOS, false on
  Android** — same user-facing setting, opposite out-of-box behaviour. Scrollback clamps differ.
- **Theme palettes:** six themes × 19 hex values hand-copied (currently exact, nothing checks);
  theme-id list repeated in three Kotlin files.
- **Agent capability bitmask + notification-token grammar + Tier-C ceilings:** magic numbers
  decoupled from the Swift enums that define them; a Swift-side reorder is a silent capability
  escalation on Android.

# Bucket B — not yet built on Android: share-first, before divergence exists

The gaps-doc roadmap items. The win is building each **once in core** rather than letting
Android re-derive it the way it re-derived tmux policy in week one.

1. **SwipePad model** — the largest pure block with zero Kotlin counterpart: macro grammar
   (`MacroEncoder`), `regex:` process matcher (exists because Claude Code renames its process
   title every release), `AgentDetectionRules` prompt grammar, ps-output parsers, petal geometry.
2. **HW-keyboard shortcut catalog** — `ShortcutAction` registry + availability gates +
   34-line fail-closed `ShortcutScopeEvaluator`; the never-retry-this-chord scar tissue travels
   as design intent even where chords differ (Android tablet/Chromebook follow-up).
3. **Accessory sticky modifiers + notation** — half already forked (Android hand-copied the chip
   catalog with its own persisted IDs and codec); the sticky/notation delta is a named roadmap item.
4. **Keys ledger + install/verify/revoke script grammar** — the awk authorized_keys matcher, the
   `KeySecurityRecord` verification-state ledger ("a half-completed install must not claim a
   verified outcome" — same discipline as `7eee832`); Android has already started an independent
   partial version.
5. **Per-host terminal background resolution** — small pure three-tier policy whose two silent
   fallbacks are exactly what a second implementation gets wrong.
6. **Multi-session registry** — MRU + the "connected ≠ render-ready" invariant; Android needs it
   the moment it allows a second session per host.
7. **OS detection + WSL/Tailscale MTU classifier** — fully pure, absent on Android, productized
   support diagnosis.
8. **Play Billing (later):** adapt onto `ContinuationAdmissionPolicy` exactly as iOS does —
   the admission policy is already in core; `android/billing` is an empty module today.

# Bucket C — hygiene of the sharing mechanism itself

1. **Conformance-gate expansion** — for anything not extracted this round, add vectors +
   KotlinConformance coverage (input encoding first: the vector already exists and is unwired).
   Would have caught the Shift+Tab, session-name, resize, and preference-default drifts already
   in the tree.
2. **ABI header drift** — `TesseraCoreABI.h` declares 59 of 64 exported functions (five
   `tessera_tmux_runtime_*` missing); nothing checks it because Android `dlsym`s without the
   header. A trivial generated check (`grep @_cdecl` vs header) closes it.
3. **Dangling deps + dead weight** — `TesseraCoreABI` declares `TesseraTrustCore`/
   `TesseraDomainCore` deps no source imports (makes them look shared); iOS links ~1,660 lines of
   ABI it never calls via the umbrella's `@_exported import`; Android ships
   `LegacyNearbyHandshakeV2` (1,375 lines) with zero Kotlin references.
4. **`AutoTmuxScript.swift` (301 lines, pure strings)** sits in the iOS-only `TmuxControl`
   wrapper, not `TmuxControlCore` — the `$SHELL -c` login-shell bug (`a7aaaeb`) bit Android
   precisely because the launch script wasn't shared. Move it down.
5. **`docs/android-product-gaps.md` is stale** — Agent Center row says "not implemented on
   Android" while ~5.3k LOC across two modules shipped 08-30/31.

# Bucket D — legitimately platform-native (surveyed, excluded)

SSHJ/Citadel transport wiring, mosh UDP driver + JNI, Compose/SwiftUI UI, IME handling
(`add57c3`), Compose view lifecycle (`2b5fab9`), Room/SwiftData persistence schemas
(the domain *types above* them are Bucket A), Keystore/Secure Enclave/biometrics, notification
plumbing, bell audio, Gradle/packaging, find-in-terminal emulator matching, Handoff
(`TesseraAppleContinuity` — correctly quarantined), macOS bridge (`TesseraBridgeCore`).
SSH **error classification** is a convergence target (agree the reason taxonomy), not a
lift-and-shift — it is welded to Citadel/NIOSSH vs SSHJ error types and Android's works.

---

# Suggested confirmation shape

- **Wave 1 (confirmed drift, cheap, high blast radius):** A1 input encoding · A4 session-name +
  validBranch · A2 lifecycle cluster · A5 mosh grammar/redactor · A8 cwd-probe/path-resolver.
- **Wave 2 (needs a small design/product decision first):** A3 trust/known_hosts · A6 canonical
  strings/typed ABI · A7 forwarding model (lift from Android).
- **Wave 3 (share-first roadmap builds):** B1–B7 in whatever order the product roadmap dictates.
- **Continuous:** C1 conformance vectors for everything not yet moved; C2–C4 hygiene as a small
  standalone pass.
