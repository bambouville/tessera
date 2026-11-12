package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.*
import com.bambouville.tessera.core.bridge.CoreCallResult
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallOutcome
import com.bambouville.tessera.core.bridge.SharedAgentRuntimeEvent
import com.bambouville.tessera.core.bridge.SharedAgentRouteRetirement
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

/** Production action plans and receipts use the host JNI shared Core; endpoints never connect. */
class AgentCenterActionTest {
    @Test fun aCroppedClaudeQuestionAnswersThroughItsWaitingCall() = runBlocking<Unit> {
        val rig = Rig(AgentEndpointTransport.MOSH_TMUX)
        try {
            val thread = watchCroppedQuestion(rig)
            projectQuestionCall(rig, thread)
            rig.await {
                val prompt = it.projectedDetails[thread.row.key]?.prompt
                prompt?.question == "Which database?" && prompt.fresh != null
            }
            val detail = rig.detail("A", rig.mosh)
            val prompt = requireNotNull(detail.prompt)
            assertTrue(detail.canAnswerPrompt())
            // The fresh screen is read as the card was: through the thread's waiting call.
            rig.onPresenter { it.requestPromptAnswer(detail, prompt, AgentPromptAnswerChoice.Option("2")) }
            rig.await { rig.mosh.writes.any { bytes -> bytes.decodeToString() == "2" } }
        } finally { rig.close() }
    }

    @Test fun aCroppedClaudeQuestionTakesNoCallItsHookClosedBeforeThePageArrived() = runBlocking<Unit> {
        val rig = Rig(AgentEndpointTransport.MOSH_TMUX)
        try {
            val thread = watchCroppedQuestion(rig)
            // The question is answered and the next one, drawn with the same
            // choices, opens before the transcript page holding the first call.
            rig.frame("A", rig.mosh, event = "PostToolUse", reason = "question", toolUseId = "toolu_A",
                timestampNs = 1_799_999_999_000_000_000L)
            rig.frame("A", rig.mosh, event = "PreToolUse", reason = "question", toolUseId = "toolu_B",
                timestampNs = 1_800_000_000_000_000_000L)
            rig.await {
                val row = it.projectedDetails[thread.row.key]?.row
                row?.lastActivityMillis == 1_800_000_000_000L && row.livePromptWatch
            }
            projectQuestionCall(rig, thread)
            val seen = rig.mosh.inspections.get()
            rig.await { rig.mosh.inspections.get() >= seen + 3 }
            delay(100)
            assertNull("the closed call must not name the dialog now on screen", rig.detail("A", rig.mosh).prompt)
            // The page holding the next call names it.
            projectQuestionCall(rig, thread, call = "toolu_B", answered = "toolu_A")
            rig.await { it.projectedDetails[thread.row.key]?.prompt?.question == "Which database?" }
        } finally { rig.close() }
    }

    @Test fun anAnswerPlannedForAClosedQuestionWritesNothingIntoTheNextOne() = runBlocking<Unit> {
        val rig = Rig(AgentEndpointTransport.MOSH_TMUX)
        try {
            val thread = watchCroppedQuestion(rig)
            projectQuestionCall(rig, thread)
            rig.await { it.projectedDetails[thread.row.key]?.prompt?.fresh != null }
            val detail = rig.detail("A", rig.mosh)
            // The answer proves its process once before it plans and again
            // before Core's check: that second proof is held while another
            // terminal answers the question and Claude asks the next with the
            // same choices, so the check sees both hooks.
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            rig.mosh.proofGate = Triple(rig.mosh.proofs.count { it } + 2, entered, release)
            rig.onPresenter { it.requestPromptAnswer(detail, requireNotNull(detail.prompt), AgentPromptAnswerChoice.Option("2")) }
            withTimeout(10_000) { entered.await() }
            rig.frame("A", rig.mosh, event = "PostToolUse", reason = "question", toolUseId = "toolu_A",
                timestampNs = 1_799_999_999_000_000_000L)
            rig.frame("A", rig.mosh, event = "PreToolUse", reason = "question", toolUseId = "toolu_B",
                timestampNs = 1_800_000_000_000_000_000L)
            rig.await { it.projectedDetails[thread.row.key]?.row?.lastActivityMillis == 1_800_000_000_000L }
            projectQuestionCall(rig, thread, call = "toolu_B", answered = "toolu_A")
            release.complete(Unit)
            rig.await { it.notice == "Prompt changed; review it in the terminal" }
            assertTrue("the planned digit must not answer the next question", rig.mosh.writes.isEmpty())
        } finally { rig.close() }
    }

