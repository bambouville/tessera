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
import com.bambouville.tessera.core.bridge.SharedAgentHostSearch
import java.lang.reflect.Proxy
import java.nio.ByteBuffer
import java.util.UUID
import kotlinx.coroutines.CancellationException
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
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** One host's `search.v1` pass: request bounds, batching, the needle, partial
 * results at the deadline, refused or oversized matches, paging a refused
 * batch, and `satisfied`. */
class AgentHostSearchPassTest {
    /** A fresh search has about 30 s left, but one connection request may
     * wait at most 15 s; asking for more failed every host search. */
    @Test fun aSearchWithMoreThanFifteenSecondsLeftStillReachesTheHost() = runBlocking {
        val host = ScriptedHost { _, _ ->
            listOf(frame("search.begin"), record("t1", "r1"), frame("search.end").put("records", 1))
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val connection = AgentIngestionConnection.open(Endpoint(host), scope)
            assertTrue(connection.supportsSearch)
            val timeouts = mutableListOf<Long>()
            val outcome = runAgentHostSearch(listOf("t1"), "needle", AGENT_SEARCH_HOST_RESULTS,
                System.nanoTime() + 30_000_000_000L,
                request = { fields, timeoutMillis -> timeouts += timeoutMillis; connection.request(fields, timeoutMillis) },
                match = { reply, batch -> decode(reply, batch) },
                handleOf = { it.getString("thread") },
                admit = { it.getString("thread") })
            assertFalse(outcome.incomplete)
            assertEquals(listOf("r1"), outcome.results.map { it.getString("recordID") })
            assertEquals(1, timeouts.size)
            assertTrue("request timeout ${timeouts.single()}", timeouts.single() in 1L..15_000L)
            assertFalse(host.requests.single().has("limit"))
        } finally {
            scope.cancel()
        }
    }

    /** A host refusing the first request pages that batch: the host read
     * nothing of it, so paging finds nothing twice. */
    @Test fun aHostRefusalOfTheFirstRequestPagesTheBatch() = runBlocking {
        val host = ScriptedHost { _, _ -> listOf(frame("error").put("code", "invalidRequest")) }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        try {
            val connection = AgentIngestionConnection.open(Endpoint(host), scope)
            val outcome = runAgentHostSearch(listOf("t1", "t2"), "needle", AGENT_SEARCH_HOST_RESULTS,
                System.nanoTime() + 30_000_000_000L,
                request = { fields, timeoutMillis -> connection.request(fields, timeoutMillis) },
                match = { reply, batch -> decode(reply, batch) },
                handleOf = { it.getString("thread") },
                admit = { it.getString("thread") })
            assertEquals(listOf("t1", "t2"), outcome.paged)
            assertTrue(outcome.results.isEmpty())
            assertFalse(outcome.incomplete)
            assertFalse(connection.isClosed)
        } finally {
            scope.cancel()
        }
    }

