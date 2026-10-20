package com.bambouville.tessera.agent.platform

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentTierCRemoteInventoryTest {
    @Test fun acceptsOnlyOrderedFixedProviderInventoryFrames() {
        val bytes = """
            {"v":1,"kind":"inventory","sequence":0,"provider":"opencode","providerSessionID":"session-1","transcriptRef":"opaque-ref","lastActivityNs":1,"size":0}
            {"v":1,"kind":"end","cursor":null,"hasMore":false,"warnings":[]}
        """.trimIndent().encodeToByteArray()

        val result = AgentTierCRemoteInventory.AgentTierCInventoryFrames.parse(
            AgentTierCProvider.OpenCode,
            bytes,
        )

        val accepted = result as AgentEndpointResult.Success
        assertEquals(AgentTierCProvider.OpenCode, accepted.value.provider)
        assertEquals(listOf("session-1"), accepted.value.records.map { it.providerSessionID })
        assertEquals(null, accepted.value.cursor)
        assertEquals(false, accepted.value.hasMore)
    }

    @Test fun rejectsWrongProviderOutOfOrderAndForgedFrames() {
        val wrongProvider = """
            {"v":1,"kind":"inventory","sequence":0,"provider":"claude","providerSessionID":"session-1","transcriptRef":"opaque-ref"}
            {"v":1,"kind":"end","cursor":null,"hasMore":false,"warnings":[]}
        """.trimIndent().encodeToByteArray()
        val outOfOrder = """
            {"v":1,"kind":"inventory","sequence":4,"provider":"kimi","providerSessionID":"session-1","transcriptRef":"opaque-ref"}
            {"v":1,"kind":"end","cursor":null,"hasMore":false,"warnings":[]}
        """.trimIndent().encodeToByteArray()
        val forged = """
            {"v":1,"kind":"inventory","sequence":0,"provider":"pi","providerSessionID":"session-1","transcriptRef":"opaque-ref"}
            {"v":1,"kind":"error","error":"unsupported"}
        """.trimIndent().encodeToByteArray()

        assertTrue(AgentTierCRemoteInventory.AgentTierCInventoryFrames.parse(AgentTierCProvider.OpenCode, wrongProvider) is AgentEndpointResult.Failed)
        assertTrue(AgentTierCRemoteInventory.AgentTierCInventoryFrames.parse(AgentTierCProvider.Kimi, outOfOrder) is AgentEndpointResult.Failed)
        assertTrue(AgentTierCRemoteInventory.AgentTierCInventoryFrames.parse(AgentTierCProvider.Pi, forged) is AgentEndpointResult.Failed)
    }

    @Test fun requiresBoundedOpaqueCursorForContinuedInventory() {
        val continued = """
            {"v":1,"kind":"inventory","sequence":0,"provider":"pi","providerSessionID":"session-1","transcriptRef":"opaque-ref"}
            {"v":1,"kind":"end","cursor":"next-page","hasMore":true,"warnings":[]}
        """.trimIndent().encodeToByteArray()
        val missingCursor = """
            {"v":1,"kind":"end","cursor":null,"hasMore":true,"warnings":[]}
        """.trimIndent().encodeToByteArray()

        val accepted = AgentTierCRemoteInventory.AgentTierCInventoryFrames.parse(
            AgentTierCProvider.Pi,
            continued,
        ) as AgentEndpointResult.Success
        assertEquals("next-page", accepted.value.cursor)
        assertTrue(accepted.value.hasMore)
        assertTrue(AgentTierCRemoteInventory.AgentTierCInventoryFrames.parse(AgentTierCProvider.Pi, missingCursor) is AgentEndpointResult.Failed)
    }
}