    @Test fun anAnswerCoreClearedBeforeTheNextQuestionArrivedWritesNothingIntoIt() = runBlocking<Unit> {
        val rig = Rig(AgentEndpointTransport.MOSH_TMUX)
        try {
            val thread = watchCroppedQuestion(rig)
            projectQuestionCall(rig, thread)
            rig.await { it.projectedDetails[thread.row.key]?.prompt?.fresh != null }
            val detail = rig.detail("A", rig.mosh)
            // Core answers the check while the question still waits. Before the
            // presenter reads that yes, the next question is drawn and the live
            // watch forwards it, so only the count of question input forwarded
            // since the check can stop the write. The hook must not wait on the
            // collector it holds: a lifecycle frame's bind would. A newer frame
            // time restarts the watch's fast cadence within one 250 ms tick,
            // well inside the check's own wait.
            val watched = CompletableDeferred<Boolean>()
            rig.beforePromptCurrent = {
                val counted = rig.questionInputCount(thread.row.key)
                rig.mosh.screen = nextQuestionScreen
                rig.promptLifecycleNanos()[thread.row.key] = System.nanoTime()
                watched.complete(withTimeoutOrNull(1_000) {
                    while (rig.questionInputCount(thread.row.key) == counted) delay(10)
                    true
                } == true)
            }
            rig.onPresenter { it.requestPromptAnswer(detail, requireNotNull(detail.prompt), AgentPromptAnswerChoice.Option("2")) }
            assertTrue("the live watch must forward the next question within 1 s", withTimeout(10_000) { watched.await() })
            rig.await { it.notice == "Prompt changed; review it in the terminal" }
            assertNull("the reply must have been held", rig.beforePromptCurrent)
            assertTrue("Core must have been asked again and said the prompt changed", rig.events.any {
                it is SharedAgentRuntimeEvent.Snapshot && it.snapshot.payload.string("code") == "promptChanged"
            })
            assertTrue("the planned digit must not answer the next question", rig.mosh.writes.isEmpty())
        } finally { rig.close() }
    }

    /** Core refuses a capture under a stale fence, so the same screen under a newer one counts again. */
    @Test fun theSameScreenUnderANewerFenceIsQuestionInputAgain() = runBlocking<Unit> {
        val rig = Rig()
        try {
            fun capture(sequence: Long, text: String) = JSONObject().put("observedLifecycleSequence", sequence)
                .put("bindingToken", "token").put("promptObservation", JSONObject().put("visibleText", text))
            val counts = listOf(capture(1, "Q2"), capture(1, "Q2"), capture(2, "Q2"), capture(2, "Q3")).map {
                rig.forwardQuestionScreen("thread", it)
                rig.questionInputCount("thread")
            }
            assertEquals(listOf(1L, 1L, 2L, 3L), counts)
            rig.forwardQuestionScreen("thread", capture(3, "Q4"), sent = false)
            assertEquals("a capture Core never got is not input", 3L, rig.questionInputCount("thread"))
        } finally { rig.close() }
    }

    /** Another question, drawn whole over the cropped one. */
    private val nextQuestionScreen = "─".repeat(60) + "\n ☐ Cache\n\nWhich cache should the service use?\n\n" +
        "❯ 1. Redis\n     In memory.\n  2. Memcached\n  3. Type something.\n" + "─".repeat(60) +
        "\n  4. Chat about this\n\nEnter to select · ↑/↓ to navigate · Esc to cancel"

    /** A Claude thread waiting on a question whose dialog is cropped to its choices. */
    private suspend fun watchCroppedQuestion(rig: Rig): AgentThreadDetail {
        rig.mosh.screen = "❯ 1. Postgres\n     Mature, transactional.\n  2. SQLite\n  3. Type something.\n\nEnter to select · ↑/↓ to navigate · Esc to cancel"
        rig.onPresenter { presenter ->
            AgentCenterPresenter::class.java.getDeclaredField("applicationForeground").also {
                it.isAccessible = true
            }.setBoolean(presenter, true)
        }
        rig.frame("A", rig.mosh)
        rig.await { it.projectedDetails.containsKey(rig.mosh.threadKey("A")) }
        rig.frame("A", rig.mosh, event = "PreToolUse", reason = "question", toolUseId = "toolu_A")
        rig.await { it.projectedDetails[rig.mosh.threadKey("A")]?.row?.livePromptWatch == true }
        return rig.detail("A", rig.mosh)
    }

