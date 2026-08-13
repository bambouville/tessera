# Paid app to free + Unlimited Hosts IAP

Status: Swift implementation exists on branch `feat/iap-unlimited-hosts`
(worktree `.worktrees/iap-unlimited-hosts`; 4 commits, full unit suite green).
No App Store Connect state has been changed; the release checklist below and
the `freeModelFirstBuild` confirmation remain release-time steps.

Companion mock: `index.html`.

## Product contract

Tessera becomes free on iPhone and iPad. The free app keeps the complete product
surface — SSH, SSH+tmux, mosh, mosh+tmux, Files, keys, port forwarding, keyboard
and touch controls, sync/continuity, and security — but remembers one host.

A single **non-consumable** In-App Purchase unlocks unlimited saved hosts:

- Reference name: `Unlimited Saved Hosts`
- Product ID: `com.bambouville.TesseraApp.unlimited-hosts`
- Type: non-consumable
- Display name: `Unlimited Saved Hosts`
- Description: `Save and manage as many hosts as you need.`
- Price: business decision; the mock's `$14.99` is illustrative only
- Subscription: none
- Account/backend: none

Production UI must render `Product.displayName`, `Product.description`, and
`Product.displayPrice`; it must never ship a hard-coded price or currency.

## Existing paid customers are grandfathered

Customers who originally downloaded the paid app get unlimited hosts without
buying the IAP. This is an entitlement, not a local migration flag.

At the free-model release, increment `CFBundleVersion` and freeze that exact
build number as `freeModelFirstBuild`. On iOS/iPadOS, verify
`AppTransaction.shared` and compare `originalAppVersion` with that cutoff:

```
legacyPaid = verifiedAppTransaction.originalBuild < freeModelFirstBuild
unlimited = legacyPaid || verifiedUnlimitedHostsTransaction
```

`originalAppVersion` is the original `CFBundleVersion` on iOS, not
`CFBundleShortVersionString`. Compare numeric components, not raw strings. The
repository currently says marketing version `0.2.0`, build `1`; the release
must use the actual App Store build sequence and must not reuse the paid build
number for the first free binary.

This preserves the purchase across updates, reinstall, and the customer's
iPhone/iPad without Tessera accounts or a server. The settings UI should name
the source honestly:

- `included with your original Tessera purchase`
- `unlimited hosts purchased`
- `free · 1 saved host`

Existing saved hosts are never hidden, deleted, or made unlaunchable while an
entitlement check is loading or unavailable.

## One product decision before implementation

The literal one-host rule counts each `PersistedHost` row. That means a saved
destination plus a separately saved jump host uses two slots. This is the
simplest and clearest quota, but it means a multi-host ProxyJump route requires
the unlock.

If “all features free” must include a multi-hop route for the one free
destination, count logical destination profiles and include their jump-host
dependency closure for free. That requires a larger change: an atomic “add jump
host to this route” flow, graph-aware quota accounting, deletion semantics, and
bootstrap/Handoff dependency selection. Do not improvise this during coding;
confirm which rule owns before implementation. The mock uses the literal
one-`PersistedHost` rule.

## UX contract

### Entry points

1. `new host`, the global `Command-N`, and the sidebar add action all call the
   same admission check before inserting a blank SwiftData draft.
2. If a free customer already has one saved host, present the Unlimited Hosts
   sheet. No extra `PersistedHost` is inserted before purchase succeeds.
3. Add an `unlimited hosts` Settings section so purchase, status, retry, and
   restore remain discoverable without first hitting the limit.
4. Quick Connect remains ephemeral and never consumes a saved-host slot.
5. Editing, launching, deleting, exporting, or using an already saved host is
   never gated.

### Prompt frequency and suppression

Existing paid customers and customers who own the IAP receive **no promotional
banner, toast, badge, confirmation, or purchase prompt**. Their add-host action
continues directly into the editor.

For a free customer:

1. Never present an offer on launch, foreground, connection, session count,
   elapsed time, update, or a timer.
