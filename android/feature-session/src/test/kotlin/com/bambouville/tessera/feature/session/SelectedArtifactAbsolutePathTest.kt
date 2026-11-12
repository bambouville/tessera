package com.bambouville.tessera.feature.session

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/** Guard the Compose callback's never-connect branch, which cannot mount on the JVM. */
class SelectedArtifactAbsolutePathTest {
    @Test fun absoluteSelectionsBypassTheCwdProbeAndRelativeSelectionsKeepIt() {
        val relative = "src/main/kotlin/com/bambouville/tessera/feature/session/SshSessionScreen.kt"
        val source = listOf(File(relative), File("feature-session", relative), File("android/feature-session", relative))
            .first(File::isFile).readText()
        val action = source.substringAfter("val currentSelectionPathAction by ").substringBefore("val forwardingRuleStore =")
        assertTrue("absolute path actions must call perform directly before the relative-path probe", Regex(
            """if\s*\(selection\.trim\(\)\.startsWith\('/'\)\)\s*\{\s*perform\(currentTerminalDirectory\)\s*}\s*else\s*\{\s*controller\.queryTerminalDirectory\(currentTerminalDirectory, currentTerminalPaneId\)""",
        ).containsMatchIn(action))
        assertTrue(action.contains("perform(freshDirectory ?: currentTerminalDirectory)"))
    }
}
