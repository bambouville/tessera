package com.bambouville.tessera.agent.platform

import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Route currency is "does this endpoint still address this route", never "is
 * this the pane on screen".
 *
 * tmux hands one client every pane of the session, and an agent is nearly
 * always working in a window nobody is watching. Every authority and action
 * gate used to ask the active-pane question instead, so an agent outside the
 * visible pane could not be bound, projected or acted on — Agent Center simply
 * stayed empty while several agents ran.
 */
class AgentEndpointRouteCurrencyTest {
    @Test fun coreRouteWithoutDisplayLabelRetainsEveryAuthorityFence() {
        for (transport in AgentEndpointTransport.entries) {
            val native = AgentEndpointBinding(
                AgentSessionKey("session-a", 3), "host-a", transport,
                "work", "@1", "%10", hostDisplayLabel = "My Mac",
            )
            val core = native.copy(hostDisplayLabel = native.hostID)
            assertTrue(native.sameRouteAs(core))
            assertTrue(FakeEndpoint(native).isCurrentRoute(core))
            for (changed in listOf(
                core.copy(key = core.key.copy(liveSessionID = "session-b")),
                core.copy(key = core.key.copy(carrierGeneration = 4)),
                core.copy(hostID = "host-b"),
                core.copy(transport = AgentEndpointTransport.entries.first { it != transport }),
                core.copy(tmuxSession = "Work"), core.copy(windowID = "@2"), core.copy(paneID = "%11"),
            )) assertFalse(native.sameRouteAs(changed))
        }
    }
    private val key = AgentSessionKey("session-a", 3)
    private fun binding(pane: String?, window: String? = null) = AgentEndpointBinding(
        key = key,
        hostID = "host-a",
        transport = AgentEndpointTransport.SSH_TMUX,
        tmuxSession = "work",
        windowID = window,
        paneID = pane,
    )

    @Test
    fun anEndpointWithNoRoutesOfItsOwnFallsBackToItsPublishedBinding() {
        val endpoint = FakeEndpoint(binding(pane = null))

        assertTrue(endpoint.isCurrentRoute(endpoint.binding.value))
        assertFalse(endpoint.isCurrentRoute(binding(pane = "%70", window = "@7")))
    }

    @Test
    fun aRouteAwareEndpointKeepsAnUnwatchedPaneAddressable() {
        val active = binding(pane = "%10", window = "@1")
        val background = binding(pane = "%70", window = "@7")
        val endpoint = RouteAwareEndpoint(active, routes = listOf(active, background))

        assertTrue(endpoint.isCurrentRoute(background))
        assertTrue(endpoint.isCurrentRoute(active))
        assertTrue(endpoint.isCurrentRoute(background.copy(hostDisplayLabel = "Different display metadata")))
    }

    /** Widening which pane may answer must not weaken address equality. */
    @Test
    fun aRouteAwareEndpointStillRejectsAnyMismatchedAddressField() {
        val active = binding(pane = "%10", window = "@1")
        val background = binding(pane = "%70", window = "@7")
        val endpoint = RouteAwareEndpoint(active, routes = listOf(active, background))

        assertFalse(endpoint.isCurrentRoute(background.copy(windowID = "@1")))
        assertFalse(endpoint.isCurrentRoute(background.copy(hostID = "host-b")))
        assertFalse(endpoint.isCurrentRoute(background.copy(tmuxSession = "other")))
        assertFalse(endpoint.isCurrentRoute(binding(pane = "%99", window = "@9")))
    }

    private class RouteAwareEndpoint(
        active: AgentEndpointBinding,
        private val routes: List<AgentEndpointBinding>,
    ) : FakeEndpoint(active) {
        override fun isCurrentRoute(candidate: AgentEndpointBinding): Boolean = routes.any { it.sameRouteAs(candidate) }
    }

    private open class FakeEndpoint(published: AgentEndpointBinding) : AgentSessionEndpoint {
        override val key = published.key
        override val binding = MutableStateFlow(published)
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames: Flow<AgentLifecycleFrame> = emptyFlow()

        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> =
            AgentEndpointResult.Unavailable("fake")

        override suspend fun proveProcess(
            binding: AgentEndpointBinding,
            claimedPID: Int,
            provider: AgentProofProvider,
            requireForeground: Boolean,
        ): AgentEndpointResult<AgentProcessProof> = AgentEndpointResult.Unavailable("fake")

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

        override suspend fun launchTmux(
            binding: AgentEndpointBinding,
            placement: AgentTmuxPlacement,
            requestID: String,
            request: ByteArray,
        ): AgentEndpointResult<AgentTmuxLaunchReceipt> = AgentEndpointResult.Unavailable("fake")

        override fun close() = Unit
    }
}
