package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentProcessProof
import com.bambouville.tessera.agent.platform.AgentProofProvider
import com.bambouville.tessera.agent.platform.AgentSemanticKey
import com.bambouville.tessera.agent.platform.AgentSessionEndpoint
import com.bambouville.tessera.agent.platform.AgentTerminalObservation
import com.bambouville.tessera.core.bridge.SharedAgentComposerEvidence.Assessment
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject

/** The only actions whose refusal can return a message to the composer. */
internal val AGENT_TEXT_ACTIONS = setOf("send", "queue")

/**
 * Why a send/queue finished before any byte could reach the terminal. The
 * codes are content-free and appear only in local diagnostics; the wire
 * carries the single shared status `notSent`.
 */
internal enum class AgentNotSentReason(val code: String) {
    /** The pane, carrier or agent process is no longer the leased target. */
    ROUTE_CHANGED("routeChanged"),
    /** The agent's input never settled (a dialog, a redraw, no capture). */
    INPUT_NOT_READY("inputNotReady"),
    /** The terminal's own composer already holds unsent text. */
    TERMINAL_DRAFT("terminalDraft"),
    /** The endpoint cannot perform verified input at all. */
    INPUT_UNAVAILABLE("inputUnavailable"),
    /** The text cannot be expressed as one guarded insertion. */
    UNSUPPORTED_INPUT("unsupportedInput"),
    /** Core's plan no longer matches what the composer asked for. */
    PLAN_MISMATCH("planMismatch"),
    /** The receipt baseline could not be armed before the write. */
    RECEIPT_UNAVAILABLE("receiptUnavailable"),
    CANCELLED("cancelled"),
    /** The action job threw before the write (a decode or read failure). */
    UNEXPECTED("unexpected"),
}

/**
 * One pre-write proof that the leased route and agent process are still the
 * input target. A probe that merely missed is transient, like a torn capture;
 * a route or process that is definitively gone is final.
 */
internal enum class AgentInputTargetProof {
    PROVEN,
    /** The probe timed out or could not run; retried within the window. */
    UNPROVEN,
    /** The route is no longer current, or another process owns the pane. */
    GONE,
}

/**
 * Endpoint proof failures that answer the question rather than miss it: the
 * leased PID is not listed, the prover judged the process invalid, or another
 * provider owns it. A retry cannot change that answer. Everything else (a
 * timeout, an exec or tmux failure, a malformed reply) merely missed.
 */
internal fun agentProofFailureIsDefinitive(code: String, proofReason: String? = null): Boolean =
    proofReason in setOf("invalidProcess", "unrelatedProcess", "providerMismatch", "backgroundProcess") ||
        code == "invalid_process" || (code == "proof_not_valid" && proofReason == null) ||
        code.startsWith("proof_pid_unlisted") || code.startsWith("proof_provider=")

/** A missed authority refresh does not prove that the terminal changed. */
internal fun agentRouteRefreshFailureReason(result: AgentEndpointResult<*>): AgentNotSentReason = when (result) {
    is AgentEndpointResult.Failed -> when {
        result.code == "staleBinding" || agentProofFailureIsDefinitive(result.code, result.proofReason) -> AgentNotSentReason.ROUTE_CHANGED
        result.code in setOf("invalid_provider", "platform_proof_rejected", "platform_binding_rejected", "raw_input_unavailable") ||
            result.proofReason in setOf("unsupported", "adapterOutdated", "invalidProvider", "invalidRoot", "invalidMarker", "malformed") ->
            AgentNotSentReason.INPUT_UNAVAILABLE
        else -> AgentNotSentReason.INPUT_NOT_READY
    }
    is AgentEndpointResult.Unavailable -> AgentNotSentReason.INPUT_UNAVAILABLE
    else -> AgentNotSentReason.ROUTE_CHANGED
}

/**
 * One process proof of the leased target. [result] is null when the probe
 * timed out. Only a timeout or transport failure is [AgentInputTargetProof.UNPROVEN];
 * a changed route, a stale binding or a definitive answer naming another
 * process is [AgentInputTargetProof.GONE].
 */
internal fun agentInputTargetProof(
    result: AgentEndpointResult<AgentProcessProof>?,
    routeCurrent: Boolean,
    claimedPID: Int,
    provider: AgentProofProvider,
    processStart: String,
    inputCapable: Boolean,
): AgentInputTargetProof {
    if (!routeCurrent || result == AgentEndpointResult.StaleBinding) return AgentInputTargetProof.GONE
    if (result is AgentEndpointResult.Failed && agentProofFailureIsDefinitive(result.code, result.proofReason)) return AgentInputTargetProof.GONE
    val proof = (result as? AgentEndpointResult.Success)?.value ?: return AgentInputTargetProof.UNPROVEN
    if (proof.provider != provider || claimedPID !in proof.processIDs || proof.processStart != processStart) {
        return AgentInputTargetProof.GONE
    }
    return if (inputCapable) AgentInputTargetProof.PROVEN else AgentInputTargetProof.UNPROVEN
}

/**
 * Only the action job's own cancellation is a cancelled send. A
 * CancellationException that leaves the job active came from inside a read
 * (a nested timeout, a closed connection, a cancelled exec stream).
 */
internal fun agentThrowIsCancellation(failure: Throwable, jobActive: Boolean): Boolean =
    failure is CancellationException && !jobActive

/**
 * Ends an action job that [failure] escaped. The lease is always finished
 * first, as cancelled only for the job's own cancellation (then rethrown); a
 * foreign cancellation or any other throw is unexpected. A throw inside
 * [finish] is reported and can never replace [failure], and an Error (OOM,
 * stack overflow, linkage) is never swallowed.
 */
internal fun agentEndActionJob(
    failure: Throwable,
    jobActive: Boolean,
    finish: (cancelled: Boolean) -> Unit,
    onUnexpected: (Throwable) -> Unit,
    onFinishFailure: (Throwable) -> Unit,
) {
    val cancelled = agentThrowIsCancellation(failure, jobActive)
    if (!cancelled) runCatching { onUnexpected(failure) }
    val finishFailure = try { finish(cancelled); null } catch (thrown: Throwable) { thrown }
    finishFailure?.let { runCatching { onFinishFailure(it) } }
    if (cancelled || failure is Error) throw failure
    if (finishFailure is Error) throw finishFailure
}

/**
 * Latched before a terminal write. Only the transport's explicit non-admission
 * can undo that attempt; an earlier write remains ambiguous.
 */
internal class AgentTerminalWriteLatch {
    @Volatile var mayHaveWritten: Boolean = false
        private set

    fun markWriting() { mayHaveWritten = true }

    suspend fun attempt(write: suspend () -> AgentEndpointResult<Unit>): AgentEndpointResult<Unit> {
        val alreadyWritten = mayHaveWritten
        markWriting()
        return write().also { if (it is AgentEndpointResult.Failed && it.inputNotAdmitted) mayHaveWritten = alreadyWritten }
    }
}

