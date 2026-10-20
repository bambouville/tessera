package com.bambouville.tessera.feature.session

import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityShowSource
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
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Live rig for "create a new tmux window" on **SSH+tmux**, the report from the
 * phone: the window really is created on the server, but the terminal keeps
 * painting the previous window and the switcher cannot move to the new one
 * either.
 *
 * The reported session had a second client attached to the same tmux session
 * ("I am looking at the tmux session on another device too"), so the rig
 * attaches a plain 160x48 `tmux attach` peer and drives the *product*
 * controller through creation with and without it. Each phase reports what
 * the snapshot, the render-surface owner and the grid authority did, and the
 * summary line `TESSERA_NEW_WINDOW_RIG` carries the verdicts a runner greps.
 */
@RunWith(AndroidJUnit4::class)
class TmuxNewWindowLiveInstrumentedTest {
    @Test
    fun liveSshTmuxNewWindowFollowsTheCreatedWindow(): Unit = runBlocking {
        val fixture = readFixture()
        assumeTrue("no rig fixture at $FIXTURE_PATH; the runner script pushes one", fixture != null)
        val target = fixture!!.session
        // Every remote command below splices the session name into a shell
        // string and an exact `pkill -xf` pattern.
        check(target.matches(Regex("[A-Za-z0-9_-]+"))) { "unsafe rig session: $target" }
        val verdicts = linkedMapOf<String, String>()
        var live: LiveController? = null
        try {
            prepareFixture(fixture, target, withPeer = true)
            val identity = TmuxDeviceIdentity("android-newwin-${UUID.randomUUID()}", "Android-Rig")
            live = createLiveController(fixture, target, identity).also { it.connectAndAwait() }

            // Phase A: what the phone settles to after its show, before
            // anyone touches windows.
            val initial = live.observe("A-initial", INITIAL_OBSERVE_MS)
            verdicts["A_authority"] = initial.describeAuthority()
            verdicts["A_active"] = initial.active
            verdicts["A_owner"] = initial.owner
            verdicts["A_server"] = serverState(fixture, target)

            // Phase B: the reported gesture, with the peer attached.
            verdicts.putAll(live.createWindow("B-with-peer", fixture, target, "withpeer"))

            // Phase C: the peer leaves; repeat. Isolates whether a second
            // client is required to reproduce. A peer's departure moves
            // nothing (§6.9 R5), so a phone that yielded still needs its tap.
            // The whole command line, exactly: a substring would also match a
            // client of any session whose name merely starts with this one.
            remote(fixture, "pkill -u \"\$(id -u)\" -xf 'tmux attach -t $target' >/dev/null 2>&1; true")
            live.observe("C-peer-left", PEER_OBSERVE_MS)
            if (live.authority() is SharedTmuxGridAuthoritySnapshot.Peer) {
                verdicts["C_takeback"] = live.takeBack("C", attempts = 3)
            }
            verdicts.putAll(live.createWindow("C-alone", fixture, target, "alone"))
        } finally {
            val summary = verdicts.entries.joinToString(" ") { "${it.key}=${it.value.replace(' ', '_')}" }
            log("TESSERA_NEW_WINDOW_RIG $summary")
            live?.dumpDiagnostics()
            runCatching { live?.close() }.onFailure { log("controller close failed: $it") }
            runCatching { cleanupFixture(fixture, target) }.onFailure { log("fixture cleanup failed: $it") }
        }
        assertTrue("rig ran", verdicts.isNotEmpty())
        // The peer has left, so it is no longer tmux's `latest` client: a
        // take-back has nothing to contend with and one tap settles it.
        verdicts["C_takeback"]?.let { verdict ->
            val summary = verdicts.entries.joinToString(" ") { "${it.key}=${it.value.replace(' ', '_')}" }
            assertTrue(
                "C: a take-back from a departed peer needed a retry or never settled ($verdict). " +
                    "Full rig summary: $summary",
                verdict.startsWith("settled-on-attempt-1-"),
            )
        }
    }

    // ---- fixture orchestration -------------------------------------------------

