package com.bambouville.tessera.networking

import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import com.bambouville.tessera.forwarding.ForwardingTransport
import com.bambouville.tessera.forwarding.PortForwardingRuntime
import com.bambouville.tessera.forwarding.SshjPortForwardingRuntime
import net.schmizz.sshj.SSHClient

/**
 * Narrow capability handed to session code after route authentication. It
 * intentionally exposes forwarding runtimes only, never the underlying
 * SSHClient or its credential/authentication state.
 */
class AuthenticatedForwardingRuntimeFactory internal constructor(
    private val client: SSHClient,
) {
    fun create(transport: ForwardingTransport = ForwardingTransport.Ssh): PortForwardingRuntime {
        check(client.isConnected && client.isAuthenticated) { "authenticated SSH route is unavailable" }
        return SshjPortForwardingRuntime(client, transport)
    }
}

/**
 * An authenticated route retained solely for Mosh forwarding. Closing this
 * object first closes its listeners, then the SSH jump-chain resources.
 */
class AuthenticatedForwardingSideChannel internal constructor(
    client: SSHClient,
    private val resources: List<Closeable>,
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val factory = AuthenticatedForwardingRuntimeFactory(client)
    private var runtime: PortForwardingRuntime? = null

    @Synchronized
    fun runtime(): PortForwardingRuntime {
        check(!closed.get()) { "forwarding side channel is closed" }
        return runtime ?: factory.create(ForwardingTransport.Mosh(sshSideChannelAvailable = true)).also {
            runtime = it
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { runtime?.close() }
        resources.asReversed().forEach { resource -> runCatching { resource.close() } }
    }
}
