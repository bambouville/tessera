package com.bambouville.tessera.data.continuity

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.job
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Everything about restore that must outlive one Activity.
 *
 * Restore used to keep all of this in the composition — the window, its latch,
 * the document mutex, and the "already evaluated" flag were all `remember`ed.
 * On iOS the equivalent state lives in a view that is never torn down, so the
 * port inherited a premise Android does not satisfy: here the UI is destroyed
 * routinely, and each time it was, the latch that arms the next wake went with
 * it and the cold-start path re-ran from scratch over sessions that were
 * already there.
 *
 * The write is the sharper half. It was launched on the Activity's own
 * coroutine scope, which is cancelled at ON_DESTROY — about thirty
 * milliseconds after ON_STOP on a real device, while the write is still inside
 * two suspending DataStore round trips. It is the only thing that arms
 * [preservedSnapshots], and that latch gates the entire wake path. So it runs
 * on [scope], from an immutable payload captured before the composition can go
 * away.
 *
 * The live sessions themselves are not here either, but they are no longer
 * owned by the composition: `LiveSessionStore` holds them for the process, so
 * a destroyed Activity no longer takes its transports with it. This class keeps
 * only what restore itself needs to know, and the two are deliberately apart —
 * restore has to survive a process that has no sessions at all.
 */
class SessionRestoreCoordinator private constructor(context: Context) {
    val documents = AndroidForegroundRestoreStore(context.applicationContext)

    /**
     * Outlives the Activity on purpose. A departing write that is cancelled is
     * indistinguishable from one that never mattered, and it is the write the
     * next wake seeds from.
     */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val window = ForegroundRestoreWindow()

    /**
     * Serialises every touch of the restore document. The background edge
     * writes while the next wake reads to seed its cohort, and those are the
     * same document — one composition-scoped `Mutex` per Activity could not
     * order a write from the departing one against a read from the arriving one.
     */
    private val documentLock = Mutex()

    private val _preservedSnapshots = MutableStateFlow(false)

    /**
     * Whether the last background edge left snapshots worth restoring.
     *
     * Observable, because arming it is the tail of an asynchronous write while
     * reading it is the first guard of the wake path. A plain field was read
     * once, by an effect whose keys never changed when the arm landed — so a
     * wake that recomposed first got no window at all, and nothing retried.
     */
    val preservedSnapshots: StateFlow<Boolean> = _preservedSnapshots.asStateFlow()

    private val _startupEvaluated = MutableStateFlow(false)

    /** The cold-start path has had its turn *in this process*. */
    val startupEvaluated: StateFlow<Boolean> = _startupEvaluated.asStateFlow()

    /**
     * Set when this instance has been replaced, which only a test does.
     *
     * Cancelling [scope] is not enough on its own: a persist reaches the store
     * through whichever coordinator its composition remembered, on the
     * composition's coroutine, so a write already in flight from a dying
     * Activity can still land — with an empty tab list, clearing the document
     * the next case has just seeded. A replaced coordinator writes nothing.
     */
    @Volatile private var retired = false

    private val _startupResolved = MutableStateFlow(false)
    val startupResolved: StateFlow<Boolean> = _startupResolved.asStateFlow()

    /**
     * Claim the cold-start pass. Returns false if this process already made it,
     * which is what stops an Activity recreation replaying the whole thing over
     * sessions that are already there.
     */
    fun claimStartupPass(): Boolean {
        if (_startupEvaluated.value) return false
        _startupEvaluated.value = true
        return true
    }

    fun markStartupResolved() { _startupResolved.value = true }

    @Volatile private var startupRearmPending = false

    /**
     * Remember that the app actually left, so the next composition gets its own
     * cold-start pass.
     *
     * Called only from a real background edge — the same
     * `!isChangingConfigurations && !externalUiActive` rule that already decides
     * whether to close the window — so a rotation or a file picker cannot arm
     * it. Re-arming is deliberately *not* done here: at ON_STOP nothing yet
     * knows whether an ON_DESTROY follows, and clearing the latches on an
     * Activity that survives would strand [startupResolved] false with no
     * cold-start effect left to run and set it, which is the gate the
     * foreground persist gets written behind.
     */
    fun noteRealBackgroundEdge() { startupRearmPending = true }