/**
 * Bounded re-inspection before refusing a send. Claude Code repaints its
 * whole frame while an animated panel is visible; one capture can land
 * mid-paint (cursor hidden, composer half drawn, cursor moved between reads).
 * Attempts start only within [windowMillis]; every probe and capture is
 * bounded by what remains of [deadlineMillis], so the lease is held before
 * the write for at most that long, however slow the reads.
 */
internal data class AgentSendPreflightPolicy(
    val intervalMillis: Long = 150,
    val windowMillis: Long = 2_000,
    val deadlineMillis: Long = 5_000,
)

internal data class AgentRouteBindingRefresh<T>(
    val result: AgentEndpointResult<T>,
    val attempts: Int,
    val elapsedMillis: Long,
) {
    fun remainingPolicy(policy: AgentSendPreflightPolicy) = policy.copy(
        windowMillis = (policy.windowMillis - elapsedMillis).coerceAtLeast(0),
        deadlineMillis = (policy.deadlineMillis - elapsedMillis).coerceAtLeast(0),
    )
}

/** Initial authority misses consume the same bounded preflight allowance as later reads. */
internal suspend fun <T> retryAgentRouteBinding(
    policy: AgentSendPreflightPolicy = AgentSendPreflightPolicy(),
    nanoTime: () -> Long = System::nanoTime,
    pause: suspend (Long) -> Unit = { delay(it) },
    issue: suspend () -> AgentEndpointResult<T>,
): AgentRouteBindingRefresh<T> {
    val started = nanoTime()
    fun elapsedMillis() = (nanoTime() - started) / 1_000_000
    var attempts = 0
    while (true) {
        val budget = policy.deadlineMillis - elapsedMillis()
        val result: AgentEndpointResult<T> = if (budget <= 0) AgentEndpointResult.Failed("proof_timeout") else {
            attempts++
            try { withTimeoutOrNull(budget) { issue() } ?: AgentEndpointResult.Failed("proof_timeout") }
            catch (cancelled: CancellationException) {
                if (agentThrowIsCancellation(cancelled, currentCoroutineContext().isActive)) throw cancelled
                AgentEndpointResult.Failed("proof_read_failed")
            }
        }
        if (result is AgentEndpointResult.Success || agentRouteRefreshFailureReason(result) != AgentNotSentReason.INPUT_NOT_READY ||
            elapsedMillis() + policy.intervalMillis > policy.windowMillis || elapsedMillis() >= policy.deadlineMillis) {
            return AgentRouteBindingRefresh(result, attempts, elapsedMillis())
        }
        pause(policy.intervalMillis)
    }
}

internal suspend fun sendAgentPromptStep(
    endpoint: AgentSessionEndpoint,
    binding: AgentEndpointBinding,
    bytes: String,
    semanticKey: String?,
): AgentEndpointResult<Unit> {
    if (semanticKey != null && binding.transport in setOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
        val key = AgentSemanticKey.fromTmuxName(semanticKey) ?: return AgentEndpointResult.Failed("invalid_semantic_key", inputNotAdmitted = true)
        return endpoint.sendSemanticKey(binding, key)
    }
    return endpoint.sendInput(binding, bytes.encodeToByteArray())
}

/** One pre-write look at the agent's input surface. */
internal sealed interface AgentInputSurfaceSample {
    /** Not transient: the leased route/process is no longer the input target. */
    data object RouteChanged : AgentInputSurfaceSample
    /** Transient: this attempt's process/route proof missed. */
    data object TargetUnproven : AgentInputSurfaceSample
    /** Capture failed, or only a frame-waited (aged) capture was available. */
    data object CaptureUnavailable : AgentInputSurfaceSample
    data class Observed(val observation: AgentTerminalObservation, val assessment: Assessment) : AgentInputSurfaceSample
}

/**
 * Platform side of one guarded text delivery. Every suspending read rechecks
 * the action lifetime through [ensureActive].
 */
internal interface AgentTextDeliveryPort {
    /** Throws CancellationException once the action is no longer active. */
    suspend fun ensureActive()
    /**
     * [AgentInputTargetProof.PROVEN] when the route is current and a fresh
     * process proof names the leased agent; UNPROVEN when the probe does not
     * finish within [timeoutMillis].
     */
    suspend fun proveInputTarget(timeoutMillis: Long): AgentInputTargetProof
    /** Null when the endpoint could not capture the pane within [timeoutMillis]. */
    suspend fun inspect(timeoutMillis: Long): AgentTerminalObservation?
    /** Shared composer assessment with `requireEmpty`, from this capture only. */
    fun assessEmptyComposer(observation: AgentTerminalObservation): Assessment
    /** Shared insertion bytes; null when the text cannot be inserted. */
    fun insertion(): ByteArray?
    /**
     * A refusal the transport already knows before the first byte, or null
     * to write. A later failure stays ambiguous unless the transport explicitly
     * proves that none of this call's input was admitted.
     */
    fun writeRefusal(): AgentNotSentReason? = null
    suspend fun write(input: ByteArray): AgentEndpointResult<Unit>
    /** Post-insert composer proof and submit key. Only runs after a write. */
    suspend fun submit(): AgentEndpointResult<Unit>
}

internal sealed interface AgentTextDeliveryResult {
    /** No input was admitted, including an explicit refusal from the writer. */
    data class NotSent(
        val reason: AgentNotSentReason,
        val attempts: Int,
        val last: AgentInputSurfaceSample?,
    ) : AgentTextDeliveryResult

    /** The write was invoked; bytes may have reached the terminal. */
    data class Attempted(val result: AgentEndpointResult<Unit>, val attempts: Int) : AgentTextDeliveryResult
}

/** Known provider editors must show an empty, submit-ready composer. */
internal fun agentInputSurfaceReady(sample: AgentInputSurfaceSample, knownEditor: Boolean): Boolean {
    val observed = sample as? AgentInputSurfaceSample.Observed ?: return false
    if (!observed.observation.authoritative || observed.observation.truncated) return false
    return if (knownEditor) observed.assessment == Assessment.RETURN || observed.assessment == Assessment.TAB
    else observed.assessment == Assessment.ABSENT
}

/**
 * Proves the target, captures, and (after a frame wait) re-proves and accepts
 * only an immediate capture, exactly as a single inspection always did. A
 * proof is never carried across a retry pause: every attempt starts afresh.
 * Each read gets what remains of the deadline ([remainingMillis]); none
 * starts once it has passed.
 */
