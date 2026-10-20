package com.bambouville.tessera.networking

import java.io.Closeable
import java.io.InputStream
import java.io.OutputStream
import java.util.EnumSet
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import net.schmizz.concurrent.Promise
import net.schmizz.sshj.sftp.FileAttributes
import net.schmizz.sshj.sftp.FileMode
import net.schmizz.sshj.sftp.OpenMode
import net.schmizz.sshj.sftp.PacketType
import net.schmizz.sshj.sftp.RemoteFile
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPClient
import net.schmizz.sshj.sftp.SFTPEngine
import net.schmizz.sshj.sftp.SFTPException

enum class SshRemoteEntryKind { FILE, DIRECTORY, SYMLINK, OTHER }

data class SshRemoteEntry(
    val name: String,
    val path: String,
    val kind: SshRemoteEntryKind,
    val size: Long?,
    val modifiedEpochSeconds: Long?,
    val permissions: Int?,
)

class SshFileConnection internal constructor(
    private val owner: SshRouteOwner,
    private val sftp: SFTPClient,
    private val closeRouteOnClose: Boolean,
) : Closeable {
    private val closed = AtomicBoolean(false)

    /** See [SshRouteOwner.routeIdentity]. */
    val routeIdentity: String get() = owner.routeIdentity

    /**
     * False once this connection, its route or its SFTP channel has closed:
     * after a reconnect the session's old route is closed, so a connection
     * cached from it must be replaced rather than reused. Never dials.
     */
    val isOpen: Boolean
        get() = !closed.get() && owner.isConnected && runCatching { sftp.sftpEngine.subsystem.isOpen }.getOrDefault(false)

    suspend fun realPath(path: String): String = io { sftp.canonicalize(path) }

    /** Whether anything, a dangling symlink included, holds [path]. Other failures throw. */
    suspend fun exists(path: String): Boolean = io {
        try {
            sftp.lstat(path)
            true
        } catch (failure: SFTPException) {
            if (failure.statusCode == Response.StatusCode.NO_SUCH_FILE) false else throw failure
        }
    }

    /**
     * Follows the selected path through the authenticated SFTP connection.
     * Callers canonicalize first, so the returned path is the one that was
     * actually checked rather than an untrusted terminal-selection spelling.
     */
    suspend fun stat(path: String): SshRemoteEntry = io {
        val attributes = sftp.stat(path)
        SshRemoteEntry(
            name = path.substringAfterLast('/').ifBlank { "/" },
            path = path.trimTrailingSlash(),
            kind = attributes.kind(),
            size = attributes.reportedSize()?.takeIf { attributes.type == FileMode.Type.REGULAR },
            modifiedEpochSeconds = attributes.mtime.takeIf { it > 0 },
            permissions = attributes.mode.mask and 0xFFF,
        )
    }

    suspend fun list(path: String): List<SshRemoteEntry> = io {
        sftp.ls(path).asSequence()
            .filterNot { it.name == "." || it.name == ".." }
            .map { info ->
                val listedAttributes = info.attributes
                val attributes = if (listedAttributes.type == FileMode.Type.SYMLINK) {
                    runCatching { sftp.stat(info.path) }.getOrNull() ?: listedAttributes
                } else {
                    listedAttributes
                }
                SshRemoteEntry(
                    name = info.name,
                    path = info.path.trimTrailingSlash(),
                    kind = attributes.kind(),
                    size = attributes.reportedSize()?.takeIf { attributes.type == FileMode.Type.REGULAR },
                    modifiedEpochSeconds = attributes.mtime.takeIf { it > 0 },
                    permissions = attributes.mode.mask and 0xFFF,
                )
            }
            .sortedWith(compareBy<SshRemoteEntry> { it.kind != SshRemoteEntryKind.DIRECTORY }.thenBy { it.name.lowercase() })
            .toList()
    }

    suspend fun createDirectory(path: String) = io { sftp.mkdir(path) }
    suspend fun rename(from: String, to: String) = io { sftp.rename(from, to) }
    suspend fun removeFile(path: String) = io { sftp.rm(path) }
    suspend fun removeDirectory(path: String) = io { sftp.rmdir(path) }
    suspend fun setPermissions(path: String, permissions: Int) = io {
        require(permissions in 0..0xFFF)
        sftp.chmod(path, permissions)
    }

    /**
     * Runs one bounded command on the route this browser already authenticated.
     *
     * The cwd follow poll asks the host a question every couple of seconds.
     * `AndroidSshBackend.executeRouteCommand` would dial and authenticate the
     * whole route again per tick — a password prompt or a Keystore
     * authorization each time — so the poll rides the open route instead, as
     * the exec channel is a sibling of the SFTP channel, not a new session.
     */
    suspend fun executeBoundedCommand(commandText: String): SshCommandTranscript =
        owner.executeBoundedCommand(commandText)

    /*
     * SFTP answers every request separately, so awaiting each reply before
     * sending the next caps a transfer at one request per round trip. These
     * pipeline requests instead (SftpTransferPipeline). Every other request on
     * this connection — browsing, the CLOSE that ends a cancelled transfer,
     * the terminal when the files channel rides the live route — waits behind
     * what is queued, so the bytes in flight follow measured throughput
     * (SftpPipelineWindow): at most about 2 MiB, like OpenSSH's sftp client,
     * and about a round trip plus 250 ms of data. One window per direction
     * serves all of this connection's transfers, so concurrent ones share that
     * queue rather than each growing its own. A one-request floor keeps a very
     * slow link near stop-and-wait.
     */
    private val uploadWindow = SftpPipelineWindow(
        floorBytes = WRITE_REQUEST_BYTES.toLong(),
        ceilingBytes = 64L * WRITE_REQUEST_BYTES,
        initialBytes = 4L * WRITE_REQUEST_BYTES,
    )
    private val downloadWindow = SftpPipelineWindow(
        floorBytes = SftpTransferPipeline.READ_REQUEST_BYTES.toLong(),
        ceilingBytes = 32L * SftpTransferPipeline.READ_REQUEST_BYTES,
        initialBytes = 4L * SftpTransferPipeline.READ_REQUEST_BYTES,
    )

    suspend fun download(
        remotePath: String,
        output: OutputStream,
        progress: suspend (Long, Long?) -> Unit,
    ) = withContext(Dispatchers.IO) {
        PipelinedRemoteFile.open(sftp.sftpEngine, remotePath, EnumSet.of(OpenMode.READ)).use { remote ->
            // Only a read-ahead bound and a progress total; the transfer
            // itself always runs to end of file.
            val total = sizeAtOpen { remote.fetchAttributes() }
            SftpTransferPipeline.download(
                file = remote,
                window = downloadWindow,
                sizeAtOpen = total,
                output = output,
                progress = { progress(it, total) },
                nanoTime = System::nanoTime,
                checkCancelled = { ensureActive() },
            )
        }
    }

    suspend fun upload(
        input: InputStream,
        remotePath: String,
        totalBytes: Long?,
        progress: suspend (Long, Long?) -> Unit,
    ) = withContext(Dispatchers.IO) {
        PipelinedRemoteFile.open(
            sftp.sftpEngine,
            remotePath,
            EnumSet.of(OpenMode.WRITE, OpenMode.CREAT, OpenMode.TRUNC),
        ).use { remote ->
            // One request per SSH channel packet, as sshj's own uploader
            // sizes them; every SFTP server accepts 32 KiB writes.
            val requestBytes = (
                minOf(sftp.sftpEngine.subsystem.remoteMaxPacketSize, WRITE_REQUEST_BYTES) -
                    remote.outgoingPacketOverhead
                ).coerceAtLeast(MIN_WRITE_REQUEST_BYTES)
            SftpTransferPipeline.upload(
                file = remote,
                window = uploadWindow,
                readChunk = { input.readUpTo(it) },
                requestBytes = requestBytes,
                progress = { progress(it, totalBytes) },
                nanoTime = System::nanoTime,
                checkCancelled = { ensureActive() },
            )
        }
    }

    /**
     * Blocks until the server acknowledges, up to the SSH timeout on a dead
     * link: call it off the main thread. Repeat calls, including the route
     * owner's when it retires its children, return at once.
     */
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        // A route this connection owns goes first, as SshRouteOwner.close
        // orders it, so the SFTP CLOSE after it doesn't wait for a reply from
        // a dead link.
        if (closeRouteOnClose) owner.close()
        runCatching { sftp.close() }
        owner.release(this)
    }

    private suspend fun <T> io(block: () -> T): T = withContext(Dispatchers.IO) { block() }

    private fun String.trimTrailingSlash(): String = if (length > 1) trimEnd('/') else this

    private fun net.schmizz.sshj.sftp.FileAttributes.kind(): SshRemoteEntryKind = when (type) {
        FileMode.Type.REGULAR -> SshRemoteEntryKind.FILE
        FileMode.Type.DIRECTORY -> SshRemoteEntryKind.DIRECTORY
        FileMode.Type.SYMLINK -> SshRemoteEntryKind.SYMLINK
        else -> SshRemoteEntryKind.OTHER
    }

    /**
     * Fills [buffer] unless the stream ends or a read returns nothing first.
     * Returns the bytes read, 0 if the first read returned nothing (the
     * caller asks again), or -1 once nothing is left.
     */
    private fun InputStream.readUpTo(buffer: ByteArray): Int {
        var filled = 0
        while (filled < buffer.size) {
            val count = read(buffer, filled, buffer.size - filled)
            if (count < 0) return if (filled == 0) -1 else filled
            if (count == 0) break
            filled += count
        }
        return filled
    }

    private companion object {
        const val WRITE_REQUEST_BYTES = 32 * 1024
        const val MIN_WRITE_REQUEST_BYTES = 4 * 1024
    }
}

