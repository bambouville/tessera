package com.bambouville.tessera.feature.session

import android.content.Context
import android.graphics.Typeface
import android.os.Build
import android.view.View
import android.view.ViewTreeObserver
import android.view.MotionEvent
import android.view.InputDevice
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import com.bambouville.tessera.core.bridge.SharedTmuxCellRect
import com.bambouville.tessera.core.bridge.SharedTmuxRenderEffect
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.terminal.TerminalCursorStyle
import com.bambouville.tessera.terminal.TerminalFont
import com.bambouville.tessera.terminal.TerminalTheme
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import kotlinx.coroutines.delay
import kotlin.math.min

/**
 * The stable ledger surface identifier for mosh's detached pane-history view.
 *
 * This deliberately belongs beside the presentation, rather than inside the
 * controller's mosh policy: the controller executes effects by ID while this
 * layer decides which detached Android view exists and where it is framed.
 */
internal fun moshPaneHistoryOverlaySurfaceId(paneId: Int): String = "overlay:$paneId"

internal fun moshSplitScrollAcceptsTouch(isMouseSource: Boolean, classification: Int, sdkInt: Int): Boolean =
    !isMouseSource || (sdkInt >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
        classification == MotionEvent.CLASSIFICATION_TWO_FINGER_SWIPE)

internal class MoshSplitScrollTouchGesture {
    var trackedPointerId: Int? = null
        private set
    var scrolling = false
        private set
    var consumesEvents = false
        private set
    private var initialY = 0f
    private var previousY = 0f

    fun begin(pointerId: Int, y: Float, isMouseSource: Boolean, classification: Int, sdkInt: Int) {
        val accepted = moshSplitScrollAcceptsTouch(isMouseSource, classification, sdkInt)
        trackedPointerId = pointerId.takeIf { accepted }
        initialY = y
        previousY = y
        scrolling = false
        // A touchpad swipe must never send a mouse press to the primary.
        consumesEvents = accepted && isMouseSource
    }

    fun pointerDown() {
        if (!scrolling) trackedPointerId = null
    }

    fun move(pointerId: Int, y: Float, touchSlop: Float): Float? {
        if (pointerId != trackedPointerId) return null
        if (!scrolling && kotlin.math.abs(y - initialY) <= touchSlop) return null
        scrolling = true
        consumesEvents = true
        return (previousY - y).also { previousY = y }
    }

    fun pointerUp(pointerId: Int): Boolean {
        if (pointerId != trackedPointerId) return false
        trackedPointerId = null
        val endedScroll = scrolling
        scrolling = false
        // Keep ownership after takeover until the whole stream ends.
        return endedScroll
    }

    fun finish() {
        trackedPointerId = null
        scrolling = false
        consumesEvents = false
    }
}

/**
 * Each gesture may request history once, on its first frame toward history.
 * A drag that starts toward the tail can still reverse into history.
 */
internal class MoshHistoryRequestOffer {
    var offered = false
        private set

    fun reset() { offered = false }

    /** True while this frame may still request history. */
    fun take(pointsY: Double): Boolean {
        if (offered) return false
        if (pointsY < 0) offered = true
        return true
    }
}

internal class MoshScrollGestureTarget {
    var paneId: Int? = null
        private set

    private var wheelToken: Long? = null
    private var lastWheelEventTime = 0L

    fun begin(paneId: Int?) { this.paneId = paneId }

    fun beginsWheelGesture(downTime: Long, eventTime: Long): Boolean {
        // Mouse wheels may omit downTime; continuous streams otherwise keep
        // their OS gesture identity even across a delayed frame.
        val begins = wheelToken != downTime ||
            (downTime == 0L && eventTime - lastWheelEventTime > 250)
        wheelToken = downTime
        lastWheelEventTime = eventTime
        return begins
    }
}

/** The request-producing part of the native split observer, also driven on the JVM. */
internal class MoshSplitScrollRequestObserver<R>(
    private val paneAtLocation: (Float, Float) -> Int?,
    private val onScroll: (Int, Int, Double, Boolean) -> R?,
) {
    private val target = MoshScrollGestureTarget()
    private val historyOffer = MoshHistoryRequestOffer()
    val offered: Boolean get() = historyOffer.offered

    fun begin(x: Float, y: Float) {
        target.begin(paneAtLocation(x, y))
        historyOffer.reset()
    }

    fun beginsWheelGesture(downTime: Long, eventTime: Long): Boolean =
        target.beginsWheelGesture(downTime, eventTime)

    fun scroll(rowsDown: Int, pointsY: Double): R? = target.paneId?.let {
        onScroll(it, rowsDown, pointsY, historyOffer.take(pointsY))
    }
}

/** Lazily owns physical readers; registration completes before getOrCreate returns. */
internal class MoshPaneHistoryRuntimeStore<R>(
    private val createAndAttach: (Int) -> R,
    private val detachAndClose: (Int, R) -> Unit,
) {
    val runtimes = mutableStateMapOf<Int, R>()

    fun getOrCreate(paneId: Int): R = runtimes[paneId] ?: createAndAttach(paneId).also {
        runtimes[paneId] = it
    }

    fun retainPanes(paneIds: Set<Int>) {
        runtimes.keys.filter { it !in paneIds }.forEach { paneId ->
            runtimes.remove(paneId)?.let { detachAndClose(paneId, it) }
        }
    }

    fun close() = retainPanes(emptySet())
}

/** Input targets a pane even when a different pane owns the visible reader. */
internal fun returnMoshPaneHistoryInputToTail(
    paneId: Int?,
    hasHistory: (String) -> Boolean,
    cancelHistoryScroll: (String) -> Unit,
    returnToTail: (String) -> Unit,
) {
    val surfaceId = paneId?.let(::moshPaneHistoryOverlaySurfaceId) ?: return
    if (!hasHistory(surfaceId)) return
    cancelHistoryScroll(surfaceId)
    returnToTail(surfaceId)
}

