package com.bambouville.tessera.files

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraBanner
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraConfirmDialog
import com.bambouville.tessera.design.TesseraDialog
import com.bambouville.tessera.design.TesseraEmptyState
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraPageHeader
import com.bambouville.tessera.design.TesseraProgressTrack
import com.bambouville.tessera.design.TesseraRowGlyph
import com.bambouville.tessera.design.TesseraTag
import com.bambouville.tessera.design.TesseraTextField
import com.bambouville.tessera.design.TesseraType
import java.util.Locale

private data class PendingUploadConflict(
    val uri: Uri,
    val existingKind: RemoteFileKind,
)

@Composable
fun RemoteFilesScreen(
    controller: RemoteFilesPresenter,
    modifier: Modifier = Modifier,
    onSystemPickerActiveChanged: (Boolean) -> Unit = {},
    terminalPathSink: RemoteTerminalPathSink? = null,
    onOutboundPresentationActiveChanged: (Boolean) -> Unit = {},
) {
    val state by controller.state.collectAsState()
    val transfers by controller.transfers.collectAsState()
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOutboundPresentationCallback by rememberUpdatedState(onOutboundPresentationActiveChanged)
    var downloadEntry by remember { mutableStateOf<RemoteFileEntry?>(null) }
    var renameEntry by remember { mutableStateOf<RemoteFileEntry?>(null) }
    var deleteEntry by remember { mutableStateOf<RemoteFileEntry?>(null) }
    var creatingDirectory by remember { mutableStateOf(false) }
    var conflictingUploads by remember { mutableStateOf<List<PendingUploadConflict>>(emptyList()) }
    var browserToolsOpen by remember { mutableStateOf(false) }
    var filterQuery by remember { mutableStateOf("") }
    var outboundPresentationActive by remember { mutableStateOf(false) }

    fun queueConflict(uri: Uri, kind: RemoteFileKind) {
        if (conflictingUploads.none { it.uri == uri }) {
            conflictingUploads = conflictingUploads + PendingUploadConflict(uri, kind)
        }
    }

    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && outboundPresentationActive) {
                outboundPresentationActive = false
                currentOutboundPresentationCallback(false)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            if (outboundPresentationActive) currentOutboundPresentationCallback(false)
        }
    }

    val downloadLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/octet-stream"),
    ) { uri ->
        onSystemPickerActiveChanged(false)
        val entry = downloadEntry
        downloadEntry = null
        if (uri != null && entry != null) controller.enqueueDownload(entry, uri)
        if (uri != null) runCatching {
            context.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
        }
    }
    val uploadLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        onSystemPickerActiveChanged(false)
        if (uri != null) {
            runCatching {
                context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val name = controller.displayName(uri)
            val existing = state.entries.firstOrNull { it.name == name }
            if (existing != null) queueConflict(uri, existing.kind)
            else controller.enqueueUpload(uri)
        }
    }

    LaunchedEffect(controller) { controller.open() }

    BoxWithConstraints(modifier.fillMaxSize()) {
        val tablet = maxWidth >= 700.dp
        val browser: @Composable (Modifier) -> Unit = { paneModifier ->
            BrowserPane(
                state,
                preparingPaths = transfers.filter(RemoteFilesBrowser::isPreparingPresentation)
                    .mapTo(mutableSetOf()) { it.remotePath },
                onParent = controller::parent,
                onRefresh = { controller.open(state.currentPath) },
                onBrowserTools = { browserToolsOpen = true },
                onCreateDirectory = { creatingDirectory = true },
                onUpload = {
                    onSystemPickerActiveChanged(true)
                    uploadLauncher.launch(arrayOf("*/*"))
                },
                onOpen = controller::openEntry,
                onDownload = { entry ->
                    downloadEntry = entry
                    onSystemPickerActiveChanged(true)
                    downloadLauncher.launch(entry.name)
                },
                onRename = { renameEntry = it },
                onDelete = { deleteEntry = it },
                onPresent = { entry, action ->
                    controller.present(entry, action) {
                        outboundPresentationActive = true
                        currentOutboundPresentationCallback(true)
                    }
                },
                onInsertTerminalPath = terminalPathSink?.let { sink -> { entry -> sink.insert(RemoteTerminalPath(entry.path)) } },
                onDroppedUris = { uris ->
                    uris.forEach { uri ->
                        val name = controller.displayName(uri)
                        val existing = state.entries.firstOrNull { it.name == name }
                        if (existing != null) queueConflict(uri, existing.kind)
                        else controller.enqueueUpload(uri)
                    }
                },
                onToggleFollow = controller::toggleFollow,
                filterQuery = filterQuery,
                modifier = paneModifier,
            )
        }
        if (tablet) {
            Row(Modifier.fillMaxSize()) {
                browser(Modifier.weight(1f))
                Box(
                    Modifier
                        .fillMaxHeight()
                        .width(1.dp)
                        .background(LocalTesseraTokens.current.border),
                )
                TransferPane(transfers, controller, Modifier.width(330.dp).fillMaxSize())
            }
        } else {
            Column(Modifier.fillMaxSize()) {
                browser(Modifier.weight(1f))
                if (transfers.isNotEmpty()) {
                    TesseraHairline()
                    TransferPane(transfers, controller, Modifier.fillMaxWidth().height(200.dp))
                }
            }
        }
    }

    if (creatingDirectory) NameDialog(
        title = "new folder",
        label = "Folder name",
        initial = "",
        confirmLabel = "Create",
        onDismiss = { creatingDirectory = false },
        onConfirm = { controller.createDirectory(it); creatingDirectory = false },
    )
    renameEntry?.let { entry ->
        NameDialog(
            title = "rename",
            label = "New name for ${entry.name}",
            initial = entry.name,
            confirmLabel = "Rename",
            onDismiss = { renameEntry = null },
            onConfirm = { controller.rename(entry, it); renameEntry = null },
        )
    }
    if (browserToolsOpen) BrowserToolsDialog(
        currentPath = state.currentPath.orEmpty(),
        homePath = state.homePath,
        initialFilter = filterQuery,
        onDismiss = { browserToolsOpen = false },
        onOpenPath = { value ->
            RemoteFilesBrowser.requestedPath(value, state.homePath)?.let(controller::navigate)
            browserToolsOpen = false
        },
        onFilterChange = { filterQuery = it },
    )
    deleteEntry?.let { entry ->
        TesseraConfirmDialog(
            title = "Delete ${entry.name}?",
            body = "This permanently removes the remote item. Non-empty folders are never deleted recursively.",
            confirmLabel = "Delete",
            cancelLabel = "Cancel",
            destructive = true,
            onConfirm = { controller.delete(entry); deleteEntry = null },
            onDismiss = { deleteEntry = null },
        )
    }
    conflictingUploads.firstOrNull()?.let { conflict ->
        fun resolveConflict() {
            conflictingUploads = conflictingUploads.drop(1)
        }
        val displayName = controller.displayName(conflict.uri)
        if (conflict.existingKind == RemoteFileKind.FILE) {
            TesseraConfirmDialog(
                title = "Replace $displayName?",
                body = "A remote file with this name already exists. Replacing it cannot be undone.",
                confirmLabel = "Replace",
                cancelLabel = "Skip",
                destructive = true,
                onConfirm = {
                    controller.enqueueUpload(conflict.uri, replaceExisting = true)
                    resolveConflict()
                },
                onDismiss = ::resolveConflict,
            )
        } else {
            TesseraDialog(
                title = "Can't replace $displayName",
                onDismissRequest = ::resolveConflict,
                actions = {
                    TesseraButton(
                        text = "OK",
                        onClick = ::resolveConflict,
                        style = TesseraButtonStyle.Primary,
                        compact = true,
                    )
                },
            ) {
                Text(
                    "A remote ${conflict.existingKind.name.lowercase()} already uses this name. Tessera only replaces regular files.",
                    style = TesseraType.body,
                    color = LocalTesseraTokens.current.fgMuted,
                )
            }
        }
    }
}

