package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxWindow

/**
 * The top bar's session-name target: everywhere this client can jump to from a
 * live terminal.
 *
 * The switcher used to offer only the attached tmux session's windows and panes,
 * which left the other live host sessions reachable only by backing out to the
 * tab bar. It now lists the same three groups iOS's compact palette does —
 * hosts home, this session's tmux targets, then every live host session — so one
 * tap on the session name reaches any of them.
 *
 * This file is the pure half: filtering, ordering, and the labels each row
 * reads. It mirrors `Tessera/Navigation/CommandPalette.swift` rule for rule, so
 * a query that surfaces a target on the iPhone surfaces the same target here.
 * Keeping it free of Compose is what lets those rules be tested directly.
 */

/** Connection tone for a session row's status dot. */
enum class SessionSwitcherStatus {
    CONNECTED,
    PENDING,
    FAILED,
    IDLE,
}

/**
 * One live host session, as the switcher reads it.
 *
 * [paneTitle] is the attached tmux window's label. Only the session doing the
 * asking knows its own — the others are mounted but not observed from here — so
 * it is populated for the current row and null for the rest, exactly as iOS
 * passes a single-entry `paneTitles` map.
 */
data class SessionSwitcherSession(
    val hostId: String,
    val title: String,
    /** `user@host:port`, matched by the query the way iOS matches `hostKey`. */
    val endpoint: String,
    val status: SessionSwitcherStatus,
    val isCurrent: Boolean,
    val unread: Boolean = false,
    val lastTouchedEpochMilliseconds: Long? = null,
    val paneTitle: String? = null,
    val programAttention: ProgramAttentionCounts? = null,
)

data class SessionSwitcherPane(
    val id: Int,
    val title: String,
    val command: String?,
)

data class SessionSwitcherWindow(
    val id: Int,
    val index: Int?,
    /** One-based position in the ordered snapshot; this is the visible shortcut number. */
    val position: Int,
    /**
     * What the row reads: its one-based position plus the live display name.
     * The server index remains separate because gaps and a non-default base
     * index must not change the position users see and reorder.
     */
    val title: String,
    /**
     * What the rename field starts from — tmux's own `#{window_name}`, not
     * [title]. Renaming sets `window_name` and disables `automatic-rename`, so
     * seeding it with the active pane's OSC title bakes "vim README" in as the
     * window's name for every attached client. iOS seeds the same value.
     */
    val renameSeed: String,
    val panes: List<SessionSwitcherPane>,
    val zoomed: Boolean,
    val splitTargetReady: Boolean = false,
)

sealed interface SessionSwitcherEntry {
    data object Home : SessionSwitcherEntry

    data class Window(val window: SessionSwitcherWindow) : SessionSwitcherEntry

    data class Pane(
        val window: SessionSwitcherWindow,
        val pane: SessionSwitcherPane,
    ) : SessionSwitcherEntry

    data class Session(val session: SessionSwitcherSession) : SessionSwitcherEntry
}

/** The three filtered groups, kept apart so the sheet can head each section. */
data class SessionSwitcherResults(
    val home: List<SessionSwitcherEntry>,
    val tmux: List<SessionSwitcherEntry>,
    val sessions: List<SessionSwitcherSession>,
) {
    val isEmpty: Boolean
        get() = home.isEmpty() && tmux.isEmpty() && sessions.isEmpty()
}

object SessionSwitcherEntries {
    /**
     * The home row answers to either word, so "hosts" and "home" both reach it.
     * iOS matches the same haystack.
     */
    private const val HOME_HAYSTACK = "hosts home"

    fun results(
        query: String,
        windows: List<SessionSwitcherWindow>,
        sessions: List<SessionSwitcherSession>,
        includesHome: Boolean = true,
    ): SessionSwitcherResults = SessionSwitcherResults(
        home = home(query, includesHome),
        tmux = tmux(query, windows),
        sessions = sessions(query, sessions),
    )

    fun home(query: String, includesHome: Boolean): List<SessionSwitcherEntry> {
        if (!includesHome) return emptyList()
        val needle = query.needle()
        return if (needle.isEmpty() || HOME_HAYSTACK.contains(needle)) {
            listOf(SessionSwitcherEntry.Home)
        } else {
            emptyList()
        }
    }

