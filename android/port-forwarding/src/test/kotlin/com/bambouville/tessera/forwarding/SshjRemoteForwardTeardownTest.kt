package com.bambouville.tessera.forwarding

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.Connection
import net.schmizz.sshj.connection.channel.forwarded.ConnectListener
import net.schmizz.sshj.connection.channel.forwarded.RemotePortForwarder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * An `-R` cancel waits for the server's reply. Session teardown retires the
 * runtime on Main, so on a stalled link it froze the UI for SSHJ's 30 s
 * timeout; stopping one rule must still cancel before it returns.
 */
class SshjRemoteForwardTeardownTest {
    private val rule = PortForwardRule(
        direction = PortForwardDirection.REMOTE,
        bind = PortForwardEndpoint("127.0.0.1", 9000),
        target = PortForwardEndpoint("localhost", 3000),
    )

    @Test(timeout = 10_000)
    fun retiringTheRuntimeDoesNotWaitForAStalledCancel() = runBlocking {
        val client = RemoteForwardClient(stallCancel = true)
        val runtime = SshjPortForwardingRuntime(client)
        runtime.start(rule)

        val started = System.nanoTime()
        runtime.close()
        val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)

        assertTrue("teardown waited ${elapsedMillis} ms for the cancel", elapsedMillis < 1_000)
        assertTrue("the cancel was never sent", client.forwarder.cancelStarted.await(2, TimeUnit.SECONDS))
        client.forwarder.release.countDown()
    }

    @Test(timeout = 10_000)
    fun stoppingOneRuleCancelsBeforeItReturns() = runBlocking {
        val client = RemoteForwardClient(stallCancel = false)
        val runtime = SshjPortForwardingRuntime(client)
        val lease = runtime.start(rule)

        lease.close()

        assertEquals(1, client.forwarder.cancels.get())
        runtime.close()
        assertEquals("a closed lease cancelled twice", 1, client.forwarder.cancels.get())
    }

    private class RemoteForwardClient(stallCancel: Boolean) : SSHClient() {
        val forwarder = FakeRemoteForwarder(connection, stallCancel)

        override fun getRemotePortForwarder(): RemotePortForwarder = forwarder
    }

    private class FakeRemoteForwarder(
        connection: Connection,
        private val stallCancel: Boolean,
    ) : RemotePortForwarder(connection) {
        val cancels = AtomicInteger()
        val cancelStarted = CountDownLatch(1)
        val release = CountDownLatch(1)

        override fun bind(forward: Forward, listener: ConnectListener): Forward = forward

        override fun cancel(forward: Forward) {
            cancelStarted.countDown()
            if (stallCancel) release.await(30, TimeUnit.SECONDS)
            cancels.incrementAndGet()
        }
    }
}
