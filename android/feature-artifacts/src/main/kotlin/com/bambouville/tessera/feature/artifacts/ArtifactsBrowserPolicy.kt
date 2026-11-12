package com.bambouville.tessera.feature.artifacts

import android.view.KeyEvent
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsQuickOpenIntent
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestion
import com.bambouville.tessera.core.bridge.SharedArtifactsSuggestionKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import java.io.File

// Browser policy with no Compose or Android framework state, so JVM tests own it.

/** Where typed or picked input goes: a new tab, or the address bar's own tab. */
sealed interface ArtifactOpenPlacement {
    data object NewTab : ArtifactOpenPlacement
    data class Navigate(val tabId: String) : ArtifactOpenPlacement
}

/**
 * The browser's chrome at one moment. Exactly one new-tab control and at
 * most one way back to the overview are visible: the overview's + is the
 * only + (a tab on a phone reaches new tab from its menu, Ctrl+T, or the
 * overview), and the overview pane beside a wide tab is its own overview.
 */
internal data class ArtifactsChrome(
    val overview: Boolean,
    val overviewNewTab: Boolean,
    val overviewBack: Boolean,
    val menuNewTab: Boolean,
    /** Back, forward, the address field and reload share the top toolbar row. */
    val toolbarHistory: Boolean,
    /** A phone keeps page history and reload in its bottom bar, within reach of a thumb. */
    val bottomHistory: Boolean,
) {
    val visibleNewTabControls: Int get() = listOf(overviewNewTab).count { it }
    val visibleOverviewControls: Int get() = listOf(overviewBack).count { it }
}

internal fun artifactsChrome(wide: Boolean, tabShown: Boolean): ArtifactsChrome {
    val overview = wide || !tabShown
    return ArtifactsChrome(
        overview = overview,
        overviewNewTab = overview,
        overviewBack = !wide && tabShown,
        menuNewTab = !overview,
        toolbarHistory = wide && tabShown,
        bottomHistory = !wide && tabShown,
    )
}

/**
 * The text the address bar shows and edits: `localhost:8001/laptop.html` for
 * a page (an https page keeps its scheme so editing round-trips), and
 * `host:path` for a file or change. A forwarded page shows where its viewer
 * is now, which in-page links may have moved from the tab's target.
 */
internal fun artifactAddressText(tab: SharedArtifactTab, webUrl: String? = null): String = when (val target = tab.target) {
    is SharedArtifactsTarget.Page -> {
        val path = webUrl?.let(::artifactPagePathOf) ?: target.path.ifEmpty { "/" }
        if (target.scheme == "https") "https://localhost:${target.port}$path" else "localhost:${target.port}$path"
    }
    else -> "${tab.hostLabel}:${target.path}"
}

/** The path, query and fragment of a loaded http(s) URL; null for anything else. */
internal fun artifactPagePathOf(url: String): String? {
    val schemeEnd = url.indexOf("://")
    if (schemeEnd <= 0 || url.substring(0, schemeEnd).lowercase() !in setOf("http", "https")) return null
    val authorityEnd = url.indexOfAny(charArrayOf('/', '?', '#'), schemeEnd + 3).let { if (it < 0) url.length else it }
    val rest = url.substring(authorityEnd)
    return if (rest.startsWith('/')) rest else "/$rest"
}

/** The same forwarded origin at another path, query and fragment. */
internal fun artifactRebasedPageUrl(url: String, path: String): String {
    val schemeEnd = url.indexOf("://")
    if (schemeEnd <= 0) return url
    val authorityEnd = url.indexOfAny(charArrayOf('/', '?', '#'), schemeEnd + 3).let { if (it < 0) url.length else it }
    return url.substring(0, authorityEnd) + (if (path.startsWith('/')) path else "/$path")
}

/** Return on a tab retargets it when it can show the new target on its own host. */
internal fun artifactNavigatesInPlace(tab: SharedArtifactTab, hostId: String, toChange: Boolean): Boolean =
    tab.hostId == hostId && tab.target !is SharedArtifactsTarget.Change && !toChange

/** An address edit starts with the whole shown address selected, so typing replaces it. */
internal data class ArtifactAddressEdit(val text: String, val selectionStart: Int, val selectionEnd: Int)

internal fun artifactAddressEditStart(address: String): ArtifactAddressEdit = ArtifactAddressEdit(address, 0, address.length)

/** What picking a suggestion does. An open tab is a "switch to tab" row; everything else opens. */
internal sealed interface ArtifactSuggestionChoice {
    data class SwitchTo(val tabId: String) : ArtifactSuggestionChoice
    data class Open(val input: String, val hostId: String) : ArtifactSuggestionChoice
    data class Search(val text: String) : ArtifactSuggestionChoice
    data class Invalid(val reason: String) : ArtifactSuggestionChoice
}

