package com.bambouville.tessera.feature.session

import android.content.ComponentName
import android.content.Intent
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import java.io.File
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentIntegrationCommand
import com.bambouville.tessera.agent.platform.AgentProcessDiscoveryCommands
import com.bambouville.tessera.agent.platform.AgentProcessDiscoveryScope
import com.bambouville.tessera.agent.platform.AgentSessionEndpoint
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityShowSource
import com.bambouville.tessera.core.bridge.SharedTmuxCommands
import com.bambouville.tessera.core.bridge.SharedTmuxGridPresentation
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedSessionPolicy
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
import com.bambouville.tessera.files.RemoteFilesController
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshKeyAuthorizationProvider
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import com.bambouville.tessera.networking.SshRouteOwner
import com.bambouville.tessera.networking.mosh.JniMoshNativeClientFactory
import com.bambouville.tessera.networking.mosh.AndroidMoshTransport
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import java.util.Properties
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.Assume.assumeTrue
import org.junit.runner.RunWith

/**
 * Native fixture proof for the render-ledger ownership invariant.
 *
 * This deliberately does not mock the controller, runtime, terminal surface,
 * SSH fixture, or Mosh transport. The fixture preloads two tmux windows and a
 * split pane with enough marker rows to require scrollback, then the product
 * controller performs every switch and recovery. A clean screen alone is not
 * sufficient: every assertion searches the full Termux transcript and demands
 * a bound owner's history while rejecting the previous owners' markers.
 */
@RunWith(AndroidJUnit4::class)
class TmuxRenderLedgerIsolationInstrumentedTest {
    // describeTransition records the fence event that actually confirmed,
    // which can be an acknowledgement, policy reply or explicit confirmation.
    private fun String.claimReachedAwaitingRepaint(): Boolean =
        Regex("""\bclaim=g\d+:[^\r\n]*?/awaitingFence[^\r\n]*?->g\d+:[^ \r\n]*/awaitingRepaint""").containsMatchIn(this)

    /** S1/S6: real primary history, htop and Vim through each product transport. */
    @Test
    fun liveTuiScrollingAcrossAllTransports(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        val token = UUID.randomUUID().toString().take(8)
        val cleanupToken = UUID.randomUUID().toString()
        val onlyTransport = InstrumentationRegistry.getArguments().getString("scrollTransport").orEmpty()
        require(onlyTransport in setOf("", "all", "ssh", "ssh-tmux", "mosh", "mosh-tmux"))
        fun quote(value: String): String = "'" + value.replace("'", "'\"'\"'") + "'"
        val primaryPattern = Regex("S1-$token-(\\d{4})")
        val vimPattern = Regex("VIM-$token-(\\d{5})")
        val phaseNames = listOf("primary-tail", "primary-older", "primary-return", "htop-before", "htop-forward", "htop-reverse", "vim-before", "vim-forward", "vim-reverse")
        // Publish cleanup identities before the first SSH mutation, so the
        // canonical EXIT trap can finish exact cleanup if this process fails.
        // Targets also carry the lane's run token: a lane that never received
        // this record (a native crash, or the native gate, which runs every
        // case) still reaps `tessera-tui-<run token>-*` sessions and the
        // mosh-servers naming them.
        fun tuiTarget(label: String) = "tessera-tui-${fixture.token}-$token-$label".sanitizeTmuxTarget()
        val ownedResources = org.json.JSONArray()
        for (label in listOf("ssh", "ssh-tmux", "mosh", "mosh-tmux")) {
            if (onlyTransport !in setOf("", "all", label)) continue
            val target = tuiTarget(label)
            val directory = "/tmp/$target"
            ownedResources.put(JSONObject()
                .put("transport", label).put("target", target)
                .put("viewTarget", SharedTmuxCommands.moshViewSessionName(target))
                .put("directory", directory).put("workerFile", "$directory/workers"))
        }
        File(evidence, "tui-fixture-ownership.json").writeText(JSONObject()
            .put("schemaVersion", 1).put("fixtureSession", fixture.renderLedgerSession)
            .put("token", token).put("ownerMarker", cleanupToken)
            .put("resources", ownedResources).toString(2))

        for (transport in listOf(TransportKinds.SSH, TransportKinds.MOSH)) {
            for (tmux in listOf(false, true)) {
                val label = "$transport${if (tmux) "-tmux" else ""}"
                if (onlyTransport !in setOf("", "all", label)) continue
                val target = tuiTarget(label)
                val viewTarget = SharedTmuxCommands.moshViewSessionName(target)
                val directory = "/tmp/$target"
                val workerFile = "$directory/workers"
                val vimFile = "$directory/numbered.txt"
                val prefix = "tui-$label"
                var live: LiveController? = null
                var activity: ComponentActivity? = null
                var connected = false
                var prepared = false
                var primaryFailure: Throwable? = null
                val phases = org.json.JSONArray()
                val workers = mutableSetOf<Int>()
                var plainMoshVimMoved = false

                suspend fun exactGrid(session: LiveController, phase: String) {
                    awaitValue("$label $phase native measured 100x30") {
                        session.onMain {
                            session.surface.snapshotNonSecretState().takeIf {
                                session.surface.view.isAttachedToWindow && session.surface.view.isShown &&
                                    it.columns == 100 && it.rows == 30
                            }
                        }
                    }
                    if (connected && transport == TransportKinds.MOSH) {
                        awaitValue("$label $phase native canvas equality") {
                            session.controller.moshCanvasSize.value?.takeIf { it.columns == 100 && it.rows == 30 }
                        }
                    }
                }

                suspend fun viewport(session: LiveController): String = session.onMain { session.viewportTextNow() }
                fun rowNumbers(text: String, pattern: Regex): List<Int> =
                    pattern.findAll(text).map { it.groupValues[1].toInt() }.toList()
                fun visiblePids(text: String): List<Int> = text.lineSequence().mapNotNull { row ->
                    Regex("^\\s*(\\d+)\\s").find(row)?.groupValues?.get(1)?.toIntOrNull()?.takeIf { it in workers }
                }.toList()

                suspend fun capture(session: LiveController, phase: String, indices: List<Int>) {
                    exactGrid(session, phase)
                    data class Facts(
                        val text: String,
                        val state: com.bambouville.tessera.terminal.TerminalSurfaceState,
                        val route: com.bambouville.tessera.core.bridge.SharedScrollRoute,
                        val rows: List<Int>,
                        val canvas: Pair<Int, Int>?,
                        val framePending: Boolean,
                        val at: Long,
                    )
                    var lastObserved: Facts? = null
                    fun observeNow(): Facts {
                        val text = session.viewportTextNow()
                        val rows = when {
                            phase.startsWith("primary-") -> rowNumbers(text, primaryPattern)
                            phase.startsWith("htop-") -> visiblePids(text)
                            else -> rowNumbers(text, vimPattern)
                        }
                        val canvas = session.controller.moshCanvasSize.value?.let { it.columns to it.rows }
                        return Facts(text, session.surface.snapshotNonSecretState(), session.surface.view.scrollRoute(),
                            rows, canvas, session.surface.snapshotText()?.framePending != false, SystemClock.uptimeMillis())
                            .also { lastObserved = it }
                    }
                    fun matches(facts: Facts): Boolean = !facts.framePending && facts.rows == indices &&
                        facts.state.columns == 100 && facts.state.rows == 30 &&
                        (transport != TransportKinds.MOSH || facts.canvas == (100 to 30)) &&
                        (!phase.startsWith("primary-") || facts.route == com.bambouville.tessera.core.bridge.SharedScrollRoute.LocalScrollback) &&
                        (!phase.startsWith("htop-") || facts.route == com.bambouville.tessera.core.bridge.SharedScrollRoute.MouseWheel) &&
                        (!phase.startsWith("vim-") || (transport == TransportKinds.MOSH && !tmux) ||
                            facts.route == com.bambouville.tessera.core.bridge.SharedScrollRoute.MouseWheel)
                    fun samePhase(first: Facts, second: Facts): Boolean = matches(second) &&
                        first.rows == second.rows && first.route == second.route &&
                        first.state.topRow == second.state.topRow &&
                        first.state.alternateScreen == second.state.alternateScreen &&
                        first.state.mouseTracking == second.state.mouseTracking

                    var accepted: Facts? = null
                    var acceptedBefore: Facts? = null
                    var acceptedDraw: Facts? = null
                    var commitTimes = emptyList<Long>()
                    var animationAt = 0L
                    var screenshotAt = 0L
                    var attempt = 0
                    try {
                        withTimeout(8_000) {
                            while (accepted == null && attempt < 3) {
                                attempt++
                                val before = awaitValue("$label $phase complete pre-capture model") {
                                    session.onMain { observeNow().takeIf(::matches) }
                                }
                                val view = session.surface.view
                                val drawn = AtomicReference<Facts?>()
                                val committedDraw = AtomicReference<Facts?>()
                                val onDraw = android.view.ViewTreeObserver.OnDrawListener { drawn.set(observeNow()) }
                                val registeredObserver = AtomicReference<android.view.ViewTreeObserver?>()
                                val committed = mutableListOf<Long>()
                                try {
                                    val observer = session.onMain {
                                        check(view.isHardwareAccelerated) { "$label $phase requires the actual hardware renderer" }
                                        view.viewTreeObserver.also {
                                            registeredObserver.set(it)
                                            it.addOnDrawListener(onDraw)
                                        }
                                    }
                                    // UI idleness only fences model callbacks. Two real hardware draws,
                                    // each followed by another animation frame, also fence submission
                                    // before UiAutomation asks SurfaceFlinger for the displayed pixels.
                                    repeat(2) {
                                        val frame = CompletableDeferred<Long>()
                                        val animation = CompletableDeferred<Long>()
                                        val onCommit = Runnable {
                                            committedDraw.set(drawn.get())
                                            frame.complete(SystemClock.uptimeMillis())
                                        }
                                        val onAnimation = Runnable { animation.complete(SystemClock.uptimeMillis()) }
                                        try {
                                            session.onMain {
                                                check(observer.isAlive && view.isAttachedToWindow && view.isShown)
                                                observer.registerFrameCommitCallback(onCommit)
                                                view.invalidate()
                                            }
                                            committed += withTimeout(2_000) { frame.await() }
                                            session.onMain { view.postOnAnimation(onAnimation) }
                                            animationAt = withTimeout(2_000) { animation.await() }
                                        } finally {
                                            frame.cancel(); animation.cancel()
                                            withContext(NonCancellable) {
                                                session.onMain {
                                                    if (observer.isAlive) observer.unregisterFrameCommitCallback(onCommit)
                                                    view.removeCallbacks(onAnimation)
                                                }
                                            }
                                        }
                                    }
                                    val afterDraw = session.onMain { observeNow() }
                                    val rendered = committedDraw.get()
                                    if (rendered == null || !samePhase(before, rendered) || !samePhase(before, afterDraw)) continue
                                    screenshotAt = SystemClock.uptimeMillis()
                                    val bitmap = instrumentation.uiAutomation.takeScreenshot()
                                    try {
                                        val afterScreenshot = session.onMain { observeNow() }
                                        if (!samePhase(before, afterScreenshot)) continue
                                        File(evidence, "$prefix-$phase.png").outputStream().use {
                                            check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
                                        }
                                        accepted = afterScreenshot
                                        acceptedBefore = before
                                        acceptedDraw = rendered
                                        commitTimes = committed.toList()
                                    } finally { bitmap.recycle() }
                                } finally {
                                    withContext(NonCancellable) {
                                        session.onMain {
                                            registeredObserver.get()?.takeIf { it.isAlive }?.removeOnDrawListener(onDraw)
                                        }
                                    }
                                }
                            }
                        }
                    } catch (failure: Throwable) {
                        lastObserved?.let { facts ->
                            File(evidence, "$prefix-$phase-rejected-state.json").writeText(JSONObject()
                                .put("phase", phase).put("uptimeMs", facts.at)
                                .put("expectedIndices", org.json.JSONArray(indices))
                                .put("observedIndices", org.json.JSONArray(facts.rows))
                                .put("columns", facts.state.columns).put("rows", facts.state.rows)
                                .put("topRow", facts.state.topRow).put("alternateScreen", facts.state.alternateScreen)
                                .put("mouseTracking", facts.state.mouseTracking).put("scrollRoute", facts.route.toString())
                                .put("canvasColumns", facts.canvas?.first ?: JSONObject.NULL)
                                .put("canvasRows", facts.canvas?.second ?: JSONObject.NULL)
                                .put("framePending", facts.framePending).put("modelMatches", matches(facts))
                                .put("attempt", attempt).toString(2))
                            File(evidence, "$prefix-$phase-rejected-rows.txt").writeText(facts.text)
                        }
                        // The rejected-state files stay on the emulator; name the
                        // mismatch here so a gate log alone shows it.
                        val observed = lastObserved?.let { facts ->
                            "; expected rows $indices, observed ${facts.rows} route=${facts.route} " +
                                "grid=${facts.state.columns}x${facts.state.rows} framePending=${facts.framePending}"
                        }.orEmpty()
                        if (failure is TimeoutCancellationException) {
                            throw AssertionError("$label $phase timed out waiting for a matching hardware-committed screenshot$observed", failure)
                        }
                        if (failure is AssertionError && observed.isNotEmpty()) throw AssertionError("${failure.message}$observed", failure)
                        throw failure
                    }
                    val captured = requireNotNull(accepted) { "$label $phase changed across all $attempt capture attempts" }
                    val before = requireNotNull(acceptedBefore)
                    val rendered = requireNotNull(acceptedDraw)
                    val state = captured.state
                    val route = captured.route
                    File(evidence, "$prefix-$phase-rows.txt").writeText(captured.text)
                    val entry = JSONObject()
                        .put("phase", phase).put("uptimeMs", captured.at)
                        .put("preCaptureUptimeMs", before.at).put("preCaptureIndices", org.json.JSONArray(before.rows))
                        .put("postCaptureIndices", org.json.JSONArray(captured.rows))
                        .put("drawUptimeMs", rendered.at).put("drawnIndices", org.json.JSONArray(rendered.rows))
                        .put("drawnScrollRoute", rendered.route.toString())
                        .put("hardwareFrameCommitUptimeMs", org.json.JSONArray(commitTimes))
                        .put("afterCommitAnimationUptimeMs", animationAt).put("screenshotUptimeMs", screenshotAt)
                        .put("captureAttempts", attempt).put("prePostPhaseMatched", true).put("framePending", captured.framePending)
                        .put("columns", state.columns).put("rows", state.rows).put("topRow", state.topRow)
                        .put("canvasColumns", captured.canvas?.first ?: JSONObject.NULL).put("canvasRows", captured.canvas?.second ?: JSONObject.NULL)
                        .put("alternateScreen", state.alternateScreen).put("mouseTracking", state.mouseTracking)
                        .put("scrollRoute", route.toString())
                        .put("indices", org.json.JSONArray(indices)).put("workerPids", org.json.JSONArray(workers.sorted()))
                        .put("vimGraded", transport != TransportKinds.MOSH || tmux)
                    phases.put(entry)
                    File(evidence, "$prefix-state.json").writeText(JSONObject()
                        .put("transport", label).put("token", token).put("phases", phases)
                        .put("plainMoshVim", if (transport == TransportKinds.MOSH && !tmux) "diagnostic; manual acceptance remains" else "graded")
                        .toString(2))
                }

                // Finger motion exercises the same native recognizer as the product.
                // Disable only post-release momentum for stable S1/S6 positions.
                suspend fun drag(session: LiveController, towardLaterRows: Boolean) {
                    val geometry = session.onMain {
                        val view = session.surface.view
                        val location = IntArray(2); view.getLocationOnScreen(location)
                        floatArrayOf(location[0] + view.width * .5f,
                            location[1] + view.height * (if (towardLaterRows) .84f else .18f),
                            view.height * (if (towardLaterRows) -.66f else .66f))
                    }
                    val downTime = SystemClock.uptimeMillis()
                    fun inject(action: Int, fraction: Float) {
                        val event = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), action,
                            geometry[0], geometry[1] + geometry[2] * fraction, 0)
                        event.source = InputDevice.SOURCE_TOUCHSCREEN
                        try { check(instrumentation.uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
                    }
                    inject(MotionEvent.ACTION_DOWN, 0f)
                    for (step in 1..12) { delay(25); inject(MotionEvent.ACTION_MOVE, step / 12f) }
                    delay(25); inject(MotionEvent.ACTION_UP, 1f)
                    awaitFlickAtRest("$label TUI finger motion at rest", session)
                }

                suspend fun send(session: LiveController, text: String) = session.onMain { session.surface.sendInput(text.encodeToByteArray()) }
                suspend fun awaitMouseWheel(session: LiveController, program: String) {
                    awaitValue("$label $program production mouse-wheel route") {
                        session.onMain {
                            session.surface.view.scrollRoute().takeIf {
                                it == com.bambouville.tessera.core.bridge.SharedScrollRoute.MouseWheel
                            }
                        }
                    }
                }

                try {
                    // Keep every remote file, worker and program preference under this run's directory.
                    prepared = true // Retain the cleanup obligation even if the SSH response is lost.
                    remote(fixture, "set -eu; command -v htop >/dev/null; command -v vim >/dev/null; " +
                        "test ! -e ${quote(directory)}; mkdir -m 700 ${quote(directory)}; " +
                        "printf '%s\\n' ${quote(cleanupToken)} > ${quote("$directory/.owner")}")
                    remote(fixture, "set -eu; " +
                        "awk 'BEGIN { for(i=1;i<=600;i++) printf \"VIM-$token-%05d | numbered real Vim fixture\\n\", i }' > ${quote(vimFile)}; " +
                        ": > ${quote(workerFile)}; for i in ${'$'}(seq 1 80); do " +
                        "nohup bash -c 'exec -a \"${'$'}1\" sleep 900' bash \"S6-$token-${'$'}i\" </dev/null >/dev/null 2>&1 & " +
                        "p=${'$'}!; s=${'$'}(awk '{print ${'$'}22}' /proc/${'$'}p/stat); printf '%s %s\\n' \"${'$'}p\" \"${'$'}s\" >> ${quote(workerFile)}; done")
                    workers += remote(fixture, "awk '{print ${'$'}1}' ${quote(workerFile)}").lineSequence().mapNotNull(String::toIntOrNull)
                    assertEquals("$label real htop worker inventory", 80, workers.size)
                    if (tmux) remote(fixture, newSessionWithHistoryLimit(target, 4_000))
                    val session = createLiveController(fixture, target.takeIf { tmux }, transport)
                    live = session
                    activity = instrumentation.startActivitySync(
                        Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    ) as ComponentActivity
                    session.onMain {
                        session.surface.view.setSmoothScrollingEnabled(false)
                        activity.setContent {
                            Layout(content = { AndroidView(factory = { session.surface.view }, modifier = Modifier.onSizeChanged { size ->
                                val grid = session.surface.gridMetrics()
                                session.controller.updateTmuxViewport(grid.columnsFor(size.width), grid.rowsFor(size.height))
                            }) }, modifier = Modifier.fillMaxSize()) { measurables, constraints ->
                                val grid = session.surface.gridMetrics()
                                val width = grid.pixelWidth(100); val height = grid.pixelHeight(30)
                                check(width <= constraints.maxWidth && height <= constraints.maxHeight) {
                                    "$label TUI fixture requires landscape tablet space for measured 100x30: $constraints"
                                }
                                val terminal = measurables.single().measure(Constraints.fixed(width, height))
                                layout(constraints.maxWidth, constraints.maxHeight) { terminal.place(0, 0) }
                            }
                            val history by session.controller.tmuxRenderHistory.collectAsState()
                            MoshPrimaryLiveHistoryController(primaryTerminal = session.surface, delivery = history["live"],
                                enabled = transport == TransportKinds.MOSH && tmux,
                                onHistoryRequested = session.controller::requestTmuxScrollback,
                                onReturnedToLiveTail = session.controller::returnTmuxScrollbackToTail,
                                onHistoryDeliveryApplied = session.controller::acknowledgeTmuxRenderHistoryPresented)
                        }
                    }
                    exactGrid(session, "before-connect")
                    session.connectAndAwait(); connected = true
                    if (tmux) {
                        awaitValue("$label pane hydration") {
                            session.controller.tmuxSnapshot.value?.takeIf { it.activeWindowId != null && it.activePaneId != null }
                        }
                        session.onMain { session.declareSingleSurfaces() }
                        awaitValue("$label owned initial geometry") {
                            (session.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine)
                                ?.takeIf { !session.controller.tmuxReclaimInFlight.value }
                        }
                        assertSessionGroupMouseEnabled(fixture, target, mosh = transport == TransportKinds.MOSH)
                    }
                    exactGrid(session, "connected")
                    send(session, "for i in ${'$'}(seq 1 320); do printf 'S1-$token-%04d | $label primary history\\n' \"${'$'}i\"; " +
                        "if [ ${'$'}((i % 5)) -eq 0 ]; then sleep 0.08; fi; done; printf 'S1_READY_$token\\n'\n")
                    awaitValue("$label actual primary rows rendered") {
                        viewport(session).takeIf { it.contains("S1_READY_$token") && it.contains("S1-$token-0320") }
                    }
                    val tail = rowNumbers(viewport(session), primaryPattern)
                    assertTrue("$label primary tail lacks numbered rows", tail.size >= 20)
                    assertEquals("$label primary finger route", com.bambouville.tessera.core.bridge.SharedScrollRoute.LocalScrollback,
                        session.onMain { session.surface.view.scrollRoute() })
                    capture(session, phaseNames[0], tail)
                    drag(session, towardLaterRows = false)
                    val older = awaitValue("$label finger revealed older primary rows") {
                        rowNumbers(viewport(session), primaryPattern).takeIf { rows ->
                            rows.size >= 20 && rows.first() < tail.first() && session.onMain { session.surface.view.topRow < 0 }
                        }
                    }
                    assertTrue("$label older primary rows are disordered", older.zipWithNext().all { (a, b) -> b == a + 1 })
                    capture(session, phaseNames[1], older)
                    repeat(4) { if (session.onMain { session.surface.view.topRow < 0 }) drag(session, towardLaterRows = true) }
                    awaitValue("$label reversed to live primary tail") {
                        viewport(session).takeIf { session.onMain { session.surface.view.topRow == 0 } && it.contains("S1_READY_$token") }
                    }
                    capture(session, phaseNames[2], rowNumbers(viewport(session), primaryPattern))
                    if (tmux) assertEquals("$label local history entered remote copy mode", "0",
                        remote(fixture, "tmux display-message -p -t '=$target:0.0' '#{pane_in_mode}'").trim())

                    val pidList = workers.sorted().joinToString(",")
                    send(session, "HTOPRC=${quote("$directory/htoprc")} htop -d 10 -s PID -p $pidList; printf 'HTOP_EXIT_$token\\n'\n")
                    // htop paints a frame in pieces over a slow link. A list read
                    // mid-paint becomes an expectation the finished screen never
                    // matches, so take worker rows only once they hold still.
                    suspend fun settledWorkerRows(stage: String): List<Int> {
                        var candidate: List<Int>? = null
                        var since = 0L
                        return awaitValue("$label htop $stage settled worker rows") {
                            val rows = visiblePids(viewport(session)).takeIf { it.size >= 5 }
                            val now = SystemClock.uptimeMillis()
                            if (rows != candidate) { candidate = rows; since = now }
                            rows?.takeIf { now - since >= 500 }
                        }
                    }
                    val htopBefore = settledWorkerRows("before")
                    awaitMouseWheel(session, "htop")
                    capture(session, phaseNames[3], htopBefore)
                    var htopForward = htopBefore
                    repeat(4) {
                        if (htopForward.first() == htopBefore.first()) {
                            drag(session, towardLaterRows = true)
                            htopForward = settledWorkerRows("forward")
                        }
                    }
                    assertTrue("$label htop mouse wheel did not advance stable worker viewport: $htopBefore -> $htopForward",
                        htopForward.first() > htopBefore.first())
                    capture(session, phaseNames[4], htopForward)
                    var htopReverse = htopForward
                    repeat(4) {
                        if (htopReverse.first() >= htopForward.first()) {
                            drag(session, towardLaterRows = false)
                            htopReverse = settledWorkerRows("reverse")
                        }
                    }
                    assertTrue("$label htop mouse wheel did not reverse stable worker viewport: $htopForward -> $htopReverse",
                        htopReverse.first() < htopForward.first())
                    capture(session, phaseNames[5], htopReverse)
                    send(session, "q")
                    awaitValue("$label htop exited itself") { viewport(session).takeIf { it.contains("HTOP_EXIT_$token") } }

                    send(session, "vim -Nu NONE -n -i NONE -R -c 'set mouse=a number nowrap scrolloff=0 noshowmode noruler laststatus=0' " +
                        "-c 'normal! 150Gzt' -- ${quote(vimFile)}; printf 'VIM_EXIT_$token\\n'\n")
                    val vimBefore = awaitValue("$label actual numbered Vim file") {
                        rowNumbers(viewport(session), vimPattern).takeIf { it.size >= 20 && it.first() == 150 }
                    }
                    val gradeVim = transport != TransportKinds.MOSH || tmux
                    if (gradeVim) awaitMouseWheel(session, "Vim mouse=a")
                    capture(session, phaseNames[6], vimBefore)
                    drag(session, towardLaterRows = true)
                    val vimForward = if (gradeVim) awaitValue("$label Vim mouse=a moved toward later rows") {
                        rowNumbers(viewport(session), vimPattern).takeIf { it.size >= 20 && it.first() > vimBefore.first() }
                    } else { delay(500); rowNumbers(viewport(session), vimPattern) }
                    capture(session, phaseNames[7], vimForward)
                    drag(session, towardLaterRows = false)
                    val vimReverse = if (gradeVim) awaitValue("$label Vim mouse=a reversed toward earlier rows") {
                        rowNumbers(viewport(session), vimPattern).takeIf { it.size >= 20 && it.first() < vimForward.first() }
                    } else { delay(500); rowNumbers(viewport(session), vimPattern) }
                    plainMoshVimMoved = vimForward.firstOrNull()?.let { it > vimBefore.first() } == true &&
                        vimReverse.firstOrNull()?.let { it < (vimForward.firstOrNull() ?: it) } == true
                    capture(session, phaseNames[8], vimReverse)
                    send(session, "\u001b:q!\n")
                    awaitValue("$label Vim exited itself") { viewport(session).takeIf { it.contains("VIM_EXIT_$token") } }
                    assertEquals("$label nine TUI evidence phases", 9, phases.length())
                    Log.i("TesseraNativeSsh", "TESSERA_ANDROID_TUI_SCROLL_OK transport=$label primary=1 htop=1 vim=${if (gradeVim) "graded" else "manual-diagnostic"} diagnosticMotion=$plainMoshVimMoved phases=9 grid=100x30")
                } catch (failure: Throwable) {
                    primaryFailure = failure
                    throw failure
                } finally {
                    val cleanupFailures = mutableListOf<Throwable>()
                    withContext(NonCancellable) {
                        live?.let { session ->
                            runCatching { File(evidence, "$prefix-diagnostics.txt").writeText(session.diagnosticsSinceStart()) }.exceptionOrNull()?.let(cleanupFailures::add)
                            runCatching { File(evidence, "$prefix-transcript.txt").writeText(session.transcriptText()) }.exceptionOrNull()?.let(cleanupFailures::add)
                            runCatching { session.onMain { session.surface.sendInput(byteArrayOf(3)) } }.exceptionOrNull()?.let(cleanupFailures::add)
                            runCatching { session.close(awaitMoshCleanup = connected && transport == TransportKinds.MOSH) }.exceptionOrNull()?.let(cleanupFailures::add)
                        }
                        activity?.let { mounted -> runCatching { runOnMain { mounted.finish() } }.exceptionOrNull()?.let(cleanupFailures::add) }
                        if (tmux) runCatching { remote(fixture,
                            "tmux kill-session -t '=$viewTarget' 2>/dev/null || true; tmux kill-session -t '=$target' 2>/dev/null || true; " +
                                "if tmux has-session -t '=$target' 2>/dev/null || tmux has-session -t '=$viewTarget' 2>/dev/null; then exit 1; fi") }.exceptionOrNull()?.let(cleanupFailures::add)
                        // A PID from another run, or a reused PID, can never be signalled.
                        // A partially prepared directory is still ours and may contain workers.
                        if (prepared) runCatching { remote(fixture, "set -eu; if [ -d ${quote(directory)} ]; then " +
                            "test -f ${quote("$directory/.owner")}; test \"${'$'}(cat ${quote("$directory/.owner")})\" = ${quote(cleanupToken)}; " +
                            "if [ -f ${quote(workerFile)} ]; then while read -r p s; do " +
                            "if [ -r /proc/${'$'}p/stat ] && [ \"${'$'}(awk '{print ${'$'}22}' /proc/${'$'}p/stat)\" = \"${'$'}s\" ] && " +
                            "[ \"${'$'}(cat /proc/${'$'}p/comm)\" = sleep ]; then kill \"${'$'}p\"; " +
                            "for n in ${'$'}(seq 1 40); do if [ ! -r /proc/${'$'}p/stat ] || " +
                            "[ \"${'$'}(awk '{print ${'$'}22}' /proc/${'$'}p/stat)\" != \"${'$'}s\" ] || " +
                            "[ \"${'$'}(awk '{print ${'$'}3}' /proc/${'$'}p/stat)\" = Z ]; then break; fi; sleep 0.05; done; " +
                            "if [ -r /proc/${'$'}p/stat ] && [ \"${'$'}(awk '{print ${'$'}22}' /proc/${'$'}p/stat)\" = \"${'$'}s\" ] && " +
                            "[ \"${'$'}(awk '{print ${'$'}3}' /proc/${'$'}p/stat)\" != Z ]; then exit 1; fi; fi; done < ${quote(workerFile)}; fi; " +
                            "rm -rf -- ${quote(directory)}; fi; " +
                            "test ! -e ${quote(directory)}") }.exceptionOrNull()?.let(cleanupFailures::add)
                    }
                    if (cleanupFailures.isNotEmpty()) {
                        val cleanup = AssertionError("$label TUI fixture cleanup failed (prepared=$prepared)")
                        cleanupFailures.forEach(cleanup::addSuppressed)
                        primaryFailure?.addSuppressed(cleanup) ?: throw cleanup
                    }
                }
            }
        }
    }

