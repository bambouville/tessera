package com.bambouville.tessera.networking.mosh

import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteRequest
import com.bambouville.tessera.networking.SshAuthentication
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.CoroutineContext

class AndroidMoshTransportTest {
    @Test
    fun `outage uses contact age at the strict server late boundary`() {
        assertNull(MoshOutageTiming.next(null, true, true, 6_500, 10_000, 100_000))
        assertNull(MoshOutageTiming.next(null, true, false, 6_500, 10_000, 100_000))
        val outage = MoshOutageTiming.next(null, true, false, 6_501, 0, 100_000)
        assertEquals(MoshOutageTiming(100_000, MoshOutageTiming.Kind.CONTACT, 6), outage)
        assertEquals(6L, MoshOutageTiming.next(outage, true, false, 6_999, 0, 101_000)?.seconds)
        assertEquals(7L, MoshOutageTiming.next(outage, true, false, 7_000, 0, 101_000)?.seconds)
    }

    @Test
    fun `outage uses reply age and prefers late server contact`() {
        val reply = MoshOutageTiming.next(null, true, false, 6_500, 10_001, 100_000)
        assertEquals(MoshOutageTiming(100_000, MoshOutageTiming.Kind.REPLY, 10), reply)
        assertEquals(10L, MoshOutageTiming.next(reply, true, false, 0, 10_999, 101_000)?.seconds)
        assertEquals(11L, MoshOutageTiming.next(reply, true, false, 0, 11_000, 101_000)?.seconds)
        assertEquals(
            MoshOutageTiming(100_000, MoshOutageTiming.Kind.CONTACT, 8),
            MoshOutageTiming.next(null, true, false, 8_999, 20_000, 100_000),
        )
    }

    @Test
    fun `outage preserves identity and monotonic age until the kind changes`() {
        val outage = MoshOutageTiming(100_000, MoshOutageTiming.Kind.REPLY, 12)
        assertEquals(outage, MoshOutageTiming.next(outage, true, false, 0, 11_000, 50_000))
        assertEquals(
            MoshOutageTiming(100_000, MoshOutageTiming.Kind.CONTACT, 7),
            MoshOutageTiming.next(outage, true, false, 7_000, 13_000, 101_000),
        )
        assertEquals(
            MoshOutageTiming(100_000, MoshOutageTiming.Kind.REPLY, 15),
            MoshOutageTiming.next(outage, true, false, 0, 15_999, 50_000),
        )
    }

    @Test
    fun `outage switches from contact to reply without another announcement identity`() {
        val outage = MoshOutageTiming(100_000, MoshOutageTiming.Kind.CONTACT, 20)
        assertEquals(
            MoshOutageTiming(100_000, MoshOutageTiming.Kind.REPLY, 11),
            MoshOutageTiming.next(outage, true, false, 0, 11_000, 120_000),
        )
    }

    @Test
    fun `outage clears on recovery or disconnect and restarts its identity`() {
        val outage = MoshOutageTiming(100_000, MoshOutageTiming.Kind.CONTACT, 12)
        assertNull(MoshOutageTiming.next(outage, true, true, 15_000, 20_000, 116_000))
        assertNull(MoshOutageTiming.next(outage, false, false, 15_000, 20_000, 116_000))
        assertEquals(120_000L, MoshOutageTiming.next(null, true, false, 7_000, 0, 120_000)?.startedAtMillis)
        assertEquals(
            Long.MAX_VALUE / 1_000,
            MoshOutageTiming.next(null, true, false, Long.MAX_VALUE, 0, 120_000)?.seconds,
        )
    }

    @Test fun absentOrRetiredDriverRefusesInputBeforeInjection() = runBlocking {
        val client = FakeClient()
        val transport = fakeTransport(client)
        try {
            for (phase in listOf("absent", "retired")) {
                if (phase == "retired") {
                    transport.connect(MoshConnectRequest(request(), columns = 120, rows = 40))
                    transport.close()
                }
                val failure = runCatching { transport.send("hello".encodeToByteArray()) }.exceptionOrNull()
                assertTrue(failure is MoshInputNotAdmittedException)
                assertTrue(client.injected.isEmpty())
            }
        } finally { transport.close() }
    }

