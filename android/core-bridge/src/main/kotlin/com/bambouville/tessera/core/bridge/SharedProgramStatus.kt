package com.bambouville.tessera.core.bridge

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

sealed interface SharedProgramStatusTerminal {
    data object Raw : SharedProgramStatusTerminal
    data class Pane(val paneId: Int) : SharedProgramStatusTerminal
}

enum class SharedProgramStatusState(val wireValue: String) {
    IDLE("idle"), WORKING("working"), BLOCKED("blocked"), DONE("done"), ERROR("error"),
}

enum class SharedProgramStatusBlockedKind(val wireValue: String) {
    PERMISSION("permission"), QUESTION("question"), AUTH("auth"),
}

/** Precedence matches the shared monitor: NEEDS_INPUT 3 > FAILED 2 > FINISHED 1. */
enum class SharedProgramStatusAttention(val wireValue: String, val precedence: Int) {
    NEEDS_INPUT("needsInput", 3), FAILED("failed", 2), FINISHED("finished", 1),
}

data class SharedProgramStatusEntry(
    val terminal: SharedProgramStatusTerminal,
    val idPath: List<String>,
    val state: SharedProgramStatusState,
    val kind: SharedProgramStatusBlockedKind?,
    val progress: Int?,
    val app: String?,
    val title: String?,
    val message: String?,
    val isHistorical: Boolean,
    val isUnreadResult: Boolean,
    val updateToken: Long,
    val resultToken: Long?,
    val attention: SharedProgramStatusAttention?,
)

data class SharedProgramStatusTerminalSnapshot(
    val terminal: SharedProgramStatusTerminal,
    val entries: List<SharedProgramStatusEntry>,
    val primaryEntry: SharedProgramStatusEntry?,
    val latestUnreadResultToken: Long?,
) {
    val attention: SharedProgramStatusAttention? get() = primaryEntry?.attention

    /** The blocked kind behind a NEEDS_INPUT attention, else null. */
    val blockedKind: SharedProgramStatusBlockedKind?
        get() = primaryEntry?.takeIf { attention == SharedProgramStatusAttention.NEEDS_INPUT }?.kind
}

data class SharedProgramStatusSnapshot(
    val revision: Long,
    val terminals: List<SharedProgramStatusTerminalSnapshot>,
) {
    fun terminal(terminal: SharedProgramStatusTerminal): SharedProgramStatusTerminalSnapshot? =
        terminals.firstOrNull { it.terminal == terminal }

    fun pane(paneId: Int): SharedProgramStatusTerminalSnapshot? = terminal(SharedProgramStatusTerminal.Pane(paneId))

    companion object {
        val EMPTY = SharedProgramStatusSnapshot(0, emptyList())

        /**
         * Decode the v1 ABI document. Malformed documents and unsupported versions throw.
         * Unknown state/kind/attention entries are dropped without shifting the primary index.
         */
        fun decode(document: ByteArray): SharedProgramStatusSnapshot {
            val value = JSONObject(document.decodeToString())
            require(value.programStatusLong("version") == 1L) { "unsupported program status version" }
            val terminals = value.getJSONArray("terminals")
            return SharedProgramStatusSnapshot(
                revision = value.programStatusLong("revision"),
                terminals = List(terminals.length()) { index ->
                    val row = terminals.getJSONObject(index)
                    val terminal = if (row.has("paneID")) {
                        SharedProgramStatusTerminal.Pane(row.programStatusInt("paneID"))
                    } else SharedProgramStatusTerminal.Raw
                    val entries = row.getJSONArray("entries")
                    // Keep the wire indices until primary has been resolved: a dropped entry
                    // must not silently promote the entry after it to primary.
                    val decoded = List(entries.length()) { entries.getJSONObject(it).programStatusEntry(terminal) }
                    SharedProgramStatusTerminalSnapshot(
                        terminal = terminal,
                        entries = decoded.filterNotNull(),
                        primaryEntry = row.programStatusOptionalInt("primary")?.let(decoded::getOrNull),
                        latestUnreadResultToken = row.programStatusOptionalLong("latestUnreadResultToken"),
                    )
                },
            )
        }
    }
}

private fun JSONObject.programStatusEntry(terminal: SharedProgramStatusTerminal): SharedProgramStatusEntry? {
    val stateValue = getString("state")
    val state = SharedProgramStatusState.entries.firstOrNull { it.wireValue == stateValue } ?: return null
    val kindValue = programStatusOptionalString("kind")
    val kind = kindValue?.let { wire -> SharedProgramStatusBlockedKind.entries.firstOrNull { it.wireValue == wire } }
    if (kindValue != null && kind == null) return null
    val attentionValue = programStatusOptionalString("attention")
    val attention = attentionValue?.let { wire -> SharedProgramStatusAttention.entries.firstOrNull { it.wireValue == wire } }
    if (attentionValue != null && attention == null) return null
    val path = getJSONArray("idPath")
    return SharedProgramStatusEntry(
        terminal = terminal,
        idPath = List(path.length()) { path.getString(it) },
        state = state,
        kind = kind,
        progress = programStatusOptionalInt("progress"),
        app = programStatusOptionalString("app"),
        title = programStatusOptionalString("title"),
        message = programStatusOptionalString("message"),
        isHistorical = getBoolean("historical"),
        isUnreadResult = getBoolean("unreadResult"),
        updateToken = programStatusLong("updateToken"),
        resultToken = programStatusOptionalLong("resultToken"),
        attention = attention,
    )
}

