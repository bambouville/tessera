package com.bambouville.tessera.networking

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.OpenFailException
import net.schmizz.sshj.connection.channel.direct.Session
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SshRouteOwnerCancellationTest {
    @Test(timeout = 10_000)
    fun cancellingBlockedExecOpenClosesUnclaimedChannelAndPreservesSibling() = runBlocking {
        val client = BlockingSessionClient()
        val owner = SshRouteOwner(client, listOf(client))
        try {
            val sibling = owner.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL))
            repeat(12) {
                client.blockNextOpen()
                val opening = launch { owner.execute(SshExecRequest(SshRemoteOperation.AGENT_HOST)) }
                withTimeout(2_000) { client.openStarted.await() }
                opening.cancel()
                client.finishOpen.countDown()
                opening.join()
                assertEquals("cancelled open retained a remote session", 1, client.activeSessions.get())
                assertEquals("route retained an unclaimed exec", 1, owner.activeExecChannels)
                assertFalse("cancelling exec closed its shared route", client.clientClosed.get())
            }
            sibling.close()
            assertEquals(0, client.activeSessions.get())
            owner.execute(SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL)).close()
            assertEquals(0, client.activeSessions.get())
        } finally {
            client.finishOpen.countDown()
            owner.close()
        }
    }

    @Test
    fun channelRejectionDiagnosticsContainOnlyKnownReason() {
        assertEquals(
            "OpenFailException:RESOURCE_SHORTAGE",
            sshExecFailureCode(OpenFailException("private-channel", OpenFailException.Reason.RESOURCE_SHORTAGE,
                "private command, host, and path")),
        )
    }

    @Test
    fun serverPolicyRejectionDoesNotTriggerReauthentication() {
        for (reason in OpenFailException.Reason.entries) {
            assertEquals(
                reason == OpenFailException.Reason.RESOURCE_SHORTAGE || reason == OpenFailException.Reason.CONNECT_FAILED,
                sshExecFailureNeedsNewRoute(OpenFailException("session", reason, "remote text")),
            )
        }
    }

    @Test(timeout = 10_000)
    fun successfulOpenRemainsOwnedByCaller() = runBlocking {
        val client = BlockingSessionClient()
        SshRouteOwner(client, listOf(client)).use { owner ->
            val stream = owner.execute(SshExecRequest(SshRemoteOperation.AGENT_HOST))
            assertEquals(1, client.activeSessions.get())
            stream.close()
            stream.close()
            assertEquals(0, client.activeSessions.get())
        }
    }

    @Test(timeout = 10_000)
    fun retiringRouteClosesTransportBeforeWaitingForChildren() = runBlocking {
        val client = BlockingSessionClient()
        val owner = SshRouteOwner(client, listOf(client))
        owner.execute(SshExecRequest(SshRemoteOperation.AGENT_HOST))
        owner.execute(SshExecRequest(SshRemoteOperation.AGENT_PROVE))
        owner.close()
        assertTrue(client.clientClosed.get())
        assertEquals(0, client.activeSessions.get())
        assertEquals(0, client.childrenClosedBeforeTransport.get())
    }

    private class BlockingSessionClient : SSHClient() {
        val activeSessions = AtomicInteger()
        val clientClosed = AtomicBoolean()
        val childrenClosedBeforeTransport = AtomicInteger()
        var openStarted = CompletableDeferred<Unit>()
        var finishOpen = CountDownLatch(0)

        fun blockNextOpen() {
            openStarted = CompletableDeferred()
            finishOpen = CountDownLatch(1)
        }

        override fun startSession(): Session {
            openStarted.complete(Unit)
            assertTrue("blocked fake SSH open was not released", finishOpen.await(2, TimeUnit.SECONDS))
            activeSessions.incrementAndGet()
            val closed = AtomicBoolean()
            val input = ByteArrayInputStream(byteArrayOf())
            val output = ByteArrayOutputStream()
            return Proxy.newProxyInstance(
                javaClass.classLoader,
                arrayOf(Session::class.java, Session.Command::class.java),
            ) { proxy, method, arguments ->
                when (method.name) {
                    "exec" -> proxy
                    "close" -> {
                        if (closed.compareAndSet(false, true)) {
                            if (!clientClosed.get()) childrenClosedBeforeTransport.incrementAndGet()
                            activeSessions.decrementAndGet()
                        }
                        null
                    }
                    "getInputStream", "getErrorStream" -> input
                    "getOutputStream" -> output
                    "join" -> null
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === arguments?.firstOrNull()
                    "toString" -> "fake-ssh-session"
                    else -> error("Unexpected fake SSH call: ${method.name}")
                }
            } as Session
        }

        override fun close() { clientClosed.set(true) }
    }
}
