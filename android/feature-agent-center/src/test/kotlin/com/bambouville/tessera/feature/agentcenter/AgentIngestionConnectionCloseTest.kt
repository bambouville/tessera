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
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
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
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentIngestionConnectionCloseTest {
    /** The app crashed with ConcurrentModificationException when the helper
     * went away (an integration update replaced it) while several requests
     * were in flight: on Main.immediate a cancelled waiter resumes inline on
     * the closing thread and removes itself from the map close() iterated.
     * Unconfined waiters closed from this thread resume inline the same way. */
    @Test fun closingWithSeveralRequestsInFlightWakesEveryWaiter() = runBlocking {
        val stream = SilentHost()
        // Supervisors, so a failed reader or caller would only print: each
        // one is recorded, and any fails the test.
        val uncaught = Collections.synchronizedList(mutableListOf<Throwable>())
        val recorded = CoroutineExceptionHandler { _, failure -> uncaught += failure }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined + recorded)
        val callers = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined + recorded)
        try {
            val connection = AgentIngestionConnection.open(HostEndpoint(stream), scope)
            val requests = listOf(
                JSONObject().put("kind", "window.read").put("thread", "thread-a").put("operation", "bootstrap"),
                JSONObject().put("kind", "window.read").put("thread", "thread-b").put("operation", "bootstrap"),
                JSONObject().put("kind", "heartbeat"),
                JSONObject().put("kind", "heartbeat"),
            ).map { fields -> callers.async { runCatching { connection.request(fields) }.exceptionOrNull() } }
            assertEquals("every request must be on the wire before close", 4, stream.requests.get())

            connection.close()

            assertTrue(connection.isClosed)
            for (request in requests) {
                assertTrue("a waiter was left suspended", request.isCompleted)
                assertTrue(request.await() is CancellationException)
            }
        } finally {
            callers.cancel(); scope.cancel()
        }
        assertEquals("coroutines failed uncaught", emptyList<Throwable>(), synchronized(uncaught) { uncaught.toList() })
    }

    private class SilentHost : AgentRemoteExecStream {
        private val frames = Channel<ByteArray>(Channel.UNLIMITED)
        val requests = AtomicInteger()
        init {
            frames.trySend(AgentIngestionConnection.frame(JSONObject().put("kind", "hello").put("id", "hello")
                .put("serviceEpoch", "close_epoch").put("v", 3)
                .put("capabilities", JSONArray(listOf("bounded.windows", "window.partitions", "read.progress.v1")))))
        }
        override val stdout = frames.receiveAsFlow()
        override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
        override suspend fun awaitExit() = AgentExecExitStatus(0)
        // Accept every request and never answer, like a helper being replaced.
        override suspend fun send(bytes: ByteArray) { requests.incrementAndGet() }
        override fun cancel() { frames.close() }
        override fun close() { frames.close() }
    }

    private class HostEndpoint(private val stream: AgentRemoteExecStream) : AgentSessionEndpoint by unusedEndpoint() {
        override val key = AgentSessionKey("close-carrier", 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key, "close-host", AgentEndpointTransport.MOSH_TMUX))
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
