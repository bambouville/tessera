package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentSessionKey
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentEndpointInventoryIdentityTest {
    @Test fun focusAndSavedNameChangesKeepOwnersButCarrierChangesRevokeThem() {
        for (transport in AgentEndpointTransport.entries) {
            val original = AgentEndpointBinding(AgentSessionKey("carrier", 1), "host", transport,
                tmuxSession = "session", windowID = "@1", paneID = "%1", hostDisplayLabel = "old")
            assertTrue(original.retainsAgentThreadOwners(original.copy(windowID = "@2", paneID = "%2")))
            assertTrue("native Pi inventory uses a pane-free carrier", original.retainsAgentThreadOwners(original.copy(windowID = null, paneID = null)))
            assertTrue(original.retainsAgentThreadOwners(original.copy(hostDisplayLabel = "renamed")))
            assertFalse(original.retainsAgentThreadOwners(original.copy(hostID = "other")))
            assertFalse(original.retainsAgentThreadOwners(original.copy(tmuxSession = "other")))
            assertFalse(original.retainsAgentThreadOwners(original.copy(key = original.key.copy(carrierGeneration = 2))))
            assertFalse(original.retainsAgentThreadOwners(original.copy(transport = AgentEndpointTransport.entries.first { it != transport })))
        }
    }
}
