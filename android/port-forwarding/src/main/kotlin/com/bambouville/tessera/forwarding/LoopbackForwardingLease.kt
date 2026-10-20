package com.bambouville.tessera.forwarding

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withTimeoutOrNull
import net.schmizz.sshj.connection.channel.OpenFailException
import net.schmizz.sshj.connection.channel.direct.DirectConnection

/**
 * The SSH side of one forwarded client: an opened direct-tcpip channel's two
 * streams. Closing [outputStream] half-closes (SSH `CHANNEL_EOF`); closing the
 * channel tears both directions down.
 */
internal interface ForwardingChannel : Closeable {
    val inputStream: InputStream
    val outputStream: OutputStream
}

internal fun DirectConnection.asForwardingChannel(): ForwardingChannel {
    val connection = this
    return object : ForwardingChannel {
        override val inputStream: InputStream get() = connection.inputStream
        override val outputStream: OutputStream get() = connection.outputStream
        override fun close() = connection.close()
    }
}

/**
 * A loopback listener that accepts clients and carries each over its own SSH
 * channel: the plumbing shared by local (`-L`) and dynamic (`-D`) forwards.
 *
 * Every client runs on its own pool task, and nothing a client does can end
 * the listener: an exception that escapes an executor task is uncaught on a
 * pool thread, and Android's default handler answers that by killing the
 * process. Only the listening socket failing closes the lease.
 *
 * [activeConnectionCount] counts clients whose channel is open and carrying,
 * not clients merely accepted: a connection the server refuses was never
 * active, and must not flash the rule as such.
 */
internal abstract class LoopbackForwardingLease(
    final override val bound: BoundForwardEndpoint,
    private val serverSocket: ServerSocket,
    private val executor: ExecutorService,
    private val onClosed: () -> Unit,
) : PortForwardingLease {
    private val closed = AtomicBoolean(false)
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    private val channels = ConcurrentHashMap.newKeySet<Closeable>()
    private val mutableConnectionCount = MutableStateFlow(0)
    private val mutableOpen = MutableStateFlow(true)

    final override val activeConnectionCount: StateFlow<Int> = mutableConnectionCount.asStateFlow()
    final override val isOpen: StateFlow<Boolean> = mutableOpen.asStateFlow()

    /**
     * Serves one accepted client on a pool thread. It may throw; the caller
     * contains it and closes [socket] afterwards either way.
     */
    protected abstract fun serve(socket: Socket)

    fun start() {
        executor.execute {
            try {
                while (!closed.get()) {
                    val socket = try {
                        serverSocket.accept()
                    } catch (error: IOException) {
                        if (closed.get()) break
                        throw error
                    }
                    admit(socket)
                }
            } catch (_: Throwable) {
                // Closed below; the lease reports itself shut through `isOpen`.
            } finally {
                close()
            }
        }
    }

    private fun admit(socket: Socket) {
        sockets += socket
        // close() may have swept the set between accept() and the add above.
        if (closed.get()) {
            release(socket)
            return
        }
        try {
            executor.execute {
                try {
                    serve(socket)
                } catch (_: Throwable) {
                    // One client's failure is that client's alone.
                } finally {
                    release(socket)
                }
            }
        } catch (_: RejectedExecutionException) {
            release(socket)
        }
    }

    private fun release(socket: Socket) {
        sockets.remove(socket)
        runCatching { socket.close() }
    }

    /**
     * Registers an opened channel so [close] can tear it down. False — with
     * the channel already closed — when the lease closed first.
     */
    protected fun adopt(channel: Closeable): Boolean {
        channels += channel
        if (closed.get()) {
            abandon(channel)
            return false
        }
        return true
    }

    protected fun abandon(channel: Closeable) {
        channels.remove(channel)
        runCatching { channel.close() }
    }

    /**
     * Pipes [socket] and [channel] both ways until the remote side ends or
     * either side fails, counting one active connection for exactly that
     * span. [clientInput] is the socket's input, possibly already buffered by
     * a handshake. Never throws.
     */
    protected fun carry(socket: Socket, clientInput: InputStream, channel: ForwardingChannel) {
        mutableConnectionCount.update { it + 1 }
        try {
            val upload = executor.submit(
                Runnable {
                    try {
                        copyFlushing(clientInput, channel.outputStream)
                        // The client finished sending. Pass the EOF on and keep
                        // reading: a request/response client half-closes first.
                        runCatching { channel.outputStream.close() }
                    } catch (_: Throwable) {
                        runCatching { channel.close() }
                    }
                },
            )
            try {
                copyFlushing(channel.inputStream, socket.getOutputStream())
            } catch (_: Throwable) {
                // Either side went away; both are closed below.
            } finally {
                runCatching { channel.close() }
                // Unblocks the upload's read if the client is still connected.
                runCatching { socket.close() }
                runCatching { upload.get() }
            }
        } catch (_: Throwable) {
            // The executor refused the upload task: the runtime is closing.
        } finally {
            mutableConnectionCount.update { (it - 1).coerceAtLeast(0) }
        }
    }

    /** Set once [close] has begun; a client accepted since has nowhere to go. */
    protected val isClosed: Boolean get() = closed.get()

    /**
     * Closes the listener and every client socket here and now — both are
     * local and immediate — and hands the SSH channels to the pool.
     *
     * SSHJ's channel close sends `CHANNEL_CLOSE` and then waits for the
     * server's reply for up to the transport timeout, 30 s. This is reached
     * under the manager's mutex and from `detachBlocking` on the main thread,
     * so on a stalled link a synchronous sweep would hold the mutex that long
     * and the main thread into an ANR.
     */
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        mutableOpen.value = false
        runCatching { serverSocket.close() }
        sockets.toList().forEach { runCatching { it.close() } }
        channels.toList().forEach(::closeInBackground)
        onClosed()
    }

    /**
     * The runtime shuts its pool down right after closing its leases, which
     * still runs a task submitted first; one refused after that gets a thread
     * of its own rather than a wait on the caller's.
     */
    private fun closeInBackground(channel: Closeable) {
        val task = Runnable { runCatching { channel.close() } }
        try {
            executor.execute(task)
        } catch (_: RejectedExecutionException) {
            Thread(task, "tessera-forward-channel-close").apply { isDaemon = true }.start()
        }
    }
}

