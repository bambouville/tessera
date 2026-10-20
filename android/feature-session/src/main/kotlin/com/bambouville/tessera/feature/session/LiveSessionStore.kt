package com.bambouville.tessera.feature.session

import android.os.SystemClock
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import com.bambouville.tessera.core.bridge.SharedTmuxAuthorityCarriedShow
import com.bambouville.tessera.core.bridge.SharedTmuxShowEdge
import com.bambouville.tessera.core.bridge.SharedTmuxShowEdges
import com.bambouville.tessera.data.SavedHost
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/**
 * The live sessions themselves, for as long as the process lives.
 *
 * `SessionRestoreCoordinator` made this move for restore's own state, and its
 * doc comment used to end by saying the sessions were deliberately left behind:
 * "a destroyed Activity still takes its transports with it; what changes is
 * that restore now notices and can bring them back." That was the compromise,
 * and this is the thing it was compensating for.
 *
 * Compose state and a `rememberCoroutineScope` belong to a composition, and a
 * destroyed Activity takes both with it. Not the cheap edges — the manifest
 * declares `configChanges` for orientation, screenSize, fontScale, uiMode and
 * the rest, so a rotation, a split-screen resize or a dark-mode switch never
 * reached the composition at all. What is left is a real destroy, and the
 * device log has both kinds: one the system did on its own (two `app_launch`
 * 370 ms apart, cause never established) and one after the user left and came
 * back to a warm process. Either closed SSH, killed the mosh client, dropped
 * the tmux `-CC` side channel with every forwarded port on it, and charged the
 * user a full reconnect. Restore then reopened the tabs, which is why the
 * reported bug went away — but the sessions had genuinely died and were being
 * rebuilt.
 *
 * Two consequences worth stating, because both are the point rather than side
 * effects:
 *
 * - Composition disposal is no longer indistinguishable from a user disconnect.
 *   `close()` is now only ever called for a real ending, so the
 *   `explicitDisconnect` it raises — and the `restore.delete(sessionId)` that
 *   follows from it — finally mean what they say.
 * - The cold-start pass now genuinely sees the sessions that are already up. It
 *   has always excluded them entry by entry (`ForegroundRestoreStartup.action`);
 *   until now there was simply never anything there to exclude on a relaunch.
 *
 * A session ends when the user ends it: from inside the session, from the
 * sessions list, or by removing the task from recents. Process death ends the
 * rest, and that is what restore is for.
 */
class LiveSessionStore private constructor() {

    /**
     * Outlives the Activity, like the controllers it drives. A transport's
     * reconnect ladder, resize debounce and tmux reply pumps all run here; on a
     * composition scope they were cancelled mid-flight at every destroy edge.
     */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /**
     * Whether the app presents its phone shell, which reads the restore
     * setting differently (`SessionRestorePresentationPolicy.effective`).
     * Controllers outlive the composition that knows it, so it lives here.
     */
    val usesCompactShell = MutableStateFlow(false)

    /** The open tabs, in the order they were opened. */
    val hosts = mutableStateListOf<SavedHost>()

    /** Host id to the id its live session is known by everywhere else. */
    val sessionIds = mutableStateMapOf<String, String>()
    val createdAt = mutableStateMapOf<String, Long>()

    /**
     * Visit order for the top bar's switcher. Creation order is the wrong key:
     * the session the user keeps returning to is the oldest one.
     */
    val lastTouched = mutableStateMapOf<String, Long>()

    /**
     * Which tab is on screen. Here rather than in the composition so an
     * Activity rebuilt around live sessions comes back to the one the user was
     * looking at, not to the list.
     */
    val presentedHost = mutableStateOf<String?>(null)

    /**
     * The tmux target and pairing attempt a session was opened against.
     *
     * Here because they are part of [ControllerKey]: a session restored onto a
     * stored tmux target, or opened by a QR continuation, is built around that
     * value. Left in the composition they came back empty after a recreation,
     * the key changed, and the store would have retired the very transport this
     * class exists to keep — for exactly the tmux sessions that cost the most
     * to rebuild.
     */
    val tmuxTargets = mutableStateMapOf<String, String?>()
    val pairingAttempts = mutableStateMapOf<String, String?>()

    private val controllers = LinkedHashMap<String, Entry>()

    /**
     * The count of activity ON_START edges this process has seen (§6.9).
     * Compose pauses its frame clock between ON_STOP and ON_START, so a
     * composition's Displayed value is only news about *now* when it was
     * computed in a later start epoch than the stop it would end.
     */
    val startEpoch = mutableLongStateOf(0L)

    /**
     * Per tab, a monotonic count of explicit opens: a pairing continuation, a
     * host or sessions-list tap, an Agent Center "open terminal", a share
     * routed to a host. Each one is a show even when the tab is already on
     * screen. A restore is not an explicit open.
     */
    val explicitOpenRequests = mutableStateMapOf<String, Long>()

    private class ShowSlot(val edges: SharedTmuxShowEdges) {
        var consumedExplicitOpens = 0L
        var tick: Job? = null
    }

    /** Show-edge state per tab; here so an Activity recreation keeps it. */
    private val showSlots = HashMap<String, ShowSlot>()

