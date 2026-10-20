package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxLayoutNode
import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The switcher's filtering and ordering rules, which have to match
 * `Tessera/Navigation/CommandPalette.swift` — a query that finds a target on the
 * iPhone must find the same target here.
 */
class SessionSwitcherTest {

    private fun window(
        id: Int,
        index: Int,
        title: String,
        panes: List<SessionSwitcherPane>,
        zoomed: Boolean = false,
    ) = SessionSwitcherWindow(
        id = id,
        index = index,
        position = index + 1,
        title = title,
        renameSeed = title,
        panes = panes,
        zoomed = zoomed,
    )

    private fun session(
        hostId: String,
        title: String = hostId,
        endpoint: String = "dev@$hostId.example.net:22",
        lastTouched: Long? = null,
        paneTitle: String? = null,
    ) = SessionSwitcherSession(
        hostId = hostId,
        title = title,
        endpoint = endpoint,
        status = SessionSwitcherStatus.CONNECTED,
        isCurrent = false,
        lastTouchedEpochMilliseconds = lastTouched,
        paneTitle = paneTitle,
    )

    private val editWindow = window(
        id = 1,
        index = 0,
        title = "0:edit",
        panes = listOf(
            SessionSwitcherPane(id = 11, title = "nvim", command = "nvim"),
            SessionSwitcherPane(id = 12, title = "pytest", command = "pytest"),
        ),
    )
    private val logsWindow = window(
        id = 2,
        index = 1,
        title = "1:logs",
        panes = listOf(SessionSwitcherPane(id = 21, title = "journalctl", command = "journalctl")),
    )

    @Test
    fun `an empty query lists home, every window, and every session`() {
        val results = SessionSwitcherEntries.results(
            query = "",
            windows = listOf(editWindow, logsWindow),
            sessions = listOf(session("relay"), session("builder")),
        )

        assertEquals(listOf(SessionSwitcherEntry.Home), results.home)
        assertEquals(
            listOf("0:edit", "%11", "%12", "1:logs"),
            results.tmux.map(::label),
        )
        assertEquals(listOf("relay", "builder"), results.sessions.map { it.hostId })
    }

    @Test
    fun `a single-pane window does not repeat itself as a pane row`() {
        val results = SessionSwitcherEntries.tmux(query = "", windows = listOf(logsWindow))

        assertEquals(listOf("1:logs"), results.map(::label))
    }

    @Test
    fun `a pane match carries its window even when the window label does not match`() {
        val results = SessionSwitcherEntries.tmux(
            query = "pytest",
            windows = listOf(editWindow, logsWindow),
        )

        // The window row is the context for the matching pane, and only the
        // matching pane is listed under it.
        assertEquals(listOf("0:edit", "%12"), results.map(::label))
    }

    @Test
    fun `a window match carries all of its panes`() {
        val results = SessionSwitcherEntries.tmux(
            query = "edit",
            windows = listOf(editWindow, logsWindow),
        )

        assertEquals(listOf("0:edit", "%11", "%12"), results.map(::label))
    }

    @Test
    fun `a pane is reachable by its tmux id`() {
        val results = SessionSwitcherEntries.tmux(
            query = "%12",
            windows = listOf(editWindow, logsWindow),
        )

        assertEquals(listOf("0:edit", "%12"), results.map(::label))
    }

    @Test
    fun `home answers to either of its words and disappears otherwise`() {
        assertEquals(1, SessionSwitcherEntries.home("hosts", includesHome = true).size)
        assertEquals(1, SessionSwitcherEntries.home("HOME", includesHome = true).size)
        assertEquals(0, SessionSwitcherEntries.home("nvim", includesHome = true).size)
        assertEquals(0, SessionSwitcherEntries.home("", includesHome = false).size)
    }

    @Test
    fun `sessions match on name, endpoint, and the attached window label`() {
        val sessions = listOf(
            session("relay", title = "orbital-relay"),
            session("builder", endpoint = "ci@builder.example.net:22"),
            session("archive", paneTitle = "restore"),
        )

        assertEquals(
            listOf("relay"),
            SessionSwitcherEntries.sessions("orbital", sessions).map { it.hostId },
        )
        assertEquals(
            listOf("builder"),
            SessionSwitcherEntries.sessions("ci@", sessions).map { it.hostId },
        )
        assertEquals(
            listOf("archive"),
            SessionSwitcherEntries.sessions("restore", sessions).map { it.hostId },
        )
    }

    @Test
    fun `sessions sort by last visit, with never-visited ones tailing in open order`() {
        val sessions = listOf(
            session("first-opened"),
            session("older", lastTouched = 100),
            session("second-opened"),
            session("newest", lastTouched = 900),
        )

        assertEquals(
            listOf("newest", "older", "first-opened", "second-opened"),
            SessionSwitcherEntries.sessions("", sessions).map { it.hostId },
        )
    }

    @Test
    fun `filtering is case-insensitive and ignores surrounding space`() {
        val results = SessionSwitcherEntries.results(
            query = "  NVIM ",
            windows = listOf(editWindow, logsWindow),
            sessions = listOf(session("relay")),
        )

        assertEquals(listOf("0:edit", "%11"), results.tmux.map(::label))
        assertTrue(results.sessions.isEmpty())
        assertTrue(results.home.isEmpty())
    }