/**
 * SSH `-L`: each accepted client becomes a direct-tcpip channel to [target].
 *
 * This replaces SSHJ's `LocalPortForwarder`, whose `listen()` rethrows the
 * `OpenFailException` of any one refused channel. A single browser request to
 * a tunnel whose remote service was not up yet therefore ended the listener,
 * and with it the rule, until the user restarted it. Here a refused open
 * closes that client alone; it also becomes passive service evidence.
 *
 * [openChannel] is a seam for tests; production opens an SSHJ
 * `DirectConnection` on the session's own client.
 */
internal class LocalForwardLease(
    bound: BoundForwardEndpoint,
    serverSocket: ServerSocket,
    private val target: PortForwardEndpoint,
    executor: ExecutorService,
    private val openChannel: (PortForwardEndpoint) -> ForwardingChannel,
    onClosed: () -> Unit,
) : LoopbackForwardingLease(bound, serverSocket, executor, onClosed) {
    // Replays the latest outcome so one landing before the manager subscribes
    // is not lost; never suspends a pool thread, since overflow drops the
    // oldest outcome instead.
    private val evidence = MutableSharedFlow<ForwardedServiceProbe>(
        replay = 1,
        extraBufferCapacity = EVIDENCE_BUFFER,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    override val serviceEvidence: Flow<ForwardedServiceProbe> = evidence.asSharedFlow()

    override fun serve(socket: Socket) {
        // Accepted as the lease closed: the channel would only be abandoned,
        // after costing the server a connect to the target.
        if (isClosed) return
        val channel = try {
            openChannel(target)
        } catch (error: Throwable) {
            evidence.tryEmit(classifyDirectOpenFailure(error))
            return
        }
        evidence.tryEmit(ForwardedServiceProbe.Serving)
        if (!adopt(channel)) return
        try {
            carry(socket, socket.getInputStream(), channel)
        } finally {
            abandon(channel)
        }
    }

    private companion object {
        const val EVIDENCE_BUFFER = 8
    }
}

/**
 * Copies until [input] ends, flushing every chunk. SSHJ's channel stream
 * buffers a whole SSH packet before sending, so an unflushed copy would hold a
 * small request — an HTTP GET — until the client gave up.
 */
internal fun copyFlushing(input: InputStream, output: OutputStream) {
    val buffer = ByteArray(COPY_BUFFER_BYTES)
    while (true) {
        val read = input.read(buffer)
        if (read < 0) return
        if (read == 0) continue
        output.write(buffer, 0, read)
        output.flush()
    }
}

/**
 * What a failed direct-tcpip open says about its target. Only the server's
 * own refusal reason is conclusive; timeouts and transport failures are not.
 */
internal fun classifyDirectOpenFailure(error: Throwable): ForwardedServiceProbe {
    var cause: Throwable? = error
    val seen = HashSet<Throwable>()
    while (cause != null && seen.add(cause)) {
        if (cause is OpenFailException) {
            return when (cause.reason) {
                OpenFailException.Reason.CONNECT_FAILED -> ForwardedServiceProbe.NotServing
                OpenFailException.Reason.ADMINISTRATIVELY_PROHIBITED -> ForwardedServiceProbe.Prohibited
                null -> ForwardedServiceProbe.Inconclusive("OpenFailException")
                else -> ForwardedServiceProbe.Inconclusive("open_failed_${cause.reason.name.lowercase()}")
            }
        }
        cause = cause.cause
    }
    return ForwardedServiceProbe.Inconclusive(error.javaClass.simpleName)
}

/**
 * A probe: open a channel through [open], [report] the verdict, and close
 * what opened. The verdict goes out before the close, which waits on the
 * server's reply: an open that succeeded has already answered. Never throws.
 */
internal fun probeDirectOpen(open: () -> Closeable, report: (ForwardedServiceProbe) -> Unit) {
    val channel = try {
        open()
    } catch (error: Throwable) {
        report(classifyDirectOpenFailure(error))
        return
    }
    report(ForwardedServiceProbe.Serving)
    runCatching { channel.close() }
}

/**
 * [probeDirectOpen] on [executor], answered within [deadlineMillis]: at the
 * deadline the probe is inconclusive, and the open carries on to its own end
 * on the pool thread, where anything that opens late is closed at once. A
 * pool that refuses the task belongs to a closed runtime. Never throws but
 * for cancellation.
 */
internal suspend fun probeDirectOpenWithin(
    deadlineMillis: Long,
    executor: Executor,
    open: () -> Closeable,
): ForwardedServiceProbe {
    val answer = CompletableDeferred<ForwardedServiceProbe>()
    try {
        executor.execute { probeDirectOpen(open) { answer.complete(it) } }
    } catch (_: RejectedExecutionException) {
        return ForwardedServiceProbe.Inconclusive("runtime_closed")
    }
    return withTimeoutOrNull(deadlineMillis) { answer.await() }
        ?: ForwardedServiceProbe.Inconclusive("timeout")
}

private const val COPY_BUFFER_BYTES = 32 * 1024
