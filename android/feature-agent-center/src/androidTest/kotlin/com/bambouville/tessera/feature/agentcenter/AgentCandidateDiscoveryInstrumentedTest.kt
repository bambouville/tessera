package com.bambouville.tessera.feature.agentcenter

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationForeground
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
import com.bambouville.tessera.design.TesseraTheme
import java.io.File
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.json.JSONObject

/** Host-free process facts through the production coordinator, JNI reducer and presenter. */
class AgentCandidateDiscoveryInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun discoverySweepRetiresTheFieldOrphanAfterRefusedTerminalEvents() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val registry = LiveAgentSessionRegistry()
        val coordinator = AndroidAgentSessionCoordinator(registry)
        val endpoint = CandidateEndpoint()
        endpoint.occupancyEnabled = true
        endpoint.binding.value = endpoint.binding.value.copy(paneID = "%75")
        endpoint.processes = listOf(AgentDiscoveredProcess(95076, 42, "/usr/local/bin/claude", true))
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
            ?: throw AssertionError("$name timed out; rows=${presenter.state.value.threads.map { it.providerSessionID }} logs=$logs")
        try {
            withContext(Dispatchers.Main) { presenter.setEnabled(true) }
            // The feed has no replay: a frame emitted before the presenter
            // subscribes is dropped.
            step("lifecycle subscription") { endpoint.lifecycleFrames.subscriptionCount.first { it > 0 } }
            endpoint.lifecycleFrames.emit(frame("field-A", 95076, "SessionStart"))
            step("field-A row") { presenter.state.first { it.threads.singleOrNull()?.providerSessionID == "field-A" } }
            val memo = coordinator.javaClass.getDeclaredField("issuedRoutes").also { it.isAccessible = true }.get(coordinator)
            memo.javaClass.getDeclaredMethod("clear").also { it.isAccessible = true }.invoke(memo)
            endpoint.processes = emptyList()
            endpoint.lifecycleFrames.emit(frame("field-A", 95076, "SessionEnd"))
            step("refused SessionEnd") { while (logs.none { it.first == "agent_lifecycle_refused" &&
                it.second["detail"].orEmpty().contains("proof_exit_1") }) delay(10) }
            endpoint.lifecycleFrames.emit(frame("", null, "WrapperExit"))
            endpoint.processes = listOf(AgentDiscoveredProcess(2, 42, "/usr/local/bin/claude", true))
            endpoint.lifecycleFrames.emit(frame("field-B", 2, "SessionStart"))
            val kept = step("field-B only") { presenter.state.first { it.threads.map { row -> row.providerSessionID } == listOf("field-B") } }
            assertTrue(kept.candidates.isEmpty())
            assertTrue(logs.any { it.first == "agent_route_retired" && it.second["pid"] == "95076" })
            assertTrue(logs.any { it.first == "agent_lifecycle_refused" && it.second["detail"].orEmpty().contains("blank-session-id") })
        } finally {
            withContext(Dispatchers.Main) { presenter.close() }
            registration.close(); integration.close(); coordinator.close(); scope.cancel()
        }
    }

    @Test fun providerParentAndChildHaveOneTerminalFallback(): Unit = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        // The before capture explicitly expects the restored build's two rows.
        val expected = arguments.getString("tesseraDiscoveryExpected")?.toInt() ?: 1
        val stage = arguments.getString("tesseraDiscoveryStage") ?: "after"
        require(stage in setOf("before", "after"))
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val registry = LiveAgentSessionRegistry()
        val coordinator = AndroidAgentSessionCoordinator(registry)
        val endpoint = CandidateEndpoint()
        val registration = registry.register(endpoint)
        val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
        val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
            AndroidAgentCenterViewPreferences(context), scope, integration,
            diagnostics = { code, values -> android.util.Log.i("TesseraCandidates", "$code $values") })
        try {
            compose.setContent {
                val state by presenter.state.collectAsState()
                TesseraTheme {
                    AgentListPane(state, {}, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding())
                }
            }
            withContext(Dispatchers.Main) { presenter.setEnabled(true) }
            withTimeout(10_000) { presenter.state.first { it.candidates.size >= expected } }
            delay(300) // Allow both queued native registration snapshots to reach Compose.
            compose.waitForIdle()
            assertEquals(expected, presenter.state.value.candidates.size)
            compose.onAllNodesWithText("Claude Code terminal").assertCountEquals(expected)
            delay(800) // Let the emulator compositor present the asserted Compose frame.
            val shot = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
            File(context.filesDir, "agent-candidates-$stage.png").outputStream().use {
                check(shot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
            }
            shot.recycle()
            if (stage == "after") {
                compose.onAllNodesWithText("Working on the fixture task", substring = true).assertCountEquals(1)
                val original = endpoint.binding.value
                // Real lifecycle acceptance through the coordinator proof path.
                endpoint.lifecycleFrames.emit(AgentLifecycleFrame(original,
                    """{"version":9,"provider":"claude","event":"SessionStart","state":"idle","timestampNs":"1","sessionId":"fixture-conversation","agentPid":102,"transcriptRef":"b3BhcXVl"}""".encodeToByteArray()))
                android.util.Log.i("TesseraCandidates", "awaiting lifecycle identity")
                withTimeout(10_000) { presenter.state.first { it.threads.size == 1 && it.candidates.isEmpty() } }
                withContext(Dispatchers.Main) {
                    endpoint.binding.value = original.copy(paneID = "%3")
                    registry.refresh(endpoint.key)
                }
                withTimeout(10_000) { presenter.state.first { it.candidates.size == 1 } }
                withContext(Dispatchers.Main) {
                    endpoint.binding.value = original
                    registry.refresh(endpoint.key)
                }
                withTimeout(10_000) { presenter.state.first { it.candidates.isEmpty() } }
                delay(2_500)
                assertEquals(0, presenter.state.value.candidates.size)
                assertEquals(1, presenter.state.value.threads.size)

                // Equal Set.hashCode values must not retain exited identity PID102.
                assertEquals(setOf(101, 102, 103).hashCode(), setOf(101, 100, 105).hashCode())
                endpoint.processes = listOf(AgentDiscoveredProcess(101, 42, "/usr/local/bin/claude", true),
                    AgentDiscoveredProcess(100, 42, "/bin/sh", true), AgentDiscoveredProcess(105, 42, "/bin/sh", true))
                withTimeout(10_000) { presenter.state.first { it.candidates.size == 1 } }

                // A cancelled inspection can return after focus A -> B -> A.
                // Its old process list must never resurrect a candidate.
                val entered = CompletableDeferred<Unit>()
                val release = CompletableDeferred<Unit>()
                endpoint.inspectGate = entered to release
                withTimeout(10_000) { entered.await() }
                endpoint.processes = emptyList()
                withContext(Dispatchers.Main) {
                    endpoint.binding.value = original.copy(paneID = "%3")
                    registry.refresh(endpoint.key)
                }
                delay(150)
                withContext(Dispatchers.Main) {
                    endpoint.binding.value = original
                    registry.refresh(endpoint.key)
                }
                delay(150)
                release.complete(Unit)
                delay(500)
                assertTrue("cancelled inspection must not publish after ABA focus", presenter.state.value.candidates.isEmpty())
                assertEquals(1, presenter.state.value.threads.size)
            }
            android.util.Log.i("TesseraCandidates", "TESSERA_CANDIDATE_DISCOVERY rows=$expected stage=$stage processes=2 pane=%2")
        } finally {
            withContext(Dispatchers.Main) { presenter.close() }
            registration.close()
            integration.close()
            coordinator.close()
            scope.cancel()
        }
    }

    private class CandidateEndpoint : AgentSessionEndpoint {
        @Volatile var occupancyEnabled = false
        @Volatile var processes = listOf(AgentDiscoveredProcess(101, 42, "/usr/local/bin/claude", true),
            AgentDiscoveredProcess(102, 101, "/usr/local/bin/claude", true), AgentDiscoveredProcess(103, 42, "/bin/sh", true))
        @Volatile var inspectGate: Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
        override val key = AgentSessionKey("11111111-2222-3333-4444-555555555555", 1)
        override val binding = MutableStateFlow(AgentEndpointBinding(key,
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", AgentEndpointTransport.SSH_TMUX,
            hostDisplayLabel = "windows fixture", tmuxSession = "fixture", windowID = "@1", paneID = "%2"))
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities())
        override val lifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>()

        override suspend fun processDiscoveryScope(binding: AgentEndpointBinding) =
            AgentEndpointResult.Success(AgentProcessDiscoveryScope.RootProcess(42))
        override suspend fun discoverProcesses(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentProcessDiscoverySnapshot> {
            val snapshot = processes
            val ids = snapshot.mapTo(linkedSetOf()) { it.processID }
            return AgentEndpointResult.Success(AgentProcessDiscoverySnapshot(snapshot,
                SharedAgentIntegrationForeground.Agent, emptySet(), ids, ids, true))
        }
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> {
            inspectGate?.let { (entered, release) ->
                inspectGate = null
                entered.complete(Unit)
                withContext(NonCancellable) { release.await() }
            }
            return AgentEndpointResult.Success(AgentTerminalObservation(binding,
                "\u001b[32mWorking on the fixture task\u001b[0m\n".encodeToByteArray(), false, authoritative = true))
        }

        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider, requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> {
            if (!occupancyEnabled) return AgentEndpointResult.Success(AgentProcessProof(setOf(101, 102, 103), provider, "fixture-start"))
            val ids = processes.mapTo(linkedSetOf()) { it.processID }
            return if (claimedPID in ids) AgentEndpointResult.Success(AgentProcessProof(ids, provider, "fixture-start"))
                else AgentEndpointResult.Failed("proof_exit_1")
        }
        override suspend fun observeOccupancy(bindings: List<AgentEndpointBinding>): AgentEndpointResult<AgentOccupancySnapshot> =
            if (!occupancyEnabled) unavailable() else AgentEndpointResult.Success(AgentOccupancySnapshot(bindings.map {
                AgentOccupancyPane(it.paneID, true, true, processes.filter { process -> process.executable.endsWith("/claude") }
                    .map { process -> AgentOccupancyProcess(process.processID, AgentProofProvider.CLAUDE) })
            }, listOf(binding.value.paneID!!)))

        override suspend fun probeIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationStatus> = unavailable()
        override suspend fun readIntegrationConfigs(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentIntegrationConfigSnapshots> = unavailable()
        override suspend fun installIntegration(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<SharedAgentIntegrationInstallOutcome> = unavailable()
        override suspend fun inspectCurrentShell(binding: AgentEndpointBinding, command: AgentIntegrationCommand): AgentEndpointResult<AgentCurrentShellStatus> = unavailable()
        override suspend fun activateCurrentShell(binding: AgentEndpointBinding, expectedProcessIDs: Set<Int>, command: AgentShellActivationCommand): AgentEndpointResult<Unit> = unavailable()
        override suspend fun validatedDirectories(binding: AgentEndpointBinding): AgentEndpointResult<List<String>> = unavailable()
        override suspend fun execute(binding: AgentEndpointBinding, request: AgentExecRequest): AgentEndpointResult<AgentRemoteExecStream> = unavailable()
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> = unavailable()
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> = unavailable()
        override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> = unavailable()
        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> = unavailable()
        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> = unavailable()
        override fun close() {}
        private fun unavailable() = AgentEndpointResult.Unavailable("host-free discovery fixture")
    }
}
