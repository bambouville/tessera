package com.bambouville.tessera.feature.session

import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
import com.bambouville.tessera.core.bridge.SharedProgramStatusAttention
import com.bambouville.tessera.core.bridge.SharedProgramStatusBlockedKind
import com.bambouville.tessera.core.bridge.SharedProgramStatusState
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.core.bridge.SharedTmuxCommands
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Live OSC 7501 reports through the production controller, using only the gate's fixture. */
@RunWith(AndroidJUnit4::class)
class ProgramStatusLiveInstrumentedTest {
    @Test
    fun liveProgramStatusReportsCrossEveryIncludedTransport(): Unit = runBlocking {
        val fixture = readFixture()
        assumeTrue("no native SSH fixture at $FIXTURE_PATH; the gate pushes one", fixture != null)
        val target = requireNotNull(fixture)
        assertRawSSHProgramStatus(target)
        assertTmuxProgramStatus(target, TransportKinds.SSH)
        val mosh = JniMoshNativeClientFactory.isAvailable
        if (mosh) assertTmuxProgramStatus(target, TransportKinds.MOSH)
        Log.i(TAG, "TESSERA_ANDROID_PROGRAM_STATUS_OK raw=1 query=1 sshTmux=1 moshTmux=${if (mosh) 1 else 0}")
    }

    private suspend fun assertRawSSHProgramStatus(fixture: Fixture) {
        val live = createLiveController(fixture, target = null, transport = TransportKinds.SSH)
        try {
            live.connectAndAwait()
            // Read both answers with echo off. The first ten bytes must be the
            // OSC reply, before the emulator's DA1 reply from the same read.
            val probe = """psprobe() { stty -echo -icanon min 0 time 30; printf '\033]7501;?\033\\\033[c'; r=${'$'}(dd bs=1 count=128 2>/dev/null | od -An -tx1 | tr -d ' \n'); stty sane; printf 'PSREPLY_%s_%s_END\n' "${'$'}1" "${'$'}r"; }"""
            live.send("$probe\npsprobe on\n")
            val enabledHex = live.awaitProbe("on")
            assertTrue("OSC reply must precede DA1: $enabledHex", enabledHex.startsWith(QUERY_REPLY_HEX))
            val da1 = enabledHex.removePrefix(QUERY_REPLY_HEX)
            assertTrue("DA1 must follow the OSC reply: $enabledHex", da1.startsWith("1b5b3f") && da1.endsWith("63"))

            live.send("printf '\\033]7501;state=blocked:kind=permission:app=deploy\\007'\n")
            awaitValue("raw blocked permission report") {
                live.controller.programStatus.value.terminal(SharedProgramStatusTerminal.Raw)
                    ?.takeIf { it.attention == SharedProgramStatusAttention.NEEDS_INPUT }
            }.also { blocked ->
                assertEquals(SharedProgramStatusState.BLOCKED, blocked.primaryEntry?.state)
                assertEquals(SharedProgramStatusBlockedKind.PERMISSION, blocked.blockedKind)
                assertEquals("deploy", blocked.primaryEntry?.app)
            }
            live.send("printf '\\033]7501;state=done\\007'\n")
            val done = awaitValue("raw unread finished report") {
                live.controller.programStatus.value.terminal(SharedProgramStatusTerminal.Raw)
                    ?.takeIf { it.attention == SharedProgramStatusAttention.FINISHED && it.primaryEntry?.isUnreadResult == true }
            }
            live.onMain {
                live.controller.acknowledgeProgramStatus(SharedProgramStatusTerminal.Raw, requireNotNull(done.latestUnreadResultToken))
            }
            awaitValue("raw result acknowledged") {
                live.controller.programStatus.value.terminal(SharedProgramStatusTerminal.Raw)
                    ?.takeIf { it.attention == null && it.entries.none { entry -> entry.isUnreadResult } }
            }
            live.onMain { live.controller.setProgramStatusEnabled(false) }
            assertTrue(live.controller.programStatus.value.terminals.isEmpty())
            live.send("psprobe off\n")
            val disabledHex = live.awaitProbe("off")
            assertFalse("disabled monitor must not answer OSC: $disabledHex", disabledHex.contains(QUERY_REPLY_HEX))
            assertTrue("DA1 still answers while OSC is off: $disabledHex", disabledHex.startsWith("1b5b3f") && disabledHex.endsWith("63"))
            assertTrue(live.controller.programStatus.value.terminals.isEmpty())
        } finally {
            live.close()
        }
    }

