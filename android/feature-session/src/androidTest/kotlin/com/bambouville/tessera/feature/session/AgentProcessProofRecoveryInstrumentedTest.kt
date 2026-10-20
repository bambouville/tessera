package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.networking.SshRouteOwner
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.InputStream
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import org.junit.Assert.*
import org.junit.Test

/** Real endpoint, exec adapter and blocking SSH readers; no network sockets. */
class AgentProcessProofRecoveryInstrumentedTest {
    @Test fun siblingPaneProofDoesNotWaitForAnotherPanesHelper(): Unit = runBlocking {
        val client = ProofClient(silentFirst = false)
        val route = route(client)
        val endpoint = endpoint(route, AgentEndpointTransport.SSH_TMUX)
        endpoint.updateActiveTmuxTarget(1, 2)
        @Suppress("UNCHECKED_CAST")
        val gate = SshAgentSessionEndpoint::class.java.getDeclaredField("execBindingGate").let {
            it.isAccessible = true; it.get(endpoint) as AgentExecBindingGate<AgentEndpointBinding>
        }
        val sibling = checkNotNull(gate.acquire(endpoint.binding.value))
        try {
            endpoint.updateActiveTmuxTarget(2, 3)
            assertTrue("A valid sibling pane must prove input while another pane's helper remains open", withTimeout(2_000) {
                endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX)
            } is AgentEndpointResult.Success)
            assertTrue(client.opened.isCompleted)
            assertTrue(route.isConnected)
            sibling.close()
            assertTrue(withTimeout(2_000) {
                endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX)
            } is AgentEndpointResult.Success)
        } finally { sibling.close(); endpoint.close(); route.close() }
    }

    @Test fun silentProofExpiresAndAnotherPaneCanReadAgain(): Unit = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val client = ProofClient()
            val route = route(client)
            val endpoint = endpoint(route, transport)
            var proof: Deferred<AgentEndpointResult<AgentProcessProof>>? = null
            try {
                endpoint.updateActiveTmuxTarget(1, 2)
                proof = async(Dispatchers.Default) { endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX) }
                withTimeout(2_000) { client.opened.await() }
                withContext(Dispatchers.IO) { assertTrue(client.readersBlocked.await(2, TimeUnit.SECONDS)) }
                val ended = withTimeoutOrNull(12_000) { proof.await() }
                assertEquals("An idle proof must expire without restarting Agent Center", AgentEndpointResult.Failed("proof_timeout"), ended)
                assertTrue("Deadline must close the blocked child before joining its readers", client.firstClosed.get())
                assertTrue("Child cancellation must preserve the established carrier", route.isConnected)
                endpoint.updateActiveTmuxTarget(2, 3)
                assertTrue("A sibling pane must acquire the released exec gate", withTimeout(2_000) {
                    endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX)
                } is AgentEndpointResult.Success)
            } finally {
                client.release.countDown()
                proof?.cancelAndJoin()
                endpoint.close(); route.close()
            }
        }
    }

    @Test fun cancellingSilentProofUnblocksReadersAndPreservesTheCarrier(): Unit = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH)) {
            val client = ProofClient()
            val route = route(client)
            val endpoint = endpoint(route, transport)
            var proof: Deferred<AgentEndpointResult<AgentProcessProof>>? = null
            try {
                proof = async(Dispatchers.Default) { endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX) }
                withTimeout(2_000) { client.opened.await() }
                withContext(Dispatchers.IO) { assertTrue(client.readersBlocked.await(2, TimeUnit.SECONDS)) }
                proof.cancel()
                assertEquals("Background cancellation must close the child before waiting for its readers", true,
                    withTimeoutOrNull(2_000) { proof.join(); true })
                assertTrue(client.firstClosed.get())
                assertTrue(route.isConnected)
                assertTrue(withTimeout(2_000) {
                    endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX)
                } is AgentEndpointResult.Success)
            } finally {
                client.release.countDown()
                proof?.cancelAndJoin()
                endpoint.close(); route.close()
            }
        }
    }

    private fun endpoint(route: SshRouteOwner, transport: AgentEndpointTransport) = SshAgentSessionEndpoint(
        AgentSessionKey("proof-recovery", 1), "fixture-host", transport, route = route,
        tmuxSession = if (transport.name.endsWith("TMUX")) "fixture-session" else null,
        routeMarker = "fixture-marker", processRootPID = { 101 },
        tmuxControl = TmuxAgentControlPort(directResponder = { AgentTmuxControlAck(true, listOf("101")) }),
    )

    private fun route(client: SSHClient): SshRouteOwner = SshRouteOwner::class.java.declaredConstructors.single {
        it.parameterTypes.size == 2
    }.also { it.isAccessible = true }.newInstance(client, emptyList<Closeable>()) as SshRouteOwner

    private class ProofClient(private val silentFirst: Boolean = true) : SSHClient() {
        val opened = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        val readersBlocked = CountDownLatch(3)
        val firstClosed = AtomicBoolean(false)
        private var opens = 0
        private val connected = AtomicBoolean(true)
        override fun isConnected() = connected.get()
        override fun isAuthenticated() = connected.get()
        override fun close() { connected.set(false) }
        override fun startSession(): Session {
            val first = opens++ == 0 && silentFirst
            val input = if (first) object : InputStream() {
                override fun read(): Int { readersBlocked.countDown(); release.await(); return -1 }
                override fun read(bytes: ByteArray, offset: Int, length: Int): Int { readersBlocked.countDown(); release.await(); return -1 }
            } else ByteArrayInputStream("""{"v":1,"valid":true,"provider":"codex","processIDs":[102],"processStart":"fixture-start"}""".encodeToByteArray())
            val errors = if (first) input else ByteArrayInputStream(byteArrayOf())
            val output = ByteArrayOutputStream()
            return Proxy.newProxyInstance(javaClass.classLoader, arrayOf(Session::class.java, Session.Command::class.java)) { proxy, method, arguments ->
                when (method.name) {
                    "exec" -> { opened.complete(Unit); proxy }
                    "close" -> { if (first) { firstClosed.set(true); release.countDown() }; null }
                    "getInputStream" -> input
                    "getErrorStream" -> errors
                    "getOutputStream" -> output
                    "getExitStatus" -> 0
                    "join" -> {
                        if (first) {
                            if (arguments.isNullOrEmpty()) { readersBlocked.countDown(); release.await() }
                            else release.await((arguments[0] as Number).toLong(), arguments[1] as TimeUnit)
                        }
                        null
                    }
                    "signal" -> null
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === arguments?.firstOrNull()
                    "toString" -> "fixture-proof-session"
                    else -> error("Unexpected SSH fixture call: ${method.name}")
                }
            } as Session
        }
    }
}