    /**
     * The transcript page holding the question's [call]; with [answered], the
     * earlier call and its result come first.
     */
    private suspend fun projectQuestionCall(rig: Rig, thread: AgentThreadDetail, call: String = "toolu_A", answered: String? = null) {
        val preview = """{"questions":[{"header":"Database","multiSelect":false,"options":[{"description":"Mature, transactional.","label":"Postgres"},{"label":"SQLite"}],"question":"Which database?"}]}"""
        fun ask(id: String) = JSONObject().put("type", "message").put("role", "assistant")
            .put("blocks", org.json.JSONArray().put(JSONObject().put("type", "tool_call").put("name", "AskUserQuestion")
                .put("preview", preview).put("toolCallID", id)))
        val records = listOfNotNull(
            answered?.let { ask(it) },
            answered?.let {
                JSONObject().put("type", "message").put("role", "tool").put("blocks", org.json.JSONArray()
                    .put(JSONObject().put("type", "tool_result").put("preview", "User answered.").put("toolCallID", it)))
            },
            ask(call),
        )
        val page = JSONObject().put("sourceIdentity", "source").put("cursor", "${records.size}").put("hasMore", false)
            .put("records", org.json.JSONArray(records.mapIndexed { index, record ->
                JSONObject().put("sequence", index + 1).put("recordID", "record-${index + 1}").put("record", record)
            }))
        assertEquals(CoreCallResult.Accepted, rig.onPresenter {
            val token = rig.bindingTokens().getValue(thread.binding!!.toJson().tokenKey(thread.row.key))
            rig.runtime.sendCanonical(JSONObject().put("v", 1).put("kind", "projection")
                .put("threadID", thread.row.threadIDJson()).put("bindingToken", token)
                .put("projection", page).toString().encodeToByteArray())
        })
    }

    @Test fun candidateAnswerSerializesItsPaneWithoutBlockingAnIndependentEndpoint() = runBlocking {
        val rig = Rig()
        try {
            rig.frame("A", rig.mosh); rig.frame("B", rig.ssh)
            rig.await { it.projectedDetails.size == 2 }
            val a = rig.detail("A", rig.mosh)
            val b = rig.detail("B", rig.ssh)
            rig.onPresenter { rig.candidateBindings()["candidate"] = a.binding!!.toJson() }
            assertFalse(rig.onPresenter { it.requestAction(a, "send", "hello A") })
            assertTrue(rig.onPresenter { it.requestAction(b, "send", "hello B") })
            rig.await { it.sendingThreads.isEmpty() && rig.ssh.keys.size == 1 }
            assertTrue(rig.mosh.writes.isEmpty())
            assertEquals(1, rig.ssh.writes.size)
        } finally { rig.close() }
    }

    @Test fun stalledMoshSendDoesNotBlockOrSettleAnIndependentSshSend() = runBlocking {
        val rig = Rig()
        try {
            rig.frame("A", rig.mosh); rig.frame("B", rig.ssh)
            rig.await { it.projectedDetails.size == 2 }
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            rig.mosh.inspectionGate = entered to release
            val a = rig.detail("A", rig.mosh)
            val b = rig.detail("B", rig.ssh)
            assertTrue(rig.onPresenter { it.setDraft(a.row.key, "hello A"); it.requestAction(a, "send", "hello A") })
            withTimeout(5_000) { entered.await() }
            rig.onPresenter { it.select(a.row.key) }
            assertTrue(rig.presenter.state.value.pendingActionInFlight)
            rig.onPresenter { it.select(b.row.key) }
            assertFalse(rig.presenter.state.value.pendingActionInFlight)
            // List prompt cards gate on their own thread, not on the selection.
            assertEquals(setOf(a.row.key), rig.presenter.state.value.actionThreads)
            assertTrue(rig.onPresenter { it.setDraft(b.row.key, "hello B"); it.requestAction(b, "send", "hello B") })
            rig.await { a.row.key in it.sendingThreads && b.row.key !in it.sendingThreads && rig.ssh.keys.size == 1 }
            assertEquals(1, rig.ssh.writes.size)
            assertEquals(listOf(AgentSemanticKey.RETURN), rig.ssh.keys.toList())
            assertTrue(rig.mosh.writes.isEmpty())
            rig.mosh.writeResult = AgentEndpointResult.Failed("raw_input_unavailable", inputNotAdmitted = true)
            release.complete(Unit)
            rig.await { it.sendingThreads.isEmpty() && it.drafts[a.row.key] == "hello A" }
            assertEquals("", rig.presenter.state.value.drafts[b.row.key].orEmpty())
            assertEquals(1, rig.ssh.writes.size)
            assertEquals(1, rig.ssh.keys.size)
            assertEquals(1, rig.logs.count { it.first == "agent_action_finished" && it.second["result"] == "success" })
            assertTrue(rig.logs.any { it.first == "agent_send_not_sent" && it.second["reason"] == "inputUnavailable" })
        } finally { rig.close() }
    }

    @Test fun anotherThreadsRejectedRequestLeavesTheAcceptedStalledActionPending() = runBlocking {
        val rig = Rig()
        try {
            rig.frame("A", rig.mosh); rig.frame("B", rig.ssh)
            rig.await { it.projectedDetails.size == 2 }
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            rig.mosh.inspectionGate = entered to release
            val a = rig.detail("A", rig.mosh)
            val b = rig.detail("B", rig.ssh)
            assertTrue(rig.onPresenter { it.requestAction(a, "send", "hello A") })
            withTimeout(5_000) { entered.await() }
            rig.onPresenter { rig.bindingTokens()[b.binding!!.toJson().tokenKey(b.row.key)] = UUID.randomUUID().toString() }
            assertTrue(rig.onPresenter { it.setDraft(b.row.key, "hello B"); it.requestAction(b, "send", "hello B") })
            withTimeout(5_000) { while (rig.events.none { it is SharedAgentRuntimeEvent.Failure && it.code.endsWith("@action") }) delay(10) }
            rig.await { a.row.key in it.sendingThreads && b.row.key !in it.sendingThreads }
            assertTrue(rig.mosh.writes.isEmpty())
            assertTrue(rig.ssh.writes.isEmpty())
            assertEquals("hello B", rig.presenter.state.value.drafts[b.row.key])
            release.complete(Unit)
            rig.await { it.sendingThreads.isEmpty() && rig.mosh.keys.size == 1 }
            assertEquals(1, rig.mosh.writes.size)
        } finally { rig.close() }
    }

