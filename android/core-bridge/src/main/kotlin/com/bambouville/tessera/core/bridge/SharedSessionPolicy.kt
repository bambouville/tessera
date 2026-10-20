package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * Session lifecycle, owned by `TesseraSessionCore`.
 *
 * Swift authority: `Packages/TesseraCore/Sources/TesseraSessionCore/` —
 * `ForegroundRestoreCohort`, `TerminalResizeCoalescer`,
 * `SessionEndClassification`, `SessionRetryPolicy`. The ABI seam is
 * `Sources/TesseraCoreABI/SessionPolicyABI.swift`.
 *
 * The core's unit is seconds as a Double. This file converts at the edge, so a
 * caller that carries milliseconds keeps carrying milliseconds.
 */

/** The five lifecycle buckets a transport projects itself into. */
enum class SharedRestoreLiveState(val wireValue: String) {
    Idle("idle"),
    Connecting("connecting"),
    Connected("connected"),
    Disconnected("disconnected"),
    Failed("failed"),
}

/** One cohort entry, reduced to the two facts a verdict needs. */
data class SharedRestoreCandidate(
    val liveSessionId: String,
    val persistedHostId: String?,
)

/**
 * The live facts about one running session.
 *
 * [transportConfirmed] is null for a transport with no separate reachability
 * signal (SSH). Passing `false` is what keeps a mosh session that reads as
 * `Connected` but is unreachable from being scored alive.
 */
data class SharedRestoreLiveSession(
    val liveSessionId: String,
    val persistedHostId: String?,
    val state: SharedRestoreLiveState,
    val transportConfirmed: Boolean? = null,
)

/** A verdict for one cohort entry. */
enum class SharedRestoreVerdict(val wireValue: String) {
    /** Reported dead, or its tab is gone. Reconnect it. */
    Dead("dead"),

    /** Believed alive, and enough time has passed to believe it. */
    Alive("alive"),

    /** No verdict yet. */
    Pending("pending");

    companion object {
        fun fromWire(value: String): SharedRestoreVerdict =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared restore verdict")
    }
}

/** One classification pass over a whole cohort. */
data class SharedRestoreEvaluation(
    val deadSessionIds: List<String>,
    /** Positions in the supplied cohort, so a caller holding a parallel array
     * of its own snapshots can map back without assuming ids are unique. */
    val deadIndices: List<Int>,
    val retiredSessionIds: List<String>,
    val hasWork: Boolean,
)

/** Whether the restore window is over. */
enum class SharedRestoreWindowClosure(val wireValue: String) {
    /** Every entry reached a verdict. */
    Settled("settled"),

    /** Time ran out with entries unresolved. */
    Backstop("backstop"),

    /** Keep waiting. */
    Open("open");

    companion object {
        fun fromWire(value: String): SharedRestoreWindowClosure =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared window closure")
    }
}

/** What a snapshot write may do to the document already in the store. */
enum class SharedRestorePersistMode(val wireValue: String) {
    /** Nothing is at risk: write exactly what is live. */
    LiveOnly("liveOnly"),

    /** The window is open — entries awaiting a verdict keep their snapshots. */
    KeepCohort("keepCohort"),

    /** Merge over the stored document instead of replacing it. */
    MergeWithStored("mergeWithStored");

    companion object {
        fun fromWire(value: String): SharedRestorePersistMode =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared persist mode")
    }
}

/** One restore-document rule violation. */
data class SharedRestoreDocumentViolation(
    val kind: String,
    val count: Int?,
    val sessionId: String?,
)

/** The result of validating a restore document. */
data class SharedRestoreDocumentCheck(
    val isValid: Boolean,
    val violations: List<SharedRestoreDocumentViolation>,
    /** A dangling selection is the one violation both platforms repair rather
     * than reject: the sessions are still restorable, only the highlight is
     * stale. */
    val normalizedSelection: String?,
    val schemaVersion: Int,
    val maxSnapshots: Int,
)

