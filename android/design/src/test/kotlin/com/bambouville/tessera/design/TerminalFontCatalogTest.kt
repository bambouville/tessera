package com.bambouville.tessera.design

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The id list is pinned here and in `TerminalFontCatalogTests.swift` against the
 * same literal, because the two catalogs are hand-mirrored: a family added to
 * one platform and forgotten on the other would otherwise ship as a preference
 * that syncs across but renders as the default on arrival.
 *
 * `AppPreferencesTerminalFontTest` pins the third copy — the stored default in `:data`,
 * which cannot see this module.
 */
class TerminalFontCatalogTest {

    private val expectedIds = listOf(
        "jetbrains_mono",
        "fira_code",
        "hack",
        "cascadia_mono",
        "source_code_pro",
        "ibm_plex_mono",
        "geist_mono",
        "ubuntu_mono",
        "inconsolata",
        "dejavu_sans_mono",
        "system",
    )

    @Test
    fun `catalog ids and order match the shared list`() {
        assertEquals(expectedIds, TerminalFontCatalog.all.map { it.id })
    }

    @Test
    fun `default is the first entry`() {
        assertEquals("jetbrains_mono", TerminalFontCatalog.DEFAULT_ID)
        assertEquals(TerminalFontCatalog.DEFAULT_ID, TerminalFontCatalog.all.first().id)
    }

    @Test
    fun `every bundled family names a font resource and a PostScript name`() {
        TerminalFontCatalog.all.filter { it.id != "system" }.forEach { option ->
            assertNotNull("${option.id} has no font resource", option.fontRes)
            assertNotNull("${option.id} has no PostScript name", option.postScriptName)
        }
    }

    @Test
    fun `system bundles nothing`() {
        val system = TerminalFontCatalog.find("system")
        assertNull(system.fontRes)
        assertNull(system.postScriptName)
    }

    @Test
    fun `resolve maps legacy PostScript names onto ids`() {
        assertEquals("jetbrains_mono", TerminalFontCatalog.resolve("JetBrainsMono-Regular"))
        assertEquals("dejavu_sans_mono", TerminalFontCatalog.resolve("DejaVuSansMono"))
    }

    @Test
    fun `resolve falls back to the default for values this build cannot render`() {
        // Android's own pre-picker manifest placeholder, an iOS face Tessera
        // never bundled, a family from a future build, and no value at all.
        assertEquals("jetbrains_mono", TerminalFontCatalog.resolve("monospace"))
        assertEquals("jetbrains_mono", TerminalFontCatalog.resolve("SFMono-Regular"))
        assertEquals("jetbrains_mono", TerminalFontCatalog.resolve("victor_mono"))
        assertEquals("jetbrains_mono", TerminalFontCatalog.resolve(null))
    }

    @Test
    fun `resolve is idempotent over every catalog id`() {
        TerminalFontCatalog.all.forEach { option ->
            assertEquals(option.id, TerminalFontCatalog.resolve(option.id))
        }
    }

    @Test
    fun `find falls back rather than throwing`() {
        assertEquals("jetbrains_mono", TerminalFontCatalog.find("nonexistent").id)
    }
}
