package com.bambouville.tessera.terminal

import android.annotation.SuppressLint
import android.content.Context
import android.view.View
import android.view.ViewGroup
import com.bambouville.tessera.core.bridge.SharedTmuxCanvas
import com.bambouville.tessera.core.bridge.SharedTmuxCanvasProjection
import com.bambouville.tessera.core.bridge.SharedTmuxCellRect
import com.termux.view.TerminalView

/**
 * Fits one authoritative tmux window into a compact physical viewport without
 * changing its local terminal grid.
 *
 * tmux continues to render at the server-reported columns and rows; this
 * container measures [TerminalView] at exactly that grid, then applies the
 * presentation-only transform the shared core computes — the same one iOS'
 * GeometryNeutralTmuxCanvasModifier applies. Split topology and server geometry
 * remain owned by tmux/shared core rather than by the phone's View bounds.
 *
 * The window and focus rects differ only where a transport paints the whole
 * window itself: mosh streams every pane, so the content must be laid out at
 * the window grid and *panned* until the focused pane is on screen. Transports
 * that feed this surface focused-pane capture only pass the same rect twice,
 * which degenerates to centring the pane, unchanged.
 */
@SuppressLint("ViewConstructor")
class GeometryNeutralTerminalViewport(
    context: Context,
    private val surface: TermuxTerminalSurface,
) : ViewGroup(context) {
    private val terminal: TerminalView = surface.view
    private var windowRect: SharedTmuxCellRect? = null
    private var focusRect: SharedTmuxCellRect? = null
    private var projection: SharedTmuxCanvasProjection? = null
    private var baselineInsetPixels = 0
    private var measuredViewportColumns = 0
    private var measuredViewportRows = 0
    private var deliveredViewportColumns = 0
    private var deliveredViewportRows = 0
    private val publishViewportGrid = Runnable {
        val receiver = onViewportGridChanged
        val columns = measuredViewportColumns
        val rows = measuredViewportRows
        if (isAttachedToWindow && receiver != null && columns > 0 && rows > 0 &&
            (columns != deliveredViewportColumns || rows != deliveredViewportRows)
        ) {
            receiver(columns, rows)
            // A receiver can be replaced synchronously by the callback itself.
            // Its replacement still needs the current physical viewport.
            if (onViewportGridChanged === receiver) {
                deliveredViewportColumns = columns
                deliveredViewportRows = rows
            }
        }
    }
    private val backgroundChanged: () -> Unit = {
        background = surface.backgroundDrawable()
        invalidate()
    }

    var onViewportGridChanged: ((columns: Int, rows: Int) -> Unit)? = null
        set(value) {
            if (field === value) return
            field = value
            deliveredViewportColumns = 0
            deliveredViewportRows = 0
            queueViewportPublication()
        }

    private fun queueViewportPublication() {
        removeCallbacks(publishViewportGrid)
        if (isAttachedToWindow && onViewportGridChanged != null &&
            measuredViewportColumns > 0 && measuredViewportRows > 0 &&
            (measuredViewportColumns != deliveredViewportColumns || measuredViewportRows != deliveredViewportRows)
        ) {
            post(publishViewportGrid)
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        deliveredViewportColumns = 0
        deliveredViewportRows = 0
        queueViewportPublication()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(publishViewportGrid)
        super.onDetachedFromWindow()
    }

    init {
        background = surface.backgroundDrawable()
        clipChildren = true
        clipToPadding = true
        // Compose builds a replacement AndroidView node *before* it releases the
        // node being replaced, so on any branch swap that remounts the terminal
        // — connected -> terminated is the one users hit — the shared terminal
        // view is still parented by the outgoing viewport right here. Adopting
        // it is the correct resolution: the outgoing holder is on its way out,
        // and `releaseTerminal` only detaches a child it still owns, so it
        // cannot steal the view back. Requiring a free parent instead turned an
        // ordinary swap into a fatal `IllegalStateException: The specified child
        // already has a parent` from ViewGroup.addView.
        (terminal.parent as? ViewGroup)?.removeView(terminal)
        addView(terminal)
        surface.addBackgroundChangedListener(backgroundChanged)
    }

    /**
     * @param window the whole tmux window's cell rect, which the terminal is
     *   laid out at.
     * @param focus the rect inside [window] that must fill the viewport. Pass
     *   the same rect as [window] when this surface only ever renders one pane.
     */
    fun setWindowGrid(window: SharedTmuxCellRect?, focus: SharedTmuxCellRect?) {
        // The scaled margins are part of this terminal surface, not app chrome.
        background = surface.backgroundDrawable()
        // Both or neither: a focus too small to frame must fall back to the
        // natural-size render, never to scaling the whole window into the
        // viewport — that is the illegible peer-sized canvas this projection
        // exists to prevent, just self-inflicted.
        val usable = window?.takeIf { it.columns >= 4 && it.rows >= 4 } != null &&
            (focus ?: window)?.takeIf { it.columns >= 4 && it.rows >= 4 } != null
        val validWindow = window.takeIf { usable }
        val validFocus = focus.takeIf { usable }
        if (windowRect == validWindow && focusRect == validFocus) return
        windowRect = validWindow
        focusRect = validFocus
        requestLayout()
    }

    fun releaseTerminal() {
        onViewportGridChanged = null
        surface.removeBackgroundChangedListener(backgroundChanged)
        if (terminal.parent === this) removeView(terminal)
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val viewportWidth = MeasureSpec.getSize(widthMeasureSpec).coerceAtLeast(1)
        val viewportHeight = MeasureSpec.getSize(heightMeasureSpec).coerceAtLeast(1)
        setMeasuredDimension(
            resolveSize(viewportWidth, widthMeasureSpec),
            resolveSize(viewportHeight, heightMeasureSpec),
        )

        val metrics = surface.gridMetrics()
        val window = windowRect
        val focus = focusRect ?: window
        val canvas = if (window != null && focus != null) {
            SharedTmuxCanvas.projection(
                window = window,
                focus = focus,
                cellWidth = metrics.cellWidthPixels.toDouble(),
                cellHeight = metrics.cellHeightPixels.toDouble(),
                viewportWidth = measuredWidth.toDouble(),
                viewportHeight = measuredHeight.toDouble(),
            )
        } else {
            null
        }
        projection = canvas
        // TerminalView reserves a first-baseline inset above row 0, so the view
        // is that much taller than the projection's pure cell grid and its
        // content starts that much lower.
        baselineInsetPixels = metrics.firstBaselineInsetPixels
        val terminalWidth = if (canvas != null && window != null) {
            metrics.pixelWidth(window.columns)
        } else {
            measuredWidth
        }
        val terminalHeight = if (canvas != null && window != null) {
            metrics.pixelHeight(window.rows)
        } else {
            measuredHeight
        }
        terminal.measure(
            MeasureSpec.makeMeasureSpec(terminalWidth.coerceAtLeast(1), MeasureSpec.EXACTLY),
            MeasureSpec.makeMeasureSpec(terminalHeight.coerceAtLeast(1), MeasureSpec.EXACTLY),
        )

        measuredViewportColumns = metrics.columnsFor(measuredWidth)
        measuredViewportRows = metrics.rowsFor(measuredHeight)
        queueViewportPublication()
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        terminal.layout(0, 0, terminal.measuredWidth, terminal.measuredHeight)
        terminal.pivotX = 0f
        terminal.pivotY = 0f

        val canvas = projection
        val scale = canvas?.scale?.toFloat() ?: 1f
        terminal.scaleX = scale
        terminal.scaleY = scale
        terminal.translationX = canvas?.offsetX?.toFloat() ?: 0f
        terminal.translationY = canvas
            ?.let { (it.offsetY - baselineInsetPixels * it.scale).toFloat() }
            ?: 0f
    }

    override fun shouldDelayChildPressedState(): Boolean = false

    override fun onViewRemoved(child: View) {
        child.scaleX = 1f
        child.scaleY = 1f
        child.translationX = 0f
        child.translationY = 0f
        super.onViewRemoved(child)
    }
}
