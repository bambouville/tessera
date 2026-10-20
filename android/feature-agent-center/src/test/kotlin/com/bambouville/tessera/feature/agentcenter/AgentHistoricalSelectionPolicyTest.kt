package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertEquals
import org.junit.Test

class AgentHistoricalSelectionPolicyTest {
    @Test fun hiddenButOwnedSelectionAndCachedDetailSurviveLiveListReplacement() {
        val resolved = resolveAgentHistoricalSelection(
            previousSelection = "host:codex:history",
            cachedDetailKeys = setOf("host:codex:history", "host:claude:live"),
            visibleRowKeys = listOf("host:claude:live"),
            ownedThreadKeys = setOf("host:codex:history", "host:claude:live"),
        )

        assertEquals("host:codex:history", resolved.selectedThreadKey)
        assertEquals(setOf("host:codex:history", "host:claude:live"), resolved.retainedDetailKeys)
    }

    @Test fun revokedHiddenOwnerRetiresSelectionAndCachedDetail() {
        val resolved = resolveAgentHistoricalSelection(
            previousSelection = "host:codex:history",
            cachedDetailKeys = setOf("host:codex:history", "host:claude:live"),
            visibleRowKeys = listOf("host:claude:live"),
            ownedThreadKeys = setOf("host:claude:live"),
        )

        assertEquals("host:claude:live", resolved.selectedThreadKey)
        assertEquals(setOf("host:claude:live"), resolved.retainedDetailKeys)
    }

    @Test fun invalidOrAbsentSelectionDefaultsToFirstVisibleRow() {
        val resolved = resolveAgentHistoricalSelection(
            previousSelection = "host:codex:gone",
            cachedDetailKeys = emptySet(),
            visibleRowKeys = listOf("host:claude:first", "host:codex:second"),
            ownedThreadKeys = emptySet(),
        )

        assertEquals("host:claude:first", resolved.selectedThreadKey)
    }
}
