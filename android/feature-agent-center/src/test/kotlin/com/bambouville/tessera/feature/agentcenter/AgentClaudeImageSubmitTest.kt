package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.SharedAgentComposerEvidence
import com.bambouville.tessera.core.bridge.SharedAgentComposerEvidence.Assessment
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.core.bridge.SharedAgentRuntimeEvent
import com.bambouville.tessera.core.bridge.SharedAgentSnapshotKind
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import java.lang.reflect.Proxy
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import sun.misc.Unsafe

/**
 * Real presenter send plans, insertion and composer evidence (including host JNI),
 * with no remote endpoint. Like AgentSendAnywayTest, no display watcher consumes
 * action captures. The production 50 ms delays cost about seven seconds in total;
 * there is no presenter clock/delay injection and no copied submission loop here.
 */
class AgentClaudeImageSubmitTest {
    @Test fun imageWaitsForMarkersThenForRecognizedEmptyComposer() = runBlocking {
        val rig = Rig(listOf(IMAGE_DRAFT, MARKERS), listOf(MARKERS, null, ""))
        try {
            // Assert fixture meaning through JNI, rather than assuming these
            // strings look like Claude to the shared classifier.
            assertEquals(Assessment.UNAVAILABLE, rig.endpoint.assess(IMAGE_DRAFT, IMAGE_DRAFT, safetyOnly = true))
            assertEquals(Assessment.RETURN, rig.endpoint.assess(MARKERS, IMAGE_DRAFT, safetyOnly = true))
            assertEquals(Assessment.RETURN, rig.endpoint.assess(MARKERS, IMAGE_DRAFT))
            assertEquals(Assessment.UNAVAILABLE, rig.endpoint.assess(null, IMAGE_DRAFT))
            assertEquals(Assessment.ABSENT, rig.endpoint.assess("", IMAGE_DRAFT))
            rig.send(IMAGE_DRAFT)
            rig.assertOutcome("success")
            rig.assertWrites(IMAGE_INSERTION, returnSent = true)
            assertEquals(listOf(IMAGE_DRAFT, MARKERS), rig.endpoint.beforeReturn.toList())
            // Neither retained markers nor a torn/unrecognized screen proves
            // departure. Success requires consuming the third, empty composer.
            assertEquals(listOf(MARKERS, null, ""), rig.endpoint.afterReturn.toList())
        } finally { rig.close() }
    }

    @Test fun retainedMarkersAfterReturnFailVerification() = runBlocking {
        val rig = Rig(listOf(MARKERS), listOf(MARKERS))
        try {
            rig.send(IMAGE_DRAFT)
            rig.assertOutcome("verificationFailed")
            rig.assertWrites(IMAGE_INSERTION, returnSent = true)
            assertEquals(listOf(MARKERS), rig.endpoint.beforeReturn.toList())
            assertEquals(List(40) { MARKERS }, rig.endpoint.afterReturn.toList())
            assertNull(rig.presenter.state.value.sendAnywayNotice)
        } finally { rig.close() }
    }

    @Test fun unchangedLiteralDraftFallsBackOnlyAfterFortyAttemptsWithoutDeparturePolling() = runBlocking {
        val rig = Rig(listOf(IMAGE_DRAFT), listOf(MARKERS))
        try {
            assertEquals(Assessment.RETURN, rig.endpoint.assess(IMAGE_DRAFT, IMAGE_DRAFT,
                safetyOnly = true, literalOnly = true))
            rig.send(IMAGE_DRAFT)
            rig.assertOutcome("success")
            rig.assertWrites(IMAGE_INSERTION, returnSent = true)
            // Forty normal checks, followed by the one literal-only fallback.
            assertEquals(List(41) { IMAGE_DRAFT }, rig.endpoint.beforeReturn.toList())
            assertTrue(rig.endpoint.afterReturn.isEmpty())
        } finally { rig.close() }
    }

