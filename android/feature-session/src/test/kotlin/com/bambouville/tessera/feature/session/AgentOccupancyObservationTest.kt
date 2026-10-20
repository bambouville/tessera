package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.networking.SshRouteOwner
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.lang.reflect.Proxy
import kotlinx.coroutines.runBlocking
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.connection.channel.direct.Session
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Real endpoint and Core discovery parsing; SSH execs have no sockets. */
class AgentOccupancyObservationTest {
    @Test fun paneListsAreBoundedAndMalformedOrFailedListsProveNothing() {
        assertEquals(mapOf("%75" to 100, "%76" to 200),
            parseAgentOccupancyPanes(AgentTmuxControlAck(true, listOf("%75 100", "%76 200")))!!.roots)
        assertTrue(parseAgentOccupancyPanes(AgentTmuxControlAck(true, emptyList()))!!.complete)
        val bounded = parseAgentOccupancyPanes(AgentTmuxControlAck(true, listOf("%75 100", "%76 200")), limit = 1)!!
        assertFalse(bounded.complete)
        assertEquals(mapOf("%75" to 100), bounded.roots)
        for (lines in listOf(listOf("%75 nope"), listOf("%75 1"), listOf("@1 100"),
            listOf("%75 100 extra"), listOf("%75 100", "%75 200"))) {
            assertNull(parseAgentOccupancyPanes(AgentTmuxControlAck(true, lines)))
        }
        assertNull(parseAgentOccupancyPanes(AgentTmuxControlAck(false, listOf("%75 100"))))
    }

