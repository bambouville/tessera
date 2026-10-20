package com.bambouville.tessera.networking.mosh

import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshKeyAuthorizationProvider
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteRequest
import com.bambouville.tessera.networking.SshTmuxConnection
import com.bambouville.tessera.networking.connectTmux
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.Closeable
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

enum class MoshConnectionState { IDLE, BOOTSTRAPPING, CONNECTING, CONNECTED, DISCONNECTED, FAILED }

/** No driver accepted any bytes from this input call. */
class MoshInputNotAdmittedException : IllegalStateException("Mosh input was not admitted")

data class MoshConnectivity(
    val state: MoshConnectionState,
    val transportReachable: Boolean = false,
    val message: String? = null,
    val outageTiming: MoshOutageTiming? = null,
)

/** Match NotificationEngine's contact/reply thresholds and age selection. */
data class MoshOutageTiming(val startedAtMillis: Long, val kind: Kind, val seconds: Long) {
    enum class Kind { CONTACT, REPLY }

    companion object {
        fun next(
            previous: MoshOutageTiming?, connected: Boolean, reachable: Boolean,
            serverContactAgeMilliseconds: Long, replyAgeMilliseconds: Long, nowMillis: Long,
        ): MoshOutageTiming? {
            if (!connected || reachable) return null
            val kind: Kind
            val age: Long
            if (serverContactAgeMilliseconds > 6_500) {
                kind = Kind.CONTACT
                age = serverContactAgeMilliseconds
            } else if (replyAgeMilliseconds > 10_000) {
                kind = Kind.REPLY
                age = replyAgeMilliseconds
            } else {
                return null
            }
            // A kind switch selects a different clock, whose age may be younger.
            val previousSeconds = if (previous != null && previous.kind == kind) previous.seconds else 0
            return MoshOutageTiming(
                startedAtMillis = previous?.startedAtMillis ?: nowMillis,
                kind = kind,
                seconds = maxOf(previousSeconds, age / 1_000),
            )
        }
    }
}

data class MoshConnectRequest(
    val bootstrap: MoshBootstrapRequest,
    val columns: Int,
    val rows: Int,
) {
    init {
        require(columns >= 4 && rows >= 4)
    }
}

data class MoshOutputChunk(
    val sequence: Long,
    val bytes: ByteArray,
    val repaintRequestId: Long? = null,
)

/**
 * Cumulative counters from the Mosh driver loop, sampled for diagnostics.
 *
 * `wakesReadable` is the number of times the pump woke because a datagram
 * arrived; `wakesTimeout` the number of times it woke on the driver's own
 * deadline instead. A session that reports almost no readable wakes is back
 * on the old fixed-interval poll, which is exactly the lag this loop was
 * rebuilt to remove, so the ratio is the first thing to read in a report.
 */
data class MoshPumpStats(
    val ticks: Long,
    val wakesReadable: Long,
    val wakesTimeout: Long,
    val wakesImmediate: Long,
    val wakesInterrupted: Long,
    val wakesFallback: Long,
    val outputChunks: Long,
    val outputBytes: Long,
    val maxTickMicros: Long,
    val totalTickMicros: Long,
    val backpressureBlocks: Long,
    val maxBackpressureMicros: Long,
    val connectStartedAtMillis: Long?,
    val connectedAtMillis: Long?,
    val firstOutputAtMillis: Long?,
) {
    /** One bounded line for the diagnostics log. */
    fun summary(): String = buildString {
        append("ticks=").append(ticks)
        append(" wake[readable=").append(wakesReadable)
        append(" timeout=").append(wakesTimeout)
        append(" immediate=").append(wakesImmediate)
        append(" interrupted=").append(wakesInterrupted)
        append(" fallback=").append(wakesFallback).append(']')
        append(" out[chunks=").append(outputChunks).append(" bytes=").append(outputBytes).append(']')
        append(" tick[max=").append(maxTickMicros / 1000.0).append("ms")
        append(" avg=")
        append(if (ticks == 0L) 0.0 else (totalTickMicros / ticks) / 1000.0).append("ms]")
        append(" backpressure[blocks=").append(backpressureBlocks)
        append(" max=").append(maxBackpressureMicros / 1000.0).append("ms]")
        val start = connectStartedAtMillis
        if (start != null) {
            append(" connect=").append(connectedAtMillis?.let { "${it - start}ms" } ?: "pending")
            append(" firstOutput=").append(firstOutputAtMillis?.let { "${it - start}ms" } ?: "none")
        }
    }
}

