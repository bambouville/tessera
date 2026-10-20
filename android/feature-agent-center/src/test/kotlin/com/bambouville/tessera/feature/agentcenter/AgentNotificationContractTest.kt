package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Test
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentSessionKey

class AgentNotificationContractTest {
    @Test fun malformedTokensFailClosed() {
        assertNull(runCatching { AgentNotificationRoute("not allowed", 1) }.getOrNull())
        assertNull(runCatching { AgentNotificationRoute("a".repeat(16), 0) }.getOrNull())
    }

    @Test fun notificationCopyIsContentFreeByDefault() {
        assertEquals("Open Tessera to review.", AndroidAgentAttentionNotifier.CONTENT_FREE_BODY)
        assertEquals(false, AndroidAgentAttentionNotifier.deliveryAllowed(false, "needsYou"))
        assertEquals(true, AndroidAgentAttentionNotifier.deliveryAllowed(true, "needsYou"))
        assertEquals(false, AndroidAgentAttentionNotifier.deliveryAllowed(true, "working"))
    }

    @Test fun routeRequiresTheCurrentLiveCarrierGeneration() {
        val live = listOf(AgentEndpointBinding(
            key = AgentSessionKey("live-1", 9), hostID = "fixture-host", transport = AgentEndpointTransport.SSH_TMUX,
        ))

        assertEquals(true, AgentNotificationContract.routeMatchesLiveCarrier("fixture-host:claude:thread", 9, live))
        assertEquals(false, AgentNotificationContract.routeMatchesLiveCarrier("fixture-host:claude:thread", 8, live))
        assertEquals(false, AgentNotificationContract.routeMatchesLiveCarrier("other-host:claude:thread", 9, live))
    }
}
