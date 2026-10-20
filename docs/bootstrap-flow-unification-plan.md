# Bootstrap and continuity flow unification

Status: implemented on `feat/bootstrap-flow-unification`; final validation ledger
and scope limitations are in `qa/unification-regression-20260911/README.md`.
Written: 2026-09-11. Inspection baseline: primary `main`, `6c21dc16`.

Implementation worktree: `.worktrees/bootstrap-flow-unification` (durable,
isolated from ongoing `main` work). The sequence below is retained as the design
record; it is not a claim that every hardware-only check has been completed.

## Objective and boundaries

Give nearby Apple bootstrap and QR bootstrap a consistent native iOS experience,
and share the presentation decisions that should agree between iOS and Android.
Keep SwiftUI and Compose responsible for rendering and platform interaction.

The intended result is one set of reusable iOS setup screens, an equivalent set
of native Android screens, and a small shared presentation contract derived from
the existing protocol state. Do not create a second protocol state machine or
adopt a cross-platform UI framework for this feature.

This plan also closes the outstanding live public-key bootstrap coverage gap.
It does not authorize broad changes to discovery protocols, session transport,
host persistence, or the meaning of existing consent controls.

## Starting point

| Area | Current implementation | Opportunity |
| --- | --- | --- |
| iOS nearby bootstrap | `Tessera/Bootstrap/BootstrapFlowView.swift`, `BootstrapCoordinator.swift` | Retain discovery and coordinator; compose shared screens |
| iOS QR setup/continuation | `Tessera/Pairing/CrossDevicePairingView.swift`, `CrossDevicePairingCoordinator.swift` | Remove duplicated verification, layout, review, and receipt presentation |
| Existing shared iOS controls | `Tessera/Bootstrap/BootstrapGrantSelectionViews.swift` | Extend existing host/data/key controls rather than replace them |
| Android QR flow | `android/feature-pairing/.../PairingScreen.kt`, `CrossDevicePairingCoordinator.kt` | Split native screen components; replace duplicated decisions with shared projection |
| Shared protocol/runtime | `Packages/TesseraCore/Sources/TesseraCrossDeviceCore/`, `TesseraBootstrapCore/`, `TesseraContinuityCore/` | Reuse authoritative state, policy, and outcome types |
| iOS continuation | `Tessera/Continuity/`, integration in `Tessera/ContentView.swift` | Preserve existing receive coordinator, overlay, and receipt callbacks |

Known differences that must be represented deliberately:

- Nearby copies all eligible manifest hosts; its checkboxes select recipient
  public-key grants. QR checkboxes select hosts to copy, with required routes
  included. `BootstrapHostSelectionMode.grants` and `.copy` already express this
  distinction. Do not change it silently during extraction.
- Nearby has a richer receipt: import counts, preserved trust conflicts,
  per-host explanations, and a `configure later` action. QR's receipt is simpler.
- QR has scan/manual-entry/expiry states and several purposes, including
  continuation without setup. Nearby has discovery, compatibility hints, and
  peer-rejection acknowledgement states. These are not interchangeable.
- Android currently has presentation states containing free-form strings
  (`Working`, `Completed`, `Failed`) and its own progress-stage mapping. iOS
  also maps stages and receipt statuses locally.

Previous evidence is under `qa/qr-final-20260910/` and the preceding QR QA
folders; these are local artifacts, not committed dependencies of this plan.
The recorded live handoff used password authentication. Pairing adapter tests
substituted the remote grant installer; separate networking tests exercised
real generated-key authentication. That is not proof of the complete QR
public-key enrollment path. Earlier broad transport tests passed, with one
intermittent mosh history/reconnect failure documented before two final passes.

## Intended ownership

| Layer | Owns | Must not own |
| --- | --- | --- |
| Existing protocol engines | Handshake, authenticated manifests, ordering, acceptance, receipts, expiry and transaction rules | Native layout or UI navigation |
| Shared presentation projection | Semantic stages, status/reason codes, action availability, selection summaries, receipt meaning | Keys/passwords, sockets, timers, persistence, approval or connection side effects |
| Platform adapters/coordinators | Native service integration, operation facts, dispatch of validated actions into existing engines | Reimplementation of shared policy |
| Shared iOS components / native Android components | Screens, formatting, accessibility, layout and animation | Inferring authorization or successful remote access from display state |

Implement the projection as pure, deterministic code next to the existing
cross-device core where its dependencies permit. Use the existing C ABI and
Android bindings for Android access. Exact type/file names are provisional;
audit existing exported types before adding another target or abstraction.

Projection inputs should contain existing runtime facts plus the minimum
platform facts needed to describe an operation: flow purpose, source/recipient
role, entry method, current phase, selection, per-host outcomes, pending local
authentication, and supported actions. Keep nearby-specific mappings thin.

Projection outputs should contain typed data, not rendered views:

- A purpose-aware ordered stage list and current stage. Continuation-only must
  not advertise a host-selection step that will never occur.
