package com.bambouville.tessera.terminal

import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A paste reaches the session as one write (S5′): the session's authority
 * gate decides per write, so a bracketed paste split into three could lose
 * its text and closing delimiter after the opening one went out, leaving the
 * application reading every later key as pasted text.
 */
class TerminalPasteTest {
    private class RecordingOutput : TerminalOutput() {
        val writes = mutableListOf<String>()
        override fun write(data: ByteArray, offset: Int, count: Int) {
            writes += String(data, offset, count, Charsets.UTF_8)
        }
        override fun titleChanged(oldTitle: String?, newTitle: String?) = Unit
        override fun hostDirectoryChanged(uri: String?) = Unit
        override fun onCopyTextToClipboard(text: String?) = Unit
        override fun onPasteTextFromClipboard() = Unit
        override fun onBell() = Unit
        override fun onColorsChanged() = Unit
    }

    private fun emulator(output: RecordingOutput) = TerminalEmulator(output, 80, 24, 10, 20, 100, null)

    @Test fun aBracketedPasteIsOneWrite() {
        val output = RecordingOutput()
        val emulator = emulator(output)
        val enable = "\u001b[?2004h".toByteArray()
        emulator.append(enable, enable.size)

        emulator.paste("echo one\necho two")

        assertEquals(listOf("\u001b[200~echo one\recho two\u001b[201~"), output.writes)
    }

    @Test fun aPlainPasteIsOneWriteWithoutDelimiters() {
        val output = RecordingOutput()

        emulator(output).paste("a\r\nb")

        assertEquals(listOf("a\rb"), output.writes)
    }
}
