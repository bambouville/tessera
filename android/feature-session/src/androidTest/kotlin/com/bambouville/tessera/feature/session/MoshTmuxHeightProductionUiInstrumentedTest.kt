package com.bambouville.tessera.feature.session

import android.content.Intent
import android.graphics.Bitmap
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.os.Process
import android.util.Log
import androidx.lifecycle.Lifecycle
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.AndroidAgentSessionCoordinator
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationCoordinator
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.core.bridge.SharedTmuxAuthoritySessionState
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxGridSize
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
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.feature.session.bell.AndroidBellController
import com.bambouville.tessera.feature.session.bell.BellPreferences
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteOwner
import com.bambouville.tessera.networking.SshRouteRequest
import com.bambouville.tessera.networking.mosh.JniMoshNativeClientFactory
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.terminal.GeometryNeutralTerminalViewport
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import java.io.File
import java.util.Properties
import java.util.UUID
import java.util.concurrent.atomic.AtomicReference
import com.bambouville.tessera.networking.mosh.AndroidMoshTransport
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Uses the actual session screen and its surface, geometry callbacks, chrome and IME policy. */
@RunWith(AndroidJUnit4::class)
class MoshTmuxHeightProductionUiInstrumentedTest {
    @Test
    fun liveProductionScreenRepairsVerticalWindowDrift(): Unit = runBlocking {
        assumeTrue("native Mosh is required", JniMoshNativeClientFactory.isAvailable)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val fixture = readFixture()
        val resizeKeyboard = when (val argument = InstrumentationRegistry.getArguments().getString("resizeKeyboard")) {
            null, "false" -> false
            "true" -> true
            else -> error("resizeKeyboard must be true or false, received $argument")
        }
        val token = UUID.randomUUID().toString().replace("-", "").take(8)
        val target = fixture.session
        require(target.matches(Regex("[A-Za-z0-9_.-]+")))
        val viewTarget = "$target-view"
        val directory = "/tmp/$target"
        val host = SavedHost(id = UUID.randomUUID().toString(), displayName = "Height fixture $token",
            hostname = fixture.host, port = fixture.port, username = fixture.user, jumpHostId = null,
            identityId = null, transportKind = TransportKinds.MOSH, tmuxMode = TmuxModes.PINNED, tmuxTarget = target)
        val hosts = FixtureHosts(host)
        val identities = FixtureIdentities()
        val knownHosts = FixtureKnownHosts()
        val restore = FixtureRestore()
        val sessions = LiveSessionStore.get()
        val registry = LiveAgentSessionRegistry()
        val coordinator = AndroidAgentSessionCoordinator(registry)
        val integration = AgentSessionIntegrationCoordinator(coordinator.directory, sessions.scope, coordinator)
        val bell = AndroidBellController(context)
        val credentials = AndroidKeystoreCredentialStore()
        val presented = mutableStateOf(true)
        val diagnostics = DiagnosticLogStore(context)
        val logStart = diagnostics.read().length
        val evidence = File(context.filesDir, "height-production-ui").apply { mkdirs() }
        val states = JSONArray()
        var activity: ComponentActivity? = null
        var controller: SshSessionController? = null
        var probe: SshRouteOwner? = null
        var prepared = false
        var auth: kotlinx.coroutines.Job? = null
        var primaryFailure: Throwable? = null
        var driftFailure: Throwable? = null
        var exactMoshPid: Int? = null
        var exactMoshStart: String? = null
        var displayResized = false
        suspend fun exec(command: String): String {
            val output = requireNotNull(probe).executeBoundedCommand(command)
            check(output.exitStatus == 0) { "owned fixture command failed: ${output.standardError.take(300)}" }
            return output.standardOutput
        }
        fun ownController(): SshSessionController = requireNotNull(controller)
        fun surface(): TermuxTerminalSurface {
            val field = SshSessionController::class.java.getDeclaredField("terminalSurface").apply { isAccessible = true }
            return field.get(ownController()) as? TermuxTerminalSurface ?: error("screen has no attached native surface")
        }
        fun viewport(): GeometryNeutralTerminalViewport {
            fun visit(view: View): GeometryNeutralTerminalViewport? {
                if (view is GeometryNeutralTerminalViewport) return view
                if (view is ViewGroup) for (index in 0 until view.childCount) visit(view.getChildAt(index))?.let { return it }
                return null
            }
            return visit(requireNotNull(activity).window.decorView) ?: error("production geometry viewport is not mounted")
        }
        fun privateGrid(name: String): SharedTmuxGridSize? {
            val field = SshSessionController::class.java.getDeclaredField(name).apply { isAccessible = true }
            return field.get(ownController()) as? SharedTmuxGridSize
        }
        fun nativeState(): JSONObject {
            val terminal = surface()
            val view = viewport()
            val metrics = terminal.gridMetrics()
            val native = terminal.snapshotNonSecretState()
            val requested = privateGrid("lastTmuxViewport")
            val client = privateGrid("lastPublishedTmuxSize")
            val canvas = ownController().moshCanvasSize.value
            val location = IntArray(2).also(view::getLocationOnScreen)
            val insets = ViewCompat.getRootWindowInsets(requireNotNull(activity).window.decorView)
            return JSONObject().put("uptimeMs", SystemClock.uptimeMillis())
                .put("viewportWidthPixels", view.width).put("viewportHeightPixels", view.height)
                .put("viewportX", location[0]).put("viewportY", location[1])
                .put("physicalColumns", metrics.columnsFor(view.width)).put("physicalRows", metrics.rowsFor(view.height))
                .put("cellWidthPixels", metrics.cellWidthPixels).put("cellHeightPixels", metrics.cellHeightPixels)
                .put("firstBaselineInsetPixels", metrics.firstBaselineInsetPixels)
                .put("requestedColumns", requested?.columns).put("requestedRows", requested?.rows)
                .put("publishedClientColumns", client?.columns).put("publishedClientRows", client?.rows)
                .put("nativeColumns", native.columns).put("nativeRows", native.rows)
                .put("canvasColumns", canvas?.columns).put("canvasRows", canvas?.rows)
                .put("authority", ownController().tmuxAuthority.value.toString())
                .put("owner", terminal.boundOwner.toString()).put("visibleText", terminal.snapshotText()?.visibleText ?: "")
                .put("imeBottomPixels", insets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0)
                .put("activityLifecycle", requireNotNull(activity).lifecycle.currentState.name)
                .put("presented", presented.value)
                .put("framePending", terminal.snapshotText()?.framePending ?: true)
                .put("scrollRoute", terminal.view.scrollRoute().toString())
        }
        suspend fun serverState(): JSONObject {
            val output = exec("tmux display-message -p -t '=$viewTarget:0.0' " +
                "'GRID|#{window_id}|#{pane_id}|#{window_width}|#{window_height}|#{pane_width}|#{pane_height}|#{@tessera_authority}|#{status}'; " +
                "tmux list-clients -t '=$viewTarget' -F 'CLIENT|#{client_name}|#{client_session}|#{client_width}|#{client_height}|#{client_flags}|#{client_control_mode}'")
            val grid = output.lineSequence().first { it.startsWith("GRID|") }.split('|')
            return JSONObject().put("windowId", grid[1]).put("paneId", grid[2])
                .put("windowColumns", grid[3].toInt()).put("windowRows", grid[4].toInt())
                .put("paneColumns", grid[5].toInt()).put("paneRows", grid[6].toInt())
                .put("authorityStamp", grid[7]).put("status", grid[8])
                .put("clients", JSONArray(output.lineSequence().filter { it.startsWith("CLIENT|") }.toList()))
        }
        suspend fun sample(phase: String): JSONObject {
            val local = onMain { nativeState() }
            val remote = serverState()
            val record = JSONObject().put("phase", phase).put("local", local).put("remote", remote)
            states.put(record)
            File(evidence, "geometry.json").writeText(JSONObject().put("token", token).put("target", target)
                .put("viewTarget", viewTarget).put("ownedDirectory", directory).put("resizeKeyboard", resizeKeyboard).put("phases", states).toString(2))
            return record
        }
        fun sameLocal(a: JSONObject, b: JSONObject): Boolean = listOf(
            "viewportWidthPixels", "viewportHeightPixels", "viewportX", "viewportY", "physicalColumns", "physicalRows",
            "requestedColumns", "requestedRows", "publishedClientColumns", "publishedClientRows", "nativeColumns", "nativeRows",
            "canvasColumns", "canvasRows", "authority", "owner", "visibleText", "imeBottomPixels", "scrollRoute", "presented",
        ).all { a.opt(it) == b.opt(it) } && !b.getBoolean("framePending")
        fun sameRemote(a: JSONObject, b: JSONObject): Boolean = listOf(
            "windowId", "paneId", "windowColumns", "windowRows", "paneColumns", "paneRows", "authorityStamp", "status",
        ).all { a.opt(it) == b.opt(it) } && a.getJSONArray("clients").toString() == b.getJSONArray("clients").toString()
        suspend fun capture(phase: String): JSONObject {
            // Bounded and spaced: the repair a phase sets off (a window force,
            // its painter handoffs) settles within a few frames, which three
            // back-to-back attempts could all fall inside.
            val attempts = 8
            repeat(attempts) { attempt ->
                if (attempt > 0) delay(40)
                val pre = onMain { nativeState() }
                if (pre.getBoolean("framePending")) return@repeat
                val remotePre = serverState()
                val drawn = AtomicReference<JSONObject?>()
                val committedDraw = AtomicReference<JSONObject?>()
                val registered = AtomicReference<android.view.ViewTreeObserver?>()
                val commits = JSONArray()
                val onDraw = android.view.ViewTreeObserver.OnDrawListener { drawn.set(nativeState()) }
                var animationTime = 0L
                try {
                    val observer = onMain {
                        val view = surface().view
                        check(view.isHardwareAccelerated && view.isAttachedToWindow && view.isShown)
                        view.viewTreeObserver.also { registered.set(it); it.addOnDrawListener(onDraw) }
                    }
                    repeat(2) {
                        val committed = CompletableDeferred<Long>()
                        val animation = CompletableDeferred<Long>()
                        val onCommit = Runnable { committedDraw.set(drawn.get()); committed.complete(SystemClock.uptimeMillis()) }
                        val onAnimation = Runnable { animation.complete(SystemClock.uptimeMillis()) }
                        try {
                            onMain { observer.registerFrameCommitCallback(onCommit); surface().view.invalidate() }
                            commits.put(withTimeout(2_000) { committed.await() })
                            onMain { surface().view.postOnAnimation(onAnimation) }
                            animationTime = withTimeout(2_000) { animation.await() }
                        } finally {
                            committed.cancel(); animation.cancel()
                            withContext(NonCancellable) { onMain {
                                if (observer.isAlive) observer.unregisterFrameCommitCallback(onCommit)
                                surface().view.removeCallbacks(onAnimation)
                            } }
                        }
                    }
                    val draw = committedDraw.get()
                    if (draw == null || !sameLocal(pre, draw) || !sameLocal(pre, onMain { nativeState() })) return@repeat
                    val remoteBeforeScreenshot = serverState()
                    if (!sameRemote(remotePre, remoteBeforeScreenshot)) return@repeat
                    val screenshotTime = SystemClock.uptimeMillis()
                    val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
                    try {
                        val post = onMain { nativeState() }
                        val remotePost = serverState()
                        if (!sameLocal(pre, post) || !sameRemote(remotePre, remotePost)) return@repeat
                        File(evidence, "$phase.png").outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
                        File(evidence, "$phase-rows.txt").writeText(post.getString("visibleText"))
                        val record = JSONObject().put("phase", phase).put("local", post).put("remote", remotePost)
                            .put("preCapture", pre).put("drawn", draw).put("postCapture", post)
                            .put("remotePreCapture", remotePre).put("remotePostCapture", remotePost)
                            .put("hardwareFrameCommitUptimeMs", commits).put("afterCommitAnimationUptimeMs", animationTime)
                            .put("screenshotUptimeMs", screenshotTime).put("captureAttempts", attempt + 1)
                            .put("preDrawPostMatched", true).put("remotePrePostMatched", true)
                        states.put(record)
                        File(evidence, "geometry.json").writeText(JSONObject().put("token", token).put("target", target)
                            .put("viewTarget", viewTarget).put("ownedDirectory", directory).put("resizeKeyboard", resizeKeyboard).put("phases", states).toString(2))
                        return record
                    } finally { bitmap.recycle() }
                } finally {
                    withContext(NonCancellable) { onMain { registered.get()?.takeIf { it.isAlive }?.removeOnDrawListener(onDraw) } }
                }
            }
            error("$phase changed across all $attempts bounded hardware-commit capture attempts")
        }
        suspend fun mount() {
            val mounted = instrumentation.startActivitySync(Intent(context, ComponentActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as ComponentActivity
            activity = mounted
            onMain {
                mounted.enableEdgeToEdge()
                mounted.window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
                mounted.setContent {
                    TesseraTheme {
                        SshSessionScreen(host, hosts, identities, knownHosts, restore, credentials, bell,
                            BellPreferences(false, false, false), registry, integration, sessions,
                            modifier = Modifier.fillMaxSize(), terminalTextSizeSp = 10,
                            resizeTerminalWithKeyboard = resizeKeyboard, isPresented = presented.value,
                            liveSessionId = host.id, onBack = {})
                    }
                }
            }
            await("screen-owned controller") { onMain { sessions.isLive(host.id) } }
            controller = onMain { sessions.controller(LiveSessionStore.ControllerKey(host.id, host.id, null, null)) {
                error("screen must construct the real controller")
            } }
        }
        suspend fun hideInitialIme() {
            delay(200) // Production connected/presentation effect first requests its keyboard.
            onMain {
                val view = surface().view
                ViewCompat.getWindowInsetsController(view)?.hide(WindowInsetsCompat.Type.ime())
                context.getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(view.windowToken, 0)
            }
            await("default fixture IME hidden") { onMain { nativeState().getInt("imeBottomPixels") == 0 } }
            delay(200)
        }
        suspend fun finishMountedActivity() {
            val mounted = activity ?: return
            onMain { mounted.finish() }
            await("fixture Activity actually destroyed", 5_000) { onMain { mounted.lifecycle.currentState == Lifecycle.State.DESTROYED } }
            delay(80)
        }
        suspend fun exactLocalGrid(): Boolean = onMain {
            val s = nativeState()
            listOf("physical", "requested", "publishedClient", "native", "canvas").all {
                s.optInt(it + "Columns") == 56 && s.optInt(it + "Rows") == 48
            }
        }
        try {
            probe = AndroidSshBackend().openRoute(request = SshRouteRequest(hops = listOf(SshRouteHop(
                id = "height-$token", endpoint = SshEndpoint(fixture.host, fixture.port), username = fixture.user,
                authentication = SshAuthentication.Password))), passwordProvider = SshPasswordProvider { fixture.password.toCharArray() }, hostKeyPolicy = SshHostKeyPolicy { true })
            prepared = true
            File(evidence, "ownership.json").writeText(JSONObject().put("target", target).put("viewTarget", viewTarget)
                .put("directory", directory).put("ownerMarker", token).put("appPid", Process.myPid()).toString(2))
            exec("mkdir ${quote(directory)} && printf '%s\\n' '$token' > ${quote("$directory/.owner")}")
            val program = """
                import os,signal,time,tty
                tty.setraw(0)
                running=True
                def stop(*args):
                    global running
                    running=False
                signal.signal(signal.SIGTERM,stop)
                print('\\x1b[?1049h\\x1b[?25l',end='',flush=True)
                try:
                    while running:
                        c,r=os.get_terminal_size()
                        lines=['+'+'-'*(c-2)+'+']
                        for y in range(2,r):
                            text='HEIGHT-$token-%02d ROW-%02d COL-%02d'%(r,y,c)
                            lines.append('|'+text[:c-2].ljust(c-2)+'|')
                        lines.append('+'+('BOTTOM-$token-%02d'%r).ljust(c-2,'-')+'+')
                        print('\\x1b[H'+'\\r\\n'.join(lines),end='',flush=True)
                        time.sleep(.15)
                finally:
                    print('\\x1b[?25h\\x1b[?1049l',end='',flush=True)
            """.trimIndent().replace("\\\\", "\\")
            exec("printf '%s' ${quote(program)} > ${quote("$directory/tui.py")}; " +
                "tmux new-session -d -s '$target' -x 56 -y 48 ${quote("exec python3 $directory/tui.py")}; " +
                "tmux set-option -t '$target' status off; tmux set-option -t '$target' window-size latest; " +
                "pid=\$(tmux display-message -p -t '=$target:0.0' '#{pane_pid}'); " +
                "printf '%s %s\\n' \"\$pid\" \"\$(awk '{print \$22}' /proc/\$pid/stat)\" > ${quote("$directory/pid")}")
            mount()
            auth = sessions.scope.launch {
                ownController().state.collect { state -> when (state) {
                    is SshSessionUiState.AwaitingCredential -> ownController().submitPassword(fixture.password)
                    is SshSessionUiState.AwaitingHostKey -> ownController().decideHostKey(true)
                    else -> Unit
                } }
            }
            onMain { ownController().connect() }
            await("production screen connected") { ownController().state.value == SshSessionUiState.Connected }
            await("real production GeometryNeutralTerminalViewport") { onMain { runCatching { viewport().isAttachedToWindow }.getOrDefault(false) } }
            hideInitialIme()
            // Calibrate the whole disposable display. The full screen still lays out its own chrome and viewport.
            for (calibration in 0..3) {
                sample("calibration-$calibration")
                if (exactLocalGrid()) break
                if (!exactLocalGrid()) {
                    val dimensions = onMain {
                        val view = viewport(); val metrics = surface().gridMetrics()
                        val root = requireNotNull(activity).window.decorView
                        Pair(root.width + metrics.pixelWidth(56) - view.width,
                            root.height + metrics.pixelHeight(48) - view.height)
                    }
                    require(dimensions.first in 500..2000 && dimensions.second in 1000..3500)
                    finishMountedActivity()
                    displayResized = true
                    shell("wm size ${dimensions.first}x${dimensions.second}")
                    delay(500)
                    mount()
                    await("calibrated screen viewport") { onMain { runCatching { viewport().width > 0 }.getOrDefault(false) } }
                    hideInitialIme()
                }
            }
            await("all real local grids56x48") { exactLocalGrid() }
            await("initial owned layout56x48") {
                val w = ownController().tmuxSnapshot.value?.activeWindow
                ownController().tmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Mine && w?.layout?.width == 56 && w?.layout?.height == 48
            }
            await("real bottom48-row SSP content") { onMain { surface().snapshotText()?.visibleText?.contains("BOTTOM-$token-48") == true } }
            val carrier = SshSessionController::class.java.getDeclaredField("moshTransport").apply { isAccessible = true }
                .get(ownController()) as AndroidMoshTransport
            exactMoshPid = requireNotNull(carrier.bootstrapServerPid)
            exactMoshStart = exec("awk '{print ${'$'}22}' /proc/$exactMoshPid/stat").trim()
            File(evidence, "ownership.json").writeText(JSONObject().put("target", target).put("viewTarget", viewTarget)
                .put("directory", directory).put("ownerMarker", token).put("moshPid", exactMoshPid)
                .put("moshStart", exactMoshStart).put("appPid", Process.myPid()).toString(2))
            fun replayAgeMillis(): Long {
                val field = SshSessionController::class.java.getDeclaredField("lastDeliveredTmuxClientSizeAtMillis").apply { isAccessible = true }
                // The controller stamps deliveries on the elapsed-realtime clock.
                return SystemClock.elapsedRealtime() - (field.get(ownController()) as? Long ?: error("missing actual natural size replay"))
            }
            val memo = runCatching { SshSessionController::class.java.getDeclaredField("forcedTmuxWindowSizes").apply { isAccessible = true }.get(ownController()) as Map<*, *> }.getOrNull()
            memo?.let { assertEquals("owned window has memoized the actual56x48 force", SharedTmuxGridSize(56, 48), it[ownController().tmuxSnapshot.value?.activeWindowId]) }
            sample("force-memo-before-drift").put("memo", memo.toString()).put("replayAgeMillis", replayAgeMillis())
            assertTrue("fresh natural UI size replay needed to isolate memo from stampless-peer grace", replayAgeMillis() < 1_400)
            val before = capture("01-before-drift")
            val originalStamp = before.getJSONObject("remote").getString("authorityStamp")
            assertTrue("initial owned authority stamp must be nonempty", originalStamp.isNotEmpty())
            assertEquals("view status consumes no rows", "off", before.getJSONObject("remote").getString("status"))
            val clientsBefore = before.getJSONObject("remote").getJSONArray("clients")
            val clients = (0 until clientsBefore.length()).map { clientsBefore.getString(it).split('|') }
            assertEquals("exact view must have two real clients", 2, clients.size)
            val control = clients.single { it[6] == "1" }
            val painter = clients.single { it[6] != "1" }
            assertEquals("control client columns", "56", control[3])
            assertTrue("control-mode height is either reported48 or unavailable on tmux3.4", control[4].isEmpty() || control[4] == "48")
            assertEquals("real visible carrier columns", "56", painter[3]); assertEquals("real visible carrier rows", "48", painter[4])
            before.put("controlClientRowsObservation", if (control[4].isEmpty()) "unavailable for ttyless control client" else control[4])
            // Program status is on in production, so the side channel streams
            // pane output for its reports; the Mosh carrier still paints.
            assertFalse("program status streams the side channel's pane output", control[5].contains("no-output"))
            assertTrue("visible Mosh ignores shared-session size", painter[5].contains("ignore-size"))
            val mineBefore = ownController().tmuxAuthority.value as SharedTmuxGridAuthoritySnapshot.Mine
            onMain { surface().sendInput("x".encodeToByteArray()) }
            delay(80)
            assertTrue("baseline screenshot and key stay within actual2s replay grace", replayAgeMillis() < 2_000)
            val driftLogStart = diagnostics.read().length
            val driftStartedAt = SystemClock.uptimeMillis()
            // The server's real layout-change notification is the sole reconciliation trigger.
            val injection = exec("tmux resize-window -t '=$target:0' -x 56 -y 46 \\; " +
                "display-message -p -t '=$target:0.0' 'DRIFT|#{window_width}|#{window_height}|#{pane_width}|#{pane_height}'")
            assertTrue("the owned remote window and pane must actually reach56x46", injection.lineSequence().any { it.trim() == "DRIFT|56|46|56|46" })
            File(evidence, "drift-injection.json").writeText(JSONObject().put("observed", injection.trim())
                .put("startedUptimeMs", driftStartedAt).put("replayAgeMillis", replayAgeMillis())
                .put("authorityBefore", mineBefore.toString()).toString(2))
            assertEquals("drift must not initially yield to a different client", mineBefore, ownController().tmuxAuthority.value)
            val drift = capture("02-remote-height-drift")
            assertEquals("drift keeps the exact control/painter identities", clientsBefore.toString(), drift.getJSONObject("remote").getJSONArray("clients").toString())
            assertEquals("drift retains own authority stamp", originalStamp, drift.getJSONObject("remote").getString("authorityStamp"))
            val remainingRepairMillis = (3_000 - (SystemClock.uptimeMillis() - driftStartedAt)).coerceAtLeast(1)
            val recovered = withTimeoutOrNull(remainingRepairMillis) {
                while (true) {
                    val remote = serverState()
                    if (remote.getInt("windowRows") == 48 && remote.getInt("paneRows") == 48 &&
                        remote.getString("authorityStamp") == originalStamp && exactLocalGrid() &&
                        ownController().tmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Mine &&
                        onMain { surface().snapshotText()?.visibleText?.contains("BOTTOM-$token-48") == true }) break
                    delay(40)
                }
                true
            } == true
            capture("03-after-normal-reconciliation").put("elapsedSinceDriftMs", SystemClock.uptimeMillis() - driftStartedAt)
                .put("freshDriftDiagnostics", diagnostics.read().drop(driftLogStart))
            if (!recovered) driftFailure = AssertionError("ordinary height repair failed within3s; physical/requested/native/canvas56x48 vs remote window/pane46; see geometry.json")
            // Keep foreground recovery independent and preserve before evidence even if ordinary repair failed.
            onMain { presented.value = false }
            shell("input keyevent KEYCODE_HOME")
            await("actual Activity stopped by Home") { onMain { requireNotNull(activity).lifecycle.currentState == Lifecycle.State.CREATED } }
            exec("tmux resize-window -t '=$target:0' -x 56 -y 45")
            sample("04-hidden-height45")
            // §6.9: only a hide longer than the debounce makes the return a
            // show, and only a show claims; a shorter interval is transparent
            // and a bare foreground would yield to the drifted size. Wait for
            // the screen's hide edge to reach the controller, so the return
            // below is deterministically a show.
            val sessionState = SshSessionController::class.java.getDeclaredField("lastTmuxAuthorityResult").apply { isAccessible = true }
            await("screen hide edge delivered after the debounce", LiveSessionStore.HIDE_DEBOUNCE_MILLIS + 5_000) {
                onMain { (sessionState.get(ownController()) as? SharedTmuxAuthoritySessionState)?.hidden == true }
            }
            val showLogStart = diagnostics.read().length
            onMain {
                val mounted = requireNotNull(activity)
                mounted.startActivity(Intent(mounted, ComponentActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                presented.value = true
            }
            await("actual Activity resumed") { onMain { requireNotNull(activity).lifecycle.currentState == Lifecycle.State.RESUMED } }
            await("screen show edge repairs height48", 5_000) {
                val remote = serverState()
                remote.getInt("windowRows") == 48 && remote.getInt("paneRows") == 48 && exactLocalGrid() &&
                    ownController().tmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Mine
            }
            val showLog = diagnostics.read().drop(showLogStart)
            assertTrue("the return's repair was not the show's claim: $showLog",
                showLog.contains("event=shown") && showLog.contains(":show/awaitingFence"))
            hideInitialIme()
            capture("05-visible-recovered")
            onMain { surface().requestSoftwareKeyboard() }
            await("actual production IME visible") { onMain { nativeState().getInt("imeBottomPixels") > 0 } }
            delay(350)
            if (resizeKeyboard) {
                await("resizing IME converges all actual local and remote grids", 8_000) {
                    val local = onMain { nativeState() }
                    val rows = local.getInt("physicalRows")
                    val remote = serverState()
                    rows in 2 until 48 && local.getInt("physicalColumns") == 56 &&
                        listOf("requested", "publishedClient", "native", "canvas").all {
                            local.getInt(it + "Columns") == 56 && local.getInt(it + "Rows") == rows
                        } && remote.getInt("windowColumns") == 56 && remote.getInt("windowRows") == rows &&
                        remote.getInt("paneColumns") == 56 && remote.getInt("paneRows") == rows &&
                        ownController().tmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Mine &&
                        local.getString("visibleText").contains("BOTTOM-$token-${rows.toString().padStart(2, '0')}")
                }
            } else {
                assertTrue("nonresizing production IME preserves all grids", exactLocalGrid())
            }
            capture("06-ime-visible")
            onMain {
                val view = surface().view
                context.getSystemService(InputMethodManager::class.java).hideSoftInputFromWindow(view.windowToken, 0)
            }
            await("actual IME hidden") { onMain { nativeState().getInt("imeBottomPixels") == 0 } }
            await("IME hide returns all actual grids and SSP content to48 rows", 8_000) {
                val remote = serverState()
                exactLocalGrid() && remote.getInt("windowColumns") == 56 && remote.getInt("windowRows") == 48 &&
                    remote.getInt("paneColumns") == 56 && remote.getInt("paneRows") == 48 &&
                    ownController().tmuxAuthority.value is SharedTmuxGridAuthoritySnapshot.Mine &&
                    onMain { surface().snapshotText()?.visibleText?.contains("BOTTOM-$token-48") == true }
            }
            capture("07-ime-hidden")
            driftFailure?.let { throw it }
        } catch (failure: Throwable) {
            primaryFailure = failure
            Log.e("TesseraHeightFixture", "owned fullUI fixture failed before cleanup: ${failure.message}", failure)
            File(evidence, "primary-failure.txt").writeText(failure.stackTraceToString())
            runCatching { capture("failure") }.exceptionOrNull()?.let(failure::addSuppressed)
        } finally {
            withContext(NonCancellable) {
                val failures = mutableListOf<Throwable>()
                fun cleanupStage(stage: String) {
                    File(evidence, "cleanup-stages.jsonl").appendText(JSONObject().put("stage", stage)
                        .put("uptimeMs", SystemClock.uptimeMillis()).toString() + "\n")
                }
                cleanupStage("entered")
                val cleanupRead = runCatching { diagnostics.read().length }
                cleanupRead.exceptionOrNull()?.let(failures::add)
                val cleanupOffset = cleanupRead.getOrDefault(logStart)
                cleanupStage("finish-activity")
                runCatching { finishMountedActivity() }.exceptionOrNull()?.let(failures::add)
                // Later tests in the run need the emulator's own display size.
                if (displayResized) runCatching { restoreDisplaySize() }.exceptionOrNull()?.let(failures::add)
                cleanupStage("close-controller")
                runCatching { onMain { sessions.close(host.id) } }.exceptionOrNull()?.let(failures::add)
                cleanupStage("carrier-receipt")
                if (exactMoshPid != null) runCatching {
                    await("this carrier's fresh Mosh cleanup receipt", 20_000) {
                        diagnostics.read().drop(cleanupOffset).contains("mosh_explicit_cleanup_succeeded")
                    }
                    val process = exec("if [ -r /proc/$exactMoshPid/stat ]; then awk '{print ${'$'}3, ${'$'}22}' /proc/$exactMoshPid/stat; fi").trim().split(' ')
                    check(process.size != 2 || process[1] != exactMoshStart || process[0] == "Z") { "exact owned Mosh server still alive after cleanup receipt" }
                }.exceptionOrNull()?.let(failures::add)
                cleanupStage("diagnostics")
                runCatching { File(evidence, "diagnostics.txt").writeText(diagnostics.read().drop(logStart)) }.exceptionOrNull()?.let(failures::add)
                runCatching { auth?.cancelAndJoin() }.exceptionOrNull()?.let(failures::add)
                cleanupStage("remote-resources")
                if (prepared && probe != null) runCatching {
                    exec("tmux kill-session -t '=$viewTarget' 2>/dev/null || true; tmux kill-session -t '=$target' 2>/dev/null || true; " +
                        "if tmux has-session -t '=$target' 2>/dev/null || tmux has-session -t '=$viewTarget' 2>/dev/null; then exit 1; fi; " +
                        "if [ -e ${quote(directory)} ]; then test \"\$(cat ${quote("$directory/.owner")})\" = '$token' || exit 1; " +
                        "if [ -f ${quote("$directory/pid")} ]; then read p s < ${quote("$directory/pid")}; " +
                        "if [ -r /proc/\$p/stat ] && [ \"\$(awk '{print \$22}' /proc/\$p/stat)\" = \"\$s\" ]; then kill -TERM \"\$p\"; fi; fi; " +
                        "rm -rf ${quote(directory)}; fi; test ! -e ${quote(directory)}")
                    File(evidence, "cleanup.json").writeText(JSONObject().put("target", target).put("viewTarget", viewTarget)
                        .put("directory", directory).put("verifiedAbsent", true).toString(2))
                }.exceptionOrNull()?.let(failures::add)
                runCatching { probe?.close() }.exceptionOrNull()?.let(failures::add)
                runCatching { integration.close(); coordinator.close(); bell.close() }.exceptionOrNull()?.let(failures::add)
                failures.forEach { primaryFailure?.addSuppressed(it) }
                cleanupStage("completed")
                primaryFailure?.let { File(evidence, "primary-failure.txt").writeText(it.stackTraceToString()) }
                if (primaryFailure == null && failures.isNotEmpty()) throw failures.first()
            }
        }
        primaryFailure?.let { throw it }
    }

    private suspend fun <T> onMain(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    private suspend fun await(label: String, timeout: Long = 30_000, predicate: suspend () -> Boolean) {
        check(withTimeoutOrNull(timeout) { while (!predicate()) delay(40); true } == true) { "timed out: $label" }
    }
    /**
     * Resets the display and restarts the input method. LatinIME keeps the
     * keyboard it measured on the resized display after `wm size reset` (787
     * instead of 916 px tall on the tablet), so a later case would lay out
     * around a keyboard this emulator never shows; a restarted IME measures
     * the restored display when it is next shown.
     */
    private suspend fun restoreDisplaySize() {
        shell("wm size reset")
        val ime = shell("settings get secure default_input_method").trim().substringBefore('/')
        check(Regex("[A-Za-z0-9_.]+").matches(ime)) { "unexpected default input method: $ime" }
        shell("am force-stop $ime")
        await("restarted input method $ime", 10_000) { shell("pidof $ime").isBlank() }
    }
    private fun quote(value: String): String = "'" + value.replace("'", "'\\''") + "'"
    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private fun readFixture(): Fixture {
        val path = "/data/local/tmp/tessera-native-ssh-fixture.properties"
        assumeTrue("push the permissioned native SSH fixture before this live case", shell("ls $path").trim() == path)
        val p = Properties().apply { load(shell("cat $path").reader()) }
        fun value(name: String) = requireNotNull(p.getProperty(name)).also { require(it.isNotBlank()) }
        return Fixture(value("stableHost"), value("port").toInt(), value("user"),
            android.util.Base64.decode(value("passwordBase64"), android.util.Base64.DEFAULT).decodeToString(), value("token"), value("renderLedgerSession"))
    }
    private data class Fixture(val host: String, val port: Int, val user: String, val password: String, val token: String, val session: String)
    private class FixtureHosts(private val host: SavedHost) : HostRepository {
        private val values = MutableStateFlow(listOf(host))
        override val loadedHosts: StateFlow<List<SavedHost>?> = values
        override fun observeHosts(): Flow<List<SavedHost>> = values
        override suspend fun host(id: String): SavedHost? = host.takeIf { it.id == id }
        override suspend fun save(draft: HostDraft): SavedHost = error("no fixture persistence")
        override suspend fun delete(id: String) = false
        override suspend fun resolveRoute(hostId: String): List<SavedHost> = listOf(requireNotNull(host(hostId)))
    }
    private class FixtureIdentities : IdentityRepository {
        private val values = MutableStateFlow<List<SavedIdentity>>(emptyList())
        override val loadedIdentities: StateFlow<List<SavedIdentity>?> = values
        override fun observeIdentities(): Flow<List<SavedIdentity>> = values
        override suspend fun identity(id: String): SavedIdentity? = null
        override suspend fun save(displayName: String, credentialKind: String, credentialReference: String, id: String?): SavedIdentity = error("no fixture persistence")
        override suspend fun delete(id: String) = false
    }
    private class FixtureKnownHosts : KnownHostsRepository {
        private val values = MutableStateFlow<List<SavedKnownHost>>(emptyList())
        override val loadedKnownHosts: StateFlow<List<SavedKnownHost>?> = values
        override fun observeKnownHosts(): Flow<List<SavedKnownHost>> = values
        override suspend fun evaluate(hostname: String, port: Int, algorithm: String, canonicalKeyBlob: ByteArray): HostTrustEvaluation = HostTrustEvaluation.Trusted
        override suspend fun trust(hostname: String, port: Int, algorithm: String, canonicalKeyBlob: ByteArray) = Unit
        override suspend fun forget(hostname: String, port: Int) = false
    }
    private class FixtureRestore : SessionRestoreRepository {
        override fun observeRecords(): Flow<List<SessionRestoreRecord>> = MutableStateFlow(emptyList())
        override suspend fun records(): List<SessionRestoreRecord> = emptyList()
        override suspend fun record(sessionId: String): SessionRestoreRecord? = null
        override suspend fun save(record: SessionRestoreRecord) = Unit
        override suspend fun delete(sessionId: String) = Unit
        override suspend fun deleteForHost(hostId: String) = Unit
        override suspend fun deleteAll() = Unit
    }
}
