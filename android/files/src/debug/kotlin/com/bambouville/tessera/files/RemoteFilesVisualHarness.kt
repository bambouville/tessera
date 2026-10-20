package com.bambouville.tessera.files

import android.net.Uri
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext

/**
 * Debug-only Remote Files harness.
 *
 * [RemoteFilesScreen] binds to [RemoteFilesPresenter], so the real screen — rows,
 * path bar, empty/loading/error presentation, and the transfer pane — can be driven
 * from canned state instead of an SFTP side channel. Every scene below is a state a
 * user reaches only mid-connection, which is exactly why they went unproven in the
 * previous visual pass.
 */
enum class FilesHarnessScene(val slug: String, val label: String) {
    Browse("files", "files"),
    Empty("files-empty", "empty"),
    Loading("files-loading", "loading"),
    Error("files-error", "error"),
    Transfers("transfers", "transfers"),
    ShareIngress("share-ingress", "share in"),
    ShareIngressText("share-ingress-text", "share text"),
    TransferStrip("transfer-strip", "strip"),
}

private fun entry(
    name: String,
    kind: RemoteFileKind,
    size: Long?,
) = RemoteFileEntry(
    name = name,
    path = "/home/dev/$name",
    kind = kind,
    size = size,
    modified = Instant.parse("2026-08-20T09:14:00Z"),
    permissions = null,
)

private val browseEntries = listOf(
    entry("projects", RemoteFileKind.DIRECTORY, null),
    entry("backups", RemoteFileKind.DIRECTORY, null),
    entry(".config", RemoteFileKind.DIRECTORY, null),
    entry("current", RemoteFileKind.SYMLINK, null),
    entry("deploy-notes-2026-08.md", RemoteFileKind.FILE, 18_432),
    entry("relay.service", RemoteFileKind.FILE, 1_204),
    entry("nightly-snapshot.tar.zst", RemoteFileKind.FILE, 734_003_200),
    entry("id_ed25519.pub", RemoteFileKind.FILE, 96),
)

/** What the strip shows mid-share: a generated paste name, part-way up. */
private val harnessStripTransfers = listOf(
    TransferItem(
        id = UUID.fromString("00000000-0000-4000-8000-0000000000f1"),
        direction = TransferDirection.UPLOAD,
        displayName = "paste-20260905-122818-0cd5.png",
        remotePath = "/home/dev/.cache/tessera/paste-20260905-122818-0cd5.png",
        localUri = null,
        phase = TransferPhase.RUNNING,
        transferredBytes = 1_293_824,
        totalBytes = 3_884_112,
    ),
    TransferItem(
        id = UUID.fromString("00000000-0000-4000-8000-0000000000f2"),
        direction = TransferDirection.UPLOAD,
        displayName = "IMG_20260905_101530.heic",
        remotePath = "/home/dev/.cache/tessera/IMG_20260905_101530.heic",
        localUri = null,
        phase = TransferPhase.QUEUED,
        transferredBytes = 0,
        totalBytes = 2_201_440,
    ),
)

private val harnessTransfers = listOf(
    TransferItem(
        id = UUID.fromString("00000000-0000-4000-8000-00000000000a"),
        direction = TransferDirection.UPLOAD,
        displayName = "nightly-snapshot.tar.zst",
        remotePath = "/home/dev/nightly-snapshot.tar.zst",
        localUri = null,
        phase = TransferPhase.RUNNING,
        transferredBytes = 291_504_128,
        totalBytes = 734_003_200,
    ),
    TransferItem(
        id = UUID.fromString("00000000-0000-4000-8000-00000000000b"),
        direction = TransferDirection.DOWNLOAD,
        displayName = "deploy-notes-2026-08.md",
        remotePath = "/home/dev/deploy-notes-2026-08.md",
        localUri = null,
        phase = TransferPhase.COMPLETED,
        transferredBytes = 18_432,
        totalBytes = 18_432,
    ),
    TransferItem(
        id = UUID.fromString("00000000-0000-4000-8000-00000000000c"),
        direction = TransferDirection.DOWNLOAD,
        displayName = "relay.service",
        remotePath = "/home/dev/relay.service",
        localUri = null,
        phase = TransferPhase.FAILED,
        transferredBytes = 512,
        totalBytes = 1_204,
        error = "The remote host closed the transfer channel before the file was complete.",
    ),
)

/**
 * What the harness stages for a quick view. The Markdown sample deliberately
 * covers every block the shared parser can emit, so one screenshot proves the
 * renderer rather than the one construct a note happened to use.
 */
private fun harnessPreviewContent(name: String): String =
    if (RemoteFileQuickView.isMarkdown(name)) HARNESS_MARKDOWN else HARNESS_PLAIN_TEXT

