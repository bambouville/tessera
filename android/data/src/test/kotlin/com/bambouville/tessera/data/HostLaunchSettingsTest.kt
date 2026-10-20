package com.bambouville.tessera.data

import org.junit.Assert.*
import org.junit.Test

class HostLaunchSettingsTest {
    private val host = SavedHost("fixture", "fixture", "fixture.example", 22, "tester", null, null,
        TransportKinds.SSH, TmuxModes.OFF, null, launchCommand = "printf 'custom\\n'",
        envVars = "# ignored\nexport QR_TEST=hello\nBAD-NAME=no\nOTHER='two words'",
        startupSnippet = "if true; then\n printf 'startup\\n'\nfi # keep newline")

    @Test fun allTransportsShareTheSamePrologue() {
        val prefix = HostLaunchSettings.prologue(host.envVars, host.startupSnippet)
        assertTrue(prefix.startsWith("export QR_TEST=hello\nexport OTHER='two words'\n"))
        assertTrue(prefix.endsWith("fi # keep newline\n"))
        assertFalse(prefix.contains("BAD-NAME"))
        assertEquals(prefix + host.launchCommand + "\n", HostLaunchSettings.stdin(host))
        val tmux = "exec tmux -CC attach -t 'fixture'"
        assertEquals(HostLaunchSettings.beforeCommand(host, tmux), HostLaunchSettings.moshCommand(host, tmux))
        assertTrue(HostLaunchSettings.moshCommand(host, null)!!.contains("'\\''"))
    }

    @Test fun emptySettingsPreserveExistingLaunches() {
        val empty = host.copy(envVars = null, startupSnippet = null, launchCommand = null)
        assertEquals("", HostLaunchSettings.stdin(empty))
        assertEquals("tmux command", HostLaunchSettings.beforeCommand(empty, "tmux command"))
        assertEquals("tmux command", HostLaunchSettings.moshCommand(empty, "tmux command"))
        assertNull(HostLaunchSettings.moshCommand(empty, null))
    }

    @Test fun tmuxDegradationDoesNotRepeatStartupSnippet() {
        val tmuxHost = host.copy(tmuxMode = TmuxModes.AUTOMATIC)
        val fallback = HostLaunchSettings.stdin(tmuxHost, includeStartupSnippet = false)
        assertTrue(fallback.contains("export QR_TEST="))
        assertFalse(fallback.contains("startup"))
        assertFalse(fallback.contains("custom"))
    }

    @Test fun optionalDataLimitMatchesWireUtf8Bytes() {
        val draft = HostDraft(displayName = "fixture", hostname = "fixture.example", username = "tester", notes = "x".repeat(65_536))
        assertEquals(draft.notes, HostDraftValidator.normalize(draft).notes)
        assertThrows(IllegalArgumentException::class.java) { HostDraftValidator.normalize(draft.copy(notes = "é".repeat(32_769))) }
    }
}