    /** A stop is process-wide, including tabs whose tracker is created later. */
    private var backgroundedInEpoch: Long? = null
    private data class ExcursionStop(val epoch: Long, val atMillis: Long)
    private var excursionStop: ExcursionStop? = null

    internal var showClock: () -> Long = { SystemClock.elapsedRealtime() }

    /** Tests capture the real tracker to verify its lifetime through its public API. */
    internal var createShowEdges: () -> SharedTmuxShowEdges = { SharedTmuxShowEdges.create() }

    /**
     * What makes a controller a *different* controller.
     *
     * A pairing target or attempt id arriving for a host is a different session
     * to the same machine, and the controller is built around it — so a change
     * here retires the old one rather than rebinding it. The screen used to get
     * this from `remember`'s keys, which no longer decide the controller's life.
     */
    internal data class ControllerKey(
        val hostId: String,
        val sessionId: String,
        val tmuxTarget: String?,
        val pairingAttemptId: String?,
    )

    private class Entry(val key: ControllerKey, val controller: SshSessionController)

    internal fun controller(
        key: ControllerKey,
        create: () -> SshSessionController,
    ): SshSessionController {
        var carriedShow: SharedTmuxAuthorityCarriedShow? = null
        controllers[key.hostId]?.let { existing ->
            if (existing.key == key) return existing.controller
            controllers.remove(key.hostId)
            // A replacement in the same slot is a transparent interval: a
            // show that had not finished (still waiting for its read, or
            // already claiming) moves to the new controller instead of being
            // lost with the old one.
            carriedShow = existing.controller.carriedShow()
            existing.controller.close()
        }
        return create().also { created ->
            controllers[key.hostId] = Entry(key, created)
            when {
                carriedShow != null -> created.shown(carriedShow.source, carriedShow.stepAtMillis)
                // A controller starts hidden (never sized before its first
                // show). One that transparently replaces the controller of a
                // tab the user is looking at takes over its shown state
                // instead, as iOS registers only an undisplayed slot hidden.
                showSlots[key.hostId]?.edges?.state?.isShown == true -> created.adoptShownSlot()
                else -> Unit
            }
        }
    }

    /**
     * `MainActivity.onStart`, before the lifecycle event is dispatched. Ends
     * an open excursion stop at its real end time: one past its bound (the
     * tick may never have run) hides now, ahead of the return's show.
     */
    fun activityStarted() {
        startEpoch.longValue += 1
        val now = showClock()
        if (endExcursion(now)) return
        showSlots.keys.toList().forEach { hostId ->
            val slot = showSlots[hostId] ?: return@forEach
            deliverShowEdge(hostId, slot, slot.edges.tick(nowMillis = now))
        }
    }

    /**
     * `MainActivity.onStop`. [realBackground] is `isRealBackgroundEdge()`:
     * a configuration change or one of Tessera's own excursions is not one.
     * A configuration change neither hides nor ends an intent; a show still
     * settling waits for the new activity's composition. A stop
     * [duringExcursion] is transparent (§6.9 A2) until it outlasts
     * [EXCURSION_TRANSPARENCY_MILLIS], and only then
     * hides like a real background (the user left from the picker or
     * "Open with").
     */
    fun activityStopped(realBackground: Boolean, duringExcursion: Boolean = false) {
        val epoch = startEpoch.longValue
        val now = showClock()
        if (!realBackground && !duringExcursion) {
            // A configuration change neither hides nor ends an intent. A show
            // still settling is the exception: its display was the old
            // activity's, and the new one may come up behind the lock, so it
            // waits for the new composition instead of settling on the
            // restart's tick. A shown slot is back within the debounce.
            showSlots.keys.toList().forEach { hostId ->
                val slot = showSlots[hostId] ?: return@forEach
                if (slot.edges.state.showPending) deliverShowEdge(hostId, slot, slot.edges.displayed(false, nowMillis = now))
            }
            return
        }
        if (realBackground) {
            // End any earlier transparent interval before reporting false.
            endExcursion(now)
            backgroundedInEpoch = epoch
        } else if (excursionStop == null) {
            excursionStop = ExcursionStop(epoch, now)
        }
        showSlots.keys.toList().forEach { hostId ->
            val slot = showSlots[hostId] ?: return@forEach
            val edges = if (realBackground) {
                slot.edges.displayed(false, nowMillis = now)
            } else {
                slot.edges.transparentBegan(nowMillis = now)
            }
            deliverShowEdge(hostId, slot, edges)
        }
    }

    /** Returns whether there was an interval to end; delivers owed hides before any wake read. */
    private fun endExcursion(now: Long): Boolean {
        val stop = excursionStop ?: return false
        excursionStop = null
        if (now - stop.atMillis >= EXCURSION_TRANSPARENCY_MILLIS) {
            backgroundedInEpoch = stop.epoch
        }
        showSlots.keys.toList().forEach { hostId ->
            val slot = showSlots[hostId] ?: return@forEach
            deliverShowEdge(hostId, slot, slot.edges.transparentEnded(nowMillis = now))
        }
        return true
    }