    @Test fun unwrittenSendUsesItsOriginalLeaseAuthorityAfterRebind() = runBlocking {
        val rig = Rig()
        try {
            rig.frame("A", rig.mosh)
            rig.await { it.projectedDetails.isNotEmpty() }
            val a = rig.detail("A", rig.mosh)
            val originalToken = rig.bindingTokens()[a.binding!!.toJson().tokenKey(a.row.key)]!!
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            rig.mosh.inspectionGate = entered to release
            assertTrue(rig.onPresenter { it.setDraft(a.row.key, "hello A"); it.requestAction(a, "send", "hello A") })
            withTimeout(5_000) { entered.await() }
            val lease = rig.lease(a.row.key)
            rig.onPresenter { rig.runtime.sendCanonical(JSONObject().put("v", 1).put("kind", "unbind")
                .put("threadID", a.row.threadIDJson()).toString().encodeToByteArray()) }
            rig.await { rig.bindingTokens().values.none { token -> token == originalToken } }
            rig.await { a.row.key !in it.sendingThreads && it.drafts[a.row.key] == "hello A" }
            assertTrue(rig.acceptedNotSent(lease))
            rig.mosh.close()
            val replacement = Endpoint(AgentEndpointTransport.MOSH, rig.mosh.binding.value.hostID, generation = 2)
            rig.register(replacement)
            rig.frame("A", replacement)
            rig.await { it.projectedDetails[a.row.key]?.binding?.number("carrierGeneration") == "2" }
            val newToken = rig.bindingTokens()[rig.detail("A", replacement).binding!!.toJson().tokenKey(a.row.key)]
            assertNotNull(newToken)
            assertNotEquals(originalToken, newToken)
            release.complete(Unit)
            rig.await { a.row.key !in it.sendingThreads && it.drafts[a.row.key] == "hello A" }
            assertTrue(rig.mosh.writes.isEmpty())
            assertTrue(replacement.writes.isEmpty())
            assertEquals(newToken, rig.bindingTokens()[rig.detail("A", replacement).binding!!.toJson().tokenKey(a.row.key)])
            assertEquals(1, rig.logs.count { it.first == "agent_send_not_sent_settled" && it.second["settlement"] == "return_draft" })
        } finally { rig.close() }
    }

    @Test fun retirementBeforeActionDispatchStillSettlesTheOriginalLease() = runBlocking {
        val rig = Rig()
        try {
            rig.frame("A", rig.mosh)
            rig.await { it.projectedDetails.isNotEmpty() }
            val a = rig.detail("A", rig.mosh)
            rig.retireBeforeActionStart = true
            assertTrue(rig.onPresenter { it.setDraft(a.row.key, "hello A"); it.requestAction(a, "send", "hello A") })
            rig.await { a.row.key !in it.sendingThreads && it.drafts[a.row.key] == "hello A" }
            assertTrue(rig.acceptedNotSent(rig.lease(a.row.key)))
            assertTrue(rig.logs.none { it.first == "agent_action_plan" })
            assertTrue(rig.mosh.writes.isEmpty())
            assertTrue(rig.mosh.keys.isEmpty())
        } finally { rig.close() }
    }

    @Test fun conversationReplacementCancelsAnUnwrittenActionOnTheSamePane() = runBlocking {
        for (kind in listOf("send", "queue")) {
            val rig = Rig(AgentEndpointTransport.MOSH_TMUX)
            try {
                rig.frame("A", rig.mosh)
                rig.await { it.projectedDetails.isNotEmpty() }
                val a = rig.detail("A", rig.mosh)
                val originalToken = rig.bindingTokens()[a.binding!!.toJson().tokenKey(a.row.key)]!!
                val entered = CompletableDeferred<Unit>()
                val release = CompletableDeferred<Unit>()
                rig.mosh.inspectionGate = entered to release
                assertTrue(rig.onPresenter { it.setDraft(a.row.key, "hello A"); it.requestAction(a, kind, "hello A") })
                withTimeout(5_000) { entered.await() }
                val lease = rig.lease(a.row.key)
                rig.frame("B", rig.mosh)
                rig.await { a.row.key !in it.sendingThreads && it.drafts[a.row.key] == "hello A" &&
                    it.projectedDetails.containsKey(rig.mosh.threadKey("B")) }
                val b = rig.detail("B", rig.mosh)
                val successorToken = rig.bindingTokens()[b.binding!!.toJson().tokenKey(b.row.key)]
                assertNotNull(successorToken)
                assertNotEquals(originalToken, successorToken)
                assertFalse(rig.bindingTokens().containsValue(originalToken))
                rig.awaitNotSent(lease, originalToken)
                assertFalse(rig.presenter.state.value.projectedDetails.containsKey(a.row.key))
                assertTrue(rig.logs.any { it.first == "agent_send_not_sent_settled" && it.second["reason"] == "routeChanged" &&
                    it.second["settlement"] == "return_draft" })
                release.complete(Unit)
                assertTrue(rig.mosh.writes.isEmpty())
                assertTrue(rig.mosh.keys.isEmpty())
            } finally { rig.close() }
        }
    }

