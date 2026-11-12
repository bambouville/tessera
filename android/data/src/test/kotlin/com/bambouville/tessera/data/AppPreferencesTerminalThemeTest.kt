package com.bambouville.tessera.data

import org.junit.Assert.assertEquals
import org.junit.Test

class AppPreferencesTerminalThemeTest {
    @Test
    fun defaultTerminalThemeIsAutomatic() {
        assertEquals("system", AppPreferences().terminalThemeId)
    }

    @Test
    fun absentTerminalThemeIsAutomatic() {
        assertEquals(AutomaticTerminalThemeId, knownTerminalTheme(null))
    }

    @Test
    fun automaticSelectionIsAccepted() {
        assertEquals(AutomaticTerminalThemeId, knownTerminalTheme("system"))
    }

    @Test
    fun unknownTerminalThemeIsAutomatic() {
        assertEquals(AutomaticTerminalThemeId, knownTerminalTheme("unknown"))
        assertEquals(AutomaticTerminalThemeId, knownTerminalTheme(""))
    }

    @Test
    fun explicitSelectionsArePreserved() {
        for (id in listOf("void", "graphite", "amber", "paper", "dracula", "nord")) {
            assertEquals(id, knownTerminalTheme(id))
        }
    }

    @Test
    fun automaticSelectionFollowsSystemAppearance() {
        assertEquals("paper", resolvedTerminalThemeId(AutomaticTerminalThemeId, systemDark = false))
        assertEquals("void", resolvedTerminalThemeId(AutomaticTerminalThemeId, systemDark = true))
    }

    @Test
    fun explicitSelectionsIgnoreSystemAppearance() {
        for (id in listOf("void", "graphite", "amber", "paper", "dracula", "nord")) {
            assertEquals(id, resolvedTerminalThemeId(id, systemDark = false))
            assertEquals(id, resolvedTerminalThemeId(id, systemDark = true))
        }
    }
}