    @Test fun partialConversionRefusesReturnWithComposerGuardReason() = runBlocking {
        val partial = "[Image #1]\nDescribe a different image"
        val rig = Rig(listOf(partial), listOf(""))
        try {
            for (literal in listOf(false, true)) {
                assertEquals(Assessment.UNAVAILABLE, rig.endpoint.assess(partial, IMAGE_DRAFT,
                    safetyOnly = true, literalOnly = literal))
            }
            rig.send(IMAGE_DRAFT)
            rig.assertOutcome("terminal_input_not_ready")
            rig.assertWrites(IMAGE_INSERTION, returnSent = false)
            assertEquals(List(41) { partial }, rig.endpoint.beforeReturn.toList())
            assertTrue(rig.endpoint.afterReturn.isEmpty())
            assertEquals(listOf(mapOf("stage" to "before_submit", "reason" to "capture_unavailable", "written" to "true")),
                rig.logs.filter { it.first == "agent_composer_guard_refused" }.map { it.second })
        } finally { rig.close() }
    }

    @Test fun nonImageDraftUsesTwentyAttemptsAndNeverPollsAfterReturn() = runBlocking {
        val text = "Describe this text"
        // Ready immediately: no marker wait or post-Return check, even though
        // the scripted endpoint would keep the draft after Return.
        // Never ready: exhaust exactly the ordinary twenty-attempt budget.
        for (ready in listOf(true, false)) {
            val body = if (ready) text else null
            val rig = Rig(listOf(body), listOf(body))
            try {
                rig.send(text)
                rig.assertOutcome(if (ready) "success" else "terminal_input_not_ready")
                rig.assertWrites("\u001b[200~${text}\u001b[201~", returnSent = ready)
                assertEquals(List(if (ready) 1 else 20) { body }, rig.endpoint.beforeReturn.toList())
                assertTrue(rig.endpoint.afterReturn.isEmpty())
            } finally { rig.close() }
        }
    }

    private class Rig(beforeReturn: List<String?>, afterReturn: List<String?>) {
        private val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        private val scope = CoroutineScope(SupervisorJob() + dispatcher)
        private val registry = LiveAgentSessionRegistry()
        private val coordinator = AndroidAgentSessionCoordinator(registry)
        private val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
        private val runtime = coordinator.runtime()
        val endpoint = Endpoint(beforeReturn, afterReturn)
        private val registration = registry.register(endpoint)
        val logs = CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
        private val verificationModes = CopyOnWriteArrayList<String>()
        val presenter = AgentCenterPresenter(coordinator, metadata(), unusedPreferences(), scope, integration,
            diagnostics = { event, fields -> logs.add(event to fields) })

        init {
            field("runtime").set(presenter, runtime)
            field("enabled").setBoolean(presenter, true)
            field("applicationForeground").setBoolean(presenter, false)
            scope.launch { runtime.events.collect { event ->
                if (event is SharedAgentRuntimeEvent.Snapshot && event.snapshot.kind == SharedAgentSnapshotKind.ActionPlan) {
                    verificationModes.add(event.snapshot.payload.obj("actionPayload")?.obj("text")
                        ?.string("composerVerification") ?: "missing")
                }
                presenter.consume(event)
            } }
        }

        suspend fun send(text: String) {
            withContext(dispatcher) {
                val transcript = Base64.getUrlEncoder().withoutPadding()
                    .encodeToString("/fixture/claude-image-submit".encodeToByteArray())
                presenter.consumeLifecycle(endpoint, AgentLifecycleFrame(endpoint.binding.value, JSONObject()
                    .put("version", 9).put("provider", "claude").put("event", "SessionStart").put("state", "idle")
                    .put("timestampNs", "${System.nanoTime()}").put("sessionId", "claude-image-submit").put("agentPid", 42)
                    .put("transcriptRef", transcript).toString().encodeToByteArray()))
            }
            await { it.projectedDetails.isNotEmpty() }
            withContext(dispatcher) {
                val detail = presenter.state.value.projectedDetails.getValue(
                    canonicalAgentThreadKey(endpoint.binding.value.hostID, "claude", "claude-image-submit"))
                presenter.select(detail.row.key)
                presenter.setDraft(detail.row.key, text)
                // Public normal-send entry point; never invoke Send anyway.
                assertTrue(presenter.requestAction(detail, "send", text))
            }
            await { it.sendingThreads.isEmpty() && logs.any { entry -> entry.first == "agent_action_finished" } }
            assertEquals(listOf("required"), verificationModes.toList())
        }