    @Test
    fun `a query matching nothing reports an empty result set`() {
        val results = SessionSwitcherEntries.results(
            query = "zzz",
            windows = listOf(editWindow),
            sessions = listOf(session("relay")),
        )

        assertTrue(results.isEmpty)
    }

    @Test
    fun `a snapshot projects window labels, rename seeds, and pane titles`() {
        val snapshot = SharedTmuxSnapshot(
            sessionName = "orbital",
            activeWindowId = 7,
            windows = listOf(
                SharedTmuxWindow(
                    id = 7,
                    index = 3,
                    name = "build",
                    activePaneId = 70,
                    panes = listOf(
                        // A renamed pane keeps its own title…
                        SharedTmuxPane(
                            id = 70,
                            title = "watcher",
                            currentCommand = "cargo",
                            active = true,
                            titleIsDefault = false,
                        ),
                        // …while tmux's host-derived default gives way to the
                        // running command, which is what tells the panes apart.
                        SharedTmuxPane(
                            id = 71,
                            title = "relay.example.net",
                            currentCommand = "htop",
                            active = false,
                            titleIsDefault = true,
                        ),
                        // No command either: the window's own label is the last
                        // resort, never the machine name.
                        SharedTmuxPane(
                            id = 72,
                            title = "relay.example.net",
                            currentCommand = null,
                            active = false,
                            titleIsDefault = true,
                        ),
                    ),
                    zoomed = true,
                    layout = SharedTmuxLayoutNode.Leaf(paneId = 70, width = 80, height = 24),
                    displayName = "cargo watch",
                ),
            ),
            authority = SharedTmuxGridAuthoritySnapshot.Mine(generation = 1),
            revision = 4,
            rawJson = ByteArray(0),
        )

        val projected = snapshot.switcherWindows().single()

        assertEquals("1:cargo watch", projected.title)
        assertEquals(1, projected.position)
        assertEquals(3, projected.index)
        // Seeded from #{window_name}, never from the live pane title, or a
        // rename would bake "cargo watch" in as the window's name everywhere.
        assertEquals("build", projected.renameSeed)
        assertTrue(projected.zoomed)
        assertEquals(listOf("watcher", "htop", "cargo watch"), projected.panes.map { it.title })
        assertEquals(listOf("cargo", "htop", null), projected.panes.map { it.command })
    }

    @Test
    fun `verified agent replaces wrapper command but explicit pane title wins`() {
        val window = agentWindow()
        assertEquals("claude", window.switcherPaneTitle(70) { "claude" })
        assertEquals("sh", window.switcherPaneTitle(70))
        assertEquals("sh", window.switcherPaneTitle(70) { null }) // absent or ambiguous
        assertEquals("My work", window.copy(panes = listOf(window.panes.single().copy(
            title = "  My work  ", titleIsDefault = false,
        ))).switcherPaneTitle(70) { "codex" })
        assertEquals("codex", window.copy(panes = listOf(window.panes.single().copy(
            title = " ", titleIsDefault = false,
        ))).switcherPaneTitle(70) { "codex" })
        assertEquals("shell", window.copy(panes = listOf(window.panes.single().copy(
            currentCommand = null,
        ))).switcherPaneTitle(70))
    }

    @Test
    fun `window label uses explicit active title then active provider then display name`() {
        val window = agentWindow()
        val snapshot = SharedTmuxSnapshot(
            sessionName = "session", activeWindowId = 7, windows = listOf(window),
            authority = SharedTmuxGridAuthoritySnapshot.Mine(generation = 1),
            revision = 1, rawJson = ByteArray(0),
        )
        val projected = snapshot.switcherWindows { if (it == 70) "claude" else null }.single()
        assertEquals("1:claude", projected.title)
        assertEquals("claude", projected.panes.single().title)
        assertEquals("shell", projected.renameSeed)
        assertEquals("1:shell", snapshot.switcherWindows { null }.single().title)
        assertEquals("1:Custom", snapshot.copy(windows = listOf(window.copy(
            activePaneTitle = "  Custom  ", activePaneTitleIsDefault = false,
        ))).switcherWindows { "claude" }.single().title)
        assertEquals("1:codex", snapshot.copy(windows = listOf(window.copy(
            activePaneId = null, activePaneTitle = " ", activePaneTitleIsDefault = false,
        ))).switcherWindows { "codex" }.single().title)
        assertEquals("1:shell", snapshot.copy(windows = listOf(window.copy(
            activePaneId = null, panes = listOf(window.panes.single().copy(active = false)),
        ))).switcherWindows { "claude" }.single().title)
    }

    private fun agentWindow() = SharedTmuxWindow(
        id = 7, index = 3, name = "shell", activePaneId = 70,
        panes = listOf(SharedTmuxPane(
            id = 70, title = "relay.example.net", titleIsDefault = true,
            currentCommand = "sh", active = true,
        )),
        zoomed = false, layout = null,
        activePaneTitle = "relay.example.net", activePaneTitleIsDefault = true,
        displayName = "shell",
    )

    private fun label(entry: SessionSwitcherEntry): String = when (entry) {
        is SessionSwitcherEntry.Window -> entry.window.title
        is SessionSwitcherEntry.Pane -> "%${entry.pane.id}"
        is SessionSwitcherEntry.Session -> entry.session.hostId
        SessionSwitcherEntry.Home -> "home"
    }
}
