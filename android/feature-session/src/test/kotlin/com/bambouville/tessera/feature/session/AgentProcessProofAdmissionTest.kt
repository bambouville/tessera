package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.networking.SshRouteOwner
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.lang.reflect.Proxy
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Real input endpoint; independent fake exec channels, no network. */
class AgentProcessProofAdmissionTest {
    @Test fun retiredEndpointCannotOpenAProofAfterWaitingForAChannel(): Unit = runBlocking {
        val client = ProofClient()
        val route = route(client)
        val endpoint = endpoint(route, AgentEndpointTransport.MOSH_TMUX)
        endpoint.updateActiveTmuxTarget(1, 2)
        val channels = SshAgentSessionEndpoint::class.java.getDeclaredField("execChannels").let {
            it.isAccessible = true; it.get(endpoint) as kotlinx.coroutines.sync.Semaphore
        }
        val permits = channels.availablePermits
        repeat(permits) { channels.acquire() }
        val proof = async(start = CoroutineStart.UNDISPATCHED) {
            endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX)
        }
        try {
            assertFalse(proof.isCompleted)
            endpoint.close()
            channels.release()
            assertEquals(AgentEndpointResult.StaleBinding, withTimeout(2_000) { proof.await() })
            assertFalse("Retired input target must never open a child", client.opened.isCompleted)
        } finally {
            repeat(permits - 1) { channels.release() }
            proof.cancelAndJoin(); endpoint.close(); route.close()
        }
    }

    @Test fun siblingPaneProofDoesNotWaitForAnotherPanesHelper(): Unit = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val client = ProofClient()
            val route = route(client)
            val endpoint = endpoint(route, transport)
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
    }

    @Test fun onlyActionProofRequestsRequireForeground(): Unit = runBlocking {
        for (transport in AgentEndpointTransport.entries) {
            val client = ProofClient()
            val route = route(client)
            val endpoint = endpoint(route, transport)
            if (transport.name.endsWith("TMUX")) endpoint.updateActiveTmuxTarget(1, 2)
            try {
                assertTrue(endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX) is AgentEndpointResult.Success)
                assertTrue(endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX, requireForeground = true) is AgentEndpointResult.Success)
                assertTrue(endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX, requireForeground = false) is AgentEndpointResult.Success)
                val requests = client.requests.map { JSONObject(it.toByteArray().decodeToString()) }
                assertEquals(3, requests.size)
                assertFalse(requests[0].has("requireForeground"))
                assertTrue(requests[1].getBoolean("requireForeground"))
                assertFalse(requests[2].has("requireForeground"))
                assertTrue(requests.all { it.getInt("claimedPID") == 102 && it.getString("provider") == "codex" })
            } finally { endpoint.close(); route.close() }
        }
    }

    @Test fun refusedProofCarriesTheHelpersReasonWithItsExitStatus(): Unit = runBlocking {
        val cases = listOf(
            Triple("""{"v":1,"valid":false,"error":"unrelatedProcess"}""", 1, "unrelatedProcess"),
            Triple("""{"v":1,"valid":false,"error":"backgroundProcess"}""", 1, "backgroundProcess"),
            Triple("""{"v":1,"valid":false,"error":"processIdentityUnavailable"}""", 1, "processIdentityUnavailable"),
            Triple("""{"v":1,"valid":false,"error":"unsupported"}""", 69, "unsupported"),
            Triple("""{"v":1,"valid":true,"error":"unrelatedProcess"}""", 1, null),
            Triple("""{"v":2,"valid":false,"error":"unrelatedProcess"}""", 1, null),
            Triple("""{"v":1,"valid":false,"error":"bad reason"}""", 1, null),
            Triple("Traceback (most recent call last):", 1, null),
        )
        for ((stdout, exit, reason) in cases) {
            val route = route(ProofClient(stdout, exit))
            val endpoint = endpoint(route, AgentEndpointTransport.SSH_TMUX)
            endpoint.updateActiveTmuxTarget(1, 2)
            try {
                assertEquals(stdout, AgentEndpointResult.Failed("proof_exit_$exit", proofReason = reason),
                    withTimeout(2_000) { endpoint.proveProcess(endpoint.binding.value, 102, AgentProofProvider.CODEX) })
            } finally { endpoint.close(); route.close() }
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

    private class ProofClient(
        private val stdout: String = """{"v":1,"valid":true,"provider":"codex","processIDs":[102],"processStart":"fixture-start"}""",
        private val exit: Int = 0,
    ) : SSHClient() {
        val opened = CompletableDeferred<Unit>()
        val requests = CopyOnWriteArrayList<ByteArrayOutputStream>()
        private val connected = AtomicBoolean(true)
        override fun isConnected() = connected.get()
        override fun isAuthenticated() = connected.get()
        override fun close() { connected.set(false) }
        override fun startSession(): Session {
            val input = ByteArrayInputStream(stdout.encodeToByteArray())
            val errors = ByteArrayInputStream(byteArrayOf())
            val output = ByteArrayOutputStream()
            return Proxy.newProxyInstance(javaClass.classLoader, arrayOf(Session::class.java, Session.Command::class.java)) { proxy, method, arguments ->
                when (method.name) {
                    "exec" -> { requests.add(output); opened.complete(Unit); proxy }
                    "close" -> null
                    "getInputStream" -> input
                    "getErrorStream" -> errors
                    "getOutputStream" -> output
                    "getExitStatus" -> exit
                    "join" -> null
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