    @Test(expected = IllegalArgumentException::class)
    fun forcedRepaintRejectsZeroRequestIdentifier() {
        runBlocking {
            val transport = AndroidMoshTransport(
                bootstrapper = MoshBootstrapper { error("unused") },
            )
            transport.forceFullRepaint(repaintRequestId = 0)
        }
    }

    @Test
    fun startsNativeClientAndWipesBootstrapKeyAfterCrossingBoundary() = runBlocking {
        val bootstrapKey = "AAECAwQFBgcICQoLDA0ODw".encodeToByteArray()
        val client = FakeClient()
        var receivedKey: ByteArray? = null
        var cleanupPid: Int? = null
        val transport = AndroidMoshTransport(
            bootstrapper = MoshBootstrapper {
                MoshBootstrapResult("198.51.100.8", 60001, bootstrapKey, 34)
            },
            nativeFactory = MoshNativeClientFactory { host, port, key, output ->
                assertEquals("198.51.100.8", host)
                assertEquals(60001, port)
                receivedKey = key.copyOf()
                client.output = output
                client
            },
            onBootstrapServerStarted = { cleanupPid = it },
        )

        transport.connect(MoshConnectRequest(request(), columns = 120, rows = 40))

        assertArrayEquals("AAECAwQFBgcICQoLDA0ODw".encodeToByteArray(), receivedKey)
        assertArrayEquals(ByteArray(bootstrapKey.size), bootstrapKey)
        assertEquals(1, client.starts)
        assertEquals(120 to 40, client.lastResize)
        assertEquals(34, transport.bootstrapServerPid)
        assertEquals(34, cleanupPid)
        transport.close()
        assertFalse(client.open)
        assertNull(transport.bootstrapServerPid)
    }

    @Test
    fun normalizesCsiArrowKeysToMoshSs3Form() {
        assertArrayEquals(
            byteArrayOf(0x1b, 0x4f, 0x41, 0x1b, 0x4f, 0x44),
            MoshInputNormalizer.normalizeArrowKeys(byteArrayOf(0x1b, 0x5b, 0x41, 0x1b, 0x5b, 0x44)),
        )
        assertArrayEquals(
            byteArrayOf(0x1b, 0x5b, 0x31, 0x7e),
            MoshInputNormalizer.normalizeArrowKeys(byteArrayOf(0x1b, 0x5b, 0x31, 0x7e)),
        )
    }

    @Test
    fun inputIsChunkedAtTheCAbiLimitAndTicksImmediately() = runBlocking {
        val client = FakeClient()
        val transport = AndroidMoshTransport(
            bootstrapper = MoshBootstrapper {
                MoshBootstrapResult("198.51.100.8", 60001, "AAECAwQFBgcICQoLDA0ODw".encodeToByteArray(), 34)
            },
            nativeFactory = MoshNativeClientFactory { _, _, _, output ->
                client.output = output
                client
            },
        )
        transport.connect(MoshConnectRequest(request(), columns = 120, rows = 40))

        val bytes = ByteArray(130_000) { 0x78 }
        val ticksBeforeInput = client.ticks.get()
        transport.send(bytes)

        val injected = synchronized(client.injected) { client.injected.toList() }
        assertTrue(client.ticks.get() > ticksBeforeInput)
        assertTrue(injected.all { it.size <= 65_536 })
        val rebuilt = ByteArrayOutputStream().use { output ->
            injected.forEach { output.write(it) }
            output.toByteArray()
        }
        assertArrayEquals(bytes, rebuilt)
        transport.close()
    }

