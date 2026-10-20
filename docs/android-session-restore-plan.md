# Android session restore — why it still doesn't work, and the strategic fix

Status: proposal, 2026-09-11. Evidence: user device log (Pixel 11 Pro, 0.1.0-dev-debug,
18:40–18:47Z 2026-09-11), main @ `2206f709`.

---

## 1. Diagnosis in one line

The 2026-09-10 port (`79689c0`, `1a43c38`, `6151cce`) copied iOS's restore **window**, but
iOS's window rests on three lifecycle premises Android does not satisfy:

1. the scene is never destroyed (`UIApplicationSupportsMultipleScenes=false`, S5);
2. restore state lives in a view that outlives every background edge;
3. every trigger funnels through one function, `attemptForegroundRestoreIfNeeded(reason:)`.

Android destroys its UI routinely, keeps **all** restore state in the composition, has **two
disjoint drivers**, and adds three lifecycle edges iOS has never had: task removal, Activity
recreation, and process death with UI restore.

---

## 2. What the device log proves

| Time | Event | Reading |
|---|---|---|
| 18:40:59–18:44:29 | app backgrounded, sessions alive, **zero** `restore_persist` | the previous ON_STOP write never landed |
| 18:44:29 | `restore_persist merge_with_stored` → `restore_window_open cohort=2` → `restore_window_close settled elapsedMs=5038` | the warm-foreground window **does** work when the latch happens to be armed |
| 18:45:58.45 / .82 | **two** `app_launch`, 370 ms apart | Activity recreated |
| 18:45:58.82 / 18:45:59.13 | **two** `startup_restore_plan count=2` | cold-start path replayed |
| 18:45:58.99–59.31 | 4× `restore_reconnect_start`, 4× `connect_start` | duplicate restore; one host, two transports |
| 18:45:59.26–.27 | `session_controller_close state=Connecting` ×2 | instance #1's transports killed mid-connect |
| 18:46:16.95–17.00 | ON_STOP → `session_controller_close state=Connected` ×2, 30 ms apart | UI destroy kills every transport |
| 18:46:17.03 | `app_launch` (#3) | relaunch |
| — | **no `startup_restore_plan`, no `restore_window_open`, no further `restore_persist`** | restore did nothing at all |
| 18:46:18.27 / 18:46:35.32 | `host_open_connect_start` ssh, then mosh 17 s later | the user reopened both hosts by hand |

Across the whole 6.5-minute log there is **not one `restore_persist active=false`** — the
background-edge write never completes.

---

## 3. The defects

### D1 — swiping Tessera out of recents deletes the restore document, on purpose
`android/app/src/main/kotlin/com/bambouville/tessera/SystemPickerSessionService.kt:71-87`:
`onTaskRemoved` runs `AndroidSessionRestoreRepository.deleteAll()` +
`AndroidForegroundRestoreStore.clear()`. So the most natural way a user tests *"restart the
app"* guarantees nothing restores. iOS never does this — its document is `UserDefaults` and a
force-quit from the app switcher restores normally. This is a straight product divergence and
is the most likely cause of the reported symptom. It emits no diagnostic, so it is invisible
in the log.

### D2 — the background-edge write is cancelled by the Activity it depends on
`MainActivity.kt:936-938` launches `persistRestoreSnapshots(isActive = false)` on
`lifecycleOwner.lifecycleScope` — the **Activity's** scope, cancelled at ON_DESTROY. On this
device ON_STOP and composition disposal are 30 ms apart, and the write does two suspending
DataStore round-trips. It never lands. That write is the only caller of
`restoreWindow.armPreservedSnapshots()` (`MainActivity.kt:889`), and
`hasPreservedSnapshots` is the single gate on the whole wake path (`MainActivity.kt:988`).

### D3 — the latch is armed asynchronously and read once, synchronously
`hasPreservedSnapshots` is a plain `var` on a remembered object
(`ForegroundRestoreWindow.kt:134`), not Compose state. The wake effect's keys
(`appActive, locked, startupRestoreResolved, policy, usesCompactShell`) do not change when the
arm finally lands. Any wake that recomposes before the ON_STOP write finishes gets **no window
for that wake**, and nothing retries.

### D4 — every piece of restore state is composition-scoped — **fixed**
`liveSessions`, `liveSessionIds/States/CreatedAt`, `startupRestoreEvaluated`,
`startupRestoreResolved`, `restoreWindow`, `restoreDocumentLock`, `restoreReconnectRequests`
were all `remember` (`MainActivity.kt:536-584`). Combined with
`SshSessionScreen.kt:833-835` (`onDispose { controller.close() }`), an Activity recreation
killed every transport *and* every latch, then replayed the cold-start path — exactly the
18:45:58 double-launch above. There was no Application class, no `ProcessLifecycleOwner`, and
no process-scoped coroutine scope anywhere in the Android tree.

Fixed in two passes. `SessionRestoreCoordinator` took restore's own state first, which stopped
the replay while the sessions still died and were rebuilt. `LiveSessionStore`
(`feature-session`) then took the sessions: the tab list, the controllers, and the scope their
transports run on. `onDispose` unbinds the view; only `LiveSessionStore.close` ends a session,
and the sessions list, the in-session close action and task removal are what call it. The agent
runtime moved with them — it hung off the Activity's `ViewModelStore`, which a real destroy
clears, so a surviving controller would have held a closed coordinator.

Worth stating precisely, because it narrows what this ever cost: the manifest declares
`configChanges` for `orientation|screenSize|fontScale|uiMode` and the rest, so rotation,
split-screen resize and theme changes never destroyed the Activity and never killed a session,
and the app never calls `recreate()` itself. What remains is a real destroy, of which the log
above has both kinds: one the system did on its own at 18:45:58 (cause never established, and
outside this fix) and one at 18:46:16 when the user left and came back to a warm process.

One thing does not come back with the session: `TermuxTerminalSurface` owns an Android `View`
and dies with the Activity that themed it, so the new screen repaints from tmux or from mosh's
own model, and a plain-SSH grid starts empty under a shell that is otherwise exactly where the
user left it. Keeping the emulator without its view is a separate change; the sessions were
being destroyed outright before, so nothing regressed by doing less.

### D5 — ordinary UI round-trips run a full background edge
`MainActivity.onStop:320` guards on `!isChangingConfigurations && !externalUiActive`. The
composable's lifecycle observer (`MainActivity.kt:920-946`) does not. So a SAF file picker, the
camera, a full-screen permission screen, or the keyguard-credential activity each close the
window mid-wake, do a merge write, re-arm the latch, and on return open a fresh 60 s window
over sessions that never died.

### D6 — two restore drivers that cannot see each other — **fixed**
Path A (cold start, `MainActivity.kt:767-814`) and path B (wake window,
`MainActivity.kt:986-1143`) share no funnel. A is latched off after the first composition; B is
gated on a latch only A's counterpart can arm. A session whose tab was torn down at a destroy
edge falls into neither.

The gap closed from both ends rather than by merging the drivers. A real background edge
re-arms A's pass (`consumeStartupRearm`), so a relaunch is no longer mistaken for a
recreation; and with D4 fixed there is no longer a tab torn down at a destroy edge for either
driver to miss — a session that really died is still B's, and A now finds the survivors already
on screen and correctly plans nothing.

### D7 — the cold-start path could spend its one pass on a host list that had not arrived

Found by the `startup_restore_skip` instrumentation added during the fix, on its first run:

```
startup_restore_skip reason=hosts-not-loaded
startup_restore_skip reason=nothing-restorable detail=stored=2 hosts=0 live=0
```

`loadedHosts` stops being null at Room's first emission, and that emission can predate a write
the query has not observed yet. The path read every snapshot as naming a host this device no
longer has, resolved with nothing restorable, cleared the document, and logged none of it. The
wake window already refuses to tick before the host list has loaded, for exactly this reason;
the startup path did not — the same rule present in one place and missing in the other, which is
the argument for the shared driver in section 4.

This is a second candidate explanation for the 18:46:17 launch, alongside D1. Both are fixed, and
a future occurrence now names its own guard.

**Open:** the proximate cause of launch #3 is unproven. By elimination on the path-A guards it
is either "the stored document was empty" (D1 would do it) or "`continuityState` never
emitted". One instrumented repro settles it.

---

## 4. The fix

### Layer 1 — share the *driver*, not just the verdicts

The shared core already owns the decisions —
`Packages/TesseraCore/Sources/TesseraSessionCore/ForegroundRestoreCohort.swift`: `verdict`,
`evaluate`, `windowClosure`, `chargeDelta`, `persistMode`, all across the C ABI
(`SessionPolicyABI.swift:95-307`). What is still duplicated is the **driver**, and that is where
every one of the 41 shipped iOS bugs actually lived: guard order, latch semantics, the seeding
rule, the merge algorithm, the selection rule, the constants and their derivation.

iOS keeps it inline in `ContentView.swift:3722-4213`. Android keeps a partial, already-drifted
copy in `ForegroundRestoreWindow.kt`. The c2b02c9 review recorded four of these as debts by name.

Add `ForegroundRestoreDriver` to `TesseraSessionCore` as a **pure state machine** — no handle,
in keeping with `SessionPolicyABI`'s stated rule ("the platform already owns the clock, the
store, and the observable wrapper; what it must not own is a second copy of the decision"):

```
step(state, event, facts) -> (state', effects)

events  startupReady | foreground | background | unlock | lock | tick
        sessionsChanged | promptAnswered(reopen|notNow) | userRetired(ids)
        policyChanged | taskRemoved | uiTornDown
facts   live sessions (id, hostId, state, transportConfirmed), stored document,
        stored + effective policy, now, hasUnansweredPrompt, isPrompting, locked
effects persist(mode, snapshots, selection) | reopen(snapshots, selection)
        | reconnect(ids) | offerPrompt(document) | clearStore | armTick | log
```

Both platforms become executors. The latch, the cohort, the clock and the guard order stop
being platform code.

Two things come with it:

- **Cross-platform vectors.** `ProtocolVectors/session/restore-driver-v1.json`, consumed by the
  Swift tests and by `KotlinConformance` — the render-ledger precedent. This is the only way to
  test any of this on the Android JVM: a unit test cannot `dlopen` the core, which is why
  `ForegroundRestoreWindowTest` currently fakes every decision.
- **Retire the orphan.** `tessera_session_restore_document_rules` is exported, headered, JNI'd,
  Kotlin-wrapped, and **called by nobody**, while both platforms restate the rules locally and
  disagree (iOS has no max-snapshot cap and no duplicate-ID check). Wire it or delete it.

**iOS adopts first.** Standing rule: an Android-only restore/tmux bug is usually a shared-core
hole iOS patched privately.

### Layer 2 — give Android a process-scoped owner

This is the half no shared component can fix, and the reason the port failed.

- Add `TesseraApplication` + `androidx.lifecycle:lifecycle-process` and an application-scoped
  `SupervisorJob` scope.
- Move the driver state, the live-session registry and the document mutex out of the
  composition into a process-scoped holder. The composition becomes a *view* of it.
- The background-edge write runs on the application scope, so ON_DESTROY cannot cancel it
  (**D2**); the latch becomes a `StateFlow` so a late arm re-triggers the wake path (**D3**).
- Sessions stop dying with the Activity: `controller.close()` moves from `onDispose` to the
  registry's own teardown (**D4**). This also makes `restore.delete(sessionId)`-on-
  `explicitDisconnect` correct again — composition disposal used to be indistinguishable from a
  user disconnect at the record layer (`SshSessionController.kt:1523`, `:1577`). **Done**, as
  `LiveSessionStore`. No `TesseraApplication` was needed: the singleton-with-`get()` shape
  `SessionRestoreCoordinator` already uses carries a process scope perfectly well, and the
  foreground service that keeps a connected session alive was already there.
- Single-flight the funnel, mirroring iOS's `foregroundRestoreEvaluating`, so a recreation
  cannot double-plan (**D6**).

### Layer 3 — decide each Android lifecycle edge explicitly

| Edge | Today | Proposed |
|---|---|---|
| Cold start from launcher | path A | unchanged |
| Warm foreground (ON_STOP → ON_START) | window, only if the latch happened to arm | window, latch observable |
| Activity destroy, process alive | ~~kills all transports, replays path A~~ | **done** — driver + transports survive; the relaunch gets its own pass and finds nothing to rebuild |
| Process death + restore from recents | path A | unchanged |
| **Task swiped from recents** | **both stores wiped** | honour the setting: keep the document unless policy = NEVER |
| Share / notification / shortcut launch | opens a host; `liveSessions.isNotEmpty()` then silently suppresses restore | restore runs first, then the intent's host is opened/focused |
| SAF picker / camera / permission / keyguard | full background edge + a 60 s window over live sessions | guard on `isChangingConfigurations` / `externalUiActive`, as `MainActivity.onStop` already does |
| Undeclared config change (Bold Text, colorMode, grammaticalGender, "Don't keep activities") | full recreation = session kill | absorbed by Layer 2 |
| `ASK` + unanswered prompt on a tablet | `startupRestoreResolved` stays false ⇒ persistence disabled entirely | driver owns the state |

iPhone/compact: `ASK` coerces to `ALWAYS` on compact width on both platforms
(`SessionRestorePresentationPolicy.effective`). Keep it — already shared, already correct.

---

## 5. Verification

- **Shared** — extend `ForegroundRestoreCohortTests` into driver-sequence tests; add the vector
  file; `scripts/check-abi-header.sh` gates any new symbol (it only checks Swift↔header; JNI and
  Kotlin drift still fails at `dlsym` on a device).
- **Android JVM** — replace `ForegroundRestoreWindowTest`'s scripted-decision fakes with vector
  conformance plus driver sequencing. First time these rules are testable without `dlopen`.
- **Android instrumented** — a new gate on a **disposable AVD** driving the real edges:
  ON_STOP/ON_START, `am kill` (process death), Activity recreate, task removal, SAF round-trip;
  asserts the diagnostic sequence `restore_persist active=false` → `restore_window_open` →
  `restore_window_dead` → `restore_window_reconnect` → `restore_window_close settled`.
- **Live** — four transports (ssh, ssh+tmux, mosh, mosh+tmux) across a background/foreground
  cycle and a relaunch, on the VPS fixtures; plus the user's own Pixel pass.
- **iOS** — the existing scenario tests must stay green through the adoption.

---

## 6. Sequencing

| Milestone | Content | Scope / how you verify it |
|---|---|---|
| **M0** | Task-removal policy only: `onTaskRemoved` stops wiping the stores unless policy = NEVER, and emits a diagnostic so the wipe is no longer invisible. | ~1 hour. Self-contained, one file. You verify directly: swipe away from recents, relaunch, sessions come back. |
| **M1** | Process-scoped owner: `TesseraApplication` + `lifecycle-process`, live-session registry and restore-document mutex out of the composition, durable background-edge write, single restore funnel, the Layer-3 lifecycle matrix. | Multi-file, lifecycle-critical. Verified on a device: `restore_persist active=false` must appear at every background edge; recreate / picker / share-launch / process-death cases each behave per the matrix. |
| **M2** | The remaining duplicated *rules* move into `TesseraSessionCore` — the cold-start plan, the compact-shell policy coercion, and what each persist mode writes — with ABI, header, JNI and Kotlin wrappers, vectors, and iOS adopting first. | Shared-core tests, the vector file, the iOS restore gate. |
| **M3** | Android adopts the same three rules; the Kotlin copies are deleted. | Android restore gate + `:data` JVM tests. |
| **M4** | Instrumented lifecycle gate on a disposable AVD + VPS suite + live device pass, both platforms. | Suite output. |

### What M2 deliberately did *not* do

An earlier draft called M2 a `ForegroundRestoreDriver`: a `step(state, event, facts)` state
machine owning the cohort, the window clock and the latch. That was dropped, for a reason the ABI
states about itself:

> All three are pure state-in/state-out, so nothing here takes a handle. That is deliberate — the
> platform already owns the clock, the store, and the observable wrapper; what it must not own is
> a second copy of the decision.

A driver would move restore's *state* into the core and so would need a handle. It also would not
have prevented any of the bugs this round actually found: D2, D3 and D4 were Android
lifecycle-ownership defects that no shared core can reach, and they were fixed by M1 giving that
state a process-scoped owner. D7 was different in kind — a *rule* that existed on one platform and
not the other. Rules are what belong in the core, so M2 lifted the three that were still
duplicated and left the state where it is.

The latch likewise stayed platform state. `hasPreservedSnapshots` is now on
`SessionRestoreCoordinator`, which outlives the Activity, so the composition-scoped failure it had
is gone without moving it across the ABI.

Only M0 carries a wall-clock estimate. M1–M3 are multi-file changes to lifecycle-critical code
whose cost is dominated by device verification, so they are sequenced by what each one makes
testable rather than by a quoted duration.

Two items were moved out of an earlier draft's M0 because they were mis-scoped:

- *Durable background-edge write* is not a scope change. `persistRestoreSnapshots`
  (`MainActivity.kt:856`) is a local suspend fun inside the composable, closing over
  `liveSessions`, `liveSessionIds`, `restoreWindow`, `continuityState`, `restoreRecords` and
  `presentedHostId`, and taking `restoreDocumentLock` — itself `remember { Mutex() }`
  (`:580`). Running it on a scope that outlives the composition leaves the departing write and
  the next wake's seed read serialised by two different mutexes. The real change is to snapshot
  an immutable payload synchronously at ON_STOP and hand it to a process-scoped writer. That is
  the front half of M1.
- *Observable latch* only closes the race inside one composition (ON_STOP without destroy, then
  ON_START before the write lands). `hasPreservedSnapshots` lived on the composition-scoped
  `ForegroundRestoreWindow` (`ForegroundRestoreWindow.kt:134`), so a destroyed composition started
  unarmed however observable the flag was. M1 fixed it by moving the window onto
  `SessionRestoreCoordinator`, which is process-scoped; the latch is exposed as a `StateFlow` the
  composition collects.

## 6b. What M2 and M3 moved

| Rule | Was | Is now |
|---|---|---|
| What a cold start should do, and why it should *wait* rather than skip | Inline in `ContentView.attemptStartupRestoreIfReady` and again inline in `MainActivity`'s startup `LaunchedEffect` — where D7 lived, present on one side only | `ForegroundRestoreStartup.action` |
| `ask` behaves as `always` on a compact shell | `SessionRestorePresentationPolicy.effective` on iOS, `SessionRestorePresentationPolicy.effective` on Android, spelled identically | `ForegroundRestorePresentation.effectivePolicy` |
| What each persist mode writes, and what it selects | Inline in `ContentView.persistRestoreSnapshots` (named as a debt in the review that shipped it) and in `ForegroundRestoreWindow.snapshotsToPersist` / `.selectionToPersist` | `ForegroundRestorePersistPlan.entries` / `.selection` |

Three ABI functions carry them: `tessera_session_restore_startup_action`,
`tessera_session_restore_effective_policy`, `tessera_session_restore_persist_plan` — each present
in all four layers, which `scripts/check-abi-header.sh` enforces.

What stayed on each platform, on purpose: the *records*. The core answers in session ids and says
which collection each one comes from, because a snapshot carries display names, launch modes,
transports and tmux targets that mean nothing to it. iOS also keeps `SessionRestoreResolver` —
credential eligibility reads the keychain, and the lineage / singleton-tmux dedup is a deferred
lift, not a shared rule yet.

Two defects the lift itself exposed:

- **D8 — Android's `keepCohort` write could not see the stored selection.** The coordinator loaded
  the stored document only for `MERGE_WITH_STORED`, so the `keepCohort` fallback — the one that
  exists because mid-wake the session the user was last looking at is reconnecting and momentarily
  has no tab — was always handed `null`. The JVM test passed a stored document explicitly and so
  never saw it. Fixed by loading for both modes.
- **D9 — iOS could write a dangling selection.** A merge returned `previousDocument.selectedSessionID`
  unconditionally, even when that session was not in the write. Kotlin already checked. The shared
  rule drops it, which is what the document's own validation says should happen anyway — so the
  effect was a document that was repaired on load instead of being correct when written.

- **D10 — identifiers came home re-spelled.** Swift decodes a session id into `UUID` and re-encodes
  with `.uuidString`, which is always UPPER case; Android writes `UUID.randomUUID().toString()`,
  which is lower. Every id the two new calls returned therefore matched nothing in the store, and
  the cold-start plan crashed on `require(snapshots.isNotEmpty())`. `:data` already carried a
  private repair for this in `evaluate`'s retired ids; it is now fixed once, in
  `SharedSessionPolicy`, which re-spells every id it returns to match the ones it was given.
  The vectors could not have caught it — their symbolic ids were all digits, identical in either
  case — so they now use lower-case ids with hex letters.

The first two are one platform's private repair or private omission of a rule the other had — the
shape `feedback_ios_private_repairs_hide_android_bugs` names, in both directions. The third is the
cost of the seam itself, and is the reason the vectors exist.

## 7. Test-first plan (precedes the refactor)

The coverage gap is not where it looks. The **decisions** are already heavily tested —
`Packages/TesseraCore/Tests/TesseraSessionCoreTests/ForegroundRestoreCohortTests.swift` (719
lines), `TesseraTests/ForegroundRestoreCohortTests.swift` (510), and
`android/data/src/test/.../ForegroundRestoreWindowTest.kt` (13 sequencing tests). Every defect
in section 3 is in the **wiring**, and the two platforms are not equally reachable:

- **Android wiring is testable today.** `createAndroidComposeRule<MainActivity>` plus
  `ActivityScenario.moveToState` / `.recreate()` already works in this repo
  (`android/app/src/androidTest/.../HostShellInstrumentedTest.kt:59`). No Robolectric is present,
  so this is instrumented-only and needs a disposable AVD per run — model the runner on
  `scripts/android/run-runtime-gate.sh`. The tests read two things to decide pass/fail: what is in the DataStore document, and
  which lines appear in `tessera-diagnostics.log`. Both already exist.
- **iOS wiring is testable one level up, today.** The *unit* level is blocked, but not by access
  control: the driver's state is SwiftUI `@State` on a `View`, so widening `private` to
  `internal` still leaves nothing a test can construct and drive. The **wiring** level — where
  every defect in section 3 lives — is reachable now, and the instrumentation is already
  richer than Android's:
  - `logRestoreDiag` → `DiagnosticLogStore.appendRestore` (`ContentView.swift:5578`) is called
    from ~40 sites and names the guard that bailed:
    `startup-restore-skip reason=already-evaluated|locked|no-document`,
    `startup-restore-clear reason=policy-never|no-restorable-sessions`,
    `app-phase-skip reason=startup-restore-not-evaluated`, `app-lock-changed locked=…`. That is
    exactly the instrumentation whose absence left the Android launch-#3 gap unexplained.
  - Five `TESSERA_*_HARNESS` env gates already exist (`TesseraApp.swift:114, 267, 270, 286`;
    `ContentView.swift:4521`), including `TESSERA_CONTINUITY_LIVE_HARNESS` — the established
    pattern for driving a lifecycle-dependent flow with fake sessions and no real host, which
    also keeps the never-auto-connect rule intact.

  So the iOS suite is the same shape as the Android one: a `#if DEBUG` env-gated restore
  harness seeding fake sessions, XCUITest driving the real lifecycle
  (`XCUIDevice.press(.home)` / `app.activate()` for the wake edge, `app.terminate()` /
  `app.launch()` for force-quit-and-relaunch, harness env for lock and policy), and the runner script checking
  `tessera-diagnostics.log`, pulled out with `xcrun simctl get_app_container`. Runs on a **disposable** simulator — UI tests mutate
  settings and rotate the device.

  So the iOS driver does not have to be pulled out of `ContentView` before iOS can be tested.
  The tests come first and then watch over that change.

These tests must describe how restore **should** behave, so the ones covering a live defect
fail until it is fixed. A suite written to match today's behaviour would just freeze the bugs
in place.

### T0 — writable now, no production change

| ID | What it does | What it checks | Covers | Status |
|---|---|---|---|---|
| A1 | RESUMED → CREATED (ON_STOP, no destroy) | `restore_persist active=false` lands; document holds the live set | D2 | **passes** — the write survives a stop |
| A2 | RESUMED → DESTROYED | same | D2 | **fails** |
| A3 | `scenario.recreate()` with a document present | no second `startup_restore_plan`; no `restore_reconnect_start`; **no `session_controller_close` at all**; the same hosts still live in `LiveSessionStore` | D4 | **passes** |
| A4 | ON_STOP → ON_START, looped 8× | `restore_window_open` follows every time | D3 | **fails** |
| A5 | Configuration change | no background edge, no `restore_window_open` over live sessions | D5 | **passes, for the wrong reason** — see note |
| A6 | Launch with a share / notification intent while a document exists | `startup_restore_plan` still emitted | D6 | **passes** (iOS twin: `launch-opens-host` in the restore lifecycle gate) |
| A7 | `onTaskRemoved` with policy = ALWAYS | document survives | D1 | **fails** |
| A8 | policy = NEVER across every edge | document cleared, nothing restores | nothing broken — catches a future break | **passes** |
| B1 | `ProtocolVectors/session/v1/restore-decisions.json` — 27 rows stating each decision once; pinned to the core by `RestoreDecisionVectorTests`, and to the bridge by `SharedRestoreDecisionVectorInstrumentedTest` | the same rule holds in Swift and after JNI marshalling | nothing broken — catches a future break | **passes** |
| B2 | JVM: `SessionRestoreTaskRemovalTest` | removing the task honours the restore setting | D1 | **2 of 3 fail** |
| B3 | JVM: `ForegroundRestoreWindowConstantsTest` | Android's alive floor / backstop / tick / charge clamp still match iOS's | nothing broken — catches a future break | **passes** |
| C1 | Swift: go through `ForegroundRestoreCohortTests` against the list at the end of this doc | every scenario in that list has a case | nothing broken — catches a future break | **passes** |
| D1 | iOS XCUITest: home → activate with a document present | wake window opens; `app-phase` path taken, not `app-phase-skip` | S3/S23 | **passes** |
| D2 | iOS XCUITest: `terminate()` → `launch()` | sessions restore — pins the deliberate divergence from Android's task-removal wipe | A7's twin | **passes** |
| D3 | iOS XCUITest: lock → unlock across a background edge | window seeds *after* the lock guard; document not stripped by a live-only write | S37 | **passes** |
| D4 | iOS XCUITest: policy = `.ask`, a session dies after the sheet is up | sheet absorbs the larger set in place, identity preserved | S13/S27 | **passes** |
| D5 | iOS XCUITest: app visit shorter than the 5 s alive floor | window does not carry the previous wake's clock | S23 | **passes** |

Verified on a disposable emulator, 2026-09-11: 5 of 8 red, each for the defect it was written
for. **A1 passing while A2 fails sharpens D2**: the background-edge write does land when the
Activity is merely stopped, and is lost specifically on the destroy edge, where the Activity's
coroutine scope is cancelled underneath it. That is exactly the shape of the reporter's log — the
18:44:29 wake window worked because an earlier stop-only edge had armed the latch, and the
18:46:17 launch restored nothing because the edge before it was a destroy.

A correction to an earlier draft: `B1` does **not** let Android check a decision without an
emulator. A JVM test cannot reach the core, and a Kotlin reimplementation of the rules would only
be a second authority to drift from — which is the thing this codebase deliberately avoids. What
the vectors actually buy is narrower and still worth having: the rules are written down once, the
Swift test pins them to the authority, and the Android *instrumented* test pins the same rows to
what comes back over JNI. That is where Android-only drift lives — milliseconds converted to
seconds at the wrapper edge, enums crossing as wire strings, an absent optional arriving as a
missing key rather than a null, and a `-1` that means invalid arguments, an undersized buffer, or
an unreachable state depending on the call.

### T1 — small production changes that make the rest testable (no change in behaviour)

Both are done:

- `SessionRestoreTaskRemoval` (`android/data/.../continuity/`) gives the recents-swipe path an
  entry point a test can call. `Service.onTaskRemoved` is otherwise unreachable — the service
  publishes no binder, so neither `ServiceTestRule` nor instrumentation can get an instance.
  Behaviour is unchanged: the rule still says "retire", which is why `B2` and `A7` fail.
- `SessionRestoreDebugHarness` (`Tessera/`, `#if DEBUG`) seeds fixture hosts at a closed loopback
  port and the document the launch is about to read, and mirrors the restore report to the system
  log so a UI test — which runs out of process and cannot read the app container — can be checked
  against it.

Pulling the iOS driver out of `ContentView` moves out of T1 entirely: `D1`–`D5` watch over that
change rather than waiting on it.

All three gates were run on 2026-09-11: Android 5/8 red (each for its own defect), iOS
`TESSERA_RESTORE_LIFECYCLE_GATE_OK` (8 assertions over 5 cases), shared-core vectors 5/5.

### Files

| File | What it is |
|---|---|
| `android/app/src/androidTest/.../SessionRestoreLifecycleInstrumentedTest.kt` | A1–A8, driven through `ActivityScenario` lifecycle edges |
| `android/data/src/main/.../continuity/SessionRestoreTaskRemoval.kt` | the recents-swipe path, given an entry point a test can call; behaviour unchanged |
| `android/data/src/test/.../continuity/SessionRestoreTaskRemovalTest.kt` | B2 |
| `android/data/src/test/.../continuity/ForegroundRestoreWindowConstantsTest.kt` | B3 |
| `android/core-bridge/src/androidTest/.../SharedRestoreDecisionVectorInstrumentedTest.kt` | B1, Android half |
| `ProtocolVectors/session/v1/restore-decisions.json` | the decisions, stated once — 27 rows |
| `Packages/TesseraCore/Tests/TesseraSessionCoreTests/RestoreDecisionVectorTests.swift` | B1, Swift half |
| `Tessera/SessionRestoreDebugHarness.swift` | `#if DEBUG` seeding + system-log mirror |
| `TesseraUITests/SessionRestoreLifecycleProbe.swift` | D1–D5 |
| `scripts/uitest/run-restore-lifecycle-gate.sh` | iOS gate, disposable simulator, assertions over the mirrored log |
| `scripts/android/run-runtime-gate.sh` | gained a `restore` focus: `TESSERA_ANDROID_RUNTIME_FOCUS=restore` |

Running them:

```
TESSERA_ANDROID_RUNTIME_FOCUS=restore scripts/android/run-runtime-gate.sh   # A1-A8
(cd android && ./gradlew :data:testDebugUnitTest)                          # B2, B3
(cd Packages/TesseraCore && swift test --filter RestoreDecisionVectorTests) # B1 Swift
TESSERA_ANDROID_RUNTIME_FOCUS=all scripts/android/run-runtime-gate.sh       # B1 Android
scripts/uitest/run-restore-lifecycle-gate.sh                               # D1-D5
```

### T2 — refactor against a green suite

M0 → M1 → M3, each one turning its rows from failing to passing.

### Stays a live check regardless

Real LMK process death; the actual recents swipe gesture (it cannot be injected — same
constraint as the back gesture); mosh zombie behaviour across a genuine network loss;
four-transport parity.

## Appendix — the iOS scenario catalogue this is built on

Three eras: cold-start only (`199228c8`), timed foreground grace (`1db1ea6c` … `0f10ad6e`),
verdict cohort (`2c1f20f5`, `4072faa8`, `fee3e934`, `c2b02c92`), then extraction to the shared
core (`f49764ce`) and the ABI bridge (`45f4621f`). iOS restore has been functionally frozen
since `c2b02c92` (2026-08-18).

Load-bearing fixes, all of which the Android driver must inherit rather than re-derive:

- **S3** the process survived the background edge so the startup latch was spent — the bug
  Android still has.
- **S11** the first death report at wake cleared the latch and stranded every session that
  reported after it (field log: two transports 5 ms apart, one restored).
- **S13/S27/S29** the `.ask` sheet must absorb a strictly larger set in place, must count as a
  verdict, and must resist interactive dismissal.
- **S16–S19** the window ends on a verdict, not a clock; mosh zombies read `pending`; a 5 s
  alive floor stands in for SSH's missing reachability signal; entries only ever leave.
- **S23** a window carried across the background edge runs the previous wake's clock — every
  app visit shorter than the alive floor hits it.
- **S25** the backstop is *derived* from the SSH handshake budget (40 s + 20 s). Android has no
  connect budget, so nothing there rules on a wedged connect and 60 s is a guess.
- **S26** five explicit-close gestures must retire their entry; `onSessionEnded` deliberately
  must not.
- **S37 (High)** the app-lock persist hole: `persistMode` became a pure function precisely
  because a live-only write behind a lock screen deleted the snapshots the post-unlock wake
  needed.
- **S39/S40** the backstop defers while a prompt is unanswered, and the window clock charges in
  the same units as the handshake budget (2 s-clamped, zero while prompting).

Open iOS lows carried forward: `review-auto-reconnect-cohort.md` R5 (no wake epoch; mosh
correctness rests on Darwin's `CLOCK_MONOTONIC_RAW` counting sleep), L2 (`+N reconnecting`
miscounts), L3 ("Not now" closes the whole window), L4 (one handshake budget spans a jump
chain).
