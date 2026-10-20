package com.bambouville.tessera.feature.agentcenter

import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** A quiet pane needs no second hook to recover a missed read-only process proof. */
internal class AgentLifecycleProofRetry<K>(
    private val scope: CoroutineScope,
    private val intervalMillis: Long = 1_000,
    private val mayAttempt: () -> Boolean = { true },
) {
    private val jobs = ConcurrentHashMap<K, Job>()

    fun cancel(key: K) { jobs.remove(key)?.cancel() }
    fun clear() { jobs.values.forEach(Job::cancel); jobs.clear() }

    fun schedule(key: K, isCurrent: () -> Boolean, attempt: suspend () -> Boolean) {
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                var retryMillis = intervalMillis
                while (true) {
                    delay(retryMillis)
                    if (!isCurrent()) return@launch
                    if (!mayAttempt()) continue
                    if (!attempt()) return@launch
                    retryMillis = (retryMillis * 2).coerceAtMost(30_000)
                }
            } finally {
                currentCoroutineContext()[Job]?.let { jobs.remove(key, it) }
            }
        }
        jobs.put(key, job)?.cancel()
        job.start()
    }
}
