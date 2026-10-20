package com.bambouville.tessera.feature.session

import android.content.Context
import android.net.Uri
import android.util.Base64
import android.util.Log
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.files.RemoteFilesController
import com.bambouville.tessera.files.RemoteFilesState
import com.bambouville.tessera.files.TransferPhase
import com.bambouville.tessera.networking.AndroidSshBackend
import com.bambouville.tessera.networking.SshAuthentication
import com.bambouville.tessera.networking.SshEndpoint
import com.bambouville.tessera.networking.SshFileConnection
import com.bambouville.tessera.networking.SshHostKeyPolicy
import com.bambouville.tessera.networking.SshKeyAuthorizationProvider
import com.bambouville.tessera.networking.SshPasswordProvider
import com.bambouville.tessera.networking.SshRouteHop
import com.bambouville.tessera.networking.SshRouteOwner
import com.bambouville.tessera.networking.SshRouteRequest
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URLEncoder
import java.util.Properties
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Opt-in Files upload recovery gate against the disposable VPS. Every remote
 * write stays inside one run-owned directory, removed at the end.
 */
class RemoteFilesRecoveryInstrumentedTest {
    @Test(timeout = 420_000)
    fun uploadsCleanUpAfterDisposalReplaceRecoverAfterRestartAndSurviveReconnect(): Unit = runBlocking(Dispatchers.IO) {
        val path = InstrumentationRegistry.getArguments().getString("tesseraAttachmentFixture")
        assumeTrue("requires the opt-in disposable VPS runner", path != null)
        val fixture = Properties().apply { File(requireNotNull(path)).inputStream().use(::load) }
        val host = fixture.getProperty("host")
        require(host !in setOf("localhost", "127.0.0.1", "::1", "10.0.2.2"))
        val keys = fixture.getProperty("hostKeyBlobs").split(',').toSet()
        val request = SshRouteRequest(listOf(SshRouteHop("files-recovery", SshEndpoint(host, fixture.getProperty("port").toInt()),
            fixture.getProperty("user"), SshAuthentication.Password)))
        suspend fun openRoute(): SshRouteOwner = AndroidSshBackend().openRoute(
            request,
            SshPasswordProvider { Base64.decode(fixture.getProperty("passwordBase64"), Base64.DEFAULT).decodeToString().toCharArray() },
            SshHostKeyPolicy { Base64.encodeToString(it.canonicalKeyBlob, Base64.NO_WRAP) in keys },
        )
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val journal = context.getSharedPreferences("tessera_files_upload_cleanup", Context.MODE_PRIVATE)
        val probeRoute = openRoute()
        val probe = probeRoute.openFiles()
        val home = probe.realPath(".")
        runCatching { probe.createDirectory("$home/.cache") }
        runCatching { probe.createDirectory("$home/.cache/tessera") }
        val directory = "$home/.cache/tessera/files-recovery-${UUID.randomUUID()}"
        probe.createDirectory(directory)
        val routes = mutableListOf<SshRouteOwner>()
        val localDirectory = File(context.cacheDir, "files-recovery").apply { mkdirs() }
        val local = File(localDirectory, "disposal-${UUID.randomUUID()}.bin")
        try {
            // 1. Disposal mid-upload: the cancelled upload removes its staging
            // file on the connection before that connection closes.
            Log.i(TAG, "stage=disposal")
            local.outputStream().use { output ->
                val block = ByteArray(1 shl 20) { (it * 31).toByte() }
                repeat(UPLOAD_MIB) { output.write(block) }
            }
            val disposalRoute = openRoute().also(routes::add)
            val disposed = controller(context) { disposalRoute.openFiles() }
            try {
                openAndAwait(disposed, directory)
                withContext(Dispatchers.Main) { disposed.enqueueUpload(Uri.fromFile(local), replaceExisting = false) }
                awaitValue("upload progress") { disposed.transfers.value.firstOrNull()?.takeIf { it.transferredBytes > 0 } }
                val phaseAtClose = withContext(Dispatchers.Main) { disposed.transfers.value.single().phase.also { disposed.close() } }
                assertEquals("the upload ended before disposal; enlarge it", TransferPhase.RUNNING, phaseAtClose)
                awaitValue("the upload's cancellation") { Unit.takeIf { disposed.transfers.value.single().phase == TransferPhase.CANCELLED } }
                // Neither the staging file nor a destination may remain.
                awaitValue("run directory emptied after disposal") { Unit.takeIf { probe.list(directory).isEmpty() } }
                awaitValue("journal cleared after disposal") { Unit.takeIf { journal.getString(JOURNAL_KEY, null) == null } }
            } finally {
                withContext(Dispatchers.Main) { disposed.close() }
            }

            // 2. A replace on the real server: the original moves aside, the
            // new file goes in under its display name, and the original is
            // deleted, leaving only the destination.
            Log.i(TAG, "stage=replace")
            val notes = "$directory/notes.txt"
            probe.write(notes, "original")
            val named = File(localDirectory, "notes.txt").apply { writeText("replacement") }
            val replaceRoute = openRoute().also(routes::add)
            val replacing = controller(context) { replaceRoute.openFiles() }
            try {
                openAndAwait(replacing, directory)
                val source = FileProvider.getUriForFile(context, "${context.packageName}.recovery", named)
                withContext(Dispatchers.Main) { replacing.enqueueUpload(source, replaceExisting = true) }
                val finished = awaitValue("replace") {
                    replacing.transfers.value.singleOrNull()?.takeIf { it.phase in FINISHED }
                }
                assertEquals(finished.error, TransferPhase.COMPLETED, finished.phase)
                assertEquals("replacement", probe.read(notes))
                assertEquals(listOf("notes.txt"), probe.list(directory).map { it.name })
                awaitValue("journal cleared after replace") { Unit.takeIf { journal.getString(JOURNAL_KEY, null) == null } }
            } finally {
                withContext(Dispatchers.Main) { replacing.closeAfterTransfers() }
                named.delete()
            }

            // 3. A replace interrupted in a killed process, between moving the
            // original aside and renaming the new file in: the next
            // connection puts the original back and deletes the partial.
            Log.i(TAG, "stage=restart")
            val final = "$directory/report.txt"
            val token = UUID.randomUUID()
            val staging = "$directory/.report.txt.tessera-upload-$token.partial"
            val backup = "$directory/.report.txt.tessera-replaced-$token.backup"
            probe.write(final, "original")
            probe.rename(final, backup)
            probe.write(staging, "partial")
            // The killed process's connection was another route to this host.
            val restartRoute = openRoute().also(routes::add)
            assertEquals(probeRoute.routeIdentity, restartRoute.routeIdentity)
            assertTrue(probeRoute.routeIdentity, " SHA256:" in probeRoute.routeIdentity)
            journal.edit().putString(JOURNAL_KEY, listOf(
                journalLine(probeRoute.routeIdentity, staging, null),
                journalLine(probeRoute.routeIdentity, backup, final),
            ).joinToString("\n")).commit()
            val restarted = controller(context) { restartRoute.openFiles() }
            try {
                openAndAwait(restarted, directory)
                awaitValue("original restored") {
                    Unit.takeIf { probe.exists(final) && !probe.exists(backup) && !probe.exists(staging) }
                }
                assertEquals("original", probe.read(final))
                awaitValue("journal cleared after recovery") { Unit.takeIf { journal.getString(JOURNAL_KEY, null) == null } }
            } finally {
                withContext(Dispatchers.Main) { restarted.closeAfterTransfers() }
            }

            // 4. The live session reconnects: its old route closes and Files
            // must replace the SFTP channel it had opened on that route.
            Log.i(TAG, "stage=reconnect")
            var live = openRoute().also(routes::add)
            val following = controller(context) { live.openFiles() }
            try {
                openAndAwait(following, directory)
                val replaced = live
                live = openRoute().also(routes::add)
                replaced.close()
                probe.write("$directory/after-reconnect.txt", "fresh")
                withContext(Dispatchers.Main) { following.open(directory) }
                val state = awaitValue("listing after reconnect") {
                    following.state.value.takeIf { !it.loading && (it.error != null || it.entries.any { e -> e.name == "after-reconnect.txt" }) }
                }
                assertNull("Files kept the closed route's connection", state.error)
            } finally {
                withContext(Dispatchers.Main) { following.closeAfterTransfers() }
            }
            Log.i(TAG, "TESSERA_FILES_RECOVERY_OK disposal=1 replace=1 restart=1 reconnect=1")
        } finally {
            localDirectory.deleteRecursively()
            runCatching {
                probe.list(directory).forEach { probe.removeFile("$directory/${it.name}") }
                probe.removeDirectory(directory)
            }.onFailure { Log.w(TAG, "fixture cleanup failed", it) }
            routes.forEach { runCatching { it.close() } }
            probe.close()
            probeRoute.close()
        }
    }

