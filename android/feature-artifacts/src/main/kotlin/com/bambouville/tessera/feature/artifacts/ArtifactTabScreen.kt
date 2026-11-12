package com.bambouville.tessera.feature.artifacts

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.net.toUri
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheState
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.design.LocalArtifactOpener
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactDiffView
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactDocumentView
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactWebView
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactWebViewController
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactWebViewState
import com.bambouville.tessera.feature.artifacts.viewers.artifactShareChooser
import com.bambouville.tessera.feature.artifacts.viewers.artifactWebViewOrigin
import com.bambouville.tessera.feature.artifacts.viewers.stageArtifactExport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/**
 * What the browser's keyboard shortcuts reach in the tab on screen. The tab
 * binds its own actions while it is composed.
 */
@Stable
internal class ArtifactTabCommands {
    private var owner: String? = null
    private var actions = ArtifactTabActions()

    val tabId: String? get() = owner
    fun reload() = actions.reload()
    fun back() = actions.back()
    fun forward() = actions.forward()
    fun editAddress() = actions.editAddress()

    internal fun bind(tabId: String, actions: ArtifactTabActions) { owner = tabId; this.actions = actions }
    internal fun unbind(tabId: String) { if (owner == tabId) { owner = null; actions = ArtifactTabActions() } }
}

internal data class ArtifactTabActions(
    val reload: () -> Unit = {},
    val back: () -> Unit = {},
    val forward: () -> Unit = {},
    val editAddress: () -> Unit = {},
)

/**
 * One tab with its chrome. Wide windows put back, forward, reload, the
 * address field and share in one toolbar row; a phone keeps the address
 * under the title and history, reload and share in a bottom bar.
 */
