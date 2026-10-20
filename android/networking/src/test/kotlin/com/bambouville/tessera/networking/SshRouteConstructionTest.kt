package com.bambouville.tessera.networking

import java.io.Closeable
import java.io.InterruptedIOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SshRouteConstructionTest {
    @Test(timeout = 30_000)
    fun abandoningUnblocksAHandshakeWaitingOnASilentServer() = runBlocking {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val accepted = CompletableDeferred<Socket>()
            thread(isDaemon = true) { runCatching { accepted.complete(server.accept()) } }
            val construction = SshRouteConstruction()
            val opening = async(Dispatchers.IO) {
                runCatching {
                    AndroidSshBackend().openRoute(
                        request = SshRouteRequest(
                            listOf(
                                SshRouteHop(
                                    id = "silent",
                                    endpoint = SshEndpoint("127.0.0.1", server.localPort),
                                    username = "probe",
                                    authentication = SshAuthentication.Password,
                                ),
                            ),
                        ),
                        passwordProvider = SshPasswordProvider { error("a silent server never asks") },
                        hostKeyPolicy = SshHostKeyPolicy { false },
                        construction = construction,
                    )
                }
            }
            val socket = withTimeout(10_000) { accepted.await() }
            try {
                // TCP is up and the server says nothing: SSHJ now waits for
                // its identification line with no read timeout.
                delay(1_000)
                assertFalse("a silent server must hold the handshake", opening.isCompleted)
                construction.abandon()
                val result = withTimeout(5_000) { opening.await() }
                assertTrue("an abandoned handshake must fail, not produce a route", result.isFailure)
            } finally {
                socket.close()
            }
        }
    }

    @Test(timeout = 30_000)
    fun abandoningBeforeTheFirstSocketStopsTheRouteBeforeItConnects() = runBlocking<Unit> {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            server.soTimeout = 1_500
            val construction = SshRouteConstruction()
            construction.abandon()
            val result = withTimeout(5_000) {
                async(Dispatchers.IO) {
                    runCatching {
                        AndroidSshBackend().openRoute(
                            request = SshRouteRequest(
                                listOf(
                                    SshRouteHop(
                                        id = "silent",
                                        endpoint = SshEndpoint("127.0.0.1", server.localPort),
                                        username = "probe",
                                        authentication = SshAuthentication.Password,
                                    ),
                                ),
                            ),
                            passwordProvider = SshPasswordProvider { error("never asked") },
                            hostKeyPolicy = SshHostKeyPolicy { false },
                            construction = construction,
                        )
                    }
                }.await()
            }
            assertTrue(result.isFailure)
            assertThrows("an abandoned route must not dial the host", SocketTimeoutException::class.java) {
                server.accept().close()
            }
        }
    }

    @Test
    fun aSocketAbandonedBeforeItConnectsCannotConnect() {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val construction = SshRouteConstruction()
            val socket = construction.socketFactory().createSocket()
            construction.abandon()
            assertTrue(socket.isClosed)
            assertThrows(SocketException::class.java) {
                socket.connect(InetSocketAddress(InetAddress.getLoopbackAddress(), server.localPort), 1_000)
            }
            assertThrows(InterruptedIOException::class.java) { construction.socketFactory().createSocket() }
        }
    }

    @Test
    fun aResourceBuiltAfterAbandonmentIsClosedAndRefused() {
        val construction = SshRouteConstruction()
        val first = CountingCloseable()
        construction.adopt(first)
        construction.abandon()
        assertEquals(1, first.closes.get())
        val late = CountingCloseable()
        assertThrows(InterruptedIOException::class.java) { construction.adopt(late) }
        assertEquals(1, late.closes.get())
        construction.abandon()
        assertEquals("abandoning twice closes nothing twice", 1, first.closes.get())
    }

    @Test
    fun aReturnedRouteKeepsItsResources() {
        val construction = SshRouteConstruction()
        val client = CountingCloseable()
        construction.adopt(client)
        construction.release()
        construction.abandon()
        assertEquals(0, client.closes.get())
    }

    private class CountingCloseable : Closeable {
        val closes = AtomicInteger()
        override fun close() {
            closes.incrementAndGet()
        }
    }
}