2. The full explainer may appear only on the first explicit action that would
   save a host beyond the free limit.
3. If the customer dismisses it, persist a local, non-authoritative
   `hasSeenUnlimitedHostsOffer` presentation preference. It is not entitlement
   state and must never affect access decisions.
4. Later over-limit add attempts show only a compact factual limit notice:
   `Free Tessera remembers one host.` Its actions are `view unlimited hosts`
   and `cancel`/`manage saved host`; it does not start a purchase.
5. The full purchase sheet appears again only after the customer explicitly
   taps `view unlimited hosts` in that notice or opens Settings → Unlimited
   Hosts and taps the purchase action.
6. There is no day/week cooldown because there is no automatic resurfacing.
   The compact notice appears only as direct feedback to a blocked save action.

This means at most one automatically presented full explainer per device. A
customer can always reach the offer deliberately from Settings. Nearby setup
and Handoff use the same rule: after the first explainer, show a neutral
capacity decision before any persistence rather than reopening a paywall.

### Purchase sheet

- Headline: `save every host`
- Plain statement: every Tessera feature is free; the purchase changes only
  how many hosts the app remembers.
- Show current localized product name and price.
- Primary action: `unlock unlimited hosts · <localized price>`
- Secondary actions: `restore purchases` and `not now`
- Reassurance: one-time purchase, no subscription, no Tessera account.
- Name cross-device behavior: available on the customer's iPhone and iPad
  through the App Store.

Do not use countdowns, “best value,” fake discounts, repeated prompts, or a
startup paywall. Never add an upgrade banner to Hosts or Settings. The purchase
sheet appears only under the frequency policy above.

### States

- `checking`: wait for App Store product and entitlement truth; do not assume
  free while state is unknown.
- `free`: one saved host; primary purchase action is enabled.
- `purchasing`: one in-flight action, controls disabled, system sheet owns
  confirmation.
- `pending`: keep the app usable and explain that approval is pending; resolve
  later through `Transaction.updates`.
- `purchased`: dismiss an add-triggered sheet and continue the original add
  action exactly once with no success banner/toast. In Settings, show the
  purchased status instead.
- `legacyPaid`: no sale UI or status banner on Hosts; add-host proceeds normally.
  The Settings detail may state that unlimited hosts were included with the
  original purchase.
- `cancelled`: dismiss system progress without an error toast.
- `unavailable/error`: keep existing hosts usable, show a compact retry, and
  retain `restore purchases`.
- `revoked/refunded`: remove only the unlimited entitlement. Never delete or
  hide saved hosts; prevent additional saves while above the free limit and
  explain the state.

### iPhone

Use a compact full-height sheet/page with one column and at least 44-point
targets. Software-keyboard occlusion is irrelevant because the purchase sheet
contains no text fields. After purchase, dismiss back into the host editor so
the user does not have to tap `new host` again.

### iPad

Use a centered sheet over the Hosts page and a normal Settings detail page.
Validate in landscape. Keep the existing flat, dark/frosted, hairline-border
visual language; the system App Store confirmation sheet remains system-owned.

## Architecture

### `HostAccessStore`

Add one app-lifetime `@MainActor @Observable` store, constructed in
`TesseraApp.init` and injected through `RootView` like the other controllers.
It owns:

- loaded `Product`
- verified `AppTransaction` migration entitlement
- verified non-consumable entitlement
- transaction update task
- purchase/restore state and user-facing errors
- a single deferred post-purchase action token

It does not own host data and does not persist entitlement truth in SwiftData or
UserDefaults.

### StoreKit boundary

Put StoreKit calls behind a small protocol so policy/state tests do not depend
on the live App Store:

- `Product.products(for:)` loads the one product
- verified `AppTransaction.shared` grants the paid-app legacy entitlement
- `Transaction.currentEntitlements` finds the non-consumable purchase
- `Transaction.updates` handles purchases completed elsewhere, Ask to Buy,
  refunds, and revocations