    @Test
    fun forcedRepaintKeepsNaturalPumpOutputOutsideItsSequencedConsumptionTarget() = runBlocking<Unit> {
        val client = FakeClient()
        // Hold the pump at its dispatch boundary so this test controls the
        // next real tick independently of the forced framebuffer operation.
        val pumpDispatches = ArrayDeque<Runnable>()
        val pumpDispatcher = object : CoroutineDispatcher() {
            override fun dispatch(context: CoroutineContext, block: Runnable) {
                synchronized(pumpDispatches) { pumpDispatches.addLast(block) }
            }
        }
        val transport = AndroidMoshTransport(
            bootstrapper = MoshBootstrapper {
                MoshBootstrapResult(
                    "198.51.100.8",
                    60001,
                    "AAECAwQFBgcICQoLDA0ODw".encodeToByteArray(),
                    34,
                )
            },
            nativeFactory = MoshNativeClientFactory { _, _, _, output ->
                client.output = output
                client
            },
            scope = CoroutineScope(SupervisorJob() + pumpDispatcher),
        )
        transport.connect(MoshConnectRequest(request(), columns = 120, rows = 40))
        val received = async(start = CoroutineStart.UNDISPATCHED) {
            withTimeout(2_000) { transport.output.take(3).toList() }
        }

        client.output?.invoke("ordinary".encodeToByteArray())
        client.repaintOutput = "forced"
        client.tickAfterRepaintOutput = "tick"
        val target = transport.forceFullRepaint(repaintRequestId = 41)
        assertEquals("a cached framebuffer replay must not poll SSP", 0, client.ticks.get())
        assertEquals(2L, target)
        assertEquals(2L, transport.outputSequenceHighWater)
        // Run the normal pump's first tick: its update is a distinct natural
        // chunk, so history can observe it without crediting a cached replay.
        synchronized(pumpDispatches) { pumpDispatches.removeFirst() }.run()

        val chunks = received.await()
        assertEquals(listOf(1L, 2L, 3L), chunks.map { it.sequence })
        assertEquals(listOf(null, 41L, null), chunks.map { it.repaintRequestId })
        assertEquals(listOf("ordinary", "forced", "tick"), chunks.map { it.bytes.decodeToString() })
        assertEquals(3L, transport.outputSequenceHighWater)
        assertNull(transport.forceFullRepaint(repaintRequestId = 42))
        transport.close()
        // Finish the cancelled pump's queued continuation as well.
        synchronized(pumpDispatches) { pumpDispatches.removeFirstOrNull() }?.run()
    }

    @Test
    fun freshRepaintWaitsForAcknowledgementWithoutCollectingNaturalPumpOutput() = runBlocking<Unit> {
        val client = FakeClient().apply { repaintOutput = "fresh full frame" }
        val pumpDispatches = ArrayDeque<Runnable>()
        val pumpDispatcher = object : CoroutineDispatcher() {
            override fun dispatch(context: CoroutineContext, block: Runnable) {
                synchronized(pumpDispatches) { pumpDispatches.addLast(block) }
            }
        }
        val transport = fakeTransport(client, CoroutineScope(SupervisorJob() + pumpDispatcher))
        try {
            transport.connect(MoshConnectRequest(request(), columns = 56, rows = 45))
            val received = async(start = CoroutineStart.UNDISPATCHED) {
                withTimeout(2_000) { transport.output.take(2).toList() }
            }
            val repaint = async {
                transport.forceFullRepaint(repaintRequestId = 41, requiringFreshRemoteState = true)
            }
            withTimeout(2_000) {
                while (client.fenceChecks.get() == 0) delay(5)
            }
            assertFalse(repaint.isCompleted)
            assertEquals(0, client.forcedRepaints.get())
            assertEquals(1, client.ticks.get())
            assertTrue("beginning the fence must transmit its queued resize", client.fenceSent)

            client.tickAfterRepaintOutput = "natural SSP"
            synchronized(pumpDispatches) { pumpDispatches.removeFirst() }.run()
            assertEquals(2, client.ticks.get())
            assertEquals(1L, transport.outputSequenceHighWater)
            delay(50)
            assertFalse("a tick without the server acknowledgement is insufficient", repaint.isCompleted)
            assertEquals(0, client.forcedRepaints.get())
            client.fenceReady = true

            assertEquals(2L, repaint.await())
            val chunks = received.await()
            assertEquals(listOf("natural SSP", "fresh full frame"), chunks.map { it.bytes.decodeToString() })
            assertEquals(listOf(null, 41L), chunks.map { it.repaintRequestId })
            assertEquals(1, client.fenceBegins.get())
            assertEquals(1, client.forcedRepaints.get())
            assertEquals("the forced collector must not tick", 2, client.ticks.get())
        } finally {
            transport.close()
            synchronized(pumpDispatches) { pumpDispatches.removeFirstOrNull() }?.run()
        }
    }