    @Test fun onlyTheFirstRequestOfABatchFallsBackToPaging() = runBlocking {
        val handles = (0 until 1_500).map { "h%05d".format(it) }
        val sent = mutableListOf<JSONObject>()
        val outcome = runAgentHostSearch(handles, "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { fields, _ ->
                sent += fields
                // The first batch is refused outright; the second fails on
                // its cursor, after the host already returned matches.
                if (sent.size == 1) throw AgentIngestionRemoteError("busy")
                if (sent.size == 3) throw AgentIngestionRemoteError("cursorExpired")
                AgentIngestionConnection.Reply(JSONObject())
            },
            match = { _, batch -> hostReply(listOf(batch.first() to "found"), cursor = "next") },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { 0L })
        assertEquals(handles.take(1_000), outcome.paged)
        assertEquals(listOf("found"), outcome.results.map { it.getString("recordID") })
        assertTrue(outcome.incomplete)
        assertEquals(3, sent.size)
    }

    /** Each reply that finds more shows what the host found so far; one
     * that adds nothing shows nothing new. */
    @Test fun eachReplyThatFindsMoreShowsItsRows() = runBlocking {
        var calls = 0
        val seen = mutableListOf<List<String>>()
        val outcome = runAgentHostSearch(listOf("a", "b"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { _, _ -> calls++; AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ ->
                when (calls) {
                    1 -> hostReply(listOf("a" to "a1", "a" to "a2"), cursor = "next_1")
                    2 -> hostReply(emptyList(), cursor = "next_2")
                    else -> hostReply(listOf("b" to "b1"), cursor = null)
                }
            },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { 0L },
            progress = { results -> seen += results.map { it.getString("recordID") } })
        assertEquals(3, calls)
        assertEquals(listOf(listOf("a1", "a2"), listOf("a1", "a2", "b1")), seen)
        assertEquals(listOf("a1", "a2", "b1"), outcome.results.map { it.getString("recordID") })
    }

    /** The budget ending keeps every match already found and reports the
     * host incomplete; it does not throw them away. */
    @Test fun theDeadlineKeepsWhatTheHostAlreadyFound() = runBlocking {
        var now = 0L
        val deadline = 30_000_000_000L
        val sent = mutableListOf<JSONObject>()
        val outcome = runAgentHostSearch(listOf("a", "b"), "needle", AGENT_SEARCH_HOST_RESULTS, deadline,
            request = { fields, _ -> sent += fields; now = deadline; AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> hostReply(listOf("a" to "a1", "b" to "b1"), cursor = "next") },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { now })
        assertEquals(1, sent.size)
        assertEquals(listOf("a1", "b1"), outcome.results.map { it.getString("recordID") })
        assertTrue(outcome.incomplete)
        assertTrue(outcome.paged.isEmpty())
    }

    @Test fun aTimedOutOrClosedRequestKeepsWhatTheHostAlreadyFound() = runBlocking {
        for (failure in listOf("timeout", "closed")) {
            val sent = mutableListOf<JSONObject>()
            val outcome = runAgentHostSearch(listOf("a"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
                request = { fields, _ ->
                    sent += fields
                    if (sent.size == 2) {
                        // A nested timeout, or the connection cancelling its
                        // waiting reads as it closes: neither is this search's
                        // own cancellation.
                        if (failure == "timeout") withTimeout(1) { awaitCancellation() }
                        else throw CancellationException("connection closed")
                    }
                    AgentIngestionConnection.Reply(JSONObject())
                },
                match = { _, _ -> hostReply(listOf("a" to "a1"), cursor = "next") },
                handleOf = { it.getString("thread") },
                admit = { it.getString("thread") },
                nanoTime = { 0L })
            assertEquals(failure, 2, sent.size)
            assertEquals(failure, listOf("a1"), outcome.results.map { it.getString("recordID") })
            assertTrue(failure, outcome.incomplete)
        }
    }

    /** One 4,096-handle request is about 143 KiB, past any 64 KiB frame. */
    @Test fun handlesAreSplitIntoRequestsAFrameCanCarry() {
        val handles = (0 until 4_096).map { "%032x".format(it) }
        assertTrue(runCatching { AgentIngestionConnection.frame(searchRequest(handles)) }.isFailure)
        val batches = agentSearchBatches(handles)
        assertEquals(handles, batches.flatten())
        assertEquals(5, batches.size)
        for (batch in batches) {
            assertTrue(batch.size <= 1_000)
            assertTrue(JSONArray(batch).toString().encodeToByteArray().size <= 48 * 1024)
            AgentIngestionConnection.frame(searchRequest(batch))
        }
        // Longest handles: the byte bound, not the count, splits them.
        val long = (0 until 1_000).map { "h".repeat(120) + "%08d".format(it) }
        val longBatches = agentSearchBatches(long)
        assertTrue(longBatches.size > 1)
        assertEquals(long, longBatches.flatten())
        for (batch in longBatches) AgentIngestionConnection.frame(searchRequest(batch))
        assertTrue(agentSearchBatches(emptyList()).isEmpty())
    }

    /** Each batch is its own search: its first request names its threads,
     * its cursors follow only its own chain, and matching sees only it. */
    @Test fun eachBatchIsItsOwnSearchWithItsOwnCursors() = runBlocking {
        val handles = (0 until 2_500).map { "h%05d".format(it) }
        val sent = mutableListOf<JSONObject>()
        val matched = mutableListOf<List<String>>()
        val outcome = runAgentHostSearch(handles, "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { fields, _ -> sent += fields; AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, batch ->
                matched += batch
                // One cursor per batch, then its end.
                hostReply(emptyList(), cursor = if (sent.last().has("cursor")) null else "cursor_${matched.size}")
            },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { 0L })
        assertFalse(outcome.incomplete)
        assertEquals(6, sent.size)
        val batches = agentSearchBatches(handles)
        assertEquals(3, batches.size)
        for ((index, batch) in batches.withIndex()) {
            val first = sent[index * 2]
            val next = sent[index * 2 + 1]
            assertEquals(batch, first.getJSONArray("threads").strings())
            assertEquals("needle", first.getString("query"))
            assertFalse(first.has("cursor") || first.has("limit"))
            assertEquals("cursor_${index * 2 + 1}", next.getString("cursor"))
            assertFalse(next.has("query") || next.has("threads") || next.has("satisfied"))
            AgentIngestionConnection.frame(first.put("id", UUID.randomUUID().toString()))
            assertEquals(batch, matched[index * 2])
        }
    }

    /** A thread that holds 25 matches is reported satisfied on every later
     * cursor of its batch, and nothing past its 25th match is kept. */
    @Test fun aThreadWithTwentyFiveMatchesIsSatisfiedOnEveryLaterCursor() = runBlocking {
        val sent = mutableListOf<JSONObject>()
        val replies = ArrayDeque(listOf(
            hostReply((1..25).map { "a" to "a$it" } + ("b" to "b1"), cursor = "k"),
            hostReply(listOf("a" to "a26", "b" to "b2"), cursor = "k"),
            hostReply(listOf("b" to "b3"), cursor = null)))
        val outcome = runAgentHostSearch(listOf("a", "b"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { fields, _ -> sent += fields; AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> replies.removeFirst() },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { 0L })
        assertEquals(3, sent.size)
        assertFalse(sent[0].has("satisfied") || sent[0].has("limit"))
        assertEquals(listOf("a"), sent[1].getJSONArray("satisfied").strings())
        assertEquals(listOf("a"), sent[2].getJSONArray("satisfied").strings())
        assertEquals((1..25).map { "a$it" } + listOf("b1", "b2", "b3"), outcome.results.map { it.getString("recordID") })
        assertFalse(outcome.incomplete)
    }

    @Test fun aSearchStopsAtTheHostsRoomAndDropsStaleMatches() = runBlocking {
        val sent = mutableListOf<JSONObject>()
        val outcome = runAgentHostSearch(listOf("stale", "a", "b"), "needle", 2, Long.MAX_VALUE,
            request = { fields, _ -> sent += fields; AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> hostReply(listOf("stale" to "s1", "a" to "a1", "b" to "b1", "b" to "b2"), cursor = "more") },
            // A match whose source is no longer current is not admitted.
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread").takeIf { thread -> thread != "stale" } },
            nanoTime = { 0L })
        assertEquals(1, sent.size)
        assertEquals(listOf("a1", "b1"), outcome.results.map { it.getString("recordID") })
        assertTrue(outcome.incomplete)
    }

    /** A match whose source changed meanwhile is dropped, and the host reads
     * as incomplete: that thread was not searched on its current route. The
     * rest of what the host found stands. */
    @Test fun aRefusedMatchLeavesTheHostIncomplete() = runBlocking {
        val outcome = runAgentHostSearch(listOf("a", "b"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { _, _ -> AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> hostReply(listOf("a" to "a1", "b" to "b1", "a" to "a2"), cursor = null) },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread").takeIf { thread -> thread != "b" } },
            nanoTime = { 0L })
        assertEquals(listOf("a1", "a2"), outcome.results.map { it.getString("recordID") })
        assertTrue(outcome.incomplete)
        assertTrue(outcome.paged.isEmpty())
        val current = runAgentHostSearch(listOf("a", "b"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { _, _ -> AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> hostReply(listOf("a" to "a1", "b" to "b1", "a" to "a2"), cursor = null) },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { 0L })
        assertEquals(listOf("a1", "b1", "a2"), current.results.map { it.getString("recordID") })
        assertFalse(current.incomplete)
    }

    /** Matches the host left out as too large to send were never seen, so the
     * host reads as incomplete; what it did send stands. */
    @Test fun recordsTheHostCouldNotSendLeaveTheHostIncomplete() = runBlocking {
        val replies = ArrayDeque(listOf(
            hostReply(listOf("a" to "a1"), cursor = "k", oversizedRecords = 1),
            hostReply(listOf("a" to "a2"), cursor = null)))
        val outcome = runAgentHostSearch(listOf("a"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { _, _ -> AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> replies.removeFirst() },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { 0L })
        assertEquals(listOf("a1", "a2"), outcome.results.map { it.getString("recordID") })
        assertTrue(outcome.incomplete)
        assertTrue(replies.isEmpty())
    }

    @Test fun aSkippedThreadIsPagedOnlyWhenTheHostFoundNothingInIt() = runBlocking {
        val skipped = listOf(
            SharedAgentHostSearch.Skipped("a", "searchUnsupported", pagedFallback = true),
            SharedAgentHostSearch.Skipped("b", "searchUnsupported", pagedFallback = true),
            SharedAgentHostSearch.Skipped("c", "sourceMissing", pagedFallback = false),
            SharedAgentHostSearch.Skipped("elsewhere", "searchUnsupported", pagedFallback = true))
        val outcome = runAgentHostSearch(listOf("a", "b", "c"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { _, _ -> AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> hostReply(listOf("a" to "a1"), cursor = null, skipped = skipped) },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { 0L })
        assertEquals(listOf("b"), outcome.paged)
        assertEquals(listOf("a1"), outcome.results.map { it.getString("recordID") })
        // "c" was not read to its end: its host reads as incomplete.
        assertTrue(outcome.incomplete)
        val whole = runAgentHostSearch(listOf("a", "b"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { _, _ -> AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> hostReply(listOf("a" to "a1"), cursor = null, skipped = skipped.take(2)) },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { 0L })
        // "a" gave a match and was then skipped: paging would repeat it, so
        // it is not paged and its host reads as incomplete, as on iOS.
        assertEquals(listOf("b"), whole.paged)
        assertTrue(whole.incomplete)
        val unread = runAgentHostSearch(listOf("a", "b"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { _, _ -> AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> hostReply(emptyList(), cursor = null, skipped = skipped.take(2)) },
            handleOf = { it.getString("thread") },
            admit = { it.getString("thread") },
            nanoTime = { 0L })
        assertEquals(listOf("a", "b"), unread.paged)
        assertFalse(unread.incomplete)
    }

    /** A thread already holding its 25 matches takes no more, so a refused
     * match past that cap changes nothing, as on iOS. */
    @Test fun aRefusedMatchPastItsThreadsCapLeavesTheHostComplete() = runBlocking {
        val matches = (1..26).map { "a" to "a$it" }
        val outcome = runAgentHostSearch(listOf("a"), "needle", AGENT_SEARCH_HOST_RESULTS, Long.MAX_VALUE,
            request = { _, _ -> AgentIngestionConnection.Reply(JSONObject()) },
            match = { _, _ -> hostReply(matches, cursor = null) },
            handleOf = { it.getString("thread") },
            admit = { match -> match.getString("thread").takeIf { match.getString("recordID") != "a26" } },
            nanoTime = { 0L })
        assertEquals(AGENT_SEARCH_THREAD_RESULTS, outcome.results.size)
        assertFalse(outcome.incomplete)
    }

    /** The host refuses a needle over 512 UTF-8 bytes; the cut never splits
     * a character and drops whitespace it leaves at the end. */
    @Test fun theNeedleFitsTheHostsByteLimitOnACharacterBoundary() {
        assertEquals("needle", agentSearchNeedle("  needle \n"))
        assertEquals("", agentSearchNeedle(" \t "))
        assertEquals("a".repeat(512), agentSearchNeedle("a".repeat(600)))
        assertEquals("\u00e9".repeat(256), agentSearchNeedle("\u00e9".repeat(300)))
        assertEquals("\u691c".repeat(170), agentSearchNeedle("\u691c".repeat(200)))
        val thumb = "\uD83D\uDC4D\uD83C\uDFFD"
        assertEquals(thumb.repeat(64), agentSearchNeedle(thumb.repeat(100)))
        assertEquals("e\u0301".repeat(170), agentSearchNeedle("e\u0301".repeat(200)))
        assertEquals("a".repeat(511), agentSearchNeedle("a".repeat(511) + " b"))
        for (query in listOf("\u691c".repeat(200), thumb.repeat(100), "e\u0301".repeat(200), "x\u00e9".repeat(400))) {
            val needle = agentSearchNeedle(query)
            assertTrue(needle.encodeToByteArray().size <= AGENT_SEARCH_NEEDLE_BYTES)
            assertTrue(query.startsWith(needle))
            assertFalse(needle.last().isHighSurrogate())
        }
    }

    private fun searchRequest(handles: List<String>) = JSONObject().put("kind", "search").put("id", UUID.randomUUID().toString())
        .put("query", "q".repeat(512)).put("threads", JSONArray(handles))

    private fun hostReply(results: List<Pair<String, String>>, cursor: String?,
                          skipped: List<SharedAgentHostSearch.Skipped> = emptyList(), oversizedRecords: Long = 0) = SharedAgentHostSearch.Reply(
        JSONArray().also { array -> results.forEach { (thread, record) -> array.put(JSONObject().put("thread", thread).put("recordID", record)) } },
        skipped, cursor, oversizedRecords)

    /** What Core's exact match returns for this fixture: every record is a
     * match, kept only for the batch's own handles. */
    private fun decode(received: AgentIngestionConnection.Reply, batch: List<String>): SharedAgentHostSearch.Reply {
        val wire = ByteBuffer.wrap(checkNotNull(received.wire))
        val results = mutableListOf<Pair<String, String>>()
        val skipped = mutableListOf<SharedAgentHostSearch.Skipped>()
        var cursor: String? = null
        while (wire.hasRemaining()) {
            val body = ByteArray(wire.int).also { wire.get(it) }
            val frame = JSONObject(body.decodeToString())
            when (frame.getString("kind")) {
                "search.record" -> {
                    if (frame.getString("thread") in batch) results += frame.getString("thread") to frame.getString("recordID")
                }
                "search.skipped" -> {
                    skipped += SharedAgentHostSearch.Skipped(frame.getString("thread"), frame.getString("code"),
                        frame.getString("code") == "searchUnsupported")
                }
                "search.end" -> {
                    cursor = if (frame.has("cursor")) frame.getString("cursor") else null
                }
            }
        }
        return hostReply(results, cursor, skipped)
    }

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

    private class ScriptedHost(private val script: (request: JSONObject, index: Int) -> List<JSONObject>) : AgentRemoteExecStream {
        private val frames = Channel<ByteArray>(Channel.UNLIMITED)
        val requests = mutableListOf<JSONObject>()
        init {
            frames.trySend(AgentIngestionConnection.frame(JSONObject().put("kind", "hello").put("id", "hello")
                .put("serviceEpoch", EPOCH).put("v", 3)
                .put("capabilities", JSONArray(listOf("bounded.windows", "window.partitions", "search.v1")))))
        }
        override val stdout: Flow<ByteArray> = frames.receiveAsFlow()
        override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
        override suspend fun awaitExit() = AgentExecExitStatus(0)
        override suspend fun send(bytes: ByteArray) {
            val request = JSONObject(bytes.copyOfRange(4, bytes.size).decodeToString())
            if (request.optString("kind") != "search") return
            requests += request
            for (value in script(request, requests.size - 1)) {
                frames.trySend(AgentIngestionConnection.frame(value.put("id", request.getString("id")).put("serviceEpoch", EPOCH)))
            }
        }
        override fun cancel() { frames.close() }
        override fun close() { frames.close() }
    }

    private class Endpoint(private val stream: AgentRemoteExecStream) : AgentSessionEndpoint by unusedEndpoint() {
        override val key = AgentSessionKey("search-pass-carrier", 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key, "search-host", AgentEndpointTransport.SSH_TMUX))
        override val ingestionBinding: AgentEndpointBinding get() = binding.value
        override fun isCurrentIngestion(candidate: AgentEndpointBinding) = candidate.sameRouteAs(binding.value)
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames: Flow<AgentLifecycleFrame> = emptyFlow()
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> =
            AgentEndpointResult.Success(stream)
        override fun close() {}
    }

    private companion object {
        const val EPOCH = "search_pass_epoch"

        fun frame(kind: String): JSONObject = JSONObject().put("kind", kind)

        fun record(thread: String, recordID: String): JSONObject = frame("search.record").put("thread", thread).put("recordID", recordID)

        fun unusedEndpoint(): AgentSessionEndpoint = Proxy.newProxyInstance(
            AgentSessionEndpoint::class.java.classLoader, arrayOf(AgentSessionEndpoint::class.java),
        ) { _, method, _ -> error("unexpected endpoint call ${method.name}") } as AgentSessionEndpoint
    }
}
