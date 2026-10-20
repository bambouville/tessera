package com.bambouville.tessera.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class TerminalAppearanceTest {
    @Test
    fun `catalog keeps the six iOS terminal themes`() {
        assertEquals(
            listOf("void", "graphite", "amber", "paper", "dracula", "nord"),
            TerminalTheme.all.map(TerminalTheme::id),
        )
        assertEquals(16, TerminalTheme.Void.ansi.size)
        assertEquals("#000000", TerminalTheme.Void.background)
        assertEquals("#FAFAFA", TerminalTheme.Paper.background)
        assertEquals("#2E3440", TerminalTheme.Nord.background)
        assertSame(TerminalTheme.Void, TerminalTheme.fromId("unknown"))
    }

    @Test
    fun `cursor preferences default to the iOS block cursor contract`() {
        assertEquals(TerminalCursorStyle.Block, TerminalCursorStyle.fromPersisted("block"))
        assertEquals(TerminalCursorStyle.Bar, TerminalCursorStyle.fromPersisted("bar"))
        assertEquals(TerminalCursorStyle.Underline, TerminalCursorStyle.fromPersisted("underline"))
        assertEquals(TerminalCursorStyle.Block, TerminalCursorStyle.fromPersisted("bad-value"))
    }
}
