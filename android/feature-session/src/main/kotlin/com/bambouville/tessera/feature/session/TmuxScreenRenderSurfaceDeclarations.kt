package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxSurfaceDeclaration
import com.bambouville.tessera.core.bridge.SharedTmuxSurfacePresentation

/**
 * Presentation topology as mounted by [SshSessionScreen], rather than inferred
 * from the controller's physical terminal-surface registry.
 */
internal enum class TmuxScreenRenderPresentation {
    None,
    Single,
    Grid,
}

internal const val TMUX_RENDER_LIVE_SURFACE_ID = "live"
internal const val TMUX_RENDER_PANE_SURFACE_PREFIX = "pane:"
internal const val TMUX_RENDER_OVERLAY_SURFACE_PREFIX = "overlay:"

/**
 * Builds the sole render-surface declaration for the currently mounted tmux
 * presentation.  Surface IDs are deliberately sorted to make equal screen
 * states submit equal ledger facts regardless of Compose mount order.
 *
 * Declarations stay *pinned* to the identity they were built from.  The pin
 * is not decoration: [validatedInlineAuthorityRepaintTargets] compares
 * `windowId`/`paneId` on every non-overlay declaration against the snapshot
 * before it will fence an inline authority repaint, and an unpinned live
 * surface makes that comparison fail forever — the claim never settles, no
 * surface is ever mounted, and the session hangs on "attaching pane".
 *
 * What must *not* happen is withholding the declaration.  tmux names a
 * created window (`%session-window-changed` + `%window-add`) before it
 * describes it, so for one beat the active window is the new one and its
 * active pane is still unknown.  Dropping the live surface for that beat
 * removes it from the ledger, and the re-declaration that follows arrives as
 * a fresh mount that nothing refreshes — the terminal keeps painting the
 * window the user just left, and the switcher cannot rescue it because tmux
 * has already made the new window current, so `select-window` on it notifies
 * nobody.  So the live surface is declared across the beat carrying the new
 * window and a null pane; `TmuxRuntimeHydrationQuery.windowDetailsCommand`
 * supplies the pane a moment later and the re-pin is what the ledger sees as
 * the identity move.
 *
 * Grid and overlay surfaces are per-pane, so they genuinely have nothing to
 * declare until the pane set is known.
 */
internal fun tmuxScreenRenderSurfaceDeclarations(
    presentation: TmuxScreenRenderPresentation,
    activeWindowId: Int?,
    activePaneId: Int?,
    activePaneIds: Set<Int>,
    mountedGridPaneIds: Set<Int>,
    mountedOverlayPaneIds: Set<Int>,
): List<SharedTmuxSurfaceDeclaration> {
    val windowId = activeWindowId ?: return emptyList()

    val declarations = when (presentation) {
        TmuxScreenRenderPresentation.None -> emptyList()
        TmuxScreenRenderPresentation.Single -> buildList {
            add(
                SharedTmuxSurfaceDeclaration(
                    surfaceId = TMUX_RENDER_LIVE_SURFACE_ID,
                    presentation = SharedTmuxSurfacePresentation.Single,
                    windowId = windowId,
                    paneId = activePaneId,
                ),
            )
            if (activePaneId == null) return@buildList
            mountedOverlayPaneIds
                .asSequence()
                .filter { it in activePaneIds }
                .forEach { paneId ->
                    add(
                        SharedTmuxSurfaceDeclaration(
                            surfaceId = "$TMUX_RENDER_OVERLAY_SURFACE_PREFIX$paneId",
                            presentation = SharedTmuxSurfacePresentation.Overlay,
                            windowId = windowId,
                            paneId = paneId,
                        ),
                    )
                }
        }
        TmuxScreenRenderPresentation.Grid -> if (activePaneId == null) {
            emptyList()
        } else {
            mountedGridPaneIds
                .asSequence()
                .filter { it in activePaneIds }
                .map { paneId ->
                    SharedTmuxSurfaceDeclaration(
                        surfaceId = "$TMUX_RENDER_PANE_SURFACE_PREFIX$paneId",
                        presentation = SharedTmuxSurfacePresentation.Grid,
                        windowId = windowId,
                        paneId = paneId,
                    )
                }
                .toList()
        }
    }

    return declarations.sortedBy(SharedTmuxSurfaceDeclaration::surfaceId)
}