- SwiftUI's `PurchaseAction` starts the purchase
- `AppStore.sync()` runs only after an explicit `restore purchases` tap because
  it can prompt for App Store authentication
- successful verified transactions are applied, then finished
- unverified transactions never grant access

No server is required for this non-consumable. StoreKit's signed transaction is
the authority. Do not add an app account token: Tessera has no account to bind.

### Admission boundary

Add a pure `SavedHostAdmissionPolicy` and funnel every production host-creation
path through it. Inputs are current persisted-host count, the number of new
rows requested, and access state; output is `allow`, `requiresPurchase`, or
`checkingEntitlement`.

The policy must be enforced before persistence, not only by disabled buttons.
That prevents keyboard shortcuts, Handoff, or nearby setup from bypassing the
limit.

Production insertion paths found in the current tree:

| Path | Current insertion point | Required behavior |
|---|---|---|
| New Host / `Command-N` / sidebar | `ContentView.createAndEditNewHost()` | Check before blank draft insert; after purchase resume once. |
| Handoff for an unknown endpoint | `ContentView.beginContinuationPrefill()` | Count destination plus new `via` rows atomically; existing matches add zero. Never silently truncate a route. |
| Nearby setup import | `BootstrapManifestAdapter.apply()` | Preflight the full accepted batch before any mutation. Free recipient chooses one importable host or unlocks; route dependencies follow the confirmed counting rule. |
| DEBUG seeds/harnesses | `TesseraApp` / harness helpers | Explicitly exempt; never let harness state exercise production admission by accident. |

Identity creation, host edits, known-host trust, key installation, and quick
connect do not create saved-host slots.

### Suggested files

New:

- `Tessera/Purchases/HostAccessProduct.swift`
- `Tessera/Purchases/StoreKitClient.swift`
- `Tessera/Purchases/HostAccessStore.swift`
- `Tessera/Purchases/SavedHostAdmissionPolicy.swift`
- `Tessera/Purchases/UnlimitedHostsSheet.swift`
- `Tessera/Settings/UnlimitedHostsSettingsView.swift`
- `Tessera/StoreKit/Tessera.storekit`
- `TesseraTests/HostAccessStoreTests.swift`
- `TesseraTests/SavedHostAdmissionPolicyTests.swift`
- `TesseraTests/StoreKitPurchaseTests.swift`

Modify:

- `Tessera/TesseraApp.swift` — construct/inject store, start transaction task
- `Tessera/Settings/SettingsPageView.swift` — section, icon, compact navigation
- `Tessera/ContentView.swift` — one admission/presentation coordinator shared by
  all add-host entry points and Handoff
- `Tessera/Bootstrap/BootstrapCoordinator.swift` and
  `BootstrapManifestAdapter.swift` — entitlement-aware atomic import selection
- `Tessera.xcodeproj/xcshareddata/xcschemes/Tessera.xcscheme` — local StoreKit
  test configuration for the test/run action as appropriate
- `Tessera.xcodeproj/project.pbxproj` — In-App Purchase capability and resources

Do not add a SwiftData column for entitlement or plan state. Apart from being
the wrong authority, it would enter the repository's known `PersistedHost`
migration hazard.

## Milestones

1. **Entitlement truth.** Product config, client protocol, app-transaction
   grandfathering, current-entitlement scan, update listener, unit tests.
   Human-testable Settings page shows `legacy paid`, `free`, or `purchased`.
2. **Manual limit and purchase.** Central admission for New Host and
   `Command-N`, purchase sheet, pending/cancel/error/restore flows, automatic
   continuation into a fresh editor after purchase.
3. **Cross-device creation paths.** Handoff prefill and nearby bootstrap use the
   same policy, with atomic batch behavior and no route truncation.
4. **Release validation.** StoreKit local automation, sandbox/TestFlight on
   iPhone and iPad, full integration suite, adversarial review, normal install
   and launch on the user's existing iPad simulator.

Each milestone ends at a UI the user can exercise. Do not stop after adding
only the StoreKit service or only the App Store Connect product.

## Verification matrix

