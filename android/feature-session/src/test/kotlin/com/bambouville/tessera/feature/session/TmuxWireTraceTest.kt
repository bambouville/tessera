package com.bambouville.tessera.feature.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TmuxWireTraceTest {
    @Test
    fun separatorsAndControlBytesStayVisible() {
        assertEquals(
            "%3\\t12\\t4\\r\\n\\eP1000p\\x01",
            tmuxWireSnippet("%3\t12\t4\r\n\u001bP1000p\u0001", 100),
        )
        assertEquals("abc…", tmuxWireSnippet("abcdef", 3))
    }

    @Test
    fun paneContentNeverEntersTheTrace() {
        assertEquals("%output %3 len=11", tmuxWireTraceLine("%output %3 secret text"))
        assertEquals("body len=14", tmuxWireTraceLine("password: hunt"))
        assertEquals("send-keys …", tmuxWireTraceLine("send-keys -t %3 -l 'hunter2'"))
        assertNull(tmuxWireTraceLine(""))
    }

    @Test
    fun framesRowsAndEchoesAreKeptEscaped() {
        assertEquals("%begin 1 2 1", tmuxWireTraceLine("%begin 1 2 1"))
        assertEquals("%3\\t0\\t1\\tsh", tmuxWireTraceLine("%3\t0\t1\tsh"))
        assertEquals("__tessera_windows__\\t@3\\t0", tmuxWireTraceLine("__tessera_windows__\t@3\t0"))
        assertEquals("@3", tmuxWireTraceLine("@3"))
        assertEquals("\\eP1000p%begin 1 0 0", tmuxWireTraceLine("\u001bP1000p%begin 1 0 0"))
        assertEquals(
            "display-message -p '#{window_id}'",
            tmuxWireTraceLine("display-message -p '#{window_id}'"),
        )
    }
}
