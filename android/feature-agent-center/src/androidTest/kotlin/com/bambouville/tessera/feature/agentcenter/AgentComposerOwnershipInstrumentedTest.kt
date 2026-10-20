package com.bambouville.tessera.feature.agentcenter

import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationForeground
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.data.AndroidAgentCenterViewPreferences
import com.bambouville.tessera.data.AndroidAgentMetadataRepository
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
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Production JNI ownership checks; synthetic endpoints never open a host connection. */
class AgentComposerOwnershipInstrumentedTest {
    @Test fun attachmentOriginAndCancellationAcrossFourTransports(): Unit = runBlocking {
        for (transport in AgentEndpointTransport.entries) {
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
            val registry = LiveAgentSessionRegistry()
            val coordinator = AndroidAgentSessionCoordinator(registry)
            val endpoint = CandidateEndpoint(transport)
            val registration = registry.register(endpoint)
            val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
            val presenter = AgentCenterPresenter(coordinator, AndroidAgentMetadataRepository(context),
                AndroidAgentCenterViewPreferences(context), scope, integration)
            try {
                withContext(Dispatchers.Main) { presenter.setEnabled(true) }
                endpoint.lifecycleFrames.emit(AgentLifecycleFrame(endpoint.binding.value,
                    """{"version":9,"provider":"codex","event":"SessionStart","state":"idle","timestampNs":"1","sessionId":"fixture-conversation","agentPid":102,"transcriptRef":"b3BhcXVl"}""".encodeToByteArray()))
                val row = withTimeout(10_000) { presenter.state.first { it.threads.isNotEmpty() } }.threads.single()
                withContext(Dispatchers.Main) { presenter.select(row.key) }
                val detail = withTimeout(10_000) { presenter.state.first { it.detail?.row?.key == row.key } }.detail!!
                for ((kind, expectedKey) in listOf("send" to AgentSemanticKey.RETURN, "queue" to AgentSemanticKey.TAB)) {
                    withContext(Dispatchers.Main) {
                        presenter.setDraft(row.key, "instruction")
                        check(presenter.requestAction(detail, kind, "instruction"))
                        check(row.key in presenter.state.value.sendingThreads)
                        check(!presenter.requestAction(detail, kind, "instruction"))
                        presenter.setDraft(row.key, "concurrent edit")
                    }
                    val key = withTimeout(10_000) { endpoint.submittedKeys.receive() }
                    assertEquals(expectedKey, key)
                    withTimeout(5_000) { presenter.state.first { it.sendingThreads.isEmpty() } }
                    assertEquals("concurrent edit", presenter.state.value.drafts[row.key])
                }
                withContext(Dispatchers.Main) {
                    presenter.setDraft(row.key, "initial")
                    check(presenter.beginAttachmentSelection(detail))
                    presenter.select(null)
                    presenter.setDraft("other-thread", "other draft")
                    presenter.completeAttachmentSelection(listOf("content://fixture/document"))
                    check(row.key in presenter.state.value.uploadingThreads)
                    check(!presenter.requestAction(detail, "send", "initial"))
                    presenter.setDraft(row.key, "edited while uploading")
                }
                withTimeout(5_000) { endpoint.uploadEntered.receive() }
                endpoint.uploadGate.complete("/private/file with spaces.txt")
                withTimeout(5_000) { presenter.state.first { it.uploadingThreads.isEmpty() } }
                assertEquals("edited while uploading\n\"/private/file with spaces.txt\"", presenter.state.value.drafts[row.key])
                assertEquals("other draft", presenter.state.value.drafts["other-thread"])
                // Removed route between picker launch and result: no upload starts.
                withContext(Dispatchers.Main) {
                    check(presenter.beginAttachmentSelection(detail))
                    endpoint.routeValid = false
                    presenter.completeAttachmentSelection(listOf("content://fixture/stale"))
                }
                assertEquals(1, endpoint.uploadCalls)
                // A non-cooperative transfer returning after disable cannot restore its old draft.
                endpoint.routeValid = true
                endpoint.uploadGate = CompletableDeferred()
                withContext(Dispatchers.Main) {
                    check(presenter.beginAttachmentSelection(detail))
                    presenter.completeAttachmentSelection(listOf("content://fixture/late"))
                }
                withTimeout(5_000) { endpoint.uploadEntered.receive() }
                withContext(Dispatchers.Main) { presenter.setEnabled(false); presenter.setDraft(row.key, "new generation") }
                endpoint.uploadGate.complete("/private/late.txt")
                delay(250)
                assertEquals("new generation", presenter.state.value.drafts[row.key])
                assertTrue(presenter.state.value.uploadingThreads.isEmpty())
                android.util.Log.i("TesseraComposerOwnership", "TESSERA_COMPOSER_OWNERSHIP $transport passed")
            } finally {
                withContext(Dispatchers.Main) { presenter.close() }
                registration.close(); integration.close(); coordinator.close(); scope.cancel()
            }
        }
        assertEquals("\"/a \\\"b\\\"/c\\\\d\"", quoteAgentAttachmentPath("/a \"b\"/c\\d"))
    }

    private class CandidateEndpoint(transport: AgentEndpointTransport) : AgentSessionEndpoint {
        @Volatile var processes = listOf(AgentDiscoveredProcess(101, 42, "/usr/local/bin/codex", true),
            AgentDiscoveredProcess(102, 101, "/usr/local/bin/codex", true), AgentDiscoveredProcess(103, 42, "/bin/sh", true))
        @Volatile var inspectGate: Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
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
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> {
            inspectGate?.let { (entered, release) ->
                inspectGate = null
                entered.complete(Unit)
                withContext(NonCancellable) { release.await() }
            }
            return AgentEndpointResult.Success(AgentTerminalObservation(binding,
                "› $inputText\n\ntab to queue message 97% context left".encodeToByteArray(), false, authoritative = true, cursorRow = 0, cursorVisible = true))
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
        var inputText = ""
        val submittedKeys = kotlinx.coroutines.channels.Channel<AgentSemanticKey>(kotlinx.coroutines.channels.Channel.UNLIMITED)
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> {
            inputText = bytes.decodeToString().removePrefix("\u001b[200~").removeSuffix("\u001b[201~")
            return AgentEndpointResult.Success(Unit)
        }
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> {
            submittedKeys.send(key)
            inputText = ""
            return AgentEndpointResult.Success(Unit)
        }
        override suspend fun focus(binding: AgentEndpointBinding): AgentEndpointResult<Unit> = unavailable()
        override suspend fun placeTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement): AgentEndpointResult<AgentTmuxPlacementReceipt> = unavailable()
        override suspend fun launchTmux(binding: AgentEndpointBinding, placement: AgentTmuxPlacement, requestID: String, request: ByteArray): AgentEndpointResult<AgentTmuxLaunchReceipt> = unavailable()
        var routeValid = true
        var uploadCalls = 0
        var uploadGate = CompletableDeferred<String>()
        val uploadEntered = kotlinx.coroutines.channels.Channel<Unit>(kotlinx.coroutines.channels.Channel.UNLIMITED)
        override fun isCurrentRoute(candidate: AgentEndpointBinding) = routeValid && candidate.sameRouteAs(binding.value)
        override suspend fun uploadAttachment(binding: AgentEndpointBinding, sourceURI: String): AgentEndpointResult<String> {
            uploadCalls++
            uploadEntered.send(Unit)
            return withContext(NonCancellable) { AgentEndpointResult.Success(uploadGate.await()) }
        }
        override fun close() {}
        private fun unavailable() = AgentEndpointResult.Unavailable("host-free discovery fixture")
    }
}