internal suspend fun sampleAgentInputSurface(
    port: AgentTextDeliveryPort,
    remainingMillis: () -> Long = { Long.MAX_VALUE },
): AgentInputSurfaceSample {
    fun unproven(proof: AgentInputTargetProof): AgentInputSurfaceSample? = when (proof) {
        AgentInputTargetProof.PROVEN -> null
        AgentInputTargetProof.UNPROVEN -> AgentInputSurfaceSample.TargetUnproven
        AgentInputTargetProof.GONE -> AgentInputSurfaceSample.RouteChanged
    }
    suspend fun prove(): AgentInputTargetProof {
        val budget = remainingMillis()
        if (budget <= 0) return AgentInputTargetProof.UNPROVEN
        return port.readOrMissed(AgentInputTargetProof.UNPROVEN) { port.proveInputTarget(budget) }
    }
    suspend fun capture(): AgentTerminalObservation? {
        val budget = remainingMillis()
        if (budget <= 0) return null
        return port.readOrMissed(null) { port.inspect(budget) }
    }
    port.ensureActive()
    unproven(prove())?.let { return it }
    var observed = capture() ?: return AgentInputSurfaceSample.CaptureUnavailable
    if (observed.captureWaitedForFrame) {
        // Frame readiness can outlive a process. Refresh authority, then
        // accept only an immediate capture; do not age that proof again.
        unproven(prove())?.let { return it }
        observed = capture() ?: return AgentInputSurfaceSample.CaptureUnavailable
        if (observed.captureWaitedForFrame) return AgentInputSurfaceSample.CaptureUnavailable
    }
    return AgentInputSurfaceSample.Observed(observed, port.assessEmptyComposer(observed))
}

/**
 * A read cancelled while this coroutine is still active was cancelled by
 * something else (a nested timeout, a closed ingestion connection, a
 * cancelled exec stream): a probe that missed, retried like one. The action's
 * own cancellation, or the end of its lifetime, still propagates.
 */
private suspend inline fun <T> AgentTextDeliveryPort.readOrMissed(missed: T, read: () -> T): T = try {
    read()
} catch (cancelled: CancellationException) {
    if (agentThrowIsCancellation(cancelled, currentCoroutineContext().isActive)) throw cancelled
    ensureActive()
    missed
}

/**
 * Pre-write guard plus the single write. Transient input states, including a
 * process/route proof that merely missed, are retried every
 * [AgentSendPreflightPolicy.intervalMillis] until no further attempt fits in
 * [AgentSendPreflightPolicy.windowMillis]; a target still unproven then is
 * input not ready. A route that is definitively gone stops at once. The
 * accepted capture is followed directly by the write, with only
 * lifetime checks, the pure insertion encoding and the transport's own
 * pre-write refusal in between. [latch] flips immediately before the write,
 * so any refusal or cancellation before it is provably unwritten.
 */
internal suspend fun deliverAgentGuardedText(
    port: AgentTextDeliveryPort,
    latch: AgentTerminalWriteLatch,
    knownEditor: Boolean,
    policy: AgentSendPreflightPolicy = AgentSendPreflightPolicy(),
    nanoTime: () -> Long = System::nanoTime,
    pause: suspend (Long) -> Unit = { delay(it) },
    bypassComposerVerification: Boolean = false,
): AgentTextDeliveryResult {
    val started = nanoTime()
    fun elapsedMillis() = (nanoTime() - started) / 1_000_000
    var attempts = 0
    while (true) {
        attempts++
        // Explicit one-shot retries skip only composer recognition. A fresh
        // process/route proof is still required before the same safe insertion.
        val sample = if (bypassComposerVerification) {
            port.ensureActive()
            val budget = policy.deadlineMillis - elapsedMillis()
            val proof = if (budget <= 0) AgentInputTargetProof.UNPROVEN else
                port.readOrMissed(AgentInputTargetProof.UNPROVEN) { port.proveInputTarget(budget) }
            when (proof) {
                AgentInputTargetProof.PROVEN -> null
                AgentInputTargetProof.UNPROVEN -> AgentInputSurfaceSample.TargetUnproven
                AgentInputTargetProof.GONE -> AgentInputSurfaceSample.RouteChanged
            }
        } else sampleAgentInputSurface(port) { policy.deadlineMillis - elapsedMillis() }
        if (sample == AgentInputSurfaceSample.RouteChanged) {
            return AgentTextDeliveryResult.NotSent(AgentNotSentReason.ROUTE_CHANGED, attempts, sample)
        }
        if (sample == null || agentInputSurfaceReady(sample, knownEditor)) break
        if (elapsedMillis() + policy.intervalMillis > policy.windowMillis) {
            val reason = when {
                sample == AgentInputSurfaceSample.TargetUnproven -> AgentNotSentReason.INPUT_NOT_READY
                (sample as? AgentInputSurfaceSample.Observed)?.assessment == Assessment.OCCUPIED -> AgentNotSentReason.TERMINAL_DRAFT
                else -> AgentNotSentReason.INPUT_NOT_READY
            }
            return AgentTextDeliveryResult.NotSent(reason, attempts, sample)
        }
        pause(policy.intervalMillis)
    }
    port.ensureActive()
    val input = port.insertion()
        ?: return AgentTextDeliveryResult.NotSent(AgentNotSentReason.UNSUPPORTED_INPUT, attempts, null)
    port.ensureActive()
    port.writeRefusal()?.let { return AgentTextDeliveryResult.NotSent(it, attempts, null) }
    val inserted = latch.attempt { port.write(input) }
    if (inserted is AgentEndpointResult.Failed && inserted.inputNotAdmitted && !latch.mayHaveWritten) {
        return AgentTextDeliveryResult.NotSent(agentRouteRefreshFailureReason(inserted), attempts, null)
    }
    if (inserted !is AgentEndpointResult.Success) return AgentTextDeliveryResult.Attempted(inserted, attempts)
    return AgentTextDeliveryResult.Attempted(port.submit(), attempts)
}

/** Only a composer/capture refusal proves that an explicit retry may skip recognition. */
internal fun AgentTextDeliveryResult.NotSent.canSkipComposerVerification(provider: String): Boolean =
    provider in setOf("codex", "claude") &&
        reason in setOf(AgentNotSentReason.INPUT_NOT_READY, AgentNotSentReason.TERMINAL_DRAFT) &&
        (last is AgentInputSurfaceSample.Observed || last == AgentInputSurfaceSample.CaptureUnavailable)

/**
 * Content-free layout facts for a refused pre-write sample: counts, cursor
 * cells and flags only, never captured text.
 */
internal fun agentComposerGuardFields(sample: AgentInputSurfaceSample?, attempts: Int): Map<String, String> {
    val base = mapOf("stage" to "before_insert", "attempts" to attempts.toString(), "written" to "false")
    return when (sample) {
        is AgentInputSurfaceSample.Observed -> base + mapOf(
            "reason" to sample.assessment.name.lowercase(),
            "capturedRows" to sample.observation.visibleTail.decodeToString().split('\n').size.toString(),
            "cursorRow" to sample.observation.cursorRow.toString(),
            "cursorColumn" to sample.observation.cursorColumn.toString(),
            "cursorVisible" to sample.observation.cursorVisible.toString(),
            "authoritative" to sample.observation.authoritative.toString(),
            "truncated" to sample.observation.truncated.toString(),
        )
        AgentInputSurfaceSample.CaptureUnavailable -> base + ("reason" to "capture_unavailable")
        AgentInputSurfaceSample.RouteChanged -> base + ("reason" to "route_changed")
        AgentInputSurfaceSample.TargetUnproven -> base + ("reason" to "target_unproven")
        null -> base + ("reason" to "unsupported_input")
    }
}