@Composable
private fun BrowserPane(
    state: RemoteFilesState,
    preparingPaths: Set<String>,
    onParent: () -> Unit,
    onRefresh: () -> Unit,
    onBrowserTools: () -> Unit,
    onCreateDirectory: () -> Unit,
    onUpload: () -> Unit,
    onOpen: (RemoteFileEntry) -> Unit,
    onDownload: (RemoteFileEntry) -> Unit,
    onRename: (RemoteFileEntry) -> Unit,
    onDelete: (RemoteFileEntry) -> Unit,
    onPresent: (RemoteFileEntry, RemoteFilePresentationAction) -> Unit,
    onInsertTerminalPath: ((RemoteFileEntry) -> Unit)?,
    onDroppedUris: (List<Uri>) -> Unit,
    onToggleFollow: () -> Unit,
    filterQuery: String,
    modifier: Modifier,
) {
    val tokens = LocalTesseraTokens.current
    Column(
        modifier
            .remoteFileDropTarget(enabled = state.currentPath != null, onDropped = onDroppedUris)
            .background(tokens.bg),
    ) {
        TesseraPageHeader("files") {
            TesseraIconButton(
                icon = TesseraIcons.ArrowUp,
                contentDescription = "Parent folder",
                onClick = onParent,
                enabled = state.currentPath != null && state.currentPath != "/",
            )
            TesseraIconButton(icon = TesseraIcons.Refresh, contentDescription = "Refresh", onClick = onRefresh)
            TesseraIconButton(
                icon = TesseraIcons.Search,
                contentDescription = "Quick open and filter",
                onClick = onBrowserTools,
                enabled = state.currentPath != null,
                selected = filterQuery.isNotBlank(),
            )
            TesseraIconButton(
                icon = TesseraIcons.FolderPlus,
                contentDescription = "New folder",
                onClick = onCreateDirectory,
                enabled = state.currentPath != null,
            )
            TesseraIconButton(
                icon = TesseraIcons.Upload,
                contentDescription = "Upload",
                onClick = onUpload,
                enabled = state.currentPath != null,
                prominent = true,
            )
        }
        TesseraHairline()
        Row(
            Modifier.fillMaxWidth().heightIn(min = 36.dp).padding(horizontal = 18.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            FollowTerminalToggle(state.followState, onToggleFollow)
            Text(
                state.currentPath ?: "connecting…",
                modifier = Modifier.weight(1f),
                color = tokens.fgMuted,
                style = TesseraType.code,
                maxLines = 1,
                overflow = TextOverflow.StartEllipsis,
            )
            if (state.loading && state.entries.isNotEmpty()) {
                CircularProgressIndicator(
                    modifier = Modifier.size(14.dp),
                    color = tokens.accent,
                    strokeWidth = 1.5.dp,
                )
            }
        }
        TesseraHairline()
        val filteredEntries = RemoteFilesBrowser.filter(state.entries, filterQuery)
        if (filterQuery.isNotBlank()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "filter: $filterQuery",
                    modifier = Modifier.weight(1f),
                    style = TesseraType.rowMeta,
                    color = tokens.fgMuted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    "${filteredEntries.size}/${state.entries.size}",
                    style = TesseraType.rowMeta,
                    color = tokens.fgDim,
                )
            }
            TesseraHairline()
        }
        state.error?.let {
            TesseraBanner(text = it, modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp))
        }
        when {
            state.loading && state.entries.isEmpty() -> Column(
                Modifier.fillMaxSize(),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(26.dp),
                    color = tokens.accent,
                    strokeWidth = 2.dp,
                )
                Text(
                    "loading directory…",
                    modifier = Modifier.padding(top = 14.dp),
                    style = TesseraType.body,
                    color = tokens.fgMuted,
                )
            }
            state.entries.isEmpty() && state.error == null -> TesseraEmptyState(
                title = "empty folder",
                body = "Nothing is stored here yet. Upload a file, or move up to the parent folder.",
                icon = TesseraIcons.Folder,
                modifier = Modifier.fillMaxSize(),
            )
            filteredEntries.isEmpty() && state.error == null -> TesseraEmptyState(
                title = "no matching files",
                body = "Change the filter from quick open to show the rest of this folder.",
                icon = TesseraIcons.Search,
                modifier = Modifier.fillMaxSize(),
            )
            else -> LazyColumn(Modifier.fillMaxSize()) {
                items(filteredEntries, key = RemoteFileEntry::id) { entry ->
                    RemoteFileRow(
                        entry = entry,
                        isPreparing = entry.path in preparingPaths,
                        onOpen = onOpen,
                        onDownload = onDownload,
                        onRename = onRename,
                        onDelete = onDelete,
                        onPresent = onPresent,
                        onInsertTerminalPath = onInsertTerminalPath,
                    )
                }
            }
        }
    }
}

