package com.bambouville.tessera.feature.session

import android.content.Context
import android.view.View
import android.widget.FrameLayout
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.bambouville.tessera.terminal.GeometryNeutralTerminalViewport
import com.bambouville.tessera.terminal.TermuxTerminalSurface

/**
 * Whether a session's terminals may draw (§6.4 P9): only the session on
 * screen — MainActivity keeps every live session composed, the others at
 * alpha 0 — and never under its shown take-back veil, which covers the
 * terminal with a 0.88 scrim over a blur.
 */
internal fun terminalDrawingEnabled(presented: Boolean, veilShown: Boolean): Boolean =
    presented && !veilShown

/**
 * The take-back veil is on screen: a peer holds the grid (or a take-back is
 * running), nothing else covers the session, and the session is connected
 * or its take-back is only waiting for the connection. One rule for both the
 * veil itself and the drawing it pauses, so they can never disagree.
 */
internal fun tmuxAuthorityVeilShown(
    presentation: TmuxAuthorityPresentation,
    launchOverlayShown: Boolean,
    connected: Boolean,
): Boolean {
    val veiled = presentation is TmuxAuthorityPresentation.Veiled ||
        presentation is TmuxAuthorityPresentation.Reclaiming
    val awaitingConnection = (presentation as? TmuxAuthorityPresentation.Reclaiming)?.awaitingConnection == true
    return veiled && !launchOverlayShown && (connected || awaitingConnection)
}

/**
 * Holds a terminal's invalidations while [drawingEnabled] is false.
 *
 * Termux redraws its whole display list on every output burst and cursor
 * blink, and each one also scheduled a frame for the window and, through
 * Compose's view holder, re-recorded the session's layer and re-ran the
 * veil's blur. Swallowing the invalidation here stops all of that while the
 * terminal cannot be seen: the emulator still consumes every byte, the last
 * frame stays in place (the veil's faint ghost of the terminal does not
 * blank), and the first frame after the gate opens paints the current
 * screen. Visibility is left alone on purpose: `INVISIBLE` would drop that
 * ghost, take focus from the view and fail the `isShown` checks the history
 * overlays wait on.
 */
internal class TerminalDrawingGate(context: Context) : FrameLayout(context) {
    private var invalidatedWhileHeld = false

    var drawingEnabled: Boolean = true
        set(value) {
            if (field == value) return
            field = value
            if (value && invalidatedWhileHeld) {
                invalidatedWhileHeld = false
                // The descendants are already marked dirty; re-recording this
                // layer re-records exactly those of them.
                invalidate()
            }
        }

    /** True while a held invalidation is waiting for the gate to open. */
    val holdsInvalidation: Boolean get() = invalidatedWhileHeld

    val viewport: GeometryNeutralTerminalViewport
        get() = getChildAt(0) as GeometryNeutralTerminalViewport

    // A hardware-accelerated window routes every descendant invalidation,
    // and every RenderNode property damage, through here (API 26+).
    override fun onDescendantInvalidated(child: View, target: View) {
        if (drawingEnabled) {
            super.onDescendantInvalidated(child, target)
        } else {
            invalidatedWhileHeld = true
        }
    }
}

/**
 * A [GeometryNeutralTerminalViewport] for [terminal] behind a
 * [TerminalDrawingGate] open while [drawingEnabled] (see
 * [terminalDrawingEnabled]). [onCreated] and [update] see the viewport
 * exactly as a bare `AndroidView` of it did.
 */
@Composable
internal fun TerminalViewport(
    terminal: TermuxTerminalSurface,
    drawingEnabled: Boolean,
    modifier: Modifier = Modifier,
    onCreated: GeometryNeutralTerminalViewport.() -> Unit = {},
    update: (GeometryNeutralTerminalViewport) -> Unit = {},
) {
    AndroidView(
        factory = { context ->
            TerminalDrawingGate(context).apply {
                addView(GeometryNeutralTerminalViewport(context, terminal).apply(onCreated))
            }
        },
        update = { gate ->
            gate.drawingEnabled = drawingEnabled
            update(gate.viewport)
        },
        onRelease = { gate -> gate.viewport.releaseTerminal() },
        modifier = modifier,
    )
}
