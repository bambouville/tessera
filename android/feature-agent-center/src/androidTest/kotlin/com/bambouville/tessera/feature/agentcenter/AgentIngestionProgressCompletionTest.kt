package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.*
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.lang.reflect.Proxy
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AgentIngestionProgressCompletionTest {
    @Test fun completedSummaryEndsOnlyItsOwnProgress() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val host = ProgressHost()
        val connection = AgentIngestionConnection.open(Endpoint(host), scope)
        val completed = mutableListOf<String>()
        val preparing = mutableListOf<String>()
        connection.onReadStatus = { thread, _ -> preparing.add(thread) }
        connection.onReadComplete = { completed.add(it) }
        try {
            val first = async(start = CoroutineStart.UNDISPATCHED) {
                connection.request(JSONObject().put("kind", "summary").put("thread", "thread"))
            }
            val a = host.requests.receive()
            host.progress(a)
            assertEquals(listOf("thread"), preparing)
            host.summary(a)
            first.await()
            assertEquals("A successful metadata read must end preparation", listOf("thread"), completed)

            completed.clear()
            val older = async(start = CoroutineStart.UNDISPATCHED) {
                connection.request(JSONObject().put("kind", "summary").put("thread", "thread"))
            }
            val b = host.requests.receive()
            host.progress(b)
            val newer = async(start = CoroutineStart.UNDISPATCHED) {
                connection.request(JSONObject().put("kind", "summary").put("thread", "thread"))
            }
            val c = host.requests.receive()
            host.progress(c)
            host.summary(b); older.await()
            assertTrue("An older completion cannot clear newer progress", completed.isEmpty())
            host.summary(c); newer.await()
            assertEquals(listOf("thread"), completed)
        } finally { connection.close(); scope.cancel() }
    }

    @Test fun cancelledReadEndsPreparationWithoutAReply() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val host = ProgressHost()
        val connection = AgentIngestionConnection.open(Endpoint(host), scope)
        val completed = mutableListOf<String>()
        connection.onReadComplete = { completed.add(it) }
        try {
            val request = async(start = CoroutineStart.UNDISPATCHED) {
                connection.request(JSONObject().put("kind", "summary").put("thread", "thread"))
            }
            host.progress(host.requests.receive())
            request.cancelAndJoin()
            assertEquals("A cancelled read must not leave an endless preparing state", listOf("thread"), completed)
            assertFalse("Cancelling a read preserves sibling reads", connection.isClosed)
        } finally { connection.close(); scope.cancel() }
    }

    @Test fun completedWindowAndTimedOutReadEndPreparationButFailureRemains() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val host = ProgressHost()
        val connection = AgentIngestionConnection.open(Endpoint(host), scope)
        val completed = mutableListOf<String>()
        val states = mutableListOf<String>()
        connection.onReadComplete = { completed.add(it) }
        connection.onReadStatus = { _, status -> states.add(status.state) }
        try {
            val page = async(start = CoroutineStart.UNDISPATCHED) {
                connection.request(JSONObject().put("kind", "window.read").put("thread", "thread"))
            }
            val a = host.requests.receive()
            host.progress(a); host.page(a); page.await()
            assertEquals(listOf("thread"), completed)
            completed.clear()
            val timeout = async(start = CoroutineStart.UNDISPATCHED) {
                runCatching { connection.request(JSONObject().put("kind", "summary").put("thread", "thread"), 100) }
            }
            host.progress(host.requests.receive())
            assertTrue(timeout.await().exceptionOrNull() is TimeoutCancellationException)
            assertEquals(listOf("thread"), completed)
            completed.clear()
            val failed = async(start = CoroutineStart.UNDISPATCHED) {
                runCatching { connection.request(JSONObject().put("kind", "summary").put("thread", "thread")) }
            }
            val b = host.requests.receive()
            host.progress(b); host.failure(b)
            assertTrue(failed.await().exceptionOrNull() is AgentIngestionReadFailure)
            assertEquals("failed", states.last())
            assertTrue("Completion must not erase a terminal read failure", completed.isEmpty())
            assertFalse(connection.isClosed)
        } finally { connection.close(); scope.cancel() }
    }

    @Test fun unsubscribingEndsOnlyWatchProgressAndRejectsRepeatedCounters() = runBlocking {
        for (control in listOf("unsubscribe", "window.release")) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
            val host = ProgressHost()
            val connection = AgentIngestionConnection.open(Endpoint(host), scope)
            val completed = mutableListOf<String>()
            var preparing = 0
            connection.onReadComplete = { completed.add(it) }
            connection.onReadStatus = { _, _ -> preparing++ }
            suspend fun control(kind: String) {
                val request = async(start = CoroutineStart.UNDISPATCHED) {
                    connection.request(JSONObject().put("kind", kind).put("thread", "thread").put("interest", "slow"))
                }
                host.ack(host.requests.receive()); request.await()
            }
            try {
                control("subscribe")
                val watch = JSONObject().put("id", "watch_read").put("thread", "thread")
                host.progress(watch, "0", "0")
                assertEquals(0, preparing)
                host.progress(watch)
                host.progress(watch)
                host.progress(watch, "2", "4096")
                assertEquals(1, preparing)
                control(control)
                assertEquals(listOf("thread"), completed)
                completed.clear()
                control("subscribe")
                host.progress(watch)
                val explicit = async(start = CoroutineStart.UNDISPATCHED) {
                    connection.request(JSONObject().put("kind", "summary").put("thread", "thread"))
                }
                val a = host.requests.receive()
                host.progress(a)
                control(control)
                assertTrue("A control ACK cannot clear a newer explicit read", completed.isEmpty())
                host.summary(a); explicit.await()
                assertEquals(listOf("thread"), completed)
            } finally { connection.close(); scope.cancel() }
        }
    }

    private class ProgressHost : AgentRemoteExecStream {
        private val frames = Channel<ByteArray>(Channel.UNLIMITED)
        val requests = Channel<JSONObject>(Channel.UNLIMITED)
        init { emit(JSONObject().put("kind", "hello").put("id", "hello").put("v", 3)
            .put("capabilities", JSONArray(listOf("bounded.windows", "window.partitions", "read.progress.v1")))) }
        private fun emit(value: JSONObject) {
            frames.trySend(AgentIngestionConnection.frame(value.put("serviceEpoch", "progress_epoch"))).getOrThrow()
        }
        fun progress(request: JSONObject, sequence: String = "1", bytes: String = "4096") = emit(JSONObject().put("kind", "read.progress")
            .put("id", request.getString("id")).put("thread", request.getString("thread"))
            .put("sequence", sequence).put("bytesRead", bytes).put("status", JSONObject()
                .put("v", 1).put("state", "preparing").put("domain", "source").put("recovery", "continue").put("code", "readPending")))
        fun summary(request: JSONObject) = emit(JSONObject().put("kind", "summary")
            .put("id", request.getString("id")).put("thread", request.getString("thread")))
        fun ack(request: JSONObject) = emit(JSONObject().put("kind", "ack").put("id", request.getString("id")))
        fun page(request: JSONObject) {
            emit(JSONObject().put("kind", "page.begin").put("id", request.getString("id")).put("sourceIdentity", "source"))
            emit(JSONObject().put("kind", "page.end").put("id", request.getString("id")).put("thread", request.getString("thread")))
        }
        fun failure(request: JSONObject) = emit(JSONObject().put("kind", "error")
            .put("id", request.getString("id")).put("thread", request.getString("thread")).put("status", JSONObject()
                .put("v", 1).put("state", "failed").put("domain", "source").put("recovery", "manual").put("code", "sourceNotAuthorized")))
        override val stdout = frames.receiveAsFlow()
        override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
        override suspend fun awaitExit() = AgentExecExitStatus(0)
        override suspend fun send(bytes: ByteArray) {
            val size = java.nio.ByteBuffer.wrap(bytes, 0, 4).int
            requests.send(JSONObject(bytes.copyOfRange(4, 4 + size).decodeToString()))
        }
        override fun cancel() { frames.close() }
        override fun close() { frames.close() }
    }

    private class Endpoint(private val stream: AgentRemoteExecStream) : AgentSessionEndpoint by unusedEndpoint() {
        override val key = AgentSessionKey("progress-carrier", 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key, "progress-host", AgentEndpointTransport.SSH_TMUX))
        override val ingestionBinding get() = binding.value
        override fun isCurrentIngestion(candidate: AgentEndpointBinding) = candidate.sameRouteAs(binding.value)
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames: Flow<AgentLifecycleFrame> = emptyFlow()
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest) = AgentEndpointResult.Success(stream)
        override fun close() {}
    }
    private companion object {
        fun unusedEndpoint(): AgentSessionEndpoint = Proxy.newProxyInstance(AgentSessionEndpoint::class.java.classLoader,
            arrayOf(AgentSessionEndpoint::class.java)) { _, method, _ -> error("unexpected endpoint call ${method.name}") } as AgentSessionEndpoint
    }
}
