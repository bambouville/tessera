package com.bambouville.tessera.data.continuity

import com.bambouville.tessera.core.bridge.SharedRestoreCandidate
import com.bambouville.tessera.core.bridge.SharedRestoreLiveSession
import com.bambouville.tessera.core.bridge.SharedRestoreLiveState
import com.bambouville.tessera.core.bridge.SharedRestorePersistMode
import com.bambouville.tessera.core.bridge.SharedRestorePolicy
import com.bambouville.tessera.core.bridge.SharedRestoreStartupAction
import com.bambouville.tessera.core.bridge.SharedRestoreStartupCandidate
import com.bambouville.tessera.core.bridge.SharedRestoreStartupPlan
import com.bambouville.tessera.core.bridge.SharedRestoreStartupReason
import com.bambouville.tessera.core.bridge.SharedRestoreVerdict
import com.bambouville.tessera.core.bridge.SharedRestoreWindowClosure
import com.bambouville.tessera.core.bridge.SharedSessionPolicy
import com.bambouville.tessera.data.TransportKinds

/**
 * Restore rows from pre-parity Android builds sometimes encoded tmux in the
 * transport string (for example `ssh+tmux`).  Current hosts keep transport and
 * tmux mode separate.  Normalize that durable state at the boundary so a
 * legacy row can never crash the foreground snapshot writer.
 */
fun normalizedRestoreTransportKind(candidate: String?, fallback: String = TransportKinds.SSH): String =
    when {
        candidate.equals(TransportKinds.MOSH, ignoreCase = true) ||
            candidate?.startsWith("mosh", ignoreCase = true) == true -> TransportKinds.MOSH
        candidate.equals(TransportKinds.SSH, ignoreCase = true) ||
            candidate?.startsWith("ssh", ignoreCase = true) == true -> TransportKinds.SSH
        fallback.equals(TransportKinds.MOSH, ignoreCase = true) -> TransportKinds.MOSH
        else -> TransportKinds.SSH
    }

/**
 * Android's secret-free, process-death-safe counterpart to the iOS session
 * restore document. Credentials, terminal bytes, and SSH/Mosh key material
 * never belong in this type.
 */
enum class SessionRestorePolicy {
    ASK,
    ALWAYS,
    NEVER,
}

object SessionRestorePresentationPolicy {
    /**
     * Compact navigation has no multi-session restore chooser, so `ask`
     * behaves as `always` while the phone shell is presented — without
     * disturbing the stored preference, which is a cross-device setting the
     * tablet still honours.
     *
     * iOS spelled this rule out a second time, identically. It lives in
     * `ForegroundRestorePresentation` now, and both platforms read it there;
     * the rows are pinned by
     * `ProtocolVectors/session/v1/restore-decisions.json`.
     */
    fun effective(stored: SessionRestorePolicy, usesCompactShell: Boolean): SessionRestorePolicy =
        SharedSessionPolicy.restoreEffectivePolicy(
            stored = stored.shared,
            usesCompactShell = usesCompactShell,
        ).local()
}

/** Why a cold start is waiting or skipping. */
enum class ForegroundRestoreStartupReason(val wireValue: String) {
    /** The host list has not arrived. Acting now reads every snapshot as
     * naming a host this device no longer has. */
    HOSTS_NOT_LOADED("hostsNotLoaded"),

    /** The host list arrived empty while the document names hosts — which is
     * also what a Room emission predating a recent write looks like. A verdict
     * the caller cannot yet make, so it waits and bounds the wait itself. */
    HOST_LIST_EMPTY("hostListEmpty"),
    POLICY_NEVER("policyNever"),
    NO_DOCUMENT("noDocument"),
    NOTHING_RESTORABLE("nothingRestorable"),
}

/** The sessions a launch should bring back, in the stored document's order. */
data class ForegroundRestoreStartupPlan(
    val snapshots: List<ForegroundRestoreSnapshot>,
    val selectedSessionId: String?,
    /** Entries this device cannot restore. Surfaced, not silently dropped. */
    val skippedCount: Int,
)

/**
 * What a cold start should do.
 *
 * [Wait] is not [Skip]. A caller that collapses them spends its one cold-start
 * pass on a question it could not yet answer, and the document it clears is the
 * one it was about to restore from — which is exactly what Android did until
 * 2026-09-11.
 */
sealed interface ForegroundRestoreStartupAction {
    data class Wait(val reason: ForegroundRestoreStartupReason) : ForegroundRestoreStartupAction

    data class Skip(val reason: ForegroundRestoreStartupReason) : ForegroundRestoreStartupAction

    data class Restore(val plan: ForegroundRestoreStartupPlan) : ForegroundRestoreStartupAction