    /**
     * Windows, each followed by its panes.
     *
     * A window whose own label matches carries all of its panes; a window whose
     * label does not still appears when one of its panes matches, so a search for
     * a command finds the window it is running in. Panes are listed only for a
     * split window — a single-pane window and its one pane are the same target,
     * and listing both would double every row.
     */
    fun tmux(
        query: String,
        windows: List<SessionSwitcherWindow>,
    ): List<SessionSwitcherEntry> {
        val needle = query.needle()
        return windows.flatMap { window ->
            val windowMatches = needle.isEmpty() || window.title.matches(needle)
            val matchingPanes = window.panes.filter { pane ->
                windowMatches ||
                    pane.title.matches(needle) ||
                    pane.command?.matches(needle) == true ||
                    "%${pane.id}".matches(needle)
            }
            if (!windowMatches && matchingPanes.isEmpty()) return@flatMap emptyList()
            buildList {
                add(SessionSwitcherEntry.Window(window))
                if (window.panes.size > 1) {
                    matchingPanes.forEach { add(SessionSwitcherEntry.Pane(window, it)) }
                }
            }
        }
    }

    /**
     * Live sessions, most recently visited first.
     *
     * Sessions never yet visited have no timestamp and tail the list in the order
     * they were opened, so connecting a new host does not bury the one the user
     * has been working in.
     */
    fun sessions(
        query: String,
        sessions: List<SessionSwitcherSession>,
    ): List<SessionSwitcherSession> {
        val needle = query.needle()
        return sessions
            .filter { session ->
                needle.isEmpty() ||
                    session.title.matches(needle) ||
                    session.endpoint.matches(needle) ||
                    session.paneTitle?.matches(needle) == true
            }
            // Kotlin's sort is stable, so equal keys — and every untouched
            // session shares one — keep their incoming order.
            .sortedWith(
                compareByDescending<SessionSwitcherSession> {
                    it.lastTouchedEpochMilliseconds != null
                }.thenByDescending { it.lastTouchedEpochMilliseconds ?: 0L },
            )
    }

    private fun String.needle(): String = trim().lowercase()

    private fun String.matches(needle: String): Boolean =
        needle.isEmpty() || lowercase().contains(needle)
}

/**
 * The label a pane row reads.
 *
 * tmux hands out a host-derived default title for a pane nothing has renamed,
 * which names the machine rather than the pane and is identical for every pane
 * in the window. A verified Agent Center provider precedes the wrapper command,
 * which may only be `sh`. Match iOS CommandPaletteTmuxSnapshot precedence.
 */
internal fun SharedTmuxWindow.switcherPaneTitle(
    paneId: Int,
    agentProvider: (paneId: Int) -> String? = { null },
): String {
    val pane = panes.firstOrNull { it.id == paneId }
    val title = pane?.title?.trim()
    if (pane?.titleIsDefault == false && !title.isNullOrEmpty()) return title
    agentProvider(paneId)?.let { return it }
    pane?.currentCommand?.takeIf { it.isNotBlank() }?.let { return it }
    return displayName
}

/** Projects the live snapshot onto the switcher's own value types. */
internal fun SharedTmuxSnapshot.switcherWindows(
    agentProvider: (paneId: Int) -> String? = { null },
): List<SessionSwitcherWindow> =
    windows.mapIndexed { ordinal, window ->
        val activePaneId = window.activePaneId ?: window.panes.firstOrNull { it.active }?.id
        val title = window.activePaneTitle?.trim()?.takeIf {
            !window.activePaneTitleIsDefault && it.isNotEmpty()
        } ?: activePaneId?.let(agentProvider) ?: window.displayName
        SessionSwitcherWindow(
            id = window.id,
            index = window.index,
            position = ordinal + 1,
            title = "${ordinal + 1}:$title",
            renameSeed = window.name.orEmpty(),
            panes = window.panes.map { pane ->
                SessionSwitcherPane(
                    id = pane.id,
                    title = window.switcherPaneTitle(pane.id, agentProvider),
                    command = pane.currentCommand?.takeIf { it.isNotBlank() },
                )
            },
            zoomed = window.zoomed,
            splitTargetReady = isWindowListHydrated && tmuxWindowSplitTargetPane(window) != null,
        )
    }
