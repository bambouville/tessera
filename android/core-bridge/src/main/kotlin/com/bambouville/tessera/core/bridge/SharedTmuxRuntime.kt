package com.bambouville.tessera.core.bridge

import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject

/** The two render paths the shared ledger supports. */
enum class SharedTmuxRenderProfile(val wireValue: String) {
    Inline("inline"),
    SideChannel("sideChannel"),
    ;

    companion object {
        fun fromWire(value: String): SharedTmuxRenderProfile =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown render profile '$value'")
    }
}

enum class SharedTmuxRenderStage(val wireValue: String) {
    Viewport("viewport"),
    ViewportOnly("viewportOnly"),
    Deep("deep"),
    ;

    companion object {
        fun fromWire(value: String): SharedTmuxRenderStage =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown render stage '$value'")
    }
}

enum class SharedTmuxSurfacePresentation(val wireValue: String) {
    Single("single"),
    Grid("grid"),
    Overlay("overlay"),
    ;

    companion object {
        fun fromWire(value: String): SharedTmuxSurfacePresentation =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown surface presentation '$value'")
    }
}

enum class SharedTmuxRenderFeedSource(val wireValue: String) {
    PaneOutput("pane-output"),
    ViewportRepaint("tmux-repaint-viewport"),
    ViewportRefresh("tmux-repaint-viewport-refresh"),
    DeepRepaint("tmux-repaint-deep"),
    RepaintScrub("tmux-repaint-scrub"),
    ForegroundReplay("foreground-replay"),
    MoshHistory("mosh-history"),
    ;

    companion object {
        fun fromWire(value: String): SharedTmuxRenderFeedSource =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown render feed source '$value'")
    }
}

enum class SharedTmuxRenderMouseMode(val wireValue: String) {
    Off("off"),
    Tracking("tracking"),
    ;

    companion object {
        fun fromWire(value: String): SharedTmuxRenderMouseMode =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown render mouse mode '$value'")
    }
}

enum class SharedTmuxRenderHistoryPlacement(val wireValue: String) {
    Bottom("bottom"),
    PreserveDistanceFromBottom("preserveDistanceFromBottom"),
    ;

    companion object {
        fun fromWire(value: String): SharedTmuxRenderHistoryPlacement =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown render history placement '$value'")
    }
}

/** A platform-declared terminal surface, field-for-field with `SurfaceDeclaration`. */
data class SharedTmuxSurfaceDeclaration(
    val surfaceId: String,
    val presentation: SharedTmuxSurfacePresentation,
    val windowId: Int? = null,
    val paneId: Int? = null,
) {
    init {
        require(surfaceId.isNotBlank()) { "surface id must not be blank" }
    }

    internal fun toWire(): Map<String, Any> = buildMap {
        put("surfaceID", surfaceId)
        put("presentation", presentation.wireValue)
        windowId?.let { put("windowID", it) }
        paneId?.let { put("paneID", it) }
    }
}

/** Owner of the rows currently permitted to enter a render surface. */
data class SharedTmuxRenderOwner(
    val windowId: Int?,
    val paneId: Int?,
    val epoch: Long,
) {
    init {
        require(epoch >= 0) { "render owner epoch must be non-negative" }
    }

    internal fun toWire(): Map<String, Any> = buildMap {
        windowId?.let { put("windowID", it) }
        paneId?.let { put("paneID", it) }
        put("epoch", epoch)
    }
}

/**
 * Ordered, byte-free instructions emitted by the v2 tmux runtime callback.
 * `Feed.bytesRef` is deliberately a handle-local reference; obtain its bytes
 * with [SharedTmuxRuntime.takeRenderBytes] before executing a later effect.
 */
sealed interface SharedTmuxRenderEffect {
    data class SendCommand(val command: String) : SharedTmuxRenderEffect
    data class CommandReply(val tag: Long, val success: Boolean, val lines: List<String>) : SharedTmuxRenderEffect
    data class BindSurface(val surfaceId: String, val owner: SharedTmuxRenderOwner) : SharedTmuxRenderEffect
    data class Feed(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner,
        val bytesRef: Long,
        val source: SharedTmuxRenderFeedSource,
    ) : SharedTmuxRenderEffect

    data class SaveWindowModes(val surfaceId: String, val windowId: Int) : SharedTmuxRenderEffect
    data class RestoreWindowModes(
        val surfaceId: String,
        val windowId: Int,
        val paneInAltScreen: Boolean,
    ) : SharedTmuxRenderEffect

    data class ResolveSurfaceState(val surfaceId: String, val request: Long) : SharedTmuxRenderEffect
    data class ArmTimer(val token: Long, val milliseconds: Int) : SharedTmuxRenderEffect
    data class CancelTimer(val token: Long) : SharedTmuxRenderEffect
    data object InitialRenderReady : SharedTmuxRenderEffect
    data object RequestTransportFullFrame : SharedTmuxRenderEffect
    data class HistoryReady(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner,
        val depth: Int,
        val historySize: Int,
        val placement: SharedTmuxRenderHistoryPlacement,
    ) : SharedTmuxRenderEffect

    /**
     * One inline (SSH+tmux) deep capture has settled for this surface.
     *
     * The ledger emits exactly one of these per gesture-triggered
     * `scrollbackRequested`/`findOpened` — including the ignored, exhausted
     * and aborted outcomes — so a platform that latched a history gesture can
     * always release it. [depth] is the credited capture depth, [historySize]
     * the tmux `history_size` behind it, and [canDeepen] whether another
     * request can still fetch older rows. Both platforms keep only these two
     * facts plus their own in-flight latch; every other decision is ledger
     * state.
     */
    data class InlineHistorySettled(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner,
        val depth: Int,
        val historySize: Int,
        val canDeepen: Boolean,
    ) : SharedTmuxRenderEffect

    data class RefreshCompleted(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner,
        val stage: SharedTmuxRenderStage,
        val correlation: Long,
    ) : SharedTmuxRenderEffect

    data class RefreshFailed(
        val surfaceId: String,
        val correlation: Long,
        val reason: String,
    ) : SharedTmuxRenderEffect

    /**
     * Force one transport-painted full frame for `correlation`. The ledger
     * owns the reservation and re-emits this effect under the same correlation
     * whenever it rebinds the surface to the same window and pane, so the
     * adapter never has to notice a rebind: it paints for the owner named here
     * and reports the outcome back as a fact.
     *
     * `owner` is null before the surface's first bind, which the mosh
     * initial-attach claim depends on -- Mosh paints the whole PTY, so the
     * frame rides the untagged painter feed exactly like every other frame
     * before the first bind.
     */
    data class RequestCorrelatedTransportFullFrame(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner?,
        val correlation: Long,
        val reason: String,
    ) : SharedTmuxRenderEffect

    data class TransportFullFrameCompleted(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner?,
        val correlation: Long,
    ) : SharedTmuxRenderEffect

    data class TransportFullFrameFailed(
        val surfaceId: String,
        val correlation: Long,
        val reason: String,
    ) : SharedTmuxRenderEffect

    data class Diagnostic(val message: String) : SharedTmuxRenderEffect
}

/**
 * Facts submitted by the Android adapter to the shared render ledger.
 * Encoding is canonical (lexicographically sorted keys, no null optionals),
 * keeping the Android producer aligned with the shared ABI encoder.
 */
sealed interface SharedTmuxRenderFact {
    data class TransportAttached(val profile: SharedTmuxRenderProfile) : SharedTmuxRenderFact
    data object TransportLost : SharedTmuxRenderFact
    data class SurfacesDeclared(val surfaces: List<SharedTmuxSurfaceDeclaration>) : SharedTmuxRenderFact
    data class ClientSize(val columns: Int, val rows: Int) : SharedTmuxRenderFact
    /** Natural whole-window Mosh activity, excluding forced frame replays. */
    data class TransportOutputObserved(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner,
    ) : SharedTmuxRenderFact
    data class SurfaceState(
        val surfaceId: String,
        val request: Long,
        val altScreen: Boolean,
        val mouseMode: SharedTmuxRenderMouseMode,
        val columns: Int,
        val rows: Int,
    ) : SharedTmuxRenderFact

