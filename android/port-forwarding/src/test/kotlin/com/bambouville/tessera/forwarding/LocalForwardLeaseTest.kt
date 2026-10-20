package com.bambouville.tessera.forwarding

import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.FilterOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import net.schmizz.sshj.connection.ConnectionException
import net.schmizz.sshj.connection.channel.OpenFailException
import net.schmizz.sshj.transport.TransportException
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Tessera's own `-L` accept loop, which replaced SSHJ's `LocalPortForwarder`.
 *
 * The SSH side is a seam: [LocalForwardLease] asks a function to open each
 * direct-tcpip channel, and here that function either refuses the way SSHJ
 * does (`OpenFailException`) or connects a real loopback socket to a stand-in
 * remote service. Everything on the device side — the listener, the accepted
 * sockets, the copy threads — is the production code over real TCP.
 */
class LocalForwardLeaseTest {
    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val closeables = CopyOnWriteArrayList<Closeable>()
    private val collectors = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @After fun tearDown() {
        collectors.cancel()
        closeables.asReversed().forEach { runCatching { it.close() } }
        executor.shutdownNow()
        executor.awaitTermination(5, TimeUnit.SECONDS)
    }

    /**
     * The regression: SSHJ's `listen()` rethrew one refused channel and took
     * the whole rule down with it. A refused open must end that client alone.
     */
    @Test fun aRefusedDirectOpenClosesOnlyThatClientAndTheNextConnectionIsCarried() {
        val service = track(EchoService())
        val opens = AtomicInteger()
        val started = AtomicReference<LocalForwardLease>()
        val counts = CopyOnWriteArrayList<Int>()
        val (lease, evidence) = startLease(service) { endpoint ->
            if (opens.getAndIncrement() == 0) {
                // Holds the refusal until the collector has seen the count as
                // it stands mid-open: a StateFlow collector can miss a value
                // that is set and cleared again straight away.
                val midOpen = started.get().activeConnectionCount.value
                awaitTrue("the count mid-open was never collected") { counts.lastOrNull() == midOpen }
                throw OpenFailException("direct-tcpip", OpenFailException.Reason.CONNECT_FAILED, "Connection refused")
            }
            service.open(endpoint)
        }
        started.set(lease)
        collectors.launch(start = CoroutineStart.UNDISPATCHED) {
            lease.activeConnectionCount.collect { counts += it }
        }

        client(lease).use { refused ->
            assertClosedByPeer(refused)
        }
        awaitTrue("the refusal was never reported") { ForwardedServiceProbe.NotServing in evidence }
        assertTrue("one refused client closed the listener", lease.isOpen.value)
        assertTrue("a refused client was counted as active: $counts", counts.none { it > 0 })
        assertEquals("a refused client was counted as active", 0, lease.activeConnectionCount.value)

        client(lease).use { carried ->
            // A small interactive exchange first: the channel side buffers like
            // SSHJ's packet stream, so this only answers if every chunk is flushed.
            carried.getOutputStream().write("hello".encodeToByteArray())
            assertEquals("hello", carried.readExactly(5).decodeToString())
            awaitTrue("the carried connection was not counted") { lease.activeConnectionCount.value == 1 }

            // Then more than one copy buffer, byte for byte.
            val payload = ByteArray(200_000) { (it * 31 + 7).toByte() }
            val writer = thread { carried.getOutputStream().write(payload) }
            assertArrayEquals(payload, carried.readExactly(payload.size))
            writer.join(5_000)
        }
        awaitTrue("the finished connection was never released") { lease.activeConnectionCount.value == 0 }
        awaitTrue("the carried open was not reported as serving") { evidence.lastOrNull() == ForwardedServiceProbe.Serving }
        assertTrue(lease.isOpen.value)
        assertEquals(2, opens.get())
    }