    /** An explicit open targeting [hostId]; folded into its next composed report. */
    fun requestExplicitOpen(hostId: String) {
        explicitOpenRequests[hostId] = (explicitOpenRequests[hostId] ?: 0L) + 1
    }

    /**
     * Composition's Displayed value for one tab (presented ∧ STARTED ∧ not
     * locked), delivered after the recomposition that computed it.
     */
    internal fun reportComposedDisplay(
        hostId: String,
        displayed: Boolean,
        startEpoch: Long,
        explicitOpens: Long,
    ) {
        if (!controllers.containsKey(hostId)) return
        val now = showClock()
        excursionStop?.let { stop ->
            // The stopped composition says nothing about now, and false is
            // forbidden inside the core's transparent interval.
            if (startEpoch <= stop.epoch) return
            // Fallback if a later epoch's composition is the first news of
            // the return. Normally activityStarted already ended this.
            endExcursion(now)
        }
        val slot = showSlots.getOrPut(hostId) { ShowSlot(createShowEdges()) }
        val effective = displayed && (backgroundedInEpoch?.let { startEpoch > it } ?: true)
        val opens = explicitOpens > slot.consumedExplicitOpens
        if (opens) slot.consumedExplicitOpens = explicitOpens
        // An open folds into the presentation it caused: one edge. Leaving
        // the screen is reported first, so an open never settles a show for
        // a tab this report says is gone; it then waits for the tab's return.
        val edges = buildList {
            if (!effective) addAll(slot.edges.displayed(false, nowMillis = now))
            if (opens) addAll(slot.edges.explicitOpen(nowMillis = now))
            if (effective) addAll(slot.edges.displayed(true, nowMillis = now))
        }
        deliverShowEdge(hostId, slot, edges)
    }

    private fun deliverShowEdge(hostId: String, slot: ShowSlot, edges: List<SharedTmuxShowEdge>) {
        val controller = controllers[hostId]?.controller
        edges.forEach { edge ->
            when (edge) {
                is SharedTmuxShowEdge.Show -> controller?.shown(edge.source, edge.stepAtMillis)
                SharedTmuxShowEdge.Hide -> controller?.hidden()
            }
        }
        slot.tick?.cancel()
        slot.tick = slot.edges.state.nextDeadlineMillis?.let { deadline ->
            scope.launch {
                delay((deadline - showClock()).coerceAtLeast(0))
                if (showSlots[hostId] === slot) {
                    slot.tick = null
                    deliverShowEdge(hostId, slot, slot.edges.tick(nowMillis = showClock()))
                }
            }
        }
    }

    /** Whether this host still has a live transport behind it. */
    fun isLive(hostId: String): Boolean = controllers.containsKey(hostId)

    val liveHostIds: Set<String> get() = controllers.keys.toSet()

    /**
     * End one session for good and forget its tab.
     *
     * Every removal from [hosts] has to come through here: a tab dropped
     * without closing its controller leaves a transport with nothing on screen
     * that can ever reach it again.
     */
    fun close(hostId: String) {
        closeShowSlot(hostId)
        controllers.remove(hostId)?.controller?.close()
        explicitOpenRequests.remove(hostId)
        hosts.removeAll { it.id == hostId }
        sessionIds.remove(hostId)
        createdAt.remove(hostId)
        lastTouched.remove(hostId)
        tmuxTargets.remove(hostId)
        pairingAttempts.remove(hostId)
        if (presentedHost.value == hostId) presentedHost.value = null
    }

    private fun closeShowSlot(hostId: String) {
        showSlots.remove(hostId)?.let { slot ->
            slot.tick?.cancel()
            slot.edges.close()
        }
    }

    /** Removing the task from recents is the one gesture that means all of them. */
    fun closeAll() {
        val hostIds = (controllers.keys + showSlots.keys).toSet()
        // Release every native show handle even if a controller teardown fails.
        hostIds.forEach(::closeShowSlot)
        hostIds.forEach(::close)
    }

    companion object {
        /** SharedTmuxShowEdges' documented core timing; all values use elapsed realtime. */
        const val SHOW_SETTLE_MILLIS = 350L
        const val HIDE_DEBOUNCE_MILLIS = 1_500L
        const val EXCURSION_TRANSPARENCY_MILLIS = 60_000L

        @Volatile private var instance: LiveSessionStore? = null

        fun get(): LiveSessionStore =
            instance ?: synchronized(this) {
                instance ?: LiveSessionStore().also { instance = it }
            }

        /**
         * Forget every live session this process has.
         *
         * Only process death does this in production. An instrumented test runs
         * every case in one process, and these sessions now deliberately
         * survive an Activity — so without this, case two inherits case one's
         * tabs and its cold-start pass correctly decides there is nothing to
         * restore.
         */
        fun resetForTests() {
            val previous = synchronized(this) { instance.also { instance = null } }
            previous?.let {
                // Controllers are main-thread objects and a test runs on the
                // instrumentation thread.
                runBlocking(Dispatchers.Main) { it.closeAll() }
                runBlocking { it.scope.coroutineContext.job.cancelAndJoin() }
            }
        }
    }
}