/**
 * ABI `resultOutcome`. `notSent` is admissible only for text actions and
 * only when no write was invoked; it removes Core's outgoing bubble.
 */
internal fun agentActionResultOutcome(action: String, code: String, notSent: Boolean = false): JSONObject? {
    if (action !in setOf("send", "queue", "interrupt", "answerPrompt", "openTerminal")) return null
    val status = when {
        notSent && action in AGENT_TEXT_ACTIONS -> "notSent"
        code == "success" -> "verified"
        code == "staleBinding" -> "staleBinding"
        code == "cancelled" -> "cancelled"
        else -> "failed"
    }
    return JSONObject().put("status", status).put("action", action)
        .also { value -> if (status == "verified") value.put("verification", "fresh-terminal-postcondition") }
}

/** A cancelled text action is `notSent` exactly when its write never began. */
internal fun agentCancellationIsNotSent(action: String, latch: AgentTerminalWriteLatch): Boolean =
    action in AGENT_TEXT_ACTIONS && !latch.mayHaveWritten

/**
 * How an action whose job threw is finished. [notSent] is set only for a text
 * action whose write never began; otherwise the ambiguous [legacyCode] is the
 * result. [legacyCode] is also the fallback when `notSent` cannot reach Core.
 */
internal data class AgentAbortedActionFinish(val notSent: AgentNotSentReason?, val legacyCode: String)

/**
 * A cancellation keeps `cancelled`; any other throw (a lease that fails to
 * decode, a route or capture read that throws) is `failed`, so the action
 * can never stay pending with Core's bubble sending forever.
 */
internal fun agentAbortedActionFinish(action: String, latch: AgentTerminalWriteLatch, cancelled: Boolean): AgentAbortedActionFinish {
    val legacyCode = if (cancelled) "cancelled" else "failed"
    val reason = if (cancelled) AgentNotSentReason.CANCELLED else AgentNotSentReason.UNEXPECTED
    return AgentAbortedActionFinish(reason.takeIf { agentCancellationIsNotSent(action, latch) }, legacyCode)
}

/** What a pre-write refusal does once its `notSent` result was, or was not, queued for Core. */
internal sealed interface AgentNotSentFinish {
    /**
     * `notSent` was queued. That is not acceptance: Core applies it later and
     * may still reject it, so the draft waits for [agentNotSentSettlement].
     */
    data object Forwarded : AgentNotSentFinish

    /**
     * Core never took `notSent` (binding authority already purged), so its
     * bubble was not withdrawn. Finish with the ambiguous legacy code and
     * leave the composer alone: returning the draft beside a surviving
     * bubble invites a duplicate send.
     */
    data class Ambiguous(val legacyCode: String) : AgentNotSentFinish
}

internal fun agentNotSentFinish(resultForwarded: Boolean, legacyCode: String): AgentNotSentFinish =
    if (resultForwarded) AgentNotSentFinish.Forwarded else AgentNotSentFinish.Ambiguous(legacyCode)

/**
 * A queued `notSent` result waiting for Core's verdict. [draftCleared] says
 * whether this lease's ActionPlan actually took the message out of the box.
 */
internal data class AgentPendingNotSent(
    val threadKey: String,
    val leaseToken: String,
    val action: String,
    val text: String?,
    val reason: AgentNotSentReason,
    val providerName: String?,
    val legacyCode: String,
    val draftCleared: Boolean,
)

internal enum class AgentNotSentSettlement {
    /** Core's verdict is not visible yet. */
    WAIT,
    /** Core withdrew the bubble: the message goes back to the composer. */
    RETURN_DRAFT,
    /** Core rejected the result or kept the bubble: ambiguous, composer alone. */
    AMBIGUOUS,
    /**
     * Ambiguous for now (composer alone, the legacy notice), but Core may
     * still have withdrawn the bubble unseen: a late watch returns the
     * message if a later snapshot shows it gone.
     */
    AMBIGUOUS_WATCH,
    /**
     * The thread's next ActionPlan accepted this very text again: the user
     * already resent it, so it does not come back and no "Not sent" shows.
     */
    RESENT,
}

/** What one snapshot of the thread proves about a queued `notSent`. */
internal enum class AgentNotSentEvidence {
    /** Any snapshot: it may predate Core processing the result. */
    SNAPSHOT,
    /**
     * Core's answer to a `notSent` result for the thread (code `notSent`):
     * accepted, and acceptance always withdraws a bubble no write acknowledged.
     */
    ACCEPTED,
    /**
     * A later ActionPlan for the thread: Core processed the result before
     * planning it, but may have rejected it.
     */
    APPLIED,
}

/** The evidence a thread snapshot carries, by its Core code. */
internal fun agentNotSentEvidence(snapshotCode: String?): AgentNotSentEvidence =
    if (snapshotCode == "notSent") AgentNotSentEvidence.ACCEPTED else AgentNotSentEvidence.SNAPSHOT

/**
 * Settles a queued `notSent` from one snapshot of its own thread. The outgoing
 * bubble is named by the lease token. Core withdraws an issued lease's
 * unacknowledged bubble even after an unbind or rebind revoked the lease, so
 * the thread's binding proves nothing: a listed bubble in a plain snapshot
 * may simply predate the result. [outgoingHidden] is a window away from the
 * live head that still retains outgoing messages it does not list.
 *
 * A hidden bubble after an ActionPlan ([AgentNotSentEvidence.APPLIED]) is not
 * proof of withdrawal: Core may have rejected the result (a lease it no longer
 * holds, or a different binding token) before planning again. It is
 * ambiguous, watched for a late withdrawal.
 */
internal fun agentNotSentSettlement(
    leaseToken: String,
    outgoingIDs: Collection<String>,
    outgoingHidden: Boolean,
    evidence: AgentNotSentEvidence,
): AgentNotSentSettlement = when {
    outgoingIDs.any { it.equals(leaseToken, ignoreCase = true) } ->
        if (evidence != AgentNotSentEvidence.SNAPSHOT) AgentNotSentSettlement.AMBIGUOUS
        else AgentNotSentSettlement.WAIT
    !outgoingHidden -> AgentNotSentSettlement.RETURN_DRAFT
    evidence == AgentNotSentEvidence.ACCEPTED -> AgentNotSentSettlement.RETURN_DRAFT
    evidence == AgentNotSentEvidence.APPLIED -> AgentNotSentSettlement.AMBIGUOUS_WATCH
    else -> AgentNotSentSettlement.WAIT
}

private fun AgentThreadDetail.hidesOutgoing(): Boolean = window?.let { !it.atLiveHead && it.retainsOutgoing } == true