    @Test
    fun beginningFreshRepaintTransmitsItsFenceBeforeTheNormalPumpRuns() = runBlocking<Unit> {
        val client = FakeClient().apply {
            fenceReady = true
            repaintOutput = "fresh full frame"
            tickAfterRepaintOutput = "natural fence output"
        }
        val pumpDispatches = ArrayDeque<Runnable>()
        val pumpDispatcher = object : CoroutineDispatcher() {
            override fun dispatch(context: CoroutineContext, block: Runnable) {
                synchronized(pumpDispatches) { pumpDispatches.addLast(block) }
            }
        }
        val transport = fakeTransport(client, CoroutineScope(SupervisorJob() + pumpDispatcher))
        try {
            transport.connect(MoshConnectRequest(request(), columns = 56, rows = 45))
            val received = async(start = CoroutineStart.UNDISPATCHED) {
                withTimeout(2_000) { transport.output.take(2).toList() }
            }
            assertEquals(2L, transport.forceFullRepaint(repaintRequestId = 41, requiringFreshRemoteState = true))
            assertEquals("the normal pump is still held at its dispatch boundary", 1,
                synchronized(pumpDispatches) { pumpDispatches.size })
            assertTrue(client.fenceSent)
            assertEquals(1, client.ticks.get())
            val chunks = received.await()
            assertEquals(listOf("natural fence output", "fresh full frame"), chunks.map { it.bytes.decodeToString() })
            assertEquals(listOf(null, 41L), chunks.map { it.repaintRequestId })
        } finally {
            transport.close()
            synchronized(pumpDispatches) { pumpDispatches.removeFirstOrNull() }?.run()
        }
    }

    @Test
    fun freshRepaintTimesOutWithoutReturningAnOldCachedFrame() = runBlocking<Unit> {
        val client = FakeClient().apply { repaintOutput = "stale cached frame" }
        val transport = fakeTransport(client)
        try {
            transport.connect(MoshConnectRequest(request(), columns = 56, rows = 45))
            assertNull(transport.forceFullRepaint(repaintRequestId = 41, requiringFreshRemoteState = true))
            assertTrue("the normal pump must remain available during the wait", client.ticks.get() > 1)
            assertEquals(0, client.forcedRepaints.get())
            assertEquals(0L, transport.outputSequenceHighWater)
            // The optional fence does not change ordinary cached repaints.
            assertEquals(1L, transport.forceFullRepaint(repaintRequestId = 42))
            assertEquals(1, client.forcedRepaints.get())
        } finally {
            transport.close()
        }
    }

    @Test
    fun closingDuringFreshRepaintWaitDoesNotReadOrForceTheClosedDriver() = runBlocking<Unit> {
        val client = FakeClient().apply { repaintOutput = "stale cached frame" }
        val transport = fakeTransport(client)
        try {
            transport.connect(MoshConnectRequest(request(), columns = 56, rows = 45))
            val repaint = async {
                transport.forceFullRepaint(repaintRequestId = 41, requiringFreshRemoteState = true)
            }
            withTimeout(2_000) {
                while (client.fenceChecks.get() == 0) delay(5)
            }
            transport.close()
            client.fenceReady = true
            assertNull(withTimeout(500) { repaint.await() })
            assertEquals(0, client.forcedRepaints.get())
            assertEquals(0L, transport.outputSequenceHighWater)
        } finally {
            transport.close()
        }
    }

    @Test
    fun unavailableFreshRepaintFenceDoesNotFallBackToTheCachedFrame() = runBlocking<Unit> {
        val client = FakeClient().apply {
            fenceToken = 0L
            repaintOutput = "stale cached frame"
        }
        val transport = fakeTransport(client)
        try {
            transport.connect(MoshConnectRequest(request(), columns = 56, rows = 45))
            assertNull(transport.forceFullRepaint(repaintRequestId = 41, requiringFreshRemoteState = true))
            assertEquals(1, client.fenceBegins.get())
            assertEquals(0, client.fenceChecks.get())
            assertEquals(0, client.forcedRepaints.get())
        } finally {
            transport.close()
        }
    }

    @Test
    fun clearsBootstrapServerPidWhenNativeStartupFails() = runBlocking {
        var cleanupPid: Int? = null
        val transport = AndroidMoshTransport(
            bootstrapper = MoshBootstrapper {
                MoshBootstrapResult("198.51.100.8", 60001, "AAECAwQFBgcICQoLDA0ODw".encodeToByteArray(), 34)
            },
            nativeFactory = MoshNativeClientFactory { _, _, _, _ -> error("native startup failed") },
            onBootstrapServerStarted = { cleanupPid = it },
        )

        runCatching { transport.connect(MoshConnectRequest(request(), columns = 120, rows = 40)) }

        assertNull(transport.bootstrapServerPid)
        assertEquals(34, cleanupPid)
        assertEquals(MoshConnectionState.FAILED, transport.connectivity.value.state)
    }

