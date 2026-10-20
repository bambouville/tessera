package com.bambouville.tessera.data

import androidx.room.Room
import androidx.room.withTransaction
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AgentThreadRepairInstrumentedTest {
    private val upper = "3D3A4197-49AB-4532-AED7-7518ED250C72:codex:Session-A"
    private val lower = "3d3a4197-49ab-4532-aed7-7518ed250c72:codex:Session-A"

    @Test fun repairAndConcurrentReadKeepTheNewestAcknowledgement() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val database = Room.inMemoryDatabaseBuilder(context, TesseraDatabase::class.java).build()
        try {
            val dao = database.agentMetadataDao()
            val restoring = AndroidAgentMetadataRepository(dao)
            val reading = AndroidAgentMetadataRepository(dao)
            repeat(40) { iteration ->
                dao.deleteThread(lower)
                dao.upsertThread(AgentThreadMetadataEntity(upper, "old", false, 1))
                listOf(
                    async(Dispatchers.IO) { restoring.restoredThreads() },
                    async(Dispatchers.IO) { reading.rememberRead(lower, "new-$iteration", false, 2) },
                ).awaitAll()
                assertEquals("new-$iteration", dao.thread(lower)?.lastReadRecordID)
                assertEquals(listOf(lower), dao.threads().map { it.threadKey })
            }
        } finally { database.close() }
    }

    @Test fun concurrentReadsAndCompletionReadsKeepEachOther() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val database = Room.inMemoryDatabaseBuilder(context, TesseraDatabase::class.java).build()
        try {
            val dao = database.agentMetadataDao()
            val repository = AndroidAgentMetadataRepository(dao)
            repeat(40) { iteration ->
                dao.deleteThread(lower)
                listOf(
                    async(Dispatchers.IO) { repository.rememberRead(lower, "record-$iteration", false, 2) },
                    async(Dispatchers.IO) { repository.rememberCompletion(lower, null, "c1:$iteration:2a", 3) },
                ).awaitAll()
                val row = dao.thread(lower)
                assertEquals("record-$iteration", row?.lastReadRecordID)
                assertEquals("c1:$iteration:2a", row?.acknowledgedCompletionKey)
            }
            assertEquals(
                listOf(RestoredAgentThreadMetadata(lower, "record-39", null, "c1:39:2a")),
                repository.restoredThreads(),
            )
        } finally { database.close() }
    }

    @Test fun interruptedRepairRollsBackAndCanBeRetried() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val database = Room.inMemoryDatabaseBuilder(context, TesseraDatabase::class.java).build()
        try {
            val dao = database.agentMetadataDao()
            dao.upsertThread(AgentThreadMetadataEntity(upper, "retained", true, 7))
            runCatching {
                database.withTransaction {
                    dao.repairThreadKeys()
                    error("interrupt before commit")
                }
            }
            assertEquals(listOf(upper), dao.threads().map { it.threadKey })
            val restored = AndroidAgentMetadataRepository(dao).restoredThreads()
            assertEquals(listOf(RestoredAgentThreadMetadata(lower, "retained")), restored)
            assertEquals(listOf(lower), dao.threads().map { it.threadKey })
        } finally { database.close() }
    }
}