    data object AppForeground : SharedTmuxRenderFact
    data object AppBackground : SharedTmuxRenderFact
    data class TimerFired(val token: Long) : SharedTmuxRenderFact
    data class ScrollbackRequested(
        val surfaceId: String,
        val pointsY: Double,
        val isInertial: Boolean,
    ) : SharedTmuxRenderFact

    data class ScrollbackReturnedToTail(val surfaceId: String) : SharedTmuxRenderFact
    data class HistoryPresented(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner,
    ) : SharedTmuxRenderFact
    data class HistoryPresentationFailed(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner,
    ) : SharedTmuxRenderFact
    data class FindOpened(val surfaceId: String) : SharedTmuxRenderFact
    data object UserInput : SharedTmuxRenderFact
    data class ScrollbackLimit(val lines: Int) : SharedTmuxRenderFact
    data class RefreshRequested(
        val surfaceId: String,
        val stage: SharedTmuxRenderStage,
        val reason: String,
    ) : SharedTmuxRenderFact

    data class CorrelatedRefreshRequested(
        val surfaceId: String,
        val stage: SharedTmuxRenderStage,
        val reason: String,
        val correlation: Long,
    ) : SharedTmuxRenderFact

    /**
     * Reserve one transport-painted full frame under `correlation`: the
     * side-channel twin of [CorrelatedRefreshRequested]. The ledger holds the
     * reservation and decides, on each of its own surface rebinds, whether to
     * re-issue it or fail it -- the rule used to be re-derived privately here
     * and in the Apple controller, and one of them always forgot a case.
     */
    data class CorrelatedTransportFullFrameRequested(
        val surfaceId: String,
        val reason: String,
        val correlation: Long,
    ) : SharedTmuxRenderFact

    /**
     * The reserved frame was rendered by `owner`. Like [HistoryPresented] this
     * is an acceptance by a mounted surface, never an acknowledgement that the
     * driver was asked: enqueueing the force is not evidence the frame reached
     * the screen, and a stale-frame flash is the regression the reservation
     * exists to prevent.
     */
    data class TransportFullFramePresented(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner?,
        val correlation: Long,
    ) : SharedTmuxRenderFact

    data class TransportFullFramePresentationFailed(
        val surfaceId: String,
        val owner: SharedTmuxRenderOwner?,
        val correlation: Long,
        val reason: String,
    ) : SharedTmuxRenderFact

    /** Begin one optimistic window reorder under an adapter-owned token. */
    data class ReorderBegan(val token: Long, val order: List<Int>) : SharedTmuxRenderFact
    /** The mutation commands ACKed; full-list truth still owns confirmation. */
    data class ReorderConfirmed(val token: Long) : SharedTmuxRenderFact
    /** The mutation failed, disconnected, or exceeded the adapter deadline. */
    data class UnwrittenCommandsCancelled(val tags: List<Long>) : SharedTmuxRenderFact
    data class ReorderAbandoned(val token: Long) : SharedTmuxRenderFact

    fun canonicalBytes(): ByteArray = SharedTmuxRenderFactEncoder.encode(this)
}

sealed interface SharedTmuxCommandSubmission {
    data class Accepted(val tag: Long) : SharedTmuxCommandSubmission
    data object InvalidArguments : SharedTmuxCommandSubmission
    data object StaleHandle : SharedTmuxCommandSubmission
}

sealed interface SharedTmuxRenderBytes {
    data class Available(val bytes: ByteArray) : SharedTmuxRenderBytes
    data object InvalidReference : SharedTmuxRenderBytes
    data object StaleHandle : SharedTmuxRenderBytes
}

internal object SharedTmuxRenderFactEncoder {
    fun encode(fact: SharedTmuxRenderFact): ByteArray = canonicalJson(fact.toWire()).encodeToByteArray()

    fun encodeDocument(value: Map<String, Any>): ByteArray = canonicalJson(value).encodeToByteArray()

    private fun SharedTmuxRenderFact.toWire(): Map<String, Any> = when (this) {
        is SharedTmuxRenderFact.TransportAttached -> mapOf(
            "version" to 1,
            "kind" to "transportAttached",
            "profile" to profile.wireValue,
        )
        SharedTmuxRenderFact.TransportLost -> mapOf("version" to 1, "kind" to "transportLost")
        is SharedTmuxRenderFact.SurfacesDeclared -> mapOf(
            "version" to 1,
            "kind" to "surfacesDeclared",
            "surfaces" to surfaces.map(SharedTmuxSurfaceDeclaration::toWire),
        )
        is SharedTmuxRenderFact.ClientSize -> mapOf(
            "version" to 1,
            "kind" to "clientSize",
            "columns" to columns,
            "rows" to rows,
        )
        is SharedTmuxRenderFact.TransportOutputObserved -> mapOf(
            "version" to 1,
            "kind" to "transportOutputObserved",
            "surfaceID" to surfaceId,
            "owner" to owner.toWire(),
        )
        is SharedTmuxRenderFact.SurfaceState -> mapOf(
            "version" to 1,
            "kind" to "surfaceState",
            "surfaceID" to surfaceId,
            "request" to request.unsignedWireValue("surface state request"),
            "altScreen" to altScreen,
            "mouseMode" to mouseMode.wireValue,
            "columns" to columns,
            "rows" to rows,
        )
        SharedTmuxRenderFact.AppForeground -> mapOf("version" to 1, "kind" to "appForeground")
        SharedTmuxRenderFact.AppBackground -> mapOf("version" to 1, "kind" to "appBackground")
        is SharedTmuxRenderFact.TimerFired -> mapOf(
            "version" to 1,
            "kind" to "timerFired",
            "token" to token.unsignedWireValue("timer token"),
        )
        is SharedTmuxRenderFact.ScrollbackRequested -> mapOf(
            "version" to 1,
            "kind" to "scrollbackRequested",
            "surfaceID" to surfaceId,
            "pointsY" to pointsY.finiteWireValue("scrollback pointsY"),
            "isInertial" to isInertial,
        )
        is SharedTmuxRenderFact.ScrollbackReturnedToTail -> mapOf(
            "version" to 1,
            "kind" to "scrollbackReturnedToTail",
            "surfaceID" to surfaceId,
        )
        is SharedTmuxRenderFact.HistoryPresented -> mapOf(
            "version" to 1,
            "kind" to "historyPresented",
            "surfaceID" to surfaceId,
            "owner" to owner.toWire(),
        )
        is SharedTmuxRenderFact.HistoryPresentationFailed -> mapOf(
            "version" to 1,
            "kind" to "historyPresentationFailed",
            "surfaceID" to surfaceId,
            "owner" to owner.toWire(),
        )
        is SharedTmuxRenderFact.FindOpened -> mapOf(
            "version" to 1,
            "kind" to "findOpened",
            "surfaceID" to surfaceId,
        )
        SharedTmuxRenderFact.UserInput -> mapOf("version" to 1, "kind" to "userInput")
        is SharedTmuxRenderFact.ScrollbackLimit -> mapOf(
            "version" to 1,
            "kind" to "scrollbackLimit",
            "lines" to lines,
        )
        is SharedTmuxRenderFact.RefreshRequested -> mapOf(
            "version" to 1,
            "kind" to "refreshRequested",
            "surfaceID" to surfaceId,
            "stage" to stage.wireValue,
            "reason" to reason,
        )
        is SharedTmuxRenderFact.CorrelatedRefreshRequested -> mapOf(
            "version" to 1,
            "kind" to "correlatedRefreshRequested",
            "surfaceID" to surfaceId,
            "stage" to stage.wireValue,
            "reason" to reason,
            "correlation" to correlation.unsignedWireValue("refresh correlation"),
        )
        is SharedTmuxRenderFact.CorrelatedTransportFullFrameRequested -> mapOf(
            "version" to 1,
            "kind" to "correlatedTransportFullFrameRequested",
            "surfaceID" to surfaceId,
            "reason" to reason,
            "correlation" to correlation.unsignedWireValue("transport frame correlation"),
        )
        is SharedTmuxRenderFact.TransportFullFramePresented -> buildMap {
            put("version", 1)
            put("kind", "transportFullFramePresented")
            put("surfaceID", surfaceId)
            owner?.let { put("owner", it.toWire()) }
            put("correlation", correlation.unsignedWireValue("transport frame correlation"))
        }
        is SharedTmuxRenderFact.TransportFullFramePresentationFailed -> buildMap {
            put("version", 1)
            put("kind", "transportFullFramePresentationFailed")
            put("surfaceID", surfaceId)
            owner?.let { put("owner", it.toWire()) }
            put("correlation", correlation.unsignedWireValue("transport frame correlation"))
            put("reason", reason)
        }
        is SharedTmuxRenderFact.ReorderBegan -> mapOf(
            "version" to 1,
            "kind" to "reorderBegan",
            "token" to token.unsignedWireValue("reorder token"),
            "order" to order.map {
                require(it >= 0) { "window id must be non-negative" }
                mapOf("rawValue" to it)
            },
        )
        is SharedTmuxRenderFact.ReorderConfirmed -> mapOf(
            "version" to 1,
            "kind" to "reorderConfirmed",
            "token" to token.unsignedWireValue("reorder token"),
        )
        is SharedTmuxRenderFact.UnwrittenCommandsCancelled -> mapOf(
            "version" to 1,
            "kind" to "unwrittenCommandsCancelled",
            "tags" to tags.map { it.unsignedWireValue("command tag") },
        )
        is SharedTmuxRenderFact.ReorderAbandoned -> mapOf(
            "version" to 1,
            "kind" to "reorderAbandoned",
            "token" to token.unsignedWireValue("reorder token"),
        )
    }