@Composable
private fun RemoteFileRow(
    entry: RemoteFileEntry,
    isPreparing: Boolean,
    onOpen: (RemoteFileEntry) -> Unit,
    onDownload: (RemoteFileEntry) -> Unit,
    onRename: (RemoteFileEntry) -> Unit,
    onDelete: (RemoteFileEntry) -> Unit,
    onPresent: (RemoteFileEntry, RemoteFilePresentationAction) -> Unit,
    onInsertTerminalPath: ((RemoteFileEntry) -> Unit)?,
) {
    val tokens = LocalTesseraTokens.current
    val tap = RemoteFilesBrowser.rowTap(entry.kind)
    val navigable = tap == RemoteFileRowTap.NAVIGATE
    var menuOpen by remember(entry.id) { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 66.dp)
            .clickable(
                enabled = tap != RemoteFileRowTap.NONE,
                onClickLabel = when (tap) {
                    RemoteFileRowTap.NAVIGATE -> "Open directory"
                    RemoteFileRowTap.QUICK_VIEW -> "Quick view"
                    RemoteFileRowTap.NONE -> null
                },
                onClick = {
                    when (tap) {
                        RemoteFileRowTap.NAVIGATE -> onOpen(entry)
                        RemoteFileRowTap.QUICK_VIEW -> onPresent(entry, RemoteFilePresentationAction.OPEN)
                        RemoteFileRowTap.NONE -> Unit
                    }
                },
            )
            .padding(start = 18.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TesseraRowGlyph(
            icon = if (navigable) TesseraIcons.Folder else TesseraIcons.File,
            tint = if (navigable) tokens.accent else tokens.fgMuted,
        )
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(
                entry.name,
                style = TesseraType.rowTitle,
                color = tokens.fg,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
            )
            Text(
                entry.size?.let(::formatBytes) ?: entry.kind.name.lowercase(Locale.US),
                color = tokens.fgMuted,
                style = TesseraType.rowMeta,
                maxLines = 1,
            )
        }
        Box {
            if (isPreparing) {
                Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp).semantics { contentDescription = "Preparing file" },
                        color = tokens.fgMuted,
                        strokeWidth = 1.5.dp,
                    )
                }
            } else {
                TesseraIconButton(
                    icon = TesseraIcons.MoreVertical,
                    contentDescription = "Actions for ${entry.name}",
                    onClick = { menuOpen = true },
                )
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                if (entry.kind == RemoteFileKind.FILE) {
                    DropdownMenuItem(text = { Text("Quick open") }, onClick = {
                        menuOpen = false
                        onPresent(entry, RemoteFilePresentationAction.OPEN)
                    })
                    DropdownMenuItem(text = { Text("Share…") }, enabled = !isPreparing, onClick = {
                        menuOpen = false
                        onPresent(entry, RemoteFilePresentationAction.SHARE)
                    })
                    DropdownMenuItem(text = { Text("Download") }, onClick = { menuOpen = false; onDownload(entry) })
                }
                onInsertTerminalPath?.let { insert ->
                    DropdownMenuItem(text = { Text("Insert path in terminal") }, onClick = {
                        menuOpen = false
                        insert(entry)
                    })
                }
                DropdownMenuItem(text = { Text("Rename") }, onClick = { menuOpen = false; onRename(entry) })
                DropdownMenuItem(
                    text = { Text("Delete", color = tokens.red) },
                    onClick = { menuOpen = false; onDelete(entry) },
                )
            }
        }
    }
    TesseraHairline(Modifier.padding(start = 66.dp))
}