    private suspend fun prepareFixture(fixture: Fixture, target: String, withPeer: Boolean) {
        val base = listOf(
            "cd \"\$HOME\" && tmux new-session -d -s '$target' -x 100 -y 30",
            "tmux set-option -t '$target' window-size latest",
        )
        val peer = if (!withPeer) emptyList() else listOf(
            "mkfifo /tmp/$target.fifo",
            // The keeper's argv names the session, so cleanup can end exactly
            // this run's keeper and no other `sleep` on the shared account.
            "(nohup bash -c 'exec -a \"\$0\" sleep 3600 > /tmp/$target.fifo' '$target-fifo-keeper' </dev/null >/dev/null 2>&1 &)",
            "(nohup setsid env TERM=xterm-256color script -qfc " +
                "'stty cols 160 rows 48; exec tmux attach -t $target' /dev/null " +
                "</tmp/$target.fifo >/tmp/$target.script.log 2>&1 &)",
            "sleep 2",
        )
        val script = "tmux kill-session -t '=$target' 2>/dev/null; " +
            "rm -f /tmp/$target.fifo /tmp/$target.script.log; " +
            (base + peer + listOf(
                "tmux list-clients -t '$target' -F " +
                    "'#{client_name}|#{client_width}x#{client_height}|#{client_flags}'",
            )).joinToString(" && ")
        val output = remote(fixture, script)
        log("fixture prepared; clients: ${output.trim()}")
        if (withPeer) check(output.contains("160x48")) { "peer client did not attach at 160x48: $output" }
    }

    private suspend fun cleanupFixture(fixture: Fixture, target: String) {
        // Killing the session detaches the plain peer, which ends its
        // `script`. Only this run's FIFO keeper goes besides: its whole
        // command line is `<target>-fifo-keeper 3600` (an exact match, never
        // another lane's `sleep`); run-new-window-rig.sh then ends anything
        // left that names the session.
        remote(
            fixture,
            "tmux kill-session -t '=$target' 2>/dev/null; " +
                "pkill -u \"\$(id -u)\" -xf '$target-fifo-keeper 3600' >/dev/null 2>&1; " +
                "rm -f /tmp/$target.fifo /tmp/$target.script.log; true",
        )
    }

    private suspend fun serverState(fixture: Fixture, target: String): String = remote(
        fixture,
        "tmux display-message -p -t '$target' 'current=#{window_id}:#{window_width}x#{window_height}'; " +
            "tmux list-windows -t '$target' -F 'w=#{window_id}:#{window_width}x#{window_height}:#{?window_active,active,-}'; " +
            "tmux list-clients -t '$target' -F 'c=#{client_name}:#{client_width}x#{client_height}:#{client_flags}'",
    ).lineSequence().filter(String::isNotBlank).joinToString(";")

    // ---- controller harness ----------------------------------------------------

    private data class Sample(
        val authority: SharedTmuxGridAuthoritySnapshot,
        val active: String,
        val owner: String,
        val windows: String,
    ) {
        fun describeAuthority(): String = when (val a = authority) {
            SharedTmuxGridAuthoritySnapshot.Unknown -> "unknown"
            is SharedTmuxGridAuthoritySnapshot.Mine -> "mine(gen=${a.generation})"
            is SharedTmuxGridAuthoritySnapshot.Peer -> "peer(${a.deviceId},${a.displayName},gen=${a.generation})"
        }
    }