private fun AgentThreadDetail.listsOutgoing(leaseToken: String): Boolean =
    outgoingMessages.any { it.id.equals(leaseToken, ignoreCase = true) }

/** [agentNotSentSettlement] read from one snapshot of the thread. */
internal fun AgentThreadDetail.notSentSettlement(
    leaseToken: String,
    evidence: AgentNotSentEvidence,
): AgentNotSentSettlement = agentNotSentSettlement(leaseToken, outgoingMessages.map { it.id }, hidesOutgoing(), evidence)

/**
 * The verdict once the fallback runs out: only the thread's latest snapshot
 * showing the bubble gone returns the draft now. A bubble still listed, a
 * window hiding it, or no snapshot at all is ambiguous, never settled blindly
 * as withdrawn; its withdrawal may only have been dropped, so it is watched.
 */
internal fun agentNotSentFallbackSettlement(leaseToken: String, latest: AgentThreadDetail?): AgentNotSentSettlement =
    if (latest == null || !agentNotSentVisiblyWithdrawn(leaseToken, latest)) AgentNotSentSettlement.AMBIGUOUS_WATCH
    else AgentNotSentSettlement.RETURN_DRAFT

/**
 * A snapshot that lists outgoing messages without the lease's bubble. Only a
 * queued `notSent` (the write latch never flipped) is ever watched, so
 * returning its message on this evidence, however late, can never duplicate
 * written bytes.
 */
internal fun agentNotSentVisiblyWithdrawn(leaseToken: String, detail: AgentThreadDetail): Boolean =
    !detail.hidesOutgoing() && !detail.listsOutgoing(leaseToken)

/**
 * The thread's next ActionPlan settles its queued `notSent` ([AgentNotSentEvidence.APPLIED]).
 * When it accepted exactly that text again the user already resent it:
 * returning it (or a "Not sent" notice) while the resend is being written
 * would invite a real duplicate send.
 */
internal fun agentNotSentActionPlanSettlement(
    pending: AgentPendingNotSent,
    plan: AgentThreadDetail,
    acceptedText: String?,
): AgentNotSentSettlement {
    if (acceptedText != null && acceptedText == pending.text) return AgentNotSentSettlement.RESENT
    return plan.notSentSettlement(pending.leaseToken, AgentNotSentEvidence.APPLIED)
}

/**
 * Core reports a rejected `result` only by its kind, with no thread or lease
 * (a launch receipt is a `result` too), and replaces an event too large to
 * deliver with a bare rejection. Either may be, or hide, a queued `notSent`'s
 * verdict. Neither settles it: it only asks Core again now rather than at the
 * fallback's deadline.
 */
internal fun agentRejectionMayHideNotSent(failureCode: String): Boolean =
    failureCode.substringAfter('@', "") == "result" || failureCode == "abi_event_too_large"

/** Core's `AgentActionError` names; the ABI suffixes them with the refused command (`actionInFlight@action`). */
private val AGENT_ACTION_ERRORS = setOf(
    "unavailable", "actionInFlight", "staleBinding", "invalidLaunch", "stalePrompt",
    "verificationFailed", "cancelled", "inputNotReady", "terminalDraft",
)

/** The notice for a Core rejection: action errors in words, any other code as it is. */
internal fun agentRejectionNotice(failureCode: String): String {
    val error = failureCode.substringBefore('@')
    return (if (error in AGENT_ACTION_ERRORS) agentActionResultNotice(error) else null) ?: failureCode.replace('_', ' ')
}

/** What the presenter does with one Core rejection. */
internal data class AgentRejectionReaction(
    val notice: String,
    /**
     * The `action` command itself was refused (e.g. `actionInFlight@action`):
     * no ActionPlan will come, so no pending action may stay "in progress".
     */
    val endsPendingActions: Boolean,
    /** May be, or hide, a queued `notSent`'s verdict ([agentRejectionMayHideNotSent]). */
    val mayHideNotSent: Boolean,
)

/**
 * Null for stale background work, which is routine and shows nothing: Core
 * refuses a `bind`, `lifecycle` or projection whose token a newer proof or an
 * `unbind` retired while it was queued (`bind_staleBinding`, ...). A refused
 * action still names its command (`staleBinding@action`) and still shows.
 */
internal fun agentRejectionReaction(failureCode: String): AgentRejectionReaction? =
    if (failureCode.endsWith("_staleBinding")) null
    else AgentRejectionReaction(
        notice = agentRejectionNotice(failureCode),
        endsPendingActions = failureCode.substringAfter('@', "") == "action",
        mayHideNotSent = agentRejectionMayHideNotSent(failureCode),
    )

/**
 * Whether a queued `notSent` may be probed now. Not while an action for the
 * same thread is queued: the probe could land after that action's
 * ActionPlan, and its `notSent` answer would read as that send's verdict.
 */
internal fun agentNotSentProbeAllowed(threadKey: String, pendingActionThreads: Collection<String>): Boolean =
    threadKey !in pendingActionThreads

/**
 * The `notSent` result for [lease]. The fallback probe queues exactly this
 * command again: Core applies it idempotently (a released or revoked lease
 * only withdraws the bubble its token names, and only if no write was
 * acknowledged; a newer lease is never touched), and every acceptance answers
 * with a fresh `notSent` snapshot of the thread.
 */
internal fun agentNotSentResultCommand(
    lease: JSONObject,
    bindingToken: String,
    action: String,
    reason: AgentNotSentReason,
): JSONObject = JSONObject().put("v", 1).put("kind", "result").put("bindingToken", bindingToken).put("lease", lease)
    .putOpt("resultOutcome", agentActionResultOutcome(action, reason.code, notSent = true))

/**
 * Queues a `notSent` result in the only safe order: the wait is registered
 * before the result is forwarded (Core may answer at once), and the pending
 * action is released only after it, so no later action reaches Core ahead of
 * it (an ActionPlan then proves it was applied). A result that never reached
 * Core drops its wait: nothing will answer it.
 */
internal inline fun agentQueueNotSent(
    register: () -> Unit,
    forward: () -> Boolean,
    release: () -> Unit,
    abandon: () -> Unit,
): Boolean {
    register()
    val forwarded = forward()
    release()
    if (!forwarded) abandon()
    return forwarded
}

/**
 * Bounds a queued `notSent` whose verdict never shows: Core's snapshot can be
 * dropped from the bounded event buffer, replaced by `abi_event_too_large`,
 * or answered only by an unattributed rejection. After [probeAfterMillis]
 * (sooner after a rejection) the result is queued again ([agentNotSentResultCommand]);
 * [probeWindowMillis] after that probe, or at [hardCapMillis] when a probe
 * never became safe to send, the thread's latest snapshot decides
 * ([agentNotSentFallbackSettlement]). The clock advances in [tickMillis] steps.
 */
internal data class AgentNotSentFallbackPolicy(
    val probeAfterMillis: Long = 2_000,
    val probeWindowMillis: Long = 2_000,
    val hardCapMillis: Long = 10_000,
    val tickMillis: Long = 100,
    /** How long a message settled ambiguous stays watched for a late withdrawal. */
    val lateWatchMillis: Long = 60_000,
)