    @Test fun acceptedEndCancelsAnUnwrittenSendThroughItsOriginalLease() = runBlocking {
        for (event in listOf("SessionEnd", "WrapperExit")) {
            val rig = Rig(AgentEndpointTransport.MOSH_TMUX)
            try {
                rig.frame("A", rig.mosh)
                rig.await { it.projectedDetails.isNotEmpty() }
                val a = rig.detail("A", rig.mosh)
                val originalToken = rig.bindingTokens()[a.binding!!.toJson().tokenKey(a.row.key)]!!
                val entered = CompletableDeferred<Unit>()
                val release = CompletableDeferred<Unit>()
                rig.mosh.inspectionGate = entered to release
                assertTrue(rig.onPresenter { it.setDraft(a.row.key, "hello A"); it.requestAction(a, "send", "hello A") })
                withTimeout(5_000) { entered.await() }
                val lease = rig.lease(a.row.key)
                rig.frame("A", rig.mosh, event = event)
                rig.await { a.row.key !in it.sendingThreads && it.drafts[a.row.key] == "hello A" }
                assertTrue(rig.acceptedNotSent(lease))
                assertEquals(originalToken, rig.bindingTokens()[requireNotNull(a.binding).toJson().tokenKey(a.row.key)])
                assertTrue(rig.logs.any { it.first == "agent_send_not_sent" && it.second["reason"] == "routeChanged" })
                release.complete(Unit)
                assertTrue(rig.mosh.writes.isEmpty())
                assertTrue(rig.mosh.keys.isEmpty())
            } finally { rig.close() }
        }
    }

    @Test fun acceptedEndAfterInsertionRefusesTheSubmitKeyAndKeepsTheSendAmbiguous() = runBlocking {
        val rig = Rig()
        try {
            rig.frame("A", rig.mosh)
            rig.await { it.projectedDetails.isNotEmpty() }
            val a = rig.detail("A", rig.mosh)
            val entered = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            rig.mosh.submitInspectionGate = entered to release
            assertTrue(rig.onPresenter { it.setDraft(a.row.key, "hello A"); it.requestAction(a, "send", "hello A") })
            withTimeout(5_000) { entered.await() }
            assertEquals(1, rig.mosh.writes.size)
            val lease = rig.lease(a.row.key)
            rig.frame("A", rig.mosh, event = "SessionEnd")
            rig.await { rig.ended(a.row.key) }
            release.complete(Unit)
            rig.await { a.row.key !in it.sendingThreads && rig.logs.any { log ->
                log.first == "agent_action_finished" && log.second["result"] == "staleBinding" } }
            assertTrue(rig.mosh.keys.isEmpty())
            assertEquals("", rig.presenter.state.value.drafts[a.row.key].orEmpty())
            assertFalse(rig.acceptedNotSent(lease))
            assertTrue(rig.logs.none { it.first == "agent_send_not_sent" })
        } finally { rig.close() }
    }

    @Test fun backgroundActionProofIsNotSentWhileLifecycleAndBindingProofsKeepTheOwner() = runBlocking {
        val rig = Rig()
        try {
            rig.frame("A", rig.mosh)
            rig.await { it.projectedDetails.isNotEmpty() }
            val a = rig.detail("A", rig.mosh)
            assertTrue(rig.mosh.proofs.isNotEmpty())
            assertTrue(rig.mosh.proofs.none { it })
            rig.mosh.background = true
            assertTrue(rig.onPresenter { it.setDraft(a.row.key, "hello A"); it.requestAction(a, "send", "hello A") })
            rig.await { a.row.key !in it.sendingThreads && it.drafts[a.row.key] == "hello A" }
            assertTrue(rig.acceptedNotSent(rig.lease(a.row.key)))
            assertEquals(1, rig.mosh.proofs.count { it })
            assertTrue(rig.mosh.proofs.count { !it } >= 2)
            assertTrue(rig.presenter.state.value.projectedDetails.containsKey(a.row.key))
            assertTrue(rig.logs.any { it.first == "agent_send_not_sent" && it.second["reason"] == "routeChanged" })
            assertTrue(rig.mosh.writes.isEmpty())
            assertTrue(rig.mosh.keys.isEmpty())
        } finally { rig.close() }
    }

