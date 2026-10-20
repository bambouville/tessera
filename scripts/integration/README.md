# Tessera integration regression suite

This is the opt-in suite derived from `docs/manual-testing-matrix.md`. It uses
two disposable Linux VPS fixtures plus run-scoped disposable simulators; it never
connects through UI automation and never touches the user's existing simulator
or local Mac SSH/tmux setup.

## One-time fixture setup

### iOS keyboard dismissal

`bash scripts/integration/run-keyboard-dismissal-tests.sh /tmp/tessera-keyboard-<run>`
builds the app and tests on an owned landscape iPad, then deletes that device
on exit. It covers the system Hide key, explicit hide/show, output and SwiftUI
updates, terminal and mouse-reporting taps, local text fields, visibility,
rotation, foreground recovery, permission changes, and queued-focus races.
The shared `TerminalSurfaceBound` policy applies to SSH, SSH+tmux, mosh and
mosh+tmux. This host-free lane complements the existing iPhone keyboard and
hardware-keyboard lanes; physical iPad keyboard attachment and multitasking
remain device checks. Continuous video, milestone screenshots and xcresults
are saved in the supplied fresh directory. Set `TESSERA_INTEGRATION_PREBUILT=1`
to reuse the current integration build.
The lane disconnects Mac keyboard forwarding only for its disposable device
before boot. On Simulator, if native Hide prevents software-keyboard reopening,
the test checks a plain text field with no terminal mounted. If native input
is also unusable there (initially or after Hide), it records an explicit skip
for the final native visual/delivery
check. Dismissal persistence, foreground suppression and tap intent are still
asserted; explicit hide/show and mouse-reporting restoration require real key
delivery. A skip is not physical-device acceptance.

### Android Files directory following

`JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_SDK_ROOT=/path/to/android-sdk TESSERA_ANDROID_MOSH_OPENSSL_ROOT=/path/to/arm64-openssl bash scripts/integration/run-android-files-follow-tests.sh qa/<run>/files-follow`
builds the Android app and exercises terminal `cd` through live SSH, SSH+tmux,
mosh, and mosh+tmux into the production Files controller and SFTP listing.
It checks opening/reopening, manual browsing, resuming follow, and superseding
pending listings, including two simultaneous plain SSH sessions. The native tmux
subscription must deliver directory-only
changes; plain transports exercise the no-OSC shell probe. The runner uses
a disposable landscape Android tablet and exact run-scoped tmux sessions,
with cleanup on exit. This case also runs in the full native SSH gate.
It verifies data flow and listings, not physical-device touch behavior.
Set `TESSERA_FILES_FOLLOW_FIXTURE=chaos` to repeat against tmux 3.6a;
the default stable fixture runs tmux 3.4.

### Android terminal scrolling

`JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_SDK_ROOT=/path/to/android-sdk bash scripts/integration/run-android-scroll-harness-tests.sh qa/<run>/android-scroll`
creates a disposable Android phone, runs terminal unit tests and the 43 focused
native terminal cases, saves frame-by-frame scroll positions, and deletes the
owned AVD even on failure. The pixel-scroll cases check rendered sub-row motion,
ANSI background alignment, selection coordinates, native release deceleration,
touch interruption, wheel boundaries, output anchoring, and remote wheel/key
routing, including a mosh+tmux pane whose full-screen program asked for the
mouse while the visible tmux client shows no mouse mode. The app's debug
`scene=terminal, terminal_fixture=scroll` supplies
numbered colored history for portrait and landscape video capture without a host.
Include those captures with the run's single aggregate visual review. This
host-free lane does not replace the existing Android native SSH/Mosh fixture
lane or the live S1/S6 transport acceptance cases.
The mouse-mode regression checks a newly mounted alternate screen restoring
only mode 1003, plus resize, saved-mode restoration and repaint. It records
rendered frames and exact wheel bytes in `mouse-mode-recovery.tar`.
`TESSERA_TERMINAL_TEST_CLASS=<class>#<method>` selects one case for diagnosis.

### Offline Codex mouse lifecycle

`bash scripts/integration/prepare-codex-mouse-fixture.sh` stages the pinned
Codex 0.160.0 Linux binary and a synthetic 300-row conversation on the disposable
stable VPS, then prints its owned `/tmp/tessera-codex-...` root. The provider is
an unused loopback endpoint, requires no authentication, and receives no
submitted prompt. Each generated tmux pane uses its own Codex home.
Set `TESSERA_SCROLL_CODEX_FIXTURE_ROOT` to that root and run these lanes
sequentially:

- Android: select `TESSERA_LIVE_SCROLL_TEST_METHOD=liveCodexMouseSurvivesLifecycleOnBothTransports`
  with `run-android-live-scroll-tests.sh` and the native Mosh build settings below.
- iOS: select `TesseraTests/RealHostTransportIntegrationTests/test_liveCodexMouseSurvivesLifecycleOnBothTransports`
  with `run-app-transport-tests.sh` on an owned landscape simulator.

Both runners require an initial and a restore case to pass in separate app
processes. They keep the real Codex process and its unsent `KEEP MY DRAFT`
composer alive remotely. The cases verify older/newer transcript rows, its
1003-only mouse request, foreground recovery, and a dropped tmux control
connection on SSH+tmux and mosh+tmux. Android injects finger swipes; iOS uses
SwiftTerm's native wheel encoder and also restores a compact grid. Evidence
includes rendered frames, transcript ranges and process/owner information.
Native Mosh frames restore tracking after encoding resets. The host-free
`MoshMouseFrameTests` and iOS terminal-surface regression cover full repaints,
resizes, encoding changes, disabled tracking and unchanged diffs using real
native frame bytes.
The runners remove their exact tmux sessions and devices. After both finish,
run `bash scripts/integration/prepare-codex-mouse-fixture.sh cleanup ROOT` to
remove the staged binary and synthetic homes. Physical suspension/eviction
and trackpad feel remain device checks.

### Android live terminal gestures and inline tmux history

`JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_SDK_ROOT=/path/to/android-sdk TESSERA_ANDROID_MOSH_OPENSSL_ROOT=/path/to/arm64-openssl bash scripts/integration/run-android-live-scroll-tests.sh qa/<run>/live`
builds the instrumented `feature-session` bundle, creates and deletes one owned
AVD, and runs a single live case against the VPS fixture. The default case is
`liveScrollingAcrossAllTransports` (S1/S6 gestures over ssh, ssh+tmux, mosh and
mosh+tmux), which also writes the frame-position evidence directory.
`TESSERA_LIVE_SCROLL_TEST_METHOD=<jUnitMethodName>` selects another case in
`TmuxRenderLedgerIsolationInstrumentedTest` instead; the runner still requires
`OK (1 test)`, so every selectable method must be exactly one JUnit case, and
the evidence tarball is collected for the touch gesture and continuation cases.
The real TUI case records its exact resource identities before creating them.
Its EXIT fallback validates the run marker and worker PID/start identities,
then removes those workers, sessions and directories if test cleanup failed.
Missing or mismatched identities fail the run without guessing another target.
Use `TESSERA_LIVE_SCROLL_TEST_METHOD=liveMoshTmuxContinuationAlternatesOwnersWithoutStalling`
to keep two real Mosh clients attached while alternating ownership four times.
Each take-back must finish an owner-bound framebuffer repaint within three
seconds, commit the expected remote geometry, and accept fresh typed output.
The case also checks metadata-only control-client flags, background pane output,
and revealed history staying still through natural output and authority replays.
It saves screenshots, claim timing, transcripts and controller diagnostics.
Set `TESSERA_CONTINUATION_HEIGHT_ONLY_PEERS=true` to retain the same width on
both clients while alternating different heights; the original exact geometry,
owned-frame, input and history assertions still apply.
Use `TESSERA_LIVE_SCROLL_TEST_METHOD=liveMoshTmuxShowRepairsOwnedDriftAndForegroundYieldsToPeer`
to verify that showing a Mosh+tmux session repairs a remote window that
drifted to a wider grid (the §6.9 show rule in
`docs/reviews/takeover-authority-review-2026-10-05.md`).
The case requires correction without a window switch, a fresh consumed Mosh
frame, preserved near-tail history through real output, a same-grid show that
sends no claim, and a bare foreground (no show) that leaves a live peer in
control.
To test delayed SSP, it stops the exact run-owned Mosh server PID and uses an
independent persistent SSH probe to verify the corrected grid and unchanged
authority stamp before continuing that server.
The pause lasts at least 250 ms after the SSH geometry fence, ends within the
two-second foreground frame budget, and is recorded in a timing CSV alongside
screenshots and diagnostics.
The frame producer is a separate interruptible process. Before seeding history,
the case requires the exact run prompt in both native and remote cursor lines,
with the shell owning the foreground PTY. It records the Mosh PID and start time
before pausing that process so failed runs retain an exact cleanup identity.
Use `TESSERA_LIVE_SCROLL_TEST_METHOD=liveProductionScreenRepairsVerticalWindowDrift`
with the `pixel_6` device profile to mount the actual compact `SshSessionScreen`,
including chrome and its physical viewport. The case calibrates the disposable
display to 56×48, leaves the remote window two rows shorter, and requires repair
without another viewport report or window switch. It then exercises actual
Home/resume and IME show/hide. Run once with `TESSERA_HEIGHT_RESIZE_KEYBOARD=false`
and once with `true`; the latter requires the smaller measured viewport, native
Mosh canvas and remote window/pane to agree before returning to 48 rows.
Hardware frame captures, geometry, diagnostics and exact cleanup identities
are collected in `height-production-ui`, including failed runs.
Use `TESSERA_LIVE_SCROLL_TEST_METHOD=liveSshTmuxWidthOnlyForegroundWaitsForNativeGrid`
for a mounted SSH+tmux terminal resuming during a width-only native resize.
The case checks that the shared geometry fence waits for both grid dimensions,
then verifies the settled remote grid, rendered rows and fresh typed output.
Use `TESSERA_LIVE_SCROLL_TEST_METHOD=liveMoshTmuxMouseOffTouchReachesFullScreenPane`
for S12 on Android: under tmux's default `mouse off` a mosh+tmux pane already
runs a full-screen, mouse-reporting capture program when Tessera attaches. The
test clears the mouse mode the fixture's client does receive (the state a
user's session showed) and checks it stays off. A finger swipe must reach the
program as SGR wheel reports and a tap as an SGR press and release, without
revealing tmux history or entering copy mode.
Use `TESSERA_LIVE_SCROLL_TEST_METHOD=liveMoshTmuxFrozenReaderFlicksToOldestRow`
for S13 on Android: a mosh+tmux pane prints 1 500 numbered rows and keeps a
heartbeat ticking, which freezes a history reader's page. After the first
finger drag the pane prints eight new lines; the reader must stay on its
rows, finger flings must still reach row 1 with every screen of rows (at
least 80% fixture rows) in order, the ledger must log the freeze and then
`side-channel-anchored-deepen surface=live dropped=8 expected=8 anchor=page`,
and flings back must return to the live tail with the heartbeat moving and
the pane out of copy mode. Every session of the fixture's tmux group, the
app's view session included, must keep `mouse off`.
Use `TESSERA_LIVE_SCROLL_TEST_METHOD=liveInlineTmuxHistoryDeepensToScrollbackLimit`
for the SSH+tmux inline history ladder: it fills a run-scoped tmux pane with
6 000 numbered rows under a raised `history-limit`, proves the attach capture
stops at the 2 000-row first fill, then drives the production
`requestTmuxInlineHistory` gesture and requires the ledger's
`inlineHistorySettled` to report an exhausted ladder over the whole pane
history without duplicating rows across the rebind. That case restores the
fixture's previous global `history-limit` and kills its own session on exit.
`TESSERA_LIVE_SCROLL_TEST_METHOD=liveInlineTmuxFingerFlicksDeepenToOldestRow`
fills the same kind of pane but mounts the production
`InlineTmuxHistoryController` and never calls the request API: injected
finger flings alone must take the reader from the 2 000-row attach capture to
row 1 (every screen of numbered rows in order), leave the ladder exhausted
over the whole history without duplicating rows, and fling back to the live
tail with the pane out of copy mode.
The fixture credential file is shared, so run only one fixture-backed lane at
a time. See [`docs/tmux-inline-history-deepen.md`](../../docs/tmux-inline-history-deepen.md).

