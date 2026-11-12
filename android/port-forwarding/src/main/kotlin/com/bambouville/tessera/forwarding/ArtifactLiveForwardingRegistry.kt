package com.bambouville.tessera.forwarding

import java.io.Closeable
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** A session publishes an acquirer that uses its authenticated transport only. */
object ArtifactLiveForwardingRegistry {
    class Session internal constructor(
        val hostId: String,
        val sessionId: String,
        val states: StateFlow<Map<java.util.UUID, PortForwardingState>>,
        private val transportLive: () -> Boolean,
    ) {
        @Volatile private var active = true
        internal fun retire() { active = false }
        val canAcquire: Boolean get() = active && acquirers[sessionId]?.live?.invoke() == true
        val isLive: Boolean get() = active && (acquirers[sessionId]?.live?.invoke() ?: (transportLive() && states.value.values.any {
            it.status is PortForwardingStatus.Listening || it.status is PortForwardingStatus.Active
        }))
        suspend fun acquire(rule: PortForwardRule): PortForwardingLease? {
            if (!active) return null
            val acquirer = acquirers[sessionId] ?: return null
            if (!acquirer.live()) return null
            return acquirer.acquire(rule)
        }
    }
    private class Acquirer(val live: () -> Boolean, val acquire: suspend (PortForwardRule) -> PortForwardingLease?)
    private val acquirers = ConcurrentHashMap<String, Acquirer>()
    private val sessions = mutableListOf<Session>()
    private val mutableRevision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()

    fun register(hostId: String, sessionId: String, states: StateFlow<Map<java.util.UUID, PortForwardingState>>, transportLive: () -> Boolean): Closeable {
        val session = Session(hostId, sessionId, states, transportLive)
        synchronized(sessions) { sessions += session }
        changed()
        return Closeable {
            session.retire()
            synchronized(sessions) { sessions.remove(session) }
            changed()
        }
    }

    /** The controller owns this registration, including across Activity recreation. */
    fun publishAcquirer(sessionId: String, live: () -> Boolean, acquire: suspend (PortForwardRule) -> PortForwardingLease?): Closeable {
        val entry = Acquirer(live, acquire)
        acquirers[sessionId] = entry
        changed()
        return Closeable {
            if (acquirers.remove(sessionId, entry)) synchronized(sessions) {
                sessions.filter { it.sessionId == sessionId }.forEach(Session::retire)
            }
            changed()
        }
    }

    fun sessions(hostId: String): List<Session> = synchronized(sessions) {
        sessions.filter { it.hostId == hostId && it.isLive }
    }
    fun changed() { mutableRevision.update { it + 1 } }
}
