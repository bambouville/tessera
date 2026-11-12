package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import org.junit.Assert.assertEquals
import org.junit.Test

class TmuxWindowLabelTest {
    @Test fun tabsAndSwitcherUseTheSharedWindowLabelVectors() {
        data class Case(val title: String?, val name: String?, val command: String?, val provider: String?,
            val expected: String, val defaultTitle: Boolean = false)
        val cases = listOf(
            Case("vim README", "sh", "sh", "claude", "vim README"),
            Case(null, "agent", "node", "claude", "agent"),
            Case(null, "sh", "sh", "claude", "claude"),
            Case(null, "sh", "sh", null, "sh"),
            Case(null, "", "zsh", "codex", "codex"),
            Case(null, null, null, null, "@7"),
            Case("devbox", "sh", "sh", "claude", "claude", defaultTitle = true),
        )
        for (case in cases) {
            val window = SharedTmuxWindow(
                id = 7, index = 0, name = case.name, activePaneId = 70,
                panes = listOf(SharedTmuxPane(id = 70, title = null, currentCommand = case.command, active = true)),
                zoomed = false, layout = null, activePaneTitle = case.title,
                activePaneTitleIsDefault = case.defaultTitle,
            )
            val snapshot = SharedTmuxSnapshot(
                sessionName = "fixture", activeWindowId = 7, windows = listOf(window),
                authority = SharedTmuxGridAuthoritySnapshot.Mine(generation = 1), revision = 1, rawJson = ByteArray(0),
            )
            assertEquals(case.toString(), case.expected, window.agentDisplayName { case.provider })
            val row = snapshot.switcherWindows { case.provider }.single()
            assertEquals(case.toString(), "1:${case.expected}", row.title)
            assertEquals(case.name.orEmpty(), row.renameSeed)
        }
    }
}
