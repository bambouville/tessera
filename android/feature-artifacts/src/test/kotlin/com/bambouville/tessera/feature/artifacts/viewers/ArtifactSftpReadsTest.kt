package com.bambouville.tessera.feature.artifacts.viewers

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactSftpReadsTest {
    @Test fun reloadingWaitsForFourCancellingReadsWithoutJoiningThemBeforeTheNewRead() = runBlocking {
        val permits = Semaphore(4)
        val page = ArtifactSftpReads(permits)
        val entered = CountDownLatch(4)
        val cancelling = CountDownLatch(4)
        val release = CompletableDeferred<Unit>()
        val ioJobs = CopyOnWriteArrayList<Job>()
        val reader = ArtifactRemoteReader { _, path, _ ->
            if (path == "/site/next.html") "next".toByteArray()
            else {
                ioJobs += currentCoroutineContext()[Job]!!
                entered.countDown()
                try { awaitCancellation() } finally {
                    cancelling.countDown()
                    withContext(NonCancellable) { release.await() }
                }
            }
        }
        val old = (1..4).map { index ->
            async(start = CoroutineStart.UNDISPATCHED) { page.read { reader.read("/site", "/site/$index.js", 1024) } }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            page.resetGeneration()
            assertTrue(cancelling.await(5, TimeUnit.SECONDS))
            assertEquals(0, permits.availablePermits)
            val next = async(start = CoroutineStart.UNDISPATCHED) {
                withTimeout(5_000) { page.read { reader.read("/site", "/site/next.html", 1024) } }
            }
            assertFalse(next.isCompleted)
            release.complete(Unit)
            assertEquals("next", next.await().decodeToString())
            withTimeout(5_000) { old.joinAll(); ioJobs.joinAll() }
            assertTrue(old.all { it.isCancelled })
            assertEquals(4, permits.availablePermits)
        } finally {
            release.complete(Unit)
            page.close()
            withTimeout(5_000) { old.joinAll(); ioJobs.joinAll() }
        }
    }

    @Test fun reloadingKeepsABlockingReadsPermitUntilItsIoReturns() = runBlocking {
        val permits = Semaphore(1)
        val page = ArtifactSftpReads(permits)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val ioJob = CompletableDeferred<Job>()
        val old = async(start = CoroutineStart.UNDISPATCHED) {
            page.read {
                ioJob.complete(currentCoroutineContext()[Job]!!)
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                "old".toByteArray()
            }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            page.resetGeneration()
            assertTrue(ioJob.await().isCancelled)
            assertFalse(ioJob.await().isCompleted)
            assertEquals(0, permits.availablePermits)
            assertNull(withTimeoutOrNull(50) { page.read { error("cancelled blocking I/O still holds the permit") } })
            release.countDown()
            assertEquals("next", withTimeout(5_000) { page.read { "next".toByteArray() } }.decodeToString())
            withTimeout(5_000) { old.join(); ioJob.await().join() }
            assertEquals(1, permits.availablePermits)
        } finally {
            release.countDown()
            page.close()
            withTimeout(5_000) { old.join(); ioJob.await().join() }
        }
    }

    @Test fun reloadingADisposedPageCannotReviveItsReads() = runBlocking {
        val permits = Semaphore(1)
        val page = ArtifactSftpReads(permits)
        page.close()
        page.resetGeneration()
        assertTrue(runCatching { page.read { error("a disposed page must stay closed") } }.exceptionOrNull() is CancellationException)
        assertEquals(1, permits.availablePermits)
    }

    @Test fun aRequestCapturedBeforeReloadCannotStartInTheNewGeneration() = runBlocking {
        val permits = Semaphore(1)
        val page = ArtifactSftpReads(permits)
        try {
            val previous = checkNotNull(page.currentGeneration())
            page.resetGeneration()
            assertTrue(runCatching { previous.read { error("an old request cannot borrow the new document's scope") } }.exceptionOrNull() is CancellationException)
            assertEquals(1, permits.availablePermits)
            assertEquals("new", withTimeout(5_000) { page.read { "new".toByteArray() } }.decodeToString())
        } finally { page.close() }
    }

    @Test fun theDefaultReadLimitIsSharedAcrossPages() = runBlocking {
        val first = ArtifactSftpReads()
        val second = ArtifactSftpReads()
        val entered = CountDownLatch(4)
        val ioJobs = CopyOnWriteArrayList<Job>()
        val jobs = (1..4).map {
            async(start = CoroutineStart.UNDISPATCHED) {
                first.read { ioJobs += currentCoroutineContext()[Job]!!; entered.countDown(); awaitCancellation() }
            }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertNull(withTimeoutOrNull(50) { second.read { error("the process-wide four-read bound is exhausted") } })
        } finally {
            first.close(); second.close()
            withTimeout(5_000) { jobs.joinAll(); ioJobs.joinAll() }
        }
    }

    @Test fun closingAPageCancelsAllItsReadsAndMakesRoomForAnotherPage() = runBlocking {
        val permits = Semaphore(4)
        val page = ArtifactSftpReads(permits)
        val otherPage = ArtifactSftpReads(permits)
        val entered = CountDownLatch(4)
        val ioJobs = CopyOnWriteArrayList<Job>()
        val jobs = (1..4).map {
            async(start = CoroutineStart.UNDISPATCHED) {
                page.read { ioJobs += currentCoroutineContext()[Job]!!; entered.countDown(); awaitCancellation() }
            }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertNull(withTimeoutOrNull(50) { otherPage.read { error("all four reads are still running") } })
            page.close()
            assertEquals("next", withTimeout(5_000) { otherPage.read { "next".toByteArray() } }.decodeToString())
            withTimeout(5_000) { jobs.joinAll(); ioJobs.joinAll() }
            assertTrue(jobs.all { it.isCancelled })
            assertEquals(4, permits.availablePermits)
            assertTrue(runCatching { page.read { error("a disposed page cannot start another read") } }.exceptionOrNull() is CancellationException)
        } finally {
            page.close(); otherPage.close()
            withTimeout(5_000) { jobs.joinAll(); ioJobs.joinAll() }
        }
    }

    @Test fun closingOnePageDoesNotCancelAnotherPagesRead() = runBlocking {
        val permits = Semaphore(4)
        val first = ArtifactSftpReads(permits)
        val second = ArtifactSftpReads(permits)
        val entered = CountDownLatch(2)
        val firstIo = CompletableDeferred<Job>()
        val a = async(start = CoroutineStart.UNDISPATCHED) {
            first.read { firstIo.complete(currentCoroutineContext()[Job]!!); entered.countDown(); awaitCancellation() }
        }
        val b = async(start = CoroutineStart.UNDISPATCHED) { second.read { entered.countDown(); awaitCancellation() } }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            first.close()
            withTimeout(5_000) { a.join(); firstIo.await().join() }
            assertTrue(a.isCancelled)
            assertFalse(b.isCancelled)
            assertEquals(3, permits.availablePermits)
        } finally {
            first.close(); second.close()
            withTimeout(5_000) { a.join(); b.join() }
        }
    }

    @Test fun cancellationKeepsThePermitUntilBlockingIoActuallyFinishes() = runBlocking {
        val permits = Semaphore(1)
        val first = ArtifactSftpReads(permits)
        val second = ArtifactSftpReads(permits)
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val ioJob = CompletableDeferred<Job>()
        val pending = async(start = CoroutineStart.UNDISPATCHED) {
            first.read {
                ioJob.complete(currentCoroutineContext()[Job]!!)
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                byteArrayOf(1)
            }
        }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            first.close()
            assertTrue(ioJob.await().isCancelled)
            assertFalse(ioJob.await().isCompleted)
            assertEquals(0, permits.availablePermits)
            assertNull(withTimeoutOrNull(50) { second.read { error("the blocking read still owns its permit") } })
            release.countDown()
            assertEquals(listOf<Byte>(2), withTimeout(5_000) { second.read { byteArrayOf(2) } }.toList())
            withTimeout(5_000) { pending.join(); ioJob.await().join() }
            assertEquals(1, permits.availablePermits)
        } finally {
            release.countDown()
            first.close(); second.close()
            withTimeout(5_000) { pending.join(); ioJob.await().join() }
        }
    }

    @Test fun aFailedReadAlsoReleasesItsPermit() = runBlocking {
        val permits = Semaphore(1)
        val page = ArtifactSftpReads(permits)
        try {
            assertTrue(runCatching { page.read { throw java.io.IOException("read failed") } }.exceptionOrNull() is java.io.IOException)
            assertEquals(1, permits.availablePermits)
        } finally { page.close() }
    }

    @Test fun cancellingAQueuedRequestDoesNotRunItsReaderOrLeakAPermit() = runBlocking {
        val permits = Semaphore(1)
        permits.acquire()
        val page = ArtifactSftpReads(permits)
        val pending = async(start = CoroutineStart.UNDISPATCHED) { page.read { error("cancelled admission must not read") } }
        try {
            assertFalse(pending.isCompleted)
            pending.cancel()
            withTimeout(5_000) { pending.join() }
            assertEquals(0, permits.availablePermits)
            permits.release()
            assertEquals("next", withTimeout(5_000) { page.read { "next".toByteArray() } }.decodeToString())
            assertEquals(1, permits.availablePermits)
        } finally { page.close() }
    }

    @Test fun cancellationBetweenAcquisitionAndDispatchReturnsThePermit() = runBlocking {
        val permits = Semaphore(1)
        val cancellingPermits = object : Semaphore by permits {
            override suspend fun acquire() {
                permits.acquire()
                currentCoroutineContext().cancel()
            }
        }
        val page = ArtifactSftpReads(cancellingPermits)
        try {
            val pending = async(start = CoroutineStart.UNDISPATCHED) { page.read { error("cancelled admission must not dispatch") } }
            withTimeout(5_000) { pending.join() }
            assertTrue(pending.isCancelled)
            assertEquals(1, permits.availablePermits)
        } finally { page.close() }
    }

    @Test fun closingTheGenerationBetweenAcquisitionAndDispatchReturnsThePermit() = runBlocking {
        val permits = Semaphore(1)
        lateinit var page: ArtifactSftpReads
        val closingPermits = object : Semaphore by permits {
            override suspend fun acquire() {
                permits.acquire()
                page.close()
            }
        }
        page = ArtifactSftpReads(closingPermits)
        try {
            assertTrue(runCatching { page.read { error("a closed generation must not dispatch") } }.exceptionOrNull() is CancellationException)
            assertEquals(1, permits.availablePermits)
        } finally { page.close() }
    }
}
