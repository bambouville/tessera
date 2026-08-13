# Tessera onboarding — Codex Desktop exploratory QA guide

Tessera is an iPad-first SSH/Mosh terminal app (SwiftUI, iOS 17+, tested on iOS 26
simulators) with an iPhone companion experience. This guide is optimized for **Codex Desktop
acting as a human QA tester**: it drives the visible app through the Simulator or physical
device, notices visual and interaction problems, captures evidence, and only then uses the
repository, logs, or CLI tooling to diagnose what happened.

The detailed expected behavior remains deliberately exhaustive. It is the product oracle for
the new-user journey: first launch, Nearby Setup, walkthrough, first host, keys and trust,
first terminal session, and every shell/window variant. The new agent-facing layer tells
Codex how to explore those flows without reducing the exercise to another deterministic UI
test.

Chapters are ordered the way a QA session should use them:

0. **Codex Desktop operating protocol** — black-box first pass, evidence, severity, reports.
1. **Prepare the QA environment** — reset procedures, hooks, fixtures, two-device staging.
2. **Master device / orientation / window matrix** — choose the correct shell and geometry.
3. **First open & Nearby Setup bootstrap** — first-launch comprehension and transfer trust.
4. **iPad walkthrough** — visual teaching quality, spotlight placement, and resizing.
5. **Landing page & first host** — discoverability, form friction, defaults, and recovery.
6. **Keys & first-connection trust** — security comprehension and dangerous-action clarity.
7. **First session basics** — progress, failure recovery, terminal controls, keyboard, Files.
8. **Shell & orientation variants** — responsive continuity, rotation, Split View, Stage Manager.
9. **Automated coverage catalog** — what automation already proves and what Desktop should judge.
10. **Reusable Codex Desktop missions** — prompts for first-user, adversarial, visual, and regression passes.

Every product flow retains the same reference format: **Preconditions**, numbered **Steps**
with `-> Expected:`, **Device/orientation variants**, **Edge & failure cases**, and
**Automated coverage**. UI copy in quotes is exact source copy. HTML comments
(`<!-- src: ... -->`) preserve the original code provenance. Sections labeled
**Codex Desktop QA charter** are exploratory instructions added for the agent; they are not
claims about current implementation.

---

## 0. Codex Desktop operating protocol

### 0.1 Role and objective

Act as an independent user, not as the developer who already knows how Tessera works. The
primary question is not merely whether a control exists or an assertion passes. Judge:

- Can a new user understand what to do next without source-code knowledge?
- Does the visible interface communicate progress, safety, and recovery?
- Are controls easy to hit, labels readable, and layouts stable during keyboard, rotation,
  resizing, sheets, and system prompts?
- Does the app preserve the user's mental model when moving between iPhone, iPad, tabs,
  sidebar, session overlays, and external system surfaces?
- When something fails, can the user identify what happened and recover without guessing?

Automated tests remain the regression layer. This guide uses Codex Desktop to find the class
of bugs that deterministic tests often miss: poor hierarchy, clipped or crowded layouts,
misleading copy, weak feedback, surprising state changes, accidental taps, awkward keyboard
behavior, and flows that technically complete but feel broken.

### 0.2 Mandatory two-pass method

#### Pass A — black-box user simulation

Complete the assigned mission through visible UI only.

1. Do not inspect implementation files before attempting the flow.
2. Do not use accessibility identifiers as a substitute for looking at the screen.
3. Do not silently work around confusing UI because the guide reveals the intended action.
4. Record every hesitation, wrong first interpretation, accidental tap, and unexpected state.
5. Capture evidence before changing state when a problem appears.
6. Continue after non-blocking issues to find compounding friction.
7. Stop and preserve the state for crashes, data-loss risk, security ambiguity, or a blocked
   critical path.

The `Expected:` lines are an oracle, not a script to rationalize the UI. First note what an
unfamiliar user would infer; then compare it with the expected behavior.

#### Pass B — diagnostic reproduction

After the black-box pass is complete:

1. Reproduce each finding from a known reset state.
2. Use logs, accessibility hierarchy, repository search, CLI tools, and test hooks only now.
3. Separate observed fact from diagnosis. A suspected implementation cause is never the
   finding itself.
4. Determine whether the issue is deterministic, timing-sensitive, device-specific,
   orientation-specific, or dependent on prior state.
5. Identify existing automated coverage and explain why it did not catch the issue.
6. Recommend the smallest useful regression test only after confirming the user-visible bug.

Do not modify code during the QA mission unless the mission explicitly includes a fix-and-
verify phase. Preserve an unmodified reproduction first.

### 0.3 Session setup and evidence header

Start every QA report with:

```text
Mission:
Build / commit:
Device or simulator:
OS runtime:
Window mode and orientation:
Input mode: touch / mouse / software keyboard / hardware keyboard
Install state: fresh / upgraded / seeded / restored
Test hooks or launch arguments:
Fixture endpoint:
Theme / text size / accessibility settings:
Start time:
```

For simulator missions, use a clean, purpose-specific simulator whenever the scenario depends
on first-launch state. Terminal commands are appropriate for uninstalling, installing,
launching, collecting logs, and taking exact screenshots; interaction with the app should
still be performed through the visible Simulator during Pass A.

### 0.4 What to observe continuously

At each transition, silently inspect the whole screen rather than only the target control:

| Lens | Questions |
| --- | --- |
| **Next action** | Is the primary action immediately obvious? Is there a competing action with equal visual weight? |
| **State** | Can the user tell whether the app is idle, working, waiting on another device, connected, or failed? |
| **Feedback** | Did the tap visibly register? Is latency acknowledged before the user taps again? |
| **Layout** | Any clipping, overlap, bad wrapping, unstable alignment, excessive empty space, or hidden content? |
| **Input** | Is focus correct? Does the keyboard cover fields or actions? Are return-key semantics sensible? |
| **Touch** | Are controls comfortably hittable? Do neighboring controls invite mis-taps? |
| **Navigation** | Is Back/Cancel/Done behavior predictable? Does returning preserve the expected state? |
| **Copy** | Is terminology understandable to a new SSH user? Does security copy explain consequences without alarm fatigue? |
| **Safety** | Are destructive, irreversible, or trust-changing actions clearly distinguished and confirmed? |
| **Recovery** | Does failure say what happened, what remained unchanged, and what the user can do next? |
| **Continuity** | Does rotation, resizing, backgrounding, or cross-device movement preserve the user's place and data? |
| **Polish** | Any stale frame, animation jump, flicker, delayed relayout, incorrect theme, or visibly unfinished placeholder? |

A behavior can match the expected functional result and still be a UX finding.

### 0.5 Exploratory modes

Use one mode per session so the observations are not contaminated by conflicting personas:

1. **First-time user:** no SSH/Tessera assumptions; follow only visible guidance.
2. **Experienced terminal user:** move quickly, use keyboard shortcuts, expect dense efficiency.
3. **Error-recovery user:** enter plausible wrong values, deny permissions, cancel prompts,
   background mid-operation, and retry.
4. **Layout stress:** rotate, summon/dismiss keyboard, resize Split View or Stage Manager,
   change Dynamic Type, and open the longest sheets.
5. **Returning user:** preserve hosts and sessions, relaunch, restore, edit, and reconnect.
6. **Security-conscious user:** scrutinize key movement, TOFU, biometrics, trust changes,
   deletion, and remote authorization language.

Do not combine all modes into one marathon. Use a fresh session and report for each.

### 0.6 Evidence rules

For every finding, collect the minimum evidence needed to make it independently actionable:

- screenshot at the moment of failure or confusion;
- a short screen recording for timing, animation, keyboard, resizing, or mis-tap issues;
- exact starting state and numbered reproduction steps;
- observed result and expected result;
- whether the issue reproduces after a clean reset;
- device, orientation, window size/shell, and input method;
- relevant logs only when they illuminate the visible result.

Never use only a screenshot filename such as `IMG_1234`. Give evidence a stable issue-oriented
name, for example:

```text
ONB-014-iphone-landscape-keyboard-covers-save.png
ONB-021-stage-manager-shell-flicker.mov
ONB-033-nearby-denial-no-recovery.log
```

### 0.7 Finding classification

Use user impact, not code complexity:

| Severity | Meaning |
| --- | --- |
| **S0 — release blocker** | Data loss, credential/private-key exposure, unsafe trust decision, or critical security boundary failure. |
| **S1 — critical journey blocked** | A normal new user cannot complete setup, add/connect to a host, or recover from a common failure. |
| **S2 — major UX defect** | The journey completes only with confusion, hidden actions, repeated attempts, severe clipping, or a misleading state. |
| **S3 — polish/accessibility defect** | Noticeable visual, copy, animation, hit-target, focus, or accessibility problem that does not block completion. |
| **Observation** | Friction or design question worth review, but evidence is insufficient to call it a defect. |

Also label confidence as **high**, **medium**, or **low**. Lower confidence rather than
inventing intent.

### 0.8 Finding template

```markdown
### ONB-___ — concise user-visible title

- **Severity:** S_
- **Confidence:** high / medium / low
- **Mission / persona:**
- **Environment:**
- **Starting state:**
- **Frequency:** _ / _ attempts
- **User impact:**

#### Reproduction
1.
2.
3.

#### Observed
What was visibly shown or what interaction occurred.

#### Expected
The relevant expected behavior from this guide, or the UX principle violated.

#### Evidence
- Screenshot:
- Recording:
- Logs:

#### Notes
- First moment of hesitation:
- Workaround discovered:
- Scope already checked:
- Existing automated coverage:
- Suggested regression test:
```

For a purely subjective observation, replace **Expected** with **Why this may be confusing**
and do not overstate it as a confirmed bug.

### 0.9 End-of-mission summary

Finish every mission with:

```markdown
## Mission result

- Critical path completed: yes / no
- Findings: S0 _ · S1 _ · S2 _ · S3 _ · observations _
- First blocker:
- Highest-friction moment:
- Strongest visual defect:
- Most important recovery defect:
- Areas not tested:
- Recommended next mission:
```

Then provide a compact journey timeline. Include successful steps as well as failures so the
report shows where coverage actually reached.

### 0.10 Rules that prevent false confidence

- A successful tap does not prove a good hit target.
- Presence in the accessibility tree does not prove visual discoverability.
- Matching text does not prove understandable copy.
- A stable screenshot does not prove stable animation or resizing.
- One successful run does not prove cancel, retry, relaunch, and interruption behavior.
- Simulator success does not prove Face ID, Secure Enclave, Local Network permission, or
  Handoff behavior on physical devices.
- Existing automated coverage changes the depth of functional re-testing, but never exempts
  the visible UX from review.

---
## 1. Prepare the Codex Desktop QA environment

### 1.1 What this guide describes (post-merge behavior)

The current branch carries an unmerged 4-PR stack. This guide describes the **intended
post-merge behavior**, which the stack implements:

1. Portrait iPad: the sidebar launches **expanded**, and the floating reveal button works in
   portrait (previously a no-op there).
   <!-- src: Tessera/ContentView.swift (sidebarVisible Bool + comment documenting the iPadOS 26 `.automatic == .detailOnly` portrait no-op bug) -->
2. All small controls have >=44 pt-ish hit frames (sidebar title-bar buttons, compact
   session-bar buttons, host-row edit buttons).
   <!-- src: Tessera/SessionSidebar.swift (SidebarIconButton), Tessera/SessionView.swift (compactIconButton) -->
3. iPhone idiom **always** uses the compact shell in both orientations — including Pro/Plus
   Max landscape, where the size class goes regular.
   <!-- src: Tessera/Design/DesignTokens.swift (CompactLayout.isPhone) -->
4. Compact iPad windows (Split View / Slide Over) take phone layouts on Keys, Settings,
   Hosts, and Known Hosts, and modals compress to full width instead of clipping.
   <!-- src: Tessera/Keys/KeysPageView.swift, Tessera/Settings/SettingsPageView.swift, Tessera/KnownHosts/KnownHostsPageView.swift, Tessera/Keys/GenerateKeyModal.swift -->

If a step in this guide fails on `main` but passes on the stack, that is expected until the
stack merges.

### 1.2 Test environments

- **Simulators:** iOS 26 runtime. The automated lanes use an iPad Pro 13-inch (M4) and an
  iPhone 17 Pro; any iOS 26 iPad + iPhone pair works for manual testing.
  <!-- src: scripts/integration/ensure-test-simulator.sh, scripts/integration/run-bootstrap-network-harness-tests.sh -->
- **Device coverage for the matrix (§2):** at least one non-Max iPhone, one iPhone Pro/Plus
  Max (for the regular-size-class landscape row M3), one iPad, and — for the 50/50 Split
  View row M7 — note that 13-inch iPads may keep regular width where smaller iPads go
  compact.
- **Physical devices are required** for: Face ID / Secure Enclave key behavior, the Local
  Network permission prompt in Nearby Setup, real cross-device Handoff, and anything the
  Simulator intercepts (dictation, some hardware-keyboard chords).
  <!-- src: scripts/integration/README.md ("Intentionally manual") -->
- Bundle id: `com.bambouville.TesseraApp`.
  <!-- src: scripts/integration/run-bootstrap-network-harness-tests.sh -->

### 1.3 Resetting to fresh-install state

Two first-open markers persist in `UserDefaults.standard`:

| Key | Set by |
| --- | --- |
| `tessera.nearbyBootstrap.completed.v1` | "set up as new", or a **finished** Nearby Setup import. Cancel never sets it. |
| `tessera.pref.hasSeenWelcome` | Finishing/skipping the walkthrough, or **any** dismissal of the Nearby Setup presentation (including cancel). |

<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift (BootstrapFirstOpenStore), Tessera/Design/AppearancePreferences.swift ("tessera.pref.hasSeenWelcome"), Tessera/ContentView.swift (onChange(of: bootstrapCoordinator.isPresented)) -->

- **Full reset (preferred):** uninstall the app —
  `xcrun simctl uninstall booted com.bambouville.TesseraApp` (or delete it from the Home
  Screen). This clears the completion marker, import provenance, and the SwiftData store.
  <!-- src: first-open chapter hook table; Tessera/Bootstrap/BootstrapManifestAdapter.swift (BootstrapImportProvenanceStore) -->
- **Partial reset (keep hosts/keys):** delete only the two defaults keys:

  ```sh
  xcrun simctl spawn booted defaults delete com.bambouville.TesseraApp tessera.nearbyBootstrap.completed.v1
  xcrun simctl spawn booted defaults delete com.bambouville.TesseraApp tessera.pref.hasSeenWelcome
  ```

  Caveat: with saved hosts still present, Nearby Setup will **not** re-present (its gate
  also requires zero hosts or an interrupted import — see §3), and the walkthrough welcome
  card will not auto-run (it requires zero hosts). Use the full reset when testing the
  first-open surfaces themselves. Note: this hosts-present / markers-unset state is
  byte-for-byte the shape of an upgraded pre-gate install — §3.11 uses it deliberately.
  Keychain items survive both resets on device; reinstalling on the Simulator clears them
  with the app container.
  <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift (beginIfFirstOpen guards), Tessera/Onboarding/OnboardingController.swift (beginIfFirstLaunch) -->

### 1.4 Skip hooks and DEBUG/test hooks

| Hook | Kind | Effect |
| --- | --- | --- |
| `-tessera.nearbyBootstrap.completed.v1 YES` `-tessera.pref.hasSeenWelcome YES` | Launch arguments (UserDefaults argument domain) | Pre-complete first-open so neither Nearby Setup nor the walkthrough covers the app. Used by nearly every flow outside §3/§4. |
| `TESSERA_FORCE_TOUR_STEP=<0-7>` | Env, DEBUG builds | Forces the walkthrough to that step on appear and suppresses the Nearby Setup presentation. Zero-based (`0` renders "STEP 1 OF 8"). |
| `TESSERA_CONTINUITY_HOSTKEY_HARNESS=match\|mismatch` | Env, DEBUG builds | Presents the real informed-TOFU host-key sheet (peer-fingerprint panel variants) with **no SSH session at all** — safe screenshotting of §6.9 variants. |
| `TESSERA_BOOTSTRAP_NETWORK_HARNESS=origin\|recipient` | Env, DEBUG builds | Replaces the production root with the automated two-process Bonjour harness (in-memory store, auto-approving biometrics). **Automation only** — do not use for manual UI testing. |
| `scripts/integration/fixture.env` | File | Real SSH fixture hosts for every connection flow — see §1.5. |

<!-- src: Tessera/ContentView.swift (prepareBootstrapFlow TESSERA_FORCE_TOUR_STEP guard, maybeBeginOnboarding DEBUG block, presentContinuityHostKeyHarnessIfNeeded), Tessera/Bootstrap/BootstrapNetworkHarness.swift (environmentKey), Tessera/TesseraApp.swift (DEBUG harness root) -->

To pass launch arguments / env on the Simulator: use the scheme's Run arguments in Xcode, or
`xcrun simctl launch booted com.bambouville.TesseraApp -tessera.nearbyBootstrap.completed.v1 YES ...`
(env vars via `SIMCTL_CHILD_` prefix).
<!-- src: scripts/integration/visual-cases/o1-onboarding-tour.sh (SIMCTL_CHILD_TESSERA_FORCE_TOUR_STEP usage) -->

### 1.5 Real SSH fixture hosts (`fixture.env`)

Every connection flow needs a reachable SSH server. Provision the integration fixtures once
and reuse them for manual testing:

```sh
cp scripts/integration/fixture.env.example scripts/integration/fixture.env  # fill in droplets
./scripts/integration/provision-fixtures.sh
./scripts/integration/verify-fixtures.sh
```

- App-facing endpoint: user `tessera` on port `2222` of the stable fixture host
  (`TESSERA_FIXTURE_STABLE_HOST`, `TESSERA_FIXTURE_APP_PORT=2222`,
  `TESSERA_FIXTURE_USER=tessera`, password auth).
- A second restricted user `tessera-notmux` (`TESSERA_FIXTURE_NOTMUX_USER`) has **no tmux**
  — used for the no-tmux fallback flows (§6.12, §7.4).
- Generated passwords/keys land under the gitignored `.state/`.
- The two fixtures run tmux 3.4 (stable) and 3.6a (chaos); the chaos host is also the
  re-keying target for the changed-host-key flow (§6.10).

<!-- src: scripts/integration/fixture.env.example, scripts/integration/README.md, scripts/integration/verify-fixtures.sh -->

### 1.6 Two-device staging for Nearby Setup pairing

Bonjour works between two simulators on the same Mac (the automated lane relies on it).
Manual staging:

```sh
# 1. Create + boot two simulators (any iOS 26 iPad + iPhone pair works)
ORIGIN=$(xcrun simctl create "BS Origin" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB com.apple.CoreSimulator.SimRuntime.iOS-26-0)
RECIP=$(xcrun simctl create "BS Recipient" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-0)
xcrun simctl boot "$ORIGIN"; xcrun simctl boot "$RECIP"

# 2. Install the same Tessera.app build on both, then launch both.
xcrun simctl install "$ORIGIN" path/to/Tessera.app
xcrun simctl install "$RECIP"  path/to/Tessera.app
```

Prepare the **origin** as an existing device: complete first-open ("set up as new"), add at
least one host with a key-based identity (fixture hosts from §1.5 if you want key installs
to succeed). Leave the **recipient** fresh-installed so the Nearby Setup welcome presents.
Both apps must stay foregrounded on their setup screens — backgrounding either side cancels
its attempt (see §3.6). On physical devices, expect the iOS **Local Network permission**
prompt; its timing and the denial/recovery script are §3.10 (manual-only — no lane covers
it).

<!-- src: scripts/integration/run-bootstrap-network-harness-tests.sh (two-simulator creation pattern, device types, bundle id) -->
<!-- src: Tessera/TesseraApp.swift (scenePhase .background -> bootstrapCoordinator.stopForBackground()) -->
<!-- src: scripts/integration/README.md (Local Network permission listed as intentionally manual) -->

### 1.7 How Codex Desktop should use existing automation

Every flow ends with an **Automated coverage** line. Treat it as diagnostic context:

- If automation proves the protocol or state transition, do not spend the session manually
  re-proving every permutation. Execute one representative path and concentrate on what the
  automation cannot judge: hierarchy, clarity, feedback, timing, hit comfort, animation,
  keyboard behavior, and recovery language.
- If a flow is marked **manual only**, execute its critical path completely and include at
  least one interruption or failure variant.
- A visual lane does not eliminate Desktop review. Static captures can miss animation,
  focus, keyboard, resize, stale-frame, and human-comprehension problems.
- When Desktop finds a defect in an automated path, state why the current test passed. Common
  reasons include checking existence instead of placement, waiting for a terminal state but
  not judging intermediate feedback, or using an accessibility action that bypasses actual
  touch difficulty.
- Do not modify or weaken an expected result merely because the present build behaves
  differently. Record the mismatch and identify whether the guide is stale only during the
  diagnostic pass.

The appendix (§9) is the coverage map. Use it after an issue is found to choose a regression
test; do not read it first if doing so would reveal implementation details that bias the
black-box pass.
### 1.8 Terminology

| Term | Meaning |
| --- | --- |
| **Nearby Setup** | The first-open "Bring your setup with you" full-screen flow, including the two-device transfer. Code and test names call it "bootstrap" (`BootstrapCoordinator`, `BootstrapFlowView`). |
| **walkthrough** | The iPad-only 8-step guided tour opened by the "welcome to Tessera" card. Code calls it "onboarding"/"tour" (`OnboardingController`); Settings labels it "replay walkthrough". |
| **compact shell** | The four-tab `TabView` navigation: "hosts", "sessions", "keys", "settings". |
| **sidebar shell** | The iPad regular-width shell: a floating 240 pt `SessionSidebar` over a full-frame detail pane. |
| **phone layout** | A page's compact rendering, used whenever `CompactLayout.isPhone(horizontalSizeClass)` is true: iPhone idiom in ANY orientation, or an iPad window whose horizontal size class is compact. |
| **TOFU** | Trust-on-first-use — the "Unknown Host" host-key sheet on first connection (§6.9). |
| **fixture hosts** | The two disposable Linux VPSes from §1.5. |

<!-- src: Tessera/Design/DesignTokens.swift (CompactLayout.isPhone), Tessera/ContentView.swift (compactNavigationShell), Tessera/SessionSidebar.swift -->

---

## 2. Master device / orientation / window matrix

### 2.1 The one rule that decides everything

```swift
// Tessera/Design/DesignTokens.swift
enum CompactLayout {
    static func isPhone(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone
            || horizontalSizeClass == .compact
    }
}
```

`ContentView.contentShell` branches on exactly this predicate:

- `isPhone == true` → **compact shell** (`compactNavigationShell`): a `TabView` with four
  root tabs labeled `hosts` (`server.rack`), `sessions` (`rectangle.stack.fill`), `keys`
  (`key.fill`), `settings` (`gearshape.fill`). The `keys` tab carries a two-way selector
  between "keys" and "known hosts" (`CompactViewSelector`). Live sessions and the host editor
  render as a full-screen overlay above the tab bar (opacity-swapped, never unmounted).
  <!-- src: Tessera/ContentView.swift lines 307-408 (compactNavigationShell, tabItem labels), 3900-3915 (CompactRootTab/CompactSessionsView/CompactKeysView) -->
- `isPhone == false` → **sidebar shell**: a custom `ZStack` (not `NavigationSplitView`)
  with a floating 240 pt `SessionSidebar` above a full-frame detail pane. Sidebar visibility is
  a plain `@State private var sidebarVisible = true` — it **launches expanded** in both
  orientations. <!-- src: Tessera/ContentView.swift lines 108-113, 193-250; Tessera/SessionSidebar.swift line 10 (static let width: CGFloat = 240) -->

Consequences testers must internalize:

1. **iPhone idiom always gets the compact shell, in both orientations** — including iPhone
   Pro Max landscape, whose horizontal size class is regular. The idiom check wins.
   <!-- src: Tessera/Design/DesignTokens.swift lines 6-16 (doc comment: "iPhone idiom always presents the compact phone experience, even where the size class goes regular (Pro Max landscape)") -->
2. **iPad follows the size class**, so a compact-width iPad window (Split View narrow pane,
   Slide Over) presents the *entire* compact shell, and each routed page inside it renders
   its phone layout (each page re-checks `CompactLayout.isPhone` itself).
3. Pages that route to phone layouts under compact width: **Hosts landing**
   (`HostsLandingView`), **Keys** (`KeysPageView` — single-pane `phoneContent` instead of the
   two-pane list+detail), **Settings** (`SettingsPageView` — `NavigationStack` drill-down list
   instead of the two-pane layout; the "themes" gallery section is omitted on phone), **Known
   Hosts** (`KnownHostsPageView`), plus the host editor (`HostDetailView`).
   <!-- src: Tessera/Hosts/HostsLandingView.swift lines 21-35; Tessera/Keys/KeysPageView.swift lines 43-84, 182-195; Tessera/Settings/SettingsPageView.swift lines 15-91 (phoneBody, phoneSections filter excludes .themes); Tessera/KnownHosts/KnownHostsPageView.swift lines 13-14; Tessera/HostDetailView.swift lines 20, 67 -->
4. **Modals compress instead of clipping**: key modals switch from fixed max widths to
   `.infinity` and tighter padding when compact — `GenerateKeyModal` 480 → full width,
   `ImportKeyModal` 520 → full width, and the in-page key modals (500 / 560 / 620 / 560 pt)
   likewise; padding drops 28 → 18.
   <!-- src: Tessera/Keys/GenerateKeyModal.swift lines 89-91; Tessera/Keys/ImportKeyModal.swift lines 114-116; Tessera/Keys/KeysPageView.swift lines 1871-1873, 2004-2006, 2109-2111, 2172-2174 -->

### 2.2 The matrix (referenced by all chapters)

Shell is decided by **idiom + horizontal size class**, never by orientation directly. Size-class
assignments for Split View fractions are made by iPadOS and vary by iPad model — verify the
actual size class per row by which shell appears (the shell itself is the oracle). Stage
Manager windows resize continuously, so rows M11/M12 have no fixed fraction at all: the same
oracle applies, and the compact↔regular crossing can happen mid-drag (§8.6 Flow F).

| # | Device | Window mode | Orientation | H. size class | Shell | Status bar | Notes |
|---|--------|-------------|-------------|---------------|-------|-----------|-------|
| M1 | iPhone (any, e.g. 17 Pro) | Full screen | Portrait | compact | Compact shell | Visible on tabs; hidden in session | Baseline phone |
| M2 | iPhone (any non-Max) | Full screen | Landscape | compact | Compact shell | Visible on tabs; hidden in session | Same shell as M1 |
| M3 | iPhone Pro/Plus Max | Full screen | Landscape | **regular** | **Compact shell** | Visible on tabs; hidden in session | Idiom overrides size class — must NOT show sidebar shell |
| M4 | iPad (any) | Full screen | Portrait | regular | Sidebar shell, **sidebar expanded at launch** | Always hidden | Reveal button must work (post-fix) |
| M5 | iPad (any) | Full screen | Landscape | regular | Sidebar shell, sidebar expanded at launch | Always hidden | |
| M6 | iPad | Split View, wide pane (≈2/3) | Landscape | regular (typical) | Sidebar shell | System-managed | iPad layouts persist; walkthrough mounts here (§4.4) |
| M7 | iPad | Split View, 50/50 | Landscape | model-dependent | Follows size class | System-managed | 13" iPads may stay regular; smaller iPads go compact — record which per test device |
| M8 | iPad | Split View, narrow pane (≈1/3) | Either | compact | Compact shell + phone page layouts | System-managed | Modals go full-width |
| M9 | iPad | Split View, any split | Portrait | compact (typical) | Compact shell + phone page layouts | System-managed | |
| M10 | iPad | Slide Over | Either | compact (always) | Compact shell + phone page layouts | System-managed | |
| M11 | iPad, Stage Manager on | Stage Manager window, large | Either | regular (typical) | Sidebar shell | System-managed | Arbitrary continuous sizes; verify by shell, not points (§8.6 Flow F) |
| M12 | iPad, Stage Manager on | Stage Manager window, narrow | Either | compact | Compact shell + phone page layouts | System-managed | Same routing as M8/M10; live resize across the boundary is §8.6 Flow F |

Overlay layers that sit above whichever shell is active (identical across the matrix):
Nearby Setup first-open flow (`zIndex 110`, §3), enrollment approval (`zIndex 120`, §6.14),
continuity overlay (`zIndex 100`), command palette (`zIndex 50`), and — above absolutely
everything — the lock screen (`RootView`, `zIndex 10` in its own ZStack over `ContentView`).
<!-- src: Tessera/ContentView.swift lines 519-576 (presentedContent overlays), 922-931 (bootstrapFlowOverlay); Tessera/TesseraApp.swift lines 594-609 (mainContent lock overlay) -->

---
## 3. First open & Nearby Setup bootstrap

### Codex Desktop QA charter

**Primary mission:** determine whether a person with no Tessera context can choose between
setting up as new and inheriting a nearby device, understand what will and will not move,
complete pairing without losing trust in the process, and recover from denial, cancellation,
or interruption.

During Pass A:

- Start from a genuine fresh install. Do not use completion launch arguments.
- Let the visible copy teach the flow; do not jump ahead because this guide names the next
  screen.
- Record whether the relationship between origin and recipient is understandable before
  interacting with the second device.
- On every waiting screen, judge whether the user knows which device requires action.
- Treat code comparison, optional-data selection, biometrics, and host-grant receipts as
  security decisions: inspect hierarchy, default selections, consequences, and reassurance.
- For at least one run, deny or cancel at the most plausible human moment rather than at a
  predetermined protocol boundary.
- Capture both devices when a cross-device state appears inconsistent.

The highest-value findings are ambiguous device roles, unclear waiting states, accidental
approval risk, failure with no recovery path, missing explanation after Local Network denial,
and receipts that appear more successful than the actual host state.

This chapter covers the complete new-user first-open experience: the "Bring your setup with
you" welcome, the "set up as new" path, the two-device Nearby Setup transfer (recipient and
origin roles), failure/cancel semantics per phase, and interrupted-import recovery — plus
the flows that revisit first-open later: origin-side transfer interruption (§3.8), the
Settings-initiated re-receive on a completed device (§3.9), the physical-device Local
Network permission (§3.10), and upgrade-in-place gating (§3.11).

<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift (phases, gating, cancel/finish/retry semantics) -->
<!-- src: Tessera/Bootstrap/BootstrapFlowView.swift (all screen states and UI copy) -->
<!-- src: Tessera/Bootstrap/BootstrapManifest.swift (wire allowlist, optional transfers) -->
<!-- src: Tessera/Bootstrap/BootstrapManifestAdapter.swift (import/export, provenance store) -->
<!-- src: Tessera/Bootstrap/NearbyTransferService.swift (Bonjour discovery/offering) -->
<!-- src: Tessera/Bootstrap/NearbyHandshake.swift (SAS format, commitment ordering) -->
<!-- src: Tessera/ContentView.swift (presentation wiring, hasSeenWelcome observer) -->
<!-- src: Tessera/TesseraApp.swift (background cancellation, DEBUG harness root) -->
<!-- src: Tessera/Settings/ContinuitySettingsView.swift (origin entry point) -->
<!-- src: Tessera/Enrollment/EnrollmentCoordinator.swift (DeviceEnrollmentKeyFactory / key policy) -->

### How presentation is gated (read before testing)

`BootstrapCoordinator.beginIfFirstOpen(hasHosts:)` presents the welcome only when **all** of
these hold (it is called from `ContentView` on appearance, so it re-evaluates every launch):

1. The flow is not already presented (`phase == .inactive`).
2. The device has **zero saved hosts**, *or* a previous nearby import was interrupted
   (`BootstrapImportProvenanceStore().hasInterruptedImport`).
3. The persisted completion marker `tessera.nearbyBootstrap.completed.v1` (bool in
   `UserDefaults.standard`) is **not** set. Only "set up as new" or a **finished** nearby
   import sets it. Cancel never sets it, so the welcome re-presents on every launch until one
   of those completes.

<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — BootstrapFirstOpenStore (key "tessera.nearbyBootstrap.completed.v1"), beginIfFirstOpen(hasHosts:), setUpAsNew(), finish() -->
<!-- src: Tessera/ContentView.swift — prepareBootstrapFlow(), maybeBeginOnboarding() -->

The flow renders as a full-screen overlay (`zIndex(110)`) above all app content, with a
single scrolling content column capped at 620pt width. While presented it suppresses the
walkthrough; when it dismisses **for any reason** (including cancel), an observer sets
`tessera.pref.hasSeenWelcome = true` so the walkthrough's welcome card never stacks on top
of it.

<!-- src: Tessera/ContentView.swift — bootstrapFlowOverlay, .onChange(of: bootstrapCoordinator.isPresented) -->
<!-- src: Tessera/Bootstrap/BootstrapFlowView.swift — .frame(maxWidth: 620), accessibilityIdentifier "bootstrap.flow" -->

**Setup for this chapter:** general hooks and resets are in §1.3–§1.4; two-device staging is
in §1.6. Chapter-specific notes:

- DEBUG builds do not seed demo hosts unless a `tessera-dev-key.raw` file was manually
  placed in the app's Documents directory — a clean install stays hostless, so gate 2
  passes. <!-- src: Tessera/TesseraApp.swift — seedDevStateIfNeeded logs "dev-seed skipped reason=missing-or-invalid" without the seed file -->
