package com.bambouville.tessera.agent.platform

import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AgentSessionIntegrationCoordinatorTest {
    private val key = AgentSessionKey("session-a", 1)
    private val paneA = AgentEndpointBinding(key, "host-a", AgentEndpointTransport.SSH_TMUX, "work", "@1", "%1")
    private val paneB = paneA.copy(windowID = "@2", paneID = "%2")

    /**
     * The endpoint can visit another pane and come back before the directory
     * publishes, and the directory keeps only its latest value, so the
     * coordinator never hears of the visit. The monitor is the only recheck a
     * plain shell gets: ending it there froze the session's last status, a
     * stale "Could not verify agent integration" included.
     */
    @Test
    fun aPaneVisitTheDirectoryNeverPublishesKeepsTheSessionChecked() = runTest {
        val endpoint = ProbeCountingEndpoint(paneA)
        val directory = object : AgentSessionDirectory {
            override val sessions: StateFlow<List<AgentEndpointBinding>> = MutableStateFlow(listOf(paneA))
            override fun resolve(key: AgentSessionKey): AgentSessionEndpoint? = endpoint.takeIf { key == this@AgentSessionIntegrationCoordinatorTest.key }
        }
        val statuses = mutableListOf<String>()
        val coordinator = AgentSessionIntegrationCoordinator(
            directory,
            backgroundScope,
            diagnostics = { code, values -> if (code == "agent_integration_status") statuses += values.getValue("kind") },
        )
        coordinator.setEnabled(true)
        runCurrent()
        assertEquals("the first check probes the host", 1, endpoint.probes)
        assertEquals(AgentSessionIntegrationKind.Unavailable, coordinator.statuses.value[key]?.kind)

        // The first retry finds the endpoint on another pane.
        endpoint.binding.value = paneB
        advanceTimeBy(60_000)
        runCurrent()
        val whileAway = endpoint.probes
        endpoint.binding.value = paneA
        runCurrent()
        advanceTimeBy(120_000)
        runCurrent()

        assertTrue(
            "the session must keep being checked once its pane is back (${endpoint.probes} probes, $whileAway while away)",
            endpoint.probes > whileAway + 1,
        )
        assertEquals("one transition, not one per retry", listOf("Checking", "Unavailable"), statuses)
        coordinator.close()
    }

    /**
     * A pane visit during a check leaves the status as it was. Counting that
     * stale status as one more failure lengthened the backoff, and the loop
     * slept it out after the pane came back instead of checking it at once.
     */
    @Test
    fun aCheckAPaneVisitInterruptsChecksAgainWhenThePaneReturns() = runTest {
        val endpoint = ProbeCountingEndpoint(paneA)
        endpoint.onProbe = { probe -> if (probe == 2) endpoint.binding.value = paneB }
        val directory = object : AgentSessionDirectory {
            override val sessions: StateFlow<List<AgentEndpointBinding>> = MutableStateFlow(listOf(paneA))
            override fun resolve(key: AgentSessionKey): AgentSessionEndpoint? = endpoint.takeIf { key == this@AgentSessionIntegrationCoordinatorTest.key }
        }
        val coordinator = AgentSessionIntegrationCoordinator(directory, backgroundScope)
        coordinator.setEnabled(true)
        runCurrent()
        assertEquals(1, endpoint.probes)
        var waited = 0L
        while (endpoint.probes < 2 && waited < 60_000) {
            advanceTimeBy(100)
            runCurrent()
            waited += 100
        }
        assertEquals("the retry ran and met the visit", 2, endpoint.probes)

        advanceTimeBy(100)
        endpoint.binding.value = paneA
        runCurrent()
        assertEquals("the pane's return is checked at once", 3, endpoint.probes)
        coordinator.close()
    }

    private class ProbeCountingEndpoint(initial: AgentEndpointBinding) : AgentSessionEndpoint {
        override val key = initial.key
        override val binding = MutableStateFlow(initial)
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames: Flow<AgentLifecycleFrame> = emptyFlow()
        var probes = 0
        var onProbe: (Int) -> Unit = {}

        override suspend fun probeIntegration(
            binding: AgentEndpointBinding,
            command: AgentIntegrationCommand,
        ): AgentEndpointResult<AgentIntegrationStatus> {
            probes += 1
            onProbe(probes)
            return AgentEndpointResult.Unavailable("probe_unavailable")
        }

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