internal fun artifactSuggestionChoice(suggestion: SharedArtifactsSuggestion): ArtifactSuggestionChoice {
    val tabId = suggestion.tabId
    if (tabId != null && (suggestion.kind == SharedArtifactsSuggestionKind.OpenTab || suggestion.intent !is SharedArtifactsQuickOpenIntent.Page)) {
        return ArtifactSuggestionChoice.SwitchTo(tabId)
    }
    return when (val intent = suggestion.intent) {
        is SharedArtifactsQuickOpenIntent.File -> ArtifactSuggestionChoice.Open(intent.path, intent.hostId)
        is SharedArtifactsQuickOpenIntent.Directory -> ArtifactSuggestionChoice.Open(intent.path.trimEnd('/') + "/", intent.hostId)
        is SharedArtifactsQuickOpenIntent.Page -> ArtifactSuggestionChoice.Open(
            artifactQuickOpenInput(intent.path, intent.scheme, intent.port), intent.hostId,
        )
        is SharedArtifactsQuickOpenIntent.Search -> ArtifactSuggestionChoice.Search(intent.text)
        is SharedArtifactsQuickOpenIntent.Invalid -> ArtifactSuggestionChoice.Invalid(intent.reason)
    }
}

/** Suggestions while editing [tabId]'s address: switching to the tab being edited is no choice. */
internal fun artifactEditingSuggestions(suggestions: List<SharedArtifactsSuggestion>, tabId: String?): List<SharedArtifactsSuggestion> =
    if (tabId == null) suggestions else suggestions.filterNot { it.kind == SharedArtifactsSuggestionKind.OpenTab && it.tabId == tabId }

/** A closed tab, as Ctrl+Shift+T reopens it. */
internal data class ArtifactClosedTab(
    val hostId: String, val target: SharedArtifactsTarget, val title: String,
    val origin: String, val sessionHint: String?, val pinned: Boolean,
)

/** The process's recently closed tabs, newest last; small and in memory, like a browser's. */
internal class ArtifactClosedTabs(private val capacity: Int = 16) {
    private val entries = ArrayDeque<ArtifactClosedTab>()
    val size: Int get() = entries.size

    fun push(tab: SharedArtifactTab) {
        entries.addLast(ArtifactClosedTab(tab.hostId, tab.target, tab.title, tab.origin, tab.sessionHint, tab.pinned))
        while (entries.size > capacity) entries.removeFirst()
    }

    fun pop(): ArtifactClosedTab? = entries.removeLastOrNull()

    /** A removed host's tabs cannot come back. */
    fun retainHosts(hostIds: Set<String>) { entries.removeAll { it.hostId !in hostIds } }
}

/**
 * Keyboard tab order is the order tabs were opened, as in a tab strip. The
 * overview lists tabs by recency, which would make next and previous swap
 * between the same two tabs.
 */
internal fun artifactAdjacentTab(tabIds: List<String>, currentId: String?, offset: Int): String? {
    if (tabIds.isEmpty()) return null
    val index = tabIds.indexOf(currentId)
    if (index < 0) return if (offset >= 0) tabIds.first() else tabIds.last()
    return tabIds[Math.floorMod(index + offset, tabIds.size)]
}

/** Ctrl+1 to Ctrl+8 pick that tab when it exists; Ctrl+9 is always the last tab. */
internal fun artifactNumberedTab(tabIds: List<String>, shortcut: ArtifactsShortcut): String? = when (shortcut) {
    is ArtifactsShortcut.SelectTab -> tabIds.getOrNull(shortcut.index)
    ArtifactsShortcut.LastTab -> tabIds.lastOrNull()
    else -> null
}

/** The browser's hardware-keyboard commands, with Chrome for Android's keys. */
sealed interface ArtifactsShortcut {
    data object NewTab : ArtifactsShortcut
    data object EditAddress : ArtifactsShortcut
    data object Reload : ArtifactsShortcut
    data object Back : ArtifactsShortcut
    data object Forward : ArtifactsShortcut
    data object CloseTab : ArtifactsShortcut
    data object ReopenClosedTab : ArtifactsShortcut
    data object PreviousTab : ArtifactsShortcut
    data object NextTab : ArtifactsShortcut
    data class SelectTab(val index: Int) : ArtifactsShortcut
    data object LastTab : ArtifactsShortcut
    data object Overview : ArtifactsShortcut
}

/**
 * Maps a key-down to a browser command. Ctrl is the command modifier, with
 * Meta accepted as Agent Center does. The browser is its own root tab, so a
 * terminal is never focused beside it and plain Ctrl is free here.
 * [textFocused] means a text field in the browser has focus: Alt+arrows then
 * stay with the field.
 */
