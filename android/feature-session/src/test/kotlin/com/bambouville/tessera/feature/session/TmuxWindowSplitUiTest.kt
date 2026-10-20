package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import org.junit.Assert.*
import org.junit.Test

class TmuxWindowSplitUiTest {
    @Test fun targetRequiresActivePaneOwnedByChosenWindow() {
        val window = SharedTmuxWindow(7, 2, "inactive", 12, listOf(SharedTmuxPane(12, null, "sh", true)), false, null)
        assertEquals(12, tmuxWindowSplitTargetPane(window))
        assertNull(tmuxWindowSplitTargetPane(window.copy(activePaneId = null)))
        assertNull(tmuxWindowSplitTargetPane(window.copy(activePaneId = 99)))
        assertNull(tmuxWindowSplitTargetPane(window.copy(panes = emptyList())))
    }
    @Test fun fourDirectionsPreserveAxisAndBefore() {
        assertEquals(listOf(false to false, false to true, true to false, true to true),
            TmuxWindowSplitOption.entries.map { it.vertical to it.before })
    }
}