/** Production observer -> runtime -> history request route, independent of Android Views. */
internal class MoshPaneHistoryScrollRouter<R>(
    private val runtimes: MoshPaneHistoryRuntimeStore<R>,
    private val presentation: MoshPaneHistoryOverlayPresentation,
    private val deliveries: () -> Map<String, MoshPaneHistoryReadyDelivery>,
    private val paneExists: (Int) -> Boolean,
    private val isAlternateScreen: (Int) -> Boolean,
    private val readerPaneId: () -> Int?,
    private val onReaderPaneChanged: (Int) -> Unit,
    private val beginHistoryScroll: (R) -> Unit,
    private val onHistoryRequested: (String, Double, Boolean) -> Unit,
    private val onReturnedToLiveTail: (String) -> Unit,
    private val onAltScreenScroll: (Int, Int) -> Unit,
) {
    fun find(paneId: Int, onFindRequested: (String) -> Unit) {
        val runtime = scroll(paneId, 0, 0.0, false) ?: return
        if (!presentation.shouldReveal(paneId, deliveries())) beginHistoryScroll(runtime)
        onFindRequested(moshPaneHistoryOverlaySurfaceId(paneId))
    }

    fun scroll(paneId: Int, rowsDown: Int, pointsY: Double, mayRequestHistory: Boolean): R? {
        if (!paneExists(paneId)) return null
        val ready = deliveries()
        val previousPaneId = readerPaneId()
        if (presentation.returnToLiveTailForReaderSwitch(previousPaneId, paneId, ready)) {
            onReturnedToLiveTail(moshPaneHistoryOverlaySurfaceId(requireNotNull(previousPaneId)))
        }
        onReaderPaneChanged(paneId)
        if (isAlternateScreen(paneId) && !presentation.shouldReveal(paneId, ready)) {
            if (rowsDown != 0) onAltScreenScroll(paneId, rowsDown)
            return null
        }
        // The first gesture attaches and declares the surface synchronously;
        // it must not spend its only history offer before that destination exists.
        val runtime = runtimes.getOrCreate(paneId)
        if (mayRequestHistory && pointsY < 0 && !presentation.shouldReveal(paneId, ready)) {
            beginHistoryScroll(runtime)
            onHistoryRequested(moshPaneHistoryOverlaySurfaceId(paneId), pointsY, false)
        }
        return runtime
    }
}

internal fun moshScrollPaneAtLocation(
    x: Float, y: Float,
    cellWidth: Float, cellHeight: Int,
    baselineInset: Int, scrollOffsetPixels: Float,
    layout: SharedTmuxLayoutNode?, fallback: Int?,
    contentRects: Map<Int, SharedTmuxCellRect> = emptyMap(),
): Int? {
    if (cellWidth <= 0 || cellHeight <= 0 || !x.isFinite() || !y.isFinite()) return fallback
    val column = kotlin.math.floor(x / cellWidth).toInt()
    val row = kotlin.math.floor((y + scrollOffsetPixels - baselineInset) / cellHeight).toInt()
    if (contentRects.isNotEmpty()) {
        return contentRects.entries.firstOrNull { (_, rect) ->
            column >= rect.x && column < rect.x + rect.columns &&
                row >= rect.y && row < rect.y + rect.rows
        }?.key ?: fallback
    }
    return moshScrollPaneAtCell(column, row, layout, fallback)
}

internal fun moshScrollPaneAtCell(
    column: Int,
    row: Int,
    layout: SharedTmuxLayoutNode?,
    fallback: Int?,
): Int? = when (layout) {
    null -> fallback
    is SharedTmuxLayoutNode.Leaf -> if (column >= layout.x && column < layout.x + layout.width &&
        row >= layout.y && row < layout.y + layout.height
    ) layout.paneId else fallback
    is SharedTmuxLayoutNode.Split -> layout.children.firstNotNullOfOrNull {
        moshScrollPaneAtCell(column, row, it, null)
    } ?: fallback
}

/**
 * A delivered `historyReady` needs an adapter-owned monotonic [sequence].
 * The same pane can legitimately receive a second capture with identical
 * depth/history-size values after returning to its live tail, so structural
 * equality of [effect] is not a delivery identity.
 */
internal data class MoshPaneHistoryReadyDelivery(
    val sequence: Long,
    val effect: SharedTmuxRenderEffect.HistoryReady,
) {
    init {
        require(sequence > 0) { "history-ready delivery sequence must be positive" }
        require(effect.surfaceId == moshPaneHistoryOverlaySurfaceId(requireNotNull(effect.owner.paneId))) {
            "history-ready overlay must be addressed to its owner pane"
        }
    }

    val paneId: Int get() = requireNotNull(effect.owner.paneId)
}

/** Adapts the controller's ordered v2 `historyReady` handoff for this view. */
internal fun TmuxRenderHistoryReady.asMoshPaneHistoryReadyDelivery(): MoshPaneHistoryReadyDelivery =
    MoshPaneHistoryReadyDelivery(
        sequence = deliveryToken,
        effect = SharedTmuxRenderEffect.HistoryReady(
            surfaceId = surfaceId,
            owner = owner,
            depth = depth,
            historySize = historySize,
            placement = placement,
        ),
    )

/**
 * Maps the ledger's capture replacement placement into Termux's local
 * scrollback coordinates. A capture is fed at its live tail, so a `Bottom`
 * replacement still advances one row into history to complete the gesture
 * that initiated the capture. Replacements while the user is already reading
 * history retain their distance from that tail, capped by the new capture.
 */
internal fun moshHistoryTopRowForPlacement(
    placement: com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement,
    priorDistanceFromBottom: Int,
    availableHistoryRows: Int,
): Int {
    if (availableHistoryRows <= 0) return 0
    val requestedDistance = when (placement) {
        com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement.Bottom -> 1
        com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement.PreserveDistanceFromBottom ->
            priorDistanceFromBottom.coerceAtLeast(1)
    }
    return -min(requestedDistance, availableHistoryRows)
}

/**
 * A FindOpened request is idempotent once the mounted focused overlay already
 * contains the ledger's configured full depth. In that case the ledger quite
 * correctly emits no second HistoryReady, so presentation must reuse it.
 */
internal fun moshFindCanReuseFullDepthDelivery(
    requestedSurfaceId: String,
    deliveredSurfaceId: String?,
    deliveredDepth: Int,
    scrollbackLimit: Int,
): Boolean = deliveredSurfaceId == requestedSurfaceId && deliveredDepth >= scrollbackLimit

/**
 * Find may open only after its matching full-depth capture is painted into
 * the target terminal. A pre-existing full-depth delivery is permitted when
 * the ledger has correctly suppressed a redundant replacement.
 */
internal fun moshFindCanOpenAfterAppliedDelivery(
    requestedSurfaceId: String,
    deliveredSurfaceId: String?,
    deliveredToken: Long,
    requiredNewerThanToken: Long,
    deliveredDepth: Int,
    scrollbackLimit: Int,
    appliedDeliveryToken: Long,
    mayReuseExistingDelivery: Boolean,
): Boolean = moshFindCanReuseFullDepthDelivery(
    requestedSurfaceId = requestedSurfaceId,
    deliveredSurfaceId = deliveredSurfaceId,
    deliveredDepth = deliveredDepth,
    scrollbackLimit = scrollbackLimit,
) && appliedDeliveryToken >= deliveredToken &&
    (mayReuseExistingDelivery || deliveredToken > requiredNewerThanToken)

/**
 * Pure presentation state for one or more parked pane-history surfaces.
 *
 * It owns no capture policy. In particular, it never creates a history fetch:
 * a scroll-up is submitted as a shared ledger fact by the controller, then
 * this state exposes only the first completed `historyReady` for the focused
 * pane. This keeps an output-time freeze as a ledger decision rather than a
 * UI race.
 */
internal class MoshPaneHistoryOverlayPresentation {
    private val readySequenceByPane = mutableMapOf<Int, Long>()
    private val dismissedSequenceByPane = mutableMapOf<Int, Long>()
    private val sawHistoryRowByPane = mutableMapOf<Int, Boolean>()
    private val deeperHistoryRequestedSequenceByPane = mutableMapOf<Int, Long>()

