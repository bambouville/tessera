package com.bambouville.tessera.core.bridge

/** What a compact client does with a layout update: the shared core's `TmuxCompactReprojection`. */
enum class SharedTmuxCompactReprojection {
    /** Keep the advertisement: it already fits, or the window is a peer's grid. */
    HOLD,

    /** Advertise the new projection. */
    REPROJECT,

    /**
     * The window is this device's canvas, but tmux kept landing the focused
     * pane off the projection and the core stopped the resize cycle. Hold the
     * size this device last advertised; do not repair toward the projection
     * by another route either.
     */
    HOLD_CYCLE,
}

/**
 * The shared core's reprojection memo for one tmux client: two opaque words,
 * handed back unchanged on the next call. [FRESH] for a client that has not
 * judged a layout yet.
 */
data class SharedTmuxCompactReprojectionMemo(val first: Long, val second: Long) {
    companion object {
        val FRESH = SharedTmuxCompactReprojectionMemo(0L, 0L)
    }
}

data class SharedTmuxCompactReprojectionResult(
    val decision: SharedTmuxCompactReprojection,
    /** Hand it back on the next call for the same tmux client. */
    val memo: SharedTmuxCompactReprojectionMemo,
    /**
     * This call stopped the resize cycle: [decision] is
     * [SharedTmuxCompactReprojection.HOLD_CYCLE] and the core was not
     * holding one before. A caller reports each stop once.
     */
    val stoppedCycle: Boolean = false,
)

/**
 * This tree in tmux's own cell grammar without the checksum
 * (`WxH,X,Y{…}` side by side, `[…]` stacked, `,id` for a pane), which is how
 * the shared core takes a layout it should solve against. The core's parser
 * owns the length limit: a layout past it is sized by ratio like any other
 * layout the parser refuses.
 */
internal fun SharedTmuxLayoutNode.tmuxLayoutCellBytes(): ByteArray =
    StringBuilder().also { it.appendTmuxLayoutCells(this) }
        .toString()
        .encodeToByteArray()

private fun StringBuilder.appendTmuxLayoutCells(node: SharedTmuxLayoutNode) {
    append(node.width).append('x').append(node.height)
    append(',').append(node.x).append(',').append(node.y)
    when (node) {
        is SharedTmuxLayoutNode.Leaf -> append(',').append(node.paneId)
        is SharedTmuxLayoutNode.Split -> {
            append(if (node.horizontal) '{' else '[')
            node.children.forEachIndexed { index, child ->
                if (index > 0) append(',')
                appendTmuxLayoutCells(child)
            }
            append(if (node.horizontal) '}' else ']')
        }
    }
}

/**
 * One tmux client's compact sizing: [SharedTmuxGeometry]'s layout-solved
 * projection and reprojection decision, plus the opaque memo the decision
 * threads from one layout update to the next.
 *
 * The session controller reconciles its client size on every runtime event,
 * `%output` included, and an advertisement it withholds (background, a
 * hidden tab, a peer's grid, an authority read in flight) or that waits for
 * a Mosh ownership proof leaves every input as it was. So both answers are
 * kept until an input changes, the memo deliberately not among them: the
 * core judges each layout once, as iOS does from its layout observer, and an
 * event that carries the same layout object costs a few comparisons, never a
 * re-encoded tree or a native call. A judgement that has to start over (a
 * forced replay, a new client) is a [reset].
 *
 * Synchronized: the controller sizes from its transport callbacks and from
 * UI-driven geometry changes alike, and [judge] answers the size and the
 * decision for one set of inputs together.
 *
 * The no-argument sizer asks the shared core. Another [Core] scripts the
 * answers, so a caller's handling of each decision is testable on the JVM,
 * where the native core does not load.
 */
class SharedTmuxCompactSizer(private val core: Core) {
    constructor() : this(SharedCore)

    interface Core {
        fun clientSize(
            viewport: SharedTmuxGridSize,
            layoutCells: ByteArray?,
            focusPaneId: Int?,
            window: SharedTmuxGridSize?,
            focus: SharedTmuxGridSize?,
        ): SharedTmuxGridSize

        fun reprojection(
            viewport: SharedTmuxGridSize,
            lastClientSize: SharedTmuxGridSize?,
            layoutCells: ByteArray?,
            focusPaneId: Int?,
            window: SharedTmuxGridSize?,
            focus: SharedTmuxGridSize?,
            memo: SharedTmuxCompactReprojectionMemo,
        ): SharedTmuxCompactReprojectionResult
    }

    private object SharedCore : Core {
        override fun clientSize(
            viewport: SharedTmuxGridSize,
            layoutCells: ByteArray?,
            focusPaneId: Int?,
            window: SharedTmuxGridSize?,
            focus: SharedTmuxGridSize?,
        ) = SharedTmuxGeometry.compactClientSizeForCells(viewport, layoutCells, focusPaneId, window, focus)