    /**
     * §6.9 on Mosh+tmux: a show (resume after a real background) repairs an
     * unstamped wide window without selecting another window; a same-grid
     * show resolves with no claim and leaves revealed history alone (R2); a
     * foreground without a show only reads authority and yields to a live
     * peer (R5).
     */
    @Test
    fun liveMoshTmuxShowRepairsOwnedDriftAndForegroundYieldsToPeer(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val target = fixture.renderLedgerSession.sanitizeTmuxTarget()
        val viewTarget = SharedTmuxCommands.moshViewSessionName(target)
        val token = UUID.randomUUID().toString().take(8)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        val prefix = "mosh-tmux-show-drift"
        val sessions = mutableListOf<LiveController>()
        val connected = mutableSetOf<LiveController>()
        var activity: ComponentActivity? = null
        var displayed by mutableStateOf<LiveController?>(null)
        var displayColumns by mutableStateOf(56)
        var primaryFailure: Throwable? = null
        var stoppedServer: Pair<Int, String>? = null
        var fixtureProbe: SshRouteOwner? = null
        fun quoteShell(value: String): String = "'" + value.replace("'", "'\"'\"'") + "'"

        suspend fun probe(command: String): String {
            val route = fixtureProbe ?: return remote(fixture, command)
            val reply = route.executeBoundedCommand(command)
            check(reply.exitStatus == 0) {
                "foreground fixture probe failed status=${reply.exitStatus} stderr=${reply.standardError.take(512)}"
            }
            return reply.standardOutput
        }

        val shellPrompt = "FGSHELL_READY_$token"
        var shellIdentity: Pair<Int, String>? = null

        suspend fun awaitShellPrompt(session: LiveController, windowId: Int, paneId: Int, stage: String) {
            val rejectedSamples = mutableListOf<JSONObject>()
            var rejectedCount = 0
            var persistedCount = 0
            var lastPersistedAt = 0L
            awaitValue("foreground exact native and remote shell prompt $stage") {
                val nativeBefore = session.onMain {
                    session.surface.snapshotText()?.takeUnless { it.framePending }?.currentLine
                }
                // The same shell must own the foreground PTY before and after
                // sampling its actual cursor line. A locally predicted echo
                // or a still-running foreground producer cannot admit input.
                val proof = probe(
                    "set -eu; context() { tmux display-message -p -t '=$target:0.0' '#{window_id}|#{pane_id}|#{pane_pid}|#{cursor_y}'; }; " +
                        "before=${'$'}(context); pid=${'$'}(printf '%s' \"${'$'}before\" | cut -d '|' -f 3); " +
                        "row=${'$'}(printf '%s' \"${'$'}before\" | cut -d '|' -f 4); " +
                        "case \"${'$'}pid:${'$'}row\" in *[!0-9:]*|:*) exit 1;; esac; test \"${'$'}pid\" -gt 0; " +
                        "identity() { printf '%s|' \"${'$'}(cat /proc/${'$'}pid/comm)\"; " +
                        "awk '{print ${'$'}5 \"|\" ${'$'}8 \"|\" ${'$'}22}' /proc/${'$'}pid/stat; }; " +
                        "identityBefore=${'$'}(identity); " +
                        "line=${'$'}(tmux capture-pane -p -t '=$target:0.0' -S \"${'$'}row\" -E \"${'$'}row\"); " +
                        "after=${'$'}(context); identityAfter=${'$'}(identity); " +
                        "printf '%s\\n' \"${'$'}before\" \"${'$'}identityBefore\" \"${'$'}line\" \"${'$'}after\" \"${'$'}identityAfter\"",
                ).trimEnd('\r', '\n').lines()
                val nativeAfter = session.onMain {
                    session.surface.snapshotText()?.takeUnless { it.framePending }?.currentLine
                }
                fun reject(reason: String): Boolean? {
                    val sampledAt = SystemClock.elapsedRealtime()
                    rejectedCount++
                    val sample = JSONObject().apply {
                        put("reason", reason)
                        put("checkedElapsedRealtime", sampledAt)
                        put("nativeBefore", nativeBefore?.take(256) ?: JSONObject.NULL)
                        put("nativeAfter", nativeAfter?.take(256) ?: JSONObject.NULL)
                        put("remoteLineCount", proof.size)
                        put("remoteContextBefore", proof.getOrNull(0)?.take(256) ?: JSONObject.NULL)
                        put("remoteIdentityBefore", proof.getOrNull(1)?.take(256) ?: JSONObject.NULL)
                        put("remoteCurrentLine", proof.getOrNull(2)?.take(256) ?: JSONObject.NULL)
                        put("remoteContextAfter", proof.getOrNull(3)?.take(256) ?: JSONObject.NULL)
                        put("remoteIdentityAfter", proof.getOrNull(4)?.take(256) ?: JSONObject.NULL)
                    }
                    if (rejectedSamples.size < 8) rejectedSamples += sample
                    // At most eight initial samples plus one latest sample,
                    // and at most 64 writes driven by the existing wait loop.
                    if (persistedCount < 64 && (rejectedCount <= 8 || sampledAt - lastPersistedAt >= 1_000)) {
                        File(evidence, "$prefix-shell-rejected-$stage.json").writeText(JSONObject().apply {
                            put("runToken", token)
                            put("prompt", shellPrompt)
                            put("windowId", windowId)
                            put("paneId", paneId)
                            put("rejectedCount", rejectedCount)
                            put("firstSamples", org.json.JSONArray(rejectedSamples))
                            put("latestSample", sample)
                        }.toString(2))
                        persistedCount++
                        lastPersistedAt = sampledAt
                    }
                    return null
                }
                if (proof.size != 5 || proof[0] != proof[3] || proof[1] != proof[4])
                    return@awaitValue reject("remote context or identity changed")
                val context = proof[0].split('|')
                val identity = proof[1].split('|')
                if (context.size != 4 || identity.size != 4) return@awaitValue reject("malformed remote context or identity")
                val pid = context[2].toIntOrNull()?.takeIf { it > 0 } ?: return@awaitValue reject("invalid shell PID")
                val cursorRow = context[3].toIntOrNull()?.takeIf { it in 0 until 45 } ?: return@awaitValue reject("invalid cursor row")
                val processGroup = identity[1].toLongOrNull()?.takeIf { it > 0 } ?: return@awaitValue reject("invalid process group")
                val foregroundGroup = identity[2].toLongOrNull()?.takeIf { it > 0 } ?: return@awaitValue reject("invalid foreground group")
                val startTicks = identity[3].takeIf { it.toLongOrNull()?.let { value -> value > 0 } == true }
                    ?: return@awaitValue reject("invalid shell start ticks")
                val observedIdentity = pid to startTicks
                if (context[0] != "@$windowId" || context[1] != "%$paneId" || identity[0] != "bash" ||
                    processGroup != foregroundGroup || (shellIdentity != null && shellIdentity != observedIdentity) ||
                    proof[2].trimEnd() != shellPrompt) return@awaitValue reject("remote shell or prompt not ready")
                if (nativeBefore != shellPrompt || nativeAfter != shellPrompt) return@awaitValue reject("native prompt not ready")
                shellIdentity = observedIdentity
                File(evidence, "$prefix-shell-ready-$stage.json").writeText(JSONObject().apply {
                    put("runToken", token)
                    put("prompt", shellPrompt)
                    put("windowId", windowId)
                    put("paneId", paneId)
                    put("shellPid", pid)
                    put("shellStartTicks", startTicks)
                    put("processGroup", processGroup)
                    put("foregroundGroup", foregroundGroup)
                    put("cursorRow", cursorRow)
                    put("nativeCurrentLine", nativeAfter)
                    put("remoteCurrentLine", proof[2].trimEnd())
                    put("checkedElapsedRealtime", SystemClock.elapsedRealtime())
                }.toString(2))
                true
            }
        }

        // show-options parses its -t as a session option target and does not
        // accept the =name spelling used by pane targets. The pane format
        // preserves exact view-session matching and its own option scope.
        fun authorityStampCommand(): String =
            "tmux display-message -p -t '=$viewTarget:0.0' '#{@tessera_authority}'"

        suspend fun authorityStamp(): String = probe(authorityStampCommand()).trim()

        suspend fun resumeStoppedServer() {
            val (pid, start) = stoppedServer ?: return
            // The obligation ends only on the host's word: `continued` after a
            // CONT that reached this exact PID and start time, or `absent` once
            // that process no longer exists (nothing is left stopped). A
            // stopped mosh-server outlives every client and session cleanup.
            val reply = probe(
                "if test \"${'$'}(cat /proc/$pid/comm 2>/dev/null)\" = mosh-server && " +
                    "test \"${'$'}(awk '{print ${'$'}22}' /proc/$pid/stat 2>/dev/null)\" = '$start'; " +
                    "then kill -CONT $pid && echo continued; else echo absent; fi",
            ).trim()
            check(reply == "continued" || reply == "absent") { "stopped Mosh server $pid resume unconfirmed: $reply" }
            stoppedServer = null
        }

        suspend fun capture(stage: String) {
            val bitmap = instrumentation.uiAutomation.takeScreenshot()
            File(evidence, "$prefix-$stage.png").outputStream().use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
        }

        suspend fun remoteGrid(columns: Int) {
            var observed = "none"
            try {
                awaitValue("Mosh foreground remote ${columns}x45") {
                    observed = probe("tmux display-message -p -t '=$target:0.0' '#{pane_width}x#{pane_height}'").trim()
                    observed.takeIf { it == "${columns}x45" }
                }
            } catch (failure: AssertionError) {
                throw AssertionError("${failure.message}; observed=$observed", failure)
            }
        }

        suspend fun nativeGrid(session: LiveController, columns: Int) {
            awaitValue("Mosh foreground native ${columns}x45") {
                session.onMain { session.surface.snapshotNonSecretState().takeIf { it.columns == columns && it.rows == 45 } }
            }
        }

        suspend fun settledMine(session: LiveController, after: Long): SharedTmuxGridAuthoritySnapshot.Mine =
            awaitValue("Mosh foreground settled owned claim after $after") {
                (session.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine)
                    ?.takeIf { it.generation > after && !session.controller.tmuxReclaimInFlight.value }
            }

        suspend fun mount(session: LiveController, columns: Int) {
            session.onMain { displayed = session; displayColumns = columns }
            awaitValue("Mosh foreground mounted terminal") {
                session.onMain { true.takeIf { session.surface.view.isAttachedToWindow && session.surface.view.isShown } }
            }
            nativeGrid(session, columns)
            session.onMain { session.declareSingleSurfaces() }
        }

        suspend fun typedMarker(session: LiveController, stage: String) {
            val marker = "FGDRIFT-INPUT-$token-$stage"
            session.onMain { session.surface.sendInput("printf 'FGDRIFT-INPUT-%s-%s\\n' '$token' '$stage'\n".encodeToByteArray()) }
            awaitValue("Mosh foreground typed output $stage") {
                session.onMain { session.surface.snapshotText()?.visibleText?.takeIf { it.contains(marker) } }
            }
            assertTrue("Mosh foreground input did not reach the remote pane", remote(fixture, "tmux capture-pane -p -t '=$target:0.0'").contains(marker))
        }

        suspend fun tick(session: LiveController): Long? = session.onMain {
            Regex("FGDRIFT-$token-(\\d{5})").findAll(session.surface.snapshotText()?.visibleText.orEmpty())
                .maxOfOrNull { it.groupValues[1].toLong() }
        }

        suspend fun frameAtRightEdge(session: LiveController, previousTick: Long) {
            awaitValue("fresh owned Mosh frame with restored right edge") {
                val progressed = tick(session)?.let { it > previousTick } == true
                session.onMain {
                    val frame = session.surface.snapshotText()?.screenEvidence
                    true.takeIf {
                        progressed && frame?.columns == 56 && frame.cells.size == 45 &&
                            frame.cells[1].drop(47).take(9).joinToString("") { it.text } == "EDGE_DONE"
                    }
                }
            }
        }

        suspend fun slowHistoryDrag(session: LiveController) {
            val geometry = session.onMain {
                val view = session.surface.view
                val location = IntArray(2); view.getLocationOnScreen(location)
                floatArrayOf(location[0] + view.width * .5f, location[1] + view.height * .2f, view.height * .35f)
            }
            val down = SystemClock.uptimeMillis()
            fun inject(action: Int, fraction: Float) {
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, geometry[0], geometry[1] + geometry[2] * fraction, 0)
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                try { check(instrumentation.uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
            }
            inject(MotionEvent.ACTION_DOWN, 0f)
            for (step in 1..24) { delay(16); inject(MotionEvent.ACTION_MOVE, step / 24f) }
            delay(300)
            inject(MotionEvent.ACTION_UP, 1f)
            awaitFlickAtRest("foreground owned-history reveal", session)
        }

        awaitTimeoutEvidence = { label ->
            File(evidence, "$prefix-await-timeout.txt").writeText("$label\n")
            sessions.forEachIndexed { index, session ->
                File(evidence, "$prefix-${index + 1}-diagnostics.txt").writeText(session.diagnosticsSinceStart())
            }
        }
        try {
            remote(fixture, newSessionWithHistoryLimit(target, 4_000))
            val own = createLiveController(
                fixture, target, TransportKinds.MOSH, TmuxDeviceIdentity("android-foreground-$token-own", "Foreground-Own"),
            ).also(sessions::add)
            activity = instrumentation.startActivitySync(
                Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            ) as ComponentActivity
            own.onMain {
                activity.setContent {
                    displayed?.let { session ->
                        key(session.surface) {
                            Layout(
                                content = { AndroidView(factory = { session.surface.view }) },
                                modifier = Modifier.fillMaxSize(),
                            ) { measurables, constraints ->
                                val metrics = session.surface.gridMetrics()
                                val width = metrics.pixelWidth(displayColumns)
                                val height = metrics.pixelHeight(45)
                                check(width <= constraints.maxWidth && height <= constraints.maxHeight) { "Mosh foreground fixture requires tablet ${displayColumns}x45" }
                                val terminal = measurables.single().measure(Constraints.fixed(width, height))
                                layout(constraints.maxWidth, constraints.maxHeight) { terminal.place(0, 0) }
                            }
                            val history by session.controller.tmuxRenderHistory.collectAsState()
                            MoshPrimaryLiveHistoryController(
                                primaryTerminal = session.surface,
                                delivery = history["live"],
                                enabled = true,
                                onHistoryRequested = session.controller::requestTmuxScrollback,
                                onReturnedToLiveTail = session.controller::returnTmuxScrollbackToTail,
                                onHistoryDeliveryApplied = session.controller::acknowledgeTmuxRenderHistoryPresented,
                            )
                        }
                    }
                }
                displayed = own
            }
            nativeGrid(own, 56)
            own.connectAndAwait()
            connected += own
            awaitValue("Mosh foreground pane hydration") {
                own.controller.tmuxSnapshot.value?.takeIf { it.activeWindowId != null && it.activePaneId != null }
            }
            mount(own, 56)
            val initial = settledMine(own, 0)
            own.onMain { own.controller.updateTmuxViewport(56, 45) }
            remoteGrid(56)
            val paneId = requireNotNull(own.controller.tmuxSnapshot.value?.activePaneId)
            val windowId = requireNotNull(own.controller.tmuxSnapshot.value?.activeWindowId)
            typedMarker(own, "before")
            own.onMain {
                own.surface.sendInput("PS1=${quoteShell(shellPrompt)}; printf '\\n'\n".encodeToByteArray())
            }
            awaitShellPrompt(own, windowId, paneId, "before-producer")
            // A foreground external process exits deterministically on SIGINT.
            // Its actual PTY width drives the same 600 frames and cadence; at
            // 100 columns EDGE_DONE is outside the local 56-column canvas.
            val producer = """
                import os, signal, sys, time
                def stop(*_):
                    sys.stdout.write("\x1b[3;1H\x1b[2K")
                    sys.stdout.flush()
                    sys.exit(0)
                signal.signal(signal.SIGINT, stop)
                token = sys.argv[1]
                for i in range(1, 601):
                    edge = os.get_terminal_size(sys.stdout.fileno()).columns - 8
                    sys.stdout.write("\x1b[1;1H\x1b[2KFGDRIFT-%s-%05d\x1b[2;1H\x1b[2K\x1b[2;%dHEDGE_DONE\x1b[3;1H" % (token, i, edge))
                    sys.stdout.flush()
                    time.sleep(0.15)
            """.trimIndent()
            own.onMain {
                own.surface.sendInput("python3 -c ${quoteShell(producer)} '$token'\n".encodeToByteArray())
            }
            frameAtRightEdge(own, 0)
            capture("before-owned-56x45")
            // Authenticate an independent fixture exec route before stopping
            // SSP. Repeated SSH handshakes inside the held-server proof can
            // consume the production frame fence's two-second deadline.
            fixtureProbe = AndroidSshBackend().openRoute(
                request = SshRouteRequest(
                    hops = listOf(SshRouteHop(
                        id = "foreground-fixture-probe",
                        endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                        username = fixture.user,
                        authentication = SshAuthentication.Password,
                    )),
                ),
                passwordProvider = SshPasswordProvider { fixture.password.toCharArray() },
                hostKeyPolicy = SshHostKeyPolicy { true },
            )
            val stampBeforeDrift = authorityStamp()
            assertEquals("initial remote stamp must belong to the settled local claim",
                SharedTmuxCommands.authorityStampValue(own.tmuxDeviceIdentity.id, own.tmuxDeviceIdentity.displayName, initial.generation),
                stampBeforeDrift)
            // A real background longer than the debounce: the app shell
            // reports the hide edge alongside the process background.
            own.onMain { own.controller.setAppForeground(false); own.controller.hidden() }
            probe("tmux resize-window -t '=$target:0' -x 100 -y 45")
            remoteGrid(100)
            assertEquals("fixture drift must not write an authority stamp", stampBeforeDrift,
                authorityStamp())
            val driftTick = tick(own) ?: 0L
            awaitValue("Mosh painted the wide drift before failure injection") { tick(own)?.takeIf { it > driftTick } }
            capture("drift-remote-100x45")
            val tickBefore = tick(own) ?: 0L
            val serverPid = own.moshServerPid()
            val processStart = probe(
                "test \"${'$'}(cat /proc/$serverPid/comm)\" = mosh-server && awk '{print ${'$'}22}' /proc/$serverPid/stat",
            ).trim().also { check(it.toLongOrNull()?.let { start -> start > 0 } == true) }
            // Retain the exact PID/start-time obligation before signalling, so
            // a lost SSH response still resumes this generated server in finally.
            stoppedServer = serverPid to processStart
            File(evidence, "$prefix-server-process.json").writeText(JSONObject().apply {
                put("runToken", token)
                put("pid", serverPid)
                put("startTicks", processStart)
                put("comm", "mosh-server")
                put("target", target)
                put("viewTarget", viewTarget)
                put("capturedElapsedRealtime", SystemClock.elapsedRealtime())
            }.toString(2))
            probe("test \"${'$'}(awk '{print ${'$'}22}' /proc/$serverPid/stat)\" = '$processStart' && kill -STOP $serverPid")
            awaitValue("run-owned Mosh server stopped") {
                probe("awk '/^State:/{print ${'$'}2}' /proc/$serverPid/status").trim().takeIf { it == "T" }
            }
            val ownLogOffset = own.diagnosticsSinceStart().length
            val foregroundAt = SystemClock.elapsedRealtime()
            // The resume: the process foreground and the tab's show edge.
            // Only the show claims; its own read finds this device's stamp
            // over a foreign size and begins the full claim.
            own.onMain {
                own.controller.setAppForeground(true)
                own.controller.shown(SharedTmuxAuthorityShowSource.SHOW)
            }
            remoteGrid(56)
            awaitValue("SSH fence reached the delayed SSP repaint") {
                own.diagnosticsSinceStart().drop(ownLogOffset).takeIf { it.claimReachedAwaitingRepaint() }
            }
            val fenceObservedAt = SystemClock.elapsedRealtime()
            capture("ssh-fixed-ssp-delayed")
            delay(250)
            assertFalse("a cached frame settled recovery while the Mosh server was stopped",
                own.diagnosticsSinceStart().drop(ownLogOffset).contains("event=repaintSucceeded"))
            assertFalse("recovery settled without fresh SSP",
                (own.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine)?.generation?.let { it > initial.generation } == true)
            val beforeContinueAt = SystemClock.elapsedRealtime()
            // The remote process must still be stopped when geometry and
            // stamp are sampled. Continue that exact PID in this same exec;
            // a fresh authentication between those operations adds no proof.
            val heldProof = probe(
                "set -eu; test \"${'$'}(cat /proc/$serverPid/comm)\" = mosh-server; " +
                    "test \"${'$'}(awk '{print ${'$'}22}' /proc/$serverPid/stat)\" = '$processStart'; " +
                    "state=${'$'}(awk '/^State:/{print ${'$'}2}' /proc/$serverPid/status); test \"${'$'}state\" = T; " +
                    "printf 'state=%s\\n' \"${'$'}state\"; " +
                    "printf 'grid=%s\\n' \"${'$'}(tmux display-message -p -t '=$target:0.0' '#{pane_width}x#{pane_height}')\"; " +
                    "printf 'stamp=%s\\n' \"${'$'}(${authorityStampCommand()})\"; " +
                    "kill -CONT $serverPid; printf 'continued=1\\n'",
            ).trimEnd().lines().associate { line -> line.substringBefore('=') to line.substringAfter('=') }
            // Release the resume obligation only on the host's confirmation
            // that CONT reached the server; otherwise finally continues it.
            check(heldProof["continued"] == "1") { "held Mosh server $serverPid was not confirmed continued: $heldProof" }
            stoppedServer = null
            val continuedAt = SystemClock.elapsedRealtime()
            File(evidence, "$prefix-delayed-ssp-timing.csv").writeText(
                "foregroundAt,fenceObservedAt,beforeContinueAt,continuedAt,foregroundToContinueMs,fenceToContinueMs\n" +
                    "$foregroundAt,$fenceObservedAt,$beforeContinueAt,$continuedAt,${continuedAt - foregroundAt},${continuedAt - fenceObservedAt}\n",
            )
            assertEquals("paused SSP process proof", "T", heldProof["state"])
            assertEquals("SSH geometry before fresh SSP", "56x45", heldProof["grid"])
            assertEquals("SSH geometry alone committed an authority stamp before fresh SSP", stampBeforeDrift, heldProof["stamp"])
            assertTrue("held-server proof exceeded the two-second production frame fence: ${continuedAt - foregroundAt}ms", continuedAt - foregroundAt < 2_000)
            assertTrue("held-server proof did not keep SSP paused after the SSH fence", continuedAt - fenceObservedAt >= 250)
            val recovered = settledMine(own, initial.generation)
            remoteGrid(56)
            nativeGrid(own, 56)
            awaitValue("Mosh foreground SSP canvas restored") {
                own.controller.moshCanvasSize.value?.takeIf { it.columns == 56 && it.rows == 45 }
            }
            frameAtRightEdge(own, tickBefore)
            val ownLog = own.diagnosticsSinceStart().drop(ownLogOffset)
            assertTrue("the show did not query authority: $ownLog", ownLog.contains("event=shown") && ownLog.contains("queryAuthority"))
            assertTrue("the show did not perform the shared full geometry claim: $ownLog", ownLog.contains("event=queryReplied") && ownLog.contains(":show/awaitingFence"))
            assertTrue("the show has no exact accepted native full-frame receipt: $ownLog", ownLog.contains("event=repaintSucceeded"))
            assertEquals("the show changed windows", windowId, own.controller.tmuxSnapshot.value?.activeWindowId)
            assertEquals("the show changed panes", paneId, own.controller.tmuxSnapshot.value?.activePaneId)
            capture("recovered-owned-56x45")

            // A near-tail viewport includes captured live rows. The shared
            // reservation must defer even ED2's live-bottom repaint until the
            // reader returns to tail, preserving its rows and presentation.
            own.onMain { own.surface.sendInput(byteArrayOf(3)) }
            awaitShellPrompt(own, windowId, paneId, "before-history-seed")
            own.onMain {
                own.surface.sendInput(
                    ("for i in ${'$'}(seq 1 300); do printf 'FGHISTORY_%05d | $token | 0123456789abcdef\\n' \"${'$'}i\"; " +
                        "if [ ${'$'}((i % 30)) -eq 0 ]; then sleep 0.05; fi; done; printf 'FGHISTORY_READY_%s\\n' '$token'\n").encodeToByteArray(),
                )
            }
            awaitValue("foreground history seed") {
                own.onMain { own.surface.snapshotText()?.visibleText?.takeIf { it.contains("FGHISTORY_READY_$token") } }
            }
            slowHistoryDrag(own)
            val history = awaitValue("foreground revealed owned history") {
                own.controller.tmuxRenderHistory.value["live"]?.takeIf { own.onMain { own.surface.view.topRow < 0 } }
            }
            val historyOwner = own.onMain { own.surface.boundOwner }
            val historyTop = own.onMain { own.surface.view.topRow }
            val historyViewport = own.onMain { own.viewportTextNow() }
            assertTrue("revealed viewport has no fixture history", historyViewport.contains("FGHISTORY_"))
            assertTrue("history proof must include captured live rows near tail: $historyTop", historyTop in -44..-1)
            val freezeOffset = own.diagnosticsSinceStart().length
            val burst = "for i in 1 2 3 4 5 6 7 8; do printf 'FGHISTORY_BURST_%s\\n' \"${'$'}i\"; done"
            remote(fixture, "tmux send-keys -t '=$target:0.0' -l ${quoteShell(burst)}; tmux send-keys -t '=$target:0.0' Enter")
            awaitValue("real Mosh output froze the near-tail history") {
                own.diagnosticsSinceStart().drop(freezeOffset).takeIf { it.contains("side-channel-frozen") }
            }
            assertEquals("natural output moved the near-tail history", historyViewport, own.onMain { own.viewportTextNow() })
            capture("history-before-foreground")
            val historyLogOffset = own.diagnosticsSinceStart().length
            val historyStamp = authorityStamp()
            assertEquals("history resume must begin with this device's settled stamp",
                SharedTmuxCommands.authorityStampValue(own.tmuxDeviceIdentity.id, own.tmuxDeviceIdentity.displayName, recovered.generation),
                historyStamp)
            // A same-grid hide and show: the show's own read finds this
            // device's stamp at its local size, which resolves the intent
            // with no commands at all (§6.9 R2). Nothing may touch the reader.
            own.onMain { own.controller.setAppForeground(false); own.controller.hidden() }
            own.onMain {
                own.controller.setAppForeground(true)
                own.controller.shown(SharedTmuxAuthorityShowSource.SHOW)
            }
            awaitValue("same-grid show resolved by its own read") {
                own.diagnosticsSinceStart().drop(historyLogOffset).takeIf {
                    it.contains("event=queryReplied") &&
                        own.controller.tmuxAuthorityPresentation.value == TmuxAuthorityPresentation.None
                }
            }
            delay(300)
            val heldLog = own.diagnosticsSinceStart().drop(historyLogOffset)
            assertTrue("the same-grid show did not read authority: $heldLog", heldLog.contains("event=shown") && heldLog.contains("queryAuthority"))
            assertFalse("a same-grid show began a claim: $heldLog", heldLog.contains("beginClaim("))
            assertFalse("a same-grid show fenced, repainted or committed: $heldLog",
                heldLog.contains("event=claimFenceSent") || heldLog.claimReachedAwaitingRepaint() || heldLog.contains("event=repaintSucceeded") || heldLog.contains("event=stampCommitSucceeded"))
            assertFalse("a same-grid show forced a frame into the history reader", heldLog.contains("tmux_authority_repaint detail=issued") || heldLog.contains("tmux_authority_repaint detail=forcing"))
            assertEquals("a same-grid show changed the claim", recovered, own.controller.tmuxAuthority.value)
            assertEquals("a same-grid show changed the stamp while history was revealed", historyStamp,
                authorityStamp())
            assertEquals("a same-grid show replaced the same-owner history token", history.deliveryToken, own.controller.tmuxRenderHistory.value["live"]?.deliveryToken)
            assertEquals("a same-grid show rebound the same-owner history", historyOwner, own.onMain { own.surface.boundOwner })
            assertEquals("a same-grid show moved the history reader", historyTop, own.onMain { own.surface.view.topRow })
            assertEquals("a same-grid show changed the revealed history rows", historyViewport, own.onMain { own.viewportTextNow() })
            remoteGrid(56)
            capture("history-after-show")
            own.onMain { own.surface.view.topRow = 0; own.controller.returnTmuxScrollbackToTail("live") }
            val historyRecovered = awaitValue("history returned to tail under the same claim") {
                (own.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine)
                    ?.takeIf { !own.controller.tmuxReclaimInFlight.value }
            }
            assertEquals("returning to tail after a same-grid show claimed again", recovered.generation, historyRecovered.generation)
            typedMarker(own, "history-tail")

            val peer = createLiveController(
                fixture, target, TransportKinds.MOSH, TmuxDeviceIdentity("android-foreground-$token-peer", "Foreground-Peer"),
            ).also(sessions::add)
            mount(peer, 100)
            peer.connectAndAwait()
            connected += peer
            awaitValue("foreground live-peer snapshot") {
                peer.controller.tmuxSnapshot.value?.takeIf { it.activeWindowId != null && it.activePaneId != null }
            }
            peer.onMain { peer.declareSingleSurfaces(); peer.controller.updateTmuxViewport(100, 45) }
            // The peer's show (reported by connectAndAwait) claims its
            // viewport. A later foreground on the original carrier without a
            // show only reads authority and must yield to that live owner.
            val peerAuthority = settledMine(peer, 0)
            remoteGrid(100)
            typedMarker(peer, "peer-owned")
            awaitValue("original carrier yields to real live peer") {
                (own.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Peer)?.takeIf { it.deviceId == peer.tmuxDeviceIdentity.id }
            }
            val peerStamp = authorityStamp()
            assertEquals("live peer must own the actual remote stamp",
                SharedTmuxCommands.authorityStampValue(peer.tmuxDeviceIdentity.id, peer.tmuxDeviceIdentity.displayName, peerAuthority.generation),
                peerStamp)
            mount(own, 56)
            val peerLogOffset = own.diagnosticsSinceStart().length
            own.onMain { own.controller.setAppForeground(false); own.controller.setAppForeground(true) }
            // The reply's own diagnostic: a reply that changes nothing (the
            // peer already holds the grid) leaves no reducer transition trace.
            awaitValue("foreground queried the live peer authority") {
                own.diagnosticsSinceStart().drop(peerLogOffset).takeIf { it.contains("tmux_authority_query_reply detail=") }
            }
            delay(500)
            assertEquals("foreground stole a live peer", peer.tmuxDeviceIdentity.id,
                (own.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Peer)?.deviceId)
            assertEquals("foreground changed the live peer's claim", peerAuthority, peer.controller.tmuxAuthority.value)
            assertEquals("foreground overwrote the live peer's stamp", peerStamp,
                authorityStamp())
            remoteGrid(100)
            assertFalse("foreground began a claim against a live peer", own.diagnosticsSinceStart().drop(peerLogOffset).contains("beginClaim("))
            assertEquals("peer foreground changed windows", windowId, own.controller.tmuxSnapshot.value?.activeWindowId)
            assertEquals("peer foreground changed panes", paneId, own.controller.tmuxSnapshot.value?.activePaneId)
            capture("foreground-yields-live-peer")
            mount(peer, 100)
            typedMarker(peer, "peer-after-foreground")
            assertTrue("foreground must retain both live carriers", sessions.all { it.controller.state.value is SshSessionUiState.Connected })
            File(evidence, "$prefix-generations.txt").writeText("initial=${initial.generation}\nrecovered=${recovered.generation}\nhistory=${historyRecovered.generation}\npeer=${peerAuthority.generation}\n")
            Log.i("TesseraNativeSsh", "TESSERA_ANDROID_MOSH_TMUX_SHOW_DRIFT_OK drift=100x45 restored=56x45 showQuery=1 showClaim=1 exactFrame=1 delayedSSP=1 rightEdge=1 sameWindow=1 sameGridShowNoClaim=1 historyPreserved=1 foregroundYieldsLivePeer=1 carriers=2")
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            awaitTimeoutEvidence = null
            val cleanupFailures = mutableListOf<Throwable>()
            withContext(NonCancellable) {
                runCatching { resumeStoppedServer() }.exceptionOrNull()?.let(cleanupFailures::add)
            }
            sessions.forEachIndexed { index, session ->
                runCatching {
                    File(evidence, "$prefix-${index + 1}-diagnostics.txt").writeText(session.diagnosticsSinceStart())
                    File(evidence, "$prefix-${index + 1}-transcript.txt").writeText(session.transcriptText())
                }.exceptionOrNull()?.let(cleanupFailures::add)
            }
            activity?.let { runCatching { runOnMain { it.finish() } }.exceptionOrNull()?.let(cleanupFailures::add) }
            sessions.asReversed().forEach { session ->
                runCatching { session.close(awaitMoshCleanup = session in connected) }.exceptionOrNull()?.let(cleanupFailures::add)
            }
            runCatching { fixtureProbe?.close() }.exceptionOrNull()?.let(cleanupFailures::add)
            runCatching {
                remote(fixture, "tmux kill-session -t '=$viewTarget' 2>/dev/null || true; tmux kill-session -t '=$target' 2>/dev/null || true")
                assertEquals("run-owned foreground sessions survived cleanup", "", remote(fixture, "tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
                    .lineSequence().filter { it == target || it == viewTarget }.joinToString("\n"))
            }.exceptionOrNull()?.let(cleanupFailures::add)
            cleanupFailures.forEach { primaryFailure?.addSuppressed(it) }
            if (primaryFailure == null && cleanupFailures.isNotEmpty()) throw cleanupFailures.first()
        }
    }

    /** A real width-only foreground capture must await the native layout commit. */
    @Test
    fun liveSshTmuxWidthOnlyForegroundWaitsForNativeGrid(): Unit = runBlocking {
        val fixture = readFixture()
        val target = fixture.renderLedgerSession.sanitizeTmuxTarget()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        val prefix = "ssh-tmux-width-foreground"
        val token = UUID.randomUUID().toString().take(8)
        var live: LiveController? = null
        var activity: ComponentActivity? = null
        var snapshotObserver: Job? = null
        var requestedColumns by mutableStateOf(100)
        var narrowLayoutAt = 0L
        var foregroundAt = 0L
        var primaryFailure: Throwable? = null

        suspend fun capture(stage: String) {
            val bitmap = instrumentation.uiAutomation.takeScreenshot()
            File(evidence, "$prefix-$stage.png").outputStream().use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
        }

        suspend fun remoteGrid(columns: Int) {
            var observed = "none"
            try {
                awaitValue("width-only remote ${columns}x45") {
                    observed = remote(fixture, "tmux display-message -p -t '=$target:0.0' '#{pane_width}x#{pane_height}'").trim()
                    observed.takeIf { it == "${columns}x45" }
                }
            } catch (failure: AssertionError) {
                throw AssertionError("${failure.message}; observed=$observed", failure)
            }
        }

        suspend fun typedMarker(session: LiveController, stage: String) {
            val marker = "WIDTH-FOREGROUND-$token-$stage"
            session.onMain {
                session.surface.sendInput("printf 'WIDTH-FOREGROUND-%s-%s\\n' '$token' '$stage'\n".encodeToByteArray())
            }
            awaitValue("width-only rendered marker $stage") {
                session.onMain { session.surface.snapshotText()?.visibleText?.takeIf { it.contains(marker) } }
            }
            assertTrue("width-only input did not reach the real pane", remote(fixture, "tmux capture-pane -p -t '=$target:0.0'").contains(marker))
        }

        try {
            remote(fixture, newSessionWithHistoryLimit(target, 4_000))
            val session = createLiveController(fixture, target, TransportKinds.SSH)
            live = session
            activity = instrumentation.startActivitySync(
                Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            ) as ComponentActivity
            session.onMain {
                // The existing production Handler/onSizeChanged path commits
                // the emulator after a bounded settle. No surface-state or
                // render receipt is replaced by this fixture.
                session.surface.view.layoutResizeDelayMillis = 250
                activity.setContent {
                    Layout(
                        content = {
                            AndroidView(
                                factory = { session.surface.view },
                                modifier = Modifier.onSizeChanged { size ->
                                    val metrics = session.surface.gridMetrics()
                                    val columns = metrics.columnsFor(size.width)
                                    val rows = metrics.rowsFor(size.height)
                                    if (columns == 56 && rows == 45) narrowLayoutAt = SystemClock.uptimeMillis()
                                    session.controller.updateTmuxViewport(columns, rows)
                                },
                            )
                        },
                        modifier = Modifier.fillMaxSize(),
                    ) { measurables, constraints ->
                        val metrics = session.surface.gridMetrics()
                        val width = metrics.pixelWidth(requestedColumns)
                        val height = metrics.pixelHeight(45)
                        check(width <= constraints.maxWidth && height <= constraints.maxHeight) {
                            "width-only fixture requires tablet space for ${requestedColumns}x45: $constraints"
                        }
                        val terminal = measurables.single().measure(Constraints.fixed(width, height))
                        layout(constraints.maxWidth, constraints.maxHeight) { terminal.place(0, 0) }
                    }
                }
            }
            awaitValue("mounted native width-only 100x45") {
                session.onMain {
                    session.surface.snapshotNonSecretState().takeIf {
                        session.surface.view.isAttachedToWindow && it.columns == 100 && it.rows == 45
                    }
                }
            }
            session.connectAndAwait()
            awaitValue("width-only pane hydration") { session.controller.tmuxSnapshot.value?.activePaneId }
            session.onMain { session.declareSingleSurfaces() }
            awaitValue("width-only initial authority") {
                (session.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine)
                    ?.takeIf { !session.controller.tmuxReclaimInFlight.value }
            }
            remoteGrid(100)
            typedMarker(session, "before")
            capture("before-100x45")
            val logOffset = session.diagnosticsSinceStart().length
            val foreground = CompletableDeferred<Unit>()
            snapshotObserver = launch(Dispatchers.Main.immediate) {
                session.controller.tmuxSnapshot.collect { snapshot ->
                    val pane = snapshot?.activeWindow?.layout
                    if (pane?.width == 56 && pane.height == 45 && !foreground.isCompleted) {
                        // This snapshot is the real control client's remote
                        // geometry reply. Trigger foreground immediately,
                        // without adding a second SSH route's round trips to
                        // the native layout's 250 ms settle window.
                        val native = session.surface.snapshotNonSecretState()
                        if (native.columns != 100 || native.rows != 45 || narrowLayoutAt == 0L) {
                            foreground.completeExceptionally(AssertionError(
                                "native grid settled before foreground mismatch: native=${native.columns}x${native.rows} remote=56x45",
                            ))
                        } else {
                            foregroundAt = SystemClock.uptimeMillis()
                            session.controller.setAppForeground(false)
                            session.controller.setAppForeground(true)
                            foreground.complete(Unit)
                        }
                    }
                }
            }
            session.onMain { requestedColumns = 56 }
            withTimeout(1_000) { foreground.await() }
            val wait = "render-ledger surface-grid-wait surface=live columns=100 paneColumns=56 rows=45 paneRows=45"
            val settled = "render-ledger surface-grid-settled surface=live columns=56 paneColumns=56 rows=45 paneRows=45"
            withTimeout(1_000) {
                while (!session.diagnosticsSinceStart().drop(logOffset).contains(wait)) delay(10)
            }
            val nativeCommittedAt = withTimeout(1_000) {
                while (true) {
                    val matches = session.onMain {
                        session.surface.snapshotNonSecretState().let { it.columns == 56 && it.rows == 45 }
                    }
                    if (matches) return@withTimeout SystemClock.uptimeMillis()
                    delay(10)
                }
                error("unreachable")
            }
            assertTrue("native width settle exceeded the shared 400 ms grid budget", nativeCommittedAt - narrowLayoutAt <= 400)
            awaitValue("width-only surface grid settled") {
                session.diagnosticsSinceStart().drop(logOffset).takeIf { it.contains(settled) }
            }
            val resizeLog = session.diagnosticsSinceStart().drop(logOffset)
            assertFalse("width-only layout consumed the fallback budget", resizeLog.contains("surface-grid-wait-expired"))
            typedMarker(session, "after")
            remoteGrid(56)
            assertEquals("width-only capture rejected an owned feed", 0, session.onMain { session.surface.droppedForeignFeeds })
            capture("after-56x45")
            File(evidence, "$prefix-timing.csv").writeText(
                "layoutAt,foregroundAt,nativeCommittedAt,nativeSettleMs\n$narrowLayoutAt,$foregroundAt,$nativeCommittedAt,${nativeCommittedAt - narrowLayoutAt}\n",
            )
            Log.i("TesseraNativeSsh", "TESSERA_ANDROID_SSH_TMUX_WIDTH_FOREGROUND_OK old=100x45 remote=56x45 native=56x45 wait=1 settled=1 typedMarker=1 expired=0")
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            snapshotObserver?.cancel()
            val cleanupFailures = mutableListOf<Throwable>()
            live?.let { session ->
                runCatching {
                    File(evidence, "$prefix-diagnostics.txt").writeText(session.diagnosticsSinceStart())
                    File(evidence, "$prefix-transcript.txt").writeText(session.transcriptText())
                    session.onMain { session.controller.setAppForeground(true) }
                }.exceptionOrNull()?.let(cleanupFailures::add)
            }
            activity?.let { runCatching { runOnMain { it.finish() } }.exceptionOrNull()?.let(cleanupFailures::add) }
            live?.let { runCatching { it.close() }.exceptionOrNull()?.let(cleanupFailures::add) }
            runCatching {
                remote(fixture, "tmux kill-session -t '=$target' 2>/dev/null || true")
                assertEquals("run-owned width fixture survived cleanup", "", remote(fixture, "tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
                    .lineSequence().filter { it == target }.joinToString("\n"))
            }.exceptionOrNull()?.let(cleanupFailures::add)
            cleanupFailures.forEach { primaryFailure?.addSuppressed(it) }
            if (primaryFailure == null && cleanupFailures.isNotEmpty()) throw cleanupFailures.first()
        }
    }

    /** Two actual devices' carriers stay attached throughout every take-back. */
    @Test
    fun liveMoshTmuxContinuationAlternatesOwnersWithoutStalling(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val target = fixture.renderLedgerSession.sanitizeTmuxTarget()
        val viewTarget = SharedTmuxCommands.moshViewSessionName(target)
        val token = UUID.randomUUID().toString().take(8)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        val metrics = File(evidence, "mosh-tmux-continuation.csv").apply {
            writeText("round,identity,settleMs,generation,columns,rows\n")
        }
        val sessions = mutableListOf<LiveController>()
        val deviceGrids = mutableMapOf<LiveController, Pair<Int, Int>>()
        val compact = instrumentation.targetContext.resources.configuration.smallestScreenWidthDp < 600
        val heightOnlyPeers = when (val argument = InstrumentationRegistry.getArguments().getString("heightOnlyPeers")) {
            null, "false" -> false
            "true" -> true
            else -> error("heightOnlyPeers must be true or false, received $argument")
        }
        val firstGrid = if (compact) 50 to 20 else 100 to 30
        val defaultSecondGrid = if (compact) 46 to 18 else 86 to 25
        val secondGrid = if (heightOnlyPeers) firstGrid.first to defaultSecondGrid.second else defaultSecondGrid
        File(evidence, "mosh-tmux-continuation-fixture.json").writeText(JSONObject()
            .put("heightOnlyPeers", heightOnlyPeers).put("compact", compact)
            .put("firstColumns", firstGrid.first).put("firstRows", firstGrid.second)
            .put("secondColumns", secondGrid.first).put("secondRows", secondGrid.second)
            .put("target", target).put("viewTarget", viewTarget).toString(2))
        val connected = mutableSetOf<LiveController>()
        val previousGenerations = mutableMapOf<LiveController, Long>()
        var activity: ComponentActivity? = null
        var displayed by mutableStateOf<LiveController?>(null)
        var primaryFailure: Throwable? = null
        fun quoteShell(value: String): String = "'" + value.replace("'", "'\"'\"'") + "'"

        suspend fun capture(stage: String) {
            val bitmap = instrumentation.uiAutomation.takeScreenshot()
            File(evidence, "mosh-tmux-continuation-$stage.png").outputStream().use {
                bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
            }
            bitmap.recycle()
        }

        suspend fun mount(session: LiveController) {
            session.onMain { displayed = session }
            awaitValue("continuation terminal layout") {
                session.onMain { true.takeIf { session.surface.view.isAttachedToWindow && session.surface.view.isShown } }
            }
            val (columns, rows) = requireNotNull(deviceGrids[session])
            awaitValue("continuation native grid ${columns}x$rows") {
                session.onMain {
                    session.surface.snapshotNonSecretState().takeIf { it.columns == columns && it.rows == rows }
                }
            }
            session.onMain { session.declareSingleSurfaces() }
        }

        suspend fun assertGeometry(columns: Int, rows: Int) {
            var observed = "none"
            try {
                awaitValue("continuation remote geometry ${columns}x$rows") {
                    observed = remote(fixture, "tmux display-message -p -t '=$target:0.0' '#{window_width}x#{window_height}'").trim()
                    observed.takeIf { it == "${columns}x$rows" }
                }
            } catch (failure: AssertionError) {
                throw AssertionError("${failure.message}; observed=$observed", failure)
            }
        }

        suspend fun assertStamp(session: LiveController, generation: Long) {
            val actual = remote(fixture,
                "tmux display-message -p -t '=$viewTarget:0.0' '#{@tessera_authority}'").trim()
            assertEquals("the remote view stamp must name the settled device and generation",
                SharedTmuxCommands.authorityStampValue(
                    session.tmuxDeviceIdentity.id, session.tmuxDeviceIdentity.displayName, generation,
                ), actual)
        }

        suspend fun backgroundTick(): Int? = Regex("BACKGROUND-$token-(\\d+)-\\d+")
            .findAll(remote(fixture, "tmux capture-pane -p -t '=$target:1.0'"))
            .maxOfOrNull { it.groupValues[1].toInt() }

        suspend fun typedMarker(session: LiveController, stage: String) {
            val (columns, rows) = requireNotNull(deviceGrids[session])
            awaitValue("continuation native/canvas grid ${columns}x$rows before $stage") {
                session.onMain {
                    val native = session.surface.snapshotNonSecretState()
                    val canvas = session.controller.moshCanvasSize.value
                    true.takeIf { native.columns == columns && native.rows == rows && canvas?.columns == columns && canvas.rows == rows }
                }
            }
            val marker = "CONTINUATION-$token-$stage"
            // The command line cannot contain the contiguous output marker:
            // terminal echo alone is not a successful input/painter receipt.
            session.onMain {
                session.surface.sendInput("printf 'CONTINUATION-%s-%s\\n' '$token' '$stage'\n".encodeToByteArray())
            }
            awaitValue("continuation typed marker $stage") {
                session.onMain { session.surface.snapshotText()?.visibleText?.takeIf { it.contains(marker) } }
            }
            assertTrue(
                "typed input did not reach the remote pane",
                remote(fixture, "tmux capture-pane -p -t '=$target:0.0'").contains(marker),
            )
        }

        suspend fun freezeReader(session: LiveController, stage: String) {
            // Each stage gets fresh, uniquely tagged rows. Otherwise repeated
            // bursts eventually bury the one initial row seed below this
            // bounded drag even though history presentation is correct.
            val ready = "CONTINUATION_HISTORY_READY_$stage"
            session.onMain {
                session.surface.sendInput(
                    ("for i in ${'$'}(seq 1 300); do printf 'CONTINUATION_ROW_%05d | $stage | 0123456789abcdef\\n' \"${'$'}i\"; " +
                        "if [ ${'$'}((i % 30)) -eq 0 ]; then sleep 0.05; fi; done; " +
                        "printf 'CONTINUATION_HISTORY_READY_%s\\n' '$stage'\n").encodeToByteArray(),
                )
            }
            awaitValue("continuation numbered rows $stage") {
                session.onMain { session.surface.snapshotText()?.visibleText?.takeIf { it.contains(ready) } }
            }
            // A slow real drag stops before release, so the freeze oracle has
            // no inertial motion that could explain a changing viewport.
            val geometry = session.onMain {
                val view = session.surface.view
                val location = IntArray(2)
                view.getLocationOnScreen(location)
                floatArrayOf(location[0] + view.width * .5f, location[1] + view.height * .25f, view.height * .35f)
            }
            val downTime = SystemClock.uptimeMillis()
            fun inject(action: Int, fraction: Float) {
                val event = MotionEvent.obtain(
                    downTime, SystemClock.uptimeMillis(), action,
                    geometry[0], geometry[1] + geometry[2] * fraction, 0,
                )
                event.source = InputDevice.SOURCE_TOUCHSCREEN
                try { check(instrumentation.uiAutomation.injectInputEvent(event, true)) } finally { event.recycle() }
            }
            inject(MotionEvent.ACTION_DOWN, 0f)
            for (step in 1..24) {
                delay(16)
                inject(MotionEvent.ACTION_MOVE, step / 24f)
            }
            delay(300)
            inject(MotionEvent.ACTION_UP, 1f)
            awaitFlickAtRest("continuation history reveal $stage", session)
            awaitValue("continuation history mounted $stage") {
                session.onMain { session.surface.view.topRow.takeIf { it < 0 } }
            }
            val held = session.onMain { session.viewportTextNow() }
            assertTrue("the reader did not reveal the numbered history", held.contains("CONTINUATION_ROW_"))
            val logOffset = session.diagnosticsSinceStart().length
            val burst = "CONTINUATION-BURST-$token-$stage"
            val burstCommand = "for i in 1 2 3 4 5 6 7 8; do printf '$burst-%s\\n' \"${'$'}i\"; done"
            remote(
                fixture,
                "tmux send-keys -t '=$target:0.0' -l ${quoteShell(burstCommand)}; " +
                    "tmux send-keys -t '=$target:0.0' Enter",
            )
            awaitValue("continuation natural output freezes history $stage") {
                session.diagnosticsSinceStart().drop(logOffset).takeIf {
                    it.contains("side-channel-frozen surface=live") ||
                        it.contains("side-channel-frozen-after-presentation surface=live")
                }
            }
            delay(400)
            assertEquals("natural Mosh output moved the frozen reader $stage", held, session.onMain { session.viewportTextNow() })
            capture("$stage-frozen")
            session.onMain {
                session.surface.view.topRow = 0
                session.controller.returnTmuxScrollbackToTail("live")
            }
            typedMarker(session, "$stage-tail")
        }

        try {
            remote(fixture, newSessionWithHistoryLimit(target, 4_000))
            // A second, unselected window produces enough output that a -CC
            // client receiving pane bytes would compete with claim responses.
            // Its process belongs to this exact run-owned window's lifetime.
            val backgroundCommand = "i=0; while [ \"${'$'}i\" -lt 1200 ]; do " +
                "i=${'$'}((i+1)); n=0; while [ \"${'$'}n\" -lt 20 ]; do n=${'$'}((n+1)); " +
                "printf 'BACKGROUND-$token-%s-%s\\n' \"${'$'}i\" \"${'$'}n\"; done; sleep 0.1; done"
            remote(
                fixture,
                "tmux new-window -d -t '=$target:1' ${quoteShell(backgroundCommand)}",
            )
            val first = createLiveController(
                fixture, target, TransportKinds.MOSH, TmuxDeviceIdentity("android-continuation-$token-a", "Continuation-A"),
            ).also(sessions::add)
            val second = createLiveController(
                fixture, target, TransportKinds.MOSH, TmuxDeviceIdentity("android-continuation-$token-b", "Continuation-B"),
            ).also(sessions::add)
            deviceGrids[first] = firstGrid
            deviceGrids[second] = secondGrid
            activity = instrumentation.startActivitySync(
                Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            ) as ComponentActivity
            first.onMain {
                activity.setContent {
                    displayed?.let { session ->
                        key(session.surface) {
                            Layout(
                                content = { AndroidView(factory = { session.surface.view }) },
                                modifier = Modifier.fillMaxSize().imePadding(),
                            ) { measurables, constraints ->
                                val (columns, rows) = requireNotNull(deviceGrids[session])
                                val metrics = session.surface.gridMetrics()
                                val width = metrics.pixelWidth(columns)
                                val height = metrics.pixelHeight(rows)
                                check(width <= constraints.maxWidth && height <= constraints.maxHeight) {
                                    "continuation native grid ${columns}x$rows exceeds device bounds"
                                }
                                val terminal = measurables.single().measure(Constraints.fixed(width, height))
                                layout(constraints.maxWidth, constraints.maxHeight) { terminal.place(0, 0) }
                            }
                            val history by session.controller.tmuxRenderHistory.collectAsState()
                            MoshPrimaryLiveHistoryController(
                                primaryTerminal = session.surface,
                                delivery = history["live"],
                                enabled = true,
                                onHistoryRequested = session.controller::requestTmuxScrollback,
                                onReturnedToLiveTail = session.controller::returnTmuxScrollbackToTail,
                                onHistoryDeliveryApplied = session.controller::acknowledgeTmuxRenderHistoryPresented,
                            )
                        }
                    }
                }
                displayed = first
            }
            mount(first)
            first.connectAndAwait()
            connected += first
            awaitValue("initial continuation owner snapshot") {
                first.controller.tmuxSnapshot.value?.takeIf { it.activeWindowId != null && it.activePaneId != null }
            }
            mount(first)
            val initial = awaitValue("initial continuation owner") {
                (first.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine)
                    ?.takeIf { !first.controller.tmuxReclaimInFlight.value }
            }
            previousGenerations[first] = initial.generation
            // The mounted Termux grid, native Mosh canvas and remote tmux
            // viewport must all agree before accepting actual typed output.
            first.onMain { first.controller.updateTmuxViewport(firstGrid.first, firstGrid.second) }
            assertGeometry(firstGrid.first, firstGrid.second)
            assertStamp(first, initial.generation)
            freezeReader(first, "before-continue")
            mount(second)
            val secondLogOffset = second.diagnosticsSinceStart().length
            second.connectAndAwait()
            connected += second
            awaitValue("continuation peer snapshot") {
                second.controller.tmuxSnapshot.value?.takeIf { it.activeWindowId != null && it.activePaneId != null }
            }
            second.onMain { second.declareSingleSurfaces() }
            val secondInitial = awaitValue("second device's show settles its claim") {
                (second.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine)
                    ?.takeIf { !second.controller.tmuxReclaimInFlight.value }
            }
            previousGenerations[second] = secondInitial.generation
            assertTrue("second connection has no accepted initial native frame receipt",
                second.diagnosticsSinceStart().drop(secondLogOffset).contains("event=repaintSucceeded"))
            // The second device's show claims (attach alone never would,
            // §6.9 R5). Publish this device's test viewport after bootstrap,
            // then alternate explicit take-backs beginning with the first
            // device, which must now have yielded.
            second.onMain { second.controller.updateTmuxViewport(secondGrid.first, secondGrid.second) }
            assertGeometry(secondGrid.first, secondGrid.second)
            assertStamp(second, secondInitial.generation)
            typedMarker(second, "initial-second")
            awaitValue("first carrier yields to fresh second owner") {
                (first.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Peer)
                    ?.takeIf { it.deviceId == second.tmuxDeviceIdentity.id }
            }
            val clients = remote(fixture, "tmux list-clients -t '=$viewTarget' -F '#{client_control_mode}|#{client_flags}'")
                .lineSequence().filter(String::isNotBlank).toList()
            val controls = clients.filter { it.startsWith("1|") }
            assertEquals("both real side channels must stay attached: $clients", 2, controls.size)
            assertEquals("both real Mosh painters must stay attached: $clients", 2, clients.count { it.startsWith("0|") })
            assertTrue("Mosh control clients must suppress unused pane bytes: $clients", controls.all { it.contains("no-output") })
            val backgroundBefore = awaitValue("continuation background output") { backgroundTick() }

            for ((index, owner) in listOf(first, second, first, second).withIndex()) {
                val round = index + 1
                val peer = if (owner === first) second else first
                val size = requireNotNull(deviceGrids[owner])
                mount(owner)
                assertEquals(
                    "round $round must begin with the other device owning the grid",
                    peer.tmuxDeviceIdentity.id,
                    (owner.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Peer)?.deviceId,
                )
                val logOffset = owner.diagnosticsSinceStart().length
                val previous = previousGenerations[owner] ?: 0L
                val started = SystemClock.uptimeMillis()
                owner.onMain { owner.controller.reclaimTmuxGridAuthority() }
                val settled = try {
                    withTimeout(3_000) {
                        while (true) {
                            val authority = owner.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine
                            if (authority != null && authority.generation > previous && !owner.controller.tmuxReclaimInFlight.value) {
                                return@withTimeout authority
                            }
                            delay(20)
                        }
                        error("unreachable")
                    }
                } catch (failure: TimeoutCancellationException) {
                    throw owner.withDiagnosticContext(AssertionError("continuation round $round did not settle within 3 s", failure))
                }
                val elapsed = SystemClock.uptimeMillis() - started
                assertTrue("continuation round $round took ${elapsed}ms", elapsed <= 3_000)
                previousGenerations[owner] = settled.generation
                val claimLog = owner.diagnosticsSinceStart().drop(logOffset)
                assertTrue("round $round has no accepted forced-frame receipt: $claimLog", claimLog.contains("event=repaintSucceeded"))
                assertFalse("round $round exceeded its presentation budget: $claimLog", claimLog.contains("tmux_authority_claim_slow"))
                awaitValue("other carrier yields after continuation round $round") {
                    (peer.controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Peer)
                        ?.takeIf { it.deviceId == owner.tmuxDeviceIdentity.id }
                }
                assertGeometry(size.first, size.second)
                assertStamp(owner, settled.generation)
                typedMarker(owner, "round-$round")
                capture("round-$round-live")
                freezeReader(owner, "round-$round")
                metrics.appendText("$round,${owner.tmuxDeviceIdentity.id},$elapsed,${settled.generation},${size.first},${size.second}\n")
            }
            awaitValue("background output progressed throughout continuation") {
                backgroundTick()?.takeIf { it > backgroundBefore }
            }
            assertTrue("both carriers must remain connected", sessions.all { it.controller.state.value is SshSessionUiState.Connected })
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_MOSH_TMUX_CONTINUATION_OK carriers=2 controls=2 rounds=4 bounded3s=1 " +
                    "forcedFrames=4 geometry=1 typedMarkers=1 naturalFrozenHistory=5 backgroundOutput=1 noOutput=1 " +
                    "heightOnlyPeers=$heightOnlyPeers first=${firstGrid.first}x${firstGrid.second} second=${secondGrid.first}x${secondGrid.second}",
            )
        } catch (failure: Throwable) {
            primaryFailure = failure
            throw failure
        } finally {
            val cleanupFailures = mutableListOf<Throwable>()
            sessions.forEachIndexed { index, session ->
                runCatching {
                    File(evidence, "mosh-tmux-continuation-${index + 1}-diagnostics.txt")
                        .writeText(session.diagnosticsSinceStart())
                    File(evidence, "mosh-tmux-continuation-${index + 1}-transcript.txt")
                        .writeText(session.transcriptText())
                }.exceptionOrNull()?.let(cleanupFailures::add)
            }
            activity?.let { runCatching { runOnMain { it.finish() } }.exceptionOrNull()?.let(cleanupFailures::add) }
            sessions.asReversed().forEach { session ->
                runCatching { session.close(awaitMoshCleanup = session in connected) }
                    .exceptionOrNull()?.let(cleanupFailures::add)
            }
            runCatching {
                remote(fixture, "tmux kill-session -t '=$viewTarget' 2>/dev/null || true; tmux kill-session -t '=$target' 2>/dev/null || true")
                assertEquals(
                    "run-owned continuation sessions survived cleanup",
                    "",
                    remote(fixture, "tmux list-sessions -F '#{session_name}' 2>/dev/null || true")
                        .lineSequence().filter { it == target || it == viewTarget }.joinToString("\n"),
                )
            }.exceptionOrNull()?.let(cleanupFailures::add)
            cleanupFailures.forEach { cleanup -> primaryFailure?.addSuppressed(cleanup) }
            if (primaryFailure == null && cleanupFailures.isNotEmpty()) throw cleanupFailures.first()
        }
    }

    /**
     * Exercise the session controller's actual renewable raw-Mosh route,
     * including the foreground boundary which used to leave a dead SSH
     * sidecar behind an otherwise healthy UDP terminal.
     */
    @Test
    fun liveRawMoshAgentReadRecoversAfterAuxiliarySshDrop(): Unit = runBlocking {
        assumeTrue("native Mosh is required for auxiliary-route recovery", JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val live = createLiveController(fixture, target = null, transport = TransportKinds.MOSH)
        var connected = false
        try {
            live.connectAndAwait()
            connected = true
            val endpoint = live.agentEndpoint()
            val binding = endpoint.binding.value
            assertEquals(AgentEndpointTransport.MOSH, binding.transport)
            val originalScope = (endpoint.processDiscoveryScope(binding) as AgentEndpointResult.Success).value
            assertTrue(originalScope is AgentProcessDiscoveryScope.RootProcess)
            val beforeProbe = endpoint.probeIntegration(binding, AgentIntegrationCommand.probeFromSharedCore())
            assertTrue("initial integration read failed: $beforeProbe", beforeProbe is AgentEndpointResult.Success)
            val beforeProcesses = endpoint.discoverProcesses(binding, AgentProcessDiscoveryCommands.command(originalScope))
            assertTrue("initial process read failed: $beforeProcesses", beforeProcesses is AgentEndpointResult.Success)

            val marker = "TESSERA-AGENT-RECOVERY-${UUID.randomUUID().toString().take(8)}"
            live.onMain {
                live.surface.sendInput(
                    ("n=0; while [ \"${'$'}n\" -lt 180 ]; do n=${'$'}((n+1)); " +
                        "printf '$marker-HEARTBEAT-%s\\n' \"${'$'}n\"; sleep 0.3; done\n").encodeToByteArray(),
                )
            }
            live.awaitHeartbeatAfter(marker, 0)
            val beforeDrop = live.latestHeartbeat(marker)
            val originalRoute = live.auxiliaryRoute()
            live.onMain { live.controller.setAppForeground(false) }
            // This object belongs solely to this generated controller. No
            // PID/account-wide kill, user session, or normal restore action
            // participates in the failure injection.
            withContext(Dispatchers.IO) { originalRoute.close() }
            assertFalse(originalRoute.isConnected)
            live.onMain { live.controller.setAppForeground(true) }
            live.awaitHeartbeatAfter(marker, beforeDrop)
            assertTrue(live.controller.state.value is SshSessionUiState.Connected)

            val recoveredProbe = withTimeout(30_000) {
                endpoint.probeIntegration(binding, AgentIntegrationCommand.probeFromSharedCore())
            }
            assertEquals("integration read must recover on demand", beforeProbe, recoveredProbe)
            live.awaitDiagnostic("mosh_agent_route_renewed")
            assertNotSame("the failed auxiliary SSH route must be replaced", originalRoute, live.auxiliaryRoute())
            assertSame("renewal must preserve the visible carrier's endpoint", endpoint, live.agentEndpoint())
            assertEquals(binding, endpoint.binding.value)
            assertEquals(originalScope, (endpoint.processDiscoveryScope(binding) as AgentEndpointResult.Success).value)
            val recoveredProcesses = endpoint.discoverProcesses(binding, AgentProcessDiscoveryCommands.command(originalScope))
            assertTrue("process inventory did not recover: $recoveredProcesses", recoveredProcesses is AgentEndpointResult.Success)
            assertTrue((recoveredProcesses as AgentEndpointResult.Success).value.processes.isNotEmpty())
            live.awaitHeartbeatAfter(marker, live.latestHeartbeat(marker))
            Log.i("TesseraNativeSsh", "TESSERA_ANDROID_AGENT_MOSH_RECOVERY_OK sameCarrier=1 udpProgress=1 foreground=1 renewedRoute=1 integration=1 processInventory=1")
        } finally {
            live.onMain {
                live.controller.setAppForeground(true)
                live.surface.sendInput(byteArrayOf(3))
            }
            live.close(awaitMoshCleanup = connected)
        }
    }

    /** Real injected gestures against the production Mosh history controller and live fixture. */
    @Test
    fun liveScrollingAcrossAllTransports(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val target = fixture.renderLedgerSession.sanitizeTmuxTarget()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        val metrics = StringBuilder("transport,first,second,afterInput\n")
        val testArguments = InstrumentationRegistry.getArguments()
        val onlyTransport = testArguments.getString("scrollTransport").orEmpty()
        require(onlyTransport in setOf("", "all", "ssh", "ssh-tmux", "mosh", "mosh-tmux")) {
            "Unknown scrollTransport: $onlyTransport"
        }
        val presentationDelay = testArguments.getString("historyPresentationDelayMs")?.toLong() ?: 1_500L
        require(presentationDelay >= 0)
        File(evidence, "presentation-delay-ms.txt").writeText(presentationDelay.toString())
        for (transport in listOf(TransportKinds.SSH, TransportKinds.MOSH)) {
            for (tmux in listOf(false, true)) {
                val label = "$transport${if (tmux) "-tmux" else ""}"
                if (onlyTransport.isNotEmpty() && onlyTransport != "all" && label != onlyTransport) continue
                var live: LiveController? = null
                var activity: ComponentActivity? = null
                try {
                    if (tmux) {
                        remote(fixture, "tmux new-session -d -s '$target' -c /tmp -x 100 -y 30")
                        // Start with mouse off to verify that Tessera enables it
                        // on attach. Primary finger swipes must still scroll
                        // local history while tmux tracks the mouse.
                        assertEquals(
                            "The fixture session must begin with mouse off",
                            "off",
                            // A flag option expands to 1/0 in a format; spell it as the option does.
                            remote(fixture, "tmux display-message -p -t '$target' '#{?mouse,on,off}'").trim(),
                        )
                    }
                    val session = createLiveController(fixture, target.takeIf { tmux }, transport)
                    live = session
                    activity = instrumentation.startActivitySync(
                        Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    ) as ComponentActivity
                    var placementPosition: Float? = null
                    var requestedAt = 0L
                    var visibleRequestedAt = 0L
                    val drawLatencies = mutableListOf<Long>()
                    val captureLatencies = mutableListOf<Long>()
                    session.onMain {
                        session.surface.view.viewTreeObserver.addOnDrawListener {
                            if (visibleRequestedAt > 0L && session.surface.view.topRow < 0 &&
                                !session.surface.view.isHistoryScrollPending) {
                                drawLatencies += SystemClock.uptimeMillis() - visibleRequestedAt
                                visibleRequestedAt = 0L
                                File(evidence, "$label-first-history-draw-ms.txt").writeText(drawLatencies.joinToString("\n"))
                            } else if (!session.surface.view.isHistoryScrollPending) {
                                // Refused/cancelled requests must not age into the next gesture's sample.
                                requestedAt = 0L
                                visibleRequestedAt = 0L
                            }
                        }
                        activity.setContent {
                            AndroidView(factory = { session.surface.view }, modifier = Modifier.fillMaxSize().imePadding())
                            val history by session.controller.tmuxRenderHistory.collectAsState()
                            if (transport == TransportKinds.MOSH && tmux) {
                                // Retain a real controller/capture/rebind, but delay presentation
                                // long enough that the first finger release precedes historyReady.
                                var presentedHistory by remember { mutableStateOf<TmuxRenderHistoryReady?>(null) }
                                LaunchedEffect(history["live"]) {
                                    if (history["live"] != null) delay(presentationDelay)
                                    presentedHistory = history["live"]
                                }
                                MoshPrimaryLiveHistoryController(
                                    primaryTerminal = session.surface, delivery = presentedHistory, enabled = true,
                                    onHistoryRequested = { surfaceId, points, inertial ->
                                        if (requestedAt == 0L) {
                                            requestedAt = SystemClock.uptimeMillis()
                                            if (session.surface.view.topRow == 0) visibleRequestedAt = requestedAt
                                        }
                                        session.controller.requestTmuxScrollback(surfaceId, points, inertial)
                                        if (!session.surface.view.isHistoryScrollPending) {
                                            requestedAt = 0L
                                            visibleRequestedAt = 0L
                                        }
                                    },
                                    onReturnedToLiveTail = { surfaceId ->
                                        requestedAt = 0L
                                        visibleRequestedAt = 0L
                                        session.controller.returnTmuxScrollbackToTail(surfaceId)
                                    },
                                    onHistoryDeliveryApplied = { surfaceId, token ->
                                        placementPosition = session.surface.view.scrollPositionPixels
                                        val samples = mutableListOf<String>()
                                        samples += "${SystemClock.uptimeMillis()},${session.surface.view.scrollPositionPixels}"
                                        val callback = object : android.view.Choreographer.FrameCallback {
                                            override fun doFrame(frameTimeNanos: Long) {
                                                samples += "${SystemClock.uptimeMillis()},${session.surface.view.scrollPositionPixels}"
                                                if (samples.size < 31) {
                                                    android.view.Choreographer.getInstance().postFrameCallback(this)
                                                } else {
                                                    File(evidence, "$label-delivery-$token-frames.csv")
                                                        .writeText("uptimeMs,positionPixels\n" + samples.joinToString("\n"))
                                                }
                                            }
                                        }
                                        android.view.Choreographer.getInstance().postFrameCallback(callback)
                                        captureLatencies += SystemClock.uptimeMillis() - requestedAt
                                        requestedAt = 0L
                                        File(evidence, "$label-request-to-placement-ms.txt").writeText(captureLatencies.joinToString("\n"))
                                        session.controller.acknowledgeTmuxRenderHistoryPresented(surfaceId, token)
                                    },
                                )
                            }
                        }
                    }
                    session.connectAndAwait()
                    if (tmux) {
                        awaitValue("$label pane hydration") { session.controller.tmuxSnapshot.value?.activePaneId }
                        session.onMain { session.declareSingleSurfaces() }
                        assertSessionGroupMouseEnabled(fixture, target, mosh = transport == TransportKinds.MOSH)
                        session.awaitTypingAdmitted(label)
                    }
                    delay(1_000)
                    // Throttled output lets plain Mosh's SSP painter observe real screen scrolls.
                    val command = "for i in ${'$'}(seq 1 400); do printf '%04d | $label HISTORY |\\r\\n' \"${'$'}i\"; " +
                        "if [ ${'$'}((i % 10)) -eq 0 ]; then sleep 0.05; fi; done; " +
                        "(for i in ${'$'}(seq 1 200); do printf '\\0337\\033[1;1HLIVE_TICK_%04d\\0338' \"${'$'}i\" || exit; sleep 0.1; done) & " +
                        "SCROLL_HEARTBEAT=${'$'}!; echo SCROLL_READY\n"
                    session.onMain { session.surface.sendInput(command.encodeToByteArray()) }
                    awaitValue("$label numbered history ready") {
                        session.onMain { session.surface.snapshotText()?.visibleText?.takeIf { it.contains("SCROLL_READY") && it.contains("0400") } }
                    }
                    delay(600)
                    suspend fun capture(stage: String) {
                        delay(100)
                        val bitmap = instrumentation.uiAutomation.takeScreenshot()
                        File(evidence, "$label-$stage.png").outputStream().use {
                            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                        }
                        bitmap.recycle()
                    }
                    suspend fun swipe(reverse: Boolean = false) {
                        val geometry = session.onMain {
                            val view = session.surface.view
                            val location = IntArray(2); view.getLocationOnScreen(location)
                            floatArrayOf(location[0] + view.width * .5f,
                                location[1] + view.height * (if (reverse) .85f else .25f),
                                view.height * (if (reverse) -.75f else .35f))
                        }
                        val down = SystemClock.uptimeMillis()
                        // Events carry their planned times, 16 ms apart, not
                        // the time each was injected. Synchronous injection on
                        // a loaded emulator outlasts the step: wall-clock stamps
                        // slowed the flick about threefold, and with it the
                        // release velocity, so whether a fling ran at all (and
                        // outlived the delayed capture) followed host load.
                        // The last column records when each event really went in.
                        fun event(action: Int, fraction: Float, plannedMillis: Long) {
                            val eventTime = down + plannedMillis
                            val e = MotionEvent.obtain(down, eventTime, action,
                                geometry[0], geometry[1] + geometry[2] * fraction, 0)
                            e.source = InputDevice.SOURCE_TOUCHSCREEN
                            File(evidence, "$label-touch-events.csv")
                                .appendText("$down,$action,$eventTime,$fraction,${SystemClock.uptimeMillis()}\n")
                            check(instrumentation.uiAutomation.injectInputEvent(e, true))
                            e.recycle()
                        }
                        event(MotionEvent.ACTION_DOWN, 0f, 0L)
                        for (step in 1..12) { delay(16); event(MotionEvent.ACTION_MOVE, step / 12f, step * 16L) }
                        event(MotionEvent.ACTION_UP, 1f, 12 * 16L)
                        if (transport == TransportKinds.MOSH && tmux) {
                            awaitValue("$label pending history presented") {
                                session.onMain { true.takeIf { !session.surface.view.isHistoryScrollPending } }
                            }
                        }
                        delay(1_000)
                    }
                    // Match a phone's first gesture after dismissing the IME,
                    // with the remote pane still emitting cursor-only redraws.
                    session.onMain { session.surface.requestSoftwareKeyboard() }
                    awaitValue("$label keyboard shown") {
                        session.onMain { true.takeIf {
                            ViewCompat.getRootWindowInsets(session.surface.view)?.isVisible(WindowInsetsCompat.Type.ime()) == true
                        } }
                    }
                    capture("keyboard")
                    session.onMain { session.surface.toggleSoftwareKeyboard() }
                    awaitValue("$label keyboard hidden") {
                        session.onMain { true.takeIf {
                            ViewCompat.getRootWindowInsets(session.surface.view)?.isVisible(WindowInsetsCompat.Type.ime()) == false
                        } }
                    }
                    capture("before")
                    swipe(); capture("first")
                    val first = session.onMain { session.surface.view.scrollPositionPixels }
                    if (transport == TransportKinds.MOSH && tmux && presentationDelay >= 1_000L) {
                        // Only the delayed-presentation lane guarantees that capture
                        // arrives after release. The latency lane measures first draw.
                        val placed = requireNotNull(placementPosition)
                        assertTrue("Live Mosh release must continue after delayed capture: placed=$placed first=$first", first < placed - 20)
                    }
                    repeat(4) {
                        if (session.onMain { session.surface.view.topRow < 0 }) swipe(reverse = true)
                    }
                    assertEquals("Reverse must reach live tail", 0, session.onMain { session.surface.view.topRow })
                    capture("tail")
                    swipe(); capture("second")
                    val second = session.onMain { session.surface.view.scrollPositionPixels }
                    assertTrue("$label first scroll must move: $first", first < -100)
                    assertTrue("$label re-entry after tail must move: first=$first second=$second", second < -100)
                    session.onMain { session.surface.sendInput("kill ${'$'}SCROLL_HEARTBEAT; wait ${'$'}SCROLL_HEARTBEAT 2>/dev/null; echo AFTER_INPUT\n".encodeToByteArray()) }
                    delay(800)
                    swipe(); capture("after-input")
                    val afterInput = session.onMain { session.surface.view.scrollPositionPixels }
                    assertTrue("$label scroll after typing must move: $afterInput", afterInput < -100)
                    if (tmux) {
                        val mode = remote(fixture, "tmux display-message -p -t '$target:0.0' '#{pane_in_mode}'").trim()
                        assertEquals("Primary scrolling must stay out of remote copy mode", "0", mode)
                    }
                    if (transport == TransportKinds.MOSH && tmux) {
                        // Exhaust the immutable page; a refused deepen must not absorb reversal.
                        session.onMain { session.surface.view.scrollHistoryRows(-100_000) }
                        awaitValue("Deep history presented") {
                            session.onMain { true.takeIf { !session.surface.view.isHistoryScrollPending } }
                        }
                        session.onMain { session.surface.view.scrollHistoryRows(-100_000) }
                        awaitValue("Exhausted history request ended") {
                            session.onMain { true.takeIf { !session.surface.view.isHistoryScrollPending } }
                        }
                        assertFalse("Refused/frozen/full-depth page must release pending motion", session.onMain { session.surface.view.isHistoryScrollPending })
                        val edge = session.onMain { session.surface.view.scrollPositionPixels }
                        session.onMain { session.surface.view.scrollHistoryRows(10) }
                        delay(100)
                        assertTrue("Reversing away from oldest row must move", session.onMain { session.surface.view.scrollPositionPixels } > edge)
                        capture("exhausted-reverse")
                    }
                    metrics.append("$label,$first,$second,$afterInput\n")
                    File(evidence, "positions.csv").writeText(metrics.toString())
                } finally {
                    activity?.let { runOnMain { it.finish() } }
                    live?.close(awaitMoshCleanup = transport == TransportKinds.MOSH)
                    if (tmux) remote(fixture, "tmux kill-session -t '$target' 2>/dev/null || true")
                }
            }
        }
    }

    /** Finger flings must deepen a frozen Mosh page without losing its numbered rows. */
    @Test
    fun liveMoshTmuxFrozenReaderFlicksToOldestRow(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val target = fixture.renderLedgerSession.sanitizeTmuxTarget()
        val marker = "tessera-frozen-${UUID.randomUUID()}"
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        val prefix = "mosh-tmux-frozen-reader"
        val ranges = File(evidence, "$prefix-visible-rows.csv").apply {
            writeText("stage,flick,topRow,first,last,count,tick\n")
        }
        val rowPattern = Regex("ROW_(\\d{5})")
        val tickPattern = Regex("LIVE_TICK_(\\d{5})")
        fun visibleRows(text: String): List<Int> = rowPattern.findAll(text)
            .map { it.groupValues[1].toInt() }.toList()
        fun latestTick(text: String): Int? = tickPattern.findAll(text)
            .map { it.groupValues[1].toInt() }.maxOrNull()

        var live: LiveController? = null
        var activity: ComponentActivity? = null
        var connected = false
        var tmuxCreated = false
        try {
            remote(fixture, "tmux new-session -d -s '$target' -c /tmp -x 100 -y 30")
            tmuxCreated = true
            assertEquals(
                "The fixture session must begin with mouse off",
                "off",
                // A flag option expands to 1/0 in a format; spell it as the option does.
                remote(fixture, "tmux display-message -p -t '$target' '#{?mouse,on,off}'").trim(),
            )
            val session = createLiveController(fixture, target, TransportKinds.MOSH)
            live = session
            activity = instrumentation.startActivitySync(
                Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            ) as ComponentActivity
            session.onMain {
                activity.setContent {
                    AndroidView(factory = { session.surface.view }, modifier = Modifier.fillMaxSize().imePadding())
                    val history by session.controller.tmuxRenderHistory.collectAsState()
                    MoshPrimaryLiveHistoryController(
                        primaryTerminal = session.surface,
                        delivery = history["live"],
                        enabled = true,
                        onHistoryRequested = session.controller::requestTmuxScrollback,
                        onReturnedToLiveTail = session.controller::returnTmuxScrollbackToTail,
                        onHistoryDeliveryApplied = { surfaceId, token ->
                            session.controller.acknowledgeTmuxRenderHistoryPresented(surfaceId, token)
                        },
                    )
                }
            }
            // As in production, where program status defaults on: the side
            // channel then streams pane output, which the history reader ignores.
            session.onMain { session.controller.setProgramStatusEnabled(true) }
            session.connectAndAwait()
            connected = true
            awaitValue("frozen reader pane hydration") { session.controller.tmuxSnapshot.value?.activePaneId }
            session.onMain { session.declareSingleSurfaces() }
            assertSessionGroupMouseEnabled(fixture, target, mosh = true)
            awaitValue("frozen reader terminal layout") {
                session.onMain { true.takeIf { session.surface.view.width > 0 && session.surface.view.height > 0 } }
            }
            session.awaitTypingAdmitted("frozen reader")

            // The marker is bash's $0, so the background process has a unique
            // command line for target-scoped cleanup even if terminal input fails.
            // Once the test creates $burst, the next ticks end their lines, like
            // Claude Code finishing messages under a reader of history.
            val burst = "/tmp/$marker.burst"
            val burstLines = 8
            val command = "for i in ${'$'}(seq 1 1500); do " +
                "printf 'ROW_%05d | 0123456789abcdef\\r\\n' \"${'$'}i\"; " +
                "if [ ${'$'}((i % 50)) -eq 0 ]; then sleep 0.05; fi; done; " +
                "(bash -c 'b=0; for i in ${'$'}(seq 1 1200); do " +
                "printf \"\\rLIVE_TICK_%05d\" \"${'$'}i\" || exit; " +
                "if [ -e $burst ] && [ ${'$'}b -lt $burstLines ]; then printf \"\\r\\n\"; b=${'$'}((b + 1)); " +
                "[ ${'$'}b -eq $burstLines ] && touch $burst.done; fi; sleep 0.5; done' '$marker') & " +
                "FROZEN_READER_HEARTBEAT=${'$'}!; echo FROZEN_READER_READY\n"
            session.onMain { session.surface.sendInput(command.encodeToByteArray()) }
            awaitValue("1500 rows and live heartbeat") {
                session.onMain { session.surface.snapshotText()?.visibleText }
                    ?.takeIf { (it.contains("ROW_01500") || it.contains("FROZEN_READER_READY")) && latestTick(it) != null }
            }

            suspend fun capture(stage: String) {
                val bitmap = instrumentation.uiAutomation.takeScreenshot()
                File(evidence, "$prefix-$stage.png").outputStream().use {
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
            }

            // slow: a drag that stops before release, so nothing flings.
            suspend fun flick(intoHistory: Boolean, slow: Boolean = false) {
                val geometry = session.onMain {
                    val view = session.surface.view
                    val location = IntArray(2)
                    view.getLocationOnScreen(location)
                    floatArrayOf(
                        location[0] + view.width * .5f,
                        location[1] + view.height * (if (intoHistory) .2f else .8f),
                        view.height * (if (intoHistory) .6f else -.6f) * (if (slow) .5f else 1f),
                    )
                }
                val downTime = SystemClock.uptimeMillis()
                fun inject(action: Int, fraction: Float) {
                    val event = MotionEvent.obtain(
                        downTime, SystemClock.uptimeMillis(), action,
                        geometry[0], geometry[1] + geometry[2] * fraction, 0,
                    )
                    event.source = InputDevice.SOURCE_TOUCHSCREEN
                    try {
                        check(instrumentation.uiAutomation.injectInputEvent(event, true))
                    } finally {
                        event.recycle()
                    }
                }
                val steps = if (slow) 24 else 8
                inject(MotionEvent.ACTION_DOWN, 0f)
                for (step in 1..steps) {
                    delay(if (slow) 16 else 8)
                    inject(MotionEvent.ACTION_MOVE, step.toFloat() / steps)
                }
                delay(if (slow) 300 else 8)
                inject(MotionEvent.ACTION_UP, 1f)
                awaitFlickAtRest("frozen reader flick at rest", session)
            }

            suspend fun observe(stage: String, flick: Int): Pair<List<Int>, Int> {
                val (text, topRow, screenRows) = session.onMain {
                    Triple(session.viewportTextNow(), session.surface.view.topRow, session.surface.view.mEmulator.mRows)
                }
                val rows = visibleRows(text)
                assertTrue("$stage flick $flick has no visible numbered rows: ${text.takeLast(512)}", rows.isNotEmpty())
                // A screenful of rows: below the last fixture row come only the
                // ready line, the burst's lines and the heartbeat's.
                assertTrue(
                    "$stage flick $flick shows ${rows.size} of $screenRows rows: $rows",
                    if (rows.last() == 1500) rows.size >= screenRows - (burstLines + 4) else rows.size * 5 >= screenRows * 4,
                )
                if (rows.size >= 2) {
                    assertTrue(
                        "$stage flick $flick has gaps, duplicates or disorder: $rows",
                        rows.zipWithNext().all { (first, second) -> second == first + 1 },
                    )
                }
                ranges.appendText(
                    "$stage,$flick,$topRow,${rows.first()},${rows.last()},${rows.size},${latestTick(text) ?: ""}\n",
                )
                return rows to topRow
            }

            suspend fun settledRows(stage: String, flick: Int): List<Int> {
                var rows = observe(stage, flick).first
                repeat(16) {
                    delay(300)
                    val next = observe(stage, flick).first
                    if (next == rows) return next
                    rows = next
                }
                return rows
            }

            capture("start")
            val start = observe("start", 0).first

            // A slow drag reveals the first history page. The pane then prints
            // new lines while the reader is in history: the reader stays put,
            // and the flicks below must still deepen the page those lines froze.
            flick(intoHistory = true, slow = true)
            val held = settledRows("revealed", 0)
            assertTrue("A slow drag did not reveal history: $start -> $held", held.last() < start.last())
            remote(fixture, "touch '$burst'")
            awaitValue("streamed burst printed") {
                remote(fixture, "test -e '$burst.done' && echo done || true").trim().takeIf { it == "done" }
            }
            delay(700)
            var lastRows = observe("burst", 0).first
            assertEquals("Output while reading history moved the reader", held, lastRows)
            var lowest = lastRows.first()
            var stalled = 0
            for (flick in 1..120) {
                if (lowest == 1) break
                flick(intoHistory = true)
                lastRows = observe("history", flick).first
                val currentLowest = lastRows.first()
                if (currentLowest < lowest) {
                    lowest = currentLowest
                    stalled = 0
                } else {
                    stalled++
                }
                assertTrue("No progress toward oldest row for 8 flicks; last visible rows=$lastRows", stalled < 8)
            }
            assertEquals("Did not reach oldest row after 120 flicks; last visible rows=$lastRows", 1, lowest)
            assertTrue(
                "Oldest viewport has gaps, duplicates or disorder: $lastRows",
                lastRows.zipWithNext().all { (first, second) -> second == first + 1 },
            )
            capture("oldest")
            // Output froze the page, and the deeper history was aligned to the
            // whole page: exactly the burst's rows were newer than it.
            val anchoredDeepen = "render-ledger side-channel-anchored-deepen surface=live " +
                "dropped=$burstLines expected=$burstLines anchor=page"
            session.awaitDiagnostic(anchoredDeepen)
            val ledgerLog = session.diagnosticsSinceStart()
            val frozenAt = Regex("render-ledger side-channel-frozen(-after-presentation)? surface=live")
                .find(ledgerLog)?.range?.first
            assertTrue(
                "Output never froze the page before its deepen",
                frozenAt != null && frozenAt < ledgerLog.indexOf(anchoredDeepen),
            )
            assertFalse(
                "The frozen page's rows were lost from, or ambiguous in, the deeper history",
                ledgerLog.contains("frozen-anchor-lost") || ledgerLog.contains("frozen-anchor-ambiguous"),
            )

            var returnedToTail = session.onMain { session.surface.view.topRow == 0 }
            for (flick in 1..120) {
                if (returnedToTail) break
                flick(intoHistory = false)
                val observed = observe("tail", flick)
                lastRows = observed.first
                returnedToTail = observed.second == 0
            }
            assertTrue("Did not return to live tail after 120 flicks; last visible rows=$lastRows", returnedToTail)
            val tickAtTail = awaitValue("heartbeat visible at live tail") {
                session.onMain { session.surface.snapshotText()?.visibleText?.let(::latestTick) }
            }
            try {
                withTimeout(4_000) {
                    while (true) {
                        val tick = session.onMain { session.surface.snapshotText()?.visibleText?.let(::latestTick) }
                        if (tick != null && tick > tickAtTail) break
                        delay(POLL_MILLISECONDS)
                    }
                }
            } catch (failure: TimeoutCancellationException) {
                throw AssertionError("Heartbeat did not advance at live tail within 4 s; last tick=$tickAtTail", failure)
            }
            capture("tail")
            assertEquals(
                "Primary scrolling must stay out of remote copy mode",
                "0",
                remote(fixture, "tmux display-message -p -t '$target:0.0' '#{pane_in_mode}'").trim(),
            )
        } finally {
            activity?.let { runCatching { runOnMain { it.finish() } } }
            if (connected) {
                runCatching {
                    live?.let { session ->
                        session.onMain {
                            session.surface.sendInput("kill ${'$'}FROZEN_READER_HEARTBEAT 2>/dev/null\n".encodeToByteArray())
                        }
                    }
                }
            }
            // A bracketed first character matches the child marker, but not
            // this pkill command's own shell command line.
            val pkillPattern = "[${marker.first()}]${marker.drop(1)}"
            runCatching { remote(fixture, "pkill -f '$pkillPattern' 2>/dev/null || true") }
            runCatching { remote(fixture, "rm -f '/tmp/$marker.burst' '/tmp/$marker.burst.done'") }
            runCatching { live?.close(awaitMoshCleanup = connected) }
            if (tmuxCreated) runCatching { remote(fixture, "tmux kill-session -t '$target' 2>/dev/null || true") }
        }
    }

    /**
     * An offline real Codex TUI stays alive across foreground, transport loss,
     * and a second instrumentation process. The runner force-stops this
     * disposable app between initial and restore, leaving both tmux panes alive.
     */
    @Test
    fun liveCodexMouseSurvivesLifecycleOnBothTransports(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        // Only run-android-live-scroll-tests.sh provisions the offline Codex
        // binary, and it refuses to start without one and checks this case's
        // evidence. Elsewhere (the native gate) the case does not apply.
        val root = fixture.codexFixtureRoot
            .also { assumeTrue("requires the offline Codex fixture from run-android-live-scroll-tests.sh", it != null) }!!
        require(Regex("/tmp/tessera-codex-[A-Za-z0-9_-]+").matches(root))
        val phase = InstrumentationRegistry.getArguments().getString("codexPhase") ?: "initial"
        require(phase in setOf("initial", "restore"))
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        val metrics = File(evidence, "codex-$phase.csv").apply {
            writeText("transport,stage,first,last,mouse,owner\n")
        }
        File(evidence, "codex-$phase-process.txt").writeText(android.os.Process.myPid().toString())
        fun visibleRows(text: String): List<Int> = Regex("ROW_(\\d{5})").findAll(text)
            .map { it.groupValues[1].toInt() }.distinct().toList()
        for (transport in listOf(TransportKinds.SSH, TransportKinds.MOSH)) {
            val target = "${fixture.renderLedgerSession}-$transport".sanitizeTmuxTarget()
            val label = "$transport-codex-$phase"
            var live: LiveController? = null
            var activity: ComponentActivity? = null
            var connected = false
            var succeeded = false
            try {
                if (phase == "initial") {
                    remote(fixture, "python3 '$root/seed.py' '$root/$target' >/dev/null; " +
                        "ln -s '$root/codex-x86_64-unknown-linux-musl' '$root/$target/codex-x86_64-unknown-linux-musl'")
                    remote(fixture, "tmux new-session -d -s '$target' -c /tmp -x 100 -y 30; tmux set-option -t '$target' mouse off")
                }
                val session = createLiveController(
                    fixture, target, transport,
                    // An app restart retains its install identity. A fresh
                    // random identity would instead be a different device,
                    // correctly refused input while the old owner is stamped.
                    tmuxDeviceIdentity = TmuxDeviceIdentity("codex-scroll-${fixture.token}-$transport", "Android-Codex-fixture"),
                )
                live = session
                activity = instrumentation.startActivitySync(
                    Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                ) as ComponentActivity
                session.onMain {
                    activity.setContent {
                        AndroidView(factory = { session.surface.view }, modifier = Modifier.fillMaxSize().imePadding())
                    }
                }
                session.connectAndAwait()
                connected = true
                awaitValue("$label pane hydration") { session.controller.tmuxSnapshot.value?.activePaneId }
                session.onMain { session.declareSingleSurfaces() }
                assertSessionGroupMouseEnabled(fixture, target, mosh = transport == TransportKinds.MOSH)
                session.awaitTypingAdmitted(label)
                if (phase == "initial") {
                    session.onMain { session.surface.sendInput("python3 '$root/$target/run.py'\n".encodeToByteArray()) }
                    awaitValue("$label real Codex all-motion mode") {
                        remote(fixture, "tmux display-message -p -t '$target:0.0' '#{alternate_on}|#{mouse_standard_flag}|#{mouse_button_flag}|#{mouse_all_flag}|#{mouse_sgr_flag}'")
                            .trim().takeIf { it == "1|0|0|1|1" }
                    }
                    awaitValue("$label Codex transcript") {
                        session.onMain { session.viewportTextNow().takeIf {
                            it.contains("ROW_00300") && it.contains("Ask Codex to do anything")
                        } }
                    }
                    delay(500)
                    session.onMain { session.surface.sendInput("KEEP MY DRAFT".encodeToByteArray()) }
                }
                if (phase == "initial") {
                    remote(fixture, "tmux display-message -p -t '$target:0.0' '#{pane_pid}' > '$root/$target-pane.pid'")
                }
                val panePID = remote(fixture, "cat '$root/$target-pane.pid'").trim()

                suspend fun observe(stage: String): List<Int> {
                    val text = awaitValue("$label $stage draft and transcript") {
                        session.onMain { session.viewportTextNow() }
                            .takeIf { it.contains("KEEP MY DRAFT") && visibleRows(it).isNotEmpty() }
                    }
                    val rows = visibleRows(text)
                    val (mouse, owner) = session.onMain {
                        session.surface.view.mEmulator.isMouseTrackingActive to session.surface.boundOwner
                    }
                    assertTrue("$label $stage lost native mouse capture", mouse)
                    assertEquals("$label $stage restarted the remote pane", panePID,
                        remote(fixture, "tmux display-message -p -t '$target:0.0' '#{pane_pid}'").trim())
                    assertEquals("$label $stage changed Codex's mouse request", "1|0|0|1|1",
                        remote(fixture, "tmux display-message -p -t '$target:0.0' '#{alternate_on}|#{mouse_standard_flag}|#{mouse_button_flag}|#{mouse_all_flag}|#{mouse_sgr_flag}'").trim())
                    assertEquals("$label $stage entered tmux copy mode", "0",
                        remote(fixture, "tmux display-message -p -t '$target:0.0' '#{pane_in_mode}'").trim())
                    val csvOwner = owner.toString().replace("\"", "\"\"")
                    metrics.appendText("$transport,$stage,${rows.first()},${rows.last()},$mouse,\"$csvOwner\"\n")
                    File(evidence, "$label-$stage.txt").writeText(text)
                    val bitmap = instrumentation.uiAutomation.takeScreenshot()
                    File(evidence, "$label-$stage.png").outputStream().use {
                        bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                    }
                    bitmap.recycle()
                    return rows
                }

                suspend fun swipe(intoHistory: Boolean) {
                    val geometry = session.onMain {
                        val view = session.surface.view
                        val location = IntArray(2); view.getLocationOnScreen(location)
                        floatArrayOf(location[0] + view.width * .5f, location[1] + view.height * .25f, view.height * .4f)
                    }
                    val direction = if (intoHistory) 1f else -1f
                    val start = geometry[1] + if (intoHistory) 0f else geometry[2]
                    val down = SystemClock.uptimeMillis()
                    fun inject(action: Int, fraction: Float) {
                        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
                            geometry[0], start + direction * geometry[2] * fraction, 0)
                        event.source = InputDevice.SOURCE_TOUCHSCREEN
                        try { check(instrumentation.uiAutomation.injectInputEvent(event, true)) }
                        finally { event.recycle() }
                    }
                    inject(MotionEvent.ACTION_DOWN, 0f)
                    for (step in 1..12) {
                        delay(16)
                        inject(MotionEvent.ACTION_MOVE, step / 12f)
                    }
                    delay(150)
                    inject(MotionEvent.ACTION_UP, 1f)
                    delay(300)
                }

                suspend fun assertScroll(stage: String) {
                    val before = observe("$stage-before")
                    swipe(intoHistory = true)
                    awaitValue("$label $stage scrolls older Codex rows") {
                        session.onMain { visibleRows(session.viewportTextNow()) }
                            .takeIf { it.isNotEmpty() && it.last() < before.last() }
                    }
                    val older = observe("$stage-up")
                    swipe(intoHistory = false)
                    awaitValue("$label $stage scrolls newer Codex rows") {
                        session.onMain { visibleRows(session.viewportTextNow()) }
                            .takeIf { it.isNotEmpty() && it.last() > older.last() }
                    }
                    observe("$stage-down")
                }

                assertScroll(if (phase == "initial") "fresh" else "app-restart")
                session.onMain { session.controller.setAppForeground(false) }
                delay(600)
                session.onMain { session.controller.setAppForeground(true) }
                delay(500)
                assertScroll("foreground")
                if (phase == "initial") {
                    val owner = session.onMain { session.surface.boundOwner }
                    val beforeLog = session.diagnosticsSinceStart().length
                    dropFixtureTransport(fixture, if (transport == TransportKinds.MOSH)
                        SharedTmuxCommands.moshViewSessionName(target) else target)
                    awaitValue("$label transport recovery observed") {
                        session.diagnosticsSinceStart().drop(beforeLog).takeIf {
                            it.contains(if (transport == TransportKinds.MOSH) "mosh_tmux_control_retry" else "session_reconnect_scheduled")
                        }
                    }
                    awaitValue("$label recovered pane hydration") {
                        session.controller.tmuxSnapshot.value?.takeIf {
                            it.activePaneId != null && session.controller.state.value is SshSessionUiState.Connected
                        }
                    }
                    // Mirror the screen's declaration after the new runtime
                    // publishes its snapshot; AndroidView alone does not own it.
                    session.onMain { session.declareSingleSurfaces() }
                    awaitValue("$label new render owner after reconnect") {
                        session.onMain { session.surface.boundOwner }
                            ?.takeIf { it != owner && session.controller.state.value is SshSessionUiState.Connected }
                    }
                    assertScroll("reconnect")
                }
                succeeded = true
            } catch (failure: AssertionError) {
                File(evidence, "$label-failure.txt").writeText(live?.diagnosticsSinceStart().orEmpty())
                throw live?.withDiagnosticContext(failure) ?: failure
            } finally {
                activity?.let { runOnMain { it.finish() } }
                live?.close(awaitMoshCleanup = connected && transport == TransportKinds.MOSH)
                // A successful initial phase intentionally leaves Codex alive
                // for the fresh process. The runner also owns exact cleanup.
                if (phase == "restore" || !succeeded) {
                    val view = SharedTmuxCommands.moshViewSessionName(target)
                    remote(fixture, "tmux kill-session -t '=$view' 2>/dev/null || true; tmux kill-session -t '=$target' 2>/dev/null || true")
                }
            }
        }
    }

    /** A program that, like Codex, enables wheel capture only when tmux enables mouse input. */
    @Test
    fun liveTmuxMousePolicyEnablesFullScreenWheelOnBothTransports(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val target = fixture.renderLedgerSession.sanitizeTmuxTarget()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        // Keep a server alive between transports and verify an unrelated
        // session retains its mouse preference.
        // The run token lets the lane's cleanup prove and remove this session
        // when the process dies before its own finally.
        val control = "tessera-mouse-control-${fixture.token}-${SystemClock.uptimeMillis()}".sanitizeTmuxTarget()
        remote(fixture, "tmux new-session -d -s '$control'; tmux set-option -t '$control' mouse off")
        try {
            val globalMouse = remote(fixture, "tmux show-options -gv mouse").trim()
            for (transport in listOf(TransportKinds.SSH, TransportKinds.MOSH)) {
                val label = "$transport-tmux-mouse-policy"
                val report = "/tmp/$target-$label.json"
                var live: LiveController? = null
                var activity: ComponentActivity? = null
                try {
                    remote(fixture, "tmux new-session -d -s '$target' -c /tmp -x 100 -y 30; tmux set-option -t '$target' mouse off")
                    val session = createLiveController(fixture, target, transport)
                    live = session
                    activity = instrumentation.startActivitySync(
                        Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    ) as ComponentActivity
                    session.onMain {
                        activity.setContent {
                            AndroidView(factory = { session.surface.view }, modifier = Modifier.fillMaxSize().imePadding())
                        }
                    }
                    session.connectAndAwait()
                    awaitValue("$label pane hydration") { session.controller.tmuxSnapshot.value?.activePaneId }
                    session.onMain { session.declareSingleSurfaces() }
                    session.awaitTypingAdmitted(label)
                    // Probe using TMUX_PANE inside the work session, as Codex does.
                    // Checking only mosh's grouped view would miss an owner left off.
                    val command = "if [ \"${'$'}(tmux display-message -p -t \"${'$'}TMUX_PANE\" '#{mouse}')\" = 1 ]; " +
                        "then TESSERA_MOUSE_CAPTURE=--mouse; else TESSERA_MOUSE_CAPTURE=; fi; " +
                        "/usr/local/bin/tessera-fixture-probe capture --alt-screen ${'$'}TESSERA_MOUSE_CAPTURE " +
                        "--bytes 65536 --timeout 12 --output '$report'\n"
                    session.onMain { session.surface.sendInput(command.encodeToByteArray()) }
                    try {
                        awaitValue("$label alternate screen") {
                            remote(fixture, "tmux display-message -p -t '$target:0.0' '#{alternate_on}'")
                                .trim().takeIf { it == "1" }
                        }
                    } catch (failure: AssertionError) {
                        val pane = runCatching {
                            remote(fixture, "tmux display-message -p -t '$target:0.0' '#{pane_current_command}'; " +
                                "tmux capture-pane -p -J -t '$target:0.0' -S -12")
                        }.getOrElse { "unavailable: $it" }
                        File(evidence, "$label-alternate-screen-timeout.txt").writeText(pane)
                        throw AssertionError("${failure.message}; typed ${command.length} bytes; pane:\n$pane", failure)
                    }
                    delay(500)
                    suspend fun capture(stage: String) {
                        delay(100)
                        val bitmap = instrumentation.uiAutomation.takeScreenshot()
                        File(evidence, "$label-$stage.png").outputStream().use {
                            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                        }
                        bitmap.recycle()
                    }
                    val geometry = session.onMain {
                        val view = session.surface.view
                        val location = IntArray(2); view.getLocationOnScreen(location)
                        floatArrayOf(location[0] + view.width * .5f, location[1] + view.height * .25f, view.height * .45f)
                    }
                    fun inject(down: Long, action: Int, y: Float) {
                        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, geometry[0], y, 0)
                        event.source = InputDevice.SOURCE_TOUCHSCREEN
                        check(instrumentation.uiAutomation.injectInputEvent(event, true))
                        event.recycle()
                    }
                    capture("before")
                    for ((direction, stage) in listOf(1f to "up", -1f to "down")) {
                        val start = if (direction > 0) geometry[1] else geometry[1] + geometry[2]
                        val down = SystemClock.uptimeMillis()
                        inject(down, MotionEvent.ACTION_DOWN, start)
                        for (step in 1..12) {
                            delay(16)
                            inject(down, MotionEvent.ACTION_MOVE, start + direction * geometry[2] * step / 12f)
                        }
                        inject(down, MotionEvent.ACTION_UP, start + direction * geometry[2])
                        delay(300)
                        capture(stage)
                    }
                    val json = withTimeout(25_000) {
                        awaitValue("$label capture report") {
                            remote(fixture, "cat '$report' 2>/dev/null || true")
                                .takeIf { it.contains("TESSERA_FIXTURE_CAPTURE_V1") }
                        }
                    }
                    val received = String(
                        android.util.Base64.decode(org.json.JSONObject(json).getString("base64"), android.util.Base64.DEFAULT),
                        Charsets.ISO_8859_1,
                    )
                    File(evidence, "$label-received.txt").writeText(received.replace("\u001b", "\\e"))
                    assertSessionGroupMouseEnabled(fixture, target, mosh = transport == TransportKinds.MOSH)
                    for (button in listOf(64, 65)) {
                        assertTrue(
                            "$label must deliver wheel button $button: ${received.replace("\u001b", "\\e")}",
                            Regex("\u001b\\[<$button;\\d+;\\d+M").containsMatchIn(received),
                        )
                    }
                    assertEquals("A full-screen swipe must stay out of tmux copy mode", "0",
                        remote(fixture, "tmux display-message -p -t '$target:0.0' '#{pane_in_mode}'").trim())
                    assertEquals("Session mouse policy must preserve the global default", globalMouse,
                        remote(fixture, "tmux show-options -gv mouse").trim())
                    assertEquals("Session mouse policy must preserve unrelated session options", "0",
                        remote(fixture, "tmux display-message -p -t '$control' '#{mouse}'").trim())
                } finally {
                    activity?.let { runCatching { runOnMain { it.finish() } } }
                    runCatching { live?.close(awaitMoshCleanup = transport == TransportKinds.MOSH) }
                    runCatching { remote(fixture, "tmux kill-session -t '$target' 2>/dev/null || true; rm -f '$report'") }
                }
            }
        } finally {
            runCatching { remote(fixture, "tmux kill-session -t '$control' 2>/dev/null || true") }
        }
    }

    /**
     * A full-screen program (Claude Code's fullscreen UI, htop, Vim) inside
     * mosh+tmux under tmux's default `mouse off`. mosh never relays the
     * alternate screen, and a pane's mouse mode can be missing from the
     * visible tmux client (a user's session showed none while Claude Code's
     * pane asked for the mouse), so the pane-metadata feed is what says the
     * pane wants it. A finger drag must reach the program as SGR wheel
     * reports and a tap as an SGR click, not open tmux history. The fixture's
     * capture program records every byte its pane receives.
     */
    @Test
    fun liveMoshTmuxMouseOffTouchReachesFullScreenPane(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable)
        val fixture = readFixture()
        val target = fixture.renderLedgerSession.sanitizeTmuxTarget()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        val report = "/tmp/$target-mouse-off-touch.json"
        var live: LiveController? = null
        var activity: ComponentActivity? = null
        try {
            // The program is already full screen when Tessera attaches, as
            // when reconnecting to a running Claude Code. The capture ends
            // after 75 s and only then writes its report.
            remote(
                fixture,
                "rm -f '$report'; tmux new-session -d -s '$target' -c /tmp -x 100 -y 30; " +
                    "tmux set-option -t '$target' mouse off; " +
                    "tmux send-keys -t '$target' \"/usr/local/bin/tessera-fixture-probe capture " +
                    "--alt-screen --mouse --bytes 65536 --timeout 75 --output '$report'\" Enter",
            )
            awaitValue("full-screen capture program") {
                remote(fixture, "tmux display-message -p -t '$target:0.0' '#{alternate_on}#{mouse_any_flag}'")
                    .trim().takeIf { it == "11" }
            }
            val session = createLiveController(fixture, target, TransportKinds.MOSH)
            live = session
            activity = instrumentation.startActivitySync(
                Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            ) as ComponentActivity
            session.onMain {
                activity.setContent {
                    AndroidView(factory = { session.surface.view }, modifier = Modifier.fillMaxSize())
                }
            }
            session.connectAndAwait()
            awaitValue("pane hydration") { session.controller.tmuxSnapshot.value?.activePaneId }
            session.onMain { session.declareSingleSurfaces() }
            delay(1_000)
            try {
                withTimeout(15_000) {
                    while (session.onMain {
                            session.surface.view.remoteTmuxPane()?.takeIf { it.alternateScreen && it.mouseReporting }
                        } == null
                    ) delay(POLL_MILLISECONDS)
                }
            } catch (failure: TimeoutCancellationException) {
                throw AssertionError("timed out waiting for the side channel to report the full-screen pane", failure)
            }
            // The fixture's tmux and mosh do hand the pane's mouse mode to the
            // visible client. Clear it locally to reach that user's state;
            // mosh sends a mode again only when it changes.
            session.onMain {
                val off = "\u001b[?1000l\u001b[?1002l\u001b[?1003l\u001b[?1006l".encodeToByteArray()
                session.surface.view.mEmulator.append(off, off.size)
            }
            assertEquals(
                "The visible tmux client must not report a mouse mode (the case under test)",
                false,
                session.onMain { session.surface.view.mEmulator.isMouseTrackingActive },
            )
            suspend fun capture(stage: String) {
                delay(100)
                val bitmap = instrumentation.uiAutomation.takeScreenshot()
                File(evidence, "mosh-tmux-mouse-off-$stage.png").outputStream().use {
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
            }
            val geometry = session.onMain {
                val view = session.surface.view
                val location = IntArray(2); view.getLocationOnScreen(location)
                floatArrayOf(location[0] + view.width * .5f, location[1] + view.height * .25f, view.height * .45f)
            }
            fun inject(down: Long, action: Int, y: Float) {
                val e = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, geometry[0], y, 0)
                e.source = InputDevice.SOURCE_TOUCHSCREEN
                check(instrumentation.uiAutomation.injectInputEvent(e, true))
                e.recycle()
            }
            capture("before")
            val swipeDown = SystemClock.uptimeMillis()
            inject(swipeDown, MotionEvent.ACTION_DOWN, geometry[1])
            for (step in 1..12) { delay(16); inject(swipeDown, MotionEvent.ACTION_MOVE, geometry[1] + geometry[2] * step / 12f) }
            inject(swipeDown, MotionEvent.ACTION_UP, geometry[1] + geometry[2])
            delay(1_000)
            capture("after-swipe")
            assertEquals("A full-screen pane's swipe must not reveal tmux history", 0, session.onMain { session.surface.view.topRow })
            assertFalse("A full-screen pane's swipe must not request tmux history", session.onMain { session.surface.view.isHistoryScrollPending })
            val tapDown = SystemClock.uptimeMillis()
            inject(tapDown, MotionEvent.ACTION_DOWN, geometry[1] + geometry[2] / 2)
            delay(40)
            inject(tapDown, MotionEvent.ACTION_UP, geometry[1] + geometry[2] / 2)
            delay(1_000)
            capture("after-tap")
            assertFalse(
                "The client's mouse mode must stay off, or the emulator's own mouse path was tested",
                session.onMain { session.surface.view.mEmulator.isMouseTrackingActive },
            )

            val json = try {
                withTimeout(90_000) {
                    var text = ""
                    while (!text.contains("TESSERA_FIXTURE_CAPTURE_V1")) {
                        delay(500)
                        text = remote(fixture, "cat '$report' 2>/dev/null || true")
                    }
                    text
                }
            } catch (failure: TimeoutCancellationException) {
                throw AssertionError("timed out waiting for the fixture capture report", failure)
            }
            val received = String(
                android.util.Base64.decode(org.json.JSONObject(json).getString("base64"), android.util.Base64.DEFAULT),
                Charsets.ISO_8859_1,
            )
            File(evidence, "mosh-tmux-mouse-off-received.txt").writeText(received.replace("\u001b", "\\e"))
            assertTrue(
                "The swipe must reach the pane as SGR wheel reports: ${received.replace("\u001b", "\\e")}",
                Regex("\u001b\\[<6[45];\\d+;\\d+M").containsMatchIn(received),
            )
            assertTrue(
                "The tap must reach the pane as an SGR press and release: ${received.replace("\u001b", "\\e")}",
                Regex("\u001b\\[<0;\\d+;\\d+M").containsMatchIn(received) &&
                    Regex("\u001b\\[<0;\\d+;\\d+m").containsMatchIn(received),
            )
            assertEquals(
                "Touch must stay out of tmux copy mode",
                "0",
                remote(fixture, "tmux display-message -p -t '$target:0.0' '#{pane_in_mode}'").trim(),
            )
        } finally {
            // Close before killing the owner: the view's client must detach
            // while the owner still shares its group, or tmux 3.4's
            // `destroy-unattached keep-last` keeps the view as the group's
            // last session and the next test's fresh owner starts ungrouped
            // beside it. Remote cleanup still runs when finish or close fails,
            // and names the view too in case it was left behind.
            try {
                activity?.let { runOnMain { it.finish() } }
                live?.close(awaitMoshCleanup = true)
            } finally {
                val view = SharedTmuxCommands.moshViewSessionName(target)
                runCatching {
                    remote(
                        fixture,
                        "tmux kill-session -t '=$target' 2>/dev/null; " +
                            "tmux kill-session -t '=$view' 2>/dev/null; rm -f '$report'",
                    )
                }
            }
        }
    }

    /**
     * Inline (SSH+tmux) history ladder against a pane whose tmux history is
     * three times the attach capture.
     *
     * The fixture pane is filled with 6 000 numbered marker rows under a
     * raised `history-limit`, so the ledger's first inline fill
     * (`min(2000, scrollbackLimit)`) provably cannot reach the oldest row.
     * The gesture half is the production controller entry point
     * `requestTmuxInlineHistory`, not a synthesized render fact, and the only
     * completion signal this test waits on is the ledger's own
     * `inlineHistorySettled` mirrored into `tmuxInlineHistory`.
     *
     * A row count alone would not prove the rebind is clean: the deepened
     * capture replaces the transcript behind a continuity break, so a
     * mid-history marker is also asserted to occur exactly once. Live output
     * after the settle proves the deepen did not leave the pane detached.
     */
    @Test
    fun liveInlineTmuxHistoryDeepensToScrollbackLimit(): Unit = runBlocking {
        val fixture = readFixture()
        val session = "tessera-inline-hist-${fixture.token}".sanitizeTmuxTarget()
        val pane = "=$session:0.0"
        var live: LiveController? = null
        try {
            // The fixture server's default is small enough that 6 000 rows would
            // be evicted before the app ever attached.
            remote(fixture, newSessionWithHistoryLimit(session, 20_000))
            // 150 pad rows keep the total history comfortably above the 6 000
            // numbered markers, so the post-deepen row assertion is not
            // measuring the shell prompt. `send-keys -l` forbids key-name
            // interpretation of the loop text.
            val fill = "for i in \$(seq 1 150); do printf \"TESSERA-HIST-PAD-%03d\\n\" \$i; done; " +
                "for i in \$(seq 1 6000); do printf \"TESSERA-HIST-%06d\\n\" \$i; done; " +
                "printf \"TESSERA-HIST-DONE\\n\""
            remote(
                fixture,
                "tmux send-keys -l -t '$pane' '$fill' && tmux send-keys -t '$pane' Enter",
            )
            var fixtureHistorySize = -1
            for (attempt in 1..90) {
                fixtureHistorySize = remote(fixture, "tmux display -p -t '$pane' '#{history_size}'")
                    .trim().toIntOrNull() ?: -1
                if (fixtureHistorySize >= 5_900) break
                delay(1_000)
            }
            assertTrue(
                "fixture pane never reached 5900 history rows; last history_size=$fixtureHistorySize",
                fixtureHistorySize >= 5_900,
            )
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_INLINE_HISTORY_FIXTURE session=$session history_size=$fixtureHistorySize",
            )

            val session1 = createLiveController(
                fixture,
                session,
                TransportKinds.SSH,
                scrollbackLines = 10_000,
                transcriptRows = 12_000,
            )
            live = session1
            session1.connectAndAwait()
            awaitValue("inline pane hydration") { session1.controller.tmuxSnapshot.value?.activePaneId }
            session1.onMain { session1.declareSingleSurfaces() }

            // First fill: the attach `.deep` stage, capped at the ledger's
            // inline depth rather than the scrollback preference.
            awaitValue("inline attach capture") {
                session1.transcriptText().takeIf {
                    it.contains("TESSERA-HIST-DONE") && session1.transcriptRows() >= 1_990
                }
            }
            val attachSettle = awaitValue("inline attach settle") {
                session1.controller.tmuxInlineHistory.value[TMUX_RENDER_LIVE_SURFACE_ID]
                    ?.takeIf { it.owner != null && !it.requestInFlight }
            }
            val attachTranscript = session1.transcriptText()
            val rowsBeforeDeepen = session1.transcriptRows()
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_INLINE_HISTORY_ATTACH rows=$rowsBeforeDeepen " +
                    "depth=${attachSettle.depth} history=${attachSettle.historySize} " +
                    "canDeepen=${attachSettle.canDeepen}",
            )
            assertTrue(
                "attach capture must hold the pane tail",
                attachTranscript.contains("TESSERA-HIST-DONE"),
            )
            assertTrue(
                "attach capture must hold the middle of the first fill",
                attachTranscript.contains("TESSERA-HIST-004500"),
            )
            assertFalse(
                "attach capture must stop short of the oldest row: rows=$rowsBeforeDeepen",
                attachTranscript.contains("TESSERA-HIST-000001"),
            )
            assertTrue(
                "attach capture must be the ~2000-row first fill, got rows=$rowsBeforeDeepen",
                rowsBeforeDeepen in 1_990..2_100,
            )
            assertTrue(
                "a pane with $fixtureHistorySize history rows must leave the ladder open: $attachSettle",
                attachSettle.canDeepen,
            )

            // The production gesture entry point. The ledger answers every
            // outcome with exactly one settle, so this is the only wait.
            session1.onMain { session1.controller.requestTmuxInlineHistory(TMUX_RENDER_LIVE_SURFACE_ID) }
            val settled = awaitValue("inline history settle after deepen") {
                session1.controller.tmuxInlineHistory.value[TMUX_RENDER_LIVE_SURFACE_ID]
                    ?.takeIf { !it.requestInFlight && it.depth >= 6_000 }
            }
            awaitValue("deepened inline transcript") {
                session1.transcriptText().takeIf {
                    it.contains("TESSERA-HIST-000001") && session1.transcriptRows() >= 6_000
                }
            }
            val deepTranscript = session1.transcriptText()
            val rowsAfterDeepen = session1.transcriptRows()
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_INLINE_HISTORY_DEEPENED rows=$rowsAfterDeepen " +
                    "depth=${settled.depth} history=${settled.historySize} " +
                    "canDeepen=${settled.canDeepen}",
            )
            assertTrue(
                "deepened capture must reach the oldest marker row",
                deepTranscript.contains("TESSERA-HIST-000001"),
            )
            assertEquals(
                "the deepened capture replaces the transcript; a mid-history marker " +
                    "may not be duplicated across the rebind",
                1,
                Regex(Regex.escape("TESSERA-HIST-004500")).findAll(deepTranscript).count(),
            )
            assertTrue(
                "deepened transcript must hold the whole pane history, got rows=$rowsAfterDeepen " +
                    "(was $rowsBeforeDeepen, fixture history_size=$fixtureHistorySize)",
                rowsAfterDeepen >= 6_000,
            )
            assertFalse(
                "a capture at the scrollback limit must exhaust the ladder: $settled",
                settled.canDeepen,
            )
            assertTrue(
                "the settle must credit at least the pane's history: $settled",
                settled.historySize >= 5_900,
            )