    @Test fun anUnexpectedOpenFailureIsContainedAndInconclusive() {
        val service = track(EchoService())
        val opens = AtomicInteger()
        val (lease, evidence) = startLease(service) { endpoint ->
            when (opens.getAndIncrement()) {
                0 -> throw IllegalStateException("channel table corrupt")
                1 -> throw OpenFailException(
                    "direct-tcpip",
                    OpenFailException.Reason.ADMINISTRATIVELY_PROHIBITED,
                    "administratively prohibited",
                )
                else -> service.open(endpoint)
            }
        }

        client(lease).use(::assertClosedByPeer)
        client(lease).use(::assertClosedByPeer)
        client(lease).use { carried ->
            carried.getOutputStream().write("ok".encodeToByteArray())
            assertEquals("ok", carried.readExactly(2).decodeToString())
        }

        awaitTrue("every open was not reported") { evidence.size == 3 }
        assertEquals(
            listOf(
                ForwardedServiceProbe.Inconclusive("IllegalStateException"),
                ForwardedServiceProbe.Prohibited,
                ForwardedServiceProbe.Serving,
            ),
            evidence.toList(),
        )
        assertTrue(lease.isOpen.value)
    }

    /** A client that half-closes after its request still gets the whole reply. */
    @Test fun aHalfClosedClientStillReceivesTheReply() {
        val service = track(EchoService(replyAfterEof = true))
        val (lease, _) = startLease(service) { service.open(it) }

        client(lease).use { carried ->
            carried.getOutputStream().write("ping".encodeToByteArray())
            carried.shutdownOutput()
            assertEquals("PING", carried.getInputStream().readBytes().decodeToString())
        }
    }

    @Test fun closingTheLeaseEndsLiveConnectionsAndReportsOnce() {
        val service = track(EchoService())
        val closedCount = AtomicInteger()
        val (lease, _) = startLease(service, onClosed = { closedCount.incrementAndGet() }) { service.open(it) }

        val carried = track(client(lease))
        carried.getOutputStream().write("x".encodeToByteArray())
        assertEquals("x", carried.readExactly(1).decodeToString())

        lease.close()
        lease.close()

        assertFalse(lease.isOpen.value)
        assertEquals(1, closedCount.get())
        assertClosedByPeer(carried)
        awaitTrue("the closed connection was never released") { lease.activeConnectionCount.value == 0 }
        try {
            Socket().use { it.connect(InetSocketAddress(LOOPBACK, lease.bound.port), 1_000) }
            fail("the listener still accepts after close")
        } catch (_: IOException) {
            // Refused: nothing listens there any more.
        }
    }

    /**
     * SSHJ's channel close waits up to 30 s for the server's reply, and a
     * lease is closed under the manager's mutex and on the main thread. Here
     * the client has half-closed, so its upload is over and only the lease's
     * own sweep can close the channel.
     */
    @Test fun closingTheLeaseClosesItsChannelsWithoutWaitingOnThem() {
        val service = track(EchoService())
        val channel = StalledCloseChannel()
        track(Closeable(channel::releaseClose))
        val (lease, _) = startLease(service) { channel }

        val carried = track(client(lease))
        carried.shutdownOutput()
        assertTrue("the client's EOF never reached the channel", channel.eofSent.await(5, TimeUnit.SECONDS))
        awaitTrue("the connection was never carried") { lease.activeConnectionCount.value == 1 }

        val closer = thread(isDaemon = true, name = "lease-closer") { lease.close() }
        closer.join(1_000)
        assertFalse("closing the lease waited on a channel close", closer.isAlive)
        assertFalse(lease.isOpen.value)
        assertTrue("the lease never closed its channel", channel.closeInvoked.await(5, TimeUnit.SECONDS))
        assertNotSame("the channel was closed on the caller's thread", closer, channel.closedOn.get())
    }

    /** A client accepted as the lease closes costs the server no connect to the target. */
    @Test fun aClientServedAfterTheLeaseClosedOpensNoChannel() {
        val service = track(EchoService())
        val pool = HoldingExecutor(executor)
        val opens = AtomicInteger()
        val (lease, _) = startLease(service, executor = pool) { endpoint ->
            opens.incrementAndGet()
            service.open(endpoint)
        }

        track(client(lease))
        val serve = checkNotNull(pool.held.poll(5, TimeUnit.SECONDS)) { "the client was never accepted" }
        lease.close()
        serve.run()

        assertEquals("a channel was opened for a lease already closed", 0, opens.get())
    }