/**
 * Transport-neutral Mosh driver. It has no dependency on the app/session UI
 * or shared-core bridge: a platform session adapter can map its output and
 * connectivity flows to any presentation/runtime.
 */
class AndroidMoshTransport(
    private val bootstrapper: MoshBootstrapper,
    private val nativeFactory: MoshNativeClientFactory = JniMoshNativeClientFactory,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    private val onBootstrapServerStarted: (Int) -> Unit = {},
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val _connectivity = MutableStateFlow(MoshConnectivity(MoshConnectionState.IDLE))
    // Mosh emits its initial framebuffer synchronously from start(). This is a
    // single-consumer terminal stream: bounded backpressure preserves byte
    // order and never drops control sequences while rendering catches up.
    private val outputChannel = Channel<MoshOutputChunk>(OUTPUT_BUFFER_CAPACITY)
    /**
     * Absolute sequence of chunks accepted by [outputChannel]. A forced
     * repaint can return this target to the presentation adapter, which then
     * waits until the matching terminal consumer has applied every chunk up
     * to it. Enqueue completion alone is not a render-ordering fence.
     */
    private val allocatedOutputCount = AtomicLong(0)
    private val outputSequenceLock = Any()
    private val driverOperations = Mutex()
    private var activeRepaintOutput: ByteArrayOutputStream? = null
    @Volatile private var driver: MoshNativeClient? = null
    private var pump: Job? = null
    private val statTicks = AtomicLong(0)
    private val statWakesReadable = AtomicLong(0)
    private val statWakesTimeout = AtomicLong(0)
    private val statWakesImmediate = AtomicLong(0)
    private val statWakesInterrupted = AtomicLong(0)
    private val statWakesFallback = AtomicLong(0)
    private val statOutputChunks = AtomicLong(0)
    private val statOutputBytes = AtomicLong(0)
    private val statMaxTickMicros = AtomicLong(0)
    private val statTotalTickMicros = AtomicLong(0)
    private val statBackpressureBlocks = AtomicLong(0)
    private val statMaxBackpressureMicros = AtomicLong(0)
    @Volatile private var connectStartedAtMillis: Long? = null
    @Volatile private var connectedAtMillis: Long? = null
    @Volatile private var firstOutputAtMillis: Long? = null

    /** Detached mosh-server PID from the current bootstrap, never a credential. */
    @Volatile var bootstrapServerPid: Int? = null
        private set

    val connectivity: StateFlow<MoshConnectivity> = _connectivity.asStateFlow()
    val output: Flow<MoshOutputChunk> = outputChannel.receiveAsFlow()

    /** Includes producer callbacks that are still backpressured before delivery. */
    val outputSequenceHighWater: Long
        get() = allocatedOutputCount.get()

    /** A consistent-enough sample of the driver loop counters for a log line. */
    fun pumpStats(): MoshPumpStats = MoshPumpStats(
        ticks = statTicks.get(),
        wakesReadable = statWakesReadable.get(),
        wakesTimeout = statWakesTimeout.get(),
        wakesImmediate = statWakesImmediate.get(),
        wakesInterrupted = statWakesInterrupted.get(),
        wakesFallback = statWakesFallback.get(),
        outputChunks = statOutputChunks.get(),
        outputBytes = statOutputBytes.get(),
        maxTickMicros = statMaxTickMicros.get(),
        totalTickMicros = statTotalTickMicros.get(),
        backpressureBlocks = statBackpressureBlocks.get(),
        maxBackpressureMicros = statMaxBackpressureMicros.get(),
        connectStartedAtMillis = connectStartedAtMillis,
        connectedAtMillis = connectedAtMillis,
        firstOutputAtMillis = firstOutputAtMillis,
    )

    suspend fun connect(request: MoshConnectRequest) = withContext(Dispatchers.IO) {
        check(!closed.get()) { "Mosh transport is closed" }
        check(driver == null) { "Mosh transport is already active" }
        connectStartedAtMillis = System.currentTimeMillis()
        _connectivity.value = MoshConnectivity(MoshConnectionState.BOOTSTRAPPING)
        val bootstrap = try {
            bootstrapper.bootstrap(request.bootstrap)
        } catch (failure: Throwable) {
            fail(failure)
            throw failure
        }
        try {
            bootstrap.serverPid?.takeIf { it > 0 }?.let { serverPid ->
                // Transfer cleanup ownership before exposing the PID or
                // entering native startup. Explicit close may race either
                // boundary; after this callback the exact detached process is
                // always represented by an immutable controller lease.
                onBootstrapServerStarted(serverPid)
                bootstrapServerPid = serverPid
            }
            val client = nativeFactory.create(
                host = bootstrap.host,
                udpPort = bootstrap.udpPort,
                base64Key = bootstrap.base64Key,
                onOutput = ::enqueueOutput,
            )
            driverOperations.withLock {
                check(!closed.get()) { "Mosh transport is closed" }
                driver = client
                client.resize(request.columns, request.rows)
                _connectivity.value = MoshConnectivity(MoshConnectionState.CONNECTING)
                client.start()
            }
            pump = scope.launch { pump(client) }
        } catch (failure: Throwable) {
            fail(failure)
            throw failure
        } finally {
            // The native ABI has already decoded this into its wipeable crypto
            // session by start(). The Kotlin-side copy must not outlive setup.
            bootstrap.close()
        }
    }

    suspend fun send(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        withContext(Dispatchers.IO) {
            driverOperations.withLock {
                val client = driver?.takeUnless { closed.get() || it.shutdownComplete }
                    ?: throw MoshInputNotAdmittedException()
                val normalized = MoshInputNormalizer.normalizeArrowKeys(bytes)
                var offset = 0
                while (offset < normalized.size) {
                    val end = minOf(offset + MOSH_C_ABI_MAX_INPUT_BATCH_BYTES, normalized.size)
                    client.inject(normalized.copyOfRange(offset, end))
                    offset = end
                }
                // inject only queues state; tick transmits it. Do not make typing
                // wait for the next poll deadline.
                tickAndPublishConnectivity(client)
            }
        }
    }

    suspend fun resize(columns: Int, rows: Int) = withContext(Dispatchers.IO) {
        require(columns >= 4 && rows >= 4)
        driverOperations.withLock {
            val client = driver ?: return@withLock
            client.resize(columns, rows)
            tickAndPublishConnectivity(client)
        }
    }

    suspend fun forceFullRepaint(
        repaintRequestId: Long? = null,
        requiringFreshRemoteState: Boolean = false,
    ): Long? = withContext(Dispatchers.IO) {
        require(repaintRequestId == null || repaintRequestId > 0)
        val client = driverOperations.withLock {
            if (closed.get()) null else driver
        } ?: return@withContext null
        if (requiringFreshRemoteState) {
            val token = driverOperations.withLock {
                if (closed.get() || driver !== client) 0L else {
                    client.beginFullRepaintFence().also { fence ->
                        // Appending the resize does not send it. Transmit this
                        // fence now, keeping any SSP output natural because
                        // the forced collector is not armed yet.
                        if (fence > 0) tickAndPublishConnectivity(client)
                    }
                }
            }
            if (token <= 0) return@withContext null
            val deadlineNanos = System.nanoTime() + FULL_REPAINT_FENCE_TIMEOUT_MILLISECONDS * 1_000_000L
            while (true) {
                var waiting = false
                val target = driverOperations.withLock {
                    if (closed.get() || driver !== client) return@withLock null
                    if (client.fullRepaintFenceReady(token)) {
                        collectForcedRepaint(client, repaintRequestId)
                    } else {
                        waiting = true
                        null
                    }
                }
                if (!waiting) return@withContext target
                if (System.nanoTime() >= deadlineNanos) return@withContext null
                // Only the normal pump may receive the SSP acknowledgement.
                // Keep its output natural and let it acquire the driver lock
                // while the caller waits, before arming the forced collector.
                delay(FULL_REPAINT_FENCE_POLL_MILLISECONDS)
            }
        }
        driverOperations.withLock {
            if (closed.get() || driver !== client) return@withLock null
            collectForcedRepaint(client, repaintRequestId)
        }
    }

    /** Called with driverOperations held, immediately after any freshness check. */
    private fun collectForcedRepaint(client: MoshNativeClient, repaintRequestId: Long?): Long? {
        synchronized(outputSequenceLock) {
            check(activeRepaintOutput == null) { "Mosh full repaint is already being collected" }
            activeRepaintOutput = ByteArrayOutputStream()
        }
        var repaintBytes = ByteArray(0)
        try {
            // The native call synchronously emits its complete cached
            // framebuffer. A tick here can also receive a fresh SSP
            // update, which would incorrectly inherit this forced
            // request's identity instead of reporting natural activity.
            client.forceFullRepaint()
        } finally {
            repaintBytes = synchronized(outputSequenceLock) {
                (activeRepaintOutput?.toByteArray() ?: ByteArray(0)).also {
                    activeRepaintOutput = null
                }
            }
        }
        return if (repaintBytes.isEmpty()) null else enqueueOutput(repaintBytes, repaintRequestId)
    }

    override fun close() {
        // close() leaves already-suspended sends waiting for a receiver. During
        // teardown that receiver has gone away, while the native callback holds
        // driverOperations. Abort the channel BEFORE waiting for the driver,
        // including when a graceful remote disconnect has already started.
        val firstClose = closed.compareAndSet(false, true)
        outputChannel.cancel()
        if (!firstClose) return
        pump?.cancel()
        pump = null
        runBlocking {
            driverOperations.withLock {
                driver?.close()
                driver = null
            }
        }
        bootstrapServerPid = null
        _connectivity.value = MoshConnectivity(MoshConnectionState.DISCONNECTED)
        scope.cancel()
    }

    /**
     * The driver loop. Mosh's own `recv` never blocks and its `wait_time` only
     * knows about the sender's ack/retransmit schedule, so nothing inside the
     * native client can notice an arriving datagram until someone calls
     * `tick()` again. This loop therefore parks in `poll()` on the client's UDP
     * sockets between ticks, exactly as iOS parks in a `DispatchSourceRead`,
     * and uses the driver's deadline only as the poll timeout. Sleeping a
     * fixed interval here instead was the single largest source of Mosh
     * feeling slower than SSH: every server frame waited up to that interval
     * before it could even be parsed.
     */
    private suspend fun pump(client: MoshNativeClient) {
        try {
            while (scope.isActive && !closed.get() && !client.shutdownComplete) {
                val waitMilliseconds = driverOperations.withLock {
                    if (closed.get() || driver !== client) return@withLock null
                    tickAndPublishConnectivity(client)
                } ?: break
                val timeout = when {
                    waitMilliseconds == MoshNativeClient.NO_DEADLINE -> MAX_POLL_DELAY_MILLISECONDS
                    waitMilliseconds <= 0L -> 0L
                    else -> waitMilliseconds.coerceAtMost(MAX_POLL_DELAY_MILLISECONDS)
                }
                if (timeout == 0L) {
                    statWakesImmediate.incrementAndGet()
                    yield()
                    continue
                }
                // Re-read every iteration: mosh opens a new socket when the
                // device's address changes and retires the old one later.
                val fds = client.socketFds()
                if (fds.isEmpty()) {
                    statWakesFallback.incrementAndGet()
                    delay(timeout)
                    continue
                }
                // Blocking on the IO dispatcher, with no driver lock held, so a
                // keystroke's inject+tick from another thread never waits on it.
                when (client.awaitReadable(fds, timeout.toInt())) {
                    MoshSocketWake.READABLE -> statWakesReadable.incrementAndGet()
                    MoshSocketWake.TIMEOUT -> statWakesTimeout.incrementAndGet()
                    MoshSocketWake.INTERRUPTED -> statWakesInterrupted.incrementAndGet()
                    MoshSocketWake.UNSUPPORTED -> {
                        // A stale descriptor (POLLNVAL) or a client without
                        // sockets: sleep the deadline rather than spin.
                        statWakesFallback.incrementAndGet()
                        delay(timeout)
                    }
                }
            }
            if (!closed.get()) finishDisconnected(client)
        } catch (failure: Throwable) {
            fail(failure)
        }
    }

    private fun fail(failure: Throwable) {
        if (!closed.compareAndSet(false, true)) return
        outputChannel.cancel()
        runBlocking {
            driverOperations.withLock {
                driver?.close()
                driver = null
            }
        }
        bootstrapServerPid = null
        _connectivity.value = MoshConnectivity(MoshConnectionState.FAILED, message = failure.message)
        scope.cancel()
    }

    private fun finishDisconnected(client: MoshNativeClient) {
        if (!closed.compareAndSet(false, true)) return
        runBlocking {
            driverOperations.withLock {
                if (driver === client) driver = null
                client.close()
            }
        }
        outputChannel.close()
        bootstrapServerPid = null
        _connectivity.value = MoshConnectivity(MoshConnectionState.DISCONNECTED)
        scope.cancel()
    }

    private fun tickAndPublishConnectivity(client: MoshNativeClient): Long {
        val startedNanos = System.nanoTime()
        val waitMilliseconds = client.tick()
        val elapsedMicros = (System.nanoTime() - startedNanos) / 1_000
        statTicks.incrementAndGet()
        statTotalTickMicros.addAndGet(elapsedMicros)
        statMaxTickMicros.accumulateAndGet(elapsedMicros, ::maxOf)
        val connected = client.connected
        if (connected && connectedAtMillis == null) connectedAtMillis = System.currentTimeMillis()
        val reachable = client.transportReachable
        _connectivity.value = MoshConnectivity(
            state = if (connected) MoshConnectionState.CONNECTED else MoshConnectionState.CONNECTING,
            transportReachable = reachable,
            outageTiming = MoshOutageTiming.next(
                previous = _connectivity.value.outageTiming,
                connected = connected,
                reachable = reachable,
                serverContactAgeMilliseconds = client.serverContactAgeMilliseconds,
                replyAgeMilliseconds = client.replyAgeMilliseconds,
                nowMillis = System.nanoTime() / 1_000_000,
            ),
        )
        return waitMilliseconds
    }

    private fun enqueueOutput(bytes: ByteArray, repaintRequestId: Long? = null): Long? {
        if (bytes.isEmpty() || closed.get()) return null
        // The C ABI lends callback bytes only for this invocation. Retain a
        // copy, then backpressure the native tick/start thread rather than
        // silently losing escape sequences or allocating without bound.
        val owned = bytes.copyOf()
        synchronized(outputSequenceLock) {
            activeRepaintOutput?.let { repaint ->
                repaint.write(owned)
                return null
            }
            // Receipt IDs cross the C ABI as Swift UInt64 but Android consumes
            // signed Long. Never wrap into a negative/reused identifier: the
            // exception propagates through the active driver operation and
            // closes or rejects that operation instead.
            val sequence = Math.incrementExact(allocatedOutputCount.get())
            allocatedOutputCount.set(sequence)
            val chunk = MoshOutputChunk(
                sequence = sequence,
                bytes = owned,
                repaintRequestId = repaintRequestId,
            )
            statOutputChunks.incrementAndGet()
            statOutputBytes.addAndGet(owned.size.toLong())
            if (firstOutputAtMillis == null) firstOutputAtMillis = System.currentTimeMillis()
            val offered = outputChannel.trySend(chunk)
            if (offered.isSuccess) return sequence
            if (offered.isClosed) return null
            // The consumer is behind: block the driver thread rather than drop
            // bytes, and remember how long it stalled for the diagnostics line.
            statBackpressureBlocks.incrementAndGet()
            val startedNanos = System.nanoTime()
            val sent = runCatching { runBlocking { outputChannel.send(chunk) } }.isSuccess
            statMaxBackpressureMicros.accumulateAndGet((System.nanoTime() - startedNanos) / 1_000, ::maxOf)
            return if (sent) sequence else null
        }
    }

    private companion object {
        /**
         * Upper bound on one socket wait. Datagrams wake the loop earlier;
         * this only bounds how late a driver deadline can fire and how long
         * `close()` can wait for the loop to notice.
         */
        const val MAX_POLL_DELAY_MILLISECONDS = 100L
        const val FULL_REPAINT_FENCE_TIMEOUT_MILLISECONDS = 2_000L
        const val FULL_REPAINT_FENCE_POLL_MILLISECONDS = 20L
        const val OUTPUT_BUFFER_CAPACITY = 16
        const val MOSH_C_ABI_MAX_INPUT_BATCH_BYTES = 65_536
    }
}