        fun assertOutcome(result: String) {
            assertEquals(listOf(mapOf("action" to "send", "result" to result)),
                logs.filter { it.first == "agent_action_finished" }.map { it.second })
            assertTrue(presenter.state.value.sendingThreads.isEmpty())
        }

        fun assertWrites(insertion: String, returnSent: Boolean) {
            assertEquals(listOf(insertion), endpoint.writes.toList())
            assertEquals(if (returnSent) listOf(AgentSemanticKey.RETURN) else emptyList<AgentSemanticKey>(), endpoint.keys.toList())
            // One combined event stream proves ordering as well as key count.
            assertEquals(listOf("insert:$insertion") + if (returnSent) listOf("key:RETURN") else emptyList(),
                endpoint.events.filter { it.startsWith("insert:") || it.startsWith("key:") })
            val insertionIndex = endpoint.events.indexOf("insert:$insertion")
            assertTrue(endpoint.events.take(insertionIndex).contains("inspect:empty"))
            assertEquals(if (returnSent) 1 else 0, endpoint.events.count { it == "key:RETURN" })
        }

        private suspend fun await(predicate: (AgentCenterUiState) -> Boolean) {
            withTimeoutOrNull(5_000) {
                merge(presenter.state, flow { while (true) { delay(10); emit(presenter.state.value) } }).first(predicate)
            } ?: throw AssertionError("timed out; pending=${presenter.state.value.sendingThreads} logs=${logs.takeLast(12)}")
        }

        suspend fun close() {
            withContext(NonCancellable + dispatcher) { presenter.close(); integration.close(); coordinator.close() }
            registration.close(); endpoint.close(); scope.cancel(); dispatcher.close()
        }

        private fun field(name: String) = AgentCenterPresenter::class.java.getDeclaredField(name).also { it.isAccessible = true }
    }

