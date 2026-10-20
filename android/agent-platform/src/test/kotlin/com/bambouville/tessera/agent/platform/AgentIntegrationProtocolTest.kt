package com.bambouville.tessera.agent.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class AgentIntegrationProtocolTest {
    @Test
    fun lifecycleRequirementUsesExactEndpointCapabilityForKimi() {
        val binding = AgentEndpointBinding(
            AgentSessionKey("session-a", 2),
            "host-a",
            AgentEndpointTransport.SSH,
        )
        val discovery = AgentProcessDiscoverySnapshot(
            processes = listOf(AgentDiscoveredProcess(42, 7, "/usr/local/bin/kimi", foreground = true)),
            foreground = com.bambouville.tessera.core.bridge.SharedAgentIntegrationForeground.Agent,
            foregroundShellProcessIDs = emptySet(),
            foregroundProviderProcessIDs = setOf(42),
            foregroundLifecycleProviderProcessIDs = setOf(42),
            foregroundRequiresLifecycleHook = true,
        )
        val expectedBinding = binding
        val staleBinding = binding.copy(paneID = "%9")
        val unsupported = object : AgentSessionLifecycleCapabilities {
            override fun supportsLifecycle(binding: AgentEndpointBinding, provider: AgentProofProvider) = false
        }
        val supported = object : AgentSessionLifecycleCapabilities {
            override fun supportsLifecycle(binding: AgentEndpointBinding, provider: AgentProofProvider) =
                binding == expectedBinding && provider == AgentProofProvider.KIMI
        }

        val classifyKimi: (AgentDiscoveredProcess) -> Set<AgentProofProvider> = { setOf(AgentProofProvider.KIMI) }
        assertTrue(lifecycleCapableForegroundProcessIDs(binding, discovery, unsupported, classifyKimi).isEmpty())
        assertEquals(setOf(42), lifecycleCapableForegroundProcessIDs(binding, discovery, supported, classifyKimi))
        assertTrue(lifecycleCapableForegroundProcessIDs(staleBinding, discovery, supported, classifyKimi).isEmpty())
    }

    @Test
    fun commandFactoriesConstrainOperationPayloadAndOutputBudgets() {
        val command = AgentIntegrationCommand.probe("printf probe\n".encodeToByteArray())

        assertEquals(AgentIntegrationOperation.PROBE, command.operation)
        assertEquals(16_384, command.maxStdoutBytes)
        assertThrows(IllegalArgumentException::class.java) {
            AgentIntegrationCommand.probe(ByteArray(AgentIntegrationCommand.MAX_STDIN_BYTES + 1) { 'x'.code.toByte() })
        }
        assertThrows(IllegalArgumentException::class.java) {
            AgentIntegrationCommand.currentShell(byteArrayOf('x'.code.toByte(), 0))
        }
    }

    @Test
    fun processDiscoveryScopeCannotNameAnArbitraryOrMalformedRouteRoot() {
        val scope = AgentProcessDiscoveryScope.RootProcess(42)
        assertEquals(42, scope.processID)
        assertThrows(IllegalArgumentException::class.java) {
            AgentProcessDiscoveryScope.RootProcess(1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            AgentProcessDiscoveryScope.RouteMarker("not-a-route-marker")
        }
    }

    @Test
    fun bsdForegroundTtyStrategyRecognizesOnlyAForegroundShellGroupLeader() {
        assertEquals(42, AgentBsdForegroundTtyStrategy.syntheticTerminalProcessGroup(42, "Ss+"))
        assertTrue(AgentBsdForegroundTtyStrategy.isForegroundGroupLeader(42, 42, "Ss+"))

        assertEquals(-1, AgentBsdForegroundTtyStrategy.syntheticTerminalProcessGroup(42, "Ss"))
        assertFalse(AgentBsdForegroundTtyStrategy.isForegroundGroupLeader(42, 42, "Ss"))

        // A foreground child belongs to the group but is not the shell's
        // process-group leader, so it cannot authorize current-shell work.
        assertFalse(AgentBsdForegroundTtyStrategy.isForegroundGroupLeader(43, 42, "R+"))
        assertFalse(AgentBsdForegroundTtyStrategy.isForegroundGroupLeader(1, 1, "Ss+"))
    }
}