internal fun artifactsShortcut(
    keyCode: Int, ctrl: Boolean, shift: Boolean, alt: Boolean, meta: Boolean, textFocused: Boolean = false,
): ArtifactsShortcut? {
    val command = ctrl || meta
    if (command && !alt) {
        when (keyCode) {
            KeyEvent.KEYCODE_T -> return if (shift) ArtifactsShortcut.ReopenClosedTab else ArtifactsShortcut.NewTab
            KeyEvent.KEYCODE_L -> return if (shift) null else ArtifactsShortcut.EditAddress
            KeyEvent.KEYCODE_R -> return ArtifactsShortcut.Reload
            KeyEvent.KEYCODE_W, KeyEvent.KEYCODE_F4 -> return if (shift) null else ArtifactsShortcut.CloseTab
            KeyEvent.KEYCODE_TAB -> return if (shift) ArtifactsShortcut.PreviousTab else ArtifactsShortcut.NextTab
            KeyEvent.KEYCODE_PAGE_DOWN -> return if (shift) null else ArtifactsShortcut.NextTab
            KeyEvent.KEYCODE_PAGE_UP -> return if (shift) null else ArtifactsShortcut.PreviousTab
            KeyEvent.KEYCODE_BACKSLASH -> return if (shift) ArtifactsShortcut.Overview else null
        }
        if (!shift && keyCode in KeyEvent.KEYCODE_1..KeyEvent.KEYCODE_8) return ArtifactsShortcut.SelectTab(keyCode - KeyEvent.KEYCODE_1)
        if (!shift && keyCode == KeyEvent.KEYCODE_9) return ArtifactsShortcut.LastTab
        return null
    }
    if (alt && !command && !shift && !meta) {
        when (keyCode) {
            KeyEvent.KEYCODE_D -> return ArtifactsShortcut.EditAddress
            KeyEvent.KEYCODE_DPAD_LEFT -> return if (textFocused) null else ArtifactsShortcut.Back
            KeyEvent.KEYCODE_DPAD_RIGHT -> return if (textFocused) null else ArtifactsShortcut.Forward
        }
        return null
    }
    if (!command && !alt && !meta) {
        when (keyCode) {
            KeyEvent.KEYCODE_F5 -> return ArtifactsShortcut.Reload
            KeyEvent.KEYCODE_REFRESH -> return ArtifactsShortcut.Reload
            KeyEvent.KEYCODE_F6 -> return if (shift) null else ArtifactsShortcut.EditAddress
            KeyEvent.KEYCODE_FORWARD -> return ArtifactsShortcut.Forward
        }
    }
    return null
}

/** What a tab's share control offers. A file is shared as itself; [Unavailable] keeps the control with its reason. */
internal sealed interface ArtifactShare {
    data class Ready(val file: File, val displayName: String) : ArtifactShare
    data class Unavailable(val reason: String) : ArtifactShare
}

/**
 * Files share their complete cached copy: documents, PDFs, images, other
 * files, and served HTML reports. A forwarded page has no file to send and a
 * friend could not reach its localhost URL, so it has no share control; nor
 * does a change, which is a diff rather than a file.
 */
internal fun artifactShare(tab: SharedArtifactTab, content: ArtifactContent, cached: ArtifactContent.Document?): ArtifactShare? {
    if (tab.target !is SharedArtifactsTarget.File) return null
    val name = tab.target.path.substringAfterLast('/').ifBlank { tab.title }
    return when (content) {
        is ArtifactContent.Document -> ArtifactShare.Ready(content.file, content.displayName.ifBlank { name })
        is ArtifactContent.ServedPage -> cached?.let { ArtifactShare.Ready(it.file, it.displayName.ifBlank { name }) }
            ?: ArtifactShare.Unavailable(ARTIFACT_SHARE_DOWNLOADING)
        ArtifactContent.Loading -> ArtifactShare.Unavailable(ARTIFACT_SHARE_DOWNLOADING)
        is ArtifactContent.Unavailable -> cached?.let { ArtifactShare.Ready(it.file, it.displayName.ifBlank { name }) }
            ?: ArtifactShare.Unavailable(if (content.reason is ArtifactUnavailable.TooLarge) ARTIFACT_SHARE_TOO_LARGE else ARTIFACT_SHARE_NOT_DOWNLOADED)
        is ArtifactContent.ForwardedPage, is ArtifactContent.Change -> null
    }
}

// Reason keys; the UI resolves them to localized strings.
internal const val ARTIFACT_SHARE_DOWNLOADING = "downloading"
internal const val ARTIFACT_SHARE_TOO_LARGE = "tooLarge"
internal const val ARTIFACT_SHARE_NOT_DOWNLOADED = "notDownloaded"