internal enum class AgentNotSentFallbackStep {
    WAIT,
    /** Queue the result again now. */
    PROBE,
    /** Out of time: settle from the thread's latest snapshot. */
    SETTLE,
}

/**
 * One step of the fallback clock. A probe is sent at most once, and only when
 * [probeAllowed]: while an action for the same thread is queued, a probe
 * could land after that action's ActionPlan, and its `notSent` answer would
 * then read as the next send's verdict.
 */
internal fun agentNotSentFallbackStep(
    elapsedMillis: Long,
    probedAtMillis: Long?,
    probeRequested: Boolean,
    probeAllowed: Boolean,
    policy: AgentNotSentFallbackPolicy = AgentNotSentFallbackPolicy(),
): AgentNotSentFallbackStep = when {
    elapsedMillis >= policy.hardCapMillis -> AgentNotSentFallbackStep.SETTLE
    probedAtMillis != null ->
        if (elapsedMillis - probedAtMillis >= policy.probeWindowMillis) AgentNotSentFallbackStep.SETTLE else AgentNotSentFallbackStep.WAIT
    probeAllowed && (probeRequested || elapsedMillis >= policy.probeAfterMillis) -> AgentNotSentFallbackStep.PROBE
    else -> AgentNotSentFallbackStep.WAIT
}

/** One queued `notSent` awaiting Core's verdict, with its fallback clock. */
internal class AgentNotSentWait(
    val pending: AgentPendingNotSent,
    /** The runtime that took the result: a replaced runtime settles nothing. */
    val owner: Any,
    val lease: JSONObject,
    val bindingToken: String? = null,
) {
    val threadKey: String get() = pending.threadKey
    internal var elapsedMillis = 0L
    internal var probedAtMillis: Long? = null
    internal var probeRequested = false
}

/**
 * Queued `notSent` results by thread and the rules that settle them, plus the
 * ones settled ambiguous that are still watched for a late withdrawal. Pure
 * bookkeeping: the presenter forwards the probes, runs the clocks and applies
 * settlements.
 */
internal class AgentNotSentLedger(val policy: AgentNotSentFallbackPolicy = AgentNotSentFallbackPolicy()) {
    private val waits = java.util.concurrent.ConcurrentHashMap<String, AgentNotSentWait>()
    private val late = java.util.concurrent.ConcurrentHashMap<String, AgentNotSentWait>()

    /** Returns the wait [wait] replaced on its thread, if any. */
    fun register(wait: AgentNotSentWait): AgentNotSentWait? = waits.put(wait.threadKey, wait)

    /** Drops [wait]; false when it was already settled or replaced. */
    fun abandon(wait: AgentNotSentWait): Boolean = waits.remove(wait.threadKey, wait)

    fun clear() {
        waits.clear()
        late.clear()
    }

    fun isWaiting(wait: AgentNotSentWait): Boolean = waits[wait.threadKey] === wait

    fun isWatchingLate(wait: AgentNotSentWait): Boolean = late[wait.threadKey] === wait

    fun settleRemovedConversation(threadKey: String, bindingToken: String): AgentNotSentWait? {
        val wait = waits[threadKey]?.takeIf { it.bindingToken == bindingToken }
        if (wait != null && waits.remove(threadKey, wait)) return wait
        val watched = late[threadKey]?.takeIf { it.bindingToken == bindingToken } ?: return null
        return watched.takeIf { late.remove(threadKey, it) }
    }

    /**
     * One snapshot of the thread settles its queued wait once Core has
     * decided. Null while nothing settles.
     */
    fun settle(detail: AgentThreadDetail, evidence: AgentNotSentEvidence): Pair<AgentNotSentWait, AgentNotSentSettlement>? {
        val wait = waits[detail.row.key] ?: return null
        return conclude(wait, detail.notSentSettlement(wait.pending.leaseToken, evidence))
    }

    /**
     * One snapshot of the thread, for the message it settled ambiguous and
     * still watches: returned (settle it [AgentNotSentSettlement.RETURN_DRAFT])
     * once the snapshot shows its bubble gone. Independent of [settle]: the
     * thread's next send may be waiting on the same snapshot.
     */
    fun settleLate(detail: AgentThreadDetail): AgentNotSentWait? {
        val watched = late[detail.row.key] ?: return null
        if (!agentNotSentVisiblyWithdrawn(watched.pending.leaseToken, detail) || !late.remove(detail.row.key, watched)) return null
        return watched
    }

    /**
     * The thread's next ActionPlan (a new send): it ends any late watch and
     * settles the queued wait ([agentNotSentActionPlanSettlement]).
     */
    fun settleByActionPlan(plan: AgentThreadDetail, acceptedText: String?): Pair<AgentNotSentWait, AgentNotSentSettlement>? {
        late.remove(plan.row.key)
        val wait = waits[plan.row.key] ?: return null
        return conclude(wait, agentNotSentActionPlanSettlement(wait.pending, plan, acceptedText))
    }

    /**
     * The settlement for a wait whose clock ran out ([advance] returned
     * SETTLE), from the thread's latest snapshot; an ambiguous one is watched.
     */
    fun settleByFallback(wait: AgentNotSentWait, latest: AgentThreadDetail?): AgentNotSentSettlement {
        val settlement = agentNotSentFallbackSettlement(wait.pending.leaseToken, latest)
        if (settlement == AgentNotSentSettlement.AMBIGUOUS_WATCH) watchLate(wait)
        return settlement
    }

    private fun watchLate(wait: AgentNotSentWait) {
        late[wait.threadKey] = wait
    }

    /** Ends [wait]'s late watch at the cap; false when it had already ended. */
    fun expireLate(wait: AgentNotSentWait): Boolean = late.remove(wait.threadKey, wait)

    private fun conclude(wait: AgentNotSentWait, settlement: AgentNotSentSettlement): Pair<AgentNotSentWait, AgentNotSentSettlement>? {
        if (settlement == AgentNotSentSettlement.WAIT || !waits.remove(wait.threadKey, wait)) return null
        if (settlement == AgentNotSentSettlement.AMBIGUOUS_WATCH) watchLate(wait)
        return wait to settlement
    }

    /**
     * A rejection settles nothing. One that may hide a verdict makes every
     * wait due a probe now; one that ended the pending actions reopens the
     * probe gate. Returns the waits to re-evaluate at once.
     */
    fun noteRejection(failureCode: String): List<AgentNotSentWait> {
        val reaction = agentRejectionReaction(failureCode) ?: return emptyList()
        if (reaction.mayHideNotSent) return waits.values.toList().onEach { it.probeRequested = true }
        return if (reaction.endsPendingActions) waits.values.toList() else emptyList()
    }

