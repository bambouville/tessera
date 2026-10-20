package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedProgramStatusMonitor
import com.bambouville.tessera.core.bridge.SharedProgramStatusSnapshot
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.core.bridge.SharedTmuxRuntime
import java.util.WeakHashMap
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * One session's OSC 7501 records, as the shared core keeps them: the raw
 * terminal's monitor (plain SSH, which answers the detection query) and the
 * tmux runtime's pane monitor. This only carries their snapshots; parsing,
 * lifetime and acknowledgement rules are the core's.
 *
 * Native calls never run under [lock], which guards the published halves
 * only. Every tmux call is made by a caller holding the controller's
 * transport lock, the same order a feed takes, so tmux pulls are serialized
 * and a newer revision is never overwritten by an older one.
 */
internal class SessionProgramStatus : AutoCloseable {
    private val lock = Any()
    private val mutableSnapshot = MutableStateFlow(SharedProgramStatusSnapshot.EMPTY)

    /** The raw terminal first, then tmux panes; empty while disabled. */
    val snapshot: StateFlow<SharedProgramStatusSnapshot> = mutableSnapshot.asStateFlow()

    @Volatile
    var enabled = false
        private set

    @Volatile
    private var raw: SharedProgramStatusMonitor? = null
    private var closed = false
    private var rawSnapshot = SharedProgramStatusSnapshot.EMPTY
    private var tmuxSnapshot = SharedProgramStatusSnapshot.EMPTY
    private var tmux: SharedTmuxRuntime? = null
    private var publishRevision = 0L
    private var enableEpoch = 0L
    private val tmuxEnableEpochs = WeakHashMap<SharedTmuxRuntime, Long>()

    /** Applies the Terminal setting. Call under the transport lock with the current tmux runtime. */
    fun setEnabled(enabled: Boolean, tmuxRuntime: SharedTmuxRuntime?) {
        if (enabled && raw == null) {
            val monitor = runCatching { SharedProgramStatusMonitor.create() }.getOrNull()
            synchronized(lock) {
                if (closed || raw != null) monitor?.close() else raw = monitor
            }
        }
        synchronized(lock) {
            if (this.enabled && !enabled) enableEpoch += 1
            this.enabled = enabled
            if (!enabled) {
                rawSnapshot = SharedProgramStatusSnapshot.EMPTY
                tmuxSnapshot = SharedProgramStatusSnapshot.EMPTY
                publishLocked()
            }
        }
        raw?.setEnabled(enabled)
        tmuxRuntime?.let(::prepareTmux)
        raw?.snapshot()?.let { applyRaw(it) }
        pullTmux(tmuxRuntime)
    }

    /**
     * One read of plain SSH output, before the terminal sees it. Returns the
     * reply to write to the remote first; empty when there is none.
     */
    fun feedRaw(bytes: ByteArray): ByteArray {
        if (!enabled) return EMPTY_REPLY
        val monitor = raw ?: return EMPTY_REPLY
        val feed = monitor.feed(bytes)
        if (feed.revision != rawSnapshot.revision) monitor.snapshot()?.let { applyRaw(it) }
        return feed.reply
    }

    /** The raw transport is gone: its records become history. */
    fun noteRawTransportLost() {
        val monitor = raw ?: return
        monitor.noteTransportLost()
        monitor.snapshot()?.let { applyRaw(it) }
    }

    /**
     * A tmux runtime handle took over the control path. A new handle starts
     * a new record lifetime, so its first snapshot replaces the old one
     * whatever its revision.
     */
    fun attachTmux(runtime: SharedTmuxRuntime) {
        prepareTmux(runtime)
        synchronized(lock) { if (tmux !== runtime) tmux = runtime }
        val snapshot = runtime.programStatus() ?: return
        synchronized(lock) {
            if (tmux !== runtime) return
            tmuxSnapshot = if (enabled) snapshot else SharedProgramStatusSnapshot.EMPTY
            publishLocked()
        }
    }

    /** A runtime event named [revision]; copy the document when it moved. */
    fun observeTmuxEvent(runtime: SharedTmuxRuntime?, revision: Long?) {
        if (runtime == null || revision == null) return
        val current = synchronized(lock) { tmux === runtime && tmuxSnapshot.revision == revision }
        if (!current) pullTmux(runtime)
    }

    /** Copy the runtime's current document (for example after its transport was lost). */
    fun pullTmux(runtime: SharedTmuxRuntime?) {
        if (runtime == null) return
        prepareTmux(runtime)
        val snapshot = runtime.programStatus() ?: return
        synchronized(lock) {
            if (tmux !== runtime) tmux = runtime
            else if (snapshot.revision < tmuxSnapshot.revision) return
            tmuxSnapshot = if (enabled) snapshot else SharedProgramStatusSnapshot.EMPTY
            publishLocked()
        }
    }

    /** A parked runtime must discard reports from before an intervening disable. */
    private fun prepareTmux(runtime: SharedTmuxRuntime) {
        val reset = synchronized(lock) {
            val previous = tmuxEnableEpochs[runtime] ?: 0L
            tmuxEnableEpochs[runtime] = enableEpoch
            previous < enableEpoch
        }
        if (reset) runtime.setProgramStatusEnabled(false)
        runtime.setProgramStatusEnabled(enabled)
    }

    /** Check results through [through]. Tmux panes need the transport lock held. */
    fun acknowledge(terminal: SharedProgramStatusTerminal, through: Long, tmuxRuntime: SharedTmuxRuntime?) {
        when (terminal) {
            SharedProgramStatusTerminal.Raw -> {
                val monitor = raw ?: return
                if (monitor.acknowledge(through)) monitor.snapshot()?.let { applyRaw(it) }
            }
            is SharedProgramStatusTerminal.Pane -> {
                val runtime = tmuxRuntime ?: return
                if (runtime.acknowledgeProgramStatus(terminal.paneId, through)) pullTmux(runtime)
            }
        }
    }

    private fun applyRaw(snapshot: SharedProgramStatusSnapshot) {
        synchronized(lock) {
            if (snapshot.revision < rawSnapshot.revision) return
            rawSnapshot = if (enabled) snapshot else SharedProgramStatusSnapshot.EMPTY
            publishLocked()
        }
    }

    private fun publishLocked() {
        val terminals = if (enabled) rawSnapshot.terminals + tmuxSnapshot.terminals else emptyList()
        if (terminals == mutableSnapshot.value.terminals) return
        publishRevision += 1
        mutableSnapshot.value = SharedProgramStatusSnapshot(publishRevision, terminals)
    }

    override fun close() {
        val monitor = synchronized(lock) {
            closed = true
            tmux = null
            tmuxEnableEpochs.clear()
            raw.also { raw = null }
        }
        monitor?.close()
    }

    private companion object {
        val EMPTY_REPLY = ByteArray(0)
    }
}
