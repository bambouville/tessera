package com.bambouville.tessera.feature.agentcenter

import androidx.compose.foundation.text.contextmenu.builder.TextContextMenuBuilderScope
import androidx.compose.foundation.text.contextmenu.builder.item
import androidx.compose.foundation.text.contextmenu.modifier.appendTextContextMenuComponents
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.selection.SelectionState
import androidx.compose.foundation.text.selection.rememberSelectionState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import com.bambouville.tessera.core.bridge.SharedArtifacts
import com.bambouville.tessera.core.bridge.SharedArtifactsLinkClass
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.design.ArtifactOpener
import com.bambouville.tessera.files.RemoteSelectionPathResolver
import com.bambouville.tessera.files.SelectedArtifactLinkRoute
import com.bambouville.tessera.files.SelectedArtifactLinks

/** A transcript path action, carried out by the thread's bound session. */
enum class AgentSelectionPathAction { OpenInArtifacts, RevealInFiles }

/** What the transcript menu knows about the thread a selection came from. */
internal data class AgentSelectionContext(
    val hostId: String,
    /** The thread's bound live session; null when the thread is not bound. */
    val liveSessionId: String?,
    /** That session's transport is connected right now. */
    val sessionConnected: Boolean,
    val openerAvailable: Boolean,
)

/** The items one selection adds after Copy and Select all, which it never touches. */
internal sealed interface AgentSelectionMenu {
    data object None : AgentSelectionMenu
    /** A port on the thread host's own loopback: Open in Artifacts, never Reveal. */
    data class Link(val request: ArtifactOpenRequest.Page) : AgentSelectionMenu
    /** A plausible remote path, read with the terminal's own candidate logic. */
    data class Path(val open: Boolean, val reveal: Boolean) : AgentSelectionMenu
}

/**
 * The terminal's selection menu, read for a transcript: the shared link
 * classifier first, then the terminal's path gate. Unlike the terminal, a URL
 * the classifier recognises but cannot open (external, refused) offers
 * nothing — transcript prose is full of links, and both path actions would
 * only miss on one. Reveal needs the bound session connected; nothing here
 * ever connects one.
 */
internal fun agentSelectionMenu(
    selection: String,
    context: AgentSelectionContext,
    classifyLink: (String) -> SharedArtifactsLinkClass = SharedArtifacts::classifyLink,
    isPlausiblePath: (String) -> Boolean = RemoteSelectionPathResolver::isPlausiblePath,
): AgentSelectionMenu {
    val trimmed = selection.trim()
    // A paragraph never reaches the native classifier: no link or path is this long.
    if (trimmed.isEmpty() || trimmed.length > MAX_ACTIONABLE_SELECTION || context.hostId.isBlank()) {
        return AgentSelectionMenu.None
    }
    // A menu must open even if the classifier cannot answer; it then adds nothing.
    val link = runCatching { classifyLink(trimmed) }.getOrNull() ?: return AgentSelectionMenu.None
    when (link) {
        is SharedArtifactsLinkClass.RemoteLoopback -> {
            val route = SelectedArtifactLinks.route(trimmed, context.hostId, context.liveSessionId, context.openerAvailable) { link }
            return if (route is SelectedArtifactLinkRoute.Page) AgentSelectionMenu.Link(route.request) else AgentSelectionMenu.None
        }
        SharedArtifactsLinkClass.External, SharedArtifactsLinkClass.Refused -> return AgentSelectionMenu.None
        SharedArtifactsLinkClass.Unsupported -> Unit
    }
    if (!isPlausiblePath(selection)) return AgentSelectionMenu.None
    val reveal = context.sessionConnected && context.liveSessionId != null
    return if (context.openerAvailable || reveal) AgentSelectionMenu.Path(context.openerAvailable, reveal) else AgentSelectionMenu.None
}

/** Open in Artifacts on a path with no connected bound session. */
internal sealed interface AgentHostLevelPathOpen {
    /** A host tab; it loads only over a Files channel that is already live. */
    data class Open(val request: ArtifactOpenRequest.File) : AgentHostLevelPathOpen
    /** The terminal's miss: nothing anchors a home-relative or relative path. */
    data class Miss(val message: String) : AgentHostLevelPathOpen
}

internal fun agentHostLevelPathOpen(selection: String, hostId: String, sessionHint: String?): AgentHostLevelPathOpen {
    RemoteSelectionPathResolver.absoluteCandidate(selection)?.let { path ->
        return AgentHostLevelPathOpen.Open(ArtifactOpenRequest.File(hostId, path, ArtifactOpenOrigin.TerminalSelection, sessionHint))
    }
    val candidate = RemoteSelectionPathResolver.pathCandidates(selection).firstOrNull() ?: selection.trim()
    return AgentHostLevelPathOpen.Miss(RemoteSelectionPathResolver.noDirectoryMessage(candidate))
}