- Fixture hosts (§1.5) are needed on the **origin** if you want host-grant installation
  (`AUTHORIZED` receipts) to actually succeed; against unreachable hosts grants truthfully
  report `FAILED`. <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift (grant install over the origin's own SSH access) -->
- With DEBUG `TESSERA_FORCE_TOUR_STEP=<n>` set, `prepareBootstrapFlow()` returns before
  `beginIfFirstOpen`, so Nearby Setup never presents.
  <!-- src: Tessera/ContentView.swift — TESSERA_FORCE_TOUR_STEP guard in prepareBootstrapFlow() -->

---

### 3.1 Fresh-install first open: welcome presentation

**Preconditions:** Fresh install (no defaults, no hosts). Any device/orientation.

**Steps:**

1. Launch Tessera.
   -> Expected: a full-screen overlay appears above the app shell. Header reads
   "TESSERA · NEARBY SETUP" with a "cancel" button at the trailing edge. Title:
   "Bring your setup with you"; subtitle: "Copy hosts, jump routes, port forwards, and
   portable appearance settings from a nearby iPhone or iPad. The sending device separately
   chooses whether sensitive host text and trusted host keys move. Passwords and private
   keys never move."
2. Inspect the three choices.
   -> Expected: (a) a card labeled "INHERIT FROM NEARBY" with text "You’ll compare a
   six-digit code on both devices before the origin can approve the transfer." (typographic
   apostrophe, as in the source) and a
   primary "find nearby devices" button; (b) a dimmed "restore from iCloud" row with
   subtitle "encrypted cloud restore · coming later" and an "UNAVAILABLE" tag; (c) a
   "set up as new" button.
3. Tap "restore from iCloud".
   -> Expected: nothing happens; the row is disabled (accessibility label
   "Restore from iCloud, coming later").
4. Verify the walkthrough's welcome card did not appear underneath.
   -> Expected: no tour spotlight/coach marks; Nearby Setup owns the first-open surface.

<!-- src: Tessera/Bootstrap/BootstrapFlowView.swift — header, welcome, disabled iCloud button -->
<!-- src: Tessera/ContentView.swift — onboarding.phase = .inactive while isPresented -->

**Device/orientation variants:** None functional. The same overlay presents on iPhone (both
orientations — the compact shell stays beneath it), iPad full-screen, and compact iPad
windows (Split View/Slide Over). On widths above 620pt the content column is centered; in
iPhone landscape the column scrolls vertically. Rotation preserves the current phase (state
lives in the coordinator, not the view).

**Edge & failure cases:**

- Launch with `-tessera.nearbyBootstrap.completed.v1 YES`: welcome must NOT present.
- Add a host first (via a pre-completed install), then clear only the completion marker:
  welcome must NOT present (hosts exist and no interrupted import).
- DEBUG launch with `TESSERA_FORCE_TOUR_STEP=<n>`: Nearby Setup must NOT present; the forced
  walkthrough step shows instead.

**Automated coverage:**
`TesseraTests/BootstrapCoordinatorTests.test_constructingAndFirstOpenPresentationNeverStartsNetworkingOrCreatesKey`
verifies presentation is side-effect free (no networking, no key creation). Presentation
gating against real defaults/UI is **manual only**.

---

### 3.2 Cancel semantics and re-presentation on relaunch

**Preconditions:** Fresh install, welcome presented.

**Steps:**

1. Tap "cancel" in the header.
   -> Expected: the overlay dismisses to the normal (empty-hosts) app shell. No key is
   created, nothing persisted as complete.
2. Kill and relaunch the app.
   -> Expected: "Bring your setup with you" presents again — cancel does not mark
   first-open complete. It repeats on **every** launch until "set up as new" or a finished
   import.
3. Cancel again, then check the walkthrough.
   -> Expected: the walkthrough's welcome card does not auto-run in this session or any
   later one: dismissal set `tessera.pref.hasSeenWelcome = true` via the
   presentation-dismissed observer. (The walkthrough remains replayable from Settings —
   §4.3.)

<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — cancel() resets to .inactive without markComplete() -->
<!-- src: Tessera/ContentView.swift — onChange(isPresented): wasPresented && !isPresented -> appearance.hasSeenWelcome = true -->

**Device/orientation variants:** None.

**Edge & failure cases:**

- Background the app while the welcome is up: `stopForBackground()` cancels and dismisses
  the overlay. Relaunch re-presents it (still incomplete).
- Cancel is available in every phase **except** while the origin's biometric authorization
  sheet is up (`authorizingOrigin`) and during `transferring` — in those two phases the
  header has no cancel button.

<!-- src: Tessera/TesseraApp.swift — scenePhase == .background -> bootstrapCoordinator.stopForBackground() -->
<!-- src: Tessera/Bootstrap/BootstrapFlowView.swift — canCancel excludes .inactive, .authorizingOrigin, .transferring -->

**Automated coverage:**
`BootstrapCoordinatorTests.test_backgroundStopsBrowserAndClearsPresentation` covers the
background path at coordinator level. Relaunch re-presentation with real UserDefaults is
**manual only**.

---

### 3.3 "Set up as new"

**Preconditions:** Fresh install, welcome presented.

**Steps:**

1. Tap "set up as new".
   -> Expected: the overlay dismisses immediately to the empty app shell. No biometric
   prompt (this generates a key; it does not use one).
2. Open the Keys area.
   -> Expected: a stored key named "Tessera device key" exists. On a physical device it is
   Secure Enclave P-256 (biometric-gated for use); on the Simulator it is a software
   Ed25519 key (the Simulator has no Secure Enclave).
3. Kill and relaunch.
   -> Expected: welcome does NOT re-present — `tessera.nearbyBootstrap.completed.v1` is now
   set. (It was set only **after** the key provisioning succeeded.)

<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — setUpAsNew(): recipientKeyProvider() then interruptedImportAbandoner() then firstOpenStore.markComplete() -->
<!-- src: Tessera/Enrollment/EnrollmentCoordinator.swift — DeviceEnrollmentKeyPolicy (simulator: software Ed25519; device: Secure Enclave P-256), DeviceEnrollmentKeyFactory.storedKey name "Tessera device key" -->

Note: this is the **same** key provider used by nearby inheritance, so both first-open
choices create/reuse one device key with identical integrity checks. Any interrupted-import
provenance is also cleared by this choice.

**Device/orientation variants:** None. Simulator vs device differs only in the key type
described above (a grant-selection screen on a peer would later show the warning
"Software-backed simulator key. It is not protected by Secure Enclave; grant access only to
test hosts you intend this simulator to use." for a simulator recipient).

**Edge & failure cases:**

- If key provisioning fails, the flow shows the failure screen ("Nearby setup stopped") and
  first-open is NOT marked complete; "start again" returns to the welcome (no attempt
  intent to retry). Verify by relaunching — the welcome presents again.

<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — setUpAsNew() catch -> fail(); retry() case nil -> phase = .welcome -->

**Automated coverage:**
`BootstrapCoordinatorTests.test_setUpAsNewProvisionsDeviceKeyBeforeMarkingFirstOpenComplete`
and `test_setUpAsNewKeyFailureIsTruthfulAndDoesNotCompleteFirstOpen`. Keys-list
verification and device Secure Enclave behavior are **manual only**.

---

### 3.4 Nearby Setup pairing — full transfer (both roles)

Steps tagged **[R]** run on the recipient (fresh device), **[O]** on the origin (existing
device). Stage the devices per §1.6.

**Preconditions:** Recipient: fresh install, welcome presented. Origin: first-open
completed, at least one host saved; for `AUTHORIZED` grant receipts the host must use a
key-based identity whose whole jump route is connectable with stored keys, and be reachable
(fixture hosts). Both apps foregrounded.
<!-- src: Tessera/Bootstrap/BootstrapManifestAdapter.swift — export(): authenticationHint == .publicKey only when the route is restorable with stored keys -->

**Steps:**

1. **[R]** Tap "find nearby devices".
   -> Expected: title "Choose your other device", subtitle "On that device, open
   Settings → Continuity and tap “send setup to nearby device.”" With no peer yet, a
   progress card "Looking nearby" — "No devices found yet. Both devices must keep Tessera
   open on the setup screen."
2. **[O]** Open Settings → Continuity ("sync & continuity"), section "NEARBY SETUP", tap
   "send setup to nearby device".
   -> Expected: origin shows the same overlay chrome with progress "Waiting for your other
   device" — "Keep this screen open. Tessera is visible only while this setup flow is in
   the foreground."
3. **[R]** Wait ~1–5 s for Bonjour discovery.
   -> Expected: a row appears with the origin's device name, a pulsing green dot, and
   caption "tap to connect · name is not trusted".
4. **[R]** Tap the peer row.
   -> Expected: recipient shows "Opening an encrypted channel" — "Connecting to <name>.
   Device names are labels only; the code on the next screen verifies the channel." The
   origin transitions off "Waiting..." when the connection arrives.
5. **[R] + [O]** Both devices reach the code screen.
   -> Expected: both show "Compare this code" with a large six-digit code formatted
   `NNN NNN`, subtitle "Confirm only if the same code is visible on <peer>. A mismatch ends
   this attempt and creates fresh encryption keys next time.", and buttons "codes match" /
   "codes don’t match". **The two codes must be identical.**
6. **[R]** Tap "codes match".
   -> Expected: recipient shows "Approve on the other device" — "Code <NNN NNN> matched.
   <peer> must approve before any setup data can be sent." (The recipient's device key is
   created/reused at this moment and sent to the origin.)
7. **[O]** Tap "codes match".
   -> Expected: origin briefly shows "Waiting for the device key" — "Code <NNN NNN>
   matched. Waiting for <peer> to create or reuse its device public key." — then the grant
   selection screen "Choose what to copy".