    private fun Long.unsignedWireValue(label: String): Long {
        require(this >= 0) { "$label must be non-negative" }
        return this
    }

    private fun Double.finiteWireValue(label: String): Double {
        require(isFinite()) { "$label must be finite" }
        return this
    }

    private fun canonicalJson(value: Any): String = when (value) {
        is String -> jsonQuote(value)
        is Boolean, is Int, is Long -> value.toString()
        is Double -> canonicalDouble(value)
        is List<*> -> value.joinToString(separator = ",", prefix = "[", postfix = "]") {
            requireNotNull(it) { "canonical render JSON does not encode null" }
            canonicalJson(it)
        }
        is Map<*, *> -> value.entries
            .map { (key, entryValue) ->
                require(key is String) { "canonical render JSON keys must be strings" }
                requireNotNull(entryValue) { "canonical render JSON omits optional fields" }
                key to entryValue
            }
            .sortedBy { it.first }
            .joinToString(separator = ",", prefix = "{", postfix = "}") { (key, entryValue) ->
                "${jsonQuote(key)}:${canonicalJson(entryValue)}"
            }
        else -> error("unsupported canonical render JSON value ${value::class.java.name}")
    }

    /**
     * Match Foundation's shortest-round-tripping JSON number spelling at this
     * ABI boundary. JDK 17's `Double.toString` is not sufficient: for example,
     * it prints the least subnormal as `4.9E-324` and `1e23` as
     * `9.999999999999999E22`, while Foundation correctly chooses the shorter
     * round-tripping forms `5e-324` and `1e+23`.
     *
     * Start from the exact binary value, then find the first decimal precision
     * whose nearest value (or one adjacent unit at that precision) round-trips
     * to the same IEEE-754 bits. Seventeen digits are sufficient for every
     * finite binary64 value. The final notation thresholds and exponent format
     * are Foundation's canonical JSON rules.
     */
    private fun canonicalDouble(value: Double): String {
        require(value.isFinite()) { "canonical render JSON requires a finite number" }
        if (value == 0.0) {
            return if (value.toRawBits() == (-0.0).toRawBits()) "-0" else "0"
        }
        val exact = BigDecimal(value)
        var shortest: BigDecimal? = null
        for (precision in 1..17) {
            val rounded = exact.round(MathContext(precision, RoundingMode.HALF_EVEN))
            val exponent = exact.precision() - exact.scale() - 1
            val quantum = BigDecimal.ONE.scaleByPowerOfTen(exponent - precision + 1)
            shortest = listOf(rounded, rounded - quantum, rounded + quantum)
                .asSequence()
                .filter { candidate -> candidate.toDouble().toRawBits() == value.toRawBits() }
                .minWithOrNull(
                    compareBy<BigDecimal> { candidate -> (candidate - exact).abs() }
                        .thenBy { candidate -> candidate.unscaledValue().abs() },
                )
            if (shortest != null) break
        }
        val decimal = checkNotNull(shortest) {
            "no 17-digit decimal round-trip for finite binary64 value"
        }.stripTrailingZeros()
        val exponent = decimal.precision() - decimal.scale() - 1
        if (exponent in -4..15) return decimal.toPlainString()

        val digits = decimal.unscaledValue().abs().toString()
        val coefficient = if (digits.length == 1) {
            digits
        } else {
            "${digits.first()}.${digits.drop(1)}"
        }
        val exponentText = if (exponent >= 0) {
            "+$exponent"
        } else {
            "-${(-exponent).toString().padStart(2, '0')}"
        }
        val sign = if (decimal.signum() < 0) "-" else ""
        return "$sign${coefficient}e$exponentText"
    }

    private fun jsonQuote(value: String): String = buildString(value.length + 2) {
        append('"')
        value.forEach { character ->
            when (character) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\b' -> append("\\b")
                '\u000C' -> append("\\f")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 0x20) {
                    append("\\u")
                    append(character.code.toString(16).padStart(4, '0'))
                } else {
                    append(character)
                }
            }
        }
        append('"')
    }
}

data class SharedTmuxPane(
    val id: Int,
    val title: String?,
    val currentCommand: String?,
    val active: Boolean,
    val currentPath: String? = null,
    /**
     * True when [title] is still tmux's host-derived default rather than a
     * title the application set, so it names the machine and not the pane.
     */
    val titleIsDefault: Boolean = false,
    /**
     * `#{alternate_on}` and `#{mouse_any_flag}` from the live pane-metadata
     * feed; null until the server has reported them. mosh+tmux learns that a
     * pane runs a full-screen program only from here.
     */
    val isAlternateScreen: Boolean? = null,
    val isMouseReporting: Boolean? = null,
)

data class SharedTmuxWindow(
    val id: Int,
    val index: Int?,
    /** Raw `#{window_name}`. Use [displayName] for anything the user reads. */
    val name: String?,
    val activePaneId: Int?,
    val panes: List<SharedTmuxPane>,
    val zoomed: Boolean,
    val layout: SharedTmuxLayoutNode?,
    val activePaneTitle: String? = null,
    val activePaneTitleIsDefault: Boolean = false,
    /**
     * The window's visible label, computed by the core and carried on the
     * wire, so this client and the Apple clients render the identical string.
     * Deriving it here from [name] alone is what showed stale tmux window
     * names where iOS shows the live pane title.
     */
    val displayName: String = name.orEmpty(),
) {
    /**
     * [displayName] unless it is only the window id standing in for a label
     * nothing has answered yet. For chrome that would rather show nothing than
     * show "@1".
     */
    val namedLabel: String?
        get() = displayName.takeIf { it != "@$id" }
}

/**
 * A node of tmux's window layout tree. `x`/`y` are the node's origin inside its
 * window, which a compact renderer needs to pan a split window so the focused
 * pane lands on screen; the core has always carried them on the wire.
 */
sealed interface SharedTmuxLayoutNode {
    val width: Int
    val height: Int
    val x: Int
    val y: Int

    data class Leaf(
        val paneId: Int,
        override val width: Int,
        override val height: Int,
        override val x: Int = 0,
        override val y: Int = 0,
    ) : SharedTmuxLayoutNode

    data class Split(
        val horizontal: Boolean,
        override val width: Int,
        override val height: Int,
        override val x: Int = 0,
        override val y: Int = 0,
        val children: List<SharedTmuxLayoutNode>,
    ) : SharedTmuxLayoutNode
}

