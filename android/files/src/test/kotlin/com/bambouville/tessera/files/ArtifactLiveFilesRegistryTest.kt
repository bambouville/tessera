package com.bambouville.tessera.files

import com.bambouville.tessera.forwarding.BoundForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardingLease
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactLiveFilesRegistryTest {
    private class Lease : PortForwardingLease {
        override val bound = BoundForwardEndpoint("127.0.0.1", 45_555)
        override val activeConnectionCount = MutableStateFlow(0)
        override val isOpen = MutableStateFlow(true)
        @Volatile var closes = 0
        val closed = CountDownLatch(1)
        override fun close() { closes += 1; isOpen.value = false; closed.countDown() }
    }
    private class Files : ArtifactLiveFiles {
        @Volatile var channelOpen = true
        var channelCanOpen = true
        override val canOpenArtifactChannel get() = channelCanOpen
        var opens = 0
        var beforeOpen: () -> Unit = {}
        override suspend fun openArtifactChannel() { opens += 1; beforeOpen(); channelOpen = true }
        var connectionGeneration = 1L
        override val artifactConnectionGeneration get() = connectionGeneration
        @Volatile var duringCheck: () -> Unit = {}
        override val hasLiveArtifactChannel: Boolean get() { duringCheck(); return channelOpen }
        override val artifactHome = "/home/fixture"
        override val artifactDirectory = "/work"
        var calls = 0
        var duringCall: () -> Unit = {}
        val lease = Lease()
        private fun called() { calls += 1; duringCall() }
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat {
            called()
            output.write(1)
            return ArtifactRemoteStat(path, 1, 2, false)
        }
        override suspend fun readArtifactPageOnLiveChannel(allowedRoot: String, path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat {
            called()
            output.write(1)
            return ArtifactRemoteStat(path, 1, 2, false)
        }
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat {
            called()
            return ArtifactRemoteStat(path, 1, 2, false)
        }
        override suspend fun probeOnLiveChannel(command: String): String { called(); return "5173" }
        override suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease { called(); return lease }
    }
    private val rule = PortForwardRule(bind = PortForwardEndpoint("127.0.0.1", 0), target = PortForwardEndpoint("127.0.0.1", 5173))

    @Test fun openableLookupsArePassiveAndRequireBothTheOwnerAndSourceToAllowOpening() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files().apply { channelOpen = false }
        var channelOpenable = true
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { true }, channelOpenable = { channelOpenable })
        try {
            val retained = checkNotNull(ArtifactLiveFilesRegistry.openable(host))
            repeat(10) {
                assertSame(retained, ArtifactLiveFilesRegistry.openable(host))
                assertSame(retained, ArtifactLiveFilesRegistry.context(host))
                assertNull(ArtifactLiveFilesRegistry.files(host))
            }
            files.channelOpen = true
            assertNull(ArtifactLiveFilesRegistry.openable(host))
            assertFalse(retained.canOpenArtifactChannel)
            files.channelOpen = false
            files.channelCanOpen = false
            assertNull(ArtifactLiveFilesRegistry.openable(host))
            files.channelCanOpen = true
            channelOpenable = false
            assertNull(ArtifactLiveFilesRegistry.openable(host))
            try { retained.openArtifactChannel(); error("an unavailable owner opened Files") }
            catch (expected: FilesConnectionUnavailableException) { assertEquals("Files connection is unavailable", expected.message) }
            channelOpenable = true
            assertSame(retained, ArtifactLiveFilesRegistry.openable(host))
            registration.close()
            assertNull(ArtifactLiveFilesRegistry.openable(host))
            assertFalse(retained.canOpenArtifactChannel)
            try { retained.openArtifactChannel(); error("a retired entry opened Files") }
            catch (expected: FilesConnectionUnavailableException) { assertEquals("Files connection is unavailable", expected.message) }
            assertEquals(0, files.opens)
            assertEquals(0, files.calls)
        } finally { registration.close() }
    }

    @Test fun registrationsDefaultToNotOpeningAChannel() {
        val host = UUID.randomUUID().toString()
        val files = Files().apply { channelOpen = false }
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { true })
        try {
            assertNull(ArtifactLiveFilesRegistry.openable(host))
            assertFalse(checkNotNull(ArtifactLiveFilesRegistry.context(host)).canOpenArtifactChannel)
            assertEquals(0, files.opens)
        } finally { registration.close() }
    }

    @Test fun onlyAnExplicitOpenDelegatesAndPublishesTheLiveChannel() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files().apply { channelOpen = false }
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { true }, channelOpenable = { true })
        try {
            val retained = checkNotNull(ArtifactLiveFilesRegistry.openable(host))
            val revision = ArtifactLiveFilesRegistry.revision.value
            retained.openArtifactChannel()
            assertEquals(1, files.opens)
            assertTrue(ArtifactLiveFilesRegistry.revision.value > revision)
            assertNull(ArtifactLiveFilesRegistry.openable(host))
            assertSame(retained, ArtifactLiveFilesRegistry.files(host))
            try { retained.openArtifactChannel(); error("a live entry reopened Files") }
            catch (_: IOException) { }
            assertEquals(1, files.opens)
            assertEquals(0, files.calls)
        } finally { registration.close() }
    }

    @Test fun openableReturnsTheLastEligibleEntryForOnlyTheRequestedHost() {
        val host = UUID.randomUUID().toString()
        val first = ArtifactLiveFilesRegistry.register(host, "first", Files().apply { channelOpen = false }, sessionLive = { true }, channelOpenable = { true })
        try {
            val original = checkNotNull(ArtifactLiveFilesRegistry.openable(host))
            val last = ArtifactLiveFilesRegistry.register(host, "last", Files().apply { channelOpen = false }, sessionLive = { true }, channelOpenable = { true })
            try {
                val latest = checkNotNull(ArtifactLiveFilesRegistry.openable(host))
                assertTrue(original !== latest)
                assertNull(ArtifactLiveFilesRegistry.openable(UUID.randomUUID().toString()))
                last.close()
                assertSame(original, ArtifactLiveFilesRegistry.openable(host))
            } finally { last.close() }
        } finally { first.close() }
    }

    @Test fun anOpeningFailurePropagatesAndCanBeRetriedExplicitly() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files().apply { channelOpen = false; beforeOpen = { throw IOException("channel refused") } }
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { true }, channelOpenable = { true })
        try {
            val retained = checkNotNull(ArtifactLiveFilesRegistry.openable(host))
            val revision = ArtifactLiveFilesRegistry.revision.value
            try { retained.openArtifactChannel(); error("opening failure was swallowed") }
            catch (expected: IOException) { assertEquals("channel refused", expected.message) }
            assertEquals(revision, ArtifactLiveFilesRegistry.revision.value)
            assertSame(retained, ArtifactLiveFilesRegistry.openable(host))
            assertEquals(1, files.opens)
            files.beforeOpen = {}
            retained.openArtifactChannel()
            assertSame(retained, ArtifactLiveFilesRegistry.files(host))
            assertEquals(2, files.opens)
        } finally { registration.close() }
    }

    @Test fun theSameEntryForwardsItsSourcesGenerationWithoutCheckingOrUsingTheChannel() {
        val host = UUID.randomUUID().toString()
        val files = Files()
        var ownerChecks = 0
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { ownerChecks++; true })
        try {
            val entry = checkNotNull(ArtifactLiveFilesRegistry.files(host))
            val checksBeforeReads = ownerChecks
            files.duringCheck = { error("generation reads must not check the channel") }
            repeat(1_000) { assertEquals(1L, entry.artifactConnectionGeneration) }
            files.connectionGeneration = 2L
            repeat(1_000) { assertEquals(2L, entry.artifactConnectionGeneration) }
            assertEquals(checksBeforeReads, ownerChecks)
            assertEquals(0, files.calls)
            files.duringCheck = {}
            assertSame(entry, ArtifactLiveFilesRegistry.files(host))
        } finally { registration.close() }
    }

    @Test fun anOpenFilesChannelNeedsALiveSessionOwner() {
        val host = UUID.randomUUID().toString()
        val files = Files()
        var sessionLive = false
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { sessionLive })
        try {
            assertNull(ArtifactLiveFilesRegistry.files(host))
            assertFalse(checkNotNull(ArtifactLiveFilesRegistry.context(host)).hasLiveArtifactChannel)
            sessionLive = true
            assertNotNull(ArtifactLiveFilesRegistry.files(host))
            sessionLive = false
            assertNull(ArtifactLiveFilesRegistry.files(host))
            assertTrue(files.channelOpen)
            assertEquals(0, files.calls)
        } finally { registration.close() }
    }

    @Test fun retainedSourcesCannotReadFollowProbeOrForwardAfterTheirOwnerFails() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files()
        var sessionLive = true
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { sessionLive })
        try {
            val retained = checkNotNull(ArtifactLiveFilesRegistry.files(host))
            assertSame(retained, ArtifactLiveFilesRegistry.files(host))
            sessionLive = false
            val output = ByteArrayOutputStream()
            assertNull(retained.readArtifactOnLiveChannel("/work/a.md", output, 100))
            assertNull(retained.readArtifactPageOnLiveChannel("/work", "/work/a.css", output, 100))
            assertNull(retained.statArtifactOnLiveChannel("/work/a.md"))
            assertNull(retained.probeOnLiveChannel("probe"))
            assertNull(retained.acquireForwardingLeaseOnLiveChannel(rule))
            assertEquals(0, output.size())
            assertEquals(0, files.calls)
            assertEquals("/home/fixture", retained.artifactHome)
            assertEquals("/work", retained.artifactDirectory)
            assertTrue(files.channelOpen)
        } finally { registration.close() }
    }

    @Test fun ownerLossDuringAnOperationCannotPublishItsResult() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files()
        var sessionLive = true
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { sessionLive })
        try {
            val retained = checkNotNull(ArtifactLiveFilesRegistry.files(host))
            files.duringCall = { sessionLive = false }
            val operations: List<suspend () -> Any?> = listOf(
                { retained.readArtifactOnLiveChannel("/work/a.md", ByteArrayOutputStream(), 100) },
                { retained.readArtifactPageOnLiveChannel("/work", "/work/a.css", ByteArrayOutputStream(), 100) },
                { retained.statArtifactOnLiveChannel("/work/a.md") },
                { retained.probeOnLiveChannel("probe") },
                { retained.acquireForwardingLeaseOnLiveChannel(rule) },
            )
            operations.forEach { operation -> sessionLive = true; assertNull(operation()) }
            assertEquals(operations.size, files.calls)
            assertEquals(1, files.lease.closes)
            assertTrue(files.channelOpen)
        } finally { registration.close() }
    }

    @Test fun anExistingPageLeaseCannotStayOpenAfterItsOwnerFails() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files()
        var sessionLive = true
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { sessionLive })
        try {
            val source = checkNotNull(ArtifactLiveFilesRegistry.files(host))
            val lease = checkNotNull(source.acquireForwardingLeaseOnLiveChannel(rule))
            assertTrue(lease.isOpen.value)
            sessionLive = false
            assertFalse(lease.isOpen.value)
            assertEquals(listOf(false), lease.isOpen.replayCache)
            lease.close()
            assertEquals(1, files.lease.closes)
            assertTrue(files.channelOpen)
        } finally { registration.close() }
    }

    @Test fun retiringARegistrationInvalidatesRetainedSourcesAndLeases() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files()
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { true })
        try {
            val retained = checkNotNull(ArtifactLiveFilesRegistry.files(host))
            val lease = checkNotNull(retained.acquireForwardingLeaseOnLiveChannel(rule))
            registration.close()
            assertFalse(retained.hasLiveArtifactChannel)
            assertFalse(lease.isOpen.value)
            assertNull(retained.statArtifactOnLiveChannel("/work/a.md"))
            assertNull(retained.acquireForwardingLeaseOnLiveChannel(rule))
            assertNull(ArtifactLiveFilesRegistry.files(host))
            assertNull(ArtifactLiveFilesRegistry.context(host))
            assertEquals(1, files.calls)
            assertEquals(1, files.lease.closes)
            assertTrue(files.channelOpen)
        } finally { registration.close() }
    }

    @Test(timeout = 5_000) fun carrierDeathRetiresTheListenerWithoutAnyBrowserOrStoreRead() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files()
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val lease = checkNotNull(checkNotNull(ArtifactLiveFilesRegistry.files(host)).acquireForwardingLeaseOnLiveChannel(rule))
        try {
            files.channelOpen = false
            assertTrue("carrier death left the listener open", files.lease.closed.await(WATCH_DEADLINE_MS, TimeUnit.MILLISECONDS))
            assertEquals(1, files.lease.closes)
            assertEquals(1, files.calls)
        } finally { lease.close(); registration.close() }
    }

    @Test(timeout = 5_000) fun ownerLossRetiresTheListenerAndPublishesClosureWithoutPolling() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files()
        val sessionLive = AtomicBoolean(true)
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { sessionLive.get() })
        val lease = checkNotNull(checkNotNull(ArtifactLiveFilesRegistry.files(host)).acquireForwardingLeaseOnLiveChannel(rule))
        try {
            val closed = async(start = CoroutineStart.UNDISPATCHED) { withTimeout(WATCH_DEADLINE_MS) { lease.isOpen.first { !it } } }
            sessionLive.set(false)
            assertTrue("owner loss left the listener open", files.lease.closed.await(WATCH_DEADLINE_MS, TimeUnit.MILLISECONDS))
            assertFalse(closed.await())
            assertEquals(1, files.lease.closes)
            assertEquals(1, files.calls)
            assertTrue(files.channelOpen)
        } finally { lease.close(); registration.close() }
    }

    @Test(timeout = 5_000) fun closingTheRegistrationRetiresTheListenerWithoutAnyBrowserOrStoreRead() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files()
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val lease = checkNotNull(checkNotNull(ArtifactLiveFilesRegistry.files(host)).acquireForwardingLeaseOnLiveChannel(rule))
        try {
            registration.close()
            assertTrue("the retired registration kept its listener", files.lease.closed.await(WATCH_DEADLINE_MS, TimeUnit.MILLISECONDS))
            assertEquals(1, files.lease.closes)
            assertEquals(1, files.calls)
            assertTrue(files.channelOpen)
        } finally { lease.close(); registration.close() }
    }

    @Test(timeout = 5_000) fun closingTheLeaseStopsItsDaemonOwnerWatcherWithoutClosingFiles() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files()
        val registration = ArtifactLiveFilesRegistry.register(host, "mosh-session", files, sessionLive = { true })
        val lease = checkNotNull(checkNotNull(ArtifactLiveFilesRegistry.files(host)).acquireForwardingLeaseOnLiveChannel(rule))
        try {
            val watched = CountDownLatch(1)
            val watcherThread = AtomicReference<Thread>()
            files.duringCheck = { watcherThread.set(Thread.currentThread()); watched.countDown() }
            assertTrue("no independent owner watch ran", watched.await(WATCH_DEADLINE_MS, TimeUnit.MILLISECONDS))
            assertTrue("a watcher must not keep the process alive", watcherThread.get().isDaemon)
            lease.close()
            val readAfterClose = CountDownLatch(1)
            files.duringCheck = { readAfterClose.countDown() }
            assertFalse("the closed lease still watches its owner", readAfterClose.await(WATCH_STOP_MS, TimeUnit.MILLISECONDS))
            assertEquals(1, files.lease.closes)
            assertEquals(1, files.calls)
            assertTrue(files.channelOpen)
        } finally { lease.close(); registration.close() }
    }

    @Test fun aFailedSiblingCannotMaskAnotherLiveOwnerOrRetireItsRegistration() {
        val host = UUID.randomUUID().toString()
        val first = ArtifactLiveFilesRegistry.register(host, "first", Files(), sessionLive = { true })
        try {
            val live = checkNotNull(ArtifactLiveFilesRegistry.files(host))
            val failed = ArtifactLiveFilesRegistry.register(host, "failed", Files(), sessionLive = { false })
            try { assertSame(live, ArtifactLiveFilesRegistry.files(host)) } finally { failed.close() }
            assertSame(live, ArtifactLiveFilesRegistry.files(host))
        } finally { first.close() }
    }

    @Test fun aLiveOwnerWithNoOpenFilesChannelNeverStartsArtifactWork() = runBlocking {
        val host = UUID.randomUUID().toString()
        val files = Files().apply { channelOpen = false }
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = { true })
        try {
            assertNull(ArtifactLiveFilesRegistry.files(host))
            val context = checkNotNull(ArtifactLiveFilesRegistry.context(host))
            assertNull(context.readArtifactOnLiveChannel("/work/a.md", ByteArrayOutputStream(), 100))
            assertNull(context.statArtifactOnLiveChannel("/work/a.md"))
            assertNull(context.probeOnLiveChannel("probe"))
            assertNull(context.acquireForwardingLeaseOnLiveChannel(rule))
            assertEquals(0, files.calls)
        } finally { registration.close() }
    }

    private companion object {
        const val WATCH_DEADLINE_MS = 1_750L
        const val WATCH_STOP_MS = 1_250L
    }
}