    private class Endpoint(private val before: List<String?>, private val after: List<String?>) : AgentSessionEndpoint {
        override val key = AgentSessionKey(UUID.randomUUID().toString(), 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key, UUID.randomUUID().toString(),
            AgentEndpointTransport.MOSH_TMUX, tmuxSession = "fixture", windowID = "@1", paneID = "%75"))
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities(lifecycleFeed = true, freshTerminalObservation = true,
            remoteData = true, verifiedInput = true, semanticKeys = true, guardedFocus = true))
        override val lifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>()
        @Volatile private var closed = false
        val writes = CopyOnWriteArrayList<String>()
        val keys = CopyOnWriteArrayList<AgentSemanticKey>()
        val events = CopyOnWriteArrayList<String>()
        val beforeReturn = CopyOnWriteArrayList<String?>()
        val afterReturn = CopyOnWriteArrayList<String?>()

        override fun isCurrentRoute(candidate: AgentEndpointBinding) = !closed && candidate.sameRouteAs(binding.value)
        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider,
            requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> =
            if (!isCurrentRoute(binding)) AgentEndpointResult.StaleBinding
            else AgentEndpointResult.Success(AgentProcessProof(setOf(claimedPID), provider, "fixture-$claimedPID"))

        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> {
            if (!isCurrentRoute(binding)) return AgentEndpointResult.StaleBinding
            val body = if (writes.isEmpty()) "" else {
                val captures = if (keys.isEmpty()) beforeReturn else afterReturn
                val script = if (keys.isEmpty()) before else after
                script[minOf(captures.size, script.lastIndex)].also { captures.add(it) }
            }
            events.add("inspect:${if (body == "") "empty" else body ?: "unrecognized"}")
            return AgentEndpointResult.Success(screen(body))
        }

        // null is a coherent capture during a redraw with no recognizable
        // composer. It must not be confused with an empty Claude prompt.
        private fun screen(body: String?): AgentTerminalObservation {
            val lines = body?.split('\n')?.mapIndexed { index, line -> if (index == 0) "❯ $line" else "  $line" }
                ?: listOf("redrawing")
            return AgentTerminalObservation(binding.value, (lines.joinToString("\n") + "\n────\n? for shortcuts").encodeToByteArray(),
                truncated = false, authoritative = true, currentCursorLine = lines.last(), cursorRow = lines.lastIndex,
                cursorColumn = lines.last().length, cursorVisible = true)
        }

        fun assess(body: String?, text: String, safetyOnly: Boolean = false, literalOnly: Boolean = false): Assessment {
            val observation = screen(body)
            return SharedAgentComposerEvidence.assess("claude", observation.visibleTail.decodeToString(), observation.currentCursorLine,
                text, false, cursorRow = observation.cursorRow, safetyOnly = safetyOnly, cursorVisible = observation.cursorVisible,
                cursorColumn = observation.cursorColumn, literalImagePathsOnly = literalOnly)
        }

        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> {
            if (!isCurrentRoute(binding)) return AgentEndpointResult.StaleBinding
            writes.add(bytes.decodeToString())
            events.add("insert:${bytes.decodeToString()}")
            return AgentEndpointResult.Success(Unit)
        }
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> {
            if (!isCurrentRoute(binding)) return AgentEndpointResult.StaleBinding
            keys.add(key)
            events.add("key:$key")
            return AgentEndpointResult.Success(Unit)
        }
        private fun unavailable() = AgentEndpointResult.Unavailable("host-free Claude submit fixture")
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> = unavailable()
        override suspend fun processDiscoveryScope(binding: AgentEndpointBinding): AgentEndpointResult<AgentProcessDiscoveryScope> = unavailable()
        override suspend fun probeIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationStatus> = unavailable()
        override suspend fun readIntegrationConfigs(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationConfigSnapshots> = unavailable()
        override suspend fun installIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> = unavailable()
        override suspend fun inspectCurrentShell(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentCurrentShellStatus> = unavailable()
        override suspend fun discoverProcesses(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentProcessDiscoverySnapshot> = unavailable()
        override suspend fun activateCurrentShell(binding: AgentEndpointBinding, expectedProcessIDs: Set<Int>, command: AgentShellActivationCommand): AgentEndpointResult<Unit> = unavailable()
        override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> = unavailable()
        override suspend fun focus(binding: AgentEndpointBinding) = AgentEndpointResult.Success(Unit)
        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> = unavailable()
        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> = unavailable()
        override fun close() { closed = true }
    }

    private companion object {
        const val IMAGE_DRAFT = "\"/tmp/shot.png\"\nDescribe this image"
        const val MARKERS = "[Image #1]\nDescribe this image"
        const val IMAGE_INSERTION = "\u001b[200~\"/tmp/shot.png\"\u001b[201~\u001b[200~\n\u001b[201~\u001b[200~Describe this image\u001b[201~"

        fun metadata(): AndroidAgentMetadataRepository {
            val dao = Class.forName("com.bambouville.tessera.data.AgentMetadataDao")
            val empty = Proxy.newProxyInstance(dao.classLoader, arrayOf(dao)) { _, method, _ ->
                when (method.name) { "threads", "repairThreadKeys" -> emptyList<Any>(); "thread" -> null; else -> Unit }
            }
            return AndroidAgentMetadataRepository::class.java.getDeclaredConstructor(dao).also { it.isAccessible = true }.newInstance(empty)
        }
        fun unusedPreferences(): AndroidAgentCenterViewPreferences {
            val unsafe = Unsafe::class.java.getDeclaredField("theUnsafe").also { it.isAccessible = true }.get(null) as Unsafe
            return unsafe.allocateInstance(AndroidAgentCenterViewPreferences::class.java) as AndroidAgentCenterViewPreferences
        }
    }
}