data class SharedTmuxSnapshot(
    val sessionId: Int? = null,
    val sessionName: String?,
    val activeWindowId: Int?,
    /**
     * True only when tmux itself named [activeWindowId] for this client's
     * session (a `%session-window-changed` the core accepted as ours, or the
     * correlated active-window query reply). False for the core's provisional
     * picks: the first `%window-add` before tmux said which window is active,
     * and the fallback after the active window closed. Absent from older
     * payloads, which decode as false.
     */
    val isActiveWindowAuthoritative: Boolean = false,
    val windows: List<SharedTmuxWindow>,
    val authority: SharedTmuxGridAuthoritySnapshot,
    val capabilities: SharedTmuxWindowCapabilities? = null,
    val isReorderPending: Boolean = false,
    val authoritativeWindowOrder: List<Int> = windows.map { it.id },
    val isWindowListHydrated: Boolean = false,
    val revision: Long,
    /**
     * The snapshot exactly as the core encoded it, for re-publication. Not part
     * of equality: it is only the wire form of the fields above, and an array
     * compares by identity, which made every decoded snapshot unequal to the
     * last and so re-published `tmuxSnapshot` (and recomposed the session
     * screen) at event rate.
     */
    val rawJson: ByteArray,
) {
    val activeWindow: SharedTmuxWindow?
        get() = windows.firstOrNull { it.id == activeWindowId } ?: windows.firstOrNull()
    val activePaneId: Int?
        get() = activeWindow?.activePaneId ?: activeWindow?.panes?.firstOrNull()?.id

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SharedTmuxSnapshot) return false
        return revision == other.revision &&
            sessionId == other.sessionId &&
            sessionName == other.sessionName &&
            activeWindowId == other.activeWindowId &&
            isActiveWindowAuthoritative == other.isActiveWindowAuthoritative &&
            isReorderPending == other.isReorderPending &&
            isWindowListHydrated == other.isWindowListHydrated &&
            authority == other.authority &&
            capabilities == other.capabilities &&
            authoritativeWindowOrder == other.authoritativeWindowOrder &&
            windows == other.windows
    }

    override fun hashCode(): Int {
        var result = sessionId ?: 0
        result = 31 * result + (sessionName?.hashCode() ?: 0)
        result = 31 * result + (activeWindowId ?: 0)
        result = 31 * result + isActiveWindowAuthoritative.hashCode()
        result = 31 * result + windows.hashCode()
        result = 31 * result + authority.hashCode()
        result = 31 * result + (capabilities?.hashCode() ?: 0)
        result = 31 * result + isReorderPending.hashCode()
        result = 31 * result + authoritativeWindowOrder.hashCode()
        result = 31 * result + isWindowListHydrated.hashCode()
        result = 31 * result + revision.hashCode()
        return result
    }
}

/**
 * Removed from the v2 ABI. Kept temporarily as an empty compatibility
 * projection while the feature-session executor moves to [renderEffects].
 */
data class SharedTmuxPaneOutput(val paneId: Int, val bytes: ByteArray, val ageMilliseconds: Int?)
data class SharedTmuxBell(
    val windowId: Int,
    val isActiveWindow: Boolean,
    val windowName: String?,
)

/**
 * One pane's `@tessera_agent_state`, as the shared runtime read it off the
 * pane-metadata subscription.
 *
 * The remote lifecycle hook publishes every event twice: as an OSC on the
 * pane's own tty and as this tmux option. Only the option reaches a pane this
 * client is not painting, and a client paints one window at a time — so
 * without this feed Agent Center can only ever see the agent the user is
 * already looking at. [json] is the hook's frame, bounded by Core; it is
 * parsed by the shared Agent parser, never here.
 */
data class SharedTmuxPaneAgentState(
    val windowId: Int,
    val paneId: Int,
    val json: String,
)

/**
 * Removed from the v2 ABI. Platform replies now arrive as the ordered
 * [SharedTmuxRenderEffect.CommandReply] effect.
 */
data class SharedTmuxResponseFrame(
    val success: Boolean,
    val clientResponse: Boolean,
    val guardMatches: Boolean,
    val lines: List<String>,
)
data class SharedTmuxPlatformWireCommand(val tag: Long, val command: String)

data class SharedTmuxEvent(
    /**
     * The snapshot this event stands for. A state event either carried it or
     * named it by key as the one already decoded; one delivered while the
     * decoder knows it is out of step (a carrying event was lost) is flagged
     * by a leading `tmux-runtime snapshot-desync` [SharedTmuxRenderEffect.Diagnostic]
     * and is followed by the core's resync answer.
     *
     * A wire-only event ([platformWireCommands] non-empty) stands for no
     * snapshot: this is merely the last one decoded, which can lag the engine
     * (a claim settle moves the revision without emitting, and a wire-only
     * event never carries the newer snapshot). Ignore it on such an event.
     */
    val snapshot: SharedTmuxSnapshot,
    val bells: List<SharedTmuxBell>,
    /** Lifecycle payloads tmux published for panes of the attached session. */
    val agentStates: List<SharedTmuxPaneAgentState>,
    val renderEffects: List<SharedTmuxRenderEffect>,
    /**
     * Changed raw stamp values, once each and in arrival order; the session classifies them.
     * Empty when the attached session reduced them ([authoritySession]).
     */
    val authorityStamps: List<String> = emptyList(),
    /**
     * The attached authority session's result for what this read reduced
     * in wire order ([SharedTmuxRuntime.feed] with a clock): apply it as that
     * session's own call's result, before any newer reduction. Null when the
     * read changed nothing or its stamps are [authorityStamps].
     */
    val authoritySession: SharedTmuxAuthoritySessionResult? = null,
    /**
     * The attached session reduced this read's control-session changes,
     * window facts and stamps at their steps: report none of them again.
     */
    val authorityReducedInFeed: Boolean = false,
    /**
     * The control client moved from one known session to another during
     * this read (§6.18), reduced in the feed or not: resolve the new
     * session's scope, hydrate and subscribe again.
     */
    val controlSessionSwitched: Boolean = false,
    val peerDepartureObserved: Boolean = false,
    /**
     * Fixed topology queries the shared runtime needs on the control channel.
     *
     * tmux announces a created window with `%session-window-changed` +
     * `%window-add` and then never describes it — no `%layout-change`, no
     * `%window-pane-changed`, often no `%window-renamed` — so the core asks.
     * Replies carry the core's own tag and fold themselves back into the
     * shared snapshot: transporting the string is the whole adapter job.
     */
    val topologyQueries: List<String> = emptyList(),
    /** Core-owned per-pane registrations and removals; send each and ignore its reply. */
    val subscriptionCommands: List<String> = emptyList(),
    /**
     * Pure wire delivery: transport these without projecting [snapshot],
     * which may lag the engine. [programStatusRevision] still names the current monitor revision.
     */
    val platformWireCommands: List<SharedTmuxPlatformWireCommand> = emptyList(),
    /** Current monitor revision, including on wire-only events; absent on older cores. */
    val programStatusRevision: Long? = null,
) {
    /**
     * Transitional source compatibility only. The v2 ABI never serializes
     * pane output separately: a platform that observes this non-empty would
     * be reading a stale local projection rather than shared-core state.
     */
    @Deprecated("Execute renderEffects instead")
    val paneOutputs: List<SharedTmuxPaneOutput> = emptyList()

    /** Transitional source compatibility only; v2 emits CommandReply effects. */
    @Deprecated("Execute renderEffects instead")
    val responseFrames: List<SharedTmuxResponseFrame> = emptyList()
}

private class SharedTmuxEventSink(listener: (SharedTmuxEvent) -> Unit) {
    @Volatile
    private var listener: ((SharedTmuxEvent) -> Unit)? = listener

    fun deliver(event: SharedTmuxEvent) {
        listener?.invoke(event)
    }

    fun replace(listener: (SharedTmuxEvent) -> Unit) {
        this.listener = listener
    }

    fun clear() {
        listener = null
    }
}

/**
 * The adapter-owned render-ledger switches, the header's
 * `TESSERA_TMUX_RENDER_LEDGER_*` bits. A new runtime handle has none set;
 * the core refuses any bit it does not define.
 */
