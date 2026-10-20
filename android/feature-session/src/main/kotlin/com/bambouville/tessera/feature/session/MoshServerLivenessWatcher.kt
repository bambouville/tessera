package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedMoshServerLivenessPolicy.NextProbe
import com.bambouville.tessera.core.bridge.SharedMoshServerLivenessPolicy.Outcome
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Keep a cancelled blocking SSH worker (and its cleanup) from multiplying on retry timers. */
internal class MoshServerLivenessProbeSlot {
    private val occupied = AtomicBoolean(false)

    fun reserve(): Boolean = occupied.compareAndSet(false, true)

    fun releaseAfter(worker: Job, cleanup: () -> Job?) {
        worker.invokeOnCompletion {
            val pendingCleanup = cleanup()
            if (pendingCleanup == null) occupied.set(false)
            else pendingCleanup.invokeOnCompletion { occupied.set(false) }
        }
    }
}

/**
 * Awaits [work] for at most [budgetMillis] of time the owner was not being
 * asked, or returns null once that budget is spent. A Face ID or fingerprint
 * sheet must not be torn down because the user took a while to answer it
 * (iOS pauses its probe deadline the same way).
 */
internal suspend fun <T> awaitProbeDeadline(
    work: Deferred<T>,
    budgetMillis: Long,
    ownerPrompting: () -> Boolean,
    tickMillis: Long = 250,
): T? {
    var remaining = budgetMillis
    while (!work.isCompleted) {
        val paused = ownerPrompting()
        if (!paused && remaining <= 0) return null
        val step = if (paused) tickMillis else minOf(tickMillis, remaining)
        withTimeoutOrNull(step) { work.join() }
        if (!paused) remaining -= step
    }
    return work.await()
}

/** Platform task around the shared policy. All timing/verdict policy is injected, never recreated here. */
internal class MoshServerLivenessWatcher(
    private val scope: CoroutineScope,
    private val probe: suspend (Int) -> ProbeResult,
    private val graceMillis: () -> Long,
    /** Shared `MoshServerLivenessPolicy.nextProbe`: outcome, consecutive host failures, asked owner. */
    private val nextProbe: (Outcome, Int, Boolean) -> NextProbe,
    private val onServerGone: (Int) -> Unit,
    private val record: (String, Map<String, String>) -> Unit = { _, _ -> },
    private val sleep: suspend (Long) -> Unit = { delay(it) },
    private val clockMillis: () -> Long = { System.nanoTime() / 1_000_000 },
    private val dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
) {
    data class Conditions(
        val connectedEmitted: Boolean,
        val transportReachable: Boolean,
        val appForeground: Boolean,
        val serverPid: Int?,
        /**
         * The probe's own owner challenge is up. Its credential screen stops
         * the activity, which is not the app leaving: cancelling there would
         * lose the answer and ask again on return.
         */
        val ownerPromptPending: Boolean = false,
    ) {
        val watchedPid: Int?
            get() = serverPid?.takeIf {
                connectedEmitted && !transportReachable && (appForeground || ownerPromptPending) && it > 0
            }
    }

    data class ProbeResult(val outcome: Outcome, val neededOwnerAuthorization: Boolean = false) {
        companion object {
            /** Cancelling an unanswered owner challenge settles nothing about the host. */
            fun timedOut(neededOwnerAuthorization: Boolean, ownerAuthorizationPending: Boolean) = ProbeResult(
                if (ownerAuthorizationPending) Outcome.UNKNOWN else Outcome.HOST_UNREACHABLE,
                neededOwnerAuthorization,
            )
        }
    }

    private val lock = Any()
    private var job: Job? = null
    // Retain the episode after GONE or an on-wake answer so duplicate connectivity
    // emissions cannot start another timer. A false condition (the app leaving the
    // foreground, the transport recovering) or a changed PID rearms it.
    private var watchedPid: Int? = null
    private var generation = 0L

    fun update(conditions: Conditions) = synchronized(lock) {
        val pid = conditions.watchedPid
        if (pid == watchedPid) return@synchronized
        stopLocked(if (pid == null) "conditions" else "pid-changed")
        if (pid == null) return@synchronized
        watchedPid = pid
        val run = ++generation
        val grace = graceMillis()
        record("mosh_server_liveness_watch_start", mapOf("pid" to "$pid", "grace_ms" to "$grace"))
        job = scope.launch(dispatcher, start = CoroutineStart.LAZY) { run(pid, run, grace) }
        job?.start()
    }

    fun stop(reason: String) = synchronized(lock) { stopLocked(reason) }

    private fun stopLocked(reason: String) {
        if (watchedPid != null) {
            record("mosh_server_liveness_watch_stop", mapOf("pid" to "$watchedPid", "reason" to reason))
        }
        ++generation
        watchedPid = null
        job?.cancel()
        job = null
    }

    private suspend fun run(pid: Int, run: Long, grace: Long) {
        try {
            sleep(grace)
            var hostFailures = 0
            var probeCount = 0
            while (isCurrent(run)) {
                val started = clockMillis()
                val result = probe(pid)
                currentCoroutineContext().ensureActive()
                val delayMillis = synchronized(lock) {
                    if (generation != run) return
                    ++probeCount
                    hostFailures = if (result.outcome == Outcome.HOST_UNREACHABLE) hostFailures + 1 else 0
                    val next = nextProbe(result.outcome, hostFailures, result.neededOwnerAuthorization)
                    val delay = (next as? NextProbe.After)?.millis
                    record(
                        "mosh_server_liveness_probe",
                        mapOf(
                            "pid" to "$pid", "outcome" to result.outcome.name,
                            "probe_count" to "$probeCount", "host_failures" to "$hostFailures",
                            "next_delay_ms" to when (next) {
                                is NextProbe.After -> "${next.millis}"
                                NextProbe.OnWake -> "on-wake"
                                NextProbe.None -> "none"
                            },
                            "elapsed_ms" to "${clockMillis() - started}",
                            "owner_authorization" to "${result.neededOwnerAuthorization}",
                        ),
                    )
                    if (result.outcome == Outcome.GONE) onServerGone(pid)
                    if (delay == null) {
                        val reason = if (next == NextProbe.OnWake) "awaiting-wake" else "settled"
                        record("mosh_server_liveness_watch_stop", mapOf("pid" to "$pid", "reason" to reason))
                    }
                    delay
                } ?: return
                sleep(delayMillis)
            }
        } finally {
            synchronized(lock) {
                if (generation == run) job = null
            }
        }
    }

    private fun isCurrent(run: Long): Boolean = synchronized(lock) { generation == run }
}
