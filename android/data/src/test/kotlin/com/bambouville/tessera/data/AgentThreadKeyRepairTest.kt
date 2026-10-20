package com.bambouville.tessera.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class AgentThreadKeyRepairTest {
    private val upper = "3D3A4197-49AB-4532-AED7-7518ED250C72"
    private val lower = "3d3a4197-49ab-4532-aed7-7518ed250c72"

    @Test fun storedKeysAreRespelledOnlyInTheHostSegment() {
        assertEquals("$lower:claude:Session-A", canonicalAgentThreadKey("$upper:claude:Session-A"))
        assertEquals("$lower:claude:Session-A", canonicalAgentThreadKey("$lower:claude:Session-A"))
        assertEquals("not-a-thread-key", canonicalAgentThreadKey("not-a-thread-key"))
        assertEquals("host-a:claude:s", canonicalAgentThreadKey("host-a:claude:s"))
    }

    @Test fun restoreMergesLegacyUpperCaseRowsAndRepairsTheTable() = runBlocking {
        val dao = TableAgentMetadataDao()
        dao.rows["$upper:claude:7610a301"] = AgentThreadMetadataEntity("$upper:claude:7610a301", "record-old", false, 100L)
        dao.rows["$lower:claude:7610a301"] = AgentThreadMetadataEntity("$lower:claude:7610a301", "record-new", true, 200L)
        dao.rows["$upper:codex:only-legacy"] = AgentThreadMetadataEntity("$upper:codex:only-legacy", "record-legacy", false, 50L)
        dao.rows["$lower:codex:clean"] = AgentThreadMetadataEntity("$lower:codex:clean", null, false, 300L)
        val repository = AndroidAgentMetadataRepository(dao)

        val restored = repository.restoredThreads()

        assertEquals(
            listOf(
                RestoredAgentThreadMetadata("$lower:codex:clean", null),
                RestoredAgentThreadMetadata("$lower:claude:7610a301", "record-new"),
                RestoredAgentThreadMetadata("$lower:codex:only-legacy", "record-legacy"),
            ),
            restored,
        )
        assertEquals(restored.size, restored.map(RestoredAgentThreadMetadata::threadKey).toSet().size)
        assertEquals(
            setOf("$lower:codex:clean", "$lower:claude:7610a301", "$lower:codex:only-legacy"),
            dao.rows.keys,
        )
        assertEquals("record-new", dao.rows["$lower:claude:7610a301"]?.lastReadRecordID)
        assertEquals(200L, dao.rows["$lower:claude:7610a301"]?.updatedAtEpochMilliseconds)
        assertEquals(50L, dao.rows["$lower:codex:only-legacy"]?.updatedAtEpochMilliseconds)
    }

    @Test fun readsAreRememberedUnderTheCanonicalKey() = runBlocking {
        val dao = TableAgentMetadataDao()
        val repository = AndroidAgentMetadataRepository(dao)

        repository.rememberRead("$upper:claude:s", "record-1", unread = false, now = 7L)

        assertEquals(setOf("$lower:claude:s"), dao.rows.keys)
    }

    @Test fun completionKeysSurviveReadsAndRestore() = runBlocking {
        val dao = TableAgentMetadataDao()
        val repository = AndroidAgentMetadataRepository(dao)
        val key = "$lower:claude:s"

        repository.rememberCompletion("$upper:claude:s", null, null, now = 1L)
        assertEquals("nothing to remember creates no row", emptySet<String>(), dao.rows.keys)

        repository.rememberCompletion(key, "c1:a:2a", null, now = 5L)
        repository.rememberRead(key, "record-1", unread = false, now = 6L)
        assertEquals("c1:a:2a", dao.rows[key]?.unreadCompletionKey)
        assertEquals("record-1", dao.rows[key]?.lastReadRecordID)

        repository.rememberCompletion(key, null, "c1:a:2a", now = 7L)
        repository.rememberRead(key, "record-2", unread = false, now = 8L)
        val restored = repository.restoredThreads()
        assertEquals(listOf(RestoredAgentThreadMetadata(key, "record-2", null, "c1:a:2a")), restored)

        val unchanged = dao.rows.getValue(key)
        repository.rememberCompletion(key, null, "c1:a:2a", now = 99L)
        assertEquals("an unchanged pair is not rewritten", unchanged, dao.rows[key])
    }

    private class TableAgentMetadataDao : AgentMetadataDao {
        val rows = LinkedHashMap<String, AgentThreadMetadataEntity>()
        override suspend fun upsertThread(metadata: AgentThreadMetadataEntity) { rows[metadata.threadKey] = metadata }
        override suspend fun thread(threadKey: String): AgentThreadMetadataEntity? = rows[threadKey]
        override suspend fun threads(): List<AgentThreadMetadataEntity> =
            rows.values.sortedByDescending { it.updatedAtEpochMilliseconds }.take(1024)
        override suspend fun deleteThread(threadKey: String) { rows.remove(threadKey) }
        override suspend fun upsertRoute(route: AgentRouteTokenEntity) = Unit
        override suspend fun route(routeToken: String, generation: Long, now: Long): AgentRouteTokenEntity? = null
        override suspend fun deleteExpiredRoutes(now: Long): Int = 0
        override suspend fun upsertLineage(lineage: AgentThreadLineageEntity) = Unit
        override suspend fun lineage(threadKey: String): AgentThreadLineageEntity? = null
        override suspend fun upsertLaunchReceipt(receipt: AgentLaunchReceiptEntity) = Unit
        override suspend fun launchReceipt(threadKey: String): AgentLaunchReceiptEntity? = null
    }
}