    /**
     * Take the re-arm, if one is owed, as a new composition starts.
     *
     * The pass is claimed for the process so a configuration change cannot
     * replay it: two plans 370ms apart, four reconnects, one host holding two
     * transports. But an Activity destroyed on a warm process is not a
     * configuration change, and the relaunch that follows has to be allowed to
     * decide for itself. Latching those two together meant a real relaunch
     * never restored and, because the pass never ran, never said so either.
     *
     * What that pass decides has since changed, and the re-arm matters more
     * rather than less for it. `LiveSessionStore` keeps the sessions for the
     * process, so a relaunch usually finds its hosts already on screen and
     * correctly plans nothing — while a relaunch after real process death finds
     * an empty tab list and restores. One re-armed pass, two honest answers.
     *
     * Consumed once per composition, so a relaunch re-arms and a rotation
     * (which arms nothing) still cannot.
     */
    fun consumeStartupRearm(): Boolean {
        if (!startupRearmPending) return false
        startupRearmPending = false
        _startupEvaluated.value = false
        _startupResolved.value = false
        return true
    }

    suspend fun <T> withDocument(block: suspend () -> T): T = documentLock.withLock { block() }

    /** Re-publish the latch after anything that could have changed it. */
    fun syncLatch() { _preservedSnapshots.value = window.hasPreservedSnapshots }

    fun closeWindow() {
        window.close()
        syncLatch()
    }

    /**
     * Write the restore document from a payload captured before this was
     * called, so nothing here reads composition state that may already be gone.
     */
    suspend fun persist(payload: RestorePersistPayload): RestorePersistReport = withDocument {
        if (retired) {
            return@withDocument RestorePersistReport(
                mode = ForegroundRestorePersistMode.LIVE_ONLY,
                storedCount = 0,
                writtenCount = 0,
                cohortCount = 0,
                policyWasNever = false,
            )
        }
        if (payload.policy == SessionRestorePolicy.NEVER) {
            window.close()
            syncLatch()
            documents.clear()
            return@withDocument RestorePersistReport(
                mode = ForegroundRestorePersistMode.LIVE_ONLY,
                storedCount = 0,
                writtenCount = 0,
                cohortCount = 0,
                policyWasNever = true,
            )
        }
        val mode = window.persistMode(payload.isActive)
        // Loaded for KEEP_COHORT too, not only for a merge: the window is open
        // there, so the session the user was last looking at may be mid-
        // reconnect and momentarily absent from the tab list — and the stored
        // selection is the only record of it. Passing null here wrote a
        // selection-less document and landed the wake on the host list.
        val stored = when (mode) {
            ForegroundRestorePersistMode.MERGE_WITH_STORED,
            ForegroundRestorePersistMode.KEEP_COHORT,
            -> documents.load()
            ForegroundRestorePersistMode.LIVE_ONLY -> null
        }
        val write = window.persistWrite(
            mode = mode,
            current = payload.live,
            stored = stored,
            preferred = payload.presentedSessionId,
        )
        val snapshots = write.snapshots
        if (snapshots.isEmpty()) {
            documents.clear()
        } else {
            documents.save(
                ForegroundRestoreDocument(
                    savedAtEpochMilliseconds = System.currentTimeMillis(),
                    snapshots = snapshots,
                    selectedSessionId = write.selectedSessionId,
                ),
            )
        }
        if (!payload.isActive) {
            window.armPreservedSnapshots(snapshots.isNotEmpty())
            syncLatch()
        }
        RestorePersistReport(
            mode = mode,
            storedCount = stored?.snapshots?.size ?: 0,
            writtenCount = snapshots.size,
            cohortCount = window.cohort.size,
            policyWasNever = false,
        )
    }

    companion object {
        @Volatile private var instance: SessionRestoreCoordinator? = null

        fun get(context: Context): SessionRestoreCoordinator =
            instance ?: synchronized(this) {
                instance ?: SessionRestoreCoordinator(context).also { instance = it }
            }

        /**
         * Forget everything this process learned about restore.
         *
         * Only a real process restart does this in production. An instrumented
         * test runs every case in one process, so without it the second case
         * inherits the first's "startup already evaluated" — which is the exact
         * state this class exists to keep, and would make every case after the
         * first a no-op.
         */
        fun resetForTests() {
            // Dropping the reference is not enough. The departing write runs on
            // [scope] precisely so it can outlive the Activity that queued it —
            // which means it also outlives a test, and lands on the document
            // the next case has just seeded. Cancel it and wait.
            val previous = synchronized(this) { instance.also { instance = null } }
            previous?.let {
                it.retired = true
                runBlocking { it.scope.coroutineContext.job.cancelAndJoin() }
            }
        }
    }
}

/**
 * The facts a write needs, lifted out of the composition so the write itself
 * can outlive it.
 */
data class RestorePersistPayload(
    val isActive: Boolean,
    val policy: SessionRestorePolicy?,
    val live: List<ForegroundRestoreSnapshot>,
    val presentedSessionId: String?,
)

data class RestorePersistReport(
    val mode: ForegroundRestorePersistMode,
    val storedCount: Int,
    val writtenCount: Int,
    val cohortCount: Int,
    val policyWasNever: Boolean,
)