### iOS terminal painter performance

`bash scripts/integration/run-ios-scroll-performance-tests.sh qa/<fresh-run>/ios-scroll`
creates an owned landscape iPad, runs the cached/uncached native pixel oracle,
and records identical scripted viewport motion with the row cache disabled and
enabled. It saves repaint timing samples and deletes the simulator on exit.
Set `TESSERA_INTEGRATION_PREBUILT=1` to reuse an integration build. This host-free
CPU comparison supplements the live S1/S6 gesture gate; it does not establish
physical trackpad feel or 120 Hz device pacing. See
[`docs/ios-scroll-performance.md`](../../docs/ios-scroll-performance.md).

The `S3-live-scroll-momentum` visual case separately exercises first and second
real pointer flicks on all four transports with production physics enabled.
S1/S6 disables momentum to capture deterministic TUI positions, so it cannot
establish release behavior. S3 records continuous video, brackets each gesture,
and requires the first release to continue for at least 15 display ticks without
losing a pending history page. Each glide counts for the flick released before
it started, so pointer runs outside a split need one glide after each flick. Its fixture-output warmup lets the diagnostic
rate window expire before measurement. `TESSERA_FLICK_INPUT=touch` and
`TESSERA_FLICK_INPUT=diagonal` select direct-touch variants; both gestures must
visibly move history. The XCUITest holds at every milestone until the lane
acknowledges its capture, so the second flick cannot start inside the "first
settled" frames. The tmux cases enable mouse on the active view after
readiness and assert no primary gesture enters remote copy mode. Include all
variants in the same aggregate review.

