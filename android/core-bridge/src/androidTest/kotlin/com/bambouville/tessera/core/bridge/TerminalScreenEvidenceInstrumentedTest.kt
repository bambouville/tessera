package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TerminalScreenEvidenceInstrumentedTest {
    @Test fun claudeMaxUltracodeSoftwareCursorAndFooterCrossActualJNI() {
        val e = "\u001b"
        val footer = "\n────────\n⏸ manual mode on                     ◈ max · ultracode · /effort"
        val placeholder = "────────\n❯\u00a0$e[7mT$e[0;2mry$e[0m $e[2m\"refactor$e[0m $e[2m<filepath>\"$e[0m" + footer
        fun empty(value: String) = SharedAgentComposerEvidence.assess("claude", value, "❯ Try \"refactor <filepath>\"",
            "hello draft", false, cursorRow = 1, cursorColumn = 2, cursorVisible = false, safetyOnly = true, requireEmpty = true)
        assertEquals(SharedAgentComposerEvidence.Assessment.RETURN, empty(placeholder))
        assertEquals(SharedAgentComposerEvidence.Assessment.BLOCKED, empty(placeholder.replace("$e[7m", "$e[0m")))
        assertEquals(SharedAgentComposerEvidence.Assessment.OCCUPIED,
            empty(placeholder.replace("$e[0;2m", "$e[0m").replace("$e[2m", "$e[0m")))
        val inserted = "────────\n❯ hello draft$e[7m $e[0m" + footer
        assertEquals(SharedAgentComposerEvidence.Assessment.RETURN,
            SharedAgentComposerEvidence.assess("claude", inserted, "❯ hello draft ", "hello draft", false,
                cursorRow = 1, cursorColumn = 13, cursorVisible = false, safetyOnly = true))
        assertEquals(SharedAgentComposerEvidence.Assessment.RETURN,
            SharedAgentComposerEvidence.assess("claude", inserted, "❯ hello draft ", "hello draft", false, cursorRow = 1))

        val columns = 48
        fun row(text: String, suggestion: Boolean = false) = text.padEnd(columns).mapIndexed { index, char ->
            SharedTerminalScreenEvidence.Cell(char.toString(), 1, if (suggestion) {
                if (index == 2) 8 else if (index > 2) 32 else 0
            } else 0)
        }
        val rows = listOf(row("❯ Try refactoring", true), row("────────"), row("ctx:5%"))
        val screen = SharedTerminalScreenEvidence(columns, rows, List(rows.size) { false }, 0, 2, false, false)
        assertEquals(SharedAgentComposerEvidence.Assessment.RETURN,
            SharedAgentComposerEvidence.assess("claude", screen.physicalRows.joinToString("\n"), "❯ Try refactoring", "hello", false,
                cursorRow = 0, cursorColumn = 2, cursorVisible = false, safetyOnly = true, requireEmpty = true, screen = screen))
    }

    @Test fun codexMaxAndUltraMarkersKeepEmptyAndInsertedComposerProofAcrossJNI() {
        val e = "\u001b"
        val footer = "\n\nGPT-6.1-Sol ultra · ~/repo\n? for shortcuts    ⚠ 2 warnings · f2 to view"
        for (marker in listOf("›", "»")) {
            // Historical › must not take the place of the live ultra composer.
            val prefix = "› previous message\nprevious response\n\n"
            val idle = prefix + "$e[1;35m$marker$e[0m $e[2mAsk Codex to do anything$e[0m" + footer
            fun empty(capture: String) = SharedAgentComposerEvidence.assess("codex", capture,
                "$marker Ask Codex to do anything", "hello", false, cursorRow = 3, cursorColumn = 2,
                cursorVisible = true, safetyOnly = true, requireEmpty = true)
            assertEquals(SharedAgentComposerEvidence.Assessment.RETURN, empty(idle))
            assertEquals(SharedAgentComposerEvidence.Assessment.OCCUPIED, empty(idle.replace("$e[2mAsk", "Ask")))
            val inserted = prefix + "$marker hello draft" + footer
            assertEquals(SharedAgentComposerEvidence.Assessment.RETURN,
                SharedAgentComposerEvidence.assess("codex", inserted, "$marker hello draft", "hello draft", false,
                    cursorRow = 3, cursorColumn = 13, cursorVisible = true))
            assertEquals(SharedAgentComposerEvidence.Assessment.ABSENT,
                SharedAgentComposerEvidence.assess("codex", idle, "$marker Ask Codex to do anything", "hello draft", false, cursorRow = 3))

            val columns = 48
            fun row(text: String, dim: Boolean = false) = text.padEnd(columns).mapIndexed { index, char ->
                SharedTerminalScreenEvidence.Cell(char.toString(), 1, if (dim && index >= 2) 32 else 0)
            }
            val rows = listOf(row("$marker Ask Codex to do anything", dim = true), row(""), row("GPT-6.1-Sol ultra · ~/repo"), row("? for shortcuts"))
            val screen = SharedTerminalScreenEvidence(columns, rows, List(rows.size) { false }, 0, 2, true, false)
            assertEquals(SharedAgentComposerEvidence.Assessment.RETURN,
                SharedAgentComposerEvidence.assess("codex", screen.physicalRows.joinToString("\n"), "$marker Ask Codex to do anything", "hello", false,
                    cursorRow = 0, cursorColumn = 2, cursorVisible = true, safetyOnly = true, requireEmpty = true, screen = screen))
        }
    }

    @Test fun admittedLargeGridCrossesActualJNIWithoutANSI() {
        for ((columns, rows) in listOf(240 to 120, 65_534 to 1)) {
            val blank = SharedTerminalScreenEvidence.Cell(" ", 1, 0)
            val cells = List(rows) { MutableList(columns) { blank } }
            cells[0][0] = SharedTerminalScreenEvidence.Cell("›", 1, 0)
            cells[0][2] = SharedTerminalScreenEvidence.Cell("x", 1, 0)
            val screen = SharedTerminalScreenEvidence(columns, cells, List(rows) { false }, 0, 3, true, false)
            assertTrue(screen.toJSON().toString().encodeToByteArray().size > 256 * 1_024)
            assertEquals(SharedAgentComposerEvidence.Assessment.RETURN,
                SharedAgentComposerEvidence.assess("codex", screen.physicalRows.joinToString("\n"), "› x", "x", false,
                    cursorRow = 0, cursorColumn = 3, cursorVisible = true, safetyOnly = true, screen = screen))
        }
    }

    /** tmux 3.6a captures of Codex CLI 0.157.1 (49 columns): a status line and
     *  a hint row with a warning badge sit under the composer's padding row. */
    @Test fun codex0157TwoRowFooterSendsOverTheTmuxCapturePath() {
        val e = "\u001b"
        val status = "  $e[38;2;246;226;183mGPT-6-Luna medium$e[39m · $e[38;2;171;223;167m~/projects/tessera$e[39m · $e[38;2;242;181;144mConte…"
        val idle = "\n$e[2m  6:57 PM\n$e[0m\n\n$e[1m›$e[0m $e[2mAsk Codex to do anything$e[0m\n\n$status\n$e[39m  $e[1m?$e[0m for shortcuts                       ⚠ $e[38;2;196;167;103m1$e[39m · $e[1mf2$e[0m"
        val rows = idle.split("\n")
        assertEquals(SharedAgentComposerEvidence.Assessment.RETURN,
            SharedAgentComposerEvidence.assess("codex", idle, rows[4], "hello", false, cursorRow = 4, cursorColumn = 2,
                cursorVisible = true, safetyOnly = true, requireEmpty = true))
        assertEquals(SharedAgentComposerEvidence.Assessment.OCCUPIED,
            SharedAgentComposerEvidence.assess("codex", idle.replace("$e[2mAsk", "Ask"), rows[4], "hello", false, cursorRow = 4,
                cursorColumn = 2, cursorVisible = true, safetyOnly = true, requireEmpty = true))
        assertEquals(SharedAgentComposerEvidence.Assessment.ABSENT,
            SharedAgentComposerEvidence.assess("codex", idle, rows[4], "hello", false, cursorRow = 4))

        val text = "hello draft that is long enough to wrap across the narrow phone width"
        val wrapped = "$e[2m  6:57 PM\n$e[0m\n\n$e[1m›$e[0m hello draft that is long enough to wrap across\n  the narrow phone width\n\n$status\n$e[39m                                        ⚠ $e[38;2;196;167;103m1$e[39m · $e[1mf2$e[0m"
        assertEquals(SharedAgentComposerEvidence.Assessment.RETURN,
            SharedAgentComposerEvidence.assess("codex", wrapped, "  the narrow phone width", text, true, cursorRow = 4))

        val working = "\n$e[2mWorking$e[0m\n$e[0m\n\n$e[1m›$e[0m queued draft while working\n\n$status\n$e[39m  $e[1mtab$e[0m to queue message"
        assertEquals(SharedAgentComposerEvidence.Assessment.TAB,
            SharedAgentComposerEvidence.assess("codex", working, "› queued draft while working", "queued draft while working", true, cursorRow = 4))
    }
}
