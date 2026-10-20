package com.bambouville.tessera.networking

import java.io.Closeable
import java.io.InterruptedIOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.SocketFactory

/**
 * Lets a caller abandon a route that [AndroidSshBackend.openRoute] is still
 * building.
 *
 * SSHJ reads the server's identification line synchronously inside
 * `connect`, with no read timeout (interactive sessions must be able to idle),
 * so a server that accepts TCP and never answers holds the building thread
 * indefinitely and coroutine cancellation cannot reach it. Closing what was
 * built so far is what unblocks that read. Each direct hop's socket belongs to
 * the construction from the moment it exists ([socketFactory]), so there is no
 * window in which a socket can connect unowned; once abandoned, nothing new is
 * built. Once the route is returned its [SshRouteOwner] owns everything, and
 * abandoning no longer touches it.
 */
class SshRouteConstruction {
    private val lock = Any()
    private val resources = mutableListOf<Closeable>()
    private var abandoned = false
    private var released = false

    /** Closes everything built so far, and anything built after. Blocking: call it off the main thread. */
    fun abandon() {
        val retired = synchronized(lock) {
            if (abandoned || released) return
            abandoned = true
            resources.toList().also { resources.clear() }
        }
        retired.asReversed().forEach { runCatching { it.close() } }
    }

    /** Takes [resource]; after abandonment closes it and refuses, so the build stops here. */
    internal fun adopt(resource: Closeable) {
        val refused = synchronized(lock) {
            if (!abandoned) resources += resource
            abandoned
        }
        if (refused) {
            runCatching { resource.close() }
            throw InterruptedIOException("SSH route abandoned")
        }
    }

    /** Unconnected sockets that this construction owns before SSHJ connects them. */
    internal fun socketFactory(): SocketFactory = object : SocketFactory() {
        override fun createSocket(): Socket = Socket().also { adopt(it) }

        override fun createSocket(host: String?, port: Int): Socket =
            createSocket().apply { connect(InetSocketAddress(host, port)) }

        override fun createSocket(host: String?, port: Int, localHost: InetAddress?, localPort: Int): Socket =
            createSocket().apply {
                bind(InetSocketAddress(localHost, localPort))
                connect(InetSocketAddress(host, port))
            }

        override fun createSocket(host: InetAddress?, port: Int): Socket =
            createSocket().apply { connect(InetSocketAddress(host, port)) }

        override fun createSocket(address: InetAddress?, port: Int, localAddress: InetAddress?, localPort: Int): Socket =
            createSocket().apply {
                bind(InetSocketAddress(localAddress, localPort))
                connect(InetSocketAddress(address, port))
            }
    }

    /** The route was returned: its owner closes these now. */
    internal fun release() = synchronized(lock) {
        released = true
        resources.clear()
    }
}