@Composable
internal fun ArtifactTabScreen(
    store: ArtifactsUiStore,
    tab: SharedArtifactTab,
    revision: Long,
    nowMillis: Long,
    onBack: () -> Unit,
    onNewTab: () -> Unit,
    onClosed: () -> Unit,
    modifier: Modifier = Modifier,
    wide: Boolean = false,
    /** The address field sent the user to another tab: a switch-to row, a change, or another host. */
    onOpenTab: (String) -> Unit = {},
    /** Editing ended in the field; focus returns to the browser so its shortcuts keep working. */
    onReleaseFocus: () -> Unit = {},
    commands: ArtifactTabCommands? = null,
) {
    val tokens = LocalTesseraTokens.current
    val chrome = artifactsChrome(wide = wide, tabShown = true)
    val content = remember(store, tab, revision) { store.content(tab.id) }
    val presentation = remember(store, tab, revision) { store.presentation(tab.id) }
    val filesReconnect = remember(store, tab, revision) { store.filesReconnect(tab.id) }
    val share = remember(store, tab, revision) { store.share(tab.id) }
    val reconnectCached = filesReconnect != null &&
        (presentation.state == SharedArtifactsCacheState.Cached || presentation.state == SharedArtifactsCacheState.Stale)
    val controller = remember(tab.id) { ArtifactWebViewController() }
    val pageUrl = when (content) {
        is ArtifactContent.ServedPage -> content.url
        is ArtifactContent.ForwardedPage -> content.url
        else -> null
    }
    // The viewer survives another path on the same origin, and so does its history.
    var webState by remember(tab.id, pageUrl?.let(::artifactWebViewOrigin)) { mutableStateOf(ArtifactWebViewState(pageUrl.orEmpty())) }
    var notice by remember(tab.id) { mutableStateOf<String?>(null) }
    var editing by remember(tab.id) { mutableStateOf<TextFieldValue?>(null) }
    var sharing by remember(tab.id) { mutableStateOf(false) }
    val context = LocalContext.current
    val clipboard = LocalClipboard.current
    val keyboard = LocalSoftwareKeyboardController.current
    val scope = rememberCoroutineScope()
    val page = tab.kind == SharedArtifactsKind.Pages
    // A page whose forward failed has no viewer to reload; the store loads it again.
    val canRetry = presentation.canRefresh && (content as? ArtifactContent.Unavailable)?.reason is ArtifactUnavailable.Failed
    val canReconnect = filesReconnect == ArtifactFilesReconnect.Available || filesReconnect is ArtifactFilesReconnect.Failed
    val canReload = if (page) presentation.canRefresh && pageUrl != null || canRetry || canReconnect
        else tab.target is SharedArtifactsTarget.File && (presentation.canRefresh || canReconnect)
    val address = artifactAddressText(tab, webState.url.takeIf { pageUrl != null })
    val opened by rememberUpdatedState(onOpenTab)
    val release by rememberUpdatedState(onReleaseFocus)

    val reload: () -> Unit = {
        if (!canReload) Unit
        else if (page && pageUrl != null) controller.reload()
        else if (filesReconnect != null) store.connectFiles(tab.id)
        else store.refresh(tab.id)
    }
    val goBack: () -> Unit = { if (pageUrl != null) controller.goBack() }
    val goForward: () -> Unit = { if (pageUrl != null) controller.goForward() }
    val editAddress: () -> Unit = {
        val current = editing
        // Ctrl+L while editing selects the whole field again, as a browser does.
        editing = if (current == null) artifactAddressEditValue(address)
            else current.copy(selection = TextRange(0, current.text.length))
    }
    val endEditing: (Boolean) -> Unit = { tappedAway ->
        editing = null
        if (!tappedAway) { keyboard?.hide(); release() }
    }
    val submitter = rememberArtifactOpenSubmitter(store, ArtifactOpenPlacement.Navigate(tab.id)) { id ->
        endEditing(false)
        if (id != tab.id) opened(id)
    }
    // Resolved in composition, so a configuration change re-resolves them.
    val shareTitle = (share as? ArtifactShare.Ready)?.let { stringResource(R.string.artifacts_share_chooser, it.displayName) }
    val shareReason = (share as? ArtifactShare.Unavailable)?.let { stringResource(artifactShareReason(it.reason)) }
    val shareFailed = stringResource(R.string.artifacts_share_failed)
    val noBrowser = stringResource(R.string.artifacts_no_browser)
    val browserFailed = stringResource(R.string.artifacts_browser_failed)
    val linkFailed = stringResource(R.string.artifacts_link_failed)
    val opener = LocalArtifactOpener.current
    val deviceUriHandler = LocalUriHandler.current
    val openDocumentLink: (String) -> Unit = { link ->
        val home = store.quickOpenHosts.firstOrNull { it.id == tab.hostId }?.home
        when (val route = artifactDocumentLinkRoute(link, tab, home)) {
            is ArtifactDocumentLinkRoute.Open -> if (opener == null) notice = linkFailed else {
                notice = null
                opener.open(route.request)
            }
            // The core reads a scheme in any case; an intent filter matches only lowercase.
            ArtifactDocumentLinkRoute.External -> try { deviceUriHandler.openUri(link.toUri().normalizeScheme().toString()) }
                catch (_: ActivityNotFoundException) { notice = noBrowser }
                catch (_: IllegalArgumentException) { notice = noBrowser }
            ArtifactDocumentLinkRoute.Refused -> notice = linkFailed
            ArtifactDocumentLinkRoute.Ignored -> Unit
        }
    }
    val shareNow: () -> Unit = shareNow@{
        when (val offer = share) {
            is ArtifactShare.Ready -> {
                if (sharing) return@shareNow
                sharing = true
                notice = null
                val title = shareTitle.orEmpty()
                scope.launch {
                    try {
                        val staged = stageArtifactExport(context.applicationContext, offer.file, offer.displayName)
                        context.startActivity(artifactShareChooser(context, staged, offer.displayName, title))
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (_: Exception) {
                        notice = shareFailed
                    } finally {
                        sharing = false
                    }
                }
            }
            is ArtifactShare.Unavailable -> notice = shareReason
            null -> Unit
        }
    }

    if (commands != null) {
        SideEffect {
            commands.bind(tab.id, ArtifactTabActions(reload = reload, back = goBack, forward = goForward, editAddress = editAddress))
        }
        DisposableEffect(commands, tab.id) { onDispose { commands.unbind(tab.id) } }
    }
    BackHandler {
        if (pageUrl == null || !controller.goBack()) onBack()
    }
    // Declared later, so it wins while the address is being edited.
    BackHandler(enabled = editing != null) { endEditing(false) }

    val addressBar: @Composable (Modifier) -> Unit = { barModifier ->
        ArtifactAddressBar(
            tab = tab, address = address, live = store.isLive(tab.hostId), editing = editing,
            onEdit = { editing = it; submitter.clearMessage() },
            onCancel = endEditing,
            onSubmit = { text -> submitter.submit(text, tab.hostId) },
            modifier = barModifier,
        )
    }
    val history: @Composable () -> Unit = {
        TesseraIconButton(TesseraIcons.ChevronLeft, stringResource(R.string.artifacts_back), goBack,
            enabled = pageUrl != null && webState.canGoBack, modifier = Modifier.testTag("artifacts-page-back"))
        TesseraIconButton(TesseraIcons.ChevronRight, stringResource(R.string.artifacts_forward), goForward,
            enabled = pageUrl != null && webState.canGoForward, modifier = Modifier.testTag("artifacts-page-forward"))
        TesseraIconButton(TesseraIcons.Refresh, stringResource(R.string.artifacts_reload), reload,
            enabled = canReload, modifier = Modifier.testTag("artifacts-refresh"))
    }
    val shareButton: @Composable () -> Unit = {
        share?.let { offer ->
            val label = stringResource(R.string.artifacts_share)
            val reason = shareReason.takeIf { offer is ArtifactShare.Unavailable }
            val preparing = stringResource(R.string.artifacts_sharing)
            if (sharing) {
                Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        Modifier.size(16.dp).semantics { contentDescription = preparing },
                        color = tokens.fgMuted, strokeWidth = 2.dp,
                    )
                }
            } else {
                // An unavailable share stays tappable so it can say why; it draws as disabled.
                Box(Modifier.alpha(if (reason == null) 1f else 0.45f)) {
                    TesseraIconButton(TesseraIcons.Share, if (reason == null) label else "$label, $reason", shareNow,
                        modifier = Modifier.testTag("artifacts-share").semantics { if (reason != null) stateDescription = reason })
                }
            }
        }
    }

    Column(modifier.fillMaxSize().testTag("artifacts-tab-${tab.id}")) {
        Row(
            Modifier.fillMaxWidth().background(tokens.panelBg).padding(horizontal = 4.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (chrome.overviewBack) {
                TesseraIconButton(TesseraIcons.ChevronLeft, stringResource(R.string.artifacts_back_to_overview), onBack, Modifier.testTag("artifacts-overview-back"))
            }
            Column(Modifier.weight(1f).padding(horizontal = 4.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(tab.title, style = TesseraType.rowTitle, color = tokens.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(tab.hostLabel, style = TesseraType.rowMicro, color = tokens.fgMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                ArtifactCacheBadge(presentation, nowMillis)
            }
            ArtifactTabMenu(
                tab = tab, canKeepAsRule = store.canKeepAsRule(tab.id),
                onNewTab = if (chrome.menuNewTab) onNewTab else null,
                onPin = { store.setPinned(tab.id, !tab.pinned) },
                onClose = { store.close(tab.id); onClosed() },
                onCloseAll = { store.closeAll(tab.hostId); onClosed() },
                onKeepAsRule = { store.keepAsRule(tab.id) },
                onCopyPath = {
                    val path = ClipData.newPlainText("artifact path", artifactTabAddress(tab))
                    scope.launch { clipboard.setClipEntry(ClipEntry(path)) }
                },
                onOpenBrowser = if (content is ArtifactContent.ForwardedPage) {
                    {
                        try {
                            context.startActivity(Intent(Intent.ACTION_VIEW, content.url.toUri()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        } catch (_: ActivityNotFoundException) {
                            notice = noBrowser
                        } catch (_: SecurityException) {
                            notice = browserFailed
                        }
                    }
                } else null,
            )
        }
        if (chrome.toolbarHistory) {
            Row(
                Modifier.fillMaxWidth().background(tokens.panelBg).padding(horizontal = 4.dp, vertical = 2.dp)
                    .testTag("artifacts-toolbar"),
                horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                history()
                addressBar(Modifier.weight(1f).padding(horizontal = 4.dp, vertical = 4.dp))
                shareButton()
            }
        } else {
            addressBar(Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
        }
        TesseraHairline()
        val cacheNotice = if (reconnectCached) {
            (filesReconnect as? ArtifactFilesReconnect.Failed)?.let { artifactMessageText(it.message) }
                ?: stringResource(R.string.artifacts_showing_saved_copy)
        } else when (presentation.state) {
            SharedArtifactsCacheState.Cached -> when {
                tab.target is SharedArtifactsTarget.Change -> null
                !store.isLive(tab.hostId) -> stringResource(R.string.artifacts_host_offline_saved_copy, tab.hostLabel)
                else -> stringResource(R.string.artifacts_showing_saved_copy)
            }
            SharedArtifactsCacheState.Stale -> if (presentation.canRefresh) stringResource(R.string.artifacts_copy_changed)
                else stringResource(R.string.artifacts_copy_out_of_date, tab.hostLabel)
            else -> null
        }
        val forwardNotice = (content as? ArtifactContent.ForwardedPage)?.let {
            if (it.isEphemeral) stringResource(R.string.artifacts_forwarded_for_tab)
            else stringResource(R.string.artifacts_forwarded_by_rule, it.ruleLabel)
        }
        (notice ?: cacheNotice ?: forwardNotice)?.let {
            Row(
                Modifier.fillMaxWidth().background(tokens.panelBg).padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(it, Modifier.weight(1f).padding(vertical = 10.dp).testTag("artifacts-tab-notice"),
                    style = TesseraType.bodySmall, color = tokens.fgMuted)
                if (reconnectCached) ArtifactFilesReconnectAction(checkNotNull(filesReconnect), stringResource(R.string.artifacts_refresh)) { store.connectFiles(tab.id) }
            }
            TesseraHairline()
        }
        Box(Modifier.fillMaxWidth().weight(1f).testTag("artifacts-content")) {
            when (content) {
                ArtifactContent.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    val loading = stringResource(R.string.artifacts_loading_artifact)
                    CircularProgressIndicator(
                        Modifier.size(24.dp).semantics { contentDescription = loading },
                        color = tokens.fgMuted, strokeWidth = 2.dp,
                    )
                }
                is ArtifactContent.Document -> ArtifactDocumentView(
                    file = content.file, displayName = content.displayName,
                    reloadToken = content.reloadToken, stagedImages = content.stagedImages,
                    onLink = openDocumentLink,
                )
                is ArtifactContent.ServedPage -> ArtifactWebView(
                    content.url, hostId = tab.hostId, interceptor = content.interceptor, showControls = false, controller = controller,
                    onTitleChanged = { if (it.isNotBlank() && it != tab.title) store.titleLearned(tab.id, it) },
                    onStateChanged = { webState = it }, onBack = onBack,
                )
                is ArtifactContent.ForwardedPage -> ArtifactWebView(
                    content.url, hostId = tab.hostId, showControls = false, controller = controller,
                    navigation = content.navigation,
                    onTitleChanged = { if (it.isNotBlank() && it != tab.title) store.titleLearned(tab.id, it) },
                    onStateChanged = { webState = it }, onBack = onBack,
                )
                is ArtifactContent.Change -> ArtifactDiffView(content.diff)
                is ArtifactContent.Unavailable -> ArtifactUnavailableView(
                    content.reason, tab.hostLabel, filesReconnect = filesReconnect, onConnectFiles = { store.connectFiles(tab.id) },
                    onRetry = if (canRetry) { { store.refresh(tab.id) } } else null,
                )
            }
            if (editing != null) {
                ArtifactAddressSuggestions(store, tab, revision, editing?.text.orEmpty(), submitter) { endEditing(false) }
            }
        }
        TesseraHairline()
        Row(
            Modifier.fillMaxWidth().background(tokens.panelBg).padding(horizontal = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            if (chrome.bottomHistory) {
                history()
                shareButton()
            }
            val openedFrom = artifactMessageText(artifactOpenedFrom(tab.origin))
            Text(
                if (tab.unseenChange) stringResource(R.string.artifacts_unseen_change_opened, openedFrom)
                else openedFrom,
                Modifier.weight(1f).padding(vertical = 8.dp, horizontal = 4.dp),
                style = TesseraType.rowMicro, color = tokens.fgDim, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * Suggestions under the address field, covering the page like a browser's
 * omnibox. Picking one navigates this tab; an open tab is a switch-to row.
 * Tapping the empty space below them ends editing.
 */
@Composable
private fun ArtifactAddressSuggestions(
    store: ArtifactsUiStore,
    tab: SharedArtifactTab,
    revision: Long,
    input: String,
    submitter: ArtifactOpenSubmitter,
    onDismiss: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    val state by store.state.collectAsStateWithLifecycle()
    val suggestions = artifactEditingSuggestions(artifactSuggestions(store, state, revision, input, tab.hostId), tab.id)
    Column(
        Modifier.fillMaxSize().background(tokens.panelBg)
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss)
            .testTag("artifacts-address-suggestions"),
    ) {
        LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            submitter.message?.let { text ->
                item(key = "message") {
                    Text(artifactMessageText(text), Modifier.fillMaxWidth().padding(vertical = 12.dp).testTag("artifacts-address-message"),
                        style = TesseraType.bodySmall, color = if (submitter.failed) tokens.red else tokens.fgMuted)
                }
            }
            artifactSuggestionItems(suggestions, enabled = !submitter.submitting) { suggestion ->
                submitter.choose(suggestion, tab.hostId)
            }
        }
    }
}

internal fun artifactShareReason(reason: String): Int = when (reason) {
    ARTIFACT_SHARE_TOO_LARGE -> R.string.artifacts_share_too_large
    ARTIFACT_SHARE_NOT_DOWNLOADED -> R.string.artifacts_share_not_downloaded
    else -> R.string.artifacts_share_downloading
}

@Composable
private fun ArtifactFilesReconnectAction(reconnect: ArtifactFilesReconnect, label: String, onClick: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    if (reconnect == ArtifactFilesReconnect.Connecting) {
        val connecting = stringResource(R.string.artifacts_connecting)
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(
                Modifier.size(16.dp).semantics { contentDescription = connecting },
                color = tokens.fgMuted, strokeWidth = 2.dp,
            )
        }
    } else {
        TextButton(onClick, Modifier.heightIn(min = 48.dp).testTag("artifacts-files-reconnect"),
            colors = ButtonDefaults.textButtonColors(contentColor = tokens.accent)) {
            Text(label, style = TesseraType.button)
        }
    }
}

@Composable
internal fun ArtifactUnavailableView(
    reason: ArtifactUnavailable,
    hostLabel: String,
    modifier: Modifier = Modifier,
    filesReconnect: ArtifactFilesReconnect? = null,
    onConnectFiles: () -> Unit = {},
    /** A failed load worth another try while its host is reachable. */
    onRetry: (() -> Unit)? = null,
) {
    if ((reason == ArtifactUnavailable.Offline || reason == ArtifactUnavailable.NoForwarding) && filesReconnect != null) {
        val notLoaded = if (reason == ArtifactUnavailable.NoForwarding) R.string.artifacts_no_page_connection else R.string.artifacts_not_loaded
        TesseraEmptyState(
            title = stringResource(if (filesReconnect is ArtifactFilesReconnect.Failed) R.string.artifacts_load_failed else notLoaded),
            body = (filesReconnect as? ArtifactFilesReconnect.Failed)?.let { artifactMessageText(it.message) }
                ?: stringResource(R.string.artifacts_load_opens_files, hostLabel),
            icon = TesseraIcons.File,
            action = { ArtifactFilesReconnectAction(filesReconnect, stringResource(R.string.artifacts_load), onConnectFiles) },
            modifier = modifier.fillMaxSize().testTag("artifacts-unavailable"),
        )
        return
    }
    val message = when (reason) {
        ArtifactUnavailable.Offline -> stringResource(R.string.artifacts_connect_to_load, hostLabel)
        ArtifactUnavailable.NoForwarding -> stringResource(R.string.artifacts_mosh_pages)
        is ArtifactUnavailable.TooLarge -> stringResource(
            R.string.artifacts_too_large_to_preview,
            artifactByteCount(reason.bytes) ?: stringResource(R.string.artifacts_unknown_size),
        )
        ArtifactUnavailable.Missing -> stringResource(R.string.artifacts_file_gone, hostLabel)
        is ArtifactUnavailable.Failed -> artifactMessageText(reason.message)
    }
    TesseraEmptyState(
        title = stringResource(when (reason) {
            ArtifactUnavailable.Offline -> R.string.artifacts_offline
            ArtifactUnavailable.NoForwarding -> R.string.artifacts_page_unavailable
            ArtifactUnavailable.Missing -> R.string.artifacts_file_missing
            else -> R.string.artifacts_preview_unavailable
        }),
        body = message, icon = TesseraIcons.File,
        action = onRetry?.takeIf { reason is ArtifactUnavailable.Failed }?.let { retry ->
            {
                TextButton(retry, Modifier.heightIn(min = 48.dp).testTag("artifacts-retry"),
                    colors = ButtonDefaults.textButtonColors(contentColor = LocalTesseraTokens.current.accent)) {
                    Text(stringResource(R.string.artifacts_retry), style = TesseraType.button)
                }
            }
        },
        modifier = modifier.fillMaxSize().testTag("artifacts-unavailable"),
    )
}
