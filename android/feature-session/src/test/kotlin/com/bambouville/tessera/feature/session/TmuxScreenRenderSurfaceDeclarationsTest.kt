package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxSurfaceDeclaration
import com.bambouville.tessera.core.bridge.SharedTmuxSurfacePresentation
import org.junit.Assert.assertEquals
import org.junit.Test

class TmuxScreenRenderSurfaceDeclarationsTest {
    @Test
    fun singlePresentationDeclaresLiveAndOnlyActiveWindowOverlays() {
        assertEquals(
            listOf(
                declaration("live", SharedTmuxSurfacePresentation.Single, window = 7, pane = 71),
                declaration("overlay:71", SharedTmuxSurfacePresentation.Overlay, window = 7, pane = 71),
                declaration("overlay:72", SharedTmuxSurfacePresentation.Overlay, window = 7, pane = 72),
            ),
            tmuxScreenRenderSurfaceDeclarations(
                presentation = TmuxScreenRenderPresentation.Single,
                activeWindowId = 7,
                activePaneId = 71,
                activePaneIds = setOf(71, 72),
                mountedGridPaneIds = setOf(71, 72),
                mountedOverlayPaneIds = linkedSetOf(91, 72, 71),
            ),
        )
    }

    @Test
    fun gridPresentationDeclaresOnlyMountedActiveWindowPanes() {
        assertEquals(
            listOf(
                declaration("pane:71", SharedTmuxSurfacePresentation.Grid, window = 7, pane = 71),
                declaration("pane:72", SharedTmuxSurfacePresentation.Grid, window = 7, pane = 72),
            ),
            tmuxScreenRenderSurfaceDeclarations(
                presentation = TmuxScreenRenderPresentation.Grid,
                activeWindowId = 7,
                activePaneId = 71,
                activePaneIds = setOf(71, 72),
                mountedGridPaneIds = linkedSetOf(99, 72, 71),
                mountedOverlayPaneIds = setOf(71, 72),
            ),
        )
    }

    /**
     * tmux names a created window before it describes it, so the active pane
     * is genuinely unknown for a beat. The live surface must stay declared
     * across that beat — withdrawing it removes it from the ledger and the
     * re-declaration reads as a fresh mount nothing refreshes — carrying the
     * new window and the pane it does not know yet.
     */
    @Test
    fun singlePresentationKeepsTheLiveSurfaceWhileTheActivePaneIsUnknown() {
        assertEquals(
            listOf(
                SharedTmuxSurfaceDeclaration(
                    surfaceId = "live",
                    presentation = SharedTmuxSurfacePresentation.Single,
                    windowId = 7,
                    paneId = null,
                ),
            ),
            tmuxScreenRenderSurfaceDeclarations(
                presentation = TmuxScreenRenderPresentation.Single,
                activeWindowId = 7,
                activePaneId = null,
                activePaneIds = emptySet(),
                mountedGridPaneIds = emptySet(),
                mountedOverlayPaneIds = setOf(71),
            ),
        )
    }

    /**
     * The seam that a live session hangs on: whatever this builder declares,
     * [validatedInlineAuthorityRepaintTargets] must be willing to fence, or
     * the initial authority claim never settles, no surface is ever mounted
     * and the screen sits on "attaching pane" forever. The two functions
     * compare `windowId`/`paneId` field by field, so they have to agree about
     * pinning — asserting each one alone cannot catch a disagreement.
     */
    @Test
    fun declaredSurfacesAreAcceptedByTheInlineAuthorityRepaintFence() {
        for (presentation in listOf(
            TmuxScreenRenderPresentation.Single,
            TmuxScreenRenderPresentation.Grid,
        )) {
            val declarations = tmuxScreenRenderSurfaceDeclarations(
                presentation = presentation,
                activeWindowId = 7,
                activePaneId = 71,
                activePaneIds = setOf(71, 72),
                mountedGridPaneIds = setOf(71, 72),
                mountedOverlayPaneIds = setOf(71, 72),
            )
            val targets = validatedInlineAuthorityRepaintTargets(
                declarations = declarations,
                presentation = presentation,
                activeWindowId = 7,
                activePaneId = 71,
                activePaneIds = setOf(71, 72),
                mountedSurfaceIds = declarations.mapTo(mutableSetOf()) { it.surfaceId },
            )
            assertEquals(
                "$presentation declarations must be fenceable",
                declarations.count { it.presentation != SharedTmuxSurfacePresentation.Overlay },
                targets.size,
            )
        }
    }

    @Test
    fun noneOrIncompleteActiveIdentityClearsAllDeclarations() {
        assertEquals(
            emptyList<SharedTmuxSurfaceDeclaration>(),
            tmuxScreenRenderSurfaceDeclarations(
                presentation = TmuxScreenRenderPresentation.None,
                activeWindowId = 7,
                activePaneId = 71,
                activePaneIds = setOf(71),
                mountedGridPaneIds = setOf(71),
                mountedOverlayPaneIds = setOf(71),
            ),
        )
        assertEquals(
            emptyList<SharedTmuxSurfaceDeclaration>(),
            tmuxScreenRenderSurfaceDeclarations(
                presentation = TmuxScreenRenderPresentation.Single,
                activeWindowId = null,
                activePaneId = 71,
                activePaneIds = setOf(71),
                mountedGridPaneIds = emptySet(),
                mountedOverlayPaneIds = setOf(71),
            ),
        )
        assertEquals(
            emptyList<SharedTmuxSurfaceDeclaration>(),
            tmuxScreenRenderSurfaceDeclarations(
                presentation = TmuxScreenRenderPresentation.Grid,
                activeWindowId = 7,
                activePaneId = null,
                activePaneIds = setOf(71),
                mountedGridPaneIds = setOf(71),
                mountedOverlayPaneIds = emptySet(),
            ),
        )
    }

    private fun declaration(
        surfaceId: String,
        presentation: SharedTmuxSurfacePresentation,
        window: Int,
        pane: Int,
    ) = SharedTmuxSurfaceDeclaration(
        surfaceId = surfaceId,
        presentation = presentation,
        windowId = window,
        paneId = pane,
    )
}