object SharedTmuxRenderLedgerOptions {
    /** P6: no `refresh-client -C` for the grid this connection already advertised. */
    const val SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY = 1
    /** An inline replay sends its refresh alone, without the `latest` fence. */
    const val INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM = 2
    /** P8: a take-back's visible capture rides with its metadata query. */
    const val PIPELINES_VISIBLE_CAPTURE = 4
}

/** What `projectAuthorityReleasing` handed back. */
sealed interface SharedTmuxClaimSettlement {
    /** Settled; [renderEffects] is the released work, possibly none. */
    data class Released(val renderEffects: List<SharedTmuxRenderEffect>) : SharedTmuxClaimSettlement

    /**
     * Settled, but the core refused (or this side could not read) the
     * released work, whose commands may already hold FIFO slots: fence the
     * transport, as for a refused fact.
     */
    data object Refused : SharedTmuxClaimSettlement

    data object StaleHandle : SharedTmuxClaimSettlement

    companion object {
        /** The core's canonical `{"renderEffects":[...]}` document and nothing else. */
        internal fun decode(document: ByteArray): Released {
            val root = JSONObject(document.decodeToString())
            require(root.keys().asSequence().toSet() == setOf("renderEffects")) { "not a claim settlement" }
            val effects = root.getJSONArray("renderEffects")
            return Released(List(effects.length()) { index -> effects.getJSONObject(index).parseRenderEffect() })
        }
    }
}

/** The complete feed request; a null authority owner uses the client's own session. */
data class SharedTmuxSubscriptions(
    val bell: Boolean = false,
    val paneMetadata: Boolean = false,
    val windowOrder: Boolean = false,
    val authority: Boolean = false,
    val authorityOwnerSessionId: Int? = null,
) {
    init {
        require(authorityOwnerSessionId == null || authorityOwnerSessionId >= 0)
    }

    internal val feeds: Int
        get() = (if (bell) 1 else 0) or (if (paneMetadata) 2 else 0) or
            (if (windowOrder) 4 else 0) or (if (authority) 8 else 0)
}

class SharedTmuxRuntime private constructor(
    private val core: TmuxCoreRuntime,
    private val eventSink: SharedTmuxEventSink,
    private val decoder: SharedTmuxEventDecoder,
) : AutoCloseable {
    /** The session [attachAuthoritySession] attached; [feed] counts its adoptions. */
    @Volatile
    private var attachedSession: SharedTmuxAuthoritySession? = null

    fun feed(bytes: ByteArray): CoreCallResult = core.feed(bytes)

    /**
     * [feed] at [nowMillis] on the attached session's clock: the session
     * reduces the read's stamp edges where they arrive, before the rest of
     * the read reaches the render ledger, and the read's event carries its
     * result ([SharedTmuxEvent.authoritySession]).
     */
    fun feed(bytes: ByteArray, nowMillis: Long): CoreCallResult {
        val session = attachedSession
        val adoptions = session?.adoptions
        val code = core.feedAt(bytes, nowMillis)
        if (code != TmuxCoreRuntime.FEED_CARRIED_SESSION_RESULT) return code.toCoreCallResult()
        if (session != null && session.adoptions == adoptions) redeliverLostResult(session, nowMillis)
        return CoreCallResult.Accepted
    }

    /**
     * The read's event carried the session's result and the session never
     * adopted it: JNI dropped the callback, it failed to decode, or its
     * listener failed first. The session has moved on regardless, and a
     * repeat of the same stamp reduces nothing, so its gates would follow
     * a verdict the adapter never saw. Ask once more; the next state event
     * records the loss either way.
     */
    private fun redeliverLostResult(session: SharedTmuxAuthoritySession, nowMillis: Long) {
        val adoptions = session.adoptions
        val redelivered = core.redeliverAuthorityResult(nowMillis) == CoreCallResult.Accepted &&
            session.adoptions != adoptions
        decoder.noteLostAuthorityResult(redelivered)
    }

    /**
     * Reduce stamp edges into [session] from now on (null detaches). Call
     * under the lock that serializes every other reduction of [session].
     * A closed session is refused ([CoreCallResult.InvalidArguments]).
     */
    fun attachAuthoritySession(session: SharedTmuxAuthoritySession?): CoreCallResult {
        val handle = session?.runtimeHandle ?: 0L
        if (session != null && handle == 0L) return CoreCallResult.InvalidArguments
        return core.attachAuthoritySession(handle).also {
            if (it == CoreCallResult.Accepted) attachedSession = session
        }
    }
    fun sendCommand(command: String): SharedTmuxCommandSubmission = core.sendCommand(command)
    fun queueCommand(command: String): SharedTmuxCommandSubmission = core.queueCommand(command)
    fun submitFact(fact: SharedTmuxRenderFact): CoreCallResult = core.submitFact(fact.canonicalBytes())
    fun takeRenderBytes(bytesRef: Long): SharedTmuxRenderBytes = core.takeRenderBytes(bytesRef)
    /**
     * Project the session's verdict and return the work the ledger deferred.
     * Write returned commands under the transport lock before later commands:
     * each already holds its FIFO slot. In a callback the core queues them.
     */
    fun projectAuthorityReleasing(authority: SharedTmuxGridAuthoritySnapshot): SharedTmuxClaimSettlement =
        releasedWork(core.projectAuthorityReleasing(authority.runtimeJSON()))

    private fun releasedWork(document: ByteArray?): SharedTmuxClaimSettlement {
        if (document == null) return SharedTmuxClaimSettlement.StaleHandle
        if (document.isEmpty()) return SharedTmuxClaimSettlement.Refused
        return runCatching { SharedTmuxClaimSettlement.decode(document) }.getOrElse { SharedTmuxClaimSettlement.Refused }
    }

    /** See [SharedTmuxRenderLedgerOptions]; takes effect for the ledger's next decision. */
    fun setRenderLedgerOptions(options: Int): CoreCallResult = core.setRenderLedgerOptions(options)
    fun setProgramStatusEnabled(enabled: Boolean): CoreCallResult = core.setProgramStatusEnabled(enabled)
    fun setSubscriptions(subscriptions: SharedTmuxSubscriptions): CoreCallResult = core.setSubscriptions(subscriptions)

    /** Null for a stale handle or an undecodable document. */
    fun programStatus(): SharedProgramStatusSnapshot? = core.copyProgramStatus()?.let { document ->
        runCatching { SharedProgramStatusSnapshot.decode(document) }.getOrNull()
    }

    /** True when the visible status changed. */
    fun acknowledgeProgramStatus(paneId: Int, through: Long): Boolean =
        core.acknowledgeProgramStatus(paneId, through) == 1

    fun replaceListener(listener: (SharedTmuxEvent) -> Unit) = eventSink.replace(listener)
    fun clearListener() = eventSink.clear()
    override fun close() {
        eventSink.clear()
        core.close()
    }

    companion object {
        fun create(listener: (SharedTmuxEvent) -> Unit): SharedTmuxRuntime {
            val sink = SharedTmuxEventSink(listener)
            val coreHolder = AtomicReference<TmuxCoreRuntime?>(null)
            // The decoder belongs to the native handle, not to the listener: a
            // parked Mosh core keeps its handle (and the snapshot the core
            // knows it already sent) across a listener replacement. It decodes
            // every callback, listener or not, or it would lose its place.
            val decoder = SharedTmuxEventDecoder(
                requestResync = { coreHolder.get()?.resyncSnapshot() == CoreCallResult.Accepted },
            )
            val core = TmuxCoreRuntime.create { event ->
                // A failed decode is already recorded and a resync requested;
                // there is nothing to deliver, and nothing for JNI to clear.
                val decoded = runCatching { decoder.decode(event.bytes) }.getOrNull()
                if (decoded != null) sink.deliver(decoded)
            }
            // No callback can precede this: creating a handle emits nothing.
            coreHolder.set(core)
            return SharedTmuxRuntime(core, sink, decoder)
        }

        /** Decode one self-contained event, i.e. one that carries its snapshot. */
        internal fun parse(bytes: ByteArray): SharedTmuxEvent = SharedTmuxEventDecoder().decode(bytes)
    }
}