    /**
     * Advances [wait]'s clock by [advancedMillis]. PROBE: queue its result
     * again now. SETTLE: it has been withdrawn; settle it with
     * [settleByFallback]. Null once it no longer waits (settled, replaced or
     * cleared): its clock stops.
     */
    fun advance(wait: AgentNotSentWait, advancedMillis: Long, probeAllowed: Boolean): AgentNotSentFallbackStep? {
        if (!isWaiting(wait)) return null
        wait.elapsedMillis += advancedMillis
        val step = agentNotSentFallbackStep(wait.elapsedMillis, wait.probedAtMillis, wait.probeRequested, probeAllowed, policy)
        when (step) {
            AgentNotSentFallbackStep.WAIT -> Unit
            AgentNotSentFallbackStep.PROBE -> wait.probedAtMillis = wait.elapsedMillis
            AgentNotSentFallbackStep.SETTLE -> if (!waits.remove(wait.threadKey, wait)) return null
        }
        return step
    }
}

/** The composer and notice once a queued `notSent` settles. */
internal fun AgentCenterUiState.withSettledNotSent(pending: AgentPendingNotSent, settlement: AgentNotSentSettlement): AgentCenterUiState =
    when (settlement) {
        AgentNotSentSettlement.WAIT, AgentNotSentSettlement.RESENT -> this
        AgentNotSentSettlement.RETURN_DRAFT ->
            withUnsentMessage(pending.threadKey, pending.text, pending.reason, pending.providerName, pending.draftCleared)
        AgentNotSentSettlement.AMBIGUOUS, AgentNotSentSettlement.AMBIGUOUS_WATCH ->
            copy(notice = agentActionResultNotice(pending.legacyCode) ?: notice)
    }

/** The notice a finished action shows for its legacy result code; none for success. */
internal fun agentActionResultNotice(code: String): String? = when (code) {
    "success" -> null
    "staleBinding" -> "Terminal binding is stale; reopen the terminal before retrying"
    "verificationFailed" -> "Terminal verification failed; review the terminal before retrying"
    "actionInFlight" -> "Another action is still running on this thread; try again in a moment"
    "unavailable" -> "This terminal can't take actions right now"
    "inputNotReady" -> "The agent's input wasn't ready; nothing was typed"
    "terminalDraft" -> "The terminal already has unsent text; clear it before retrying"
    "stalePrompt" -> "Prompt changed; review it in the terminal"
    "invalidLaunch" -> "That launch request isn't valid here"
    else -> code.replace('_', ' ')
}

/**
 * Whether the ActionPlan took [acceptedText] out of [draft]. Only then does a
 * refusal put the message back; otherwise it never left the box.
 */
internal fun agentActionPlanClearsDraft(draft: String, acceptedText: String): Boolean =
    draftAfterActionPlan(draft, acceptedText) != draft

/** The thread key a lease's threadID names, spelled as [AgentPresentation] keys its rows. */
internal fun agentLeaseThreadKey(lease: JSONObject): String? {
    val id = lease.optJSONObject("threadID") ?: return null
    val provider = id.optJSONObject("providerID")?.optString("rawValue") ?: id.optString("providerID")
    val session = id.optString("providerSessionID")
    if (provider.isEmpty() || session.isEmpty()) return null
    return canonicalAgentThreadKey(id.optString("hostID").canonicalAgentUUID(), provider, session)
}

/**
 * Finishing a lease releases only its own thread's request. Once a plan was
 * accepted, its lease token also fences a later request on that thread.
 */
internal fun agentFinishReleasesPending(
    pendingThreadKey: String,
    pendingKind: String,
    pendingBinding: JSONObject,
    lease: JSONObject,
    threadKey: String?,
    pendingLeaseToken: String? = null,
): Boolean = pendingThreadKey == threadKey && (if (pendingLeaseToken != null) pendingLeaseToken == lease.optString("token")
    else pendingBinding.sameCoreBinding(lease.optJSONObject("binding")) && pendingKind == lease.optString("action"))

/**
 * Threads sharing one terminal input surface cannot interleave mutations. A
 * raw session (no pane) is one surface; a tmux pane is one per pane.
 */
internal fun agentActionTargetBusy(threadKey: String, binding: JSONObject, pendingThreadKey: String, pendingBinding: JSONObject): Boolean =
    threadKey == pendingThreadKey || (binding.optString("liveSessionID").canonicalAgentUUID() == pendingBinding.optString("liveSessionID").canonicalAgentUUID() &&
        binding.optLong("carrierGeneration") == pendingBinding.optLong("carrierGeneration") &&
        binding.opt("paneID")?.toString() == pendingBinding.opt("paneID")?.toString())

/** A capture with no text (tmux raced a redraw) is evidence of nothing. */
internal fun agentCaptureHasText(observation: AgentTerminalObservation): Boolean =
    observation.visibleTail.decodeToString().isNotBlank()

/**
 * The draft attaches an image: a line holding exactly one JSON-quoted absolute
 * image path, as an Agent Center upload writes it. The shared core decides how
 * such a line is pasted and recognized; this only scopes the longer waits.
 */
internal fun agentDraftAttachesImages(text: String): Boolean = text.split('\n').any { line ->
    val quoted = line.trim()
    if (quoted.length < 3 || !quoted.startsWith('"') || !quoted.endsWith('"')) return@any false
    val path = runCatching { JSONArray("[$quoted]").getString(0) }.getOrNull() ?: return@any false
    (path.startsWith("/") || path.startsWith("\\\\") || Regex("^[A-Za-z]:[\\\\/]").containsMatchIn(path)) &&
        path.substringAfterLast('.', "").lowercase() in setOf("png", "jpg", "jpeg", "gif", "webp")
}

/** Only recognized absence in a fresh complete composer proves submission. */
internal fun agentComposerDeparted(observation: AgentTerminalObservation, assessment: Assessment): Boolean =
    observation.authoritative && !observation.truncated && !observation.captureWaitedForFrame && assessment == Assessment.ABSENT

/** Escape landed once the pane shows different text; a blank frame differs from anything. */
internal fun agentInterruptObserved(before: AgentTerminalObservation, after: AgentTerminalObservation): Boolean =
    agentCaptureHasText(after) && !after.visibleTail.contentEquals(before.visibleTail)

/**
 * The frame an interrupt is judged against. A capture with no text (tmux
 * raced a redraw) would make any later frame look changed, so it is re-read
 * like the send preflight: attempts start only within the readiness window,
 * each bounded by what remains of the deadline. Null when no capture with
 * text arrives; the Escape is then never sent.
 */
internal suspend fun agentSettledBaseline(
    policy: AgentSendPreflightPolicy = AgentSendPreflightPolicy(),
    nanoTime: () -> Long = System::nanoTime,
    pause: suspend (Long) -> Unit = { delay(it) },
    read: suspend (timeoutMillis: Long) -> AgentTerminalObservation?,
): AgentTerminalObservation? {
    val started = nanoTime()
    fun elapsedMillis() = (nanoTime() - started) / 1_000_000
    while (true) {
        val budget = policy.deadlineMillis - elapsedMillis()
        if (budget <= 0) return null
        read(budget)?.takeIf(::agentCaptureHasText)?.let { return it }
        if (elapsedMillis() + policy.intervalMillis > policy.windowMillis) return null
        pause(policy.intervalMillis)
    }
}