    @Test fun onlyTheServersOwnRefusalReasonIsConclusive() {
        fun refusal(reason: OpenFailException.Reason) = OpenFailException("direct-tcpip", reason, "x")

        assertEquals(
            ForwardedServiceProbe.NotServing,
            classifyDirectOpenFailure(refusal(OpenFailException.Reason.CONNECT_FAILED)),
        )
        assertEquals(
            ForwardedServiceProbe.Prohibited,
            classifyDirectOpenFailure(refusal(OpenFailException.Reason.ADMINISTRATIVELY_PROHIBITED)),
        )
        assertEquals(
            ForwardedServiceProbe.Inconclusive("open_failed_resource_shortage"),
            classifyDirectOpenFailure(refusal(OpenFailException.Reason.RESOURCE_SHORTAGE)),
        )
        // Wrapped refusals are still the server's answer.
        assertEquals(
            ForwardedServiceProbe.NotServing,
            classifyDirectOpenFailure(IOException("wrapped", refusal(OpenFailException.Reason.CONNECT_FAILED))),
        )
        assertEquals(
            ForwardedServiceProbe.Inconclusive("ConnectionException"),
            classifyDirectOpenFailure(ConnectionException("Timeout expired")),
        )
        assertEquals(
            ForwardedServiceProbe.Inconclusive("TransportException"),
            classifyDirectOpenFailure(TransportException("Broken transport; encountered EOF")),
        )
    }

    @Test fun aProbeClosesTheChannelItOpened() {
        val closed = AtomicBoolean(false)
        val verdicts = mutableListOf<ForwardedServiceProbe>()

        probeDirectOpen(open = { Closeable { closed.set(true) } }, report = verdicts::add)
        assertTrue(closed.get())
        probeDirectOpen(
            open = { throw OpenFailException("direct-tcpip", OpenFailException.Reason.CONNECT_FAILED, "refused") },
            report = verdicts::add,
        )
        assertEquals(listOf(ForwardedServiceProbe.Serving, ForwardedServiceProbe.NotServing), verdicts)
    }

    /**
     * A probe gets 8 s, as on iOS. An open still pending then is inconclusive
     * and is left to finish on the pool, never interrupted; when it opens
     * after all, it is closed at once.
     */
    @Test fun aProbePastItsDeadlineIsInconclusiveAndClosesWhatOpensLate() = runBlocking<Unit> {
        val release = CountDownLatch(1)
        track(Closeable(release::countDown))
        val lateChannelClosed = CountDownLatch(1)
        val begun = System.nanoTime()

        val outcome = probeDirectOpenWithin(deadlineMillis = 100, executor = executor) {
            release.await(10, TimeUnit.SECONDS)
            Closeable(lateChannelClosed::countDown)
        }

        assertEquals(ForwardedServiceProbe.Inconclusive("timeout"), outcome)
        assertTrue("the probe outlived its deadline", System.nanoTime() - begun < TimeUnit.SECONDS.toNanos(2))
        assertEquals("the pending open ended before it answered", 1L, lateChannelClosed.count)
        release.countDown()
        assertTrue("the channel that opened late was left open", lateChannelClosed.await(5, TimeUnit.SECONDS))
    }

    @Test fun aProbeAnsweredInTimeIsThatOpensVerdict() = runBlocking<Unit> {
        val closed = CountDownLatch(1)

        assertEquals(
            ForwardedServiceProbe.Serving,
            probeDirectOpenWithin(deadlineMillis = 5_000, executor = executor) { Closeable(closed::countDown) },
        )
        assertTrue("the probe's channel was left open", closed.await(5, TimeUnit.SECONDS))
        assertEquals(
            ForwardedServiceProbe.NotServing,
            probeDirectOpenWithin(deadlineMillis = 5_000, executor = executor) {
                throw OpenFailException("direct-tcpip", OpenFailException.Reason.CONNECT_FAILED, "refused")
            },
        )
    }