/**
 * Decodes the tmux runtime callback stream of one native handle.
 *
 * Since event version 3 the core sends the snapshot only when it changed
 * since the last one it queued: encoding the whole topology into every
 * `%output` event was the largest per-event cost found. This decoder keeps the
 * last snapshot and attaches it to events that omit one, so
 * [SharedTmuxEvent.snapshot] keeps its non-null contract and an unchanged
 * snapshot is the same instance.
 *
 * Elision makes a lost event costly. v2 healed on the next event, but an
 * elided event has nothing to heal with, and the core commits to a snapshot
 * when it queues it: the JNI shim can drop a callback (thread attach, buffer
 * allocation) and a decode can fail. So every envelope names its snapshot by
 * `snapshotKey`, and a state event naming another key than the held
 * snapshot's proves a carrying event went missing. The event is still
 * delivered, its effects intact, with the held snapshot and a leading
 * `tmux-runtime snapshot-desync` diagnostic effect, and [requestResync] asks
 * the core for a state event carrying the current snapshot, which it queues
 * right behind the callbacks already queued. One request covers every event
 * queued under the same key. A decode failure forgets the held key, so the
 * stale snapshot is never kept silently, and asks once; it may ask again
 * only after the stream is back in step, so an answer that fails to decode
 * cannot ask for another answer.
 *
 * Wire-only events are decoded first and never need a snapshot: each command
 * already holds a reply slot, so it is delivered even before any snapshot is
 * known. A snapshot one carries (only ever a handle's first event) is still
 * adopted. Before the first snapshot the decoder holds the engine's initial
 * one, [INITIAL_SNAPSHOT].
 *
 * Callbacks for one handle are serialized by the core; the fields are
 * volatile only because consecutive callbacks may arrive on different threads.
 */
internal class SharedTmuxEventDecoder(
    /** Asks the core for a resync answer; true when it accepted the request. */
    private val requestResync: () -> Boolean = { false },
) {
    private data class SnapshotKey(val epoch: Long, val revision: Long) {
        override fun toString(): String = "$epoch/$revision"
    }

    @Volatile
    private var snapshot: SharedTmuxSnapshot = INITIAL_SNAPSHOT

    /** The key [snapshot] was decoded under; null when none can be trusted. */
    @Volatile
    private var snapshotKey: SnapshotKey? = null

    /** The elided key a resync was last requested for. */
    @Volatile
    private var resyncRequestedFor: SnapshotKey? = null

    /** A decode failure may ask once until the stream is back in step. */
    @Volatile
    private var failureResyncArmed = true

    /** Desync notes awaiting the next delivered state event. */
    private val pendingDiagnostics = ArrayDeque<String>()

    @Volatile
    private var droppedDiagnostics = 0

    fun decode(bytes: ByteArray): SharedTmuxEvent {
        var eventKey: SnapshotKey? = null
        try {
            val envelope = JSONObject(bytes.decodeToString())
            require(envelope.getInt("version") == EVENT_VERSION) { "unsupported tmux runtime event version" }
            eventKey = envelope.optJSONObject("snapshotKey")?.let { key ->
                SnapshotKey(key.nonNegativeLong("epoch"), key.nonNegativeLong("revision"))
            }
            val programStatusRevision = if (envelope.has("programStatusRevision")) {
                envelope.nonNegativeLong("programStatusRevision")
            } else null
            val carried = envelope.optJSONObject("snapshot")
            // Wire-only delivery first: it publishes no state and must never
            // wait for a snapshot, since its commands already hold reply slots.
            val platformWireCommands = envelope.optJSONArray("platformWireCommands")?.let { commands ->
                List(commands.length()) { index ->
                    val value = commands.getJSONObject(index)
                    SharedTmuxPlatformWireCommand(value.getLong("tag"), value.getString("command")).also {
                        require(it.tag > 0 && it.command.isNotEmpty() && '\u0000' !in it.command) {
                            "invalid ordered tmux wire command"
                        }
                    }
                }
            }.orEmpty()
            if (platformWireCommands.isNotEmpty()) {
                if (carried != null) adopt(carried, eventKey, bytes)
                return SharedTmuxEvent(
                    snapshot = snapshot,
                    bells = emptyList(),
                    agentStates = emptyList(),
                    renderEffects = emptyList(),
                    platformWireCommands = platformWireCommands,
                    programStatusRevision = programStatusRevision,
                )
            }
            if (carried != null) adopt(carried, eventKey, bytes) else requireHeldKey(eventKey)
            val bellsArray = envelope.optJSONArray("bells")
            val bells = buildList {
                if (bellsArray != null) repeat(bellsArray.length()) { index ->
                    val bell = bellsArray.getJSONObject(index)
                    add(
                        SharedTmuxBell(
                            windowId = bell.id("windowID")!!,
                            isActiveWindow = bell.getBoolean("isActiveWindow"),
                            windowName = bell.optionalString("windowName"),
                        ),
                    )
                }
            }
            val agentStatesArray = envelope.optJSONArray("agentStates")
            val agentStates = buildList {
                if (agentStatesArray != null) repeat(agentStatesArray.length()) { index ->
                    val state = agentStatesArray.getJSONObject(index)
                    val windowId = state.id("windowID")
                    val paneId = state.id("paneID")
                    val json = state.optionalString("json")
                    if (windowId != null && paneId != null && !json.isNullOrEmpty()) {
                        add(SharedTmuxPaneAgentState(windowId = windowId, paneId = paneId, json = json))
                    }
                }
            }
            val effectsArray = envelope.getJSONArray("renderEffects")
            val effects = buildList {
                repeat(effectsArray.length()) { index -> add(effectsArray.getJSONObject(index).parseRenderEffect()) }
            }
            return SharedTmuxEvent(
                snapshot = snapshot,
                bells = bells,
                agentStates = agentStates,
                renderEffects = takeDiagnostics() + effects,
                authorityStamps = envelope.optJSONArray("authorityStamps")?.strings().orEmpty(),
                authoritySession = envelope.optJSONObject("authoritySession")?.let { SharedTmuxAuthoritySession.parse(it) },
                authorityReducedInFeed = envelope.optBoolean("authorityReducedInFeed", false),
                controlSessionSwitched = envelope.optBoolean("controlSessionSwitched", false),
                peerDepartureObserved = envelope.optBoolean("peerDepartureObserved", false),
                topologyQueries = envelope.optJSONArray("topologyQueries")?.strings().orEmpty(),
                subscriptionCommands = envelope.optJSONArray("subscriptionCommands")?.strings().orEmpty(),
                programStatusRevision = programStatusRevision,
            )
        } catch (failure: Exception) {
            failed("undecodable-event", eventKey, failure)
            throw failure
        }
    }

    /** A carried snapshot. One that fails to decode never replaces the held one. */
    private fun adopt(carried: JSONObject, key: SnapshotKey?, envelopeBytes: ByteArray) {
        val parsed = try {
            parseSnapshot(carried, envelopeBytes)
        } catch (failure: Exception) {
            failed("undecodable-snapshot", key, failure)
            return
        }
        snapshot = parsed
        snapshotKey = key
        resyncRequestedFor = null
        failureResyncArmed = true
    }

    /** An elided state event must name the snapshot already held. */
    private fun requireHeldKey(key: SnapshotKey?) {
        val held = snapshotKey
        if (key != null && key == held) {
            failureResyncArmed = true
            return
        }
        val resync = if (key != null && key == resyncRequestedFor) "already-requested" else ask(key)
        note("reason=key-mismatch held=${held ?: "none"} event=${key ?: "none"} resync=$resync")
    }

    private fun failed(reason: String, key: SnapshotKey?, failure: Exception) {
        val held = snapshotKey
        snapshotKey = null
        val resync = if (failureResyncArmed) {
            failureResyncArmed = false
            ask(key)
        } else {
            "disarmed"
        }
        note(
            "reason=$reason held=${held ?: "none"} event=${key ?: "none"} resync=$resync " +
                "error=${failure.javaClass.simpleName}",
        )
    }

    private fun ask(key: SnapshotKey?): String {
        resyncRequestedFor = key
        val accepted = try {
            requestResync()
        } catch (_: Exception) {
            false
        }
        if (accepted) return "requested"
        // Nothing was queued, so nothing can answer: let the next one ask.
        resyncRequestedFor = null
        failureResyncArmed = true
        return "refused"
    }

    /** A feed's session result never reached its session; see [SharedTmuxRuntime.feed]. */
    fun noteLostAuthorityResult(redelivered: Boolean) =
        enqueueDiagnostic("$AUTHORITY_RESULT_DIAGNOSTIC redelivered=$redelivered")

    private fun note(detail: String) = enqueueDiagnostic("$DESYNC_DIAGNOSTIC $detail")

    // A feed notes a lost result outside any callback, so unlike the rest
    // of the decoder the queue is not confined to callbacks.
    private fun enqueueDiagnostic(line: String) = synchronized(pendingDiagnostics) {
        if (pendingDiagnostics.size == MAX_PENDING_DIAGNOSTICS) {
            pendingDiagnostics.removeFirst()
            droppedDiagnostics += 1
        }
        pendingDiagnostics.addLast(line)
    }

    private fun takeDiagnostics(): List<SharedTmuxRenderEffect> {
        val notes = synchronized(pendingDiagnostics) {
            if (pendingDiagnostics.isEmpty()) return emptyList()
            buildList {
                if (droppedDiagnostics > 0) add("$DESYNC_DIAGNOSTIC dropped=$droppedDiagnostics")
                addAll(pendingDiagnostics)
            }.also {
                pendingDiagnostics.clear()
                droppedDiagnostics = 0
            }
        }
        return notes.map(SharedTmuxRenderEffect::Diagnostic)
    }

    private fun parseSnapshot(snapshotObject: JSONObject, envelopeBytes: ByteArray): SharedTmuxSnapshot {
        val windowsArray = snapshotObject.getJSONArray("windows")
        val windows = buildList {
            repeat(windowsArray.length()) { index ->
                val value = windowsArray.getJSONObject(index)
                val panesArray = value.getJSONArray("panes")
                val panes = buildList {
                    repeat(panesArray.length()) { paneIndex ->
                        val pane = panesArray.getJSONObject(paneIndex)
                        add(
                            SharedTmuxPane(
                                id = pane.id("id")!!,
                                title = pane.optionalString("title"),
                                currentCommand = pane.optionalString("currentCommand"),
                                active = pane.optBoolean("isActive", false),
                                currentPath = pane.optionalString("currentPath"),
                                titleIsDefault = pane.optBoolean("titleIsDefault", false),
                                isAlternateScreen = pane.optionalBoolean("isAlternateScreen"),
                                isMouseReporting = pane.optionalBoolean("isMouseReporting"),
                            ),
                        )
                    }
                }
                add(
                    SharedTmuxWindow(
                        id = value.id("id")!!,
                        index = value.takeIf { it.has("index") && !it.isNull("index") }?.getInt("index"),
                        name = value.optionalString("name"),
                        activePaneId = value.id("activePaneID"),
                        panes = panes,
                        zoomed = value.optBoolean("isZoomed", false),
                        layout = (value.optJSONObject("visibleLayout")
                            ?: value.optJSONObject("layout"))?.optJSONObject("root")?.parseLayoutNode(),
                        activePaneTitle = value.optionalString("activePaneTitle"),
                        activePaneTitleIsDefault =
                            value.optBoolean("activePaneTitleIsDefault", false),
                        displayName = value.optionalString("displayName")
                            ?: value.optionalString("name")
                            ?: "@${value.id("id")}",
                    ),
                )
            }
        }
        return SharedTmuxSnapshot(
            sessionId = snapshotObject.id("sessionID"),
            sessionName = snapshotObject.optionalString("sessionName"),
            activeWindowId = snapshotObject.id("activeWindowID"),
            isActiveWindowAuthoritative = snapshotObject.optBoolean("isActiveWindowAuthoritative", false),
            windows = windows,
            authority = snapshotObject.optJSONObject("authority")?.let(
                SharedTmuxGridAuthoritySnapshot::fromJson,
            ) ?: SharedTmuxGridAuthoritySnapshot.Unknown,
            capabilities = snapshotObject.optJSONObject("capabilities")?.let {
                SharedTmuxWindowCapabilities(
                    supportsMoveBefore = it.getBoolean("supportsMoveBefore"),
                    supportsSubscriptions = it.getBoolean("supportsSubscriptions"),
                )
            },
            isReorderPending = snapshotObject.optBoolean("isReorderPending", false),
            isWindowListHydrated = snapshotObject.optBoolean("isWindowListHydrated", false),
            authoritativeWindowOrder = snapshotObject.optJSONArray("authoritativeWindowOrder")?.let { ids ->
                List(ids.length()) { ids.getJSONObject(it).getInt("rawValue") }
            } ?: windows.map { it.id },
            revision = snapshotObject.optLong("revision", 0),
            // The core's own bytes, sliced rather than re-serialised from the
            // parsed tree; the fallback is unreachable for a core envelope.
            rawJson = topLevelMemberBytes(envelopeBytes, "snapshot")
                ?: snapshotObject.toString().encodeToByteArray(),
        )
    }

    internal companion object {
        const val EVENT_VERSION = 3
        const val DESYNC_DIAGNOSTIC = "tmux-runtime snapshot-desync"
        const val AUTHORITY_RESULT_DIAGNOSTIC = "tmux-runtime authority-result-lost"
        private const val MAX_PENDING_DIAGNOSTICS = 16

        /**
         * The core engine's own snapshot before any input, byte for byte as
         * the core encodes it (a TesseraCore ABI test holds the core to this
         * spelling): what a platform knows before its first event, and what
         * is relayed to the session core if that event was lost.
         */
        const val INITIAL_SNAPSHOT_JSON = """{"authoritativeWindowOrder":[],"authority":{"unknown":{}},""" +
            """"isActiveWindowAuthoritative":false,"isReorderPending":false,"isWindowListHydrated":false,""" +
            """"revision":0,"windows":[]}"""

        val INITIAL_SNAPSHOT = SharedTmuxSnapshot(
            sessionName = null,
            activeWindowId = null,
            windows = emptyList(),
            authority = SharedTmuxGridAuthoritySnapshot.Unknown,
            revision = 0,
            rawJson = INITIAL_SNAPSHOT_JSON.encodeToByteArray(),
        )
    }
}