/**
 * Whether the browser is tied to the terminal's working directory.
 *
 * Three states, as on iOS: following (the browser moves with every `cd`),
 * manual (the user navigated away and the browser stays put), and no signal —
 * which is not an error, only a session whose transport is reporting nothing,
 * so the glyph warns instead of pretending to follow.
 */
@Composable
private fun FollowTerminalToggle(state: RemoteFilesFollowState, onToggle: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    val available = state != RemoteFilesFollowState.UNAVAILABLE
    val tint = when (state) {
        RemoteFilesFollowState.FOLLOWING -> tokens.accent
        RemoteFilesFollowState.MANUAL -> tokens.fgDim
        RemoteFilesFollowState.UNAVAILABLE -> tokens.amber
    }
    val background = when (state) {
        RemoteFilesFollowState.FOLLOWING -> tokens.accentSoft
        RemoteFilesFollowState.MANUAL -> tokens.inputBgSoft
        RemoteFilesFollowState.UNAVAILABLE -> tokens.amber.copy(alpha = 0.14f)
    }
    val description = when (state) {
        RemoteFilesFollowState.FOLLOWING -> "following the terminal directory — tap to browse freely"
        RemoteFilesFollowState.MANUAL -> "not following — tap to sync to the terminal directory"
        RemoteFilesFollowState.UNAVAILABLE -> "no directory signal from this session"
    }
    Box(
        Modifier
            .size(width = 34.dp, height = 28.dp)
            .clip(RoundedCornerShape(7.dp))
            .background(background)
            .semantics { contentDescription = description }
            .clickable(enabled = available, role = Role.Button, onClick = onToggle),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.material3.Icon(
            if (available) TesseraIcons.Link else TesseraIcons.Alert,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(15.dp),
        )
    }
}

