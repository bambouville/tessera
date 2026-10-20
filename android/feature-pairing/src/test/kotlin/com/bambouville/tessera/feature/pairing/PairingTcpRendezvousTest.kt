package com.bambouville.tessera.feature.pairing

import java.io.ByteArrayOutputStream
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingTcpRendezvousTest {
    @Test
    fun queuedWritesStayOrderedAndCloseDeliversBeforeEof() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val received = ByteArrayOutputStream()
        val receivedLatch = CountDownLatch(1)
        val eofLatch = CountDownLatch(1)
        val failures = mutableListOf<Throwable>()
        val server = PairingTcpRendezvous(scope, {}, {}, failures::add)
        val client = PairingTcpRendezvous(
            scope,
            onBytes = { bytes ->
                synchronized(received) {
                    received.write(bytes)
                    if (received.size() >= 6) receivedLatch.countDown()
                }
            },
            onEof = eofLatch::countDown,
            onFailure = failures::add,
        )
        try {
            val live = server.listen().first()
            val closedPort = ServerSocket(0).use { it.localPort }
            val writer = scope.launch {
                server.write(byteArrayOf(1, 2, 3))
                server.write(byteArrayOf(4, 5, 6))
            }
            client.connectCandidates(listOf(PairingTcpRendezvous.Endpoint("127.0.0.1", closedPort), live))
            assertTrue("ordered bytes timed out", receivedLatch.await(15, TimeUnit.SECONDS))
            writer.join()
            assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5, 6), synchronized(received) { received.toByteArray() })
            server.close()
            assertTrue("EOF timed out", eofLatch.await(5, TimeUnit.SECONDS))
            assertTrue(failures.toString(), failures.isEmpty())
        } finally {
            client.close()
            server.close()
            scope.cancel()
        }
    }

    @Test
    fun closeCancelsAPendingConnectionWithoutReportingTransportFailure() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val failureLatch = CountDownLatch(1)
        val client = PairingTcpRendezvous(scope, {}, {}, { failureLatch.countDown() })
        try {
            client.connect("192.0.2.1", 65000)
            client.close()
            assertFalse(failureLatch.await(500, TimeUnit.MILLISECONDS))
        } finally {
            client.close()
            scope.cancel()
        }
    }
}
