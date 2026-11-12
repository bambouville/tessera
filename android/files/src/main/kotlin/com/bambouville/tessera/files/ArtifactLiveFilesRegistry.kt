package com.bambouville.tessera.files

import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardingLease
import com.bambouville.tessera.forwarding.PortForwardingRuntime
import java.io.Closeable
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * No Files connection can serve an artifact request. The message stays English
 * for logs and tests; a screen shows its own translated text for this type.
 */
class FilesConnectionUnavailableException : IOException("Files connection is unavailable")

/**
 * The terminal's SSH route cannot carry Files: the session is not connected,
 * or its authenticated route is gone. The message stays English for logs; the
 * Files screen shows its own translated text for each reason.
 */
class FilesRouteUnavailableException(val reason: Reason) : IllegalStateException(reason.message) {
    enum class Reason(val message: String) {
        NotConnected("The terminal session is not connected"),
        RouteUnavailable("The authenticated SSH route is unavailable"),
    }
}

/** Reads use only the channel a session's Files controller already holds. */
interface ArtifactLiveFiles {
    val hasLiveArtifactChannel: Boolean
    /** Passive availability; only an explicit user refresh may open the channel. */
    val canOpenArtifactChannel: Boolean get() = false
    /** Only an explicit user refresh may call this; loads, follow and lookups must stay passive. */
    suspend fun openArtifactChannel() {}
    /** Changes when the held connection is replaced; reading never opens, probes or waits for it. */
    val artifactConnectionGeneration: Long get() = 0L
    val artifactHome: String?
    val artifactDirectory: String?
    suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat?
    /** A served page's resource: canonical `path` must stay under canonical `allowedRoot`. */
    suspend fun readArtifactPageOnLiveChannel(
        allowedRoot: String,
        path: String,
        output: OutputStream,
        maxBytes: Long,
    ): ArtifactRemoteStat? = null
    /** Canonicalizes through the held channel; never opens Files or another route. */
    suspend fun realPathArtifactOnLiveChannel(path: String): String? = null
    suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat?
    suspend fun probeOnLiveChannel(command: String): String?
    /** Never opens Files or a route; the returned lease owns its forwarding runtime. */
    suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease? = null
}

internal suspend fun <C : AutoCloseable> RemoteFilesConnectionSlot<C>.acquireArtifactForwardingLease(
    rule: PortForwardRule,
    createRuntime: (C) -> PortForwardingRuntime,
): PortForwardingLease? {
    var allocated: PortForwardingLease? = null
    try {
        return withContext(Dispatchers.IO) {
            val live = currentOrNull ?: return@withContext null
            val runtime = createRuntime(live)
            try {
                val lease = runtime.start(rule)
                val result = WatchedArtifactForwardingLease(lease, { currentOrNull === live }, runtime::close)
                allocated = result
                if (!result.isOpen.value) {
                    result.close()
                    allocated = null
                    null
                } else result.also { it.watch() }
            } catch (failure: Throwable) {
                runCatching { runtime.close() }
                throw failure
            }
        }
    } catch (failure: Throwable) {
        // Cancellation at the IO handoff can discard an allocated lease.
        withContext(NonCancellable + Dispatchers.IO) { allocated?.close() }
        throw failure
    }
}

/** Passive, lease-owned watching continues even when the browser's foreground sweep stops. */
@OptIn(kotlinx.coroutines.ExperimentalForInheritanceCoroutinesApi::class)
private class WatchedArtifactForwardingLease(
    private val lease: PortForwardingLease,
    private val live: () -> Boolean,
    private val onClose: () -> Unit = {},
) : PortForwardingLease by lease {
    private val closed = AtomicBoolean(false)
    private val open = MutableStateFlow(true)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    override val isOpen = object : StateFlow<Boolean> by open {
        override val value: Boolean get() {
            if (!closed.get() && (!live() || !lease.isOpen.value)) close()
            return open.value
        }
        override val replayCache: List<Boolean> get() = listOf(value)
    }

    fun watch() {
        // IO workers are daemon threads; this never probes or keeps a carrier connected.
        scope.launch {
            runCatching {
                try { while (isOpen.value) delay(1_000) } finally { close() }
            }
        }
    }

    override fun close() {
        // Before the CAS: a reader racing a concurrent close must read it closed.
        open.value = false
        if (!closed.compareAndSet(false, true)) return
        scope.cancel()
        try { lease.close() } finally { onClose() }
    }
}