/** What the user asked should happen to their sessions on the next launch. */
enum class SharedRestorePolicy(val wireValue: String) {
    Ask("ask"),
    Always("always"),
    Never("never");

    companion object {
        fun fromWire(value: String): SharedRestorePolicy =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared restore policy")
    }
}

/** One stored snapshot, reduced to what the cold-start decision needs. */
data class SharedRestoreStartupCandidate(
    val sessionId: String,
    val hostId: String,
)

/** Why a cold start is waiting or skipping. */
enum class SharedRestoreStartupReason(val wireValue: String) {
    /** The host list has not arrived. Acting now reads every snapshot as
     * naming a host this device no longer has. */
    HostsNotLoaded("hostsNotLoaded"),

    /** The host list arrived empty while the document names hosts — which is
     * what a Room emission predating a recent write looks like. A verdict, not
     * a fact, so the caller waits and bounds the wait itself. */
    HostListEmpty("hostListEmpty"),
    PolicyNever("policyNever"),
    NoDocument("noDocument"),
    NothingRestorable("nothingRestorable");

    companion object {
        fun fromWire(value: String): SharedRestoreStartupReason =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared restore startup reason")
    }
}

/**
 * What a cold start should do.
 *
 * [Wait] is not [Skip]: a caller that collapses them spends its one cold-start
 * pass on a question it could not yet answer, and the document it clears is the
 * one it was about to restore from.
 */
sealed interface SharedRestoreStartupAction {
    data class Wait(val reason: SharedRestoreStartupReason) : SharedRestoreStartupAction

    data class Skip(val reason: SharedRestoreStartupReason) : SharedRestoreStartupAction

    data class Restore(val plan: SharedRestoreStartupPlan) : SharedRestoreStartupAction

    data class Offer(val plan: SharedRestoreStartupPlan) : SharedRestoreStartupAction
}

/** The sessions a launch should bring back, in the stored document's order. */
data class SharedRestoreStartupPlan(
    val sessionIds: List<String>,
    val selectedSessionId: String?,
    /** Entries this device cannot restore. Surfaced, not silently dropped. */
    val skippedCount: Int,
)

/** Which of the caller's own collections a written entry comes from. */
enum class SharedRestorePersistSource(val wireValue: String) {
    Current("current"),
    Cohort("cohort"),
    Stored("stored");

    companion object {
        fun fromWire(value: String): SharedRestorePersistSource =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared persist source")
    }
}

data class SharedRestorePersistEntry(
    val sessionId: String,
    val source: SharedRestorePersistSource,
)

/** What one snapshot write contains, and what it selects. */
data class SharedRestorePersistPlan(
    val entries: List<SharedRestorePersistEntry>,
    val selectedSessionId: String?,
)

/** A terminal size in cells. */
data class SharedTerminalSize(val columns: Int, val rows: Int)

/**
 * The coalescer's whole state, carried across the ABI.
 *
 * A wait can only exist for a size that differs from what was last delivered,
 * so the two impossible combinations are rejected here rather than sent on to
 * be rejected natively: replaying "waiting with nothing delivered" would come
 * back as `Send`, and "waiting for the delivered size" as `Drop` — both
 * plausible-looking answers to a state that never existed.
 */
data class SharedResizeCoalescerState(
    val lastDelivered: SharedTerminalSize? = null,
    val pending: SharedTerminalSize? = null,
) {
    init {
        require(pending == null || (lastDelivered != null && pending != lastDelivered)) {
            "a pending resize requires a different already-delivered size"
        }
    }
}

/** What to do with a size the terminal view reported. */
enum class SharedResizeDecision(val wireValue: String) {
    /** Deliver now — nothing has been delivered yet, so the session cannot
     * start without it. */
    Send("send"),

    /** Hold it for the settle window; deliver if nothing supersedes it. */
    Wait("wait"),

    /** The size came back to what the remote already has. */
    Drop("drop");

    companion object {
        fun fromWire(value: String): SharedResizeDecision =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared resize decision")
    }
}

