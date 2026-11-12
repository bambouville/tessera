package com.bambouville.tessera.feature.artifacts

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.focusTarget
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraIcons
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

@Composable
fun ArtifactsRootScreen(modifier: Modifier = Modifier, locked: Boolean = false) {
    val store = LocalArtifactsStore.current
    if (store == null) {
        Box(modifier.fillMaxSize().background(LocalTesseraTokens.current.bg).imePadding().testTag("artifacts-page")) {
            if (!locked) ArtifactBrowserEmptyState(Modifier.fillMaxSize().testTag("artifacts-overview"))
        }
    } else {
        ArtifactsBrowser(remember(store) { LiveArtifactsUiStore(store) }, modifier, locked = locked)
    }
}

/** Which of the browser's text fields has focus, so Alt+arrows stay with a field's caret. */
internal class ArtifactTextFocus {
    private val focused = mutableSetOf<String>()
    val any: Boolean get() = focused.isNotEmpty()
    fun note(field: String, isFocused: Boolean) { if (isFocused) focused.add(field) else focused.remove(field) }
}

internal val LocalArtifactTextFocus = staticCompositionLocalOf<ArtifactTextFocus?> { null }

/** A narrow port lets the real browser run against a host-free debug store. */
@Composable
internal fun ArtifactsBrowser(
    store: ArtifactsUiStore,
    modifier: Modifier = Modifier,
    initialQuickOpen: Boolean = false,
    locked: Boolean = false,
) {
    val state by store.state.collectAsStateWithLifecycle()
    val revision by store.revision.collectAsStateWithLifecycle()
    val lifecycleOwner = LocalLifecycleOwner.current
    val keyboard = LocalSoftwareKeyboardController.current
    val nowMillis by produceState(System.currentTimeMillis()) {
        while (isActive) {
            delay(60_000)
            value = System.currentTimeMillis()
        }
    }
    var query by rememberSaveable { mutableStateOf("") }
    var quickOpen by rememberSaveable { mutableStateOf(initialQuickOpen) }
    // The store holds the route, so leaving the Artifacts tab, which disposes
    // this screen, keeps it. Back only changes the route; the tab stays selected.
    val route = store.route
    val selected = state.tabs.firstOrNull { it.id == state.selectedId }
    LaunchedEffect(route, state.selectedId, selected?.viewedAt) { route.follow(state.selectedId, selected?.viewedAt) }
    val detail = state.tabs.firstOrNull { it.id == route.displayedId(state.selectedId, selected?.viewedAt) }
    // Hardware-keyboard shortcuts need focus inside the browser. When nothing
    // in it holds focus (after a tab opens, editing ends or a sheet closes),
    // the browser itself does, rather than nothing at all.
    val browserFocus = remember { FocusRequester() }
    val searchFocus = remember { FocusRequester() }
    val textFocus = remember { ArtifactTextFocus() }
    val commands = remember { ArtifactTabCommands() }
    val takeFocus: () -> Unit = { runCatching { browserFocus.requestFocus() } }

    CompositionLocalProvider(LocalArtifactsLocked provides locked, LocalArtifactTextFocus provides textFocus) { BoxWithConstraints(
        modifier.fillMaxSize().background(LocalTesseraTokens.current.bg)
            .imePadding().testTag("artifacts-page"),
    ) {
        // Width, rather than orientation, also covers split-screen and foldables.
        val wide = maxWidth >= 700.dp
        val listWidth = (maxWidth * 0.4f).coerceIn(300.dp, 400.dp)
        val displayed = detail
        val overviewShown = wide || displayed == null
        // The page stays under the lock overlay, so unlocking keeps its web
        // history; only following pauses.
        LaunchedEffect(store, lifecycleOwner, displayed?.id, locked) {
            lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                store.noteVisible(displayed?.id.takeUnless { locked })
                try { awaitCancellation() } finally { store.noteVisible(null) }
            }
        }
        val openTab: (String) -> Unit = { id ->
            takeFocus()
            keyboard?.hide()
            route.show(id)
            store.select(id)
        }
        val showQuickOpen: () -> Unit = { takeFocus(); quickOpen = true }

        fun perform(shortcut: ArtifactsShortcut): Boolean {
            val ids = state.tabs.map { it.id }
            val shown = displayed?.takeIf { commands.tabId == it.id }
            when (shortcut) {
                ArtifactsShortcut.NewTab -> showQuickOpen()
                // The overview's open field is the new-tab sheet.
                ArtifactsShortcut.EditAddress -> if (shown != null) commands.editAddress() else showQuickOpen()
                ArtifactsShortcut.Reload -> if (shown != null) commands.reload() else return false
                ArtifactsShortcut.Back -> if (shown != null) commands.back() else return false
                ArtifactsShortcut.Forward -> if (shown != null) commands.forward() else return false
                ArtifactsShortcut.CloseTab -> {
                    val closing = displayed ?: return false
                    val index = ids.indexOf(closing.id)
                    val next = ids.getOrNull(index + 1) ?: ids.getOrNull(index - 1)
                    store.close(closing.id)
                    if (next != null) openTab(next) else { route.show(null); takeFocus() }
                }
                ArtifactsShortcut.ReopenClosedTab -> { takeFocus(); store.reopenClosed() }
                ArtifactsShortcut.PreviousTab, ArtifactsShortcut.NextTab -> openTab(
                    artifactAdjacentTab(ids, displayed?.id, if (shortcut == ArtifactsShortcut.NextTab) 1 else -1) ?: return false,
                )
                is ArtifactsShortcut.SelectTab, ArtifactsShortcut.LastTab -> openTab(artifactNumberedTab(ids, shortcut) ?: return false)
                // A wide window always shows its overview beside the tab; the shortcut searches it.
                ArtifactsShortcut.Overview -> if (!wide) { route.show(null); takeFocus() }
                    else if (state.tabs.isNotEmpty()) runCatching { searchFocus.requestFocus() }
            }
            return true
        }

        val overview: @Composable (Modifier) -> Unit = { paneModifier ->
            ArtifactsOverview(
                store = store, state = state, revision = revision,
                query = query, onQueryChange = { query = it },
                selectedId = displayed?.id, onSelect = openTab,
                onQuickOpen = showQuickOpen, nowMillis = nowMillis,
                modifier = paneModifier,
                searchModifier = Modifier.focusRequester(searchFocus).onFocusChanged { textFocus.note("search", it.isFocused) },
            )
        }
        val tab: @Composable (Modifier) -> Unit = { paneModifier ->
            if (displayed == null) {
                TesseraEmptyState(
                    title = stringResource(R.string.artifacts_select_tab), body = stringResource(R.string.artifacts_select_tab_hint),
                    icon = TesseraIcons.File, modifier = paneModifier.fillMaxSize(),
                )
            } else {
                ArtifactTabScreen(
                    store = store, tab = displayed, revision = revision,
                    nowMillis = nowMillis, onBack = { route.show(null); takeFocus() },
                    onNewTab = showQuickOpen,
                    onClosed = { route.show(null); takeFocus() }, modifier = paneModifier,
                    wide = wide, onOpenTab = openTab, onReleaseFocus = takeFocus, commands = commands,
                )
            }
        }
        // Keep the detail at one composition site when the window crosses the
        // split threshold, so resizing does not dispose its page history.
        Row(
            Modifier.fillMaxSize()
                .onPreviewKeyEvent { event ->
                    if (locked || event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
                    val native = event.nativeKeyEvent
                    val shortcut = artifactsShortcut(
                        native.keyCode, ctrl = native.isCtrlPressed, shift = native.isShiftPressed,
                        alt = native.isAltPressed, meta = native.isMetaPressed, textFocused = textFocus.any,
                    ) ?: return@onPreviewKeyEvent false
                    perform(shortcut)
                }
                .focusRequester(browserFocus)
                .focusTarget(),
        ) {
            if (overviewShown) {
                overview(
                    (if (wide) Modifier.width(listWidth) else Modifier.weight(1f))
                        .fillMaxHeight(),
                )
            }
            if (wide) Box(Modifier.width(1.dp).fillMaxHeight().background(LocalTesseraTokens.current.border))
            if (wide || detail != null) tab(Modifier.weight(1f).fillMaxHeight())
        }
        LaunchedEffect(locked) { if (!locked) takeFocus() }
        // Sheets and popup menus own windows above the activity's lock overlay.
        LaunchedEffect(locked) { if (locked) quickOpen = false }
        if (quickOpen && !locked) {
            ArtifactQuickOpen(
                store = store, state = state, revision = revision,
                currentHostId = displayed?.hostId ?: selected?.hostId,
                onOpened = { openTab(it); quickOpen = false },
                onDismiss = { quickOpen = false },
            )
        }
    } }
}

@Composable
internal fun ArtifactBrowserEmptyState(modifier: Modifier = Modifier) {
    TesseraEmptyState(
        title = stringResource(R.string.artifacts_title),
        body = stringResource(R.string.artifacts_empty_body),
        icon = TesseraIcons.File,
        modifier = modifier,
    )
}
