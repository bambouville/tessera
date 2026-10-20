package com.bambouville.tessera.feature.session

import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.core.bridge.SharedTmuxCommands
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxGridPresentation
import com.bambouville.tessera.data.HostDraft
import com.bambouville.tessera.data.HostRepository
import com.bambouville.tessera.data.HostTrustEvaluation
import com.bambouville.tessera.data.IdentityRepository
import com.bambouville.tessera.data.KnownHostsRepository
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.SavedIdentity
import com.bambouville.tessera.data.SavedKnownHost
import com.bambouville.tessera.data.SessionRestoreRecord
import com.bambouville.tessera.data.SessionRestoreRepository
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import com.bambouville.tessera.networking.mosh.JniMoshNativeClientFactory
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import java.util.Properties
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Live observation rig for tmux grid authority on **mosh+tmux** with a plain
 * `tmux attach` peer, the exact situation reported from the phone: a PC
 * terminal is attached to the session, a stale stamp from a departed device
 * sits in `@tessera_authority`, and the phone connects over mosh.
 *
 * This is mostly an observation harness rather than a strict oracle: it
 * drives the production controller through attach, a show (delivered by the
 * LiveSessionStore show pipeline), take-back, a peer keystroke, the peer's
 * departure and a window switch each way, and reports what the authority
 * state machine did at each step (logcat tag [TAG])
 * together with the device diagnostics log. The summary line
 * `TESSERA_AUTHORITY_RIG` carries the verdicts a runner script greps;
 * [assertAuthorityInvariants] turns the few verdicts that are the §6.9 show
 * rule itself into failures.
 */