    @Test fun rootAndChildSharingOneBindingEachReceiveTheirOwnActionPlan() = runBlocking {
        for (lastFrame in listOf("root", "child")) {
            val rig = Rig(AgentEndpointTransport.MOSH_TMUX)
            try {
                rig.frame("root", rig.mosh, provider = "codex")
                rig.frame("child", rig.mosh, provider = "codex", child = "worker", root = "root")
                if (lastFrame == "root") rig.frame("root", rig.mosh, provider = "codex")
                rig.await { it.projectedDetails.size == 2 }
                val root = rig.detail("root", rig.mosh, "codex")
                val child = rig.detail("child", rig.mosh, "codex")
                val rootBinding = requireNotNull(root.binding).toJson()
                val childBinding = requireNotNull(child.binding).toJson()
                assertTrue(rootBinding.sameCoreBinding(childBinding))
                val rootToken = rig.bindingTokens()[rootBinding.tokenKey(root.row.key)]
                val childToken = rig.bindingTokens()[childBinding.tokenKey(child.row.key)]
                assertNotNull(rootToken); assertNotNull(childToken); assertNotEquals(rootToken, childToken)
                rig.mosh.background = true
                for (detail in listOf(root, child)) {
                    val text = "hello ${detail.row.key}"
                    assertTrue(rig.onPresenter { it.setDraft(detail.row.key, text); it.requestAction(detail, "send", text) })
                    rig.await { detail.row.key !in it.sendingThreads && it.drafts[detail.row.key] == text }
                    assertTrue(rig.acceptedNotSent(rig.lease(detail.row.key)))
                }
                assertTrue(rig.events.none { it is SharedAgentRuntimeEvent.Failure && it.code.endsWith("@action") })
                assertTrue(rig.mosh.writes.isEmpty())
                assertTrue(rig.mosh.keys.isEmpty())
            } finally { rig.close() }
        }
    }

