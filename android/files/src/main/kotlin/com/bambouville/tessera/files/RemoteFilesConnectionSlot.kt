package com.bambouville.tessera.files

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The one file connection a [RemoteFilesController] holds, and its retirement.
 *
 * Closing an SFTP channel is blocking sshj work: the channel waits for the
 * server's CLOSE, up to the SSH timeout on a dead link, and a connection that
 * owns its route also disconnects the transport. Compose disposes the browser
 * on the main thread, so [close] never does that work itself. It detaches the
 * connection at once, so no later caller can reuse it, and closes it on a
 * scope of its own that outlives the controller's. Before closing it lets the
 * cancelled work it is given finish cleanup on the connection, for at most
 * [drainTimeoutMillis]: transfers blocked in sshj I/O on a dead link end only
 * at their own request timeouts.
 *
 * A connection that is no longer usable, such as one whose route a reconnect
 * replaced, is closed and replaced by the next [obtain] rather than reused.
 *
 * Closing is terminal. A connection that finishes opening after [close] is
 * closed the same way rather than kept, and nothing opens afterwards.
 */
internal class RemoteFilesConnectionSlot<C : AutoCloseable>(
    closeDispatcher: CoroutineDispatcher = Dispatchers.IO,
    /** Cheap and non-blocking; false once the connection has died. */
    private val isUsable: (C) -> Boolean = { true },
    private val drainTimeoutMillis: Long = DRAIN_TIMEOUT_MILLIS,
) {
    // Never cancelled: a close must run even though the work that asked for
    // it was cancelled. Each close ends on its own, so nothing accumulates.
    private val closer = CoroutineScope(SupervisorJob() + closeDispatcher)
    private val opening = Mutex()
    private val lock = Any()
    private var current: C? = null
    private var closed = false
    private val retiring = mutableListOf<Job>()

    /** The open, usable connection, or null. Never dials. */
    val currentOrNull: C? get() = synchronized(lock) { current }?.takeIf(isUsable)

    /**
     * The open connection, or the one [open] makes. Concurrent callers share
     * a single open. A connection that is no longer usable is closed and
     * replaced. Once [close] has run, this throws [CancellationException]
     * instead of opening, and a connection that [open] returns after [close]
     * is closed rather than kept.
     */
    suspend fun obtain(open: suspend () -> C): C = opening.withLock {
        val held = synchronized(lock) {
            if (closed) throw CancellationException(CLOSED)
            current
        }
        if (held != null) {
            if (isUsable(held)) return@withLock held
            val evicted = synchronized(lock) {
                if (closed) throw CancellationException(CLOSED)
                (current === held).also { if (it) current = null }
            }
            if (evicted) retire(held)
        }
        val opened = open()
        val kept = synchronized(lock) {
            if (!closed) current = opened
            !closed
        }
        if (!kept) {
            retire(opened)
            throw CancellationException(CLOSED)
        }
        opened
    }

    /**
     * Detaches the connection now and closes it off the calling thread, once
     * [drain] completes or [drainTimeoutMillis] passes. Repeat calls do nothing.
     */
    fun close(drain: Job? = null) {
        val detached = synchronized(lock) {
            closed = true
            current.also { current = null }
        } ?: return
        retire(detached, drain)
    }

    /**
     * [close], then waits until every connection retired so far has closed.
     * A connection an [obtain] still in flight retires later is not awaited,
     * so callers join their own obtaining work first.
     */
    suspend fun closeAndJoin() {
        close()
        synchronized(lock) { retiring.toList() }.joinAll()
    }

    private fun retire(connection: C, drain: Job? = null) {
        val job = closer.launch {
            if (drain != null) withTimeoutOrNull(drainTimeoutMillis) { drain.join() }
            // Uncaught, a failure here would reach the thread's handler.
            runCatching { connection.close() }
        }
        synchronized(lock) { retiring += job }
    }

    private companion object {
        const val CLOSED = "The remote files connection is closed"

        /** Long enough for a cancelled upload to delete its staging file on a healthy link. */
        const val DRAIN_TIMEOUT_MILLIS = 10_000L
    }
}
