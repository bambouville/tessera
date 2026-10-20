package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.AgentIntegrationConfigSnapshot
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationForeground
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallFailure
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Exercises the real shared decision ABI and native scheduler without host connections. */
class AgentIntegrationRecoveryInstrumentedTest {
    @Test fun quietFailureRecoversAndSuccessfulHostProbeIsCached(): Unit = runBlocking {
        for (transport in AgentEndpointTransport.entries) withFixture(transport) { integration, endpoint ->
            await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.Unavailable }
            endpoint.failProbe = false
            // No terminal output or lifecycle hook is delivered.
            await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.Ready }
            assertEquals(2, endpoint.probes)
            delay(2_200)
            assertEquals("Host file hashes must not be re-read every two seconds", 2, endpoint.probes)
            assertTrue("Foreground shell proof remains fresh", endpoint.shellInspections >= 2)
        }
    }

    @Test fun foregroundImmediatelyRetriesAndBackgroundStopsPolling(): Unit = runBlocking {
        for (transport in AgentEndpointTransport.entries) withFixture(transport) { integration, endpoint ->
            await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.Unavailable }
            integration.setApplicationForeground(false)
            val probes = endpoint.probes
            endpoint.failProbe = false
            delay(2_200)
            assertEquals(probes, endpoint.probes)
            integration.setApplicationForeground(true)
            withTimeout(1_000) { await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.Ready } }
            assertEquals(probes + 1, endpoint.probes)
        }
    }

    @Test fun repeatedManualRetryCoalescesAndCannotOverlapPeriodicCheck(): Unit = runBlocking {
        for (transport in AgentEndpointTransport.entries) withFixture(transport) { integration, endpoint ->
            await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.Unavailable }
            endpoint.failProbe = false
            val release = CompletableDeferred<Unit>()
            endpoint.probeGate = release
            val request = AgentSessionIntegrationActionRequest(endpoint.binding.value, AgentSessionIntegrationAction.Retry)
            repeat(20) { integration.requestAction(request) }
            withTimeout(1_000) { await { endpoint.probes == 2 } }
            delay(2_200) // The periodic monitor queues behind this explicit retry.
            assertEquals(2, endpoint.probes)
            assertEquals(1, endpoint.maximumConcurrentProbes)
            release.complete(Unit)
            await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.Ready }
            assertEquals(2, endpoint.probes)
        }
    }

    @Test fun installRefusedByANewerIntegrationRereadsTheHost(): Unit = runBlocking {
        for ((afterRefusal, expected) in listOf(
            AgentIntegrationStatus.RequiresAppUpdate(12) to AgentSessionIntegrationKind.AppUpdateRequired,
            AgentIntegrationStatus.Current to AgentSessionIntegrationKind.Ready,
        )) withFixture(AgentEndpointTransport.entries.first()) { integration, endpoint ->
            endpoint.failProbe = false
            endpoint.probeStatus = AgentIntegrationStatus.Missing
            await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.Missing }
            val install = checkNotNull(integration.statuses.value[endpoint.key]?.primaryAction)
            // A newer Tessera installs between this app's last probe and its install.
            endpoint.refuseInstallAs = afterRefusal
            integration.requestAction(AgentSessionIntegrationActionRequest(endpoint.binding.value, install))
            await { integration.statuses.value[endpoint.key]?.kind == expected }
            assertEquals("a refusal is never retried", 1, endpoint.installs)
        }
    }

    @Test fun provenAgentStaysReadyAcrossPaneAndWindowSwitchUntilItsProcessIdentityChanges(): Unit = runBlocking {
        withFixture(AgentEndpointTransport.SSH_TMUX, agentMode = true) { integration, endpoint ->
            await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.InsideAgent }
            endpoint.lifecycleFrames.emit(endpoint.frame())
            await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.Ready }

            val observed = mutableListOf<AgentSessionIntegrationKind>()
            val watcher = launch(Dispatchers.Main.immediate) {
                integration.statuses.collect { statuses -> statuses[endpoint.key]?.kind?.let(observed::add) }
            }
            try {
                endpoint.switchPane("@2", "%2")
                await { "%2" in endpoint.discoveredPanes }
                assertEquals(AgentSessionIntegrationKind.Ready, integration.statuses.value[endpoint.key]?.kind)
                assertFalse("A quiet proven agent must never become unconfirmed on a pane switch",
                    AgentSessionIntegrationKind.InsideAgent in observed)

                endpoint.processStart = "replacement-start"
                endpoint.switchPane("@3", "%3")
                await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.InsideAgent }
            } finally { watcher.cancel() }
        }
    }

    @Test fun retainedPaneFrameProvesQuietAgentWithoutNewEmission(): Unit = runBlocking {
        withFixture(AgentEndpointTransport.MOSH_TMUX, agentMode = true) { integration, endpoint ->
            await { integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.InsideAgent }
            val next = endpoint.binding.value.copy(windowID = "@2", paneID = "%2")
            endpoint.retainedFrames["%2"] = endpoint.frame(next)
            endpoint.switchPane("@2", "%2")
            await { "%2" in endpoint.retainedRequests &&
                "%2" in endpoint.discoveredPanes &&
                integration.statuses.value[endpoint.key]?.kind == AgentSessionIntegrationKind.Ready }
        }
    }

    private suspend fun withFixture(
        transport: AgentEndpointTransport,
        agentMode: Boolean = false,
        body: suspend (AgentSessionIntegrationCoordinator, ProbeEndpoint) -> Unit,
    ) = withContext(Dispatchers.Main) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val registry = LiveAgentSessionRegistry()
        val endpoint = ProbeEndpoint(transport, agentMode)
        registry.register(endpoint)
        endpoint.refreshBinding = { registry.refresh(endpoint.key) }
        val integration = AgentSessionIntegrationCoordinator(registry, scope)
        try { integration.setEnabled(true); body(integration, endpoint) }
        finally { integration.close(); registry.close(); scope.cancel() }
    }

    private suspend fun await(condition: () -> Boolean) = withTimeout(5_000) {
        while (!condition()) delay(10)
    }

    private class ProbeEndpoint(transport: AgentEndpointTransport, private val agentMode: Boolean) : AgentSessionEndpoint {
        override val key = AgentSessionKey(UUID.randomUUID().toString(), 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key, "test-host", transport,
            tmuxSession = if (agentMode) "fixture" else null,
            windowID = if (agentMode) "@1" else null,
            paneID = if (agentMode) "%1" else null))
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>(replay = 1)
        val retainedFrames = mutableMapOf<String, AgentLifecycleFrame>()
        val retainedRequests = mutableListOf<String>()
        val discoveredPanes = mutableListOf<String?>()
        var refreshBinding: (() -> Unit)? = null
        var processStart = "fixture-start"
        var failProbe = !agentMode
        var probeStatus: AgentIntegrationStatus = AgentIntegrationStatus.Current
        var refuseInstallAs: AgentIntegrationStatus? = null
        var installs = 0
        var probes = 0
        var concurrentProbes = 0
        var maximumConcurrentProbes = 0
        var shellInspections = 0
        var probeGate: CompletableDeferred<Unit>? = null

        fun frame(address: AgentEndpointBinding = binding.value) = AgentLifecycleFrame(address,
            """{"version":9,"provider":"claude","event":"UserPromptSubmit","state":"working","timestampNs":"1","sessionId":"fixture-conversation","agentPid":102,"transcriptRef":"b3BhcXVl"}""".encodeToByteArray())

        fun switchPane(window: String, pane: String) {
            binding.value = binding.value.copy(windowID = window, paneID = pane)
            refreshBinding?.invoke()
        }

        override fun retainedLifecycleFrame(binding: AgentEndpointBinding): AgentLifecycleFrame? {
            val pane = binding.paneID ?: return null
            retainedRequests.add(pane)
            return retainedFrames[pane]
        }

        override suspend fun probeIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationStatus> {
            probes++; concurrentProbes++
            maximumConcurrentProbes = maxOf(maximumConcurrentProbes, concurrentProbes)
            try {
                probeGate?.await()
                return if (failProbe) AgentEndpointResult.Unavailable("temporary-network-loss")
                else AgentEndpointResult.Success(probeStatus)
            } finally { concurrentProbes-- }
        }
        override suspend fun processDiscoveryScope(binding: AgentEndpointBinding): AgentEndpointResult<AgentProcessDiscoveryScope> =
            AgentEndpointResult.Success(AgentProcessDiscoveryScope.RootProcess(42))
        override suspend fun discoverProcesses(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentProcessDiscoverySnapshot> {
            discoveredPanes.add(binding.paneID)
            return if (agentMode) AgentEndpointResult.Success(AgentProcessDiscoverySnapshot(
                listOf(AgentDiscoveredProcess(102, 42, "/usr/local/bin/claude", true)),
                SharedAgentIntegrationForeground.Agent, emptySet(), setOf(102), setOf(102), true))
            else AgentEndpointResult.Success(AgentProcessDiscoverySnapshot(
                emptyList(), SharedAgentIntegrationForeground.Shell, setOf(42), emptySet(), emptySet(), false))
        }
        override suspend fun inspectCurrentShell(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentCurrentShellStatus> {
            shellInspections++
            return AgentEndpointResult.Success(AgentCurrentShellStatus(true))
        }
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> = unavailable()
        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider, requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> =
            if (agentMode && claimedPID == 102 && provider == AgentProofProvider.CLAUDE)
                AgentEndpointResult.Success(AgentProcessProof(setOf(102), provider, processStart))
            else unavailable()
        override suspend fun installIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> {
            val newer = refuseInstallAs ?: return unavailable()
            installs++
            probeStatus = newer
            return AgentEndpointResult.Success(SharedAgentIntegrationInstallOutcome.Failed(SharedAgentIntegrationInstallFailure.NewerInstalled))
        }
        override suspend fun readIntegrationConfigs(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationConfigSnapshots> =
            AgentEndpointResult.Success(AgentIntegrationConfigSnapshots(
                AgentIntegrationConfigSnapshot.Missing, AgentIntegrationConfigSnapshot.Missing, AgentIntegrationConfigSnapshot.Missing,
            ))
        override suspend fun activateCurrentShell(binding: AgentEndpointBinding, expectedProcessIDs: Set<Int>, command: AgentShellActivationCommand): AgentEndpointResult<Unit> = unavailable()
        override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> = unavailable()
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> = unavailable()
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> = unavailable()
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> = unavailable()
        override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> = unavailable()
        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> = unavailable()
        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> = unavailable()
        override fun close() = Unit
        private fun unavailable() = AgentEndpointResult.Unavailable("unused-test-operation")
    }
}
