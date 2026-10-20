package com.bambouville.tessera.feature.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteCwdProbeTest {
    private fun shellOnRoute(processes: String): String {
        val process = ProcessBuilder("awk", "-v", "probe=100", RemoteCwdProbe.sshRouteShellSelector).start()
        process.outputStream.bufferedWriter().use { it.write(processes.trimIndent() + "\n") }
        assertTrue("process selector must terminate", process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS))
        val output = process.inputStream.bufferedReader().readText().trim()
        assertEquals(process.errorStream.bufferedReader().readText(), 0, process.exitValue())
        return output
    }

    @Test fun `files probe follows only its SSH connection even with newer shells elsewhere`() {
        assertEquals("22", shellOnRoute("""
            10 1 ? sshd-session
            20 10 pts/0 bash
            22 20 pts/0 zsh
            100 10 ? sh
            200 1 ? sshd-session
            300 200 pts/1 bash
        """))
    }

    @Test fun `files probe walks exec wrappers and supports BSD tty names`() {
        assertEquals("20", shellOnRoute("""
            10 1 ?? sshd
            20 10 ttys001 -zsh
            90 10 ?? bash
            100 90 ?? sh
            300 200 ttys002 zsh
        """))
    }

    @Test fun `files probe never escapes an SSH connection that has no terminal`() {
        assertEquals("", shellOnRoute("""
            5 1 ? sshd
            10 5 ? sshd-session
            100 10 ? sh
            200 5 ? sshd-session
            300 200 pts/1 bash
        """))
    }

    @Test fun `plain ssh probe excludes its own tty-less exec shell`() {
        val command = RemoteCwdProbe.discoveryCommand(moshServerPid = null)
        assertTrue(command.startsWith("sh -c '"))
        assertTrue(command.contains("pts\\/|ttys"))
        assertTrue(command.contains("TESSERA_CWD="))
    }

    @Test fun `mosh probe anchors lookup to bootstrap server child`() {
        val command = RemoteCwdProbe.discoveryCommand(moshServerPid = 4242)
        assertTrue(command.contains("pgrep -P 4242"))
        assertTrue(command.contains("/proc/\$sp/cwd"))
    }

    @Test fun `reported path ignores login noise and rejects non-absolute values`() {
        assertEquals("/srv/project", RemoteCwdProbe.reportedPath("motd\nTESSERA_CWD=/srv/project\n"))
        assertNull(RemoteCwdProbe.reportedPath("TESSERA_CWD=relative/path\n"))
        assertNull(RemoteCwdProbe.reportedPath("motd only\n"))
    }

    @Test fun `the follow task key changes whenever the poll would decide differently`() {
        val base = RemoteCwdProbe.followTaskKey(
            panelOpen = true,
            sessionActive = true,
            tmuxAttached = false,
            moshServerPid = null,
        )
        listOf(
            RemoteCwdProbe.followTaskKey(panelOpen = false, sessionActive = true, tmuxAttached = false, moshServerPid = null),
            RemoteCwdProbe.followTaskKey(panelOpen = true, sessionActive = false, tmuxAttached = false, moshServerPid = null),
            RemoteCwdProbe.followTaskKey(panelOpen = true, sessionActive = true, tmuxAttached = true, moshServerPid = null),
            // A bootstrap that delivers its PID late must restart the loop, or
            // it keeps probing with the weaker newest-login-shell heuristic.
            RemoteCwdProbe.followTaskKey(panelOpen = true, sessionActive = true, tmuxAttached = false, moshServerPid = 4242),
        ).forEach { assertNotEquals(base, it) }
        assertEquals(
            base,
            RemoteCwdProbe.followTaskKey(panelOpen = true, sessionActive = true, tmuxAttached = false, moshServerPid = null),
        )
    }

    @Test fun `a probe hit reports its path and forgives earlier misses`() {
        val debounce = RemoteCwdProbe.FollowDebounce()
        assertEquals(RemoteCwdProbe.Outcome.Hold, debounce.step(RemoteCwdProbe.Tick.Probed("motd only\n")))
        assertEquals(1, debounce.consecutiveMisses)
        assertEquals(
            RemoteCwdProbe.Outcome.Report("/srv/project"),
            debounce.step(RemoteCwdProbe.Tick.Probed("TESSERA_CWD=/srv/project\n")),
        )
        assertEquals(0, debounce.consecutiveMisses)
    }

    @Test fun `follow clears exactly once at the miss limit`() {
        val debounce = RemoteCwdProbe.FollowDebounce()
        assertEquals(RemoteCwdProbe.Outcome.Hold, debounce.step(RemoteCwdProbe.Tick.Probed("")))
        assertEquals(RemoteCwdProbe.Outcome.ClearFollow, debounce.step(RemoteCwdProbe.Tick.Probed("")))
        // A host that stays silent must not re-clear a follow the user has
        // since re-enabled from the panel.
        repeat(4) { assertEquals(RemoteCwdProbe.Outcome.Hold, debounce.step(RemoteCwdProbe.Tick.Probed(""))) }
    }

    @Test fun `a down channel is not a miss and a live OSC 7 resets the count`() {
        val debounce = RemoteCwdProbe.FollowDebounce()
        repeat(5) { assertEquals(RemoteCwdProbe.Outcome.Hold, debounce.step(RemoteCwdProbe.Tick.NotPolled)) }
        assertEquals(0, debounce.consecutiveMisses)

        assertEquals(RemoteCwdProbe.Outcome.Hold, debounce.step(RemoteCwdProbe.Tick.Probed("")))
        assertEquals(RemoteCwdProbe.Outcome.Hold, debounce.step(RemoteCwdProbe.Tick.OscSignalLive))
        assertEquals(0, debounce.consecutiveMisses)
        // Standdown then one miss must not clear: the shell reporting in band
        // is the strongest evidence follow is alive.
        assertEquals(RemoteCwdProbe.Outcome.Hold, debounce.step(RemoteCwdProbe.Tick.Probed("")))
    }
}
