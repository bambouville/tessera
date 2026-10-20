package com.bambouville.tessera.feature.session

import java.io.Closeable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.withContext

/**
 * Demand-driven replacement of a Mosh session's observational SSH route.
 * The session controller owns the published route. This lease owns only an
 * in-flight replacement and retires the previous auxiliary route on success;
 * it never restarts the visible carrier or retries a remote command.
 */
internal class AgentAuxiliaryRouteLease<T : Closeable>(
    initial: T,
    private val usable: (T) -> Boolean,
    private val publish: (T, T) -> Boolean = { _, _ -> true },
    private val renew: suspend (T) -> T,
) : Closeable {
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var route = initial
    private var invalid = false
    private var closed = false
    private var pending: Renewal<T>? = null

    val current: T get() = synchronized(lock) { route }

    suspend fun acquire(): T {
        val renewal = synchronized(lock) {
            check(!closed) { "Agent auxiliary route lease is closed" }
            if (!invalid && usable(route)) return route
            (pending ?: Renewal<T>().also { next ->
                val previous = route
                next.task = scope.async(start = CoroutineStart.LAZY) {
                    var replacement: T? = null
                    var published = false
                    try {
                        val fresh = renew(previous).also { replacement = it }
                        synchronized(lock) {
                            if (closed || pending !== next) throw CancellationException("Auxiliary route retired")
                            if (!publish(previous, fresh)) throw CancellationException("Auxiliary route is stale")
                            route = fresh
                            invalid = false
                            published = true
                        }
                        withContext(NonCancellable + Dispatchers.IO) { runCatching { previous.close() } }
                        fresh
                    } finally {
                        if (!published) withContext(NonCancellable + Dispatchers.IO) {
                            replacement?.let { runCatching { it.close() } }
                        }
                        synchronized(lock) { if (pending === next) pending = null }
                    }
                }
                pending = next
            }).also { it.waiters += 1 }
        }
        try {
            renewal.task.start()
            return renewal.task.await()
        } finally {
            synchronized(lock) {
                renewal.waiters -= 1
                if (renewal.waiters == 0 && pending === renewal && !renewal.task.isCompleted) {
                    pending = null
                    renewal.task.cancel()
                }
            }
        }
    }

    fun invalidate(candidate: T) {
        synchronized(lock) { if (!closed && route === candidate) invalid = true }
    }

    override fun close() {
        synchronized(lock) {
            closed = true
            pending = null
        }
        scope.cancel()
    }

    private class Renewal<T> {
        lateinit var task: Deferred<T>
        var waiters = 0
    }
}