- Semantic screen/status identifiers and structured formatting arguments.
  Localized text and pluralization stay in platform catalogs; never use a
  rendered message as a state discriminator.
- Action identifiers and availability reasons. The protocol/coordinator must
  still revalidate an action when invoked; an enabled button is not authority.
- Separate copied-host and grant-host summaries, route dependencies, and
  optional-data selection. Reuse existing selection/validation policies.
- Per-host receipt meaning, distinguishing copied configuration, installed or
  already-installed access, local password needed, skipped/failed/uncertain
  access, declined import, and preserved trust conflicts where facts exist.
- Recovery capabilities backed by real native handlers. Missing information
  remains unknown; do not infer success or invent unsupported recovery actions.

Keep protocol attempt IDs/generations in the adapter boundary so stale native
callbacks cannot advance a new flow. View-local choices such as an expanded
manual-entry field or the current review tab remain local and reset on a new
attempt. There is no new persistent presentation state in this first pass.

## iOS unification

Compose both existing flow entry points from reusable components:

1. A setup presentation shell: width constraints, title, close action, content
   scrolling, keyboard accommodation, and transition policy.
2. Code verification: shared six-digit display, match/reject actions, and
   waiting-for-peer presentation that retains the code.
3. Selection/review: reuse the existing host, optional-data, and recipient-key
   components inside common Hosts / Include / Review navigation. Labels and
   enabled states must reflect copy versus grant selection explicitly.
4. Progress and failure surfaces: shared styling with operation-specific
   meaning and coordinator-supplied actions. Preserve rejection acknowledgement.
5. Completion and host-access rows: shared status formatting, explanations,
   conflict summaries, and recovery buttons. Expose richer nearby information
   in QR only where its authenticated receipts/import results support it.

Use value inputs and closures; shared views should not require one concrete
coordinator type or accumulate `if QR` branches. Remove duplicate private
card/title/code helpers after both callers migrate.

Preserve Bonjour discovery and QR scan/manual-entry as separate entry screens.
Keep camera lifecycle, permission prompts, and biometric authentication native.
Keep QR's handoff into the existing continuation coordinator and its exact
durable-acceptance/rendered-connection callbacks.

## Android and cross-platform reuse

After the iOS extraction identifies stable screen inputs, move genuinely
duplicated policy/mapping into the shared projection and bind both iOS callers
and Android to it. Avoid maintaining an interim Swift-only policy layer once
the shared implementation is adopted.

Compose screens should consume the same semantic outcomes while using Android
design tokens and native controls. Extract verification, review, progress,
receipt, and error components from `PairingScreen.kt`; keep CameraX, lifecycle,
IME handling, Android Keystore, and biometric UI in platform adapters.

Do not share fonts, view trees, pixel geometry, gesture recognition, or animation
timelines across operating systems. Do not add Android Bonjour support or
rewrite Apple Handoff as part of this unification. Continue to reuse existing
shared continuation transactions and platform session controllers.

## Behavior to preserve

- Consent remains bound to the exact authenticated recipient and reviewed
  manifest; required jump routes cannot disappear between review and approval.
- Optional sensitive host data starts off. Import preserves existing local
  text and trust conflicts according to current policy.
- Private keys and passwords remain local. A fresh recipient creates its own
  key; reuse of an existing device key follows established policy. Key-use
  authentication preferences and actual hardware-protection claims stay honest.
- A copied host is not reported authorized until its grant has been verified
  and durably recorded. Password-on-first-connect remains distinct from failure.
- Mismatch, cancellation, expiry, backgrounding, locking, and retry preserve
  existing fences. A partially installed remote grant must not be hidden by
  generic cancellation/completion wording.
- Continuation delivery is exactly once; unrelated Apple Handoff callbacks
  cannot complete a QR attempt. The sender remains available until the proper
  connection receipt, and takeover cannot re-arm after a later peer takeover.
- Handle SSH, SSH+tmux, mosh, and mosh+tmux through the common existing session
  path. Same-shell continuity assertions apply to retained tmux sessions;
  preserve and state existing raw SSH/mosh continuation semantics separately.
- iPhone receives full functional parity through compact, scrollable screens,
  reachable touch actions, and software-keyboard avoidance. Validate large text,
  VoiceOver/TalkBack, contrast, and reduced motion. iPad/tablet evidence is in
  landscape; no hardware keyboard is required to complete setup.

## Implementation sequence and checkpoints

### 1. Establish the baseline and close the key-enrollment evidence gap

Re-anchor branch/HEAD and overlapping changes before editing; `main` has been
moving and had unrelated dirty tmux files when this plan was written. Read the
current app instructions and confirm fixture ownership/configuration.

