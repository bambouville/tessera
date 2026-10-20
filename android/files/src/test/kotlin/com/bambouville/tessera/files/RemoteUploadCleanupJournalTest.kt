package com.bambouville.tessera.files

import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteUploadCleanupJournalTest {
    @Test
    fun aRecordStaysWithItsUploadUntilHandedOverOrReadByALaterProcess() = runBlocking {
        val store = MemoryStore()
        val journal = RemoteUploadCleanupJournal(store)
        val id = journal.register(ROUTE, "/srv/.a.partial")

        assertTrue("an in-flight upload's record was claimable", journal.claimInactive(ROUTE).isEmpty())
        // A killed process leaves it for the next one.
        assertEquals(listOf(id), RemoteUploadCleanupJournal(store).claimInactive(ROUTE).map { it.id })

        journal.deactivate(id)
        assertEquals(listOf(id), journal.claimInactive(ROUTE).map { it.id })
        assertTrue("a claimed record was claimable twice", journal.claimInactive(ROUTE).isEmpty())

        journal.remove(id)
        assertNull(store.value)
    }

    @Test
    fun aReplacedOriginalIsOnlyEverDeleted() = runBlocking {
        val store = MemoryStore()
        val journal = RemoteUploadCleanupJournal(store)
        val id = journal.register(ROUTE, "/srv/.a.backup", restoreToRemotePath = "/srv/a")
        journal.markReplaced(id)

        assertEquals(listOf("/srv/.a.backup" to null), RemoteUploadCleanupJournal(store).records().map { it.remotePath to it.restoreToRemotePath })
    }

    @Test
    fun deactivatingNeverWaitsOnAnotherUploadsDiskWrite() = runBlocking {
        // deactivate runs on Main; commit() can take a while to reach the disk.
        val store = MemoryStore()
        val journal = RemoteUploadCleanupJournal(store)
        val id = journal.register(ROUTE, "/srv/.a.partial")
        val writing = CountDownLatch(1)
        val release = CountDownLatch(1)
        store.onAccess = { writing.countDown(); release.await() }
        val other = launch(Dispatchers.Default) { journal.register(ROUTE, "/srv/.b.partial") }
        writing.await()
        val watchdog = thread { Thread.sleep(2_000); release.countDown() }

        val started = System.nanoTime()
        journal.deactivate(id)
        val waitedMillis = (System.nanoTime() - started) / 1_000_000
        store.onAccess = {}
        release.countDown()
        other.join()
        watchdog.join()

        assertTrue("deactivate waited ${waitedMillis}ms on a store write", waitedMillis < 1_000)
    }

    @Test
    fun claimsOnlyTheRoutesOwnRecords() = runBlocking {
        val journal = RemoteUploadCleanupJournal(MemoryStore())
        val mine = journal.register(ROUTE, "/srv/.a.partial").also(journal::deactivate)
        journal.register("other@elsewhere:22", "/srv/.b.partial").also(journal::deactivate)

        assertEquals(listOf(mine), journal.claimInactive(ROUTE).map { it.id })
    }

    @Test
    fun anyPathRoundTripsThroughTheStore() = runBlocking {
        val store = MemoryStore()
        val path = "/srv/a b\n%20+ünï\t/.x y.partial"
        val restore = "/srv/a b\n%20+ünï\t/x y"
        RemoteUploadCleanupJournal(store).apply {
            register("user name@host:22 > jump@bastion:2222", path)
            register(ROUTE, "/srv/.b.backup", restoreToRemotePath = restore)
        }

        val records = RemoteUploadCleanupJournal(store).records()
        assertEquals(listOf(path to null, "/srv/.b.backup" to restore), records.map { it.remotePath to it.restoreToRemotePath })
        assertEquals("user name@host:22 > jump@bastion:2222", records.first().route)
    }

    @Test
    fun unreadableLinesAreSkipped() = runBlocking {
        val store = MemoryStore()
        RemoteUploadCleanupJournal(store).register(ROUTE, "/srv/.a.partial")
        store.value = "garbage\n" + store.value + "\nnot-a-uuid r p x 1\n"

        assertEquals(listOf("/srv/.a.partial"), RemoteUploadCleanupJournal(store).records().map { it.remotePath })
    }

    @Test
    fun theJournalKeepsItsNewestRecordsWithinItsCap() = runBlocking {
        val journal = RemoteUploadCleanupJournal(MemoryStore())
        repeat(RemoteUploadCleanupJournal.MAXIMUM_RECORDS + 4) { journal.register(ROUTE, "/srv/.$it.partial") }

        val records = journal.records()
        assertEquals(RemoteUploadCleanupJournal.MAXIMUM_RECORDS, records.size)
        assertEquals("/srv/.4.partial", records.first().remotePath)
    }

    private companion object {
        const val ROUTE = "tester@files.example:22"
    }
}