@Composable
private fun TransferPane(
    transfers: List<TransferItem>,
    controller: RemoteFilesPresenter,
    modifier: Modifier,
) {
    val tokens = LocalTesseraTokens.current
    Column(modifier.background(tokens.panelBg)) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(start = 18.dp, end = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TesseraKicker("transfers", Modifier.weight(1f))
            TesseraButton(
                text = "clear",
                onClick = controller::clearFinished,
                compact = true,
            )
        }
        TesseraHairline()
        LazyColumn(Modifier.fillMaxSize()) {
            items(transfers, key = TransferItem::id) { item ->
                val total = item.totalBytes
                val tone = when (item.phase) {
                    TransferPhase.COMPLETED -> tokens.green
                    TransferPhase.FAILED -> tokens.red
                    TransferPhase.CANCELLED -> tokens.fgDim
                    else -> tokens.accent
                }
                Column(Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TransferDirectionGlyph(item.direction)
                        Text(
                            item.displayName,
                            modifier = Modifier.weight(1f).padding(start = 8.dp, end = 8.dp),
                            style = TesseraType.rowMeta,
                            color = tokens.fg,
                            maxLines = 1,
                            overflow = TextOverflow.MiddleEllipsis,
                        )
                        TesseraTag(item.phase.name.lowercase(Locale.US), tone = tone)
                    }
                    Spacer(Modifier.height(8.dp))
                    if (item.phase == TransferPhase.RUNNING || item.phase == TransferPhase.QUEUED) {
                        TesseraProgressTrack(
                            progress = if (total != null && total > 0) {
                                item.transferredBytes.toFloat() / total
                            } else {
                                null
                            },
                        )
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            if (total != null && total > 0) {
                                "${formatBytes(item.transferredBytes)} / ${formatBytes(total)}"
                            } else {
                                formatBytes(item.transferredBytes)
                            },
                            modifier = Modifier.weight(1f).padding(top = 6.dp),
                            style = TesseraType.rowMicro,
                            color = tokens.fgDim,
                        )
                        when (item.phase) {
                            TransferPhase.RUNNING, TransferPhase.QUEUED -> TesseraButton(
                                text = "cancel",
                                onClick = { controller.cancel(item.id) },
                                compact = true,
                            )
                            TransferPhase.FAILED, TransferPhase.CANCELLED -> TesseraButton(
                                text = "retry",
                                onClick = { controller.retry(item.id) },
                                compact = true,
                            )
                            else -> Unit
                        }
                    }
                    item.error?.let {
                        TesseraBanner(text = it, modifier = Modifier.padding(top = 8.dp))
                    }
                }
                TesseraHairline(Modifier.padding(start = 18.dp))
            }
        }
    }
}

