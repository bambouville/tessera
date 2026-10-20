package com.bambouville.tessera.data.continuity

import com.bambouville.tessera.core.bridge.SharedRestorePersistPlan
import com.bambouville.tessera.core.bridge.SharedSessionPolicy

/**
 * The decisions the restore window asks for, behind an interface so the
 * driver's *sequencing* can be exercised on the JVM.
 *
 * The decisions themselves are the shared core's and reach it over JNI, which
 * a unit test cannot dlopen — see [SharedForegroundRestoreDecisions]. What the
 * seam bugs on iOS were made of was never the verdict logic: it was the order
 * of the guards around it, and that is what stays testable here.
 */
interface ForegroundRestoreDecisions {
    fun evaluate(
        cohort: List<ForegroundRestoreSnapshot>,
        live: List<ForegroundRestoreLiveSession>,
        elapsedSinceWindowOpenedMilliseconds: Long,
        aliveFloorMilliseconds: Long,
        retiresDeadImmediately: Boolean,
    ): ForegroundRestoreEvaluation

    fun windowClosure(
        remainingCohortCount: Int,
        elapsedSinceWindowOpenedMilliseconds: Long,
        maxWindowMilliseconds: Long,
        hasUnansweredPrompt: Boolean,
    ): ForegroundRestoreWindowClosure

    fun chargeDeltaMilliseconds(
        nowEpochMilliseconds: Long,
        lastChargeAtEpochMilliseconds: Long?,
        isPrompting: Boolean,
        maxTickMilliseconds: Long,
    ): Long

    fun persistMode(
        isActive: Boolean,
        hasPreservedSnapshots: Boolean,
        isWindowOpen: Boolean,
        hasCohortEntries: Boolean,
    ): ForegroundRestorePersistMode

    /** Which sessions a write contains, and which one it selects. */
    fun persistPlan(
        mode: ForegroundRestorePersistMode,
        currentSessionIds: List<String>,
        cohortSessionIds: List<String>,
        storedSessionIds: List<String>,
        preferredSelection: String?,
        storedSelection: String?,
        maxSnapshots: Int,
    ): SharedRestorePersistPlan
}

/** Production wiring: every decision comes from `TesseraSessionCore`. */
object SharedForegroundRestoreDecisions : ForegroundRestoreDecisions {
    override fun evaluate(
        cohort: List<ForegroundRestoreSnapshot>,
        live: List<ForegroundRestoreLiveSession>,
        elapsedSinceWindowOpenedMilliseconds: Long,
        aliveFloorMilliseconds: Long,
        retiresDeadImmediately: Boolean,
    ): ForegroundRestoreEvaluation = ForegroundRestoreCohort.evaluate(
        cohort = cohort,
        live = live,
        elapsedSinceWindowOpenedMilliseconds = elapsedSinceWindowOpenedMilliseconds,
        aliveFloorMilliseconds = aliveFloorMilliseconds,
        retiresDeadImmediately = retiresDeadImmediately,
    )

    override fun windowClosure(
        remainingCohortCount: Int,
        elapsedSinceWindowOpenedMilliseconds: Long,
        maxWindowMilliseconds: Long,
        hasUnansweredPrompt: Boolean,
    ): ForegroundRestoreWindowClosure = ForegroundRestoreCohort.windowClosure(
        remainingCohortCount = remainingCohortCount,
        elapsedSinceWindowOpenedMilliseconds = elapsedSinceWindowOpenedMilliseconds,
        maxWindowMilliseconds = maxWindowMilliseconds,
        hasUnansweredPrompt = hasUnansweredPrompt,
    )

    override fun chargeDeltaMilliseconds(
        nowEpochMilliseconds: Long,
        lastChargeAtEpochMilliseconds: Long?,
        isPrompting: Boolean,
        maxTickMilliseconds: Long,
    ): Long = ForegroundRestoreCohort.chargeDeltaMilliseconds(
        nowEpochMilliseconds = nowEpochMilliseconds,
        lastChargeAtEpochMilliseconds = lastChargeAtEpochMilliseconds,
        isPrompting = isPrompting,
        maxTickMilliseconds = maxTickMilliseconds,
    )

