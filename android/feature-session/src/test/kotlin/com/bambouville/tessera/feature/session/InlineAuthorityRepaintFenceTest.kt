package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxRenderFeedSource
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.core.bridge.SharedTmuxRenderStage
import com.bambouville.tessera.core.bridge.SharedTmuxSurfaceDeclaration
import com.bambouville.tessera.core.bridge.SharedTmuxSurfacePresentation
import com.bambouville.tessera.terminal.RenderOwner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InlineAuthorityRepaintFenceTest {
    private val paneOne = InlineAuthorityRepaintTarget("pane:1", 7, 1)
    private val paneTwo = InlineAuthorityRepaintTarget("pane:2", 7, 2)

    @Test
    fun targetResolutionRequiresExactCurrentSingleOrCompleteGridTopology() {
        val live = declaration("live", SharedTmuxSurfacePresentation.Single, 7, 1)
        assertEquals(
            listOf(InlineAuthorityRepaintTarget("live", 7, 1)),
            validatedInlineAuthorityRepaintTargets(
                declarations = listOf(live),
                presentation = TmuxScreenRenderPresentation.Single,
                activeWindowId = 7,
                activePaneId = 1,
                activePaneIds = setOf(1, 2),
                mountedSurfaceIds = setOf("live"),
            ),
        )
        assertTrue(
            validatedInlineAuthorityRepaintTargets(
                declarations = listOf(live),
                presentation = TmuxScreenRenderPresentation.Grid,
                activeWindowId = 7,
                activePaneId = 1,
                activePaneIds = setOf(1, 2),
                mountedSurfaceIds = setOf("live"),
            ).isEmpty(),
        )

        val grid = listOf(
            declaration("pane:2", SharedTmuxSurfacePresentation.Grid, 7, 2),
            declaration("pane:1", SharedTmuxSurfacePresentation.Grid, 7, 1),
        )
        assertEquals(
            listOf(paneOne, paneTwo),
            validatedInlineAuthorityRepaintTargets(
                declarations = grid,
                presentation = TmuxScreenRenderPresentation.Grid,
                activeWindowId = 7,
                activePaneId = 1,
                activePaneIds = setOf(1, 2),
                mountedSurfaceIds = setOf("pane:1", "pane:2"),
            ),
        )
    }

    @Test
    fun targetResolutionRejectsStaleWindowAndPartiallyMountedGrid() {
        val grid = listOf(
            declaration("pane:1", SharedTmuxSurfacePresentation.Grid, 7, 1),
            declaration("pane:2", SharedTmuxSurfacePresentation.Grid, 7, 2),
        )
        assertTrue(
            validatedInlineAuthorityRepaintTargets(
                declarations = grid,
                presentation = TmuxScreenRenderPresentation.Grid,
                activeWindowId = 8,
                activePaneId = 1,
                activePaneIds = setOf(1, 2),
                mountedSurfaceIds = setOf("pane:1", "pane:2"),
            ).isEmpty(),
        )
        assertTrue(
            validatedInlineAuthorityRepaintTargets(
                declarations = grid.take(1),
                presentation = TmuxScreenRenderPresentation.Grid,
                activeWindowId = 7,
                activePaneId = 1,
                activePaneIds = setOf(1, 2),
                mountedSurfaceIds = setOf("pane:1"),
            ).isEmpty(),
        )
    }

    @Test
    fun gridClaimRequiresEveryExactCorrelatedSurface() {
        val fence = InlineAuthorityRepaintFence()
        assertTrue(fence.begin(41, listOf(paneOne, paneTwo)))

        assertEquals(
            InlineAuthorityRepaintFence.Receipt.Ignored,
            fence.noteCompletion(40, "pane:1", sharedOwner(1, 10), SharedTmuxRenderStage.Deep, true, owner(1, 10), fence.epoch),
        )
        assertEquals(
            InlineAuthorityRepaintFence.Receipt.Ignored,
            fence.noteCompletion(41, "pane:99", sharedOwner(99, 10), SharedTmuxRenderStage.Deep, true, owner(99, 10), fence.epoch),
        )
        assertEquals(
            InlineAuthorityRepaintFence.Receipt.Pending,
            fence.noteCompletion(41, "pane:2", sharedOwner(2, 11), SharedTmuxRenderStage.Deep, true, owner(2, 11), fence.epoch),
        )
        assertEquals(
            InlineAuthorityRepaintFence.Receipt.Complete,
            fence.noteCompletion(41, "pane:1", sharedOwner(1, 12), SharedTmuxRenderStage.Deep, true, owner(1, 12), fence.epoch),
        )
    }

    @Test
    fun rejectedOrWrongOwnerFrameCannotCompleteClaim() {
        val fence = InlineAuthorityRepaintFence()
        assertTrue(fence.begin(9, listOf(paneOne)))

        assertTrue(
            fence.noteCompletion(
                9,
                "pane:1",
                sharedOwner(1, 3),
                SharedTmuxRenderStage.Deep,
                false,
                owner(1, 3),
                fence.epoch,
            ) is InlineAuthorityRepaintFence.Receipt.Rejected,
        )
        assertTrue(
            fence.noteCompletion(
                9,
                "pane:1",
                sharedOwner(1, 3),
                SharedTmuxRenderStage.Deep,
                true,
                owner(2, 3),
                fence.epoch,
            ) is InlineAuthorityRepaintFence.Receipt.Rejected,
        )
    }

    @Test
    fun aPaintedSurfaceUnveilsOnVisibleRowsAndOnlyAFirstFillMustBeDeep() {
        // P8: the claim no longer waits for a 2,000-row capture on a surface
        // that already shows its pane; a P7 rebuild of it (viewport) counts
        // too. A surface with no frame of its pane still needs history.
        val fence = InlineAuthorityRepaintFence()
        assertTrue(fence.begin(41, listOf(paneOne, paneTwo), firstFillSurfaceIds = setOf("pane:2")))
        assertEquals(SharedTmuxRenderStage.ViewportOnly, fence.stage("pane:1"))
        assertEquals(SharedTmuxRenderStage.Deep, fence.stage("pane:2"))

        assertEquals(
            InlineAuthorityRepaintFence.Receipt.Pending,
            fence.noteCompletion(41, "pane:1", sharedOwner(1, 10), SharedTmuxRenderStage.ViewportOnly, true, owner(1, 10), fence.epoch),
        )
        assertTrue(
            fence.noteCompletion(41, "pane:2", sharedOwner(2, 11), SharedTmuxRenderStage.Viewport, true, owner(2, 11), fence.epoch)
                is InlineAuthorityRepaintFence.Receipt.Rejected,
        )

        assertTrue(fence.begin(42, listOf(paneOne, paneTwo), firstFillSurfaceIds = setOf("pane:2")))
        assertEquals(
            "a rebuild after a relayout while yielded",
            InlineAuthorityRepaintFence.Receipt.Pending,
            fence.noteCompletion(42, "pane:1", sharedOwner(1, 12), SharedTmuxRenderStage.Viewport, true, owner(1, 12), fence.epoch),
        )
        assertEquals(
            InlineAuthorityRepaintFence.Receipt.Complete,
            fence.noteCompletion(42, "pane:2", sharedOwner(2, 13), SharedTmuxRenderStage.Deep, true, owner(2, 13), fence.epoch),
        )

        // Without the set every target is a first fill, as before P8.
        assertTrue(fence.begin(43, listOf(paneOne)))
        assertEquals(SharedTmuxRenderStage.Deep, fence.stage("pane:1"))
    }

    @Test
    fun aRefreshIsAdmittedOnlyIfItsCaptureAtAnyStageAndAllThatFollowedEnteredItsOwner() {
        for (capture in listOf(
            SharedTmuxRenderFeedSource.DeepRepaint,
            SharedTmuxRenderFeedSource.ViewportRepaint,
            SharedTmuxRenderFeedSource.ViewportRefresh,
        )) {
            val admissions = RefreshFeedAdmissions()
            // A replay ahead of the capture opens nothing.
            admissions.noteFeed("pane:1", sharedOwner(1, 4), SharedTmuxRenderFeedSource.ForegroundReplay, true)
            admissions.noteFeed("pane:1", sharedOwner(1, 4), capture, true)
            admissions.noteFeed("pane:1", sharedOwner(1, 4), SharedTmuxRenderFeedSource.RepaintScrub, true)
            assertTrue(capture.name, admissions.take("pane:1", sharedOwner(1, 4)))
            assertFalse("taken once", admissions.take("pane:1", sharedOwner(1, 4)))

            admissions.noteFeed("pane:1", sharedOwner(1, 5), capture, true)
            admissions.noteFeed("pane:1", sharedOwner(1, 5), SharedTmuxRenderFeedSource.PaneOutput, false)
            assertFalse("live output after it was refused", admissions.take("pane:1", sharedOwner(1, 5)))

            admissions.noteFeed("pane:1", sharedOwner(1, 6), capture, true)
            assertFalse("another owner's completion", admissions.take("pane:1", sharedOwner(1, 7)))

            admissions.noteFeed("pane:1", sharedOwner(1, 8), capture, true)
            admissions.forget("pane:1")
            assertFalse("a failed refresh", admissions.take("pane:1", sharedOwner(1, 8)))
        }
        val admissions = RefreshFeedAdmissions()
        admissions.noteFeed("pane:1", sharedOwner(1, 9), SharedTmuxRenderFeedSource.PaneOutput, true)
        assertFalse("output alone is no refresh", admissions.take("pane:1", sharedOwner(1, 9)))
    }

    @Test
    fun topologyAndGenerationArePartOfTheFenceIdentity() {
        val fence = InlineAuthorityRepaintFence()
        assertFalse(fence.begin(0, listOf(paneOne)))
        assertFalse(fence.begin(1, emptyList()))
        assertTrue(fence.begin(12, listOf(paneOne, paneTwo)))
        assertTrue(fence.expects(12, "pane:1"))
        assertFalse(fence.expects(13, "pane:1"))
        assertFalse(fence.expects(12, "pane:99"))
        assertTrue(fence.matches(12, listOf(paneTwo, paneOne)))
        assertFalse(fence.matches(13, listOf(paneOne, paneTwo)))
        assertFalse(fence.matches(12, listOf(paneOne)))
        fence.reset()
        assertEquals(null, fence.generation)
    }

    private fun sharedOwner(paneId: Int, epoch: Long) = SharedTmuxRenderOwner(
        windowId = 7,
        paneId = paneId,
        epoch = epoch,
    )

    private fun owner(paneId: Int, epoch: Long) = RenderOwner(
        windowId = 7,
        paneId = paneId,
        epoch = epoch,
        transportGeneration = 5,
    )

    private fun declaration(
        surfaceId: String,
        presentation: SharedTmuxSurfacePresentation,
        windowId: Int,
        paneId: Int,
    ) = SharedTmuxSurfaceDeclaration(surfaceId, presentation, windowId, paneId)
}