    private suspend fun controller(context: Context, live: suspend () -> SshFileConnection) =
        withContext(Dispatchers.Main) {
            RemoteFilesController(
                context,
                route = { error("recovery runs only on the captured routes") },
                passwordProvider = SshPasswordProvider { error("no reconnect") },
                hostKeyPolicy = SshHostKeyPolicy { false },
                keyAuthorizationProvider = SshKeyAuthorizationProvider { error("no key authorization") },
                liveConnection = live,
                reaperDays = 0,
            )
        }

    private suspend fun openAndAwait(controller: RemoteFilesController, directory: String): RemoteFilesState {
        withContext(Dispatchers.Main) { controller.open(directory) }
        val state = awaitValue("listing of $directory") {
            controller.state.value.takeIf { it.currentPath == directory && !it.loading }
        }
        assertNull(state.error)
        return state
    }

    private suspend fun <T : Any> awaitValue(what: String, timeoutMillis: Long = 30_000, value: suspend () -> T?): T {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (true) {
            value()?.let { return it }
            if (System.currentTimeMillis() > deadline) fail("timed out waiting for $what")
            delay(100)
        }
    }

    private suspend fun SshFileConnection.write(path: String, text: String) {
        val bytes = text.encodeToByteArray()
        upload(ByteArrayInputStream(bytes), path, bytes.size.toLong()) { _, _ -> }
    }

    private suspend fun SshFileConnection.read(path: String): String =
        ByteArrayOutputStream().also { download(path, it) { _, _ -> } }.toByteArray().decodeToString()

    /** A killed process's journal record, in RemoteUploadCleanupJournal's v1 line format. */
    private fun journalLine(route: String, remotePath: String, restoreTo: String?): String =
        listOf(UUID.randomUUID().toString(), route, remotePath, restoreTo.orEmpty(), (System.currentTimeMillis() / 1_000).toString())
            .joinToString(" ") { URLEncoder.encode(it, Charsets.UTF_8.name()) }

    private companion object {
        const val TAG = "TesseraFilesRecovery"
        const val JOURNAL_KEY = "pendingRemoteUploadCleanup.v1"
        const val UPLOAD_MIB = 24
        val FINISHED = setOf(TransferPhase.COMPLETED, TransferPhase.FAILED, TransferPhase.CANCELLED)
    }
}
