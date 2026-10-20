package com.bambouville.tessera.feature.agentcenter

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import com.bambouville.tessera.design.TesseraTheme
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.util.UUID

/** Starts at lifecycle detection, not at nativeConnection or a prebuilt Core
 * detail. Exercises the production owner -> native wire -> JNI -> Compose path.
 * The endpoint is synthetic; no user host connections or provider data. */
class AgentDetectedConversationInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()

    @Test fun refusedEndAndBlankExitRetireTheFieldOrphanAcrossTmuxTransports() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val registry = LiveAgentSessionRegistry()
            val coordinator = AndroidAgentSessionCoordinator(registry)
            val endpoint = DetectedEndpoint(transport, "claude")
            endpoint.occupancyEnabled = true; endpoint.agentPID = 95076
            endpoint.binding.value = endpoint.binding.value.copy(paneID = "%75")
            val registration = registry.register(endpoint)
            val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
            val logs = java.util.concurrent.CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
            val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                AndroidAgentCenterViewPreferences(context), scope, integration, diagnostics = { code, fields -> logs.add(code to fields) })
            fun frame(session: String, pid: Int?, event: String) = AgentLifecycleFrame(endpoint.binding.value, JSONObject()
                .put("version", 9).put("provider", "claude").put("event", event).put("state", if (event == "SessionEnd" || event == "WrapperExit") "unavailable" else "idle")
                .put("timestampNs", "${System.nanoTime()}").put("sessionId", session).putOpt("agentPid", pid)
                .put("transcriptRef", "b3BhcXVl").toString().encodeToByteArray())
            suspend fun <T> step(name: String, block: suspend () -> T): T = withTimeoutOrNull(10_000) { block() }
                ?: throw AssertionError("$transport $name timed out; rows=${presenter.state.value.threads.map { it.providerSessionID }} " +
                    "details=${presenter.state.value.projectedDetails.values.map { "${it.row.providerSessionID}:live=${it.live.size}:window=${it.window}" }} " +
                    "reads=${presenter.state.value.ingestionReadStatuses} operations=${endpoint.operations} logs=$logs")
            try {
                withContext(Dispatchers.Main) { presenter.setEnabled(true) }
                val old = endpoint.session
                endpoint.lifecycleFrames.emit(frame(old, 95076, "SessionStart"))
                step("first row") { presenter.state.first { it.threads.singleOrNull()?.providerSessionID == old } }
                // Expire the coordinator memo without a ten-second device wait.
                val memo = coordinator.javaClass.getDeclaredField("issuedRoutes").also { it.isAccessible = true }.get(coordinator)
                memo.javaClass.getDeclaredMethod("clear").also { it.isAccessible = true }.invoke(memo)
                endpoint.processActive = false
                endpoint.lifecycleFrames.emit(frame(old, 95076, "SessionEnd"))
                step("refused SessionEnd") { while (logs.none { it.first == "agent_lifecycle_refused" &&
                    it.second["detail"].orEmpty().contains("proof_exit_1") }) delay(10) }
                endpoint.lifecycleFrames.emit(frame("", null, "WrapperExit"))
                endpoint.session = UUID.randomUUID().toString(); endpoint.agentPID = 2; endpoint.processActive = true
                endpoint.lifecycleFrames.emit(frame(endpoint.session, 2, "SessionStart"))
                val kept = step("successor only") { presenter.state.first { it.threads.map { row -> row.providerSessionID } == listOf(endpoint.session) } }
                assertFalse(kept.projectedDetails.containsKey(canonicalAgentThreadKey(endpoint.binding.value.hostID, "claude", old)))
                assertTrue(logs.any { it.first == "agent_route_retired" && it.second["pane"] == "%75" && it.second["pid"] == "95076" })
                val successor = canonicalAgentThreadKey(endpoint.binding.value.hostID, "claude", endpoint.session)
                withContext(Dispatchers.Main) {
                    presenter.setOpenDetail(successor); presenter.select(successor); presenter.setCardVisible(successor, true)
                }
                step("successor transcript") { presenter.state.first { it.projectedDetails.values.any { detail ->
                    detail.row.providerSessionID == endpoint.session && detail.live.isNotEmpty() } } }
            } finally {
                withContext(Dispatchers.Main) { presenter.close() }
                registration.close(); integration.close(); coordinator.close(); scope.cancel(); endpoint.close()
            }
        }
    }

    @Test fun sourceMissingAtFirstResolveRecoversWithoutAnotherLifecycleFrame() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val registry = LiveAgentSessionRegistry()
        val coordinator = AndroidAgentSessionCoordinator(registry)
        val endpoint = DetectedEndpoint(AgentEndpointTransport.SSH_TMUX, "claude")
        endpoint.sourceMissing = true
        val registration = registry.register(endpoint)
        val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
        val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
            AndroidAgentCenterViewPreferences(context), scope, integration)
        try {
            withContext(Dispatchers.Main) { presenter.setEnabled(true) }
            endpoint.lifecycleFrames.emit(AgentLifecycleFrame(endpoint.binding.value, JSONObject()
                .put("version", 9).put("provider", "claude").put("event", "SessionStart").put("state", "idle")
                .put("timestampNs", "1").put("sessionId", endpoint.session).put("agentPid", 102)
                .put("transcriptRef", "b3BhcXVl").toString().encodeToByteArray()))
            val key = canonicalAgentThreadKey(endpoint.binding.value.hostID, "claude", endpoint.session)
            // The reader is looking at Agent Center while the CLI has yet to
            // create its transcript (a fresh /clear or /resume successor);
            // only an open detail keeps its live window.
            withTimeout(10_000) { presenter.state.first { it.threads.any { row -> row.key == key } } }
            withContext(Dispatchers.Main) { presenter.setOpenDetail(key); presenter.select(key); presenter.setCardVisible(key, true) }
            withTimeout(10_000) { presenter.state.first { it.ingestionReadStatuses[key]?.code == "sourceMissing" } }
            endpoint.sourceMissing = false
            // The page lands through Core before the reader clears its status:
            // wait for both, then make sure no stale failed read restores it.
            withTimeout(10_000) { presenter.state.first {
                it.projectedDetails[key]?.live?.isNotEmpty() == true && it.ingestionReadStatuses[key] == null } }
            assertTrue("operations=${endpoint.operations}", endpoint.operations.count { it == "resolve" } >= 2)
            delay(1_500)
            assertNull(presenter.state.value.ingestionReadStatuses[key])
            assertTrue("details=${presenter.state.value.projectedDetails.mapValues { it.value.live.size }} operations=${endpoint.operations}",
                presenter.state.value.projectedDetails[key]?.live?.isNotEmpty() == true)
        } finally {
            withContext(Dispatchers.Main) { presenter.close() }
            registration.close(); integration.close(); coordinator.close(); scope.cancel(); endpoint.close()
        }
    }

    @Test fun initialHistoryPrefetchIsThreePagesAndYieldsToSendAcrossTransports() = runBlocking {
        for (transport in AgentEndpointTransport.entries) for (olderPages in listOf(0, 1, 5)) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val registry = LiveAgentSessionRegistry()
            val coordinator = AndroidAgentSessionCoordinator(registry)
            val endpoint = DetectedEndpoint(transport, "codex", olderPages)
            val registration = registry.register(endpoint)
            val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
            val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                AndroidAgentCenterViewPreferences(context), scope, integration)
            try {
                withContext(Dispatchers.Main) { presenter.setEnabled(true) }
                endpoint.lifecycleFrames.emit(AgentLifecycleFrame(endpoint.binding.value, JSONObject()
                    .put("version", 9).put("provider", "codex").put("event", "SessionStart").put("state", "idle")
                    .put("timestampNs", "1").put("sessionId", endpoint.session).put("agentPid", 102)
                    .put("transcriptRef", "b3BhcXVl").toString().encodeToByteArray()))
                val row = withTimeout(10_000) { presenter.state.first { it.threads.isNotEmpty() } }.threads.single()
                withContext(Dispatchers.Main) { presenter.setOpenDetail(row.key); presenter.select(row.key) }
                withTimeout(10_000) { presenter.state.first { it.detail?.live?.size == minOf(olderPages + 1, 3) } }
                withTimeout(5_000) { while (endpoint.operations.count { it == "window.ack" } < minOf(olderPages + 1, 3)) delay(10) }
                assertEquals("Initial reads use three ordinary protocol pages at most", minOf(olderPages, 2), endpoint.olderReads)
                assertEquals("The newest page remains retained", "history-record-0", presenter.state.value.detail!!.live.last().recordID)
                assertTrue("Each visible page is acknowledged", endpoint.operations.count { it == "window.ack" } >= minOf(olderPages + 1, 3))
                assertEquals("Every page is acknowledged before the next optional read",
                    List(minOf(olderPages + 1, 3)) { listOf("window.read", "window.ack") }.flatten(),
                    endpoint.operations.filter { it == "window.read" || it == "window.ack" }.take(minOf(olderPages + 1, 3) * 2))
                if (olderPages == 5) {
                    withContext(Dispatchers.Main) {
                        endpoint.holdOlder = true
                        presenter.loadNewer(row.key, latest = true)
                    }
                    withTimeout(10_000) { endpoint.heldOlder.receive() }
                    assertTrue("Newest replacement publishes before held history", presenter.state.value.detail!!.live.any { it.recordID == "history-record-0" })
                    assertFalse("Optional history does not keep the foreground spinner open", row.key in presenter.state.value.loadingTranscriptThreads)
                    withContext(Dispatchers.Main) { presenter.setOpenDetail(null); presenter.select(null) }
                    withTimeout(3_000) { while ("window.cancel" !in endpoint.operations) delay(10) }
                    endpoint.releaseHeldOlder()
                    withContext(Dispatchers.Main) {
                        presenter.setOpenDetail(row.key); presenter.select(row.key)
                        presenter.loadNewer(row.key, latest = true)
                    }
                    withTimeout(10_000) { endpoint.heldOlder.receive() }
                    val connectionsBeforeBackground = endpoint.contexts.size
                    withContext(Dispatchers.Main) { presenter.setApplicationForeground(false) }
                    endpoint.releaseHeldOlder()
                    endpoint.holdOlder = false
                    withContext(Dispatchers.Main) { presenter.setApplicationForeground(true) }
                    withTimeout(10_000) { presenter.state.first { it.detail?.live?.size == 3 && endpoint.contexts.size > connectionsBeforeBackground } }
                    withContext(Dispatchers.Main) {
                        endpoint.holdOlder = true
                        presenter.loadNewer(row.key, latest = true)
                    }
                    withTimeout(10_000) { endpoint.heldOlder.receive() }
                    val cancelsBeforeSend = endpoint.operations.count { it == "window.cancel" }
                    withContext(Dispatchers.Main) {
                        check(presenter.requestAction(checkNotNull(presenter.state.value.detail), "send", "fixture send"))
                    }
                    withTimeout(3_000) { while (endpoint.submittedKeys.isEmpty()) delay(10) }
                    assertEquals("Held optional history must not delay Send", listOf(AgentSemanticKey.RETURN), endpoint.submittedKeys.toList())
                    withTimeout(3_000) { while (endpoint.operations.count { it == "window.cancel" } == cancelsBeforeSend) delay(10) }
                    endpoint.releaseHeldOlder()
                    delay(100)
                    assertEquals("Late canceled page cannot extend the new window", 1, presenter.state.value.detail!!.live.size)
                }
            } finally {
                withContext(Dispatchers.Main) { presenter.close() }
                registration.close(); integration.close(); coordinator.close(); scope.cancel(); endpoint.close()
            }
        }
    }

    @Test fun detectedCodexAndClaudeLoadAcrossEveryTransport() = runBlocking {
        for (transport in AgentEndpointTransport.entries) for (provider in listOf("codex", "claude")) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val registry = LiveAgentSessionRegistry()
            val coordinator = AndroidAgentSessionCoordinator(registry)
            val endpoint = DetectedEndpoint(transport, provider)
            val registration = registry.register(endpoint)
            val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
            val logs = java.util.concurrent.CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
            val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                AndroidAgentCenterViewPreferences(context), scope, integration, diagnostics = { event, fields ->
                    logs.add(event to fields)
                    if (event == "agent_send_latency" && fields["stage"] == "receipt_ready") endpoint.receiptArmed = true
                })
            try {
                withContext(Dispatchers.Main) {
                    // Initial default preferences can disable before DataStore
                    // supplies the saved enabled value; reactivation must not
                    // retain the disabled empty-state over populated rows.
                    presenter.setEnabled(true)
                    presenter.setEnabled(false)
                    assertEquals("Agent Center is disabled", presenter.state.value.unavailableReason)
                    presenter.setEnabled(true)
                    assertNull(presenter.state.value.unavailableReason)
                }
                endpoint.lifecycleFrames.emit(AgentLifecycleFrame(endpoint.binding.value, JSONObject()
                    .put("version", 9).put("provider", provider).put("event", "SessionStart").put("state", "idle")
                    .put("timestampNs", "1").put("sessionId", endpoint.session).put("agentPid", 102)
                    .put("transcriptRef", "b3BhcXVl").toString().encodeToByteArray()))
                val row = withTimeout(10_000) { presenter.state.first { it.threads.isNotEmpty() } }.threads.single()
                withContext(Dispatchers.Main) {
                    presenter.setOpenDetail(row.key); presenter.select(row.key); presenter.setCardVisible(row.key, true)
                }
                compose.runOnUiThread { compose.activity.installFixture { TesseraTheme {
                    val state by presenter.state.collectAsState()
                    AgentDetailPane(state.detail, "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {},
                        Modifier.fillMaxSize().safeDrawingPadding())
                } } }
                compose.waitUntil(15_000) { presenter.state.value.detail?.live?.isNotEmpty() == true }
                compose.waitUntil(5_000) { compose.onAllNodesWithText("Detected $provider reply").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("Detected $provider reply").assertIsDisplayed()
                compose.waitUntil(10_000) { presenter.state.value.threads.any { it.title == "Detected $provider title" } }
                compose.waitUntil(5_000) { presenter.state.value.detail?.row?.title == "Detected $provider title" }
                compose.onNodeWithText("Detected $provider title").assertIsDisplayed()
                assertTrue("context PID must survive owner storage", 102 in endpoint.contexts)
                assertTrue("production resolve was reached", "resolve" in endpoint.operations)
                assertTrue("production page was ACKed", "window.ack" in endpoint.operations)
                assertTrue(logs.any { it.first == "agent_ingestion_commit" && it.second["accepted"] == "true" })
                assertFalse(logs.any { it.first == "agent_ingestion_projection_failed" })
                // Unlike a direct receipt probe, this round-trips the actual
                // Core action lease, whose address omits host display metadata.
                // A named host must still reach receipt -> insert -> submit.
                if (provider == "codex") {
                    withContext(Dispatchers.Main) {
                        endpoint.expectReceiptBarrier = true
                        check(presenter.requestAction(checkNotNull(presenter.state.value.detail), "send", "fixture send"))
                    }
                    withTimeout(10_000) {
                        presenter.state.first { it.sendingThreads.isEmpty() }
                    }
                    assertEquals("Named host send must reach the terminal after receipt arming; diagnostics=$logs",
                        listOf(AgentSemanticKey.RETURN), endpoint.submittedKeys.toList())
                    assertEquals(listOf("fixture send"), endpoint.insertions.toList())
                    compose.waitUntil(10_000) { presenter.state.value.detail?.live?.any { it.recordID == "preexisting-matching" } == true }
                    assertTrue("An identical line already below the pre-send EOF cannot confirm this send",
                        presenter.state.value.detail!!.outgoingMessages.any { it.text == "fixture send" })
                    assertTrue(endpoint.receiptRaceEmitted)
                    assertTrue("Send obtains a fresh frontier independently of history", "receipt.frontier" in endpoint.operations)
                    assertTrue("Uncached process checks are required before text and Enter", endpoint.proofs >= 3)

                    withContext(Dispatchers.Main) {
                        endpoint.receiptArmed = false
                        endpoint.replaceDuringCaptureWait = true
                        check(presenter.requestAction(checkNotNull(presenter.state.value.detail), "send", "must not reach replaced process"))
                    }
                    withTimeout(10_000) { presenter.state.first { it.sendingThreads.isEmpty() } }
                    assertFalse("The frame-wait scenario must exercise actual mutation inspection", endpoint.replaceDuringCaptureWait)
                    assertEquals("A frame wait invalidates its preceding PID/start proof", 1, endpoint.insertions.size)
                    assertEquals(1, endpoint.submittedKeys.size)
                    endpoint.processStart = "fixture-start"

                    // The memo remains valid locally, but the remote provider
                    // exits while the fresh transcript boundary is read.
                    withContext(Dispatchers.Main) {
                        endpoint.exitDuringReceipt = true
                        check(presenter.requestAction(checkNotNull(presenter.state.value.detail), "send", "must not reach shell"))
                    }
                    withTimeout(10_000) { presenter.state.first { it.sendingThreads.isEmpty() } }
                    assertEquals("An exited provider must receive neither text nor Enter", 1, endpoint.insertions.size)
                    assertEquals(1, endpoint.submittedKeys.size)
                    // PID reuse after the text write is still unsafe even if a
                    // new process with the same provider name owns that PID.
                    withContext(Dispatchers.Main) {
                        endpoint.processActive = true; endpoint.replaceAfterText = true
                        check(presenter.requestAction(checkNotNull(presenter.state.value.detail), "send", "must not submit"))
                    }
                    withTimeout(10_000) { presenter.state.first { it.sendingThreads.isEmpty() } }
                    assertEquals(listOf("fixture send", "must not submit"), endpoint.insertions.toList())
                    assertEquals("Replaced process must not receive Enter", 1, endpoint.submittedKeys.size)
                }
                withContext(Dispatchers.Main) { presenter.setOpenDetail(row.key); presenter.search("Detected") }
                compose.waitUntil(10_000) { "bootstrap" in endpoint.operations }
                compose.waitUntil(10_000) { presenter.state.value.searchResults.isNotEmpty() }
                val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
                File(context.filesDir, "agent-detected-$provider-${transport.name}.png").outputStream().use {
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
                android.util.Log.i("TesseraAgentWindow", "TESSERA_AGENT_DETECTED_OK $provider $transport")
            } finally {
                android.util.Log.i("TesseraAgentWindow", "DETECTED_FIXTURE $provider $transport operations=${endpoint.operations} diagnostics=$logs")
                withContext(Dispatchers.Main) { presenter.close() }
                registration.close(); integration.close(); coordinator.close(); scope.cancel(); endpoint.close()
            }
        }
    }

    /** `/clear` and `/new` start another conversation in the same agent
     * process and pane. The old one leaves the list and gives up its owner,
     * and a reader on it follows to the conversation the pane runs now. */
    @Test fun clearedConversationLeavesTheListAcrossEveryTransport() = runBlocking {
        for (transport in AgentEndpointTransport.entries) for (provider in listOf("codex", "claude")) for (startFirst in listOf(false, true)) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val registry = LiveAgentSessionRegistry()
            val coordinator = AndroidAgentSessionCoordinator(registry)
            val endpoint = DetectedEndpoint(transport, provider)
            val registration = registry.register(endpoint)
            val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
            val logs = java.util.concurrent.CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
            val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                AndroidAgentCenterViewPreferences(context), scope, integration, diagnostics = { event, fields -> logs.add(event to fields) })
            val before = endpoint.session
            val after = UUID.randomUUID().toString()
            val child = UUID.randomUUID().toString()
            val newChild = UUID.randomUUID().toString()
            fun frame(event: String, state: String, session: String, at: Int, agentID: String? = null) = AgentLifecycleFrame(endpoint.binding.value, JSONObject()
                .put("version", 9).put("provider", provider).put("event", event).put("state", state)
                .put("timestampNs", "$at").put("sessionId", session).put("agentPid", 102).putOpt("agentId", agentID)
                .put("transcriptRef", when (session) { before -> "b3BhcXVl"; child -> "Y2hpbGQ"; newChild -> "bmV3Y2hpbGQ"; else -> "YWZ0ZXI" })
                .toString().encodeToByteArray())
            val label = "$provider $transport ${if (startFirst) "start-first" else "end-first"}"
            suspend fun awaitState(step: String, predicate: (AgentCenterUiState) -> Boolean): AgentCenterUiState = try {
                withTimeout(10_000) { presenter.state.first(predicate) }
            } catch (timeout: TimeoutCancellationException) {
                val state = presenter.state.value
                throw AssertionError("$label: $step timed out; threads=${state.threads.map { it.providerSessionID.take(8) }} " +
                    "selected=${state.selectedThreadKey} detail=${state.detail?.row?.providerSessionID?.take(8)} diagnostics=$logs")
            }
            try {
                withContext(Dispatchers.Main) { presenter.setEnabled(true) }
                endpoint.lifecycleFrames.emit(frame("UserPromptSubmit", "working", before, 1))
                val old = awaitState("first conversation") { it.threads.isNotEmpty() }.threads.single()
                withContext(Dispatchers.Main) { presenter.setOpenDetail(old.key); presenter.select(old.key) }
                awaitState("first detail") { it.detail?.row?.key == old.key }
                // A Codex child agent reports under its own thread in the
                // same process; it runs beside the conversation and ends with it.
                if (provider == "codex") {
                    endpoint.lifecycleFrames.emit(frame("PermissionRequest", "waitingForInput", child, 2, agentID = "child-agent"))
                    awaitState("child agent") { state -> state.threads.map { it.providerSessionID }.toSet() == setOf(before, child) }
                }

                // Claude runs `/clear`'s SessionEnd before the next SessionStart,
                // but their frames can land in either order.
                endpoint.session = after
                val ended = frame("SessionEnd", "unavailable", before, 3)
                val started = frame("SessionStart", "idle", after, 4)
                for (next in if (startFirst) listOf(started, ended) else listOf(ended, started)) endpoint.lifecycleFrames.emit(next)
                val replaced = awaitState("hand-over") { state ->
                    state.threads.map { it.providerSessionID } == listOf(after) && state.detail?.row?.providerSessionID == after
                }
                assertEquals(label, replaced.threads.single().key, replaced.selectedThreadKey)
                assertFalse("$label: the old conversation backs no detail", old.key in replaced.projectedDetails)

                // Claude's `/clear` SessionEnd can land after the next
                // SessionStart. It is routine stale work: it takes nothing
                // from the conversation the pane runs now and shows nothing.
                logs.clear()
                endpoint.lifecycleFrames.emit(frame("SessionEnd", "unavailable", before, 5))
                try {
                    withTimeout(10_000) {
                        while (logs.none { it.first == "agent_core_rejected" && it.second["error"].orEmpty().endsWith("_staleBinding") }) delay(20)
                    }
                } catch (timeout: TimeoutCancellationException) {
                    throw AssertionError("$label: late end never refused; diagnostics=$logs")
                }
                val kept = presenter.state.value
                assertEquals(label, listOf(after), kept.threads.map { it.providerSessionID })
                assertEquals(label, replaced.selectedThreadKey, kept.selectedThreadKey)
                assertEquals(label, after, kept.detail?.row?.providerSessionID)
                assertEquals(label, null, kept.notice)
                assertFalse("$label: the ended conversation backs no detail", old.key in kept.projectedDetails)
                // The hook reports nothing more of a Codex child, so its root's
                // Stop ends it.
                if (provider == "codex") {
                    endpoint.lifecycleFrames.emit(frame("PermissionRequest", "waitingForInput", newChild, 6, agentID = "new-agent"))
                    awaitState("new conversation's child") { state -> state.threads.map { it.providerSessionID }.toSet() == setOf(after, newChild) }
                    endpoint.lifecycleFrames.emit(frame("Stop", "idle", after, 7))
                    val stopped = awaitState("child ends with its root") { state -> state.threads.map { it.providerSessionID } == listOf(after) }
                    assertEquals(label, replaced.selectedThreadKey, stopped.selectedThreadKey)
                }
            } finally {
                withContext(Dispatchers.Main) { presenter.close() }
                registration.close(); integration.close(); coordinator.close(); scope.cancel(); endpoint.close()
            }
        }
    }

    private class DetectedEndpoint(transport: AgentEndpointTransport, val provider: String, val historyPages: Int? = null) : AgentSessionEndpoint {
        @Volatile var session = UUID.randomUUID().toString()
        @Volatile var occupancyEnabled = false
        @Volatile var agentPID = 102
        @Volatile var sourceMissing = false
        override val key = AgentSessionKey(UUID.randomUUID().toString(), 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key, UUID.randomUUID().toString(), transport,
            hostDisplayLabel = "Synthetic host", tmuxSession = "fixture", windowID = "@1", paneID = "%2"))
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities(lifecycleFeed = true, remoteData = true,
            freshTerminalObservation = true, verifiedInput = true, semanticKeys = true))
        override val lifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>(replay = 8)
        val contexts = java.util.concurrent.CopyOnWriteArrayList<Int>()
        val operations = java.util.concurrent.CopyOnWriteArrayList<String>()
        @Volatile var olderReads = 0
        @Volatile var holdOlder = false
        val heldOlder = Channel<Unit>(Channel.UNLIMITED)
        private val heldOlderReplies = java.util.concurrent.CopyOnWriteArrayList<() -> Unit>()
        fun releaseHeldOlder() { heldOlderReplies.toList().forEach { it() }; heldOlderReplies.clear() }
        @Volatile var expectReceiptBarrier = false
        @Volatile var receiptArmed = false
        @Volatile var receiptRaceEmitted = false
        @Volatile var exitDuringReceipt = false
        @Volatile var replaceAfterText = false
        @Volatile var replaceDuringCaptureWait = false
        @Volatile var processActive = true
        @Volatile var processStart = "fixture-start"
        @Volatile var proofs = 0
        private val streams = java.util.concurrent.CopyOnWriteArrayList<DetectedStream>()
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> {
            if (request.executable != "tessera-agent-host") return unavailable()
            check(isCurrentIngestion(binding))
            val hello = JSONObject(request.stdin.copyOfRange(4, request.stdin.size).decodeToString())
            contexts.add(hello.optInt("contextPID"))
            return AgentEndpointResult.Success(DetectedStream().also { streams.add(it) })
        }
        private inner class DetectedStream : AgentRemoteExecStream {
            val frames = Channel<ByteArray>(Channel.UNLIMITED)
            @Volatile var closed = false
            private var responseHandle = "detected_thread"
            fun envelope(kind: String, id: String) = JSONObject().put("kind", kind).put("id", id)
                .put("serviceEpoch", "detected_epoch").put("thread", responseHandle)
            fun emit(value: JSONObject) {
                // Backgrounding closes this stream from an IO dispatcher. A held
                // reply released after that is dropped, never a fixture failure.
                if (closed) return
                val result = frames.trySend(AgentIngestionConnection.frame(value))
                check(result.isSuccess || result.isClosed)
            }
            init { emit(envelope("hello", "hello").put("v", 3).put("contextScope", "0000000000000001")
                .put("capabilities", JSONArray(listOf("bounded.windows", "window.partitions")))) }
            override val stdout = frames.receiveAsFlow()
            override val stderr: Flow<ByteArray> = flow { awaitCancellation() }
            override suspend fun awaitExit(): AgentExecExitStatus { while (!closed) delay(20); return AgentExecExitStatus(0) }
            private var committedVersion = 0L
            override suspend fun send(bytes: ByteArray) {
                val request = JSONObject(bytes.copyOfRange(4, bytes.size).decodeToString())
                val kind = request.getString("kind"); val id = request.getString("id")
                if (occupancyEnabled) responseHandle = request.optString("thread").ifBlank { "detected_$session" }
                operations.add(kind)
                when (kind) {
                    "resolve" -> if (sourceMissing) emit(envelope("error", id).put("code", "sourceMissing")
                        .put("status", JSONObject().put("v", 1).put("state", "failed").put("domain", "source")
                            .put("recovery", "manual").put("code", "sourceMissing")))
                        else emit(envelope("resolved", id).put("provider", provider).put("sessionID", session))
                    "inventory" -> { emit(envelope("inventory.begin", id)); emit(envelope("inventory.end", id).put("hasMore", false)) }
                    "window.read", "bootstrap" -> {
                        val operation = request.optString("operation", "bootstrap")
                        if (historyPages != null) {
                            val index = if (operation == "before") request.getString("cursor").removePrefix("history_").toInt() else 0
                            if (operation == "before") olderReads++
                            val respond = {
                                val history = operation == "before"
                                val hasOlder = index < historyPages
                                emit(envelope("page.begin", id).put("sourceIdentity", "jsonl:detected-source")
                                    .put("operation", if (history) "history" else if (operation == "head") "updates" else "bootstrap")
                                    .putOpt("from", request.optString("cursor").takeIf { it.isNotBlank() }))
                                emit(envelope("page.record", id).put("recordID", "history-record-$index").put("revision", 1).put("order", 1000 - index)
                                    .put("record", JSONObject().put("type", "message").put("role", "assistant")
                                        .put("blocks", JSONArray().put(JSONObject().put("type", "text").put("text", "History page $index")))))
                                val end = envelope("page.end", id).put("records", 1).put("backend", "jsonl")
                                if (!history) end.put("hasNewer", false).put("liveCursor", "detected_live").put("sourceEnd", 10000)
                                if (operation != "head") end.put("hasOlder", hasOlder).putOpt("historyCursor", if (hasOlder) "history_${index + 1}" else null)
                                end.put("window", JSONObject().put("lane", operation).put("version", request.optLong("windowVersion", 0) + 1)
                                    .put("segmentID", "history_$id").put("before", "history_${index + 1}").put("after", "after_$index")
                                    .put("hasOlder", hasOlder).put("hasNewer", history))
                                emit(end)
                            }
                            if (operation == "before" && holdOlder) {
                                heldOlderReplies.add(respond); heldOlder.trySend(Unit)
                            } else respond()
                            return
                        }
                        emit(envelope("page.begin", id).put("sourceIdentity", "jsonl:detected-source").put("operation", if (operation == "head") "updates" else operation)
                            .putOpt("from", request.optString("cursor").takeIf { it.isNotBlank() }))
                        if (provider == "claude") emit(envelope("page.record", id).put("recordID", "detected-title").put("revision", 1).put("order", 0)
                            .put("record", JSONObject().put("type", "ai-title").put("aiTitle", "Detected $provider title")))
                        emit(envelope("page.record", id).put("recordID", "detected-record").put("revision", 1).put("order", 1)
                            .put("record", JSONObject().put("type", "message").put("role", "assistant")
                                .put("blocks", JSONArray().put(JSONObject().put("type", "text").put("text", "Detected $provider reply")))))
                        if (receiptRaceEmitted) emitPreexistingUser(id)
                        val end = envelope("page.end", id).put("records", (if (provider == "claude") 2 else 1) + if (receiptRaceEmitted) 1 else 0).put("hasOlder", false).put("hasNewer", false)
                            .put("liveCursor", "detected_live").put("sourceEnd", 100).put("backend", "jsonl")
                        if (operation == "head") end.remove("hasOlder")
                        if (kind == "window.read") end.put("window", JSONObject().put("lane", operation).put("version", request.optLong("windowVersion", 0) + 1)
                            .put("segmentID", "detected_$id").put("before", "detected_before").put("after", "detected_after")
                            .put("hasOlder", false).put("hasNewer", false))
                        emit(end)
                    }
                    "window.ack" -> {
                        committedVersion = request.getLong("windowVersion")
                        emit(envelope("window.acked", id))
                    }
                    "receipt.frontier" -> {
                        if (exitDuringReceipt) { exitDuringReceipt = false; processActive = false }
                        emit(envelope("receipt.frontier", id).put("frontier", JSONObject().put("version", 1)
                            .put("actionID", request.getString("actionID")).put("serviceEpoch", "detected_epoch")
                            .put("provider", provider).put("providerSessionID", session)
                            .put("sourceIdentity", "jsonl:detected-source").put("sourceEnd", "100")
                            .put("consistency", "observedPrefix")))
                        if (expectReceiptBarrier && historyPages == null) {
                            if (!receiptRaceEmitted) {
                                receiptRaceEmitted = true
                                val watchID = "watch_receipt_race"
                                emit(envelope("page.begin", watchID).put("sourceIdentity", "jsonl:detected-source")
                                    .put("operation", "updates").put("from", "detected_live"))
                                emit(envelope("page.record", watchID).put("recordID", "detected-record").put("revision", 1).put("order", 1)
                                    .put("record", JSONObject().put("type", "message").put("role", "assistant")
                                        .put("blocks", JSONArray().put(JSONObject().put("type", "text").put("text", "Detected $provider reply")))))
                                emitPreexistingUser(watchID)
                                emit(envelope("page.end", watchID).put("records", 2).put("hasNewer", false)
                                    .put("liveCursor", "detected_live").put("sourceEnd", 100).put("backend", "jsonl")
                                    .put("window", JSONObject().put("lane", "head").put("version", committedVersion + 1)
                                        .put("segmentID", "receipt_race_head").put("before", "detected_before").put("after", "detected_after")
                                        .put("hasOlder", false).put("hasNewer", false)))
                            }
                        }
                    }
                    "subscribe" -> {
                        emit(envelope("subscribed", id))
                        if (request.optString("interest") == "slow") emit(envelope("summary", "watch_summary").put("revision", "summary_revision")
                            .put("modified", 1).put("records", JSONArray().put(JSONObject().put("type", "session-title")
                                .put("title", "Detected $provider title"))))
                    }
                    "summary" -> emit(envelope("summary", id).put("revision", "summary_revision").put("modified", 1)
                        .put("records", JSONArray().put(JSONObject().put("type", "session-title").put("title", "Detected $provider title"))))
                    else -> emit(envelope("ack", id))
                }
            }
            private fun emitPreexistingUser(id: String) {
                emit(envelope("page.record", id).put("recordID", "preexisting-matching").put("revision", 1).put("order", 50)
                    .put("receiptSourceIdentity", "jsonl:detected-source").put("receiptSourceOffset", 50)
                    .put("record", JSONObject().put("type", "message").put("role", "user")
                        .put("blocks", JSONArray().put(JSONObject().put("type", "text").put("text", "fixture send")))))
            }
            override fun cancel() { closed = true; frames.close() }
            override fun close() = cancel()
        }
        override fun close() { streams.forEach { it.close() } }
        private fun unavailable() = AgentEndpointResult.Unavailable("synthetic detected-thread fixture")
        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider, requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> {
            proofs++
            return if (processActive && claimedPID == agentPID) AgentEndpointResult.Success(AgentProcessProof(setOf(101, agentPID), provider, processStart))
                else AgentEndpointResult.Failed(if (occupancyEnabled) "proof_exit_1" else "provider_exited")
        }
        override suspend fun observeOccupancy(bindings: List<AgentEndpointBinding>): AgentEndpointResult<AgentOccupancySnapshot> =
            if (!occupancyEnabled) unavailable() else AgentEndpointResult.Success(AgentOccupancySnapshot(bindings.map {
                AgentOccupancyPane(it.paneID, true, true, if (processActive)
                    listOf(AgentOccupancyProcess(agentPID, AgentProofProvider.fromWire(provider)!!)) else emptyList())
            }, listOf(binding.value.paneID!!)))
        private var input = ""
        val insertions = java.util.concurrent.CopyOnWriteArrayList<String>()
        val submittedKeys = java.util.concurrent.CopyOnWriteArrayList<AgentSemanticKey>()
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> {
            val waited = replaceDuringCaptureWait && receiptArmed
            if (waited) { replaceDuringCaptureWait = false; processStart = "replaced-during-frame" }
            return AgentEndpointResult.Success(AgentTerminalObservation(binding,
                "› $input\n\n97% context left".encodeToByteArray(), false, authoritative = true, cursorRow = 0, cursorVisible = true,
                captureWaitedForFrame = waited))
        }
        override suspend fun processDiscoveryScope(binding: AgentEndpointBinding): AgentEndpointResult<AgentProcessDiscoveryScope> = unavailable()
        override suspend fun probeIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationStatus> = unavailable()
        override suspend fun readIntegrationConfigs(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationConfigSnapshots> = unavailable()
        override suspend fun installIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> = unavailable()
        override suspend fun inspectCurrentShell(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentCurrentShellStatus> = unavailable()
        override suspend fun discoverProcesses(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentProcessDiscoverySnapshot> = unavailable()
        override suspend fun activateCurrentShell(binding: AgentEndpointBinding, expectedProcessIDs: Set<Int>, command: AgentShellActivationCommand): AgentEndpointResult<Unit> = unavailable()
        override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> = unavailable()
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> {
            check(isCurrentRoute(binding))
            input = bytes.decodeToString().removePrefix("\u001b[200~").removeSuffix("\u001b[201~")
            insertions.add(input)
            if (replaceAfterText) { replaceAfterText = false; processStart = "replacement-start" }
            return AgentEndpointResult.Success(Unit)
        }
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> {
            check(isCurrentRoute(binding)); submittedKeys.add(key); input = ""
            return AgentEndpointResult.Success(Unit)
        }
        override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> = unavailable()
        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> = unavailable()
        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> = unavailable()
    }
}
