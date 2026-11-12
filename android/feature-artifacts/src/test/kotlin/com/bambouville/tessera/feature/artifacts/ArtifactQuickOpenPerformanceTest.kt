package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactsState
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ArtifactQuickOpenPerformanceTest {
    @Test fun liveStoreSuppliesCapturedInputsForWorkerSearch() {
        assertTrue("LiveArtifactsUiStore must implement the prepared-search source",
            ArtifactQuickOpenSuggestionSource::class.java.isAssignableFrom(LiveArtifactsUiStore::class.java))
    }

    @Test fun repeatedRenderKeysReuseOneEvaluationAndEachChangedKeyEvaluatesOnce() = runTest {
        val main = Thread.currentThread()
        val requests = MutableStateFlow(ArtifactQuickOpenSuggestionRequest("", "h", SharedArtifactsState(), 0))
        val results = Channel<ArtifactQuickOpenSuggestionRequest>(Channel.UNLIMITED)
        val calls = AtomicInteger()
        val worker = Executors.newSingleThreadExecutor { Thread(it, "quick-open-test-worker") }.asCoroutineDispatcher()
        val job = launch {
            artifactQuickOpenResults(requests, worker) { request ->
                assertSame(main, Thread.currentThread())
                val search = {
                    assertNotSame(main, Thread.currentThread())
                    calls.incrementAndGet()
                    request
                }
                search
            }.collect { (_, result) ->
                assertSame(main, Thread.currentThread())
                results.send(result)
            }
        }
        try {
            assertEquals(requests.value, results.receive())
            repeat(46) { requests.value = requests.value.copy(); runCurrent() }
            assertEquals(1, calls.get())
            val changed = listOf(
                requests.value.copy(input = "?resume"),
                requests.value.copy(input = "?resume", revision = 1),
                requests.value.copy(input = "?resume", revision = 1, hostId = "other"),
                requests.value.copy(input = "?resume", revision = 1, hostId = "other",
                    state = SharedArtifactsState(selectedId = "selected")),
            )
            changed.forEachIndexed { index, request ->
                requests.value = request
                assertEquals(request, results.receive())
                assertEquals(index + 2, calls.get())
                repeat(46) { requests.value = request.copy(); runCurrent() }
                assertEquals(index + 2, calls.get())
            }
        } finally {
            job.cancelAndJoin()
            worker.close()
            results.close()
        }
    }

    @Test fun burstDuringNonCancellableNativeWorkComputesOnlyFirstAndLatestAndPublishesLatest() = runTest {
        val main = Thread.currentThread()
        val requests = MutableStateFlow(0)
        val entered = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        val published = Channel<Int>(Channel.UNLIMITED)
        val searches = mutableListOf<Int>()
        val captures = mutableListOf<Int>()
        val active = AtomicInteger()
        val worker = Executors.newSingleThreadExecutor { Thread(it, "quick-open-conflation-worker") }.asCoroutineDispatcher()
        val job = launch {
            artifactQuickOpenResults(requests, worker) { request ->
                assertSame(main, Thread.currentThread())
                captures += request
                val search = {
                    assertNotSame(main, Thread.currentThread())
                    assertEquals(1, active.incrementAndGet())
                    try {
                        searches += request
                        if (request == 0) {
                            entered.complete(Unit)
                            assertTrue(release.await(10, TimeUnit.SECONDS))
                        }
                        request
                    } finally {
                        active.decrementAndGet()
                    }
                }
                search
            }.collect { (_, result) -> published.send(result) }
        }
        try {
            entered.await()
            for (request in 1..100) {
                requests.value = request
                runCurrent()
            }
            assertEquals(listOf(0), captures)
            release.countDown()
            assertEquals(100, published.receive())
            assertEquals(listOf(0, 100), searches)
            assertEquals(listOf(0, 100), captures)
            assertTrue(published.tryReceive().isFailure)
            assertEquals(0, active.get())
        } finally {
            release.countDown()
            job.cancelAndJoin()
            worker.close()
            published.close()
        }
    }

    @Test fun closingQuickOpenDiscardsAnUncancellableSearchWithoutPublishingOrStartingPendingWork() = runTest {
        val requests = MutableStateFlow(0)
        val entered = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        val published = mutableListOf<Int>()
        val calls = AtomicInteger()
        val worker = Executors.newSingleThreadExecutor { Thread(it, "quick-open-cancel-worker") }.asCoroutineDispatcher()
        val job = launch {
            artifactQuickOpenResults(requests, worker) { request ->
                val search = {
                    calls.incrementAndGet()
                    entered.complete(Unit)
                    assertTrue(release.await(10, TimeUnit.SECONDS))
                    request
                }
                search
            }.collect { (_, result) -> published += result }
        }
        try {
            entered.await()
            requests.value = 1
            runCurrent()
            job.cancel()
            release.countDown()
            job.join()
            assertEquals(1, calls.get())
            assertTrue(published.isEmpty())
        } finally {
            release.countDown()
            job.cancelAndJoin()
            worker.close()
        }
    }
}
