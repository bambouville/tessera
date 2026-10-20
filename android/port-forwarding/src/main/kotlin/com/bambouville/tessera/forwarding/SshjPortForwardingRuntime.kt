package com.bambouville.tessera.forwarding

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.forwarded.RemotePortForwarder
import net.schmizz.sshj.connection.channel.forwarded.SocketForwardingConnectListener

/**
 * SSHJ-backed implementation. It owns listeners and direct channels, but never
 * owns [client]: the session controller must close this runtime before closing
 * the authenticated route/client that it supplied.
 */
class SshjPortForwardingRuntime(
    private val client: SSHClient,
    transport: ForwardingTransport = ForwardingTransport.Ssh,
    private val executor: ExecutorService = Executors.newCachedThreadPool(),
) : PortForwardingRuntime {
    override val capabilities: ForwardingCapabilities = ForwardingCapabilities.forTransport(transport)

    private val closed = AtomicBoolean(false)
    private val leases = ConcurrentHashMap.newKeySet<PortForwardingLease>()

    override suspend fun start(rule: PortForwardRule): PortForwardingLease {
        check(!closed.get()) { "Port forwarding runtime is closed" }
        return when (rule.direction) {
            PortForwardDirection.LOCAL -> startLocal(rule)
            PortForwardDirection.REMOTE -> startRemote(rule)
            PortForwardDirection.DYNAMIC -> startDynamic(rule)
        }
    }

    /**
     * A direct-tcpip open to [target], closed at once, and answered within
     * [PROBE_DEADLINE_MILLIS] as on iOS.
     *
     * The open runs on [executor] and is left to finish there rather than
     * interrupted. SSHJ keeps a channel attached to the connection from the
     * moment it asks the server for it, and neither an interrupt nor SSHJ's
     * own open timeout detaches it: a confirmation arriving after either
     * leaves the channel open on both ends until the connection ends. Left
     * running, a late open is closed by [probeDirectOpen] like any other.
     *
     * So each probe can hold a pool thread for up to SSHJ's open timeout
     * plus its close wait, 30 s each; the manager's one probe in flight per
     * rule bounds how many do.
     */
    override suspend fun probe(target: PortForwardEndpoint): ForwardedServiceProbe {
        if (closed.get()) return ForwardedServiceProbe.Inconclusive("runtime_closed")
        return probeDirectOpenWithin(PROBE_DEADLINE_MILLIS, executor) {
            client.newDirectConnection(target.host, target.port)
        }
    }

    private fun startLocal(rule: PortForwardRule): PortForwardingLease {
        val target = checkNotNull(rule.target)
        val socket = loopbackServerSocket(rule.bind)
        lateinit var lease: LocalForwardLease
        lease = LocalForwardLease(
            bound = BoundForwardEndpoint(rule.bind.host, socket.localPort),
            serverSocket = socket,
            target = target,
            executor = executor,
            openChannel = { endpoint ->
                client.newDirectConnection(endpoint.host, endpoint.port).asForwardingChannel()
            },
            onClosed = { leases.remove(lease) },
        )
        leases += lease
        try {
            lease.start()
        } catch (error: Throwable) {
            lease.close()
            throw error
        }
        return lease
    }

    private fun startRemote(rule: PortForwardRule): PortForwardingLease {
        val target = checkNotNull(rule.target)
        val requested = RemotePortForwarder.Forward(rule.bind.host, rule.bind.port)
        val bound = client.remotePortForwarder.bind(
            requested,
            SocketForwardingConnectListener(InetSocketAddress(target.host, target.port)),
        )
        return managedLease(bound.address, bound.port) {
            runCatching { client.remotePortForwarder.cancel(bound) }
        }
    }

    private fun startDynamic(rule: PortForwardRule): PortForwardingLease {
        val socket = loopbackServerSocket(rule.bind)
        lateinit var lease: DynamicSocksLease
        lease = DynamicSocksLease(
            bound = BoundForwardEndpoint(rule.bind.host, socket.localPort),
            serverSocket = socket,
            client = client,
            executor = executor,
            onClosed = { leases.remove(lease) },
        )
        leases += lease
        try {
            lease.start()
        } catch (error: Throwable) {
            lease.close()
            throw error
        }
        return lease
    }

    private fun loopbackServerSocket(bind: PortForwardEndpoint): ServerSocket = ServerSocket().apply {
        reuseAddress = true
        bind(InetSocketAddress(InetAddress.getByName(bind.host), bind.port))
    }

    private fun managedLease(host: String, port: Int, closeAction: () -> Unit): ManagedLease {
        lateinit var lease: ManagedLease
        lease = ManagedLease(BoundForwardEndpoint(host, port)) {
            closeAction()
            leases.remove(lease)
        }
        leases += lease
        return lease
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        leases.toList().forEach { it.close() }
        // Not shutdownNow(): closing the leases above already unblocks every
        // accept and copy, and interrupting a thread inside an SSHJ channel
        // open abandons a channel the server may still confirm. An open in
        // flight finishes within SSHJ's timeout and finds its lease closed,
        // and the channel closes the leases just handed over still run.
        executor.shutdown()
    }

    private companion object {
        /** iOS `ForwardedServiceCadence.timeout`: no answer by then says nothing. */
        const val PROBE_DEADLINE_MILLIS = 8_000L
    }
}

