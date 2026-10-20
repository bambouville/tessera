package com.bambouville.tessera.feature.session

import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.IntOffset
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.abs
import kotlin.math.roundToInt

internal enum class TmuxWindowMoveAction { PREVIOUS, NEXT, START, END }

internal data class TmuxWindowRevealRequest(
    val id: Int,
    val sourceOrder: List<Int>,
    val expectedOrder: List<Int>,
    val contextKey: Any?,
)

internal enum class TmuxWindowRevealAction { WAIT, REVEAL, CANCEL }

internal fun tmuxWindowRevealAction(
    request: TmuxWindowRevealRequest,
    orderedIds: List<Int>,
    contextKey: Any?,
    contextValid: Boolean,
): TmuxWindowRevealAction {
    if (!contextValid || request.contextKey != contextKey ||
        request.sourceOrder.toSet() != orderedIds.toSet()
    ) {
        return TmuxWindowRevealAction.CANCEL
    }
    return when (orderedIds) {
        request.expectedOrder -> TmuxWindowRevealAction.REVEAL
        request.sourceOrder -> TmuxWindowRevealAction.WAIT
        else -> TmuxWindowRevealAction.CANCEL
    }
}

/** Pure destination calculation shared by menus, accessibility actions, and tests. */
internal fun tmuxWindowMoveDestination(
    orderedIds: List<Int>,
    id: Int,
    action: TmuxWindowMoveAction,
): Int? {
    val index = orderedIds.indexOf(id)
    if (index < 0 || orderedIds.size < 2) return null
    val destination = when (action) {
        TmuxWindowMoveAction.PREVIOUS -> index - 1
        TmuxWindowMoveAction.NEXT -> index + 1
        TmuxWindowMoveAction.START -> 0
        TmuxWindowMoveAction.END -> orderedIds.lastIndex
    }
    return destination.takeIf { it in orderedIds.indices && it != index }
}

internal fun movedTmuxWindowOrder(orderedIds: List<Int>, id: Int, destination: Int): List<Int>? {
    val source = orderedIds.indexOf(id)
    if (source < 0 || destination !in orderedIds.indices) return null
    return orderedIds.toMutableList().apply { add(destination, removeAt(source)) }
}

internal enum class TmuxReorderAxis { HORIZONTAL, VERTICAL }

/**
 * In-process reorder presentation. It never mutates tmux while the pointer is down:
 * neighbours move aside locally, and [finish] emits one destination only on drop.
 */