    @Test
    fun transientUnreachabilityDoesNotBecomeDisconnectedOrRemoteExit() = runBlocking {
        val client = FakeClient().apply {
            reachable = false
            serverContactAgeMilliseconds = 17_999
            replyAgeMilliseconds = 24_000
        }
        val transport = AndroidMoshTransport(
            bootstrapper = MoshBootstrapper {
                MoshBootstrapResult("198.51.100.8", 60001, "AAECAwQFBgcICQoLDA0ODw".encodeToByteArray(), 34)
            },
            nativeFactory = MoshNativeClientFactory { _, _, _, output ->
                client.output = output
                client
            },
        )

        transport.connect(MoshConnectRequest(request(), columns = 120, rows = 40))
        repeat(50) {
            if (transport.connectivity.value.state == MoshConnectionState.CONNECTED) return@repeat
            delay(10)
        }

        assertEquals(MoshConnectionState.CONNECTED, transport.connectivity.value.state)
        assertFalse(transport.connectivity.value.transportReachable)
        assertEquals(MoshOutageTiming.Kind.CONTACT, transport.connectivity.value.outageTiming?.kind)
        assertEquals(17L, transport.connectivity.value.outageTiming?.seconds)
        transport.close()
        assertNull(transport.connectivity.value.outageTiming)
    }

    private fun fakeTransport(
        client: FakeClient,
        scope: CoroutineScope = CoroutineScope(SupervisorJob() + kotlinx.coroutines.Dispatchers.IO),
    ) = AndroidMoshTransport(
        bootstrapper = MoshBootstrapper {
            MoshBootstrapResult("198.51.100.8", 60001, "AAECAwQFBgcICQoLDA0ODw".encodeToByteArray(), 34)
        },
        nativeFactory = MoshNativeClientFactory { _, _, _, output ->
            client.output = output
            client
        },
        scope = scope,
    )

    private fun request() = MoshBootstrapRequest(
        route = SshRouteRequest(
            hops = listOf(
                SshRouteHop("host", SshEndpoint("example.com"), "alice", SshAuthentication.Password),
            ),
        ),
        udpHost = "198.51.100.8",
    )

    private class FakeClient : MoshNativeClient {
        var output: ((ByteArray) -> Unit)? = null
        var starts = 0
        var lastResize: Pair<Int, Int>? = null
        var open = true
        var reachable = true
        val injected = Collections.synchronizedList(mutableListOf<ByteArray>())
        val ticks = AtomicInteger()
        val fenceBegins = AtomicInteger()
        val fenceChecks = AtomicInteger()
        val forcedRepaints = AtomicInteger()
        @Volatile var fenceReady = false
        @Volatile var fenceSent = false
        private var fenceQueued = false
        var fenceToken = 73L
        var repaintOutput: String? = null
        var tickAfterRepaintOutput: String? = null
        override fun start() { starts += 1 }
        override fun tick(): Long {
            ticks.incrementAndGet()
            if (fenceQueued) {
                fenceQueued = false
                fenceSent = true
            }
            tickAfterRepaintOutput?.let {
                tickAfterRepaintOutput = null
                output?.invoke(it.encodeToByteArray())
            }
            return MoshNativeClient.NO_DEADLINE
        }
        override fun inject(bytes: ByteArray) { injected += bytes.copyOf() }
        override fun resize(columns: Int, rows: Int) { lastResize = columns to rows }
        override fun beginFullRepaintFence(): Long {
            check(open)
            fenceBegins.incrementAndGet()
            fenceQueued = true
            return fenceToken
        }
        override fun fullRepaintFenceReady(token: Long): Boolean {
            check(open)
            assertEquals(fenceToken, token)
            fenceChecks.incrementAndGet()
            return fenceReady && fenceSent
        }
        override fun forceFullRepaint() {
            forcedRepaints.incrementAndGet()
            repaintOutput?.let {
                repaintOutput = null
                output?.invoke(it.encodeToByteArray())
            }
        }
        override val connected: Boolean get() = true
        override val transportReachable: Boolean get() = reachable
        override var serverContactAgeMilliseconds: Long = 0
        override var replyAgeMilliseconds: Long = 0
        override val shutdownComplete: Boolean get() = false
        override fun close() { open = false }
    }
}