    fun accept(delivery: MoshPaneHistoryReadyDelivery): Boolean {
        val previous = readySequenceByPane[delivery.paneId] ?: 0L
        if (delivery.sequence <= previous) return false
        readySequenceByPane[delivery.paneId] = delivery.sequence
        // A new capture is a new immutable snapshot, even if a prior capture
        // was dismissed at its tail.
        sawHistoryRowByPane.remove(delivery.paneId)
        deeperHistoryRequestedSequenceByPane.remove(delivery.paneId)
        return true
    }

    fun shouldReveal(paneId: Int?, deliveries: Map<String, MoshPaneHistoryReadyDelivery>): Boolean {
        val pane = paneId ?: return false
        val delivery = deliveries[moshPaneHistoryOverlaySurfaceId(pane)] ?: return false
        if (delivery.paneId != pane) return false
        val ready = readySequenceByPane[pane] ?: return false
        return ready == delivery.sequence && dismissedSequenceByPane[pane] != ready
    }

    /**
     * Native Termux scrollback uses `topRow == 0` for the live tail and a
     * negative row for local history. Do not dismiss the just-fed overlay at
     * row zero: it must first have genuinely entered history.
     */
    fun observeNativeTopRow(
        paneId: Int,
        topRow: Int,
        deliveries: Map<String, MoshPaneHistoryReadyDelivery>,
    ): Boolean {
        val delivery = deliveries[moshPaneHistoryOverlaySurfaceId(paneId)] ?: return false
        val ready = readySequenceByPane[paneId] ?: return false
        if (delivery.sequence != ready || dismissedSequenceByPane[paneId] == ready) return false
        if (topRow < 0) {
            sawHistoryRowByPane[paneId] = true
            return false
        }
        if (topRow == 0 && sawHistoryRowByPane[paneId] == true) {
            dismissedSequenceByPane[paneId] = ready
            sawHistoryRowByPane.remove(paneId)
            return true
        }
        return false
    }

    /**
     * The native surface has reached the oldest row of its current capture.
     * Submit exactly one deeper request for each immutable history delivery;
     * the next `historyReady` re-arms this for the replacement capture.
     */
    fun shouldRequestDeeperHistory(
        paneId: Int,
        topRow: Int,
        availableHistoryRows: Int,
        deliveries: Map<String, MoshPaneHistoryReadyDelivery>,
    ): Boolean {
        if (availableHistoryRows <= 0 || topRow > -availableHistoryRows) return false
        val delivery = deliveries[moshPaneHistoryOverlaySurfaceId(paneId)] ?: return false
        val ready = readySequenceByPane[paneId] ?: return false
        if (delivery.sequence != ready || dismissedSequenceByPane[paneId] == ready) return false
        if (deeperHistoryRequestedSequenceByPane[paneId] == ready) return false
        deeperHistoryRequestedSequenceByPane[paneId] = ready
        return true
    }

    fun dismissForPaneSwitch(paneId: Int) {
        // Pane changes do not throw content away: leaving an overlay parked is
        // what makes the switch back a zero-mount reveal. Only the active
        // pane's geometry and hit target move.
        sawHistoryRowByPane.remove(paneId)
    }

    fun returnToLiveTailForReaderSwitch(
        previousPaneId: Int?,
        nextPaneId: Int,
        deliveries: Map<String, MoshPaneHistoryReadyDelivery>,
    ): Boolean {
        val previous = previousPaneId ?: return false
        if (previous == nextPaneId || !shouldReveal(previous, deliveries)) return false
        dismissedSequenceByPane[previous] = readySequenceByPane.getValue(previous)
        sawHistoryRowByPane.remove(previous)
        return true
    }

    /**
     * Park overlays only within the active tmux window. A pane id is globally
     * stable while it exists, so retaining a runtime across a window switch
     * would retain a stale capture that the side-channel ledger can no longer
     * invalidate through the active declaration set.
     */
    fun retainPanes(paneIds: Set<Int>) {
        readySequenceByPane.keys.retainAll(paneIds)
        dismissedSequenceByPane.keys.retainAll(paneIds)
        sawHistoryRowByPane.keys.retainAll(paneIds)
        deeperHistoryRequestedSequenceByPane.keys.retainAll(paneIds)
    }

    fun visiblePane(
        focusedPaneId: Int?,
        deliveries: Map<String, MoshPaneHistoryReadyDelivery>,
    ): Int? = focusedPaneId?.takeIf { shouldReveal(it, deliveries) }
}

/**
 * Delivery-scoped tail state for a primary mosh history surface. A native
 * tail row is meaningful only after that same delivered capture has actually
 * entered local history; this prevents the just-fed capture's initial row
 * zero from thawing output immediately.
 */
internal class MoshPrimaryLiveHistoryPresentation {
    private var readyDeliveryToken = 0L
    private var returnedDeliveryToken = 0L
    private var sawHistoryRow = false
    private var deeperHistoryRequestedDeliveryToken = 0L

    fun reset() {
        returnedDeliveryToken = readyDeliveryToken
        sawHistoryRow = false
        deeperHistoryRequestedDeliveryToken = 0L
    }

    fun accept(deliveryToken: Long): Boolean {
        if (deliveryToken <= readyDeliveryToken) return false
        readyDeliveryToken = deliveryToken
        sawHistoryRow = false
        deeperHistoryRequestedDeliveryToken = 0L
        return true
    }

    /** True while this delivered capture remains the reader's local history. */
    fun hasActiveHistory(): Boolean =
        readyDeliveryToken != 0L && returnedDeliveryToken != readyDeliveryToken

    fun observeNativeTopRow(topRow: Int, availableHistoryRows: Int = Int.MAX_VALUE): Boolean {
        if (readyDeliveryToken == 0L || returnedDeliveryToken == readyDeliveryToken) return false
        if (topRow < 0) {
            sawHistoryRow = true
            return false
        }
        // `bind` clears Termux scrollback and resets topRow before a deeper
        // replacement feeds. That artificial zero has no local transcript to
        // return from, so it must not cancel the in-flight replacement.
        if (topRow == 0 && sawHistoryRow && availableHistoryRows > 0) {
            returnedDeliveryToken = readyDeliveryToken
            sawHistoryRow = false
            return true
        }
        return false
    }

    /**
     * Mirrors the detached-overlay underflow rule for the live primary
     * surface. Native scrolling handles every ordinary upward gesture; only
     * the capture's oldest row requests one replacement, re-armed by its next
     * HistoryReady delivery.
     */
    fun shouldRequestDeeperHistory(topRow: Int, availableHistoryRows: Int): Boolean {
        if (!hasActiveHistory() || availableHistoryRows <= 0 || topRow > -availableHistoryRows) {
            return false
        }
        if (deeperHistoryRequestedDeliveryToken == readyDeliveryToken) return false
        deeperHistoryRequestedDeliveryToken = readyDeliveryToken
        return true
    }
}