### Pure/unit

- numeric original-build comparison around the free-model cutoff
- verified legacy paid app transaction grants unlimited
- new free app transaction does not
- unverified/failed app transaction never misclassifies a new user as paid
- verified IAP grants; missing/refunded/revoked IAP removes that source
- union rule: legacy OR IAP is unlimited
- zero hosts allows one free insert; one host requires purchase; edits add zero
- multi-row Handoff/bootstrap request is atomic
- unknown entitlement never deletes/hides and never creates an accidental row
- deferred add action runs exactly once after verified purchase
- legacy/IAP-unlocked Hosts page contains no promotional banner or purchase UI
- first dismissed offer sets presentation suppression; later limit attempts
  show the compact notice and require an explicit `view unlimited hosts` tap

Inject app-transaction facts for deterministic tests. Apple's sandbox reports
`originalAppVersion` as `1.0`, so it cannot prove the real paid-to-free cutoff.

### StoreKit Test

Use a local `.storekit` file and `SKTestSession` for:

- product loading and localized `displayPrice`
- successful non-consumable purchase
- cancellation
- Ask to Buy / pending then approved
- interrupted/failed purchase and retry
- purchase created outside the app, delivered by `Transaction.updates`
- restore/sync
- refund/revocation while the app is running
- relaunch with an existing entitlement

### UI harness

Add a DEBUG-only, no-network purchase harness with injected access states. Cover
free limit sheet, loading, pending, error, purchased, and legacy-paid UI in iPad
landscape and iPhone compact widths. No SSH connection is initiated.

### Live release evidence

- App Store sandbox on a temporary simulator/device with real App Store Connect
  metadata and price
- TestFlight upgrade from the last paid build: unlimited, no purchase prompt
- TestFlight clean install from the free build: one host, second save prompts
- same purchaser on iPhone and iPad: unlock appears on both
- offline launch: existing hosts remain usable while StoreKit truth is unknown
- all four transports still launch and behave unchanged for allowed saved hosts
- `./scripts/integration/run-integration-tests.sh`, with every failure accounted
  for, because this is multi-file lifecycle and cross-device work

## Developer testing playbook

This section is the step-by-step test procedure for development and release.
Keep local StoreKit simulation, App Store sandbox evidence, TestFlight evidence,
and production evidence labeled separately; none substitutes for another.

### 1. Create deterministic test products

Add `Tessera/StoreKit/Tessera.storekit` with one non-consumable product whose ID
exactly matches App Store Connect:

```
com.bambouville.TesseraApp.unlimited-hosts
```

Give the local product at least two localizations and visibly different prices
so tests can catch hard-coded copy. Select the configuration only for the
development Run action and StoreKit-specific test plan. Do not make release or
normal integration runs depend on a local StoreKit file.

Keep the live App Store product IDs in a small checked-in constant. Treat a
missing returned product as a visible unavailable state; do not substitute the
mock price.

### 2. Run the fast automated lane after each StoreKit/policy edit

On a dedicated simulator, run the focused tests first:

```sh
xcodebuild test \
  -project Tessera.xcodeproj \
  -scheme Tessera \
  -destination 'platform=iOS Simulator,name=<dedicated iPad>' \
  -only-testing:TesseraTests/HostAccessStoreTests \
  -only-testing:TesseraTests/SavedHostAdmissionPolicyTests \
  -only-testing:TesseraTests/StoreKitPurchaseTests
```

The suite must use an injected StoreKit client for app-transaction facts and
`SKTestSession` for transaction mechanics. It must not call the network.

Required assertions:

1. `originalBuild < freeModelFirstBuild` grants legacy unlimited access.
2. `originalBuild == freeModelFirstBuild` is a new free customer.
3. Numeric comparisons cover `9` vs `10`, multi-component build strings, and
   malformed values without lexicographic mistakes.
4. Verified IAP, verified legacy app purchase, either source, and neither source
   produce the correct access state.
