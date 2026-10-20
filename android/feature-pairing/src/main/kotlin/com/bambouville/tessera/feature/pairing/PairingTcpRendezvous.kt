package com.bambouville.tessera.feature.pairing

import java.io.Closeable
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Raw local-TCP adapter. It carries only concatenated shared-core TPR1 bytes. */
internal class PairingTcpRendezvous(
    private val scope: CoroutineScope,
    private val onBytes: (ByteArray) -> Unit,
    private val onEof: () -> Unit,
    private val onFailure: (Throwable) -> Unit,
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val peerAdmitted = AtomicBoolean(false)
    private var server: ServerSocket? = null
    private var socket: Socket? = null
    private var acceptJob: Job? = null
    private var readJob: Job? = null
    private var connectJob: Job? = null
    private val attachedSocket = CompletableDeferred<Socket>()
    private data class PendingWrite(
        val bytes: ByteArray,
        val completion: CompletableDeferred<Unit>,
    )

    private val writes = Channel<PendingWrite>(capacity = 64)
    private val writeJob = scope.launch(Dispatchers.IO) {
        var activePending: PendingWrite? = null
        try {
            for (pending in writes) {
                activePending = pending
                val active = attachedSocket.await()
                active.getOutputStream().write(pending.bytes)
                active.getOutputStream().flush()
                pending.completion.complete(Unit)
                activePending = null
            }
        } catch (failure: Throwable) {
            activePending?.completion?.completeExceptionally(failure)
            while (true) {
                val pending = writes.tryReceive().getOrNull() ?: break
                pending.completion.completeExceptionally(failure)
            }
            if (failure is CancellationException) return@launch
            if (!closed.get()) onFailure(failure)
        }
    }

    fun listen(): List<Endpoint> {
        check(server == null) { "listener already created" }
        val listener = ServerSocket(0, 1)
        server = listener
        acceptJob = scope.launch(Dispatchers.IO) {
            try {
                val accepted = listener.accept()
                if (!peerAdmitted.compareAndSet(false, true)) {
                    accepted.close()
                    return@launch
                }
                attach(accepted)
            } catch (failure: Throwable) {
                if (!closed.get()) onFailure(failure)
            }
        }
        return localAddresses().take(MAX_ENDPOINTS).mapNotNull { address ->
            address.hostAddress?.let { Endpoint(it, listener.localPort) }
        }
    }

    fun connect(host: String, port: Int) {
        check(socket == null) { "peer already connected" }
        connectJob = scope.launch(Dispatchers.IO) {
            try {
                val connected = Socket()
                socket = connected
                connected.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT_MILLISECONDS)
                if (!peerAdmitted.compareAndSet(false, true)) {
                    connected.close()
                    return@launch
                }
                attach(connected)
            } catch (failure: Throwable) {
                if (failure is CancellationException) return@launch
                if (!closed.get()) onFailure(failure)
            }
        }
    }

    /** Try advertised interfaces in order; a stale VPN/interface must not poison a valid offer. */
    fun connectCandidates(candidates: List<Endpoint>) {
        check(socket == null) { "peer already connected" }
        connectJob = scope.launch(Dispatchers.IO) {
            var lastFailure: Throwable? = null
            for (candidate in candidates.take(MAX_ENDPOINTS)) {
                if (closed.get()) return@launch
                val pending = Socket()
                socket = pending // close() can interrupt the bounded connect.
                try {
                    pending.connect(InetSocketAddress(candidate.host, candidate.port), CONNECT_TIMEOUT_MILLISECONDS)
                    if (!peerAdmitted.compareAndSet(false, true)) { pending.close(); return@launch }
                    attach(pending)
                    return@launch
                } catch (failure: Throwable) {
                    pending.close()
                    lastFailure = failure
                    if (failure is CancellationException) return@launch
                }
            }
            if (!closed.get()) onFailure(lastFailure ?: IllegalStateException("No TCP endpoint candidates"))
        }
    }

    suspend fun write(record: ByteArray) {
        require(record.isNotEmpty())
        check(!closed.get()) { "pairing transport is closed" }
        val completion = CompletableDeferred<Unit>()
        writes.send(PendingWrite(record.copyOf(), completion))
        completion.await()
    }

    private suspend fun attach(connected: Socket) {
        withContext(Dispatchers.IO) {
            if (closed.get()) {
                connected.close()
                return@withContext
            }
            socket = connected
            attachedSocket.complete(connected)
            server?.close()
            server = null
            readJob = scope.launch(Dispatchers.IO) {
                val buffer = ByteArray(16 * 1024)
                try {
                    val input = connected.getInputStream()
                    while (!closed.get()) {
                        val count = input.read(buffer)
                        if (count < 0) {
                            onEof()
                            break
                        }
                        if (count > 0) onBytes(buffer.copyOf(count))
                    }
                } catch (failure: Throwable) {
                    if (failure is CancellationException) return@launch
                    if (!closed.get()) onFailure(failure)
                }
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { server?.close() }
        runCatching { socket?.close() }
        attachedSocket.cancel()
        writes.close()
        acceptJob?.cancel()
        readJob?.cancel()
        connectJob?.cancel()
        writeJob.cancel()
    }

    data class Endpoint(val host: String, val port: Int)

    private companion object {
        const val MAX_ENDPOINTS = 8
        const val CONNECT_TIMEOUT_MILLISECONDS = 10_000
    }

    private fun localAddresses(): List<InetAddress> = NetworkInterface.getNetworkInterfaces()
        .toList()
        .filter { it.isUp && !it.isLoopback && !it.isVirtual }
        .flatMap { it.inetAddresses.toList() }
        .filter { it is Inet4Address && !it.isLoopbackAddress && !it.isLinkLocalAddress }
        .ifEmpty { listOf(InetAddress.getLoopbackAddress()) }
}
