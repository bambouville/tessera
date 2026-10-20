package com.bambouville.tessera.files

import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Staged uploads against an in-memory SFTP v3 filesystem: rename never
 * overwrites, remove fails on a missing file, and every operation checks
 * cancellation before and after it runs, as the real `withContext(IO)` calls
 * do, so a cancel can land after the server applied an operation.
 */
class StagedRemoteUploadTest {
    private val store = MemoryStore()
    private val journal = RemoteUploadCleanupJournal(store)
    private val staged = StagedRemoteUpload(journal)
    private val token = UUID.fromString("00000000-0000-0000-0000-00000000abcd")

    @Test
    fun anUploadCommitsThroughAHiddenStagingFileAndLeavesNothingBehind() = runBlocking {
        val host = FakeRemoteFiles()
        staged.upload(host, FINAL, token, replaceExisting = false) { host.files[it] = "new" }

        assertEquals(mapOf(FINAL to "new"), host.files)
        assertEquals(listOf("rename $STAGING -> $FINAL"), host.mutations)
        assertTrue(journal.records().isEmpty())
        assertEquals(null, store.value)
    }

    @Test
    fun aReplaceSwapsTheNewFileInAndThenDeletesTheOriginal() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" }

        assertEquals(mapOf(FINAL to "new"), host.files)
        assertEquals(listOf("rename $FINAL -> $BACKUP", "rename $STAGING -> $FINAL", "remove $BACKUP"), host.mutations)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun anUploadWithoutReplaceNeverOverwritesAnExistingFile() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        val result = runCatching { staged.upload(host, FINAL, token, replaceExisting = false) { host.files[it] = "new" } }

