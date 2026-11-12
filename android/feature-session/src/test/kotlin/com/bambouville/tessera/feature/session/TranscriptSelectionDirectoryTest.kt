package com.bambouville.tessera.feature.session

import org.junit.Assert.assertEquals
import org.junit.Test

/** Where an Agent Center transcript path anchors in its bound session. */
class TranscriptSelectionDirectoryTest {
    private val noPane: (Int) -> String? = { error("no pane lookup expected") }

    @Test fun anAbsolutePathNeedsNoDirectoryAndAsksNobody() {
        for (tmuxOff in listOf(true, false)) {
            assertEquals(TranscriptSelectionDirectory.Known(null), transcriptSelectionDirectory(
                "  /srv/app.log", tmuxOff, paneId = 3, reportedShellDirectory = "/home/dev", paneCurrentPath = noPane,
            ))
        }
    }

    @Test fun aTmuxBindingAsksTheAgentsPaneWithItsSnapshotPathAsFallback() {
        assertEquals(TranscriptSelectionDirectory.QueryPane(7, "/home/dev/app"), transcriptSelectionDirectory(
            "src/App.kt", tmuxOff = false, paneId = 7, reportedShellDirectory = "/elsewhere",
        ) { pane -> if (pane == 7) "/home/dev/app" else "/wrong" })
        assertEquals(TranscriptSelectionDirectory.QueryPane(7, null), transcriptSelectionDirectory(
            "~/notes.md", tmuxOff = false, paneId = 7, reportedShellDirectory = null,
        ) { null })
    }

    @Test fun aTmuxSessionWithoutAPaneBindingHasNoDirectory() {
        assertEquals(TranscriptSelectionDirectory.Known(null), transcriptSelectionDirectory(
            "src/App.kt", tmuxOff = false, paneId = null, reportedShellDirectory = "/home/dev", paneCurrentPath = noPane,
        ))
    }

    @Test fun aPlainShellUsesOnlyTheCwdItReported() {
        assertEquals(TranscriptSelectionDirectory.Known("/home/dev/app"), transcriptSelectionDirectory(
            "src/App.kt", tmuxOff = true, paneId = null, reportedShellDirectory = "/home/dev/app", paneCurrentPath = noPane,
        ))
        for (reported in listOf(null, "", "relative/dir", "/home/dev\u001b]7;")) {
            assertEquals(reported.toString(), TranscriptSelectionDirectory.Known(null), transcriptSelectionDirectory(
                "src/App.kt", tmuxOff = true, paneId = null, reportedShellDirectory = reported, paneCurrentPath = noPane,
            ))
        }
    }

    @Test fun aTmuxPaneBindingOnAPlainSessionHasNoDirectory() {
        assertEquals(TranscriptSelectionDirectory.Known(null), transcriptSelectionDirectory(
            "src/App.kt", tmuxOff = true, paneId = 2, reportedShellDirectory = "/home/dev/app", paneCurrentPath = noPane,
        ))
    }
}
