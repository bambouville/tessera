package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointCapabilities
import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentExecExitStatus
import com.bambouville.tessera.agent.platform.AgentExecRequest
import com.bambouville.tessera.agent.platform.AgentLifecycleFrame
import com.bambouville.tessera.agent.platform.AgentRemoteExecStream
import com.bambouville.tessera.agent.platform.AgentSessionEndpoint
import com.bambouville.tessera.agent.platform.AgentSessionKey
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentIngestionSearchFramesTest {
    /** A host search answers with begin, records, skipped threads and an end;
     * the caller gets every frame, still framed, for Core to validate. */
    @Test fun aSearchReplyKeepsEveryFrameOfItsTransaction() = runBlocking {
        val host = SearchHost(capabilities = listOf("bounded.windows", "window.partitions", "search.v1"))
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val connection = AgentIngestionConnection.open(Endpoint(host), scope)
            assertTrue(connection.supportsSearch)
            val reply = connection.request(JSONObject().put("kind", "search").put("query", "needle")
                .put("threads", JSONArray(listOf("t1", "t2"))).put("limit", 100))
            assertEquals("search.end", reply.end.getString("kind"))
            assertEquals("cur_1", reply.end.getString("cursor"))
            val wire = ByteBuffer.wrap(checkNotNull(reply.wire))
            val kinds = mutableListOf<String>()
            while (wire.hasRemaining()) {
                val body = ByteArray(wire.int).also(wire::get)
                kinds += JSONObject(body.decodeToString()).getString("kind")
            }
            assertEquals(listOf("search.begin", "search.record", "search.skipped", "search.end"), kinds)
        } finally {
            scope.cancel()
        }
    }

    @Test fun aHostWithoutTheCapabilityIsNotSearched() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val connection = AgentIngestionConnection.open(Endpoint(SearchHost(listOf("bounded.windows", "window.partitions"))), scope)
            assertFalse(connection.supportsSearch)
        } finally {
            scope.cancel()
        }
    }

    @Test fun searchFramesFailClosedPastTheirBounds() {
        AgentIngestionConnection.validateSearchFrame("search.begin", 1, 100)
        AgentIngestionConnection.validateSearchFrame("search.skipped", 8193, 1_048_575)
        AgentIngestionConnection.validateSearchFrame("search.end", 8194, 1_048_576)
        for ((kind, frames, bytes) in listOf(
            Triple("search.begin", 2, 100),
            Triple("search.record", 1, 100),
            Triple("search.end", 8195, 100),
            Triple("search.end", 3, 1_048_577),
            Triple("search.unknown", 2, 100),
            Triple("page.record", 2, 100))) {
            assertTrue("search boundary must fail closed: $kind/$frames/$bytes",
                runCatching { AgentIngestionConnection.validateSearchFrame(kind, frames, bytes) }.isFailure)
        }
    }

    private class SearchHost(capabilities: List<String>) : AgentRemoteExecStream {
        private val frames = Channel<ByteArray>(Channel.UNLIMITED)
        init {
            frames.trySend(AgentIngestionConnection.frame(JSONObject().put("kind", "hello").put("id", "hello")
                .put("serviceEpoch", "search_epoch").put("v", 3).put("capabilities", JSONArray(capabilities))))
        }
        override val stdout = frames.receiveAsFlow()
        override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
        override suspend fun awaitExit() = AgentExecExitStatus(0)
        override suspend fun send(bytes: ByteArray) {
            val request = JSONObject(bytes.copyOfRange(4, bytes.size).decodeToString())
            if (request.optString("kind") != "search") return
            val id = request.getString("id")
            fun reply(kind: String) = JSONObject().put("kind", kind).put("id", id).put("serviceEpoch", "search_epoch")
            frames.trySend(AgentIngestionConnection.frame(reply("search.begin")))
            frames.trySend(AgentIngestionConnection.frame(reply("search.record").put("thread", "t1").put("recordID", "r1")))
            frames.trySend(AgentIngestionConnection.frame(reply("search.skipped").put("thread", "t2").put("code", "searchUnsupported")))
            frames.trySend(AgentIngestionConnection.frame(reply("search.end").put("records", 1).put("threadsLeft", 1).put("cursor", "cur_1")))
        }
        override fun cancel() { frames.close() }
        override fun close() { frames.close() }
    }

    private class Endpoint(private val stream: AgentRemoteExecStream) : AgentSessionEndpoint by unusedEndpoint() {
        override val key = AgentSessionKey("search-carrier", 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key, "search-host", AgentEndpointTransport.SSH_TMUX))
        override val ingestionBinding: AgentEndpointBinding get() = binding.value
        override fun isCurrentIngestion(candidate: AgentEndpointBinding) = candidate.sameRouteAs(binding.value)
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames: Flow<AgentLifecycleFrame> = emptyFlow()
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest) =
            AgentEndpointResult.Success(stream)
        override fun close() {}
    }

    private companion object {
        fun unusedEndpoint(): AgentSessionEndpoint = Proxy.newProxyInstance(
            AgentSessionEndpoint::class.java.classLoader, arrayOf(AgentSessionEndpoint::class.java),
        ) { _, method, _ -> error("unexpected endpoint call ${method.name}") } as AgentSessionEndpoint
    }
}