/** A mounted-but-parkable detached terminal and its last native scroll row. */
@Stable
internal class MoshPaneHistoryOverlayRuntime(
    val paneId: Int,
    val surface: TermuxTerminalSurface,
) {
    var lastNativeTopRow by mutableIntStateOf(0)
    var lastHistoryDistanceFromBottom by mutableIntStateOf(0)
    var pendingPlacementSequence by mutableStateOf(0L)
    var pendingPlacementTopRow by mutableIntStateOf(0)
    var appliedPlacementSequence by mutableStateOf(0L)
    var acknowledgedPlacementSequence by mutableStateOf(0L)

    fun recordNativeTopRow(topRow: Int) {
        lastNativeTopRow = topRow
        if (topRow < 0) lastHistoryDistanceFromBottom = -topRow
    }

    fun queueHistoryPlacement(delivery: MoshPaneHistoryReadyDelivery) {
        if (delivery.sequence <= pendingPlacementSequence) return
        pendingPlacementSequence = delivery.sequence
        // Preserve the last non-tail position across `bind`/`feed`: those can
        // reset the view to row zero before Compose observes HistoryReady.
        pendingPlacementTopRow = moshHistoryTopRowForPlacement(
            placement = delivery.effect.placement,
            priorDistanceFromBottom = lastHistoryDistanceFromBottom,
            availableHistoryRows = delivery.effect.historySize,
        )
    }
}

/** Invalidates posted UI work as soon as its Compose surface leaves the tree. */
private class MoshHistoryPresentationLease {
    var active: Boolean = true
}

/**
 * Android presentation for the detached mosh history surface.
 *
 * A compact mosh canvas projects the focused pane to its complete physical
 * viewport. Giving this surface that exact pane cell rect as both window and
 * focus therefore aligns its captured rows with the live mosh pane beneath it
 * without resizing the mosh-owned whole-window terminal. Hidden surfaces stay
 * attached as `INVISIBLE`, which parks the expensive Termux view while making
 * it neither drawable nor touchable.
 */
@Composable
internal fun MoshPaneHistoryOverlaySurface(
    runtime: MoshPaneHistoryOverlayRuntime,
    paneRect: SharedTmuxCellRect?,
    visible: Boolean,
    terminalTextSizeSp: Int,
    terminalTypeface: Typeface,
    terminalTheme: TerminalTheme,
    cursorStyle: TerminalCursorStyle,
    cursorBlink: Boolean,
    eligibleDeliveryToken: Long?,
    onNativeTopRowChanged: (paneId: Int, topRow: Int, atOldestHistoryRow: Boolean) -> Unit,
    onHistoryPlacementApplied: (surfaceId: String, deliveryToken: Long) -> Unit,
    onHistoryDeliveryApplied: (surfaceId: String, deliveryToken: Long) -> Unit,
    modifier: Modifier = Modifier,
    drawingEnabled: Boolean = true,
    takesFocus: Boolean = true,
) {
    val surface = runtime.surface
    val currentVisible by rememberUpdatedState(visible)
    val currentEligibleDeliveryToken by rememberUpdatedState(eligibleDeliveryToken)
    val currentOnHistoryDeliveryApplied by rememberUpdatedState(onHistoryDeliveryApplied)
    val presentationLease = remember(surface) { MoshHistoryPresentationLease() }

    DisposableEffect(surface) {
        presentationLease.active = true
        onDispose { presentationLease.active = false }
    }

    // A detached history transcript always scrolls locally. It must not
    // inherit a primary mosh surface's "mouse implies alternate screen"
    // routing (which would forward a wheel to the already-live pane instead
    // of moving this parked capture).
    LaunchedEffect(surface) { surface.setMouseReportingImpliesAltScreen(false) }
    LaunchedEffect(surface, terminalTextSizeSp, terminalTypeface) {
        surface.setFont(TerminalFont(terminalTextSizeSp.coerceIn(8, 40), terminalTypeface))
    }
    LaunchedEffect(surface, terminalTheme) { surface.setTheme(terminalTheme) }
    LaunchedEffect(surface, cursorStyle, cursorBlink) {
        surface.setCursorAppearance(cursorStyle, cursorBlink)
    }
    LaunchedEffect(surface, runtime.pendingPlacementSequence) {
        val sequence = runtime.pendingPlacementSequence
        val requestedTopRow = runtime.pendingPlacementTopRow
        if (sequence <= runtime.appliedPlacementSequence) return@LaunchedEffect
        surface.view.post {
            if (!presentationLease.active ||
                currentEligibleDeliveryToken != sequence ||
                sequence != runtime.pendingPlacementSequence ||
                sequence <= runtime.appliedPlacementSequence
            ) {
                return@post
            }
            val availableRows = surface.view.mEmulator?.screen?.activeTranscriptRows ?: 0
            val topRow = requestedTopRow.coerceIn(-availableRows, 0)
            surface.view.completeHistoryScroll(topRow)
            val placedTopRow = surface.view.topRow
            runtime.appliedPlacementSequence = sequence
            runtime.recordNativeTopRow(placedTopRow)
            onNativeTopRowChanged(
                runtime.paneId,
                placedTopRow,
                // This programmatic row is the completion of the initiating
                // request, not a second user underflow. A subsequent native
                // gesture at the oldest row is what may page deeper.
                false,
            )
            // Placement is only phase one. The host now reveals this exact
            // token; a second posted turn below proves the Android view is
            // actually shown before the shared ledger is acknowledged.
            onHistoryPlacementApplied(moshPaneHistoryOverlaySurfaceId(runtime.paneId), sequence)
        }
    }

    TerminalViewport(
        terminal = surface,
        drawingEnabled = drawingEnabled,
        update = { viewport ->
            viewport.setWindowGrid(paneRect, paneRect)
            // `INVISIBLE` keeps the AndroidView and Termux renderer mounted,
            // unlike a conditional Compose branch, while allowing the mosh
            // primary canvas to receive every touch while history is dormant.
            viewport.visibility = if (visible) View.VISIBLE else View.INVISIBLE
            surface.view.isFocusable = takesFocus
            surface.view.isFocusableInTouchMode = takesFocus
            surface.setFocused(visible && takesFocus)
        },
        modifier = modifier.clipToBounds(),
    )

    LaunchedEffect(
        surface,
        visible,
        eligibleDeliveryToken,
        runtime.appliedPlacementSequence,
    ) {
        val sequence = runtime.appliedPlacementSequence
        if (!visible || eligibleDeliveryToken != sequence ||
            sequence <= runtime.acknowledgedPlacementSequence
        ) return@LaunchedEffect
        while (presentationLease.active && currentVisible &&
            currentEligibleDeliveryToken == sequence &&
            runtime.appliedPlacementSequence == sequence &&
            sequence > runtime.acknowledgedPlacementSequence
        ) {
            if (surface.view.isAttachedToWindow && surface.view.isShown) {
                runtime.acknowledgedPlacementSequence = sequence
                currentOnHistoryDeliveryApplied(
                    moshPaneHistoryOverlaySurfaceId(runtime.paneId),
                    sequence,
                )
                return@LaunchedEffect
            }
            // AndroidView attachment and visibility can lag the Compose state
            // that reveals this token. Retain the exact staged owner until a
            // later frame proves the native terminal is actually shown.
            delay(16)
        }
    }

    // A TerminalView's native gesture recognizer owns movement. Sampling
    // after draws lets flings settle naturally before paging decisions.
    DisposableEffect(surface, visible) {
        val observer = ViewTreeObserver.OnDrawListener observer@{
            if (!visible || surface.view.isHistoryScrollPending) return@observer
            val topRow = surface.snapshotNonSecretState().topRow
            if (topRow != runtime.lastNativeTopRow) {
                runtime.recordNativeTopRow(topRow)
                val availableRows = surface.view.mEmulator?.screen?.activeTranscriptRows ?: 0
                onNativeTopRowChanged(
                    runtime.paneId,
                    topRow,
                    availableRows > 0 && topRow <= -availableRows,
                )
            }
        }
        surface.view.viewTreeObserver.addOnDrawListener(observer)
        onDispose {
            surface.view.viewTreeObserver.takeIf { it.isAlive }?.removeOnDrawListener(observer)
        }
    }

    // Termux keeps ownership of its gestures (these listeners never consume
    // an event). They cover the important case where a new drag or wheel
    // starts while the view is *already* clamped at the capture's oldest row:
    // no top-row change would otherwise cause an OnDraw callback.
    DisposableEffect(surface, visible) {
        var initialY = 0f
        var signalledInGesture = false
        val touchSlop = surface.view.context.resources.displayMetrics.density * 8f
        fun signalIfAtOldest() {
            if (!visible) return
            val availableRows = surface.view.mEmulator?.screen?.activeTranscriptRows ?: 0
            val topRow = surface.snapshotNonSecretState().topRow
            if (availableRows > 0 && topRow <= -availableRows) {
                onNativeTopRowChanged(runtime.paneId, topRow, true)
            }
        }
        val touchListener = View.OnTouchListener listener@{ _, event ->
            if (!visible) return@listener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    initialY = event.y
                    signalledInGesture = false
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!signalledInGesture && initialY - event.y <= -touchSlop) {
                        signalledInGesture = true
                        signalIfAtOldest()
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> signalledInGesture = false
            }
            false
        }
        val wheelListener = View.OnGenericMotionListener { _, event ->
            if (visible && event.actionMasked == MotionEvent.ACTION_SCROLL &&
                event.getAxisValue(MotionEvent.AXIS_VSCROLL) > 0f
            ) {
                signalIfAtOldest()
            }
            false
        }
        surface.view.setOnTouchListener(touchListener)
        surface.view.setOnGenericMotionListener(wheelListener)
        onDispose {
            surface.view.setOnTouchListener(null)
            surface.view.setOnGenericMotionListener(null)
        }
    }
}