suspend fun AndroidSshBackend.connectFiles(
    request: SshRouteRequest,
    passwordProvider: SshPasswordProvider,
    hostKeyPolicy: SshHostKeyPolicy,
    keyAuthorizationProvider: SshKeyAuthorizationProvider = SshKeyAuthorizationProvider { },
): SshFileConnection = acquireSshResource {
    // Like every other route resource: a caller cancelled while this opened
    // would otherwise discard the connection, and with it a whole
    // authenticated route, without closing either.
    require(request.hops.isNotEmpty() && request.hops.size <= 8)
    val route = openRoute(
        request = request,
        passwordProvider = passwordProvider,
        hostKeyPolicy = hostKeyPolicy,
        keyAuthorizationProvider = keyAuthorizationProvider,
    )
    try {
        route.openFiles(closeRouteOnClose = true)
    } catch (failure: Throwable) {
        route.close()
        throw failure
    }
}

/**
 * The size a server reported, or null when it gave none a transfer can use:
 * the field is optional, and SFTP's uint64 lands in a signed Long. sshj 0.40
 * refuses values past Long.MAX_VALUE rather than wrapping them, but a
 * negative size must never reach read-ahead or the progress total.
 */
internal fun FileAttributes.reportedSize(): Long? =
    size.takeIf { has(FileAttributes.Flag.SIZE) && it >= 0 }

