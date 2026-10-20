package com.bambouville.tessera.files

import android.net.Uri
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.flow.StateFlow

enum class RemoteFileKind { FILE, DIRECTORY, SYMLINK, OTHER }

data class RemoteFileEntry(
    val name: String,
    val path: String,
    val kind: RemoteFileKind,
    val size: Long?,
    val modified: Instant?,
    val permissions: Int?,
) {
    val id: String get() = path
    val isHidden: Boolean get() = name.startsWith('.')
}

enum class TransferDirection { DOWNLOAD, UPLOAD }
enum class TransferPhase { QUEUED, RUNNING, CANCELLING, COMPLETED, FAILED, CANCELLED }

data class TransferItem(
    val id: UUID = UUID.randomUUID(),
    val direction: TransferDirection,
    val displayName: String,
    val remotePath: String,
    val localUri: Uri?,
    val phase: TransferPhase = TransferPhase.QUEUED,
    val transferredBytes: Long = 0,
    val totalBytes: Long? = null,
    val replaceExisting: Boolean = false,
    val error: String? = null,
)

data class RemoteFilesState(
    val currentPath: String? = null,
    val homePath: String? = null,
    val entries: List<RemoteFileEntry> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    /** Last cwd the terminal reported, whatever transport discovered it. */
    val terminalDirectory: String? = null,
    val followEnabled: Boolean = true,
) {
    val followState: RemoteFilesFollowState
        get() = RemoteFilesFollow.state(terminalDirectory, followEnabled)
}

object RemoteFilesConstants {
    const val TEMP_DIRECTORY = ".cache/tessera"
    const val PASTE_PREFIX = "paste-"
    const val DEFAULT_REAPER_DAYS = 7
}

/**
 * Everything `RemoteFilesScreen` needs from a files session.
 *
 * The screen binds to this rather than to `RemoteFilesController` so the debug
 * visual harness can drive the real composables from canned state — browsing,
 * transfer progress, and error presentation are otherwise reachable only by
 * opening a live SSH connection, which automation must never do.
 */
interface RemoteFilesPresenter {
    val state: StateFlow<RemoteFilesState>
    val transfers: StateFlow<List<TransferItem>>

    fun open(path: String? = null)
    fun openEntry(entry: RemoteFileEntry)
    /**
     * The user chose this directory. Unlike [open] — which refresh and the
     * initial listing also use — navigating breaks follow, because the browser
     * must never fight the person driving it back to the terminal's cwd.
     */
    fun navigate(path: String)
    /** Re-enables follow (snapping to the terminal's cwd) or breaks it. */
    fun toggleFollow()
    fun parent()
    fun createDirectory(name: String)
    fun rename(entry: RemoteFileEntry, name: String)
    fun delete(entry: RemoteFileEntry)
    fun enqueueDownload(entry: RemoteFileEntry, destination: Uri)
    /**
     * Stages a remote file in the app cache, then gives another Android app a
     * short-lived read-only content URI. These actions deliberately never expose
     * an SSH path or a writable file URI to the receiving app.
     */
    fun present(
        entry: RemoteFileEntry,
        action: RemoteFilePresentationAction,
        onPresentationLaunched: () -> Unit = {},
    )
    /**
     * Resolves a terminal selection over this session's authenticated file
     * connection and asks the session UI to show Files at its directory.
     */
    fun revealSelectedPath(
        selection: String,
        terminalDirectory: String? = null,
        onRevealRequested: () -> Unit = {},
        onFailure: (String) -> Unit = {},
    )
    /**
     * Resolves a terminal selection and opens only a verified regular file
     * using the same private staging/cache path as Files row actions.
     */
    fun quickOpenSelectedFile(
        selection: String,
        terminalDirectory: String? = null,
        onPresentationLaunched: () -> Unit = {},
        onFailure: (String) -> Unit = {},
    )
    fun displayName(source: Uri): String
    fun enqueueUpload(source: Uri, replaceExisting: Boolean = false)

    /**
     * Share-in upload. Unlike [enqueueUpload] it does not need the browser to
     * be open on a directory: the destination is chosen in the ingress sheet
     * before any session exists, and the resolved absolute path comes back so
     * the caller can type it into a live terminal.
     */
    fun enqueueShareUpload(
        source: Uri,
        destination: ShareUploadDestination,
        replaceExisting: Boolean = false,
        onUploaded: (String) -> Unit = {},
        onFailed: (ShareUploadFailure) -> Unit = {},
    )
    fun cancel(id: UUID)
    fun retry(id: UUID)
    fun clearFinished()
}

enum class RemoteFilePresentationAction { OPEN, SHARE }

/**
 * Contract between Remote Files and a live terminal. The session feature owns
 * input delivery; files only supplies a fully resolved, shell-safe path payload.
 */
fun interface RemoteTerminalPathSink {
    fun insert(path: RemoteTerminalPath)
}

data class RemoteTerminalPath(val rawPath: String) {
    init {
        require(rawPath.isNotBlank()) { "A terminal path cannot be blank" }
        require(rawPath.none { it.isISOControl() }) { "A terminal path cannot contain control characters" }
    }

    /** POSIX single-quote encoding, suitable for insertion into a shell command. */
    val shellQuoted: String = "'${rawPath.replace("'", "'\"'\"'")}'"
}