5. Unverified app/IAP transactions never grant access.
6. Refund/revocation removes IAP access but preserves every saved host row.
7. Product-load failure never displays a fake price.
8. Purchase success resumes the deferred New Host action exactly once.
9. Cancellation is quiet; pending resolves only through an approved update;
   restore calls `AppStore.sync()` only from the explicit button.
10. All manual, Handoff, and bootstrap admission requests use the same quota
    function and multi-row requests are atomic.

### 3. Exercise StoreKit locally in Xcode

Use a disposable simulator, never the user's existing simulator:

1. Edit Scheme → Run → Options → StoreKit Configuration → `Tessera.storekit`.
2. Launch normally with no Tessera feature-suppression flags.
3. Save the first host. Confirm every host feature remains available.
4. Tap `new host` and `Command-N`; both must show the same purchase sheet and
   must not leave a blank second SwiftData row behind.
5. Cancel the system purchase. Confirm the sheet returns to ready without an
   error and the first host still launches.
6. Complete the purchase. Confirm the sheet dismisses and exactly one fresh
   host editor opens automatically.
7. Relaunch. Confirm unlimited access is reconstructed from StoreKit, not from
   an in-memory flag.
8. In Debug → StoreKit → Manage Transactions, delete the purchase, create a
   purchase outside the app, refund it, and resolve pending/interrupted states.
   Confirm `Transaction.updates` changes the UI without relaunching.
9. Tap Restore Purchases and confirm the Apple authentication/sync path occurs
   only after that tap.
10. Change the StoreKit test storefront/locale and verify that the button uses
    the localized product name and `displayPrice` without clipping.

For repeated clean-state tests, erase only the disposable simulator. Never
uninstall Tessera or clear defaults on the user's simulator; that would destroy
their SwiftData container.

### 4. Drive every UI state without StoreKit timing

Add a DEBUG-only `TESSERA_HOST_ACCESS_HARNESS` using an in-memory model container
and injected product/access states:

- checking product
- free with zero hosts
- free with one host
- purchasing
- pending
- product unavailable
- purchase error
- IAP unlocked
- legacy paid
- revoked while multiple hosts already exist

Capture iPad landscape and iPhone portrait plus compact landscape. Verify
44-point touch targets, VoiceOver labels, Dynamic Type, Reduce Motion, light and
dark themes, long localized product names, and long localized prices. The
harness must never initiate SSH/mosh or a real App Store purchase.

### 5. Test host-admission intersections

With the injected free and unlimited states, run these app-level cases:

| Case | Free result | Unlimited / legacy result |
|---|---|---|
| Save first manual host | Allowed | Allowed |
| Save second manual host | Purchase sheet, no draft row | Allowed |
| Edit or launch existing host | Always allowed | Always allowed |
| Delete the only host, then save another | Allowed | Allowed |
| Quick Connect to another endpoint | Ephemeral, no quota use | Same |
| Handoff exact-match host | Continue; adds zero | Same |
| Handoff unknown host with a free slot | Atomic prefill allowed | Allowed |
| Handoff unknown host with no slot | Purchase before any insert | Allowed |
| Nearby import into empty app | One host or one confirmed batch per counting rule | Full batch |
| Nearby import into one-host free app | Purchase/selection before mutation | Full batch |
| Refund with several hosts saved | All remain visible/launchable; no new saves | Not applicable until repurchase |

For jump routes, execute the table only after the counting rule near the top of
this plan is confirmed. A route must never be silently shortened to fit quota.

### 6. Test against App Store sandbox

After the product metadata exists in App Store Connect:

1. Disable the local `.storekit` configuration in the sandbox scheme.
2. Use a Sandbox Apple Account, not a personal purchasing account.
3. Install a development-signed build or TestFlight build on a disposable
   iPhone and iPad/simulators supported by Apple's sandbox.
4. Verify the real product appears, localized price/currency is correct, and
   the payment sheet names the correct app and product.
5. Purchase on iPhone; launch on iPad with the same Sandbox Apple Account and
   confirm `currentEntitlements` unlocks it there without Tessera sync.