/** Mosh expects SS3 arrows from the local terminal and maps them remotely. */
internal object MoshInputNormalizer {
    fun normalizeArrowKeys(bytes: ByteArray): ByteArray {
        if (bytes.size < 3) return bytes
        val normalized = ArrayList<Byte>(bytes.size)
        var index = 0
        while (index < bytes.size) {
            if (index + 2 < bytes.size && bytes[index] == ESCAPE && bytes[index + 1] == CSI &&
                bytes[index + 2] in ARROW_FINAL_BYTES
            ) {
                normalized += ESCAPE
                normalized += SS3
                normalized += bytes[index + 2]
                index += 3
            } else {
                normalized += bytes[index]
                index += 1
            }
        }
        return normalized.toByteArray()
    }

    private const val ESCAPE: Byte = 0x1b
    private const val CSI: Byte = 0x5b
    private const val SS3: Byte = 0x4f
    private val ARROW_FINAL_BYTES = setOf(0x41.toByte(), 0x42.toByte(), 0x43.toByte(), 0x44.toByte())
}

/** Separate SSH -CC channel used only by Mosh + tmux metadata/control traffic. */
fun interface MoshTmuxControlChannelFactory {
    suspend fun open(request: MoshTmuxControlRequest): SshTmuxConnection
}

data class MoshTmuxControlRequest(
    val route: SshRouteRequest,
    val sessionTarget: String,
    val preserveInitialGeometry: Boolean = false,
)

class AndroidMoshTmuxControlChannelFactory(
    private val backend: AndroidSshBackend,
    private val passwordProvider: SshPasswordProvider,
    private val hostKeyPolicy: SshHostKeyPolicy,
    private val keyAuthorizationProvider: SshKeyAuthorizationProvider = SshKeyAuthorizationProvider { },
) : MoshTmuxControlChannelFactory {
    override suspend fun open(request: MoshTmuxControlRequest): SshTmuxConnection = backend.connectTmux(
        request = request.route,
        sessionTarget = request.sessionTarget,
        preserveInitialGeometry = request.preserveInitialGeometry,
        moshViewSession = true,
        passwordProvider = passwordProvider,
        hostKeyPolicy = hostKeyPolicy,
        keyAuthorizationProvider = keyAuthorizationProvider,
    )
}
