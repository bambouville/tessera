package com.bambouville.tessera.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteFilesFollowTest {
    @Test fun `follow state distinguishes no signal from a broken follow`() {
        assertEquals(
            RemoteFilesFollowState.FOLLOWING,
            RemoteFilesFollow.state(terminalDirectory = "/srv", enabled = true),
        )
        assertEquals(
            RemoteFilesFollowState.MANUAL,
            RemoteFilesFollow.state(terminalDirectory = "/srv", enabled = false),
        )
        // No reported cwd outranks the flag: a session that reports nothing can
        // neither be followed nor be said to have stopped following.
        assertEquals(
            RemoteFilesFollowState.UNAVAILABLE,
            RemoteFilesFollow.state(terminalDirectory = null, enabled = true),
        )
        assertEquals(
            RemoteFilesFollowState.UNAVAILABLE,
            RemoteFilesFollow.state(terminalDirectory = null, enabled = false),
        )
    }

    @Test fun `normalize trims a reported directory to one navigable shape`() {
        assertEquals("/srv/project", RemoteFilesFollow.normalized("/srv/project/"))
        assertEquals("/srv/project", RemoteFilesFollow.normalized("  /srv/project  "))
        assertEquals("/", RemoteFilesFollow.normalized("/"))
        assertEquals("/srv/a b", RemoteFilesFollow.normalized("/srv/a b"))
    }

    @Test fun `normalize rejects reports the browser cannot navigate to`() {
        assertNull(RemoteFilesFollow.normalized(null))
        assertNull(RemoteFilesFollow.normalized(""))
        assertNull(RemoteFilesFollow.normalized("   "))
        assertNull(RemoteFilesFollow.normalized("relative/path"))
        assertNull(RemoteFilesFollow.normalized("~/project"))
        // A bell or an escape in a reported path means the report was scraped
        // out of terminal output, not resolved by the shell.
        assertNull(RemoteFilesFollow.normalized("/srv/\u0007project"))
        assertNull(RemoteFilesFollow.normalized("/srv/project\u001B[0m"))
    }

    @Test fun `an explicit request always outranks follow`() {
        assertEquals(
            "/etc",
            RemoteFilesFollow.openTarget(
                requested = "/etc",
                followEnabled = true,
                terminalDirectory = "/srv",
                currentPath = "/home/dev",
                homePath = "/home/dev",
            ),
        )
    }

    @Test fun `an unaimed open lands on the terminal only while following`() {
        assertEquals(
            "/srv",
            RemoteFilesFollow.openTarget(
                requested = null,
                followEnabled = true,
                terminalDirectory = "/srv",
                currentPath = "/home/dev",
                homePath = "/home/dev",
            ),
        )
        // Refresh must not drag a manually browsing user back to the terminal.
        assertEquals(
            "/home/dev",
            RemoteFilesFollow.openTarget(
                requested = null,
                followEnabled = false,
                terminalDirectory = "/srv",
                currentPath = "/home/dev",
                homePath = "/home/dev",
            ),
        )
    }

    @Test fun `the first open falls back through terminal then home`() {
        // Follow broken before anything was listed: the terminal's cwd is still
        // the best first landing, because home is a guess about the session.
        assertEquals(
            "/srv",
            RemoteFilesFollow.openTarget(
                requested = null,
                followEnabled = false,
                terminalDirectory = "/srv",
                currentPath = null,
                homePath = "/home/dev",
            ),
        )
        assertEquals(
            "/home/dev",
            RemoteFilesFollow.openTarget(
                requested = null,
                followEnabled = true,
                terminalDirectory = null,
                currentPath = null,
                homePath = "/home/dev",
            ),
        )
        assertNull(
            RemoteFilesFollow.openTarget(
                requested = null,
                followEnabled = true,
                terminalDirectory = null,
                currentPath = null,
                homePath = null,
            ),
        )
    }
}