    private class Rig(transport: AgentEndpointTransport = AgentEndpointTransport.MOSH) {
        private val dispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
        private val scope = CoroutineScope(SupervisorJob() + dispatcher)
        private val registry = LiveAgentSessionRegistry()
        private val coordinator = AndroidAgentSessionCoordinator(registry)
        private val integration = AgentSessionIntegrationCoordinator(coordinator.directory, scope, coordinator)
        val mosh = Endpoint(transport)
        val ssh = Endpoint(AgentEndpointTransport.SSH)
        private val endpoints = mutableListOf(mosh, ssh)
        private val registrations = mutableListOf(registry.register(mosh), registry.register(ssh))
        val logs = CopyOnWriteArrayList<Pair<String, Map<String, String>>>()
        val events = CopyOnWriteArrayList<SharedAgentRuntimeEvent>()
        val presenter = AgentCenterPresenter(coordinator, metadata(), unusedPreferences(), scope, integration,
            diagnostics = { event, fields -> logs.add(event to fields) })
        val runtime = coordinator.runtime()
        @Volatile var retireBeforeActionStart = false
        /** Runs once, before the presenter sees Core's next "promptCurrent" reply. */
        @Volatile var beforePromptCurrent: (suspend () -> Unit)? = null
        init {
            field("runtime").set(presenter, runtime)
            field("enabled").setBoolean(presenter, true)
            // Display watchers must not consume the action's inspection gate.
            field("applicationForeground").setBoolean(presenter, false)
            scope.launch { runtime.events.collect { event ->
                events.add(event)
                if (event is SharedAgentRuntimeEvent.Snapshot && event.snapshot.payload.string("code") == "promptCurrent") {
                    beforePromptCurrent?.let { beforePromptCurrent = null; it() }
                }
                presenter.consume(event)
                if (retireBeforeActionStart && event is SharedAgentRuntimeEvent.Snapshot &&
                    event.snapshot.kind == SharedAgentSnapshotKind.ActionPlan) {
                    retireBeforeActionStart = false
                    val lease = event.snapshot.payload.obj("lease")!!
                    val key = checkNotNull(agentLeaseThreadKey(lease.toJson()))
                    val token = bindingTokens().getValue(lease.obj("binding")!!.toJson().tokenKey(key))
                    check(runtime.sendCanonical(JSONObject().put("v", 1).put("kind", "unbind")
                        .put("threadID", lease.obj("threadID")!!.toJson()).put("bindingToken", token).toString().encodeToByteArray()) == CoreCallResult.Accepted)
                    // Deliver retirement in this collector turn, before the action job dispatches.
                    presenter.consume(SharedAgentRuntimeEvent.RoutesRetired(event.runtimeGeneration,
                        listOf(SharedAgentRouteRetirement(lease.obj("threadID")!!, token, null, "unbound"))))
                }
            } }
        }
        fun register(endpoint: Endpoint) { endpoints.add(endpoint); registrations.add(registry.register(endpoint)) }
        suspend fun frame(session: String, endpoint: Endpoint, event: String = "SessionStart", provider: String = "claude",
            child: String? = null, root: String? = null, reason: String? = null,
            timestampNs: Long = System.nanoTime(), toolUseId: String? = null) = withContext(dispatcher) {
            val transcript = Base64.getUrlEncoder().withoutPadding().encodeToString("/fixture/$session".encodeToByteArray())
            presenter.consumeLifecycle(endpoint, AgentLifecycleFrame(endpoint.binding.value, JSONObject()
                .put("version", 9).put("provider", provider).put("event", event)
                .put("state", when (event) {
                    "SessionEnd", "WrapperExit" -> "unavailable"
                    "PreToolUse", "PostToolUse" -> "working"
                    else -> "idle"
                })
                .putOpt("reason", reason)
                .put("timestampNs", "$timestampNs").put("sessionId", session).put("agentPid", 42)
                .putOpt("agentId", child).putOpt("rootAgentId", root).putOpt("toolUseId", toolUseId)
                .put("transcriptRef", transcript).toString().encodeToByteArray()))
        }
        fun detail(session: String, endpoint: Endpoint, provider: String = "claude") = presenter.state.value.projectedDetails.getValue(endpoint.threadKey(session, provider))
        fun lease(threadKey: String): JSONObject = events.filterIsInstance<SharedAgentRuntimeEvent.Snapshot>().last {
            it.snapshot.kind == SharedAgentSnapshotKind.ActionPlan && it.snapshot.payload.obj("lease")?.toJson()?.let(::agentLeaseThreadKey) == threadKey
        }.snapshot.payload.obj("lease")!!.toJson()
        fun acceptedNotSent(lease: JSONObject, bindingToken: String? = null): Boolean {
            val key = agentLeaseThreadKey(lease)
            val removed = bindingToken != null && events.any { event ->
                event is SharedAgentRuntimeEvent.RoutesRetired && event.retirements.any { retirement ->
                    retirement.bindingToken == bindingToken && retirement.reason == "replaced" &&
                        agentLeaseThreadKey(JSONObject().put("threadID", retirement.threadID.toJson())) == key &&
                        retirement.successor?.toJson()?.let { agentLeaseThreadKey(JSONObject().put("threadID", it)) }?.let { it != key } == true
                }
            }
            return events.any { event ->
                event is SharedAgentRuntimeEvent.Snapshot && event.snapshot.payload.string("code") == "notSent" &&
                    (AgentPresentation.detail(event.snapshot)?.let { it.row.key == key &&
                        it.outgoingMessages.none { message -> message.id.equals(lease.getString("token"), ignoreCase = true) } } == true ||
                        removed && event.snapshot.payload.obj("thread") == null)
            }
        }
        suspend fun awaitNotSent(lease: JSONObject, bindingToken: String) = withTimeout(5_000) {
            while (!acceptedNotSent(lease, bindingToken)) delay(10)
        }
        fun ended(threadKey: String) = events.any { event ->
            event is SharedAgentRuntimeEvent.Snapshot && event.snapshot.payload.obj("thread")?.bool("conversationEnded") == true &&
                AgentPresentation.detail(event.snapshot)?.row?.key == threadKey
        }
        suspend fun <T> onPresenter(action: (AgentCenterPresenter) -> T): T = withContext(dispatcher) { action(presenter) }
        // Predicates may read presenter fields, logs or events that change
        // without a state emission; re-check them on a tick as well.
        suspend fun await(predicate: (AgentCenterUiState) -> Boolean): AgentCenterUiState =
            withTimeoutOrNull(8_000) {
                merge(presenter.state, flow { while (true) { delay(10); emit(presenter.state.value) } }).first(predicate)
            }
                ?: throw AssertionError("timed out; pending=${presenter.state.value.sendingThreads} logs=${logs.takeLast(20)}")
        @Suppress("UNCHECKED_CAST") fun bindingTokens() = field("bindingTokens").get(presenter) as MutableMap<String, String>
        fun forwardQuestionScreen(threadKey: String, observation: JSONObject, sent: Boolean = true) = AgentCenterPresenter::class.java
            .getDeclaredMethod("forwardQuestionScreen", String::class.java, JSONObject::class.java, Function0::class.java)
            .also { it.isAccessible = true }.invoke(presenter, threadKey, observation, { sent }) as Boolean
        @Suppress("UNCHECKED_CAST") fun promptLifecycleNanos() = field("latestPromptLifecycleNanos").get(presenter) as MutableMap<String, Long>
        fun questionInputCount(threadKey: String) = AgentCenterPresenter::class.java
            .getDeclaredMethod("questionInputCount", String::class.java).also { it.isAccessible = true }
            .invoke(presenter, threadKey) as Long
        @Suppress("UNCHECKED_CAST") fun candidateBindings() = field("candidateActionsInFlight").get(presenter) as MutableMap<String, JSONObject>
        suspend fun close() {
            withContext(NonCancellable + dispatcher) { presenter.close(); integration.close(); coordinator.close() }
            registrations.forEach { it.close() }; endpoints.forEach { it.close() }; scope.cancel(); dispatcher.close()
        }
        private fun field(name: String) = AgentCenterPresenter::class.java.getDeclaredField(name).also { it.isAccessible = true }
    }