        assertTrue(result.exceptionOrNull() is IOException)
        assertEquals(mapOf(FINAL to "old"), host.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun cancellingWhileWritingStillRemovesTheStagingFile() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        val writing = CompletableDeferred<Unit>()
        val upload = launch(Dispatchers.Default) {
            staged.upload(host, FINAL, token, replaceExisting = true) {
                host.files[it] = "partial"
                writing.complete(Unit)
                awaitCancellation()
            }
        }
        writing.await()
        upload.cancelAndJoin()

        assertEquals(mapOf(FINAL to "old"), host.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun cancellingBetweenTheTwoRenamesPutsTheOriginalBack() = runBlocking {
        // Disposal landing after the server moved the original aside.
        val host = FakeRemoteFiles(FINAL to "old")
        val upload = launch(Dispatchers.Default, start = CoroutineStart.LAZY) {
            staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" }
        }
        host.afterApplied = { if (it == "rename $FINAL -> $BACKUP") upload.cancel() }
        upload.start()
        upload.join()

        assertTrue(upload.isCancelled)
        assertEquals(mapOf(FINAL to "old"), host.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun aLostReplyAfterTheCommitRenameStillCountsAsUploaded() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        host.afterApplied = { if (it == "rename $STAGING -> $FINAL") throw IOException("reply lost") }
        staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" }

        assertEquals(mapOf(FINAL to "new"), host.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun aLostReplyAfterAPlainCommitStillCountsAsUploaded() = runBlocking {
        val host = FakeRemoteFiles()
        host.afterApplied = { if (it == "rename $STAGING -> $FINAL") throw IOException("reply lost") }
        staged.upload(host, FINAL, token, replaceExisting = false) { host.files[it] = "new" }

        assertEquals(mapOf(FINAL to "new"), host.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun aCancelThatLandsAfterTheCommitStillReportsTheUpload() = runBlocking {
        // The server applied the commit rename; the cancel arrives with its reply.
        val host = FakeRemoteFiles(FINAL to "old")
        var returned = false
        lateinit var upload: Job
        upload = launch(Dispatchers.Default, start = CoroutineStart.LAZY) {
            staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" }
            returned = true
        }
        host.afterApplied = {
            if (it == "rename $STAGING -> $FINAL") {
                upload.cancel()
                // Journal writes finish after the caller has suspended.
                store.onAccess = { Thread.sleep(20) }
            }
        }
        upload.start()
        upload.join()

        assertTrue("a committed replace was reported as cancelled", returned)
        assertEquals(mapOf(FINAL to "new"), host.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun aDeadLinkMidReplaceLeavesBothFilesJournaledForTheNextConnectionToRestore() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        host.afterApplied = { if (it == "rename $FINAL -> $BACKUP") host.dead = true }
        val result = runCatching { staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" } }

        assertTrue(result.exceptionOrNull() is IOException)
        assertEquals(mapOf(STAGING to "new", BACKUP to "old"), host.files)
        assertEquals(setOf(STAGING to null, BACKUP to FINAL), journal.records().map { it.remotePath to it.restoreToRemotePath }.toSet())

        // A later process, on a new connection to the same host.
        val reconnected = FakeRemoteFiles(files = host.files)
        StagedRemoteUpload(RemoteUploadCleanupJournal(store)).retryPending(reconnected)

        assertEquals(mapOf(FINAL to "old"), reconnected.files)
        assertEquals(null, store.value)
    }

    @Test
    fun retryDeletesAMovedAsideOriginalOnceTheReplacementLanded() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        host.afterApplied = { if (it == "rename $STAGING -> $FINAL") host.dead = true }
        runCatching { staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" } }
        assertEquals(mapOf(FINAL to "new", BACKUP to "old"), host.files)

        val reconnected = FakeRemoteFiles(files = host.files)
        staged.retryPending(reconnected)

        assertEquals(mapOf(FINAL to "new"), reconnected.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun aReplacementThatLandedNeverBringsTheOriginalBack() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        host.afterApplied = { if (it == "rename $STAGING -> $FINAL") host.dead = true }
        staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" }
        assertEquals(mapOf(FINAL to "new", BACKUP to "old"), host.files)

        // The user deletes the new file from a terminal before Files reconnects.
        host.files.remove(FINAL)
        val reconnected = FakeRemoteFiles(files = host.files)
        staged.retryPending(reconnected)

        assertEquals(emptyMap<String, String>(), reconnected.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun aRetryCancelledWhileClaimingLeavesItsRecordsForTheNextConnection() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        host.afterApplied = { if (it == "rename $FINAL -> $BACKUP") host.dead = true }
        runCatching { staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" } }

        // The controller closes while a new connection's retry is claiming.
        val claiming = CountDownLatch(1)
        val release = CountDownLatch(1)
        store.onAccess = { claiming.countDown(); release.await() }
        val retry = launch(Dispatchers.Default) { staged.retryPending(FakeRemoteFiles(files = host.files)) }
        claiming.await()
        retry.cancel()
        store.onAccess = {}
        Thread.sleep(50)
        release.countDown()
        retry.join()

        val reconnected = FakeRemoteFiles(files = host.files)
        staged.retryPending(reconnected)
        assertEquals(mapOf(FINAL to "old"), reconnected.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun aRetryLeavesFilesThatAnUploadInProgressOwnsAlone() = runBlocking {
        val host = FakeRemoteFiles()
        val writing = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        val upload = launch(Dispatchers.Default) {
            staged.upload(host, FINAL, token, replaceExisting = false) {
                host.files[it] = "new"
                writing.complete(Unit)
                finish.await()
            }
        }
        writing.await()
        staged.retryPending(FakeRemoteFiles(files = host.files))
        assertEquals(mapOf(STAGING to "new"), host.files)

        finish.complete(Unit)
        upload.join()
        assertEquals(mapOf(FINAL to "new"), host.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun aRetryLeavesAnotherHostsRecordsAlone() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        host.afterApplied = { if (it == "rename $FINAL -> $BACKUP") host.dead = true }
        runCatching { staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" } }

        val elsewhere = FakeRemoteFiles(route = "other@elsewhere:22", files = host.files)
        staged.retryPending(elsewhere)

        assertEquals(mapOf(STAGING to "new", BACKUP to "old"), elsewhere.files)
        assertEquals(2, journal.records().size)
    }

    @Test
    fun aFailedRetryKeepsItsRecordForTheNextConnection() = runBlocking {
        val host = FakeRemoteFiles(FINAL to "old")
        host.afterApplied = { if (it == "rename $FINAL -> $BACKUP") host.dead = true }
        runCatching { staged.upload(host, FINAL, token, replaceExisting = true) { host.files[it] = "new" } }

        val stillDead = FakeRemoteFiles(files = host.files).apply { dead = true }
        staged.retryPending(stillDead)
        assertEquals(2, journal.records().size)

        val healthy = FakeRemoteFiles(files = host.files)
        staged.retryPending(healthy)
        assertEquals(mapOf(FINAL to "old"), healthy.files)
        assertTrue(journal.records().isEmpty())
    }

    @Test
    fun hiddenNamesSitBesideTheDestination() {
        assertEquals("/srv/.a b.txt.tessera-upload-$token.partial", StagedRemoteUpload.stagingPath("/srv/a b.txt", token))
        assertEquals("/srv/.a b.txt.tessera-replaced-$token.backup", StagedRemoteUpload.backupPath("/srv/a b.txt", token))
        assertEquals(".upload.tessera-upload-$token.partial", StagedRemoteUpload.stagingPath("", token))
    }

    private class FakeRemoteFiles(
        vararg initial: Pair<String, String>,
        override val route: String = ROUTE,
        val files: MutableMap<String, String> = linkedMapOf(*initial),
    ) : RemoteUploadFiles {
        val mutations = mutableListOf<String>()

        /** Runs once a mutation has applied, before its reply returns. */
        var afterApplied: (String) -> Unit = {}

        @Volatile
        var dead = false

        override suspend fun exists(path: String): Boolean = operation(null) { path in files }

        override suspend fun rename(from: String, to: String) = operation("rename $from -> $to") {
            if (from !in files) throw IOException("No such file: $from")
            if (to in files) throw IOException("Failure: $to exists")
            files[to] = files.remove(from)!!
        }

        override suspend fun remove(path: String) = operation("remove $path") {
            if (files.remove(path) == null) throw IOException("No such file: $path")
        }

        private suspend fun <T> operation(mutation: String?, apply: () -> T): T {
            currentCoroutineContext().ensureActive()
            if (dead) throw IOException("Connection closed")
            val result = synchronized(files) { apply() }
            if (mutation != null) {
                mutations += mutation
                afterApplied(mutation)
            }
            currentCoroutineContext().ensureActive()
            return result
        }
    }

    private companion object {
        const val ROUTE = "tester@files.example:22"
        const val FINAL = "/home/tester/docs/report.txt"
        const val STAGING = "/home/tester/docs/.report.txt.tessera-upload-00000000-0000-0000-0000-00000000abcd.partial"
        const val BACKUP = "/home/tester/docs/.report.txt.tessera-replaced-00000000-0000-0000-0000-00000000abcd.backup"
    }
}

internal class MemoryStore(var value: String? = null) : RemoteUploadCleanupStore {
    /** Runs at every read and write, inside the journal's store lock. */
    @Volatile
    var onAccess: () -> Unit = {}

    override fun read(): String? {
        onAccess()
        return value
    }

    override fun write(value: String?) {
        onAccess()
        this.value = value
    }
}
