package com.bambouville.tessera.files

import android.content.ContentResolver
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshFileConnection
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshKeyAuthorizationProvider
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRemoteEntry
import com.bambouville.tessera.networking.SshRemoteEntryKind
import com.bambouville.tessera.networking.SshRouteRequest
import com.bambouville.tessera.networking.connectFiles
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.io.FileOutputStream
import java.util.Locale
import java.util.UUID
import kotlin.random.Random
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.withContext
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

class RemoteFilesController(
    context: Context,
    private val route: suspend () -> SshRouteRequest,
    private val passwordProvider: SshPasswordProvider,
    private val hostKeyPolicy: SshHostKeyPolicy,
    private val keyAuthorizationProvider: SshKeyAuthorizationProvider,
    /** Uses the already authenticated live session when one owns the host. */
    private val liveConnection: (suspend () -> SshFileConnection)? = null,
    private val backend: AndroidSshBackend = AndroidSshBackend(),
    private val recordDiagnostic: (String, Map<String, String>) -> Unit = { _, _ -> },
    /** Days a `paste-` temp upload survives on the host. 0 disables the reaper. */
    private val reaperDays: Int = RemoteFilesConstants.DEFAULT_REAPER_DAYS,
) : RemoteFilesPresenter, AutoCloseable {
    private val resolver = context.applicationContext.contentResolver
    private val presentationCache = RemoteFilePresentationCache(context.applicationContext)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    /**
     * Closes on its own IO scope, never on the thread that disposes this
     * controller, and replaces a connection whose route has gone, such as the
     * live session's after it reconnects.
     */
    private val connection = RemoteFilesConnectionSlot<SshFileConnection>(isUsable = SshFileConnection::isOpen)
    private val stagedUpload = StagedRemoteUpload(
        RemoteUploadCleanupJournal.shared(context.applicationContext),
        recordDiagnostic,
    )
    private val jobs = mutableMapOf<UUID, Job>()
    private var openJob: Job? = null
    private var reaperRan = false
    private val pasteStampFormatter = DateTimeFormatter
        .ofPattern("yyyyMMdd-HHmmss", Locale.US)
        .withZone(ZoneId.systemDefault())

    private fun pasteToken(): String = "%04x".format(Locale.US, Random.nextInt(0x10000))

    private val mutableState = MutableStateFlow(RemoteFilesState())
    override val state: StateFlow<RemoteFilesState> = mutableState.asStateFlow()
    private val mutableTransfers = MutableStateFlow<List<TransferItem>>(emptyList())
    override val transfers: StateFlow<List<TransferItem>> = mutableTransfers.asStateFlow()

    override fun open(path: String?) {
        // Listings supersede each other. Follow can retarget a browse that is
        // still walking the previous directory, and two SFTP walks in flight
        // would land whichever finished last rather than the one just asked
        // for. Cancelling before the state write keeps the newest request the
        // one the user sees.
        openJob?.cancel()
        openJob = scope.launch {
            recordDiagnostic("files_open_start", emptyMap())
            mutableState.update { it.copy(loading = true, error = null) }
            try {
                val bridge = connected()
                val home = mutableState.value.homePath ?: bridge.realPath(".")
                val current = mutableState.value
                val target = RemoteFilesFollow.openTarget(
                    requested = path,
                    followEnabled = current.followEnabled,
                    terminalDirectory = current.terminalDirectory,
                    currentPath = current.currentPath,
                    homePath = home,
                ) ?: home
                val canonical = bridge.realPath(target)
                val entries = bridge.list(canonical).map { entry ->
                    RemoteFileEntry(
                        name = entry.name,
                        path = entry.path,
                        kind = when (entry.kind) {
                            SshRemoteEntryKind.FILE -> RemoteFileKind.FILE
                            SshRemoteEntryKind.DIRECTORY -> RemoteFileKind.DIRECTORY
                            SshRemoteEntryKind.SYMLINK -> RemoteFileKind.SYMLINK
                            SshRemoteEntryKind.OTHER -> RemoteFileKind.OTHER
                        },
                        size = entry.size,
                        modified = entry.modifiedEpochSeconds?.let(Instant::ofEpochSecond),
                        permissions = entry.permissions,
                    )
                }
                // Copy rather than rebuild: follow state outlives any one
                // listing, and a fresh RemoteFilesState would silently drop it.
                mutableState.update {
                    it.copy(
                        currentPath = canonical,
                        homePath = home,
                        entries = entries,
                        loading = false,
                        error = null,
                    )
                }
                recordDiagnostic("files_open_completed", mapOf("count" to entries.size.toString()))
            } catch (failure: Throwable) {
                if (failure !is CancellationException) {
                    val detail = safeMessage(failure)
                    mutableState.update { it.copy(loading = false, error = detail) }
                    recordDiagnostic("files_open_failed", mapOf("detail" to detail))
                }
            }
        }
    }

    override fun openEntry(entry: RemoteFileEntry) {
        if (entry.kind == RemoteFileKind.DIRECTORY || entry.kind == RemoteFileKind.SYMLINK) navigate(entry.path)
    }

    override fun navigate(path: String) {
        setFollowEnabled(false)
        open(path)
    }

    override fun parent() {
        val path = mutableState.value.currentPath ?: return
        if (path == "/") return
        navigate(path.substringBeforeLast('/').ifBlank { "/" })
    }

    override fun toggleFollow() {
        val current = mutableState.value
        // Nothing to toggle while no transport is reporting a cwd; the glyph is
        // already showing that, and flipping a flag nobody can act on would
        // strand the browser in a state the next report silently changes.
        val directory = current.terminalDirectory ?: return
        val enabled = !current.followEnabled
        setFollowEnabled(enabled)
        if (enabled && (directory != current.currentPath || current.loading)) open(directory)
    }

    /**
     * Every cwd report funnels through here, whichever transport found it:
     * tmux pane metadata, the terminal's own OSC 7, or the shell probe. A null
     * report means the signal is gone — the browser stops claiming to follow
     * but keeps the listing it has, which stays browsable.
     */
    fun terminalReportedDirectory(path: String?) {
        val normalized = RemoteFilesFollow.normalized(path)
        val previous = mutableState.value
        if (previous.terminalDirectory == normalized) return
        mutableState.update { it.copy(terminalDirectory = normalized) }
        recordDiagnostic(
            "files_follow_directory",
            mapOf("state" to RemoteFilesFollow.state(normalized, previous.followEnabled).name.lowercase()),
        )
        if (!previous.followEnabled || normalized == null) return
        // Returning to the displayed directory must still supersede an older
        // in-flight listing, or that listing can land after this newer report.
        if (normalized == previous.currentPath && !previous.loading) return
        open(normalized)
    }

    /**
     * Runs one bounded command on the connection the browser already holds, or
     * returns null when it holds none. It deliberately never dials: a follow
     * poll must not authenticate a route on its own — only a real browse does.
     */
    suspend fun probeOnLiveChannel(command: String): String? {
        val live = connection.currentOrNull ?: return null
        return try {
            val transcript = live.executeBoundedCommand(command)
            // rc-file noise splits across both streams, and the probe marks its
            // own line, so merging is what makes the marker findable.
            transcript.standardOutput + "\n" + transcript.standardError
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Throwable) {
            recordDiagnostic("files_follow_probe_failed", mapOf("detail" to safeMessage(failure)))
            null
        }
    }

    private fun setFollowEnabled(enabled: Boolean) {
        if (mutableState.value.followEnabled == enabled) return
        mutableState.update { it.copy(followEnabled = enabled) }
        recordDiagnostic("files_follow_enabled", mapOf("value" to enabled.toString()))
    }

    override fun createDirectory(name: String) = mutate("create_directory") {
        requireValidName(name)
        it.createDirectory(joinPath(requireNotNull(mutableState.value.currentPath), name))
    }

    override fun rename(entry: RemoteFileEntry, name: String) = mutate("rename") {
        requireValidName(name)
        it.rename(entry.path, joinPath(entry.path.substringBeforeLast('/').ifBlank { "/" }, name))
    }

    override fun delete(entry: RemoteFileEntry) = mutate("delete") {
        if (entry.kind == RemoteFileKind.DIRECTORY) it.removeDirectory(entry.path)
        else it.removeFile(entry.path)
    }

    override fun enqueueDownload(entry: RemoteFileEntry, destination: Uri) {
        require(entry.kind == RemoteFileKind.FILE)
        val item = TransferItem(
            direction = TransferDirection.DOWNLOAD,
            displayName = entry.name,
            remotePath = entry.path,
            localUri = destination,
            totalBytes = entry.size,
        )
        enqueue(item) { current ->
            val output = resolver.openOutputStream(destination, "wt") ?: error("Local destination is unavailable")
            output.use { stream ->
                connected().download(entry.path, stream) { transferred, total ->
                    updateTransfer(current.id) { value ->
                        value.copy(transferredBytes = transferred, totalBytes = total ?: value.totalBytes)
                    }
                }
            }
        }
    }

    override fun present(
        entry: RemoteFileEntry,
        action: RemoteFilePresentationAction,
        onPresentationLaunched: () -> Unit,
    ) {
        require(entry.kind == RemoteFileKind.FILE) { "Only files can be opened or shared" }
        if (action == RemoteFilePresentationAction.SHARE && mutableTransfers.value.any {
            it.remotePath == entry.path && RemoteFilesBrowser.isPreparingPresentation(it)
        }) return
        val item = TransferItem(
            direction = TransferDirection.DOWNLOAD,
            displayName = entry.name,
            remotePath = entry.path,
            localUri = null,
            totalBytes = entry.size,
        )
        enqueue(item) { current ->
            val staged = presentationCache.create(entry.name)
            try {
                FileOutputStream(staged).use { stream ->
                    connected().download(entry.path, stream) { transferred, total ->
                        updateTransfer(current.id) { value ->
                            value.copy(transferredBytes = transferred, totalBytes = total ?: value.totalBytes)
                        }
                    }
                }
                val images = if (action == RemoteFilePresentationAction.OPEN && RemoteFileQuickView.isMarkdown(entry.name)) {
                    RemoteMarkdownImages.stage(staged, entry.path, presentationCache::create) { path, output ->
                        connected().download(path, output) { _, _ -> }
                    }
                } else emptyMap()
                presentationCache.dispatch(staged, entry.name, action, images)
                onPresentationLaunched()
                recordDiagnostic(
                    "files_presentation_ready",
                    mapOf("action" to action.name.lowercase(), "bytes" to staged.length().toString()),
                )
            } catch (failure: Throwable) {
                // Do not retain partial downloads if the transfer or intent launch fails.
                runCatching { staged.delete() }
                throw failure
            }
        }
    }

    override fun revealSelectedPath(
        selection: String,
        terminalDirectory: String?,
        onRevealRequested: () -> Unit,
        onFailure: (String) -> Unit,
    ) {
        resolveSelectedPath(selection, terminalDirectory, onFailure) { resolved ->
            val directory = when (resolved.kind) {
                RemoteFileKind.DIRECTORY -> resolved.path
                RemoteFileKind.FILE -> resolved.path.substringBeforeLast('/').ifBlank { "/" }
                RemoteFileKind.SYMLINK, RemoteFileKind.OTHER -> error("unreachable")
            }
            // Publish the target before mounting RemoteFilesScreen. Its normal
            // initial `open()` then observes this same directory instead of
            // racing the reveal with a stale/default location.
            mutableState.update { it.copy(currentPath = directory, error = null) }
            onRevealRequested()
            navigate(directory)
        }
    }

    override fun quickOpenSelectedFile(
        selection: String,
        terminalDirectory: String?,
        onPresentationLaunched: () -> Unit,
        onFailure: (String) -> Unit,
    ) {
        resolveSelectedPath(selection, terminalDirectory, onFailure) { resolved ->
            if (resolved.kind != RemoteFileKind.FILE) {
                selectedPathFailure("The selected path is not a regular file.", onFailure)
                return@resolveSelectedPath
            }
            present(resolved, RemoteFilePresentationAction.OPEN, onPresentationLaunched)
        }
    }

    override fun displayName(source: Uri): String = safeUploadName(resolver.metadata(source).name)

    override fun enqueueUpload(source: Uri, replaceExisting: Boolean) {
        val directory = requireNotNull(mutableState.value.currentPath) { "Open a remote directory first" }
        upload(source, directory, nameOverride = null, replaceExisting = replaceExisting)
    }

    override fun enqueueShareUpload(
        source: Uri,
        destination: ShareUploadDestination,
        replaceExisting: Boolean,
        onUploaded: (String) -> Unit,
        onFailed: (ShareUploadFailure) -> Unit,
    ) {
        scope.launch {
            try {
                val bridge = connected()
                when (destination) {
                    is ShareUploadDestination.SessionCwd -> {
                        val directory = bridge.realPath(destination.path)
                        val name = safeUploadName(resolver.metadata(source).name)
                        // The share-in path has no browser open to show what is
                        // about to be replaced, so ask before overwriting rather
                        // than letting the commit rename fail as a bare error.
                        val existing = if (replaceExisting) null else existingEntry(bridge, joinPath(directory, name))
                        if (existing != null) {
                            onFailed(ShareUploadFailure.Conflict(name, existing))
                            return@launch
                        }
                        upload(
                            source = source,
                            directory = directory,
                            nameOverride = null,
                            replaceExisting = replaceExisting,
                            onUploaded = onUploaded,
                            onFailed = { detail -> onFailed(ShareUploadFailure.Message(detail)) },
                        )
                    }
                    ShareUploadDestination.Temp -> {
                        val home = homeDirectory(bridge)
                        val directory = ShareUploadPaths.tempDirectory(home)
                        ensureTempDirectory(bridge, directory)
                        reapTempUploads(bridge, directory)
                        upload(
                            source = source,
                            directory = directory,
                            nameOverride = ShareUploadPaths.tempFileName(
                                displayName = displayName(source),
                                stamp = pasteStampFormatter.format(Instant.now()),
                                token = pasteToken(),
                            ),
                            // A generated paste name never collides with an
                            // existing remote file, so the replace dance that
                            // protects a user-named upload has nothing to do.
                            replaceExisting = false,
                            onUploaded = onUploaded,
                            onFailed = { detail -> onFailed(ShareUploadFailure.Message(detail)) },
                        )
                    }
                }
            } catch (failure: Throwable) {
                if (failure !is CancellationException) {
                    val detail = safeMessage(failure)
                    recordDiagnostic("files_share_upload_failed", mapOf("detail" to detail))
                    onFailed(ShareUploadFailure.Message(detail))
                }
            }
        }
    }

    /**
     * The native composer owns this await; this controller owns preparation
     * and transfer. Cancelling either lifetime resolves the waiter and stops
     * its exact transfer, including disposal before an upload is enqueued.
     */
    suspend fun uploadAttachment(source: Uri): String {
        val task = scope.async {
            val bridge = connected()
            val directory = ShareUploadPaths.tempDirectory(homeDirectory(bridge))
            ensureTempDirectory(bridge, directory)
            reapTempUploads(bridge, directory)
            val completion = CompletableDeferred<String>()
            val transfer = upload(
                source = source,
                directory = directory,
                nameOverride = ShareUploadPaths.tempFileName(
                    displayName = displayName(source),
                    stamp = pasteStampFormatter.format(Instant.now()),
                    token = pasteToken(),
                ),
                replaceExisting = false,
                onUploaded = { completion.complete(it) },
                onFailed = { completion.completeExceptionally(IllegalStateException(it)) },
            )
            transfer.invokeOnCompletion { failure ->
                if (failure != null) completion.completeExceptionally(failure)
            }
            try { completion.await() } finally {
                withContext(NonCancellable) { transfer.cancelAndJoin() }
            }
        }
        return try { task.await() } finally {
            withContext(NonCancellable) { task.cancelAndJoin() }
        }
    }

    /** The kind already occupying [path], or null when the name is free. */
    private suspend fun existingEntry(bridge: SshFileConnection, path: String): RemoteFileKind? =
        runCatching { bridge.stat(path) }.getOrNull()?.let { entry ->
            when (entry.kind) {
                SshRemoteEntryKind.FILE -> RemoteFileKind.FILE
                SshRemoteEntryKind.DIRECTORY -> RemoteFileKind.DIRECTORY
                SshRemoteEntryKind.SYMLINK -> RemoteFileKind.SYMLINK
                SshRemoteEntryKind.OTHER -> RemoteFileKind.OTHER
            }
        }

    /** Resolves and caches `$HOME` so the temp destination has somewhere to be. */
    private suspend fun homeDirectory(bridge: SshFileConnection): String {
        mutableState.value.homePath?.let { return it }
        val home = bridge.realPath(".")
        mutableState.update { it.copy(homePath = home) }
        return home
    }

    /**
     * `mkdir -p` over SFTP, which has no such flag. Each level is created
     * independently and an already-present level is not an error — the whole
     * point is to converge on the directory existing.
     */
    private suspend fun ensureTempDirectory(bridge: SshFileConnection, directory: String) {
        val segments = directory.trim('/').split('/').filter(String::isNotEmpty)
        var path = ""
        for (segment in segments) {
            path = "$path/$segment"
            runCatching { bridge.createDirectory(path) }
        }
        // Shared media lands here; a world-readable temp dir on a multi-user
        // host would hand it to every other account.
        runCatching { bridge.setPermissions(directory, 0x1C0) } // 0700
        bridge.stat(directory)
    }

    /**
     * The "auto-cleans after N d" promise the ingress sheet makes. Runs once per
     * connection, off the first temp upload, and only ever deletes files
     * carrying the `paste-` prefix inside the temp directory.
     */
    private suspend fun reapTempUploads(bridge: SshFileConnection, directory: String) {
        if (reaperRan || reaperDays <= 0) return
        reaperRan = true
        val cutoff = Instant.now().minusSeconds(reaperDays.toLong() * 86_400L).epochSecond
        val stale = runCatching { bridge.list(directory) }.getOrNull().orEmpty().filter { entry ->
            entry.kind == SshRemoteEntryKind.FILE &&
                ShareUploadPaths.isReapable(entry.name) &&
                (entry.modifiedEpochSeconds ?: Long.MAX_VALUE) < cutoff
        }
        stale.forEach { entry -> runCatching { bridge.removeFile(entry.path) } }
        recordDiagnostic(
            "files_paste_reaper_ran",
            mapOf("days" to reaperDays.toString(), "deleted" to stale.size.toString()),
        )
    }

    private fun upload(
        source: Uri,
        directory: String,
        nameOverride: String?,
        replaceExisting: Boolean,
        onUploaded: (String) -> Unit = {},
        onFailed: (String) -> Unit = {},
    ): Job {
        val metadata = resolver.metadata(source)
        val uploadName = nameOverride ?: safeUploadName(metadata.name)
        val remotePath = joinPath(directory, uploadName)
        val item = TransferItem(
            direction = TransferDirection.UPLOAD,
            displayName = uploadName,
            remotePath = remotePath,
            localUri = source,
            totalBytes = metadata.size,
            replaceExisting = replaceExisting,
        )
        return enqueue(item, onCompleted = { onUploaded(remotePath) }, onFailed = onFailed) { current ->
            // One connection for the whole transfer: its cleanup must still
            // reach the host after close() has detached it from new work.
            val bridge = connected()
            stagedUpload.upload(bridge.uploadFiles(), remotePath, current.id, replaceExisting) { staging ->
                val input = resolver.openInputStream(source) ?: error("Local source is unavailable")
                input.use { stream ->
                    bridge.upload(stream, staging, metadata.size) { transferred, total ->
                        updateTransfer(current.id) { value ->
                            value.copy(transferredBytes = transferred, totalBytes = total ?: value.totalBytes)
                        }
                    }
                }
            }
        }
    }

    override fun cancel(id: UUID) {
        val item = mutableTransfers.value.firstOrNull { it.id == id } ?: return
        if (item.phase != TransferPhase.QUEUED && item.phase != TransferPhase.RUNNING) return
        updateTransfer(id) { it.copy(phase = TransferPhase.CANCELLING) }
        recordTransfer("transfer_cancelling", item)
        jobs.remove(id)?.cancel()
    }

    override fun retry(id: UUID) {
        val item = mutableTransfers.value.firstOrNull { it.id == id } ?: return
        if (item.phase != TransferPhase.FAILED && item.phase != TransferPhase.CANCELLED) return
        when (item.direction) {
            TransferDirection.DOWNLOAD -> {
                val entry = RemoteFileEntry(item.displayName, item.remotePath, RemoteFileKind.FILE, item.totalBytes, null, null)
                enqueueDownload(entry, requireNotNull(item.localUri))
            }
            // Re-derive the directory from the item rather than from the
            // browser: a share upload may have landed in the temp directory
            // while nothing was browsing, and its name is already generated.
            TransferDirection.UPLOAD -> upload(
                source = requireNotNull(item.localUri),
                directory = item.remotePath.substringBeforeLast('/').ifBlank { "/" },
                nameOverride = item.displayName,
                replaceExisting = item.replaceExisting,
            )
        }
        mutableTransfers.update { values -> values.filterNot { it.id == id } }
    }

    override fun clearFinished() {
        mutableTransfers.update { values ->
            values.filter { it.phase in setOf(TransferPhase.QUEUED, TransferPhase.RUNNING, TransferPhase.CANCELLING) }
        }
    }

    /**
     * Stops all work at once. Compose disposal calls this on the main thread,
     * and an SFTP close blocks until the server answers — up to the SSH
     * timeout on a dead link — so the connection is detached here and closed
     * on IO. It closes once cancelled uploads have removed their staging file
     * or put back an original they moved aside, or once the slot's drain
     * budget runs out; the journal retries what that cuts off.
     */
    override fun close() {
        scope.cancel()
        connection.close(drain = scope.coroutineContext[Job])
    }

    /** Stop attachment work immediately on disposal; its owner awaits cleanup. */
    fun cancelPendingTransfers() { scope.cancel() }

    /**
     * Called on Main by the attachment owner, including from a cancelled job.
     * Unlike [close], cancelled transfers finish their cleanup on the open
     * connection first; it returns once every connection this controller
     * handed off, including one [close] already detached, has closed.
     */
    suspend fun closeAfterTransfers() {
        scope.cancel()
        withContext(NonCancellable) {
            scope.coroutineContext[Job]?.join()
            connection.closeAndJoin()
        }
    }

    private fun mutate(command: String, operation: suspend (SshFileConnection) -> Unit) {
        scope.launch {
            recordDiagnostic("files_mutation_start", mapOf("command" to command))
            mutableState.update { it.copy(loading = true, error = null) }
            try {
                operation(connected())
                recordDiagnostic("files_mutation_completed", mapOf("command" to command))
                open(mutableState.value.currentPath)
            } catch (failure: Throwable) {
                if (failure !is CancellationException) {
                    val detail = safeMessage(failure)
                    mutableState.update { it.copy(loading = false, error = detail) }
                    recordDiagnostic(
                        "files_mutation_failed",
                        mapOf("command" to command, "detail" to detail),
                    )
                }
            }
        }
    }

    private fun enqueue(
        item: TransferItem,
        onCompleted: () -> Unit = {},
        onFailed: (String) -> Unit = {},
        operation: suspend (TransferItem) -> Unit,
    ): Job {
        mutableTransfers.update { it + item }
        recordTransfer("transfer_queued", item)
        val job = scope.launch(start = CoroutineStart.LAZY) {
            updateTransfer(item.id) { it.copy(phase = TransferPhase.RUNNING) }
            recordTransfer("transfer_started", item)
            try {
                operation(item)
                updateTransfer(item.id) { it.copy(phase = TransferPhase.COMPLETED) }
                recordTransfer("transfer_completed", item)
                onCompleted()
                // A share upload can land while nothing is browsing; only
                // refresh a listing that actually exists.
                mutableState.value.currentPath?.let(::open)
            } catch (_: CancellationException) {
                updateTransfer(item.id) { it.copy(phase = TransferPhase.CANCELLED) }
                recordTransfer("transfer_cancelled", item)
                onFailed(CANCELLED_DETAIL)
            } catch (failure: Throwable) {
                val detail = safeMessage(failure)
                updateTransfer(item.id) { it.copy(phase = TransferPhase.FAILED, error = detail) }
                recordTransfer("transfer_failed", item, detail)
                onFailed(detail)
            } finally {
                jobs.remove(item.id)
            }
        }
        jobs[item.id] = job
        job.start()
        return job
    }

    private suspend fun connected(): SshFileConnection = connection.obtain {
        (liveConnection?.invoke() ?: backend.connectFiles(
            route(),
            passwordProvider,
            hostKeyPolicy,
            keyAuthorizationProvider,
        )).also { opened ->
            // Each new connection first finishes what earlier ones could not:
            // staging files and moved-aside originals of interrupted uploads.
            scope.launch { stagedUpload.retryPending(opened.uploadFiles()) }
        }
    }

    private fun SshFileConnection.uploadFiles(): RemoteUploadFiles {
        val connection = this
        return object : RemoteUploadFiles {
            override val route: String get() = connection.routeIdentity
            override suspend fun exists(path: String) = connection.exists(path)
            override suspend fun rename(from: String, to: String) = connection.rename(from, to)
            override suspend fun remove(path: String) = connection.removeFile(path)
        }
    }

    /**
     * Resolves a terminal-selected token only through the authenticated SFTP
     * connection. The local parser is deliberately conservative, canonicalize
     * defeats lexical aliases, and stat makes every caller decide from the
     * remote object's current type rather than from terminal text.
     */
    private fun resolveSelectedPath(
        selection: String,
        terminalDirectory: String?,
        onFailure: (String) -> Unit,
        onResolved: (RemoteFileEntry) -> Unit,
    ) {
        scope.launch {
            try {
                // Both readings of the selection: the strict token, then the
                // whitespace-collapsed rejoin for a path an agent's wrapped
                // TUI output broke across rows.
                val candidates = RemoteSelectionPathResolver.pathCandidates(selection)
                val candidate = candidates.firstOrNull()
                    ?: return@launch selectedPathFailure("Selection doesn't look like a path.", onFailure)
                val bridge = connected()
                val home = mutableState.value.homePath ?: bridge.realPath(".")
                if (mutableState.value.homePath != home) {
                    mutableState.update { it.copy(homePath = home) }
                }
                val absolutes = candidates.mapNotNull {
                    RemoteSelectionPathResolver.expand(
                        it,
                        homePath = home,
                        currentDirectory = terminalDirectory ?: mutableState.value.currentPath,
                    )
                }
                if (absolutes.isEmpty()) {
                    return@launch selectedPathFailure(
                        "Can't resolve $candidate — no terminal directory is available for a relative path.",
                        onFailure,
                    )
                }
                val resolved = resolveRemotePath(bridge, absolutes)
                    ?: return@launch selectedPathFailure("Not found: ${absolutes.first()}", onFailure)
                val canonical = resolved.first
                val stat = resolved.second
                val kind = when (stat.kind) {
                    SshRemoteEntryKind.FILE -> RemoteFileKind.FILE
                    SshRemoteEntryKind.DIRECTORY -> RemoteFileKind.DIRECTORY
                    // `stat` normally follows symlinks. If a server still
                    // reports one, fail closed rather than presenting an
                    // ambiguous target selected from terminal text.
                    SshRemoteEntryKind.SYMLINK, SshRemoteEntryKind.OTHER -> return@launch selectedPathFailure(
                        "Unsupported remote file type: $canonical",
                        onFailure,
                    )
                }
                onResolved(
                    RemoteFileEntry(
                        name = stat.name,
                        path = canonical,
                        kind = kind,
                        size = stat.size,
                        modified = stat.modifiedEpochSeconds?.let(Instant::ofEpochSecond),
                        permissions = stat.permissions,
                    ),
                )
            } catch (failure: Throwable) {
                if (failure !is CancellationException) selectedPathFailure(safeMessage(failure), onFailure)
            }
        }
    }

    /**
     * Every reading of the selection is stat'd exactly first, and only once
     * all of them miss does the whitespace-tolerant walk run. Exact spelling
     * therefore always wins — the fallback can never shadow a file that is
     * really there.
     */
    private suspend fun resolveRemotePath(
        bridge: SshFileConnection,
        absolutes: List<String>,
    ): Pair<String, SshRemoteEntry>? {
        absolutes.forEach { absolute -> statOrNull(bridge, absolute)?.let { return it } }
        absolutes.forEach { absolute ->
            val tolerant = RemoteTolerantPathWalk.resolve(absolute, SshRemoteEntry::name) {
                listOrNull(bridge, it)
            }
            if (tolerant != null) statOrNull(bridge, tolerant)?.let { return it }
        }
        return null
    }

    private suspend fun statOrNull(
        bridge: SshFileConnection,
        path: String,
    ): Pair<String, SshRemoteEntry>? = try {
        val canonical = bridge.realPath(path)
        canonical to bridge.stat(canonical)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Throwable) {
        null
    }

    private suspend fun listOrNull(
        bridge: SshFileConnection,
        path: String,
    ): List<SshRemoteEntry>? = try {
        bridge.list(path)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Throwable) {
        null
    }

    private fun selectedPathFailure(message: String, onFailure: (String) -> Unit) {
        mutableState.update { it.copy(error = message) }
        recordDiagnostic("files_selected_path_failed", emptyMap())
        onFailure(message)
    }

    private fun updateTransfer(id: UUID, transform: (TransferItem) -> TransferItem) {
        mutableTransfers.update { values -> values.map { if (it.id == id) transform(it) else it } }
    }

    private fun recordTransfer(code: String, item: TransferItem, detail: String? = null) {
        val values = buildMap {
            put("direction", item.direction.name.lowercase())
            item.totalBytes?.let { put("bytes", it.toString()) }
            detail?.let { put("detail", it) }
        }
        recordDiagnostic(code, values)
    }

    private fun ContentResolver.metadata(uri: Uri): LocalMetadata {
        var name: String? = null
        var size: Long? = null
        query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                name = cursor.string(OpenableColumns.DISPLAY_NAME)
                size = cursor.longOrNull(OpenableColumns.SIZE)
            }
        }
        return LocalMetadata(name?.takeIf(String::isNotBlank) ?: "upload-${UUID.randomUUID()}", size)
    }

    private fun Cursor.string(column: String): String? =
        getColumnIndex(column).takeIf { it >= 0 && !isNull(it) }?.let(::getString)

    private fun Cursor.longOrNull(column: String): Long? =
        getColumnIndex(column).takeIf { it >= 0 && !isNull(it) }?.let(::getLong)

    private fun requireValidName(name: String) {
        require(name.isNotBlank() && name != "." && name != ".." && '/' !in name && name.none(Char::isISOControl)) {
            "Enter a valid file name"
        }
    }

    private fun joinPath(directory: String, name: String): String =
        if (directory == "/") "/$name" else "${directory.trimEnd('/')}/$name"

    private fun safeUploadName(providerName: String): String {
        val normalized = providerName
            .filterNot { it == '/' || it == '\\' || it.isISOControl() }
            .trim()
            .take(255)
        return normalized.takeUnless { it.isBlank() || it == "." || it == ".." }
            ?: "upload-${UUID.randomUUID()}"
    }

    private fun safeMessage(failure: Throwable): String =
        failure.message
            ?.replace(Regex("(?i)(password|passphrase|secret|token)[=:][^ ]+"), "$1=<redacted>")
            ?.take(300)
            ?: failure::class.java.simpleName

    private data class LocalMetadata(val name: String, val size: Long?)

    private companion object {
        const val CANCELLED_DETAIL = "The upload was cancelled."
    }
}