@RunWith(AndroidJUnit4::class)
class MoshTmuxAuthorityLiveInstrumentedTest {
    @Test
    fun liveMoshTmuxAuthorityWithPlainPeer(): Unit = runBlocking {
        // A plain connectedDebugAndroidTest run has neither; the runner
        // script pushes the fixture file and builds with native Mosh.
        assumeTrue("rig requires a native-Mosh Android build", JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        assumeTrue("no rig fixture at $FIXTURE_PATH; the runner script pushes one", fixture != null)
        val target = fixture!!.authoritySession
        // Every remote command below splices the session name into a shell
        // string and an exact `pkill -xf` pattern.
        check(target.matches(Regex("[A-Za-z0-9_-]+"))) { "unsafe authority session: $target" }
        val verdicts = linkedMapOf<String, String>()
        var live: LiveController? = null
        try {
            prepareFixture(fixture, target)
            val identity = TmuxDeviceIdentity("android-rig-${UUID.randomUUID()}", "Android-Rig")
            live = createLiveController(fixture, target, identity).also { it.connectAndAwait() }
            log("connected; observing attach-only authority for ${INITIAL_OBSERVE_MS}ms")

            // Phase A: attach alone only reads authority and follows the
            // stamp (§6.9 R5); with a stale foreign stamp and a sized PC
            // client attached it must never claim.
            val initial = live.observe("A-attach", INITIAL_OBSERVE_MS)
            verdicts["A_attach_authority"] = initial.describeAuthority()
            verdicts["A_attach_layout"] = initial.layout
            verdicts["A_attach_claims"] = live.claimsSince(0).toString()
            verdicts["A_attach_server"] = remoteAuthorityState(fixture, target)

            // Phase A': the tab becomes displayed. The show's own read
            // decides, and anything but our stamp at our size claims (R2).
            // The edge comes from the production pipeline: the controller is
            // registered in the process's LiveSessionStore and the store
            // turns the composed Displayed report into the show.
            val showMark = live.diagnosticsMark()
            live.reportDisplayedThroughStore()
            verdicts["A_show_edge"] = live.showEdgeSince(showMark)
            verdicts["A_show"] = live.awaitShowDecision("A-show")
            verdicts["A_show_layout"] = live.sample().layout
            verdicts["A_show_server"] = remoteAuthorityState(fixture, target)

            // Phase B: if the phone still believes a peer holds the grid, take it back.
            if (live.authority() is SharedTmuxGridAuthoritySnapshot.Peer) {
                verdicts["B_takeback"] = live.takeBack("B", attempts = 3)
                verdicts["B_server"] = remoteAuthorityState(fixture, target)
            } else {
                verdicts["B_takeback"] = "not-needed"
            }

            // Phase C: the PC user types one key; tmux makes that client
            // `latest` and the window snaps to the PC's 160x48 grid.
            remote(fixture, "printf x > /tmp/$target.fifo")
            log("PC keystroke injected; observing")
            val afterKey = live.observe("C-peer-typed", PEER_OBSERVE_MS)
            verdicts["C_after_peer_key_authority"] = afterKey.describeAuthority()
            verdicts["C_after_peer_key_layout"] = afterKey.layout
            verdicts["C_server"] = remoteAuthorityState(fixture, target)

            // Phase D: take control back from the stamp-less peer.
            if (live.authority() is SharedTmuxGridAuthoritySnapshot.Peer) {
                verdicts["D_takeback"] = live.takeBack("D", attempts = 1)
                verdicts["D_phone_grid"] = "${PHONE_COLUMNS}x${PHONE_ROWS}"
                verdicts["D_server"] = remoteAuthorityState(fixture, target)
                verdicts["D_layout"] = live.sample().layout
            } else {
                verdicts["D_takeback"] = "no-veil-after-peer-key"
            }

            // Phase E: the PC user takes the grid again, then leaves. A
            // peer's departure moves nothing (§6.9 R5, S2′): no claim, no
            // stamp write, and the phone stays yielded until a show or a tap.
            remote(fixture, "printf y > /tmp/$target.fifo")
            log("PC keystroke injected again; observing")
            val retaken = live.observe("E-peer-typed", PEER_OBSERVE_MS)
            verdicts["E_before_leave_authority"] = retaken.describeAuthority()
            val departureMark = live.diagnosticsMark()
            // The whole command line, exactly: a substring would also match a
            // client of any session whose name merely starts with this one.
            remote(fixture, "pkill -u \"\$(id -u)\" -xf 'tmux attach -t $target' || true")
            log("PC client killed; observing")
            val afterLeave = live.observe("E-peer-left", PEER_OBSERVE_MS)
            verdicts["E_after_peer_left_authority"] = afterLeave.describeAuthority()
            verdicts["E_after_peer_left_layout"] = afterLeave.layout
            verdicts["E_after_peer_left_claims"] = live.claimsSince(departureMark).toString()
            verdicts["E_server"] = remoteAuthorityState(fixture, target)

            // Phase E': one tap takes control back; window selection stays
            // gated while yielded, so phase F needs it.
            if (live.authority() is SharedTmuxGridAuthoritySnapshot.Peer) {
                verdicts["E_takeback"] = live.takeBack("E", attempts = 3)
                verdicts["E_takeback_server"] = remoteAuthorityState(fixture, target)
            } else {
                verdicts["E_takeback"] = "not-needed"
            }

            // Phase F: tap-to-paint latency of a window switch. The fixture
            // adds a second window with distinct content; the phone selects
            // it, then returns. Each leg is timed from the selection call to
            // the owner-correlated full frame the diagnostics confirm.
            val created = remote(
                fixture,
                "id=\$(tmux new-window -d -P -F '#{window_id}' -t '$target') && " +
                    "tmux send-keys -t \"\$id\" 'echo window-two' Enter && echo \"\$id\"",
            ).trim()
            val otherId = created.removePrefix("@").toIntOrNull()
            if (otherId == null) {
                verdicts["F_switch"] = "window-create-failed(${created.take(64)})"
            } else {
                val firstId = live.controller.tmuxSnapshot.value?.activeWindowId
                val listed = withTimeoutOrNull(WINDOW_APPEAR_TIMEOUT_MS) {
                    while (live.controller.tmuxSnapshot.value?.windows?.none { it.id == otherId } != false) {
                        delay(POLL_MS)
                    }
                    true
                }
                verdicts["F_windows"] = "${live.controller.tmuxSnapshot.value?.windows?.size ?: 0}"
                if (listed != true) {
                    verdicts["F_switch"] = "window-@$otherId-never-listed"
                } else {
                    verdicts["F_switch"] = live.switchWindow("F-switch", otherId)
                    delay(SWITCH_SETTLE_MS)
                    verdicts["F_switch_back"] = firstId?.let { live.switchWindow("F-back", it) }
                        ?: "no-first-window"
                }
            }
        } finally {
            val summary = verdicts.entries.joinToString(" ") { "${it.key}=${it.value.replace(' ', '_')}" }
            log("TESSERA_AUTHORITY_RIG $summary")
            live?.dumpDiagnostics()
            runCatching { live?.close() }
                .onFailure { log("controller close failed: $it") }
            runCatching { live?.unregisterFromStore() }
                .onFailure { log("store unregister failed: $it") }
            runCatching { cleanupFixture(fixture, target) }
                .onFailure { log("fixture cleanup failed: $it") }
        }
        assertTrue("rig ran", verdicts.isNotEmpty())
        assertAuthorityInvariants(verdicts)
    }

    /**
     * D4 (review §4 S6): an Android SSH+tmux reattach whose authority reply
     * lands off screen. The restore window reconnects a tab nobody is looking
     * at, and the user leaves the app before its read returns, so the reply
     * that decides authority arrives with the tab neither displayed nor in
     * the foreground. It must not claim or size the window then, and it must
     * not latch either: once the tab is shown, the show claims the grid and
     * every ordinary resize after that (the IME rising and falling) reaches
     * the window. Before the fix the off-screen reply left SSH's ordinary
     * geometry withheld for the rest of the connection.
     *
     * The owner session carries a stale stamp from a departed device, the
     * harder case: a peer verdict keeps geometry withheld until a show.
     */
    @Test
    fun liveSshTmuxReattachOffScreenKeepsGeometryLive(): Unit = runBlocking {
        val fixture = readFixture()
        assumeTrue("no rig fixture at $FIXTURE_PATH; the runner script pushes one", fixture != null)
        // The runner reaps every session and process naming `<session>-*`.
        val target = "${fixture!!.authoritySession}-ssh"
        check(target.matches(Regex("[A-Za-z0-9_-]+"))) { "unsafe authority session: $target" }
        val verdicts = linkedMapOf<String, String>()
        val identity = TmuxDeviceIdentity("android-rig-ssh-${UUID.randomUUID()}", "Android-Rig-SSH")
        var live: LiveController? = null
        try {
            prepareSshFixture(fixture, target)
            val rig = createLiveController(fixture, target, identity, TransportKinds.SSH, presented = false)
            live = rig
            rig.connectAndAwait { controller -> controller.setAppForeground(false) }

            // Phase A: the reply lands off screen. Nothing claims, nothing
            // sizes the window, and the stale stamp is not ours.
            val resolved = rig.awaitAuthorityResolved(AUTHORITY_READ_TIMEOUT_MS)
            verdicts["A_reply"] = if (resolved) "resolved" else "unresolved"
            val offScreen = rig.observe("A-offscreen", OFFSCREEN_OBSERVE_MS)
            verdicts["A_authority"] = offScreen.describeAuthority()
            verdicts["A_claims"] = rig.claimsSince(0).toString()
            verdicts["A_window"] = remoteWindowSize(fixture, target)

            // Phase A': back in the foreground, still not displayed. The app
            // coming back is not a show (§6.9 "Avoid").
            rig.onMain { rig.controller.setAppForeground(true) }
            val foreground = rig.observe("A2-foreground", OFFSCREEN_OBSERVE_MS)
            verdicts["A2_authority"] = foreground.describeAuthority()
            verdicts["A2_claims"] = rig.claimsSince(0).toString()
            verdicts["A2_window"] = remoteWindowSize(fixture, target)

            // Phase B: the tab is displayed; the show's own read claims.
            val showMark = rig.diagnosticsMark()
            rig.onMain { rig.controller.setPresentationActive(true) }
            rig.reportDisplayedThroughStore()
            verdicts["B_show_edge"] = rig.showEdgeSince(showMark)
            verdicts["B_show"] = rig.awaitShowDecision("B-show")
            verdicts["B_window"] = awaitRemoteWindow(fixture, target, "${PHONE_COLUMNS}x$PHONE_ROWS")
            verdicts["B_stamp"] = remoteStamp(fixture, target)

            // Phase C: ordinary resizes after an off-screen reply reach the
            // window and never claim.
            val resizeMark = rig.diagnosticsMark()
            rig.resizeViewport(PHONE_COLUMNS, IME_ROWS)
            verdicts["C_ime_up"] = awaitRemoteWindow(fixture, target, "${PHONE_COLUMNS}x$IME_ROWS")
            rig.resizeViewport(PHONE_COLUMNS, PHONE_ROWS)
            verdicts["C_ime_down"] = awaitRemoteWindow(fixture, target, "${PHONE_COLUMNS}x$PHONE_ROWS")
            verdicts["C_claims"] = rig.claimsSince(resizeMark).toString()
            verdicts["C_authority"] = rig.sample().describeAuthority()
        } finally {
            val summary = verdicts.entries.joinToString(" ") { "${it.key}=${it.value.replace(' ', '_')}" }
            log("TESSERA_AUTHORITY_RIG_SSH_OFFSCREEN $summary")
            live?.dumpDiagnostics()
            runCatching { live?.close() }
                .onFailure { log("controller close failed: $it") }
            runCatching { live?.unregisterFromStore() }
                .onFailure { log("store unregister failed: $it") }
            runCatching { cleanupSshFixture(fixture, target) }
                .onFailure { log("fixture cleanup failed: $it") }
        }
        val summary = verdicts.entries.joinToString(" ") { "${it.key}=${it.value.replace(' ', '_')}" }
        // §6.9 R5: neither an off-screen attach nor the app's return claims or sizes.
        for (phase in listOf("A", "A2")) {
            assertTrue("$phase began claims. Full summary: $summary", verdicts["${phase}_claims"] == "0")
            assertFalse(
                "$phase took the grid without a show. Full summary: $summary",
                verdicts["${phase}_authority"]?.startsWith("mine") == true,
            )
            assertTrue(
                "$phase sized the window off screen. Full summary: $summary",
                verdicts["${phase}_window"] == FIXTURE_WINDOW,
            )
        }
        assertTrue("the store delivered no show edge. Full summary: $summary", verdicts["B_show_edge"] == "store-show")
        assertTrue("the show never settled. Full summary: $summary", verdicts["B_show"]?.startsWith("settled-") == true)
        assertTrue("the show left the window off the phone's grid. Full summary: $summary",
            verdicts["B_window"]?.startsWith("reached-") == true)
        assertTrue("the show did not stamp this device. Full summary: $summary",
            verdicts["B_stamp"]?.startsWith("v1 ${identity.id} ") == true)
        // D4 itself: the off-screen reply must not freeze ordinary geometry.
        assertTrue("an IME rise never reached the window (D4). Full summary: $summary",
            verdicts["C_ime_up"]?.startsWith("reached-") == true)
        assertTrue("an IME fall never reached the window (D4). Full summary: $summary",
            verdicts["C_ime_down"]?.startsWith("reached-") == true)
        assertTrue("an ordinary resize claimed. Full summary: $summary", verdicts["C_claims"] == "0")
        assertTrue("ordinary resizes lost the grid. Full summary: $summary",
            verdicts["C_authority"]?.startsWith("mine") == true)
    }

    /**
     * The rig stays an observation harness for latency and layout, but a few
     * verdicts are not observations — they are the feature working or not, and
     * leaving them unasserted meant a take-back that never settled still
     * exited 0.
     *
     * These are deliberately stated over *behaviour* rather than over any
     * implementation: a take-back that was offered must complete. That keeps
     * them valid across the repaint-reservation refactor, which moves the
     * re-reservation rule out of this module and into the shared render
     * ledger. On Mosh the take-back's own geometry force re-lays the window
     * out and rebinds the render surface at a new epoch; if the frame the
     * claim is waiting on is retired there instead of re-reserved, every
     * attempt aborts and phase B/D report `never-settled-...`. That was a real
     * defect on both platforms (Android fixed it in 863c2047; iOS shipped it
     * until 2026-09-11), and it is exactly what these assertions catch.
     *
     * Latency, layout strings and the window-switch paint path stay
     * observations: they are genuinely environment-sensitive.
     */
    private fun assertAuthorityInvariants(verdicts: Map<String, String>) {
        val summary = verdicts.entries.joinToString(" ") { "${it.key}=${it.value.replace(' ', '_')}" }

        for (phase in listOf("A_show", "B_takeback", "D_takeback", "E_takeback")) {
            val verdict = verdicts[phase] ?: continue
            assertFalse(
                "$phase: a show or take-back that was offered never completed — the claim is " +
                    "aborting itself, most likely because its own geometry force rebound " +
                    "the render surface and retired the frame it was waiting on. " +
                    "Full rig summary: $summary",
                verdict.startsWith("never-settled"),
            )
        }

        // A take-back from a peer that is not tmux's `latest` client (B: a
        // stale stamp; E: a peer that has left) has nothing to contend with,
        // so one tap settles it. D's plain PC is idle after its keystroke:
        // the side-channel fence must win its old latest on the first tap.
        for (phase in listOf("B_takeback", "D_takeback", "E_takeback")) {
            val verdict = verdicts[phase] ?: continue
            if (verdict == "not-needed") continue
            assertTrue(
                "$phase: a take-back with the peer idle or departed needed a retry or never " +
                    "settled ($verdict). Full rig summary: $summary",
                verdict.startsWith("settled-on-attempt-1-"),
            )
        }

        val phoneGrid = verdicts["D_phone_grid"]
        assertTrue("D must settle at the phone's grid. Full rig summary: $summary",
            phoneGrid != null && verdicts["D_layout"]?.endsWith(":$phoneGrid") == true &&
                verdicts["D_server"]?.split(';')?.contains("window=$phoneGrid") == true)

        // The show came through the store's tracker, not a direct call.
        verdicts["A_show_edge"]?.let { edge ->
            assertTrue("the store delivered no show edge ($edge). Full rig summary: $summary", edge == "store-show")
        }

        // §6.9 R5: attach alone never claims, even over a stale stamp.
        verdicts["A_attach_claims"]?.let { claims ->
            assertTrue("attach alone began $claims claim(s). Full rig summary: $summary", claims == "0")
        }
        verdicts["A_attach_authority"]?.let { authority ->
            assertFalse("attach alone took the grid ($authority). Full rig summary: $summary", authority.startsWith("mine"))
        }
        // §6.9 R5/S2′: a peer's departure sends nothing and leaves a yielded
        // phone yielded; only a show or a tap moves control.
        verdicts["E_after_peer_left_claims"]?.let { claims ->
            assertTrue("the peer's departure began $claims claim(s). Full rig summary: $summary", claims == "0")
        }
        if (verdicts["E_before_leave_authority"]?.startsWith("peer") == true) {
            assertTrue(
                "the phone reclaimed when the peer left " +
                    "(E_after_peer_left_authority=${verdicts["E_after_peer_left_authority"]}). " +
                    "Full rig summary: $summary",
                verdicts["E_after_peer_left_authority"]?.startsWith("peer") == true,
            )
        }

        // A rig that exercises no take-back proves nothing about take-back, so
        // a regression in *peer detection* must not quietly turn this into a
        // no-op that still passes. Phase C makes the plain 160x48 peer type,
        // which takes tmux's `latest` and snaps the window to its grid, so a
        // veil is the designed outcome.
        //
        // Gate this on the server still reporting that peer attached:
        // `prepareFixture` hard-fails if it never attached, but it can die
        // mid-run, and that is infrastructure, not a regression. Only demand
        // detection when the peer is demonstrably there to be detected.
        val peerStillAttached = verdicts["C_server"]?.contains("160x48") == true
        if (peerStillAttached) {
            assertTrue(
                "the plain peer held the grid at 160x48 but the phone never veiled, " +
                    "so stamp-less peer detection regressed " +
                    "(C_after_peer_key_authority=${verdicts["C_after_peer_key_authority"]}). " +
                    "Full rig summary: $summary",
                verdicts["D_takeback"] != "no-veil-after-peer-key",
            )
            assertTrue(
                "no take-back completed in either phase, so nothing about take-back " +
                    "was actually proven. Full rig summary: $summary",
                listOf("B_takeback", "D_takeback")
                    .mapNotNull { verdicts[it] }
                    .any { it.startsWith("settled-on-attempt-") },
            )
        }
    }

    // ---- fixture orchestration -------------------------------------------------

    private suspend fun prepareFixture(fixture: Fixture, target: String) {
        // A stale stamp from a device that is no longer attached, plus one
        // plain 160x48 client fed from a FIFO so the rig can make it type.
        // `tmux -vv` writes the server log next to $HOME for the runner to pull.
        // The first two lines are tolerant resets and must not short-circuit
        // the chain when there is nothing to reset.
        val view = SharedTmuxCommands.moshViewSessionName(target)
        val script = "tmux kill-session -t '=$view' 2>/dev/null; tmux kill-session -t '=$target' 2>/dev/null; " +
            "rm -f /tmp/$target.fifo /tmp/$target.script.log; " + listOf(
            "cd \"\$HOME\" && tmux -vv new-session -d -s '$target' -x 100 -y 30",
            // The app's shared bootstrap derives this private grouped view.
            // Authority resolves to the owner; the view keeps a compatibility mirror.
            "tmux new-session -d -s '$view' -t '$target'",
            "tmux set-option -t '$target' @tessera_authority 'v1 stale-ipad 7 iPad'",
            "tmux set-option -t '$target' window-size latest",
            "mkfifo /tmp/$target.fifo",
            // The keeper's argv names the session, so cleanup can end exactly
            // this run's keeper and no other `sleep` on the shared account.
            "(nohup bash -c 'exec -a \"\$0\" sleep 3600 > /tmp/$target.fifo' '$target-fifo-keeper' </dev/null >/dev/null 2>&1 &)",
            "(nohup setsid env TERM=xterm-256color script -qfc 'stty cols 160 rows 48; exec tmux attach -t $target' /dev/null </tmp/$target.fifo >/tmp/$target.script.log 2>&1 &)",
            "sleep 2",
            "tmux list-clients -t '$target' -F '#{client_name}|#{client_width}x#{client_height}|#{client_flags}'",
        ).joinToString(" && ")
        val output = remote(fixture, script)
        log("fixture prepared; clients: ${output.trim()}")
        check(output.contains("160x48")) { "PC client did not attach at 160x48: $output" }
    }

    private suspend fun cleanupFixture(fixture: Fixture, target: String) {
        val view = SharedTmuxCommands.moshViewSessionName(target)
        // Killing the session detaches the plain client, which ends its
        // `script`. Only this run's FIFO keeper goes besides: its whole
        // command line is `<target>-fifo-keeper 3600` (an exact match, never
        // another lane's `sleep`); run-mosh-authority-rig.sh then reaps
        // anything left that names the session.
        remote(
            fixture,
            "tmux kill-session -t '=$view' 2>/dev/null; tmux kill-session -t '=$target' 2>/dev/null; " +
                "pkill -u \"\$(id -u)\" -xf '$target-fifo-keeper 3600' >/dev/null 2>&1; " +
                "rm -f /tmp/$target.fifo /tmp/$target.script.log; true",
        )
    }

    /** The owner session alone: SSH+tmux attaches it directly, with no view session. */
    private suspend fun prepareSshFixture(fixture: Fixture, target: String) {
        val output = remote(
            fixture,
            "tmux kill-session -t '=$target' 2>/dev/null; " + listOf(
                "cd \"\$HOME\" && tmux new-session -d -s '$target' -x 100 -y 30",
                "tmux set-option -t '=$target:' window-size latest",
                "tmux set-option -t '=$target:' @tessera_authority 'v1 stale-ipad 7 iPad'",
                "tmux display-message -p -t '=$target:' '#{window_width}x#{window_height}'",
            ).joinToString(" && "),
        )
        log("ssh fixture prepared; window ${output.trim()}")
        check(output.trim() == FIXTURE_WINDOW) { "fixture window is not $FIXTURE_WINDOW: $output" }
    }

    private suspend fun cleanupSshFixture(fixture: Fixture, target: String) {
        remote(fixture, "tmux kill-session -t '=$target' 2>/dev/null; true")
    }

    private suspend fun remoteWindowSize(fixture: Fixture, target: String): String =
        remote(fixture, "tmux display-message -p -t '=$target:' '#{window_width}x#{window_height}'").trim()

    /** The owner session's stamp; a bare `=session` target would resolve a pane. */
    private suspend fun remoteStamp(fixture: Fixture, target: String): String =
        remote(fixture, "tmux show-options -qv -t '=$target:' @tessera_authority").trim()

    /** `reached-in-<ms>` once the window is [expected], else where it stuck. */
    private suspend fun awaitRemoteWindow(fixture: Fixture, target: String, expected: String): String {
        val started = System.currentTimeMillis()
        var last = ""
        while (System.currentTimeMillis() - started < REMOTE_WINDOW_TIMEOUT_MS) {
            last = remoteWindowSize(fixture, target)
            if (last == expected) return "reached-in-${System.currentTimeMillis() - started}ms"
            delay(POLL_MS)
        }
        log("window never reached $expected; stuck at $last")
        return "stuck-at-$last"
    }

    private suspend fun remoteAuthorityState(fixture: Fixture, target: String): String {
        val view = SharedTmuxCommands.moshViewSessionName(target)
        val output = remote(
            fixture,
            "tmux show-options -qv -t '$target' @tessera_authority; " +
                "tmux display-message -p -t '$view' 'window=#{window_width}x#{window_height}'; " +
                "tmux list-clients -t '$target' -F 'client=#{client_name}:#{client_width}x#{client_height}:#{client_flags}'",
        )
        return output.lineSequence().filter(String::isNotBlank).joinToString(";")
    }

    // ---- controller harness ----------------------------------------------------

    private data class Sample(
        val authority: SharedTmuxGridAuthoritySnapshot,
        val reclaimInFlight: Boolean,
        val layout: String,
    ) {
        fun describeAuthority(): String = when (val a = authority) {
            SharedTmuxGridAuthoritySnapshot.Unknown -> "unknown"
            is SharedTmuxGridAuthoritySnapshot.Mine -> "mine(gen=${a.generation})"
            is SharedTmuxGridAuthoritySnapshot.Peer -> "peer(${a.deviceId},${a.displayName},gen=${a.generation})"
        } + if (reclaimInFlight) "+reclaiming" else ""
    }

    private inner class LiveController(
        val controller: SshSessionController,
        private val hostId: String,
        val surface: TermuxTerminalSurface,
        private val diagnostics: DiagnosticLogStore,
        private val scope: CoroutineScope,
        private val authentication: Job,
        private val transportKind: String,
    ) {
        private val diagnosticsPrefix = diagnostics.read().length
        private var lastDeclared: Pair<Int?, Int?>? = null

        /** [afterConnect] runs on main right after `connect()`, before any reply can land. */
        suspend fun connectAndAwait(afterConnect: (SshSessionController) -> Unit = {}) {
            onMain {
                controller.connect()
                afterConnect(controller)
            }
            val connected = withTimeoutOrNull(CONNECT_TIMEOUT_MS) {
                while (true) {
                    when (val state = controller.state.value) {
                        SshSessionUiState.Connected -> return@withTimeoutOrNull true
                        is SshSessionUiState.Failed -> error("controller failed: $state")
                        else -> Unit
                    }
                    delay(POLL_MS)
                }
                @Suppress("UNREACHABLE_CODE")
                false
            }
            check(connected == true) { "controller did not connect within ${CONNECT_TIMEOUT_MS}ms" }
            onMain { republishSurfaceDeclarations() }
        }

        fun authority(): SharedTmuxGridAuthoritySnapshot = controller.tmuxAuthority.value

        /** True once an authority read resolved the projection away from unknown. */
        suspend fun awaitAuthorityResolved(timeoutMs: Long): Boolean = withTimeoutOrNull(timeoutMs) {
            while (authority() == SharedTmuxGridAuthoritySnapshot.Unknown) delay(POLL_MS)
            true
        } == true

        /** What a settled viewport change (an IME edge, a rotation) reports. */
        suspend fun resizeViewport(columns: Int, rows: Int) {
            onMain {
                surface.resize(columns, rows)
                controller.updateTmuxViewport(columns, rows)
            }
            log("viewport ${columns}x$rows reported")
        }

        /** An offset into this controller's diagnostics for [claimsSince]. */
        fun diagnosticsMark(): Int = diagnostics.read().drop(diagnosticsPrefix).length

        /** Claims the reducer began after [mark] (its `beginClaim(` effects). */
        fun claimsSince(mark: Int): Int =
            Regex("""beginClaim\(""").findAll(diagnostics.read().drop(diagnosticsPrefix).drop(mark)).count()

        /**
         * What the screen does when this tab becomes displayed: its slot in
         * the process's [LiveSessionStore] holds this controller, and the
         * composition reports Displayed. The store's core show-edge tracker
         * settles that for 350 ms, then delivers `shown` with the core's step.
         */
        suspend fun reportDisplayedThroughStore() {
            onMain {
                val store = LiveSessionStore.get()
                store.controller(LiveSessionStore.ControllerKey(hostId, "authority-rig-$hostId", null, null)) { controller }
                store.reportComposedDisplay(
                    hostId,
                    displayed = true,
                    startEpoch = store.startEpoch.longValue,
                    explicitOpens = store.explicitOpenRequests[hostId] ?: 0L,
                )
            }
            log("[store] composed Displayed=true reported for $hostId")
        }

        /** `store-show` once the controller logged the show the store delivered after [mark]. */
        suspend fun showEdgeSince(mark: Int): String {
            val seen = withTimeoutOrNull(SHOW_EDGE_LOG_TIMEOUT_MS) {
                while (!diagnostics.read().drop(diagnosticsPrefix).drop(mark).contains("tmux_authority_show")) {
                    delay(POLL_MS)
                }
                true
            }
            return if (seen == true) "store-show" else "missing"
        }

        /** Forgets this rig's slot so a later case in this process starts clean. */
        suspend fun unregisterFromStore() {
            onMain { LiveSessionStore.get().close(hostId) }
        }

        /** Waits for a show's read to resolve or its claim to settle with the projection back at none. */
        suspend fun awaitShowDecision(label: String): String {
            val started = System.currentTimeMillis()
            val settled = withTimeoutOrNull(TAKE_BACK_TIMEOUT_MS) {
                while (authority() !is SharedTmuxGridAuthoritySnapshot.Mine ||
                    controller.tmuxReclaimInFlight.value ||
                    controller.tmuxAuthorityPresentation.value != TmuxAuthorityPresentation.None
                ) {
                    onMain { republishSurfaceDeclarations() }
                    delay(POLL_MS)
                }
                true
            }
            val elapsed = System.currentTimeMillis() - started
            val now = sample()
            log("[$label] settled=${settled == true} after ${elapsed}ms authority=${now.describeAuthority()} layout=${now.layout}")
            return if (settled == true) "settled-in-${elapsed}ms" else "never-settled(${now.describeAuthority()})"
        }

        fun sample(): Sample {
            val snapshot = controller.tmuxSnapshot.value
            val window = snapshot?.activeWindow
            val size = window?.layout?.let { "${it.width}x${it.height}" } ?: "none"
            return Sample(
                authority = controller.tmuxAuthority.value,
                reclaimInFlight = controller.tmuxReclaimInFlight.value,
                layout = "@${window?.id ?: "-"}:$size",
            )
        }

        /** Samples every [POLL_MS] for [durationMs], logging each change. Returns the last sample. */
        suspend fun observe(label: String, durationMs: Long): Sample {
            val started = System.currentTimeMillis()
            var previous: Sample? = null
            var last = sample()
            while (System.currentTimeMillis() - started < durationMs) {
                onMain { republishSurfaceDeclarations() }
                last = sample()
                if (last != previous) {
                    log("[$label +${System.currentTimeMillis() - started}ms] authority=${last.describeAuthority()} layout=${last.layout}")
                    previous = last
                }
                delay(POLL_MS)
            }
            log("[$label end] authority=${last.describeAuthority()} layout=${last.layout}")
            return last
        }

        suspend fun takeBack(label: String, attempts: Int): String {
            repeat(attempts) { attempt ->
                val started = System.currentTimeMillis()
                onMain { controller.reclaimTmuxGridAuthority() }
                log("[$label take-back #${attempt + 1}] requested")
                val settled = withTimeoutOrNull(TAKE_BACK_TIMEOUT_MS) {
                    while (authority() !is SharedTmuxGridAuthoritySnapshot.Mine) {
                        onMain { republishSurfaceDeclarations() }
                        delay(POLL_MS)
                    }
                    true
                }
                val elapsed = System.currentTimeMillis() - started
                val now = sample()
                log("[$label take-back #${attempt + 1}] settled=${settled == true} after ${elapsed}ms authority=${now.describeAuthority()} layout=${now.layout}")
                if (settled == true) return "settled-on-attempt-${attempt + 1}-in-${elapsed}ms"
                // Mirror a user who waits for the spinner to stop before tapping again.
                delay(RETAP_DELAY_MS)
            }
            return "never-settled-after-$attempts-attempts(${sample().describeAuthority()})"
        }

        /**
         * Selects [windowId] the way the window switcher does and waits for
         * the Mosh painter handoff to report a completed owned frame for it.
         * The verdict carries the paint latency, when the snapshot flipped,
         * whether the handoff was already bounded at bind (the selected
         * window's frame had landed) and whether the quiet watchdog had to
         * settle it.
         */
        suspend fun switchWindow(label: String, windowId: Int): String {
            val prefix = diagnostics.read().length
            val started = System.currentTimeMillis()
            onMain { controller.selectTmuxWindow(windowId) }
            log("[$label] selectTmuxWindow(@$windowId) requested")
            var activeAt: Long? = null
            var completedAt: Long? = null
            withTimeoutOrNull(WINDOW_SWITCH_TIMEOUT_MS) {
                while (completedAt == null) {
                    onMain { republishSurfaceDeclarations() }
                    val elapsed = System.currentTimeMillis() - started
                    if (activeAt == null && controller.tmuxSnapshot.value?.activeWindowId == windowId) {
                        activeAt = elapsed
                        log("[$label +${elapsed}ms] active window is @$windowId")
                    }
                    val completed = diagnostics.read().drop(prefix).lineSequence().any {
                        it.contains("render_painter_handoff detail=completed window=$windowId ")
                    }
                    if (completed) {
                        completedAt = System.currentTimeMillis() - started
                        log("[$label +${completedAt}ms] painter handoff completed for @$windowId")
                    } else {
                        delay(SWITCH_POLL_MS)
                    }
                }
            }
            val delta = diagnostics.read().drop(prefix).lines()
            val begin = delta.firstOrNull { it.contains("render_painter_handoff detail=begin window=$windowId ") }
            val bounded = begin?.let { Regex("bounded=(true|false)").find(it)?.groupValues?.get(1) } ?: "no-begin"
            val quietSettled = delta.any { it.contains("detail=quiet-settle window=$windowId ") }
            val path = "active-in-${activeAt?.let { "${it}ms" } ?: "never"},bounded-at-bind=$bounded,quiet-settle=$quietSettled"
            return if (completedAt != null) {
                "painted-in-${completedAt}ms($path)"
            } else {
                "not-painted-in-${WINDOW_SWITCH_TIMEOUT_MS}ms($path)"
            }
        }

        private fun republishSurfaceDeclarations() {
            val snapshot = controller.tmuxSnapshot.value
            val key = snapshot?.activeWindowId to snapshot?.activePaneId
            if (key == lastDeclared) return
            lastDeclared = key
            controller.setTmuxScreenRenderPresentation(TmuxScreenRenderPresentation.Single)
            controller.declareTmuxRenderSurfaces(
                tmuxScreenRenderSurfaceDeclarations(
                    presentation = TmuxScreenRenderPresentation.Single,
                    activeWindowId = snapshot?.activeWindowId,
                    activePaneId = snapshot?.activePaneId,
                    activePaneIds = snapshot?.activeWindow?.panes?.mapTo(mutableSetOf()) { it.id }
                        ?: emptySet(),
                    mountedGridPaneIds = emptySet(),
                    mountedOverlayPaneIds = emptySet(),
                ),
            )
        }

        fun dumpDiagnostics() {
            val text = diagnostics.read().drop(diagnosticsPrefix)
            log("---- diagnostics (${text.length} chars) ----")
            text.lineSequence().filter(String::isNotBlank).forEach { line -> Log.i(TAG, "diag| $line") }
            log("---- end diagnostics ----")
        }

        suspend fun close() {
            runOnMain {
                controller.close()
                surface.close()
            }
            // Give the explicit mosh-server cleanup a chance to finish so the
            // fixture account is left without a stray server.
            if (transportKind == TransportKinds.MOSH) withTimeoutOrNull(15_000L) {
                while (!diagnostics.read().drop(diagnosticsPrefix).contains("mosh_explicit_cleanup")) delay(POLL_MS)
            }
            authentication.cancel()
            scope.cancel()
        }

        suspend fun <T> onMain(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    }

    private fun createLiveController(
        fixture: Fixture,
        target: String,
        identity: TmuxDeviceIdentity,
        transportKind: String = TransportKinds.MOSH,
        presented: Boolean = true,
    ): LiveController {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val host = SavedHost(
            id = UUID.randomUUID().toString(),
            displayName = "authority rig",
            hostname = fixture.stableHost,
            port = fixture.port,
            username = fixture.user,
            jumpHostId = null,
            identityId = null,
            transportKind = transportKind,
            tmuxMode = TmuxModes.PINNED,
            tmuxTarget = target,
        )
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val diagnostics = DiagnosticLogStore(context)
        val agentSessions = LiveAgentSessionRegistry()
        val controller = SshSessionController(
            host = host,
            hosts = RigHostRepository(host),
            identities = RigIdentityRepository(),
            knownHosts = RigKnownHostsRepository(),
            restore = RigRestoreRepository(),
            credentialStore = AndroidKeystoreCredentialStore(),
            diagnostics = diagnostics,
            scope = scope,
            agentSessions = agentSessions,
            initialTmuxGridPresentation = SharedTmuxGridPresentation.SINGLE_PANE,
            tmuxDeviceIdentity = identity,
            scrollbackLines = 2_000,
        )
        lateinit var surface: TermuxTerminalSurface
        runOnMain {
            surface = TermuxTerminalSurface(context, transcriptRows = 4_000)
            surface.resize(PHONE_COLUMNS, PHONE_ROWS)
            controller.attachTerminal(surface)
            controller.setPresentationActive(presented)
            // What GeometryNeutralTerminalViewport reports for a portrait phone.
            controller.updateTmuxViewport(PHONE_COLUMNS, PHONE_ROWS)
        }
        val authentication = scope.launch {
            controller.state.collect { state ->
                when (state) {
                    is SshSessionUiState.AwaitingCredential -> controller.submitPassword(fixture.password)
                    is SshSessionUiState.AwaitingHostKey -> controller.decideHostKey(true)
                    else -> Unit
                }
            }
        }
        return LiveController(controller, host.id, surface, diagnostics, scope, authentication, transportKind)
    }

    private suspend fun remote(fixture: Fixture, command: String): String {
        val transcript = AndroidSshBackend().executeRouteCommand(
            request = SshRouteRequest(
                hops = listOf(
                    SshRouteHop(
                        id = "authority-rig-fixture",
                        endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                        username = fixture.user,
                        authentication = SshAuthentication.Password,
                    ),
                ),
            ),
            commandText = command,
            passwordProvider = SshPasswordProvider { fixture.password.toCharArray() },
            hostKeyPolicy = SshHostKeyPolicy { true },
        )
        check(transcript.exitStatus == 0) {
            "fixture command failed status=${transcript.exitStatus} stderr=${transcript.standardError.take(512)}"
        }
        return transcript.standardOutput
    }

    private fun readFixture(): Fixture? {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val descriptor = automation.executeShellCommand("cat $FIXTURE_PATH")
        val properties = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            Properties().apply { load(input) }
        }
        if (properties.getProperty("stableHost").isNullOrBlank()) return null
        fun value(name: String): String = properties.getProperty(name)?.takeIf { it.isNotBlank() }
            ?: error("rig fixture is missing $name")
        return Fixture(
            stableHost = value("stableHost"),
            port = value("port").toInt(),
            user = value("user"),
            password = android.util.Base64.decode(value("passwordBase64"), android.util.Base64.DEFAULT)
                .decodeToString(),
            authoritySession = value("authoritySession"),
        )
    }

    private data class Fixture(
        val stableHost: String,
        val port: Int,
        val user: String,
        val password: String,
        val authoritySession: String,
    )

    private class RigHostRepository(private val host: SavedHost) : HostRepository {
        private val hosts = MutableStateFlow(listOf(host))
        override val loadedHosts: StateFlow<List<SavedHost>?> = hosts
        override fun observeHosts(): Flow<List<SavedHost>> = hosts
        override suspend fun host(id: String): SavedHost? = hosts.value.firstOrNull { it.id == id }
        override suspend fun save(draft: HostDraft): SavedHost = error("rig must not persist hosts")
        override suspend fun delete(id: String): Boolean = false
        override suspend fun resolveRoute(hostId: String): List<SavedHost> =
            listOf(host).takeIf { host.id == hostId } ?: error("rig route host missing")
    }

    private class RigIdentityRepository : IdentityRepository {
        private val identities = MutableStateFlow<List<SavedIdentity>>(emptyList())
        override val loadedIdentities: StateFlow<List<SavedIdentity>?> = identities
        override fun observeIdentities(): Flow<List<SavedIdentity>> = identities
        override suspend fun identity(id: String): SavedIdentity? = null
        override suspend fun save(
            displayName: String,
            credentialKind: String,
            credentialReference: String,
            id: String?,
        ): SavedIdentity = error("rig must not persist identities")
        override suspend fun delete(id: String): Boolean = false
    }

    private class RigKnownHostsRepository : KnownHostsRepository {
        private val known = MutableStateFlow<List<SavedKnownHost>>(emptyList())
        private val trusted = mutableMapOf<String, Pair<String, ByteArray>>()
        override val loadedKnownHosts: StateFlow<List<SavedKnownHost>?> = known
        override fun observeKnownHosts(): Flow<List<SavedKnownHost>> = known
        override suspend fun evaluate(
            hostname: String,
            port: Int,
            algorithm: String,
            canonicalKeyBlob: ByteArray,
        ): HostTrustEvaluation {
            val entry = trusted["$hostname:$port"] ?: return HostTrustEvaluation.Unknown
            return if (entry.first == algorithm && entry.second.contentEquals(canonicalKeyBlob)) {
                HostTrustEvaluation.Trusted
            } else {
                HostTrustEvaluation.Changed(entry.second.copyOf())
            }
        }
        override suspend fun trust(hostname: String, port: Int, algorithm: String, canonicalKeyBlob: ByteArray) {
            trusted["$hostname:$port"] = algorithm to canonicalKeyBlob.copyOf()
        }
        override suspend fun forget(hostname: String, port: Int): Boolean = trusted.remove("$hostname:$port") != null
    }

    private class RigRestoreRepository : SessionRestoreRepository {
        override fun observeRecords(): Flow<List<SessionRestoreRecord>> = MutableStateFlow(emptyList())
        override suspend fun records(): List<SessionRestoreRecord> = emptyList()
        override suspend fun record(sessionId: String): SessionRestoreRecord? = null
        override suspend fun save(record: SessionRestoreRecord) = Unit
        override suspend fun delete(sessionId: String) = Unit
        override suspend fun deleteForHost(hostId: String) = Unit
        override suspend fun deleteAll() = Unit
    }

    private fun log(message: String) {
        Log.i(TAG, message)
    }

    private companion object {
        const val TAG = "TesseraAuthorityRig"
        const val FIXTURE_PATH = "/data/local/tmp/tessera-authority-rig-fixture.properties"
        const val PHONE_COLUMNS = 50
        const val PHONE_ROWS = 30
        /** The phone's rows with the IME up. */
        const val IME_ROWS = 18
        /** The SSH fixture's window as created; nothing off screen may change it. */
        const val FIXTURE_WINDOW = "100x30"
        const val AUTHORITY_READ_TIMEOUT_MS = 20_000L
        const val OFFSCREEN_OBSERVE_MS = 4_000L
        const val REMOTE_WINDOW_TIMEOUT_MS = 10_000L
        const val CONNECT_TIMEOUT_MS = 90_000L
        const val INITIAL_OBSERVE_MS = 15_000L
        const val PEER_OBSERVE_MS = 12_000L
        const val TAKE_BACK_TIMEOUT_MS = 8_000L
        const val RETAP_DELAY_MS = 1_500L
        const val POLL_MS = 200L
        /** The diagnostics writer is asynchronous; the show's line lands within this. */
        const val SHOW_EDGE_LOG_TIMEOUT_MS = 3_000L
        const val WINDOW_APPEAR_TIMEOUT_MS = 10_000L
        const val WINDOW_SWITCH_TIMEOUT_MS = 10_000L
        const val SWITCH_SETTLE_MS = 1_500L
        const val SWITCH_POLL_MS = 25L
    }
}

private fun <T> runOnMain(block: () -> T): T {
    val value = AtomicReference<T>()
    val failure = AtomicReference<Throwable?>()
    InstrumentationRegistry.getInstrumentation().runOnMainSync {
        try {
            value.set(block())
        } catch (error: Throwable) {
            failure.set(error)
        }
    }
    failure.get()?.let { throw it }
    return requireNotNull(value.get()) { "main-thread operation produced no value" }
}