/**
 * Owns detached overlay views for the lifetime of a mosh+tmux presentation.
 * It creates an overlay before requesting history, registers it with the
 * controller, reveals only after the ordered `historyReady` effect, and
 * parks it rather than destroys it at the live tail or on pane changes.
 */
@Composable
internal fun MoshPaneHistoryOverlayHost(
    context: Context,
    activeWindow: SharedTmuxWindow?,
    focusedPaneId: Int?,
    findPaneId: Int?,
    primaryTerminal: TermuxTerminalSurface,
    deliveries: Map<String, MoshPaneHistoryReadyDelivery>,
    scrollbackLines: Int,
    terminalTextSizeSp: Int,
    terminalTypeface: Typeface,
    terminalTheme: TerminalTheme,
    cursorStyle: TerminalCursorStyle,
    cursorBlink: Boolean,
    onSurfaceAttached: (paneId: Int, surface: TermuxTerminalSurface) -> Unit,
    onSurfaceDetached: (paneId: Int, surface: TermuxTerminalSurface) -> Unit,
    onHistoryRequested: (surfaceId: String, pointsY: Double, isInertial: Boolean) -> Unit,
    onFindRequested: (surfaceId: String) -> Unit,
    onReturnedToLiveTail: (surfaceId: String) -> Unit,
    onAltScreenScroll: (paneId: Int, rowsDown: Int) -> Unit = { _, _ -> },
    onHistoryDeliveryApplied: (surfaceId: String, deliveryToken: Long) -> Unit,
    onVisibleOverlaySurfaceChanged: (TermuxTerminalSurface?) -> Unit,
    modifier: Modifier = Modifier,
    /** P9: false while the session is hidden or veiled (see [TerminalDrawingGate]). */
    drawingEnabled: Boolean = true,
    paneContentRects: Map<Int, SharedTmuxCellRect> = emptyMap(),
) {
    var scrollPaneId by remember(activeWindow?.id) { mutableStateOf<Int?>(null) }
    val historyPaneId = scrollPaneId ?: focusedPaneId
    LaunchedEffect(focusedPaneId) { scrollPaneId = null }
    val presentation = remember { MoshPaneHistoryOverlayPresentation() }
    var observedDeliveryEpoch by remember { mutableStateOf(0L) }
    var placedDeliveryTokens by remember { mutableStateOf<Map<String, Long>>(emptyMap()) }
    // The local focused-pane state can lag a `%session-window-changed` by one
    // Compose frame. Keep membership derived from the new tmux snapshot, not
    // from that lagging focus value, so an old parked overlay cannot briefly
    // become visible (or be handed to Find) while its disposal effect runs.
    val activePaneIds = activeWindow?.panes
        ?.filter { activeWindow.layout?.findPaneForPresentation(it.id) != null }
        ?.mapTo(mutableSetOf()) { it.id } ?: emptySet()

    val currentOnSurfaceAttached by rememberUpdatedState(onSurfaceAttached)
    val currentOnSurfaceDetached by rememberUpdatedState(onSurfaceDetached)
    val createRuntime: (Int) -> MoshPaneHistoryOverlayRuntime = { paneId ->
        MoshPaneHistoryOverlayRuntime(
            paneId = paneId,
            surface = TermuxTerminalSurface(
                context = context,
                transcriptRows = scrollbackLines,
                initialFontSizeSp = terminalTextSizeSp,
                initialTheme = terminalTheme,
                initialCursorStyle = cursorStyle,
                initialCursorBlink = cursorBlink,
                initialTypeface = terminalTypeface,
            ),
        ).also { runtime ->
            val pane = requireNotNull(activeWindow?.layout?.findPaneForPresentation(paneId))
            val rect = paneContentRects[paneId]
            // Native DOWN/MOVE/wheel events arrive in this same stack, before
            // Compose mounts the AndroidView. An emulator-less view discards
            // those events, so initialize the authoritative pane grid now.
            runtime.surface.resize(
                (rect?.columns ?: pane.width).coerceAtLeast(4),
                (rect?.rows ?: pane.height).coerceAtLeast(4),
            )
            runtime.surface.setMouseReportingImpliesAltScreen(false)
            runtime.surface.view.isFocusable = false
            runtime.surface.view.isFocusableInTouchMode = false
            currentOnSurfaceAttached(paneId, runtime.surface)
        }
    }
    val currentCreateRuntime by rememberUpdatedState(createRuntime)
    val runtimeStore = remember {
        MoshPaneHistoryRuntimeStore(
            createAndAttach = { paneId: Int -> currentCreateRuntime(paneId) },
            detachAndClose = { paneId, runtime ->
                currentOnSurfaceDetached(paneId, runtime.surface)
                runtime.surface.close()
            },
        )
    }
    val runtimes = runtimeStore.runtimes
    DisposableEffect(runtimeStore) {
        onDispose { runtimeStore.close() }
    }

    LaunchedEffect(activeWindow?.id, activePaneIds) {
        presentation.retainPanes(activePaneIds)
        val activeSurfaceIDs = activePaneIds.mapTo(mutableSetOf(), ::moshPaneHistoryOverlaySurfaceId)
        placedDeliveryTokens = placedDeliveryTokens.filterKeys(activeSurfaceIDs::contains)
        // Close only readers that leave the current window/layout.
        runtimeStore.retainPanes(activePaneIds)
    }
    LaunchedEffect(deliveries, activeWindow?.id) {
        deliveries.values.filter { it.paneId in activePaneIds }.forEach { delivery ->
            if (presentation.accept(delivery)) {
                // A stale delivery cannot allocate an unrequested reader.
                runtimes[delivery.paneId]?.queueHistoryPlacement(delivery)
                observedDeliveryEpoch += 1
            }
        }
    }
    val visiblePaneId = historyPaneId
        ?.takeIf { it in activePaneIds }
        ?.takeIf { presentation.shouldReveal(it, deliveries) }
        ?.takeIf { paneId ->
            val surfaceID = moshPaneHistoryOverlaySurfaceId(paneId)
            val delivery = deliveries[surfaceID]
            delivery != null && placedDeliveryTokens[surfaceID] == delivery.sequence
        }
    LaunchedEffect(visiblePaneId, runtimes.size) {
        onVisibleOverlaySurfaceChanged(
            visiblePaneId?.let { paneId -> runtimes[paneId]?.surface },
        )
    }
    DisposableEffect(Unit) {
        onDispose { onVisibleOverlaySurfaceChanged(null) }
    }
    val layout = activeWindow?.layout
    runtimes.values.toList().forEach { runtime ->
        // A window change can replace the only runtime in this list at the
        // same composition slot. Key the subtree by the runtime itself so
        // AndroidView releases the old viewport and creates one bound to the
        // replacement surface; positional reuse would leave the new surface
        // registered but without an emulator.
        key(runtime) {
            val pane = layout?.findPaneForPresentation(runtime.paneId)
            val paneRect = paneContentRects[runtime.paneId] ?: pane?.let {
                SharedTmuxCellRect(columns = it.width, rows = it.height, x = it.x, y = it.y)
            }
            val visible = runtime.paneId == visiblePaneId && paneRect != null
            val surfaceID = moshPaneHistoryOverlaySurfaceId(runtime.paneId)
            val eligibleDeliveryToken = deliveries[surfaceID]
                ?.sequence
                ?.takeIf { token ->
                    paneRect != null && token == runtime.pendingPlacementSequence
                }
            MoshPaneHistoryOverlaySurface(
                runtime = runtime,
                paneRect = paneRect,
                visible = visible,
                terminalTextSizeSp = terminalTextSizeSp,
                terminalTypeface = terminalTypeface,
                terminalTheme = terminalTheme,
                cursorStyle = cursorStyle,
                cursorBlink = cursorBlink,
                drawingEnabled = drawingEnabled,
                takesFocus = false,
                eligibleDeliveryToken = eligibleDeliveryToken,
                onNativeTopRowChanged = { paneId, topRow, atOldestHistoryRow ->
                    if (presentation.observeNativeTopRow(paneId, topRow, deliveries)) {
                        onReturnedToLiveTail(moshPaneHistoryOverlaySurfaceId(paneId))
                    } else if (atOldestHistoryRow && presentation.shouldRequestDeeperHistory(
                            paneId = paneId,
                            topRow = topRow,
                            availableHistoryRows = runtime.surface.view.mEmulator?.screen?.activeTranscriptRows ?: 0,
                            deliveries = deliveries,
                        )
                    ) {
                        runtime.surface.view.beginHistoryScroll()
                        onHistoryRequested(moshPaneHistoryOverlaySurfaceId(paneId), -1.0, false)
                    }
                },
                onHistoryPlacementApplied = { placedSurfaceID, deliveryToken ->
                    val prior = placedDeliveryTokens[placedSurfaceID] ?: 0L
                    if (deliveryToken > prior) {
                        placedDeliveryTokens = placedDeliveryTokens +
                            (placedSurfaceID to deliveryToken)
                    }
                },
                onHistoryDeliveryApplied = onHistoryDeliveryApplied,
                modifier = modifier,
            )
        }
    }

    // Read the state token after all effects above. It has no visual meaning;
    // it simply makes a delivered history effect recompose the visibility gate.
    @Suppress("UNUSED_VARIABLE")
    val keepObservedDelivery = observedDeliveryEpoch

    val router = MoshPaneHistoryScrollRouter(
        runtimes = runtimeStore,
        presentation = presentation,
        deliveries = { deliveries },
        paneExists = { paneId -> paneId in activePaneIds },
        isAlternateScreen = { paneId -> activeWindow?.panes?.firstOrNull { it.id == paneId }?.isAlternateScreen == true },
        readerPaneId = { scrollPaneId ?: focusedPaneId },
        onReaderPaneChanged = { scrollPaneId = it },
        beginHistoryScroll = { it.surface.view.beginHistoryScroll() },
        onHistoryRequested = onHistoryRequested,
        onReturnedToLiveTail = onReturnedToLiveTail,
        onAltScreenScroll = onAltScreenScroll,
    )
    LaunchedEffect(findPaneId, activeWindow?.id, activePaneIds) {
        findPaneId?.let { router.find(it, onFindRequested) }
    }
    MoshSplitScrollGestureObserver(
        primaryTerminal = primaryTerminal,
        windowId = activeWindow?.id,
        paneAtLocation = { x, y ->
            val metrics = primaryTerminal.gridMetrics()
            moshScrollPaneAtLocation(
                x, y, metrics.cellWidthPixels, metrics.cellHeightPixels,
                metrics.firstBaselineInsetPixels,
                primaryTerminal.view.scrollPositionPixels - primaryTerminal.view.topRow * metrics.cellHeightPixels,
                activeWindow?.layout, focusedPaneId, paneContentRects,
            )
        },
        onScroll = { paneId, rowsDown, pointsY, mayRequestHistory ->
            router.scroll(paneId, rowsDown, pointsY, mayRequestHistory)?.surface?.view
        },
    )
}