The `S12-mouse-off-touch` visual case reruns the S1/S6 sequence on mosh+tmux
and SSH+tmux with tmux's default `mouse off` and the software keyboard up. On
mosh+tmux a DEBUG harness switch keeps every mouse mode off the mosh surface
(some hosts' visible tmux client shows none while the pane asked for the
mouse; the fixture's does), so taps and drags reach the programs through the
tmux pane state alone, and the lane fails unless the attempt's diagnostics
show that mode off throughout (`client-mouse-modes.txt`). Only lines logged
from the attempt's launch on count: the app's log keeps the lines of a run's
earlier lanes, whose htop and Vim did turn the mouse on.
htop and Vim are driven by finger drags, then one tap each: the htop tap must
select the tapped process, and a Vim tap in the middle of the rows left visible
above the keyboard must move tmux's pane cursor to within three rows of that
point (the XCUITest logs it as `TESSERA_VISUAL_TAP`; `vim-tap.json`). The lane
ends htop itself after its last htop frame. Primary history still uses
the pointer there (S13 drives it with fingers); see the case manifest.
`TESSERA_SCROLL_TOUCH_TRANSPORTS` narrows the run to one of those two
transports for diagnosis only.

The `S13-touch-primary-history` visual case scrolls primary-screen history
(a shell, or Claude Code's classic UI) with fingers only, on all four
transports, with production momentum and tmux's default `mouse off`. The lane
uploads `remote/primary-history-scenario.py` to both fixture hosts for the run
and removes it on exit: it prints 1 500 numbered rows (more than the first
mosh+tmux history page) and then keeps redrawing a heartbeat on the cursor's
line every half second, like Claude Code's status line. That output freezes
a mosh+tmux history reader, which must still reach deeper pages: the render
ledger finds the frozen page's history rows in the deeper capture (the growth
of tmux's `history_size` picks between verbatim repeats; the page's newest 64
rows stand in, if found exactly once, when its oldest have left the capture)
and drops whatever is newer, logging `side-channel-anchored-deepen ...
dropped=N expected=N anchor=page`. While the reader holds its first reveal
the pane also prints `TESSERA_SCROLL_STREAM_BURST_LINES` new lines (default 8)
in synchronized frames, as Claude Code does when it finishes messages.
`TESSERA_SCROLL_EXPOSE_ROWS=1` makes the DEBUG harness publish the fixture
rows on screen (their range, count and whether they run in order), whether
the view is at the top of its history and at the live tail, the latest
heartbeat, the rows on screen and the terminal's line count as the
terminal's accessibility value, because the Metal surface is
black to XCUITest; a revealed split overlay is read instead of the grid under
it. The test must reveal history with a slow drag, stay on those rows while
the lane holds the milestone, flick to row 00001 (plain mosh keeps only the
frames it painted, so there the top of its loaded history is enough), flick
back to the tail with the heartbeat advancing, reveal again, and return.
`primary-motion.json` grades `touch-rows.log` together with the changed-band
fractions between milestone frames (`frame-motion.txt`), the share of each
milestone frame's bands holding text (`frame-text.txt`, so black or blank
frames fail), and a second frame 1.5 s after each live-tail milestone, in
which only the heartbeat may change. Every readout's screen must be at least
80% fixture rows (below the fixture's last row, only the ready, burst and
heartbeat lines; above its first row, only the prompt and the scenario's
command, which a plain shell echoes twice; the readout's `cols` counts the
lines of a row or command that wraps, as in iPhone portrait), contiguous
outside plain mosh, and both returns must show
the fixture's last row. The reader must hold its rows through the burst; on
SSH and SSH+tmux only after the burst's lines reached the terminal (its line
count grew). Plain mosh relays only screens, without synchronized frames, and
its terminal follows scrolling output to the tail as it does under a
trackpad, so there the held rows are only recorded. tmux panes must hold the
fixture rows (`pane-history.txt`) and stay out of copy mode; on mosh+tmux the
app's verbose diagnostics must show output freezing the page, then an
anchored deepen with `dropped` and `expected` equal to the burst and
`anchor=page`, and no lost or ambiguous anchor. The tail frame is not
compared with the starting one: a scroll back rests at the scroll view's end,
up to a row below the terminal's own live placement until output scrolls.
S13 itself must run all four transports: with a narrower
`TESSERA_SCROLL_TOUCH_TRANSPORTS` it records its evidence, marks the case
incomplete and fails. Variants set `TESSERA_SCROLL_CASE_ID` (their title then
names their transports) together with
`TESSERA_SCROLL_TMUX_MOUSE=on`, `TESSERA_SCROLL_KEEP_KEYBOARD=1` (software
keyboard over the rows), `TESSERA_SCROLL_SPLIT=1` (an iPad split with the
fixture in the left, active pane: on mosh+tmux it reads history in its
overlay, on SSH+tmux in its own grid terminal; the drags aim at it, and
`TESSERA_SCROLL_AIM_X` makes the harness expose the terminal under them),
`TESSERA_SCROLL_TMUX_HISTORY_LIMIT` with a larger
`TESSERA_SCROLL_FIXTURE_ROWS` (deep tmux history in a run-scoped session
option; the fixture's global option is untouched), or an iPhone
`TESSERA_INTEGRATION_SIMULATOR_DEVICE_TYPE` with `TESSERA_SCROLL_PORTRAIT=1`.
Portrait defaults `TESSERA_SCROLL_TMUX_HISTORY_LIMIT` to 10 000: at a phone's
width tmux reflows each fixture row onto two lines, past its default
2 000-line limit, and trims the oldest at the next scroll, so SSH+tmux fingers
must also deepen past the attach capture there. A tmux pane already over its
limit when the reader starts fails the attempt.
The deep variant is its own visual case, `s13-touch-deep-history.sh`
(`S13-touch-primary-history-deep`): 6 000 rows under a 10 000-row
`history-limit` on SSH+tmux and mosh+tmux, so finger flicks must take SSH+tmux
past its 2 000-row attach capture and mosh+tmux past its 512-row first page.
S13's 1 500 rows fit inside both first captures and never ask for more. When
an SSH+tmux pane holds more history than the attach capture, the grader also
requires an `inline-history-request` and an `inline-history-settled ...
requested=true` whose depth covers the fixture.
Other cases can replace the remote fixture program by overriding the
library's `scroll_scenario_command`. Scroll-case screenshots are rotated only
when the simulator returns a portrait-shaped image of a landscape run.

### Focused setup-flow native lane

`bash scripts/integration/run-setup-flow-harness-tests.sh qa/<fresh-run>/native`
exercises shared Nearby/QR verification, zero-grant versus copied-host consent,
review/receipt/recovery, accessibility text, and QR keyboard/offer screens on
owned landscape iPad and portrait/landscape iPhone simulators. It records both
screens and exports full-display attachments, then deletes every owned device
even on failure. This lane is host-free; it does not prove SSH key installation.

For an XcodeBuildMCP-prepared build, set `TESSERA_INTEGRATION_TEST_PRODUCTS` to
its exact `.xctestproducts` path and pass `--without-building`. The same optional
product reuse is supported by the sync-unit, continuity-harness and
app-transport runners. Include native captures with the run's other evidence
in its **single aggregate visual review**, not a separate review per screen.

For a late terminal measurement on SSH+tmux, select
`TesseraTests/RealHostTransportIntegrationTests/test_liveSSHtmuxLateMeasuredViewportReclaimCompletes`
with `run-app-transport-tests.sh`. Two programmatic SSH clients share an owned
fixture window. The first attaches without a viewport, takes back control, then
receives the actual grid from a mounted landscape terminal. The original claim
must finish within three seconds, paint an owner-bound frame, agree with the
remote window and pane, yield the peer, and deliver fresh input. Readiness
failures before attachment are infrastructure failures, separate from the
claim regression. The runner deletes its owned simulator and fixture sessions.

The host-free
`TesseraTests/RealHostTransportIntegrationTests/test_tmuxIsolationSnapshotErasesPriorGlyphsCoreGraphics`
compares repeated erase/repaint captures with fresh terminal views using the
same native grid and text. The fixture uses the app's opaque black-background
configuration; stale backing pixels must fail even when the terminal model is
correct.

### VPS fixture setup

Copy `fixture.env.example` to the gitignored `fixture.env` and set:

- a stable VPS address (tmux 3.4 fixture);
- a chaos/compatibility VPS address (tmux 3.6a fixture);
- the root SSH control key and port;
- the isolated app-facing SSH port/user values (the defaults are 2222 and
  `tessera`).

Both hosts are assumed disposable. Provisioning installs sshd, mosh, SFTP,
tmux, htop/vim, a loopback-only HTTP forwarding target, deterministic PTY/file
fixtures, and a restricted no-tmux user. Root port 22 remains the control plane;
Tessera tests use the isolated app endpoint.

```sh
./scripts/integration/provision-fixtures.sh
./scripts/integration/verify-fixtures.sh
```

Generated client keys, passwords, known-host databases, DerivedData, captures,
and reports stay under ignored `.state/` and `out/`. Simulator identifiers are
stored in the run output while active; every run-created simulator is shut down
and deleted by an exit trap after verification, including failed runs.

The `PERF1-session-queue` visual case adds a host-free native scheduler-pressure
oracle on landscape iPad and iPhone. Two sources exercise the production Apple
session engine/delivery and CoreGraphics terminal, both directly and through tmux
control parsing. It requires ordered complete delivery, actual renderer feeds,
output age below one second, and input-to-backend age below 250 ms. Set
`TESSERA_QUEUE_ROUNDS=3600` for a roughly one-minute flood per variant; the
default is 900 rounds. Continuous `simctl` video and content-free timing logs
join the single aggregate review. The synthetic workload is not a physical
device CPU profile.

`PERF2-hidden-terminal` exercises the production inactive-session drawing gate
on iPad and iPhone. It checks that opacity alone still permits rendering, hidden
output continues updating the emulator without inherited drawing, and reveal
matches a continuously visible reference pixel-for-pixel. It also checks real
`TerminalSurfaceBound` environment toggles, initial layout/readiness, and normal
non-verbose drawing. CoreGraphics window captures join the aggregate review;
native counters, not screenshots alone, prove invisible work was suppressed.

## Jump-host lane (opt-in)

`jump/` holds a second, independent fixture pair for jump-host (ProxyJump)
coverage: a public bastion droplet and a target droplet whose app-facing sshd
is nftables-restricted to accept **only** the bastion (control port 22 stays
open). The target also runs a loopback-only sshd (multi-hop) and a
loopback-only HTTP endpoint (forward-through-chain), and drops mosh's UDP
range by default (`tessera-jump-mosh allow|block|status` toggles it on the
target).

```sh
cp scripts/integration/jump/jump.env.example scripts/integration/jump/jump.env  # fill in droplets
./scripts/integration/jump/provision-jump-fixtures.sh   # provisions + verifies topology (12 checks)
./scripts/integration/jump/run-jump-transport-tests.sh  # live app-level jump tests
```

When `jump/jump.env` exists, `run-integration-tests.sh` picks the lane up
automatically as the `app_jump_host_transports` case; without it the case is
skipped. Distinct per-hop credentials are generated under `.state/jump/` so
credential reuse across hops fails loudly.

## Run

```sh
# Normal comprehensive run.
./scripts/integration/run-integration-tests.sh

# Re-provision both disposable hosts first.
./scripts/integration/run-integration-tests.sh --provision

# Deterministic/capture development when Codex evaluation is unavailable.
./scripts/integration/run-integration-tests.sh --no-ai-visual

# Add the credentialed local Codex + Claude Code lifecycle gate. This uses
# isolated tmux sockets, safe print-only tool approvals, and no shell-config
# mutation. Both CLIs must already be authenticated on this Mac.
TESSERA_RUN_REAL_AGENT_E2E=1 ./scripts/integration/run-integration-tests.sh

# Run only that provider gate (optionally set
# TESSERA_REAL_AGENT_PROVIDERS=codex or =claude while diagnosing one lane).
TESSERA_RUN_REAL_AGENT_E2E=1 ./scripts/integration/run-real-agent-e2e.sh

# Focus on guarded Codex sends at default, max, and ultra effort. The effort
# picker triggers real max/ultra effects; timestamped SGR captures prove the
# animation ran while the production composer guard admitted the send.
TESSERA_RUN_REAL_AGENT_E2E=1 TESSERA_REAL_AGENT_PROVIDERS=codex \
  TESSERA_REAL_CODEX_SEND_MATRIX_ONLY=1 ./scripts/integration/run-real-agent-e2e.sh
```

### Credential-free live prompt TUI

This optional lane uses installed Claude Code, Codex, and Kimi CLIs against
local mock model APIs in private tmux servers. It skips missing providers and
keeps screen captures, driver output, mock prompts, and lifecycle diagnostics
at the optional evidence path.

```sh
TESSERA_RUN_AGENT_PROMPT_TUI=1 ./scripts/integration/run-agent-prompt-tui-tests.sh \
  .build/agent-prompt-tui/manual-run
# One provider while diagnosing (comma-separated: claude, codex, kimi).
TESSERA_RUN_AGENT_PROMPT_TUI=1 TESSERA_AGENT_PROMPT_TUI_PROVIDERS=kimi \
  ./scripts/integration/run-agent-prompt-tui-tests.sh
```

```sh
# Separate explicit Mac-host authorization is required for these opt-in gates.
# Two pinned loopback SSH clients attach to one owned helper; only new,
# dedicated Codex/Claude sessions are prompted. No global SSH edits are made.
TESSERA_RUN_MAC_AGENT_LIVE=1 python3 scripts/integration/mac-live-ingestion-probe.py \
  --host SharedAssets/agent-host/tessera-agent-host-darwin-arm64

# Dedicated Pi/OpenCode requests, using only DEEPSEEK_API_KEY from this file.
# Do not source the file. Provider configuration and logs are run-private.
TESSERA_RUN_DEEPSEEK_PROBE=1 python3 scripts/performance/agent-center/deepseek_provider_smoke.py \
  --env-file /absolute/private/.env --pi /absolute/path/pi --opencode /absolute/path/opencode

# Host-free cleanup, credential-output and delivery-proof failure tests.
python3 scripts/integration/test-credentialed-probe-safety.py

# Host-free check that every EXIT trap under scripts/ fails closed under
# macOS /bin/bash 3.2, which enters the trap with $? = 0 after a `set -u`
# abort. Lanes end with script_completed=1 (see fail_closed_status in lib.sh).
# The programmatic lane runs it as script_exit_traps_fail_closed.
/bin/bash scripts/integration/run-fail-closed-script-tests.sh

# Host-free tests for the run-owned fixture cleanup every mosh lane ends
# with (lib.sh reap_run_fixture_sessions, end_run_processes): a fake /proc and
# fake tmux check that only this run's sessions, mosh-servers and helper
# processes are touched (never a neighbouring run token's, nor anything
# through a tmux server, nor a tmux server whose command line names the run),
# that a stopped server is continued before TERM and escalated to KILL, that
# a reused PID gets no further signal, that the remote halves refuse to run
# as the fixture user, and that a survivor or a failed tmux listing fails the
# cleanup. They also drive S1/S6's own retry and cleanup functions, and check
# that lanes mint run tokens with fixture_run_token and signal nothing by a
# command-line pattern. The programmatic lane runs it as
# fixture_run_ownership_reap.
/bin/bash scripts/integration/run-fixture-reap-tests.sh

# Include the Android native tmux render-isolation gate. The explicit opt-in
# permits a disposable Android emulator and a temporary fixture-account key;
# native Mosh is required because the proof covers all four transports.
TESSERA_RUN_ANDROID_NATIVE_SSH_GATE=1 \
TESSERA_ANDROID_AGENT_CENTER_MOSH=1 \
TESSERA_ANDROID_MOSH_OPENSSL_ROOT=/path/to/reviewed/arm64-openssl \
./scripts/integration/run-integration-tests.sh
```

The Android native tmux render-isolation case is part of the aggregate
programmatic results. It runs only with all three settings above, so an ordinary
fixture run cannot create an Android emulator or add a temporary fixture key.
Without that configuration it is recorded as `unverified` in
`programmatic/results.json`, the programmatic lane exits nonzero, and the
aggregate `report.json` is non-success. This distinguishes unavailable Android
coverage from a gate that was configured and failed; the case log carries the
exact missing requirement.

The normal execution order is an invariant:

1. Build the app and both test bundles once (`build-for-testing` into
   `.state/DerivedData`); every Xcode lane then runs `test-without-building`
   against that one product. Standalone lane scripts still build themselves
   into the same tree when `TESSERA_INTEGRATION_PREBUILT` is unset.
2. Create uniquely named, run-scoped test simulators for visual and deterministic lanes. Separating them prevents unrelated unit-test installs from terminating the app mid-capture.
3. Capture every visual case and finalize one evidence manifest.
4. Start exactly one ephemeral, read-only `codex exec` process with every image
   attached and the complete manifest in the same prompt.
5. Run deterministic host, app, migration, terminal-cell, SFTP, forwarding,
   tmux, and scroll checks while that one review runs in the background.
6. Join both lanes into `report.json`, then shut down and delete every run-scoped simulator from disk.

## Wall-clock budget

Creating and booting a simulator costs about a minute, and an XCUITest
interaction against an app that never goes idle costs a 60-second timeout,
so the deterministic lane is arranged to avoid both:

- At most two run-scoped simulators are booted at once. XCTest-hosted unit
  lanes (offline oracles, sync/security units, live transports, jump hosts)
  share one iPad; UI harness lanes (scroll wiring, compact navigation,
  continuity, system presentation) share a second, fresh iPad while their
  private phones are created and deleted inside each lane; the three
  Nearby-bootstrap scenarios share one origin/recipient pair and reinstall
  the app between scenarios. `TESSERA_KEEP_TEST_SIM_BOOTED=1` is how the
  runner asks a lane to leave the shared iPad for the next one; the
  runner's exit trap still deletes every recorded device.
- Simulator boots are bounded (`TESSERA_INTEGRATION_SIMULATOR_BOOT_TIMEOUT`,
  default 300 s); a device that never boots fails its lane instead of
  hanging the suite.
- UI harnesses that assert state rather than motion launch the app with
  `TESSERA_STATIC_RINGS=1`, the app-wide `ContinuousMotion` gate that holds
  every `repeatForever` animation (status-dot pulses, the launch-overlay
  halo, sidebar attention pulse, continuation breathing, swipe-pad rings)
  at its resting frame. Without it every tap and width toggle waits out
  XCUITest's "App animations complete notification not received" timeout;
  the compact-navigation lane alone spent 16 minutes that way. Count
  occurrences of that message across `programmatic/logs` and
  `visual/cases/*/xctest.log` when a run looks slow. The F12 context-menu
  capture keeps its two: UIKit's own menu interaction holds the app
  non-idle and that case grades the real interaction.

The evaluator has no write permission, uses a strict JSON schema, and must
return exactly one verdict per captured case. A missing, duplicate, or extra
case fails review validation.

## Automated boundaries

| Matrix area | Coverage | Automated assertion |
|---|---|---|
| C1, C2, HK1, KS1/KS5 | substantial | Live password and generated Ed25519 auth over SSH and mosh; TOFU fingerprint/type; accepted-key persistence; wrong-password classification; idempotent install and revoke. Biometric/Secure Enclave remain device-only. |
| C4, C5, W1, W3, W4 | substantial | Real SSH+tmux inline control and mosh+tmux side-channel control hydrate against tmux 3.4 and 3.6a; real window names/renames; two control clients on one server remain session-isolated; SSH and mosh env/startup prologues execute remotely. |
| C6 | fixture boundary | A restricted app user on each host has no tmux executable, providing the deterministic fallback endpoint. Banner presentation remains a UI/manual assertion. |
| R1 | visual + deterministic | A host-free production-controller capture proves that an impossible zero-row inline viewport preserves the established terminal and visibly recovers on retry. Package tests apply the same required-grid policy to inline shared, inline split-pane, and mosh+tmux side-channel captures while preserving optional alternate saved-primary semantics. |
| P2 | live + visual + deterministic | The native four-transport render-isolation test creates a fresh window, splits it horizontally and vertically, types into the new pane, switches away/back, zooms/unzooms and collapses the split on SSH+tmux and mosh+tmux. Plain SSH/mosh retain passthrough behavior. `p2-split-notification-batch.sh` captures production iPad pane surfaces after coalesced focus/layout notifications and after window return. Package regressions cover separate reads, cooperative ingestion, nested newer layouts, pane closure and window-details replies. |
| K1, K5 | transport boundary + host-free UIKit focus | SSH and mosh PTYs preserve an exact multi-KiB payload containing bracketed-paste, SGR mouse, alternate-screen, newline, and printable-byte sequences; the remote SHA-256 oracle verifies every byte. `run-hardware-keyboard-tests.sh RUN_DIR` additionally exercises background-terminal cleanup, mouse focus-only taps, three Home/activate cycles, local text ownership, live input-lock permission, and modifier bytes using real UIKit key presses. K1 aggregate visual captures cover iPad and iPhone landscape; physical cover sleep/attachment and OS eviction remain device-only. |
| S1 | live visual + wiring | One continuous recording per transport drives real primary scrollback on SSH, SSH+tmux, mosh, and mosh+tmux; external Metal-aware screenshots prove tail → older numbered history → tail. A deterministic precheck (`primary_motion_precheck` in each `transport.json`) requires the first primary gesture to change at least a quarter of the screen's horizontal bands (a row-aligned reveal only changes row numbers, so raw pixel counts are not used); a frozen reveal fails the capture before review, the attempt is retried once, and every attempt keeps its in-app diagnostics log under `visual/diagnostics/` (failed attempts keep their full artifact set under `visual/failed-attempts/`, outside the reviewed cases). The host-free surface remains a fast offset/wiring assertion. Physical trackpad feel remains manual. |
| S6 | live visual + touch wiring | The same four live sessions grade htop mouse-wheel scrolling in both directions. SSH, SSH+tmux, and mosh+tmux also grade Vim `mouse=a` wheel forwarding; plain-mosh Vim is diagnostic-only because the fixture cannot reliably advance real htop while it owns that PTY. A host-free iPhone harness separately synthesizes a direct finger swipe in alternate-screen + SGR mouse mode and requires a terminal wheel event, covering the touch recognizer path that indirect-pointer tests cannot exercise; on a primary screen it requires UIScrollView's own finger frames, through the glide and a pull past the oldest row, to reach the host hook that feeds the SSH+tmux history gate. `run-scroll-harness-tests.sh` requires the exact number of passing tests and no skips in each result bundle. A 3x3 evidence sheet per transport is evaluated in the one aggregate review. Plain-mosh Vim and physical feel remain manual. |
| S9 | correctness oracle | Real `RepaintAssembly` bytes feed a headless SwiftTerm with 36 deep colored row pairs at two widths; every retained short row must end in default background, not a BCE-colored tail. |
| F1, F7 | backend + visual | Tessera's real `FileBridge` lists hidden/extension-less fixtures and performs mkdir/upload/rename/download/exec/delete with byte equality; the Files-card capture checks visible geometry and content. Quick Look/share sheets remain manual. |
| F12 | visual/timing | A complete context-menu recording, event markers, frame contact sheet, stills, and per-frame signal statistics are evaluated in the aggregate visual review. |
| PF1 | substantial | Real HTTP traffic and byte counters are verified on SSH/SSH+tmux's primary client and mosh+tmux's long-lived SSH side channel. |
| MO4 | host oracle | Both hosts enforce a bounded post-test `mosh-server` process count. Real device lifecycle/roaming remains manual. |
| A1, A5, G3 | visual | A normalized landscape terminal-canvas capture checks full bleed, top chrome, fullscreen geometry, and stale-width seams. |
| S2-S6 continuity descriptors | programmatic UI, iPad + iPhone | A DEBUG-only, host-free descriptor injection runs the production receiver/editor flow on dedicated iPad and iPhone simulators. It checks SSH/mosh x tmux/plain routing, exact named-tmux preservation, compact/regular credential gates and cancel behavior. It never initiates a host connection. Real Apple Handoff discovery/transport and continuation streams remain physical-device coverage. |
| Tmux grid authority | package + programmatic UI | Runtime/controller tests preserve peer authority across delayed local echoes, require the latest-client geometry/repaint fence for reclaim, and keep one slow claim latched. App tests pin queued commands to their originating controller; a landscape harness verifies the full-terminal pause surface and one-tap reclaim admission when the portable authority event is stale. A real second tmux client and physical-device resize remain manual continuity coverage. |
| Compact navigation transition | programmatic UI | A DEBUG-only, host-free wrapper retains one real `ContentView` while changing its injected iPad size class. In-memory host and inert-session fixtures cover Hosts, host editing, live session, Keys, Known Hosts, Settings, and Agent Center across regular -> compact -> regular, plus compact-first startup; a session-task start oracle proves width changes do not remount the live session view, while intercepted connect calls ensure no fixture opens a socket or persists presentation state. |
| S1 nearby bootstrap | programmatic two-simulator | A run-scoped disposable iPad/iPhone pair exercises production Bonjour discovery, TCP framing, X25519/HKDF/SAS, encrypted manifest transfer, grant receipts, and acknowledgements. The lane requires matching six-digit SAS values and `installed=1` completion on both roles, then deletes only its two explicit simulator UDIDs. SwiftData, Keychain, Secure Enclave, biometrics, SSH, and physical Local Network permission UI remain separate coverage. |
| O1 | visual | All nine regular-iPad forced onboarding steps are captured together and reviewed for identity, clipping, footer layout, spotlights, and illustration integrity. Run `scripts/uitest/run-onboarding-layout-matrix.sh` for exhaustive iPhone/iPad screen-size × orientation coverage (welcome + nine steps). |
| AG1 | visual + deterministic, host-free V2 fixture | The DEBUG Agent Center v2 fixture uses only shared-domain snapshots—no SSH, provider process, remote mutation, lifecycle install, notification delivery, command-palette route, or background assertion. Its primary iPad capture matches the V2 mockup’s existing navigation, grouped thread list, selected structured thread, prompt controls, and New/Fork entry. XCUITest verifies every fixture list group and displayed block kind, Live/Activity/Changes, loading search, source-changed error, degraded no-proven-transcript terminal fallback, compact list → detail → back with `Open terminal to answer`, and dark/light, Dynamic Type, and action/list/composer keyboard-focus states. The same case retains screenshots only for the stated three-option and idle SwipePad fan variants. Production installer/artifact checks run separately as `agent_integration_scripts`; real Claude/Codex transitions remain the opt-in `TESSERA_RUN_REAL_AGENT_E2E=1` lane. Composer hardware keys (Return/⇧Return newline with focus kept, ⌘Return/⌃Return send, empty ⌘Return ignored, ⌘↩ hint under the send glyph) need real simulator HID because XCUITest `typeKey` never delivers Return: run `scripts/uitest/run-agent-composer-hardware-keys.sh [ipad\|iphone]` (AXe from XcodeBuildMCP; about four minutes, including the new simulator's keyboard settling). |
| AG4 | visual + deterministic, host-free iPad + iPhone (+ Android) | The DEBUG `prompt` scene renders the live prompt cards Core derives from real Claude Code, Codex and Kimi screens: question with a freeform row, text typed in the terminal, multi-select, review, text-only, Codex's deferred async questions and a permission. XCUITest asserts every option, control and text-field identifier and keeps the answer field inside the transcript and above the software keyboard on a disposable iPhone; answers are logged, never written to a terminal. With `TESSERA_RUN_ANDROID_NATIVE_SSH_GATE=1`, the case also runs `scripts/android/run-agent-prompt-gate.sh` on a disposable AVD at tablet and phone sizes, which asserts the exact answer each option, text and control sends. The real TUIs' keystroke grammar is the opt-in credential-free `TESSERA_RUN_AGENT_PROMPT_TUI=1` lane. Physical-device answering remains manual. |
| MG1 | partial, high value | A disposable on-disk SwiftData store containing all three models and the `[String]` field is closed, reopened through the migration plan, and value-checked. Archived previous-release stores and physical upgrades remain release gates. |
| System pickers and share sheets | hosted UIKit + programmatic UI, iPad + iPhone (Mac from Xcode) | `run-system-presentation-tests.sh` runs `SystemPresentationTests` in the app: key import, Agent Center attachments, diagnostics export, public-key, Markdown and Files sharing each reach the UIKit controller really presented, then replay the Mac's order (the picker leaves before it reports), anchor rebuilds, deferred presentations, requests cleared or replaced while their controller is up, share sheets reopened at once (the Mac cancels one opened while the last share session is closing), and the QR metadata guard. The picker UI tests choose a seeded key in Files. UI tests cannot run on the Mac, and a build launched from the shell stalls behind macOS's "damaged" dialog, so the Mac pass runs the same class from Xcode on My Mac (Designed for iPad); Save to Files itself remains manual there. |

The ordinary ~660 unit/package tests remain the fast per-change lane. This
suite runs only the new matrix-derived offline oracles plus the opt-in live and
visual boundaries, avoiding a duplicate full unit pass.

## Artifacts

Each run is written to `scripts/integration/out/<UTC-run-id>/`:

- `visual/aggregate-manifest.json` and `image-list.txt` — the one AI bundle;
- `visual/codex-events.jsonl` and `codex-review.json` — evaluator trace/result;
- `visual/cases/` — stills, recordings, contact sheets, event logs, and metrics;
- `programmatic/results.json` and `programmatic/logs/` — one record per check;
- `programmatic/*.xcresult` — focused Xcode result bundles;
- `report.json` — aggregate verdict and both lane statuses.

## Intentionally manual

Physical trackpad latency/feel, deep mosh-overlay paging continuity, plain-mosh
Vim `mouse=a`, network roaming,
background/lock survival, Secure Enclave and real Face ID, hardware-keyboard
chords intercepted by Simulator, dictation, Stage Manager, cross-app drag/share,
pointer-triggered context menus, and real previous-release/device upgrades stay
in the manual matrix. Simulator coverage is not reported as proof of those
device-only properties.

### Tmux window ordering

The aggregate programmatic runner includes the VPS `tmux_window_ordering` probe
on tmux 3.4 and 3.6a at both base indexes, plus `tmux_window_ordering_legacy`
which builds upstream 3.1c on the disposable VPS and checks 64 source/destination/selection combinations. The live app transport suite verifies append, reorder,
external changes, selection, and pane preservation on both tmux transports.

The default visual aggregate includes `W2-tmux-window-ordering` (requires
`ffmpeg`, `ffprobe`, and Python Pillow for motion sheets); the Android
runtime session lane also includes ordering UI tests by default.
After `build-for-testing`, run the host-free gesture cases on owned disposable
devices (iPad defaults to landscape):

```sh
scripts/integration/run-tmux-window-ordering-ui-tests.sh /tmp/tmux-order-ipad
scripts/integration/run-tmux-window-ordering-ui-tests.sh /tmp/tmux-order-phone --phone
```

`TESSERA_INTEGRATION_DERIVED_DATA` selects an isolated prebuilt product. Each run
exports screenshots, video, an xcresult, and a JSON pass/skip summary, then
removes its exact simulator. Use a fresh output directory for each invocation.

The focused Android JNI/live gate reuses the configured disposable VPS fixtures
without installing Agent Center helpers or changing shell configuration:

```sh
TESSERA_ANDROID_NATIVE_ORDERING_ONLY=1 \
TESSERA_ANDROID_AGENT_CENTER_MOSH=1 \
TESSERA_ANDROID_MOSH_OPENSSL_ROOT=/absolute/path/to/reviewed/arm64/openssl \
JAVA_HOME=/absolute/path/to/jdk21 \
scripts/android/run-native-ssh-gate.sh
```

It requires the Android toolchain/native Mosh setup documented in
`android/README.md`, verifies ordering on SSH+tmux and mosh+tmux plus the existing
four-transport isolation marker, and cleans its owned AVD and exact sessions.
For Android gesture coverage, run the session-focused runtime gate:

```sh
TESSERA_ANDROID_RUNTIME_FOCUS=session \
TESSERA_ANDROID_RUNTIME_TEST_FILTER=com.bambouville.tessera.feature.session.TmuxWindowOrderingUiInstrumentedTest \
TESSERA_ANDROID_RUNTIME_CAPTURE_DIR=/tmp/tmux-order-android-tablet \
JAVA_HOME=/absolute/path/to/jdk21 \
scripts/android/run-runtime-gate.sh
```

For the phone fixture, also set `TESSERA_ANDROID_RUNTIME_DEVICE=pixel_6` and
append `#compactSwitcherDragPreservesActiveAndExposesMenuAndAccessibilityMoves`
to the test filter. Use fresh capture directories; the runner owns and removes
its disposable AVD. Physical interaction checks remain in
`docs/manual-testing-matrix.md`.

### Tmux semantics model differential

`Packages/TmuxControl/Tests/Support/TmuxSemanticsModel` is a deterministic,
test-only model of the tmux server rules that grid authority depends on
(sizing, `latest`, control-mode guards and notifications, targets, options,
per-version differences for 3.2, 3.3a, 3.4 and 3.6a). Its scenario scripts in
`Packages/TmuxControl/Tests/TmuxSemanticsModelTests/Scenarios/` (grammar in
`Scenario.swift`) are self-tests and also the input of a differential lane
that replays them on real tmux:

```sh
# Host-free: validate the scripts, build and check the payload, run the runner
# against a stub tmux (tmux-model-stub-tmux.py), run the model self-test,
# export nominal transcripts, and prove the replay/diff comparator on
# synthetic runner output.
scripts/integration/run-tmux-model-differential.sh --dry-run

# Live, on the configured disposable fixtures only (default: both hosts).
scripts/integration/run-tmux-model-differential.sh --host stable d2-side-channel-snapback
TESSERA_TMUX_MODEL_BUILD_VERSIONS="3.2 3.3a 3.4 3.6a" \
  scripts/integration/run-tmux-model-differential.sh
```

The fixture side (`remote/tmux-model-runner.py`, piped to
`python3 - --disposable-fixture`) gives every scenario its own server on an
exact socket in a private `mkdtemp` directory with `-f /dev/null`, attaches
real control clients (pipes) and terminal clients (pseudo-terminals), records
each control client's lines per step with the step's start and read times,
then kills its clients and server, removes the directory and records whether
cleanup was verified. `--build` downloads and builds upstream release tarballs
in a private directory that is removed afterwards; it needs a compiler, make,
pkg-config, yacc and the libevent/ncurses headers and installs nothing. The
lane then replays the recorded timeline on the model at the server's version
(`ScenarioFileTests.testReplayRecordedRuns`) and diffs each control client's
stream after dropping `%output`, stripping guard times and numbers and mapping
real client names to scenario labels. A line that only crossed a step
boundary is a note (raise `TESSERA_TMUX_MODEL_SETTLE`); any stream difference
fails the lane. Output lands in `out/tmux-model-differential/<run>/`
(`plan.json`, `payload.py`, `real-*.json`, `model-*.json`, `diff-*.txt`).