data class SharedResizeNoteOutcome(
    val decision: SharedResizeDecision,
    val state: SharedResizeCoalescerState,
)

data class SharedResizeSettleOutcome(
    /** False when the wait was superseded, so a stale timer cannot deliver an
     * old size. */
    val settled: Boolean,
    val state: SharedResizeCoalescerState,
)

/** Typed facade over `Sources/TesseraCoreABI/SessionPolicyABI.swift`. */
object SharedSessionPolicy {

    /**
     * Identifiers you get back are spelled the way you sent them.
     *
     * Session and host ids cross as canonical UUID strings and Swift parses
     * them into `UUID`, which re-renders in UPPER CASE. Android writes
     * `UUID.randomUUID().toString()`, which is lower case — so an id echoed
     * back from any call is a string that no longer matches the one in the
     * store, and every lookup against it silently misses. `restoreEvaluate`
     * returns positions rather than ids partly to sidestep this; every call
     * that must return ids runs them back through here instead, so no caller
     * has to know.
     */
    private class Spelling(known: Iterable<String?>) {
        private val byUpperCase = known.filterNotNull().associateBy { it.uppercase(Locale.ROOT) }

        fun of(id: String?): String? = id?.let { byUpperCase[it.uppercase(Locale.ROOT)] ?: it }

        fun required(id: String): String = checkNotNull(of(id))
    }

    // MARK: - Foreground restore

    /**
     * Classifies one cohort entry. [live] is null when the session's tab is
     * gone, which is a [SharedRestoreVerdict.Dead] verdict: a transport death
     * and a clean remote `exit` are indistinguishable at this point and both
     * want a reconnect offer.
     */
    fun restoreVerdict(
        candidate: SharedRestoreCandidate,
        live: SharedRestoreLiveSession?,
        elapsedSinceWindowOpenedMilliseconds: Long,
        aliveFloorMilliseconds: Long,
    ): SharedRestoreVerdict {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("candidate", candidate.toJson())
            .put("live", live?.toJson() ?: JSONObject.NULL)
            .put(
                "elapsedSinceWindowOpenedSeconds",
                elapsedSinceWindowOpenedMilliseconds.toSeconds(),
            )
            .put("aliveFloorSeconds", aliveFloorMilliseconds.toSeconds())
            .toString()
            .encodeToByteArray()
        return SharedRestoreVerdict.fromWire(
            NativeCoreBindings.sessionRestoreVerdict(request.toDirectBuffer(), request.size),
        )
    }