/**
 * App wiring for transcript selections. Both lambdas run when a menu opens or
 * an item is chosen, never during composition, so they read current state.
 */
internal class AgentTranscriptSelectionActions(
    /** The thread's bound live session is connected right now. */
    val isSessionConnected: (AgentThreadDetail) -> Boolean,
    /** Hands a path to that session; the session reports any miss itself. */
    val onPathAction: (AgentThreadDetail, AgentSelectionPathAction, String) -> Unit,
    val onMiss: (String) -> Unit,
    /** The bound session went away between the menu and the tap. */
    val onSessionUnavailable: () -> Unit,
)

/** One transcript's view of [AgentTranscriptSelectionActions], for the thread on screen. */
internal class AgentTranscriptSelectionScope(
    private val actions: AgentTranscriptSelectionActions,
    private val detail: () -> AgentThreadDetail,
    private val opener: ArtifactOpener?,
    /** Leaves the composer before another screen comes up, as an edit card's "open as a tab" does. */
    private val beforeLeaving: () -> Unit,
) {
    fun menu(selection: String): AgentSelectionMenu {
        val thread = detail()
        return agentSelectionMenu(selection, AgentSelectionContext(
            hostId = thread.row.hostID,
            liveSessionId = thread.liveSessionID(),
            sessionConnected = actions.isSessionConnected(thread),
            openerAvailable = opener != null,
        ))
    }

    fun openLink(request: ArtifactOpenRequest.Page) {
        val opener = opener ?: return
        beforeLeaving()
        opener.open(request)
    }

    fun openPath(selection: String) {
        val thread = detail()
        if (thread.liveSessionID() != null && actions.isSessionConnected(thread)) {
            beforeLeaving()
            actions.onPathAction(thread, AgentSelectionPathAction.OpenInArtifacts, selection)
            return
        }
        val opener = opener ?: return
        when (val open = agentHostLevelPathOpen(selection, thread.row.hostID, thread.liveSessionID())) {
            is AgentHostLevelPathOpen.Open -> {
                beforeLeaving()
                opener.open(open.request)
            }
            is AgentHostLevelPathOpen.Miss -> actions.onMiss(open.message)
        }
    }

    fun revealPath(selection: String) {
        val thread = detail()
        if (thread.liveSessionID() == null || !actions.isSessionConnected(thread)) {
            actions.onSessionUnavailable()
            return
        }
        actions.onPathAction(thread, AgentSelectionPathAction.RevealInFiles, selection)
    }
}

/** Provided around the transcript list only: no other text menu gains items. */
internal val LocalAgentTranscriptSelection = compositionLocalOf<AgentTranscriptSelectionScope?> { null }

/** Copy's own text: every selected text in layout order, joined as Copy joins them. */
internal fun SelectionState.joinedSelectedText(): String = selectedTexts.joinToString("\n") { it.text }

private object AgentSelectionOpenKey
private object AgentSelectionRevealKey

private fun TextContextMenuBuilderScope.agentSelectionItems(
    scope: AgentTranscriptSelectionScope,
    selection: String,
    openLabel: String,
    revealLabel: String,
) {
    when (val menu = scope.menu(selection)) {
        AgentSelectionMenu.None -> Unit
        is AgentSelectionMenu.Link -> {
            separator()
            item(AgentSelectionOpenKey, openLabel) { close(); scope.openLink(menu.request) }
        }
        is AgentSelectionMenu.Path -> {
            separator()
            if (menu.open) item(AgentSelectionOpenKey, openLabel) { close(); scope.openPath(selection) }
            if (menu.reveal) item(AgentSelectionRevealKey, revealLabel) { close(); scope.revealPath(selection) }
        }
    }
}

/**
 * A transcript `SelectionContainer` whose long-press toolbar and right-click
 * menu gain the terminal's selection items. Outside a transcript it is a
 * plain `SelectionContainer`. The selected text is read from the container's
 * own state when the menu is built; the clipboard is never involved.
 */
@Composable
internal fun AgentTranscriptSelectionContainer(content: @Composable () -> Unit) {
    val scope = LocalAgentTranscriptSelection.current
    val state = rememberSelectionState()
    val openLabel = stringResource(R.string.agent_selection_open_in_artifacts)
    val revealLabel = stringResource(R.string.agent_selection_reveal_in_files)
    val modifier = remember(scope, state, openLabel, revealLabel) {
        if (scope == null) Modifier
        else Modifier.appendTextContextMenuComponents {
            agentSelectionItems(scope, state.joinedSelectedText(), openLabel, revealLabel)
        }
    }
    SelectionContainer(state, modifier, content)
}

/** Longer than any path the terminal's gate accepts or any link worth opening. */
private const val MAX_ACTIONABLE_SELECTION = 8_192
