package com.bambouville.tessera.core.bridge

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Kotlin half of compact tmux sizing: the layout tree crosses to the
 * shared core in tmux's own cell grammar, and the controller's per-event
 * reconciliation must not re-encode or re-solve a layout that did not change.
 * The solving itself is the shared core's, pinned by its Swift tests and by
 * `SharedTmuxGeometryInstrumentedTest` on a device.
 */
class SharedTmuxCompactSizerTest {
    private val stacked = SharedTmuxLayoutNode.Split(
        horizontal = true,
        width = 121, height = 40,
        children = listOf(
            SharedTmuxLayoutNode.Leaf(paneId = 1, width = 80, height = 40),
            SharedTmuxLayoutNode.Split(
                horizontal = false,
                width = 40, height = 40, x = 81,
                children = listOf(
                    SharedTmuxLayoutNode.Leaf(paneId = 2, width = 40, height = 30, x = 81),
                    SharedTmuxLayoutNode.Leaf(paneId = 13, width = 40, height = 9, x = 81, y = 31),
                ),
            ),
        ),
    )

    @Test
    fun layoutCrossesInTmuxCellGrammarWithoutChecksum() {
        assertEquals(
            "121x40,0,0{80x40,0,0,1,40x40,81,0[40x30,81,0,2,40x9,81,31,13]}",
            stacked.tmuxLayoutCellBytes().decodeToString(),
        )
        assertEquals(
            "80x24,0,0,7",
            SharedTmuxLayoutNode.Leaf(paneId = 7, width = 80, height = 24).tmuxLayoutCellBytes().decodeToString(),
        )
    }

    /**
     * The length limit belongs to the shared core's parser alone, which sizes
     * a layout past it by ratio (pinned by the Swift ABI tests). Kotlin hands
     * over the whole encoding rather than keeping a second copy of the limit.
     */
    @Test
    fun oversizedLayoutCrossesWholeForTheCoreToRefuse() {
        val wide = SharedTmuxLayoutNode.Split(
            horizontal = true,
            width = 9_999, height = 40,
            children = List(3_000) { SharedTmuxLayoutNode.Leaf(paneId = it, width = 2, height = 40, x = it * 3) },
        )
        val cells = wide.tmuxLayoutCellBytes().decodeToString()
        assertTrue(cells.length > 32_768)
        assertTrue(cells.startsWith("9999x40,0,0{2x40,0,0,0,2x40,3,0,1,"))
        assertTrue(cells.endsWith(",2x40,8997,0,2999}"))
    }

    @Test
    fun unchangedInputsReuseTheAnswerWithoutCallingTheCore() {
        val core = RecordingCore()
        val sizer = SharedTmuxCompactSizer(core)
        val viewport = SharedTmuxGridSize(44, 20)
        val window = SharedTmuxGridSize(121, 40)
        val focus = SharedTmuxGridSize(40, 9)

        val first = sizer.clientSize(viewport, stacked, 13, window, focus)
        val again = sizer.clientSize(viewport, stacked, 13, window, focus)
        assertSame(first, again)
        assertEquals(1, core.sizeCalls)
        // An equal tree decoded from a newer snapshot is the same layout.
        sizer.clientSize(viewport, stacked.copy(), 13, window, focus)
        assertEquals(1, core.sizeCalls)
        // Any changed input asks again.
        sizer.clientSize(viewport, stacked, 2, window, focus)
        sizer.clientSize(SharedTmuxGridSize(45, 20), stacked, 2, window, focus)
        assertEquals(3, core.sizeCalls)
        // One encoding per distinct tree, shared by both questions, and a
        // judgement answers the size it judged.
        val judgement = sizer.judge(viewport, SharedTmuxGridSize(129, 62), stacked, 13, window, focus)
        assertSame(judgement.clientSize, sizer.clientSize(viewport, stacked, 13, window, focus))
        assertEquals(4, core.sizeCalls)
        assertEquals(1, core.encodings.size)
        assertArrayEquals(stacked.tmuxLayoutCellBytes(), core.encodings.single())
    }