/**
 * The exact bytes of member [key]'s value in the top-level object of [json],
 * or null if the document has no such member. JSON's structural characters
 * are ASCII and UTF-8 never reuses an ASCII byte inside a multi-byte
 * sequence, so scanning bytes is exact. Only a well-formed document is
 * expected; anything else yields null.
 */
internal fun topLevelMemberBytes(json: ByteArray, key: String): ByteArray? {
    val target = key.encodeToByteArray()
    var index = 0
    fun isSpace(byte: Byte) = byte == ' '.code.toByte() || byte == '\n'.code.toByte() ||
        byte == '\r'.code.toByte() || byte == '\t'.code.toByte()
    fun skipSpace() {
        while (index < json.size && isSpace(json[index])) index++
    }
    /** From an opening quote to just past its closing quote; false if unterminated. */
    fun skipString(): Boolean {
        index++
        while (index < json.size) {
            when (json[index]) {
                '\\'.code.toByte() -> index += 2
                '"'.code.toByte() -> {
                    index++
                    return true
                }
                else -> index++
            }
        }
        return false
    }
    fun skipValue(): Boolean {
        if (index >= json.size) return false
        when (json[index]) {
            '"'.code.toByte() -> return skipString()
            '{'.code.toByte(), '['.code.toByte() -> {
                var depth = 0
                while (index < json.size) {
                    when (json[index]) {
                        '"'.code.toByte() -> if (!skipString()) return false
                        '{'.code.toByte(), '['.code.toByte() -> {
                            depth++
                            index++
                        }
                        '}'.code.toByte(), ']'.code.toByte() -> {
                            depth--
                            index++
                            if (depth == 0) return true
                        }
                        else -> index++
                    }
                }
                return false
            }
            else -> {
                while (index < json.size) {
                    val byte = json[index]
                    if (byte == ','.code.toByte() || byte == '}'.code.toByte() ||
                        byte == ']'.code.toByte() || isSpace(byte)
                    ) return true
                    index++
                }
                return true
            }
        }
    }
    skipSpace()
    if (index >= json.size || json[index] != '{'.code.toByte()) return null
    index++
    while (true) {
        skipSpace()
        if (index >= json.size || json[index] != '"'.code.toByte()) return null
        val keyStart = index + 1
        if (!skipString()) return null
        val keyEnd = index - 1
        skipSpace()
        if (index >= json.size || json[index] != ':'.code.toByte()) return null
        index++
        skipSpace()
        val valueStart = index
        if (!skipValue()) return null
        if (keyEnd - keyStart == target.size &&
            (0 until target.size).all { json[keyStart + it] == target[it] }
        ) {
            return json.copyOfRange(valueStart, index)
        }
        skipSpace()
        if (index >= json.size || json[index] != ','.code.toByte()) return null
        index++
    }
}