private class ManagedLease(
    override val bound: BoundForwardEndpoint,
    private val closeAction: () -> Unit,
) : PortForwardingLease {
    private val closed = AtomicBoolean(false)
    private val mutableConnectionCount = MutableStateFlow(0)
    private val mutableOpen = MutableStateFlow(true)

    override val activeConnectionCount: StateFlow<Int> = mutableConnectionCount
    override val isOpen: StateFlow<Boolean> = mutableOpen

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            mutableOpen.value = false
            closeAction()
        }
    }
}

/** Minimal loopback-only SOCKS5 CONNECT implementation for SSH `-D`. */
private class DynamicSocksLease(
    bound: BoundForwardEndpoint,
    serverSocket: ServerSocket,
    private val client: SSHClient,
    executor: ExecutorService,
    onClosed: () -> Unit,
) : LoopbackForwardingLease(bound, serverSocket, executor, onClosed) {
    override fun serve(socket: Socket) {
        var output: BufferedOutputStream? = null
        var connected = false
        var channel: ForwardingChannel? = null
        try {
            val input = DataInputStream(BufferedInputStream(socket.getInputStream()))
            val bufferedOutput = BufferedOutputStream(socket.getOutputStream())
            output = bufferedOutput
            negotiate(input, bufferedOutput)
            val destination = readConnectRequest(input)
            val opened = client.newDirectConnection(destination.host, destination.port).asForwardingChannel()
            channel = opened
            if (!adopt(opened)) return
            writeReply(bufferedOutput, SocksReply.SUCCEEDED)
            bufferedOutput.flush()
            connected = true
            // `input`, not the raw socket stream: the handshake's buffer may
            // already hold the client's first bytes.
            carry(socket, input, opened)
        } catch (failure: SocksFailure) {
            if (!failure.replied) writeFailureReply(output)
        } catch (_: Throwable) {
            // Never let an individual SOCKS client kill the listener. Before a
            // successful CONNECT, provide a protocol-level failure when possible.
            if (!connected) writeFailureReply(output)
        } finally {
            channel?.let(::abandon)
        }
    }

    private fun negotiate(input: DataInputStream, output: BufferedOutputStream) {
        if (input.readUnsignedByte() != SOCKS_VERSION) throw SocksFailure()
        val methodCount = input.readUnsignedByte()
        val methods = ByteArray(methodCount)
        input.readFully(methods)
        if (NO_AUTH.toByte() !in methods) {
            output.write(byteArrayOf(SOCKS_VERSION.toByte(), NO_ACCEPTABLE_AUTH.toByte()))
            output.flush()
            throw SocksFailure(replied = true)
        }
        output.write(byteArrayOf(SOCKS_VERSION.toByte(), NO_AUTH.toByte()))
        output.flush()
    }

    private fun readConnectRequest(input: DataInputStream): PortForwardEndpoint {
        if (input.readUnsignedByte() != SOCKS_VERSION) throw SocksFailure()
        val command = input.readUnsignedByte()
        input.readUnsignedByte() // reserved
        val host = when (input.readUnsignedByte()) {
            ADDRESS_IPV4 -> {
                val address = ByteArray(4)
                input.readFully(address)
                InetAddress.getByAddress(address).hostAddress
            }
            ADDRESS_DOMAIN -> {
                val address = ByteArray(input.readUnsignedByte())
                input.readFully(address)
                address.decodeToString()
            }
            ADDRESS_IPV6 -> {
                val address = ByteArray(16)
                input.readFully(address)
                InetAddress.getByAddress(address).hostAddress
            }
            else -> throw SocksFailure()
        }
        val port = input.readUnsignedShort()
        if (command != CONNECT) throw SocksFailure()
        return PortForwardEndpoint(host, port)
    }

    private fun writeReply(output: BufferedOutputStream, reply: Int) {
        output.write(byteArrayOf(SOCKS_VERSION.toByte(), reply.toByte(), 0, ADDRESS_IPV4.toByte(), 0, 0, 0, 0, 0, 0))
    }

    private fun writeFailureReply(output: BufferedOutputStream?) {
        runCatching {
            output ?: return
            writeReply(output, SocksReply.GENERAL_FAILURE)
            output.flush()
        }
    }

    private class SocksFailure(val replied: Boolean = false) : Exception()

    private object SocksReply {
        const val SUCCEEDED = 0
        const val GENERAL_FAILURE = 1
    }

    private companion object {
        const val SOCKS_VERSION = 5
        const val NO_AUTH = 0
        const val NO_ACCEPTABLE_AUTH = 0xff
        const val CONNECT = 1
        const val ADDRESS_IPV4 = 1
        const val ADDRESS_DOMAIN = 3
        const val ADDRESS_IPV6 = 4
    }
}
