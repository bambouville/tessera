package com.bambouville.tessera.feature.agentcenter

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Rule
import java.io.File
import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.*
import org.json.JSONObject
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test

/** Production presenter and JNI; process proof and captures are host-free. */
class AgentDeferredPromptRecoveryInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    @Test fun tappingAnswerShowsTheQuestionInAgentCenter(): Unit = runBlocking { exercise(true, visual = true) }
    @Test fun stalledCaptureFinishesWithoutWriting(): Unit = runBlocking { exercise(false, stalled = true) }
    @Test fun stalledRepaintAfterTheOpenKeyStillSettlesTheAction(): Unit = runBlocking { exercise(false, stalledAfterWrite = true) }
    @Test fun answerOpensTheDeferredQuestionOnAllTransports(): Unit = runBlocking { exercise(false) }
    @Test fun answerWaitsForABusyCaptureBeforeItsFirstKey(): Unit = runBlocking { exercise(true) }

    @Test fun callbackBurstCannotLoseCorrelatedReplies(): Unit = runBlocking {
        SharedAgentRuntime.create().use { runtime ->
            val held = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val received = java.util.concurrent.CopyOnWriteArrayList<String>()
            val dropped = java.util.concurrent.CopyOnWriteArrayList<Map<String, String>>()
            runtime.droppedEventSink = { dropped.add(it) }
            val listener = launch(start = CoroutineStart.UNDISPATCHED) {
                runtime.events.collect { event ->
                    if (event is SharedAgentRuntimeEvent.Snapshot && event.snapshot.kind == SharedAgentSnapshotKind.PromptObservation) {
                        received.add((event.snapshot.payload.fields["promptRequestID"] as SharedAgentValue.StringValue).value)
                        if (received.size == 1) { held.complete(Unit); release.await() }
                    }
                }
            }
            try {
                fun request(index: Int) {
                    val command = JSONObject().put("v", 1).put("kind", "promptObservation").put("promptRequestID", "$index")
                        .put("promptObservation", JSONObject().put("providerID", JSONObject().put("rawValue", "codex"))
                            .put("visibleText", "› Ask Codex to do anything"))
                    assertEquals(CoreCallResult.Accepted, runtime.sendCanonical(command.toString().encodeToByteArray()))
                }
                request(0)
                withTimeout(5_000) { held.await() }
                for (index in 1..160) request(index)
                // With the collector held, fill both bounded queues and reach
                // producer backpressure before releasing it.
                withTimeout(5_000) { runtime.snapshot.first {
                    ((it?.payload?.fields?.get("promptRequestID") as? SharedAgentValue.StringValue)?.value?.toIntOrNull() ?: -1) >= 129
                } }
                assertEquals(listOf("0"), received.toList())
                release.complete(Unit)
                withTimeoutOrNull(3_000) { while (received.size < 161) delay(10) }
                assertTrue("Dropped callbacks: $dropped", dropped.isEmpty())
                assertEquals((0..160).map(Int::toString), received.toList())
            } finally { release.complete(Unit); listener.cancelAndJoin() }
        }
    }

    @Test fun callbacksWaitForSubscriptionAndCloseUnblocksAFullQueue(): Unit = runBlocking {
        fun request(runtime: SharedAgentRuntime, index: Int) {
            val command = JSONObject().put("v", 1).put("kind", "promptObservation").put("promptRequestID", "$index")
                .put("promptObservation", JSONObject().put("providerID", JSONObject().put("rawValue", "codex"))
                    .put("visibleText", "› Ask Codex to do anything"))
            assertEquals(CoreCallResult.Accepted, runtime.sendCanonical(command.toString().encodeToByteArray()))
        }
        SharedAgentRuntime.create().use { runtime ->
            request(runtime, 0)
            withTimeout(5_000) { runtime.snapshot.first { it?.kind == SharedAgentSnapshotKind.PromptObservation } }
            val event = withTimeout(5_000) { runtime.events.first { it is SharedAgentRuntimeEvent.Snapshot } }
            assertEquals(SharedAgentValue.StringValue("0"), (event as SharedAgentRuntimeEvent.Snapshot).snapshot.payload.fields["promptRequestID"])
        }
        SharedAgentRuntime.create().use { runtime ->
            for (index in 0..160) request(runtime, index)
            withTimeout(5_000) { runtime.snapshot.first {
                ((it?.payload?.fields?.get("promptRequestID") as? SharedAgentValue.StringValue)?.value?.toIntOrNull() ?: -1) >= 65
            } }
            withTimeout(2_000) { withContext(Dispatchers.Default) { runtime.close() } }
            assertEquals(CoreCallResult.StaleHandle, runtime.sendCanonical("{}".encodeToByteArray()))
        }
    }

    private suspend fun exercise(busy: Boolean, visual: Boolean = false, stalled: Boolean = false, stalledAfterWrite: Boolean = false) {
        val stage = InstrumentationRegistry.getArguments().getString("tesseraDeferredStage") ?: "after"
        for (transport in if (visual) listOf(AgentEndpointTransport.MOSH_TMUX) else AgentEndpointTransport.entries) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val registry = LiveAgentSessionRegistry()
            val coordinator = AndroidAgentSessionCoordinator(registry)
            val endpoint = PromptEndpoint(transport).also { it.stallAfterWrite = stalledAfterWrite }
            val registration = registry.register(endpoint)
            val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
            val logs = java.util.concurrent.CopyOnWriteArrayList<String>()
            val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                AndroidAgentCenterViewPreferences(context), scope, integration, diagnostics = { event, fields ->
                    logs.add("$event $fields")
                    if (event == "agent_action_plan") {
                        if (busy) endpoint.unavailableUntil = System.nanoTime() + 750_000_000
                        if (stalled) endpoint.stalled = true
                    }
                })
            try {
                if (visual) compose.setContent {
                    val state by presenter.state.collectAsState()
                    TesseraTheme {
                        AgentDetailPane(state.detail, "", {}, {}, {},
                            { prompt, answer -> state.detail?.let { presenter.requestPromptAnswer(it, prompt, answer) } },
                            {}, {}, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding(),
                            promptActionPending = state.detail?.row?.key in state.sendingThreads)
                    }
                }
                withContext(Dispatchers.Main) { presenter.setEnabled(true) }
                endpoint.lifecycleFrames.emit(AgentLifecycleFrame(endpoint.binding.value,
                    """{"version":9,"provider":"codex","event":"SessionStart","state":"idle","timestampNs":"1","sessionId":"fixture-deferred","agentPid":102,"transcriptRef":"b3BhcXVl"}""".encodeToByteArray()))
                val row = withTimeout(10_000) { presenter.state.first { it.threads.isNotEmpty() } }.threads.single()
                withContext(Dispatchers.Main) {
                    presenter.setOpenDetail(row.key); presenter.select(row.key); presenter.setCardVisible(row.key, true)
                }
                val detail = withTimeout(10_000) { presenter.state.first { it.detail?.canAnswerPrompt() == true } }.detail!!
                assertEquals("deferred", detail.prompt!!.kind)
                if (visual) {
                    compose.onNodeWithText("Answer").assertIsDisplayed()
                    capture(context, "$stage-waiting")
                    compose.onNodeWithText("Answer").performClick()
                } else withContext(Dispatchers.Main) { presenter.requestPromptAnswer(detail, detail.prompt, AgentPromptAnswerChoice.Control("open")) }
                if (stalled || (visual && stage == "before")) {
                    withTimeout(5_000) { presenter.state.first { row.key !in it.sendingThreads &&
                        logs.any { log -> log.startsWith("agent_action_finished {action=answerPrompt, result=") } } }
                    assertTrue(endpoint.writes.tryReceive().isFailure)
                    assertEquals("deferred", presenter.state.value.detail!!.prompt!!.kind)
                    if (visual) capture(context, "$stage-result")
                    continue
                }
                val written = withTimeoutOrNull(4_000) { endpoint.writes.receive() }
                assertEquals("$transport busy=$busy notice=${presenter.state.value.notice} logs=$logs", "\u001b[1;2D", written)
                if (stalledAfterWrite) {
                    withTimeout(5_000) { presenter.state.first { row.key !in it.sendingThreads &&
                        logs.any { log -> log == "agent_action_finished {action=answerPrompt, result=verification_failed}" } } }
                    assertTrue(endpoint.writes.tryReceive().isFailure)
                    continue
                }
                val shown = withTimeout(5_000) { presenter.state.first { it.detail?.prompt?.kind == "question" } }.detail!!
                assertEquals("Which database should the service use?", shown.prompt!!.question)
                withTimeout(5_000) { presenter.state.first { row.key !in it.sendingThreads &&
                    logs.any { log -> log == "agent_action_finished {action=answerPrompt, result=success}" } } }
                assertTrue(endpoint.writes.tryReceive().isFailure)
                if (visual) {
                    withTimeout(5_000) { presenter.state.first { it.detail?.canAnswerPrompt() == true } }
                    compose.onNodeWithTag("agent-answer-1").assertIsEnabled()
                    compose.onNodeWithTag("agent-answer-2").assertIsEnabled()
                    compose.onNodeWithText("Which database should the service use?").assertIsDisplayed()
                    compose.onNodeWithText("Postgres").assertIsDisplayed()
                    compose.onNodeWithText("SQLite").assertIsDisplayed()
                    capture(context, "$stage-result")
                }
            } finally {
                withContext(Dispatchers.Main) { presenter.close() }
                registration.close(); integration.close(); coordinator.close(); scope.cancel()
            }
        }
    }

    private suspend fun capture(context: android.content.Context, stage: String) {
        compose.waitForIdle()
        delay(800)
        val shot = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        File(context.filesDir, "agent-deferred-$stage.png").outputStream().use {
            check(shot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
        }
        shot.recycle()
    }

    private class PromptEndpoint(transport: AgentEndpointTransport) : AgentSessionEndpoint {
        @Volatile var processes = listOf(AgentDiscoveredProcess(101, 42, "/usr/local/bin/codex", true),
            AgentDiscoveredProcess(102, 101, "/usr/local/bin/codex", true), AgentDiscoveredProcess(103, 42, "/bin/sh", true))
        override val key = AgentSessionKey("11111111-2222-3333-4444-555555555555", 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key,
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", transport,
            hostDisplayLabel = "windows fixture", tmuxSession = "fixture", windowID = "@1", paneID = "%2"))
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities(lifecycleFeed = true, freshTerminalObservation = true, remoteData = true, verifiedInput = true, semanticKeys = true))
        override val lifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>(replay = 8)

        override suspend fun processDiscoveryScope(binding: AgentEndpointBinding) =
            AgentEndpointResult.Success(AgentProcessDiscoveryScope.RootProcess(42))
        override suspend fun discoverProcesses(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentProcessDiscoverySnapshot> {
            val snapshot = processes
            val ids = snapshot.mapTo(linkedSetOf()) { it.processID }
            return AgentEndpointResult.Success(AgentProcessDiscoverySnapshot(snapshot,
                SharedAgentIntegrationForeground.Agent, emptySet(), ids, ids, true))
        }
        @Volatile var unavailableUntil = 0L
        @Volatile var stalled = false
        var stallAfterWrite = false
        var opened = false
        val writes = kotlinx.coroutines.channels.Channel<String>(kotlinx.coroutines.channels.Channel.UNLIMITED)
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> {
            if (stalled) delay(30_000)
            if (System.nanoTime() < unavailableUntil) return AgentEndpointResult.Failed("tmux_cursor_moved")
            val visible = if (opened) """
                Which database should the service use?

                › 1. Postgres
                  2. SQLite
                  3. Type something.

                enter submit   ctrl+] skip
            """.trimIndent() else """
                • Working (5s • esc to interrupt)

                • Queued follow-up inputs
                  ? 1 question
                    shift+← to answer

                › Ask Codex to do anything

                  97% context left
            """.trimIndent()
            return AgentEndpointResult.Success(AgentTerminalObservation(binding,
                visible.encodeToByteArray(), false, authoritative = true, cursorRow = if (opened) 2 else 6,
                cursorVisible = !opened))
        }

        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider, requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> =
            AgentEndpointResult.Success(AgentProcessProof(setOf(101, 102, 103), provider, "fixture-start"))

        override suspend fun probeIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationStatus> = unavailable()
        override suspend fun readIntegrationConfigs(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationConfigSnapshots> = unavailable()
        override suspend fun installIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> = unavailable()
        override suspend fun inspectCurrentShell(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentCurrentShellStatus> = unavailable()
        override suspend fun activateCurrentShell(binding: AgentEndpointBinding, expectedProcessIDs: Set<Int>, command: AgentShellActivationCommand): AgentEndpointResult<Unit> = unavailable()
        override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> = unavailable()
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> =
            AgentEndpointResult.Success(object : AgentRemoteExecStream {
                override val stdout = kotlinx.coroutines.flow.flowOf(("""{"v":1,"kind":"page","sourceIdentity":"1:2:0:1"}""" + "\n" +
                    """{"v":1,"kind":"end","hasMore":false}""" + "\n").encodeToByteArray())
                override val stderr = kotlinx.coroutines.flow.emptyFlow<ByteArray>()
                override suspend fun awaitExit() = AgentExecExitStatus(0)
                override fun cancel() {}
                override fun close() {}
            })
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> =
            accept(bytes.decodeToString(), semantic = false)
        // tmux panes take a prompt's named keys as `send-keys` key names; raw
        // terminals take the same key as bytes.
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> =
            accept(key.encoded().decodeToString(), semantic = true)
        private suspend fun accept(input: String, semantic: Boolean): AgentEndpointResult<Unit> {
            check(input == "\u001b[1;2D") { "Unexpected prompt input: $input" }
            val tmux = binding.value.transport in setOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)
            check(semantic == tmux) { "${binding.value.transport} prompt key sent ${if (semantic) "as a key name" else "as bytes"}" }
            opened = true
            if (stallAfterWrite) stalled = true
            writes.send(input)
            return AgentEndpointResult.Success(Unit)
        }
        override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> = unavailable()
        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> = unavailable()
        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> = unavailable()
        var routeValid = true
        override fun isCurrentRoute(candidate: AgentEndpointBinding) = routeValid && candidate.sameRouteAs(binding.value)
        override fun close() {}
        private fun unavailable() = AgentEndpointResult.Unavailable("host-free discovery fixture")
    }
}
