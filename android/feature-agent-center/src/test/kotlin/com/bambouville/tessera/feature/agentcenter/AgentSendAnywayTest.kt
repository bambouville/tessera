package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.CoreCallResult
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.core.bridge.SharedAgentRuntimeEvent
import com.bambouville.tessera.core.bridge.SharedAgentSnapshotKind
import com.bambouville.tessera.core.bridge.SharedAgentValue
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

/** Real shared action plans and receipts; fake endpoints never connect to a host. */
class AgentSendAnywayTest {
    @Test fun occupiedComposerOffersOneExplicitRetryOnEveryTransport() = runBlocking {
        for (transport in AgentEndpointTransport.entries) {
            val rig = Rig(transport)
            try {
                val detail = rig.start()
                rig.endpoint.terminalDraft = "existing terminal draft"
                rig.request(detail, "hello from Agent Center")
                rig.awaitRetry()
                assertEquals("hello from Agent Center", rig.presenter.state.value.drafts[detail.row.key])
                assertTrue(rig.endpoint.writes.isEmpty())
                assertTrue(rig.endpoint.keys.isEmpty())
                assertTrue(rig.onPresenter { it.sendAnyway() })
                assertFalse(rig.onPresenter { it.sendAnyway() })
                rig.awaitFinished()
                assertEquals(listOf("\u001b[200~hello from Agent Center\u001b[201~"), rig.endpoint.writes.toList())
                assertEquals(listOf(AgentSemanticKey.RETURN), rig.endpoint.keys.toList())
                assertEquals("", rig.presenter.state.value.drafts[detail.row.key].orEmpty())
                assertNull(rig.presenter.state.value.sendAnywayNotice)
            } finally { rig.close() }
        }
    }