/** One post-write verification read. */
internal sealed interface AgentPoll<out T> {
    data class Found<T>(val value: T) : AgentPoll<T>
    /** Nothing yet: read again after the interval. */
    data object Again : AgentPoll<Nothing>
    /** Nothing this wait could read will verify: stop now. */
    data object GiveUp : AgentPoll<Nothing>
}

/**
 * How long a post-write verification may hold the lease. An unanswered tmux
 * command now fails its ack after 15 s instead of throwing, so an attempt
 * count alone no longer bounds a wait whose every read stalls.
 */
internal const val AGENT_OBSERVATION_BUDGET_MILLIS = 10_000L

/**
 * How long an approved image send waits before its key. It never reads the
 * composer as ready, so it would spend every check; Claude turns a pasted path
 * into a marker in about 100 ms.
 */
internal const val AGENT_OVERRIDE_IMAGE_WAIT_MILLIS = 2_000L

/**
 * At most [attempts] reads, [intervalMillis] apart, never past [budgetMillis]
 * however slow a read is. The budget running out is a verification that saw
 * nothing (null), never the action's cancellation, which still propagates, as
 * does the end of the action's lifetime thrown from [attempt].
 */
internal suspend fun <T : Any> agentBoundedPoll(
    attempts: Int = 20,
    intervalMillis: Long = 50,
    budgetMillis: Long = AGENT_OBSERVATION_BUDGET_MILLIS,
    attempt: suspend () -> AgentPoll<T>,
): T? = withTimeoutOrNull(budgetMillis) {
    repeat(attempts) {
        when (val read = attempt()) {
            is AgentPoll.Found -> return@withTimeoutOrNull read.value
            AgentPoll.GiveUp -> return@withTimeoutOrNull null
            AgentPoll.Again -> delay(intervalMillis)
        }
    }
    null
}

/**
 * An optional read: any failure is [unavailable], including a cancellation
 * that is not this action's own (closing an ingestion connection cancels its
 * pending requests). Only the action's own cancellation propagates.
 */
internal suspend inline fun <T> agentOptionalRead(unavailable: (Throwable) -> T, read: () -> T): T = try {
    read()
} catch (failure: Throwable) {
    if (agentThrowIsCancellation(failure, currentCoroutineContext().isActive)) throw failure
    unavailable(failure)
}

/** Content-free `agent_send_not_sent` fields: codes and counts only. */
internal fun agentNotSentDiagnosticFields(
    action: String,
    reason: AgentNotSentReason,
    attempts: Int?,
    finish: AgentNotSentFinish,
): Map<String, String> = buildMap {
    put("action", action)
    put("reason", reason.code)
    put("written", "false")
    put("resultForwarded", (finish == AgentNotSentFinish.Forwarded).toString())
    put("fallback", if (finish is AgentNotSentFinish.Ambiguous) "ambiguous" else "none")
    if (finish is AgentNotSentFinish.Ambiguous) put("legacyResult", finish.legacyCode)
    attempts?.let { put("attempts", it.toString()) }
}

/** Name used in not-sent notices; Core's display name for other providers. */
internal fun agentNoticeProviderName(providerID: String, displayName: String): String? = when (providerID) {
    "claude" -> "Claude"
    "codex" -> "Codex"
    else -> displayName.trim().takeIf { it.isNotEmpty() && it != "unknown" }
}

/** Where an unsent message went in its thread's composer. */
internal enum class AgentUnsentDraft {
    /** The box was empty (or already held exactly the message). */
    RESTORED,
    /** Put back above text typed since the send, separated by a blank line. */
    MERGED,
    /** There was no message to put back. */
    NONE,
}

internal fun agentNotSentNotice(reason: AgentNotSentReason, providerName: String?, draft: AgentUnsentDraft): String {
    val possessive = providerName?.let { "$it's" } ?: "the agent's"
    val cause = when (reason) {
        AgentNotSentReason.INPUT_NOT_READY -> "$possessive input wasn't ready"
        AgentNotSentReason.TERMINAL_DRAFT -> "the terminal already has unsent text in $possessive prompt"
        AgentNotSentReason.ROUTE_CHANGED -> "the terminal changed"
        AgentNotSentReason.INPUT_UNAVAILABLE -> "this terminal can't take verified input right now"
        AgentNotSentReason.UNSUPPORTED_INPUT -> "this message can't be typed into $possessive prompt from here"
        AgentNotSentReason.PLAN_MISMATCH -> "the message changed before it could be typed"
        AgentNotSentReason.RECEIPT_UNAVAILABLE -> "delivery tracking couldn't start"
        AgentNotSentReason.CANCELLED -> "the send was cancelled"
        AgentNotSentReason.UNEXPECTED -> "an unexpected error stopped the send"
    }
    val outcome = when (draft) {
        AgentUnsentDraft.RESTORED -> " Nothing was typed; your message is back in the box."
        AgentUnsentDraft.MERGED -> " Nothing was typed; your message is back in the box above what you typed since."
        AgentUnsentDraft.NONE -> " Nothing was typed."
    }
    return "Not sent — $cause.$outcome"
}

/**
 * The composer after an unsent [message] returns to it. A blank box takes the
 * message; a box already holding exactly the message is left alone; newer
 * text is never replaced: the message goes back in front of it, separated by
 * a blank line. When the send never cleared the box ([draftCleared] false:
 * typing continued before Core accepted it, or the draft was longer than the
 * message), a box that still starts with the message already holds it and is
 * left alone; any other box follows the normal rule (iOS `returnUnsentText`).
 */
internal fun agentDraftWithUnsentMessage(
    current: String,
    message: String,
    draftCleared: Boolean = true,
): Pair<String, AgentUnsentDraft> = when {
    current.isBlank() -> message to AgentUnsentDraft.RESTORED
    current == message || (!draftCleared && current.startsWith(message)) -> current to AgentUnsentDraft.RESTORED
    else -> "$message\n\n$current" to AgentUnsentDraft.MERGED
}

/** Returns an unsent message to its thread's composer and says where it went. */
internal fun AgentCenterUiState.withUnsentMessage(
    threadKey: String,
    text: String?,
    reason: AgentNotSentReason,
    providerName: String?,
    draftCleared: Boolean = true,
): AgentCenterUiState {
    val message = text?.takeIf { it.isNotBlank() }
        ?: return copy(notice = agentNotSentNotice(reason, providerName, AgentUnsentDraft.NONE))
    val (draft, placed) = agentDraftWithUnsentMessage(drafts[threadKey].orEmpty(), message, draftCleared)
    return copy(drafts = drafts + (threadKey to draft), notice = agentNotSentNotice(reason, providerName, placed))
}
