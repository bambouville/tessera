package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SharedTmuxGeometryInstrumentedTest {
    @Test
    fun automaticTargetAndRepaintUseSharedApplePolicies() {
        assertEquals(
            "tessera-b266b78c",
            SharedAutomaticTmuxTarget.sessionName("alice", "example.com", 2222),
        )
        val metadata = "%7\t3\t2\tshell\tmain\thost\t0\t12\t0\t23\t1\t0\t0\t0\t1\t0\t0\t0\t0\t0\t0\t0"
        val repaint = SharedTmuxRepaint.assemble(
            metadataLine = metadata,
            captureLines = listOf("hello", "world"),
            terminalIsInAltScreen = false,
            clientRows = 24,
        ).decodeToString()
        assertTrue(repaint.startsWith("\u001b[?2026l"))
        assertTrue(repaint.contains("hello\r\nworld"))
        assertTrue(repaint.endsWith("\u001b[3;4H"))

        val emptyRepaint = SharedTmuxRepaint.assemble(
            metadataLine = metadata,
            captureLines = emptyList(),
            terminalIsInAltScreen = false,
            clientRows = 24,
        )
        assertTrue(emptyRepaint.isNotEmpty())
    }

    @Test
    fun androidUsesSharedCompactProjectionAndPeerGuard() {
        val viewport = SharedTmuxGridSize(columns = 39, rows = 15)
        val projected = SharedTmuxGeometry.compactClientSize(
            viewport = viewport,
            layout = null,
            focusPaneId = null,
            window = SharedTmuxGridSize(columns = 80, rows = 24),
            focus = SharedTmuxGridSize(columns = 40, rows = 24),
        )

        assertEquals(SharedTmuxGridSize(columns = 78, rows = 15), projected)
        assertEquals(
            SharedTmuxCompactReprojection.REPROJECT,
            SharedTmuxGeometry.compactReprojection(
                viewport = viewport,
                lastClientSize = viewport,
                layout = null,
                focusPaneId = null,
                window = SharedTmuxGridSize(columns = 80, rows = 24),
                focus = SharedTmuxGridSize(columns = 40, rows = 24),
                memo = SharedTmuxCompactReprojectionMemo.FRESH,
            ).decision,
        )
        assertEquals(
            SharedTmuxCompactReprojection.HOLD,
            SharedTmuxGeometry.compactReprojection(
                viewport = viewport,
                lastClientSize = projected,
                layout = null,
                focusPaneId = null,
                window = SharedTmuxGridSize(columns = 160, rows = 50),
                focus = SharedTmuxGridSize(columns = 80, rows = 50),
                memo = SharedTmuxCompactReprojectionMemo.FRESH,
            ).decision,
        )
    }

    /**
     * The tree Android decoded reaches the shared solver: real tmux 3.6a took
     * a 59-of-200-column focused pane through eleven ratio resizes on a
     * 50-column phone; solved against tmux's resize it is one, and the
     * layout tmux leaves holds.
     */
    @Test
    fun androidSolvesCompactSizeAgainstTheLayoutTreeAndSettles() {
        fun twoPane(columns: Int, right: Int) = SharedTmuxLayoutNode.Split(
            horizontal = true,
            width = columns, height = 40,
            children = listOf(
                SharedTmuxLayoutNode.Leaf(paneId = 0, width = columns - right - 1, height = 40),
                SharedTmuxLayoutNode.Leaf(paneId = 1, width = right, height = 40, x = columns - right),
            ),
        )
        val viewport = SharedTmuxGridSize(columns = 50, rows = 40)
        val sizer = SharedTmuxCompactSizer()
        val start = twoPane(200, 59)
        val projected = sizer.clientSize(
            viewport, start, 1, SharedTmuxGridSize(200, 40), SharedTmuxGridSize(59, 40),
        )
        assertEquals(SharedTmuxGridSize(columns = 181, rows = 40), projected)
        assertEquals(
            SharedTmuxCompactReprojection.REPROJECT,
            sizer.judge(viewport, viewport, start, 1, SharedTmuxGridSize(200, 40), SharedTmuxGridSize(59, 40)).decision,
        )
        val landed = twoPane(181, 50)
        assertEquals(
            projected,
            sizer.clientSize(viewport, landed, 1, SharedTmuxGridSize(181, 40), SharedTmuxGridSize(50, 40)),
        )
        assertEquals(
            SharedTmuxCompactReprojection.HOLD,
            sizer.judge(viewport, projected, landed, 1, SharedTmuxGridSize(181, 40), SharedTmuxGridSize(50, 40)).decision,
        )

        // A pane after the first of a nested same-direction split (what
        // tmux leaves after closing a pane) never grows: the window stays
        // instead of running to tmux's 10000-column maximum.
        val nested = SharedTmuxLayoutNode.Split(
            horizontal = true,
            width = 200, height = 40,
            children = listOf(
                SharedTmuxLayoutNode.Leaf(paneId = 0, width = 100, height = 40),
                SharedTmuxLayoutNode.Split(
                    horizontal = true,
                    width = 99, height = 40, x = 101,
                    children = listOf(
                        SharedTmuxLayoutNode.Leaf(paneId = 2, width = 58, height = 40, x = 101),
                        SharedTmuxLayoutNode.Leaf(paneId = 1, width = 40, height = 40, x = 160),
                    ),
                ),
            ),
        )
        assertEquals(
            SharedTmuxGridSize(columns = 200, rows = 40),
            SharedTmuxGeometry.compactClientSize(
                viewport, nested, 1, SharedTmuxGridSize(200, 40), SharedTmuxGridSize(40, 40),
            ),
        )
    }

    @Test
    fun clientSizeReplayCarriesTheLatestFenceOnlyOnTheInlinePath() {
        assertEquals(
            listOf("refresh-client -C 54,37", "select-window"),
            SharedTmuxCommands.clientSizeReplayCommands(columns = 54, rows = 37, sideChannel = false),
        )
        assertEquals(
            listOf("refresh-client -C 54,37"),
            SharedTmuxCommands.clientSizeReplayCommands(columns = 54, rows = 37, sideChannel = true),
        )
        assertEquals(
            listOf("refresh-client -C 54,37"),
            SharedTmuxCommands.clientSizeReplayCommands(
                columns = 54, rows = 37, sideChannel = false, belongsToClaim = true,
            ),
        )
        assertTrue(
            SharedTmuxCommands.clientSizeReplayCommands(columns = 0, rows = 37, sideChannel = false).isEmpty(),
        )
        // The fence a claim sends itself is the one the inline replay ends
        // with; the JVM tests' port (`coreLatestFenceCommand`) is this string.
        assertEquals("select-window", SharedTmuxCommands.clientSizeLatestFenceCommand)

        // A window already at the projected grid still re-advertises a stale client size.
        val viewport = SharedTmuxGridSize(columns = 54, rows = 37)
        assertEquals(
            SharedTmuxCompactReprojection.REPROJECT,
            SharedTmuxGeometry.compactReprojection(
                viewport = viewport,
                lastClientSize = SharedTmuxGridSize(columns = 106, rows = 9),
                layout = null,
                focusPaneId = null,
                window = viewport,
                focus = viewport,
                memo = SharedTmuxCompactReprojectionMemo.FRESH,
            ).decision,
        )
    }

    @Test
    fun hydrationCommandsEndWithTheSharedPauseAfterPolicy() {
        val commands = SharedTmuxCommands.hydrationCommands()

        assertTrue(commands.isNotEmpty())
        assertEquals("refresh-client -f pause-after=5", commands.last())
        assertEquals(
            commands.single { it.contains("__tessera_active_window__") },
            SharedTmuxCommands.activeWindowHydrationCommand(),
        )
        assertTrue(
            SharedTmuxCommands.activeWindowHydrationMatches(
                windowId = 17,
                lines = listOf("", "__tessera_active_window__\t@17\t3.6a"),
            ),
        )
        assertFalse(
            SharedTmuxCommands.activeWindowHydrationMatches(
                windowId = 17,
                lines = listOf("__tessera_active_window__\t@18"),
            ),
        )
        assertEquals(
            "display-message -p -t @17 '__tessera_active_pane__\t#{window_id}\t#{pane_id}'",
            SharedTmuxCommands.activePaneHydrationCommand(windowId = 17),
        )
        assertTrue(
            SharedTmuxCommands.activePaneHydrationMatches(
                windowId = 17,
                paneId = 42,
                lines = listOf("", "__tessera_active_pane__\t@17\t%42"),
            ),
        )
        assertFalse(
            SharedTmuxCommands.activePaneHydrationMatches(
                windowId = 17,
                paneId = 42,
                lines = listOf(
                    "__tessera_active_pane__\t@17\t%42",
                    "__tessera_active_pane__\t@17\t%42",
                ),
            ),
        )
    }
}