private fun JSONObject.programStatusOptionalString(key: String): String? = if (has(key)) getString(key) else null
private fun JSONObject.programStatusOptionalInt(key: String): Int? = if (has(key)) programStatusInt(key) else null
private fun JSONObject.programStatusOptionalLong(key: String): Long? = if (has(key)) programStatusLong(key) else null

// org.json's getInt/getLong truncate fractions and accept numeric strings.
// ABI numbers are JSON integers; malformed values must not retarget panes or tokens.
private fun JSONObject.programStatusLong(key: String): Long =
    (get(key) as? Number)?.toString()?.toLongOrNull()
        ?: throw IllegalArgumentException("program status $key must be an integer")

private fun JSONObject.programStatusInt(key: String): Int = programStatusLong(key).also {
    require(it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) { "program status $key is out of range" }
}.toInt()

/** Shared two-pass copy boundary for raw and tmux monitors. A concurrent size change refuses the copy. */
internal fun copyProgramStatusDocument(copy: (ByteBuffer?, Int) -> Int): ByteArray? {
    val size = copy(null, 0)
    if (size < 0) return null
    val output = ByteBuffer.allocateDirect(maxOf(1, size))
    if (copy(output, size) != size) return null
    return ByteArray(size).also { output.position(0); output.get(it) }
}

/** Opaque shared-core monitor for a raw terminal; parsing and acknowledgement stay in the core. */
class SharedProgramStatusMonitor private constructor(handle: Long) : AutoCloseable {
    private val nativeHandle = AtomicLong(handle)
    private val feedLock = Any()
    private var replyBuffer = ByteBuffer.allocateDirect(TESSERA_PROGRAM_STATUS_MAX_REPLY_BYTES)

    data class Feed(val reply: ByteArray, val revision: Long)

    /**
     * Replies must reach the remote before these bytes reach the terminal.
     * Oversized input is scanned in ordered ABI-sized slices. A closed monitor returns empty replies and revision 0.
     */
    fun feed(bytes: ByteArray, offset: Int = 0, count: Int = bytes.size): Feed = synchronized(feedLock) {
        require(offset >= 0 && count >= 0 && offset <= bytes.size && count <= bytes.size - offset)
        val handle = nativeHandle.get()
        if (handle == 0L) return@synchronized Feed(byteArrayOf(), 0)
        val replies = ByteArrayOutputStream()
        val revision = LongArray(1)
        var position = offset
        val end = offset + count
        do {
            val chunkSize = minOf(end - position, CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES.toInt())
            // A 9-byte BEL query is the shortest; one more can complete from the previous slice.
            val replyCapacity = maxOf(TESSERA_PROGRAM_STATUS_MAX_REPLY_BYTES, (chunkSize / 9 + 1) * QUERY_REPLY_BYTES)
            if (replyBuffer.capacity() < replyCapacity) replyBuffer = ByteBuffer.allocateDirect(replyCapacity)
            replyBuffer.clear()
            val input = if (chunkSize == 0) null else bytes.copyOfRange(position, position + chunkSize).toDirectBuffer()
            val written = NativeCoreBindings.feedProgramStatusMonitor(
                handle, input, chunkSize, replyBuffer, replyBuffer.capacity(), revision,
            )
            if (written < 0) break
            check(written <= replyBuffer.capacity()) { "invalid program status reply size" }
            if (written > 0) {
                val reply = ByteArray(written)
                replyBuffer.position(0)
                replyBuffer.get(reply)
                replies.write(reply)
            }
            position += chunkSize
        } while (position < end)
        Feed(replies.toByteArray(), revision[0])
    }

    fun setEnabled(enabled: Boolean): CoreCallResult {
        val handle = nativeHandle.get()
        if (handle == 0L) return CoreCallResult.StaleHandle
        return NativeCoreBindings.setProgramStatusMonitorEnabled(handle, enabled).toCoreCallResult()
    }

    fun snapshot(): SharedProgramStatusSnapshot? {
        val handle = nativeHandle.get()
        if (handle == 0L) return null
        val document = copyProgramStatusDocument { output, capacity ->
            NativeCoreBindings.copyProgramStatusMonitorSnapshot(handle, output, capacity)
        } ?: return null
        return runCatching { SharedProgramStatusSnapshot.decode(document) }.getOrNull()
    }

    fun acknowledge(through: Long): Boolean {
        val handle = nativeHandle.get()
        return handle != 0L && NativeCoreBindings.acknowledgeProgramStatusMonitor(handle, through) == 1
    }

    fun noteTransportLost() {
        val handle = nativeHandle.get()
        if (handle != 0L) NativeCoreBindings.noteProgramStatusMonitorTransportLost(handle)
    }

    override fun close() {
        val handle = nativeHandle.getAndSet(0)
        if (handle != 0L) NativeCoreBindings.destroyProgramStatusMonitor(handle)
    }

    companion object {
        const val TESSERA_PROGRAM_STATUS_MAX_REPLY_BYTES = 4096
        // ProgramStatusReply.query: ESC ] 7501 ; ? ST.
        private const val QUERY_REPLY_BYTES = 10

        fun create(): SharedProgramStatusMonitor {
            val state = CoreBridge.inspect()
            check(state is CoreBridgeState.Ready) {
                "shared core unavailable: ${(state as CoreBridgeState.Failed).reason}"
            }
            val handle = NativeCoreBindings.createProgramStatusMonitor()
            check(handle != 0L) { "shared core refused to create a program status monitor" }
            return SharedProgramStatusMonitor(handle)
        }
    }
}