/** Split mosh owns scroll routing; touchscreen taps continue through the native view. */
@Composable
private fun MoshSplitScrollGestureObserver(
    primaryTerminal: TermuxTerminalSurface,
    windowId: Int?,
    paneAtLocation: (x: Float, y: Float) -> Int?,
    onScroll: (paneId: Int, rowsDown: Int, pointsY: Double, mayRequestHistory: Boolean) -> View?,
) {
    val currentPaneAtLocation by rememberUpdatedState(paneAtLocation)
    val currentOnScroll by rememberUpdatedState(onScroll)
    DisposableEffect(primaryTerminal, windowId) {
        fun requestObserver() = MoshSplitScrollRequestObserver(
            paneAtLocation = { x, y -> currentPaneAtLocation(x, y) },
            onScroll = { paneId, rows, points, mayRequest -> currentOnScroll(paneId, rows, points, mayRequest) },
        )
        val observer = requestObserver()
        val gesture = MoshSplitScrollTouchGesture()
        var remainder = 0f
        var historyView: View? = null
        var startEvent: MotionEvent? = null
        // A wheel routes on its own, so it never retargets a touch stream.
        val wheelObserver = requestObserver()
        var wheelView: View? = null
        val view = primaryTerminal.view
        val touchSlop = view.context.resources.displayMetrics.density * 8f
        fun begin(event: MotionEvent) {
            observer.begin(event.x, event.y)
            remainder = 0f
            historyView = null
            startEvent?.recycle()
            startEvent = MotionEvent.obtain(event).also { it.action = MotionEvent.ACTION_DOWN }
        }
        fun dispatchTrackedEvent(event: MotionEvent, action: Int = event.actionMasked) {
            val pointerId = gesture.trackedPointerId ?: return
            val destination = historyView ?: return
            val pointerIndex = event.findPointerIndex(pointerId)
            if (pointerIndex < 0) return
            val properties = MotionEvent.PointerProperties().also { event.getPointerProperties(pointerIndex, it) }
            val coords = MotionEvent.PointerCoords().also { event.getPointerCoords(pointerIndex, it) }
            val singlePointer = MotionEvent.obtain(
                event.downTime, event.eventTime, action, 1, arrayOf(properties), arrayOf(coords),
                event.metaState, event.buttonState, event.xPrecision, event.yPrecision,
                event.deviceId, event.edgeFlags, event.source, event.flags,
            )
            destination.dispatchTouchEvent(singlePointer)
            singlePointer.recycle()
        }
        fun cancelHistory() {
            startEvent?.let { dispatchTrackedEvent(it, MotionEvent.ACTION_CANCEL) }
        }
        fun clearStartEvent() {
            startEvent?.recycle()
            startEvent = null
        }
        view.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    cancelHistory()
                    // Latch at DOWN so later classification changes cannot split ownership.
                    gesture.begin(
                        event.getPointerId(0), event.y,
                        event.isFromSource(InputDevice.SOURCE_MOUSE), event.classification, Build.VERSION.SDK_INT,
                    )
                    begin(event)
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    gesture.pointerDown()
                    if (!gesture.scrolling) clearStartEvent()
                }
                MotionEvent.ACTION_MOVE -> {
                    val pointerId = gesture.trackedPointerId ?: return@setOnTouchListener gesture.consumesEvents
                    val pointerIndex = event.findPointerIndex(pointerId)
                    if (pointerIndex < 0) {
                        cancelHistory()
                        gesture.pointerUp(pointerId)
                        clearStartEvent()
                        return@setOnTouchListener gesture.consumesEvents
                    }
                    val cancelPrimary = !gesture.consumesEvents
                    val points = gesture.move(pointerId, event.getY(pointerIndex), touchSlop)
                        ?: return@setOnTouchListener gesture.consumesEvents
                    if (cancelPrimary) {
                        val cancel = MotionEvent.obtain(event)
                        cancel.action = MotionEvent.ACTION_CANCEL
                        view.onTouchEvent(cancel)
                        cancel.recycle()
                    }
                    // Synthesized touchpad fingers use the same downward-drag sign.
                    val rowHeight = primaryTerminal.gridMetrics().cellHeightPixels.coerceAtLeast(1)
                    remainder += points
                    val rows = (remainder / rowHeight).toInt()
                    remainder -= rows * rowHeight
                    if (historyView == null || !observer.offered) {
                        val destination = observer.scroll(rows, points.toDouble())
                        if (historyView == null && destination != null) {
                            historyView = destination
                            startEvent?.let { dispatchTrackedEvent(it, MotionEvent.ACTION_DOWN) }
                        }
                    }
                    dispatchTrackedEvent(event)
                }
                MotionEvent.ACTION_POINTER_UP -> {
                    val pointerId = event.getPointerId(event.actionIndex)
                    if (gesture.scrolling && pointerId == gesture.trackedPointerId) {
                        dispatchTrackedEvent(event, MotionEvent.ACTION_CANCEL)
                    }
                    if (gesture.pointerUp(pointerId)) clearStartEvent()
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    val consumed = gesture.consumesEvents
                    if (gesture.scrolling) {
                        if (event.findPointerIndex(requireNotNull(gesture.trackedPointerId)) >= 0) {
                            dispatchTrackedEvent(event)
                        } else cancelHistory()
                    }
                    clearStartEvent()
                    gesture.finish()
                    return@setOnTouchListener consumed
                }
            }
            gesture.consumesEvents
        }
        view.setOnGenericMotionListener { _, event ->
            if (event.actionMasked != MotionEvent.ACTION_SCROLL) return@setOnGenericMotionListener false
            if (wheelObserver.beginsWheelGesture(event.downTime, event.eventTime)) {
                wheelObserver.begin(event.x, event.y)
                wheelView = null
            }
            val points = -event.getAxisValue(MotionEvent.AXIS_VSCROLL).toDouble()
            val rows = if (points < 0) -3 else if (points > 0) 3 else 0
            if (wheelView == null || !wheelObserver.offered) {
                val destination = wheelObserver.scroll(rows, points)
                if (wheelView == null) wheelView = destination
            }
            wheelView?.dispatchGenericMotionEvent(event)
            true
        }
        onDispose {
            if (gesture.scrolling) cancelHistory()
            clearStartEvent()
            view.setOnTouchListener(null)
            view.setOnGenericMotionListener(null)
        }
    }
}