    private suspend fun assertTmuxProgramStatus(fixture: Fixture, transport: String) {
        val target = "tessera-ps-${if (transport == TransportKinds.MOSH) "mosh" else "ssh"}-${fixture.token}"
        val build = "build-${fixture.token}"
        val deploy = "deploy-${fixture.token}"
        val view = SharedTmuxCommands.moshViewSessionName(target)
        var live: LiveController? = null
        try {
            remote(fixture, "tmux new-session -d -s '$target' -n '$build' -x 120 -y 40 && " +
                "tmux new-window -d -t '=$target' -n '$deploy' && tmux select-window -t '$target:$build'")
            val session = createLiveController(fixture, target, transport).also { live = it }
            session.connectAndAwait()
            val panes = awaitValue("$transport pane hydration") {
                val windows = session.controller.tmuxSnapshot.value?.windows.orEmpty()
                val buildPane = windows.firstOrNull { it.name == build }?.panes?.singleOrNull()?.id
                val deployPane = windows.firstOrNull { it.name == deploy }?.panes?.singleOrNull()?.id
                if (buildPane != null && deployPane != null) buildPane to deployPane else null
            }
            remote(fixture, report(target, build, "state=error:app=cargo") + " && " +
                report(target, deploy, "state=blocked:kind=permission:app=deploy"))
            val failed = awaitValue("$transport two panes report") {
                val snapshot = session.controller.programStatus.value
                val failure = snapshot.pane(panes.first)
                val blocked = snapshot.pane(panes.second)
                failure?.takeIf { it.attention == SharedProgramStatusAttention.FAILED &&
                    blocked?.attention == SharedProgramStatusAttention.NEEDS_INPUT &&
                    blocked.blockedKind == SharedProgramStatusBlockedKind.PERMISSION }
            }
            assertEquals(SharedProgramStatusState.ERROR, failed.primaryEntry?.state)
            assertEquals("cargo", failed.primaryEntry?.app)
            val blocked = requireNotNull(session.controller.programStatus.value.pane(panes.second))
            assertEquals(SharedProgramStatusState.BLOCKED, blocked.primaryEntry?.state)
            assertEquals("deploy", blocked.primaryEntry?.app)
            assertNull(session.controller.programStatus.value.terminal(SharedProgramStatusTerminal.Raw))
            session.onMain {
                session.controller.acknowledgeProgramStatus(SharedProgramStatusTerminal.Pane(panes.first), requireNotNull(failed.latestUnreadResultToken))
                session.controller.acknowledgeProgramStatus(SharedProgramStatusTerminal.Pane(panes.second), Long.MAX_VALUE)
            }
            awaitValue("$transport failed result acknowledged") {
                session.controller.programStatus.value.pane(panes.first)
                    ?.takeIf { it.attention == null && it.entries.none { entry -> entry.isUnreadResult } }
            }
            assertEquals(SharedProgramStatusAttention.NEEDS_INPUT, session.controller.programStatus.value.pane(panes.second)?.attention)
            remote(fixture, "tmux kill-window -t '$target:$deploy'")
            awaitValue("$transport killed pane pruned") {
                true.takeIf { session.controller.programStatus.value.pane(panes.second) == null &&
                    session.controller.tmuxSnapshot.value?.windows?.none { it.name == deploy } == true }
            }
            session.onMain { session.controller.setProgramStatusEnabled(false) }
            assertTrue(session.controller.programStatus.value.terminals.isEmpty())
            remote(fixture, report(target, build, "state=error:app=ignored"))
            session.assertEmptyFor("$transport disabled reports", 1_500L)
            session.onMain { session.controller.setProgramStatusEnabled(true) }
            session.assertEmptyFor("$transport re-enabled starts empty", 1_500L)
            remote(fixture, report(target, build, "state=done:app=make"))
            awaitValue("$transport new report after re-enabling") {
                session.controller.programStatus.value.pane(panes.first)
                    ?.takeIf { it.attention == SharedProgramStatusAttention.FINISHED && it.primaryEntry?.app == "make" }
            }
        } finally {
            // Close the UDP carrier before killing its grouped view, and always
            // clean both exact session names even if controller cleanup fails.
            try {
                live?.close(awaitMoshCleanup = transport == TransportKinds.MOSH)
            } finally {
                remote(fixture, "for s in '$view' '$target'; do " +
                    "if tmux has-session -t \"=\$s\" 2>/dev/null; then tmux kill-session -t \"=\$s\" || exit; fi; done")
            }
        }
    }

    private fun report(target: String, window: String, fields: String): String =
        "tmux send-keys -t '$target:$window' -l 'printf \"\\033]7501;$fields\\007\"' && " +
            "tmux send-keys -t '$target:$window' Enter"

