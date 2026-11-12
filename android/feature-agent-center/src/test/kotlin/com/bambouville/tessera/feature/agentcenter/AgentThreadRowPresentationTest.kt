package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentThreadRowPresentationTest {
    @Test fun listIdentityUsesProviderLocationAndFork() {
        assertEquals("Claude · tessera · main", row.listMetadata(EnglishAgentRowWords))
        assertEquals("Claude · tessera · main · fork", row.copy(isFork = true).listMetadata(EnglishAgentRowWords))
        assertEquals("Claude", row.copy(location = "").listMetadata(EnglishAgentRowWords))
        assertEquals("Claude · fork", row.copy(location = " ", isFork = true).listMetadata(EnglishAgentRowWords))
        // These remain available to the detail header, but never appear in the list identity.
        assertEquals("opus", row.model)
        assertEquals("plan", row.permissionMode)
        for (hidden in listOf("opus", "plan", "waitingForInput")) assertFalse(row.listMetadata(EnglishAgentRowWords).contains(hidden))
    }

    @Test fun accessibilitySpeaksEveryStatusInsteadOfItsWireValue() {
        for ((status, words) in listOf(
            "waitingForInput" to "needs input", "working" to "working", "idle" to "idle",
            "finished" to "finished", "unavailable" to "unavailable",
        )) {
            val description = row.copy(status = status).accessibilityDescription(EnglishAgentRowWords)
            assertTrue(description, description.split(", ").contains(words))
            assertFalse(description.contains("waitingForInput"))
            assertFalse(description.contains("opus"))
            assertFalse(description.contains("plan"))
        }
    }

    @Test fun accessibilityIncludesIdentityHostForkQueueAndAttentionOnce() {
        assertEquals(
            "Review, Claude · tessera · main · fork, host devbox, needs input, 2 queued, needs your attention",
            row.copy(isFork = true, queuedCount = "2").accessibilityDescription(EnglishAgentRowWords),
        )
    }

    private val row = AgentThreadRow(
        key = "thread", title = "Review", provider = "Claude", model = "opus", preview = "Approve?",
        status = "waitingForInput", attention = "needsYou", location = "tessera · main", queuedCount = null,
        isFork = false, actionAvailable = true, spawnAvailable = false, forkAvailable = false,
        host = "devbox", permissionMode = "plan",
    )
}