    data class Offer(val plan: ForegroundRestoreStartupPlan) : ForegroundRestoreStartupAction
}

/**
 * Android's projection of the shared cold-start decision.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraSessionCore/ForegroundRestoreStartup.swift`.
 * The guard order is the whole content of the rule, and this platform had its
 * own copy of it with one guard missing.
 */
object ForegroundRestoreStartup {
    fun action(
        document: ForegroundRestoreDocument?,
        hostsLoaded: Boolean,
        availableHostIds: Set<String>,
        liveHostIds: Set<String>,
        policy: SessionRestorePolicy,
    ): ForegroundRestoreStartupAction {
        val snapshots = document?.snapshots.orEmpty()
        val action = SharedSessionPolicy.restoreStartupAction(
            candidates = snapshots.map {
                SharedRestoreStartupCandidate(sessionId = it.sessionId, hostId = it.hostId)
            },
            hasDocument = document != null,
            hostsLoaded = hostsLoaded,
            availableHostIds = availableHostIds,
            liveHostIds = liveHostIds,
            selectedSessionId = document?.selectedSessionId,
            policy = policy.shared,
        )
        fun plan(shared: SharedRestoreStartupPlan): ForegroundRestoreStartupPlan {
            val byId = snapshots.associateBy(ForegroundRestoreSnapshot::sessionId)
            return ForegroundRestoreStartupPlan(
                snapshots = shared.sessionIds.mapNotNull(byId::get),
                selectedSessionId = shared.selectedSessionId,
                skippedCount = shared.skippedCount,
            )
        }
        return when (action) {
            is SharedRestoreStartupAction.Wait ->
                ForegroundRestoreStartupAction.Wait(action.reason.local())
            is SharedRestoreStartupAction.Skip ->
                ForegroundRestoreStartupAction.Skip(action.reason.local())
            is SharedRestoreStartupAction.Restore ->
                ForegroundRestoreStartupAction.Restore(plan(action.plan))
            is SharedRestoreStartupAction.Offer ->
                ForegroundRestoreStartupAction.Offer(plan(action.plan))
        }
    }
}

private fun SharedRestoreStartupReason.local() = when (this) {
    SharedRestoreStartupReason.HostsNotLoaded -> ForegroundRestoreStartupReason.HOSTS_NOT_LOADED
    SharedRestoreStartupReason.HostListEmpty -> ForegroundRestoreStartupReason.HOST_LIST_EMPTY
    SharedRestoreStartupReason.PolicyNever -> ForegroundRestoreStartupReason.POLICY_NEVER
    SharedRestoreStartupReason.NoDocument -> ForegroundRestoreStartupReason.NO_DOCUMENT
    SharedRestoreStartupReason.NothingRestorable -> ForegroundRestoreStartupReason.NOTHING_RESTORABLE
}

/** What one snapshot write contains, and which session it selects. */
data class ForegroundRestoreWrite(
    val snapshots: List<ForegroundRestoreSnapshot>,
    val selectedSessionId: String?,
)

data class ForegroundRestoreSnapshot(
    val sessionId: String,
    val hostId: String,
    val displayName: String,
    val createdAtEpochMilliseconds: Long,
    val transportKind: String,
    val tmuxTarget: String?,
    val lastSelection: String?,
    val reconnectRequired: Boolean,
) {
    init {
        require(sessionId.isNotBlank())
        require(hostId.isNotBlank())
        require(displayName.isNotBlank())
        require(createdAtEpochMilliseconds >= 0)
        require(transportKind == TransportKinds.SSH || transportKind == TransportKinds.MOSH)
        require(tmuxTarget == null || tmuxTarget.isNotBlank())
        require(lastSelection == null || lastSelection.isNotBlank())
    }
}

data class ForegroundRestoreDocument(
    val schemaVersion: Int = CURRENT_SCHEMA_VERSION,
    val savedAtEpochMilliseconds: Long,
    val snapshots: List<ForegroundRestoreSnapshot>,
    val selectedSessionId: String?,
) {
    init {
        require(schemaVersion == CURRENT_SCHEMA_VERSION)
        require(savedAtEpochMilliseconds >= 0)
        require(snapshots.isNotEmpty())
        require(snapshots.size <= MAX_SNAPSHOTS)
        require(snapshots.map(ForegroundRestoreSnapshot::sessionId).distinct().size == snapshots.size)
        require(selectedSessionId == null || (
            selectedSessionId.isNotBlank() && snapshots.any { it.sessionId == selectedSessionId }
        ))
    }

    companion object {
        const val CURRENT_SCHEMA_VERSION = 1
        const val MAX_SNAPSHOTS = 64
    }
}

