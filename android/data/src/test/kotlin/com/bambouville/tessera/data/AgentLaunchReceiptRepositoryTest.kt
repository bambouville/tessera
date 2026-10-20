package com.bambouville.tessera.data

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AgentLaunchReceiptRepositoryTest {
    @Test fun acknowledgedReceiptIsWrittenBeforeAChildLifecycleCanArrive() = runBlocking {
        val dao = RecordingAgentMetadataDao()
        val repository = AndroidAgentMetadataRepository(dao)

        repository.rememberLaunchReceipt(
            threadKey = "host:claude:source",
            requestID = "6d5d36d0-3121-4b2e-aafd-12fd43d5c7e1",
            parentThreadKey = "host:claude:source",
            parentRecordID = "record-12",
            windowID = "@7",
            paneID = "%9",
            worktreeCreated = false,
            now = 42L,
        )

        val receipt = requireNotNull(dao.receipt)
        assertEquals("host:claude:source", receipt.threadKey)
        assertEquals("6d5d36d0-3121-4b2e-aafd-12fd43d5c7e1", receipt.requestID)
        assertEquals("record-12", receipt.parentRecordID)
        assertEquals("@7", receipt.windowID)
        assertEquals("%9", receipt.paneID)
        assertFalse(receipt.worktreeCreated)
    }

    private class RecordingAgentMetadataDao : AgentMetadataDao {
        var receipt: AgentLaunchReceiptEntity? = null
        override suspend fun upsertThread(metadata: AgentThreadMetadataEntity) = Unit
        override suspend fun thread(threadKey: String): AgentThreadMetadataEntity? = null
        override suspend fun threads(): List<AgentThreadMetadataEntity> = emptyList()
        override suspend fun deleteThread(threadKey: String) = Unit
        override suspend fun upsertRoute(route: AgentRouteTokenEntity) = Unit
        override suspend fun route(routeToken: String, generation: Long, now: Long): AgentRouteTokenEntity? = null
        override suspend fun deleteExpiredRoutes(now: Long): Int = 0
        override suspend fun upsertLineage(lineage: AgentThreadLineageEntity) = Unit
        override suspend fun lineage(threadKey: String): AgentThreadLineageEntity? = null
        override suspend fun upsertLaunchReceipt(receipt: AgentLaunchReceiptEntity) { this.receipt = receipt }
        override suspend fun launchReceipt(threadKey: String): AgentLaunchReceiptEntity? =
            receipt?.takeIf { it.threadKey == threadKey }
    }
}
