package com.bambouville.tessera.agent.platform

import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveAgentSessionRegistryTest {
    @Test
    fun registrationIsExactGenerationBoundAndCloseInvalidatesEndpoint() {
        val registry = LiveAgentSessionRegistry()
        val key = AgentSessionKey("session-a", 7)
        val endpoint = FakeEndpoint(key)
        val registration = registry.register(endpoint)

        assertEquals(endpoint, registry.resolve(key))
        assertEquals(listOf(endpoint.binding.value), registry.sessions.value)

        registration.close()

        assertNull(registry.resolve(key))
        assertTrue(endpoint.closed)
        assertTrue(registry.sessions.value.isEmpty())
    }

    @Test
    fun staleCarrierCannotReplaceLiveGeneration() {
        val registry = LiveAgentSessionRegistry()
        val first = FakeEndpoint(AgentSessionKey("session-a", 1))
        val replacement = FakeEndpoint(AgentSessionKey("session-a", 2))
        val firstRegistration = registry.register(first)
        registry.register(replacement)

        firstRegistration.close()

        assertNull(registry.resolve(first.key))
        assertEquals(replacement, registry.resolve(replacement.key))
        registry.close()
    }

    @Test
    fun coordinatorExposesReadOnlyDirectoryRatherThanMutableRegistry() {
        val registry = LiveAgentSessionRegistry()
        val coordinator = AndroidAgentSessionCoordinator(registry)

        assertTrue(coordinator.directory !is LiveAgentSessionRegistry)
        assertTrue(coordinator.directory.sessions.value.isEmpty())

        coordinator.close()
    }

    @Test
    fun aRememberedIssuanceServesOneToolCallAndThenExpires() {
        var now = 0L
        val memo = IssuedRouteMemo(freshNanos = 1_000, capacity = 4, clock = { now })
        val key = routeKey(claimedPID = 4_242)
        val issued = issuedBinding()

        assertNull(memo.remembered(key))
        memo.remember(key, issued)
        assertSame(issued, memo.remembered(key))

        now += 999
        assertSame(issued, memo.remembered(key))
        // Past the window the proof is no longer evidence of anything: the
        // agent may have exited, and a row that still offered to interrupt it
        // would be offering to interrupt whatever took its place.
        now += 2
        assertNull(memo.remembered(key))
    }

    @Test
    fun aDifferentProcessOrThreadNeverReadsAnothersProof() {
        val memo = IssuedRouteMemo(freshNanos = 1_000_000, capacity = 4, clock = { 0L })
        val issued = issuedBinding()
        memo.remember(routeKey(claimedPID = 4_242), issued)

        assertNull(memo.remembered(routeKey(claimedPID = 4_243)))
        assertNull(memo.remembered(routeKey(claimedPID = 4_242, session = "other-session")))
        assertNull(memo.remembered(routeKey(claimedPID = null)))
    }

    @Test
    fun aFreshIssuanceForgetsTheThreadsRetiredTokens() {
        val memo = IssuedRouteMemo(freshNanos = 1_000_000, capacity = 4, clock = { 0L })
        val retired = issuedBinding(token = "retired")
        val other = issuedBinding(token = "other-thread")
        memo.remember(routeKey(claimedPID = 4_242), retired)
        memo.remember(routeKey(claimedPID = 4_242, session = "other-session"), other)

        // Identical authority keeps its token, so it stays remembered.
        memo.retireOthers("host-a\u0000claude\u0000session-a", retired)
        assertSame(retired, memo.remembered(routeKey(claimedPID = 4_242)))
        // Any other mint for the thread (inventory, another pane) retired it.
        memo.retireOthers("host-a\u0000claude\u0000session-a", issuedBinding(token = "fresh"))
        assertNull(memo.remembered(routeKey(claimedPID = 4_242)))
        assertSame(other, memo.remembered(routeKey(claimedPID = 4_242, session = "other-session")))
    }

    @Test
    fun theThreadIdentityKeepsTwoSessionsOnOnePaneApart() {
        fun identity(session: String) = IssuedRouteMemo.threadIdentity(
            JSONObject()
                .put("hostID", "host-a")
                .put("providerID", JSONObject().put("rawValue", "claude"))
                .put("providerSessionID", session),
        )

        assertEquals(identity("session-a"), identity("session-a"))
        assertNotEquals(identity("session-a"), identity("session-b"))
    }

    private fun routeKey(claimedPID: Int?, session: String = "session-a") = IssuedRouteKey(
        binding = AgentEndpointBinding(AgentSessionKey("live-1", 1), "host-a", AgentEndpointTransport.SSH_TMUX),
        threadIdentity = "host-a\u0000claude\u0000$session",
        providerID = "claude",
        claimedPID = claimedPID,
    )

    private fun issuedBinding(token: String = "token") = AgentIssuedBinding(
        coreBinding = JSONObject().put("liveSessionID", "live-1"),
        bindingToken = token,
        actionable = true,
        provenDirectories = listOf("/tmp"),
    )

    private class FakeEndpoint(override val key: AgentSessionKey) : AgentSessionEndpoint {
        override val binding = MutableStateFlow(
            AgentEndpointBinding(key, "host-a", AgentEndpointTransport.SSH),
        )
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames: Flow<AgentLifecycleFrame> = emptyFlow()
        var closed = false

        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun proveProcess(
            binding: AgentEndpointBinding,
            claimedPID: Int,
            provider: AgentProofProvider,
            requireForeground: Boolean,
        ): AgentEndpointResult<AgentProcessProof> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun processDiscoveryScope(binding: AgentEndpointBinding): AgentEndpointResult<AgentProcessDiscoveryScope> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun probeIntegration(
            binding: AgentEndpointBinding,
            command: AgentIntegrationCommand,
        ): AgentEndpointResult<AgentIntegrationStatus> = AgentEndpointResult.Unavailable("fake")

        override suspend fun installIntegration(
            binding: AgentEndpointBinding,
            command: AgentIntegrationCommand,
        ): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> = AgentEndpointResult.Unavailable("fake")

        override suspend fun readIntegrationConfigs(
            binding: AgentEndpointBinding,
            command: AgentIntegrationCommand,
        ): AgentEndpointResult<AgentIntegrationConfigSnapshots> = AgentEndpointResult.Unavailable("fake")

        override suspend fun inspectCurrentShell(
            binding: AgentEndpointBinding,
            command: AgentIntegrationCommand,
        ): AgentEndpointResult<AgentCurrentShellStatus> = AgentEndpointResult.Unavailable("fake")

        override suspend fun discoverProcesses(
            binding: AgentEndpointBinding,
            command: AgentIntegrationCommand,
        ): AgentEndpointResult<AgentProcessDiscoverySnapshot> = AgentEndpointResult.Unavailable("fake")

        override suspend fun activateCurrentShell(
            binding: AgentEndpointBinding,
            expectedProcessIDs: Set<Int>,
            command: AgentShellActivationCommand,
        ): AgentEndpointResult<Unit> = AgentEndpointResult.Unavailable("fake")

        override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> =
            AgentEndpointResult.Unavailable("fake")

        override fun close() { closed = true }
    }
}