    /**
     * An open that succeeded is the answer. SSHJ's close then waits on the
     * server's reply, and a stalled one must not turn that answer into a
     * timeout.
     */
    @Test fun aProbeAnswersBeforeItsCloseIsDone() = runBlocking<Unit> {
        val release = CountDownLatch(1)
        track(Closeable(release::countDown))
        val closeBegun = CountDownLatch(1)

        val outcome = probeDirectOpenWithin(deadlineMillis = 1_000, executor = executor) {
            Closeable {
                closeBegun.countDown()
                release.await(10, TimeUnit.SECONDS)
            }
        }

        assertEquals(ForwardedServiceProbe.Serving, outcome)
        assertTrue("the probe never closed its channel", closeBegun.await(5, TimeUnit.SECONDS))
    }

    /** The runtime shut its pool down: nothing opens, and nothing throws. */
    @Test fun aProbeOnARefusingPoolIsInconclusive() = runBlocking<Unit> {
        val shutDown = Executor { throw RejectedExecutionException("shut down") }

        assertEquals(
            ForwardedServiceProbe.Inconclusive("runtime_closed"),
            probeDirectOpenWithin(deadlineMillis = 5_000, executor = shutDown) {
                throw AssertionError("opened on a pool that refused the task")
            },
        )
    }

    // region fixtures