    /**
     * Classifies a whole cohort in one pass.
     *
     * [retiresDeadImmediately] is false under the "ask" restore policy: there a
     * dead entry is offered rather than reconnected, so it keeps its cohort
     * place — and its snapshot protection — until the user answers.
     */
    fun restoreEvaluate(
        cohort: List<SharedRestoreCandidate>,
        live: List<SharedRestoreLiveSession>,
        elapsedSinceWindowOpenedMilliseconds: Long,
        aliveFloorMilliseconds: Long,
        retiresDeadImmediately: Boolean,
    ): SharedRestoreEvaluation {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("cohort", JSONArray().also { array -> cohort.forEach { array.put(it.toJson()) } })
            .put("live", JSONArray().also { array -> live.forEach { array.put(it.toJson()) } })
            .put(
                "elapsedSinceWindowOpenedSeconds",
                elapsedSinceWindowOpenedMilliseconds.toSeconds(),
            )
            .put("aliveFloorSeconds", aliveFloorMilliseconds.toSeconds())
            .put("retiresDeadImmediately", retiresDeadImmediately)
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.sessionRestoreEvaluate(request.toDirectBuffer(), request.size),
        )
        fun strings(key: String): List<String> = value.getJSONArray(key).let { array ->
            List(array.length()) { array.getString(it) }
        }
        val indices = value.getJSONArray("deadIndices")
        val spelling = Spelling(cohort.map { it.liveSessionId } + live.map { it.liveSessionId })
        return SharedRestoreEvaluation(
            deadSessionIds = strings("deadIDs").map(spelling::required),
            deadIndices = List(indices.length()) { indices.getInt(it) },
            retiredSessionIds = strings("retiredIDs").map(spelling::required),
            hasWork = value.getBoolean("hasWork"),
        )
    }

    /**
     * Whether the restore window is over. The backstop outranks settling,
     * except under an unanswered restore prompt: a sheet on screen is a
     * verdict in progress, and closing the window under it would strip the
     * snapshots the sheet is offering while the user reads them.
     */
    fun restoreWindowClosure(
        remainingCohortCount: Int,
        elapsedSinceWindowOpenedMilliseconds: Long,
        maxWindowMilliseconds: Long,
        hasUnansweredPrompt: Boolean,
    ): SharedRestoreWindowClosure {
        require(remainingCohortCount >= 0)
        NativeLibraries.ensureLoaded()
        return SharedRestoreWindowClosure.fromWire(
            NativeCoreBindings.sessionRestoreWindowClosure(
                remainingCohortCount,
                elapsedSinceWindowOpenedMilliseconds.toSeconds(),
                maxWindowMilliseconds.toSeconds(),
                hasUnansweredPrompt,
            ),
        )
    }

    /**
     * How far the window's clock advances on one pass, in milliseconds.
     *
     * A null [lastChargeAtMilliseconds] charges nothing. A single step is
     * capped for the same reason the connect watchdog is: a larger gap means
     * the process was suspended, not that time was spent waiting.
     */
    fun restoreChargeDeltaMilliseconds(
        nowMilliseconds: Long,
        lastChargeAtMilliseconds: Long?,
        isPrompting: Boolean,
        maxTickMilliseconds: Long,
    ): Long {
        NativeLibraries.ensureLoaded()
        val seconds = NativeCoreBindings.sessionRestoreChargeDelta(
            nowMilliseconds.toSeconds(),
            (lastChargeAtMilliseconds ?: 0L).toSeconds(),
            lastChargeAtMilliseconds != null,
            isPrompting,
            maxTickMilliseconds.toSeconds(),
        )
        return Math.round(seconds * 1_000.0)
    }

    /**
     * What a snapshot write may do to the stored document. A write that
     * mirrors the live session list deletes everything it cannot see — and the
     * sessions worth restoring are exactly the ones that are no longer there.
     */
    fun restorePersistMode(
        isActive: Boolean,
        hasPreservedSnapshots: Boolean,
        isWindowOpen: Boolean,
        hasCohortEntries: Boolean,
    ): SharedRestorePersistMode {
        NativeLibraries.ensureLoaded()
        return SharedRestorePersistMode.fromWire(
            NativeCoreBindings.sessionRestorePersistMode(
                isActive,
                hasPreservedSnapshots,
                isWindowOpen,
                hasCohortEntries,
            ),
        )
    }

    /** Validates a restore document against the shared rules. */
    fun restoreDocumentRules(
        schemaVersion: Int,
        sessionIds: List<String>,
        selectedSessionId: String?,
    ): SharedRestoreDocumentCheck {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("schemaVersion", schemaVersion)
            .put("sessionIDs", JSONArray().also { array -> sessionIds.forEach(array::put) })
            .put("selectedSessionID", selectedSessionId ?: JSONObject.NULL)
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.sessionRestoreDocumentRules(request.toDirectBuffer(), request.size),
        )
        val violations = value.getJSONArray("violations")
        return SharedRestoreDocumentCheck(
            isValid = value.getBoolean("isValid"),
            violations = List(violations.length()) { index ->
                violations.getJSONObject(index).let { violation ->
                    SharedRestoreDocumentViolation(
                        kind = violation.getString("kind"),
                        count = if (violation.isNull("count")) null else violation.getInt("count"),
                        sessionId = if (violation.isNull("sessionID")) {
                            null
                        } else {
                            violation.getString("sessionID")
                        },
                    )
                }
            },
            normalizedSelection = if (value.isNull("normalizedSelection")) {
                null
            } else {
                value.getString("normalizedSelection")
            },
            schemaVersion = value.getInt("schemaVersion"),
            maxSnapshots = value.getInt("maxSnapshots"),
        )
    }

    // MARK: - Cold start

    /**
     * What a launch should do with the stored document.
     *
     * [hostsLoaded] and an empty [availableHostIds] are separate arguments on
     * purpose: the first says the store has not answered, the second that it
     * answered with nothing — and on Room the second is also what an emission
     * predating a recent write looks like. Both are a wait; neither spends the
     * pass.
     */
    fun restoreStartupAction(
        candidates: List<SharedRestoreStartupCandidate>,
        hasDocument: Boolean,
        hostsLoaded: Boolean,
        availableHostIds: Collection<String>,
        liveHostIds: Collection<String>,
        selectedSessionId: String?,
        policy: SharedRestorePolicy,
    ): SharedRestoreStartupAction {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put(
                "candidates",
                JSONArray().also { array ->
                    candidates.forEach { candidate ->
                        array.put(
                            JSONObject()
                                .put("sessionID", candidate.sessionId)
                                .put("hostID", candidate.hostId),
                        )
                    }
                },
            )
            .put("hasDocument", hasDocument)
            .put("hostsLoaded", hostsLoaded)
            .put("availableHostIDs", JSONArray().also { array -> availableHostIds.forEach(array::put) })
            .put("liveHostIDs", JSONArray().also { array -> liveHostIds.forEach(array::put) })
            .put("selectedSessionID", selectedSessionId ?: JSONObject.NULL)
            .put("policy", policy.wireValue)
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.sessionRestoreStartupAction(request.toDirectBuffer(), request.size),
        )
        val spelling = Spelling(candidates.map { it.sessionId } + selectedSessionId)
        fun reason() = SharedRestoreStartupReason.fromWire(value.getString("reason"))
        fun plan(): SharedRestoreStartupPlan {
            val sessionIds = value.getJSONArray("sessionIDs")
            return SharedRestoreStartupPlan(
                sessionIds = List(sessionIds.length()) { spelling.required(sessionIds.getString(it)) },
                selectedSessionId = if (value.isNull("selectedSessionID")) {
                    null
                } else {
                    spelling.of(value.getString("selectedSessionID"))
                },
                skippedCount = value.getInt("skippedCount"),
            )
        }
        return when (val action = value.getString("action")) {
            "wait" -> SharedRestoreStartupAction.Wait(reason())
            "skip" -> SharedRestoreStartupAction.Skip(reason())
            "restore" -> SharedRestoreStartupAction.Restore(plan())
            "offer" -> SharedRestoreStartupAction.Offer(plan())
            else -> throw IllegalArgumentException("unknown shared restore startup action $action")
        }
    }

    /**
     * The policy actually in force for the shell being presented. Compact
     * navigation has no multi-session chooser, so `ask` behaves as `always`
     * there — without disturbing the stored preference, which is a
     * cross-device setting the tablet still honours.
     */
    fun restoreEffectivePolicy(
        stored: SharedRestorePolicy,
        usesCompactShell: Boolean,
    ): SharedRestorePolicy {
        NativeLibraries.ensureLoaded()
        val policy = stored.wireValue.encodeToByteArray()
        return SharedRestorePolicy.fromWire(
            NativeCoreBindings.sessionRestoreEffectivePolicy(
                policy.toDirectBuffer(),
                policy.size,
                usesCompactShell,
            ),
        )
    }

    /**
     * What one snapshot write contains, given the mode [restorePersistMode]
     * chose, and which session it selects.
     *
     * Each entry names the collection its record comes from; the core never
     * sees the records themselves, because they carry display names, launch
     * modes and tmux targets that mean nothing to it.
     */
    fun restorePersistPlan(
        mode: SharedRestorePersistMode,
        currentSessionIds: List<String>,
        cohortSessionIds: List<String>,
        storedSessionIds: List<String>,
        preferredSelection: String?,
        storedSelection: String?,
        maxSnapshots: Int,
    ): SharedRestorePersistPlan {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("mode", mode.wireValue)
            .put("currentSessionIDs", JSONArray().also { array -> currentSessionIds.forEach(array::put) })
            .put("cohortSessionIDs", JSONArray().also { array -> cohortSessionIds.forEach(array::put) })
            .put("storedSessionIDs", JSONArray().also { array -> storedSessionIds.forEach(array::put) })
            .put("preferredSelection", preferredSelection ?: JSONObject.NULL)
            .put("storedSelection", storedSelection ?: JSONObject.NULL)
            .put("maxSnapshots", maxSnapshots)
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.sessionRestorePersistPlan(request.toDirectBuffer(), request.size),
        )
        val spelling = Spelling(
            currentSessionIds + cohortSessionIds + storedSessionIds +
                listOf(preferredSelection, storedSelection),
        )
        val entries = value.getJSONArray("entries")
        return SharedRestorePersistPlan(
            entries = List(entries.length()) { index ->
                entries.getJSONObject(index).let { entry ->
                    SharedRestorePersistEntry(
                        sessionId = spelling.required(entry.getString("sessionID")),
                        source = SharedRestorePersistSource.fromWire(entry.getString("source")),
                    )
                }
            },
            selectedSessionId = if (value.isNull("selectedSessionID")) {
                null
            } else {
                spelling.of(value.getString("selectedSessionID"))
            },
        )
    }

    // MARK: - Resize coalescing

    /**
     * Notes a size the terminal view reported.
     *
     * The first size SENDs. Scheduling it instead — which this platform used
     * to do — leaves the remote without a geometry it cannot start without.
     */
    fun resizeNote(
        state: SharedResizeCoalescerState,
        size: SharedTerminalSize,
    ): SharedResizeNoteOutcome {
        NativeLibraries.ensureLoaded()
        val request = coalescerRequest(state, size)
        val value = JSONObject(
            NativeCoreBindings.sessionResizeNote(request.toDirectBuffer(), request.size),
        )
        return SharedResizeNoteOutcome(
            decision = SharedResizeDecision.fromWire(value.getString("decision")),
            state = coalescerState(value.getJSONObject("state")),
        )
    }

    /** Settles an expired wait. */
    fun resizeSettle(
        state: SharedResizeCoalescerState,
        size: SharedTerminalSize,
    ): SharedResizeSettleOutcome {
        NativeLibraries.ensureLoaded()
        val request = coalescerRequest(state, size)
        val value = JSONObject(
            NativeCoreBindings.sessionResizeSettle(request.toDirectBuffer(), request.size),
        )
        return SharedResizeSettleOutcome(
            settled = value.getBoolean("settled"),
            state = coalescerState(value.getJSONObject("state")),
        )
    }

    /**
     * The settle window in milliseconds (120). Long enough to swallow a
     * modal's measured 28 ms shrink-and-restore, short enough that a real
     * resize is not perceptibly late. Take the window from here rather than
     * keeping a local constant.
     */
    fun resizeSettleMilliseconds(): Long {
        NativeLibraries.ensureLoaded()
        return Math.round(NativeCoreBindings.sessionResizeSettleSeconds() * 1_000.0)
    }

    // MARK: - End of session and retry

    /**
     * Whether the remote process itself ended, as opposed to the transport
     * carrying it.
     *
     * A null [exitStatus] is EOF-without-status: recoverable transport loss, so
     * the session stays reconnectable. Any status — including 0 — is
     * authenticated evidence from the far side that the shell finished.
     */
    fun remoteProcessEnded(exitStatus: Int?): Boolean {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.sessionRemoteProcessEnded(
            exitStatus ?: 0,
            exitStatus != null,
        ) == 1
    }

    /** Whether a session that ended this way keeps its restore record. */
    fun retainsRestoreRecord(exitStatus: Int?): Boolean {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.sessionRetainsRestoreRecord(
            exitStatus ?: 0,
            exitStatus != null,
        ) == 1
    }

    /**
     * Native mosh's two end events, which one integer cannot tell apart.
     *
     * A transport stop is the client noticing its own socket stopped: no
     * authenticated remote status, and the far-side `mosh-server` is still
     * there to re-attach. A shutdown completion is client and server agreeing
     * the session is over, and does retire the restore record.
     */
    fun moshRemoteProcessEnded(isShutdownCompletion: Boolean): Boolean {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.sessionMoshRemoteProcessEnded(isShutdownCompletion) == 1
    }

    /**
     * Whether a lost session should try again.
     *
     * The rules fire in order: an explicit disconnect never retries; a
     * transport that never connected never retries unless a recovery is
     * already in flight; `transport_disconnected` always retries; otherwise
     * the failure's `detail` must name one of the shared transient markers.
     */
    fun shouldRetry(
        explicitDisconnect: Boolean,
        hadConnectedTransport: Boolean,
        alreadyRecovering: Boolean,
        code: String,
        arguments: Map<String, String>,
    ): Boolean {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("explicitDisconnect", explicitDisconnect)
            .put("hadConnectedTransport", hadConnectedTransport)
            .put("alreadyRecovering", alreadyRecovering)
            .put("code", code)
            .put(
                "arguments",
                JSONObject().also { entries ->
                    arguments.forEach { (key, argument) -> entries.put(key, argument) }
                },
            )
            .toString()
            .encodeToByteArray()
        return when (
            NativeCoreBindings.sessionShouldRetry(request.toDirectBuffer(), request.size)
        ) {
            0 -> false
            1 -> true
            else -> error("shared retry policy rejected a well-formed failure")
        }
    }

    /**
     * Delay before a one-based attempt, in milliseconds. Attempts past the
     * ladder's end hold at its last rung rather than growing without bound.
     */
    fun retryDelayMilliseconds(attempt: Int): Long {
        NativeLibraries.ensureLoaded()
        return Math.round(NativeCoreBindings.sessionRetryDelaySeconds(attempt) * 1_000.0)
    }

    /** The shared attempt cap. */
    fun retryMaxAttempts(): Int {
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.sessionRetryMaxAttempts()
    }

    // MARK: - Marshalling

    private fun coalescerRequest(
        state: SharedResizeCoalescerState,
        size: SharedTerminalSize,
    ): ByteArray = JSONObject()
        .put(
            "state",
            JSONObject()
                .put("lastDelivered", state.lastDelivered?.toJson() ?: JSONObject.NULL)
                .put("pending", state.pending?.toJson() ?: JSONObject.NULL),
        )
        .put("size", size.toJson())
        .toString()
        .encodeToByteArray()

    private fun coalescerState(value: JSONObject): SharedResizeCoalescerState =
        SharedResizeCoalescerState(
            lastDelivered = value.optJSONObject("lastDelivered")?.toTerminalSize(),
            pending = value.optJSONObject("pending")?.toTerminalSize(),
        )
}

private fun SharedRestoreCandidate.toJson(): JSONObject = JSONObject()
    .put("liveSessionID", liveSessionId)
    .put("persistedHostID", persistedHostId ?: JSONObject.NULL)

private fun SharedRestoreLiveSession.toJson(): JSONObject = JSONObject()
    .put("liveSessionID", liveSessionId)
    .put("persistedHostID", persistedHostId ?: JSONObject.NULL)
    .put("state", state.wireValue)
    .put("transportConfirmed", transportConfirmed ?: JSONObject.NULL)

private fun SharedTerminalSize.toJson(): JSONObject = JSONObject()
    .put("cols", columns)
    .put("rows", rows)

private fun JSONObject.toTerminalSize(): SharedTerminalSize =
    SharedTerminalSize(columns = getInt("cols"), rows = getInt("rows"))

/** The core's boundary unit is seconds as a Double; convert at this edge. */
private fun Long.toSeconds(): Double = this / 1_000.0
