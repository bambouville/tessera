package com.bambouville.tessera.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Test

class AgentMetadataPolicyTest {
    @Test fun metadataEntitiesContainNoTranscriptCursorOrPathFields() {
        val fields = listOf(
            AgentThreadMetadataEntity::class.java,
            AgentRouteTokenEntity::class.java,
            AgentThreadLineageEntity::class.java,
            AgentLaunchReceiptEntity::class.java,
        ).flatMap { it.declaredFields.asList() }.map { it.name.lowercase() }
        listOf("transcript", "cursor", "path", "content", "preview", "body").forEach { forbidden ->
            assertFalse("persisted Agent metadata must not contain $forbidden", fields.any { forbidden in it })
        }
    }

    @Test fun viewPreferencesPersistOnlySafeDisplayChoicesWithSpecDefaults() {
        val defaults = AgentCenterViewPreferences()

        assertEquals("attention", defaults.grouping)
        assertFalse(defaults.showSystemEvents)
        assertEquals("live", defaults.compactTab)
        val fields = AgentCenterViewPreferences::class.java.declaredFields.map { it.name.lowercase() }
        listOf("transcript", "cursor", "path", "content", "binding", "token").forEach { forbidden ->
            assertFalse("view preferences must not contain $forbidden", fields.any { forbidden in it })
        }
    }
}