private val HARNESS_MARKDOWN = """
# Deploy notes — 2026-08

Rolled the **relay** tier to `v4.2.0`. Read the [runbook](https://example.com/runbook)
before the next window; the *old* rollback step is ~~no longer safe~~.

## Checks

- [x] canary held for 30 minutes
- [x] error budget untouched
- [ ] archive the previous image

1. drain the pool
2. swap the unit file
3. re-arm alerting

> Roll back on any 5xx above baseline. The window closes at 02:00 UTC.

### Timings

| stage   | duration | owner |
| ------- | -------: | :---: |
| drain   |     4m12 |  ops  |
| swap    |     0m48 |  ops  |
| verify  |    11m05 |  sre  |

```sh
systemctl restart relay.service
journalctl -u relay.service -n 50 --no-pager
```

---

![topology diagram](https://example.com/topology.png)
""".trimIndent()

private val HARNESS_PLAIN_TEXT = """
[Unit]
Description=Relay
After=network-online.target

[Service]
ExecStart=/usr/local/bin/relay --config /etc/relay.toml
Restart=on-failure
""".trimIndent()

/**
 * A presenter that only remembers. Navigation between the seeded directories works;
 * anything that would touch the network is a no-op, so the harness cannot open a
 * connection even by accident.
 */
private class FakeRemoteFilesPresenter(scene: FilesHarnessScene) : RemoteFilesPresenter {
    var quickViewEntry by mutableStateOf<RemoteFileEntry?>(null)

    private val mutableState = MutableStateFlow(
        when (scene) {
            FilesHarnessScene.Browse,
            FilesHarnessScene.Transfers,
            FilesHarnessScene.ShareIngress,
            FilesHarnessScene.ShareIngressText,
            FilesHarnessScene.TransferStrip,
            -> RemoteFilesState(
                currentPath = "/home/dev",
                homePath = "/home/dev",
                entries = browseEntries,
                // Follow is live here so the chip renders its following/manual
                // pair; the scenes below leave it null for the unavailable one.
                terminalDirectory = "/home/dev",
            )
            FilesHarnessScene.Empty -> RemoteFilesState(
                currentPath = "/home/dev/backups",
                homePath = "/home/dev",
                entries = emptyList(),
            )
            FilesHarnessScene.Loading -> RemoteFilesState(loading = true)
            FilesHarnessScene.Error -> RemoteFilesState(
                currentPath = "/home/dev/projects",
                homePath = "/home/dev",
                entries = emptyList(),
                error = "Permission denied reading /home/dev/projects.",
            )
        },
    )
    private val mutableTransfers = MutableStateFlow(
        if (scene == FilesHarnessScene.Transfers) harnessTransfers else emptyList(),
    )


    override val state: StateFlow<RemoteFilesState> = mutableState.asStateFlow()
    override val transfers: StateFlow<List<TransferItem>> = mutableTransfers.asStateFlow()

    override fun open(path: String?) = Unit
    override fun openEntry(entry: RemoteFileEntry) {
        if (entry.kind == RemoteFileKind.DIRECTORY || entry.kind == RemoteFileKind.SYMLINK) navigate(entry.path)
    }
    override fun navigate(path: String) {
        mutableState.value = mutableState.value.copy(
            currentPath = path,
            entries = emptyList(),
            followEnabled = false,
        )
    }
    override fun toggleFollow() {
        val current = mutableState.value
        val directory = current.terminalDirectory ?: return
        val enabled = !current.followEnabled
        mutableState.value = current.copy(
            currentPath = if (enabled) directory else current.currentPath,
            entries = if (enabled) browseEntries else current.entries,
            followEnabled = enabled,
        )
    }
    override fun parent() {
        val path = mutableState.value.currentPath ?: return
        navigate(path.substringBeforeLast('/').ifBlank { "/" })
        mutableState.value = mutableState.value.copy(entries = browseEntries)
    }
    override fun createDirectory(name: String) = Unit
    override fun rename(entry: RemoteFileEntry, name: String) = Unit
    override fun delete(entry: RemoteFileEntry) {
        mutableState.value = mutableState.value.copy(
            entries = mutableState.value.entries.filterNot { it.id == entry.id },
        )
    }
    override fun enqueueDownload(entry: RemoteFileEntry, destination: Uri) = Unit
    override fun present(
        entry: RemoteFileEntry,
        action: RemoteFilePresentationAction,
        onPresentationLaunched: () -> Unit,
    ) {
        if (action == RemoteFilePresentationAction.OPEN) quickViewEntry = entry
    }
    override fun revealSelectedPath(
        selection: String,
        terminalDirectory: String?,
        onRevealRequested: () -> Unit,
        onFailure: (String) -> Unit,
    ) = onFailure("Terminal selection actions require a live Files connection.")
    override fun quickOpenSelectedFile(
        selection: String,
        terminalDirectory: String?,
        onPresentationLaunched: () -> Unit,
        onFailure: (String) -> Unit,
    ) = onFailure("Terminal selection actions require a live Files connection.")
    override fun displayName(source: Uri): String = "shared-file"
    override fun enqueueUpload(source: Uri, replaceExisting: Boolean) = Unit
    override fun enqueueShareUpload(
        source: Uri,
        destination: ShareUploadDestination,
        replaceExisting: Boolean,
        onUploaded: (String) -> Unit,
        onFailed: (ShareUploadFailure) -> Unit,
    ) = onFailed(ShareUploadFailure.Message("Share uploads require a live Files connection."))
    override fun cancel(id: UUID) {
        mutableTransfers.value = mutableTransfers.value.map {
            if (it.id == id) it.copy(phase = TransferPhase.CANCELLED) else it
        }
    }
    override fun retry(id: UUID) {
        mutableTransfers.value = mutableTransfers.value.map {
            if (it.id == id) it.copy(phase = TransferPhase.QUEUED, transferredBytes = 0) else it
        }
    }
    override fun clearFinished() {
        mutableTransfers.value = mutableTransfers.value.filter {
            it.phase == TransferPhase.QUEUED || it.phase == TransferPhase.RUNNING
        }
    }
}

