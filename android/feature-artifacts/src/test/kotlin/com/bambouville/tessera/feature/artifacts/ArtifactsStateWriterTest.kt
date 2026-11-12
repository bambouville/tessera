package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactsFilter
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.core.bridge.SharedArtifactsPersistenceFiles
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ArtifactsStateWriterTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test(timeout = 10_000) fun splittingAndBlobWritesRunOnTheWriterAndStaleGenerationsDoNoWork() {
        val caller = Thread.currentThread()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val saved = CountDownLatch(2)
        val splits = AtomicInteger()
        val blobWrites = AtomicInteger()
        val stateWrites = AtomicInteger()
        val file = File(temporary.root, "artifacts/state.json")
        val stateFile = ArtifactsStateFile(file, split = {
            assertNotEquals(caller, Thread.currentThread())
            splits.incrementAndGet()
            if (it.filter == SharedArtifactsFilter.Docs) {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
            }
            SharedArtifactsPersistenceFiles(it.filter.wireValue, mapOf("a".repeat(64) to "+immutable\n"))
        }, blobDigests = { emptyList() }, join = { _, _ -> SharedArtifactsState() }, replace = { from, to ->
            assertNotEquals(caller, Thread.currentThread())
            if (to.extension == "diff") blobWrites.incrementAndGet() else stateWrites.incrementAndGet()
            replaceArtifactFile(from, to)
            if (to == file) saved.countDown()
        })
        val writer = ArtifactsStateWriter(stateFile, scope)
        try {
            writer.enqueue(SharedArtifactsState(filter = SharedArtifactsFilter.Docs), 1)
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            writer.enqueue(SharedArtifactsState(filter = SharedArtifactsFilter.Pages), 3)
            writer.enqueue(SharedArtifactsState(filter = SharedArtifactsFilter.Files), 2)
            release.countDown()
            assertTrue(saved.await(5, TimeUnit.SECONDS))
            // Synchronized save also drains the consumer's current critical section.
            stateFile.save(SharedArtifactsState(), 0)
            assertEquals("pages", file.readText())
            assertEquals(2, splits.get())
            assertEquals(1, blobWrites.get())
            assertEquals(2, stateWrites.get())
        } finally { release.countDown(); scope.cancel() }
    }

    @Test(timeout = 10_000) fun enqueueNeverWaitsForEncodingOrSyncAndOlderGenerationsCannotLandLast() {
        val caller = Thread.currentThread()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val saved = CountDownLatch(2)
        val file = File(temporary.root, "state.json")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val writes = mutableListOf<String>()
        val stateFile = ArtifactsStateFile(file, encode = {
            assertNotEquals(caller, Thread.currentThread())
            it.filter.wireValue
        }, replace = { from, to ->
            val value = from.readText()
            if (value == "docs") {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
            }
            replaceArtifactFile(from, to)
            synchronized(writes) { writes += value }
            saved.countDown()
        })
        val writer = ArtifactsStateWriter(stateFile, scope)
        try {
            writer.enqueue(SharedArtifactsState(filter = SharedArtifactsFilter.Docs), 1)
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            writer.enqueue(SharedArtifactsState(filter = SharedArtifactsFilter.Pages), 3)
            writer.enqueue(SharedArtifactsState(filter = SharedArtifactsFilter.Files), 2)
            assertFalse(file.exists())
            release.countDown()
            assertTrue(saved.await(5, TimeUnit.SECONDS))
            assertEquals("pages", file.readText())
            assertEquals(listOf("docs", "pages"), synchronized(writes) { writes.toList() })
        } finally { release.countDown(); scope.cancel() }
    }

    @Test(timeout = 10_000) fun aFailedWriteDoesNotStopTheProcessWriter() {
        val failures = AtomicInteger()
        val saved = CountDownLatch(1)
        val file = File(temporary.root, "state.json")
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val stateFile = ArtifactsStateFile(file, encode = { it.filter.wireValue }, replace = { from, to ->
            if (from.readText() == "docs") throw IOException("failed write")
            replaceArtifactFile(from, to)
            saved.countDown()
        })
        val writer = ArtifactsStateWriter(stateFile, scope, onFailure = { failures.incrementAndGet() })
        try {
            writer.enqueue(SharedArtifactsState(filter = SharedArtifactsFilter.Docs), 1)
            writer.enqueue(SharedArtifactsState(filter = SharedArtifactsFilter.Pages), 2)
            assertTrue(saved.await(5, TimeUnit.SECONDS))
            assertEquals(1, failures.get())
            assertEquals("pages", file.readText())
        } finally { scope.cancel() }
    }
}
