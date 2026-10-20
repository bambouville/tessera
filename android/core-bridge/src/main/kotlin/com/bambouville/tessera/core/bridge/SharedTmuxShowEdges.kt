package com.bambouville.tessera.core.bridge

import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

/** A show or hide edge for one presentation slot, in emission order. */
sealed interface SharedTmuxShowEdge {
    data object Hide : SharedTmuxShowEdge

    /**
     * [stepAtMillis] is when the show was emitted: the user's step that the
     * session's ~20 s intent window runs from.
     */
    data class Show(
        val source: SharedTmuxAuthorityShowSource,
        val stepAtMillis: Long,
    ) : SharedTmuxShowEdge
}

data class SharedTmuxShowEdgesState(
    val displayed: Boolean,
    /** A show was emitted and no hide has been; a debouncing hide still counts. */
    val isShown: Boolean,
    val showPending: Boolean,
    val transparent: Boolean,
    /** When to call [SharedTmuxShowEdges.tick]; null when nothing is pending. */
    val nextDeadlineMillis: Long?,
) {
    companion object {
        /** A slot starts not displayed and not shown, with nothing pending. */
        val INITIAL = SharedTmuxShowEdgesState(
            displayed = false,
            isShown = false,
            showPending = false,
            transparent = false,
            nextDeadlineMillis = null,
        )
    }
}

/**
 * Stateful JNI projection of the core's `TmuxShowEdgeTracker` for one
 * presentation slot (a host tab), with iOS's timing: a show waits 0.35 s to
 * settle, a hide is debounced 1.5 s, an explicit open waits 3 s for its slot,
 * and a transparent interval (one of Tessera's own excursions) that outlasts
 * 60 s was a background from its start.
 *
 * All times are milliseconds on one monotonic clock that keeps running while
 * the device sleeps. The tracker owns no timer: schedule [tick] at
 * [state]'s `nextDeadlineMillis`. Replacing the session behind a slot is
 * invisible here; keep one tracker per slot.
 */
class SharedTmuxShowEdges private constructor(handle: Long) : AutoCloseable {
    private val nativeHandle = AtomicLong(handle)

    /** The tracker's state after the last reduction. */
    @Volatile
    var state: SharedTmuxShowEdgesState = SharedTmuxShowEdgesState.INITIAL
        private set

    /** The slot is presented, the app is in the foreground and the lock is not up. */
    fun displayed(displayed: Boolean, nowMillis: Long): List<SharedTmuxShowEdge> =
        reduce("displayed", nowMillis, displayed)

    /** An explicit open targets this slot; shows even if it is already displayed. */
    fun explicitOpen(nowMillis: Long): List<SharedTmuxShowEdge> = reduce("explicitOpen", nowMillis)

    fun transparentBegan(nowMillis: Long): List<SharedTmuxShowEdge> = reduce("transparentBegan", nowMillis)

    fun transparentEnded(nowMillis: Long): List<SharedTmuxShowEdge> = reduce("transparentEnded", nowMillis)

    fun tick(nowMillis: Long): List<SharedTmuxShowEdge> = reduce("tick", nowMillis)

    @Synchronized
    private fun reduce(event: String, nowMillis: Long, displayed: Boolean? = null): List<SharedTmuxShowEdge> {
        val handle = nativeHandle.get()
        check(handle != 0L) { "tmux show edges are closed" }
        val request = requestJson(event, nowMillis, displayed).toString().encodeToByteArray()
        val response = checkNotNull(
            NativeCoreBindings.reduceTmuxShowEdges(handle, request.toDirectBuffer(), request.size),
        ) { "shared tmux show edges rejected $event" }
        // Most facts change nothing; skip the JSON parse for the short reply.
        if (response.contentEquals(UNCHANGED_RESPONSE)) return emptyList()
        val reply = parse(JSONObject(response.decodeToString()))
        reply.state?.let { state = it }
        return reply.edges
    }

    override fun close() {
        val handle = nativeHandle.getAndSet(0)
        if (handle != 0L) NativeCoreBindings.destroyTmuxShowEdges(handle)
    }

    /** [state] is null for the core's unchanged reply. */
    internal data class Reply(
        val edges: List<SharedTmuxShowEdge>,
        val state: SharedTmuxShowEdgesState?,
    )

    companion object {
        private const val VERSION = 1
        private val UNCHANGED_RESPONSE = """{"version":1,"unchanged":true}""".encodeToByteArray()

        fun create(): SharedTmuxShowEdges {
            NativeLibraries.ensureLoaded()
            val handle = NativeCoreBindings.createTmuxShowEdges()
            check(handle != 0L) { "shared tmux show edges are unavailable" }
            return SharedTmuxShowEdges(handle)
        }

        internal fun requestJson(event: String, nowMillis: Long, displayed: Boolean? = null): JSONObject =
            JSONObject()
                .put("version", VERSION)
                .put("event", event)
                .put("nowMillis", nowMillis)
                .apply { displayed?.let { put("displayed", it) } }

        internal fun parse(value: JSONObject): Reply {
            require(value.getInt("version") == VERSION)
            if (value.optBoolean("unchanged", false)) return Reply(emptyList(), null)
            val edges = value.getJSONArray("edges")
            return Reply(
                edges = buildList {
                    repeat(edges.length()) { index ->
                        val edge = edges.getJSONObject(index)
                        add(
                            when (edge.getString("kind")) {
                                "hide" -> SharedTmuxShowEdge.Hide
                                "show" -> SharedTmuxShowEdge.Show(
                                    SharedTmuxAuthorityShowSource.fromWire(edge.getString("source")),
                                    edge.getLong("stepAtMillis"),
                                )
                                else -> error("unknown tmux show edge")
                            },
                        )
                    }
                },
                state = SharedTmuxShowEdgesState(
                    displayed = value.getBoolean("displayed"),
                    isShown = value.getBoolean("isShown"),
                    showPending = value.getBoolean("showPending"),
                    transparent = value.getBoolean("transparent"),
                    nextDeadlineMillis = value.optionalLong("nextDeadlineMillis"),
                ),
            )
        }
    }
}

private fun JSONObject.optionalLong(key: String): Long? =
    takeIf { has(key) && !isNull(key) }?.getLong(key)
