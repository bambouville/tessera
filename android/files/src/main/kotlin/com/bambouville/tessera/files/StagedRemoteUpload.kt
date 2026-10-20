package com.bambouville.tessera.files

import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** The remote operations a staged upload needs; one SFTP connection in the app. */
internal interface RemoteUploadFiles {
    /** Journal key: which remote filesystem these paths belong to. */
    val route: String
    suspend fun exists(path: String): Boolean
    suspend fun rename(from: String, to: String)
    suspend fun remove(path: String)
}

/**
 * Uploads through a hidden staging file beside the destination, renamed into
 * place once complete, so the destination never holds a partial file. SFTP v3
 * cannot rename over an existing file, so a replace first moves the original
 * aside to a hidden backup and deletes it once the new file is in place. This
 * mirrors iOS's TransferTask staged upload and replacement recovery.
 *
 * Both files are journaled before they exist. Failure or cancellation removes
 * the staging file and puts back a moved-aside original, outside the
 * cancelled work and on the same connection. Whatever that cannot finish, on
 * a dead link or in a killed process, stays journaled for [retryPending].
 */
internal class StagedRemoteUpload(
    private val journal: RemoteUploadCleanupJournal,
    private val recordDiagnostic: (String, Map<String, String>) -> Unit = { _, _ -> },
) {
    /** [write] fills the staging path it is given; [token] makes the hidden names unique. */
    suspend fun upload(
        files: RemoteUploadFiles,
        finalPath: String,
        token: UUID,
        replaceExisting: Boolean,
        write: suspend (stagingPath: String) -> Unit,
    ) {
        val staging = stagingPath(finalPath, token)
        val stagingRecord = journal.register(files.route, staging)
        try {
            write(staging)
            currentCoroutineContext().ensureActive()
            if (replaceExisting) replace(files, staging, finalPath, token) else commit(files, staging, finalPath)
        } catch (failure: Throwable) {
            withContext(NonCancellable) { settle(stagingRecord, "staging") { removeIfPresent(files, staging) } }
            throw failure
        }
        journal.remove(stagingRecord)
    }

    /**
     * Finishes what earlier connections to this route could not: removes
     * staging files and restores or deletes moved-aside originals. Records an
     * upload in progress owns are skipped; a failure leaves the record for
     * the next connection.
     */
    suspend fun retryPending(files: RemoteUploadFiles) {
        val claimed = journal.claimInactive(files.route)
        try {
            for (pending in claimed) {
                val restoreTo = pending.restoreToRemotePath
                val kind = if (restoreTo == null) "remove" else "restore"
                try {
                    if (restoreTo == null) removeIfPresent(files, pending.remotePath) else recover(files, pending.remotePath, restoreTo)
                    journal.remove(pending.id)
                    recordDiagnostic("files_upload_cleanup_retried", mapOf("kind" to kind))
                } catch (failure: CancellationException) {
                    throw failure
                } catch (failure: Throwable) {
                    recordDiagnostic("files_upload_cleanup_retry_deferred", mapOf("kind" to kind, "error" to failure.javaClass.simpleName))
                }
            }
        } finally {
            // A removed record ignores this; any other goes back to the journal.
            claimed.forEach { journal.deactivate(it.id) }
        }
    }

    private suspend fun commit(files: RemoteUploadFiles, staging: String, finalPath: String) {
        try {
            files.rename(staging, finalPath)
        } catch (failure: Throwable) {
            if (!committed(files, staging, finalPath)) throw failure
        }
    }

    private suspend fun replace(files: RemoteUploadFiles, staging: String, finalPath: String, token: UUID) {
        val backup = backupPath(finalPath, token)
        val backupRecord = journal.register(files.route, backup, restoreToRemotePath = finalPath)
        try {
            try {
                if (files.exists(finalPath)) files.rename(finalPath, backup)
                files.rename(staging, finalPath)
            } catch (failure: Throwable) {
                if (!committed(files, staging, finalPath)) {
                    withContext(NonCancellable) { settle(backupRecord, "backup") { recover(files, backup, finalPath) } }
                    throw failure
                }
            }
            // The new file is in place, so the original it replaced is only
            // ever deleted now, whatever later happens to the destination.
            journal.markReplaced(backupRecord)
            withContext(NonCancellable) { settle(backupRecord, "backup") { removeIfPresent(files, backup) } }
        } finally {
            journal.deactivate(backupRecord)
        }
    }

    /**
     * A reply can be lost after the server applied a rename, and cancellation
     * can land after it did. Only the staging file gone from beside a present
     * destination proves the upload committed.
     */
    private suspend fun committed(files: RemoteUploadFiles, staging: String, finalPath: String): Boolean =
        withContext(NonCancellable) {
            runCatching { !files.exists(staging) && files.exists(finalPath) }.getOrDefault(false)
        }

    /** Runs one cleanup step; its record goes on success and stays journaled otherwise. */
    private suspend fun settle(id: UUID, kind: String, step: suspend () -> Unit) {
        try {
            step()
            journal.remove(id)
        } catch (failure: Throwable) {
            journal.deactivate(id)
            recordDiagnostic("files_upload_cleanup_deferred", mapOf("kind" to kind, "error" to failure.javaClass.simpleName))
        }
    }

    companion object {
        fun stagingPath(finalPath: String, token: UUID): String =
            sibling(finalPath) { ".$it.tessera-upload-$token.partial" }

        fun backupPath(finalPath: String, token: UUID): String =
            sibling(finalPath) { ".$it.tessera-replaced-$token.backup" }

        private fun sibling(path: String, name: (String) -> String): String {
            val slash = path.lastIndexOf('/')
            return path.substring(0, slash + 1) + name(path.substring(slash + 1).ifEmpty { "upload" })
        }

        /** SFTP remove is not `rm -f`: a missing file is an error, and fine here. */
        private suspend fun removeIfPresent(files: RemoteUploadFiles, path: String) {
            try {
                files.remove(path)
            } catch (failure: Throwable) {
                if (files.exists(path)) throw failure
            }
        }

        /** Puts a moved-aside original back if nothing replaced it, and deletes it if something did. */
        private suspend fun recover(files: RemoteUploadFiles, backup: String, finalPath: String) {
            if (!files.exists(backup)) return
            if (files.exists(finalPath)) {
                removeIfPresent(files, backup)
                return
            }
            try {
                files.rename(backup, finalPath)
            } catch (failure: Throwable) {
                if (files.exists(backup) || !files.exists(finalPath)) throw failure
            }
        }
    }
}