/**
 * Host rows for the ingress harness. Every status the sheet can render is
 * present at once — the live combination is otherwise reachable only by opening
 * real connections, which automation must never do.
 */
private val harnessShareTargets = listOf(
    ShareUploadTarget(
        id = "h-active",
        label = "build-box",
        detail = "dev@build.example.net:22",
        isConnected = true,
        isActiveSession = true,
        sessionCwd = "/srv/deploy/releases/2026-09-05",
    ),
    ShareUploadTarget(
        id = "h-connected",
        label = "media-01",
        detail = "dev@media-01.example.net:22",
        isConnected = true,
    ),
    ShareUploadTarget(
        id = "h-connecting",
        label = "edge-eu",
        detail = "ops@edge-eu.example.net:2222",
        isConnecting = true,
    ),
    ShareUploadTarget(
        id = "h-failed",
        label = "archive",
        detail = "dev@archive.example.net:22",
        isFailed = true,
    ),
    ShareUploadTarget(
        id = "h-saved",
        label = "zeta",
        detail = "root@zeta.example.net:22",
    ),
)

@Composable
fun RemoteFilesVisualHarness(scene: FilesHarnessScene, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val presenter = remember(scene) { FakeRemoteFilesPresenter(scene) }
    RemoteFilesScreen(
        controller = presenter,
        modifier = modifier,
    )
    // Quick view runs its real path here — stage, then dispatch — rather than a
    // stand-in dialog. Everything after the download is transport-independent,
    // so this is the whole of what a tap on a file does on a live session.
    presenter.quickViewEntry?.let { entry ->
        LaunchedEffect(entry.id) {
            presenter.quickViewEntry = null
            withContext(Dispatchers.IO) {
                runCatching {
                    val cache = RemoteFilePresentationCache(context)
                    val staged = cache.create(entry.name)
                    staged.writeText(harnessPreviewContent(entry.name))
                    cache.dispatch(staged, entry.name, RemoteFilePresentationAction.OPEN)
                }
            }
        }
    }
    if (scene == FilesHarnessScene.TransferStrip) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            RemoteTransferStrip(
                items = harnessStripTransfers,
                onCancel = {},
                onOpenPanel = {},
                modifier = Modifier.padding(12.dp),
            )
        }
    }
    val textShare = scene == FilesHarnessScene.ShareIngressText
    if (scene == FilesHarnessScene.ShareIngress || textShare) {
        var dismissed by remember(scene) { mutableStateOf(false) }
        if (!dismissed) {
            ShareUploadSheet(
                fileNames = if (textShare) emptyList() else listOf("IMG_20260905_101530.heic"),
                totalBytes = if (textShare) null else 3_884_112L,
                sharedText = if (textShare) "https://example.com/release-notes" else null,
                targets = harnessShareTargets,
                reaperDays = RemoteFilesConstants.DEFAULT_REAPER_DAYS,
                initialTargetId = null,
                rememberedDestination = { null },
                onRememberDestination = { _, _ -> },
                onConfirm = { dismissed = true },
                onCancel = { dismissed = true },
            )
        }
    }
}
