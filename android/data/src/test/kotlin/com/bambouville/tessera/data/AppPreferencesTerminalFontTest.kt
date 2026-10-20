package com.bambouville.tessera.data

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `:data` cannot see `:design`, so the stored default is spelled by hand here.
 * A typo would leave every fresh install on a font id the catalog resolves away
 * to the default anyway — invisible in the terminal, but it would show as an
 * unselected picker on first open. `TerminalFontCatalogTest` pins the other end
 * of the same literal.
 */
class AppPreferencesTerminalFontTest {
    @Test
    fun defaultTerminalFontMatchesTheCatalogDefaultId() {
        assertEquals("jetbrains_mono", AppPreferences().terminalFontId)
    }
}