    /**
     * The controller judges on every runtime event, and an advertisement it
     * withholds changes none of the inputs. The core judges each set of
     * inputs once: asking again with the memo it advanced would count the
     * same layout as another correction and stop a cycle that never ran.
     */
    @Test
    fun judgementsAreKeptPerInputsAndReportAStopOnce() {
        val core = RecordingCore()
        val sizer = SharedTmuxCompactSizer(core)
        val viewport = SharedTmuxGridSize(44, 20)
        val last = SharedTmuxGridSize(121, 40)
        val advanced = SharedTmuxCompactReprojectionMemo(0x100L, 0x1L)

        core.next += SharedTmuxCompactReprojectionResult(SharedTmuxCompactReprojection.REPROJECT, advanced)
        repeat(6) {
            val judgement = sizer.judge(viewport, last, stacked, 13, last, null)
            assertEquals(SharedTmuxCompactReprojection.REPROJECT, judgement.decision)
            assertEquals(advanced, sizer.memo)
        }
        assertEquals(listOf(SharedTmuxCompactReprojectionMemo.FRESH), core.memosIn)
        // An equal tree from a newer snapshot is the same judgement.
        sizer.judge(viewport, last, stacked.copy(), 13, last, null)
        assertEquals(1, core.memosIn.size)

        // A changed input is a new judgement, from the advanced memo.
        val stopped = SharedTmuxCompactReprojectionMemo(0x100L, 0x9L)
        core.next += SharedTmuxCompactReprojectionResult(SharedTmuxCompactReprojection.HOLD_CYCLE, stopped, stoppedCycle = true)
        val advertised = SharedTmuxGridSize(130, 40)
        val stop = sizer.judge(viewport, advertised, stacked, 13, last, null)
        assertEquals(SharedTmuxCompactReprojection.HOLD_CYCLE, stop.decision)
        assertTrue(stop.stoppedCycle)
        assertEquals(listOf(SharedTmuxCompactReprojectionMemo.FRESH, advanced), core.memosIn)
        assertEquals(stopped, sizer.memo)
        // The stop is reported once; the hold itself is kept.
        val held = sizer.judge(viewport, advertised, stacked, 13, last, null)
        assertEquals(SharedTmuxCompactReprojection.HOLD_CYCLE, held.decision)
        assertFalse(held.stoppedCycle)
        assertEquals(2, core.memosIn.size)

        // A forced replay starts over: the same inputs reach the core again,
        // with a fresh memo.
        sizer.reset()
        assertEquals(SharedTmuxCompactReprojectionMemo.FRESH, sizer.memo)
        core.next += SharedTmuxCompactReprojectionResult(SharedTmuxCompactReprojection.REPROJECT, advanced)
        assertEquals(
            SharedTmuxCompactReprojection.REPROJECT,
            sizer.judge(viewport, advertised, stacked, 13, last, null).decision,
        )
        assertEquals(SharedTmuxCompactReprojectionMemo.FRESH, core.memosIn.last())
        assertEquals(3, core.memosIn.size)
    }

    private class RecordingCore : SharedTmuxCompactSizer.Core {
        var sizeCalls = 0
        val encodings = mutableListOf<ByteArray>()
        val memosIn = mutableListOf<SharedTmuxCompactReprojectionMemo>()
        val next = ArrayDeque<SharedTmuxCompactReprojectionResult>()

        override fun clientSize(
            viewport: SharedTmuxGridSize,
            layoutCells: ByteArray?,
            focusPaneId: Int?,
            window: SharedTmuxGridSize?,
            focus: SharedTmuxGridSize?,
        ): SharedTmuxGridSize {
            sizeCalls += 1
            note(layoutCells)
            return SharedTmuxGridSize(viewport.columns + sizeCalls, viewport.rows)
        }

        override fun reprojection(
            viewport: SharedTmuxGridSize,
            lastClientSize: SharedTmuxGridSize?,
            layoutCells: ByteArray?,
            focusPaneId: Int?,
            window: SharedTmuxGridSize?,
            focus: SharedTmuxGridSize?,
            memo: SharedTmuxCompactReprojectionMemo,
        ): SharedTmuxCompactReprojectionResult {
            note(layoutCells)
            memosIn += memo
            return next.removeFirstOrNull() ?: SharedTmuxCompactReprojectionResult(SharedTmuxCompactReprojection.HOLD, memo)
        }

        private fun note(cells: ByteArray?) {
            if (cells != null && encodings.none { it === cells }) encodings += cells
        }
    }
}