    @Test fun editingTheDraftAfterARefusalInvalidatesTheOverride() = runBlocking {
        val rig = Rig()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            rig.request(detail, "original refused message")
            rig.awaitRetry()
            rig.onPresenter { it.setDraft(detail.row.key, "a separate edited message") }
            assertFalse(rig.onPresenter { it.sendAnyway() })
            assertNull(rig.presenter.state.value.sendAnywayNotice)
            assertTrue(rig.endpoint.writes.isEmpty())
            assertTrue(rig.endpoint.keys.isEmpty())
            assertEquals("a separate edited message", rig.presenter.state.value.drafts[detail.row.key])
        } finally { rig.close() }
    }

    @Test fun imageOverrideInspectsAfterInsertionBeforeReturnAndStopsWhenReady() = runBlocking {
        for (provider in listOf("claude", "codex")) {
            val rig = Rig(provider = provider)
            val release = CompletableDeferred<Unit>()
            try {
                val detail = rig.start()
                rig.endpoint.captureUnavailable = true
                rig.request(detail, "\"/tmp/attachment.png\"")
                rig.awaitRetry()
                val inspections = rig.endpoint.inspections
                val entered = CompletableDeferred<Unit>()
                rig.endpoint.inspectionGate = entered to release
                rig.endpoint.captureUnavailable = false
                assertTrue(rig.onPresenter { it.sendAnyway() })
                withTimeout(5_000) { entered.await() }
                assertEquals(1, rig.endpoint.writes.size)
                assertTrue(rig.endpoint.keys.isEmpty())
                rig.endpoint.attachedImageProvider = provider
                release.complete(Unit)
                rig.awaitFinished()
                assertEquals(listOf(AgentSemanticKey.RETURN), rig.endpoint.keys.toList())
                assertEquals(listOf(inspections + 1), rig.endpoint.inspectionsAtKey.toList())
                assertEquals(inspections + 1, rig.endpoint.inspections)
            } finally { release.complete(Unit); rig.close() }
        }
    }

    @Test fun imageOverrideStillSendsReturnWhenComposerNeverReadsReady() = runBlocking {
        for (provider in listOf("claude", "codex")) {
            val rig = Rig(provider = provider)
            try {
                val detail = rig.start()
                rig.endpoint.captureUnavailable = true
                rig.request(detail, "\"/tmp/attachment.png\"")
                rig.awaitRetry()
                val inspections = rig.endpoint.inspections
                // A slow link: every check would add up to seconds.
                rig.endpoint.inspectionDelayMillis = 150
                val started = System.nanoTime()
                assertTrue(rig.onPresenter { it.sendAnyway() })
                rig.awaitFinished()
                assertEquals(1, rig.endpoint.writes.size)
                assertEquals(listOf(AgentSemanticKey.RETURN), rig.endpoint.keys.toList())
                val checks = rig.endpoint.inspectionsAtKey.single() - inspections
                assertTrue("checks=$checks", checks in 5 until (if (provider == "claude") 40 else 20))
                val waitedMillis = (System.nanoTime() - started) / 1_000_000
                assertTrue("waited=$waitedMillis", waitedMillis < AGENT_OVERRIDE_IMAGE_WAIT_MILLIS + 1_500)
            } finally { rig.close() }
        }
    }

    @Test fun imageOverrideReprovesTheProcessAfterTheAttachmentWait() = runBlocking {
        val rig = Rig()
        val release = CompletableDeferred<Unit>()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            rig.request(detail, "\"/tmp/attachment.png\"")
            rig.awaitRetry()
            val entered = CompletableDeferred<Unit>()
            rig.endpoint.inspectionGate = entered to release
            assertTrue(rig.onPresenter { it.sendAnyway() })
            withTimeout(5_000) { entered.await() }
            assertEquals(1, rig.endpoint.writes.size)
            rig.endpoint.foregroundProofFailure = AgentEndpointResult.Failed("proof_exit_1", proofReason = "backgroundProcess")
            release.complete(Unit)
            rig.awaitFinished()
            assertTrue(rig.endpoint.keys.isEmpty())
        } finally { release.complete(Unit); rig.close() }
    }

    @Test fun captureOverrideSendsOnlyTheOriginalPartOfAnUnchangedMergedDraft() = runBlocking {
        val rig = Rig()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            rig.endpoint.inspectionGate = entered to release
            rig.request(detail, "original refused message")
            withTimeout(5_000) { entered.await() }
            rig.onPresenter { it.setDraft(detail.row.key, "what I typed while waiting") }
            release.complete(Unit)
            rig.awaitRetry()
            assertEquals("original refused message\n\nwhat I typed while waiting", rig.presenter.state.value.drafts[detail.row.key])
            val inspections = rig.endpoint.inspections
            assertTrue(rig.onPresenter { it.sendAnyway() })
            rig.awaitFinished()
            assertEquals(listOf("\u001b[200~original refused message\u001b[201~"), rig.endpoint.writes.toList())
            assertEquals(listOf(AgentSemanticKey.RETURN), rig.endpoint.keys.toList())
            assertEquals("what I typed while waiting", rig.presenter.state.value.drafts[detail.row.key])
            assertEquals("Explicit override should not need another capture", inspections, rig.endpoint.inspections)
        } finally { rig.close() }
    }

    @Test fun textEditedAfterTheRetryClickSurvivesItsDelayedActionPlan() = runBlocking {
        val rig = Rig()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            rig.request(detail, "original refused message")
            rig.awaitRetry()
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            rig.actionPlanGate = entered to release
            assertTrue(rig.onPresenter { it.sendAnyway() })
            withTimeout(5_000) { entered.await() }
            rig.onPresenter { it.setDraft(detail.row.key, "new text after my retry click") }
            release.complete(Unit)
            rig.awaitFinished()
            assertEquals(listOf("\u001b[200~original refused message\u001b[201~"), rig.endpoint.writes.toList())
            assertEquals("new text after my retry click", rig.presenter.state.value.drafts[detail.row.key])
        } finally { rig.close() }
    }

    @Test fun messageRevisedBeforeTheOriginalActionPlanDoesNotOfferTheOldText() = runBlocking {
        val rig = Rig()
        val release = CompletableDeferred<Unit>()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            val entered = CompletableDeferred<Unit>()
            rig.actionPlanGate = entered to release
            rig.request(detail, "original")
            withTimeout(5_000) { entered.await() }
            rig.onPresenter { it.setDraft(detail.row.key, "original revised before acceptance") }
            release.complete(Unit)
            rig.awaitFinished()
            assertEquals("original revised before acceptance", rig.presenter.state.value.drafts[detail.row.key])
            assertNull(rig.presenter.state.value.sendAnywayNotice)
            assertFalse(rig.onPresenter { it.sendAnyway() })
            assertTrue(rig.endpoint.writes.isEmpty())
            assertTrue(rig.endpoint.keys.isEmpty())
        } finally { release.complete(Unit); rig.close() }
    }

    @Test fun missedOrRejectedTargetProofNeverOffersOverride() = runBlocking {
        for (failure in listOf(
            AgentEndpointResult.Failed("proof_timeout"),
            AgentEndpointResult.Failed("proof_exit_1", proofReason = "backgroundProcess"),
            AgentEndpointResult.StaleBinding,
        )) {
            val rig = Rig()
            try {
                val detail = rig.start()
                rig.endpoint.foregroundProofFailure = failure
                rig.request(detail, "do not send to an unproven process")
                rig.awaitFinished()
                assertNull(rig.presenter.state.value.sendAnywayNotice)
                assertFalse(rig.onPresenter { it.sendAnyway() })
                assertTrue(rig.endpoint.writes.isEmpty())
                assertTrue(rig.endpoint.keys.isEmpty())
            } finally { rig.close() }
        }
    }

    @Test fun unavailableInputNeverOffersOverride() = runBlocking {
        val rig = Rig()
        try {
            val detail = rig.start()
            rig.endpoint.capabilities.value = rig.endpoint.capabilities.value.copy(verifiedInput = false)
            rig.request(detail, "keep this draft")
            rig.awaitFinished()
            assertNull(rig.presenter.state.value.sendAnywayNotice)
            assertFalse(rig.onPresenter { it.sendAnyway() })
            assertTrue(rig.endpoint.writes.isEmpty())
            assertTrue(rig.endpoint.keys.isEmpty())
        } finally { rig.close() }
    }

    @Test fun verificationFailureAfterInsertionNeverOffersAnotherInsertion() = runBlocking {
        val rig = Rig()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailableAfterInsertion = true
            rig.request(detail, "inserted but not submitted")
            rig.awaitFinished()
            assertEquals(1, rig.endpoint.writes.size)
            assertTrue(rig.endpoint.keys.isEmpty())
            assertNull(rig.presenter.state.value.sendAnywayNotice)
            assertFalse(rig.onPresenter { it.sendAnyway() })
            assertEquals(1, rig.endpoint.writes.size)
        } finally { rig.close() }
    }

    @Test fun dismissalOrSelectionChangeInvalidatesTheExactCandidate() = runBlocking {
        for (action in listOf("dismiss", "selection", "notification")) {
            val rig = Rig()
            try {
                val detail = rig.start()
                rig.endpoint.captureUnavailable = true
                rig.request(detail, "original refused message")
                rig.awaitRetry()
                rig.onPresenter {
                    when (action) {
                        "dismiss" -> it.clearNotice()
                        "selection" -> it.select(null)
                        else -> it.prearmPromptReview("another-thread")
                    }
                }
                assertNull(rig.presenter.state.value.sendAnywayNotice)
                assertFalse(rig.onPresenter { it.sendAnyway() })
                assertTrue(rig.endpoint.writes.isEmpty())
                assertTrue(rig.endpoint.keys.isEmpty())
            } finally { rig.close() }
        }
    }

    @Test fun notificationSelectionDuringPreflightCannotOfferTheOldThreadsRetry() = runBlocking {
        val rig = Rig()
        val release = CompletableDeferred<Unit>()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            val entered = CompletableDeferred<Unit>()
            rig.endpoint.inspectionGate = entered to release
            rig.request(detail, "message for the old selection")
            withTimeout(5_000) { entered.await() }
            rig.onPresenter { it.prearmPromptReview("another-thread") }
            release.complete(Unit)
            rig.awaitFinished()
            assertNull(rig.presenter.state.value.sendAnywayNotice)
            assertFalse(rig.onPresenter { it.sendAnyway() })
            assertTrue(rig.endpoint.writes.isEmpty())
            assertTrue(rig.endpoint.keys.isEmpty())
        } finally { release.complete(Unit); rig.close() }
    }

    @Test fun aNewNormalActionInvalidatesThePreviousOverride() = runBlocking {
        val rig = Rig()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            rig.request(detail, "old refused message")
            rig.awaitRetry()
            rig.endpoint.captureUnavailable = false
            rig.request(rig.detail(), "new requested message")
            assertFalse(rig.onPresenter { it.sendAnyway() })
            rig.awaitFinished()
            assertEquals(listOf("\u001b[200~new requested message\u001b[201~"), rig.endpoint.writes.toList())
            assertEquals(listOf(AgentSemanticKey.RETURN), rig.endpoint.keys.toList())
        } finally { rig.close() }
    }

    @Test fun carrierReplacementInvalidatesTheRefusedMessage() = runBlocking {
        val rig = Rig()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            rig.request(detail, "must stay on its original carrier")
            rig.awaitRetry()
            rig.unbind(detail)
            rig.await { rig.bindingToken(detail) == null }
            rig.endpoint.close()
            val replacement = Endpoint(rig.endpoint.binding.value.transport, rig.endpoint.binding.value.hostID, generation = 2)
            rig.register(replacement)
            rig.frame(replacement)
            rig.await { it.projectedDetails[detail.row.key]?.binding?.number("carrierGeneration") == "2" }
            assertFalse(rig.onPresenter { it.sendAnyway() })
            assertNull(rig.presenter.state.value.sendAnywayNotice)
            assertTrue(rig.endpoint.writes.isEmpty())
            assertTrue(replacement.writes.isEmpty())
            assertTrue(replacement.keys.isEmpty())
        } finally { rig.close() }
    }

    @Test fun overrideStillReprovesTheProcessBeforeWriting() = runBlocking {
        val rig = Rig()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            rig.request(detail, "refused original message")
            rig.awaitRetry()
            rig.endpoint.foregroundProofFailure = AgentEndpointResult.Failed("proof_exit_1", proofReason = "backgroundProcess")
            assertTrue(rig.onPresenter { it.sendAnyway() })
            rig.awaitFinished()
            assertTrue(rig.endpoint.writes.isEmpty())
            assertTrue(rig.endpoint.keys.isEmpty())
            assertNull(rig.presenter.state.value.sendAnywayNotice)
        } finally { rig.close() }
    }

    @Test fun overrideDoesNotSubmitIfTheProcessChangesAfterItsInsertion() = runBlocking {
        val rig = Rig()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            rig.request(detail, "insert once but never submit to a changed process")
            rig.awaitRetry()
            rig.endpoint.processChangedAfterInsertion = true
            assertTrue(rig.onPresenter { it.sendAnyway() })
            rig.awaitFinished()
            assertEquals(listOf("\u001b[200~insert once but never submit to a changed process\u001b[201~"), rig.endpoint.writes.toList())
            assertTrue(rig.endpoint.keys.isEmpty())
            assertNull(rig.presenter.state.value.sendAnywayNotice)
            assertFalse(rig.onPresenter { it.sendAnyway() })
            assertEquals(1, rig.endpoint.writes.size)
        } finally { rig.close() }
    }

    @Test fun codexQueueOverrideUsesTabAndRetainsTheOriginalActionKind() = runBlocking {
        val rig = Rig(provider = "codex")
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            rig.request(detail, "queue the exact original message", kind = "queue")
            rig.awaitRetry()
            assertTrue(rig.onPresenter { it.sendAnyway() })
            rig.awaitFinished()
            assertEquals(listOf("\u001b[200~queue the exact original message\u001b[201~"), rig.endpoint.writes.toList())
            assertEquals(listOf(AgentSemanticKey.TAB), rig.endpoint.keys.toList())
            assertEquals(2, rig.logs.count { it.first == "agent_action_requested" && it.second["action"] == "queue" })
            assertTrue(rig.logs.none { it.first == "agent_action_requested" && it.second["action"] == "send" })
        } finally { rig.close() }
    }

    @Test fun delayedWithdrawalOffersRetryOnlyAfterTheLateSnapshotProvesNothingWasSent() = runBlocking {
        val rig = Rig()
        val release = CompletableDeferred<Unit>()
        try {
            val detail = rig.start()
            rig.endpoint.captureUnavailable = true
            val entered = CompletableDeferred<Unit>()
            rig.notSentSnapshotGate = entered to release
            rig.request(detail, "message whose withdrawal arrives late")
            withTimeout(6_000) { entered.await() }
            rig.await { rig.logs.any { (event, fields) -> event == "agent_send_not_sent_settled" &&
                fields["settlement"] == "ambiguous_watch" } }
            assertNull(rig.presenter.state.value.sendAnywayNotice)
            assertTrue(rig.endpoint.writes.isEmpty())
            release.complete(Unit)
            rig.awaitRetry()
            assertEquals("message whose withdrawal arrives late", rig.presenter.state.value.drafts[detail.row.key])
            rig.onPresenter {
                val state = it.state.value
                assertTrue("notice=${state.notice}; retry=${state.sendAnywayNotice}; logs=${rig.logs.takeLast(25)}", it.sendAnyway())
            }
            rig.awaitFinished()
            assertEquals(listOf("\u001b[200~message whose withdrawal arrives late\u001b[201~"), rig.endpoint.writes.toList())
            assertEquals(listOf(AgentSemanticKey.RETURN), rig.endpoint.keys.toList())
        } finally { release.complete(Unit); rig.close() }
    }

    @Test fun anUnrelatedResultRejectionStillReplacesANormalRetryNotice() = runBlocking {
        for (foreignLease in listOf(false, true)) {
            val rig = Rig()
            try {
                val detail = rig.start()
                rig.endpoint.captureUnavailable = true
                rig.request(detail, "ordinary refused message")
                rig.awaitRetry()
                assertTrue(rig.logs.none { it.first == "agent_send_not_sent_probe" })
                val details = if (foreignLease) {
                    val lease = requireNotNull(rig.lastActionLease)
                    SharedAgentValue.ObjectValue(mapOf("lease" to SharedAgentValue.ObjectValue(lease.fields +
                        ("token" to SharedAgentValue.StringValue(UUID.randomUUID().toString())))))
                } else SharedAgentValue.ObjectValue(emptyMap())
                rig.consume(SharedAgentRuntimeEvent.Failure(0, "abi_invalidField@result", details))
                assertEquals(agentRejectionNotice("abi_invalidField@result"), rig.presenter.state.value.notice)
                assertFalse(rig.onPresenter { it.sendAnyway() })
                assertTrue(rig.endpoint.writes.isEmpty())
                assertTrue(rig.endpoint.keys.isEmpty())
            } finally { rig.close() }
        }
    }

    private class Rig(
        transport: AgentEndpointTransport = AgentEndpointTransport.MOSH_TMUX,
        val provider: String = "claude",
    ) {
        private val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        private val scope = CoroutineScope(SupervisorJob() + dispatcher)
        private val registry = LiveAgentSessionRegistry()
        private val coordinator = AndroidAgentSessionCoordinator(registry)
        private val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
        private val runtime = coordinator.runtime()
        val endpoint = Endpoint(transport)
        private val endpoints = mutableListOf(endpoint)
        private val registrations = mutableListOf(registry.register(endpoint))
        val logs = CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
        @Volatile var actionPlanGate: Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
        @Volatile var notSentSnapshotGate: Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
        @Volatile var lastActionLease: SharedAgentValue.ObjectValue? = null
        val presenter = AgentCenterPresenter(coordinator, metadata(), unusedPreferences(), scope, integration,
            diagnostics = { event, fields -> logs.add(event to fields) })
        init {
            field("runtime").set(presenter, runtime)
            field("enabled").setBoolean(presenter, true)
            // No display watcher may consume captures intended for the action.
            field("applicationForeground").setBoolean(presenter, false)
            scope.launch { runtime.events.collect { event ->
                if (event is SharedAgentRuntimeEvent.Snapshot && event.snapshot.kind == SharedAgentSnapshotKind.ActionPlan) {
                    lastActionLease = event.snapshot.payload.obj("lease")
                    actionPlanGate?.let { (entered, release) -> actionPlanGate = null; entered.complete(Unit); release.await() }
                }
                if (event is SharedAgentRuntimeEvent.Snapshot && event.snapshot.payload.string("code") == "notSent") {
                    notSentSnapshotGate?.let { (entered, release) -> notSentSnapshotGate = null; entered.complete(Unit); release.await() }
                }
                presenter.consume(event)
            } }
        }
        fun register(endpoint: Endpoint) { endpoints.add(endpoint); registrations.add(registry.register(endpoint)) }
        suspend fun start(): AgentThreadDetail {
            frame(endpoint)
            await { it.projectedDetails.isNotEmpty() }
            val detail = detail()
            onPresenter { it.select(detail.row.key) }
            return detail
        }
        suspend fun frame(endpoint: Endpoint) = withContext(dispatcher) {
            val transcript = Base64.getUrlEncoder().withoutPadding().encodeToString("/fixture/send-anyway".encodeToByteArray())
            presenter.consumeLifecycle(endpoint, AgentLifecycleFrame(endpoint.binding.value, JSONObject()
                .put("version", 9).put("provider", provider).put("event", "SessionStart").put("state", "idle")
                .put("timestampNs", "${System.nanoTime()}").put("sessionId", "send-anyway").put("agentPid", 42)
                .put("transcriptRef", transcript).toString().encodeToByteArray()))
        }
        fun detail() = presenter.state.value.projectedDetails.getValue(
            canonicalAgentThreadKey(endpoint.binding.value.hostID, provider, "send-anyway"))
        @Suppress("UNCHECKED_CAST") fun bindingToken(detail: AgentThreadDetail): String? =
            (field("bindingTokens").get(presenter) as Map<String, String>)[requireNotNull(detail.binding).toJson().tokenKey(detail.row.key)]
        suspend fun unbind(detail: AgentThreadDetail) = withContext(dispatcher) {
            assertEquals(CoreCallResult.Accepted, runtime.sendCanonical(JSONObject().put("v", 1).put("kind", "unbind")
                .put("threadID", detail.row.threadIDJson()).toString().encodeToByteArray()))
        }
        suspend fun request(detail: AgentThreadDetail, text: String, kind: String = "send") {
            assertTrue(onPresenter { it.setDraft(detail.row.key, text); it.requestAction(detail, kind, text) })
        }
        suspend fun awaitRetry() = await { it.sendAnywayNotice != null && it.sendAnywayNotice == it.notice && it.sendingThreads.isEmpty() }
        suspend fun awaitFinished() = await { it.sendingThreads.isEmpty() &&
            logs.any { (event, _) -> event in setOf("agent_action_finished", "agent_send_not_sent_settled") } }
        suspend fun <T> onPresenter(action: (AgentCenterPresenter) -> T): T = withContext(dispatcher) { action(presenter) }
        suspend fun consume(event: SharedAgentRuntimeEvent) = withContext(dispatcher) { presenter.consume(event) }
        // Predicates may read presenter fields, logs or events that change
        // without a state emission; re-check them on a tick as well.
        suspend fun await(predicate: (AgentCenterUiState) -> Boolean): AgentCenterUiState =
            withTimeoutOrNull(12_000) {
                merge(presenter.state, flow { while (true) { delay(10); emit(presenter.state.value) } }).first(predicate)
            }
                ?: throw AssertionError("timed out; pending=${presenter.state.value.sendingThreads} logs=${logs.takeLast(20)}")
        suspend fun close() {
            withContext(NonCancellable + dispatcher) { presenter.close(); integration.close(); coordinator.close() }
            registrations.forEach { it.close() }; endpoints.forEach { it.close() }; scope.cancel(); dispatcher.close()
        }
        private fun field(name: String) = AgentCenterPresenter::class.java.getDeclaredField(name).also { it.isAccessible = true }
    }

    private class Endpoint(
        transport: AgentEndpointTransport,
        host: String = UUID.randomUUID().toString(),
        generation: Long = 1,
    ) : AgentSessionEndpoint {
        override val key = AgentSessionKey(UUID.randomUUID().toString(), generation)
        private val tmux = transport.name.endsWith("TMUX")
        override val binding = MutableStateFlow(AgentEndpointBinding(key, host, transport,
            tmuxSession = if (tmux) "fixture" else null, windowID = if (tmux) "@1" else null, paneID = if (tmux) "%75" else null))
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities(lifecycleFeed = true, freshTerminalObservation = true,
            remoteData = true, verifiedInput = true, semanticKeys = true, guardedFocus = true))
        override val lifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>()
        @Volatile private var closed = false
        @Volatile var terminalDraft = ""
        @Volatile var captureUnavailable = false
        @Volatile var captureUnavailableAfterInsertion = false
        @Volatile var processChangedAfterInsertion = false
        @Volatile var foregroundProofFailure: AgentEndpointResult<AgentProcessProof>? = null
        @Volatile var inspections = 0
        @Volatile var inspectionGate: Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
        @Volatile var attachedImageProvider: String? = null
        @Volatile var inspectionDelayMillis = 0L
        val writes = CopyOnWriteArrayList<String>()
        val keys = CopyOnWriteArrayList<AgentSemanticKey>()
        val inspectionsAtKey = CopyOnWriteArrayList<Int>()
        override fun isCurrentRoute(candidate: AgentEndpointBinding) = !closed && candidate.sameRouteAs(binding.value)
        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider,
            requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> {
            if (!isCurrentRoute(binding)) return AgentEndpointResult.StaleBinding
            if (requireForeground) foregroundProofFailure?.let { return it }
            return AgentEndpointResult.Success(AgentProcessProof(setOf(claimedPID), provider, "fixture-$claimedPID"))
        }
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> {
            inspections++
            inspectionGate?.let { (entered, release) -> inspectionGate = null; entered.complete(Unit); release.await() }
            if (writes.isNotEmpty() && inspectionDelayMillis > 0) delay(inspectionDelayMillis)
            if (!isCurrentRoute(binding)) return AgentEndpointResult.StaleBinding
            if (captureUnavailable || captureUnavailableAfterInsertion && writes.isNotEmpty()) return unavailable()
            val imageProvider = attachedImageProvider
            val line = if (imageProvider == null) "❯ $terminalDraft" else
                "${if (imageProvider == "codex") "›" else "❯"} [Image #1]"
            val visible = if (imageProvider == "codex") "$line\n\n? for shortcuts" else "$line\n────\nctx:25%"
            return AgentEndpointResult.Success(AgentTerminalObservation(binding, visible.encodeToByteArray(), false, true,
                currentCursorLine = line, cursorRow = 0, cursorColumn = line.length, cursorVisible = true))
        }
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> {
            if (!isCurrentRoute(binding)) return AgentEndpointResult.Failed("staleBinding", inputNotAdmitted = true)
            writes.add(bytes.decodeToString())
            terminalDraft = bytes.decodeToString().removePrefix("\u001b[200~").removeSuffix("\u001b[201~")
            if (processChangedAfterInsertion) foregroundProofFailure =
                AgentEndpointResult.Failed("proof_exit_1", proofReason = "backgroundProcess")
            return AgentEndpointResult.Success(Unit)
        }
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> {
            if (!isCurrentRoute(binding)) return AgentEndpointResult.StaleBinding
            inspectionsAtKey.add(inspections)
            keys.add(key)
            return AgentEndpointResult.Success(Unit)
        }
        private fun unavailable() = AgentEndpointResult.Unavailable("host-free send-anyway fixture")
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