private fun JSONObject.id(key: String): Int? =
    optJSONObject(key)?.optInt("rawValue")?.takeIf { has(key) }

private fun JSONObject.optionalString(key: String): String? =
    takeIf { has(key) && !isNull(key) }?.getString(key)

private fun JSONObject.optionalBoolean(key: String): Boolean? =
    takeIf { has(key) && !isNull(key) }?.getBoolean(key)

private fun JSONObject.parseRenderEffect(): SharedTmuxRenderEffect {
    fun surfaceId(): String = getString("surfaceID").also {
        require(it.isNotBlank()) { "render effect surface id must not be blank" }
    }
    fun token(key: String): Long = getLong(key).also {
        require(it >= 0) { "render effect $key must be non-negative" }
    }
    fun positiveToken(key: String): Long = token(key).also {
        require(it > 0) { "render effect $key must be positive" }
    }
    fun owner(): SharedTmuxRenderOwner {
        val value = getJSONObject("owner")
        return SharedTmuxRenderOwner(
            windowId = value.optionalInt("windowID"),
            paneId = value.optionalInt("paneID"),
            epoch = value.nonNegativeLong("epoch"),
        )
    }
    /** Absent for a reservation made before the surface's first bind. */
    fun optionalOwner(): SharedTmuxRenderOwner? =
        if (has("owner") && !isNull("owner")) owner() else null

    return when (getString("kind")) {
        "sendCommand" -> SharedTmuxRenderEffect.SendCommand(getString("command"))
        "commandReply" -> SharedTmuxRenderEffect.CommandReply(
            tag = positiveToken("tag"),
            success = getBoolean("success"),
            lines = getJSONArray("lines").strings(),
        )
        "bindSurface" -> SharedTmuxRenderEffect.BindSurface(surfaceId(), owner())
        "feed" -> SharedTmuxRenderEffect.Feed(
            surfaceId = surfaceId(),
            owner = owner(),
            bytesRef = getJSONObject("bytesRef").nonNegativeLong("id").also {
                require(it > 0) { "render effect bytes reference must be positive" }
            },
            source = SharedTmuxRenderFeedSource.fromWire(getString("source")),
        )
        "saveWindowModes" -> SharedTmuxRenderEffect.SaveWindowModes(surfaceId(), getInt("windowID"))
        "restoreWindowModes" -> SharedTmuxRenderEffect.RestoreWindowModes(
            surfaceId = surfaceId(),
            windowId = getInt("windowID"),
            paneInAltScreen = getBoolean("paneInAltScreen"),
        )
        "resolveSurfaceState" -> SharedTmuxRenderEffect.ResolveSurfaceState(surfaceId(), positiveToken("request"))
        "armTimer" -> SharedTmuxRenderEffect.ArmTimer(
            token = positiveToken("token"),
            milliseconds = getInt("milliseconds"),
        )
        "cancelTimer" -> SharedTmuxRenderEffect.CancelTimer(positiveToken("token"))
        "initialRenderReady" -> SharedTmuxRenderEffect.InitialRenderReady
        "requestTransportFullFrame" -> SharedTmuxRenderEffect.RequestTransportFullFrame
        "historyReady" -> SharedTmuxRenderEffect.HistoryReady(
            surfaceId = surfaceId(),
            owner = owner(),
            depth = getInt("depth"),
            historySize = getInt("historySize"),
            placement = SharedTmuxRenderHistoryPlacement.fromWire(getString("placement")),
        )
        "inlineHistorySettled" -> SharedTmuxRenderEffect.InlineHistorySettled(
            surfaceId = surfaceId(),
            owner = owner(),
            depth = getInt("depth"),
            historySize = getInt("historySize"),
            canDeepen = getBoolean("canDeepen"),
        )
        "refreshCompleted" -> SharedTmuxRenderEffect.RefreshCompleted(
            surfaceId = surfaceId(),
            owner = owner(),
            stage = SharedTmuxRenderStage.fromWire(getString("stage")),
            correlation = positiveToken("correlation"),
        )
        "refreshFailed" -> SharedTmuxRenderEffect.RefreshFailed(
            surfaceId = surfaceId(),
            correlation = token("correlation"),
            reason = getString("reason"),
        )
        "requestCorrelatedTransportFullFrame" -> SharedTmuxRenderEffect.RequestCorrelatedTransportFullFrame(
            surfaceId = surfaceId(),
            owner = optionalOwner(),
            correlation = positiveToken("correlation"),
            reason = getString("reason"),
        )
        "transportFullFrameCompleted" -> SharedTmuxRenderEffect.TransportFullFrameCompleted(
            surfaceId = surfaceId(),
            owner = optionalOwner(),
            correlation = positiveToken("correlation"),
        )
        "transportFullFrameFailed" -> SharedTmuxRenderEffect.TransportFullFrameFailed(
            surfaceId = surfaceId(),
            correlation = token("correlation"),
            reason = getString("reason"),
        )
        "diagnostic" -> SharedTmuxRenderEffect.Diagnostic(getString("message"))
        else -> throw IllegalArgumentException("unknown render effect '${getString("kind")}'")
    }
}

private fun org.json.JSONArray.strings(): List<String> = buildList {
    repeat(length()) { add(getString(it)) }
}

private fun JSONObject.optionalInt(key: String): Int? =
    takeIf { has(key) && !isNull(key) }?.getInt(key)

private fun JSONObject.nonNegativeLong(key: String): Long = getLong(key).also {
    require(it >= 0) { "$key must be non-negative" }
}

private fun JSONObject.parseLayoutNode(): SharedTmuxLayoutNode? {
    optJSONObject("leaf")?.let { leaf ->
        val rect = leaf.getJSONObject("rect")
        return SharedTmuxLayoutNode.Leaf(
            paneId = leaf.id("paneId") ?: return null,
            width = rect.getInt("width"),
            height = rect.getInt("height"),
            x = rect.getInt("x"),
            y = rect.getInt("y"),
        )
    }
    optJSONObject("split")?.let { split ->
        val rect = split.getJSONObject("rect")
        val children = split.getJSONArray("children")
        return SharedTmuxLayoutNode.Split(
            horizontal = split.getString("axis") == "horizontal",
            width = rect.getInt("width"),
            height = rect.getInt("height"),
            x = rect.getInt("x"),
            y = rect.getInt("y"),
            children = buildList {
                repeat(children.length()) { children.getJSONObject(it).parseLayoutNode()?.let(::add) }
            },
        )
    }
    return null
}

/** The runtime's projection input uses the snapshot's existing Codable enum shape. */
internal fun SharedTmuxGridAuthoritySnapshot.runtimeJSON(): ByteArray = when (this) {
    SharedTmuxGridAuthoritySnapshot.Unknown -> JSONObject().put("unknown", JSONObject())
    is SharedTmuxGridAuthoritySnapshot.Mine -> {
        require(generation >= 0)
        JSONObject().put("mine", JSONObject().put("generation", generation))
    }
    is SharedTmuxGridAuthoritySnapshot.Peer -> {
        require(generation >= 0)
        JSONObject().put("peer", JSONObject().put("deviceID", deviceId)
            .put("displayName", displayName).put("generation", generation))
    }
}.toString().encodeToByteArray()
