package com.bambouville.tessera.feature.agentcenter

import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Actual presenter and duplex client, synthetic endpoints; no host connections. */
class AgentContextPoolInstrumentedTest {
    @Test fun readProgressRenewsOnlyItsReadIdleDeadlineAcrossAllTransports(): Unit = runBlocking {
        for (transport in AgentEndpointTransport.entries) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val endpoint = ContextEndpoint(transport, readProgress = true)
            val connection = AgentIngestionConnection.open(endpoint, scope)
            try {
                val statuses = java.util.concurrent.CopyOnWriteArrayList<String>()
                connection.onReadStatus = { thread, status -> assertEquals("thread", thread); assertTrue(status.isProgress); statuses.add(status.code) }
                val stream = endpoint.streams.single()
                val request = async { runCatching { connection.request(JSONObject().put("kind", "summary").put("thread", "thread"), 400) } }
                val id = withTimeout(2_000) { stream.summaryRequests.receive() }
                assertTrue(stream.sentRequests.last().getBoolean("readProgress"))
                for (index in 1..3) {
                    delay(200)
                    stream.progress(id, sequence = (ULong.MAX_VALUE - (3 - index).toULong()).toString(),
                        bytes = (ULong.MAX_VALUE - (3 - index).toULong()).toString())
                    withTimeout(2_000) { while (statuses.size < index) delay(1) }
                }
                stream.replySummary(id)
                request.await().getOrThrow()
                assertEquals(3, statuses.size)
                assertFalse(connection.isClosed)
            } finally { connection.close(); endpoint.close(); scope.cancel() }
        }
    }

    @Test fun duplicateForeignAndControlProgressCannotRenewDeadline(): Unit = runBlocking {
        for (scenario in listOf("duplicate", "sameBytes", "sameSequence", "foreignThread", "foreignID", "heartbeat", "legacy", "cancelled")) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val endpoint = ContextEndpoint(AgentEndpointTransport.MOSH_TMUX, readProgress = scenario != "legacy")
            val connection = AgentIngestionConnection.open(endpoint, scope)
            try {
                val statuses = java.util.concurrent.CopyOnWriteArrayList<String>()
                connection.onReadStatus = { _, status -> statuses.add(status.code) }
                val stream = endpoint.streams.single()
                val kind = if (scenario == "heartbeat") "heartbeat" else "summary"
                stream.heldControlKind = if (scenario == "heartbeat") "heartbeat" else null
                val request = async { runCatching { connection.request(JSONObject().put("kind", kind).put("thread", "thread"), 200) } }
                val id = withTimeout(2_000) {
                    if (kind == "summary") stream.summaryRequests.receive() else stream.heldControlRequests.receive().getString("id")
                }
                if (scenario == "cancelled") {
                    request.cancelAndJoin()
                    stream.progress(id, sequence = "1", bytes = "100")
                    stream.replySummary(id)
                    connection.request(JSONObject().put("kind", "heartbeat"))
                    assertEquals(0, statuses.size); assertFalse(connection.isClosed)
                    continue
                }
                if (scenario == "legacy") assertFalse(stream.sentRequests.last().has("readProgress"))
                else repeat(4) { index ->
                    delay(80)
                    stream.progress(if (scenario == "foreignID") "other_request" else id,
                        thread = if (scenario == "foreignThread") "otherThread" else "thread",
                        sequence = if (scenario == "sameBytes") (index + 1).toString() else "1",
                        bytes = if (scenario == "sameSequence") ((index + 1) * 100).toString() else "100")
                    if (scenario in listOf("duplicate", "sameBytes", "sameSequence") && index == 0)
                        withTimeout(2_000) { while (statuses.isEmpty()) delay(1) }
                }
                assertTrue("$scenario kept a stalled read alive", request.await().exceptionOrNull() is TimeoutCancellationException)
                assertEquals(if (scenario in listOf("duplicate", "sameBytes", "sameSequence")) 1 else 0, statuses.size)
                assertFalse(connection.isClosed)
            } finally { connection.close(); endpoint.close(); scope.cancel() }
        }
    }

    @Test fun hostReadStatusNeverUsesLocalRetentionCapacityCallback(): Unit = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val endpoint = ContextEndpoint(AgentEndpointTransport.SSH)
        val connection = AgentIngestionConnection.open(endpoint, scope)
        try {
            val codes = java.util.concurrent.CopyOnWriteArrayList<String>()
            var resets = 0
            connection.onCapacity = { fail("host failure is not local retention pressure") }
            connection.onReadStatus = { _, status -> codes.add(status.code) }
            connection.onResync = { resets++ }
            val stream = endpoint.streams.single()
            val status = JSONObject().put("v", 1).put("state", "resourceLimited").put("domain", "host")
                .put("recovery", "manual").put("code", "codexIndexCapacity")
            stream.inject(JSONObject().put("kind", "resyncRequired").put("thread", "thread").put("status", status))
            stream.resync("capacityExceeded")
            connection.request(JSONObject().put("kind", "heartbeat"))
            assertEquals(listOf("codexIndexCapacity"), codes.toList()); assertEquals(1, resets)
            val request = async { runCatching { connection.request(JSONObject().put("kind", "summary").put("thread", "thread")) } }
            val id = withTimeout(2_000) { stream.summaryRequests.receive() }
            stream.inject(JSONObject().put("kind", "error").put("id", id).put("thread", "thread").put("status", status))
            assertEquals("codexIndexCapacity", (request.await().exceptionOrNull() as AgentIngestionReadFailure).status.code)
            assertEquals(2, codes.size)
        } finally { connection.close(); endpoint.close(); scope.cancel() }
    }

    @Test fun visibleCardResubscribesImmediatelyAfterServerResync(): Unit = runBlocking {
        withContext(Dispatchers.Main) {
            for (transport in AgentEndpointTransport.entries) {
                val context = InstrumentationRegistry.getInstrumentation().targetContext
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                val coordinator = AndroidAgentSessionCoordinator(LiveAgentSessionRegistry())
                val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
                val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                    AndroidAgentCenterViewPreferences(context), scope, integration)
                val endpoint = ContextEndpoint(transport)
                try {
                    presenter.setEnabled(true)
                    val (host, connection) = presenter.nativeConnection(endpoint)
                    val thread = AgentCenterPresenter.NativeThread("thread")
                    host.threads["visible-card"] = thread
                    val stream = endpoint.streams.single()
                    stream.heldControlKind = "subscribe"
                    presenter.setCardVisible("visible-card", true)
                    val pendingSubscribe = withTimeout(2_000) { stream.heldControlRequests.receive() }
                    // The service revokes the subscription before its earlier
                    // ACK reaches us. A late ACK must not reinstate fast=false
                    // and make the scheduled retry believe the watch exists.
                    stream.resync("canonicalReadFailed")
                    connection.request(JSONObject().put("kind", "heartbeat"))
                    assertFalse("Revoked pending subscription is not current", connection.isSubscribed("thread"))
                    stream.heldControlKind = null
                    stream.replyAck(pendingSubscribe.getString("id"))
                    withTimeout(2_000) {
                        while (stream.sentKinds.count { it == "subscribe" } < 2 || thread.fast != false) delay(10)
                    }
                    assertTrue("Only the replacement subscribe restores membership", connection.isSubscribed("thread"))
                    assertNull(presenter.state.value.selectedThreadKey)
                    for (reason in listOf("canonicalReadFailed", "subscriptionAckExpired", "hookOverflow")) {
                        val subscriptions = stream.sentKinds.count { it == "subscribe" }
                        stream.resync(reason)
                        withTimeout(2_000) {
                            while (stream.sentKinds.count { it == "subscribe" } == subscriptions || thread.fast != false) delay(10)
                        }
                        assertEquals(false, thread.fast)
                        assertFalse(connection.isClosed)
                    }
                    // A stale ACK can also succeed after demand disappears.
                    // Unlike resync, hiding does not remove the remote watch;
                    // the client must compensate instead of losing ownership.
                    presenter.setCardVisible("visible-card", false)
                    withTimeout(2_000) { while (thread.fast != null) delay(10) }
                    val unsubscribedBeforeHide = stream.sentKinds.count { it == "unsubscribe" }
                    stream.heldControlKind = "subscribe"
                    presenter.setCardVisible("visible-card", true)
                    val hiddenSubscribe = withTimeout(2_000) { stream.heldControlRequests.receive() }
                    presenter.setCardVisible("visible-card", false)
                    stream.heldControlKind = null
                    stream.replyAck(hiddenSubscribe.getString("id"))
                    withTimeout(2_000) {
                        while (stream.sentKinds.count { it == "unsubscribe" } == unsubscribedBeforeHide || thread.fast != null) delay(10)
                    }
                    val hiddenSubscriptions = stream.sentKinds.count { it == "subscribe" }
                    delay(150)
                    assertEquals(hiddenSubscriptions, stream.sentKinds.count { it == "subscribe" })
                    presenter.setCardVisible("visible-card", true)
                    withTimeout(2_000) { while (thread.fast != false) delay(10) }
                    // Likewise, an older release ACK cannot erase a newer
                    // capacity pause while the same host remains current.
                    thread.window = JSONObject().put("version", 1)
                    thread.liveCursor = "retained-head"
                    stream.heldControlKind = "window.release"
                    presenter.setCardVisible("visible-card", true)
                    val pendingRelease = withTimeout(2_000) { stream.heldControlRequests.receive() }
                    // Model local Core retention pressure directly. Native
                    // read/index limits use the independent read-status path.
                    connection.onCapacity?.invoke("thread")
                    connection.request(JSONObject().put("kind", "heartbeat"))
                    assertTrue(thread.paused)
                    stream.heldControlKind = null
                    stream.replyAck(pendingRelease.getString("id"))
                    withTimeout(2_000) { while (thread.window != null) delay(10) }
                    delay(150)
                    assertTrue(thread.paused)
                    assertTrue("A newer capacity event survives a release ACK", "visible-card" in presenter.state.value.ingestionCapacityThreads)
                    val capacitySubscriptions = stream.sentKinds.count { it == "subscribe" }
                    // A reader's finally block ends only its transient pause;
                    // it must not implicitly clear the service's capacity stop.
                    thread.paused = false
                    presenter.setCardVisible("visible-card", true)
                    delay(150)
                    assertNull(thread.fast)
                    assertEquals(capacitySubscriptions, stream.sentKinds.count { it == "subscribe" })
                    // When an old retained window actually releases capacity,
                    // the desired-card snapshot must be rebuilt immediately.
                    thread.window = JSONObject().put("version", 2)
                    thread.liveCursor = "old-capacity-head"
                    stream.heldControlKind = "window.release"
                    presenter.setCardVisible("visible-card", true)
                    val freesOldCapacity = withTimeout(2_000) { stream.heldControlRequests.receive() }
                    stream.heldControlKind = null
                    stream.replyAck(freesOldCapacity.getString("id"))
                    withTimeout(2_000) {
                        while (thread.fast != false || stream.sentKinds.count { it == "subscribe" } == capacitySubscriptions) delay(10)
                    }
                    assertFalse("Confirmed old-window release resumes the visible card", "visible-card" in presenter.state.value.ingestionCapacityThreads)
                    // Retiring the visible surface must not reopen a watch
                    // merely because a delayed resync arrives afterwards.
                    presenter.setCardVisible("visible-card", false)
                    withTimeout(2_000) { while (thread.fast != null) delay(10) }
                    val subscriptions = stream.sentKinds.count { it == "subscribe" }
                    stream.resync("canonicalReadFailed")
                    connection.request(JSONObject().put("kind", "heartbeat"))
                    delay(150)
                    assertEquals(subscriptions, stream.sentKinds.count { it == "subscribe" })
                } finally { presenter.close(); endpoint.close(); coordinator.close(); scope.cancel() }
            }
        }
    }

    @Test fun unsubscribeWaitsForCommittedWatchAcknowledgment(): Unit = runBlocking {
        for (transport in AgentEndpointTransport.entries) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val endpoint = ContextEndpoint(transport)
            val connection = AgentIngestionConnection.open(endpoint, scope)
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            try {
                val stream = endpoint.streams.single()
                connection.onWindowPage = { _, _ ->
                    entered.complete(Unit); release.await()
                    AgentIngestionConnection.WindowCommit(JSONObject().put("epoch", connection.epoch).put("version", 1)
                        .put("viewportSegmentIDs", JSONArray().put("head")).put("headSegmentID", "head"), true)
                }
                stream.watchWindow("watch_first")
                withTimeout(5_000) { entered.await() }
                val stop = async { connection.request(JSONObject().put("kind", "unsubscribe").put("thread", "thread")) }
                delay(100)
                assertFalse("Unsubscribe overtook Core commit's ACK", "unsubscribe" in stream.sentKinds)
                val overlap = runCatching { connection.request(JSONObject().put("kind", "subscribe").put("thread", "thread")) }
                assertEquals("controlBusy", overlap.exceptionOrNull()?.message)
                assertFalse("New subscribe overtook pending unsubscribe", "subscribe" in stream.sentKinds)
                release.complete(Unit)
                withTimeout(5_000) { stop.await() }
                val kinds = stream.sentKinds.toList()
                assertTrue(kinds.indexOf("window.ack") < kinds.indexOf("unsubscribe"))
                connection.onWindowPage = { _, _ -> fail("Paused watch must not commit"); null }
                stream.watchWindow("watch_late")
                connection.request(JSONObject().put("kind", "heartbeat"))
                assertFalse(connection.isClosed)
                connection.request(JSONObject().put("kind", "subscribe").put("thread", "thread"))
                stream.busyReads = 2
                connection.request(JSONObject().put("kind", "window.read").put("thread", "thread"))
                assertEquals(0, stream.busyReads)
                stream.busyReads = 6
                val exhausted = runCatching { connection.request(JSONObject().put("kind", "window.read").put("thread", "thread")) }
                assertEquals("busy", exhausted.exceptionOrNull()?.message)
                assertEquals("Busy retries must remain bounded", 1, stream.busyReads)
            } finally { release.complete(Unit); connection.close(); endpoint.close(); scope.cancel() }
        }
    }
    @Test fun lateCancelledSummaryDoesNotCloseSiblingRequests(): Unit = runBlocking {
        for (transport in AgentEndpointTransport.entries) {
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val endpoint = ContextEndpoint(transport)
            val connection = AgentIngestionConnection.open(endpoint, scope)
            var summaries = 0
            connection.onPage = { _, _ -> summaries++; true }
            try {
                val stream = endpoint.streams.single()
                repeat(130) {
                    val request = async { connection.request(JSONObject().put("kind", "summary").put("thread", "thread")) }
                    val id = withTimeout(5_000) { stream.summaryRequests.receive() }
                    request.cancelAndJoin()
                    stream.replySummary(id)
                    connection.request(JSONObject().put("kind", "heartbeat"))
                    assertFalse(connection.isClosed)
                }
                assertEquals(0, summaries)
                // A timeout while an existing watch drains has not written a
                // control frame. Keep this child and restore its watch state.
                val watchEntered = CompletableDeferred<Unit>()
                val releaseWatch = CompletableDeferred<Unit>()
                val watches = java.util.concurrent.atomic.AtomicInteger()
                connection.onWindowPage = { _, _ ->
                    if (watches.incrementAndGet() == 1) { watchEntered.complete(Unit); releaseWatch.await() }
                    AgentIngestionConnection.WindowCommit(JSONObject().put("epoch", connection.epoch).put("version", 1)
                        .put("viewportSegmentIDs", JSONArray().put("head")).put("headSegmentID", "head"), true)
                }
                try {
                    stream.watchWindow("watch_before_unsent_timeout")
                    withTimeout(5_000) { watchEntered.await() }
                    val unsent = runCatching { connection.request(JSONObject().put("kind", "unsubscribe")
                        .put("thread", "thread"), timeoutMillis = 75) }.exceptionOrNull()
                    assertTrue(unsent is TimeoutCancellationException)
                    assertFalse(connection.isClosed)
                    assertFalse("Unsent cancellation must not write a control", "unsubscribe" in stream.sentKinds)
                } finally { releaseWatch.complete(Unit) }
                connection.request(JSONObject().put("kind", "heartbeat"))
                stream.watchWindow("watch_after_unsent_timeout")
                connection.request(JSONObject().put("kind", "heartbeat"))
                assertEquals("Unsent cancellation must restore watch admission", 2, watches.get())

                stream.heldControlKind = "window.read"
                val read = async { connection.request(JSONObject().put("kind", "window.read").put("thread", "thread")) }
                val readID = withTimeout(5_000) { stream.heldControlRequests.receive() }.getString("id")
                read.cancelAndJoin()
                stream.heldControlKind = null
                stream.replyAck(readID)
                connection.request(JSONObject().put("kind", "heartbeat"))
                assertFalse("Ordinary page cancellation must preserve sibling reads", connection.isClosed)

                for (code in listOf("busy", "sourceUnavailable")) {
                    stream.controlRejection = code
                    for (kind in listOf("subscribe", "unsubscribe", "window.release")) {
                        val rejected = runCatching { connection.request(JSONObject().put("kind", kind).put("thread", "thread")) }
                        assertEquals(code, rejected.exceptionOrNull()?.message)
                        assertFalse("An explicit rejection is not an ambiguous commit", connection.isClosed)
                        val received = watches.get()
                        stream.watchWindow("watch_after_rejected_${kind.replace('.', '_')}_$code")
                        connection.request(JSONObject().put("kind", "heartbeat"))
                        assertEquals("Rejected controls must restore watch admission", received + 1, watches.get())
                    }
                }
                stream.controlRejection = null

                // Once any ownership-changing control reaches the wire, an
                // abandoned result retires only that child, including a late ACK.
                for (kind in listOf("subscribe", "unsubscribe", "window.release")) {
                    for (timeout in listOf(true, false)) {
                        val child = AgentIngestionConnection.open(endpoint, scope)
                        val childStream = endpoint.streams.last()
                        try {
                            childStream.heldControlKind = kind
                            val control = async { runCatching { child.request(JSONObject().put("kind", kind)
                                .put("thread", "thread"), timeoutMillis = if (timeout) 75 else 15_000) } }
                            val id = withTimeout(5_000) { childStream.heldControlRequests.receive() }.getString("id")
                            if (timeout) assertTrue(withTimeout(5_000) { control.await() }.exceptionOrNull() is TimeoutCancellationException)
                            else control.cancelAndJoin()
                            assertTrue("Abandoned $kind must retire its child", child.isClosed)
                            runCatching { childStream.replyAck(id) }
                            assertTrue(child.isClosed)
                            connection.request(JSONObject().put("kind", "heartbeat"))
                            assertFalse("A sibling duplex child must survive", connection.isClosed)
                        } finally { child.close() }
                    }
                }
            } finally { connection.close(); endpoint.close(); scope.cancel() }
        }
    }
    @Test fun explicitLatestCoalescesBehindRefreshAndClearsOnBackground(): Unit = runBlocking {
        withContext(Dispatchers.Main) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val coordinator = AndroidAgentSessionCoordinator(LiveAgentSessionRegistry())
            val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
            val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                AndroidAgentCenterViewPreferences(context), scope, integration)
            @Suppress("UNCHECKED_CAST")
            fun <T> field(name: String): T = AgentCenterPresenter::class.java.getDeclaredField(name).let {
                it.isAccessible = true; it.get(presenter) as T
            }
            try {
                presenter.setEnabled(true)
                val jobs = field<MutableMap<String, Job>>("projectionJobs")
                jobs["thread"] = scope.launch { awaitCancellation() }
                val history = field<MutableSet<String>>("pendingHistoryRequests")
                val refresh = field<MutableSet<String>>("pendingProjectionRefreshes")
                val latest = field<MutableSet<String>>("pendingLatestRequests")
                assertTrue(presenter.coalesceProjectionIfRunning("thread", "older", "before"))
                assertTrue(presenter.coalesceProjectionIfRunning("thread", null, "before"))
                assertTrue(presenter.coalesceProjectionIfRunning("thread", null, "bootstrap"))
                assertTrue(presenter.coalesceProjectionIfRunning("thread", null, "bootstrap"))
                assertEquals(setOf("thread"), latest)
                assertTrue(history.isEmpty()); assertTrue(refresh.isEmpty())
                val pendingSearch = scope.launch { awaitCancellation() }
                AgentCenterPresenter::class.java.getDeclaredField("searchJob").also { it.isAccessible = true }.set(presenter, pendingSearch)
                val progress = com.bambouville.tessera.core.bridge.SharedAgentReadStatus("preparing", "source", "continue", "readPending", "Preparing conversation…", true, false)
                val failure = com.bambouville.tessera.core.bridge.SharedAgentReadStatus("failed", "source", "manual", "sourceNotAuthorized", "The conversation could not be read.", false, true)
                field<kotlinx.coroutines.flow.MutableStateFlow<AgentCenterUiState>>("mutableState").value = presenter.state.value.copy(
                    ingestionReadStatuses = mapOf("old-read" to progress, "failed-read" to failure),
                )
                presenter.setApplicationForeground(false)
                assertTrue(latest.isEmpty()); assertTrue(jobs.isEmpty())
                assertEquals("Only preparation owned by retired reads is cleared", mapOf("failed-read" to failure), presenter.state.value.ingestionReadStatuses)
                assertTrue(pendingSearch.isCancelled)
                assertNull(field<Job?>("searchJob"))
                presenter.search("background query")
                assertNull(field<Job?>("searchJob"))
            } finally { presenter.close(); scope.cancel() }
        }
    }

    @Test fun retiringOneReaderKeepsSiblingProgressAndTerminalFailures(): Unit = runBlocking {
        withContext(Dispatchers.Main) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val coordinator = AndroidAgentSessionCoordinator(LiveAgentSessionRegistry())
            val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
            val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                AndroidAgentCenterViewPreferences(context), scope, integration)
            val endpoint = ContextEndpoint(AgentEndpointTransport.SSH_TMUX)
            val siblingEndpoint = ContextEndpoint(AgentEndpointTransport.MOSH_TMUX)
            try {
                presenter.setEnabled(true)
                val retired = presenter.nativeConnection(endpoint)
                val sibling = presenter.nativeConnection(siblingEndpoint)
                retired.first.threads["retired"] = AgentCenterPresenter.NativeThread("retired_handle")
                retired.first.threads["failed"] = AgentCenterPresenter.NativeThread("failed_handle")
                sibling.first.threads["sibling"] = AgentCenterPresenter.NativeThread("sibling_handle")
                fun status(state: String, recovery: String) = checkNotNull(com.bambouville.tessera.core.bridge.SharedAgentReadStatus.decode(
                    JSONObject().put("v", 1).put("state", state).put("domain", "source")
                        .put("recovery", recovery).put("code", "readPending")))
                val progress = status("preparing", "continue")
                val failure = status("failed", "manual")
                @Suppress("UNCHECKED_CAST")
                val state = AgentCenterPresenter::class.java.getDeclaredField("mutableState").let {
                    it.isAccessible = true; it.get(presenter) as MutableStateFlow<AgentCenterUiState>
                }
                state.value = presenter.state.value.copy(ingestionReadStatuses = mapOf(
                    "retired" to progress, "failed" to failure, "sibling" to progress))
                retired.second.close()
                val reopened = presenter.nativeConnection(endpoint)
                assertNotSame(retired.first, reopened.first)
                assertEquals(mapOf("failed" to failure, "sibling" to progress), presenter.state.value.ingestionReadStatuses)
                assertFalse(sibling.second.isClosed)
            } finally {
                presenter.close(); endpoint.close(); siblingEndpoint.close()
                integration.close(); coordinator.close(); scope.cancel()
            }
        }
    }

    @Test fun contextAliasesDoNotReplaceAdmittedHostsOrCancelSiblingWaiters(): Unit = runBlocking {
        withTimeout(60_000) { withContext(Dispatchers.Main) {
            for (transport in AgentEndpointTransport.entries) {
                val context = InstrumentationRegistry.getInstrumentation().targetContext
                val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
                val registry = LiveAgentSessionRegistry()
                val coordinator = AndroidAgentSessionCoordinator(registry)
                val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
                val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                    AndroidAgentCenterViewPreferences(context), scope, integration)
                val endpoint = ContextEndpoint(transport)
                try {
                    presenter.setEnabled(true)
                    val baseline = presenter.nativeConnection(endpoint)
                    presenter.requireCurrentNativeConnection(baseline.first, baseline.second)
                    val first = async { presenter.nativeConnection(endpoint, 42, "incarnation") }
                    val second = async { presenter.nativeConnection(endpoint, 42, "incarnation") }
                    val cancelled = async { presenter.nativeConnection(endpoint, 42, "incarnation") }
                    endpoint.entered.await()
                    cancelled.cancel(); endpoint.release.complete(Unit)
                    val a = first.await(); val b = second.await()
                    assertSame(baseline.first, a.first); assertSame(baseline.first, b.first)
                    assertTrue(cancelled.isCancelled)
                    assertSame(baseline.first, presenter.nativeConnection(endpoint, 42, "incarnation").first)
                    val other = presenter.nativeConnection(endpoint, 99, "incarnation")
                    assertNotSame(baseline.first, other.first)
                    assertSame(baseline.first, presenter.nativeConnection(endpoint).first)
                    presenter.claimNativeThread("collision", baseline.first)
                    assertTrue(runCatching { presenter.claimNativeThread("collision", other.first) }.isFailure)
                    val otherSession = ContextEndpoint(transport)
                    try {
                        val foreign = presenter.nativeConnection(otherSession, 99, "incarnation")
                        assertTrue(runCatching { presenter.claimNativeThread("collision", foreign.first) }.isFailure)
                    } finally { otherSession.close() }
                    baseline.second.request(JSONObject().put("kind", "heartbeat"))
                    assertEquals(listOf(0, 42, 99), endpoint.contexts)
                    val abandoned = async { presenter.nativeConnection(endpoint, 200, "incarnation") }
                    withTimeout(5_000) { while (200 !in endpoint.contexts) delay(10) }
                    abandoned.cancelAndJoin()
                    withTimeout(5_000) { endpoint.abandonedOpeningCancelled.await() }
                    assertFalse(baseline.second.isClosed)
                    withTimeout(5_000) { while (endpoint.streams.count { it.closed } != 1) delay(10) }
                    // Background closes each unique scope once; aliases must
                    // not retain a leased channel or affect another app process.
                    presenter.setApplicationForeground(false)
                    assertEquals("projectionInactive", runCatching {
                        presenter.requireCurrentNativeConnection(baseline.first, baseline.second)
                    }.exceptionOrNull()?.message)
                    withTimeout(5_000) { while (!endpoint.streams.all { it.closed }) delay(10) }
                    endpoint.processExited = true
                    presenter.setApplicationForeground(true)
                    val resumed = presenter.nativeConnection(endpoint, 42, "incarnation")
                    assertEquals("0000000000000001", resumed.second.contextScope)
                    assertEquals(listOf("0000000000000001"), endpoint.scopeRequests)
                    // A published helper upgrade ends the leased stream while
                    // the app stays foreground. Concurrent users reconnect to
                    // one new epoch, retaining the frozen provider scope.
                    val successfulReply = CompletableDeferred<Unit>()
                    val resumeCommit = CompletableDeferred<Unit>()
                    val staleSummary = async {
                        resumed.second.request(JSONObject().put("kind", "summary").put("thread", "thread"))
                        successfulReply.complete(Unit)
                        resumeCommit.await()
                        runCatching { presenter.requireCurrentNativeConnection(resumed.first, resumed.second) }
                            .exceptionOrNull()?.message
                    }
                    val activeStream = endpoint.streams.last { !it.closed }
                    activeStream.replySummary(withTimeout(5_000) { activeStream.summaryRequests.receive() })
                    withTimeout(5_000) { successfulReply.await() }
                    val retiredThread = AgentCenterPresenter.NativeThread("thread").also {
                        it.liveCursor = "retained-before-retirement"
                    }
                    resumed.first.threads["retired"] = retiredThread
                    endpoint.serviceGeneration++
                    endpoint.streams.forEach { it.close() }
                    withTimeout(5_000) { while (!resumed.second.isClosed) delay(10) }
                    // The host is still in the pool here. A successful page
                    // or metadata reply queued just before EOF must not use
                    // pool membership alone to resurrect that retired epoch.
                    assertEquals("staleEpoch", runCatching {
                        presenter.requireCurrentNativeConnection(resumed.first, resumed.second)
                    }.exceptionOrNull()?.message)
                    resumeCommit.complete(Unit)
                    assertEquals("staleEpoch", withTimeout(5_000) { staleSummary.await() })
                    resumed.second.onResync?.invoke("thread")
                    resumed.second.onCapacity?.invoke("thread")
                    assertEquals("retained-before-retirement", retiredThread.liveCursor)
                    assertFalse("Retired callbacks must not poison current UI", "retired" in presenter.state.value.ingestionCapacityThreads)
                    val reconnectA = async { presenter.nativeConnection(endpoint, 42, "incarnation") }
                    val reconnectB = async { presenter.nativeConnection(endpoint, 42, "incarnation") }
                    val upgraded = reconnectA.await()
                    assertSame(upgraded.first, reconnectB.await().first)
                    assertNotSame(resumed.first, upgraded.first)
                    assertEquals("fixture_1", upgraded.second.epoch)
                    assertEquals("0000000000000001", upgraded.second.contextScope)
                    presenter.requireCurrentNativeConnection(upgraded.first, upgraded.second)
                    assertEquals("staleEpoch", runCatching {
                        presenter.requireCurrentNativeConnection(resumed.first, resumed.second)
                    }.exceptionOrNull()?.message)
                    upgraded.second.request(JSONObject().put("kind", "heartbeat"))
                    presenter.setApplicationForeground(false)
                    endpoint.processExited = false
                    presenter.setApplicationForeground(true)
                    val hosts = (100..107).map { presenter.nativeConnection(endpoint, it, "incarnation") }
                    hosts.forEach { it.second.close() }
                    assertFalse(presenter.nativeConnection(endpoint, 108, "incarnation").second.isClosed)
                    // Hundreds of completed incarnations may alias one
                    // service. Only a still-owned historical context must
                    // survive pressure and an app-background boundary.
                    val historical = presenter.nativeConnection(endpoint, 300, "incarnation")
                    @Suppress("UNCHECKED_CAST")
                    val owners = AgentCenterPresenter::class.java.getDeclaredField("threadOwners").let {
                        it.isAccessible = true
                        it.get(presenter) as MutableMap<String, AgentCenterPresenter.ThreadOwner>
                    }
                    owners["historical"] = AgentCenterPresenter.ThreadOwner(endpoint.key, "{}",
                        JSONObject().put("agentPID", 300).put("incarnation", JSONObject().put("rawValue", "incarnation")).toString(), "historical-token")
                    for (pid in 301..460) assertFalse(presenter.nativeConnection(endpoint, pid, "incarnation").second.isClosed)
                    assertSame(historical.first, presenter.nativeConnection(endpoint, 300, "incarnation").first)
                    presenter.setApplicationForeground(false)
                    endpoint.processExited = true
                    presenter.setApplicationForeground(true)
                    assertEquals("0000000000000001", presenter.nativeConnection(endpoint, 300, "incarnation").second.contextScope)
                    presenter.setEnabled(false)
                    val scopes = AgentCenterPresenter::class.java.getDeclaredField("ingestionScopes").let {
                        it.isAccessible = true; it.get(presenter) as Map<*, *>
                    }
                    assertTrue("Disable must retire cached context aliases", scopes.isEmpty())
                } finally {
                    presenter.close(); scope.cancel(); endpoint.close(); coordinator.close()
                }
            }
        } }
    }

    private class ContextStream(private val epoch: String, contextScope: String, readProgress: Boolean = false) : AgentRemoteExecStream {
        val sentKinds = java.util.concurrent.CopyOnWriteArrayList<String>()
        val sentRequests = java.util.concurrent.CopyOnWriteArrayList<JSONObject>()
        @Volatile var busyReads = 0
        @Volatile var heldControlKind: String? = null
        @Volatile var controlRejection: String? = null
        val heldControlRequests = Channel<JSONObject>(Channel.UNLIMITED)
        val summaryRequests = Channel<String>(Channel.UNLIMITED)
        private val frames = Channel<ByteArray>(16)
        @Volatile var closed = false; private set
        init { frames.trySend(AgentIngestionConnection.frame(JSONObject().put("kind", "hello").put("id", "hello")
            .put("v", 3).put("serviceEpoch", epoch).put("contextScope", contextScope)
            .put("capabilities", JSONArray(listOf("bounded.windows", "window.partitions") + if (readProgress) listOf("read.progress.v1") else emptyList<String>())))) }
        override val stdout = frames.receiveAsFlow()
        override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
        override suspend fun awaitExit(): AgentExecExitStatus { while (!closed) delay(20); return AgentExecExitStatus(0) }
        override suspend fun send(bytes: ByteArray) {
            val request = JSONObject(bytes.copyOfRange(4, bytes.size).decodeToString())
            sentKinds.add(request.getString("kind"))
            sentRequests.add(request)
            if (request.getString("kind") == "window.read" && busyReads > 0) {
                busyReads--
                frames.send(AgentIngestionConnection.frame(JSONObject().put("kind", "error").put("code", "busy")
                    .put("id", request.getString("id")).put("serviceEpoch", epoch)))
                return
            }
            if (request.getString("kind") == "summary") { summaryRequests.send(request.getString("id")); return }
            if (request.getString("kind") in setOf("subscribe", "unsubscribe", "window.release")) controlRejection?.let { code ->
                frames.send(AgentIngestionConnection.frame(JSONObject().put("kind", "error").put("code", code)
                    .put("id", request.getString("id")).put("serviceEpoch", epoch)))
                return
            }
            if (request.getString("kind") == heldControlKind) { heldControlRequests.send(request); return }
            replyAck(request.getString("id"))
        }
        suspend fun replyAck(id: String) {
            frames.send(AgentIngestionConnection.frame(JSONObject().put("kind", "ack")
                .put("id", id).put("serviceEpoch", epoch)))
        }
        suspend fun replySummary(id: String) {
            frames.send(AgentIngestionConnection.frame(JSONObject().put("kind", "summary").put("id", id)
                .put("serviceEpoch", epoch).put("thread", "thread").put("revision", "revision").put("modified", 1)
                .put("records", JSONArray())))
        }
        suspend fun resync(reason: String) {
            frames.send(AgentIngestionConnection.frame(JSONObject().put("kind", "resyncRequired")
                .put("thread", "thread").put("serviceEpoch", epoch).put("reason", reason)))
        }
        suspend fun inject(value: JSONObject) { frames.send(AgentIngestionConnection.frame(value.put("serviceEpoch", epoch))) }
        suspend fun progress(id: String, thread: String = "thread", sequence: String, bytes: String) {
            inject(JSONObject().put("kind", "read.progress").put("id", id).put("thread", thread)
                .put("sequence", sequence).put("bytesRead", bytes).put("status", JSONObject().put("v", 1)
                    .put("state", "preparing").put("domain", "source").put("recovery", "continue").put("code", "readPending")))
        }
        suspend fun watchWindow(id: String) {
            for (kind in listOf("page.begin", "page.end")) frames.send(AgentIngestionConnection.frame(
                JSONObject().put("kind", kind).put("id", id).put("thread", "thread").put("serviceEpoch", epoch)
                    .put("sourceIdentity", "fixture").put("window", JSONObject().put("version", 1))))
        }
        override fun cancel() { closed = true; frames.close() }
        override fun close() = cancel()
    }

    private class ContextEndpoint(transport: AgentEndpointTransport, private val readProgress: Boolean = false) : AgentSessionEndpoint {
        override val key = AgentSessionKey(UUID.randomUUID().toString(), 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key, UUID.randomUUID().toString(), transport))
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames = emptyFlow<AgentLifecycleFrame>()
        val contexts = mutableListOf<Int>()
        val scopeRequests = mutableListOf<String>()
        var processExited = false
        var serviceGeneration = 0
        val streams = mutableListOf<ContextStream>()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        val abandonedOpeningCancelled = CompletableDeferred<Unit>()
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> {
            check(request.executable == "tessera-agent-host" && isCurrentIngestion(binding))
            val hello = JSONObject(request.stdin.copyOfRange(4, request.stdin.size).decodeToString())
            if (hello.has("contextScope")) scopeRequests.add(hello.getString("contextScope"))
            else check(!processExited) { "contextProcessUnavailable" }
            val pid = hello.optInt("contextPID", 0); contexts.add(pid)
            if (pid == 200) {
                try { delay(30_000) } catch (cancelled: CancellationException) {
                    abandonedOpeningCancelled.complete(Unit); throw cancelled
                }
            }
            if (pid == 42) { entered.complete(Unit); release.await() }
            val separateScope = pid >= 99 && pid !in 300..499
            val epoch = if (separateScope) "scope_$pid" else "fixture"
            val stream = ContextStream(if (serviceGeneration == 0) epoch else "${epoch}_$serviceGeneration",
                if (separateScope) "%016x".format(pid) else "0000000000000001", readProgress)
            streams.add(stream); return AgentEndpointResult.Success(stream)
        }
        override fun close() { streams.forEach { it.close() } }
        private fun unavailable() = AgentEndpointResult.Unavailable("synthetic context fixture")
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> = unavailable()
        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider, requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> = unavailable()
        override suspend fun processDiscoveryScope(binding: AgentEndpointBinding): AgentEndpointResult<AgentProcessDiscoveryScope> = unavailable()
        override suspend fun probeIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationStatus> = unavailable()
        override suspend fun readIntegrationConfigs(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationConfigSnapshots> = unavailable()
        override suspend fun installIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> = unavailable()
        override suspend fun inspectCurrentShell(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentCurrentShellStatus> = unavailable()
        override suspend fun discoverProcesses(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentProcessDiscoverySnapshot> = unavailable()
        override suspend fun activateCurrentShell(binding: AgentEndpointBinding, expectedProcessIDs: Set<Int>, command: AgentShellActivationCommand): AgentEndpointResult<Unit> = unavailable()
        override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> = unavailable()
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> = unavailable()
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> = unavailable()
        override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> = unavailable()
        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> = unavailable()
        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> = unavailable()
    }
}