    private inner class LiveController(
        val controller: SshSessionController,
        val surface: TermuxTerminalSurface,
        private val diagnostics: DiagnosticLogStore,
        private val agentSessions: LiveAgentSessionRegistry,
        private val scope: CoroutineScope,
        private val authentication: Job,
    ) {
        private var connected = false

        suspend fun connectAndAwait() {
            onMain { controller.connect() }
            awaitValue("controller connected") {
                when (val state = controller.state.value) {
                    SshSessionUiState.Connected -> true
                    is SshSessionUiState.Failed -> error("controller failed: $state")
                    else -> null
                }
            }
            connected = true
        }

        suspend fun send(text: String) = onMain { surface.sendInput(text.encodeToByteArray()) }

        suspend fun awaitProbe(label: String): String = awaitValue("raw query probe $label") {
            val transcript = onMain {
                val emulator = surface.view.mEmulator
                emulator.screen.getSelectedText(0, -emulator.screen.activeTranscriptRows, emulator.mColumns, emulator.mRows, false)
            }
            Regex("PSREPLY_${label}_([0-9a-f]+)_END").find(transcript)?.groupValues?.get(1)
        }

        suspend fun assertEmptyFor(label: String, durationMs: Long) {
            val deadline = System.currentTimeMillis() + durationMs
            do {
                assertTrue("$label: ${controller.programStatus.value}", controller.programStatus.value.terminals.isEmpty())
                delay(POLL_MS)
            } while (System.currentTimeMillis() < deadline)
        }

        suspend fun close(awaitMoshCleanup: Boolean = false) {
            val cleanupOffset = diagnostics.read().length
            try {
                onMain { try { controller.close() } finally { surface.close() } }
                if (awaitMoshCleanup && connected) {
                    awaitValue("fresh Mosh cleanup receipt") {
                        diagnostics.read().drop(cleanupOffset).takeIf { it.contains("mosh_explicit_cleanup_succeeded") }
                    }
                }
            } finally {
                agentSessions.close()
                authentication.cancel()
                scope.cancel()
            }
        }

        suspend fun <T> onMain(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    }

    private fun createLiveController(fixture: Fixture, target: String?, transport: String): LiveController {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val host = SavedHost(
            id = UUID.randomUUID().toString(),
            displayName = "program status fixture",
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
            hosts = RigHostRepository(host),
            identities = RigIdentityRepository(),
            knownHosts = RigKnownHostsRepository(),
            restore = RigRestoreRepository(),
            credentialStore = AndroidKeystoreCredentialStore(),
            diagnostics = diagnostics,
            scope = scope,
            agentSessions = agentSessions,
            initialTmuxGridPresentation = SharedTmuxGridPresentation.SINGLE_PANE,
            tmuxDeviceIdentity = TmuxDeviceIdentity("android-ps-${UUID.randomUUID()}", "Android-ProgramStatus"),
            scrollbackLines = 2_000,
        )
        runProgramStatusOnMain {
            controller.setProgramStatusEnabled(true)
        }
        val surface = runProgramStatusOnMain {
            TermuxTerminalSurface(context, transcriptRows = 4_000).also {
                it.resize(120, 40)
                controller.attachTerminal(it)
                controller.setPresentationActive(true)
                controller.updateTmuxViewport(120, 40)
            }
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

    private suspend fun <T : Any> awaitValue(label: String, value: suspend () -> T?): T {
        val result = withTimeoutOrNull(90_000L) {
            var found = value()
            while (found == null) {
                delay(POLL_MS)
                found = value()
            }
            found
        }
        return requireNotNull(result) { "timed out: $label" }
    }

    private suspend fun remote(fixture: Fixture, command: String): String {
        val transcript = AndroidSshBackend().executeRouteCommand(
            request = SshRouteRequest(hops = listOf(SshRouteHop(
                id = "program-status-fixture",
                endpoint = SshEndpoint(fixture.stableHost, fixture.port),
                username = fixture.user,
                authentication = SshAuthentication.Password,
            ))),
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
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cat $FIXTURE_PATH")
        val properties = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            Properties().apply { load(input) }
        }
        if (properties.getProperty("stableHost").isNullOrBlank()) return null
        fun value(name: String): String = properties.getProperty(name)?.takeIf { it.isNotBlank() }
            ?: error("native SSH fixture is missing $name")
        val token = value("token")
        check(token.matches(Regex("[A-Za-z0-9_-]{1,64}"))) { "unsafe fixture token" }
        return Fixture(
            stableHost = value("stableHost"),
            port = value("port").toInt(),
            user = value("user"),
            password = android.util.Base64.decode(value("passwordBase64"), android.util.Base64.DEFAULT).decodeToString(),
            token = token,
        )
    }

    private data class Fixture(val stableHost: String, val port: Int, val user: String, val password: String, val token: String)

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

    private companion object {
        const val TAG = "TesseraNativeSsh"
        const val FIXTURE_PATH = "/data/local/tmp/tessera-native-ssh-fixture.properties"
        const val POLL_MS = 200L
        const val QUERY_REPLY_HEX = "1b5d373530313b3f1b5c"
    }
}

private fun <T> runProgramStatusOnMain(block: () -> T): T {
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