        override fun reprojection(
            viewport: SharedTmuxGridSize,
            lastClientSize: SharedTmuxGridSize?,
            layoutCells: ByteArray?,
            focusPaneId: Int?,
            window: SharedTmuxGridSize?,
            focus: SharedTmuxGridSize?,
            memo: SharedTmuxCompactReprojectionMemo,
        ) = SharedTmuxGeometry.compactReprojectionForCells(
            viewport, lastClientSize, layoutCells, focusPaneId, window, focus, memo,
        )
    }

    /** What [judge] decided: the projection and what to do with it. */
    data class Judgement(
        /** The client size that gives the focused pane the viewport. */
        val clientSize: SharedTmuxGridSize,
        val decision: SharedTmuxCompactReprojection,
        /** True only from the judgement that stopped a resize cycle. */
        val stoppedCycle: Boolean,
    )

    /** The reprojection memo; [SharedTmuxCompactReprojectionMemo.FRESH] for a client that has not judged a layout yet. */
    @get:Synchronized
    var memo: SharedTmuxCompactReprojectionMemo = SharedTmuxCompactReprojectionMemo.FRESH
        private set

    private var encodedLayout: SharedTmuxLayoutNode? = null
    private var encodedCells: ByteArray? = null

    private var sized = false
    private var sizeViewport: SharedTmuxGridSize? = null
    private var sizeLayout: SharedTmuxLayoutNode? = null
    private var sizeFocusPaneId: Int? = null
    private var sizeWindow: SharedTmuxGridSize? = null
    private var sizeFocus: SharedTmuxGridSize? = null
    private var sizeResult: SharedTmuxGridSize? = null

    private var judged = false
    private var judgedViewport: SharedTmuxGridSize? = null
    private var judgedLast: SharedTmuxGridSize? = null
    private var judgedLayout: SharedTmuxLayoutNode? = null
    private var judgedFocusPaneId: Int? = null
    private var judgedWindow: SharedTmuxGridSize? = null
    private var judgedFocus: SharedTmuxGridSize? = null
    private var judgedDecision = SharedTmuxCompactReprojection.HOLD

    /** The client size that gives the focused pane [viewport]. */
    @Synchronized
    fun clientSize(
        viewport: SharedTmuxGridSize,
        layout: SharedTmuxLayoutNode?,
        focusPaneId: Int?,
        window: SharedTmuxGridSize?,
        focus: SharedTmuxGridSize?,
    ): SharedTmuxGridSize {
        val cached = sizeResult
        if (sized && cached != null && sizeViewport == viewport && sameLayout(sizeLayout, layout) &&
            sizeFocusPaneId == focusPaneId && sizeWindow == window && sizeFocus == focus
        ) return cached
        val result = core.clientSize(viewport, cells(layout), focusPaneId, window, focus)
        sized = true
        sizeViewport = viewport
        sizeLayout = layout
        sizeFocusPaneId = focusPaneId
        sizeWindow = window
        sizeFocus = focus
        sizeResult = result
        return result
    }

    /**
     * What this layout update does to the advertisement, with the projection
     * it is about, judged under one lock. [lastClientSize] is the size this
     * client last advertised to tmux, never one it withheld: the core counts
     * a correction only when tmux resizes the window after that changed.
     * Judging the same inputs again returns the same decision without asking
     * the core, and leaves [memo] alone.
     */
    @Synchronized
    fun judge(
        viewport: SharedTmuxGridSize,
        lastClientSize: SharedTmuxGridSize?,
        layout: SharedTmuxLayoutNode?,
        focusPaneId: Int?,
        window: SharedTmuxGridSize?,
        focus: SharedTmuxGridSize?,
    ): Judgement {
        val size = clientSize(viewport, layout, focusPaneId, window, focus)
        if (judged && judgedViewport == viewport && judgedLast == lastClientSize && sameLayout(judgedLayout, layout) &&
            judgedFocusPaneId == focusPaneId && judgedWindow == window && judgedFocus == focus
        ) return Judgement(size, judgedDecision, stoppedCycle = false)
        val result = core.reprojection(viewport, lastClientSize, cells(layout), focusPaneId, window, focus, memo)
        judged = true
        judgedViewport = viewport
        judgedLast = lastClientSize
        judgedLayout = layout
        judgedFocusPaneId = focusPaneId
        judgedWindow = window
        judgedFocus = focus
        judgedDecision = result.decision
        memo = result.memo
        return Judgement(size, result.decision, result.stoppedCycle)
    }

    /**
     * A fresh start for this client's corrections, as iOS makes on every
     * forced replay: a new tmux client, the app returning to the foreground,
     * a show, a take-back or a presentation change. The next [judge] asks the
     * core again even with unchanged inputs.
     */
    @Synchronized
    fun reset() {
        memo = SharedTmuxCompactReprojectionMemo.FRESH
        judged = false
    }

    private fun cells(layout: SharedTmuxLayoutNode?): ByteArray? {
        if (layout == null) return null
        if (sameLayout(encodedLayout, layout)) return encodedCells
        val cells = layout.tmuxLayoutCellBytes()
        encodedLayout = layout
        encodedCells = cells
        return cells
    }

    /** Identity first: an event that did not change the snapshot reuses its tree. */
    private fun sameLayout(a: SharedTmuxLayoutNode?, b: SharedTmuxLayoutNode?): Boolean = a === b || a == b
}
