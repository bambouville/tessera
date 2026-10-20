package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import org.junit.Assert.assertEquals
import org.junit.Test

class PresentedProgramStatusTerminalsTest {
    private fun snapshot(zoomed: Boolean = false, split: Boolean = true) = SharedTmuxSnapshot(
        sessionName = "test",
        activeWindowId = 1,
        windows = listOf(
            SharedTmuxWindow(id = 1, index = 0, name = "deploy", activePaneId = 11,
                panes = if (split) listOf(SharedTmuxPane(id = 11, title = null, currentCommand = null, active = true), SharedTmuxPane(id = 12, title = null, currentCommand = null, active = false))
                    else listOf(SharedTmuxPane(id = 11, title = null, currentCommand = null, active = true)), zoomed = zoomed, layout = null),
            SharedTmuxWindow(id = 2, index = 1, name = "tests", activePaneId = 21,
                panes = listOf(SharedTmuxPane(id = 21, title = null, currentCommand = null, active = true)), zoomed = false, layout = null),
        ),
        authority = SharedTmuxGridAuthoritySnapshot.Mine(generation = 1),
        revision = 1,
        rawJson = ByteArray(0),
    )

    @Test fun hiddenSessionsPresentNothingOnEveryRenderingPath() {
        for (compact in listOf(false, true)) for (whole in listOf(false, true)) {
            assertEquals(emptySet<SharedProgramStatusTerminal>(), presentedProgramStatusTerminals(
                false, true, snapshot(), compact, whole))
        }
        assertEquals(emptySet<SharedProgramStatusTerminal>(), presentedProgramStatusTerminals(
            false, false, null, false, false))
    }

    @Test fun rawAndDegradedTmuxSessionsPresentRaw() {
        val raw = setOf(SharedProgramStatusTerminal.Raw)
        assertEquals(raw, presentedProgramStatusTerminals(true, false, snapshot(), false, false))
        assertEquals(raw, presentedProgramStatusTerminals(true, true, null, false, false))
    }

    @Test fun tabletGridPresentsEveryPaneOfOnlyTheActiveWindow() {
        assertEquals(setOf(SharedProgramStatusTerminal.Pane(11), SharedProgramStatusTerminal.Pane(12)),
            presentedProgramStatusTerminals(true, true, snapshot(), false, false))
    }

    @Test fun compactWholeWindowZoomedAndSinglePanePresentOnlyFocusedPane() {
        val pane = setOf(SharedProgramStatusTerminal.Pane(11))
        assertEquals(pane, presentedProgramStatusTerminals(true, true, snapshot(), true, false))
        assertEquals(pane, presentedProgramStatusTerminals(true, true, snapshot(), false, true))
        assertEquals(pane, presentedProgramStatusTerminals(true, true, snapshot(zoomed = true), false, false))
        assertEquals(pane, presentedProgramStatusTerminals(true, true, snapshot(split = false), false, false))
    }

    @Test fun singleSurfaceAcknowledgesOnlyTheSnapshotPaneActuallyDisplayed() {
        val shown = snapshot()
        // A requested pane B is not presentation evidence until the snapshot changes.
        assertEquals(setOf(SharedProgramStatusTerminal.Pane(11)),
            presentedProgramStatusTerminals(true, true, shown, true, false))
        val selected = shown.copy(windows = shown.windows.map {
            if (it.id == 1) it.copy(activePaneId = 12) else it
        })
        assertEquals(setOf(SharedProgramStatusTerminal.Pane(12)),
            presentedProgramStatusTerminals(true, true, selected, true, false))
        assertEquals(setOf(SharedProgramStatusTerminal.Pane(12)),
            presentedProgramStatusTerminals(true, true, selected, false, true))
    }

    @Test fun coveringPanelsSheetsLaunchAndVeilPresentNothing() {
        for (compact in listOf(false, true)) for (whole in listOf(false, true)) {
            assertEquals(emptySet<SharedProgramStatusTerminal>(), presentedProgramStatusTerminals(
                true, true, snapshot(), compact, whole, terminalCovered = true))
        }
        assertEquals(emptySet<SharedProgramStatusTerminal>(), presentedProgramStatusTerminals(
            true, false, null, false, false, terminalCovered = true))
        // Small dropdowns and find do not set the covering flag.
        assertEquals(setOf(SharedProgramStatusTerminal.Raw), presentedProgramStatusTerminals(
            true, false, null, false, false, terminalCovered = false))
    }

    @Test fun emptyTmuxWindowCannotCheckAResult() {
        val empty = snapshot().copy(windows = emptyList())
        assertEquals(emptySet<SharedProgramStatusTerminal>(),
            presentedProgramStatusTerminals(true, true, empty, false, false))
    }
}