/** Non-consuming scroll-up observer shared by single-pane and split mosh. */
@Composable
internal fun MoshPrimaryHistoryGestureObserver(
    primaryTerminal: TermuxTerminalSurface,
    surfaceId: String?,
    enabled: Boolean,
    onScrollUp: (pointsY: Double, isInertial: Boolean) -> Unit,
) {
    DisposableEffect(primaryTerminal, surfaceId, enabled) {
        var initialY = 0f
        var requestedInGesture = false
        val touchSlop = primaryTerminal.view.context.resources.displayMetrics.density * 8f
        val listener = View.OnTouchListener listener@{ _, event ->
            if (!enabled || surfaceId == null) return@listener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    initialY = event.y
                    requestedInGesture = false
                }
                MotionEvent.ACTION_MOVE -> {
                    // A downward finger drag enters terminal history; its
                    // sign is retained for the ledger's presentation policy.
                    val pointsY = (initialY - event.y).toDouble()
                    if (!requestedInGesture && pointsY <= -touchSlop) {
                        requestedInGesture = true
                        onScrollUp(pointsY, false)
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> requestedInGesture = false
            }
            false
        }
        primaryTerminal.view.setOnTouchListener(listener)
        val wheelListener = View.OnGenericMotionListener { _, event ->
            if (enabled && surfaceId != null &&
                event.actionMasked == MotionEvent.ACTION_SCROLL &&
                event.getAxisValue(MotionEvent.AXIS_VSCROLL) > 0f
            ) {
                // Android reports a positive wheel axis for scroll-up, the
                // same direction that enters terminal history.
                onScrollUp(-event.getAxisValue(MotionEvent.AXIS_VSCROLL).toDouble(), false)
            }
            false
        }
        primaryTerminal.view.setOnGenericMotionListener(wheelListener)
        onDispose {
            primaryTerminal.view.setOnTouchListener(null)
            primaryTerminal.view.setOnGenericMotionListener(null)
        }
    }
}