    private fun startLease(
        service: EchoService,
        onClosed: () -> Unit = {},
        executor: ExecutorService = this.executor,
        openChannel: (PortForwardEndpoint) -> ForwardingChannel,
    ): Pair<LocalForwardLease, MutableList<ForwardedServiceProbe>> {
        val serverSocket = ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress(LOOPBACK, 0))
        }
        val lease = LocalForwardLease(
            bound = BoundForwardEndpoint("127.0.0.1", serverSocket.localPort),
            serverSocket = serverSocket,
            target = PortForwardEndpoint("localhost", service.port),
            executor = executor,
            openChannel = openChannel,
            onClosed = onClosed,
        )
        track(lease)
        val evidence = CopyOnWriteArrayList<ForwardedServiceProbe>()
        // Undispatched, so the subscription exists before the first client:
        // the lease replays only its latest outcome.
        collectors.launch(start = CoroutineStart.UNDISPATCHED) {
            lease.serviceEvidence.collect { evidence += it }
        }
        lease.start()
        return lease to evidence
    }

    private fun client(lease: PortForwardingLease): Socket = Socket().apply {
        soTimeout = 5_000
        connect(InetSocketAddress(LOOPBACK, lease.bound.port), 5_000)
    }

    private fun <T : Closeable> track(closeable: T): T = closeable.also { closeables += it }

    /** The peer ended the connection: EOF or a reset, but never a hang. */
    private fun assertClosedByPeer(socket: Socket) {
        try {
            assertEquals(-1, socket.getInputStream().read())
        } catch (timeout: SocketTimeoutException) {
            throw AssertionError("the client was left hanging instead of closed", timeout)
        } catch (_: IOException) {
            // Reset by peer is a close too.
        }
    }

    private fun Socket.readExactly(count: Int): ByteArray {
        val input = getInputStream()
        val out = ByteArrayOutputStream(count)
        val buffer = ByteArray(8_192)
        while (out.size() < count) {
            val read = input.read(buffer, 0, minOf(buffer.size, count - out.size()))
            if (read < 0) throw AssertionError("stream ended after ${out.size()} of $count bytes")
            out.write(buffer, 0, read)
        }
        return out.toByteArray()
    }

    private fun awaitTrue(message: String, condition: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!condition()) {
            if (System.nanoTime() > deadline) throw AssertionError(message)
            Thread.sleep(5)
        }
    }

    /**
     * The remote service a channel reaches: echoes as bytes arrive, or, with
     * [replyAfterEof], answers upper-cased once the request is complete.
     */
    private class EchoService(private val replyAfterEof: Boolean = false) : Closeable {
        private val socket = ServerSocket(0, 16, LOOPBACK)
        private val clients = CopyOnWriteArrayList<Socket>()
        val port: Int get() = socket.localPort

        init {
            thread(isDaemon = true, name = "forward-lease-test-service") {
                while (!socket.isClosed) {
                    val client = try {
                        socket.accept()
                    } catch (_: IOException) {
                        break
                    }
                    clients += client
                    thread(isDaemon = true) { serve(client) }
                }
            }
        }

        private fun serve(client: Socket) {
            try {
                client.use {
                    if (replyAfterEof) {
                        val request = it.getInputStream().readBytes()
                        it.getOutputStream().write(request.decodeToString().uppercase().encodeToByteArray())
                    } else {
                        it.getInputStream().copyTo(it.getOutputStream())
                    }
                }
            } catch (_: IOException) {
                // Torn down by the test.
            }
        }

        /** A channel to this service, buffered the way SSHJ's channel stream is. */
        fun open(endpoint: PortForwardEndpoint): ForwardingChannel {
            val socket = Socket(LOOPBACK, endpoint.port)
            return SocketChannel(socket)
        }

        override fun close() {
            socket.close()
            clients.forEach { runCatching { it.close() } }
        }
    }

    /**
     * SSHJ's `ChannelOutputStream` holds data until a whole packet is written
     * or it is flushed, and closing it sends EOF rather than closing the
     * channel. A large buffer and a half-close model both.
     */
    private class SocketChannel(private val socket: Socket) : ForwardingChannel {
        override val inputStream: InputStream = socket.getInputStream()
        override val outputStream: OutputStream =
            object : FilterOutputStream(BufferedOutputStream(socket.getOutputStream(), 1 shl 20)) {
                override fun write(b: ByteArray, off: Int, len: Int) = out.write(b, off, len)

                override fun close() {
                    runCatching { out.flush() }
                    runCatching { socket.shutdownOutput() }
                }
            }

        override fun close() = socket.close()
    }

    /**
     * Runs the lease's accept loop and holds every later task — each client's
     * serve — in [held] for the test to run when it chooses.
     */
    private class HoldingExecutor(private val delegate: ExecutorService) : AbstractExecutorService() {
        private val acceptLoopStarted = AtomicBoolean(false)
        val held = LinkedBlockingQueue<Runnable>()

        override fun execute(command: Runnable) {
            if (acceptLoopStarted.compareAndSet(false, true)) delegate.execute(command) else held.put(command)
        }

        override fun shutdown() = Unit
        override fun shutdownNow(): List<Runnable> = emptyList()
        override fun isShutdown() = false
        override fun isTerminated() = false
        override fun awaitTermination(timeout: Long, unit: TimeUnit) = true
    }

    /**
     * A channel whose close stalls until [releaseClose], the way SSHJ's waits
     * for a server that no longer answers. Its input ends once a close has.
     */
    private class StalledCloseChannel : ForwardingChannel {
        val eofSent = CountDownLatch(1)
        val closeInvoked = CountDownLatch(1)
        val closedOn = AtomicReference<Thread>()
        private val released = CountDownLatch(1)
        private val closed = CountDownLatch(1)

        override val inputStream: InputStream = object : InputStream() {
            override fun read(): Int {
                closed.await()
                return -1
            }
        }
        override val outputStream: OutputStream = object : OutputStream() {
            override fun write(b: Int) = Unit

            override fun close() = eofSent.countDown()
        }

        override fun close() {
            closedOn.compareAndSet(null, Thread.currentThread())
            closeInvoked.countDown()
            released.await()
            closed.countDown()
        }

        fun releaseClose() = released.countDown()
    }

    private companion object {
        val LOOPBACK: InetAddress = InetAddress.getByName("127.0.0.1")
    }

    // endregion
}
