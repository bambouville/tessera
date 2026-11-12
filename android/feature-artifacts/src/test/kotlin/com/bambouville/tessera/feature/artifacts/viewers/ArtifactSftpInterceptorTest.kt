package com.bambouville.tessera.feature.artifacts.viewers

import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactSftpInterceptorTest {
    private val paths = ArtifactSftpPaths("tab-1", "/srv/build/report/index.html")
    private val origin = "https://tab-1.artifact.tessera.invalid"

    @Test fun aReplacementTimesOutWith504WhileFourCancelledBlockingReadsHoldEveryPermit() = runBlocking {
        val permits = Semaphore(4)
        val page = ArtifactSftpReads(permits)
        val entered = CountDownLatch(4)
        val release = CountDownLatch(1)
        val ioJobs = CopyOnWriteArrayList<Job>()
        val old = (1..4).map {
            async(start = CoroutineStart.UNDISPATCHED) {
                page.read {
                    ioJobs += currentCoroutineContext()[Job]!!
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                    byteArrayOf(1)
                }
            }
        }
        val calls = AtomicInteger()
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val next = page.resetGeneration()
            val result = artifactSftpRead(next, 50) { calls.incrementAndGet(); "next".toByteArray() }
            assertEquals(ArtifactSftpReadResult.Failure(504, "Gateway Timeout"), result)
            assertEquals(0, calls.get())
            assertEquals(0, permits.availablePermits)
            assertTrue(ioJobs.all { it.isCancelled && !it.isCompleted })
            release.countDown()
            val replacement = artifactSftpRead(next, 5_000) { calls.incrementAndGet(); "next".toByteArray() }
            assertEquals("next", (replacement as ArtifactSftpReadResult.Content).bytes.decodeToString())
            assertEquals(1, calls.get())
            withTimeout(5_000) { old.joinAll(); ioJobs.joinAll() }
            assertEquals(4, permits.availablePermits)
            repeat(4) { assertTrue(permits.tryAcquire()) }
            assertFalse(permits.tryAcquire())
            repeat(4) { permits.release() }
        } finally {
            release.countDown()
            page.close()
            withTimeout(5_000) { old.joinAll(); ioJobs.joinAll() }
        }
    }

    @Test fun aDeadlineReturns504WithoutWaitingForBlockingIoOrReleasingItsPermitEarly() = runBlocking {
        val permits = Semaphore(1)
        val page = ArtifactSftpReads(permits)
        val release = CountDownLatch(1)
        val ioJob = CompletableDeferred<Job>()
        try {
            val result = artifactSftpRead(page.currentGeneration(), 200) {
                ioJob.complete(currentCoroutineContext()[Job]!!)
                check(release.await(5, TimeUnit.SECONDS))
                byteArrayOf(1)
            }
            assertEquals(ArtifactSftpReadResult.Failure(504, "Gateway Timeout"), result)
            val job = withTimeout(5_000) { ioJob.await() }
            assertTrue(job.isCancelled)
            assertFalse(job.isCompleted)
            assertEquals(0, permits.availablePermits)
            release.countDown()
            val next = artifactSftpRead(page.currentGeneration(), 5_000) { "next".toByteArray() }
            assertEquals("next", (next as ArtifactSftpReadResult.Content).bytes.decodeToString())
            withTimeout(5_000) { job.join() }
            assertEquals(1, permits.availablePermits)
        } finally {
            release.countDown()
            page.close()
        }
    }

    @Test fun closingAQueuedGenerationReturns503WithoutWaitingForAPermitOrCallingTheReader() = runBlocking {
        val permits = Semaphore(1)
        permits.acquire()
        val entered = CompletableDeferred<Unit>()
        val observedPermits = object : Semaphore by permits {
            override suspend fun acquire() {
                entered.complete(Unit)
                permits.acquire()
            }
        }
        val page = ArtifactSftpReads(observedPermits)
        val calls = AtomicInteger()
        val pending = async(Dispatchers.Default) {
            artifactSftpRead(page.currentGeneration(), 1_000) { calls.incrementAndGet(); byteArrayOf(1) }
        }
        try {
            withTimeout(5_000) { entered.await() }
            page.close()
            assertEquals(ArtifactSftpReadResult.Failure(503, "Service Unavailable"), withTimeout(5_000) { pending.await() })
            assertEquals(0, calls.get())
            assertEquals(0, permits.availablePermits)
        } finally {
            page.close()
            permits.release()
            withTimeout(5_000) { pending.join() }
        }
        assertEquals(1, permits.availablePermits)
    }

    @Test fun closedAndReplacedGenerationsReturn503WithoutInvokingTheReader() {
        val permits = Semaphore(1)
        val page = ArtifactSftpReads(permits)
        val old = page.currentGeneration()
        page.resetGeneration()
        try {
            assertEquals(ArtifactSftpReadResult.Failure(503, "Service Unavailable"), artifactSftpRead(old, 50) { error("old requests cannot read") })
            page.close()
            assertEquals(ArtifactSftpReadResult.Failure(503, "Service Unavailable"), artifactSftpRead(page.currentGeneration(), 50) { error("a disposed page cannot reconnect") })
            assertEquals(1, permits.availablePermits)
        } finally { page.close() }
    }

    @Test fun aReadFailureIsReturnedWithoutRetryingTheHeldReader() {
        val permits = Semaphore(1)
        val page = ArtifactSftpReads(permits)
        val calls = AtomicInteger()
        try {
            val result = artifactSftpRead(page.currentGeneration(), 5_000) {
                calls.incrementAndGet()
                throw java.io.IOException("the held connection went offline")
            }
            assertEquals(ArtifactSftpReadResult.Failure(502, "Bad Gateway"), result)
            assertEquals(1, calls.get())
            assertEquals(1, permits.availablePermits)
        } finally { page.close() }
    }

    @Test fun pageAndSiblingAssetsStayInsideThePageDirectory() {
        assertEquals("/srv/build/report", paths.root)
        assertEquals("$origin/index.html", paths.pageUrl)
        assertEquals(ArtifactSftpResolution.File("/srv/build/report/index.html"), paths.resolve(paths.pageUrl))
        assertEquals(ArtifactSftpResolution.File("/srv/build/report/assets/main.css"), paths.resolve("$origin/assets/main.css?v=2#style"))
        assertEquals(ArtifactSftpResolution.File("/srv/build/report/main.js"), paths.resolve("$origin/assets/.././main.js"))
    }

    @Test fun namesArePercentEncodedAndDecodedExactlyOnce() {
        val spaced = ArtifactSftpPaths("tab-1", "/srv/build/report/my report #1.html")
        assertEquals("$origin/my%20report%20%231.html", spaced.pageUrl)
        assertEquals(ArtifactSftpResolution.File("/srv/build/report/my report #1.html"), spaced.resolve(spaced.pageUrl))
        assertEquals(ArtifactSftpResolution.File("/srv/build/report/a+b.js"), paths.resolve("$origin/a+b.js"))
        assertEquals(ArtifactSftpResolution.File("/srv/build/report/%2e%2e/file"), paths.resolve("$origin/%252e%252e/file"))
    }

    @Test fun traversalAboveTheRootIsForbiddenEvenWhenEncoded() {
        for (suffix in listOf(
            "/../secret",
            "/assets/../../secret",
            "/%2e%2e/secret",
            "/.%2E/secret",
            "/assets%2F..%2F..%2Fsecret",
            "/%2e%2e%2fsecret",
        )) assertEquals(suffix, ArtifactSftpResolution.Forbidden, paths.resolve(origin + suffix))
    }

    @Test fun otherTabsAndUnsafeCharactersCannotReadFromThisTab() {
        for (suffix in listOf(
            "/a%5Cb", "/%00file", "/%0Afile", "/%FFfile",
        )) assertEquals(suffix, ArtifactSftpResolution.Forbidden, paths.resolve(origin + suffix))
        assertEquals(ArtifactSftpResolution.Forbidden, paths.resolve("https://user@tab-1.artifact.tessera.invalid/index.html"))
    }

    @Test fun rootRelativeAssetsResolveWithinThisTabsOrigin() {
        assertEquals(ArtifactSftpResolution.File("/srv/build/report/assets/x.css"), paths.resolve("$origin/assets/x.css"))
        assertEquals(ArtifactSftpResolution.Forbidden, paths.resolve("https://tab-2.artifact.tessera.invalid/assets/x.css"))
    }

    @Test fun directoryRequestsAreMissingRatherThanUnboundedListings() {
        assertEquals(ArtifactSftpResolution.Missing, paths.resolve("$origin/"))
        assertEquals(ArtifactSftpResolution.Missing, paths.resolve("$origin/assets/"))
        assertEquals(ArtifactSftpResolution.Missing, paths.resolve("$origin/assets/.."))
    }

    @Test fun publicNetworkResourcesPassThrough() {
        for (url in listOf(
            "https://cdn.example.org/main.js", "https://example.org/", "http://192.0.2.1/",
            "https://tab-1.artifact.tessera.invalid.example.org/index.html",
        )) assertEquals(url, ArtifactSftpResolution.Network, paths.resolve(url))
    }

    @Test fun servedPagesCannotReachDeviceLoopbackOrUnspecifiedAddresses() {
        for (host in listOf(
            "127.0.0.1", "127.42.9.8", "127.1", "2130706433", "0x7f000001", "0177.0.0.1",
            "localhost", "LOCALHOST.", "app.localhost", "0.0.0.0", "0", "[::1]", "[::]",
            "[0:0:0:0:0:0:0:1]", "[0000:0000:0000:0000:0000:0000:0000:0000]", "[::ffff:127.0.0.1]",
            "[::ffff:7f00:1]", "[::ffff:0:0]", "[::127.0.0.1]", "[::7f00:1]", "[0:0:0:0:0:0:7f2a:908]",
            "127%2e0%2e0%2e1", "%6cocalhost",
        )) for (scheme in listOf("http", "https")) for (userinfo in listOf("", "user:password@")) {
            val url = "$scheme://$userinfo$host:8080/private"
            assertEquals(url, ArtifactSftpResolution.Forbidden, paths.resolve(url))
        }
    }

    @Test fun loopbackPolicyDoesNotMistakePublicLookalikesForDeviceAddresses() {
        for (host in listOf("localhost.example.org", "127.example.org", "128.0.0.1", "[2001:db8::1]", "[::ffff:c000:201]", "[::c000:201]")) {
            assertEquals(host, ArtifactSftpResolution.Network, paths.resolve("https://$host/"))
        }
    }

    @Test fun originComparisonIsCaseInsensitiveAndUnderstandsTheDefaultPort() {
        assertEquals(ArtifactSftpResolution.File("/srv/build/report/app.js"), paths.resolve("HTTPS://TAB-1.ARTIFACT.TESSERA.INVALID:443/app.js"))
        assertEquals(ArtifactSftpResolution.File("/root.html"), ArtifactSftpPaths("root", "/root.html").resolve("https://root.artifact.tessera.invalid/root.html"))
        assertEquals("/", ArtifactSftpPaths("root", "/root.html").root)
    }

    @Test fun onlyTheSamePageOriginStaysInTheEmbeddedBrowser() {
        assertEquals(true, artifactSameOrigin("https://example.org/start", "HTTPS://EXAMPLE.ORG:443/next"))
        assertEquals(true, artifactSameOrigin("http://127.0.0.1:5173/", "http://127.0.0.1:5173/next?x=1"))
        assertEquals(false, artifactSameOrigin("http://127.0.0.1:5173/", "http://127.0.0.1:8080/"))
        assertEquals(false, artifactSameOrigin("https://example.org/", "http://example.org/"))
        assertEquals(false, artifactSameOrigin("https://example.org/", "https://example.org.evil.invalid/"))
        assertEquals(false, artifactSameOrigin("https://example.org/", "mailto:person@example.org"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun relativePagePathsAreRejected() { ArtifactSftpPaths("tab", "report/index.html") }

    @Test(expected = IllegalArgumentException::class)
    fun tabIdentifiersCannotInjectPathComponents() { ArtifactSftpPaths("../tab", "/report/index.html") }
}
