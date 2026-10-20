package com.bambouville.tessera.feature.session

import android.os.ParcelFileDescriptor
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.LiveAgentSessionRegistry
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
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import java.util.Collections
import java.util.Properties
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
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
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Delayed prompt answers through the real controller and the gate's password SSH fixture. */
@RunWith(AndroidJUnit4::class)
class ChallengeRenewalLiveInstrumentedTest {
    @After
    fun resetChallengeTiming() = SharedChallengeTiming.reset()

    @Test
    fun hostKeyAnswerAfterCoreExpiryStillConnects(): Unit = runBlocking {
        assertDelayedAnswer(delayHostKey = true)
    }

    @Test
    fun passwordAnswerAfterCoreExpiryStillConnects(): Unit = runBlocking {
        assertDelayedAnswer(delayHostKey = false)
    }

    private suspend fun assertDelayedAnswer(delayHostKey: Boolean) {
        val fixture = readFixture()
        assumeTrue("no native SSH fixture at $FIXTURE_PATH; the gate pushes one", fixture != null)
        val target = requireNotNull(fixture)
        SharedChallengeTiming.lifetimeSeconds = 3
        SharedChallengeTiming.renewAfterSeconds = 1
        var live: LiveController? = null
        try {
            val session = createLiveController(target, delayHostKey).also { live = it }
            session.onMain { session.controller.connect() }
            val label = if (delayHostKey) "AwaitingHostKey" else "AwaitingCredential"
            session.awaitState(label) { state ->
                if (delayHostKey) state is SshSessionUiState.AwaitingHostKey
                else state is SshSessionUiState.AwaitingCredential
            }
            // The bridge floors expiresAt to whole seconds. Wait well past the
            // full three-second lifetime before answering the original UI prompt.
            val answerAfter = System.currentTimeMillis() + 4_500L
            do {
                delay(POLL_MS)
                session.assertNoFailure()
            } while (System.currentTimeMillis() < answerAfter)
            session.onMain {
                if (delayHostKey) session.controller.decideHostKey(true)
                else session.controller.submitPassword(target.password)
            }
            session.awaitState("Connected after delayed $label") { it == SshSessionUiState.Connected }
            session.assertNoFailure()
        } finally {
            try {
                live?.close()
            } finally {
                SharedChallengeTiming.reset()
            }
        }
    }

    private inner class LiveController(
        val controller: SshSessionController,
        private val surface: TermuxTerminalSurface,
        private val fixture: Fixture,
        private val delayHostKey: Boolean,
        private val agentSessions: LiveAgentSessionRegistry,
        private val scope: CoroutineScope,
    ) {
        private val states = Collections.synchronizedList(mutableListOf<SshSessionUiState>())
        // Subscribe before connect and record emissions immediately, including a
        // transient Failed state that the polling loop could otherwise miss.
        private val observation = scope.launch(Dispatchers.Unconfined, start = CoroutineStart.UNDISPATCHED) {
            controller.state.collect { states.add(it) }
        }

        private fun history(): List<SshSessionUiState> = synchronized(states) { states.toList() }

        fun assertNoFailure() {
            val observed = history()
            assertFalse("controller reached Failed; states=$observed", observed.any { it is SshSessionUiState.Failed })
        }

        suspend fun awaitState(label: String, ready: (SshSessionUiState) -> Boolean) {
            val reached = withTimeoutOrNull(30_000L) {
                while (true) {
                    assertNoFailure()
                    val state = onMain { controller.state.value }
                    if (ready(state)) return@withTimeoutOrNull true
                    // Answer only the other prompt type. Never retry the delayed
                    // answer here: a broken renewal must fail this test.
                    onMain {
                        when {
                            delayHostKey && state is SshSessionUiState.AwaitingCredential ->
                                controller.submitPassword(fixture.password)
                            !delayHostKey && state is SshSessionUiState.AwaitingHostKey ->
                                controller.decideHostKey(true)
                            else -> Unit
                        }
                    }
                    delay(POLL_MS)
                }
            }
            assertTrue("timed out waiting for $label; states=${history()}", reached == true)
            assertNoFailure()
        }

        suspend fun close() {
            try {
                onMain { try { controller.close() } finally { surface.close() } }
            } finally {
                observation.cancel()
                agentSessions.close()
                scope.cancel()
            }
        }

        suspend fun <T> onMain(block: () -> T): T = withContext(Dispatchers.Main.immediate) { block() }
    }

    private suspend fun createLiveController(fixture: Fixture, delayHostKey: Boolean): LiveController =
        withContext(Dispatchers.Main.immediate) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val host = SavedHost(
                id = UUID.randomUUID().toString(),
                displayName = "challenge renewal fixture",
                hostname = fixture.stableHost,
                port = fixture.port,
                username = fixture.user,
                jumpHostId = null,
                identityId = null,
                transportKind = TransportKinds.SSH,
                tmuxMode = TmuxModes.OFF,
                tmuxTarget = null,
            )
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val agentSessions = LiveAgentSessionRegistry()
            val controller = SshSessionController(
                host = host,
                hosts = RigHostRepository(host),
                identities = RigIdentityRepository(),
                knownHosts = RigKnownHostsRepository(),
                restore = RigRestoreRepository(),
                credentialStore = AndroidKeystoreCredentialStore(),
                diagnostics = DiagnosticLogStore(context),
                scope = scope,
                agentSessions = agentSessions,
                initialTmuxGridPresentation = SharedTmuxGridPresentation.SINGLE_PANE,
                tmuxDeviceIdentity = TmuxDeviceIdentity("android-renewal-${UUID.randomUUID()}", "Android-ChallengeRenewal"),
                scrollbackLines = 2_000,
            )
            val surface = TermuxTerminalSurface(context, transcriptRows = 4_000).also {
                it.resize(120, 40)
                controller.attachTerminal(it)
                controller.setPresentationActive(true)
                controller.updateTmuxViewport(120, 40)
            }
            LiveController(controller, surface, fixture, delayHostKey, agentSessions, scope)
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
        const val FIXTURE_PATH = "/data/local/tmp/tessera-native-ssh-fixture.properties"
        const val POLL_MS = 50L
    }
}