internal class TmuxWindowReorderState(
    private val axis: TmuxReorderAxis,
    private val spacingPx: Float,
) {
    private val bounds = mutableStateMapOf<Int, Rect>()
    private var containerOrigin by mutableStateOf(Offset.Zero)
    private var viewport by mutableStateOf(Rect.Zero)
    private var pointer by mutableStateOf(Offset.Zero)
    private var grabInset by mutableStateOf(0f)
    private var sourceOrder: List<Int> = emptyList()
    private var expectedOrder: List<Int>? by mutableStateOf(null)
    private var contextKey: Any? = null

    var armedId: Int? by mutableStateOf(null)
        private set
    var draggingId: Int? by mutableStateOf(null)
        private set
    var previewOrder: List<Int>? by mutableStateOf(null)
        private set

    val isActive: Boolean get() = armedId != null || draggingId != null

    fun reportContainer(coordinates: LayoutCoordinates) {
        reportGeometry(coordinates.positionInRoot(), coordinates.boundsInRoot())
    }

    internal fun reportGeometry(contentOrigin: Offset, viewportBounds: Rect) {
        containerOrigin = contentOrigin
        viewport = viewportBounds
    }

    internal fun reportItemBounds(id: Int, rect: Rect) { bounds[id] = rect }

    fun reportItem(id: Int, coordinates: LayoutCoordinates) {
        // boundsInRoot() clips descendants to the scroll viewport. An offscreen
        // row can therefore collapse to an empty rect whose centre sorts before
        // the pointer, making a one-row move jump to the end while the IME is up.
        // Reorder comparisons need each item's full layout bounds; only the
        // container viewport used by edge auto-scroll should remain clipped.
        val topLeft = coordinates.positionInRoot()
        bounds[id] = Rect(
            offset = topLeft,
            size = Size(coordinates.size.width.toFloat(), coordinates.size.height.toFloat()),
        )
    }

    fun updateContext(key: Any, order: List<Int>) {
        if (contextKey != null && contextKey != key) cancel()
        contextKey = key
        if (expectedOrder == order) {
            expectedOrder = null
            previewOrder = null
        } else if (!isActive && expectedOrder != null && order.toSet() != expectedOrder?.toSet()) {
            cancel()
        }
        bounds.keys.filterNot(order::contains).forEach(bounds::remove)
    }

    fun idAt(localPosition: Offset, order: List<Int>): Int? {
        val root = localPosition + containerOrigin
        return order.firstOrNull { id -> bounds[id]?.contains(root) == true }
    }

    fun arm(localPosition: Offset, order: List<Int>): Boolean {
        val id = idAt(localPosition, order) ?: return false
        val item = bounds[id] ?: return false
        sourceOrder = order
        previewOrder = order
        armedId = id
        pointer = localPosition + containerOrigin
        grabInset = along(pointer) - start(item)
        return true
    }

    fun beginDrag(): Boolean {
        val id = armedId ?: return false
        armedId = null
        draggingId = id
        return true
    }

    /** Returns true when the preview destination changed. */
    fun drag(localPosition: Offset): Boolean {
        val id = draggingId ?: return false
        pointer = localPosition + containerOrigin
        val item = bounds[id] ?: return false
        val centre = along(localPosition + containerOrigin) - grabInset + extent(item) / 2f
        val remaining = sourceOrder.filterNot { it == id }
        val destination = remaining.count { other ->
            val otherBounds = bounds[other]
            otherBounds != null && centre > start(otherBounds) + extent(otherBounds) / 2f
        }
        val next = remaining.toMutableList().apply { add(destination.coerceIn(0, size), id) }
        if (next == previewOrder) return false
        previewOrder = next
        return true
    }

    fun edgeScrollDelta(localPosition: Offset, edgePx: Float, maximumStepPx: Float): Float {
        val value = along(localPosition + containerOrigin - viewport.topLeft)
        val limit = if (axis == TmuxReorderAxis.HORIZONTAL) viewport.width else viewport.height
        if (limit <= 0f) return 0f
        return when {
            value < edgePx -> -maximumStepPx * ((edgePx - value) / edgePx).coerceIn(0f, 1f)
            value > limit - edgePx -> maximumStepPx * ((value - (limit - edgePx)) / edgePx).coerceIn(0f, 1f)
            else -> 0f
        }
    }

    fun edgeScrollDelta(edgePx: Float, maximumStepPx: Float): Float =
        edgeScrollDelta(pointer - containerOrigin, edgePx, maximumStepPx)

    fun refreshDrag(): Boolean = if (draggingId == null) false else drag(pointer - containerOrigin)

    fun offsetFor(id: Int): IntOffset {
        val item = bounds[id] ?: return IntOffset.Zero
        val alongOffset = if (id == draggingId) {
            along(pointer) - grabInset - start(item)
        } else {
            val order = previewOrder ?: return IntOffset.Zero
            if (id !in order) return IntOffset.Zero
            var target = sourceOrder.firstNotNullOfOrNull { bounds[it]?.let(::start) } ?: start(item)
            for (candidate in order) {
                if (candidate == id) break
                val candidateBounds = bounds[candidate] ?: continue
                target += extent(candidateBounds) + spacingPx
            }
            target - start(item)
        }
        return if (axis == TmuxReorderAxis.HORIZONTAL) {
            IntOffset(alongOffset.roundToInt(), 0)
        } else {
            IntOffset(0, alongOffset.roundToInt())
        }
    }

    fun finish(onCommit: (Int, Int) -> Unit) {
        val id = draggingId ?: return cancel()
        val order = previewOrder ?: return cancel()
        val destination = order.indexOf(id)
        val changed = destination >= 0 && destination != sourceOrder.indexOf(id)
        armedId = null
        draggingId = null
        grabInset = 0f
        if (changed) {
            expectedOrder = order
            onCommit(id, destination)
        } else {
            previewOrder = null
        }
    }

    fun cancel() {
        armedId = null
        draggingId = null
        previewOrder = null
        expectedOrder = null
        sourceOrder = emptyList()
        grabInset = 0f
    }

    private fun along(offset: Offset): Float =
        if (axis == TmuxReorderAxis.HORIZONTAL) offset.x else offset.y

    private fun start(rect: Rect): Float = if (axis == TmuxReorderAxis.HORIZONTAL) rect.left else rect.top
    private fun extent(rect: Rect): Float = if (axis == TmuxReorderAxis.HORIZONTAL) rect.width else rect.height
}

/**
 * Ordinary swipes remain unconsumed for scrolling. A held pointer either moves far enough to
 * start reorder, or stays still long enough to open the item's menu.
 */