/**
 * Gives the single-pane mosh primary surface the same first-scroll completion
 * as a detached overlay. Unlike the split path it remains the input surface,
 * so there is no tail-dismissal transition to perform here.
 */
@Composable
internal fun MoshPrimaryLiveHistoryController(
    primaryTerminal: TermuxTerminalSurface,
    delivery: TmuxRenderHistoryReady?,
    enabled: Boolean,
    onHistoryRequested: (surfaceId: String, pointsY: Double, isInertial: Boolean) -> Unit,
    onReturnedToLiveTail: (surfaceId: String) -> Unit,
    onHistoryDeliveryApplied: (surfaceId: String, deliveryToken: Long) -> Unit,
) {
    val presentation = remember(primaryTerminal) { MoshPrimaryLiveHistoryPresentation() }
    val currentEnabled by rememberUpdatedState(enabled)
    val currentDelivery by rememberUpdatedState(delivery)
    val currentOnHistoryDeliveryApplied by rememberUpdatedState(onHistoryDeliveryApplied)
    val currentOnHistoryRequested by rememberUpdatedState(onHistoryRequested)
    val presentationLease = remember(primaryTerminal) { MoshHistoryPresentationLease() }
    var lastHistoryDistanceFromBottom by remember(primaryTerminal) { mutableIntStateOf(0) }
    var lastObservedTopRow by remember(primaryTerminal) { mutableIntStateOf(0) }
    var appliedDeliveryToken by remember(primaryTerminal) { mutableStateOf(0L) }
    var scheduledDeliveryToken by remember(primaryTerminal) { mutableStateOf(0L) }
    DisposableEffect(primaryTerminal) {
        presentationLease.active = true
        onDispose { presentationLease.active = false }
    }
    DisposableEffect(primaryTerminal, enabled) {
        val observer = ViewTreeObserver.OnDrawListener observer@{
            if (!enabled || primaryTerminal.view.isHistoryScrollPending) return@observer
            val topRow = primaryTerminal.snapshotNonSecretState().topRow
            if (topRow == lastObservedTopRow) return@observer
            lastObservedTopRow = topRow
            if (topRow < 0) lastHistoryDistanceFromBottom = -topRow
            val availableRows = primaryTerminal.view.mEmulator?.screen?.activeTranscriptRows ?: 0
            if (presentation.observeNativeTopRow(topRow, availableRows)) {
                onReturnedToLiveTail("live")
            } else {
                if (presentation.shouldRequestDeeperHistory(topRow, availableRows)) {
                    primaryTerminal.view.beginHistoryScroll()
                    currentOnHistoryRequested("live", -1.0, false)
                }
            }
        }
        primaryTerminal.view.viewTreeObserver.addOnDrawListener(observer)
        onDispose {
            primaryTerminal.view.viewTreeObserver.takeIf { it.isAlive }?.removeOnDrawListener(observer)
        }
    }
    LaunchedEffect(primaryTerminal, enabled, delivery?.deliveryToken) {
        val ready = delivery
        if (!enabled || ready == null) {
            // Typing, window changes, and authoritative repaints retire the
            // delivery. Its old reveal latch must not suppress future requests.
            presentation.reset()
            lastHistoryDistanceFromBottom = 0
            lastObservedTopRow = 0
            // Controller invalidation cancels native motion synchronously. A
            // matching capture bind also retires the old delivery, but keeps
            // its pending gesture until the replacement is presented.
            if (!enabled) primaryTerminal.view.cancelHistoryScroll()
            return@LaunchedEffect
        }
        if (ready.surfaceId != "live" || ready.deliveryToken <= appliedDeliveryToken) {
            return@LaunchedEffect
        }
        if (!presentation.accept(ready.deliveryToken)) return@LaunchedEffect
        scheduledDeliveryToken = ready.deliveryToken
        val targetTopRow = moshHistoryTopRowForPlacement(
            placement = ready.placement,
            priorDistanceFromBottom = lastHistoryDistanceFromBottom,
            availableHistoryRows = ready.historySize,
        )
        while (presentationLease.active && currentEnabled &&
            currentDelivery?.deliveryToken == ready.deliveryToken &&
            ready.deliveryToken == scheduledDeliveryToken &&
            ready.deliveryToken > appliedDeliveryToken
        ) {
            if (primaryTerminal.view.isAttachedToWindow && primaryTerminal.view.isShown) {
                val availableRows = primaryTerminal.view.mEmulator?.screen?.activeTranscriptRows ?: 0
                val topRow = targetTopRow.coerceIn(-availableRows, 0)
                primaryTerminal.view.completeHistoryScroll(topRow)
                val placedTopRow = primaryTerminal.view.topRow
                lastObservedTopRow = placedTopRow
                if (placedTopRow < 0) lastHistoryDistanceFromBottom = -placedTopRow
                // This is a placement completion, not native underflow. Record it
                // for tail gating but do not request a deeper replacement solely
                // because a one-row capture is already at its oldest row.
                presentation.observeNativeTopRow(placedTopRow, availableRows)
                appliedDeliveryToken = ready.deliveryToken
                currentOnHistoryDeliveryApplied("live", ready.deliveryToken)
                if (placedTopRow == 0) onReturnedToLiveTail("live")
                return@LaunchedEffect
            }
            delay(16)
        }
    }
    DisposableEffect(primaryTerminal, enabled) {
        primaryTerminal.view.setHistoryScrollRequest(if (!enabled) null else Runnable {
            val view = primaryTerminal.view
            if (currentDelivery == null) presentation.reset()
            val availableRows = view.mEmulator?.screen?.activeTranscriptRows ?: 0
            if (!presentation.hasActiveHistory() ||
                presentation.shouldRequestDeeperHistory(view.topRow, availableRows)
            ) {
                view.beginHistoryScroll()
                currentOnHistoryRequested("live", -1.0, false)
            }
        })
        onDispose { primaryTerminal.view.setHistoryScrollRequest(null) }
    }
}