/** UI-neutral liveness facts supplied by the session/controller layer at wake. */
data class ForegroundRestoreLiveSession(
    val sessionId: String,
    val hostId: String?,
    val state: ForegroundRestoreConnectionState,
    /** Null means the transport does not separately report reachability (SSH). */
    val transportConfirmed: Boolean? = null,
)

enum class ForegroundRestoreConnectionState { IDLE, CONNECTING, CONNECTED, DISCONNECTED, FAILED }

enum class ForegroundRestoreVerdict { DEAD, ALIVE, PENDING }

data class ForegroundRestoreEvaluation(
    val dead: List<ForegroundRestoreSnapshot> = emptyList(),
    val retiredSessionIds: List<String> = emptyList(),
)

enum class ForegroundRestoreWindowClosure { SETTLED, BACKSTOP, OPEN }

enum class ForegroundRestorePersistMode { LIVE_ONLY, KEEP_COHORT, MERGE_WITH_STORED }

/**
 * Android's projection of the shared foreground-restore cohort.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraSessionCore/ForegroundRestoreCohort.swift`,
 * reached through `SharedSessionPolicy` in `:core-bridge`. Every decision —
 * verdict, cohort evaluation, window closure, clock charging, persist mode —
 * belongs to the core; what stays here is the mapping between the store's
 * snapshot rows and the two facts a verdict actually needs.
 *
 * The two rules this platform used to restate, and must never restate again:
 * a Mosh session reading `CONNECTED` proves nothing while its reachability
 * signal is false, and an unanswered restore prompt keeps the cohort's
 * snapshots alive until the user answers.
 *
 * Session and host identifiers cross the ABI as canonical UUID strings, which
 * is what this app already writes (`UUID.randomUUID().toString()`).
 */
object ForegroundRestoreCohort {
    fun verdict(
        snapshot: ForegroundRestoreSnapshot,
        live: ForegroundRestoreLiveSession?,
        elapsedSinceWindowOpenedMilliseconds: Long,
        aliveFloorMilliseconds: Long,
    ): ForegroundRestoreVerdict {
        require(elapsedSinceWindowOpenedMilliseconds >= 0)
        require(aliveFloorMilliseconds >= 0)
        return SharedSessionPolicy.restoreVerdict(
            candidate = snapshot.sharedCandidate(),
            live = live?.shared(),
            elapsedSinceWindowOpenedMilliseconds = elapsedSinceWindowOpenedMilliseconds,
            aliveFloorMilliseconds = aliveFloorMilliseconds,
        ).local()
    }

    /**
     * [retiresDeadImmediately] is false under [SessionRestorePolicy.ASK]: a
     * dead entry is offered rather than reconnected, so it keeps its cohort
     * place — and its snapshot protection — until the user answers.
     */
    fun evaluate(
        cohort: List<ForegroundRestoreSnapshot>,
        live: List<ForegroundRestoreLiveSession>,
        elapsedSinceWindowOpenedMilliseconds: Long,
        aliveFloorMilliseconds: Long,
        retiresDeadImmediately: Boolean,
    ): ForegroundRestoreEvaluation {
        require(elapsedSinceWindowOpenedMilliseconds >= 0)
        require(aliveFloorMilliseconds >= 0)
        val evaluation = SharedSessionPolicy.restoreEvaluate(
            cohort = cohort.map(ForegroundRestoreSnapshot::sharedCandidate),
            live = live.map(ForegroundRestoreLiveSession::shared),
            elapsedSinceWindowOpenedMilliseconds = elapsedSinceWindowOpenedMilliseconds,
            aliveFloorMilliseconds = aliveFloorMilliseconds,
            retiresDeadImmediately = retiresDeadImmediately,
        )
        // Positions, not identifiers: the core returns them precisely so a
        // caller holding the parallel snapshot array maps back without
        // assuming session ids are unique. Retired entries have no index, and
        // the wrapper hands them back in the spelling they were sent in — see
        // the note on `SharedSessionPolicy`.
        return ForegroundRestoreEvaluation(
            dead = evaluation.deadIndices.map(cohort::get),
            retiredSessionIds = evaluation.retiredSessionIds,
        )
    }

    fun windowClosure(
        remainingCohortCount: Int,
        elapsedSinceWindowOpenedMilliseconds: Long,
        maxWindowMilliseconds: Long,
        hasUnansweredPrompt: Boolean,
    ): ForegroundRestoreWindowClosure {
        require(elapsedSinceWindowOpenedMilliseconds >= 0)
        require(maxWindowMilliseconds >= 0)
        return SharedSessionPolicy.restoreWindowClosure(
            remainingCohortCount = remainingCohortCount,
            elapsedSinceWindowOpenedMilliseconds = elapsedSinceWindowOpenedMilliseconds,
            maxWindowMilliseconds = maxWindowMilliseconds,
            hasUnansweredPrompt = hasUnansweredPrompt,
        ).local()
    }