    @Test fun tmuxSweepListsAllPanesOnceAndReadsOnlyRequestedRoots() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val client = InventoryClient(listOf(discovery(100, 102, "claude"), discovery(200, 202, "codex")))
            val route = route(client)
            val commands = mutableListOf<String>()
            val endpoint = endpoint(route, transport) { command ->
                commands.add(command)
                AgentTmuxControlAck(true, listOf("%75 100", "%76 200", "%77 300"))
            }
            try {
                endpoint.updateActiveTmuxTarget(1, 75)
                val binding = endpoint.binding.value
                val observed = (endpoint.observeOccupancy(listOf(binding, binding.copy(paneID = "%76", windowID = "@2")))
                    as AgentEndpointResult.Success).value
                assertEquals(listOf("list-panes -a -F '#{pane_id} #{pane_pid}'"), commands)
                assertEquals(listOf("%75", "%76", "%77"), observed.allPaneIDs)
                assertEquals(listOf(AgentOccupancyProcess(102, AgentProofProvider.CLAUDE)), observed.panes[0].processes)
                assertEquals(listOf(AgentOccupancyProcess(202, AgentProofProvider.CODEX)), observed.panes[1].processes)
                assertTrue(observed.panes.all { it.exists && it.complete })
                assertEquals(2, client.inputs.size)
                assertTrue(client.inputs[0].toString().contains("roots=' 100'"))
                assertTrue(client.inputs[1].toString().contains("roots=' 200'"))
            } finally { endpoint.close(); route.close() }
        }
    }

    @Test fun missingPaneRequiresACompleteSuccessfulList() = runBlocking {
        for (mode in listOf("complete", "incomplete", "failed")) {
            val client = InventoryClient(emptyList())
            val route = route(client)
            val endpoint = endpoint(route, AgentEndpointTransport.SSH_TMUX) {
                AgentTmuxControlAck(mode != "failed", if (mode == "incomplete") (0..256).map { "%$it ${it + 100}" } else emptyList())
            }
            try {
                endpoint.updateActiveTmuxTarget(1, 999)
                val result = endpoint.observeOccupancy(listOf(endpoint.binding.value))
                if (mode == "failed") assertTrue(result is AgentEndpointResult.Failed)
                else {
                    val snapshot = (result as AgentEndpointResult.Success).value
                    if (mode == "complete") assertEquals(listOf(AgentOccupancyPane("%999", false, true, emptyList())), snapshot.panes)
                    else { assertNull(snapshot.allPaneIDs); assertTrue(snapshot.panes.isEmpty()) }
                }
                assertTrue(client.inputs.isEmpty())
            } finally { endpoint.close(); route.close() }
        }
    }

    @Test fun rawSshAndMoshUseTheirExistingScopesAndNullPane() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH)) {
            val client = InventoryClient(listOf(discovery(100, 102, "claude")))
            val route = route(client)
            val endpoint = endpoint(route, transport) { error("raw occupancy must not use tmux") }
            try {
                val snapshot = (endpoint.observeOccupancy(listOf(endpoint.binding.value)) as AgentEndpointResult.Success).value
                assertNull(snapshot.allPaneIDs)
                assertNull(snapshot.panes.single().paneID)
                assertTrue(snapshot.panes.single().complete)
                assertEquals(listOf(AgentOccupancyProcess(102, AgentProofProvider.CLAUDE)), snapshot.panes.single().processes)
                assertEquals(listOf(100), snapshot.panes.single().unclassifiedPIDs)
                assertTrue(client.inputs.single().toString().contains(if (transport == AgentEndpointTransport.SSH) MARKER else "roots=' 100'"))
            } finally { endpoint.close(); route.close() }
        }
    }

    // Discovery reports `comm` only, which names no provider for a Node
    // launcher or a versioned native Claude binary; its PID is still there.
    @Test fun presentProcessesNamingNoProviderAreReportedUnclassified() = runBlocking {
        for (executable in listOf("node", "2.0.14")) {
            val client = InventoryClient(listOf(discovery(100, 102, executable)))
            val route = route(client)
            val endpoint = endpoint(route, AgentEndpointTransport.MOSH) { error("unexpected tmux") }
            try {
                val pane = (endpoint.observeOccupancy(listOf(endpoint.binding.value)) as AgentEndpointResult.Success).value.panes.single()
                assertTrue(executable, pane.processes.isEmpty())
                assertEquals(executable, listOf(100, 102), pane.unclassifiedPIDs)
                assertTrue(pane.complete)
            } finally { endpoint.close(); route.close() }
        }
    }

    @Test fun discoveryTruncationPreservesTheFlagAndFailsClosedAtTheLegacyCap() = runBlocking {
        for (output in listOf(discovery(100, 102, "claude", truncated = true), cappedDiscovery(),
            discovery(100, 102, "claude").replace("\"truncated\":false", "\"truncated\":\"false\""))) {
            val client = InventoryClient(listOf(output))
            val route = route(client)
            val endpoint = endpoint(route, AgentEndpointTransport.MOSH) { error("unexpected tmux") }
            try {
                val snapshot = (endpoint.observeOccupancy(listOf(endpoint.binding.value)) as AgentEndpointResult.Success).value
                assertFalse(snapshot.panes.single().complete)
            } finally { endpoint.close(); route.close() }
        }
        val explicitComplete = cappedDiscovery().trimEnd().removeSuffix("}") + ",\"truncated\":false}\n"
        val route = route(InventoryClient(listOf(explicitComplete)))
        val endpoint = endpoint(route, AgentEndpointTransport.MOSH) { error("unexpected tmux") }
        try {
            val snapshot = (endpoint.observeOccupancy(listOf(endpoint.binding.value)) as AgentEndpointResult.Success).value
            assertTrue(snapshot.panes.single().complete)
        } finally { endpoint.close(); route.close() }
    }

    @Test fun failedProcessInventoryAndStaleCarrierCannotRetireAnExistingPane() = runBlocking {
        val client = InventoryClient(listOf("malformed\n"))
        val route = route(client)
        val endpoint = endpoint(route, AgentEndpointTransport.SSH_TMUX) { AgentTmuxControlAck(true, listOf("%75 100")) }
        try {
            endpoint.updateActiveTmuxTarget(1, 75)
            val binding = endpoint.binding.value
            val snapshot = (endpoint.observeOccupancy(listOf(binding)) as AgentEndpointResult.Success).value
            assertTrue(snapshot.panes.isEmpty())
            assertEquals(listOf("%75"), snapshot.allPaneIDs)
            assertEquals(AgentEndpointResult.StaleBinding, endpoint.observeOccupancy(listOf(binding.copy(key = AgentSessionKey("other", 2)))))
            endpoint.close()
            assertEquals(AgentEndpointResult.StaleBinding, endpoint.observeOccupancy(listOf(binding)))
        } finally { endpoint.close(); route.close() }
    }

    private fun endpoint(route: SshRouteOwner, transport: AgentEndpointTransport,
        respond: suspend (String) -> AgentTmuxControlAck) = SshAgentSessionEndpoint(
        AgentSessionKey("occupancy-carrier", 1), "fixture-host", transport, route = route,
        tmuxSession = if (transport.name.endsWith("TMUX")) "fixture" else null,
        routeMarker = MARKER, processRootPID = { 100 }, tmuxControl = TmuxAgentControlPort(directResponder = respond),
    )

    private fun route(client: SSHClient): SshRouteOwner = SshRouteOwner::class.java.declaredConstructors.single {
        it.parameterTypes.size == 2
    }.also { it.isAccessible = true }.newInstance(client, emptyList<Closeable>()) as SshRouteOwner

    private class InventoryClient(outputs: List<String>) : SSHClient() {
        private val responses = outputs.toMutableList()
        val inputs = mutableListOf<ByteArrayOutputStream>()
        override fun isConnected() = true
        override fun isAuthenticated() = true
        override fun close() {}
        override fun startSession(): Session {
            val input = ByteArrayInputStream(responses.removeAt(0).encodeToByteArray())
            val errors = ByteArrayInputStream(byteArrayOf())
            val output = ByteArrayOutputStream().also(inputs::add)
            return Proxy.newProxyInstance(javaClass.classLoader, arrayOf(Session::class.java, Session.Command::class.java)) { proxy, method, arguments ->
                when (method.name) {
                    "exec" -> proxy
                    "getInputStream" -> input
                    "getErrorStream" -> errors
                    "getOutputStream" -> output
                    "getExitStatus" -> 0
                    "close", "join", "signal" -> null
                    "hashCode" -> System.identityHashCode(proxy)
                    "equals" -> proxy === arguments?.firstOrNull()
                    "toString" -> "fixture-occupancy-session"
                    else -> error("Unexpected fixture call ${method.name}")
                }
            } as Session
        }
    }

    private companion object {
        const val MARKER = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        fun process(pid: Int, parent: Int, executable: String) = JSONObject().put("pid", pid).put("ppid", parent)
            .put("executable", executable).put("foreground", false)
        fun discovery(root: Int, pid: Int, provider: String, truncated: Boolean = false) =
            "TESSERA_AGENT_PROCESS_DISCOVERY " + JSONObject().put("v", 1).put("kind", "processDiscovery")
                .put("processes", JSONArray().put(process(root, 1, "bash")).put(process(pid, root, provider)))
                .put("truncated", truncated).toString() + "\n"
        fun cappedDiscovery() = "TESSERA_AGENT_PROCESS_DISCOVERY " + JSONObject().put("v", 1).put("kind", "processDiscovery")
            .put("processes", JSONArray().put(process(100, 1, "bash")).also { entries ->
                (101..227).forEach { entries.put(process(it, 100, "sleep")) }
            }).toString() + "\n"
    }
}