    private class Endpoint(transport: AgentEndpointTransport, host: String = UUID.randomUUID().toString(), generation: Long = 1) : AgentSessionEndpoint {
        override val key = AgentSessionKey(UUID.randomUUID().toString(), generation)
        private val tmux = transport.name.endsWith("TMUX")
        override val binding = MutableStateFlow(AgentEndpointBinding(key, host, transport,
            tmuxSession = if (tmux) "fixture" else null, windowID = if (tmux) "@1" else null, paneID = if (tmux) "%75" else null))
        override val capabilities = MutableStateFlow(AgentEndpointCapabilities(lifecycleFeed = true, freshTerminalObservation = true,
            remoteData = true, verifiedInput = true, semanticKeys = true, guardedFocus = true))
        override val lifecycleFrames = MutableSharedFlow<AgentLifecycleFrame>()
        @Volatile private var closed = false
        @Volatile var inspectionGate: Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
        @Volatile var submitInspectionGate: Pair<CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
        @Volatile var background = false
        @Volatile var screen: String? = null
        val inspections = java.util.concurrent.atomic.AtomicInteger()
        @Volatile var writeResult: AgentEndpointResult<Unit> = AgentEndpointResult.Success(Unit)
        val writes = CopyOnWriteArrayList<ByteArray>()
        val keys = CopyOnWriteArrayList<AgentSemanticKey>()
        val proofs = CopyOnWriteArrayList<Boolean>()
        /** Holds the foreground proof with this ordinal among [proofs] until released. */
        @Volatile var proofGate: Triple<Int, CompletableDeferred<Unit>, CompletableDeferred<Unit>>? = null
        private var draft = ""
        fun threadKey(session: String, provider: String = "claude") = canonicalAgentThreadKey(binding.value.hostID, provider, session)
        override fun isCurrentRoute(candidate: AgentEndpointBinding) = !closed && candidate.sameRouteAs(binding.value)
        override suspend fun proveProcess(binding: AgentEndpointBinding, claimedPID: Int, provider: AgentProofProvider, requireForeground: Boolean): AgentEndpointResult<AgentProcessProof> {
            proofs.add(requireForeground)
            proofGate?.takeIf { requireForeground && it.first == proofs.count { foreground -> foreground } }?.let { (_, entered, release) ->
                proofGate = null; entered.complete(Unit); release.await()
            }
            return when {
                !isCurrentRoute(binding) -> AgentEndpointResult.StaleBinding
                requireForeground && background -> AgentEndpointResult.Failed("proof_exit_1", proofReason = "backgroundProcess")
                else -> AgentEndpointResult.Success(AgentProcessProof(setOf(claimedPID), provider, "fixture-$claimedPID"))
            }
        }
        override suspend fun inspect(binding: AgentEndpointBinding): AgentEndpointResult<AgentTerminalObservation> {
            inspections.incrementAndGet()
            inspectionGate?.let { (entered, release) -> inspectionGate = null; entered.complete(Unit); release.await() }
            if (!isCurrentRoute(binding)) return AgentEndpointResult.StaleBinding
            screen?.let {
                return AgentEndpointResult.Success(AgentTerminalObservation(binding, it.encodeToByteArray(), false, true,
                    cursorVisible = false))
            }
            val line = "❯ $draft"
            return AgentEndpointResult.Success(AgentTerminalObservation(binding, "$line\n────\nctx:25%".encodeToByteArray(), false, true,
                currentCursorLine = line, cursorRow = 0, cursorColumn = 2 + draft.length, cursorVisible = true))
        }
        override suspend fun sendInput(binding: AgentEndpointBinding, bytes: ByteArray): AgentEndpointResult<Unit> {
            if (!isCurrentRoute(binding)) return AgentEndpointResult.Failed("staleBinding", inputNotAdmitted = true)
            if (writeResult !is AgentEndpointResult.Success) return writeResult
            writes.add(bytes.copyOf())
            draft = bytes.decodeToString().removePrefix("\u001b[200~").removeSuffix("\u001b[201~")
            submitInspectionGate?.let { inspectionGate = it; submitInspectionGate = null }
            return AgentEndpointResult.Success(Unit)
        }
        override suspend fun sendSemanticKey(binding: AgentEndpointBinding, key: AgentSemanticKey): AgentEndpointResult<Unit> {
            if (!isCurrentRoute(binding)) return AgentEndpointResult.StaleBinding
            keys.add(key)
            return AgentEndpointResult.Success(Unit)
        }
        private fun unavailable() = AgentEndpointResult.Unavailable("host-free action fixture")
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