    override fun persistMode(
        isActive: Boolean,
        hasPreservedSnapshots: Boolean,
        isWindowOpen: Boolean,
        hasCohortEntries: Boolean,
    ): ForegroundRestorePersistMode = ForegroundRestoreCohort.persistMode(
        isActive = isActive,
        hasPreservedSnapshots = hasPreservedSnapshots,
        isWindowOpen = isWindowOpen,
        hasCohortEntries = hasCohortEntries,
    )

    override fun persistPlan(
        mode: ForegroundRestorePersistMode,
        currentSessionIds: List<String>,
        cohortSessionIds: List<String>,
        storedSessionIds: List<String>,
        preferredSelection: String?,
        storedSelection: String?,
        maxSnapshots: Int,
    ): SharedRestorePersistPlan = SharedSessionPolicy.restorePersistPlan(
        mode = mode.shared,
        currentSessionIds = currentSessionIds,
        cohortSessionIds = cohortSessionIds,
        storedSessionIds = storedSessionIds,
        preferredSelection = preferredSelection,
        storedSelection = storedSelection,
        maxSnapshots = maxSnapshots,
    )
}

/**
 * The platform half of the foreground restore window — the state iOS keeps in
 * `ContentView` and Android used not to keep at all.
 *
 * Android's restore was cold-start only: a one-shot latch evaluated the stored
 * document on first composition and never looked again, so a process that
 * survived the background edge came back to dead transports and no mechanism
 * that would notice. Everything below is the shape iOS arrived at over five
 * fix rounds; the comments name which failure each guard is holding shut,
 * because every one of them was a shipped bug there first.
 *
 * The window belongs to ONE wake. It is seeded from the document the
 * background edge wrote — the exact set of sessions whose snapshots are at
 * risk, which does not lag the way a live-session list does — and each entry
 * is held until the shared core gives it a verdict. Entries only ever leave:
 * nothing joins an open window, or a replacement that fails re-enters as a
 * fresh candidate and the reconnect loops forever.
 */