/** Direction marker for a transfer row: up for uploads, down for downloads. */
@Composable
private fun TransferDirectionGlyph(direction: TransferDirection) {
    androidx.compose.material3.Icon(
        if (direction == TransferDirection.UPLOAD) TesseraIcons.Upload else TesseraIcons.Download,
        contentDescription = null,
        tint = LocalTesseraTokens.current.fgMuted,
        modifier = Modifier.size(15.dp),
    )
}

@Composable
private fun NameDialog(
    title: String,
    label: String,
    initial: String,
    confirmLabel: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var value by remember(initial) { mutableStateOf(initial) }
    TesseraDialog(
        title = title,
        onDismissRequest = onDismiss,
        actions = {
            TesseraButton(text = "Cancel", onClick = onDismiss, compact = true)
            TesseraButton(
                text = confirmLabel,
                onClick = { onConfirm(value) },
                style = TesseraButtonStyle.Primary,
                enabled = value.isNotBlank(),
                compact = true,
            )
        },
    ) {
        TesseraTextField(
            value = value,
            onValueChange = { value = it },
            modifier = Modifier.fillMaxWidth(),
            label = label,
        )
    }
}

@Composable
private fun BrowserToolsDialog(
    currentPath: String,
    homePath: String?,
    initialFilter: String,
    onDismiss: () -> Unit,
    onOpenPath: (String) -> Unit,
    onFilterChange: (String) -> Unit,
) {
    var path by remember(currentPath) { mutableStateOf(currentPath) }
    var filter by remember(initialFilter) { mutableStateOf(initialFilter) }
    TesseraDialog(
        title = "quick open",
        onDismissRequest = onDismiss,
        actions = {
            TesseraButton(text = "Cancel", onClick = onDismiss, compact = true)
            TesseraButton(
                text = "Open",
                onClick = { onOpenPath(path) },
                style = TesseraButtonStyle.Primary,
                enabled = RemoteFilesBrowser.requestedPath(path, homePath) != null,
                compact = true,
            )
        },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            TesseraTextField(
                value = path,
                onValueChange = { path = it },
                modifier = Modifier.fillMaxWidth(),
                label = "Remote path",
                supporting = "Enter an absolute path, ~, or . to navigate directly.",
                inputTestTag = "files-quick-open-path",
            )
            TesseraTextField(
                value = filter,
                onValueChange = { value ->
                    filter = value
                    onFilterChange(value)
                },
                modifier = Modifier.fillMaxWidth(),
                label = "Filter this folder",
                supporting = "Matches file and folder names without changing the remote directory.",
                inputTestTag = "files-filter",
                leading = TesseraIcons.Search,
            )
        }
    }
}

internal fun formatBytes(value: Long): String {
    if (value < 1024) return "$value B"
    val units = arrayOf("KiB", "MiB", "GiB", "TiB")
    var amount = value.toDouble()
    var unit = -1
    while (amount >= 1024 && unit < units.lastIndex) { amount /= 1024; unit += 1 }
    return String.format(Locale.US, "%.1f %s", amount, units[unit])
}