    private inner class LiveController(
        val controller: SshSessionController,
        val surface: TermuxTerminalSurface,
        private val diagnostics: DiagnosticLogStore,
        private val agentSessions: LiveAgentSessionRegistry,
        private val scope: CoroutineScope,
        private val authentication: Job,
    ) {
        private val diagnosticsPrefix = diagnostics.read().length
        private var lastDeclared: Pair<Int?, Int?>? = null

        suspend fun connectAndAwait() {
            onMain { controller.connect() }
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
            // The phone's tab is displayed: report the show edge the screen
            // reports (§6.9 R1). Attach alone only reads authority, and
            // window mutations are refused while a peer holds the grid.
            onMain { controller.shown(SharedTmuxAuthorityShowSource.SHOW) }
            withTimeoutOrNull(SHOW_DECISION_TIMEOUT_MS) {
                while (controller.tmuxAuthorityPresentation.value is TmuxAuthorityPresentation.Resuming) {
                    onMain { republishSurfaceDeclarations() }
                    delay(POLL_MS)
                }
            }
            log("show decided: authority=${sample().describeAuthority()} presentation=${controller.tmuxAuthorityPresentation.value}")
        }

        fun authority(): SharedTmuxGridAuthoritySnapshot = controller.tmuxAuthority.value

        suspend fun sample(): Sample {
            val snapshot = controller.tmuxSnapshot.value
            val window = snapshot?.activeWindow
            val size = window?.layout?.let { "${it.width}x${it.height}" } ?: "none"
            val owner = onMain { surface.boundOwner }
            return Sample(
                authority = controller.tmuxAuthority.value,
                active = "@${window?.id ?: "-"}:$size",
                owner = owner?.let { "@${it.windowId},%${it.paneId},e${it.epoch}" } ?: "none",
                windows = snapshot?.windows.orEmpty().joinToString(",") { "@${it.id}" },
            )
        }

        suspend fun observe(label: String, durationMs: Long): Sample {
            val started = System.currentTimeMillis()
            var previous: Sample? = null
            var last = sample()
            while (System.currentTimeMillis() - started < durationMs) {
                onMain { republishSurfaceDeclarations() }
                last = sample()
                if (last != previous) {
                    log(
                        "[$label +${System.currentTimeMillis() - started}ms] " +
                            "authority=${last.describeAuthority()} active=${last.active} " +
                            "owner=${last.owner} windows=${last.windows}",
                    )
                    previous = last
                }
                delay(POLL_MS)
            }
            return last
        }

        suspend fun takeBack(label: String, attempts: Int): String {
            repeat(attempts) { attempt ->
                val started = System.currentTimeMillis()
                onMain { controller.reclaimTmuxGridAuthority() }
                val settled = withTimeoutOrNull(TAKE_BACK_TIMEOUT_MS) {
                    while (authority() !is SharedTmuxGridAuthoritySnapshot.Mine) {
                        onMain { republishSurfaceDeclarations() }
                        delay(POLL_MS)
                    }
                    true
                }
                val elapsed = System.currentTimeMillis() - started
                log("[$label take-back #${attempt + 1}] settled=${settled == true} after ${elapsed}ms")
                if (settled == true) return "settled-on-attempt-${attempt + 1}-in-${elapsed}ms"
                delay(RETAP_DELAY_MS)
            }
            return "never-settled(${sample().describeAuthority()})"
        }

        /**
         * The reported gesture end to end: tap "+", then look for the created
         * window in the snapshot, in the render-surface owner, and finally in
         * the pixels — a marker echoed into the new window's own shell must
         * reach this device's transcript. When the terminal does not follow on
         * its own, the switcher's explicit selection gets its own attempt.
         */
        suspend fun createWindow(
            label: String,
            fixture: Fixture,
            target: String,
            key: String,
        ): Map<String, String> {
            val prefix = diagnostics.read().length
            val before = controller.tmuxSnapshot.value?.windows.orEmpty().map { it.id }.toSet()
            val beforeActive = controller.tmuxSnapshot.value?.activeWindowId
            val verdicts = linkedMapOf<String, String>()
            val started = System.currentTimeMillis()
            onMain { controller.createTmuxWindow() }
            log("[$label] createTmuxWindow() requested; before=$before active=@$beforeActive")

            val created = withTimeoutOrNull(WINDOW_APPEAR_TIMEOUT_MS) {
                while (true) {
                    onMain { republishSurfaceDeclarations() }
                    val now = controller.tmuxSnapshot.value?.windows.orEmpty().map { it.id }.toSet()
                    (now - before).firstOrNull()?.let { return@withTimeoutOrNull it }
                    delay(POLL_MS)
                }
                @Suppress("UNREACHABLE_CODE")
                null
            }
            verdicts["${key}_listed"] = created?.let { "@$it-in-${System.currentTimeMillis() - started}ms" }
                ?: "never-listed"
            verdicts["${key}_server"] = serverState(fixture, target)
            if (created == null) return verdicts

            verdicts["${key}_followed"] = awaitOwner("$label-create", created)
            if (onMain { surface.boundOwner }?.windowId != created) {
                // The switcher's explicit gesture, exactly as the sheet calls it.
                val selected = System.currentTimeMillis()
                onMain { controller.selectTmuxWindow(created) }
                log("[$label] selectTmuxWindow(@$created) requested")
                verdicts["${key}_switcher"] = awaitOwner("$label-switch", created)
                verdicts["${key}_switcher_ms"] = "${System.currentTimeMillis() - selected}"
            }
            verdicts["${key}_authority"] = sample().describeAuthority()
            verdicts["${key}_active"] = sample().active

            // The pixels. The new window runs its own shell, so echo a marker
            // into it from the server and demand it in this device's screen.
            val marker = "NEWWIN-$key-${UUID.randomUUID().toString().take(6).uppercase()}"
            remote(fixture, "tmux send-keys -t '@$created' 'echo $marker' Enter")
            val painted = withTimeoutOrNull(MARKER_TIMEOUT_MS) {
                while (!onMain { transcriptNow() }.contains(marker)) {
                    onMain { republishSurfaceDeclarations() }
                    delay(POLL_MS)
                }
                true
            }
            verdicts["${key}_painted"] = if (painted == true) "yes" else "no"
            val delta = diagnostics.read().drop(prefix)
            verdicts["${key}_binds"] = delta.lineSequence()
                .count { it.contains("render_surface_bind ") }.toString()
            log("---- [$label] diagnostics delta ----")
            delta.lineSequence().filter(String::isNotBlank).forEach { Log.i(TAG, "diag| $it") }
            return verdicts
        }

        private suspend fun awaitOwner(label: String, windowId: Int): String {
            val started = System.currentTimeMillis()
            val bound = withTimeoutOrNull(OWNER_TIMEOUT_MS) {
                while (onMain { surface.boundOwner }?.windowId != windowId) {
                    onMain { republishSurfaceDeclarations() }
                    delay(POLL_MS)
                }
                true
            }
            val elapsed = System.currentTimeMillis() - started
            val now = sample()
            log("[$label] owner=@$windowId bound=${bound == true} after ${elapsed}ms owner=${now.owner}")
            return if (bound == true) "bound-in-${elapsed}ms" else "never-bound(${now.owner},active=${now.active})"
        }

        private fun transcriptNow(): String {
            val emulator = surface.view.mEmulator
            val history = emulator.screen.activeTranscriptRows
            return emulator.screen.getSelectedText(0, -history, emulator.mColumns, emulator.mRows, false)
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
            agentSessions.close()
            authentication.cancel()
            scope.cancel()
        }

        suspend fun <T> onMain(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    }

    private fun createLiveController(
        fixture: Fixture,
        target: String,
        identity: TmuxDeviceIdentity,
    ): LiveController {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val host = SavedHost(
            id = UUID.randomUUID().toString(),
            displayName = "new window rig",
            hostname = fixture.stableHost,
            port = fixture.port,
            username = fixture.user,
            jumpHostId = null,
            identityId = null,
            transportKind = TransportKinds.SSH,
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
            controller.setPresentationActive(true)
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
        return LiveController(controller, surface, diagnostics, agentSessions, scope, authentication)
    }

    private suspend fun remote(fixture: Fixture, command: String): String {
        val transcript = AndroidSshBackend().executeRouteCommand(
            request = SshRouteRequest(
                hops = listOf(
                    SshRouteHop(
                        id = "new-window-rig-fixture",
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
            session = value("rigSession"),
        )
    }

    private data class Fixture(
        val stableHost: String,
        val port: Int,
        val user: String,
        val password: String,
        val session: String,
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
        const val TAG = "TesseraNewWindowRig"
        const val FIXTURE_PATH = "/data/local/tmp/tessera-new-window-rig-fixture.properties"
        const val PHONE_COLUMNS = 50
        const val PHONE_ROWS = 30
        const val CONNECT_TIMEOUT_MS = 90_000L
        const val INITIAL_OBSERVE_MS = 10_000L
        const val PEER_OBSERVE_MS = 8_000L
        const val TAKE_BACK_TIMEOUT_MS = 8_000L
        const val SHOW_DECISION_TIMEOUT_MS = 15_000L
        const val RETAP_DELAY_MS = 1_500L
        const val POLL_MS = 200L
        const val WINDOW_APPEAR_TIMEOUT_MS = 10_000L
        const val OWNER_TIMEOUT_MS = 10_000L
        const val MARKER_TIMEOUT_MS = 10_000L
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