    /** Do not charge lock/prompt time or a process-suspension-sized time jump. */
    fun chargeDeltaMilliseconds(
        nowEpochMilliseconds: Long,
        lastChargeAtEpochMilliseconds: Long?,
        isPrompting: Boolean,
        maxTickMilliseconds: Long,
    ): Long {
        require(maxTickMilliseconds >= 0)
        return SharedSessionPolicy.restoreChargeDeltaMilliseconds(
            nowMilliseconds = nowEpochMilliseconds,
            lastChargeAtMilliseconds = lastChargeAtEpochMilliseconds,
            isPrompting = isPrompting,
            maxTickMilliseconds = maxTickMilliseconds,
        )
    }

    fun persistMode(
        isActive: Boolean,
        hasPreservedSnapshots: Boolean,
        isWindowOpen: Boolean,
        hasCohortEntries: Boolean,
    ): ForegroundRestorePersistMode = SharedSessionPolicy.restorePersistMode(
        isActive = isActive,
        hasPreservedSnapshots = hasPreservedSnapshots,
        isWindowOpen = isWindowOpen,
        hasCohortEntries = hasCohortEntries,
    ).local()
}

private fun ForegroundRestoreSnapshot.sharedCandidate() = SharedRestoreCandidate(
    liveSessionId = sessionId,
    persistedHostId = hostId,
)

private fun ForegroundRestoreLiveSession.shared() = SharedRestoreLiveSession(
    liveSessionId = sessionId,
    persistedHostId = hostId,
    state = when (state) {
        ForegroundRestoreConnectionState.IDLE -> SharedRestoreLiveState.Idle
        ForegroundRestoreConnectionState.CONNECTING -> SharedRestoreLiveState.Connecting
        ForegroundRestoreConnectionState.CONNECTED -> SharedRestoreLiveState.Connected
        ForegroundRestoreConnectionState.DISCONNECTED -> SharedRestoreLiveState.Disconnected
        ForegroundRestoreConnectionState.FAILED -> SharedRestoreLiveState.Failed
    },
    transportConfirmed = transportConfirmed,
)

private fun SharedRestoreVerdict.local() = when (this) {
    SharedRestoreVerdict.Dead -> ForegroundRestoreVerdict.DEAD
    SharedRestoreVerdict.Alive -> ForegroundRestoreVerdict.ALIVE
    SharedRestoreVerdict.Pending -> ForegroundRestoreVerdict.PENDING
}

private fun SharedRestoreWindowClosure.local() = when (this) {
    SharedRestoreWindowClosure.Settled -> ForegroundRestoreWindowClosure.SETTLED
    SharedRestoreWindowClosure.Backstop -> ForegroundRestoreWindowClosure.BACKSTOP
    SharedRestoreWindowClosure.Open -> ForegroundRestoreWindowClosure.OPEN
}

private fun SharedRestorePersistMode.local() = when (this) {
    SharedRestorePersistMode.LiveOnly -> ForegroundRestorePersistMode.LIVE_ONLY
    SharedRestorePersistMode.KeepCohort -> ForegroundRestorePersistMode.KEEP_COHORT
    SharedRestorePersistMode.MergeWithStored -> ForegroundRestorePersistMode.MERGE_WITH_STORED
}

internal val ForegroundRestorePersistMode.shared: SharedRestorePersistMode
    get() = when (this) {
        ForegroundRestorePersistMode.LIVE_ONLY -> SharedRestorePersistMode.LiveOnly
        ForegroundRestorePersistMode.KEEP_COHORT -> SharedRestorePersistMode.KeepCohort
        ForegroundRestorePersistMode.MERGE_WITH_STORED -> SharedRestorePersistMode.MergeWithStored
    }

internal val SessionRestorePolicy.shared: SharedRestorePolicy
    get() = when (this) {
        SessionRestorePolicy.ASK -> SharedRestorePolicy.Ask
        SessionRestorePolicy.ALWAYS -> SharedRestorePolicy.Always
        SessionRestorePolicy.NEVER -> SharedRestorePolicy.Never
    }

internal fun SharedRestorePolicy.local() = when (this) {
    SharedRestorePolicy.Ask -> SessionRestorePolicy.ASK
    SharedRestorePolicy.Always -> SessionRestorePolicy.ALWAYS
    SharedRestorePolicy.Never -> SessionRestorePolicy.NEVER
}