class ForegroundRestoreWindow(
    private val decisions: ForegroundRestoreDecisions = SharedForegroundRestoreDecisions,
    val aliveFloorMilliseconds: Long = ALIVE_FLOOR_MILLISECONDS,
    val maxWindowMilliseconds: Long = MAX_WINDOW_MILLISECONDS,
    private val maxChargeMilliseconds: Long = MAX_CHARGE_MILLISECONDS,
) {
    private var openedAtEpochMilliseconds: Long? = null
    private var chargedMilliseconds: Long = 0
    private var lastChargeAtEpochMilliseconds: Long? = null

    /** Entries still awaiting a verdict, in the stored document's order. */
    var cohort: List<ForegroundRestoreSnapshot> = emptyList()
        private set

    /**
     * Whether the last background edge left snapshots worth restoring. This is
     * the latch that arms the next foreground pass, and — separately — the
     * reason a write must merge rather than replace while a lock screen delays
     * the window from opening.
     */
    var hasPreservedSnapshots: Boolean = false
        private set

    val isOpen: Boolean get() = openedAtEpochMilliseconds != null

    val elapsedMilliseconds: Long get() = if (isOpen) chargedMilliseconds else 0

    /**
     * Record what the background-edge write left behind. A write that stored
     * nothing disarms the latch: there is no wake to owe anybody.
     */
    fun armPreservedSnapshots(hasSnapshots: Boolean) {
        hasPreservedSnapshots = hasSnapshots
    }

    /**
     * The app went inactive.
     *
     * Carrying a window across the background edge is the 2026-08-17 iOS High:
     * wake 2 reused wake 1's cohort against wake 1's clock, so the alive floor
     * read as long-spent, every entry retired on the first pass, and the
     * detection window was zero. Since a healthy entry stays pending for the
     * whole floor, any app visit shorter than the floor hit it — the common
     * case, not a corner. The latch is deliberately NOT cleared here: the
     * background-edge write re-arms it, and the next foreground seeds fresh.
     */
    fun closeForBackgroundEdge() {
        openedAtEpochMilliseconds = null
        chargedMilliseconds = 0
        lastChargeAtEpochMilliseconds = null
        cohort = emptyList()
    }

    /**
     * Seed the window if it is not already open. Returns true when this call
     * opened it.
     *
     * Callers must apply their app-lock guard BEFORE this: seeding behind a
     * lock screen spends the alive floor and the backstop on time the user
     * was busy authenticating, and the first pass that could observe anything
     * arrives after the window has already run out.
     */
    fun openIfNeeded(
        nowEpochMilliseconds: Long,
        snapshots: List<ForegroundRestoreSnapshot>,
    ): Boolean {
        if (isOpen) return false
        openedAtEpochMilliseconds = nowEpochMilliseconds
        chargedMilliseconds = 0
        lastChargeAtEpochMilliseconds = nowEpochMilliseconds
        cohort = snapshots
        return true
    }

    /**
     * Advance the window's clock, in the same units the thing it must outlive
     * is charged in: clamped steps, and nothing at all while a prompt is up.
     * Wall time would run the window faster than a connect budget that pauses
     * behind a host-key sheet, and the entry would be dropped unresolved.
     */
    fun charge(nowEpochMilliseconds: Long, isPrompting: Boolean) {
        if (!isOpen) return
        chargedMilliseconds += decisions.chargeDeltaMilliseconds(
            nowEpochMilliseconds = nowEpochMilliseconds,
            lastChargeAtEpochMilliseconds = lastChargeAtEpochMilliseconds,
            isPrompting = isPrompting,
            maxTickMilliseconds = maxChargeMilliseconds,
        )
        lastChargeAtEpochMilliseconds = nowEpochMilliseconds
    }

    /**
     * Classify the cohort and drop everything that reached a verdict.
     *
     * Retiring happens here, before the caller acts on the dead, because an
     * entry that has been acted on must never be reconsidered — that is what
     * stops a replacement that fails from re-entering and looping.
     *
     * [retiresDeadImmediately] is false under the "ask" policy: there a dead
     * entry is *offered*, not reconnected, so it keeps its place — and its
     * snapshot protection — until the user answers. The replacement carries a
     * new session id and could never match this entry again.
     */
    fun evaluate(
        live: List<ForegroundRestoreLiveSession>,
        retiresDeadImmediately: Boolean,
    ): ForegroundRestoreEvaluation {
        if (!isOpen) return ForegroundRestoreEvaluation()
        val evaluation = decisions.evaluate(
            cohort = cohort,
            live = live,
            elapsedSinceWindowOpenedMilliseconds = elapsedMilliseconds,
            aliveFloorMilliseconds = aliveFloorMilliseconds,
            retiresDeadImmediately = retiresDeadImmediately,
        )
        if (evaluation.retiredSessionIds.isNotEmpty()) {
            val retired = evaluation.retiredSessionIds.toSet()
            cohort = cohort.filterNot { it.sessionId in retired }
        }
        return evaluation
    }

    /**
     * Drop entries because the user took ownership of those sessions — closed
     * one, answered the prompt, edited the host, hit retry. Without this the
     * window reopens a session the user deliberately dismissed.
     *
     * A session simply *ending* is not such a gesture: a transport death and a
     * clean remote `exit` are indistinguishable at that point, and covering
     * that ambiguity is the entire reason the window exists.
     */
    fun retire(sessionIds: Collection<String>): Int {
        if (!isOpen || sessionIds.isEmpty()) return 0
        val ids = sessionIds.toSet()
        val before = cohort.size
        cohort = cohort.filterNot { it.sessionId in ids }
        return before - cohort.size
    }

    /** Empty the cohort without closing the window, for the restore-all branch. */
    fun retireAll(): Int {
        val before = cohort.size
        cohort = emptyList()
        return before
    }

    fun closure(hasUnansweredPrompt: Boolean): ForegroundRestoreWindowClosure {
        if (!isOpen) return ForegroundRestoreWindowClosure.SETTLED
        return decisions.windowClosure(
            remainingCohortCount = cohort.size,
            elapsedSinceWindowOpenedMilliseconds = elapsedMilliseconds,
            maxWindowMilliseconds = maxWindowMilliseconds,
            hasUnansweredPrompt = hasUnansweredPrompt,
        )
    }

    /** The wake is over: no entry is at risk any more, so the latch drops too. */
    fun close() {
        closeForBackgroundEdge()
        hasPreservedSnapshots = false
    }

    fun persistMode(isActive: Boolean): ForegroundRestorePersistMode = decisions.persistMode(
        isActive = isActive,
        hasPreservedSnapshots = hasPreservedSnapshots,
        isWindowOpen = isOpen,
        hasCohortEntries = cohort.isNotEmpty(),
    )

    /**
     * What actually gets written, given the mode.
     *
     * Which sessions, in what order, and which one is selected are the shared
     * core's rules — the same ones iOS applies. Both platforms used to spell
     * them out separately, and a snapshot silently dropped by one copy is a
     * session the next wake cannot reopen.
     *
     * What stays here is the records: the core answers in session ids and says
     * which of the three collections each one comes from, because the records
     * themselves carry display names, transports and tmux targets that mean
     * nothing to it. A session present in more than one collection is taken
     * from the freshest — `current` over `cohort` over `stored`.
     */
    fun persistWrite(
        mode: ForegroundRestorePersistMode,
        current: List<ForegroundRestoreSnapshot>,
        stored: ForegroundRestoreDocument?,
        preferred: String?,
        maxSnapshots: Int = ForegroundRestoreDocument.MAX_SNAPSHOTS,
    ): ForegroundRestoreWrite {
        val plan = decisions.persistPlan(
            mode = mode,
            currentSessionIds = current.map(ForegroundRestoreSnapshot::sessionId),
            cohortSessionIds = cohort.map(ForegroundRestoreSnapshot::sessionId),
            storedSessionIds = stored?.snapshots.orEmpty().map(ForegroundRestoreSnapshot::sessionId),
            preferredSelection = preferred,
            storedSelection = stored?.selectedSessionId,
            maxSnapshots = maxSnapshots,
        )
        val records = LinkedHashMap<String, ForegroundRestoreSnapshot>()
        stored?.snapshots?.forEach { records[it.sessionId] = it }
        cohort.forEach { records[it.sessionId] = it }
        current.forEach { records[it.sessionId] = it }
        return ForegroundRestoreWrite(
            snapshots = plan.entries.mapNotNull { records[it.sessionId] },
            selectedSessionId = plan.selectedSessionId,
        )
    }

    companion object {
        /**
         * Earliest a still-connected entry may be believed.
         *
         * The live-session list lags a session's published state: in the
         * 2026-08-17 iOS repro two SSH transports died 4ms apart and the
         * summary logged one millisecond later still printed both as
         * connected. Plain SSH has no reachability signal to confirm against,
         * so this floor stands in for one. It delays only the RETIREMENT of
         * entries believed alive — dead entries reconnect the moment they are
         * seen — so it costs no reconnect latency.
         */
        const val ALIVE_FLOOR_MILLISECONDS = 5_000L

        /**
         * Longest a window may stay open. Bounds every way an entry can fail
         * to reach a verdict: a wedged connect, a transport that never
         * reports, a prompt the user never answers.
         *
         * On iOS this is derived — the SSH handshake budget (40s) plus a 20s
         * margin — so a session wedged in `connecting` reaches its watchdog
         * verdict before losing its cohort place. Android has no connect
         * budget yet, so nothing rules on a wedged connect and this backstop
         * is the only bound on one. It is pinned to the same 60s so the two
         * platforms behave alike; when Android grows a connect watchdog this
         * must be derived from it rather than chosen, or the ordering breaks
         * silently.
         */
        const val MAX_WINDOW_MILLISECONDS = 60_000L

        /**
         * Longest step the window's clock may charge at once. A larger gap
         * means the process was frozen, and a suspension is not time spent
         * waiting on this wake.
         */
        const val MAX_CHARGE_MILLISECONDS = 2_000L

        /** How often an open window re-reads the world. */
        const val TICK_MILLISECONDS = 500L
    }
}
