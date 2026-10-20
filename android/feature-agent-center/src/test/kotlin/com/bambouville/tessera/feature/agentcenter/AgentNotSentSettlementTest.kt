package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentTerminalObservation
import com.bambouville.tessera.core.bridge.SharedAgentValue
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentNotSentSettlementTest {
    private val token = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

    private fun pending(
        text: String? = "hello Claude",
        draftCleared: Boolean = true,
        legacyCode: String = "staleBinding",
        threadKey: String = "thread",
    ) = AgentPendingNotSent(threadKey, token, "send", text, AgentNotSentReason.INPUT_NOT_READY, "Claude", legacyCode, draftCleared)

    // A queued notSent is not an accepted one: the draft returns only once a
    // snapshot shows the bubble withdrawn.
    @Test fun theDraftWaitsForCoreToWithdrawTheBubble() {
        val other = "11111111-2222-3333-4444-555555555555"
        val snapshot = AgentNotSentEvidence.SNAPSHOT
        val accepted = AgentNotSentEvidence.ACCEPTED
        val applied = AgentNotSentEvidence.APPLIED
        fun settle(ids: List<String>, hidden: Boolean, evidence: AgentNotSentEvidence) =
            agentNotSentSettlement(token, ids, outgoingHidden = hidden, evidence = evidence)
        // A snapshot from before Core processed the result still shows it.
        assertEquals(AgentNotSentSettlement.WAIT, settle(listOf(other, token), hidden = false, snapshot))
        // Withdrawn: the lease token no longer names a bubble.
        for (evidence in AgentNotSentEvidence.entries) {
            assertEquals(AgentNotSentSettlement.RETURN_DRAFT, settle(listOf(other), hidden = false, evidence))
            assertEquals(AgentNotSentSettlement.RETURN_DRAFT, settle(emptyList(), hidden = false, evidence))
        }
        // Processed, yet the bubble survives: ambiguous.
        assertEquals(AgentNotSentSettlement.AMBIGUOUS, settle(listOf(token), hidden = false, accepted))
        assertEquals(AgentNotSentSettlement.AMBIGUOUS, settle(listOf(token), hidden = false, applied))
        // Swift and Java spell UUIDs in different cases.
        assertEquals(AgentNotSentSettlement.AMBIGUOUS, settle(listOf(token.lowercase()), hidden = false, accepted))
        assertEquals(AgentNotSentSettlement.WAIT, settle(listOf(token.lowercase()), hidden = false, snapshot))
        // A window off the live head that still retains outgoing messages
        // lists none of them. Core's acceptance always withdraws the bubble.
        assertEquals(AgentNotSentSettlement.WAIT, settle(emptyList(), hidden = true, snapshot))
        assertEquals(AgentNotSentSettlement.RETURN_DRAFT, settle(emptyList(), hidden = true, accepted))
        assertEquals("notSent evidence", AgentNotSentEvidence.ACCEPTED, agentNotSentEvidence("notSent"))
        for (code in listOf(null, "applied", "outgoingArmed", "verified", "failed")) {
            assertEquals(AgentNotSentEvidence.SNAPSHOT, agentNotSentEvidence(code))
        }
    }

    // An ActionPlan proves Core processed the result, not that it accepted
    // it: with the bubble hidden, the result may have been rejected.
    @Test fun aLaterActionPlanIsNotAcceptance() {
        assertEquals(AgentNotSentSettlement.AMBIGUOUS_WATCH, agentNotSentSettlement(token, emptyList(), outgoingHidden = true,
            evidence = AgentNotSentEvidence.APPLIED))
        // A rebind whose snapshot is off the live head proves nothing yet:
        // Core still withdraws the issued lease's bubble.
        val ledger = AgentNotSentLedger()
        val a = wait()
        ledger.register(a)
        val rebound = JSONObject(leaseBinding.toString()).put("carrierGeneration", 4)
        val hidden = AgentHistoryWindow(1, atLiveHead = false, hasNewer = true, after = null, transition = "older", retainsOutgoing = true)
        assertNull(ledger.settle(snapshot(binding = rebound, window = hidden), AgentNotSentEvidence.SNAPSHOT))
        assertTrue(ledger.isWaiting(a))
        // B's hidden ActionPlan under the same binding: ambiguous, watched.
        assertEquals(AgentNotSentSettlement.AMBIGUOUS_WATCH,
            ledger.settleByActionPlan(snapshot(window = hidden), acceptedText = "a different message")?.second)
        assertTrue(ledger.isWatchingLate(a))
        // ...and under the rebound binding: the same.
        val third = wait()
        ledger.register(third)
        assertEquals(AgentNotSentSettlement.AMBIGUOUS_WATCH,
            ledger.settleByActionPlan(snapshot(binding = rebound, window = hidden), acceptedText = "a different message")?.second)
        // An ActionPlan that lists no bubble at the live head returns it.
        val fourth = wait()
        ledger.register(fourth)
        assertEquals(AgentNotSentSettlement.RETURN_DRAFT, ledger.settleByActionPlan(snapshot(), acceptedText = null)?.second)
    }

    // The user resent exactly the unsent text while its verdict was delayed:
    // returning it too (or "Not sent") while the resend is written invites a
    // real duplicate.
    @Test fun anIdenticalResendIsNeitherReturnedNorAnnounced() {
        val ledger = AgentNotSentLedger()
        val a = wait()
        ledger.register(a)
        val verdict = ledger.settleByActionPlan(snapshot(outgoing = listOf("resend-token")), acceptedText = "hello Claude")
        assertSame(a, verdict?.first)
        assertEquals(AgentNotSentSettlement.RESENT, verdict?.second)
        assertFalse(ledger.isWaiting(a))
        assertFalse(ledger.isWatchingLate(a))
        val state = AgentCenterUiState(drafts = mapOf("thread" to ""), notice = null)
        assertSame(state, state.withSettledNotSent(a.pending, AgentNotSentSettlement.RESENT))
        // Even a bubble that survived: the resend is what the user meant.
        val kept = wait()
        ledger.register(kept)
        assertEquals(AgentNotSentSettlement.RESENT,
            ledger.settleByActionPlan(snapshot(outgoing = listOf(token)), acceptedText = "hello Claude")?.second)
        // Different text, or no text (an interrupt): the normal rule.
        val other = wait()
        ledger.register(other)
        assertEquals(AgentNotSentSettlement.RETURN_DRAFT,
            ledger.settleByActionPlan(snapshot(), acceptedText = "hello Claude, again")?.second)
        assertEquals(AgentNotSentSettlement.RETURN_DRAFT,
            agentNotSentActionPlanSettlement(pending(text = null), snapshot(), acceptedText = null))
    }

    // The fallback's ambiguous verdict is not final: Core's withdrawal may
    // only have been dropped. A later snapshot showing the bubble gone still
    // returns the message (nothing was written), until the next send or the cap.
    @Test fun aLateWithdrawalStillReturnsTheMessage() {
        val hidden = AgentHistoryWindow(1, atLiveHead = false, hasNewer = true, after = null, transition = "older", retainsOutgoing = true)
        val ledger = AgentNotSentLedger()
        fun settledByFallback(): AgentNotSentWait {
            val queued = wait()
            ledger.register(queued)
            while (ledger.advance(queued, 100, probeAllowed = true) != AgentNotSentFallbackStep.SETTLE) Unit
            assertEquals(AgentNotSentSettlement.AMBIGUOUS_WATCH, ledger.settleByFallback(queued, snapshot(outgoing = listOf(token))))
            assertTrue(ledger.isWatchingLate(queued))
            return queued
        }
        val late = settledByFallback()
        // Still listed, or hidden, or another thread: nothing yet.
        assertNull(ledger.settleLate(snapshot(outgoing = listOf(token))))
        assertNull(ledger.settleLate(snapshot(window = hidden)))
        assertNull(ledger.settleLate(snapshot(threadKey = "other")))
        assertSame(late, ledger.settleLate(snapshot(outgoing = listOf("other"))))
        val returned = AgentCenterUiState(drafts = mapOf("thread" to "typed since"))
            .withSettledNotSent(late.pending, AgentNotSentSettlement.RETURN_DRAFT)
        assertEquals("hello Claude\n\ntyped since", returned.drafts["thread"])
        assertEquals("Not sent — Claude's input wasn't ready. Nothing was typed; your message is back in the box above what you typed since.",
            returned.notice)
        assertFalse("returned once", ledger.isWatchingLate(late))
        assertNull(ledger.settleLate(snapshot()))

        // The thread's next send ends the watch.
        val superseded = settledByFallback()
        assertNull(ledger.settleByActionPlan(snapshot(outgoing = listOf("next")), acceptedText = "next"))
        assertFalse(ledger.isWatchingLate(superseded))
        assertNull(ledger.settleLate(snapshot()))
        // So does the cap, and clearing (deactivate).
        val expired = settledByFallback()
        assertTrue(ledger.expireLate(expired))
        assertFalse(ledger.expireLate(expired))
        assertNull(ledger.settleLate(snapshot()))
        val cleared = settledByFallback()
        ledger.clear()
        assertFalse(ledger.isWatchingLate(cleared))
        assertNull(ledger.settleLate(snapshot()))
        assertEquals(60_000L, AgentNotSentFallbackPolicy().lateWatchMillis)

        // A watch left by the next send's hidden ActionPlan, and that send's
        // own queued notSent: one snapshot showing both bubbles gone returns
        // both, each independently.
        val a = wait()
        ledger.register(a)
        assertEquals(AgentNotSentSettlement.AMBIGUOUS_WATCH, ledger.settleByActionPlan(snapshot(window = hidden), "B")?.second)
        val b = AgentNotSentWait(pending(text = "B").copy(leaseToken = "B-TOKEN"), "runtime",
            JSONObject(lease.toString()).put("token", "B-TOKEN"))
        ledger.register(b)
        assertNull(ledger.settleLate(snapshot(outgoing = listOf(token, "B-TOKEN"))))
        assertNull(ledger.settle(snapshot(outgoing = listOf(token, "B-TOKEN")), AgentNotSentEvidence.SNAPSHOT))
        val bothGone = snapshot(outgoing = listOf("unrelated"))
        assertSame(a, ledger.settleLate(bothGone))
        val verdict = ledger.settle(bothGone, AgentNotSentEvidence.ACCEPTED)
        assertSame(b, verdict?.first)
        assertEquals(AgentNotSentSettlement.RETURN_DRAFT, verdict?.second)
    }

    // Core's action errors carry the refused command (actionInFlight@action).
    // They read as words, and a refused `action` ends the pending actions,
    // which reopens the probe gate for a queued notSent on that thread.
    @Test fun coreActionErrorsReadAsWordsAndEndPendingActions() {
        assertEquals("Another action is still running on this thread; try again in a moment", agentRejectionNotice("actionInFlight@action"))
        assertEquals("Another action is still running on this thread; try again in a moment", agentRejectionNotice("actionInFlight"))
        assertEquals("This terminal can't take actions right now", agentRejectionNotice("unavailable@action"))
        assertEquals("The agent's input wasn't ready; nothing was typed", agentRejectionNotice("inputNotReady@action"))
        assertEquals("Terminal binding is stale; reopen the terminal before retrying", agentRejectionNotice("staleBinding@outgoingDispatched"))
        assertEquals("Terminal verification failed; review the terminal before retrying", agentRejectionNotice("verificationFailed@action"))
        assertEquals("abi invalidField@result", agentRejectionNotice("abi_invalidField@result"))
        assertEquals("projection transcriptUnavailable", agentRejectionNotice("projection_transcriptUnavailable"))
        assertEquals("abi event too large", agentRejectionNotice("abi_event_too_large"))

        // Background work whose token rotated while it was queued is routine.
        for (code in listOf("projection_staleBinding", "bind_staleBinding", "lifecycle_staleBinding",
                "terminalVisible_staleBinding", "livePromptObservation_staleBinding")) {
            assertNull(code, agentRejectionReaction(code))
        }
        assertEquals("abi invalidField@bind", agentRejectionReaction("abi_invalidField@bind")!!.notice)
        for (code in listOf("actionInFlight@action", "staleBinding@action", "unavailable@action", "abi_invalidField@action")) {
            val reaction = agentRejectionReaction(code)!!
            assertTrue(code, reaction.endsPendingActions)
            assertFalse(code, reaction.mayHideNotSent)
        }
        for (code in listOf("staleBinding@outgoingDispatched", "staleBinding@armOutgoing", "actionInFlight", "abi_invalidField@select")) {
            assertFalse(code, agentRejectionReaction(code)!!.endsPendingActions)
        }
        assertTrue(agentRejectionReaction("abi_invalidField@result")!!.mayHideNotSent)
        assertFalse(agentRejectionReaction("abi_invalidField@result")!!.endsPendingActions)

        // The gate: no probe while this thread's action is queued.
        assertFalse(agentNotSentProbeAllowed("thread", setOf("thread")))
        assertTrue(agentNotSentProbeAllowed("thread", setOf("other")))
        assertTrue(agentNotSentProbeAllowed("thread", emptySet()))

        // A wait past its probe time, blocked by this thread's pending
        // action, probes as soon as the refused action clears it.
        val ledger = AgentNotSentLedger()
        val queued = wait()
        ledger.register(queued)
        val pendingActions = mutableSetOf("thread")
        repeat(25) { assertEquals(AgentNotSentFallbackStep.WAIT, ledger.advance(queued, 100, agentNotSentProbeAllowed("thread", pendingActions))) }
        assertTrue(ledger.noteRejection("abi_invalidField@select").isEmpty())
        val reaction = agentRejectionReaction("actionInFlight@action")!!
        if (reaction.endsPendingActions) pendingActions.clear()
        val reevaluated = ledger.noteRejection("actionInFlight@action")
        assertEquals(listOf(queued), reevaluated)
        assertFalse("not a verdict, so no early probe request", queued.probeRequested)
        assertEquals(AgentNotSentFallbackStep.PROBE, ledger.advance(queued, 0, agentNotSentProbeAllowed("thread", pendingActions)))
    }

    private val leaseBinding = JSONObject().put("liveSessionID", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE").put("carrierGeneration", 3)
        .put("transport", "sshTmux").put("tmuxSession", "s").put("windowID", "@1").put("paneID", "%1").put("agentPID", 42)
        .put("capabilities", 7)
    private val lease = JSONObject().put("action", "send").put("token", token).put("binding", leaseBinding)

    private fun JSONObject.asShared(): SharedAgentValue.ObjectValue = SharedAgentValue.ObjectValue(keys().asSequence().associateWith { key ->
        when (val value = get(key)) {
            is Number -> SharedAgentValue.NumberValue(value.toString())
            else -> SharedAgentValue.StringValue(value.toString())
        }
    })

    /** A thread snapshot as Core sends it: listed bubbles, its binding, its window. */
    private fun snapshot(
        outgoing: List<String> = emptyList(),
        binding: JSONObject? = leaseBinding,
        window: AgentHistoryWindow? = null,
        threadKey: String = "thread",
    ) = AgentThreadDetail(
        AgentThreadRow(key = threadKey, title = "t", provider = "Claude", model = null, preview = null, status = "idle",
            attention = "none", location = "", queuedCount = null, isFork = false, actionAvailable = true,
            spawnAvailable = false, forkAvailable = false),
        live = emptyList(), activity = emptyList(), changes = emptyList(), binding = binding?.asShared(), hasMore = false,
        outgoingMessages = outgoing.map { AgentOutgoingMessage(it, "hello Claude", "sending") }, window = window,
    )

    private fun wait(threadKey: String = "thread", owner: Any = "runtime") =
        AgentNotSentWait(pending(threadKey = threadKey), owner, JSONObject(lease.toString()))

    // A rejection names no command: a launch receipt is a `result` too. It
    // settles nothing; a listed bubble while the lease's binding is current
    // may simply predate the result, so only the bubble's fate decides.
    @Test fun aRejectionNeverSettlesAQueuedNotSent() {
        assertTrue(agentRejectionMayHideNotSent("abi_invalidField@result"))
        assertTrue(agentRejectionMayHideNotSent("abi_missingField@result"))
        assertTrue(agentRejectionMayHideNotSent("abi_event_too_large"))
        assertFalse(agentRejectionMayHideNotSent("abi_invalidField@action"))
        assertFalse(agentRejectionMayHideNotSent("abi_invalidField"))
        assertFalse(agentRejectionMayHideNotSent("projection_staleBinding"))
        assertFalse(agentRejectionMayHideNotSent("abi_invalidField@resultOutcome"))

        val ledger = AgentNotSentLedger()
        val queued = wait()
        ledger.register(queued)
        assertEquals(listOf(queued), ledger.noteRejection("abi_invalidField@result"))
        assertTrue(queued.probeRequested)
        assertTrue(ledger.isWaiting(queued))
        assertTrue(ledger.noteRejection("projection_transcriptUnavailable").isEmpty())
        // A snapshot from before Core processed the result still lists the bubble.
        assertNull(ledger.settle(snapshot(outgoing = listOf(token)), AgentNotSentEvidence.SNAPSHOT))
        assertTrue(ledger.isWaiting(queued))
        // The launch receipt was the rejected result: Core then withdraws it.
        val verdict = ledger.settle(snapshot(), AgentNotSentEvidence.ACCEPTED)
        assertNotNull(verdict)
        val (settled, settlement) = verdict!!
        assertSame(queued, settled)
        assertEquals(AgentNotSentSettlement.RETURN_DRAFT, settlement)
        assertEquals("hello Claude", AgentCenterUiState().withSettledNotSent(settled.pending, settlement).drafts["thread"])
        assertFalse(ledger.isWaiting(queued))
    }

    // Core withdraws an issued lease's bubble even after an unbind or rebind
    // revoked it, so a snapshot that still lists the bubble under another
    // binding (or none) may predate the result: only Core's answer settles.
    @Test fun aBubbleListedAfterARebindWaitsForCoresAnswer() {
        val ledger = AgentNotSentLedger()
        val queued = wait()
        ledger.register(queued)
        val rebound = JSONObject(leaseBinding.toString()).put("carrierGeneration", 4)
        val plain = AgentNotSentEvidence.SNAPSHOT
        assertNull(ledger.settle(snapshot(outgoing = listOf(token), binding = leaseBinding), plain))
        assertNull(ledger.settle(snapshot(outgoing = listOf(token), binding = rebound), plain))
        assertNull(ledger.settle(snapshot(outgoing = listOf(token.lowercase()), binding = null), plain))
        val hidden = AgentHistoryWindow(1, atLiveHead = false, hasNewer = true, after = null, transition = "older", retainsOutgoing = true)
        assertNull(ledger.settle(snapshot(binding = rebound, window = hidden), plain))
        assertTrue(ledger.isWaiting(queued))
        assertEquals(AgentNotSentSettlement.RETURN_DRAFT,
            ledger.settle(snapshot(binding = null), AgentNotSentEvidence.ACCEPTED)?.second)
        assertFalse(ledger.isWaiting(queued))
        // Core answered and the bubble survived: ambiguous at once.
        val kept = wait()
        ledger.register(kept)
        assertEquals(AgentNotSentSettlement.AMBIGUOUS,
            ledger.settle(snapshot(outgoing = listOf(token), binding = rebound), AgentNotSentEvidence.ACCEPTED)?.second)
    }

    // Core's verdict can be dropped from the event buffer or replaced by
    // abi_event_too_large. The result is queued once more, and then the
    // latest snapshot decides; nothing waits forever.
    @Test fun aVerdictThatNeverShowsIsProbedOnceThenSettled() {
        val policy = AgentNotSentFallbackPolicy(probeAfterMillis = 2_000, probeWindowMillis = 2_000, hardCapMillis = 10_000, tickMillis = 100)
        fun run(ledger: AgentNotSentLedger, queued: AgentNotSentWait, probeAllowed: (Long) -> Boolean = { true }): List<Pair<Long, AgentNotSentFallbackStep>> {
            val steps = mutableListOf<Pair<Long, AgentNotSentFallbackStep>>()
            while (true) {
                val step = ledger.advance(queued, policy.tickMillis, probeAllowed(queued.elapsedMillis + policy.tickMillis)) ?: break
                if (step != AgentNotSentFallbackStep.WAIT) steps += queued.elapsedMillis to step
                if (step == AgentNotSentFallbackStep.SETTLE) break
                check(queued.elapsedMillis <= 60_000) { "the clock never stopped" }
            }
            return steps
        }
        val ledger = AgentNotSentLedger(policy)
        val quiet = wait()
        ledger.register(quiet)
        assertEquals(listOf(2_000L to AgentNotSentFallbackStep.PROBE, 4_000L to AgentNotSentFallbackStep.SETTLE), run(ledger, quiet))
        assertFalse(ledger.isWaiting(quiet))
        assertNull("a settled wait's clock stops", ledger.advance(quiet, policy.tickMillis, true))

        // A rejection asks at once; the verdict still gets a full window.
        val rejected = wait()
        ledger.register(rejected)
        ledger.advance(rejected, 300, true)
        ledger.noteRejection("abi_invalidField@result")
        assertEquals(AgentNotSentFallbackStep.PROBE, ledger.advance(rejected, 0, true))
        assertEquals(listOf(2_300L to AgentNotSentFallbackStep.SETTLE), run(ledger, rejected))

        // While the thread's next action is queued no probe is sent (its
        // answer could follow that ActionPlan); the hard cap still settles.
        val busy = wait()
        ledger.register(busy)
        assertEquals(listOf(10_000L to AgentNotSentFallbackStep.SETTLE), run(ledger, busy) { false })
        val freed = wait()
        ledger.register(freed)
        assertEquals(listOf(3_000L to AgentNotSentFallbackStep.PROBE, 5_000L to AgentNotSentFallbackStep.SETTLE),
            run(ledger, freed) { it > 3_000 - policy.tickMillis })

        // Settled from its snapshot meanwhile: the clock just stops.
        val answered = wait()
        ledger.register(answered)
        ledger.advance(answered, 1_000, true)
        assertNotNull(ledger.settle(snapshot(), AgentNotSentEvidence.ACCEPTED))
        assertNull(ledger.advance(answered, 5_000, true))
    }

    // Not final either: the ambiguous verdict keeps a late watch.
    @Test fun theFallbackNeverSettlesBlindlyAsWithdrawn() {
        assertEquals(AgentNotSentSettlement.AMBIGUOUS_WATCH, agentNotSentFallbackSettlement(token, null))
        assertEquals(AgentNotSentSettlement.AMBIGUOUS_WATCH, agentNotSentFallbackSettlement(token, snapshot(outgoing = listOf(token.lowercase()))))
        assertEquals(AgentNotSentSettlement.AMBIGUOUS_WATCH, agentNotSentFallbackSettlement(token, snapshot(
            window = AgentHistoryWindow(1, atLiveHead = false, hasNewer = true, after = null, transition = "older", retainsOutgoing = true))))
        assertEquals(AgentNotSentSettlement.RETURN_DRAFT, agentNotSentFallbackSettlement(token, snapshot(outgoing = listOf("other"))))
        assertEquals(AgentNotSentSettlement.RETURN_DRAFT, agentNotSentFallbackSettlement(token, snapshot(
            window = AgentHistoryWindow(1, atLiveHead = false, hasNewer = true, after = null, transition = "older", retainsOutgoing = false))))
    }

    // The probe is the very result Core already has: idempotent there.
    @Test fun theProbeRequeuesExactlyTheOriginalResult() {
        val first = agentNotSentResultCommand(lease, "binding-token", "send", AgentNotSentReason.INPUT_NOT_READY)
        assertEquals("result", first.getString("kind"))
        assertEquals("binding-token", first.getString("bindingToken"))
        assertEquals(token, first.getJSONObject("lease").getString("token"))
        assertEquals("notSent", first.getJSONObject("resultOutcome").getString("status"))
        assertEquals("send", first.getJSONObject("resultOutcome").getString("action"))
        assertEquals(first.toString(), agentNotSentResultCommand(lease, "binding-token", "send", AgentNotSentReason.INPUT_NOT_READY).toString())
    }

    // Registered before the result is queued (Core may answer at once), the
    // pending action released only after it; a result Core never took drops
    // its wait.
    @Test fun notSentIsQueuedInTheOnlySafeOrder() {
        for (accepted in listOf(true, false)) {
            val order = mutableListOf<String>()
            val forwarded = agentQueueNotSent(
                register = { order += "register" },
                forward = { order += "forward"; accepted },
                release = { order += "release" },
                abandon = { order += "abandon" },
            )
            assertEquals(accepted, forwarded)
            assertEquals(listOf("register", "forward", "release") + if (accepted) emptyList() else listOf("abandon"), order)
        }
        // One wait per thread: a newer one replaces (and stops) the older.
        val ledger = AgentNotSentLedger()
        val older = wait()
        val newer = wait()
        assertNull(ledger.register(older))
        assertSame(older, ledger.register(newer))
        assertFalse(ledger.abandon(older))
        assertNull(ledger.advance(older, 100, true))
        assertTrue(ledger.isWaiting(newer))
        assertTrue(ledger.abandon(newer))
        assertFalse(ledger.isWaiting(newer))
    }

    @Test fun settlingReturnsTheDraftOnlyWhenWithdrawn() {
        val state = AgentCenterUiState(drafts = mapOf("other" to "keep me"), notice = "abi invalidField@result")
        val returned = state.withSettledNotSent(pending(), AgentNotSentSettlement.RETURN_DRAFT)
        assertEquals("hello Claude", returned.drafts["thread"])
        assertEquals("keep me", returned.drafts["other"])
        assertEquals("Not sent — Claude's input wasn't ready. Nothing was typed; your message is back in the box.", returned.notice)

        // Ambiguous: the composer is left alone and the legacy notice shows,
        // exactly as the unconfirmed result would have.
        val ambiguous = state.withSettledNotSent(pending(), AgentNotSentSettlement.AMBIGUOUS)
        assertNull(ambiguous.drafts["thread"])
        assertEquals(state.drafts, ambiguous.drafts)
        assertEquals("Terminal binding is stale; reopen the terminal before retrying", ambiguous.notice)
        assertEquals("terminal input not ready",
            state.withSettledNotSent(pending(legacyCode = "terminal_input_not_ready"), AgentNotSentSettlement.AMBIGUOUS).notice)
        assertEquals(ambiguous, state.withSettledNotSent(pending(), AgentNotSentSettlement.AMBIGUOUS_WATCH))

        assertSame(state, state.withSettledNotSent(pending(), AgentNotSentSettlement.WAIT))
    }

    @Test fun legacyNoticesMatchTheFinishedActionCopy() {
        assertNull(agentActionResultNotice("success"))
        assertEquals("Terminal binding is stale; reopen the terminal before retrying", agentActionResultNotice("staleBinding"))
        assertEquals("Terminal verification failed; review the terminal before retrying", agentActionResultNotice("verificationFailed"))
        assertEquals("receipt baseline unavailable", agentActionResultNotice("receipt_baseline_unavailable"))
        assertEquals("cancelled", agentActionResultNotice("cancelled"))
    }

    // The ActionPlan clears only the exact accepted draft. Typing between
    // Send and the plan, or a draft longer than the 32,768-character message,
    // leaves the box as it was: the message never left, so it is not merged.
    @Test fun aDraftTheActionPlanNeverClearedIsNotDuplicated() {
        assertTrue(agentActionPlanClearsDraft("msg", "msg"))
        assertFalse(agentActionPlanClearsDraft("msg more", "msg"))
        assertFalse(agentActionPlanClearsDraft("", "msg"))
        assertFalse(agentActionPlanClearsDraft("", ""))
        val long = "x".repeat(40_000)
        val accepted = long.take(32_768)
        assertFalse(agentActionPlanClearsDraft(long, accepted))

        // Typing continued before acceptance: the box keeps what it holds.
        val typed = AgentCenterUiState(drafts = mapOf("thread" to "msg more"))
            .withUnsentMessage("thread", "msg", AgentNotSentReason.INPUT_NOT_READY, "Claude", draftCleared = false)
        assertEquals("msg more", typed.drafts["thread"])
        assertEquals("Not sent — Claude's input wasn't ready. Nothing was typed; your message is back in the box.", typed.notice)
        val tooLong = AgentCenterUiState(drafts = mapOf("thread" to long))
            .withUnsentMessage("thread", accepted, AgentNotSentReason.ROUTE_CHANGED, "Claude", draftCleared = false)
        assertEquals(long, tooLong.drafts["thread"])
        // A box emptied since still takes the message back.
        for (blank in listOf("", "  \n")) {
            assertEquals("msg" to AgentUnsentDraft.RESTORED, agentDraftWithUnsentMessage(blank, "msg", draftCleared = false))
        }
        // A cleared box keeps the restore/merge rule.
        assertEquals("msg\n\nnewer" to AgentUnsentDraft.MERGED, agentDraftWithUnsentMessage("newer", "msg", draftCleared = true))
        // Never cleared, and the box no longer starts with the message: the
        // normal rule, so the message is not lost (iOS returnUnsentText).
        assertEquals("msg\n\nnewer" to AgentUnsentDraft.MERGED, agentDraftWithUnsentMessage("newer", "msg", draftCleared = false))
        assertEquals("msg\n\nmore msg" to AgentUnsentDraft.MERGED, agentDraftWithUnsentMessage("more msg", "msg", draftCleared = false))
        assertEquals("msg" to AgentUnsentDraft.RESTORED, agentDraftWithUnsentMessage("msg", "msg", draftCleared = false))
        // A cleared box that happens to start with the message still merges.
        assertEquals("msg\n\nmsg more" to AgentUnsentDraft.MERGED, agentDraftWithUnsentMessage("msg more", "msg", draftCleared = true))

        // The draft rule reaches settlement.
        val settled = AgentCenterUiState(drafts = mapOf("thread" to "hello Claude and more"))
            .withSettledNotSent(pending(draftCleared = false), AgentNotSentSettlement.RETURN_DRAFT)
        assertEquals("hello Claude and more", settled.drafts["thread"])
    }

    @Test fun finishingReleasesOnlyTheMatchingThreadAndLease() {
        val binding = JSONObject().put("liveSessionID", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE").put("carrierGeneration", 3)
            .put("transport", "sshTmux").put("tmuxSession", "s").put("windowID", "@1").put("paneID", "%1").put("agentPID", 42)
        val otherBinding = JSONObject(binding.toString()).put("paneID", "%2")
        val lease = JSONObject().put("action", "send").put("binding", binding).put("token", token)
        assertTrue(agentFinishReleasesPending("thread", "send", binding, lease, "thread", token))
        assertTrue(agentFinishReleasesPending("thread", "interrupt", otherBinding, lease, "thread", token))
        assertFalse(agentFinishReleasesPending("thread", "send", binding, lease, "thread", "new-lease"))
        assertFalse(agentFinishReleasesPending("thread", "interrupt", otherBinding, lease, "thread"))
        assertFalse(agentFinishReleasesPending("other", "send", binding, lease, "thread"))
        assertFalse(agentFinishReleasesPending("other", "send", binding, lease, null))
        assertFalse(agentFinishReleasesPending("other", "queue", binding, lease, "thread"))
        assertFalse(agentFinishReleasesPending("other", "send", otherBinding, lease, "thread"))

        // The lease names its thread exactly as the list keys its row.
        val host = "0F8FAD5B-D9CB-469F-A165-70867728950E"
        val threadID = JSONObject().put("hostID", host).put("providerID", JSONObject().put("rawValue", "claude"))
            .put("providerSessionID", "session-1")
        assertEquals(canonicalAgentThreadKey(host.lowercase(), "claude", "session-1"),
            agentLeaseThreadKey(JSONObject().put("threadID", threadID)))
        assertEquals(agentLeaseThreadKey(JSONObject().put("threadID", threadID)),
            agentLeaseThreadKey(JSONObject().put("threadID", JSONObject(threadID.toString()).put("hostID", host.lowercase()))))
        assertNull(agentLeaseThreadKey(JSONObject()))
        assertNull(agentLeaseThreadKey(JSONObject().put("threadID", JSONObject().put("hostID", host))))
    }

    @Test fun removedConversationSettlesOnlyItsOriginalBindingWaitOnce() {
        val ledger = AgentNotSentLedger()
        val original = AgentNotSentWait(pending(), "runtime", JSONObject(lease.toString()), "original-binding")
        ledger.register(original)
        assertNull(ledger.settleRemovedConversation("other", "original-binding"))
        assertNull(ledger.settleRemovedConversation("thread", "replacement-binding"))
        assertTrue(ledger.isWaiting(original))
        assertSame(original, ledger.settleRemovedConversation("thread", "original-binding"))
        assertFalse(ledger.isWaiting(original))
        assertNull(ledger.settleRemovedConversation("thread", "original-binding"))

        val replacement = AgentNotSentWait(pending(), "runtime", JSONObject(lease.toString()), "replacement-binding")
        ledger.register(replacement)
        assertNull(ledger.settleRemovedConversation("thread", "original-binding"))
        assertTrue(ledger.isWaiting(replacement))
        while (ledger.advance(replacement, 100, probeAllowed = true) != AgentNotSentFallbackStep.SETTLE) Unit
        assertEquals(AgentNotSentSettlement.AMBIGUOUS_WATCH, ledger.settleByFallback(replacement, null))
        assertNull(ledger.settleRemovedConversation("thread", "original-binding"))
        assertTrue(ledger.isWatchingLate(replacement))
        assertSame(replacement, ledger.settleRemovedConversation("thread", "replacement-binding"))
        assertFalse(ledger.isWatchingLate(replacement))
    }

    @Test fun unwrittenWithdrawalRetainsOriginalAuthorityAfterRebind() {
        val original = "original-binding-token"
        val wait = AgentNotSentWait(pending(), "runtime", JSONObject(lease.toString()), original)
        val currentAuthority = mutableMapOf("thread" to original)
        currentAuthority["thread"] = "replacement-binding-token"
        val command = agentNotSentResultCommand(wait.lease, checkNotNull(wait.bindingToken), wait.pending.action, wait.pending.reason)
        assertEquals(original, command.getString("bindingToken"))
        assertEquals(token, command.getJSONObject("lease").getString("token"))
        assertEquals("notSent", command.getJSONObject("resultOutcome").getString("status"))
        assertEquals("replacement-binding-token", currentAuthority["thread"])
    }

    // A prompt-answer check never accepts a capture with no text.
    @Test fun aCaptureWithoutTextIsEvidenceOfNothing() {
        val binding = AgentEndpointBinding(AgentSessionKey("carrier", 1), "host", AgentEndpointTransport.SSH_TMUX)
        fun capture(tail: String) = AgentTerminalObservation(binding, tail.encodeToByteArray(), truncated = false, authoritative = true,
            currentCursorLine = null)
        assertFalse(agentCaptureHasText(capture("")))
        assertFalse(agentCaptureHasText(capture("\n\n  \n")))
        assertTrue(agentCaptureHasText(capture("\n❯ \n")))
        val working = capture("• Working (3s · esc to interrupt)\n❯ ")
        assertFalse("a blank frame never proves Escape landed", agentInterruptObserved(working, capture("\n\n")))
        assertFalse(agentInterruptObserved(working, capture("• Working (3s · esc to interrupt)\n❯ ")))
        assertTrue(agentInterruptObserved(working, capture("■ Conversation interrupted\n❯ ")))
    }
}