data class ArtifactRemoteStat(val path: String, val size: Long?, val modifiedAtMillis: Long?, val directory: Boolean)
class ArtifactSizeLimitExceeded(val bytes: Long) : IOException("artifact exceeds size limit")

/** Process-local registration; neither lookup nor registration opens a channel. */
object ArtifactLiveFilesRegistry {
    private class Entry(
        val hostId: String,
        val sessionId: String,
        private val source: ArtifactLiveFiles,
        private val sessionLive: () -> Boolean,
        private val channelOpenable: () -> Boolean,
    ) : ArtifactLiveFiles {
        @Volatile private var registered = true
        fun retire() { registered = false }
        override val hasLiveArtifactChannel: Boolean get() = registered && sessionLive() && source.hasLiveArtifactChannel
        override val canOpenArtifactChannel: Boolean get() = registered && channelOpenable() && !hasLiveArtifactChannel && source.canOpenArtifactChannel
        override val artifactConnectionGeneration: Long get() = source.artifactConnectionGeneration
        override val artifactHome: String? get() = source.artifactHome
        override val artifactDirectory: String? get() = source.artifactDirectory

        override suspend fun openArtifactChannel() {
            if (!canOpenArtifactChannel) throw FilesConnectionUnavailableException()
            source.openArtifactChannel()
            changed()
        }

        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? {
            if (!hasLiveArtifactChannel) return null
            return source.readArtifactOnLiveChannel(path, output, maxBytes)?.takeIf { hasLiveArtifactChannel }
        }
        override suspend fun readArtifactPageOnLiveChannel(allowedRoot: String, path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? {
            if (!hasLiveArtifactChannel) return null
            return source.readArtifactPageOnLiveChannel(allowedRoot, path, output, maxBytes)?.takeIf { hasLiveArtifactChannel }
        }
        override suspend fun realPathArtifactOnLiveChannel(path: String): String? {
            if (!hasLiveArtifactChannel) return null
            return source.realPathArtifactOnLiveChannel(path)?.takeIf { hasLiveArtifactChannel }
        }
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat? {
            if (!hasLiveArtifactChannel) return null
            return source.statArtifactOnLiveChannel(path)?.takeIf { hasLiveArtifactChannel }
        }
        override suspend fun probeOnLiveChannel(command: String): String? {
            if (!hasLiveArtifactChannel) return null
            return source.probeOnLiveChannel(command)?.takeIf { hasLiveArtifactChannel }
        }

        override suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease? {
            if (!hasLiveArtifactChannel) return null
            val lease = source.acquireForwardingLeaseOnLiveChannel(rule) ?: return null
            val result = WatchedArtifactForwardingLease(lease, { hasLiveArtifactChannel })
            return result.takeIf { it.isOpen.value }?.also { it.watch() }
        }
    }
    private val entries = mutableListOf<Entry>()
    private val mutableRevision = MutableStateFlow(0L)
    val revision: StateFlow<Long> = mutableRevision.asStateFlow()

    /** The predicate reads the owner's current state, including after a caller retains this source. */
    fun register(
        hostId: String,
        sessionId: String,
        files: ArtifactLiveFiles,
        sessionLive: () -> Boolean,
        channelOpenable: () -> Boolean = { false },
    ): Closeable {
        val entry = Entry(hostId, sessionId, files, sessionLive, channelOpenable)
        synchronized(entries) { entries += entry }
        changed()
        return Closeable {
            entry.retire()
            synchronized(entries) { entries.remove(entry) }
            changed()
        }
    }

    fun files(hostId: String): ArtifactLiveFiles? = synchronized(entries) {
        entries.lastOrNull { it.hostId == hostId && it.hasLiveArtifactChannel }
    }
    fun openable(hostId: String): ArtifactLiveFiles? = synchronized(entries) {
        entries.lastOrNull { it.hostId == hostId && it.canOpenArtifactChannel }
    }
    fun context(hostId: String): ArtifactLiveFiles? = files(hostId) ?: synchronized(entries) {
        entries.lastOrNull { it.hostId == hostId }
    }
    fun changed() { mutableRevision.update { it + 1 } }
}