internal fun Modifier.tmuxWindowReorderGesture(
    state: TmuxWindowReorderState,
    order: State<List<Int>>,
    enabled: State<Boolean>,
    onMenu: State<(Int) -> Unit>,
    onLift: State<() -> Unit>,
    onCross: State<() -> Unit>,
    onCommit: State<(Int, Int) -> Unit>,
): Modifier = pointerInput(state) {
    try {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            var thresholdPosition: Offset? = null
            var releasedAfterMenuDelay = false
            val cancelled = withTimeoutOrNull(300L) {
                while (true) {
                    val change = awaitPointerEvent(PointerEventPass.Final).changes.firstOrNull { it.id == down.id }
                        ?: return@withTimeoutOrNull true
                    val elapsed = change.uptimeMillis - down.uptimeMillis
                    val distance = (change.position - down.position).getDistance()
                    // awaitFirstDown(Main) can be followed by the very same down at Final.
                    // The chip's clickable modifier may have marked that down consumed; it
                    // is still this recognizer's accepted initial contact, not evidence of
                    // a competing scroll or cancellation.
                    if (elapsed == 0L && change.pressed && distance == 0f) continue
                    if (!change.pressed) {
                        // Synthetic long-clicks can deliver only down/up. A release after
                        // the complete stationary delay opens the menu; an earlier release
                        // must never leave an armed gesture behind.
                        releasedAfterMenuDelay = elapsed >= 600L && distance <= viewConfiguration.touchSlop
                        return@withTimeoutOrNull !releasedAfterMenuDelay
                    }
                    // UI tests and accessibility injectors can advance event time without
                    // waiting in wall-clock time. The hold belongs to the pointer stream,
                    // so honour either clock reaching the threshold. This check precedes
                    // consumption deliberately: a scroll modifier can consume the first
                    // movement after a completed stationary hold in Main before this Final
                    // pass sees it. Any movement/consumption delivered before 300 ms still
                    // takes the cancellation branch below and remains an ordinary scroll.
                    if (elapsed >= 300L) {
                        thresholdPosition = change.position
                        return@withTimeoutOrNull false
                    }
                    if (change.isConsumed || distance > viewConfiguration.touchSlop) return@withTimeoutOrNull true
                }
            }
            if (cancelled == true || !enabled.value || !state.arm(down.position, order.value)) {
                return@awaitEachGesture
            }
            onLift.value()
            if (releasedAfterMenuDelay) {
                val menuId = state.armedId
                state.cancel()
                if (menuId != null) {
                    onMenu.value(menuId)
                }
                return@awaitEachGesture
            }

            val crossedAtThreshold = thresholdPosition?.let { position ->
                (position - down.position).getDistance() > viewConfiguration.touchSlop
            } == true
            var pointerStillPressedAtMenu = true
            val moved = if (crossedAtThreshold) {
                true
            } else {
                withTimeoutOrNull(300L) {
                    while (true) {
                        val change = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.id == down.id }
                            ?: return@withTimeoutOrNull false
                        if (change.uptimeMillis - down.uptimeMillis >= 600L) {
                            pointerStillPressedAtMenu = change.pressed
                            return@withTimeoutOrNull null
                        }
                        if (!change.pressed || change.isConsumed) return@withTimeoutOrNull false
                        if ((change.position - down.position).getDistance() > viewConfiguration.touchSlop) {
                            change.consume()
                            return@withTimeoutOrNull true
                        }
                    }
                }
            }
            if (moved != true) {
                val menuId = state.armedId
                state.cancel()
                if (moved == null && menuId != null) {
                    onMenu.value(menuId)
                    if (pointerStillPressedAtMenu) {
                        while (true) {
                            val change = awaitPointerEvent(PointerEventPass.Initial).changes
                                .firstOrNull { it.id == down.id } ?: break
                            change.consume()
                            if (!change.pressed) break
                        }
                    }
                }
                return@awaitEachGesture
            }
            if (!state.beginDrag()) return@awaitEachGesture
            thresholdPosition?.takeIf { crossedAtThreshold }?.let { position ->
                if (state.drag(position)) onCross.value()
            }

            var dropped = false
            while (true) {
                val change = awaitPointerEvent(PointerEventPass.Initial).changes
                    .firstOrNull { it.id == down.id }
                if (change == null || change.isConsumed) {
                    state.cancel()
                    break
                }
                if (!change.pressed) {
                    dropped = true
                    break
                }
                change.consume()
                if (state.drag(change.position)) onCross.value()
            }
            if (dropped && enabled.value) state.finish(onCommit.value) else state.cancel()
        }
    } finally {
        state.cancel()
    }
}

/** Keeps scrolling at the edge even when the held pointer itself is stationary. */
@Composable
internal fun TmuxWindowEdgeAutoScroll(
    state: TmuxWindowReorderState,
    scrollState: ScrollState,
    edgePx: Float,
    onCross: () -> Unit,
) {
    val currentOnCross = rememberUpdatedState(onCross)
    LaunchedEffect(state.draggingId, scrollState, edgePx) {
        while (state.draggingId != null) {
            withFrameNanos { }
            val delta = state.edgeScrollDelta(edgePx, edgePx / 3f)
            if (abs(delta) > 0.5f) {
                scrollState.scrollBy(delta)
                if (state.refreshDrag()) currentOnCross.value()
            }
        }
    }
}