6. Test explicit restore, interrupted purchases, Ask to Buy/pending, region
   changes, failure, refund, and an externally created transaction.
7. Repeat at least one purchase on a physical iPhone/iPad because the system
   authentication sheet and account state are not fully represented by the
   simulator.

Record the account storefront, app build, device/OS, product ID, and result for
each sandbox run. Do not record Apple Account credentials or transaction JWS.

### 7. Test the paid-to-free grandfather path honestly

Apple documents that sandbox `AppTransaction.originalAppVersion` is always
`1.0`. Therefore sandbox/TestFlight evidence cannot by itself prove the real
production cutoff. Use three layers:

1. **Deterministic tests:** inject original builds immediately below, at, and
   above `freeModelFirstBuild` and test the complete access state machine.
2. **Upgrade rehearsal:** install the last paid production binary on a device
   using an Apple Account that actually acquired it, populate multiple hosts,
   then update to the release candidate without uninstalling. Confirm no data
   mutation and log only the entitlement source/build classification through
   in-app diagnostics. Label this as an upgrade/data-preservation rehearsal if
   TestFlight still supplies sandbox app-transaction values.
3. **Production cohort check:** at the coordinated free release, test one Apple
   Account that acquired the paid app before the cutoff and one genuinely new
   Apple Account that first downloads the free build. The former must show
   `included with your original Tessera purchase`; the latter must allow one
   saved host and prompt on the second.

Use manual release plus the safest available phased release. Confirm the
grandfather cutoff and IAP availability before expanding rollout. If either
production cohort is misclassified, halt rollout; never “fix” it by deleting or
hiding hosts.

### 8. Regression and handoff gate

Before each human-testable milestone handoff:

1. Build for the dedicated iPad simulator.
2. Run the focused tests and StoreKit UI harness.
3. Run affected Handoff/bootstrap tests when their admission paths change.
4. For the final milestone run `./scripts/integration/run-integration-tests.sh`
   and account for every programmatic and visual failure.
5. Run the adversarial-review workflow because entitlement lifecycle,
   multi-path persistence admission, and nearby/Handoff batch behavior are
   tricky cross-cutting changes.
6. Install the verified normal build on the user's pre-existing booted iPad
   simulator, launch normally with their restore policy intact, and bring
   Simulator.app forward. Do not uninstall/reset it and do not use
   `scripts/install-ipad.sh`.

The final report must label evidence as unit/injected, local StoreKit,
sandbox, TestFlight rehearsal, or production cohort. “StoreKit tested” without
that boundary is not sufficient for this migration.

## App Store Connect and release checklist

1. Verify the Paid Apps Agreement, tax, and banking status is active (the app is
   already paid, but do not assume the agreement has not lapsed).
2. Create the non-consumable product and its localization, availability, price,
   and App Review screenshot. Decide Family Sharing explicitly.
3. Add In-App Purchase capability to the app target.
4. Submit the first non-consumable with the new app version; Apple requires the
   first product of that type to accompany an app version.
5. Put the purchase in an obvious review path: Hosts → New Host after one saved,
   and Settings → Unlimited Hosts.
6. Review notes must explain the paid-to-free transition, the
   `AppTransaction.originalAppVersion` grandfather rule, the one-host free
   limit, the IAP location, and that no server/account is involved.
7. Update App Store description/screenshots to say that saving multiple hosts
   requires a one-time purchase. Do not imply that transports or terminal
   features are paid.
8. Coordinate the app price change to free with the binary/IAP release so no
   build is live where a new free customer can bypass or cannot buy the unlock.
9. Confirm the production `freeModelFirstBuild` against the actual uploaded
   build number before submission. Treat a mismatch as a release blocker.

## Explicit non-goals

- no subscription
- no consumable tip jar
- no Tessera account or receipt server
- no telemetry or purchase analytics
- no per-transport purchase branches
- no paywall on launch or connection to an already saved host
- no deletion, hiding, or forced selection among a paid customer's existing
  hosts