8. **[O]** Review the grant selection screen.
   -> Expected, top to bottom:
   - Subtitle "Code <NNN NNN> matched. Optional host text and trust start off. Review this
     exact setup transfer and where to install <recipient key name>."
   - Card "RECIPIENT PUBLIC KEY" showing the recipient key's fingerprint. If the recipient
     is a Simulator, an amber warning: "Software-backed simulator key. It is not protected
     by Secure Enclave; grant access only to test hosts you intend this simulator to use."
   - "OPTIONAL HOST DATA · OFF BY DEFAULT" — five checkboxes, **all unchecked** on every
     fresh attempt: "launch commands" ("Custom shell commands. These may contain secrets."),
     "notes", "environment variables" ("Environment variables. These commonly contain
     tokens or credentials."), "startup snippets", "trusted host keys" ("The receiving
     device will trust the same server keys without prompting again. Existing conflicts are
     preserved for review.").
   - "HOST GRANTS" — one row per exported host. Key-authenticated hosts are pre-checked and
     toggleable ("Install the other device's public key using this device's existing
     access."). Password hosts show a disabled minus checkbox with "Excluded. Passwords
     never transfer and will be requested on first connect."; credential-less hosts show
     "Excluded because this device has no reusable authenticated path."
   - A summary card: "hosts, jump routes, port forwards, and portable appearance" / "N
     optional data categories selected" / "no passwords or private keys move" / "N
     public-key grants selected".
   - Button "approve selected batch" and footer "Sending to <peer>. Its displayed name is
     never used as a security decision."
9. **[O]** Optionally toggle host grants and optional-data categories, then tap
   "approve selected batch".
   -> Expected: phase "Confirm on this device" — "Authorizing <peer> with code <NNN NNN>."
   and **one** system biometric prompt with reason "Approve setup and N host key grant(s)
   with code <NNN NNN>". Exactly one prompt regardless of how many hosts are selected.
   (Simulator: use Features → Face ID → Matching Face, with enrollment on.)
10. **[O]** Authenticate.
    -> Expected: origin shows "Sending setup" — "Sending the approved, encrypted manifest
    to <peer>." Recipient switches to "Importing setup" — "Verifying and importing the
    approved manifest from <peer>." During transfer neither side shows a cancel button.
    The origin then installs the recipient's public key on each selected, accepted host
    over its own SSH access.
11. **[R]** Wait for completion.
    -> Expected: "Setup inherited" — "Imported N host(s), M jump route(s), and K trusted
    host key(s)." (K is 0 unless the origin selected "trusted host keys"). Below, "HOST
    ACCESS RECEIPT" — "This is the acknowledged result for every host. Failed, skipped, and
    credential-ineligible hosts are never reported as authorized." — one card per host with
    status label `AUTHORIZED` (green, "The recipient device key was installed and recorded
    on both devices."), `FAILED`, `NOT SELECTED`, `NOT IMPORTED`, or `EXCLUDED`
    ("Passwords and unavailable credentials cannot be reused for a bootstrap grant.").
    Non-authorized rows offer a "configure later" button. A "done" button ends the flow.
12. **[O]** Observe the origin's receipt.
    -> Expected: "Setup sent" — "N host(s) sent securely. Credentials remain local to each
    device." plus the same per-host receipt list, then "done".
13. **[R]** Tap "configure later" on any non-authorized row (before "done"), or tap "done".
    -> Expected: "configure later" dismisses the flow and navigates to that host's detail
    (Hosts tab on the compact shell). "done" dismisses to the app shell with the imported
    hosts listed; imported appearance/settings (theme, accent, font size, scrollback…) are
    applied.
14. **[R]** Kill and relaunch.
    -> Expected: welcome does NOT re-present — the finished import marked
    `tessera.nearbyBootstrap.completed.v1` complete (this happened at transfer completion,
    so even cancel from the receipt screen cannot lose it).

<!-- src: Tessera/Bootstrap/BootstrapFlowView.swift — browser, codeComparison, originApproval, progress, receiptView copy -->
<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — confirmCodeMatches(), approveOriginTransfer() single biometric batch, sendRecipientKeyAndWait() markComplete before .completed -->
<!-- src: Tessera/Bootstrap/NearbyHandshake.swift — NearbyShortAuthenticationString.displayValue "NNN NNN" -->
<!-- src: Tessera/Settings/ContinuitySettingsView.swift — "send setup to nearby device", "receive setup from nearby device" -->
<!-- src: Tessera/ContentView.swift — configureBootstrapHost(): finish, compactTab = .hosts, selectedItem = .host(id) -->

**What moves / what never moves (spot-check on the recipient):**

| Always (when accepted) | Opt-in only (origin checkboxes, off by default) | Never on the wire |
| --- | --- | --- |
| Hosts: name, address, port, user, transport, launch mode, tmux session name, tags, OS hint, sort order; port-forward rules; jump chains; identity **names/users** (credential-less); portable appearance (scheme, accent, font, cursor, theme); general settings (scrollback, modifier behavior, bells, accessory bar keys, files reaper/destination) | launch commands, notes, environment variables, startup snippets, trusted host keys (known-host pins + per-host fingerprints) | Passwords, private keys, key handles/Keychain references, credential modes, security policy (Face ID lock, biometric-for-keys), session-restore state, background images, `hasSeenWelcome` |

The wire schema rejects unknown fields outright, and imported identities arrive with
`credentialMode: .none`. Verify on the recipient: imported hosts have no password stored
and no private key material; connecting to a password host prompts for the password.

<!-- src: Tessera/Bootstrap/BootstrapManifest.swift — BootstrapSyncClassification, selectingOptionalTransfers, rejectUnknownFields -->
<!-- src: Tessera/Bootstrap/BootstrapManifestAdapter.swift — Identity(credentialMode: .none) on import -->

**Device/orientation variants:** None in the flow itself — any iPhone/iPad mix works and
either idiom can be origin or recipient. The grant-selection and receipt screens are the
longest; on iPhone landscape and Slide Over they scroll. The software-key warning appears
exactly when the **recipient** is a Simulator.

**Edge & failure cases:** see §3.5–§3.8.

**Automated coverage:** the real two-simulator Bonjour path (discovery, encrypted
handshake, SAS equality on both sides, manifest transfer, grant + receipt + final
acknowledgement) is covered by the `app_nearby_bootstrap_two_sim` case in
`scripts/integration/run-programmatic-tests.sh`, implemented by
`scripts/integration/run-bootstrap-network-harness-tests.sh`. Protocol/coordinator logic:
`BootstrapCoordinatorTests` (`test_selectedHostsOnlyAndSingleBiometricBatchAfterBothSASConfirmations`,
`test_optionalHostDataDefaultsOffOnTheEncryptedWire`,
`test_senderCanIndividuallyOptIntoEveryOptionalHostDataCategory`,
`test_sameFlowWorksWhenIPhoneAndIPadSwapOriginRoles`,
`test_softwareKeyProtectionSurvivesIntoOriginGrantSelection`), plus
`BootstrapManifestTests`, `BootstrapManifestAdapterTests`, `BootstrapNearbyHandshakeTests`,
`BootstrapNearbyTransferServiceTests`. Manual testers should therefore spot-check **UI copy,
biometric prompt UX, SwiftData persistence, and navigation** rather than re-proving the
protocol.

---

### 3.5 SAS code rejection ("codes don’t match")

**Preconditions:** Two devices paired up to the "Compare this code" screen.

**Steps:**

1. On either device, tap "codes don’t match".
   -> Expected: that device shows the failure screen "Nearby setup stopped" with message
   "The codes did not match; start a fresh transfer." and the reassurance card: "Setup was
   not marked complete. Any encrypted channel is closed, and any host grant is recorded
   only after its remote installation succeeds; retrying nearby transfer creates fresh
   ephemeral keys and a new comparison code."
2. Observe the other device.
   -> Expected: it fails at its next protocol step with a connection-closed style message
   (e.g. "The nearby connection closed.") — it does not hang forever on the code screen if
   it had already confirmed; if it had not confirmed yet, it fails upon its next action.
3. Tap "start again" on the recipient.
   -> Expected: browsing restarts ("Choose your other device"). Re-pair with the origin
   ("start again" there restarts offering with the same display name).
   -> Expected: the new attempt shows a **different** six-digit code (fresh ephemeral keys).

<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — rejectCode() -> confirmSAS(matches:false) throws sasMismatch -> fail; retry() re-runs startRecipientDiscovery / startOffering(displayName:) -->
<!-- src: Tessera/Bootstrap/NearbyHandshake.swift — "The codes did not match; start a fresh transfer." -->
<!-- src: Tessera/Bootstrap/BootstrapFlowView.swift — failure() copy, "start again", "close" -->

**Device/orientation variants:** None.

**Edge & failure cases:** "close" instead of "start again" dismisses; on a fresh recipient
the welcome re-presents next launch (nothing was completed).

**Automated coverage:**
`BootstrapCoordinatorTests.test_recipientFailureRetryRestartsBrowsing`,
`test_originFailureRetryRestartsOfferingWithSameDisplayName`,
`test_nonTransferFailureRetryReturnsToFirstOpenChoice`;
`BootstrapNearbyHandshakeTests` for SAS mismatch mechanics. Cross-device UX is
**manual only**.

---

### 3.6 Per-phase cancel / background / failure matrix

Test each row by driving the pairing flow to that phase, then performing the interruption.
In every case the flow must end on either dismissal or the "Nearby setup stopped" screen —
never a hang — and first-open must remain incomplete on a fresh recipient (relaunch
re-presents the welcome), except where noted.

| Phase (screen) | cancel button? | Cancel/background result | Peer's view |
| --- | --- | --- | --- |
| welcome | yes | dismisses; re-presents next launch | n/a |
| browsing ("Choose your other device") | yes | discovery stops; dismisses | origin keeps "Waiting for your other device" |
| offering ("Waiting for your other device") | yes | listener stops; dismisses; origin device disappears from recipient's peer list | recipient row vanishes / connect fails "The nearby peer is no longer available." |
| negotiating ("Opening an encrypted channel") | yes | connection cancelled; dismisses | peer fails: "The nearby connection closed." |
| compareCode ("Compare this code") | yes | same as above | peer fails on next receive |
| awaitingRecipientPublicKey / waitingForOriginApproval | yes | same as above | peer fails: "The nearby connection closed." |
| selectingGrants ("Choose what to copy") | yes | origin cancels; **no manifest was sent, no grant installed** | recipient fails out of "Approve on the other device" |
| authorizingOrigin (biometric up) | **no** | biometric cancel ("Cancel" on the Face ID sheet) fails the flow with "Nearby setup was not approved."; no manifest is sent | recipient fails: "The nearby connection closed." |
| transferring ("Sending/Importing setup") | **no** | only backgrounding/kill interrupts; see §3.7 (recipient side) / §3.8 (origin side) | peer fails at next receive |
| completed (receipt) | yes | "done"/cancel both dismiss; a finished **received** transfer is already marked complete | independent |
| failed ("Nearby setup stopped") | yes | "close" dismisses, "start again" retries | independent |

Backgrounding **either** device in any active phase calls `stopForBackground()` → the whole
attempt cancels and the overlay dismisses on that device; the peer errors out as above.

<!-- src: Tessera/Bootstrap/BootstrapFlowView.swift — canCancel -->
<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — stopForBackground(), cancel(), approveOriginTransfer() cancelled decision -> "Nearby setup was not approved.", finish() -->
<!-- src: Tessera/Bootstrap/NearbyTransferService.swift — error strings "The nearby connection closed.", "The nearby peer is no longer available." -->

**Automated coverage:**
`BootstrapCoordinatorTests.test_cancelledOwnerAuthenticationSendsNoManifestAndInstallsNoGrant`,
`test_backgroundFromSelectionCancelsConnectionWithoutGrant`,
`test_backgroundStopsBrowserAndClearsPresentation`,
`test_partialFailureIsTruthfulAndAcknowledgedWithoutRecordingFailure`,
`test_recipientImportRejectionPreventsRemoteGrantAndCompletesTruthfully`,
`test_changedLiveHostIsRejectedBeforeBiometricOrInstaller`. On-screen failure copy and
peer-side UX are **manual only**.

---

### 3.7 Interrupted import recovery on next launch

An import is "interrupted" when the recipient durably applied the manifest (hosts saved,
provenance recorded) but the flow died before the final completion acknowledgement — so
first-open was never marked complete.

**Preconditions:** Two staged devices; drive the pairing flow through origin approval. The
easiest reliable interruption: on the **recipient**, watch for "Importing setup" to appear,
give it a beat to finish the local import (with an origin whose grant installs are slow or
failing against unreachable hosts, this window is generous), then kill the recipient app
from the app switcher (or `xcrun simctl terminate <udid> com.bambouville.TesseraApp`).

**Steps:**

1. Interrupt the recipient as described.
   -> Expected: the origin fails with a connection error ("Nearby setup stopped").
2. Relaunch the recipient.
   -> Expected: "Bring your setup with you" presents **even though hosts now exist** — the
   interrupted-import provenance re-opens the first-open gate.
3. Path A — retry the transfer: tap "find nearby devices" and re-pair with the same origin
   (fresh code; origin re-approves with one biometric).
   -> Expected: the receipt shows the previously imported, unchanged hosts as accepted
   without duplicating them ("Imported 0 hosts" if nothing else changed / "N identical
   trusted host keys were already present." lines as applicable); grants can now reach
   `AUTHORIZED`; the flow completes and marks first-open complete. Relaunch: no welcome.
4. Path B — abandon: tap "set up as new" instead.
   -> Expected: the provenance is cleared, first-open marks complete, the previously
   imported hosts remain usable, and the welcome never re-presents.

<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — beginIfFirstOpen guard (!hasHosts || interruptedImportProvider()), configure(): interruptedImportProvider = BootstrapImportProvenanceStore().hasInterruptedImport, setUpAsNew() -> interruptedImportAbandoner() -->
<!-- src: Tessera/Bootstrap/BootstrapManifestAdapter.swift — BootstrapImportProvenanceStore (key "tessera.bootstrapImportProvenance.v1"), reusableAcceptedHostIDs / acceptedHostIDs on re-import, markComplete removes the record -->

**Device/orientation variants:** None.

**Edge & failure cases:**

- If the tester killed the recipient **before** "Importing setup" finished the local save,
  no provenance exists; relaunch behaves like a plain cancelled attempt (welcome presents
  only because there are still zero hosts).
- Editing an imported host (address/port/user/route) between attempts invalidates its
  provenance match: the retry treats it as conflicting/existing rather than re-accepting
  it, and its grant reports `NOT IMPORTED` on the origin receipt.
- A host granted `.failed` on a prior attempt keeps an "uncertain" recipient-side install
  intent for recovery (visible as key-security metadata), by design.

<!-- src: Tessera/Bootstrap/BootstrapManifestAdapter.swift — matchesImportedConfiguration(), priorRouteIsIntact() -->
<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — comment: `.failed` is ambiguous; intent retained -->

**Automated coverage:**
`BootstrapCoordinatorTests.test_interruptedImportResumesFirstOpenEvenAfterHostsWerePersisted`
covers the gate; `BootstrapManifestAdapterTests` covers provenance matching/reuse. The
end-to-end kill/relaunch recovery on real devices is **manual only**.

---

### 3.8 Origin-side interruption during transfer

§3.7 interrupts the recipient; this flow interrupts the **origin** during "Sending setup" /
the post-transfer grant installs. The protocol ordering that decides every expectation: the
origin installs each selected grant sequentially, only THEN seals and sends the grant
receipt, and the recipient marks first-open complete only AFTER receiving that receipt and
sending the final completion acknowledgement.
<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — finishOriginAuthorization (install loop precedes sealGrantReceipt/send), sendRecipientKeyAndWait (openGrantReceipt, sealCompletionAcknowledgement, importCompletionRecorder, firstOpenStore.markComplete, then phase = .completed) -->

**Preconditions:** Two staged devices (§1.6); drive the pairing through origin biometric
approval (§3.4 step 10). To widen the interruption window, select several grants or point
grants at slow/unreachable hosts so the origin's install loop runs long.

**Steps:**

1. **[O]** While the origin shows "Sending setup", kill the origin app from the app switcher
   (or `xcrun simctl terminate <udid> com.bambouville.TesseraApp`).
   -> Expected **[R]**: the recipient fails at its next protocol receive with "Nearby setup
   stopped" ("The nearby connection closed."). It must NOT reach "Setup inherited": the
   HOST ACCESS RECEIPT renders only in the completed phase, which requires the origin's
   signed grant receipt plus the acknowledgement round-trip — so the recipient never shows
   an `AUTHORIZED` (or any other) row for grants the origin never confirmed.
   <!-- src: Tessera/Bootstrap/BootstrapFlowView.swift — receiptView rendered only for phase .completed -->
   <!-- src: Tessera/Bootstrap/NearbyTransferService.swift — "The nearby connection closed." -->
   The failure is typically immediate (TCP teardown on process kill); if the recipient
   lingers in "Importing setup" first, record how long — the coordinator has no client-side
   timeout of its own.
2. **[R]** Distinguish the two timing windows and relaunch the recipient:
   - Origin died BEFORE the manifest arrived → nothing was imported; a fresh recipient
     behaves like a plain cancelled attempt (welcome re-presents only because there are
     still zero hosts).
   - Origin died AFTER "Importing setup" finished the local save → hosts and provenance are
     durable but incomplete: this is exactly the interrupted-import state, and recovery
     (welcome re-presents even with hosts; retry or "set up as new") follows §3.7.
   <!-- src: Tessera/Bootstrap/BootstrapManifestAdapter.swift — provenance recorded inside apply(); markComplete only via importCompletionRecorder at acknowledgement time -->
3. **[R]** Inspect key-security metadata for the accepted key-eligible hosts.
   -> Expected: "uncertain" install intents remain — the recipient records them BEFORE
   sending its import acceptance, and an origin-side death leaves them standing by design
   (the origin may or may not have appended the key).
   <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — recipientGrantIntentRecorder(verificationState: .uncertain) before sealImportAcceptance -->
4. On the target fixture host, check `~/.ssh/authorized_keys`.
   -> Expected: grants the origin finished installing before dying MAY already be present
   even though neither device ever showed `AUTHORIZED` — installs precede the receipt.
   Record what is actually on the host; a §3.7 retry reconciles truthfully (the install
   command is idempotent, so re-approval adds no duplicate line).
   <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — finishOriginAuthorization install loop; Tessera/Keys/RemoteAuthorizedKeysInstaller.swift — idempotent append -->
5. **[O]** Relaunch the origin.
   -> Expected: the normal shell, no overlay and no receipt for the aborted attempt — the
   origin's first-open marker was already set, and its attempt state was in-memory only.
   <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — beginIfFirstOpen guards on !firstOpenStore.isComplete; no attempt persistence -->
6. Variant — **background** the origin instead of killing it.
   -> Expected: `stopForBackground()` cancels the attempt and dismisses the origin overlay
   even in `transferring` (backgrounding bypasses the hidden cancel button); the recipient
   errors out exactly as in step 1.
   <!-- src: Tessera/TesseraApp.swift — scenePhase .background -> bootstrapCoordinator.stopForBackground(); Tessera/Bootstrap/BootstrapCoordinator.swift — stopForBackground() guards only phase != .inactive -->

**Device/orientation variants:** None.

**Edge & failure cases:**

- Origin killed AFTER sending the grant receipt but before the acknowledgement lands: the
  recipient may still complete (it marks complete after sending its acknowledgement) —
  record which side of the race you observed; both outcomes are protocol-consistent.
  <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — sendRecipientKeyAndWait tail ordering -->

**Automated coverage:**
`BootstrapCoordinatorTests.test_partialFailureIsTruthfulAndAcknowledgedWithoutRecordingFailure`
and `test_cancelledOwnerAuthenticationSendsNoManifestAndInstallsNoGrant` cover receipt
truthfulness at coordinator level. The cross-device kill/relaunch sequencing, the
on-host `authorized_keys` audit, and the uncertain-intent inspection are **manual only**.

---

### 3.9 Settings-initiated re-receive on a completed device

Settings → Continuity → "receive setup from nearby device" is the ONLY recovery path for a
user who chose "set up as new" and later wants to inherit from another device — the
first-open welcome can never re-present once the completion marker is set.
<!-- src: Tessera/Settings/ContinuitySettingsView.swift — "receive setup from nearby device" -> bootstrapCoordinator.startRecipientDiscovery() -->
<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — beginIfFirstOpen requires !firstOpenStore.isComplete; startRecipientDiscovery guard allows phase == .inactive -->

**Preconditions:** Recipient device with first-open COMPLETE and at least one saved host
(so §3's gate would never fire). An origin staged per §1.6. Launch args not needed.

**Steps:**

1. **[R]** Open Settings → "sync & continuity", section "NEARBY SETUP", tap
   "receive setup from nearby device".
   -> Expected: the full-screen Nearby Setup overlay (`zIndex 110`) presents over the
   completed shell — it covers Settings, the sidebar/tab bar, everything — and opens
   directly at "Choose your other device". The "Bring your setup with you" welcome is
   skipped: `startRecipientDiscovery` from the inactive phase goes straight to browsing.
   <!-- src: Tessera/ContentView.swift — bootstrapFlowOverlay (isPresented == phase != .inactive); Tessera/Bootstrap/BootstrapCoordinator.swift — startRecipientDiscovery: phase = .browsing -->
2. **[R]** Tap "cancel".
   -> Expected: the overlay dismisses back to Settings exactly where you were (selection
   untouched; nothing persisted). The dismissal observer sets `hasSeenWelcome`, which is
   already true — no visible change. Relaunch: no welcome (marker still set).
   <!-- src: Tessera/ContentView.swift — onChange(of: bootstrapCoordinator.isPresented) -->
3. Re-enter and pair per §3.4 steps 2–10.
   -> Expected: identical chrome and protocol. The recipient's EXISTING "Tessera device key"
   is reused, not re-created — the origin's grant screen shows that key's fingerprint.
   <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — confirmCodeMatches -> recipientKeyProvider; Tessera/Enrollment/EnrollmentCoordinator.swift — DeviceEnrollmentKeyFactory.storedKey reuses by name/algorithm/protection -->
4. **[R]** Read the "Setup inherited" receipt against the pre-existing data (the merge
   semantics):
   - A manifest host whose UUID already exists locally (e.g. shared import history) is
     skipped, never overwritten — "Imported N host(s)" counts only new inserts.
   - Hosts that exist on both devices as SEPARATE records (same name/address, different
     UUID) import as duplicates — dedupe is UUID-based, not address-based; expect two rows
     on the landing page and record them.
   - An imported identity whose UUID collides with a local identity is cloned under a fresh
     UUID, credential-less; it never binds to the local credential.
   - With "trusted host keys" opted in: identical pins report "N identical trusted host
     keys were already present."; conflicting pins are NEVER overwritten — the amber line
     "N local trusted host key conflict(s) was/were preserved for review in Known Hosts."
     appears and the Known Hosts page flags the endpoint `MISMATCH` (§6.13).
   - Portable appearance and general settings from the origin are applied UNCONDITIONALLY,
     overwriting this device's theme/accent/font/scrollback — warn testers using their
     personal device setup.
   <!-- src: Tessera/Bootstrap/BootstrapManifestAdapter.swift — apply(): unavailableHostIDs exclusion, identity UUID clone (credentialMode .none), importTrustedRecord conflict counting, apply(manifest.appearance, manifest.settings, to:) -->
   <!-- src: Tessera/Bootstrap/BootstrapFlowView.swift — receiptView skipped/conflict lines -->
5. **[R]** Tap "done".
   -> Expected: `finish()` re-marks the already-set completion marker (idempotent, no
   behavior change) and dismisses to the shell the overlay covered. "configure later" on a
   non-authorized row navigates to that host's editor instead, as in §3.4 step 13.
   <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — finish() markComplete for received completions; Tessera/ContentView.swift — configureBootstrapHost -->
6. Kill the recipient mid-"Importing setup" (as in §3.7) and relaunch.
   -> Expected DIFFERENCE from first-open: the welcome does NOT re-present — the completion
   marker is set, so the gate fails even though interrupted-import provenance exists.
   Recovery is to re-run "receive setup from nearby device" from Settings; provenance
   matching then re-accepts the unchanged prior import without duplicating it.
   <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — beginIfFirstOpen requires !firstOpenStore.isComplete; Tessera/Bootstrap/BootstrapManifestAdapter.swift — reusableAcceptedHostIDs -->

**Device/orientation variants:** None — the same overlay presents on every matrix row; on
the compact shell Settings is a tab, so cancel returns to the `settings` tab.

**Edge & failure cases:** The adjacent "send setup to nearby device" button is the §3.4
origin role from the same screen. Per-phase cancel/background semantics are §3.6, unchanged.
A `.welcome`-phase entry is impossible here; "start again" after a failure retries browsing
directly (the failed attempt intent was `.receive`).
<!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — retry() case .receive -->

**Automated coverage:** merge/conflict and provenance semantics:
`BootstrapManifestAdapterTests`; coordinator retry intents: `BootstrapCoordinatorTests`
(`test_recipientFailureRetryRestartsBrowsing`). The Settings entry point, the
overlay-over-completed-shell presentation, and the post-"set up as new" recovery UX are
**manual only**.

---

### 3.10 Local Network permission (physical devices)

**Preconditions:** Two PHYSICAL devices with the same Tessera build — the Simulator never
shows this prompt, which is why no lane can cover it. A path into the flow on the recipient
(fresh install §3.1, or Settings re-receive §3.9). To force a fresh permission state:
iOS Settings → Privacy & Security → Local Network → toggle Tessera off, or delete and
reinstall the app.
<!-- src: scripts/integration/README.md ("Intentionally manual") -->

Nearby Setup uses Bonjour service type `_tessera-bootstrap._tcp` — an `NWBrowser` on the
recipient ("find nearby devices") and an `NWListener` on the origin ("send setup to nearby
device"); both sit behind the iOS Local Network permission.
<!-- src: Tessera/Bootstrap/NearbyTransferService.swift — bonjourServiceType, BonjourNearbyTransferNetworking (NWBrowser/NWListener); Tessera/Info.plist — NSBonjourServices -->

**Steps:**

1. **[R]** Tap "find nearby devices" for the first time on this install.
   -> Expected: iOS presents the Local Network permission alert. The exact moment it fires
   is OS behavior, not app code — **observe and record**: does it appear on this tap (first
   `NWBrowser` start), earlier (some other first network use), or later? Also record the
   usage string shown. Two candidate strings exist in the project — note which one iOS
   displays: "Find a nearby iPhone or iPad to transfer your Tessera setup securely."
   (`Tessera/Info.plist`) or "Tessera connects to SSH and Mosh servers on your local
   network, forwards local ports, and can bootstrap a new device directly from a nearby
   Tessera device." (build-settings `INFOPLIST_KEY_NSLocalNetworkUsageDescription`).
   <!-- src: Tessera/Info.plist — NSLocalNetworkUsageDescription; Tessera.xcodeproj/project.pbxproj — INFOPLIST_KEY_NSLocalNetworkUsageDescription -->
2. **[R]** Allow.
   -> Expected: discovery proceeds normally (§3.4 step 3 — the origin's row appears).
3. Reset the permission, re-enter, and this time DENY.
   -> Expected: no peer can ever appear. The app maps browser `.failed`/`.waiting(error)`
   states to the failure screen ("Nearby setup stopped" plus the OS error text), but
   whether iOS reports denial as a browser error or silently starves the browser is
   OS-version behavior — **observe and record which outcome occurs**: (a) the failure
   screen, or (b) stuck on "Looking nearby" with an empty peer list. Either way, no
   silent partial discovery is acceptable.
   <!-- src: Tessera/Bootstrap/NearbyTransferService.swift — browser stateUpdateHandler .failed/.waiting -> failed(.network); Tessera/Bootstrap/BootstrapCoordinator.swift — handle(.failed) -> fail -->
4. **[O]** Repeat the denial on the origin with "send setup to nearby device".
   -> Expected: the origin's listener is gated the same way; a recipient WITH permission
   granted never discovers this origin. **Observe and record** the origin-side surface
   (failure screen vs endless "Waiting for your other device").
   <!-- src: Tessera/Bootstrap/NearbyTransferService.swift — listener stateUpdateHandler .failed/.waiting -> failed(.network) -->
5. Recovery: iOS Settings → Privacy & Security → Local Network → enable Tessera, return to
   the app, tap "start again" (failure screen) or re-enter the flow.
   -> Expected: discovery now works without reinstalling the app.

**Device/orientation variants:** Physical devices only; on the Simulator the flow runs
without any prompt (the §1.6 staging relies on this).

**Edge & failure cases:** Denial also gates later attempts silently — a tester returning
weeks later sees only the step-3 outcome with no new prompt; the recovery path in step 5 is
the only fix. Record this state clearly in bug reports to distinguish it from Bonjour
failures.

**Automated coverage:** none — explicitly listed as intentionally manual
(`scripts/integration/README.md`); see §9.6.

---

### 3.11 Upgrade in place: existing installs and the first-open gate

Covers updating the app over an EXISTING data container — in particular an install that
predates the Nearby Setup gate, where hosts exist but `tessera.nearbyBootstrap.completed.v1`
was never written. Stage a faithful equivalent without an old build: with hosts and keys
saved, run the §1.3 partial reset (delete both defaults keys) — that state is exactly the
upgraded-install shape. Real archived-store and physical-device upgrades remain release
gates (README, MG1 row).
<!-- src: scripts/integration/README.md — MG1 "Archived previous-release stores and physical upgrades remain release gates" -->

**Steps:**

1. Relaunch after the partial reset (or install the current build over an old container on
   a real device).
   -> Expected: NO "Bring your setup with you" welcome. `beginIfFirstOpen(hasHosts:)`
   requires zero hosts (or interrupted-import provenance) — an upgraded install with hosts
   short-circuits on that gate even though the completion marker is unset. The marker then
   simply stays unset forever: the gate re-evaluates on every launch and always
   short-circuits while hosts exist.
   <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift — beginIfFirstOpen guard (!hasHosts || interruptedImportProvider()) && !firstOpenStore.isComplete -->
2. Verify the walkthrough did not auto-run either.
   -> Expected: no welcome card — `beginIfFirstLaunch` requires zero hosts, independent of
   `hasSeenWelcome`, so an upgraded install with hosts never auto-runs the tour. It stays
   reachable from Settings → about → "replay walkthrough" (§4.3).
   <!-- src: Tessera/Onboarding/OnboardingController.swift — beginIfFirstLaunch guard (!hasSeen, !hasHosts) -->
3. Verify data integrity: hosts list, identities, keys, and jump-host chains all intact.
   -> Expected: the SwiftData store reopened through `TesseraMigrationPlan` (V1 → V2 adds
   only the `HostJumpLink` entity via a lightweight stage); a failed migration would
   present as an EMPTY container — "all my saved hosts vanished" is the classic failure
   signature to watch for.
   <!-- src: Tessera/TesseraMigration.swift — TesseraMigrationPlan (V1→V2 lightweight), TesseraModelContainer.make; doc comment on the empty-container fallback -->
4. Hostless-upgrade variant: an existing install with ZERO hosts (installed, never added a
   host), upgraded.
   -> Expected: the welcome DOES present on the next launch — with no hosts and no marker,
   an upgraded install is indistinguishable from a fresh one by design. "set up as new"
   completes it normally.
5. On a physical device, open the Keys page after upgrading.
   -> Expected: Keychain items survive an app update (unlike delete+reinstall), so no
   "PRIVATE MATERIAL MISSING" badges appear and stored keys remain usable.

**Device/orientation variants:** None; the simulator staging in step 1 covers gating logic,
but step 3 and step 5 carry real weight only on physical upgrades.

**Edge & failure cases:**

- Upgraded install that ALSO has interrupted-import provenance (rare — a pre-upgrade nearby
  import died mid-flow): the welcome re-presents despite hosts, per §3.7's gate.
- After step 1, deliberately delete every host: the next launch DOES present the welcome
  (zero hosts, marker still unset) — expected, not a regression.

**Automated coverage:** `TesseraTests/TesseraMigrationTests`
(`test_v1StoreOnDisk_migratesToV2_keepingHostsAndArrayColumn`,
`test_currentSchema_reopensARealOnDiskStoreWithoutLosingRows`) via
`scripts/integration/run-offline-oracle-tests.sh` covers ONLY the store reopen (§9.1 MG1);
`OnboardingControllerTests` and `BootstrapCoordinatorTests` cover the two gate predicates in
isolation. The upgrade-shaped end-to-end launch behavior, physical-device migration, and
Keychain survival are **manual only**.

---
## 4. iPad walkthrough

### Codex Desktop QA charter

**Primary mission:** judge whether the walkthrough teaches Tessera's mental model rather than
merely rendering eight correct cards.

During Pass A:

- Enter through the same surface a real user would see; use forced-step hooks only for a
  separate visual-regression mission.
- Before reading each body paragraph in detail, state what the illustration and hierarchy
  imply the feature does.
- Check whether the spotlight clearly belongs to the intended control and whether the user
  could confuse it with a nearby control.
- Try portrait, regular-width Split View, one light theme, and a larger text size.
- Watch transitions and resizing, not only settled frames.
- Record copy that assumes knowledge introduced only later, keyboard shortcuts that dominate
  the explanation, or illustrations that look interactive when they are not.

A step can match the screenshot oracle and still fail if it does not improve a new user's
understanding or if Skip/Back/Done behavior feels surprising.

The walkthrough is the iPad-only 8-step guided tour that starts from the "welcome to
Tessera" card. How it relates to the Nearby Setup first-open flow (read first):

- On a production fresh install, Nearby Setup presents first and *owns* the welcome moment.
  While it is presented the walkthrough controller is forced `.inactive`, and the moment the
  Nearby Setup presentation dismisses — for **any** reason, including cancel —
  `hasSeenWelcome` is set to `true`, so the walkthrough's welcome card never auto-runs on
  top of it. The walkthrough is then reachable only via Settings → about →
  "replay walkthrough" (§4.3).
  <!-- src: Tessera/ContentView.swift (onChange(of: bootstrapCoordinator.isPresented) lines ~625-634, maybeBeginOnboarding lines ~2249-2271) -->
- The welcome card **auto-runs** only when all of these hold: first-open is already complete
  (`tessera.nearbyBootstrap.completed.v1` set), `hasSeenWelcome` is false, there are zero
  saved hosts, no session is active, and nothing is selected. In practice testers reach it
  with the launch argument `-tessera.nearbyBootstrap.completed.v1 YES` alone (§1.4).
  <!-- src: Tessera/Onboarding/OnboardingController.swift (beginIfFirstLaunch), Tessera/ContentView.swift (maybeBeginOnboarding), Tessera/Bootstrap/BootstrapCoordinator.swift (BootstrapFirstOpenStore, beginIfFirstOpen) -->
- The walkthrough overlay is mounted only when the window is **not** phone-classed
  (`if !isPhone` around the `OnboardingOverlay` mount). iPhone never shows the walkthrough
  in any orientation, and a compact iPad window (Split View / Slide Over) doesn't either.
  The About "replay walkthrough" row is likewise hidden on phone-classed windows. The check
  is size-class, not full-screen: a REGULAR-width iPad pane (e.g. the ≈2/3 Split View pane,
  matrix M6) DOES mount the walkthrough — §4.4.
  <!-- src: Tessera/ContentView.swift (agentAwareContent overlayPreferenceValue, lines ~423-441), Tessera/Settings/AboutSettingsView.swift (line ~70), Tessera/Design/DesignTokens.swift (CompactLayout.isPhone) -->

DEBUG builds can force any step directly with `TESSERA_FORCE_TOUR_STEP=<0-7>` (§1.4).

---

### 4.1 Welcome card and auto-run gating

**Preconditions:** DEBUG or release build on iPad full screen. Fresh container (§1.3 full
reset). Launch with `-tessera.nearbyBootstrap.completed.v1 YES` only (NOT the
hasSeenWelcome arg). Zero saved hosts.

**Steps:**

1. Launch the app.
   -> Expected: the screen dims (76% black) and a 440 pt-wide centered card shows the
   Tessera logo, the title "welcome to Tessera", the body "A fast iPad terminal for SSH &
   Mosh — trackpad scrolling in TUIs, native tmux, truecolor, edge-to-edge. Want a quick
   tour?", and two buttons: "take the tour" (primary) and "skip".
   <!-- src: Tessera/Onboarding/OnboardingOverlay.swift (welcomeLayer), Tessera/Onboarding/OnboardingController.swift (beginIfFirstLaunch) -->
2. Tap anywhere on the dim backdrop.
   -> Expected: nothing happens — the tap is consumed. The walkthrough is passive; only its
   own buttons act. <!-- src: Tessera/Onboarding/OnboardingOverlay.swift (dimBackdrop onTapGesture consume) -->
3. Tap "skip".
   -> Expected: overlay dismisses to the landing page. Relaunch the app: the welcome card
   does NOT reappear (`skip` is `finish` — it persists `hasSeenWelcome`).
   <!-- src: Tessera/Onboarding/OnboardingController.swift (skip() calls finish(); finish() sets appearance.hasSeenWelcome = true) -->
4. Reset the container, relaunch with the same arg, and this time add a host first (§5.3),
   then relaunch again with `hasSeenWelcome` cleared.
   -> Expected: the welcome card does NOT auto-run once any host exists — auto-run requires
   zero hosts AND unseen. <!-- src: OnboardingController.beginIfFirstLaunch guard (!hasSeen, !hasHosts); verified by OnboardingControllerTests truth table -->
5. Reset again, launch WITHOUT the bootstrap-completed arg.
   -> Expected: Nearby Setup presents instead; no welcome card underneath. Cancel/dismiss
   it, then relaunch: Nearby Setup re-presents (cancel does not complete it), and the
   welcome card still never auto-runs, because dismissing the Nearby Setup presentation set
   `hasSeenWelcome`.
   <!-- src: Tessera/ContentView.swift (onChange bootstrapCoordinator.isPresented: on dismiss sets appearance.hasSeenWelcome = true; comment "Keep the legacy tour replayable from Settings without stacking a second welcome"), Tessera/Bootstrap/BootstrapCoordinator.swift (cancel() does not markComplete; only setUpAsNew()/finished received import do) -->

**Device/orientation variants:**

- iPhone (any orientation) and compact iPad windows: no welcome card ever — the overlay is
  only mounted for non-phone-classed windows. Verify explicitly on iPhone: the same
  fresh-launch args land directly on the landing page.
  <!-- src: Tessera/ContentView.swift (overlayPreferenceValue ... if !isPhone) -->
- iPad portrait vs landscape: card is centered in both; no differences beyond geometry.

**Edge & failure cases:**

- Relaunch mid-welcome (kill the app with the card up, relaunch): the card reappears —
  `hasSeenWelcome` is only set by "skip"/finishing, not by showing the card.
- Auto-run must not fire when a session restore is in progress or something is selected:
  `maybeBeginOnboarding` bails unless the state is a clean landing (no active sessions,
  nothing selected). <!-- src: Tessera/ContentView.swift (maybeBeginOnboarding guard activeSessions.isEmpty, selectedItem == nil) -->
- A re-entrant appearance while the walkthrough is running must not yank it back to the
  welcome card (controller `beginIfFirstLaunch` is guarded on `.inactive`).

**Automated coverage:** `TesseraTests/OnboardingControllerTests.swift` covers the complete
begin/skip/finish truth table (unseen+no-hosts shows welcome; any other combination stays
inactive; begin is idempotent during a running tour), and
`TesseraTests/BootstrapCoordinatorTests.swift` covers `beginIfFirstOpen` gating. The
overlay/backdrop rendering and the ContentView wiring (Nearby-Setup-dismiss sets
`hasSeenWelcome`) are **manual only**.

---

### 4.2 The eight steps

**Preconditions:** iPad full screen, welcome card on screen (§4.1 step 1) — or jump
directly to any step in a DEBUG build with `TESSERA_FORCE_TOUR_STEP=<0-7>`.

The step inventory (titles are exact UI copy; kind determines rendering):

| # | Title | Kind |
| --- | --- | --- |
| 1 | "add your first host" | spotlight on the add-host control, callout below |
| 2 | "keys, secured by your iPad" | spotlight on the sidebar "keys" row, callout to its right |
| 3 | "tmux windows & panes" | illustration: mock tmux terminal |
| 4 | "swipe pad" | illustration: Claude Code prompt + swipe-pad puck |
| 5 | "files, beside your shell" | illustration: Files panel beside a mock terminal |
| 6 | "share, in and out" | illustration: share sheet both directions |
| 7 | "paste a screenshot" | illustration: image-paste pipeline with the `[Image #1]` token |
| 8 | "keyboard shortcuts" | illustration: two-column shortcut grid |

<!-- src: Tessera/Onboarding/OnboardingStep.swift (OnboardingStep.firstRun), Tessera/Onboarding/OnboardingOverlay.swift (spotlightLayer/centeredLayer/illustrationView) -->

**Steps:**

1. Tap "take the tour" on the welcome card.
   -> Expected: step 1 appears: the dim layer (72% black) has a rounded hole punched around
   the "add your first host" button on the empty-state landing (7 pt padding, accent-colored
   ring), and a 360 pt callout card sits below the hole. The card reads "STEP 1 OF 8", title
   "add your first host", body "Start here. Name it, drop in an address, pick an SSH key,
   then connect. ⌘N works from anywhere."
   <!-- src: Tessera/Onboarding/OnboardingOverlay.swift (spotlightPad=7, calloutWidth=360, dim 0.72), OnboardingStep.firstRun[0], Tessera/Hosts/HostsLandingView.swift (.onboardingAnchor(.addHost) on the empty-state CTA) -->
2. Tap inside the spotlight hole (on the highlighted button itself).
   -> Expected: nothing — a hit-blocker under the dim consumes taps in the hole. The
   walkthrough never drives you into a real flow. <!-- src: OnboardingOverlay.swift (tapBlocker comment) -->
3. Check the callout footer on every step.
   -> Expected: 8 page dots (current one accent-colored), "skip tour ✕" on **every** step,
   "back" from step 2 onward, and "next" ("done" on step 8) — all on a single line, no
   wrapping. <!-- src: OnboardingOverlay.swift (calloutCard footer; width comment re single-line footer at eight steps) -->
4. Tap "next".
   -> Expected: step 2 "keys, secured by your iPad" spotlights the sidebar's "keys" row with
   the callout to its right. Body: "Generate SSH keys backed by the Secure Enclave, unlocked
   with Face ID. Tessera can even install the public key on your server for you."
   <!-- src: OnboardingStep.firstRun[1] (.spotlight(.keysNav, .right)), Tessera/SessionSidebar.swift (.onboardingAnchor(.keysNav) on the keys row) -->
5. Continue through steps 3–8.
   -> Expected: each renders a centered 478 pt card (no spotlight) with its illustration:
   - Step 3 body mentions "⌘T opens one, ⌘1–9 jumps", "⌘D", "Native -CC, not a passthrough";
     illustration shows a tab strip ("1:vim", "2:server", "3:logs") over a split-pane mock
     terminal.
   - Step 4 shows a simulated Claude Code permission box ("❯ 1. Yes" / "2. Yes, don't ask
     again" / "3. No, tell Claude") beside the radial puck with petals "approve" (right,
     green), "deny" (left, red), "always" (up, amber), "macro" (down, accent).
   - Step 5 body mentions "⌘⇧E"; illustration shows the Files panel with a breadcrumb and an
     in-flight download row.
   - Step 6 shows OUT (server.log → app tiles) and IN (photo.heic → host chip) lanes.
   - Step 7 shows the pill "share or drop a screenshot", the caption "uploads to
     ~/.cache/tessera/ · types the path", and the `[Image #1]` composer token.
   - Step 8 shows the chord grid (⌘N "new host", ⌘F "find in scrollback", ⌘T, ⌘⇧W, ⌘1–9,
     ⌘⇧[ ], ⌘D, ⌘⇧E "files panel", ⌘K "session switcher", ⌘, "settings") and the footer
     "full list in Settings → Keyboard".
   <!-- src: Tessera/Onboarding/OnboardingOverlay.swift (MockTerminalIllustration, ClaudeCodePromptIllustration, PuckPetalsIllustration, FilesPanelIllustration, ShareInOutIllustration, AgentImagePasteIllustration, ShortcutsIllustration), OnboardingStep.firstRun bodies -->
6. On step 8 tap "done".
   -> Expected: overlay dismisses; `hasSeenWelcome` persists; relaunch shows no walkthrough.
   <!-- src: OnboardingController.next() → finish() when advancing past the last step -->
7. Re-run and tap "back" repeatedly from step 2.
   -> Expected: steps go backward and clamp at step 1 (back is hidden there).
   <!-- src: OnboardingController.back() clamps at index 0 -->
8. Re-run and tap "skip tour ✕" mid-way.
   -> Expected: same as finishing — dismisses and persists the seen flag.

**Device/orientation variants:**

- iPad portrait vs landscape: callout position is clamped to keep 12 pt margins inside the
  window, so on narrow/portrait geometry the callout may shift rather than sit exactly
  below/right of the hole. <!-- src: OnboardingOverlay.calloutOffset clamping -->
- Rotate mid-walkthrough: the spotlight hole must re-resolve to the target's new frame
  (anchors resolve through the live GeometryReader).
- iPhone / compact iPad windows: N/A (walkthrough not mounted). Regular-width Split View
  panes DO mount it — §4.4.

**Edge & failure cases:**

- Kill the app mid-walkthrough and relaunch: the phase is in-memory only. With
  `hasSeenWelcome` still false and zero hosts, the *welcome card* (not the mid-tour step)
  reappears.
- Themed chrome: the walkthrough renders with the active terminal theme's chrome tokens —
  if a non-default theme is set, cards/dots/ring follow it. Verify legibility on at least
  one light theme. <!-- src: OnboardingOverlay.swift (TerminalTheme.chromeTokens(applying:)) -->
- Spotlight target missing: see §4.3 edge cases (degrades to a centered card, copy still
  readable).

**Automated coverage:** visual lane
`scripts/integration/visual-cases/o1-onboarding-tour.sh` (case `O1-onboarding-tour`, run by
`scripts/integration/run-visual-review.sh`) captures all eight forced-step states in
landscape and gates on: correct "STEP N OF 8", fully on-screen callouts with a single-row
footer, spotlight ring alignment, and complete illustrations. State-machine transitions are
covered by `TesseraTests/OnboardingControllerTests.swift`. Manual testers should spot-check
portrait, rotation mid-walkthrough, and non-default themes — the lane covers neither.

---

### 4.3 Replay walkthrough from Settings → about

**Preconditions:** iPad full screen; walkthrough already seen; at least one saved host
exists (so the empty-state CTA is absent — this exercises the anchor hand-off). App can
even have a live session open.

**Steps:**

1. Open Settings (⌘, or the sidebar "settings" row), go to the about section.
   -> Expected: below "tessera · v<version>" / "build <build>" there is a button with a
   sparkles icon labeled "replay walkthrough".
   <!-- src: Tessera/Settings/AboutSettingsView.swift (Btn "replay walkthrough", gated !CompactLayout.isPhone) -->
2. Tap "replay walkthrough".
   -> Expected: the walkthrough starts directly at "STEP 1 OF 8" — no welcome card. The app
   navigates itself out of Settings back to the hosts landing and reveals the sidebar, so
   both spotlight targets are on screen. With hosts present, step 1's spotlight ring wraps
   the **header "new host" button** (the empty-state CTA doesn't exist; the anchor
   conditionally moves to the header button).
   <!-- src: Tessera/Onboarding/OnboardingController.swift (startTour → .touring(0)), Tessera/ContentView.swift (onChange(of: onboarding.phase): selectedItem = nil; sidebarVisible = true for spotlight steps), Tessera/Hosts/HostsLandingView.swift (.onboardingAnchor(.addHost, if: !hosts.isEmpty) on the header button) -->
3. Complete or skip the walkthrough.
   -> Expected: returns to the landing; replay is repeatable any number of times.

**Device/orientation variants:**

- iPhone and compact iPad windows: the "replay walkthrough" button is **not rendered** in
  about — confirm its absence rather than a broken tap.

**Edge & failure cases:**

- If a spotlight target is somehow not on screen, the step degrades to a centered card with
  the same copy instead of a mis-placed ring.
  <!-- src: Tessera/Onboarding/OnboardingOverlay.swift (tourLayer: resolvedRect nil → centeredLayer fallback) -->
- Replaying with a live session selected: entering step 1 deselects the session view
  (returns to landing) — the session keeps running; verify it's still alive afterward.

**Automated coverage:** the step-2 core — replay starts directly at step 1 with no welcome
card — is covered by `TesseraTests/OnboardingControllerTests.swift`
(`test_startTour_beginsAtFirstStep`: `startTour()` enters `.touring(0)`, never `.welcome`) —
spot-check only. The ContentView wiring is the genuinely manual remainder: the about-page
button itself, navigating out of Settings back to the landing, forcing the sidebar visible,
and the header-button anchor hand-off. (The O1 visual lane seeds forced steps at launch, not
the Settings replay path.)

---

### 4.4 Walkthrough in a regular-width Split View pane (matrix row M6)

The overlay mounts on `!CompactLayout.isPhone`, not on "full screen" — any regular-width
iPad window mounts it, including a ≈2/3 Split View pane. The O1 visual lane captures
full-screen landscape only, so pane geometry is entirely unverified by automation.
<!-- src: Tessera/ContentView.swift — overlayPreferenceValue(OnboardingAnchorKey.self) { if !isPhone { OnboardingOverlay(...) } } -->
<!-- src: scripts/integration/visual-cases/o1-onboarding-tour.sh — landscape full-screen captures -->

**Preconditions:** iPad in landscape Split View with Tessera as the ≈2/3 pane and the
sidebar shell visible (the shell is the size-class oracle — §2.2); a second app in the
other pane. Two entry variants: (a) fresh container + `-tessera.nearbyBootstrap.completed.v1
YES` only, zero hosts, for the auto-run; (b) completed state with hosts for the Settings
replay (§4.3).

**Steps:**

1. Variant (a): launch Tessera into the regular 2/3 pane.
   -> Expected: the welcome card auto-runs inside the pane — `maybeBeginOnboarding` runs on
   appearance whenever the window is not phone-classed, with the same zero-hosts/unseen
   gates as §4.1. The dim backdrop covers only Tessera's pane; the neighboring app is
   untouched.
   <!-- src: Tessera/ContentView.swift — onAppear: `if !isPhone && !bootstrapCoordinator.isPresented { maybeBeginOnboarding() }` -->
2. Take the tour through steps 1–2 (spotlights).
   -> Expected: the spotlight hole wraps the target inside the pane, and the 360 pt callout
   clamps to keep 12 pt margins inside the NARROWED window — this clamping has never been
   exercised at pane widths, so record any clipping, overlap, or footer wrapping as a bug.
   <!-- src: Tessera/Onboarding/OnboardingOverlay.swift — calloutOffset clamping (12 pt margins), calloutWidth 360 -->
3. Continue through steps 3–8 (centered 478 pt cards).
   -> Expected: cards fit and center within the pane; on smaller iPads record whether the
   478 pt card meets the pane edge.
   <!-- src: Tessera/Onboarding/OnboardingOverlay.swift — centeredLayer width -->
4. Drag the Split View divider toward 50/50 mid-tour until the shell swaps to compact, then
   widen back.
   -> Expected: the moment the window goes phone-classed the overlay UNMOUNTS (the
   `if !isPhone` mount) — the tour vanishes with no buttons left to finish it, and
   `hasSeenWelcome` stays false. The tour phase lives in the controller (in-memory), so
   widening back to regular REMOUNTS the overlay at the same step. The spotlight must
   re-resolve to the target's new frame after the resize (anchors resolve through live
   geometry) — record actual behavior if it lands stale.
   <!-- src: Tessera/ContentView.swift — conditional overlay mount; Tessera/Onboarding/OnboardingController.swift — phase is in-memory @Observable state -->
5. Variant (b): replay from Settings → about inside the regular pane (§4.3).
   -> Expected: identical behavior; the "replay walkthrough" row is visible because the
   pane is not phone-classed.
   <!-- src: Tessera/Settings/AboutSettingsView.swift — row gated !CompactLayout.isPhone -->

**Device/orientation variants:** A 50/50 pane on a 13-inch iPad may still be regular (M7) —
the same expectations apply wherever the sidebar shell shows. Compact panes and Slide Over:
never mounted (§4.1 variants).

**Edge & failure cases:**

- Killed mid-tour while narrowed (overlay unmounted, `hasSeenWelcome` still false): with
  zero hosts and the launch arg, the next launch auto-runs the welcome card again — same
  rule as the §4.2 relaunch edge case.
- Launch variant (a) directly INTO a compact pane: `maybeBeginOnboarding` is only called
  from the not-phone-classed branch of onAppear, so nothing begins; then widen the pane to
  regular WITHOUT relaunching. The begin call runs on appearance, not on size-class change —
  expected: the welcome does not retroactively auto-run until the next launch. Verify and
  record, since a SwiftUI remount could change this in practice.
  <!-- src: Tessera/ContentView.swift — maybeBeginOnboarding called from onAppear behind `!isPhone` -->

**Automated coverage:** none — the O1 lane is full-screen landscape only (§9.2), and
`OnboardingControllerTests` covers only the state machine. **Manual only.**

---

## 5. Landing page & first host

### Codex Desktop QA charter

**Primary mission:** get from an empty host list to a saved, connectable host without relying
on knowledge of Tessera's data model.

During Pass A:

- Use realistic typing, including corrections, keyboard dismissal, field-to-field movement,
  and one plausible invalid value.
- Note which field the eye reaches first and whether the identity/password relationship is
  understandable.
- Judge default choices as a user would; do not assume auto-tmux, SSH/Mosh, jump hosts, or
  credentials are self-explanatory.
- On iPhone and compact iPad, explicitly test the meaning of Save versus Connect and Cancel.
- On iPad, test the surprising persistence boundary: partially edit, cancel, return, and
  report whether the visible language prepared the user for retained changes.
- Try quick-connect as taught by the UI, not from the parser specification.

High-value issues include keyboard-covered actions, fields with unclear validation, silent
rejection, accidental persistence, hidden credentials requirements, and layouts that make a
secondary action look primary.

The surfaces a brand-new user meets after the first-open choice is behind them: the sidebar
anatomy on iPad, the empty-state hosts landing page, host creation end-to-end in the host
editor (both idioms), jump hosts and forwarding rules, and quick-connect via `user@host` in
the search bar. Unless a flow says otherwise, launch with both pre-complete args (§1.4) so
no first-open overlay covers the shell.

Which shell appears on which device is §2; the full per-shell flows (including iPhone first
contact, Split View swaps, status bar, rotation) are §8.

---

### 5.1 iPad sidebar anatomy, hit frames, and shell shortcuts

**Preconditions:** iPad full screen, portrait first (portrait is what the current PR stack
fixes), pre-complete launch args, zero saved hosts. Full collapse/reveal and orientation
assertions live in §8 Flow B — this flow covers what a new user inspects *inside* the
sidebar, plus the shell-level keyboard shortcuts.

**Steps:**

1. Launch the app in portrait.
   -> Expected: the landing page ("hosts" title) fills the window with a 240 pt sidebar
   expanded on the leading edge. On browse pages the sidebar *pushes content aside* (the
   landing content is inset by the sidebar width), it does not float over it.
   <!-- src: Tessera/ContentView.swift (@State private var sidebarVisible = true; detail padding .leading SessionSidebar.width), Tessera/SessionSidebar.swift (static let width: CGFloat = 240) -->
2. Inspect the sidebar top bar.
   -> Expected: Tessera logo + "Tessera" title; on the trailing side a `+` button
   (accessibility label "new host") and a `‹` chevron button (accessibility label
   "hide sidebar"). Each has a ≥44 pt hit frame; tapping the visible `+` must not trigger
   the chevron (this exact mis-tap was the bug the hit-frame work fixed).
   <!-- src: Tessera/SessionSidebar.swift (titleBar, SidebarIconButton comments re 44pt frames) -->
3. Inspect the sidebar body and footer.
   -> Expected: a "hosts" section header with a "view all" underlined link (empty list on a
   fresh install), then bottom navigation rows: "keys" (key.fill), "known hosts"
   (lock.shield.fill), "tunnels" (arrow.left.arrow.right), "settings" (gearshape.fill).
   An "agents" (sparkles) row appears only when Agent Center is enabled in settings.
   <!-- src: Tessera/SessionSidebar.swift (hostsSection, bottomNavigation, appearance.agentCenterEnabled gate) -->
4. Collapse via the `‹` chevron and reveal via the floating `line.3.horizontal` button —
   in portrait.
   -> Expected: both work; full expectations (animation, content insets, reveal-button
   geometry) are §8 Flow B steps 4–6.
5. With a hardware keyboard, press ⌘N, ⌘K, ⌘, in turn.
   -> Expected: ⌘N opens a "new host" editor draft, ⌘K opens the command palette/session
   switcher, ⌘, opens Settings — all from the landing page (these are registered as hidden
   shell-level buttons, so they work outside a terminal).
   <!-- src: Tessera/ContentView.swift (contentShell hidden Buttons with .keyboardShortcut "n"/"k"/",") -->

**Device/orientation variants:** iPhone and compact iPad windows have no sidebar at all —
the compact shell applies (§8 Flows A and C). iPad portrait vs landscape: no structural
difference; the sidebar starts expanded in both.

**Edge & failure cases:**

- While a *session* is selected on iPad, the open sidebar floats over the terminal with a
  dim scrim behind it; see §8 Flow B step 7.
- Resize an iPad window from regular to compact with the sidebar open: the shell must swap
  to the compact shell without losing the selected page (§8 Flow C).

**Automated coverage:** `SidebarToggleHarnessTests` (expanded-at-launch in both
orientations, collapse/reveal round-trip) and `OrientationButtonSweepTests` (dead-tap sweep
of every sidebar row and CTA on both idioms and orientations) — see §9.3. Spot-check
hit-target *comfort* and the ⌘ chords; the chords are **manual only**.

---

### 5.2 Empty-state hosts landing page

**Preconditions:** Launch with both pre-complete args (no overlays), zero saved hosts.
iPad full screen and iPhone.

**Steps (iPad):**

1. Look at the page.
   -> Expected, top to bottom: "hosts" page title with a "new host" button (plus icon and a
   small "⌘N" chip) on the trailing edge; a search field with a magnifying glass and the
   placeholder "search hosts, or type user@host to quick-connect"; then a centered empty
   state: Tessera logo, "no hosts yet", body "Add a server to open a session over SSH or
   Mosh — with tmux, truecolor, and trackpad scrolling built in.", a primary button
   "add your first host" with a "⌘N" chip, a secondary button "generate a key", and the
   mono hint "or type user@host in the search bar above to connect right away".
   <!-- src: Tessera/Hosts/HostsLandingView.swift (pageHeader, quickConnectRow, emptyState, searchPlaceholder) -->
2. Tap "generate a key".
   -> Expected: navigates to the Keys page (sidebar "keys" row selects). Key generation
   itself is §6.1.
   <!-- src: Tessera/ContentView.swift (landing onOpenKeys: selectedItem = .keys; phone also sets compactTab/.keys) -->
3. Go back (sidebar "view all" or hosts row) and tap "add your first host".
   -> Expected: the host editor opens titled "new host" (§5.3).

**Device/orientation variants:**

- iPhone: no "⌘N" chips anywhere; the search placeholder is shortened — with zero hosts it
  reads "search hosts or add new ones below", and once hosts exist "search hosts or
  user@host" (the full iPad instruction truncates in a ~300 pt field). Paddings are tighter.
  <!-- src: Tessera/Hosts/HostsLandingView.swift (searchPlaceholder isPhone branch, `if !isPhone` ⌘N chips) -->
- iPad Split View / Slide Over compact: takes the phone presentation of this page (per the
  PR stack; `isPhone` is size-class-driven on iPad).
- Populated landing differences (after you have hosts): a "RECENT" card grid (first 3 hosts;
  3 columns iPad, 2 on phone) and an "all hosts · N" section — a table with column headers
  name/address/port/identity/last seen on iPad, a row list on phone where each row has a
  44 pt-tall ellipsis edit button (accessibility "edit <name>") and a long-press context
  menu "connect" / "edit…" / "remove…".
  <!-- src: Tessera/Hosts/HostsLandingView.swift (recentSection, allHostsSection, hostTableHeader, CompactHostRow) -->

**Edge & failure cases:**

- Search with hosts present filters by host name or `user@address` substring
  (case-insensitive); a non-matching query shows "all hosts · 0".
  <!-- src: HostsLandingView.filteredHosts -->
- Removing a host (phone context menu "remove…", or the delete paths in the editor) presents
  a confirmation dialog titled "remove <name>?" with destructive "remove host", "cancel",
  and the message "This removes the saved host. Existing live sessions are not
  disconnected." Verify a live session to that host indeed stays connected after removal.
  <!-- src: HostsLandingView.confirmationDialog -->
- Tapping a saved host connects **only if** every hop of its route has usable credentials;
  otherwise the host editor opens instead of a doomed connection attempt.
  <!-- src: Tessera/ContentView.swift (landing onConnect → hostRouteHasUsableCredentials gate) -->

**Automated coverage:** manual only for layout/copy (`OrientationButtonSweepTests` proves
the CTAs are tappable — §9.3). Route-credential resolution logic is unit-covered in
`TesseraTests/HostJumpChainResolverTests.swift`.

---

### 5.3 Host creation end-to-end (iPad editor)

**Preconditions:** iPad full screen, landing page visible. For the connect step, fixture
hosts from §1.5 (stable host, app port 2222, user `tessera`).

**Steps:**

1. Press ⌘N (or tap "add your first host" / header "new host" / sidebar `+`).
   -> Expected: an empty `PersistedHost` (port 22, auto-tmux) is inserted and its editor
   opens as the detail page, titled "new host". Header has "cancel" but **no delete button**
   (drafts — name AND address both empty — hide delete). A tab strip shows "connection",
   "advanced", "forwarding", "snippets". The bottom bar is a full-width primary "connect"
   button with a → arrow, disabled (dimmed) while the address is empty.
   <!-- src: Tessera/ContentView.swift (createAndEditNewHost), Tessera/HostDetailView.swift (isDraft, PageHeader onDelete nil for drafts, SegmentedTabBar, connectBar, connectEnabled) -->
2. Connection tab — fill the field groups:
   - "name" (placeholder "my-server"), "address" (placeholder "192.168.1.10"),
     "port" (placeholder "22"; number pad; formatter clamps to 1–65535),
     "user" (placeholder "username").
   - "identity": a menu listing "None" plus every stored key by name. Picking a key
     find-or-creates an Identity wrapping that key (no separate identity management UI).
   - With **no identity chosen** on a fresh draft, a credential card appears instead of a
     plain password field: "authenticate to <name-or-'host'>", tag "first time on this
     device", a secure password input, and the caption "stored only in this device's
     keychain — never synced and never sent to the other device".
   - After choosing a stored key, the card disappears and an optional plain "password"
     field shows.
   -> Expected: all of the above; typing edits write straight to the model (iPad edits are
   live — see edge cases).
   <!-- src: Tessera/HostDetailView.swift (connectionTab, identityField, identityForKey, destinationNeedsCredentialInput, `if !isPhone && !isContinuationDraft && !destinationNeedsCredentialInput` password field), Tessera/Continuity/CredentialCardView.swift -->
3. Transport + launch groups (still connection tab):
   -> Expected: "transport" segmented ssh/mosh with captions "single SSH connection; tmux
   tabs stay on the main session." (ssh) or "mosh terminal over UDP; tmux tabs use a second
   SSH side channel." (mosh). "launch" segmented "auto-tmux" / "named tmux" / "custom":
   auto-tmux caption "attach to per-host tmux session `<derived-name>`."; named tmux shows a
   "tmux session name" field (placeholder "dev") and the caption "letters, numbers, dash,
   underscore, dot only; anything else falls back to the auto-derived name."; custom shows a
   "launch command" field (ssh placeholder "exec tmux -CC new -s dev") captioned "sent
   verbatim to the login shell on connect."
   <!-- src: Tessera/HostDetailView.swift (transportSection, launchSection, autoTmuxDescription, customLaunchPlaceholder/Description), Tessera/PersistedHost.swift (editorDescription) -->
4. Advanced tab:
   -> Expected field groups: "os logo" (auto/manual; auto shows "auto-detected on connect
   (currently: <os>)", manual reveals a picker of macos/ubuntu/debian/alpine/linux/raspbian);
   "terminal background" (global / theme color / image, with dim/blur/fill controls in image
   mode); "tags" (add via field + "add" button, remove by tapping a pill's ✕); "notes"
   (sub "free-form, shown in tooltips and host details"); "environment variables" (sub
   begins "one KEY=value per line; an optional leading `export ` is stripped…") and the
   caption starting "tmux gotcha: env vars and the startup snippet only run when tmux
   *starts*."
   <!-- src: Tessera/HostDetailView.swift (advancedTab, osHintOptions, terminalBackgroundField) -->
5. Snippets tab:
   -> Expected: single "startup snippet" multiline field, sub "commands run immediately
   after connect". <!-- src: HostDetailView.snippetsTab -->
6. Forwarding tab (see §5.5 for depth).
   -> Expected: "port forwarding rules applied when this host connects." + "no rules
   configured" + "+ add forwarding rule".
7. Point the fields at the fixture host (address = `TESSERA_FIXTURE_STABLE_HOST`,
   port = 2222, user = `tessera`, fixture password in the credential card) and tap
   "connect".
   -> Expected: the password is persisted to the keychain behind a created "<name> password"
   identity, then a live terminal session opens full-screen (sidebar hides) and lands in a
   tmux session on the host — with the Unknown Host trust sheet first on a fresh install
   (§6.9). The host now appears in the sidebar "hosts" list and on the landing page.
   <!-- src: Tessera/HostDetailView.swift (connectFromEditor, persistCredentialPasswordIfNeeded), Tessera/ContentView.swift (onConnect → connect(to:)) -->
8. Reopen the host from the sidebar.
   -> Expected: title is now the host's name; the header gains a red "delete" button;
   "cancel" returns to the landing without deleting.

**Device/orientation variants:** see §5.4 for iPhone/compact — the editor's save semantics
differ fundamentally. iPad portrait/landscape: identical form, max content width 560 pt.

**Edge & failure cases:**

- **Draft cancel deletes:** tap "cancel" on a never-touched "new host" draft → the empty
  record is deleted; the sidebar host list stays clean. The trash "delete" button force-
  deletes regardless of content. <!-- src: Tessera/ContentView.swift (dismissEditor(host:deleteIfDraft:force:)) -->
- **iPad cancel is not revert:** type a name or address, then "cancel" → the host is *kept*
  (it no longer qualifies as a draft, and iPad edits are written through SwiftData
  immediately). Expect the partially-filled host in the list. This asymmetry with the phone
  editor is by design.
  <!-- src: Tessera/HostDetailView.swift (isDraft comment; iPad bindings write host.* directly) -->
- **Connect disabled states:** "connect" stays disabled while address is empty, while the
  credential card requires a password that hasn't been typed, or while any password-only
  jump hop lacks a password. <!-- src: HostDetailView.connectEnabled -->
- **Connect with no credential:** with no identity and an empty password, tapping connect is
  blocked with the inline error "Enter a password or choose a key before connecting."
  <!-- src: HostDetailView.persistCredentialPasswordIfNeeded (required: true) -->
- **Invalid port input:** non-numeric or out-of-range port entries are rejected by the
  formatter (min 1, max 65535). <!-- src: HostDetailView NumberFormatter.port -->
- **Relaunch mid-edit:** kill the app with a half-filled draft open. On relaunch the record
  exists (SwiftData persisted it); if both name and address were still empty it is an
  orphan draft that will show as an unnamed row — opening and cancelling it cleans it up.

**Automated coverage:** end-to-end connect against real fixture hosts is exercised by
`TesseraTests/RealHostTransportIntegrationTests.swift` /
`scripts/integration/run-app-transport-tests.sh` (transport level, not through this UI), so
manual testers should focus on the form itself; the editor UI is manual only.

---

### 5.4 Host creation on iPhone / compact windows (staged draft, Save/Cancel)

**Preconditions:** iPhone (any orientation) or iPad Split View compact window. Landing
page, zero or more hosts.

**Steps:**

1. Tap "add your first host" (or "new host").
   -> Expected: the editor opens as a full-screen overlay above the tab bar. Header: title
   "new host" and a 44×44 pt ✕ button (accessibility "cancel") instead of a text cancel
   button. Below the header a two-segment section picker: "connection" and "tunnels" — no
   advanced/snippets sections on phone. The bottom bar has "cancel" and a primary "save"
   (not "connect"); "save" is disabled until the address is non-empty.
   <!-- src: Tessera/ContentView.swift (compact branch: host editor as overlay), Tessera/HostDetailView.swift (PageHeader isPhone xmark, CompactHostSectionPicker "connection"/"tunnels", compactEditorBar, compactSaveEnabled) -->
2. Check the connection section layout.
   -> Expected: address+port share one row (port 86 pt wide), user+identity share one row,
   and a footnote reads "jump chains, environment variables, startup snippets, and terminal
   backgrounds remain editable on iPad." <!-- src: HostDetailView.connectionTab isPhone branches -->
3. Type a name and address, then tap "cancel" (either button).
   -> Expected: edits are **discarded** — phone fields are staged in local state and only
   committed by "save". Since the underlying record is still an empty draft, cancel also
   deletes it: the host list is unchanged.
   <!-- src: HostDetailView (compactName/compactAddress… @State staging; comment "Keep the editable subset local until Save so SwiftData autosave cannot turn Cancel into an accidental commit"), Tessera/ContentView.swift (onCancel → dismissEditor deleteIfDraft: true) -->
4. Recreate, fill name/address/user, tap "save".
   -> Expected: values are trimmed and written, the editor closes back to the hosts tab, and
   the host appears in the list. There is no connect-from-editor on phone — connect by
   tapping the host row. <!-- src: HostDetailView.saveCompactDraft, ContentView onSave (selectedItem = nil) -->
5. Edit an existing host (row ellipsis button → editor), change a field, cancel.
   -> Expected: the change is reverted (staging), and the host is NOT deleted (it isn't a
   draft).

**Device/orientation variants:** identical between iPhone portrait/landscape and compact
iPad windows; the editor compresses rather than clipping (PR stack behavior). The primary
button reads "add & connect" only for a continuation draft arriving from another device
(Handoff/continuity), not for locally created drafts.
<!-- src: Tessera/HostDetailView.swift (compactEditorBar, compactPrimaryTitle), Tessera/ContentView.swift (compactPrimaryTitle argument) -->

**Edge & failure cases:**

- Identity display on phone: an untouched existing host shows its stored identity label
  (name, or "Password" / "Legacy key" / "None") until the picker is touched; after changing
  it, save writes the new identity, and clearing to "None" makes the credential card path
  apply on next connect. <!-- src: HostDetailView.identityDisplayLabel, compactIdentityWasChanged -->
- Forwarding rules edited on phone are staged too — they only apply on "save"
  (`compactPortForwardRules`), after which live tunnels reconcile.
  <!-- src: HostDetailView (forwardingTab stagedRules, saveCompactDraft reconcile task) -->

**Automated coverage:** manual only.

---

### 5.5 Jump host and forwarding rules (iPad editor depth)

**Preconditions:** iPad full screen; at least two saved hosts (one to act as bastion).

**Steps:**

1. Open a host's editor, connection tab, "jump host" group.
   -> Expected: a menu of "none" plus other saved hosts; caption "connect through another
   saved host (SSH bastion / ProxyJump)." when none selected.
   <!-- src: HostDetailView.jumpHostSection -->
2. Pick a bastion.
   -> Expected: caption becomes "path: <bastion> → <this host>"; if the bastion itself has a
   jump host the path extends and appends "(the jump host's own jump host extends the
   chain)". A mosh-transport host adds "mosh UDP cannot traverse bastions — if the mosh
   server is unreachable the session falls back to SSH."
   <!-- src: HostDetailView.jumpChainCaption -->
3. If any hop is password-authenticated with no stored password:
   -> Expected: a field "password · <hop name>" per such hop plus the caption "jump-host
   passwords are kept only for this live session." "connect" stays disabled until each such
   hop has a password. <!-- src: HostDetailView.jumpPasswordInputs, connectEnabled -->
4. Break the chain (delete the bastion from the sidebar), reopen the editor.
   -> Expected: caption becomes a "⚠ …" line ending "connections fail until this is fixed."
   Dependents fail closed rather than silently connecting direct.
   <!-- src: HostDetailView.jumpChainCaption isBroken branch, ContentView dismissEditor comment -->
5. Forwarding tab: tap "+ add forwarding rule".
   -> Expected: an edit card with "local port" (placeholder "8080") → "remote port",
   "remote host" (sub "the address as seen from the SSH server", placeholder "localhost"),
   "label (optional)" (placeholder "web app"), a toggle "auto-start when connecting" (sub
   "open the listener automatically once the SSH session is up"), a "presets" grid, and
   "cancel" / "add rule" buttons ("add rule" disabled until valid).
   <!-- src: Tessera/Forwarding/ForwardingTabView.swift (editCard, addButton) -->
6. Add a rule, then tap it to edit and try switching away with unsaved changes.
   -> Expected: alert "discard changes?" with message "the form has unsaved changes."
   (buttons "discard" / "keep editing"). Deleting a rule asks "delete rule?" with the rule
   summary. <!-- src: ForwardingTabView alerts -->
7. Switch the host's launch mode to "custom" and revisit the forwarding tab.
   -> Expected: the disabled note appears: "this launch mode has no ssh connection to carry
   forwards. switch the launch mode to auto-tmux or pinned-tmux on the connection tab —
   those modes keep an ssh side-channel for tmux that forwarding can ride on. (or change
   transport to ssh.)" <!-- src: ForwardingTabView (isForwardingDisabled note) -->

**Device/orientation variants:** phone exposes the same rule editor under the "tunnels"
section, but rules are staged until Save (§5.4). Jump host configuration is iPad only —
phone shows only the repair password fields when a continuation/credential-setup context
requires them. <!-- src: HostDetailView (jumpHostSection under !isPhone; compactContinuationJumpCredentials) -->

**Edge & failure cases:**

- Rule validation errors render in amber inside the card. Invalid ports must not save.
- A host cannot be offered as its own bastion (eligibility is resolver-filtered).

**Automated coverage:** `TesseraTests/HostJumpChainResolverTests.swift` (chain resolution,
broken chains), `TesseraTests/JumpHostTransportIntegrationTests.swift` (transport through a
jump), and `Tessera/Forwarding/PortForwardBridgeTests.swift` (bridge unit tests). The tab's
UI states and copy are manual only.

---

### 5.6 Quick-connect via `user@host` in the search bar

**Preconditions:** Landing page on iPad or iPhone. A fixture host from §1.5 reachable,
though the parse steps need no network.

What the parser accepts: trimmed input containing **exactly one** `@`; non-empty user;
non-empty address; optional `:port` suffix where the port parses as an integer 1–65535
(default 22). Anything else is silently ignored.
<!-- src: Tessera/ContentView.swift (handleQuickConnect), Tessera/Hosts/HostsLandingView.swift (quickConnectRow onSubmit guards value.contains("@")) -->

**Steps:**

1. Type `tessera@<fixture-host>:2222` in the search field and press the keyboard's "go".
   -> Expected: the field clears and a live session view opens immediately (sidebar hides on
   iPad; on phone it presents over the tab bar). The session is **ephemeral**: it is a Host
   DTO, not a saved host — the hosts list does NOT gain an entry, and it is excluded from
   relaunch session restore (no persisted-host marker). Its display name is the address,
   transport is SSH, launch mode is auto-tmux, and no identity or password is attached.
   <!-- src: Tessera/ContentView.swift (handleQuickConnect builds Host(name: address, …) with default transport .ssh / launchMode .autoTmux, appends LiveSession, selectedItem = .session, sidebarVisible = false; persistRestoreSnapshots skips live sessions without persistedHostID), Tessera/Host.swift (init defaults) -->
2. Observe authentication.
   -> Expected: because quick-connect attaches no key or password, the SSH attempt
   authenticates with an empty credential after the Unknown Host prompt; it succeeds only
   if the target accepts that. Against the password-protected fixture host it fails and
   lands on the "connection failed" overlay (§7.2) rather than an interactive prompt —
   treat the failure surface as the expected first-run outcome. (Use a saved host with a
   stored credential for a guaranteed-green connect.)
   <!-- src: Tessera/SSHAuth.swift (password fallback uses host.password) -->
3. Type `production-web` (no `@`) and press go.
   -> Expected: nothing is submitted — the text stays and simply acts as a host-list filter.
4. Type `a@b@c`, ` @host`, `user@`, and `user@host:99999`, pressing go after each.
   -> Expected: no session opens for any of them (multiple `@`s, empty user, empty address,
   and out-of-range port are all rejected) — but note the field still **clears** for each,
   because the landing view clears on any submission containing `@` even when the parse is
   rejected downstream. No error message is shown; this is a known silent-failure surface
   worth watching in review.
   <!-- src: HostsLandingView.quickConnectRow (onSubmit clears after onQuickConnect), ContentView.handleQuickConnect (guard-return paths) -->
5. Repeat step 1 twice.
   -> Expected: two separate live sessions to the same endpoint (quick-connect never dedups
   into an existing session).

**Device/orientation variants:**

- Placeholder copy differs (§5.2): the phone placeholder only teaches `user@host` once
  hosts exist; the empty-state bottom hint carries the teaching before that. Parsing
  behavior is identical everywhere.

**Edge & failure cases:**

- Whitespace around the input and around user/address/port segments is trimmed before
  parsing (` tessera @ host ` → user "tessera", address "host").
- `user@host:` (trailing colon, empty port) is rejected (empty string fails Int parsing).
- SHARP EDGE — "edit host" from a quick-connect failure overlay: the app removes the
  session and selects a host record that was never persisted. On iPad this falls back to
  the hosts landing; on compact the host-editor overlay resolves to an empty view. Record
  actual behavior — a blank full-screen page here is a bug worth filing.
  <!-- src: Tessera/ContentView.swift (onEditHost -> selectedItem = .host(id); fetchHost(id) == nil -> landing on regular, Color.clear on phone branch) -->

**Automated coverage:** manual only — `handleQuickConnect` has no unit test; the transport
underneath is covered by the app-transport integration lane
(`scripts/integration/run-app-transport-tests.sh`), so manual focus belongs on the parse
acceptance/rejection table and the "field clears on rejected input" quirk.

---
## 6. Keys & first-connection trust

### Codex Desktop QA charter

**Primary mission:** determine whether a user can make safe key and host-trust decisions
without needing to understand Tessera's implementation or cryptographic terminology.

During Pass A:

- Separate three user questions: where private material lives, whether it can be recovered,
  and what remote access changes when a public key is installed.
- Inspect dangerous-action hierarchy. Safe/cancel actions must not be visually subordinate to
  irreversible trust, delete, or unsafe-override actions.
- Read security copy as a non-expert. Flag accurate text that is too dense to support a real
  decision.
- For TOFU and changed-host-key flows, pause before acting and state what the screen appears
  to recommend.
- Exercise wrong passphrase/password, biometric cancellation, unavailable host, and one
  remote-install failure.
- On physical-device missions, treat system biometric and Local Network prompts as part of
  the experience, not external noise.

Any possibility of trusting the wrong key, misunderstanding whether a private key moves, or
believing remote authorization was revoked when only local material was deleted is at least
an S1 candidate and may be S0.

This chapter covers key management for a brand-new user (generate, import, recovery export,
install-to-host, copy public key, delete/cleanup) and the trust surfaces hit on the very first
connection (host-key TOFU sheet, password entry, per-transport differences), plus Known Hosts
page basics and the Handoff device-enrollment approval overlay (§6.14).

<!-- src: Tessera/Keys/GenerateKeyModal.swift, Tessera/Keys/ImportKeyModal.swift,
     Tessera/Keys/KeysPageView.swift, Tessera/Keys/InstallKeyToHostFlow.swift,
     Tessera/Keys/RemoteAuthorizedKeysInstaller.swift, Tessera/HostKeyVerificationView.swift,
     Tessera/SSHAuth.swift, Tessera/KnownHostsStore.swift,
     Tessera/KnownHosts/KnownHostsPageView.swift, Tessera/KeyStore.swift,
     Tessera/HostDetailView.swift, Tessera/Continuity/CredentialCardView.swift,
     Tessera/SessionLaunchOverlay.swift, Tessera/SessionView.swift, Tessera/ContentView.swift,
     Tessera/MoshBootstrap.swift, Tessera/PersistedHost.swift, Tessera/LiveSession.swift,
     Tessera/Enrollment/EnrollmentApprovalView.swift, Tessera/Enrollment/EnrollmentCoordinator.swift -->

**Tester setup (applies to all flows below):**

- Launch with the pre-complete args (§1.4) so Nearby Setup does not re-present over these
  tests. Real-connection flows (install key, TOFU, password failures, mosh) use the fixture
  hosts (§1.5).
- DEBUG-only: `TESSERA_CONTINUITY_HOSTKEY_HARNESS=match` (or `mismatch`) in the environment
  presents the real informed-TOFU sheet with a peer-fingerprint panel and **no SSH session at
  all** — useful for screenshotting the sheet variants safely.
  <!-- src: Tessera/ContentView.swift (presentContinuityHostKeyHarnessIfNeeded) -->
- "Phone layout" is defined in §1.8/§2: all iPhone orientations AND compact iPad windows.
  Every modal in this chapter branches on it (tighter 18pt padding, full-width cards, stacked
  full-width buttons) instead of the iPad width caps (480–620pt cards, horizontal button
  rows). <!-- src: Tessera/Design/DesignTokens.swift (CompactLayout.isPhone), Tessera/Keys/KeysPageView.swift -->

Navigation to the Keys page:

- iPad regular width: sidebar item opens `KeysPageView` as a two-pane layout (340pt list +
  detail); the first key is auto-selected when one exists; empty state reads
  "no keys yet · generate or import one".
- Phone layout: the tab bar's "keys" tab shows a top `CompactViewSelector` toggling between
  "keys" and "known hosts". The keys list has no auto-selection; tapping a key pushes a detail
  view with a back chevron (accessibility label "back to keys"). Empty state: "no keys yet".
<!-- src: Tessera/ContentView.swift (compact tab shell + sidebar cases), Tessera/Keys/KeysPageView.swift -->

---

### 6.1 Generate an Ed25519 key

**Preconditions:** Fresh install (or any state), Keys page open. No biometric enrollment
required. Works fully offline.

**Steps:**

1. Tap "+ generate" (list header, both layouts).
   -> Expected: dark scrim + card modal titled "generate key" with fields "name" (placeholder
   "my new key"), "algorithm" (two cards: "Ed25519" / "fast, modern default" and
   "P-256 Enclave" / "device-bound"), and a toggle "require biometrics or passcode" with
   subtitle "Face ID/Touch ID or passcode whenever Tessera accesses this key".
   Ed25519 is pre-selected; below the algorithm grid the note reads "Ed25519 keys are stored in
   the iOS Keychain and can be exported as a passphrase-encrypted standard OpenSSH recovery
   file." Footer note: "This protection is enforced by iOS at the key boundary. It is separate
   from the recovery-file passphrase."
2. Tap "generate" with the name empty.
   -> Expected: inline red error "name is required" under the name field. Typing any character
   clears it.
3. Enter a name and tap "generate".
   -> Expected: modal closes; the new key is selected. Immediately after, the
   recovery-passphrase modal "protect recovery key" auto-presents (§6.4) — this is
   `beginInitialRecovery`, which for a non-enclave key jumps straight to the export
   passphrase modal.
4. Cancel the recovery modal and inspect the key detail.
   -> Expected: badges "ED25519" and "RECOVERY NOT EXPORTED" (plus "USER PRESENCE" if the
   toggle was on); recovery section text "No verified recovery export is recorded. Device loss
   or local deletion may permanently remove this credential." with button
   "protect recovery key…".

**Device/orientation variants:** Phone layout: card fills the width (18pt padding); iPad: card
capped at 480pt, 28pt padding. Compact iPad windows take the phone variant. No portrait vs
landscape differences beyond that.

**Edge & failure cases:**

- Tapping the dark scrim closes the modal without creating anything (tap on the card itself
  does not).
- The toggle's initial state follows the global Settings preference
  (`KeyOwnerPresencePolicy.initialKeyPreference(globalPreference:)`).
- KeyStore/Keychain failures surface as the localized error inline under the name field; the
  modal stays open.

**Automated coverage:** Key generation/protection semantics:
`TesseraTests/KeyStoreSecurityTests.swift`
(`test_newKeyProtectionDefaultsFollowExplicitGlobalPreference`,
`test_userPresenceProtectionIsAppliedAtKeychainBoundary`,
`test_generationCannotSucceedAfterKeychainAddFailure`). Modal UI itself: manual only.

<!-- src: Tessera/Keys/GenerateKeyModal.swift, Tessera/Keys/KeysPageView.swift
     (beginInitialRecovery, recoverySection, keyBadges) -->

---

### 6.2 Generate a Secure Enclave (P-256) key

**Preconditions:** As above. Note: Secure Enclave availability differs on simulator vs device;
run at least once on hardware.

**Steps:**

1. In "generate key", select the "P-256 Enclave" card.
   -> Expected: the Ed25519 note is replaced by a bordered enclave note: "P-256 keys are
   generated in the Secure Enclave. They cannot be exported or moved to another device. Install
   a separate recoverable Ed25519 key before relying on this credential."
2. Name it and tap "generate".
   -> Expected: modal closes and the risk-acknowledgement modal auto-presents with title
   "device-bound key", the key's SHA256 fingerprint, and body "This Secure Enclave key can
   never be recovered after device loss. Before installing it remotely, keep a second
   recoverable credential on that host." Buttons: "I understand · continue" (danger) and
   "cancel". There is NO "export recovery first" button for enclave keys.
3. Tap "cancel" and inspect the detail.
   -> Expected: badges include "SECURE ENCLAVE"; the public-key field carries the note
   "private key never leaves this device. sync, export, and copy-private-key are disabled.";
   recovery section: "Secure Enclave private material cannot leave this device. Keep a second,
   recoverable credential authorized on every host that uses it." with button
   "acknowledge device-loss risk…". No "export private key…" button exists.
4. Tap "I understand · continue" instead (step 2).
   -> Expected: acknowledgement is recorded and the "copy key to host" sheet opens directly.
   Afterwards the badge "DEVICE-LOSS RISK ACKNOWLEDGED" shows and the acknowledge button is
   gone.

**Device/orientation variants:** Phone layout stacks the risk modal's buttons full-width in
order export (n/a here) / continue / cancel; iPad shows a horizontal row (cancel left,
continue right), card capped at 560pt.

**Edge & failure cases:** Biometrics/passcode note in the detail for enclave keys is
informational only: "changing Secure Enclave protection requires key rotation" with tag
"rotation required" when protection was created off; toggling is not offered.

**Automated coverage:** Enclave intent reconciliation:
`TesseraTests/KeyStoreSecurityTests.swift` (`test_reconciliationNeverOverwritesSecureEnclaveIntent`).
Modal flow: manual only.

<!-- src: Tessera/Keys/GenerateKeyModal.swift (protectionOptions),
     Tessera/Keys/KeysPageView.swift (KeyRiskAcknowledgementModal, beginInitialRecovery,
     requestCopyToHost, keyDetail) -->

---

### 6.3 Import an OpenSSH private key

**Preconditions:** A private-key file reachable via the Files picker. Supported: OpenSSH
Ed25519 private keys (`openssh-key-v1` text), optionally passphrase-encrypted. RSA and all
other algorithms are rejected by design.

**Steps:**

1. Tap "import" in the Keys list header.
   -> Expected: modal "import OpenSSH key" with fields "name" (placeholder "imported key"),
   "private-key file" showing "no file selected" plus the note "The key body is never displayed
   or sent through a keyboard input surface." and a "choose file…" button,
   "source-file passphrase (optional)" (secure input) with note "This passphrase is used once
   to decrypt the selected file and is not retained. Tessera stores the imported key under the
   iOS protection selected below.", and the "require biometrics or passcode" toggle.
2. Tap "import" without choosing a file.
   -> Expected: red error "Choose an OpenSSH private-key file first."
3. Choose a valid unencrypted Ed25519 OpenSSH key file, tap "import".
   -> Expected: modal closes, key is selected, and (as with generate) the
   "protect recovery key" passphrase modal auto-presents.
4. Repeat with a passphrase-encrypted OpenSSH Ed25519 file, entering the correct passphrase.
   -> Expected: same success path.
5. Repeat with the wrong passphrase.
   -> Expected: error "The OpenSSH private key or its passphrase is invalid."; the passphrase
   field is cleared; the modal stays open.
6. Try an RSA private key.
   -> Expected: "RSA import is disabled because the current SSH stack can only offer the
   deprecated RSA/SHA-1 signature. Use Ed25519 instead."
7. Try a non-key text file or binary.
   -> Expected: "The private key is not valid UTF-8 OpenSSH text." (non-UTF-8 data) or
   "The OpenSSH private key or its passphrase is invalid." (unparseable text). Other detected
   algorithms (e.g. ECDSA files): "Importing <algorithm> keys is not supported. Use Ed25519
   instead."
8. Try an empty file or one larger than 1 MB.
   -> Expected: "The selected key file is empty or exceeds the 1 MB safety limit."

**Device/orientation variants:** Phone layout: full-width card, 18pt padding; iPad: 520pt cap.
Same in Split View/Slide Over compact windows (phone variant).

**Edge & failure cases:**

- Backgrounding the app (app switcher) or starting screen capture/mirroring while the modal is
  open blanks it with a black shield reading "private-key import hidden" and clears the
  selected file data and passphrase — re-select the file after returning.
- Closing via scrim tap or "cancel" clears the passphrase and zeroes the loaded file bytes.
- An empty name is allowed; the key lists as "unnamed key".

**Automated coverage:** `TesseraTests/KeyStoreSecurityTests.swift`
(`test_encryptedSourceImportAcceptsCorrectPassphrase`,
`test_encryptedSourceImportRejectsWrongPassphraseBeforeKeychainMutation`,
`test_RSAImportIsDisabledBeforeKeychainMutation`,
`test_importCannotSucceedAfterKeychainAddFailure`). Picker + privacy shield UI: manual only.

<!-- src: Tessera/Keys/ImportKeyModal.swift, Tessera/KeyStore.swift (importKey,
     KeyImportError), Tessera/Keys/KeysPageView.swift (onImported -> beginInitialRecovery) -->

---

### 6.4 Recovery passphrase export (auto-presented after generate/import)

**Preconditions:** A software Ed25519 key just generated or imported (the modal auto-presents),
or tap "protect recovery key…" / "export a new copy…" in the key detail's recovery section.

**Steps:**

1. Observe the modal.
   -> Expected: title "protect recovery key", the key's name, explanation "Tessera will create
   a standard passphrase-encrypted OpenSSH private-key file. Tessera cannot recover this
   passphrase. No plaintext key file is created.", fields "recovery-file passphrase" and
   "confirm passphrase" (both secure), buttons "cancel" and "export encrypted file…".
2. Submit empty.
   -> Expected: "A passphrase is required."
3. Submit fewer than 8 characters.
   -> Expected: "Use at least 8 characters."
4. Submit mismatched confirmation.
   -> Expected: "Passphrases do not match."
5. Submit a valid pair.
   -> Expected: if the key requires user presence, a Face ID/Touch ID/passcode prompt appears
   ("export encrypted recovery for <key name>"); then the system file exporter opens with
   default filename `<key name>-recovery.key`. Saving shows toast
   "encrypted recovery file exported"; the badge flips to "RECOVERY EXPORTED" (green) and the
   recovery section reads "Encrypted OpenSSH recovery exported <date>. Fingerprint <SHA256:…>."
   with buttons "verify recovery file…" and "export a new copy…".
6. Tap "verify recovery file…", pick the exported file, enter its passphrase in the
   "verify recovery file" modal (explanation: "The file will be decrypted in memory and its
   public fingerprint compared with this key. It will not replace the live key.").
   -> Expected: toast "recovery file verified". A wrong file/passphrase shows
   "This recovery key does not match the selected key." or the decrypt error.

**Device/orientation variants:** Phone layout: full-width card; iPad: 500pt cap. Button rows
are identical (trailing cancel/submit) in both.

**Edge & failure cases:**

- Cancel (step 1) is allowed; the key simply stays "recovery not exported". Nothing else
  blocks — but "copy to host…" will later force the risk acknowledgement (§6.6).
- Cancelling the file exporter dialog shows "Recovery export was not completed: …" and does
  NOT mark the key exported.
- Backgrounding or screen capture blanks the modal with "recovery operation hidden" and clears
  both passphrase fields.
- Cancelling the biometric prompt aborts with the toast for
  `AuthResolutionError.biometricCancelled`.
- Restore/repair variant: when a key's badges show "PRIVATE MATERIAL MISSING" / "PRIVATE
  MATERIAL MISMATCH" / "PRIVATE MATERIAL INVALID", the recovery section offers
  "restore from recovery file…" / "repair from matching recovery file…" which run the same
  modal with purpose "restore private key"; success toast "private key restored" and the key
  is restored under the same identity so host references stay intact.

**Automated coverage:** `TesseraTests/KeyStoreSecurityTests.swift`
(`test_encryptedOpenSSHEd25519_roundTripsWithCorrectPassphrase`,
`test_encryptedOpenSSHEd25519_rejectsWrongPassphraseSafely`,
`test_recoveryRestoresMatchingMaterialUnderExistingUUID`,
`test_recoveryRejectsFingerprintMismatchBeforeKeychainMutation`,
`test_exportWithoutAuthorizationForbidsRawKeychainPrompt`). File-exporter UI and toasts:
manual only.

<!-- src: Tessera/Keys/KeysPageView.swift (RecoveryPassphraseModal, RecoveryPassphrasePurpose,
     performRecoveryAction, handleRecoveryExportCompletion, recoverySection),
     Tessera/KeyStore.swift (exportEncryptedEd25519PrivateKey, recoveryFingerprint,
     recoverEd25519Key) -->

---

### 6.5 Copy public key

**Preconditions:** Any non-RSA key selected in the Keys detail.

**Steps:**

1. In the "public key" field, tap "copy public key".
   -> Expected: the full `authorized_keys` line is on the pasteboard; inline toast
   "public key copied" appears for ~1.8 s.
2. Tap "share".
   -> Expected: toast "share ships later" (placeholder — not implemented).

**Device/orientation variants:** None beyond the page layout (phone detail is a pushed
full-screen view; iPad is the right pane capped at 680pt).

**Edge & failure cases:** For legacy RSA keys the button row is replaced by red text
"Legacy RSA is disabled: Tessera cannot authenticate with or install this key. …" — no copy
button.

**Automated coverage:** manual only.

<!-- src: Tessera/Keys/KeysPageView.swift (keyDetail public key Field, showToast) -->

---

### 6.6 Copy key to host (install over SSH)

**Preconditions:** A software Ed25519 key with "recovery exported" (or a key whose device-loss
risk was acknowledged); at least one saved host whose configured identity is a DIFFERENT
working credential (password, or another key) — the fixture host with its password identity
works. The target host's own host key should already be trusted (connect once first).

**Steps:**

1. In the key detail, tap "copy to host…".
   -> Expected (gate): if the key is exported or acknowledged, a sheet "copy key to host"
   opens at step label "pick host". If the key is NOT backed up and unacknowledged, the risk
   modal "recovery not exported" appears first with body "This software key has no recorded
   recovery export. Installing it as the only remote credential can permanently lock you out
   after device loss or accidental deletion.", buttons "export recovery first" (primary),
   "I understand · continue" (danger), "cancel". "export recovery first" routes to the
   passphrase-export modal; continue opens the sheet.
2. Pick a saved host (rows show name and `user@address:port`).
   -> Expected: step "confirm": "About to install <key name> on <host name>" plus an
   "authorized_keys line" block (horizontally scrollable, selectable). Buttons back / cancel /
   install.
3. Tap "install".
   -> Expected: step "installing" with a spinner ("installing key", host name); then step
   "result" with either green "Key installed on <host>" (button "done") or a red failure
   message (buttons "retry" and "done").
4. On the remote host, verify what was done over SSH.
   -> Expected: Tessera connected with the host's configured credential and ran an idempotent
   append: `mkdir -m 700 -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600
   ~/.ssh/authorized_keys && { grep -qxF '<line>' … || echo '<line>' >> … }` followed by a
   verify command that must print `TESSERA_KEY_INSTALLED`. Re-running install adds no
   duplicate line. The installation is recorded in the local security ledger
   (uncertain-before-write, verified-after-check).
5. Back in the key detail.
   -> Expected: "used by" reflects hosts whose identity uses this key (assignment happens in
   the host editor, not here).

**Device/orientation variants:** The sheet content is width-capped at 560pt in all
environments; on phone it is a full-screen sheet. No other differences.

**Edge & failure cases:**

- Selected host authenticates WITH the key being installed -> "This host uses this key for
  authentication. Choose a host identity that uses a different key or password."
- Target host key never trusted -> the install path runs promptless and fails after a short
  grace with "Host key was not trusted. Connect once first to review it, then retry."
- Wrong credential -> "Authentication failed" (or the server-specific message); unreachable ->
  "Network unreachable: …". Remote write failure -> "Could not write to
  ~/.ssh/authorized_keys: …"; verification failure -> "Could not verify …".
- Gate toasts instead of opening the sheet when the key is unusable:
  "Restore the missing private key before installing it" (material missing),
  "Repair the rejected private material before installing it" (mismatch/invalid),
  "Key integrity is unavailable; installation is blocked",
  "Legacy RSA installation is disabled; rotate to Ed25519".
- "no saved hosts" placeholder if none exist.
- Closing the sheet mid-install cancels the task; retry from the failure screen re-runs.
- RSA key opened into the sheet shows a blocking message and only "done".

**Automated coverage:** Command construction, idempotency, self-install and route validation:
`TesseraTests/RemoteAuthorizedKeysInstallerTests.swift`; ledger records:
`TesseraTests/RemoteInstallationLedgerTests.swift`. Full live loop (generate, install via
password credential, then authenticate with the key):
`TesseraTests/RealHostTransportIntegrationTests.swift`
(`test_generateInstallAndAuthenticateWithEd25519Key`) via
`scripts/integration/run-app-transport-tests.sh` with `fixture.env`. Sheet UI: manual only.

<!-- src: Tessera/Keys/InstallKeyToHostFlow.swift, Tessera/Keys/RemoteAuthorizedKeysInstaller.swift
     (makeInstallCommand, makeVerifyCommand, InstallError, validateCanInstall),
     Tessera/Keys/KeysPageView.swift (requestCopyToHost, KeyRiskAcknowledgementModal) -->

---

### 6.7 Delete local private key

**Preconditions:** Any key selected. Danger flow — use a throwaway key.

**Steps:**

1. Tap "delete local private key…" at the bottom of the detail.
   -> Expected: red-bordered modal "delete local private key" with the fingerprint, a backup
   line ("No recovery export is recorded. Deletion may be permanent." / "A recovery export was
   recorded <date>. Confirm that you still possess its passphrase before deleting." /
   "This Secure Enclave key is permanently unrecoverable after deletion."), a references line
   "Local references: N identit(y/ies) and M host(s). They will be detached before deletion.",
   and "Known remote installations: N. Deleting locally does not revoke any authorized_keys
   entry; remove this public key from every remote host separately." Host-name tags listed if
   any.
2. If the ledger tracks installs on hosts that still have a reachable alternate credential, a
   primary button "revoke on N tracked host(s) & delete" appears alongside
   "local delete only" (danger) and "cancel".
3. Tap "local delete only".
   -> Expected: modal closes, selection clears, toast "local private key deleted; remote
   authorizations were not revoked" (or the revoked/preserved variants).
4. Tap "revoke on N tracked host(s) & delete" instead.
   -> Expected: spinner replaces the buttons; on success the key is deleted with toast
   "local private key deleted after revoking N tracked remote authorization(s)"; on failure
   "Remote revocation failed; the local key was not deleted: …" and the key remains.

**Device/orientation variants:** Phone layout stacks full-width buttons (revoke, delete,
cancel); iPad horizontal row, card capped at 620pt.

**Edge & failure cases:** Deletion failure leaves material untouched ("Local key deletion
failed; private material was not touched: …"). A crash-interrupted deletion resumes via the
deletion-intent journal and can surface as an orphan (§6.8).

**Automated coverage:** `TesseraTests/KeyStoreSecurityTests.swift`
(`test_keyDeletionPreservesKeychainStatusAndMaterial`,
`test_unattendedDeletionDoesNotReadPrivateMaterial`,
`test_deletionJournalResumesAfterCrashBoundaryWithoutSecrets`); revoke command semantics:
`TesseraTests/RemoteAuthorizedKeysInstallerTests.swift` (semantic revoke tests). Modal UI:
manual only.

<!-- src: Tessera/Keys/KeysPageView.swift (KeyDeletionConfirmationModal, deleteConfirmed,
     revokeRemotelyThenDelete, eligibleRemoteRevocationHosts) -->

---

### 6.8 Orphaned Keychain cleanup

**Preconditions:** Rare in normal use — appears when Keychain private material exists without
matching key metadata (e.g. interrupted deletion, reinstall remnants). Detected on every Keys
page appearance via an integrity report.

**Steps:**

1. Open the Keys page with orphans present.
   -> Expected: above the key list, red text "N orphaned Keychain item(s)" with
   "Private material exists without matching key metadata." and a button "review cleanup…".
2. Tap "review cleanup…".
   -> Expected: red-bordered modal "delete orphaned private material": "Tessera found N
   Keychain item(s) with no matching key metadata. They cannot be selected, authenticated
   with, exported, or associated with a host. This removes only those inaccessible orphaned
   items." Buttons "delete N orphaned item(s)" (danger) and "cancel".
3. Confirm.
   -> Expected: toast "orphaned private material deleted" (or "Some orphaned Keychain items
   could not be deleted"), and the banner disappears.

**Device/orientation variants:** Phone layout stacks the two buttons full-width; iPad
horizontal, 560pt cap. The banner itself renders in both the phone list and the iPad left
pane.

**Edge & failure cases:** On real devices a protected item can block the bulk inventory; the
page then falls back to per-key checks and hides orphan cleanup rather than guessing
(pending-deletion intents still show).

**Automated coverage:** `TesseraTests/KeyStoreSecurityTests.swift`
(`test_integrityReportDetectsMetadataOnlyAndOrphanedItemsWithoutData`). Banner/modal: manual
only.

<!-- src: Tessera/Keys/KeysPageView.swift (refreshIntegrityReport, OrphanedKeyCleanupModal,
     cleanupOrphanedPrivateMaterial), Tessera/KeyStore.swift (IntegrityReport) -->

---

### 6.9 First connection: unknown host key (TOFU accept/reject)

**Preconditions:** Fresh install (empty `known_hosts.json`), a saved host with working
credentials, transport ssh or mosh. The store lives at
`Application Support/known_hosts.json`, keyed by `address:port`.

**Steps:**

1. Connect to the host for the first time.
   -> Expected: during the handshake a blocking sheet appears (interactive dismissal
   disabled): amber half-shield icon, title "Unknown Host", the endpoint, a
   "Server fingerprint:" block (`SHA256:` + base64, matching OpenSSH's default sha256
   display), a "Key type:" block (e.g. `ssh-ed25519`), and full-width buttons
   "Trust & Connect" (primary) and "Cancel".
2. Tap "Trust & Connect".
   -> Expected: handshake completes and the terminal opens. The store persists a record
   (fingerprint, key string, firstSeen, lastSeen) for `address:port`; subsequent connections
   verify silently (no sheet) and only bump lastSeen.
3. Disconnect, reconnect.
   -> Expected: no prompt.
4. Fresh state again; this time tap "Cancel".
   -> Expected: the handshake fails; the session launch overlay switches to "connection
   failed" with the reason and buttons "edit host" / "retry" / "back" (§7.2). Nothing is
   persisted — retrying prompts again.

**Device/orientation variants:** The sheet content is width-capped at 560pt; phone shows a
full-screen sheet, iPad a centered sheet. Identical in both orientations.

**Edge & failure cases:**

- Two sessions racing to the same unknown host: identical challenges coalesce into one sheet
  whose decision answers both. When a DIFFERENT challenge arrives while one is pending, the
  PREVIOUS pending request is auto-rejected and the sheet switches to the newly arrived
  challenge — the newest prompt wins, so only one shows at a time, and the session whose
  request was rejected fails to its launch-failure overlay.
  <!-- src: Tessera/ContentView.swift (onReceive hostKeyVerificationPublisher: isSameChallenge -> coalesce; otherwise `if let previous = hostKeyRequest { previous.reject() }; hostKeyRequest = request`) -->
- Promptless side channels (key install, file bridge, tmux side channel) never present this
  sheet; they wait ~1 s for an equivalent prompted decision, then fail closed.
- Continuation/Handoff connects may add a peer panel: green "Matches the key <peer> trusts."
  when the other device's pinned fingerprint matches; amber "Differs from the key <peer>
  trusts. Verify out of band before connecting." when it does not — in the mismatch case the
  buttons invert to "Don't Connect" (primary) and "Trust Anyway" (danger). Accepting a
  matching peer hint stores an audit label shown on the Known Hosts page ("matched peer").
  DEBUG: use `TESSERA_CONTINUITY_HOSTKEY_HARNESS=match|mismatch` to present these variants
  without SSH.

**Automated coverage:** Store semantics: `TesseraTests/KnownHostsStoreTests.swift`. Prompt
coalescing/promptless grace: `TesseraTests/HostKeyVerificationRequestTests.swift`. Live
end-to-end TOFU + PTY over both transports:
`TesseraTests/RealHostTransportIntegrationTests.swift` (`test_liveSSHPasswordTOFUAndPTY`,
`test_liveMoshPasswordTOFUAndPTY`, `test_liveSSHInformedTOFUMismatchRequiresExplicitUnsafeOverride`)
via `scripts/integration/run-app-transport-tests.sh`. The informed-TOFU **peer-panel edge
case** (last bullet above) is covered end-to-end in the real sheet by
`ContinuityHarnessTests.testInformedTOFUMatchPromotesTrustedAction` /
`testInformedTOFUMismatchPromotesSafeAction`
(`TesseraUITests/TerminalScrollHarnessTests.swift`, lane
`scripts/integration/run-continuity-harness-tests.sh`): match promotes "Trust & Connect",
mismatch promotes "Don't Connect" with a "Trust Anyway" secondary — spot-check only.
Manual only: the plain (no-peer-panel) sheet visuals, real cross-device Handoff variants,
and the "matched peer" audit label on the Known Hosts page.

<!-- src: Tessera/HostKeyVerificationView.swift, Tessera/SSHAuth.swift
     (TesseraHostKeyValidator, HostKeyVerificationCoordinator), Tessera/KnownHostsStore.swift
     (check/trust/touch), Tessera/ContentView.swift (.sheet(item: $hostKeyRequest),
     onReceive hostKeyVerificationPublisher), Tessera/SessionLaunchOverlay.swift -->

---

### 6.10 Changed host key (possible MITM)

**Preconditions:** A host already trusted once; then its key rotated (fixture chaos host, or a
re-keyed test server).

**Steps:**

1. Reconnect.
   -> Expected: red variant of the sheet: exclamation shield, title "HOST KEY CHANGED", warning
   panel "WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!" with body "The host key for this
   server has changed since the last connection. This could indicate a man-in-the-middle
   attack, or the server was reinstalled.", blocks "Old fingerprint:", "Server fingerprint:",
   "Key type:", buttons "Trust" (primary) and "Cancel".
2. Tap "Cancel".
   -> Expected: connection fails, BUT the store has already recorded the new fingerprint as
   pending — the Known Hosts page now flags this endpoint "MISMATCH" persistently even though
   nothing was trusted.
3. Reconnect and tap "Trust".
   -> Expected: connects; the record is overwritten, the pending state clears, and the old
   fingerprint is preserved as "previous fingerprint:" in the Known Hosts detail row.

**Device/orientation variants:** Same as the unknown-host sheet.

**Edge & failure cases:** If the server reverts to the originally trusted key, the pending
mismatch clears automatically on the next successful check.

**Automated coverage:** `TesseraTests/KnownHostsStoreTests.swift`
(`test_check_recordsPendingFingerprint_onChange`,
`test_check_clearsPending_whenHostRevertsToTrustedKey`,
`test_trust_overrideStoresPreviousFingerprint`). Live sheet: manual only.

<!-- src: Tessera/HostKeyVerificationView.swift (changedWarningPanel),
     Tessera/KnownHostsStore.swift (pendingFingerprint/previousFingerprint) -->

---

### 6.11 Password entry and first-connect failures

**Preconditions:** Fresh install; new host being created in the host editor (§5.3). Note:
Tessera has NO mid-handshake password dialog — passwords are collected in the host editor
before connect and stored (per identity) in the device-only Keychain.

**Steps:**

1. Create a host with address/user and no key identity (identity "None").
   -> Expected: because the destination has no usable credential, the editor shows the
   credential card: "authenticate to <host name>" / "first time on this device", a secure
   "password" input, and the note "stored only in this device's keychain — never synced and
   never sent to the other device". The Connect action stays disabled until the password is
   non-empty (`connectEnabled`).
2. Enter the correct password and connect.
   -> Expected: launch overlay ("connecting — …"), then the TOFU sheet (first time), then the
   terminal.
3. Repeat with a wrong password.
   -> Expected: the TOFU/trust step still happens first (host key precedes auth); then the
   launch overlay switches to the failure state (§7.2): "connection failed" + reason
   (authentication failure text), buttons "edit host" (primary) / "retry" / "back".
   "edit host" reopens the editor where the password can be corrected.
4. Hosts routed through jump hosts whose hop identity is password-backed but has no stored
   password show per-hop fields "password · <jump host name>" with the caption
   "jump-host passwords are kept only for this live session." — these are transient and
   re-requested next launch.

**Device/orientation variants:** On iPad regular width, an additional plain "password" field
shows in the editor even when a stored credential exists (transient override); the phone
compact editor omits it unless credential input is required. Phone editor also notes
"jump chains, environment variables, startup snippets, and terminal backgrounds remain
editable on iPad."

**Edge & failure cases:** Backgrounding mid-connect: the attempt continues; if it fails while
backgrounded the failure overlay is waiting on return. Empty user is allowed at save time but
the credential card gates connect on a password.

**Automated coverage:** Wrong-password classification over live transports:
`TesseraTests/RealHostTransportIntegrationTests.swift`
(`test_liveSSHWrongPasswordIsClassifiedAsFailure`,
`test_liveMoshWrongPasswordIsClassifiedAsFailure`). Editor gating and credential card: manual
only.

<!-- src: Tessera/HostDetailView.swift (connectEnabled, destinationNeedsCredentialInput,
     jumpPasswordInputs, connectFromEditor), Tessera/Continuity/CredentialCardView.swift,
     Tessera/SessionLaunchOverlay.swift (LaunchOverlayFailure), Tessera/SSHAuth.swift
     (describeSSHError) -->

---

### 6.12 First connection per transport: ssh vs mosh vs tmux auto-attach

**Preconditions:** Same host reachable over SSH and (for mosh) UDP with `mosh-server`
installed; a second run against a host WITHOUT tmux (fixture `tessera-notmux` user) for step 4.

**Steps:**

1. In the host editor's transport section note the copy: ssh — "single SSH connection; tmux
   tabs stay on the main session."; mosh — "mosh terminal over UDP; tmux tabs use a second SSH
   side channel."
2. Connect with transport ssh (defaults untouched).
   -> Expected: hosts default to launch mode auto-tmux; after auth the session attaches to (or
   creates) a per-host tmux session with a SHA-derived name `tessera-XXXXXXXX` (the host
   editor's launch section shows exactly "attach to per-host tmux session `tessera-…`."). The
   sidebar/session label reads "<host> (tmux)".
3. Connect with transport mosh.
   -> Expected: the FIRST hop is still an SSH bootstrap, so the same TOFU sheet and the same
   credentials apply; mosh then runs `mosh-server new` and switches to UDP. Launch copy for
   auto-tmux mosh: "start mosh inside per-host tmux session `tessera-…`.". A first-time user
   sees no extra prompts beyond ssh.
4. Connect (either transport, auto-tmux) to a host without tmux.
   -> Expected: the connection still succeeds as a plain shell; a dismissible dark banner
   appears: "tmux not available on remote host — multi-window features disabled".
5. Connect over mosh to a host without `mosh-server`.
   -> Expected: failure overlay with "Could not start mosh: the remote host does not have
   `mosh-server` installed or on PATH."

**Device/orientation variants:** None specific to trust/first-connect. (Terminal geometry
differs per device but is out of scope here.)

**Edge & failure cases:** Launch mode "custom command" bypasses tmux entirely (command "sent
verbatim to the login shell on connect." for ssh; "run by `mosh-server new -- <command>` as
the initial command." for mosh) — no tmux banner logic applies.

**Automated coverage:** `TesseraTests/RealHostTransportIntegrationTests.swift`
(`test_liveSSHPasswordTOFUAndPTY`, `test_liveMoshPasswordTOFUAndPTY`, tmux viewport tests) and
`TesseraTests/MoshBootstrapTests.swift` for bootstrap errors, all via
`scripts/integration/run-app-transport-tests.sh` + `fixture.env`. Banner UI: manual only.

<!-- src: Tessera/PersistedHost.swift (HostLaunchMode, launchModeRaw default "autoTmux",
     transport descriptions), Tessera/HostDetailView.swift (autoTmuxDescription,
     customLaunchDescription), Tessera/LiveSession.swift (displayLabel),
     Tessera/MoshBootstrap.swift (MoshBootstrapError), Tessera/MoshSession.swift
     (hostKeyPrompt), Tessera/SessionView.swift (NoTmuxBanner),
     Packages/TmuxControl/Sources/TmuxControl/AutoTmuxScript.swift (defaultSessionName) -->

---

### 6.13 Known Hosts page basics

**Preconditions:** At least one trusted host; ideally one changed-key endpoint for the
mismatch states. Reached from the iPad sidebar ("known hosts") or the phone "keys" tab's
top selector ("keys | known hosts").

**Steps:**

1. Open the page.
   -> Expected: title "known hosts"; filter chips "all · N", "verified", "stale", "changed";
   rows sorted by last-seen descending. Status per row: green dot + "verified" (seen within
   90 days), amber + "stale" (lastSeen older than 90 days), red + "MISMATCH" (pending changed
   key). Default port `:22` is stripped from the displayed host; non-standard ports show
   verbatim.
2. With any changed-key rows, observe the banner above the chips.
   -> Expected: red banner "N host key(s) has/have changed since last connect — review before
   reconnecting", and mismatch rows get a faint red row tint.
3. Tap a row.
   -> Expected: it expands to a detail: "current fingerprint: …" (selectable); optional
   "matched <peer> at trust time" (green, when the key was trusted with a matching peer hint);
   "previous fingerprint: …" after an accepted rotation; on changed rows a warning
   "⚠ remote host identification has changed. man-in-the-middle attack, or server key was
   rotated." plus "new fingerprint: …". Actions: "copy fingerprint", "accept new key"
   (changed rows only — trusts the pending key in place), "remove" (danger — deletes the
   record; the next connect prompts TOFU again).
4. Use each filter chip.
   -> Expected: the table narrows to that status; "all · N" count matches the row total.

**Device/orientation variants:** iPad regular width shows a column header row
(host / algo / added / status) and header buttons "export" and "import" — both are currently
placeholders with empty actions (tapping does nothing); phone hides them and uses stacked
compact rows (>=58pt) with the algo tag and "added <date>" inline. Compact iPad windows use
the phone layout. Filter chips scroll horizontally on narrow widths.

**Edge & failure cases:**

- "accept new key" on a row whose pending key string is missing is a no-op (logged).
- Records imported from a Nearby Setup peer show the "matched peer" tag with label
  "Imported from <device>"; a conflicting import never overwrites a local pin — it surfaces
  as a pending MISMATCH for explicit review here.
- Removing a record does not touch the host entry or its credentials.

**Automated coverage:** Status thresholds, sorting, pending/previous fingerprints, import
conflict behavior: `TesseraTests/KnownHostsStoreTests.swift`. Page UI, filters, expand
actions: manual only.

<!-- src: Tessera/KnownHosts/KnownHostsPageView.swift, Tessera/KnownHostsStore.swift
     (staleThresholdDays, DisplayRow, importTrustedRecord, endpointHost),
     Tessera/ContentView.swift (CompactViewSelector wiring) -->

---

### 6.14 Device enrollment approval overlay (Handoff "authorize this device")

This is the overlay listed in the §2.2 inventory at `zIndex 120`. It mounts — full-screen,
above the Nearby Setup layer — whenever the enrollment coordinator's phase is not idle, on
BOTH roles of a Handoff key enrollment:
<!-- src: Tessera/ContentView.swift — `if enrollmentCoordinator.phase.isPresented { EnrollmentApprovalView(...).zIndex(120) }`; Tessera/Enrollment/EnrollmentCoordinator.swift — Phase.isPresented (every case except .idle) -->

- **Requester** (the new device): entry is the Handoff continuation credential card for a
  never-seen host — below the password field, an accent panel "authorize this device from
  your other device" / "installs this device's public key over the session already open
  there — no password moves between devices". The button exists only while a continuation
  draft for that host is active and its activity supports continuation streams.
  <!-- src: Tessera/Continuity/CredentialCardView.swift — onAuthorizeFromPeer panel; Tessera/ContentView.swift — continuationEnrollmentAction guards (continuationDraft, activity.supportsContinuationStreams) -->
- **Origin** (the device with the live authenticated session being handed off): the overlay
  presents over whatever is on screen when the requester's enrollment request arrives on the
  continuation streams.
  <!-- src: Tessera/ContentView.swift — activityBroadcaster.onContinuationStreams -> enrollmentCoordinator.acceptOriginStreams -->

**Preconditions:** Two physical devices on the same Apple Account with Handoff enabled
(real cross-device Handoff is physical-only — §1.2), "hand off sessions" on (Settings →
sync & continuity), a live authenticated session focused on the origin, and the requester
arriving via the session's Handoff continuation into the "add host & connect" credential
editor.

**Steps:**

1. **[Requester]** Tap "authorize this device from your other device".
   -> Expected: the overlay opens: "Requesting Access" — "Keep Tessera open on both
   devices." with the progress row "Waiting for your other device…" and a full-width
   "Cancel" button. Only the device public key is sent — no password or private key.
   <!-- src: Tessera/Enrollment/EnrollmentApprovalView.swift — headerTitle/.openingStreams/.requesting, progressPanel; Tessera/Enrollment/EnrollmentCoordinator.swift — requestAuthorization -->
2. **[Origin]** The approval overlay appears.
   -> Expected: "Authorize Device" — "Review the exact host and public key before granting
   access." with detail rows "device (self-reported)", "host", "endpoint", "key" (e.g.
   "Ed25519 · software key (peer-reported)"), "fingerprint", the green note "Approve sends
   only this public key to the host. No password or private key crosses devices.", and
   buttons "Authorize with Face ID / Passcode" (primary) and "Deny". The host row shows the
   ORIGIN's local name for its focused session — peer-supplied labels are never used to
   describe where the mutation occurs.
   <!-- src: Tessera/Enrollment/EnrollmentApprovalView.swift — approvalDetails, actions; Tessera/Enrollment/EnrollmentCoordinator.swift — approvalHostName comment ("Local, authoritative consent target") -->
3. **[Origin]** Tap "Authorize with Face ID / Passcode" and authenticate.
   -> Expected phase sequence: "Confirm Your Identity" — "A fresh device-owner check is
   required for every grant." → "Installing Public Key" — "Tessera is adding the approved
   public key to authorized_keys." → "Recording Authorization" — "Completion waits until
   both devices durably record the authorization."
   <!-- src: Tessera/Enrollment/EnrollmentApprovalView.swift — headerTitle/headerSubtitle for .authorizing/.installing/.syncingRecords -->
4. Both sides complete.
   -> Expected: "Access Granted to <host>" with the green panel "The approved public key
   was installed and recorded on both devices. No private key crossed devices." and a
   "Done" button. On the REQUESTER, completion immediately starts the connection to the
   host with the newly enrolled key (the original Authorize tap is the user action that
   starts it); "Done" dismisses the overlay onto that session.
   <!-- src: Tessera/Enrollment/EnrollmentApprovalView.swift — .completed panel; Tessera/ContentView.swift — onRequesterEnrollmentCompleted -> connect(to:) -->
5. **[Origin]** Repeat and tap "Deny" instead.
   -> Expected requester: "Request Denied" — "The other device declined the request. No
   host access changed."
   <!-- src: Tessera/Enrollment/EnrollmentApprovalView.swift — .rejected panel -->
6. Background either device mid-flow.
   -> Expected: the enrollment cancels on that device ("Enrollment Cancelled" — "Enrollment
   was cancelled and the continuation streams were closed."); an enrollment channel never
   survives backgrounding. Locking the origin (Face ID app lock) cancels the same way —
   lock is a stronger boundary than scene lifecycle.
   <!-- src: Tessera/Enrollment/EnrollmentCoordinator.swift — applicationDidEnterBackground(), applicationDidLock() -->

**Device/orientation variants:** Overlay content is width-capped at 560 pt and identical on
every matrix row — it presents above whichever shell is active.
<!-- src: Tessera/Enrollment/EnrollmentApprovalView.swift — .frame(maxWidth: 560) -->

**Edge & failure cases:**

- Request targeting a different host than the origin's focused session is auto-rejected;
  the origin fails with "The peer requested a different host than the focused session."
  <!-- src: Tessera/Enrollment/EnrollmentCoordinator.swift — reconcileServiceState .awaitingApproval hostID guard, CoordinatorError.hostMismatch -->
- "Cancel" on the requester during "Requesting Access" ends the attempt; "Done" on any
  terminal state (granted/denied/cancelled/failed) resets the overlay to idle.
- Failure states render the red "Enrollment Failed" header with the specific message (e.g.
  "The continuation channel closed before enrollment completed.").
  <!-- src: Tessera/Enrollment/EnrollmentCoordinator.swift — message(for:) table -->

**Automated coverage:** all four `Enrollment*Tests` classes (messages, service, coordinator,
continuation stream transport) run in the `app_sync_security_and_lifecycle_units` lane
(§9.1) — the protocol, the single fresh biometric per grant, host-mismatch rejection, and
durable-record ordering are covered; spot-check only. The overlay UI itself, real Handoff
stream establishment, and the cross-device UX are **manual only** (physical devices — §1.2).

---
## 7. First session basics

### Codex Desktop QA charter

**Primary mission:** judge the first five minutes after Connect: whether progress feels alive,
failure feels recoverable, and the terminal controls are discoverable without covering or
destabilizing the terminal.

During Pass A:

- Time the subjective gaps between tap, trust prompt, authentication, tmux attach, and first
  usable terminal frame.
- Try one impatient second tap during a slow transition and record whether the UI prevents or
  compounds duplicate action.
- Cause a wrong-password failure and attempt recovery using only the presented actions.
- On iPhone, test with software keyboard visible, hidden, and returned; watch the accessory
  bar, terminal focus, and top controls.
- Leave a session running, navigate elsewhere, return, then disconnect from both inside and
  outside the session.
- Open Files for the first time and judge whether lazy connection state is clear and whether
  the terminal remains trustworthy while the panel is loading or failing.

Focus on stale loading screens, ambiguous connected state, dead-looking terminal frames,
controls crowded near Disconnect, unexplained tmux behavior, and failures that discard useful
context.

Scope: what a brand-new user hits from "tap connect" through their first minutes inside a
live terminal — the launch overlay and its failure state, the session top bar, the tmux
auto-attach default, the iPhone keyboard accessory bar, the Files panel's first open,
leaving vs disconnecting, and session restore on relaunch. Power features (panes, SwipePad,
forwarding rules, agents, continuity) are outside onboarding scope.

The three connect entry points overlap earlier chapters — deduped as follows:

- **Saved host row** — §7.1 (canonical, below).
- **Host editor "connect"** — §5.3 step 7 (iPad; compact saves instead of connecting, §5.4).
- **Quick-connect `user@host`** — §5.6.
- The trust sheets that interleave with any first connect are §6.9–§6.11.

**Prerequisites for every flow in this chapter:**

- A real SSH fixture host (§1.5): user `tessera` on port `2222` of the stable host; the
  restricted `tessera-notmux` user for the no-tmux fallback.
- Pre-complete first-open with the launch args (§1.4) — critical for the relaunch-heavy
  restore flow, since Nearby Setup otherwise re-presents on every launch. Keep
  `TESSERA_FORCE_TOUR_STEP` unset.

**Explicit QA exclusions (product-owner decision, 2026-07-30):**

- Do not run extreme Dynamic-Type/accessibility-size layout stress against the session-restore
  sheet. Validate its functional actions and ordinary layout at the default text size.
- Do not audit the accessibility hierarchy for duplicated hidden session controls, modal
  background controls, failed-connection recovery actions, or compact root-tab children.
  Revisit these cases only when explicitly requested or when attached to a blocking visible
  user flow.

**Defaults that matter here (all code defaults, no setup needed):**

- New hosts launch in tmux auto-attach mode: `PersistedHost.launchModeRaw = "autoTmux"` /
  `Host.launchMode = .autoTmux`, `autoTmux = true`. <!-- src: Tessera/PersistedHost.swift, Tessera/Host.swift -->
- The accessory bar is on by default (`showAccessoryBar = true`). <!-- src: Tessera/Design/AppearancePreferences.swift -->
- Session restore policy defaults to `ask`; on the compact shell `ask` is treated as
  restore-on-launch. <!-- src: Tessera/SessionRestoreStore.swift (SessionRestorePresentationPolicy) -->
- "Compact" below means `CompactLayout.isPhone` (§2): iPhone idiom in ANY orientation, or an
  iPad window whose horizontal size class is compact (Split View / Slide Over).
  <!-- src: Tessera/Design/DesignTokens.swift (CompactLayout.isPhone) -->

---

### 7.1 Connect from a saved host row

**Preconditions:** App installed, first-open pre-completed (launch args above). One saved
host pointing at the fixture endpoint (`tessera@<stable-host>:2222`, password identity saved).
App has never connected to this endpoint before (fresh install or Known Hosts record removed),
so the first connect is a trust-on-first-use event.

**Steps:**

1. Land on the hosts page. -> Expected: header "hosts" with a "new host" button; a search field;
   a "RECENT" card grid and an "all hosts · N" list. The saved host shows name, `user@address`,
   port, and transport (`ssh` or `mosh`).
   <!-- src: Tessera/Hosts/HostsLandingView.swift -->
2. Tap the host row (or a RECENT card). -> Expected: the row connects immediately — no editor
   detour — because the host has usable credentials. The session opens full-screen and the
   branded launch overlay appears: Tessera mark with breathing glow, lowercase mono caption
   "connecting", and an indeterminate accent bar.
   <!-- src: Tessera/ContentView.swift (landing onConnect -> hostRouteHasUsableCredentials -> connect), Tessera/SessionLaunchOverlay.swift -->
3. During the SSH handshake the blocking "Unknown Host" sheet appears (full trust script:
   §6.9). -> Expected: the sheet cannot be swipe-dismissed (`interactiveDismissDisabled`).
   <!-- src: Tessera/HostKeyVerificationView.swift, Tessera/ContentView.swift (.sheet(item: $hostKeyRequest)) -->
4. Tap "Trust & Connect". -> Expected: overlay caption crossfades "connecting" -> "starting tmux"
   -> "attaching pane" (SSH) with a second dim line showing the resolved tmux session name
   (first-ever connect: `tessera-` + 8 hex chars derived from `user@address:port`).
   <!-- src: Tessera/SessionView.swift (launchPhase, launchSubtitle), Packages/TmuxControl/Sources/TmuxControl/AutoTmuxScript.swift (defaultSessionName), Tessera/AutoTmuxHostStorage.swift -->
5. Overlay fades out on first pane render. -> Expected: live shell prompt inside a tmux session;
   the top bar shows the tmux tab strip (§7.3). No stray shell output from the bootstrap
   one-liner is visible (passthrough output is suppressed until control mode).
   <!-- src: Tessera/SessionView.swift (onChange of tmux.isInitialRenderReady -> launchOverlayVisible = false; suppressPassthroughOutputUntilControlMode) -->
6. Return home (house icon on iPad / back chevron on compact) and tap the same host row again.
   -> Expected: NO second connection is spawned — the app switches to the existing live session
   (singleton auto-tmux reuse keyed on host + `.autoTmux`). The landing row/card shows a pulsing
   green dot while the session is active.
   <!-- src: Tessera/ContentView.swift (connectSavedHost singleton-tmux branch), Tessera/Hosts/HostsLandingView.swift (isActive StatusDot) -->

**Device/orientation variants:**

- iPhone / iPhone Max: the "all hosts" table becomes `CompactHostRow`s (badge + name + endpoint,
  trailing port/transport, `…` edit button with a 36×44 hit frame); RECENT grid drops to 2
  columns. The opened session covers the tab bar; the status bar hides while a session is
  selected. <!-- src: Tessera/Hosts/HostsLandingView.swift (CompactHostRow, recentColumns), Tessera/ContentView.swift (.statusBarHidden) -->
- iPad Split View / Slide Over: same phone-style hosts list (compact size class), same connect
  behavior.
- Portrait vs landscape: no behavioral difference in this flow.

**Edge & failure cases:**

- Tap "Cancel" on the Unknown Host sheet -> the handshake is rejected; the launch overlay flips
  to its failure state (§7.2) instead of showing a dead shell.
- Host row whose credentials are NOT usable (identity removed, key material missing, broken jump
  chain) -> tapping the row opens the host editor instead of connecting.
  <!-- src: Tessera/ContentView.swift (hostRouteHasUsableCredentials else selectedItem = .host) -->
- Two hosts connecting simultaneously -> only one host-key prompt at a time; a second pending
  request rejects the first. <!-- src: Tessera/ContentView.swift (onReceive hostKeyVerificationPublisher) -->
- Kill and relaunch the app mid-connect -> the connecting session was already snapshotted for
  restore (states idle/connecting/connected are persisted), so the restore flow (§7.8)
  offers it. <!-- src: Tessera/ContentView.swift (persistRestoreSnapshots) -->

**Automated coverage:** live TOFU + PTY over both transports is covered by
`TesseraTests/RealHostTransportIntegrationTests` (`test_liveSSHPasswordTOFUAndPTY`,
`test_liveMoshPasswordTOFUAndPTY`, `test_liveSSHInformedTOFUMismatchRequiresExplicitUnsafeOverride`)
via `scripts/integration/run-app-transport-tests.sh`. The UI chrome (rows, overlay, sheet
buttons) is manual only — spot-check the UI, not the transport.

---

### 7.2 Launch overlay and the connection failure surface

**Preconditions:** Saved fixture host. To force a failure, edit the saved host to a wrong
password (or point it at a dead address).

**Steps:**

1. Connect. -> Expected: the overlay owns the whole canvas — themed background, 64pt Tessera mark
   with breathing accent halo and blinking inner cursor, phase caption, optional tmux-name
   sub-line, 200×2 sliding accent bar. Phases in order: SSH+tmux "connecting" -> "starting tmux"
   -> "attaching pane"; mosh+tmux "connecting" -> "attaching tmux" -> "attaching pane"; plain
   custom-command sessions only ever show "connecting".
   <!-- src: Tessera/SessionLaunchOverlay.swift (SessionLaunchPhase.caption), Tessera/SessionView.swift (launchPhase, both variants) -->
2. Force a wrong-password connect. -> Expected: the overlay does NOT dismiss to a dead shell. It
   flips to the failure layout: static mark with red cursor, "connection failed", the reason
   string in dim mono, and three buttons — "edit host" (primary), "retry", "back".
   <!-- src: Tessera/SessionLaunchOverlay.swift (LaunchOverlayFailure), Tessera/SessionView.swift (launchFailureReason; .failed keeps overlay up) -->
3. Tap "retry". -> Expected: the failed session is dropped and a fresh connect starts with the
   same saved settings (fresh overlay from "connecting").
   <!-- src: Tessera/ContentView.swift (onRetry: removeAll + connect(to:)) -->
4. Tap "back". -> Expected: session is discarded; you land back on the hosts page (regular: with
   sidebar revealed). <!-- src: Tessera/SessionView.swift (onBack: onSessionEnded), Tessera/ContentView.swift (onSessionEnded) -->
5. Tap "edit host". -> Expected: the failed session is discarded and the saved host's editor
   opens, focused on fixing the identity. <!-- src: Tessera/ContentView.swift (onEditHost) -->

**Device/orientation variants:** identical layout everywhere (centered column, reason wraps at
360pt max width).

**Edge & failure cases:**

- Rejecting the Unknown Host sheet -> failure overlay, not a silent bounce.
- Biometric-protected key and the user cancels Face ID -> reason reads
  "Device authentication was cancelled - connection wasn't started."
  <!-- src: Tessera/SSHAuth.swift (AuthResolutionError descriptions) -->
- Clean remote exit (`exit` / Ctrl+D in the last tmux window) is NOT a failure: the session
  ends, the overlay logic is bypassed, and the app returns to the landing page without an error
  banner. <!-- src: Tessera/SessionView.swift (.onChange(of: session.state) .disconnected -> onSessionEnded) -->
- Mosh behind a jump chain that never gets UDP through -> the app rebuilds the session as plain
  SSH automatically (same host snapshot, fresh connect). Watch for the overlay restarting once.
  <!-- src: Tessera/ContentView.swift (attemptMoshJumpFallback) -->
- "edit host" from a **quick-connect** failure targets a host that was never persisted — see
  the sharp edge in §5.6.

**Automated coverage:** failure classification is covered by `RealHostTransportIntegrationTests`
(`test_liveSSHWrongPasswordIsClassifiedAsFailure`, `test_liveMoshWrongPasswordIsClassifiedAsFailure`).
Overlay visuals and the three recovery buttons are manual only.

---

### 7.3 Session top bar controls

**Preconditions:** Live tmux session to the fixture host.

**Steps (iPad / regular — floating pill bar):**

1. Inspect the pill. -> Expected, left to right: sidebar toggle (`line.3.horizontal`, accent-lit
   while the sidebar is open), the leading region (host status pill `user@address:port` + status
   dot when NOT in tmux; the tmux tab strip when tmux is active), find (`magnifyingglass`),
   Files (`folder`), a `⇄ N` forwarding chip only when forwarders exist, and home (`house`).
   There is NO disconnect button in the regular top bar.
   <!-- src: Tessera/SessionView.swift (SessionTopBar body, regular branch) -->
2. Tap the sidebar toggle. -> Expected: the sidebar floats OVER the terminal; the grid does not
   resize (no reflow). Toggle again to collapse.
   <!-- src: Tessera/SessionView.swift (SessionTopBar comment), Tessera/ContentView.swift (contentShell ZStack) -->
3. Tap find. -> Expected: a find bar drops in below the pill with the field
   "find in scrollback"; match counter reads "N of M" or "no matches"; the button stays
   accent-lit while open; tapping again closes it.
   <!-- src: Tessera/SessionView.swift (findController toggle), Tessera/Find/FindBar.swift -->
4. Tap home. -> Expected: back to the hosts landing; the session keeps running (§7.7).

**Steps (compact — 44pt bar):**

5. Inspect the bar. -> Expected, left to right: back chevron (accessibility label
   "Back — session keeps running"), host pill with status dot + name + down-chevron
   (accessibility "Switch session, window, or pane" — opens the switcher), a `plus` button
   ("New tmux window", only while tmux windows exist), find ("Find in terminal"), folder
   ("Files"), forwarding status, and a red `xmark` ("Disconnect").
   <!-- src: Tessera/SessionView.swift (compactBarCore, compactIconButton) -->
6. Tap the red `xmark`. -> Expected: immediate disconnect — no confirmation dialog — and return
   to the shell's root. <!-- src: Tessera/SessionView.swift (onDisconnect: session.disconnect()) -->

**Device/orientation variants:**

- Compact bar buttons render 38×44 visuals inside 40pt-pitch hit frames (the >=44pt-ish hit
  target work from the current PR stack); verify taps land on the intended control, especially
  between folder and disconnect. <!-- src: Tessera/SessionView.swift (compactIconButton comment) -->
- iPad Split View / Slide Over uses the compact bar (size-class driven), including the
  Disconnect button.
- The regular pill's height follows the Settings "top bar" slider; compact is fixed 44pt.
  <!-- src: Tessera/SessionView.swift (SessionTopBar.reservedHeight) -->
- On iPhone the status bar is hidden while a session is selected.
  <!-- src: Tessera/ContentView.swift (.statusBarHidden) -->

**Edge & failure cases:**

- With zero forwarders the `⇄` chip is absent entirely — a rule-less session's bar matches the
  screenshots in this guide. <!-- src: Tessera/SessionView.swift (forwarderManager chip auto-hide) -->
- Mosh only: while the tmux side-channel is reconnecting the host pill shows an amber
  "sync offline" tag and the compact `plus` button is disabled.
  <!-- src: Tessera/SessionView.swift (tabStrip tmuxIsDegraded, compactBarCore .disabled(tmuxIsDegraded)) -->

**Automated coverage:** manual only (bar layout/hit-targets). Find internals have
`TesseraTests/TerminalScrollbackOracleTests` adjacent coverage but the bar itself is untested.

---

### 7.4 tmux auto-attach default and the tab strip

**Preconditions:** Saved fixture host with default launch settings (never touched the "launch"
section). Second test needs the `tessera-notmux` fixture user.

**Steps:**

1. Connect. -> Expected: you are inside tmux without asking for it — auto-attach is the default
   for every new host. The overlay's sub-line shows the session name (`tessera-XXXXXXXX` on
   first contact). <!-- src: Tessera/PersistedHost.swift (launchModeRaw default), Tessera/SessionView.swift (auto-tmux command send on .connected) -->
2. Inspect the regular top bar. -> Expected: leading host pill (status dot, host name, a thin
   `·`, then a small-caps "tmux" tag), followed by one numbered window tab per tmux window; the
   active tab is highlighted; a `+` button ends the strip ("New tmux window").
   <!-- src: Tessera/SessionView.swift (tabStrip, tabButton) -->
3. Tap `+`. -> Expected: a second window tab appears and becomes active (same path as ⌘T).
4. Disconnect (compact `xmark`, or sidebar row disconnect), then reconnect the same host.
   -> Expected: SAME tmux session name in the overlay sub-line, and your windows are still
   there — the name is persisted per `user@address:port` and, failing that, re-derived
   deterministically, so even a reinstall re-attaches.
   <!-- src: Tessera/AutoTmuxHostStorage.swift (sessionName, recordSessionUsed), Packages/TmuxControl/Sources/TmuxControl/AutoTmuxScript.swift -->
5. Connect to the `tessera-notmux` user. -> Expected: the overlay drops early and a dismissable
   dark banner appears under the top bar: "tmux not available on remote host — multi-window
   features disabled". The session continues as a plain shell; the top bar shows the passthrough
   host status pill (no tab strip).
   <!-- src: Tessera/SessionView.swift (noTmuxScanner sentinel branch, NoTmuxBanner) -->

**Device/orientation variants:**

- Compact: there is no tab strip. tmux windows live behind the host-pill switcher
  ("Switch session, window, or pane") and the `+` button sits in the bar while tmux is active.
  <!-- src: Tessera/SessionView.swift (compactBarCore) -->
- The sidebar's active-session row and the compact sessions list both suffix tmux sessions:
  row title "name · tmux", compact subtitle "ssh+tmux · connected" / "mosh+tmux · connected".
  <!-- src: Tessera/SessionSidebar.swift (live.autoTmux " · tmux"), Tessera/ContentView.swift (CompactSessionRowBody transportLabel) -->

**Edge & failure cases:**

- The sidebar row holds "connecting…" (amber, pulsing) until the first pane actually renders,
  even though the transport is already `.connected` — do not read that as a hang.
  <!-- src: Tessera/SessionSidebar.swift (registry.isRenderReady gate), Tessera/SessionView.swift (markRenderReady) -->
- A pinned-tmux or custom-command host is NOT deduplicated the same way: only same-name
  auto-tmux/pinned sessions reuse; custom commands always spawn fresh.
  <!-- src: Tessera/ContentView.swift (connectSavedHost reuse branches) -->

**Automated coverage:** tmux hydrate/attach across fixture tmux versions:
`RealHostTransportIntegrationTests.test_liveInlineTmuxControllersHydrateBothFixtureVersions`;
phone/iPad viewport projection `test_liveSSHtmuxAppliesPhoneViewportThenIPadViewport` and
`test_liveMoshTmuxAppliesPhoneViewportThenIPadViewport`; name resolution logic in
`TesseraTests/MoshBootstrapTests`. The no-tmux banner and tab-strip UI are manual only.

---

### 7.5 iPhone keyboard accessory bar and dismissal

**Preconditions:** iPhone (real or simulator, software keyboard enabled — on simulator toggle
⌘K if a hardware keyboard is attached). Live session.

**Steps:**

1. Open a session. -> Expected: the terminal takes focus and the software keyboard rises; the
   accessory bar (52pt dark strip) sits above it with chips, in default order:
   `esc  ctrl  alt  ←  →  ↓  ↑`, plus a keyboard-dismiss button (`keyboard.chevron.compact.down`,
   accessibility "Hide keyboard") pinned at the right.
   <!-- src: Tessera/Keyboard/AccessoryChip.swift (defaultBarOrder phone), Tessera/Keyboard/SessionAccessoryBar.swift (hideButton) -->
2. Tap `ctrl`. -> Expected: the chip arms (accent tint + border); accessibility value "armed".
   No bytes are sent yet.
3. Type `c` on the keyboard. -> Expected: Ctrl+C reaches the shell (interrupts a running
   command); the chip disarms (one-shot is the default behavior).
   <!-- src: Tessera/Keyboard/SessionAccessoryBar.swift (handleTap/consume), Tessera/Keyboard/ModifierState.swift (oneShot) -->
4. Tap the hide button. -> Expected: the software keyboard dismisses; the accessory bar remains
   available above the home indicator; the terminal does NOT immediately re-summon the keyboard.
5. Tap the terminal canvas. -> Expected: the keyboard returns (the suppression lasts exactly
   until the terminal requests the keyboard again).
   <!-- src: Tessera/Keyboard/ModifierState.swift (dismissSoftwareKeyboard / noteSoftwareKeyboardRequested) -->
6. Tap an arrow chip in a full-screen program (e.g. run `htop` on the fixture, which provisions
   it). -> Expected: cursor-key bytes honor application-cursor mode (navigation works).
   <!-- src: Tessera/Keyboard/SessionAccessoryBar.swift (applicationCursor), Tessera/Keyboard/AccessoryChipEncoder.swift -->

**Device/orientation variants:**

- iPad (any window size, including Split View — this is idiom-keyed, not size-class-keyed): the
  right-edge button is "Hide accessory bar" and hides the BAR itself (re-enable in keyboard
  settings), not the keyboard. Default iPad chip set adds `tab`, `|`, `~`.
  <!-- src: Tessera/Keyboard/SessionAccessoryBar.swift (hideButton idiom branch), Tessera/Keyboard/AccessoryChip.swift (defaultBarOrder pad) -->
- iPhone Max: same chips, more horizontal room; the chip strip is horizontally scrollable on all
  widths.

**Edge & failure cases:**

- Chip taps during the launch overlay are dropped (input is gated until the shield falls).
  <!-- src: Tessera/SessionView.swift (SessionAccessoryBar onSend guard !showsLaunchOverlay) -->
- Long-press a chip -> drag-reorder starts; releasing on the red trash target at the right edge
  removes the chip (restore via Settings > keyboard "reset"). Editing the chip set cancels any
  armed modifier. <!-- src: Tessera/Keyboard/SessionAccessoryBar.swift (DraggableChipBar, onChange cancel), Tessera/Settings/KeyboardSettingsView.swift -->

**Automated coverage:**
`TesseraUITests/IPhoneKeyboardHarnessTests/testHideKeyboardDismissesUntilTerminalIsTappedAgain`
(lane: `scripts/integration/run-iphone-keyboard-harness-tests.sh`; visual case
`scripts/integration/visual-cases/p1-iphone-keyboard.sh`). Chip byte encoding:
`TesseraTests/AccessoryChipEncoderTests`, `TesseraTests/ModifierStateTests`. Spot-check the
visuals; do not re-test the dismissal state machine by hand.

---

### 7.6 Files panel first open (lazy per-host bridge)

**Preconditions:** Live session to the fixture host (SSH or mosh — both work; the fixture
provisions SFTP). Files panel never opened for this host in this app run.

**Steps:**

1. Tap the `folder` button in the top bar. -> Expected: this first open is what triggers the
   SFTP bridge connect — nothing dialed before the gesture ("never-auto-connect" rule). The
   panel shows a spinner with "Connecting to <endpoint>…", then the listing.
   <!-- src: Tessera/Files/FilesPanelController.swift (open() comment + ensureConnectedAndLoad), Tessera/Files/FilesPanelView.swift ("Connecting to …") -->
2. Check the panel header. -> Expected: title "Files" with a dim "· sftp" transport tag, and
   breadcrumbs seeded at the terminal's current directory (tmux pane path or OSC 7).
   <!-- src: Tessera/Files/FilesPanelView.swift, Tessera/SessionView.swift (toggleFilesPanel seeds terminalReportedDirectory) -->
3. `cd /tmp` in the terminal. -> Expected: the panel follows (follow mode is on by default when
   the terminal reports a cwd). <!-- src: Tessera/Files/FilesPanelController.swift (terminalReportedDirectory, followEnabled) -->
4. Close and reopen the panel. -> Expected: reopen is instant (bridge stays warm while the app
   holds it); no second auth prompt.
5. Open the Files panel from a mosh session to the same host. -> Expected: it works — the bridge
   is plain SSH to the same endpoint, and SSH + mosh sessions to one host SHARE a single bridge
   (the bridge key strips terminal transport). Biometric-gated keys prompt with the same policy
   the terminal used. <!-- src: Tessera/Files/FileBridgeRegistry.swift (bridge(for:) comment), Tessera/SessionView.swift (mosh configureFilesPanelIfNeeded comment) -->

**Device/orientation variants:**

- Regular: the panel floats over the trailing edge of the terminal (terminal does not resize);
  tapping the terminal outside the card dismisses it.
  <!-- src: Tessera/SessionView.swift (overlay(alignment: .trailing) + tap-catcher) -->
- Compact: the panel presents as a sheet with `.medium`/`.large` detents and a drag indicator;
  interaction with the terminal stays enabled at medium height.
  <!-- src: Tessera/SessionView.swift (.sheet(isPresented: compactFilesBinding), presentationDetents) -->

**Edge & failure cases:**

- Wrong credentials / SFTP subsystem missing -> the panel shows its error state ("Connection
  lost" / "Disconnected" banners exist for later drops); the terminal session is unaffected.
  <!-- src: Tessera/Files/FilesPanelView.swift (state banners) -->
- Switching away from the session force-closes the panel; returning with the panel previously
  open reconnects the bridge automatically (standing user intent).
  <!-- src: Tessera/SessionView.swift (onChange(of: isActive) filesPanel.close() / reopen) -->
- Follow shows "Enable follow — install shell integration" when no cwd source exists (plain
  shell without OSC 7); installing prints "Installing shell integration…" then an "Installed
  (…). Takes effect on the next shell login — run exec $SHELL or reconnect." info line.
  <!-- src: Tessera/Files/FilesPanelView.swift, Tessera/SessionView.swift (onInstallShellIntegration) -->

**Automated coverage:** `TesseraTests/FileBridgeTests` (unit) and
`RealHostTransportIntegrationTests.test_liveFileBridgeListsAndRoundTripsFiles` (live listing +
round-trip). Panel presentation (overlay vs sheet, follow UI) is manual only.

---

### 7.7 Leaving a session running vs disconnecting

**Preconditions:** One live session to the fixture host.

**Steps:**

1. Regular: tap `house`. Compact: tap the back chevron. -> Expected: you land on the hosts page;
   the session keeps running. Nothing was torn down — every live SessionView stays mounted and
   consuming its output stream while hidden.
   <!-- src: Tessera/ContentView.swift (onBack sets selectedItem = nil; comment on keeping SessionViews mounted), Tessera/SessionView.swift (compactIconButton "Back — session keeps running") -->
2. Verify liveness. -> Expected (regular): sidebar "active sessions" row with pulsing green dot
   and "connected"; landing row/card green dot. (Compact): the "sessions" tab lists it as
   "ssh+tmux · connected"; the empty state, if you disconnect everything, reads "no active
   sessions" / "connect from Hosts; leaving a terminal keeps it running here".
   <!-- src: Tessera/SessionSidebar.swift, Tessera/ContentView.swift (CompactSessionsPage) -->
3. Re-enter from the sessions list / sidebar row. -> Expected: instant switch back — no
   reconnect, scrollback intact; the terminal replays its size to the remote (a brief reflow of
   a full-screen program is normal).
   <!-- src: Tessera/ContentView.swift (selectSession), Tessera/SessionView.swift (onChange(of: isActive) resize replay) -->
4. Disconnect from the list: tap the red `xmark` on the row. -> Expected: confirmation dialog
   "Disconnect <name>?" with destructive "Disconnect" and "Cancel". Confirming removes the row
   and closes the transport. The same confirm exists on the iPad sidebar row.
   <!-- src: Tessera/ContentView.swift (CompactSessionRowBody confirmationDialog), Tessera/SessionSidebar.swift (confirmationDialog) -->
5. Disconnect from inside (compact bar `xmark`). -> Expected: immediate, no confirmation.
6. After disconnecting, check the remote: the tmux session survives on the server (that is the
   auto-attach contract — reconnect resumes it, see §7.4).

**Device/orientation variants:**

- Compact back returns to whichever root tab you left; the sessions tab badge counts agent
  attention items only (not session count).
  <!-- src: Tessera/ContentView.swift (compactSessionBadge) -->
- Mosh: backing out also stops the tmux side-channel; it re-establishes when you return.
  <!-- src: Tessera/SessionView.swift (moshSessionTopBar onBack stopTmuxControlChannel) -->

**Edge & failure cases:**

- Removing a saved host does NOT kill its live sessions — the removal dialog says so:
  "This removes the saved host. Existing live sessions are not disconnected."
  <!-- src: Tessera/Hosts/HostsLandingView.swift (confirmationDialog) -->
- A clean `exit` in the last tmux window ends the session remotely; the app returns to the
  landing page with no error surface. <!-- src: Tessera/SessionView.swift (.disconnected -> onSessionEnded) -->

**Automated coverage:** manual only (navigation lifecycles). Background-session output handling
has adjacent coverage in `TesseraUITests/TerminalScrollHarnessTests`.

---

### 7.8 Session restore on relaunch

**Preconditions:** First-open pre-completed via launch args (critical — otherwise Nearby
Setup re-presents on every relaunch and confuses the sequencing). One or two live saved-host
sessions (password saved to Keychain or a non-RSA key with material present — restore
eligibility fails closed otherwise). Restore policy untouched (default `ask` — fresh install
or delete the `tessera.pref.sessionRestorePolicy` default).

**Steps (iPad full-screen / regular):**

1. With sessions connected, kill the app from the app switcher, relaunch. -> Expected: a sheet
   "reopen previous connections" listing "N saved-host connection(s) can be reopened.", one
   green-dotted line per host, an "always reopen" toggle, and buttons "reopen" (primary) and
   "not now". <!-- src: Tessera/SessionRestoreSheet.swift, Tessera/ContentView.swift (attemptStartupRestoreIfReady .ask branch) -->
2. Tap "reopen". -> Expected: each host reconnects (launch overlays), the previously selected
   session is re-selected; duplicates to one auto-tmux host collapse into a single reopened
   session. <!-- src: Tessera/ContentView.swift (restorePreviousConnections), Tessera/SessionRestoreStore.swift (SessionRestoreResolver singleton collapse) -->
3. Repeat, but toggle "always reopen" on before tapping "reopen". -> Expected: the stored policy
   flips to `always`; the NEXT relaunch reopens silently with no prompt.
   <!-- src: Tessera/ContentView.swift (reopenPreviousConnections), Tessera/Settings/TerminalSettingsView.swift -->
4. Repeat with "not now". -> Expected: nothing reopens AND the stored snapshot is cleared — a
   further relaunch shows no prompt until new sessions are opened.
   <!-- src: Tessera/ContentView.swift (skipPreviousConnections -> sessionRestoreStore.clear()) -->

**Steps (iPhone / compact):**

5. Same kill-and-relaunch with policy still `ask`. -> Expected: NO prompt — compact treats `ask`
   as restore-on-launch and reopens automatically (the compact shell has no multi-session
   chooser). The stored preference is NOT rewritten; moving the same account/data to a regular
   iPad window shows the prompt again — a stored `ask` set on iPad remains `ask` even after
   phone-shell launches silently reopened.
   <!-- src: Tessera/SessionRestoreStore.swift (SessionRestorePresentationPolicy.effective), Tessera/ContentView.swift (effectiveSessionRestorePolicy; comment "the stored preference is left untouched so opening the same app on iPad still honors 'ask'") -->
6. Check Settings > terminal > startup. -> Expected (compact): a single toggle "restore on
   launch" — "reopen restorable saved-host sessions automatically" (maps to always/never).
   (Regular): a "previous connections" field with three chips ask / always / never, described as
   "ask before reopening saved-host sessions on fresh launch" etc.
   <!-- src: Tessera/Settings/TerminalSettingsView.swift (startup section) -->

**Device/orientation variants:**

- The split is **shell-based, not device-based**: an iPad launched into a compact Split View /
  Slide Over pane also silently reopens under `ask`, since the policy is evaluated against the
  presenting shell (`usesCompactShell`). Full-screen iPad always prompts under `ask`. Worth one
  explicit check. <!-- src: Tessera/ContentView.swift (usesCompactShell: isPhone via CompactLayout.isPhone) -->

**Edge & failure cases:**

- Policy `never` -> relaunch clears any stored snapshot; nothing reopens, no prompt.
  <!-- src: Tessera/ContentView.swift (attemptStartupRestoreIfReady .never) -->
- Delete the host (or its key/password) between kill and relaunch -> that session is skipped;
  with other survivors the sheet adds the dim line "N previous connection(s) was/were skipped
  because the saved host or credentials changed."; with no survivors the store is cleared
  silently. <!-- src: Tessera/SessionRestoreSheet.swift (skippedText), Tessera/SessionRestoreStore.swift (SessionRestoreEligibility) -->
- Quick-connect sessions never restore (no persisted host marker).
  <!-- src: Tessera/ContentView.swift (persistRestoreSnapshots skip reason=no-persisted-host-marker) -->
- Relaunch with the process still alive (ordinary foreground return, sessions intact): no
  restore evaluation at all (`activeSessions` non-empty short-circuits).
  <!-- src: Tessera/ContentView.swift (attemptStartupRestoreIfReady guard activeSessions.isEmpty) -->
- App lock enabled -> restore evaluation is deferred until unlock; the prompt appears after the
  lock clears (§8 Flow D). <!-- src: Tessera/ContentView.swift (attemptStartupRestoreIfReady guard !isLocked, unlock observer) -->
- Ordinary backgrounding (not a kill) must NOT duplicate sessions on return — the process
  survived, so foreground restore only replaces dead counterparts.
  <!-- src: Tessera/ContentView.swift (attemptForegroundRestoreIfNeeded, restore-session-reuse idempotency) -->
- Diagnosing failures: Settings > diagnostics log upload includes a "full tmux, mosh, SwipePad,
  and restore trace". <!-- src: Tessera/Settings/SettingsPageView.swift -->

**Automated coverage:** heavily covered at the logic layer — spot-check UI only.
`TesseraTests/SessionRestoreStoreTests`
(incl. `testCompactPresentationTreatsAskAsRestoreOnLaunchWithoutChangingOtherPolicies`),
`TesseraTests/SessionRestoreResolverTests` (credential eligibility fail-closed, singleton/lineage
collapse, rename/current-config behavior). The sheet itself and the live reconnect sequencing
are manual.

---
## 8. Shell & orientation variants

### Codex Desktop QA charter

**Primary mission:** verify continuity of the user's place, data, and understanding while the
same app moves among iPhone tabs, iPad sidebar, compact iPad windows, rotation, keyboard, and
Stage Manager.

During Pass A:

- Begin an actual task before resizing: half-complete a host form, keep a modal open, or keep a
  live terminal selected. Empty-shell resizing is insufficient.
- Drag continuously across compact/regular boundaries and watch for flicker, duplicate
  overlays, stale selection, focus loss, and contradictory controls.
- Test controls near system edges and neighboring destructive actions after every layout
  switch.
- Record whether the navigation model changes in a way that strands the user.
- Distinguish OS-owned behavior from app behavior, but still report user-visible dead ends.
- Use the shell shown on screen as the size-class oracle; do not force an expectation based
  solely on orientation.

The most important defects are state loss, accidental commit/revert during shell changes,
terminal disconnects, inaccessible modals, and oscillation or stale layouts at a resize
boundary.

Per-shell verification flows for the matrix in §2, plus the app lock screen on launch,
Stage Manager window resizing, status-bar behavior, and rotation-mid-flow expectations. The
shell-dependent session-restore policy split lives in §7.8. Launch with the pre-complete
args (§1.4) unless a step says otherwise.

<!-- src: Tessera/ContentView.swift (contentShell, compactNavigationShell, isPhone, statusBarHidden, persistentSystemOverlays) -->
<!-- src: Tessera/Design/DesignTokens.swift (CompactLayout.isPhone) -->

---

### 8.1 Flow A — iPhone compact shell (both orientations)

**Preconditions:** iPhone (any size; run once on a regular-width Max model for M3), fresh
install, launch args `-tessera.nearbyBootstrap.completed.v1 YES` and
`-tessera.pref.hasSeenWelcome YES` so the first-open flow does not cover the shell. Portrait.

**Steps:**

1. Cold-launch Tessera. -> Expected: a bottom tab bar with exactly four tabs labeled
   `hosts`, `sessions`, `keys`, `settings` (lower-case). The `hosts` tab is selected and shows
   the hosts landing page. No sidebar, no sidebar reveal button anywhere.
   <!-- src: Tessera/ContentView.swift lines 160, 309-359 -->
2. Confirm the phone-variant landing copy (full landing script: §5.2). -> Expected: primary
   button "add your first host" **without** a "⌘N" chip (the shortcut chip is iPad-only),
   secondary "generate a key", and the short search placeholder "search hosts or add new
   ones below". <!-- src: Tessera/Hosts/HostsLandingView.swift lines 25-35, 82-133 -->
3. Tap `keys`. -> Expected: keys page in single-pane phone layout, topped by a two-way selector
   "keys" / "known hosts". Tap "known hosts" -> Expected: Known Hosts page (phone layout)
   replaces keys in place; tab stays `keys`. <!-- src: Tessera/ContentView.swift lines 330-350 -->
4. Tap `settings`. -> Expected: a navigation list of settings sections with chevrons
   (drill-down), large title "settings". The **themes** section is absent on phone (theme
   selection lives inside Appearance). <!-- src: Tessera/Settings/SettingsPageView.swift lines 34-91 -->
5. Tap `sessions`. -> Expected: page title "sessions" with the empty state "no active
   sessions" and hint "connect from Hosts; leaving a terminal keeps it running here". Only
   with Agent Center enabled (Experimental settings) does a "sessions" / "agents" selector
   appear; a numeric badge on the tab reflects waiting/just-finished agents.
   <!-- src: Tessera/ContentView.swift lines 316-328, 419-421, 3917-3990 (CompactSessionsPage) -->
6. Check the status bar on each tab. -> Expected: status bar **visible** (clock/battery) on all
   four root tabs. <!-- src: Tessera/ContentView.swift line 780: .statusBarHidden(isPhone ? isSessionSelected : true) -->
7. Rotate to landscape and revisit each tab. -> Expected: same compact shell, same four tabs, same
   phone layouts. On a Max model in landscape this is the critical assertion: still the
   compact shell, never the sidebar shell. <!-- src: Tessera/Design/DesignTokens.swift lines 6-16 -->
8. Connect to a fixture host (§1.5), then observe. -> Expected: the session opens as a
   full-screen overlay above the tab bar; the status bar is now **hidden**. Back navigation
   returns to the tabs with the session still alive (it is opacity-hidden, not unmounted).
   <!-- src: Tessera/ContentView.swift lines 362-376, 780 -->

**Device/orientation variants:**
- iPhone Max landscape (M3) is the only row where size class (regular) and idiom (phone)
  disagree — layout must be identical to M1/M2.
- No other differences: the phone shell is orientation-invariant by design.

**Edge & failure cases:**
- Relaunch on the `settings` tab: tab selection is `@State`, not persisted — app relaunches on
  `hosts`. <!-- src: Tessera/ContentView.swift line 160 -->
- Kill the app mid-rotation: no persisted orientation state exists; relaunch is normal.
- On first ever open *without* the pre-complete launch args, Nearby Setup covers the shell
  (§3); "cancel" dismisses it but it **re-presents on every launch** until completed via
  "set up as new" or a finished import.
  <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift lines 409-432 (beginIfFirstOpen guards on !firstOpenStore.isComplete; cancel never calls markComplete) -->

**Automated coverage:** steps 3, 4, and 5 (tab routing, the keys↔known-hosts selector, and
each root tab's landing content) plus the tab-revisit half of step 7 are covered in BOTH
orientations by `OrientationButtonSweepTests.testIPhonePortraitSweep` /
`testIPhoneLandscapeSweep` (`TesseraUITests/TerminalScrollHarnessTests.swift`, run directly
per §9.3, with the same two pre-complete launch args) — spot-check only. The visual lane
`scripts/integration/visual-cases/p1-iphone-keyboard.sh` (via
`scripts/integration/run-visual-review.sh`) covers the live-session surface of step 8.
Manual only: the exact phone-copy assertions of step 2, status-bar visibility (steps 6
and 8), the Max-model run of step 7 (the sweep runs on whichever iPhone simulator is
provided and pins no Max device, so the M3 idiom-beats-size-class assertion stays manual),
the Agent-Center selector/badge variant of step 5, and the first-open edge case.
<!-- src: TesseraUITests/TerminalScrollHarnessTests.swift (OrientationButtonSweepTests.runPhoneSweep: tabs, selector, landing texts, both orientations) -->

---

### 8.2 Flow B — iPad full screen: sidebar shell, portrait + landscape

**Preconditions:** iPad simulator or device (iOS 17+; tested on iOS 26 sims), fresh install
with the two pre-complete launch args, full-screen window, **portrait first** (portrait is the
orientation the sidebar fix targets).

**Steps:**

1. Cold-launch in portrait. -> Expected: the sidebar is **expanded at launch** — a 240 pt
   floating glass column on the leading edge with the Tessera logo + title, a `+` ("new host")
   button and a `‹` chevron ("hide sidebar") in its title bar. The detail pane behind it shows
   the hosts landing page. (Sidebar body anatomy: §5.1.)
   <!-- src: Tessera/ContentView.swift line 113 (sidebarVisible = true), 226-236; Tessera/SessionSidebar.swift lines 10, 77-110 (accessibility labels "new host", "hide sidebar") -->
2. Check the status bar and home indicator. -> Expected: status bar **hidden** on iPad at all
   times; persistent system overlays (home indicator) also hidden.
   <!-- src: Tessera/ContentView.swift lines 780-781: .statusBarHidden(... : true), .persistentSystemOverlays(isPhone ? .automatic : .hidden) -->
3. Confirm the iPad landing copy (full landing script: §5.2). -> Expected: primary button
   "add your first host" **with** a "⌘N" chip, and the long quick-connect placeholder
   "search hosts, or type user@host to quick-connect".
   <!-- src: Tessera/Hosts/HostsLandingView.swift lines 28-31, 102-113 -->
4. Tap the `‹` chevron in the sidebar title bar. -> Expected: sidebar slides out (0.24 s
   ease-in-out). Because no session is open, the browse page expands to full width and a
   floating glass **reveal button** (`line.3.horizontal` glyph, accessibility label
   "show sidebar") appears at the top-leading corner. <!-- src: Tessera/ContentView.swift lines 241-246, 1352-1389 -->
5. Still in **portrait**, tap the reveal button. -> Expected: sidebar slides back in. This is
   the regression the current PR stack fixes — the button was previously a no-op in portrait
   because `NavigationSplitViewVisibility.automatic == .detailOnly` compares equal in portrait
   on iPadOS 26; visibility is now a plain Bool. Repeat collapse/reveal in landscape.
   <!-- src: Tessera/ContentView.swift lines 108-113 (comment documents the portrait no-op bug and the Bool fix) -->
6. With the sidebar expanded, open a browse page (e.g. select keys via the sidebar bottom
   navigation). -> Expected: page content is **pushed aside** — inset by exactly the 240 pt
   sidebar width, not overlapped. Collapse the sidebar -> content goes full-width with a 50 pt
   top inset so its title clears the floating reveal button.
   <!-- src: Tessera/ContentView.swift lines 1336-1341 (.padding(.leading, sidebarVisible ? SessionSidebar.width : 0), .padding(.top, sidebarVisible ? 0 : 50)) -->
7. Connect to a fixture host, keep the sidebar expanded. -> Expected: over a live session the
   sidebar **floats above** the terminal with a dim scrim (28 % black) covering the terminal;
   the terminal does not resize (no reflow/SIGWINCH). Tapping the scrim collapses the sidebar
   (scrim accessibility label "hide sidebar"). In-session, the sidebar toggle is the
   `line.3.horizontal` button in the terminal top bar, not the floating reveal button.
   <!-- src: Tessera/ContentView.swift lines 198-224 (scrim + no-resize comment), 239-246 -->
8. Rotate portrait ↔ landscape at each step above. -> Expected: identical shell; sidebar
   expansion state carries across rotation (plain `@State` Bool, not orientation-derived).

**Device/orientation variants:**
- Portrait vs landscape differ only in available width; shell, affordances, and launch-expanded
  state are identical. Landscape with a Magic Keyboard: sidebar bottom nav reaches the screen
  edge (bottom safe-area inset lifted). <!-- src: Tessera/SessionSidebar.swift lines 69-74 -->

**Edge & failure cases:**
- Collapse the sidebar, force-quit, relaunch: `sidebarVisible` is not persisted → sidebar is
  expanded again on launch.
- Session ends or Back is tapped from a session: selection clears **and the sidebar is forced
  visible** (`selectedItem = nil; sidebarVisible = true`). <!-- src: Tessera/ContentView.swift lines 1128-1131, 1144-1150 -->
- Starting the replayed walkthrough (or a forced spotlight step) also forces
  `sidebarVisible = true` so the spotlighted sidebar keys row is on screen.
  <!-- src: Tessera/ContentView.swift lines 686-697 -->

**Automated coverage:** `SidebarToggleHarnessTests` proves the sidebar launches expanded in
portrait AND landscape and the collapse/reveal round-trip works (§9.3); the visual lane
`scripts/integration/visual-cases/o1-onboarding-tour.sh` captures the sidebar-shell surface in
landscape. Sidebar float/scrim interaction over a session is **manual only**.

---

### 8.3 Flow C — iPad Split View & Slide Over: compact width routes phone layouts

**Preconditions:** iPad full-screen baseline from Flow B verified; a second app (e.g. Safari)
available for Split View; pre-complete launch args applied; at least one saved host and one
stored key so list layouts are non-empty.

**Steps:**

1. With Tessera full screen showing the sidebar shell, create a Split View and drag the divider
   until Tessera is the **narrow pane** (≈1/3). -> Expected: the entire shell swaps live to the
   compact shell (`hosts` / `sessions` / `keys` / `settings` tabs). No sidebar, no reveal
   button. <!-- src: Tessera/ContentView.swift lines 179-196 (isPhone recomputed from horizontalSizeClass) -->
2. Visit `hosts`. -> Expected: phone landing layout (compact paddings, short search
   placeholder, edit/delete routed through phone affordances).
   <!-- src: Tessera/Hosts/HostsLandingView.swift lines 131-132, 225-236 -->
3. Visit `keys`. -> Expected: single-pane phone keys layout with the "keys"/"known hosts"
   selector; open "generate" -> Expected: `GenerateKeyModal` spans the full pane width
   (compact `maxWidth: .infinity`, 18 pt padding) — content compresses, nothing clips off the
   pane edge. Cancel it. <!-- src: Tessera/Keys/KeysPageView.swift lines 67-84; Tessera/Keys/GenerateKeyModal.swift lines 89-91 -->
4. Visit `settings`. -> Expected: phone drill-down settings list (no two-pane layout, no
   themes gallery section). Visit `keys` → "known hosts". -> Expected: phone Known Hosts
   layout. <!-- src: Tessera/Settings/SettingsPageView.swift lines 19-91; Tessera/KnownHosts/KnownHostsPageView.swift lines 13-14 -->
5. Drag the divider to make Tessera the **wide pane** (≈2/3, landscape). -> Expected: shell
   swaps back to the sidebar shell; the keys page returns to two-pane list+detail and
   auto-selects an initial key if none is selected (explicit re-apply on size-class change).
   <!-- src: Tessera/Keys/KeysPageView.swift lines 188-195 -->
6. Replace Split View with **Slide Over**. -> Expected: always the compact shell + phone
   layouts (Slide Over is always compact width), in both orientations.
7. Open a session from the compact pane, then widen the pane to regular. -> Expected: the live
   session survives the shell swap (session views stay mounted in both shells) and now renders
   inside the sidebar shell with the floating sidebar/scrim behavior of Flow B step 7.
   <!-- src: Tessera/ContentView.swift lines 362-376 (compact keeps detailContent mounted), 1102-1210 (shared detailContent in both shells) -->

**Device/orientation variants:**
- 50/50 landscape split (M7): 13-inch iPads may keep both windows regular → sidebar shell;
  smaller iPads go compact → compact shell. Record the observed size class per device; the app
  requirement is only "shell follows size class".
- Portrait splits are typically compact for both panes → compact shell.

**Edge & failure cases:**
- Resize the divider **while the generate/import key modal is open**: modal must re-lay out
  between fixed-width (480/520 pt) and full-width without clipping or dismissing.
- Resize while the host editor is open: editor persists (`selectedItem` unchanged) — on compact
  it renders as the full-screen phone overlay; on regular it renders in the detail pane.
  <!-- src: Tessera/ContentView.swift lines 1213-1275 (compact host-editor overlay) vs 1276-1342 -->
- Launch Tessera *directly into* a compact Split View pane: expect the compact shell from
  first frame, and note the session-restore policy difference in §7.8 (an `ask` preference
  silently reopens because the compact shell is presenting).
- App backgrounded when the other Split View app is focused: Nearby Setup discovery stops on
  background (`stopForBackground`), so don't run the first-open transfer in an unfocused pane.
  <!-- src: Tessera/Bootstrap/BootstrapCoordinator.swift lines 608-611; Tessera/TesseraApp.swift lines 158-161 -->

**Automated coverage:** unit `TesseraTests/SessionRestoreStoreTests.swift`
`testCompactPresentationTreatsAskAsRestoreOnLaunchWithoutChangingOtherPolicies` covers the
policy half of the compact swap; shell swap and modal compression are **manual only**.

---

### 8.4 Flow D — App lock screen on first launch

**Preconditions:** fresh install, no launch args. Any device from the matrix.

**Steps:**

1. Cold-launch a fresh install. -> Expected: **no lock screen**. `requireFaceIDToUnlock`
   defaults to `false`, and `AppLockController.isLocked` initializes from it — a NEW user never
   sees the lock screen until they enable the toggle themselves.
   <!-- src: Tessera/Design/AppearancePreferences.swift line 231 (var requireFaceIDToUnlock: Bool = false); Tessera/Security/AppLockController.swift lines 16-23; Tessera/TesseraApp.swift line 216 (isInitialColdLaunch seeded from the pref) -->
2. Enable Settings → security → "require device owner authentication to unlock" (subtitle
   "Face ID first, with device-passcode fallback"). -> Expected: the app locks **immediately**
   (enabling enforces now). <!-- src: Tessera/Settings/SecuritySettingsView.swift lines 28-33; Tessera/TesseraApp.swift lines 490-492; Tessera/Security/AppLockController.swift lines 153-158 -->
3. Inspect the lock screen. -> Expected: full-screen surface themed from the terminal theme,
   showing the Tessera logo, "— locked —", a button "tap to unlock" (shows "unlocking..." while
   in flight), and the caption "face id · or device passcode". The app content behind it does
   not accept touches. <!-- src: Tessera/Security/LockScreenView.swift lines 40-97; Tessera/TesseraApp.swift line 597 (.allowsHitTesting(!appLockController.isLocked)) -->
4. Force-quit and cold-launch again. -> Expected: lock screen appears at launch and
   **auto-prompts** Face ID once (initial-cold-launch auto prompt); cancelling the system sheet
   leaves the "tap to unlock" button as the retry path.
   <!-- src: Tessera/Security/LockScreenView.swift lines 100-109 -->
5. Fail biometrics deliberately. -> Expected: inline error "face id didn't match. tap to try
   again or use device passcode."; if biometrics are unavailable: "biometric authentication is
   unavailable. tap to use device passcode." User-cancel shows no error.
   <!-- src: Tessera/Security/LockScreenView.swift lines 112-122 -->
6. Unlock. -> Expected: lock fades out; only now does startup session-restore evaluation run
   (§7.8) — restore is deferred while locked.
   <!-- src: Tessera/ContentView.swift lines 635-647, 2281-2284 -->

**Device/orientation variants:** identical on all matrix rows — the lock screen is a
whole-window overlay above whichever shell is active. No differences to call out.

**Edge & failure cases:**
- Lock while the Nearby Setup first-open flow is presented: the flow is **cancelled** by the
  lock. First-open is *not* marked complete, so Nearby Setup re-presents next launch; the
  dismissal observer still sets `hasSeenWelcome = true`, so the walkthrough will not stack on
  top of it. <!-- src: Tessera/TesseraApp.swift lines 496-509 (bootstrapCoordinator.cancel() on lock); Tessera/ContentView.swift lines 625-634 (dismissal observer sets hasSeenWelcome) -->
- Background/foreground with "lock when backgrounded" on: relock + one auto-prompt on return.
  <!-- src: Tessera/Security/AppLockController.swift lines 96-118 -->
- Disable the toggle while locked: lock dismisses without another biometric prompt (explicit
  OFF is authoritative). <!-- src: Tessera/Security/AppLockController.swift lines 151-170 -->

**Automated coverage:** `TesseraTests/BiometricRevocationRaceTests.swift` covers
lock-controller/key-grant race behavior at the unit level; the lock-screen UI and launch
sequencing are **manual only**.

---

### 8.5 Flow E — Rotation mid-flow

**Preconditions:** matrix rows M1, M4/M5 minimum (one iPhone, one full-screen iPad);
fixture host available; fresh install **without** pre-complete args for step 1, with them for
the rest.

**Steps:**

1. **During first-open Nearby Setup:** cold-launch (the "TESSERA · NEARBY SETUP" welcome is
   up), rotate the device. -> Expected: the flow stays presented and reflows — it is a
   full-screen `ScrollView` whose content column caps at 620 pt and centers; no state loss
   (phase lives in the `BootstrapCoordinator`, not the view). Buttons "find nearby devices" /
   "set up as new" remain tappable in both orientations.
   <!-- src: Tessera/Bootstrap/BootstrapFlowView.swift lines 13-50, 105-160; Tessera/Bootstrap/BootstrapCoordinator.swift lines 225-228 -->
2. **During the host editor:** open the editor (add a host), type into a field, rotate. ->
   Expected: editor stays presented with text intact (`selectedItem` drives presentation and
   is orientation-independent); compact vs regular editor layout only changes if the size
   class changes (Split View resize — see Flow C), never on same-window rotation on iPhone or
   full-screen iPad. <!-- src: Tessera/ContentView.swift lines 453-484, 1213-1342 -->
3. **During a live session:** connect, run `watch -n1 date` or open `vim`, rotate. ->
   Expected: the terminal grid resizes to the new dimensions (a resize/SIGWINCH reaches the
   remote; full-screen apps repaint at the new size); the session stays connected. On iPad the
   sidebar, if open, still floats without altering the grid width.
   <!-- src: Tessera/ContentView.swift lines 198-224 (sidebar float never resizes detail) -->
4. **iPhone shell invariance:** rotate on every root tab. -> Expected: compact shell persists
   (see Flow A step 7).
5. **iPad sidebar-state persistence:** collapse the sidebar in landscape, rotate to portrait.
   -> Expected: sidebar stays collapsed; the reveal button is present and functional in
   portrait (the fixed code path). Reveal, rotate back — stays expanded.
   <!-- src: Tessera/ContentView.swift lines 108-113 -->
6. **During the restore prompt (iPad):** relaunch to the "reopen previous connections" sheet
   (§7.8), rotate. -> Expected: sheet survives rotation; buttons remain reachable.
7. **iPad Split View rotation:** with Tessera in a landscape 2/3 pane (sidebar shell), rotate
   to portrait. -> Expected: iPadOS narrows the pane; if the size class flips to compact the
   shell swaps to tabs live, with sessions and selection preserved (Flow C step 7 semantics).

**Device/orientation variants:**
- iPhone: rotation never changes shell or layouts (idiom-pinned) — only geometry.
- iPad full screen: rotation never changes shell (regular both ways) — only geometry.
- iPad Split View/Slide Over: rotation may change the *size class*, which is a shell swap, not
  a rotation effect per se. Test it as Flow C.

**Edge & failure cases:**
- Rotate during the SAS code-compare step of a live nearby transfer: the handshake must not
  drop (state is in the coordinator/service, UI is stateless).
- Rotate while a key modal is open on iPhone: modal is full-width in both orientations;
  verify no clipped buttons in landscape's reduced height (content is scrollable).
- Rotate exactly during the session-connect launch overlay: overlay reflows; connection
  proceeds.

**Automated coverage:** `scripts/integration/visual-cases/o1-onboarding-tour.sh` pins the iPad
walkthrough to landscape (rotation itself untested); `TesseraTests/BootstrapCoordinatorTests.swift`
(`test_backgroundStopsBrowserAndClearsPresentation`,
`test_backgroundFromSelectionCancelsConnectionWithoutGrant`) covers lifecycle interruptions of
the Nearby Setup flow at the unit level. Rotation behavior is otherwise **manual only**.

---

### 8.6 Flow F — Stage Manager: arbitrary window sizes and the live size-class crossing

Matrix rows M11/M12. The app has no Stage-Manager-specific code path — routing input is
exactly the horizontal size class of §2.1, recomputed live — but Stage Manager is the only
mode where the user drags a window CONTINUOUSLY through the compact↔regular boundary, so it
stresses the same swaps as Flow C under sustained resize.
<!-- src: Tessera/ContentView.swift lines 179-196 (isPhone derived from horizontalSizeClass; contentShell branches on it); Tessera/Design/DesignTokens.swift (CompactLayout.isPhone) -->

**Preconditions:** iPad supporting Stage Manager (iPadOS Settings → Multitasking & Gestures
→ Stage Manager on); pre-complete launch args; at least one saved host and one stored key;
fixture host reachable for step 7.

**Steps:**

1. Open Tessera in a large Stage Manager window.
   -> Expected: sidebar shell (regular width). The exact point-size at which iPadOS assigns
   compact is device-dependent and not contractual — the shell on screen is the oracle, as
   everywhere in §2.2.
2. Grab a window corner and shrink the window slowly, continuously, through the size-class
   boundary.
   -> Expected: at the compact threshold the entire shell swaps live to the four-tab compact
   shell — the same swap as Flow C step 1, with no state loss. There must be exactly one
   clean swap per crossing: hold the window size right at the boundary and record any
   flicker/oscillation between shells.
   <!-- src: Tessera/ContentView.swift lines 179-196 (shell recomputed from the environment size class on every change) -->
3. In the compact-size window, route through the pages: `hosts` → `keys` (with the
   "keys"/"known hosts" selector) → `settings` → known hosts.
   -> Expected: phone layouts throughout, identical to Flow C steps 2–4 (drill-down
   settings without the themes gallery, single-pane keys, full-width modals).
   <!-- src: Tessera/Keys/KeysPageView.swift lines 43-84; Tessera/Settings/SettingsPageView.swift lines 15-91; Tessera/KnownHosts/KnownHostsPageView.swift lines 13-14 -->
4. Widen back across the boundary.
   -> Expected: sidebar shell returns; the keys page returns to two-pane list+detail and
   re-applies its initial auto-selection on the size-class change.
   <!-- src: Tessera/Keys/KeysPageView.swift lines 188-195 (explicit re-apply on size-class change) -->
5. Repeat the crossing with the **generate-key modal open**.
   -> Expected: the modal re-lays out between its 480 pt cap (regular) and full-width
   (compact) without clipping or dismissing — Flow C's divider edge case, but under a
   continuous drag rather than a discrete snap.
   <!-- src: Tessera/Keys/GenerateKeyModal.swift lines 89-91 -->
6. Repeat the crossing with the **host editor open** and a half-typed field.
   -> Expected: the editor persists (`selectedItem` unchanged) — compact renders the
   full-screen phone overlay editor, regular the detail-pane editor. Sharp edge to record:
   the two editors have DIFFERENT save semantics for the same record — iPad edits write
   through immediately, while the compact editor stages until "save". Values typed on the
   regular side before the crossing are already committed; values typed after it are staged
   and revert on "cancel". Record what the compact editor displays for each.
   <!-- src: Tessera/ContentView.swift lines 1213-1342 (compact overlay vs regular detail editor); Tessera/HostDetailView.swift (compact @State staging comment; iPad bindings write host.* directly) -->
7. Repeat the crossing with a **live session open**.
   -> Expected: the session survives the swap (views stay mounted in both shells): regular
   gets the floating pill bar and sidebar-over-terminal scrim; compact gets the 44 pt bar
   with the red disconnect — Flow C step 7 semantics.
   <!-- src: Tessera/ContentView.swift lines 362-376, 1102-1210 (shared detailContent in both shells) -->
8. Add a second app to the same stage and move focus to it while a Nearby Setup attempt is
   on the setup screen.
   -> Expected: the coordinator cancels only when the app's scene actually reports
   `.background` — whether an unfocused-but-visible Stage Manager window backgrounds the
   scene is OS behavior, not app code. **Observe and record** whether the attempt survives
   focus loss; if the scene backgrounds, the §3.6 cancel semantics apply.
   <!-- src: Tessera/TesseraApp.swift — onChange(of: scenePhase) .background -> bootstrapCoordinator.stopForBackground() -->

**Device/orientation variants:** Rotation while in Stage Manager can change the window's
assigned size — treat any resulting crossing as this flow, not Flow E. External-display
stages inherit the same size-class rule; record observed classes per geometry.

**Edge & failure cases:**

- Welcome-card / walkthrough gating in a Stage Manager window follows the same `!isPhone`
  mount as Split View — §4.4's expectations apply verbatim to a regular-size Stage Manager
  window, including the mid-tour unmount/remount when dragging across the boundary.
- Session-restore policy in a compact-size Stage Manager window follows the compact shell
  (`ask` silently reopens) exactly as §7.8's shell-based split.

**Automated coverage:** none — no lane runs Stage Manager (§9.6). The nearest adjacent
coverage is the unit-level compact-restore policy test
(`SessionRestoreStoreTests.testCompactPresentationTreatsAskAsRestoreOnLaunchWithoutChangingOtherPolicies`);
the shell swap under continuous resize, the modal/editor re-layouts, and step 8 are
**manual only**.

---

### 8.7 Status bar & system overlay summary

| Presentation | Status bar | Home indicator / system overlays |
|---|---|---|
| iPhone, root tabs | Visible | Automatic |
| iPhone, session overlay open | Hidden | Automatic |
| iPad (regular shell), everywhere | Hidden | Hidden |
| Compact iPad window | Follows the phone rule above inside the pane; the system owns the shared status bar in Split View | Automatic |

<!-- src: Tessera/ContentView.swift lines 780-781 -->

The lock screen (Flow D) and the Nearby Setup flow paint their own full-screen backgrounds
(`tokens.bg` / `T.presentationBg`) and are unaffected by these rules.
<!-- src: Tessera/Security/LockScreenView.swift lines 37-38, 99; Tessera/Bootstrap/BootstrapFlowView.swift line 15 -->

---

## 9. Appendix: automated coverage catalog

<!-- src: scripts/integration/README.md, scripts/integration/run-integration-tests.sh, scripts/integration/run-programmatic-tests.sh, TesseraUITests/TerminalScrollHarnessTests.swift, TesseraUITests/VisualCaptureProbe.swift -->

This appendix is the master index of everything that is ALREADY verified by automation, so the
manual chapters never re-test it. When a manual flow overlaps a lane below, the manual tester
should **spot-check** (one quick pass to confirm the automated result still matches reality on
their device/orientation), not re-execute the full script (§1.7).

Automation is organized in three layers:

1. **Fast per-change unit lane** — the ordinary `TesseraTests` + Swift package tests
   (~660 tests). Run via `xcodebuild test -project Tessera.xcodeproj -scheme Tessera
   -destination 'platform=iOS Simulator,name=<sim>'` or `swift test --package-path Packages/<name>`.
   <!-- src: scripts/integration/README.md ("The ordinary ~660 unit/package tests remain the fast per-change lane") -->
2. **Opt-in integration regression suite** — `scripts/integration/run-integration-tests.sh`
   orchestrates (a) capture of every visual case, (b) exactly one aggregate Codex AI review of all
   captured evidence, and (c) deterministic host/app lanes, joined into
   `scripts/integration/out/<run-id>/report.json`. It uses two disposable Linux VPS fixtures
   (`fixture.env`) plus dedicated simulators and never touches the user's own simulators or Mac
   SSH/tmux setup. <!-- src: scripts/integration/run-integration-tests.sh, scripts/integration/README.md -->
3. **Directly-run UI harnesses** — XCTest classes in `TesseraUITests/TerminalScrollHarnessTests.swift`
   that are NOT wired into any integration runner on this branch
   (`SidebarToggleHarnessTests`, `OrientationButtonSweepTests`, `IPhoneCompanionHarnessTests`,
   `AccessoryEditorHarnessTests`) and are invoked with plain `xcodebuild test -only-testing:` against
   an iPad or iPhone simulator. <!-- src: TesseraUITests/TerminalScrollHarnessTests.swift; no scripts/ reference exists for these class names -->

> Note: `TesseraUITests` has one source file containing seven test classes, and several
> `TesseraTests` classes live in files with different names (e.g. `AgentCenterSafetyTests` is in
> `TesseraTests/SwipePadProfileTests.swift`, `HostLaunchPrologueTests` is in
> `TesseraTests/MoshBootstrapTests.swift`). Search by class name, not file name.
> <!-- src: TesseraTests/SwipePadProfileTests.swift, TesseraTests/MoshBootstrapTests.swift -->

### 9.1 Integration suite — deterministic lanes

All rows below are `run_case` entries executed by `scripts/integration/run-programmatic-tests.sh`
(inside `run-integration-tests.sh`). Every lane needs `fixture.env` (copy
`fixture.env.example`; both VPS fixtures provisioned via `./scripts/integration/provision-fixtures.sh`)
unless marked *sim-only*. Results land in `out/<run-id>/programmatic/results.json` plus per-lane
`.xcresult` bundles. <!-- src: scripts/integration/run-programmatic-tests.sh, scripts/integration/lib.sh -->

| Lane / suite | What it verifies | How to run | Onboarding-relevant? |
|---|---|---|---|
| `fixture_contract` (`verify-fixtures.sh`) | Both fixture hosts answer the PTY identity probe, run exactly tmux 3.4 (stable) / 3.6a (chaos), have a no-tmux restricted user, and serve the loopback forwarding target. | `./scripts/integration/verify-fixtures.sh` | No (infra gate) |
| `ssh_pty_stable` / `ssh_pty_chaos` | 25 deterministic `TESSERA_ROW_` lines arrive intact over a live SSH PTY on each host. | via `run-programmatic-tests.sh` | No |
| `tmux_capture_*`, `tmux_isolation_*`, `tmux_missing_*` | Live tmux capture-pane fidelity, two-session isolation (renames/current-path do not bleed across sessions), and the deterministic no-tmux fallback user on both tmux versions. | via `run-programmatic-tests.sh` | No |
| `forwarding_target_*`, `sftp_*` | Loopback HTTP forwarding target answers `TESSERA_FORWARD_OK`; SFTP listing shows hidden/extension-less fixtures. | via `run-programmatic-tests.sh` | No |
| `agent_integration_scripts` (`run-agent-integration-script-tests.sh`) | Compiles the production Agent Center installer source, syntax-checks every generated script for sh/bash/zsh, performs fresh bash and ZDOTDIR-zsh installs in throwaway HOMEs, proves idempotent rc persistence, validates the legacy Claude settings compatibility file, and drives Codex trusted/untrusted/disabled readiness through a deterministic app-server double. | `./scripts/integration/run-agent-integration-script-tests.sh RUN_DIR` (*sim-only*, no fixtures) | No |
| `app_offline_oracles` (`run-offline-oracle-tests.sh`) | Host-free XCTest oracles on the dedicated iPad sim: `AgentCenterSafetyTests`, `RemoteShellIntegrationInstallerTests`, `TesseraMigrationTests` (SwiftData store reopen through the migration plan), `TerminalScrollbackOracleTests` (BCE colored-tail scrub), `HostLaunchPrologueTests`. | `./scripts/integration/run-offline-oracle-tests.sh RUN_DIR` | No |
| `app_sync_security_and_lifecycle_units` (`run-sync-unit-tests.sh`) | The comprehensive secret-boundary/protocol regression gate: `ContinuityFoundationTests`, `ContinuityLifecycleTests`, `SessionRestoreResolverTests`, all four `Enrollment*Tests`, all five `Bootstrap*Tests` (coordinator, manifest, manifest adapter, nearby handshake, nearby transfer service), `RemoteInstallationLedgerTests`, `RemoteAuthorizedKeysInstallerTests`, `SyncClassificationTests`, `HostKeyVerificationRequestTests`, `MoshBootstrapTests`, and two `KeyStoreSecurityTests` key-material cases. | `./scripts/integration/run-sync-unit-tests.sh RUN_DIR` | **Yes** — Nearby Setup state machine, manifest transfer, enrollment, first-open key provisioning |
| `tmux_control_pane_commands`, `tmux_control_compact_client_role` | `Packages/TmuxControl` package tests: pane command encoding and the compact (phone) client-role controller behavior. | `swift test --package-path Packages/TmuxControl --filter PaneCommandTests` (and `--filter TmuxControllerTests/test_compact`) | Partially — compact client sizing backs the iPhone tmux experience |
| `app_live_transports_tmux_files_forwarding` (`run-app-transport-tests.sh`) | `TesseraTests/RealHostTransportIntegrationTests` against the live fixtures via `TESSERA_REAL_HOST_CONFIG_B64`: live password + generated-Ed25519 auth over SSH and mosh, TOFU fingerprint/type, accepted-key persistence, wrong-password classification, idempotent key install/revoke, tmux hydration, FileBridge operations, port forwarding (matrix rows C1, C2, HK1, KS1/KS5, C4/C5/W1, F1/F7, PF1). | `./scripts/integration/run-app-transport-tests.sh RUN_DIR` | **Yes** — first-connection TOFU + auth outcomes that follow "add your first host" |
| `real_agent_center_state_transitions` (`run-real-agent-e2e.sh`) | Opt-in credentialed gate: the actually installed Codex + Claude Code run in isolated tmux servers and must emit the full provider lifecycle (`idle → working → waitingForInput → working → idle`, plan approval, hook tables). | `TESSERA_RUN_REAL_AGENT_E2E=1 ./scripts/integration/run-real-agent-e2e.sh` (needs local `codex`, `claude`, `tmux`, `swiftc`, both CLIs authenticated) | No |
| `app_jump_host_transports` (`jump/run-jump-transport-tests.sh`) | Opt-in `JumpHostTransportIntegrationTests` against a two-droplet bastion/target bed: chained SSH, per-hop TOFU and auth attribution, multi-hop, SFTP + forwarding through the chain, mosh-UDP-blocked fallback. | Configure `jump/jump.env`, then automatic in the suite, or `./scripts/integration/jump/run-jump-transport-tests.sh` | No |
| `app_terminal_scroll_wiring` (`run-scroll-harness-tests.sh`) | `TerminalScrollHarnessTests/testPrimaryScrollMovesIntoHistoryAndBackToBottom`: host-free 500-row DEBUG surface; indirect-pointer scroll enters history and clamps back to the live tail via an accessibility oracle. Gated: skips unless `TESSERA_SCROLL_CAPTURE=1`. | `./scripts/integration/run-scroll-harness-tests.sh RUN_DIR` (sets `TESSERA_SCROLL_CAPTURE`/`TESSERA_SCROLL_HARNESS` in the sim's launchd) | No |
| `app_iphone_keyboard_and_tmux_viewport` (`run-iphone-keyboard-harness-tests.sh`) | On a dedicated **iPhone 17 Pro** sim: `IPhoneKeyboardHarnessTests` — "Hide keyboard" dismisses, viewport row count grows, the dismiss control does not cover the "Left arrow" accessory key, and only a terminal tap reclaims first responder; plus `PaneLayoutMathTests/test_compactTmuxClientSizingProjectsFocusedPaneToPhoneViewport`. | `./scripts/integration/run-iphone-keyboard-harness-tests.sh RUN_DIR` | **Yes** — first iPhone session keyboard behavior |
| `app_continuity_descriptor_routes` (`run-continuity-harness-tests.sh`) | `ContinuityHarnessTests` (DEBUG descriptor injection, never connects): a never-seen Handoff descriptor stops at the "add host & connect" credential editor with Connect disabled; tmux vs plain-shell routing; matched-host exact/endpoint resolution overlays; locked-descriptor replay after unlock; informed TOFU match ("Trust & Connect") and mismatch ("Don't Connect"/"Trust Anyway"). Gated: skips unless `TESSERA_CONTINUITY_CAPTURE=1`; runner pre-writes `tessera.nearbyBootstrap.completed.v1` + `tessera.pref.hasSeenWelcome` so first-open UI cannot obscure the descriptor UI. | `./scripts/integration/run-continuity-harness-tests.sh RUN_DIR` | **Yes** — the Handoff-initiated "add host & connect" variant of onboarding |
| `mosh_orphan_budget_*` | Post-test `mosh-server` process count on each host stays ≤ 1. | via `run-programmatic-tests.sh` | No |
| `app_nearby_bootstrap_two_sim` (`run-bootstrap-network-harness-tests.sh`) | Creates a **run-scoped disposable iPad Pro 13" M4 + iPhone 17 Pro pair** (deleted afterwards by explicit UDID), installs the Debug app on both, sets `TESSERA_BOOTSTRAP_NETWORK_HARNESS=origin\|recipient`, and requires production Bonjour discovery, TCP framing, X25519/HKDF, **matching six-digit SAS codes on both roles**, encrypted manifest transfer, grant receipts, and `result=completed installed=1` on both roles within ~60 s. | `./scripts/integration/run-bootstrap-network-harness-tests.sh RUN_DIR` (*sim-only*; needs `jq`, `rg`, iOS 26 runtime) | **Yes** — the entire Nearby Setup network path behind first-open import |

<!-- src: scripts/integration/run-programmatic-tests.sh, scripts/integration/verify-fixtures.sh, scripts/integration/run-agent-integration-script-tests.sh, scripts/integration/run-offline-oracle-tests.sh, scripts/integration/run-sync-unit-tests.sh, scripts/integration/run-app-transport-tests.sh, scripts/integration/run-real-agent-e2e.sh, scripts/integration/jump/run-jump-transport-tests.sh, scripts/integration/run-scroll-harness-tests.sh, scripts/integration/run-iphone-keyboard-harness-tests.sh, scripts/integration/run-continuity-harness-tests.sh, scripts/integration/run-bootstrap-network-harness-tests.sh, TesseraUITests/TerminalScrollHarnessTests.swift -->

### 9.2 Integration suite — visual cases (AI-reviewed)

Captured by `capture-visual-evidence.sh` on the dedicated **"Tessera Visual Integration Tests"**
iPad simulator (landscape-primed via `VisualCaptureProbe/testSetLandscapeOnly`; screenshots are
rotation-normalized with `sips -r 270`), then judged in **one** aggregate `codex exec` review
(`run-visual-review.sh` + `visual-review-prompt.md`) that must return exactly one verdict per case.
Skip the AI lane with `run-integration-tests.sh --no-ai-visual` (captures still run).
<!-- src: scripts/integration/capture-visual-evidence.sh, scripts/integration/prepare-visual-simulator.sh, scripts/integration/run-visual-review.sh, scripts/integration/visual-review-prompt.md -->

| Case | What it verifies | How it captures | Onboarding-relevant? |
|---|---|---|---|
| `O1-onboarding-tour` (`o1-onboarding-tour.sh`) | All **eight** forced walkthrough steps, launched with `SIMCTL_CHILD_TESSERA_FORCE_TOUR_STEP=0..7`: each capture shows the matching "STEP N OF 8" state; callouts fully on-screen with readable title/body and an unbroken single-row footer; buttons/page dots do not overlap or clip; spotlight rings in steps 1–2 align with the intended control; the six illustration steps render complete diagrams without missing layers/black rectangles/stale frames/edge clipping. Landscape iPad only. | 8 relaunches + `simctl io screenshot` per step | **Yes** — walkthrough visual integrity |
| `P1-iphone-keyboard` (`p1-iphone-keyboard.sh`) | Against a real 160x50 SSH+tmux htop/Vim split on the stable fixture: the portrait iPhone presents only the focused pane full-width with readable 13 pt text while the software keyboard + accessory bar are visible; a later iPad attach expands the same layout instead of inheriting a phone-width split. Includes a deterministic remote tmux geometry pre-check. | Dedicated iPhone 17 Pro sim + visual iPad sim, `TESSERA_LIVE_SCROLL_HARNESS`/`_CONFIG_B64` (needs `fixture.env`) | **Yes** — first iPhone session appearance |
| `A1-A5-terminal-canvas` (`a1-a5-terminal-canvas.sh`) | Full-bleed terminal background, no black letterbox/chrome slab, no stale-width seams (matrix A1/A5/G3). | DEBUG canvas harness, one still | No |
| `AG1-agent-center` (`ag1-agent-center.sh`) | Agent Center lifecycle states, session identity, counters, attention routing, install-prompt/help disclosures (plus focused `VisualCaptureProbe` XCUITests). | probes + harness screenshots | No |
| `C4-tmux-foreground-refresh` (`c4-tmux-foreground-refresh.sh`) | Inline tmux foreground restore does not replay deep history (live fixture recording). | recording + event timeline (needs `fixture.env`) | No |
| `F12-files-context-menu` (`f12-files-context-menu.sh`) | Files card glass stays backed through context-menu suppression; settled geometry recovers. | recording + stills + signal stats | No |
| `R1-tmux-empty-capture` (`r1-tmux-empty-capture.sh`) | A zero-row tmux capture preserves the established viewport and visibly recovers on retry (log-token oracle + stills). | DEBUG host-free harness | No |
| `S1-S6-live-scroll-transports` (`s1-s6-live-scroll-transports.sh`) | Real scrollback + htop/Vim wheel forwarding across ssh / ssh+tmux / mosh / mosh+tmux (3x3 evidence sheet per transport). | live fixture recordings (needs `fixture.env`) | No |
| `W1-tmux-window-close` (`w1-tmux-window-close.sh`) | Per-tab close controls and the split-pane destructive confirmation (XCUITest assertions + stills). | DEBUG harness + `VisualCaptureProbe/testTmuxWindowCloseControls` | No |

<!-- src: scripts/integration/visual-cases/o1-onboarding-tour.sh, scripts/integration/visual-cases/p1-iphone-keyboard.sh, scripts/integration/visual-cases/a1-a5-terminal-canvas.sh, scripts/integration/visual-cases/ag1-agent-center.sh, scripts/integration/visual-cases/c4-tmux-foreground-refresh.sh, scripts/integration/visual-cases/f12-files-context-menu.sh, scripts/integration/visual-cases/r1-tmux-empty-capture.sh, scripts/integration/visual-cases/s1-s6-live-scroll-transports.sh, scripts/integration/visual-cases/w1-tmux-window-close.sh, Tessera/ContentView.swift (TESSERA_FORCE_TOUR_STEP) -->

### 9.3 UI-test harnesses run directly with `xcodebuild` (this branch)

These classes live in `TesseraUITests/TerminalScrollHarnessTests.swift` and have **no runner script**;
run them with
`xcodebuild test -project Tessera.xcodeproj -scheme Tessera -destination 'platform=iOS Simulator,name=<sim>' -only-testing:TesseraUITests/<Class>`.
<!-- src: TesseraUITests/TerminalScrollHarnessTests.swift -->

| Suite | What it verifies | Gating / prerequisites | Onboarding-relevant? |
|---|---|---|---|
| `SidebarToggleHarnessTests` | On iPad in **both portrait and landscape**: the sidebar starts expanded on every orientation (collapse chevron `hide sidebar` present after launch), collapsing shows the floating `show sidebar` reveal button, and tapping it reopens the sidebar (regression for the iPadOS 26 `.automatic == .detailOnly` portrait no-op). | Skips unless `SIMULATOR_DEVICE_NAME` contains "iPad". Launches with `-tessera.nearbyBootstrap.completed.v1 YES` and `-tessera.pref.hasSeenWelcome YES` so Nearby Setup does not cover the landing page. | **Yes** — post-onboarding landing-page sidebar behavior |
| `OrientationButtonSweepTests` | Dead-tap sweep of every primary browse-surface control, reporting all failures at once. iPad: sidebar rows (keys / known hosts / tunnels / settings / "view all hosts"), collapse/reveal round-trip, `new host, ⌘N` header chip, `add your first host, ⌘N` empty-state CTA, `generate a key`, sidebar `new host` +. iPhone: compact tab bar (sessions / keys / settings / hosts), the keys↔known-hosts selector, `add your first host`, `generate a key` (phone labels carry no ⌘N chip). Four tests: iPad/iPhone x portrait/landscape. | Each test skips unless the sim name matches its idiom; `TESSERA_SWEEP_FORCE=1` bypasses the check. Same two first-open launch arguments. Failure screenshots land in `/tmp/tessera-sweep-*.png`. | **Yes** — every empty-state CTA a new user meets |
| `IPhoneCompanionHarnessTests` | iPhone session palette long-press menus: tmux window offers "Switch to"/"Rename"/"Close window" (and the "Rename tmux window" alert with "Window name" field); tmux pane offers "Switch to"/"Split left / right"/"Split top / bottom"/"Close pane"; window vs pane actions never cross-contaminate. | `TESSERA_IPHONE_SESSION_HARNESS=1` is set by the tests themselves; run on an iPhone sim. | No |
| `AccessoryEditorHarnessTests` | Accessory-bar editor Preview: tap removes a chip, quick horizontal swipe scrolls instead of reordering, long-press-then-drag still reorders. | none (harness env set by tests) | No |
| `TerminalScrollHarnessTests` | (listed in §9.1 — driven by `run-scroll-harness-tests.sh`) | `TESSERA_SCROLL_CAPTURE=1` else skip | No |
| `ContinuityHarnessTests` | (listed in §9.1 — driven by `run-continuity-harness-tests.sh`) | `TESSERA_CONTINUITY_CAPTURE=1` else skip | **Yes** |
| `IPhoneKeyboardHarnessTests` | (listed in §9.1 — driven by `run-iphone-keyboard-harness-tests.sh`) | iPhone sim required | **Yes** |

### 9.4 Unit-test themes (`TesseraTests` + packages)

Skim-level index for manual testers; run as the ordinary per-change lane. Onboarding-relevant
themes are bolded.

| Theme | Classes/files | Onboarding-relevant? |
|---|---|---|
| **Walkthrough gating** | `OnboardingControllerTests` — the `beginIfFirstLaunch` truth table (welcome shows only when unseen AND no hosts; idempotent; does not reset an active tour) | **Yes** |
| **Nearby Setup / bootstrap** | `BootstrapCoordinatorTests` (first-open presentation starts no networking and creates no key; "set up as new" provisions the device key **before** marking first-open complete), `BootstrapManifestTests`, `BootstrapManifestAdapterTests`, `BootstrapNearbyHandshakeTests`, `BootstrapNearbyTransferServiceTests` | **Yes** |
| **Device enrollment** | `EnrollmentMessagesTests`, `EnrollmentServiceTests`, `EnrollmentCoordinatorTests`, `EnrollmentContinuationStreamTransportTests` | **Yes** |
| Continuity / restore | `ContinuityFoundationTests`, `ContinuityLifecycleTests`, `SessionRestoreResolverTests`, `SessionRestoreStoreTests`, `SessionRegistryTests`, `SessionSwitcherTests` | Partially (Handoff-driven add-host) |
| **Keys & trust** | `KeyStoreSecurityTests`, `BiometricRevocationRaceTests`, `SSHAuthenticationPolicyRaceTests`, `KnownHostsStoreTests`, `HostKeyVerificationRequestTests` | **Yes** — key generation + TOFU logic behind first connect |
| Transports & hosts | `RealHostTransportIntegrationTests`, `JumpHostTransportIntegrationTests`, `HostJumpChainResolverTests`, `MoshBootstrapTests` (+`HostLaunchPrologueTests`), `OSDetectorTests` | Partially (first connection) |
| Remote install | `RemoteAuthorizedKeysInstallerTests`, `RemoteInstallationLedgerTests`, `RemoteShellIntegrationInstallerTests`, `RemotePathResolverTests`, `RemoteCwdPollerTests` | Partially (key install during first connect) |
| Terminal rendering & layout | `TerminalScrollbackOracleTests`, `TerminalBackdropTests`, `TerminalBackgroundTests`, `PaneLayoutMathTests`, `KittyWindowModeStoreTests` | No |
| Files | `FileBridgeTests`, `TransferQueueTests` | No |
| Input / accessory UI | `AccessoryChipEncoderTests`, `MacroEncoderTests`, `ModifierStateTests`, `SwipePadProfileTests` (+`AgentCenterSafetyTests`), `CommandPaletteTests` | No |
| Data & sync | `TesseraMigrationTests`, `SyncClassificationTests` | No |
| Packages | `Packages/TmuxControl` (`PaneCommandTests`, `TmuxControllerTests` incl. compact client role), `MoshBridge`, `PortForwarding`, `ScrollDispatcher` — `swift test --package-path Packages/<name>` | No |

<!-- src: TesseraTests/OnboardingControllerTests.swift, TesseraTests/BootstrapCoordinatorTests.swift, TesseraTests directory listing, Packages directory listing, scripts/integration/run-programmatic-tests.sh -->

### 9.5 Prerequisites per lane

| Prerequisite | Needed by | Notes |
|---|---|---|
| `scripts/integration/fixture.env` + provisioned VPS pair | all `run-programmatic-tests.sh` host lanes; visual cases `P1`, `C4`, `S1-S6`; `run-app-transport-tests.sh` | Copy `fixture.env.example`; `./scripts/integration/provision-fixtures.sh` then `verify-fixtures.sh`. Generated client keys/passwords/known-hosts live in ignored `.state/`. <!-- src: scripts/integration/README.md, scripts/integration/lib.sh --> |
| Dedicated simulator **"Tessera Integration Tests"** (iPad Pro 13" M4, iOS 26 runtime) | scroll, continuity, sync-unit, offline-oracle, transport, jump lanes | Auto-created/booted by `ensure-test-simulator.sh`; UDID cached in `.state/simulator_udid`. Overridable via `TESSERA_INTEGRATION_SIMULATOR_NAME/_DEVICE_TYPE/_RUNTIME/_UDID_FILE`. <!-- src: scripts/integration/ensure-test-simulator.sh --> |
| Dedicated simulator **"Tessera Visual Integration Tests"** (iPad) | all visual cases | Separate from the deterministic sim so reinstalls cannot terminate the app mid-recording. <!-- src: scripts/integration/prepare-visual-simulator.sh --> |
| Dedicated simulator **"Tessera Integration iPhone Keyboard"** (iPhone 17 Pro) | `run-iphone-keyboard-harness-tests.sh`, visual case `P1` | UDID cached in `.state/iphone_keyboard_simulator_udid`. <!-- src: scripts/integration/run-iphone-keyboard-harness-tests.sh, scripts/integration/visual-cases/p1-iphone-keyboard.sh --> |
| Run-scoped disposable sim pair (iPad Pro 13" M4 + iPhone 17 Pro) | `run-bootstrap-network-harness-tests.sh` | Created and **deleted by explicit UDID** each run; device types/runtime overridable via `TESSERA_BOOTSTRAP_*` env. <!-- src: scripts/integration/run-bootstrap-network-harness-tests.sh --> |
| launchd env injection (`xcrun simctl spawn <udid> launchctl setenv ...`) | scroll (`TESSERA_SCROLL_CAPTURE`, `TESSERA_SCROLL_HARNESS`), continuity (`TESSERA_CONTINUITY_CAPTURE`), transports (`TESSERA_REAL_HOST_CONFIG_B64`), bootstrap pair (`TESSERA_BOOTSTRAP_NETWORK_HARNESS`), visual sim (`TESSERA_VISUAL_CAPTURE`), live-scroll cases (`TESSERA_LIVE_SCROLL_HARNESS`, `TESSERA_LIVE_SCROLL_CONFIG_B64`) | Runners set and unset these; if a lane is killed mid-run, stale launchd env on the dedicated sim can leak into the next manual session — `launchctl unsetenv` or shut the sim down. <!-- src: scripts/integration/run-scroll-harness-tests.sh, scripts/integration/run-continuity-harness-tests.sh, scripts/integration/run-app-transport-tests.sh --> |
| `codex` CLI (authenticated) | `run-visual-review.sh` | Or run with `--no-ai-visual`. <!-- src: scripts/integration/run-visual-review.sh --> |
| `TESSERA_RUN_REAL_AGENT_E2E=1` + local authenticated `codex` **and** `claude` + `tmux` + `swiftc` | `run-real-agent-e2e.sh` | Deliberately opt-in; isolated tmux sockets; no shell-config mutation. <!-- src: scripts/integration/run-real-agent-e2e.sh, scripts/integration/run-programmatic-tests.sh --> |
| `scripts/integration/jump/jump.env` + two-droplet jump bed | jump-host lane | Auto-detected by `run-programmatic-tests.sh`; skipped otherwise. <!-- src: scripts/integration/run-programmatic-tests.sh --> |
| CLI tools: `jq`, `rg`, `sftp`, `sips`, `xcodebuild`, `xcrun`, `python3` | various | Checked via `require_command`. <!-- src: scripts/integration/lib.sh --> |

### 9.6 Onboarding flows already covered — spot-check only

Manual chapters reference this list and do **not** re-test these behaviors in full:

- **O1 walkthrough visuals (iPad landscape)** — all eight forced steps: step identity,
  clipping, single-row footer, spotlight alignment, illustration integrity. *Spot-check only:*
  actually tapping through the walkthrough, skip/exit paths, portrait, and iPhone rendering —
  the automated captures are forced-step landscape-iPad stills only.
  <!-- src: scripts/integration/visual-cases/o1-onboarding-tour.sh -->
- **Walkthrough start conditions** — `OnboardingControllerTests` proves the welcome/tour only
  starts when unseen AND no hosts exist, and is idempotent. *Spot-check only:* one
  fresh-install launch. <!-- src: TesseraTests/OnboardingControllerTests.swift -->
- **Nearby Setup network path** — the two-simulator bootstrap harness proves production Bonjour
  discovery, encrypted channel, matching SAS, manifest transfer, and completion (`installed=1`) on
  both roles; `Bootstrap*Tests` prove no networking/key creation on mere presentation and that
  "set up as new" provisions the device key before marking first-open complete. *Manual testers own:*
  the visible first-open sheet itself, the re-present-until-completed loop after cancel (§3.2),
  origin-side interruption during transfer (§3.8), the Settings-initiated re-receive path on a
  completed device (§3.9), and the physical Local Network permission prompt (§3.10 — explicitly
  out of automated scope).
  <!-- src: scripts/integration/run-bootstrap-network-harness-tests.sh, TesseraTests/BootstrapCoordinatorTests.swift, scripts/integration/README.md ("S1 nearby bootstrap" row) -->
- **Sync/enrollment/continuity unit gate** — `run-sync-unit-tests.sh` keeps every enrollment
  message/service/coordinator boundary and continuation route under regression. *Spot-check only:*
  end-to-end import UX on real devices.
  <!-- src: scripts/integration/run-sync-unit-tests.sh -->
- **iPad sidebar first-launch behavior** — `SidebarToggleHarnessTests` proves the sidebar launches
  expanded in portrait AND landscape and the collapse/reveal round-trip works. Do not re-test the
  toggle mechanics; spot-check only visual polish and Split View/Slide Over widths (not covered —
  the harness runs full-screen only).
  <!-- src: TesseraUITests/TerminalScrollHarnessTests.swift (SidebarToggleHarnessTests) -->
- **Browse-page CTA reachability** — `OrientationButtonSweepTests` sweeps every sidebar row, tab-bar
  tab, `add your first host` / `generate a key` / `new host` CTA and the keys↔known-hosts selector
  on both idioms and orientations, failing on any dead tap. Do not manually re-tap each control;
  spot-check hit-target *comfort* (the >=44 pt feel) which a pass/fail tap cannot judge.
  <!-- src: TesseraUITests/TerminalScrollHarnessTests.swift (OrientationButtonSweepTests) -->
- **P1 iPhone keyboard + first session on iPhone** — the visual case plus
  `IPhoneKeyboardHarnessTests` cover keyboard show/hide/reclaim, accessory-bar overlap, focused-pane
  projection, and readable phone text against a real host. *Spot-check only:* landscape-iPhone
  keyboard and hardware-keyboard variants.
  <!-- src: scripts/integration/visual-cases/p1-iphone-keyboard.sh, scripts/integration/run-iphone-keyboard-harness-tests.sh -->
- **Handoff/continuation onboarding variant** — `ContinuityHarnessTests` proves a never-seen
  descriptor lands on "add host & connect" with the Connect button disabled until credentials are
  entered, preserves named-tmux vs plain-shell routing, and shows informed-TOFU choices. *Manual
  testers own:* real cross-device Handoff (physical-device-only per the README).
  <!-- src: scripts/integration/run-continuity-harness-tests.sh, TesseraUITests/TerminalScrollHarnessTests.swift (ContinuityHarnessTests), scripts/integration/README.md -->
- **First-connection trust & auth outcomes** — `RealHostTransportIntegrationTests` covers live TOFU
  fingerprint/type, wrong-password classification, key install/revoke idempotence over SSH and mosh.
  *Manual testers own:* the host-key sheet UI itself and Face ID/Secure Enclave paths (device-only).
  <!-- src: scripts/integration/run-app-transport-tests.sh, scripts/integration/README.md (C1/C2/HK1/KS1 row) -->

**Not covered by any lane (manual chapters must own these):** the Nearby Setup sheet's
cancel → `hasSeenWelcome` observer behavior and re-presentation loop (§3.2); origin-side
interruption during transfer (§3.8); the Settings-initiated re-receive path (§3.9); Local
Network permission timing and denial (§3.10); upgrade-in-place first-open gating and
real-device migrations (§3.11 — the MG1 oracle covers only the store reopen); onboarding on
compact iPad windows (Split View / Slide Over); walkthrough rendering in portrait, on iPhone
(verify absence), and in regular-width Split View panes (§4.4); the enrollment approval
overlay UI and real cross-device Handoff (§6.14); Stage Manager (§8.6 Flow F); Face ID;
dictation and hardware-keyboard chords intercepted by Simulator.
<!-- src: scripts/integration/README.md ("Intentionally manual"), scripts/integration/visual-cases/o1-onboarding-tour.sh (landscape-only capture) -->

---

## 10. Reusable Codex Desktop missions

These prompts are designed to be pasted into a fresh Codex Desktop thread with this guide
and the repository available. Replace bracketed values. Keep separate threads for separate
personas so prior implementation knowledge does not contaminate a first-user pass.

### 10.1 Recommended mission order

For a release candidate, run these as independent sessions:

| Order | Mission | Minimum environment | Main value |
| --- | --- | --- | --- |
| 1 | First-time iPad onboarding | Fresh full-screen iPad simulator, portrait | Primary hierarchy and onboarding comprehension |
| 2 | First-time iPhone host setup | Fresh iPhone simulator, portrait + landscape | Compact navigation, form, keyboard, Save/Cancel |
| 3 | Connection failure and recovery | Seeded saved host + fixture | Progress, TOFU, wrong password, retry/edit/back |
| 4 | Nearby Setup cross-device | Fresh recipient + prepared origin | Device roles, trust, waiting states, receipts |
| 5 | Responsive layout stress | iPad Split View + Stage Manager | State preservation across shell changes |
| 6 | Physical security surfaces | Two physical devices | Face ID, Secure Enclave, Local Network, Handoff |
| 7 | Focused regression confirmation | Exact device/state from a fixed issue | Verify the user-visible defect and new automated guard |

Do not turn this into one continuous session. Clean state and an unprimed agent are part of
the test design.

### 10.2 First-time user mission

```text
Act as a first-time Tessera user performing exploratory QA through the visible iOS
Simulator. Follow the Codex Desktop operating protocol in §0 and the product expectations in
§§[SECTIONS].

Mission: [for example, complete first launch, set up as new, add the first SSH host, and
reach a usable terminal].

Use [DEVICE / ORIENTATION / WINDOW MODE] and start from [FRESH-INSTALL PROCEDURE].
Do not inspect source code, tests, accessibility identifiers, or logs until the visible
black-box pass is complete. Do not fix code during the mission.

Interact as a human user. Record every hesitation, wrong interpretation, accidental tap,
unclear state, visual defect, keyboard/focus issue, and recovery problem. Capture screenshots
or recordings before leaving a problematic state. Continue past non-blocking issues.

After the black-box pass, reproduce each finding, use code/logs only for diagnosis, map it to
existing automated coverage in §9, and produce findings using §0.8 plus the mission summary
in §0.9.
```

### 10.3 Visual and interaction polish mission

```text
Perform a visual and interaction QA pass of Tessera sections [SECTIONS] on
[DEVICE / WINDOW MODE]. This is not a functional assertion sweep.

For every screen and transition, judge hierarchy, spacing, clipping, text wrapping, tap
comfort, neighboring-control confusion, focus, keyboard coverage, animation continuity,
loading feedback, destructive-action prominence, and recovery clarity. Inspect the whole
screen after each action. Use screenshots for settled layout defects and recordings for
timing, keyboard, animation, or resize defects.

Run one normal path and one layout-stress variant: [ROTATION / DYNAMIC TYPE / SPLIT VIEW /
STAGE MANAGER / LIGHT THEME]. Treat a behavior that technically succeeds but feels confusing
or unstable as a valid finding. Do not inspect or edit source until the black-box pass is
finished. Report with §0.8 and §0.9.
```

### 10.4 Error-recovery mission

```text
Act as a plausible but imperfect user testing Tessera's recovery behavior in
[SECTIONS/FLOW]. Begin from [STARTING STATE].

Introduce only realistic mistakes: one invalid field, one wrong password or passphrase, one
cancel or denial, one background/interruption, and one retry. Do not use impossible internal
states unless the guide explicitly calls for them.

For each failure, assess:
1. whether the app acknowledges the initiating action;
2. whether it explains what happened;
3. whether it says what remained unchanged;
4. whether the next safe action is obvious;
5. whether retry preserves useful input and context;
6. whether repeated action creates duplicate or contradictory state.

Capture evidence at the first confusing state. Complete a diagnostic pass only afterward and
identify why existing automated coverage did or did not catch the user-visible problem.
```

### 10.5 Nearby Setup two-device mission

```text
Use Codex Desktop to test Tessera Nearby Setup with [ORIGIN DEVICE] and
[RECIPIENT DEVICE], following §§3 and 6 where referenced.

Keep both Simulator/device windows visible. Start the recipient fresh and prepare the origin
exactly as §1.6 describes. During the black-box pass, do not inspect protocol code or logs.

Continuously record:
- which device appears to require action;
- whether the origin/recipient roles are understandable;
- whether waiting states explain the dependency;
- whether the six-digit comparison and approval hierarchy feel safe;
- whether optional sensitive categories are visibly off by default;
- whether biometric approval describes the exact batch;
- whether receipts accurately communicate imported data and host access;
- whether cancel, denial, backgrounding, and retry leave both devices in understandable
  states.

Capture paired screenshots whenever the two devices disagree or one appears stuck. Afterward,
diagnose each issue and distinguish app behavior from Local Network or OS lifecycle behavior.
```

### 10.6 Responsive shell stress mission

```text
Test Tessera's live compact↔regular shell transition on an iPad using
[SPLIT VIEW / STAGE MANAGER], following §§2 and 8.

Before crossing the boundary, put the app in each of these meaningful states:
1. half-edited host form;
2. open key modal;
3. selected settings/detail page;
4. live terminal session;
5. walkthrough step, where supported.

Drag slowly across the boundary in both directions. Look for shell flicker, state loss,
unexpected save/revert, duplicate overlays, stale detail selection, focus loss, keyboard
misplacement, terminal disconnect/reflow, inaccessible controls, and navigation that strands
the user. Record the shell shown on screen rather than guessing the size class from geometry.

Do a black-box pass first, then inspect state-management code and existing coverage. Produce
one finding per independently actionable defect.
```

### 10.7 Focused regression confirmation

```text
Verify issue [ISSUE ID / DESCRIPTION] in build [BUILD].

Reproduce first on the known-bad build or commit using the original environment and exact
user-level steps. Capture evidence. Then test the candidate fix from a clean equivalent
state. Confirm both:
- the original user-visible failure is gone; and
- adjacent behavior still works, especially [CANCEL / RETRY / ROTATION / KEYBOARD /
  ALTERNATE SHELL].

Do not accept an automated-test pass as sufficient. Repeat the visible flow [N] times if it
was timing-sensitive. Identify the added or existing regression test and state precisely
what it proves versus what remains visually/manual.
```

### 10.8 Optional fix-and-verify handoff

Only after the exploratory report is saved:

```text
Using the confirmed findings from this QA report, fix [ISSUE IDS] in priority order. Preserve
the original reproduction evidence. For each fix:

1. explain the user-visible cause in one sentence;
2. make the smallest coherent implementation change;
3. add or update a deterministic regression test where useful;
4. build and run the targeted automated lane;
5. return to the visible Simulator and repeat the exact QA reproduction;
6. check one adjacent device/orientation or cancellation path;
7. update the issue with before/after evidence.

Do not close a finding solely because the code changed or tests passed.
```

### 10.9 Release-level deliverables

A complete Desktop QA run should leave:

```text
qa/onboarding/<build>/
  mission-summary.md
  findings/
    ONB-001.md
    ONB-002.md
  evidence/
    ONB-001-*.png
    ONB-002-*.mov
  logs/
    ONB-002-*.log
  coverage-notes.md
```

The exact directory is optional; stable issue IDs and evidence links are not. Keep UX
observations distinct from confirmed implementation defects, and keep product-oracle
questions distinct from failures against a documented expectation.
