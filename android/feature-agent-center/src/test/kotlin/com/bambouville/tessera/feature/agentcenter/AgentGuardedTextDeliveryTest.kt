package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentProcessProof
import com.bambouville.tessera.agent.platform.AgentProofProvider
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentTerminalObservation
import com.bambouville.tessera.core.bridge.SharedAgentComposerEvidence.Assessment
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class AgentGuardedTextDeliveryTest {
    @Test fun claudeSubmissionNeedsRecognizedAbsenceAfterTheMarkersLeave() = runBlocking {
        for (transport in AgentEndpointTransport.entries) {
            val binding = AgentEndpointBinding(AgentSessionKey("carrier", 1), "host", transport, paneID = "%4")
            val retained = AgentTerminalObservation(binding, "❯ [Image #4]\n  [Image #5]\n────\n? for shortcuts".encodeToByteArray(),
                truncated = false, authoritative = true, currentCursorLine = "  [Image #5]", cursorRow = 1)
            for (assessment in Assessment.entries) {
                assertEquals(assessment == Assessment.ABSENT, agentComposerDeparted(retained, assessment))
            }
            for (unproven in listOf(retained.copy(authoritative = false), retained.copy(truncated = true), retained.copy(captureWaitedForFrame = true))) {
                assertFalse(agentComposerDeparted(unproven, Assessment.ABSENT))
            }
            for (swallowed in listOf(false, true)) {
                var reads = 0
                val departed = agentBoundedPoll(attempts = 4, intervalMillis = 0, budgetMillis = 2_000) {
                    val assessment = if (++reads < 3 || swallowed) Assessment.RETURN else Assessment.ABSENT
                    if (agentComposerDeparted(retained, assessment)) AgentPoll.Found(Unit) else AgentPoll.Again
                }
                assertEquals(if (swallowed) null else Unit, departed)
                assertEquals(if (swallowed) 4 else 3, reads)
            }
        }
        assertEquals("Terminal verification failed; review the terminal before retrying", agentActionResultNotice("verificationFailed"))
    }

    @Test fun consecutiveFrameWaitsAreInconclusiveUntilSettledDepartureOrBudget() = runBlocking {
        val binding = AgentEndpointBinding(AgentSessionKey("carrier", 1), "host", AgentEndpointTransport.SSH_TMUX, paneID = "%4")
        val frame = AgentTerminalObservation(binding, "❯ \n────\n? for shortcuts".encodeToByteArray(),
            truncated = false, authoritative = true, currentCursorLine = "❯ ", cursorRow = 0)
        var reads = 0
        var predicates = 0
        val found = agentBoundedPoll(attempts = 8, intervalMillis = 0, budgetMillis = 2_000) {
            val observed = frame.copy(captureWaitedForFrame = ++reads <= 4)
            agentObservationPoll(observed) { predicates++; agentComposerDeparted(it, Assessment.ABSENT) }
        }
        assertEquals(frame, found)
        assertEquals(5, reads)
        assertEquals(1, predicates)
        assertNull(agentBoundedPoll(attempts = 40, intervalMillis = 50, budgetMillis = 30) {
            agentObservationPoll(frame.copy(captureWaitedForFrame = true)) { error("Unsettled frame assessed") }
        })
        assertNull(agentBoundedPoll<AgentTerminalObservation>(attempts = 40, intervalMillis = 0, budgetMillis = 30) {
            awaitCancellation()
        })
    }

    @Test fun onlyAnUploadedImageLineScopesTheImageWaits() {
        assertTrue(agentDraftAttachesImages("\"/home/dev/.cache/tessera/paste-1.png\""))
        assertTrue(agentDraftAttachesImages("Describe this\n  \"/tmp/a b.JPG\"  \nThanks"))
        assertTrue(agentDraftAttachesImages("\"C:\\\\Users\\\\dev\\\\shot.webp\""))
        for (text in listOf("Describe /tmp/a.png", "\"/tmp/a.txt\"", "\"relative/a.png\"", "say \"/tmp/a.png\"", "\"\"", "")) {
            assertFalse(text, agentDraftAttachesImages(text))
        }
    }

    @Test fun transportNonAdmissionReturnsTheDraftButFailureAfterAdmissionStaysAmbiguous() = runBlocking {
        for (admitted in listOf(false, true)) {
            val port = FakePort(captures = { Capture(Assessment.RETURN) },
                writeResult = AgentEndpointResult.Failed(if (admitted) "raw_write_failed" else "raw_input_unavailable", inputNotAdmitted = !admitted))
            val latch = AgentTerminalWriteLatch()
            val result = port.deliver(latch)
            if (admitted) assertTrue(result is AgentTextDeliveryResult.Attempted)
            else assertEquals(AgentNotSentReason.INPUT_UNAVAILABLE, (result as AgentTextDeliveryResult.NotSent).reason)
            assertEquals(admitted, latch.mayHaveWritten)
            assertEquals(1, port.writes.size)
            assertEquals(0, port.submits)
        }
        val latch = AgentTerminalWriteLatch().also { it.markWriting() }
        latch.attempt { AgentEndpointResult.Failed("raw_input_unavailable", inputNotAdmitted = true) }
        assertTrue("A later refusal cannot undo an earlier write", latch.mayHaveWritten)
    }

    @Test fun promptStepsUseNamedKeysOnTmuxAndKeepPlannerBytesOnRawCarriers() = runBlocking {
        for (transport in AgentEndpointTransport.entries) {
            val binding = AgentEndpointBinding(AgentSessionKey("carrier", 1), "host", transport, paneID = "%4")
            val writes = mutableListOf<String>()
            val endpoint = java.lang.reflect.Proxy.newProxyInstance(javaClass.classLoader,
                arrayOf(com.bambouville.tessera.agent.platform.AgentSessionEndpoint::class.java)) { _, method, arguments ->
                when (method.name) {
                    "sendInput" -> { writes += "bytes:${(arguments!![1] as ByteArray).decodeToString()}"; AgentEndpointResult.Success(Unit) }
                    "sendSemanticKey" -> { writes += "key:${(arguments!![1] as com.bambouville.tessera.agent.platform.AgentSemanticKey).tmuxName}"; AgentEndpointResult.Success(Unit) }
                    else -> error("unexpected ${method.name}")
                }
            } as com.bambouville.tessera.agent.platform.AgentSessionEndpoint
            for (key in com.bambouville.tessera.agent.platform.AgentSemanticKey.entries) {
                val bytes = key.encoded().decodeToString()
                assertEquals(AgentEndpointResult.Success(Unit), sendAgentPromptStep(endpoint, binding, bytes, key.tmuxName))
                assertEquals(if (transport.name.endsWith("TMUX")) "key:${key.tmuxName}" else "bytes:$bytes", writes.last())
            }
            sendAgentPromptStep(endpoint, binding, "1", null)
            assertEquals("bytes:1", writes.last())
            if (transport.name.endsWith("TMUX")) {
                val count = writes.size
                assertTrue(sendAgentPromptStep(endpoint, binding, "\r", "Enter; select-pane") is AgentEndpointResult.Failed)
                assertEquals(count, writes.size)
            }
        }
    }

    @Test fun missedAuthorityRefreshDoesNotClaimThatTheTerminalChanged() {
        for (code in listOf("proof_timeout", "proof_read_failed", "proof_exit_1", "tmux_process_unavailable", "exec_unavailable:closed")) {
            assertEquals(code, AgentNotSentReason.INPUT_NOT_READY, agentRouteRefreshFailureReason(AgentEndpointResult.Failed(code)))
        }
        for (code in listOf("invalid_process", "proof_not_valid", "proof_pid_unlisted=42", "proof_provider=claude/codex")) {
            assertEquals(code, AgentNotSentReason.ROUTE_CHANGED, agentRouteRefreshFailureReason(AgentEndpointResult.Failed(code)))
        }
        assertEquals(AgentNotSentReason.ROUTE_CHANGED, agentRouteRefreshFailureReason(AgentEndpointResult.StaleBinding))
        assertEquals(AgentNotSentReason.INPUT_UNAVAILABLE, agentRouteRefreshFailureReason(AgentEndpointResult.Unavailable("no input")))
        assertEquals(AgentNotSentReason.INPUT_UNAVAILABLE, agentRouteRefreshFailureReason(AgentEndpointResult.Failed("platform_binding_rejected")))
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, agentRouteRefreshFailureReason(AgentEndpointResult.Failed("proof_exit_1", proofReason = "processIdentityUnavailable")))
        assertEquals(AgentNotSentReason.ROUTE_CHANGED, agentRouteRefreshFailureReason(AgentEndpointResult.Failed("proof_exit_1", proofReason = "providerMismatch")))
    }

    @Test fun initialAuthorityMissRetriesWithinTheSharedPreflightAllowance() = runBlocking {
        var now = 0L
        var attempts = 0
        val refresh = retryAgentRouteBinding(nanoTime = { now }, pause = { now += it * 1_000_000 }) {
            if (++attempts == 1) AgentEndpointResult.Failed("proof_exit_1", proofReason = "processIdentityUnavailable")
            else AgentEndpointResult.Success("authority")
        }
        assertEquals(AgentEndpointResult.Success("authority"), refresh.result)
        assertEquals(2, attempts)
        assertEquals(150, refresh.elapsedMillis)
        assertEquals(AgentSendPreflightPolicy(windowMillis = 1_850, deadlineMillis = 4_850), refresh.remainingPolicy(AgentSendPreflightPolicy()))
    }

    @Test fun exhaustedInitialMissIsInputNotReadyAndDefinitiveChangeDoesNotRetry() = runBlocking {
        for (definitive in listOf(false, true)) {
            var now = 0L
            val refresh = retryAgentRouteBinding<Unit>(nanoTime = { now }, pause = { now += it * 1_000_000 }) {
                AgentEndpointResult.Failed("proof_exit_1", proofReason = if (definitive) "providerMismatch" else "processIdentityUnavailable")
            }
            assertEquals(if (definitive) 1 else 14, refresh.attempts)
            assertEquals(if (definitive) AgentNotSentReason.ROUTE_CHANGED else AgentNotSentReason.INPUT_NOT_READY,
                agentRouteRefreshFailureReason(refresh.result))
        }
    }

    @Test fun slowInitialAuthorityReadCannotOutliveTheDeadline() = runBlocking {
        val refresh = retryAgentRouteBinding<Unit>(policy = AgentSendPreflightPolicy(intervalMillis = 5, windowMillis = 20, deadlineMillis = 30)) {
            kotlinx.coroutines.awaitCancellation()
        }
        assertEquals(1, refresh.attempts)
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, agentRouteRefreshFailureReason(refresh.result))
    }

    /** One scripted capture: what the endpoint returns and how Core assesses it. */
    private data class Capture(
        val assessment: Assessment,
        val authoritative: Boolean = true,
        val truncated: Boolean = false,
        val waitedForFrame: Boolean = false,
        val cursorVisible: Boolean = true,
        val unavailable: Boolean = false,
        val tail: String = "❯ \n────",
        val inspectMillis: Long = 0,
    )

    private class FakePort(
        private val transport: AgentEndpointTransport = AgentEndpointTransport.SSH_TMUX,
        private val captures: (Int) -> Capture,
        private val proof: (Int) -> AgentInputTargetProof = { AgentInputTargetProof.PROVEN },
        /** How long each proof takes; past its budget it times out as UNPROVEN. */
        private val proofMillis: (Int) -> Long = { 0 },
        /** A throw from inside a read, e.g. a foreign cancellation. */
        private val readThrows: suspend (read: String, n: Int) -> Unit = { _, _ -> },
        private val insertion: ByteArray? = "hello".encodeToByteArray(),
        private val writeResult: AgentEndpointResult<Unit> = AgentEndpointResult.Success(Unit),
        private val submitResult: AgentEndpointResult<Unit> = AgentEndpointResult.Success(Unit),
        private val cancelAtActiveCheck: Int? = null,
        private val cancelDuringWrite: Boolean = false,
        /** The transport's pre-write refusal (D7), asked once before the write. */
        private val writeRefusal: AgentNotSentReason? = null,
    ) : AgentTextDeliveryPort {
        var nowNanos = 0L
        val pauses = mutableListOf<Long>()
        var activeChecks = 0
        var proofs = 0
        var inspections = 0
        val writes = mutableListOf<ByteArray>()
        var submits = 0
        val events = mutableListOf<String>()
        /** The time budget each read was given, in call order. */
        val budgets = mutableListOf<Pair<String, Long>>()
        private var lastAssessment = Assessment.UNAVAILABLE
        private val binding = AgentEndpointBinding(AgentSessionKey("carrier", 1), "host", transport,
            tmuxSession = "s", windowID = "@1", paneID = "%1")

        override suspend fun ensureActive() {
            activeChecks++
            if (activeChecks == cancelAtActiveCheck) throw CancellationException("Agent action no longer active")
        }

        override suspend fun proveInputTarget(timeoutMillis: Long): AgentInputTargetProof {
            val n = ++proofs
            events += "prove"
            budgets += "prove" to timeoutMillis
            readThrows("prove", n)
            val latency = proofMillis(n)
            nowNanos += minOf(latency, timeoutMillis) * 1_000_000
            return if (latency > timeoutMillis) AgentInputTargetProof.UNPROVEN else proof(n)
        }

        override suspend fun inspect(timeoutMillis: Long): AgentTerminalObservation? {
            val capture = captures(++inspections)
            events += "inspect"
            budgets += "inspect" to timeoutMillis
            readThrows("inspect", inspections)
            nowNanos += minOf(capture.inspectMillis, timeoutMillis) * 1_000_000
            if (capture.unavailable || capture.inspectMillis > timeoutMillis) return null
            lastAssessment = capture.assessment
            return AgentTerminalObservation(binding, capture.tail.encodeToByteArray(), capture.truncated, capture.authoritative,
                currentCursorLine = "❯ ", cursorRow = 0, cursorVisible = capture.cursorVisible, cursorColumn = 2,
                captureWaitedForFrame = capture.waitedForFrame)
        }

        override fun assessEmptyComposer(observation: AgentTerminalObservation): Assessment = lastAssessment

        override fun insertion(): ByteArray? = insertion

        override fun writeRefusal(): AgentNotSentReason? = writeRefusal?.also { events += "refusal" }

        override suspend fun write(input: ByteArray): AgentEndpointResult<Unit> {
            events += "write"
            writes += input
            if (cancelDuringWrite) throw CancellationException("cancelled mid-write")
            return writeResult
        }

        override suspend fun submit(): AgentEndpointResult<Unit> {
            events += "submit"
            submits++
            return submitResult
        }

        suspend fun deliver(latch: AgentTerminalWriteLatch, knownEditor: Boolean = true) =
            deliverAgentGuardedText(this, latch, knownEditor, nanoTime = { nowNanos }, pause = { millis ->
                pauses += millis
                nowNanos += millis * 1_000_000
            })
    }

    // (b) Claude Code's animated redraw: hidden cursor, a torn capture, and a
    // half-painted composer each settle within the window; one write follows.
    // Delivery never branches on transport (the endpoint owns SSH, mosh and
    // tmux differences), so one scripted port covers all four.
    @Test fun transientInputStatesSettleAndWriteExactlyOnce() = runBlocking {
        val script = listOf(
            Capture(Assessment.BLOCKED, cursorVisible = false),
            Capture(Assessment.UNAVAILABLE, unavailable = true),
            Capture(Assessment.UNAVAILABLE),
            Capture(Assessment.RETURN, authoritative = false),
            Capture(Assessment.RETURN, truncated = true),
            Capture(Assessment.RETURN),
        )
        val port = FakePort(captures = { script[it - 1] })
        val latch = AgentTerminalWriteLatch()
        val result = port.deliver(latch)
        assertTrue(result is AgentTextDeliveryResult.Attempted)
        result as AgentTextDeliveryResult.Attempted
        assertEquals(AgentEndpointResult.Success(Unit), result.result)
        assertEquals(6, result.attempts)
        assertEquals(1, port.writes.size)
        assertEquals(1, port.submits)
        assertTrue(latch.mayHaveWritten)
        assertEquals(List(5) { 150L }, port.pauses)
        // A proof is never carried across a pause: each attempt re-proves
        // before it captures, and the accepted capture precedes the write.
        assertEquals(6, port.proofs)
        assertEquals(listOf("prove", "inspect", "write", "submit"), port.events.takeLast(4))
    }

    @Test fun frameWaitedCaptureIsReprovenAndOnlyAnImmediateCaptureIsAccepted() = runBlocking {
        val port = FakePort(captures = { n ->
            when (n) {
                1 -> Capture(Assessment.RETURN, waitedForFrame = true)
                2 -> Capture(Assessment.RETURN, waitedForFrame = true)  // still aged: transient
                3 -> Capture(Assessment.RETURN, waitedForFrame = true)
                else -> Capture(Assessment.RETURN)
            }
        })
        val latch = AgentTerminalWriteLatch()
        val result = port.deliver(latch) as AgentTextDeliveryResult.Attempted
        assertEquals(2, result.attempts)
        assertEquals(listOf("prove", "inspect", "prove", "inspect", "prove", "inspect", "prove", "inspect", "write", "submit"), port.events)
        assertEquals(1, port.writes.size)
    }

    // (c) A composer that never becomes ready is refused after the bounded
    // window, with nothing written and the last sample's reason.
    @Test fun persistentNotReadyGivesUpAfterTheWindowWithoutWriting() = runBlocking {
        for ((assessment, reason) in listOf(
            Assessment.BLOCKED to AgentNotSentReason.INPUT_NOT_READY,
            Assessment.UNAVAILABLE to AgentNotSentReason.INPUT_NOT_READY,
            Assessment.ABSENT to AgentNotSentReason.INPUT_NOT_READY,
            Assessment.OCCUPIED to AgentNotSentReason.TERMINAL_DRAFT,
        )) {
            val port = FakePort(captures = { Capture(assessment, cursorVisible = assessment != Assessment.BLOCKED) })
            val latch = AgentTerminalWriteLatch()
            val result = port.deliver(latch)
            assertTrue(result is AgentTextDeliveryResult.NotSent)
            result as AgentTextDeliveryResult.NotSent
            assertEquals(reason, result.reason)
            // 0, 150, ..., 1950 ms: no attempt starts after the 2 s window.
            assertEquals(14, result.attempts)
            assertEquals(13, port.pauses.size)
            assertTrue(port.pauses.sum() <= 2_000)
            assertTrue(port.writes.isEmpty())
            assertEquals(0, port.submits)
            assertFalse(latch.mayHaveWritten)
            assertEquals(assessment, (result.last as AgentInputSurfaceSample.Observed).assessment)
        }
    }

    @Test fun slowCapturesStillRespectTheWindow() = runBlocking {
        val port = FakePort(captures = { Capture(Assessment.BLOCKED, inspectMillis = 400) })
        val result = port.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, result.reason)
        assertEquals(4, result.attempts)
        assertTrue(port.nowNanos / 1_000_000 <= 2_000 + 400)
    }

    @Test fun unavailableCaptureThroughoutIsInputNotReady() = runBlocking {
        val port = FakePort(captures = { Capture(Assessment.UNAVAILABLE, unavailable = true) })
        val result = port.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, result.reason)
        assertEquals(AgentInputSurfaceSample.CaptureUnavailable, result.last)
        assertTrue(port.writes.isEmpty())
    }

    @Test fun aChangedRouteIsNotTransientAndStopsImmediately() = runBlocking {
        // First attempt: route gone before any capture.
        val gone = FakePort(captures = { Capture(Assessment.RETURN) }, proof = { AgentInputTargetProof.GONE })
        val first = gone.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.ROUTE_CHANGED, first.reason)
        assertEquals(1, first.attempts)
        assertEquals(0, gone.inspections)
        assertTrue(gone.pauses.isEmpty())
        // Mid-retry: the process changes while waiting for the composer.
        val changed = FakePort(captures = { Capture(Assessment.BLOCKED) },
            proof = { if (it < 3) AgentInputTargetProof.PROVEN else AgentInputTargetProof.GONE })
        val later = changed.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.ROUTE_CHANGED, later.reason)
        assertEquals(3, later.attempts)
        assertEquals(2, changed.pauses.size)
        assertTrue(changed.writes.isEmpty())
        // A frame wait whose re-proof fails is a changed route as well.
        val aged = FakePort(captures = { Capture(Assessment.RETURN, waitedForFrame = true) },
            proof = { if (it == 1) AgentInputTargetProof.PROVEN else AgentInputTargetProof.GONE })
        val refused = aged.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.ROUTE_CHANGED, refused.reason)
        assertEquals(1, refused.attempts)
        assertTrue(aged.writes.isEmpty())
    }

    // iOS parity: a process probe that missed is transient within the window.
    @Test fun aMissedTargetProofIsRetriedAndWritesExactlyOnce() = runBlocking {
        val port = FakePort(captures = { Capture(Assessment.RETURN) },
            proof = { if (it < 3) AgentInputTargetProof.UNPROVEN else AgentInputTargetProof.PROVEN })
        val latch = AgentTerminalWriteLatch()
        val result = port.deliver(latch) as AgentTextDeliveryResult.Attempted
        assertEquals(AgentEndpointResult.Success(Unit), result.result)
        assertEquals(3, result.attempts)
        assertEquals(listOf(150L, 150L), port.pauses)
        // Nothing is captured, let alone written, until the target is proven.
        assertEquals(listOf("prove", "prove", "prove", "inspect", "write", "submit"), port.events)
        assertEquals(1, port.writes.size)
        assertEquals(1, port.submits)
        assertTrue(latch.mayHaveWritten)

        // A frame-wait re-proof that misses is retried the same way.
        val aged = FakePort(captures = { n -> Capture(Assessment.RETURN, waitedForFrame = n == 1) },
            proof = { if (it == 2) AgentInputTargetProof.UNPROVEN else AgentInputTargetProof.PROVEN })
        val settled = aged.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.Attempted
        assertEquals(2, settled.attempts)
        assertEquals(listOf("prove", "inspect", "prove", "prove", "inspect", "write", "submit"), aged.events)
        assertEquals(1, aged.writes.size)
    }

    @Test fun aTargetNeverProvenIsInputNotReadyAfterTheWindowWithoutAnyWrite() = runBlocking {
        val port = FakePort(captures = { Capture(Assessment.RETURN) }, proof = { AgentInputTargetProof.UNPROVEN })
        val latch = AgentTerminalWriteLatch()
        val result = port.deliver(latch) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, result.reason)
        assertEquals(AgentInputSurfaceSample.TargetUnproven, result.last)
        assertEquals(14, result.attempts)
        assertTrue(port.pauses.sum() <= 2_000)
        assertEquals(0, port.inspections)
        assertTrue(port.writes.isEmpty())
        assertEquals(0, port.submits)
        assertFalse(latch.mayHaveWritten)
        assertEquals("target_unproven", agentComposerGuardFields(result.last, result.attempts)["reason"])

        // A missed proof followed by a route that is definitively gone stops
        // at once instead of spending the rest of the window.
        val gone = FakePort(captures = { Capture(Assessment.RETURN) },
            proof = { if (it == 1) AgentInputTargetProof.UNPROVEN else AgentInputTargetProof.GONE })
        val stopped = gone.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.ROUTE_CHANGED, stopped.reason)
        assertEquals(AgentInputSurfaceSample.RouteChanged, stopped.last)
        assertEquals(2, stopped.attempts)
        assertEquals(listOf(150L), gone.pauses)
        assertTrue(gone.writes.isEmpty())

        // A slow probe still cannot start an attempt past the window.
        val slow = FakePort(captures = { Capture(Assessment.RETURN) }, proof = { AgentInputTargetProof.UNPROVEN }, proofMillis = { 900 })
        val slowResult = slow.deliver(AgentTerminalWriteLatch())
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, (slowResult as AgentTextDeliveryResult.NotSent).reason)
        assertEquals(2, slowResult.attempts)
        assertTrue(slow.writes.isEmpty())
    }

    @Test fun unknownEditorsRequireAnAbsentComposer() = runBlocking {
        val ready = FakePort(captures = { Capture(Assessment.ABSENT) })
        assertTrue(ready.deliver(AgentTerminalWriteLatch(), knownEditor = false) is AgentTextDeliveryResult.Attempted)
        val refused = FakePort(captures = { Capture(Assessment.RETURN) })
        val result = refused.deliver(AgentTerminalWriteLatch(), knownEditor = false)
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, (result as AgentTextDeliveryResult.NotSent).reason)
        assertTrue(refused.writes.isEmpty())
    }

    @Test fun backgroundProcessProofIsDefinitiveAndStopsBeforeTheWrite() = runBlocking {
        val failure = AgentEndpointResult.Failed("proof_exit_1", proofReason = "backgroundProcess")
        assertTrue(agentProofFailureIsDefinitive(failure.code, failure.proofReason))
        assertEquals(AgentNotSentReason.ROUTE_CHANGED, agentRouteRefreshFailureReason(failure))
        val proof = agentInputTargetProof(failure, routeCurrent = true, claimedPID = 42,
            provider = AgentProofProvider.CLAUDE, processStart = "fixture-42", inputCapable = true)
        val port = FakePort(captures = { Capture(Assessment.RETURN) }, proof = { proof })
        val latch = AgentTerminalWriteLatch()
        val result = port.deliver(latch) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.ROUTE_CHANGED, result.reason)
        assertEquals(1, result.attempts)
        assertTrue(port.writes.isEmpty())
        assertFalse(latch.mayHaveWritten)
    }

    @Test fun invalidInsertionIsRefusedBeforeTheWrite() = runBlocking {
        val port = FakePort(captures = { Capture(Assessment.RETURN) }, insertion = null)
        val latch = AgentTerminalWriteLatch()
        val result = port.deliver(latch) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.UNSUPPORTED_INPUT, result.reason)
        assertTrue(port.writes.isEmpty())
        assertFalse(latch.mayHaveWritten)
    }

    // D7: a transport that already refuses (another device holds the tmux
    // grid) is asked after the accepted capture and before the latch, so
    // the refusal is provably unsent: Core withdraws the bubble and the
    // draft comes back, as iOS' pre-write `sendRefusal` does.
    @Test fun aTransportRefusalKnownBeforeTheFirstByteIsNotSent() = runBlocking {
        val port = FakePort(captures = { Capture(Assessment.RETURN) }, writeRefusal = AgentNotSentReason.ROUTE_CHANGED)
        val latch = AgentTerminalWriteLatch()
        val result = port.deliver(latch)
        assertEquals(AgentTextDeliveryResult.NotSent(AgentNotSentReason.ROUTE_CHANGED, 1, null), result)
        assertEquals(listOf("prove", "inspect", "refusal"), port.events)
        assertTrue(port.writes.isEmpty())
        assertFalse(latch.mayHaveWritten)
        assertTrue(agentCancellationIsNotSent("send", latch))
    }

    @Test fun cancellationIsNotSentOnlyBeforeTheWriteLatch() = runBlocking {
        // Cancelled while retrying: provably unwritten.
        val waiting = FakePort(captures = { Capture(Assessment.BLOCKED) }, cancelAtActiveCheck = 3)
        val before = AgentTerminalWriteLatch()
        try { waiting.deliver(before); fail("expected cancellation") } catch (_: CancellationException) {}
        assertTrue(waiting.writes.isEmpty())
        assertTrue(agentCancellationIsNotSent("send", before))
        assertTrue(agentCancellationIsNotSent("queue", before))
        assertFalse(agentCancellationIsNotSent("interrupt", before))
        assertFalse(agentCancellationIsNotSent("answerPrompt", before))
        // Cancelled inside the write: ambiguous, keeps the legacy result.
        val writing = FakePort(captures = { Capture(Assessment.RETURN) }, cancelDuringWrite = true)
        val during = AgentTerminalWriteLatch()
        try { writing.deliver(during); fail("expected cancellation") } catch (_: CancellationException) {}
        assertEquals(1, writing.writes.size)
        assertFalse(agentCancellationIsNotSent("send", during))
        assertEquals("cancelled", agentActionResultOutcome("send", "cancelled")!!.getString("status"))
    }

    // (d) Anything at or after the write is ambiguous and keeps failed →
    // unconfirmed, never notSent.
    @Test fun failuresAtOrAfterTheWriteKeepTheAmbiguousResult() = runBlocking {
        for ((writeResult, submitResult, code) in listOf(
            Triple(AgentEndpointResult.Failed("write_failed"), AgentEndpointResult.Success(Unit), "write_failed"),
            Triple(AgentEndpointResult.StaleBinding, AgentEndpointResult.Success(Unit), "staleBinding"),
            Triple(AgentEndpointResult.Success(Unit), AgentEndpointResult.Failed("terminal_input_not_ready"), "terminal_input_not_ready"),
        )) {
            val port = FakePort(captures = { Capture(Assessment.RETURN) }, writeResult = writeResult, submitResult = submitResult)
            val latch = AgentTerminalWriteLatch()
            val result = port.deliver(latch) as AgentTextDeliveryResult.Attempted
            assertTrue(latch.mayHaveWritten)
            assertEquals(1, port.writes.size)
            val finished = result.result
            assertFalse(finished is AgentEndpointResult.Success)
            val resultCode = when (finished) {
                is AgentEndpointResult.Failed -> finished.code
                AgentEndpointResult.StaleBinding -> "staleBinding"
                else -> "unavailable"
            }
            assertEquals(code, resultCode)
            val outcome = agentActionResultOutcome("send", resultCode)!!
            assertEquals(if (code == "staleBinding") "staleBinding" else "failed", outcome.getString("status"))
            assertFalse(outcome.has("verification"))
        }
    }

    // (a) A pre-write refusal forwards notSent and returns the text to an
    // empty composer only.
    @Test fun preWriteRefusalForwardsNotSentForTextActionsOnly() {
        for (action in listOf("send", "queue")) {
            val outcome = agentActionResultOutcome(action, AgentNotSentReason.INPUT_NOT_READY.code, notSent = true)!!
            assertEquals("notSent", outcome.getString("status"))
            assertEquals(action, outcome.getString("action"))
            assertFalse("notSent carries no verification", outcome.has("verification"))
        }
        // Non-text actions never report notSent; their legacy code decides.
        assertEquals("failed", agentActionResultOutcome("interrupt", "verificationFailed", notSent = true)!!.getString("status"))
        assertEquals("cancelled", agentActionResultOutcome("answerPrompt", "cancelled", notSent = true)!!.getString("status"))
        assertEquals("failed", agentActionResultOutcome("send", "terminal_input_not_ready")!!.getString("status"))
        val verified = agentActionResultOutcome("send", "success")!!
        assertEquals("verified", verified.getString("status"))
        assertEquals("fresh-terminal-postcondition", verified.getString("verification"))
        assertNull(agentActionResultOutcome("unknown", "success"))
    }

    @Test fun unsentMessageReturnsToTheComposerAheadOfNewerText() {
        val empty = AgentCenterUiState(drafts = mapOf("other" to "keep me"))
            .withUnsentMessage("thread", "hello Claude", AgentNotSentReason.INPUT_NOT_READY, "Claude")
        assertEquals("hello Claude", empty.drafts["thread"])
        assertEquals("keep me", empty.drafts["other"])
        assertEquals("Not sent — Claude's input wasn't ready. Nothing was typed; your message is back in the box.", empty.notice)

        // A whitespace-only box counts as empty.
        for (blank in listOf("", " ", "\n\t ")) {
            val cleared = AgentCenterUiState(drafts = mapOf("thread" to blank))
                .withUnsentMessage("thread", "hello", AgentNotSentReason.ROUTE_CHANGED, "Codex")
            assertEquals("hello", cleared.drafts["thread"])
            assertEquals("Not sent — the terminal changed. Nothing was typed; your message is back in the box.", cleared.notice)
        }

        // Newer text is never replaced: the message goes back in front of it.
        val merged = AgentCenterUiState(drafts = mapOf("thread" to "newer text", "other" to "keep me"))
            .withUnsentMessage("thread", "hello", AgentNotSentReason.TERMINAL_DRAFT, "Claude")
        assertEquals("hello\n\nnewer text", merged.drafts["thread"])
        assertEquals("keep me", merged.drafts["other"])
        assertEquals("Not sent — the terminal already has unsent text in Claude's prompt. " +
            "Nothing was typed; your message is back in the box above what you typed since.", merged.notice)
        // Newer text keeps its own spacing; only the separator is added.
        assertEquals("line one\nline two\n\n  indented\n" to AgentUnsentDraft.MERGED,
            agentDraftWithUnsentMessage("  indented\n", "line one\nline two"))
        // Text that merely contains the message is still newer text.
        assertEquals("hello\n\nhello again" to AgentUnsentDraft.MERGED, agentDraftWithUnsentMessage("hello again", "hello"))
        assertEquals("hello" to AgentUnsentDraft.RESTORED, agentDraftWithUnsentMessage(" ", "hello"))

        val same = AgentCenterUiState(drafts = mapOf("thread" to "hello"))
            .withUnsentMessage("thread", "hello", AgentNotSentReason.TERMINAL_DRAFT, "Claude")
        assertEquals("hello", same.drafts["thread"])
        assertEquals("Not sent — the terminal already has unsent text in Claude's prompt. " +
            "Nothing was typed; your message is back in the box.", same.notice)

        val noText = AgentCenterUiState().withUnsentMessage("thread", null, AgentNotSentReason.CANCELLED, null)
        assertNull(noText.drafts["thread"])
        assertEquals("Not sent — the send was cancelled. Nothing was typed.", noText.notice)
    }

    @Test fun noticeUsesTheProviderShortName() {
        assertEquals("Claude", agentNoticeProviderName("claude", "Claude Code"))
        assertEquals("Codex", agentNoticeProviderName("codex", "Codex"))
        assertEquals("OpenCode", agentNoticeProviderName("opencode", "OpenCode"))
        assertNull(agentNoticeProviderName("pi", "unknown"))
        assertEquals("Not sent — Codex's input wasn't ready. Nothing was typed; your message is back in the box.",
            agentNotSentNotice(AgentNotSentReason.INPUT_NOT_READY, "Codex", AgentUnsentDraft.RESTORED))
        assertEquals("Not sent — the agent's input wasn't ready. Nothing was typed; your message is back in the box.",
            agentNotSentNotice(AgentNotSentReason.INPUT_NOT_READY, null, AgentUnsentDraft.RESTORED))
        assertEquals("Not sent — an unexpected error stopped the send. Nothing was typed.",
            agentNotSentNotice(AgentNotSentReason.UNEXPECTED, "Claude", AgentUnsentDraft.NONE))
        for (reason in AgentNotSentReason.entries) {
            for (draft in AgentUnsentDraft.entries) {
                val notice = agentNotSentNotice(reason, "Claude", draft)
                assertTrue(notice, notice.startsWith("Not sent — ") && "Nothing was typed" in notice)
                assertFalse(notice, "wasn't put back" in notice)
            }
        }
    }

    // A notSent result that cannot reach Core leaves Core's bubble in place,
    // so the refusal falls back to the legacy ambiguous result, no draft.
    @Test fun unforwardedNotSentFallsBackToTheLegacyAmbiguousResult() {
        assertEquals(AgentNotSentFinish.Forwarded, agentNotSentFinish(resultForwarded = true, legacyCode = "staleBinding"))
        for (legacy in listOf("staleBinding", "terminal_input_not_ready", "cancelled", "failed")) {
            val finish = agentNotSentFinish(resultForwarded = false, legacyCode = legacy)
            assertEquals(AgentNotSentFinish.Ambiguous(legacy), finish)
            // The legacy code maps to the same ambiguous wire status as before notSent.
            val status = agentActionResultOutcome("send", (finish as AgentNotSentFinish.Ambiguous).legacyCode)!!.getString("status")
            assertTrue(status, status in setOf("staleBinding", "failed", "cancelled"))
        }

        val fallback = agentNotSentDiagnosticFields("send", AgentNotSentReason.ROUTE_CHANGED, 3,
            agentNotSentFinish(resultForwarded = false, legacyCode = "staleBinding"))
        assertEquals(mapOf("action" to "send", "reason" to "routeChanged", "written" to "false", "resultForwarded" to "false",
            "fallback" to "ambiguous", "legacyResult" to "staleBinding", "attempts" to "3"), fallback)
        val delivered = agentNotSentDiagnosticFields("queue", AgentNotSentReason.CANCELLED, null, AgentNotSentFinish.Forwarded)
        assertEquals(mapOf("action" to "queue", "reason" to "cancelled", "written" to "false", "resultForwarded" to "true",
            "fallback" to "none"), delivered)
    }

    // A throw inside the action job must still finish the lease: notSent only
    // for a text action whose write never began, otherwise `failed`.
    @Test fun anUnexpectedThrowFinishesTheActionByTheWriteLatch() {
        for (action in listOf("send", "queue")) {
            val before = AgentTerminalWriteLatch()
            assertEquals(AgentAbortedActionFinish(AgentNotSentReason.UNEXPECTED, "failed"),
                agentAbortedActionFinish(action, before, cancelled = false))
            assertEquals(AgentAbortedActionFinish(AgentNotSentReason.CANCELLED, "cancelled"),
                agentAbortedActionFinish(action, before, cancelled = true))
            val after = AgentTerminalWriteLatch().apply { markWriting() }
            assertEquals(AgentAbortedActionFinish(null, "failed"), agentAbortedActionFinish(action, after, cancelled = false))
            assertEquals(AgentAbortedActionFinish(null, "cancelled"), agentAbortedActionFinish(action, after, cancelled = true))
        }
        for (action in listOf("interrupt", "answerPrompt", "openTerminal")) {
            assertEquals(AgentAbortedActionFinish(null, "failed"),
                agentAbortedActionFinish(action, AgentTerminalWriteLatch(), cancelled = false))
            assertEquals(AgentAbortedActionFinish(null, "cancelled"),
                agentAbortedActionFinish(action, AgentTerminalWriteLatch(), cancelled = true))
        }
        assertEquals("failed", agentActionResultOutcome("send", "failed")!!.getString("status"))
        assertEquals("notSent", agentActionResultOutcome("send", AgentNotSentReason.UNEXPECTED.code, notSent = true)!!.getString("status"))
    }

    @Test fun guardDiagnosticsAreContentFreeAndRecordAttempts() {
        val binding = AgentEndpointBinding(AgentSessionKey("carrier", 1), "host", AgentEndpointTransport.MOSH_TMUX)
        val secret = "❯ deploy with api-key-secret\n/Users/private/project\n────"
        val observation = AgentTerminalObservation(binding, secret.encodeToByteArray(), truncated = false, authoritative = true,
            currentCursorLine = "❯ deploy with api-key-secret", cursorRow = 0, cursorVisible = false, cursorColumn = 30)
        val fields = agentComposerGuardFields(AgentInputSurfaceSample.Observed(observation, Assessment.OCCUPIED), attempts = 14)
        assertEquals("before_insert", fields["stage"])
        assertEquals("occupied", fields["reason"])
        assertEquals("14", fields["attempts"])
        assertEquals("false", fields["written"])
        assertEquals("3", fields["capturedRows"])
        assertEquals("false", fields["cursorVisible"])
        for (value in fields.values) {
            assertFalse(value, "secret" in value || "/Users" in value || "deploy" in value)
        }
        assertEquals("capture_unavailable", agentComposerGuardFields(AgentInputSurfaceSample.CaptureUnavailable, 2)["reason"])
        for (reason in AgentNotSentReason.entries) {
            assertTrue(reason.code.all { it.isLetter() })
        }
    }

    // A read cancelled by something other than this action (a nested
    // timeout, a closed ingestion connection) is a probe that missed: it is
    // retried within the window, never reported as the user's cancel.
    @Test fun foreignCancellationsInsideReadsAreRetriedLikeMissedProbes() = runBlocking {
        val proofClosed = FakePort(captures = { Capture(Assessment.RETURN) }, readThrows = { read, n ->
            if (read == "prove" && n == 1) throw CancellationException("ingestion connection closed")
        })
        val latch = AgentTerminalWriteLatch()
        val proved = proofClosed.deliver(latch) as AgentTextDeliveryResult.Attempted
        assertEquals(AgentEndpointResult.Success(Unit), proved.result)
        assertEquals(2, proved.attempts)
        assertEquals(listOf(150L), proofClosed.pauses)
        assertEquals(1, proofClosed.writes.size)
        assertTrue(latch.mayHaveWritten)

        // A genuine TimeoutCancellationException from a nested withTimeout.
        var timedOut: Throwable? = null
        val nested = FakePort(captures = { Capture(Assessment.RETURN) }, readThrows = { read, n ->
            if (read == "inspect" && n == 1) {
                try { withTimeout(1) { awaitCancellation() } } catch (failure: TimeoutCancellationException) { timedOut = failure; throw failure }
            }
        })
        val captured = nested.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.Attempted
        assertTrue(timedOut is TimeoutCancellationException)
        assertEquals(2, captured.attempts)
        assertEquals(1, nested.writes.size)

        // Foreign cancellations throughout end as a refusal, not a throw.
        val always = FakePort(captures = { Capture(Assessment.RETURN) }, readThrows = { read, _ ->
            if (read == "prove") throw CancellationException("exec stream cancelled")
        })
        val refused = always.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        // Never proved either way: the input was not ready, not a changed route.
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, refused.reason)
        assertEquals(AgentInputSurfaceSample.TargetUnproven, refused.last)
        assertTrue(always.writes.isEmpty())
        val noCapture = FakePort(captures = { Capture(Assessment.RETURN) }, readThrows = { read, _ ->
            if (read == "inspect") throw CancellationException("capture cancelled")
        })
        val unavailable = noCapture.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, unavailable.reason)
        assertEquals(AgentInputSurfaceSample.CaptureUnavailable, unavailable.last)
    }

    @Test fun theActionsOwnCancellationOrLifetimeEndStillPropagates() = runBlocking {
        // The job itself is cancelled while a probe is suspended.
        val probing = CompletableDeferred<Unit>()
        val port = FakePort(captures = { Capture(Assessment.RETURN) }, readThrows = { read, _ ->
            if (read == "prove") { probing.complete(Unit); awaitCancellation() }
        })
        var thrown: Throwable? = null
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            try { port.deliver(AgentTerminalWriteLatch()) } catch (failure: CancellationException) { thrown = failure; throw failure }
        }
        probing.await()
        job.cancel()
        job.join()
        assertTrue(job.isCancelled)
        assertTrue(thrown is CancellationException)
        assertEquals(1, port.proofs)
        assertTrue(port.writes.isEmpty())

        // The action's lifetime ended (disabled) while the job is still active.
        val ended = FakePort(captures = { Capture(Assessment.RETURN) }, cancelAtActiveCheck = 2, readThrows = { read, _ ->
            if (read == "prove") throw CancellationException("route closed during disable")
        })
        try { ended.deliver(AgentTerminalWriteLatch()); fail("expected cancellation") }
        catch (failure: CancellationException) { assertEquals("Agent action no longer active", failure.message) }
        assertTrue(ended.writes.isEmpty())
    }

    @Test fun onlyTheJobsOwnCancellationIsACancelledSend() {
        assertTrue(agentThrowIsCancellation(CancellationException("job"), jobActive = false))
        assertFalse(agentThrowIsCancellation(CancellationException("nested timeout"), jobActive = true))
        assertFalse(agentThrowIsCancellation(IllegalStateException("decode"), jobActive = false))
        assertFalse(agentThrowIsCancellation(IllegalStateException("decode"), jobActive = true))
    }

    @Test fun anEndedActionJobAlwaysFinishesAndNeverSwallowsTheWrongThrow() {
        data class Ended(val finished: List<Boolean>, val unexpected: List<Throwable>, val finishFailures: List<Throwable>, val thrown: Throwable?)
        fun end(failure: Throwable, active: Boolean, finishThrows: Throwable? = null): Ended {
            val finished = mutableListOf<Boolean>()
            val unexpected = mutableListOf<Throwable>()
            val finishFailures = mutableListOf<Throwable>()
            val thrown = runCatching {
                agentEndActionJob(failure, active, { cancelled -> finished += cancelled; finishThrows?.let { throw it } },
                    onUnexpected = { unexpected += it }, onFinishFailure = { finishFailures += it })
            }.exceptionOrNull()
            return Ended(finished, unexpected, finishFailures, thrown)
        }
        // The job's own cancellation: cancelled, rethrown as itself, even
        // when finishing throws.
        val own = CancellationException("job")
        assertEquals(Ended(listOf(true), emptyList(), emptyList(), own), end(own, active = false))
        val finishBroke = IllegalStateException("finish")
        val guarded = end(own, active = false, finishThrows = finishBroke)
        assertSame(own, guarded.thrown)
        assertEquals(listOf(finishBroke), guarded.finishFailures)
        // A foreign cancellation or an ordinary throw is unexpected and ends quietly.
        val foreign = CancellationException("nested timeout")
        assertEquals(Ended(listOf(false), listOf(foreign), emptyList(), null), end(foreign, active = true))
        val decode = IllegalStateException("decode")
        assertEquals(Ended(listOf(false), listOf(decode), emptyList(), null), end(decode, active = true))
        assertNull(end(decode, active = true, finishThrows = finishBroke).thrown)
        // An Error still finishes the lease first, then is rethrown.
        for (error in listOf(StackOverflowError(), OutOfMemoryError(), NoClassDefFoundError("x"))) {
            val ended = end(error, active = true)
            assertEquals(listOf(false), ended.finished)
            assertSame(error, ended.thrown)
            assertSame(error, end(error, active = true, finishThrows = finishBroke).thrown)
        }
        // An Error thrown while finishing is not swallowed either.
        val finishError = StackOverflowError()
        assertSame(finishError, end(decode, active = true, finishThrows = finishError).thrown)
        assertSame(own, end(own, active = false, finishThrows = finishError).thrown)
    }

    // The lease is held before the write for at most the deadline: every
    // probe and capture gets only what remains of it, and none starts after.
    @Test fun everyReadIsBoundedByTheRemainingDeadline() = runBlocking {
        val policy = AgentSendPreflightPolicy()
        // A probe that hangs is cut off at the deadline.
        val hung = FakePort(captures = { Capture(Assessment.RETURN) }, proofMillis = { 60_000 })
        val hungResult = hung.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, hungResult.reason)
        assertEquals(1, hungResult.attempts)
        assertEquals(listOf("prove" to policy.deadlineMillis), hung.budgets)
        assertEquals(policy.deadlineMillis, hung.nowNanos / 1_000_000)

        // Reads in one attempt share the deadline.
        val slow = FakePort(captures = { Capture(Assessment.RETURN, inspectMillis = 60_000) }, proofMillis = { 3_000 })
        val slowResult = slow.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentNotSentReason.INPUT_NOT_READY, slowResult.reason)
        assertEquals(listOf("prove" to 5_000L, "inspect" to 2_000L), slow.budgets)
        assertEquals(policy.deadlineMillis, slow.nowNanos / 1_000_000)
        assertTrue(slow.writes.isEmpty())

        // A spent deadline starts no further read.
        val spent = FakePort(captures = { Capture(Assessment.RETURN) }, proofMillis = { policy.deadlineMillis })
        val spentResult = spent.deliver(AgentTerminalWriteLatch()) as AgentTextDeliveryResult.NotSent
        assertEquals(AgentInputSurfaceSample.CaptureUnavailable, spentResult.last)
        assertEquals(0, spent.inspections)

        // Across retries and frame waits, no read outlives the deadline.
        val frames = FakePort(captures = { Capture(Assessment.BLOCKED, waitedForFrame = it % 2 == 1, inspectMillis = 120) },
            proofMillis = { 90 })
        assertTrue(frames.deliver(AgentTerminalWriteLatch()) is AgentTextDeliveryResult.NotSent)
        assertTrue(frames.budgets.size > 4)
        for ((_, budget) in frames.budgets) assertTrue(budget in 1..policy.deadlineMillis)
        assertTrue(frames.nowNanos / 1_000_000 <= policy.deadlineMillis)
    }

    // A definitive proof answer is final; only a timeout or a transport
    // failure is retried.
    @Test fun definitiveProofFailuresAreGoneAndOnlyMissedProbesAreUnproven() {
        val provider = AgentProofProvider.CLAUDE
        fun classify(result: AgentEndpointResult<AgentProcessProof>?, routeCurrent: Boolean = true, inputCapable: Boolean = true) =
            agentInputTargetProof(result, routeCurrent, claimedPID = 42, provider = provider, processStart = "start-1", inputCapable = inputCapable)
        val proven = AgentEndpointResult.Success(AgentProcessProof(setOf(7, 42), provider, "start-1"))
        assertEquals(AgentInputTargetProof.PROVEN, classify(proven))
        assertEquals(AgentInputTargetProof.UNPROVEN, classify(proven, inputCapable = false))
        assertEquals(AgentInputTargetProof.GONE, classify(proven, routeCurrent = false))
        assertEquals(AgentInputTargetProof.GONE, classify(AgentEndpointResult.StaleBinding))
        assertEquals(AgentInputTargetProof.GONE, classify(AgentEndpointResult.Success(AgentProcessProof(setOf(7), provider, "start-1"))))
        assertEquals(AgentInputTargetProof.GONE, classify(AgentEndpointResult.Success(AgentProcessProof(setOf(42), AgentProofProvider.CODEX, "start-1"))))
        assertEquals(AgentInputTargetProof.GONE, classify(AgentEndpointResult.Success(AgentProcessProof(setOf(42), provider, "start-2"))))
        for (code in listOf("proof_pid_unlisted=42/[7]", "proof_not_valid", "proof_provider=codex/claude", "invalid_process")) {
            assertTrue(code, agentProofFailureIsDefinitive(code))
            assertEquals(code, AgentInputTargetProof.GONE, classify(AgentEndpointResult.Failed(code)))
        }
        assertEquals(AgentInputTargetProof.UNPROVEN, classify(null))
        for (code in listOf("exec_unavailable:timeout", "tmux_process_unavailable", "proof_exit_1", "proof_threw:JSONException",
            "proof_version=2", "proof_no_process_ids", "proof_no_process_start")) {
            assertFalse(code, agentProofFailureIsDefinitive(code))
            assertEquals(code, AgentInputTargetProof.UNPROVEN, classify(AgentEndpointResult.Failed(code)))
        }
        assertEquals(AgentInputTargetProof.UNPROVEN, classify(AgentEndpointResult.Unavailable("mosh process root is unavailable")))
    }

    private fun observation(tail: String) = AgentTerminalObservation(
        AgentEndpointBinding(AgentSessionKey("carrier", 1), "host", AgentEndpointTransport.SSH_TMUX, tmuxSession = "s", windowID = "@1", paneID = "%1"),
        tail.encodeToByteArray(), truncated = false, authoritative = true, currentCursorLine = null)

    // An interrupt is judged against a baseline with text: a blank frame is
    // re-read within the readiness window, and none in time means no Escape.
    @Test fun anInterruptBaselineIsReReadUntilItHasText() = runBlocking {
        val policy = AgentSendPreflightPolicy()
        var now = 0L
        val pauses = mutableListOf<Long>()
        val budgets = mutableListOf<Long>()
        suspend fun baseline(readMillis: Long = 0, capture: (Int) -> AgentTerminalObservation?): AgentTerminalObservation? {
            now = 0; pauses.clear(); budgets.clear()
            return agentSettledBaseline(policy, nanoTime = { now * 1_000_000 }, pause = { pauses += it; now += it }) { budget ->
                budgets += budget
                now += minOf(readMillis, budget)
                // A read slower than its budget times out: nothing captured.
                if (readMillis > budget) null else capture(budgets.size)
            }
        }
        val working = observation("• Working (3s · esc to interrupt)\n❯ ")
        val settled = baseline { if (it < 3) observation(if (it == 1) "" else "\n  \n") else working }
        assertSame(working, settled)
        assertEquals(listOf(150L, 150L), pauses)

        // Blank throughout: nothing to judge Escape by, so no baseline.
        assertNull(baseline { observation("\n\n") })
        assertEquals((policy.windowMillis / policy.intervalMillis).toInt(), pauses.size)
        assertTrue(now <= policy.windowMillis)
        assertNull(baseline { null })

        // Slow reads share the deadline; none starts after it.
        assertNull(baseline(readMillis = 1_800) { observation("") })
        assertEquals(listOf(5_000L, 3_050L), budgets)
        assertNull(baseline(readMillis = 60_000) { working })
        assertEquals(listOf(5_000L), budgets)
    }

    // A verification wait whose every read stalls (an unanswered tmux ack
    // now fails only after 15 s) still ends at its budget, as a failed
    // verification rather than a cancellation.
    @Test fun postWriteVerificationIsBoundedInTimeNotJustInCount() = runBlocking {
        var attempts = 0
        val started = System.nanoTime()
        val stalled = agentBoundedPoll<String>(attempts = 3, intervalMillis = 1, budgetMillis = 200) {
            attempts++
            kotlinx.coroutines.delay(1_500)
            AgentPoll.Again
        }
        assertNull(stalled)
        assertEquals(1, attempts)
        assertTrue((System.nanoTime() - started) / 1_000_000 < 1_400)

        attempts = 0
        assertNull(agentBoundedPoll<String>(attempts = 20, intervalMillis = 1, budgetMillis = 60_000) { attempts++; AgentPoll.Again })
        assertEquals(20, attempts)
        attempts = 0
        assertEquals("seen", agentBoundedPoll(attempts = 20, intervalMillis = 1, budgetMillis = 60_000) {
            if (++attempts == 3) AgentPoll.Found("seen") else AgentPoll.Again
        })
        attempts = 0
        assertNull(agentBoundedPoll<String>(attempts = 20, intervalMillis = 1, budgetMillis = 60_000) { attempts++; AgentPoll.GiveUp })
        assertEquals(1, attempts)

        // The end of the action's lifetime is not swallowed as a timeout.
        try {
            agentBoundedPoll<String>(budgetMillis = 60_000) { throw CancellationException("Agent action no longer active") }
            fail("expected the lifetime to end the wait")
        } catch (failure: CancellationException) { assertEquals("Agent action no longer active", failure.message) }

        // Nor is the job's own cancellation.
        val reading = CompletableDeferred<Unit>()
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            agentBoundedPoll<String>(budgetMillis = 60_000) { reading.complete(Unit); awaitCancellation() }
            fail("a cancelled job must not resume")
        }
        reading.await()
        job.cancel()
        job.join()
        assertTrue(job.isCancelled)
    }

    // An optional read (the receipt frontier) treats a foreign cancellation
    // as unavailable; only the action's own cancellation propagates.
    @Test fun anOptionalReadSurvivesForeignCancellation() = runBlocking {
        val failures = mutableListOf<Throwable>()
        val foreign = CancellationException("ingestion connection closed")
        assertEquals("unavailable", agentOptionalRead({ failures += it; "unavailable" }) { throw foreign })
        assertEquals(listOf<Throwable>(foreign), failures)
        assertEquals("unavailable", agentOptionalRead({ "unavailable" }) { throw IllegalStateException("staleBinding") })
        assertEquals("frontier", agentOptionalRead({ "unavailable" }) { "frontier" })

        val reading = CompletableDeferred<Unit>()
        var fellBack = false
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            agentOptionalRead({ fellBack = true; "unavailable" }) { reading.complete(Unit); awaitCancellation() }
            fail("a cancelled job must not resume")
        }
        reading.await()
        job.cancel()
        job.join()
        assertTrue(job.isCancelled)
        assertFalse(fellBack)
    }
}