            // The `TESSERA-HIST-AF""TER` split keeps the echoed command line
            // from matching; only the printed output carries the marker.
            remote(
                fixture,
                "tmux send-keys -l -t '$pane' 'printf \"TESSERA-HIST-AF\"\"TER\\n\"' && " +
                    "tmux send-keys -t '$pane' Enter",
            )
            awaitValue("live output after the deepen") {
                session1.transcriptText().takeIf { it.contains("TESSERA-HIST-AFTER") }
            }
            assertEquals(
                "the deepen must not cost the surface a foreign-feed-free painter",
                0,
                session1.onMain { session1.surface.droppedForeignFeeds },
            )
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_INLINE_HISTORY_OK rowsBefore=$rowsBeforeDeepen " +
                    "rowsAfter=$rowsAfterDeepen depth=${settled.depth} " +
                    "historySize=${settled.historySize} canDeepen=${settled.canDeepen}",
            )
        } finally {
            runCatching { live?.close() }
            runCatching { remote(fixture, "tmux kill-session -t '=$session' 2>/dev/null || true") }
        }
    }

    /**
     * Finger flicks alone must take an SSH+tmux reader past the 2000-row
     * attach capture to the pane's oldest row. The deepen above is requested
     * through the controller; here only the mounted production
     * [InlineTmuxHistoryController] may ask, from the flicks' own frames
     * (iOS once never evaluated its gate for a finger).
     */
    @Test
    fun liveInlineTmuxFingerFlicksDeepenToOldestRow(): Unit = runBlocking {
        val fixture = readFixture()
        val session = "tessera-inline-flick-${fixture.token}".sanitizeTmuxTarget()
        val pane = "=$session:0.0"
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val evidence = File(instrumentation.targetContext.filesDir, "live-scroll").apply { mkdirs() }
        val prefix = "ssh-tmux-inline-flicks"
        val ranges = File(evidence, "$prefix-visible-rows.csv").apply {
            writeText("stage,flick,topRow,first,last,count\n")
        }
        val rowPattern = Regex("TESSERA-HIST-(\\d{6})")
        fun visibleRows(text: String): List<Int> = rowPattern.findAll(text)
            .map { it.groupValues[1].toInt() }.toList()
        // The pad prints first, so PAD-001 is the oldest fixture row and
        // PAD-150 sits directly above TESSERA-HIST-000001. One index across
        // both lets a screen be checked for order across that seam, and lets
        // a fling that carries row 1 past the screen still count as reaching
        // it: a flick moves 27-170 rows of a 45-row screen, so it can come to
        // rest wholly inside the pad.
        val padRows = 150
        val fixturePattern = Regex("TESSERA-HIST-(?:PAD-(\\d{3})|(\\d{6}))")
        fun fixtureIndices(text: String): List<Int> = fixturePattern.findAll(text).map { match ->
            match.groupValues[1].toIntOrNull() ?: (padRows + match.groupValues[2].toInt())
        }.toList()
        val oldestRowIndex = padRows + 1
        var live: LiveController? = null
        var activity: ComponentActivity? = null
        try {
            remote(fixture, newSessionWithHistoryLimit(session, 20_000))
            val fill = "for i in \$(seq 1 $padRows); do printf \"TESSERA-HIST-PAD-%03d\\n\" \$i; done; " +
                "for i in \$(seq 1 6000); do printf \"TESSERA-HIST-%06d\\n\" \$i; done; " +
                "printf \"TESSERA-HIST-DONE\\n\""
            remote(fixture, "tmux send-keys -l -t '$pane' '$fill' && tmux send-keys -t '$pane' Enter")
            var fixtureHistorySize = -1
            for (attempt in 1..90) {
                fixtureHistorySize = remote(fixture, "tmux display -p -t '$pane' '#{history_size}'")
                    .trim().toIntOrNull() ?: -1
                if (fixtureHistorySize >= 5_900) break
                delay(1_000)
            }
            assertTrue(
                "fixture pane never reached 5900 history rows; last history_size=$fixtureHistorySize",
                fixtureHistorySize >= 5_900,
            )

            val session1 = createLiveController(
                fixture,
                session,
                TransportKinds.SSH,
                scrollbackLines = 10_000,
                transcriptRows = 12_000,
            )
            live = session1
            activity = instrumentation.startActivitySync(
                Intent.makeMainActivity(ComponentName(instrumentation.targetContext, ComponentActivity::class.java))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            ) as ComponentActivity
            session1.onMain {
                activity.setContent {
                    AndroidView(factory = { session1.surface.view }, modifier = Modifier.fillMaxSize().imePadding())
                    val inline by session1.controller.tmuxInlineHistory.collectAsState()
                    InlineTmuxHistoryController(
                        surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
                        terminal = session1.surface,
                        record = inline[TMUX_RENDER_LIVE_SURFACE_ID],
                        enabled = true,
                        onRequest = session1.controller::requestTmuxInlineHistory,
                    )
                }
            }
            session1.connectAndAwait()
            awaitValue("inline pane hydration") { session1.controller.tmuxSnapshot.value?.activePaneId }
            session1.onMain { session1.declareSingleSurfaces() }
            assertSessionGroupMouseEnabled(fixture, session, mosh = false)
            awaitValue("inline flick terminal layout") {
                session1.onMain { true.takeIf { session1.surface.view.width > 0 && session1.surface.view.height > 0 } }
            }
            awaitValue("inline attach capture") {
                session1.transcriptText().takeIf {
                    it.contains("TESSERA-HIST-DONE") && session1.transcriptRows() >= 1_990
                }
            }
            val attachSettle = awaitValue("inline attach settle") {
                session1.controller.tmuxInlineHistory.value[TMUX_RENDER_LIVE_SURFACE_ID]
                    ?.takeIf { it.owner != null && !it.requestInFlight }
            }
            assertTrue(
                "the attach capture must stop short of the oldest row and leave the ladder open: $attachSettle",
                attachSettle.canDeepen && attachSettle.depth < 6_000 &&
                    !session1.transcriptText().contains("TESSERA-HIST-000001"),
            )

            suspend fun capture(stage: String) {
                val bitmap = instrumentation.uiAutomation.takeScreenshot()
                File(evidence, "$prefix-$stage.png").outputStream().use {
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
            }

            suspend fun flick(intoHistory: Boolean) {
                val geometry = session1.onMain {
                    val view = session1.surface.view
                    val location = IntArray(2)
                    view.getLocationOnScreen(location)
                    floatArrayOf(
                        location[0] + view.width * .5f,
                        location[1] + view.height * (if (intoHistory) .2f else .8f),
                        view.height * (if (intoHistory) .6f else -.6f),
                    )
                }
                val downTime = SystemClock.uptimeMillis()
                fun inject(action: Int, fraction: Float) {
                    val event = MotionEvent.obtain(
                        downTime, SystemClock.uptimeMillis(), action,
                        geometry[0], geometry[1] + geometry[2] * fraction, 0,
                    )
                    event.source = InputDevice.SOURCE_TOUCHSCREEN
                    try {
                        check(instrumentation.uiAutomation.injectInputEvent(event, true))
                    } finally {
                        event.recycle()
                    }
                }
                inject(MotionEvent.ACTION_DOWN, 0f)
                for (step in 1..8) {
                    delay(8)
                    inject(MotionEvent.ACTION_MOVE, step / 8f)
                }
                delay(8)
                inject(MotionEvent.ACTION_UP, 1f)
                awaitFlickAtRest("inline flick at rest", session1)
            }

            class Observation(val rows: List<Int>, val indices: List<Int>, val topRow: Int)

            suspend fun observe(stage: String, flick: Int): Observation {
                val (text, topRow, grid) = session1.onMain {
                    val emulator = session1.surface.view.mEmulator
                    Triple(session1.viewportTextNow(), session1.surface.view.topRow, emulator.mRows to emulator.mColumns)
                }
                val (screenRows, columns) = grid
                val rows = visibleRows(text)
                val indices = fixtureIndices(text)
                // A screenful of fixture rows: beside them only the typed
                // command (wrapped at this width) and prompts at the top, or
                // the done line and a prompt at the tail.
                val slack = 3 + (fill.length + 40 + columns - 1) / maxOf(1, columns)
                assertTrue(
                    "$stage flick $flick shows ${indices.size} fixture rows of $screenRows: $rows",
                    indices.size >= screenRows - slack,
                )
                assertTrue(
                    "$stage flick $flick has gaps, duplicates or disorder: $indices",
                    indices.zipWithNext().all { (first, second) -> second == first + 1 },
                )
                ranges.appendText("$stage,$flick,$topRow,${rows.firstOrNull() ?: ""},${rows.lastOrNull() ?: ""},${rows.size}\n")
                return Observation(rows, indices, topRow)
            }

            capture("start")
            var last = observe("start", 0)
            var lastRows = last.rows
            var lowest = last.indices.minOrNull() ?: Int.MAX_VALUE
            var stalled = 0
            for (flick in 1..150) {
                if (lowest <= oldestRowIndex) break
                flick(intoHistory = true)
                val current = observe("history", flick)
                // Below the oldest fixture row's prompt, the screen's top row
                // is its first fixture row, and history scrolls under the
                // reader one row per row of topRow, the deepen's rebind
                // included. A frame that moved otherwise lost its anchor.
                if (last.indices.isNotEmpty() && current.indices.isNotEmpty() &&
                    last.indices.first() > 1 && current.indices.first() > 1
                ) {
                    assertEquals(
                        "history flick $flick moved topRow ${last.topRow} -> ${current.topRow} " +
                            "but its top fixture row ${last.indices.first()} -> ${current.indices.first()}",
                        last.indices.first() + (current.topRow - last.topRow),
                        current.indices.first(),
                    )
                }
                last = current
                lastRows = current.rows
                val currentLowest = current.indices.minOrNull() ?: Int.MAX_VALUE
                if (currentLowest < lowest) {
                    lowest = currentLowest
                    stalled = 0
                } else {
                    stalled++
                }
                assertTrue("No progress toward the oldest row for 8 flicks; last visible rows=$lastRows", stalled < 8)
            }
            assertTrue(
                "Did not reach the oldest row after 150 flicks; lowest fixture index=$lowest, last visible rows=$lastRows",
                lowest <= oldestRowIndex,
            )
            assertTrue(
                "the reader left the oldest row for the live tail on its own",
                session1.onMain { session1.surface.view.topRow < 0 },
            )
            capture("oldest")
            val deepened = awaitValue("inline history deepened by the flicks") {
                session1.controller.tmuxInlineHistory.value[TMUX_RENDER_LIVE_SURFACE_ID]
                    ?.takeIf { !it.requestInFlight && it.depth >= 6_000 }
            }
            assertFalse("the flicks' deepen must exhaust the ladder: $deepened", deepened.canDeepen)
            for (marker in listOf("TESSERA-HIST-000001", "TESSERA-HIST-004500")) {
                assertEquals(
                    "the deepened capture replaces the transcript; $marker must appear exactly once",
                    1,
                    Regex(Regex.escape(marker)).findAll(session1.transcriptText()).count(),
                )
            }

            var returnedToTail = false
            for (flick in 1..150) {
                if (returnedToTail) break
                flick(intoHistory = false)
                val observed = observe("tail", flick)
                lastRows = observed.rows
                returnedToTail = observed.topRow == 0
            }
            assertTrue("Did not return to the live tail after 150 flicks; last visible rows=$lastRows", returnedToTail)
            assertTrue(
                "the live tail must show the fixture's end",
                session1.onMain { session1.viewportTextNow() }.contains("TESSERA-HIST-DONE"),
            )
            capture("tail")
            assertEquals(
                "Primary scrolling must stay out of remote copy mode",
                "0",
                remote(fixture, "tmux display-message -p -t '$pane' '#{pane_in_mode}'").trim(),
            )
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_INLINE_FLICKS_OK attachDepth=${attachSettle.depth} " +
                    "depth=${deepened.depth} historySize=${deepened.historySize}",
            )
        } finally {
            activity?.let { runCatching { runOnMain { it.finish() } } }
            runCatching { live?.close() }
            runCatching { remote(fixture, "tmux kill-session -t '=$session' 2>/dev/null || true") }
        }
    }

    /** Exercises real terminal cd -> cwd signal -> SFTP listing for all four transports. */
    @Test
    fun liveFilesFollowDirectoryAcrossAllTransports(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable) { "Files follow gate requires native Mosh" }
        val fixture = readFixture()
        val target = "tessera-cwd-${fixture.token}".sanitizeTmuxTarget()
        for (transport in listOf(TransportKinds.SSH, TransportKinds.MOSH)) {
            for (tmux in listOf(false, true)) {
                val label = "$transport${if (tmux) "+tmux" else ""}"
                var live: LiveController? = null
                var files: RemoteFilesController? = null
                var otherSession: LiveController? = null
                try {
                    if (tmux) remote(fixture, "tmux new-session -d -s '$target' -c /tmp -x 100 -y 30")
                    val session = createLiveController(fixture, target.takeIf { tmux }, transport)
                    live = session
                    session.connectAndAwait()
                    if (tmux) {
                        awaitValue("$label pane hydration") { session.controller.tmuxSnapshot.value?.activePaneId }
                        session.onMain { session.declareSingleSurfaces() }
                        session.awaitTypingAdmitted(label)
                    }
                    val browser = session.onMain {
                        RemoteFilesController(
                            context = InstrumentationRegistry.getInstrumentation().targetContext,
                            route = { session.controller.fileRouteRequest() },
                            passwordProvider = SshPasswordProvider { session.controller.filePassword(it) },
                            hostKeyPolicy = SshHostKeyPolicy { session.controller.fileHostKey(it) },
                            keyAuthorizationProvider = SshKeyAuthorizationProvider { session.controller.fileKeyAuthorization(it) },
                            liveConnection = { session.controller.openLiveFileChannel() },
                            reaperDays = 0,
                        )
                    }
                    files = browser
                    suspend fun cd(path: String) {
                        session.onMain { session.surface.sendInput("cd '$path'\n".encodeToByteArray()) }
                    }
                    suspend fun report(expected: String) {
                        // Same sources as SshSessionScreen: tmux subscription, or
                        // the no-shell-integration fallback over the live file route.
                        awaitValue("$label cwd $expected") {
                            val directory = if (tmux) {
                                val snapshot = session.controller.tmuxSnapshot.value
                                snapshot?.activeWindow?.panes?.firstOrNull { it.id == snapshot.activePaneId }?.currentPath
                            } else {
                                browser.probeOnLiveChannel(
                                    session.controller.liveFileCwdProbeCommand(),
                                )?.let(RemoteCwdProbe::reportedPath)
                            }
                            directory?.takeIf { it == expected }
                        }
                        session.onMain { browser.terminalReportedDirectory(expected) }
                    }
                    suspend fun listed(expected: String) {
                        awaitValue("$label listing $expected") {
                            browser.state.value.takeIf { !it.loading && it.error == null && it.currentPath == expected }
                        }
                    }
                    // cd while Files is closed, then open; no OSC setup required.
                    cd("/tmp")
                    session.onMain { browser.open() }
                    report("/tmp")
                    listed("/tmp")
                    session.onMain {
                        browser.terminalReportedDirectory("/usr")
                        browser.terminalReportedDirectory("/tmp")
                    }
                    listed("/tmp")
                    session.onMain {
                        browser.navigate("/usr")
                        browser.toggleFollow()
                    }
                    listed("/tmp")
                    cd("/usr")
                    report("/usr")
                    listed("/usr")
                    if (!tmux && transport == TransportKinds.SSH) {
                        // The newer shell used to steal the account-wide fallback.
                        val other = createLiveController(fixture, null, TransportKinds.SSH)
                        otherSession = other
                        other.connectAndAwait()
                        other.onMain { other.surface.sendInput("cd /var\n".encodeToByteArray()) }
                        other.controller.openLiveFileChannel().use { channel ->
                            awaitValue("newer SSH session is in /var") {
                                val output = channel.executeBoundedCommand(other.controller.liveFileCwdProbeCommand())
                                RemoteCwdProbe.reportedPath(output.standardOutput)?.takeIf { it == "/var" }
                            }
                        }
                        report("/usr")
                        listed("/usr")
                    }
                    // Manual browsing must survive later reports; resuming follow snaps back.
                    session.onMain { browser.navigate("/var") }
                    listed("/var")
                    cd("/tmp")
                    report("/tmp")
                    assertEquals("$label manual browsing", "/var", browser.state.value.currentPath)
                    session.onMain { browser.toggleFollow() }
                    listed("/tmp")
                    // Reopening consumes the retained fresh terminal directory.
                    cd("/usr")
                    session.onMain { browser.open() }
                    report("/usr")
                    listed("/usr")
                    Log.i("TesseraNativeSsh", "TESSERA_ANDROID_FILES_FOLLOW_OK transport=$label cd=1 reopen=1 manual=1")
                } finally {
                    files?.let { browser -> withContext(Dispatchers.Main.immediate) { browser.close() } }
                    otherSession?.close()
                    live?.close(awaitMoshCleanup = transport == TransportKinds.MOSH)
                    if (tmux) remote(fixture, "tmux kill-session -t '=$target' 2>/dev/null || true")
                }
            }
        }
    }

    @Test
    fun liveTmuxRenderLedgerKeepsOwnersIsolatedAcrossSwitchReconnectAndMosh(): Unit = runBlocking {
        check(JniMoshNativeClientFactory.isAvailable) {
            "TESSERA_ANDROID_TMUX_ISOLATION requires a native-Mosh Android build; " +
                "run scripts/android/run-native-ssh-gate.sh with TESSERA_ANDROID_AGENT_CENTER_MOSH=1"
        }
        val fixture = readFixture()
        val target = fixture.renderLedgerSession.sanitizeTmuxTarget()
        val marker = MarkerSet(fixture.renderLedgerToken)
        // These transport exercises model one physical Android device. Its
        // tmux authority identity is installation-scoped in production, so it
        // must remain stable while the test swaps SSH for Mosh. Randomizing
        // each controller makes the later controller correctly treat the
        // earlier one's surviving authority stamp as a foreign peer.
        val tmuxDeviceIdentity = TmuxDeviceIdentity(
            "android-ledger-${UUID.randomUUID()}",
            "Android-Isolation",
        )

        // `target` is known before the remote creator returns JSON. Keep its
        // cleanup obligation from that point forward: a creator that succeeds
        // but emits malformed output must not strand a long-lived tmux server.
        var primaryFailure: Throwable? = null
        try {
            val topology = prepareFixture(fixture, target)
            val plainSshResult = exercisePlainTransport(
                fixture = fixture,
                transport = TransportKinds.SSH,
                markers = marker,
                tmuxDeviceIdentity = tmuxDeviceIdentity,
            )
            val sshResult = exerciseInlineSshTmux(
                fixture,
                target,
                marker,
                topology,
                tmuxDeviceIdentity,
            )
            val plainMoshResult = exercisePlainTransport(
                fixture = fixture,
                transport = TransportKinds.MOSH,
                markers = marker,
                tmuxDeviceIdentity = tmuxDeviceIdentity,
            )
            val moshResult = exerciseMoshTmux(
                fixture,
                target,
                marker,
                topology,
                tmuxDeviceIdentity,
            )

            // These values are intentionally checked by the test rather than
            // inferred from a log line. The marker is emitted only after the
            // all-four transport histories, active-window, active-pane,
            // reconnect, live UDP painter, and control recovery evidence
            // above has all passed.
            assertEquals(0, plainSshResult.droppedForeignFeeds)
            assertEquals(0, sshResult.droppedForeignFeeds)
            assertEquals(0, plainMoshResult.droppedForeignFeeds)
            assertEquals(0, moshResult.droppedForeignFeeds)
            Log.i("TesseraNativeSsh", "TESSERA_ANDROID_TMUX_ISOLATION_DIAGNOSTICS dropped_foreign=0")
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_TMUX_ISOLATION_TRANSPORTS " +
                    "ssh=1 sshTmux=1 mosh=1 moshTmux=1 history=1 freshGrid=1 p2bSurface=1 " +
                    "postDropPainter=1 dropped_foreign=0",
            )
            Log.i(
                "TesseraNativeSsh",
                "TESSERA_ANDROID_TMUX_ISOLATION_OK windows=1 panes=1 reconnect=1 mosh=1 sharedCore=1",
            )
        } catch (error: Throwable) {
            primaryFailure = error
        }

        val cleanupFailure = try {
            cleanupFixture(fixture, target)
            null
        } catch (error: Throwable) {
            error
        }
        primaryFailure?.let { failure ->
            cleanupFailure?.let(failure::addSuppressed)
            throw failure
        }
        cleanupFailure?.let { throw it }
    }

    /**
     * Plain SSH and plain Mosh do not have tmux owner switches, but both use
     * the exact production session controller and terminal ingress. Their
     * retained fixture history proves that the owner seam was not accidentally
     * applied to a non-tmux painter while this acceptance test was expanded.
     */
    private suspend fun exercisePlainTransport(
        fixture: Fixture,
        transport: String,
        markers: MarkerSet,
        tmuxDeviceIdentity: TmuxDeviceIdentity,
    ): InlineResult {
        val live = createLiveController(
            fixture,
            target = null,
            transport = transport,
            tmuxDeviceIdentity = tmuxDeviceIdentity,
        )
        try {
            live.connectAndAwait()
            live.onMain {
                live.surface.sendInput(
                    ("/usr/local/bin/tessera-fixture-probe tmux-isolation-stream" +
                        " --owner W1 --token ${fixture.renderLedgerToken} --count 300" +
                        " --hold-seconds 20 --heartbeat-seconds 0.5\n").encodeToByteArray(),
                )
            }
            live.awaitTranscript(
                present = markers.windowOne,
                absent = listOf(markers.windowTwo, markers.paneTwoB),
                label = "${transport} plain retained history",
            )
            return InlineResult(live.onMain { live.surface.droppedForeignFeeds })
        } finally {
            live.close(awaitMoshCleanup = transport == TransportKinds.MOSH)
        }
    }

    private suspend fun exerciseInlineSshTmux(
        fixture: Fixture,
        target: String,
        markers: MarkerSet,
        topology: FixtureTopology,
        tmuxDeviceIdentity: TmuxDeviceIdentity,
    ): InlineResult {
        val live = createLiveController(fixture, target, TransportKinds.SSH, tmuxDeviceIdentity)
        val gridSurfaces = mutableMapOf<Int, TermuxTerminalSurface>()
        try {
            live.connectAndAwait()
            // The fixture deliberately leaves W2 selected. Select W1 through
            // the product controller before making the initial single-surface
            // assertion so the gate does not accidentally certify W2 as W1.
            val firstWindow = try {
                awaitValue("initial tmux W1 metadata") {
                    live.controller.tmuxSnapshot.value?.windows?.singleOrNull { it.id == topology.windowOneId }
                }
            } catch (failure: AssertionError) {
                throw live.withDiagnosticContext(failure)
            }
            live.onMain { live.controller.selectTmuxWindow(firstWindow.id) }
            live.awaitActiveWindow(firstWindow.id)
            live.awaitTranscript(
                present = markers.windowOne,
                absent = listOf(markers.windowTwo, markers.paneTwoB),
                label = "initial window history",
            )
            assertTrue("initial owner must be bound", live.onMain { live.surface.boundOwner != null })
            assertTrue("initial history must exceed the viewport", live.transcriptRows() > 0)

            val first = requireNotNull(live.controller.tmuxSnapshot.value)
            val secondWindow = first.windows.singleOrNull { it.id == topology.windowTwoId }
                ?: awaitValue("second tmux window") {
                    live.controller.tmuxSnapshot.value?.windows?.singleOrNull { it.id == topology.windowTwoId }
            }
            live.onMain { live.controller.selectTmuxWindow(secondWindow.id) }
            live.awaitActiveWindow(secondWindow.id)
            live.onMain { live.controller.selectTmuxPane(topology.windowTwoPaneId) }
            live.awaitActivePane(topology.windowTwoPaneId)
            live.awaitTranscript(
                present = markers.windowTwo,
                absent = listOf(markers.windowOne, markers.paneTwoB),
                label = "window switch history",
            )

            val splitSnapshot = awaitValue("split pane metadata") {
                live.controller.tmuxSnapshot.value
                    ?.takeIf { it.activeWindowId == secondWindow.id && it.activeWindow?.panes?.size == 2 }
            }
            val split = requireNotNull(splitSnapshot.activeWindow)
            val activePane = requireNotNull(split.panes.firstOrNull { it.id == splitSnapshot.activePaneId })
            val otherPane = split.panes.singleOrNull { it.id == topology.paneTwoBId }
                ?: error("fixture P2b %${topology.paneTwoBId} is absent from @${topology.windowTwoId}")
            check(otherPane.id != activePane.id) { "fixture P2b must begin inactive" }

            // Mount both production grid surface registrations only after the
            // window is already hydrated. Neither has prior output to replay,
            // so each transcript proves attachTmuxPane triggered its explicit
            // first authoritative capture rather than waiting indefinitely
            // for a later window switch.
            live.onMain {
                live.controller.setTmuxGridPresentation(SharedTmuxGridPresentation.PANE_GRID)
                live.declareGridSurfaces()
                split.panes.forEach { pane ->
                    val surface = TermuxTerminalSurface(
                        InstrumentationRegistry.getInstrumentation().targetContext,
                        transcriptRows = 8_000,
                    )
                    surface.resize(100, 30)
                    gridSurfaces[pane.id] = surface
                    live.attachGridSurface(pane.id, surface)
                }
            }
            live.awaitSurfaceTranscript(
                surface = requireNotNull(gridSurfaces[activePane.id]),
                present = markers.windowTwo,
                absent = listOf(markers.windowOne, markers.paneTwoB),
                label = "fresh grid active-pane hydration",
            )
            live.awaitSurfaceTranscript(
                surface = requireNotNull(gridSurfaces[otherPane.id]),
                present = markers.paneTwoB,
                absent = listOf(markers.windowOne, markers.windowTwo),
                label = "fresh grid secondary-pane hydration",
            )
            live.onMain {
                gridSurfaces.forEach { (paneId, surface) ->
                    assertEquals(0, surface.droppedForeignFeeds)
                    live.detachGridSurface(paneId, surface)
                    surface.close()
                }
                gridSurfaces.clear()
                live.controller.setTmuxGridPresentation(SharedTmuxGridPresentation.SINGLE_PANE)
                live.declareSingleSurfaces()
            }
            live.onMain { live.controller.selectTmuxPane(otherPane.id) }
            live.awaitActivePane(otherPane.id)
            live.awaitTranscript(
                present = markers.paneTwoB,
                absent = listOf(markers.windowOne, markers.windowTwo),
                label = "pane switch history",
            )

            val ownerBeforeReconnect = requireNotNull(live.onMain { live.surface.boundOwner })
            // Drop only the SSH transport carrying the -CC client. The
            // detached tmux server and its pane history survive, while the
            // missing authenticated exit status makes the controller exercise
            // its real reconnect/rebuild path rather than terminal shutdown.
            dropFixtureTransport(fixture, target)
            live.awaitConnectedAfterInterruption()
            // The controller deliberately clears its cached screen declaration
            // on transport loss. The harness must replay the screen's current
            // single-surface fact after this direct reconnect, just as Compose
            // does after receiving the replacement snapshot.
            live.onMain { live.declareSingleSurfaces() }
            live.awaitActivePane(otherPane.id)
            val ownerAfterReconnect = awaitValue("inline replacement render owner") {
                live.onMain { live.surface.boundOwner }?.takeIf { owner ->
                    owner.paneId == otherPane.id &&
                        owner.transportGeneration > ownerBeforeReconnect.transportGeneration
                }
            }
            live.awaitTranscript(
                present = markers.paneTwoB,
                absent = listOf(markers.windowOne, markers.windowTwo),
                label = "reconnect history",
            )
            assertEquals("reconnect must keep the same pane", otherPane.id, ownerAfterReconnect.paneId)
            assertTrue(
                "reconnect must namespace a replacement shared runtime even if its core owner restarts: " +
                    "before=$ownerBeforeReconnect after=$ownerAfterReconnect",
                ownerAfterReconnect.transportGeneration > ownerBeforeReconnect.transportGeneration,
            )
            val droppedForeignFeeds = live.onMain { live.surface.droppedForeignFeeds }
            assertEquals(0, droppedForeignFeeds)
            exerciseWindowOrdering(live, fixture)
            return InlineResult(droppedForeignFeeds)
        } finally {
            runCatching {
                live.onMain {
                    gridSurfaces.forEach { (paneId, surface) ->
                        live.detachGridSurface(paneId, surface)
                        surface.close()
                    }
                    gridSurfaces.clear()
                }
            }
            live.close()
        }
    }

    private suspend fun exerciseMoshTmux(
        fixture: Fixture,
        target: String,
        markers: MarkerSet,
        topology: FixtureTopology,
        tmuxDeviceIdentity: TmuxDeviceIdentity,
    ): InlineResult {
        val live = createLiveController(fixture, target, TransportKinds.MOSH, tmuxDeviceIdentity)
        var overlay: TermuxTerminalSurface? = null
        try {
            live.connectAndAwait()
            val firstWindow = awaitValue("mosh tmux window metadata") {
                live.controller.tmuxSnapshot.value?.windows?.singleOrNull { it.id == topology.windowOneId }
            }
            // Side-channel surfaces deliberately remain unbound while Mosh is
            // still the initial painter. Publish the mounted live surface
            // before the first real window transition so the shared ledger can
            // bind and clear it at the @2 -> @1 ownership edge.
            live.onMain { live.declareSingleSurfaces() }
            live.onMain { live.controller.selectTmuxWindow(firstWindow.id) }
            live.awaitActiveWindow(firstWindow.id)
            live.awaitTranscript(
                present = markers.windowOne,
                absent = listOf(markers.windowTwo, markers.paneTwoB),
                label = "mosh window switch history",
            )
            awaitVisibleMoshWindow(live, fixture, target, firstWindow.id, "mosh W1 visible-client mirror")

            val secondWindow = awaitValue("mosh split window metadata") {
                live.controller.tmuxSnapshot.value?.windows?.singleOrNull { it.id == topology.windowTwoId }
            }
            live.onMain { live.controller.selectTmuxWindow(secondWindow.id) }
            live.awaitActiveWindow(secondWindow.id)
            live.onMain { live.controller.selectTmuxPane(topology.windowTwoPaneId) }
            live.awaitActivePane(topology.windowTwoPaneId)
            awaitVisibleMoshWindow(
                live,
                fixture,
                target,
                secondWindow.id,
                "mosh W2 visible-client mirror",
                paneId = topology.windowTwoPaneId,
            )
            live.awaitMoshSplitWindowCanvas(
                presentAny = listOf(markers.windowTwo, markers.paneTwoB),
                absent = listOf(markers.windowOne),
                label = "mosh W2 whole-window painter before P2b",
            )

            // Exercise Agent Center through the controller-owned port, not a
            // direct test responder. The historical pane bindings were
            // proven by the owner-specific output above; focus must move both
            // the -CC metadata client and the stamped Mosh painter.
            live.focusAgentWindow(firstWindow.id, requireNotNull(firstWindow.activePaneId))
            live.awaitActiveWindow(firstWindow.id)
            live.awaitTranscript(
                present = markers.windowOne,
                absent = listOf(markers.windowTwo, markers.paneTwoB),
                label = "mosh Agent focus W1 painter",
            )
            awaitVisibleMoshWindow(live, fixture, target, firstWindow.id, "mosh Agent focus W1 visible client")

            live.focusAgentWindow(secondWindow.id, topology.windowTwoPaneId)
            live.awaitActiveWindow(secondWindow.id)
            live.awaitMoshSplitWindowCanvas(
                presentAny = listOf(markers.windowTwo, markers.paneTwoB),
                absent = listOf(markers.windowOne),
                label = "mosh Agent focus W2 whole-window painter",
            )
            awaitVisibleMoshWindow(
                live,
                fixture,
                target,
                secondWindow.id,
                "mosh Agent focus W2 visible client",
                paneId = topology.windowTwoPaneId,
            )

            // The visible client begins on W2. Two intents delivered in the
            // same main-loop turn must carry it from W2 back to W1 even when
            // the first option/client proof is still in flight. Starting on
            // W2 makes this a real mirror assertion: leaving the client
            // untouched can no longer satisfy it.
            live.onMain {
                live.controller.selectTmuxWindow(secondWindow.id)
                live.controller.selectTmuxWindow(firstWindow.id)
            }
            live.awaitActiveWindow(firstWindow.id)
            live.awaitTranscript(
                present = markers.windowOne,
                absent = listOf(markers.windowTwo, markers.paneTwoB),
                label = "mosh rapid-selection visible painter",
            )
            awaitVisibleMoshWindow(live, fixture, target, firstWindow.id, "mosh latest selection wins")

            // Restore W2 explicitly and prove both the metadata and the
            // Mosh-painted client before exercising its split-pane path.
            live.onMain { live.controller.selectTmuxWindow(secondWindow.id) }
            live.awaitActiveWindow(secondWindow.id)
            live.onMain { live.controller.selectTmuxPane(topology.windowTwoPaneId) }
            live.awaitActivePane(topology.windowTwoPaneId)
            live.awaitMoshSplitWindowCanvas(
                presentAny = listOf(markers.windowTwo, markers.paneTwoB),
                absent = listOf(markers.windowOne),
                label = "mosh W2 whole-window painter after rapid-selection proof",
            )
            awaitVisibleMoshWindow(
                live,
                fixture,
                target,
                secondWindow.id,
                "mosh W2 visible-client mirror after rapid selection",
                paneId = topology.windowTwoPaneId,
            )
            val splitSnapshot = awaitValue("mosh split pane metadata") {
                live.controller.tmuxSnapshot.value
                    ?.takeIf { it.activeWindowId == secondWindow.id && it.activeWindow?.panes?.size == 2 }
            }
            val split = requireNotNull(splitSnapshot.activeWindow)
            val paneTwoB = split.panes.singleOrNull { it.id == topology.paneTwoBId }
                ?: error("mosh fixture P2b %${topology.paneTwoBId} is absent from @${topology.windowTwoId}")
            check(paneTwoB.id != splitSnapshot.activePaneId) { "mosh fixture P2b must begin inactive" }
            // From here the primary surface reads P2b's heartbeat out of the
            // whole-window Mosh frame, which is wider than the viewport.
            live.followMoshCanvas()
            live.onMain { live.controller.selectTmuxPane(paneTwoB.id) }
            live.awaitActivePane(paneTwoB.id)
            live.awaitMoshSplitWindowCanvas(
                presentAny = listOf(markers.paneTwoB, markers.windowTwo),
                absent = listOf(markers.windowOne),
                label = "mosh P2b whole-window painter",
            )
            awaitVisibleMoshWindow(
                live,
                fixture,
                target,
                secondWindow.id,
                "mosh P2b exact visible-client mirror",
                paneId = paneTwoB.id,
            )

            // This is the actual detached Android overlay contract, not the
            // legacy `live` history slot. A split Mosh window rejects that
            // slot precisely so local scrollback cannot overwrite the primary
            // UDP-painted canvas. Attach P2b's production overlay surface,
            // then require the ledger to bind and feed this separate terminal.
            val overlaySurfaceId = moshPaneHistoryOverlaySurfaceId(paneTwoB.id)
            overlay = live.onMain {
                TermuxTerminalSurface(
                    InstrumentationRegistry.getInstrumentation().targetContext,
                    transcriptRows = 8_000,
                ).also { surface ->
                    surface.resize(100, 30)
                    live.attachOverlaySurface(paneTwoB.id, surface)
                }
            }
            live.onMain {
                live.controller.requestTmuxScrollback(
                    overlaySurfaceId,
                    pointsY = -960.0,
                    isInertial = false,
                )
            }
            val history = awaitValue("mosh P2b detached overlay history") {
                live.controller.tmuxRenderHistory.value[overlaySurfaceId]
                    ?.takeIf {
                        it.owner.windowId == secondWindow.id && it.owner.paneId == paneTwoB.id &&
                            it.depth > 30 && it.historySize > 30
                    }
            }
            assertNotNull(history)
            live.awaitSurfaceTranscript(
                surface = requireNotNull(overlay),
                present = markers.paneTwoB,
                absent = listOf(markers.windowOne, markers.windowTwo),
                label = "mosh P2b detached overlay history",
            )
            assertEquals(
                "P2b overlay must be bound to its captured pane",
                paneTwoB.id,
                live.onMain { requireNotNull(overlay).boundOwner?.paneId },
            )
            val presentation = MoshPaneHistoryOverlayPresentation()
            val delivery = requireNotNull(history).asMoshPaneHistoryReadyDelivery()
            assertTrue("P2b detached overlay must accept the first real history delivery", presentation.accept(delivery))
            assertTrue(
                "P2b detached overlay must reveal only its bound owner",
                presentation.shouldReveal(paneTwoB.id, mapOf(overlaySurfaceId to delivery)),
            )
            live.onMain {
                requireNotNull(overlay).view.topRow = -1
                live.controller.acknowledgeTmuxRenderHistoryPresented(
                    overlaySurfaceId,
                    requireNotNull(history).deliveryToken,
                )
            }
            live.awaitHistoryPresentationAcknowledged(
                overlaySurfaceId,
                requireNotNull(history).deliveryToken,
            )
            val ownerBeforeReconnect = requireNotNull(live.onMain { requireNotNull(overlay).boundOwner })

            // Drop only this generated fixture's SSH -CC side channel. The
            // primary terminal records a monotonically increasing heartbeat
            // from the visible P2b pane; observing a newer heartbeat after
            // the drop proves Mosh kept painting, rather than merely keeping
            // a stale Connected state while control reconnects.
            val heartbeatBeforeDrop = live.latestHeartbeat(markers.paneTwoB)
            dropFixtureTransport(fixture, SharedTmuxCommands.moshViewSessionName(target))
            live.awaitDiagnostic("mosh_tmux_control_retry")
            live.awaitHeartbeatAfter(markers.paneTwoB, heartbeatBeforeDrop)
            val reattached = awaitValue("mosh reattached control snapshot") {
                live.controller.tmuxSnapshot.value
                    ?.takeIf { it.windows.any { window -> window.id == secondWindow.id } }
            }
            assertNotNull(reattached)
            assertTrue(
                "the UDP Mosh transport must stay connected while its control side channel recovers",
                live.controller.state.value is SshSessionUiState.Connected,
            )
            live.onMain {
                live.controller.selectTmuxWindow(secondWindow.id)
                live.controller.selectTmuxPane(paneTwoB.id)
            }
            live.awaitActivePane(paneTwoB.id)
            awaitVisibleMoshWindow(
                live,
                fixture,
                target,
                secondWindow.id,
                "mosh visible-client mirror after control reconnect",
                paneId = paneTwoB.id,
            )
            // A true pane change retires an in-flight side-channel gesture by
            // design; history must never migrate across pane identity. Model a
            // real user gesture only after both the metadata client and the
            // Mosh painter have committed P2b, then republish the exact mounted
            // overlay declaration for the reconnected generation.
            live.onMain {
                live.declareSingleSurfaces()
                live.controller.returnTmuxScrollbackToTail(overlaySurfaceId)
            }
            val epochBeforeGeometryStorm = requireNotNull(
                live.onMain { requireNotNull(overlay).boundOwner },
            ).epoch
            live.onMain {
                live.controller.requestTmuxScrollback(
                    overlaySurfaceId,
                    pointsY = -960.0,
                    isInertial = false,
                )
            }
            // Exercise the production resize coalescer and JNI reducer while
            // the side-channel capture/presentation is in flight. Every
            // settled size invalidates older generations, preserves the exact
            // same-pane user intent, and must converge on one final delivery.
            for ((columns, rows) in listOf(96 to 29, 104 to 31, 100 to 30)) {
                live.onMain { live.controller.updateTmuxViewport(columns, rows) }
                delay(SharedSessionPolicy.resizeSettleMilliseconds() + 40)
            }
            val reconnectHistory = awaitValue("mosh P2b history delivery after control reconnect") {
                live.controller.tmuxRenderHistory.value[overlaySurfaceId]
                    ?.takeIf {
                        it.deliveryToken > requireNotNull(history).deliveryToken &&
                            it.owner.paneId == paneTwoB.id &&
                            it.owner.epoch >= epochBeforeGeometryStorm + 3
                    }
            }
            assertTrue(
                "control reconnect must produce a later detached-overlay delivery",
                requireNotNull(reconnectHistory).historySize > 30,
            )
            live.awaitSurfaceTranscript(
                surface = requireNotNull(overlay),
                present = markers.paneTwoB,
                absent = listOf(markers.windowOne, markers.windowTwo),
                label = "mosh P2b overlay after control reconnect",
            )
            val ownerAfterReconnect = requireNotNull(live.onMain { requireNotNull(overlay).boundOwner })
            assertEquals(
                "Mosh control reconnect must keep the detached overlay on P2b",
                ownerBeforeReconnect.paneId,
                ownerAfterReconnect.paneId,
            )
            assertTrue(
                "Mosh control reconnect must advance the shared owner epoch: " +
                    "before=$ownerBeforeReconnect after=$ownerAfterReconnect",
                ownerAfterReconnect.epoch > ownerBeforeReconnect.epoch,
            )
            assertTrue(
                "Mosh control reconnect must advance the transport generation: " +
                    "before=$ownerBeforeReconnect after=$ownerAfterReconnect",
                ownerAfterReconnect.transportGeneration > ownerBeforeReconnect.transportGeneration,
            )
            live.onMain {
                requireNotNull(overlay).view.topRow = -1
                live.controller.acknowledgeTmuxRenderHistoryPresented(
                    overlaySurfaceId,
                    requireNotNull(reconnectHistory).deliveryToken,
                )
            }
            live.awaitHistoryPresentationAcknowledged(
                overlaySurfaceId,
                requireNotNull(reconnectHistory).deliveryToken,
            )
            exerciseWindowOrdering(live, fixture)
            return InlineResult(
                live.onMain { live.surface.droppedForeignFeeds + requireNotNull(overlay).droppedForeignFeeds },
            )
        } catch (failure: AssertionError) {
            throw live.withDiagnosticContext(failure, overlay)
        } finally {
            overlay?.let { surface ->
                runCatching {
                    live.onMain {
                        val owner = surface.boundOwner
                        if (owner != null) live.detachOverlaySurface(owner.paneId, surface)
                        surface.close()
                    }
                }
            }
            live.close(awaitMoshCleanup = true)
        }
    }

    /** Real JNI + controller ordering, run after render isolation on SSH and Mosh. */
    private suspend fun exerciseWindowOrdering(live: LiveController, fixture: Fixture) {
        val controller = live.controller
        val initial = awaitValue("window order hydration") {
            controller.tmuxSnapshot.value?.takeIf { it.isWindowListHydrated && it.windows.size >= 2 && it.windows.all { w -> w.index != null } }
        }
        val session = requireNotNull(initial.sessionId)
        val active = requireNotNull(initial.activeWindowId)
        val activePane = initial.activePaneId
        val panes = initial.windows.associate { it.id to it.panes.map { p -> p.id } }
        live.onMain { controller.moveTmuxWindow(active, 0) }
        awaitValue("active reorder confirmed") {
            controller.tmuxSnapshot.value?.takeIf { !it.isReorderPending && it.windows.first().id == active }
        }
        assertEquals(active, controller.tmuxSnapshot.value?.activeWindowId)
        assertEquals(activePane, controller.tmuxSnapshot.value?.activePaneId)
        assertEquals(panes, controller.tmuxSnapshot.value?.windows?.associate { it.id to it.panes.map { p -> p.id } })
        val background = initial.windows.first { it.id != active }.id
        live.onMain { controller.moveTmuxWindow(background, 0) }
        awaitValue("background reorder confirmed") {
            controller.tmuxSnapshot.value?.takeIf { !it.isReorderPending && it.windows.first().id == background }
        }
        assertEquals("background move preserved selection", active, controller.tmuxSnapshot.value?.activeWindowId)
        suspend fun create(): Int {
            val before = requireNotNull(controller.tmuxSnapshot.value).windows.map { it.id }.toSet()
            live.onMain { controller.createTmuxWindow() }
            return awaitValue("appended window hydrated") {
                controller.tmuxSnapshot.value?.windows?.lastOrNull()?.takeIf { it.id !in before && it.index != null }?.id
            }
        }
        val gap = create()
        create()
        live.onMain { controller.closeTmuxWindow(gap) }
        awaitValue("gap created") { true.takeIf { controller.tmuxSnapshot.value?.windows?.none { it.id == gap } == true } }
        val maximum = requireNotNull(controller.tmuxSnapshot.value).windows.mapNotNull { it.index }.max()
        create()
        assertTrue("Tessera append reused a gap", requireNotNull(controller.tmuxSnapshot.value?.windows?.last()?.index) > maximum)
        val beforeExternal = requireNotNull(controller.tmuxSnapshot.value).windows.map { it.id }
        val moving = beforeExternal.last()
        remote(fixture, "tmux move-window -d -b -s '${'$'}$session:@$moving' -t '${'$'}$session:@${beforeExternal.first()}'")
        awaitValue("external relink retains all windows") {
            controller.tmuxSnapshot.value?.takeIf { it.windows.first().id == moving && it.windows.size == beforeExternal.size }
        }
        val swap = requireNotNull(controller.tmuxSnapshot.value).windows.map { it.id }.toMutableList()
        val a = swap[1]; val b = swap[2]
        swap[1] = b; swap[2] = a
        remote(fixture, "tmux swap-window -s '${'$'}$session:@$a' -t '${'$'}$session:@$b'")
        awaitValue("silent swap subscription") {
            controller.tmuxSnapshot.value?.takeIf { it.windows.map { w -> w.id } == swap }
        }
        val server = remote(fixture, "tmux list-windows -t '${'$'}$session' -F '#{window_id}'")
            .lineSequence().filter { it.startsWith("@") }.map { it.drop(1).toInt() }.toList()
        assertEquals(server, controller.tmuxSnapshot.value?.windows?.map { it.id })
        for (option in TmuxWindowSplitOption.entries) {
            live.onMain { controller.selectTmuxWindow(active) }
            awaitValue("original window selected before inactive split") { true.takeIf { controller.tmuxSnapshot.value?.activeWindowId == active } }
            val target = requireNotNull(controller.tmuxSnapshot.value).windows.first { it.id == background }
            val beforePanes = target.panes.map { it.id }.toSet()
            live.onMain { controller.splitTmuxWindow(background, option.vertical, option.before) }
            val split = awaitValue("inactive window split ${option.name}") {
                controller.tmuxSnapshot.value?.takeIf { it.activeWindowId == background }
                    ?.windows?.firstOrNull { it.id == background && it.panes.size == beforePanes.size + 1 }
            }
            val created = split.panes.single { it.id !in beforePanes }.id
            val otherPaneIDs = requireNotNull(controller.tmuxSnapshot.value).windows.first { it.id == active }.panes.map { it.id }
            assertEquals("inactive split changed foreground pane membership", panes[active], otherPaneIDs)
            live.onMain { controller.closeTmuxPane(created) }
            awaitValue("split cleanup ${option.name}") { true.takeIf { controller.tmuxSnapshot.value?.windows?.first { it.id == background }?.panes?.map { it.id }?.toSet() == beforePanes } }
        }
        Log.i("TesseraNativeSsh", "TESSERA_WINDOW_ORDER_OK append=1 move=1 external=1 panes=1 inactiveSplitDirections=4")
    }

    private suspend fun prepareFixture(fixture: Fixture, target: String): FixtureTopology {
        // Tokens and the generated tmux target are restricted locally before
        // interpolation. The fixture command creates no user files and is
        // torn down by the gate's final targeted kill-session cleanup.
        val output = remote(
            fixture,
            "/usr/local/bin/tessera-fixture-probe tmux-isolation-session" +
                " --session '$target' --token '${fixture.renderLedgerToken}' --count 300" +
                " --hold-seconds 360 --heartbeat-seconds 0.5 --columns 100 --rows 30",
        )
        check(output.contains("TESSERA_TMUX_ISOLATION_FIXTURE_V1")) {
            "fixture did not report a tmux isolation topology: ${output.take(512)}"
        }
        check(output.contains("\"session\": \"$target\"")) {
            "fixture isolation topology did not report the generated session: ${output.take(512)}"
        }
        val payload = output.lineSequence()
            .map(String::trim)
            .lastOrNull { it.startsWith("{") && it.contains("TESSERA_TMUX_ISOLATION_FIXTURE_V1") }
            ?: error("fixture isolation topology did not contain its JSON payload: ${output.take(512)}")
        val topology = JSONObject(payload).getJSONObject("topology")
        fun identifier(section: String, field: String, prefix: Char): Int {
            val raw = topology.getJSONObject(section).getString(field)
            return raw.removePrefix(prefix.toString()).toIntOrNull()?.takeIf { it >= 0 }
                ?: error("fixture isolation topology has invalid $section.$field=$raw")
        }
        val windowTwoId = identifier("W2", "window_id", '@')
        check(identifier("P2b", "window_id", '@') == windowTwoId) {
            "fixture P2b does not belong to W2"
        }
        return FixtureTopology(
            windowOneId = identifier("W1", "window_id", '@'),
            windowTwoId = windowTwoId,
            windowTwoPaneId = identifier("W2", "pane_id", '%'),
            paneTwoBId = identifier("P2b", "pane_id", '%'),
        )
    }

    private suspend fun dropFixtureTransport(fixture: Fixture, target: String) {
        val output = remote(
            fixture,
            "/usr/local/bin/tessera-fixture-probe tmux-isolation-drop-transport --session '$target'",
        )
        check(output.contains("TESSERA_TMUX_ISOLATION_TRANSPORT_DROPPED_V1")) {
            "fixture did not confirm a target-scoped tmux transport drop: ${output.take(512)}"
        }
        check(output.contains("\"control_client_count\": 1")) {
            "fixture transport drop was not isolated to exactly one client: ${output.take(512)}"
        }
    }

    private suspend fun cleanupFixture(fixture: Fixture, target: String) {
        val output = remote(
            fixture,
            "/usr/local/bin/tessera-fixture-probe tmux-isolation-cleanup --session '$target'",
        )
        check(output.contains("TESSERA_TMUX_ISOLATION_CLEANUP_V1")) {
            "fixture did not confirm exact tmux isolation cleanup: ${output.take(512)}"
        }
    }

    private fun createLiveController(
        fixture: Fixture,
        target: String?,
        transport: String,
        tmuxDeviceIdentity: TmuxDeviceIdentity = TmuxDeviceIdentity(
            "android-ledger-${UUID.randomUUID()}",
            "Android-Isolation",
        ),
        // The user's scrollback preference. It is what the ledger's inline
        // ladder deepens to, so a case that exercises the deepen has to be
        // able to raise it above the 2 000-row first fill.
        scrollbackLines: Int = 4_000,
        transcriptRows: Int = 8_000,
    ): LiveController {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val host = SavedHost(
            id = UUID.randomUUID().toString(),
            displayName = "render-ledger fixture",
            hostname = fixture.stableHost,
            port = fixture.port,
            username = fixture.user,
            jumpHostId = null,
            identityId = null,
            transportKind = transport,
            tmuxMode = if (target == null) TmuxModes.OFF else TmuxModes.PINNED,
            tmuxTarget = target,
        )
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val diagnostics = DiagnosticLogStore(context)
        val agentSessions = LiveAgentSessionRegistry()
        val controller = SshSessionController(
            host = host,
            hosts = IsolationHostRepository(host),
            identities = IsolationIdentityRepository(),
            knownHosts = IsolationKnownHostsRepository(),
            restore = IsolationRestoreRepository(),
            credentialStore = AndroidKeystoreCredentialStore(),
            diagnostics = diagnostics,
            scope = scope,
            agentSessions = agentSessions,
            initialTmuxGridPresentation = SharedTmuxGridPresentation.SINGLE_PANE,
            tmuxDeviceIdentity = tmuxDeviceIdentity,
            scrollbackLines = scrollbackLines,
        )
        lateinit var surface: TermuxTerminalSurface
        runOnMain {
            surface = TermuxTerminalSurface(context, transcriptRows = transcriptRows)
            surface.resize(100, 30)
            controller.attachTerminal(surface)
            controller.setPresentationActive(true)
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
        return LiveController(
            controller,
            surface,
            diagnostics,
            scope,
            authentication,
            tmuxDeviceIdentity,
            agentSessions,
        )
    }

    private suspend fun awaitVisibleMoshWindow(
        live: LiveController,
        fixture: Fixture,
        target: String,
        windowId: Int,
        label: String,
        paneId: Int? = null,
    ) {
        val option = SharedTmuxCommands.authorityVisibleClientOption(live.tmuxDeviceIdentity.id)
        // The painter belongs to the grouped mosh view, not the owning
        // session. Probing the owner accidentally accepted the bare-id
        // switch-client escape that session-qualified selection now prevents.
        val viewTarget = SharedTmuxCommands.moshViewSessionName(target)
        val proof = awaitValue(label) {
            val output = remote(
                fixture,
                "tmux show-options -qv -t '$viewTarget' '$option' && " +
                    "tmux list-clients -t '$viewTarget' " +
                    "-F '#{client_name}|#{client_pid}|#{client_created}|#{window_id}|#{pane_id}'",
            )
            val lines = output.lineSequence().filter(String::isNotBlank).toList()
            val stamp = lines.firstOrNull()
                ?.takeIf { TmuxVisibleClientSelection.identity(it) != null }
                ?: return@awaitValue null
            lines.drop(1).singleOrNull { line ->
                val fields = line.split('|')
                fields.size == 5 && fields.take(3).joinToString("|") == stamp &&
                    fields[3] == "@$windowId" &&
                    TmuxVisibleClientSelection.paneId(fields[4]) != null &&
                    (paneId == null || fields[4] == "%$paneId")
            }
        }
        val expectedTarget = paneId?.let { "@$windowId|%$it" } ?: "@$windowId"
        assertTrue(
            "$label must prove the exact stamped client on $expectedTarget",
            proof.endsWith("|$expectedTarget") || (paneId == null && proof.contains("|@$windowId|")),
        )
    }

    /**
     * A detached 100x30 shell session whose pane keeps [historyLimit] lines.
     * `history-limit` sizes a pane when it is created, so the session's own
     * option is set before its window is recreated. This needs no tmux server
     * running beforehand and leaves the fixture's global options alone:
     * other runs share the fixture.
     */
    private fun newSessionWithHistoryLimit(session: String, historyLimit: Int): String =
        "tmux new-session -d -s '$session' -x 100 -y 30 -c /tmp \\; " +
            "set-option -t '$session' history-limit $historyLimit \\; " +
            "set-option -t '$session' default-size 100x30 \\; " +
            "new-window -k -t '$session:0' -c /tmp"

    /**
     * Tessera enables mouse input on the work session and its grouped view,
     * including mosh's private view of the same windows. Primary finger
     * scrolling must still use local history with mouse input enabled.
     */
    private suspend fun assertSessionGroupMouseEnabled(fixture: Fixture, target: String, mosh: Boolean) {
        val members = remote(fixture, "tmux list-sessions -F '#{session_group}|#{session_name}|#{?mouse,on,off}'")
            .lines().map { it.trim().split("|") }
            // The app's view session is `<target>-view` or `<target>-tessera-view`.
            .filter { it.size == 3 && (it[0] == target || it[1] == target || it[1].startsWith("$target-")) }
        val owner = members.firstOrNull { it[1] == target }
        assertTrue("No tmux session is $target: $members", owner != null)
        if (mosh) {
            val view = SharedTmuxCommands.moshViewSessionName(target)
            val viewMember = members.firstOrNull { it[1] == view }
            assertTrue("mosh's view session $view is missing: $members", viewMember != null)
            assertEquals("$view must share $target's group: $members", owner!![0], viewMember!![0])
        }
        assertEquals("Tessera must enable mouse on each session of $target: $members", listOf("on"), members.map { it[2] }.distinct())
    }

    private suspend fun remote(fixture: Fixture, command: String): String {
        val transcript = AndroidSshBackend().executeRouteCommand(
            request = SshRouteRequest(
                hops = listOf(
                    SshRouteHop(
                        id = "render-ledger-fixture",
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

    private fun readFixture(): Fixture {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val descriptor = automation.executeShellCommand("cat $FIXTURE_PATH")
        val properties = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            Properties().apply { load(input) }
        }
        fun value(name: String): String = properties.getProperty(name)?.takeIf { it.isNotBlank() }
            ?: error("native SSH fixture is missing $name")
        return Fixture(
            stableHost = value("stableHost"),
            port = value("port").toInt(),
            user = value("user"),
            password = android.util.Base64.decode(value("passwordBase64"), android.util.Base64.DEFAULT)
                .decodeToString(),
            token = value("token"),
            renderLedgerSession = value("renderLedgerSession"),
            renderLedgerToken = value("renderLedgerToken"),
            codexFixtureRoot = properties.getProperty("codexFixtureRoot"),
        )
    }

    private data class Fixture(
        val stableHost: String,
        val port: Int,
        val user: String,
        val password: String,
        val token: String,
        val renderLedgerSession: String,
        val renderLedgerToken: String,
        val codexFixtureRoot: String? = null,
    )

    private data class MarkerSet(private val token: String) {
        val windowOne = "TESSERA-W1-$token"
        val windowTwo = "TESSERA-W2-$token"
        val paneTwoB = "TESSERA-P2b-$token"
    }

    private data class FixtureTopology(
        val windowOneId: Int,
        val windowTwoId: Int,
        val windowTwoPaneId: Int,
        val paneTwoBId: Int,
    )

    private data class InlineResult(val droppedForeignFeeds: Int)

    private inner class LiveController(
        val controller: SshSessionController,
        val surface: TermuxTerminalSurface,
        private val diagnostics: DiagnosticLogStore,
        private val scope: CoroutineScope,
        private val authentication: Job,
        val tmuxDeviceIdentity: TmuxDeviceIdentity,
        private val agentSessions: LiveAgentSessionRegistry,
    ) {
        private val diagnosticsPrefix = diagnostics.read().length
        // This direct controller harness has no Compose tree. Mirror exactly
        // the screen's presentation-owned declaration, rather than relying on
        // physical controller maps to infer topology.
        private var renderPresentation = TmuxScreenRenderPresentation.Single
        private val mountedGridPaneIds = linkedSetOf<Int>()
        private val mountedOverlayPaneIds = linkedSetOf<Int>()

        /**
         * Connects and, unless [show] is false, reports the show edge the
         * screen reports for a displayed tab (§6.9 R1). Nothing else claims
         * the grid (R5): without the show a tmux session only reads authority.
         */
        suspend fun connectAndAwait(show: Boolean = true) {
            onMain { controller.connect() }
            awaitValue("controller connected") { controller.state.value.takeIf { it is SshSessionUiState.Connected } }
            if (show) showAndAwaitDecision()
        }

        /**
         * A show edge, then a bounded wait for its own authority read to
         * decide: keys, paste and paths are refused while resuming, so a
         * case that types right after connecting would otherwise race it.
         * Still resuming after the bound fails here, naming the stuck read,
         * rather than as a refused keystroke or a timeout further on. Which
         * decision it reached (mine, veiled) is each case's to assert.
         */
        suspend fun showAndAwaitDecision(
            source: SharedTmuxAuthorityShowSource = SharedTmuxAuthorityShowSource.SHOW,
        ) {
            onMain { controller.shown(source) }
            withTimeoutOrNull(SHOW_DECISION_TIMEOUT_MS) {
                while (controller.tmuxAuthorityPresentation.value is TmuxAuthorityPresentation.Resuming) delay(50)
            }
            val presentation = controller.tmuxAuthorityPresentation.value
            if (presentation is TmuxAuthorityPresentation.Resuming) {
                val authorityLines = diagnostics.read().drop(diagnosticsPrefix).lineSequence()
                    .filter { "tmux_authority" in it }
                    .toList()
                    .takeLast(20)
                    .joinToString("\n")
                throw AssertionError(
                    "show(${source.wireValue}) was still $presentation after ${SHOW_DECISION_TIMEOUT_MS} ms; " +
                        "recent authority diagnostics:\n$authorityLines",
                )
            }
        }

        /**
         * Lays the primary emulator out at the Mosh canvas, as the screen
         * does: `CompactTmuxTerminal` measures a whole-window Mosh painter at
         * the canvas grid (`GeometryNeutralTerminalViewport`) and pans to the
         * focused pane. A split window wider than the viewport (P1 | P2b is
         * 203 columns) is painted at full width. Without this mirror the
         * 203-column frame lands on the 100-column harness emulator, whose
         * clamped cursor and autowrap turn every row into artefacts that only
         * sometimes still read as `HEARTBEAT-<n>`. In single-pane presentation
         * the controller ignores the surface's own resize, exactly as for the
         * screen's canvas-sized terminal; the viewport stays 100x30.
         */
        fun followMoshCanvas() {
            scope.launch {
                controller.moshCanvasSize.collect { canvas ->
                    if (canvas != null && canvas.columns >= 4 && canvas.rows >= 4) {
                        surface.resize(canvas.columns, canvas.rows)
                    }
                }
            }
        }

        suspend fun agentEndpoint(): AgentSessionEndpoint {
            val binding = awaitValue("registered Agent endpoint") { controller.agentEndpointBinding.value }
            return agentSessions.resolve(binding.key) ?: error("controller Agent endpoint was not registered")
        }

        /** Test-only access to the exact generated controller's auxiliary route. */
        fun auxiliaryRoute(): SshRouteOwner {
            val field = SshSessionController::class.java.getDeclaredField("routeOwner")
            field.isAccessible = true
            return field.get(controller) as? SshRouteOwner ?: error("fixture controller has no auxiliary route")
        }

        /** Exact generated carrier capability; never process-name discovery. */
        fun moshServerPid(): Int {
            val field = SshSessionController::class.java.getDeclaredField("moshTransport")
            field.isAccessible = true
            return (field.get(controller) as? AndroidMoshTransport)?.bootstrapServerPid
                ?.takeIf { it > 0 } ?: error("fixture controller has no Mosh server PID")
        }

        suspend fun awaitConnectedAfterInterruption() {
            awaitDiagnostic("session_reconnect_scheduled")
            awaitValue("controller reconnect") {
                when (val state = controller.state.value) {
                    SshSessionUiState.Connected -> state
                    is SshSessionUiState.Failed -> error("controller failed during reconnect: $state")
                    else -> null
                }
            }
        }

        suspend fun awaitActiveWindow(windowID: Int) {
            try {
                awaitValue("active window @$windowID") {
                    controller.tmuxSnapshot.value?.takeIf { it.activeWindowId == windowID }
                }
            } catch (failure: AssertionError) {
                throw withDiagnosticContext(failure)
            }
            onMain(::publishRenderSurfaceDeclarations)
        }

        suspend fun awaitActivePane(paneID: Int) {
            awaitValue("active pane %$paneID") {
                controller.tmuxSnapshot.value?.takeIf { it.activePaneId == paneID }
            }
            onMain(::publishRenderSurfaceDeclarations)
        }

        suspend fun focusAgentWindow(windowID: Int, paneID: Int) {
            val current = awaitValue("Agent endpoint binding") {
                controller.agentEndpointBinding.value
            }
            val target = AgentEndpointBinding(
                key = current.key,
                hostID = current.hostID,
                transport = current.transport,
                tmuxSession = current.tmuxSession,
                windowID = "@$windowID",
                paneID = "%$paneID",
                hostDisplayLabel = current.hostDisplayLabel,
            )
            val endpoint = agentSessions.resolve(current.key)
                ?: error("controller did not register its Agent endpoint")
            val result = endpoint.focus(target)
            assertTrue(
                "production Agent focus failed for @$windowID/%$paneID: $result",
                result is AgentEndpointResult.Success,
            )
        }

        fun declareSingleSurfaces() {
            renderPresentation = TmuxScreenRenderPresentation.Single
            publishRenderSurfaceDeclarations()
        }

        /**
         * Keys, paste and paths are refused until the claim a surface
         * declaration starts has settled. A case that types right after
         * declaring waits here; typed earlier, its whole command is dropped
         * and the shell only ever shows its prompt.
         */
        suspend fun awaitTypingAdmitted(label: String) {
            awaitValue("$label owned grid accepting input") {
                (controller.tmuxAuthority.value as? SharedTmuxGridAuthoritySnapshot.Mine)?.takeIf {
                    !controller.tmuxReclaimInFlight.value && controller.acceptsTerminalInput()
                }
            }
        }

        fun declareGridSurfaces() {
            renderPresentation = TmuxScreenRenderPresentation.Grid
            publishRenderSurfaceDeclarations()
        }

        fun attachGridSurface(paneID: Int, terminal: TermuxTerminalSurface) {
            controller.attachTmuxPane(paneID, terminal)
            mountedGridPaneIds += paneID
            publishRenderSurfaceDeclarations()
        }

        fun detachGridSurface(paneID: Int, terminal: TermuxTerminalSurface) {
            mountedGridPaneIds -= paneID
            publishRenderSurfaceDeclarations()
            controller.detachTmuxPane(paneID, terminal)
        }

        fun attachOverlaySurface(paneID: Int, terminal: TermuxTerminalSurface) {
            mountedOverlayPaneIds += paneID
            controller.attachTmuxOverlay(paneID, terminal)
            publishRenderSurfaceDeclarations()
        }

        fun detachOverlaySurface(paneID: Int, terminal: TermuxTerminalSurface) {
            mountedOverlayPaneIds -= paneID
            publishRenderSurfaceDeclarations()
            controller.detachTmuxOverlay(paneID, terminal)
        }

        private fun publishRenderSurfaceDeclarations() {
            val snapshot = controller.tmuxSnapshot.value
            controller.setTmuxScreenRenderPresentation(renderPresentation)
            controller.declareTmuxRenderSurfaces(
                tmuxScreenRenderSurfaceDeclarations(
                    presentation = renderPresentation,
                    activeWindowId = snapshot?.activeWindowId,
                    activePaneId = snapshot?.activePaneId,
                    activePaneIds = snapshot?.activeWindow?.panes?.mapTo(mutableSetOf()) { it.id }
                        ?: emptySet(),
                    mountedGridPaneIds = mountedGridPaneIds,
                    mountedOverlayPaneIds = mountedOverlayPaneIds,
                ),
            )
        }

        suspend fun awaitTranscript(present: String, absent: List<String>, label: String) {
            awaitValue(label) {
                val text = transcript()
                if (text.contains(present) && absent.none(text::contains) &&
                    transcriptRows() > viewportRows()
                ) text else null
            }
            val dump = transcript()
            assertTrue("$label must retain $present", dump.contains(present))
            absent.forEach { foreign ->
                assertFalse("$label leaked foreign marker $foreign", dump.contains(foreign))
            }
            assertTrue(
                "$label must retain history deeper than the viewport: " +
                    "history=${transcriptRows()} rows=${viewportRows()}",
                transcriptRows() > viewportRows(),
            )
        }

        /**
         * Mosh paints the complete split window into the primary terminal and
         * presentation pans that canvas to the focused pane. The sibling pane
         * is therefore valid primary-canvas content; pane-specific history is
         * asserted separately against the detached ledger surface below. This
         * oracle keeps the continuity guarantee strict at the window boundary
         * while the exact stamped-client query proves the focused pane.
         */
        suspend fun awaitMoshSplitWindowCanvas(
            presentAny: List<String>,
            absent: List<String>,
            label: String,
        ) {
            require(presentAny.isNotEmpty())
            awaitValue(label) {
                val text = transcript()
                if (presentAny.any(text::contains) && absent.none(text::contains)) text else null
            }
            val dump = transcript()
            assertTrue(
                "$label must contain a marker from the active split window",
                presentAny.any(dump::contains),
            )
            absent.forEach { foreign ->
                assertFalse("$label leaked foreign-window marker $foreign", dump.contains(foreign))
            }
        }

        suspend fun awaitSurfaceTranscript(
            surface: TermuxTerminalSurface,
            present: String,
            absent: List<String>,
            label: String,
        ) {
            try {
                awaitValue(label) {
                    val text = transcript(surface)
                    if (text.contains(present) && absent.none(text::contains) &&
                        transcriptRows(surface) > viewportRows(surface)
                    ) text else null
                }
            } catch (failure: AssertionError) {
                val state = onMain {
                    "owner=${surface.boundOwner}; dropped=${surface.droppedForeignFeeds}; " +
                        "history=${surface.view.mEmulator.screen.activeTranscriptRows}; " +
                        "viewport=${surface.view.mEmulator.mRows}; transcript=${transcriptNow(surface).takeLast(2_048)}"
                }
                throw AssertionError("${failure.message}; targetSurface={$state}", failure)
            }
            val dump = transcript(surface)
            assertTrue("$label must retain $present", dump.contains(present))
            absent.forEach { foreign ->
                assertFalse("$label leaked foreign marker $foreign", dump.contains(foreign))
            }
            assertTrue(
                "$label must retain history deeper than the viewport: " +
                    "history=${transcriptRows(surface)} rows=${viewportRows(surface)}",
                transcriptRows(surface) > viewportRows(surface),
            )
        }

        fun diagnosticsSinceStart(): String = diagnostics.read().drop(diagnosticsPrefix)

        /** The rows the primary surface shows at its scroll position (main thread). */
        fun viewportTextNow(): String {
            val view = surface.view
            val emulator = view.mEmulator
            val top = view.topRow
            return emulator.screen.getSelectedText(0, top, emulator.mColumns, top + emulator.mRows - 1, false)
        }

        suspend fun awaitDiagnostic(fragment: String) {
            awaitValue("diagnostic $fragment") {
                diagnostics.read().drop(diagnosticsPrefix).takeIf { it.contains(fragment) }
            }
        }

        suspend fun awaitHistoryPresentationAcknowledged(surfaceId: String, deliveryToken: Long) {
            val accepted =
                "render_history_presentation_acknowledged detail=surface=$surfaceId " +
                    "delivery=$deliveryToken "
            awaitValue("accepted history presentation surface=$surfaceId delivery=$deliveryToken") {
                diagnostics.read()
                    .drop(diagnosticsPrefix)
                    .lineSequence()
                    .firstOrNull { it.contains(accepted) }
            }
        }

        suspend fun transcriptRows(): Int = onMain {
            surface.view.mEmulator.screen.activeTranscriptRows
        }

        suspend fun viewportRows(): Int = onMain { surface.view.mEmulator.mRows }

        suspend fun latestHeartbeat(marker: String): Long = onMain {
            heartbeatPattern(marker).findAll(transcriptNow(surface))
                .maxOfOrNull { match -> match.groupValues[1].toLong() }
                ?: 0L
        }

        suspend fun awaitHeartbeatAfter(marker: String, previous: Long) {
            awaitValue("Mosh painter heartbeat after side-channel drop") {
                latestHeartbeat(marker).takeIf { it > previous }
            }
        }

        /** The primary surface's full transcript, scrollback included. */
        suspend fun transcriptText(): String = transcript(surface)

        private suspend fun transcript(): String = transcript(surface)

        private suspend fun transcript(surface: TermuxTerminalSurface): String = onMain {
            transcriptNow(surface)
        }

        private fun transcriptNow(surface: TermuxTerminalSurface): String {
            val emulator = surface.view.mEmulator
            val history = emulator.screen.activeTranscriptRows
            return emulator.screen.getSelectedText(0, -history, emulator.mColumns, emulator.mRows, false)
        }

        private suspend fun transcriptRows(surface: TermuxTerminalSurface): Int = onMain {
            surface.view.mEmulator.screen.activeTranscriptRows
        }

        private suspend fun viewportRows(surface: TermuxTerminalSurface): Int = onMain { surface.view.mEmulator.mRows }

        suspend fun <T> onMain(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }

        suspend fun withDiagnosticContext(
            failure: AssertionError,
            targetSurface: TermuxTerminalSurface? = null,
        ): AssertionError {
            val snapshot = controller.tmuxSnapshot.value
            val recentDiagnostics = diagnostics.read().drop(diagnosticsPrefix).takeLast(65_536)
            val surfaceState = onMain {
                val text = transcriptNow(surface)
                "owner=${surface.boundOwner}; rows=${surface.view.mEmulator.screen.activeTranscriptRows}; " +
                    "viewport=${surface.view.mEmulator.mRows}; transcript=${text.takeLast(2_048)}"
            }
            val targetState = targetSurface?.let { target ->
                onMain {
                    val text = transcriptNow(target)
                    "; targetSurface=owner=${target.boundOwner}; " +
                        "rows=${target.view.mEmulator.screen.activeTranscriptRows}; " +
                        "viewport=${target.view.mEmulator.mRows}; transcript=${text.takeLast(2_048)}"
                }
            }.orEmpty()
            return AssertionError(
                "${failure.message}; controller=${controller.state.value}; " +
                    "snapshot=${snapshot?.rawJson?.decodeToString() ?: "none"}; " +
                    "surface=$surfaceState$targetState; diagnostics=$recentDiagnostics",
                failure,
            )
        }

        suspend fun close(awaitMoshCleanup: Boolean = false) {
            // Every controller writes to the same diagnostic file. An older
            // controller's cleanup receipt cannot settle this close.
            val cleanupOffset = diagnostics.read().length
            try {
                runOnMain {
                    try { controller.close() } finally { surface.close() }
                }
                if (awaitMoshCleanup) {
                    awaitValue("fresh Mosh cleanup receipt") {
                        diagnostics.read().drop(cleanupOffset)
                            .takeIf { it.contains("mosh_explicit_cleanup_succeeded") }
                    }
                }
            } finally {
                agentSessions.close()
                authentication.cancel()
                scope.cancel()
            }
        }
    }

    /**
     * A flick is at rest once its history request has settled, no glide is
     * running and the viewport holds still for [REST_POLLS] polls. The settle
     * can hand the deferred release velocity to a fresh glide, so a cleared
     * request alone can still be moving.
     */
    private suspend fun awaitFlickAtRest(label: String, session: LiveController) {
        var last = Float.NaN
        var stillPolls = 0
        awaitValue(label) {
            val position = session.onMain {
                session.surface.view
                    .takeIf { !it.isHistoryScrollPending && !it.isGliding }
                    ?.scrollPositionPixels
            }
            stillPolls = if (position != null && position == last) stillPolls + 1 else 0
            last = position ?: Float.NaN
            true.takeIf { stillPolls >= REST_POLLS }
        }
    }

    /**
     * Writes a test's in-memory evidence when an await times out, before the
     * failure unwinds. On the Android 16 emulator, ART aborted the whole
     * process while that AssertionError unwound through the foreground-drift
     * test's suspend lambda ("No pending exception expected"), so the test's
     * own `finally` never wrote its diagnostics.
     */
    @Volatile private var awaitTimeoutEvidence: ((String) -> Unit)? = null

    private suspend fun <T> awaitValue(label: String, value: suspend () -> T?): T {
        try {
            return withTimeout(AWAIT_MILLISECONDS) {
                while (true) {
                    value()?.let { return@withTimeout it }
                    delay(POLL_MILLISECONDS)
                }
                error("unreachable")
            }
        } catch (failure: TimeoutCancellationException) {
            awaitTimeoutEvidence?.let { write -> runCatching { write(label) } }
            throw AssertionError("timed out waiting for $label", failure)
        }
    }

    private class IsolationHostRepository(private val host: SavedHost) : HostRepository {
        private val hosts = MutableStateFlow(listOf(host))
        override val loadedHosts: StateFlow<List<SavedHost>?> = hosts
        override fun observeHosts(): Flow<List<SavedHost>> = hosts
        override suspend fun host(id: String): SavedHost? = hosts.value.firstOrNull { it.id == id }
        override suspend fun save(draft: HostDraft): SavedHost = error("fixture controller must not persist hosts")
        override suspend fun delete(id: String): Boolean = false
        override suspend fun resolveRoute(hostId: String): List<SavedHost> = listOf(host).takeIf { host.id == hostId }
            ?: error("fixture route host missing")
    }

    private class IsolationIdentityRepository : IdentityRepository {
        private val identities = MutableStateFlow<List<SavedIdentity>>(emptyList())
        override val loadedIdentities: StateFlow<List<SavedIdentity>?> = identities
        override fun observeIdentities(): Flow<List<SavedIdentity>> = identities
        override suspend fun identity(id: String): SavedIdentity? = null
        override suspend fun save(
            displayName: String,
            credentialKind: String,
            credentialReference: String,
            id: String?,
        ): SavedIdentity = error("fixture controller must not persist identities")
        override suspend fun delete(id: String): Boolean = false
    }

    private class IsolationKnownHostsRepository : KnownHostsRepository {
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

    private class IsolationRestoreRepository : SessionRestoreRepository {
        override fun observeRecords(): Flow<List<SessionRestoreRecord>> = MutableStateFlow(emptyList())
        override suspend fun records(): List<SessionRestoreRecord> = emptyList()
        override suspend fun record(sessionId: String): SessionRestoreRecord? = null
        override suspend fun save(record: SessionRestoreRecord) = Unit
        override suspend fun delete(sessionId: String) = Unit
        override suspend fun deleteForHost(hostId: String) = Unit
        override suspend fun deleteAll() = Unit
    }

    private companion object {
        const val FIXTURE_PATH = "/data/local/tmp/tessera-native-ssh-fixture.properties"
        const val AWAIT_MILLISECONDS = 45_000L
        const val POLL_MILLISECONDS = 50L
        /** A show's read settles within a claim's fence and repaint; mosh can take seconds. */
        const val SHOW_DECISION_TIMEOUT_MS = 15_000L
        /** Polls a flicked viewport must hold still for to count as at rest. */
        const val REST_POLLS = 4
    }
}

private fun String.sanitizeTmuxTarget(): String = replace(Regex("[^A-Za-z0-9_.-]"), "-").take(80)

private fun heartbeatPattern(marker: String): Regex =
    Regex("${Regex.escape(marker)}-HEARTBEAT-(\\d+)")

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