/** A download's size at open, or null (unknown) when the server can't say. */
internal fun sizeAtOpen(fetch: () -> FileAttributes): Long? =
    runCatching(fetch).getOrNull()?.reportedSize()

/**
 * A [RemoteFile] that can leave read and write requests outstanding. sshj
 * keeps `asyncRead`/`asyncWrite` protected and `SFTPEngine.open` returns a
 * plain [RemoteFile], so [open] sends the same OPEN request itself.
 */
internal class PipelinedRemoteFile private constructor(engine: SFTPEngine, path: String, handle: ByteArray) :
    RemoteFile(engine, path, handle), SftpPipelineFile {

    /** sshj copies [data] into the request before returning, so callers may reuse it. */
    override fun sendWrite(offset: Long, data: ByteArray, length: Int): SftpPendingReply<Unit> =
        Reply(asyncWrite(offset, data, 0, length), requester.timeoutMs.toLong()) { writeReply(it) }

    override fun sendRead(offset: Long, length: Int): SftpPendingReply<SftpReadReply> =
        Reply(asyncRead(offset, length), requester.timeoutMs.toLong()) { readReply(it, length) }

    private class Reply<T>(
        private val promise: Promise<Response, SFTPException>,
        private val timeoutMs: Long,
        private val parse: (Response) -> T,
    ) : SftpPendingReply<T> {
        override val isAnswered: Boolean get() = promise.isFulfilled

        override fun await(): T = parse(promise.retrieve(timeoutMs, TimeUnit.MILLISECONDS))
    }

    companion object {
        fun open(engine: SFTPEngine, path: String, modes: Set<OpenMode>): PipelinedRemoteFile {
            val request = engine.newRequest(PacketType.OPEN)
                .putString(path, engine.subsystem.remoteCharset)
                .putUInt32(OpenMode.toMask(modes).toLong())
                .putFileAttributes(FileAttributes.EMPTY)
            val handle = engine.request(request)
                .retrieve(engine.timeoutMs.toLong(), TimeUnit.MILLISECONDS)
                .ensurePacketTypeIs(PacketType.HANDLE)
                .readBytes()
            return PipelinedRemoteFile(engine, path, handle)
        }

        fun writeReply(response: Response) {
            response.ensureStatusPacketIsOK()
        }

        /**
         * A READ reply's data, left in the reply's own buffer (sshj allocates
         * one per reply), or end of file, which an empty DATA reply also means
         * rather than an invitation to ask again.
         */
        fun readReply(response: Response, requested: Int): SftpReadReply = when (response.type) {
            PacketType.DATA -> {
                val count = response.readUInt32()
                when {
                    count > requested -> throw SFTPException("READ of $requested bytes answered with $count")
                    count > response.available() -> throw SFTPException("READ reply shorter than its $count bytes")
                    count == 0L -> SftpReadReply.EndOfFile
                    else -> SftpReadReply.Data(response.array(), response.rpos(), count.toInt())
                }
            }
            PacketType.STATUS -> {
                response.ensureStatusIs(Response.StatusCode.EOF)
                SftpReadReply.EndOfFile
            }
            else -> throw SFTPException("Unexpected packet: ${response.type}")
        }
    }
}