Capture current QR and nearby verification/consent/receipt behavior. Add a live
test using a fresh recipient and a sender that already has key-based access to
the provisioned fixture. Exercise QR scan, matching code, selection, approval,
recipient-key generation, sender installation, verified access, and recipient
connection with its own key. Record public fingerprints and scoped authorized
key presence; never extract private key material. Password fallback must not
satisfy this test. Reproduce and fix any failure before layering on UI extraction.

Checkpoint: reproducible baseline cases and a real key-based bootstrap proof,
with raw captures and exact cleanup ownership.

### 2. Reuse complete iOS presentation components

Extract the shell and common verification/selection/progress/receipt surfaces,
then migrate both `BootstrapFlowView` and `CrossDevicePairingView`. Preserve
distinct entry and consent semantics. Extend existing harnesses to cover both
callers; retain stable accessibility IDs or deliberately update their tests.

Checkpoint: both iOS flows are usable end to end on disposable iPad and iPhone
simulators, with before/after capture showing consistent styling and no loss of
nearby receipt detail or recovery actions.

### 3. Share presentation decisions across platforms

Introduce the minimal pure projection and additive ABI bindings. Map existing
engine facts rather than duplicating handshake logic. Add shared fixtures for
stage/action/selection/receipt output, then adopt them in iOS and Compose.
Replace local string-based phase decisions and redundant mappings as callers
migrate. Add localization entries through the established catalog workflow.

Checkpoint: iOS and Android agree on semantic stages, allowed actions, consent
summaries, and outcomes for the same fixtures; each renders native controls.

### 4. Validate integrated flows and remove obsolete presentation code

Run the matrix below, review all visual cases together, resolve verified
findings, and remove superseded helpers/mappings. Do not stop at an internal
refactor that cannot be exercised through the app UI.

Checkpoint: human-testable flows, passing affected integration gates, edited
two-device evidence, and a durable report that distinguishes live tests,
injected harness cases, simulator limitations, and any unresolved failures.

## Validation matrix

| Coverage | Required evidence |
| --- | --- |
| Shared semantic contract | Stage/action mappings for every purpose and role; copy/grant distinction; route closure; truthful partial receipts; stale callback and retry cases |
| Cross-language binding | Same fixtures through Swift and Android ABI; invalid/unknown values fail safely; existing protocol compatibility tests remain green |
| iOS native surfaces | Bonjour and QR on iPad landscape and compact iPhone; code comparison/wait, selection, review, partial results, recovery, cancellation and keyboard states |
| Android native surfaces | Phone and tablet; matching scenarios, CameraX/manual fallback, back/cancel, IME, accessible actions, receipt/recovery states |
| Real key bootstrap | iOS → Android and Android → iOS QR, plus iOS → iOS nearby using existing coverage; fresh recipient key, approved remote installation, authentication with recipient key |
| Consent and partial outcomes | Multiple hosts including an excluded host, required jump host, password host, existing key, and rejected/failed grant; per-host receipt matches actual effects |
| Continuation | Setup-and-continue and continuation-only; live attachment/control and receipt gating; affected cases across all four session transports |
| Lifecycle/failure | Code mismatch, expiry, disconnect, retry, cancel during import/grant, lock/background, duplicate receipt, and conflicting concurrent continuation |

Extend affected lanes under `scripts/integration/` and the Android native gate;
run required aggregate visual review with all captured cases while programmatic
checks execute. For this multi-file/lifecycle work, use the required adversarial
review and verify each finding before changing code. Add focused meaningful
tests for newly shared decisions, not tests that merely mirror view structure.

The complete key-bootstrap proof is a release gate for this work. Separate
generated-key and mock-grant tests cannot substitute for it. For simulator
camera tests, disclose pixel-fed CameraX/decoder coverage; physical optics and
hardware-backed key/biometric behavior remain explicitly separate hardware
checks. If a failure recurs, preserve its diagnostics and account for it even
if a retry passes.

## Evidence, cleanup, and handoff

Use uniquely named, run-owned simulators/emulators and disposable VPS fixtures.
Track exact device IDs, remote sessions, and public keys installed by each run.
Install cleanup traps before mutation and delete every disposable simulator
after the run, including failures. Remove only test-created authorized-key
entries and remote sessions; never reset persistent user devices.

The existing conversation authorized connections, trust, and transfers for the
provisioned test fixture. Preserve that authorization within its scope; verify
the current target and device ownership when implementation resumes. Do not
treat this plan as permission to connect to personal hosts or install physical
device builds.

Deliver edited combined-device videos showing the key-based bootstrap and
continuation flows, plus comparison evidence for nearby/QR iOS surfaces. Keep
source captures, disclose cuts or speed changes, and do not imply edited clips
measure protocol latency. Include readable receipt/status close-ups.

The handoff report must name the tested commit, commands/results, flow coverage,
remaining hardware checks, known failures, and verified cleanup. Commit source,
tests, bindings, and reusable tooling according to the authorization in effect
when implementation begins; curate evidence deliberately instead of staging
raw multi-gigabyte result bundles. This planning task creates only this document.
