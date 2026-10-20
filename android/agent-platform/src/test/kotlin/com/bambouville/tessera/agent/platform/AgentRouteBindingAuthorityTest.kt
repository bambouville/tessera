package com.bambouville.tessera.agent.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentRouteBindingAuthorityTest {
    @Test fun pidlessLifecycleBindingIsConstrainedToObserveOnly() {
        val binding = fixture().observeOnlyCoreBinding()

        assertEquals(1, binding.getInt("capabilities"))
        assertFalse(binding.has("agentPID"))
    }

    @Test fun actionBindingCarriesOnlyEndpointDerivedCapabilities() {
        val binding = fixture().actionableCoreBinding(
            42,
            AgentEndpointCapabilities(verifiedInput = true, semanticKeys = true, freshTerminalObservation = true, acknowledgedTmuxPlacement = true),
        )

        assertEquals(42, binding.getInt("agentPID"))
        assertEquals(31, binding.getInt("capabilities"))
    }

    @Test fun moshTmuxKeepsItsWireIdentityAndTmuxCapability() {
        val binding = AgentEndpointBinding(
            AgentSessionKey("carrier", 1), "host", AgentEndpointTransport.MOSH_TMUX,
            tmuxSession = "main", windowID = "@2", paneID = "%4",
        ).actionableCoreBinding(
            42,
            AgentEndpointCapabilities(verifiedInput = true, semanticKeys = true, freshTerminalObservation = true, acknowledgedTmuxPlacement = true),
        )

        assertEquals("moshTmux", binding.getString("transport"))
        assertEquals(31, binding.getInt("capabilities"))
    }

    @Test fun routeIssuerAcceptsEndpointAndClaimButNeverACallerMadeProcessProof() {
        val issue = AgentRouteBindingAuthority::class.java.declaredMethods.single { it.name == "issue" }
        assertTrue(issue.parameterTypes.any { it == AgentSessionEndpoint::class.java })
        assertFalse(issue.parameterTypes.any { it == AgentProcessProof::class.java || Set::class.java.isAssignableFrom(it) })
    }

    @Test fun coordinatorResolvesRegisteredEndpointRatherThanAcceptingEndpointOrRawProof() {
        val issue = AndroidAgentSessionCoordinator::class.java.declaredMethods
            .single { it.name == "issueRouteBinding" }

        assertFalse(issue.parameterTypes.any { it == AgentSessionEndpoint::class.java })
        assertFalse(issue.parameterTypes.any { it == AgentProcessProof::class.java || Set::class.java.isAssignableFrom(it) })
    }

    private fun fixture() = AgentEndpointBinding(
        AgentSessionKey("carrier", 1), "host", AgentEndpointTransport.SSH_TMUX,
        tmuxSession = "main", windowID = "@2", paneID = "%4",
    )
}
