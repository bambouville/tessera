package com.bambouville.tessera.files

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.bambouville.tessera.core.bridge.SharedAgentMarkdown
import com.bambouville.tessera.core.bridge.SharedAgentMarkdownNode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileNotFoundException
import java.io.OutputStream
import java.net.URI
import java.nio.file.AccessDeniedException
import java.nio.file.NoSuchFileException
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPException

/** Paths always address the document's remote host, never Android storage. */
object RemoteMarkdownImages {
    const val MAX_IMAGE_BYTES = 8 * 1024 * 1024L
    private const val MAX_TOTAL_BYTES = 32 * 1024 * 1024L
    private const val MAX_IMAGES = 32

    data class CachedImage(val file: File, val remotePath: String, val size: Long?, val modifiedAtMillis: Long?, val sourceBytes: Long? = size)
    data class StagingResult(val images: Map<String, CachedImage>, val forcedDownloadsComplete: Boolean, val hadTransientFailure: Boolean = false)

    // Keep aligned with shared Core's MarkdownLocalImage path policy.
    fun remotePath(destination: String, documentPath: String): String? = runCatching {
        if (!documentPath.startsWith('/')) return null
        if (destination.any(Char::isISOControl)) return null
        val uri = URI(encodeDestination(destination))
        if (uri.rawAuthority != null || uri.scheme?.lowercase() !in listOf(null, "file")) return null
        val path = uri.path ?: return null
        if (path.isEmpty() || path.startsWith("//") || path.any(Char::isISOControl)) return null
        if (uri.scheme != null && !path.startsWith('/')) return null
        if (path.startsWith('/')) path else documentPath.substringBeforeLast('/') + "/" + path
        // Preserve ../ for SFTP to resolve correctly through symlink parents.
    }.getOrNull()

    /** Keep URI delimiters and existing escapes; quote ordinary filename
     * characters that Java's strict URI parser rejects (spaces, brackets, %). */
    private fun encodeDestination(value: String): String = buildString {
        var index = 0
        val allowed = "-._~:/?#@!$&'()*+,;="
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            val character = value[index]
            val validEscape = character == '%' && index + 2 < value.length &&
                value[index + 1].digitToIntOrNull(16) != null && value[index + 2].digitToIntOrNull(16) != null
            if (codePoint < 128 && (character.isLetterOrDigit() || character in allowed || validEscape)) {
                append(character)
            } else {
                String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8).forEach { byte ->
                    append('%')
                    append("0123456789ABCDEF"[(byte.toInt() and 0xff) ushr 4])
                    append("0123456789ABCDEF"[byte.toInt() and 0xf])
                }
            }
            index += Character.charCount(codePoint)
        }
    }

    fun destinations(nodes: List<SharedAgentMarkdownNode>): List<String> = buildList {
        fun visit(node: SharedAgentMarkdownNode) {
            if (node.kind == "image") node.destination?.let { add(it) }
            else node.children.forEach(::visit)
        }
        nodes.forEach(::visit)
    }.distinct()

    suspend fun stage(
        document: File,
        remotePath: String,
        create: (String) -> File,
        download: suspend (String, OutputStream) -> Unit,
    ): Map<String, File> = withContext(Dispatchers.IO) {
        val destinations = documentDestinations(document) ?: return@withContext emptyMap()
        stageCached(destinations, remotePath, emptyMap(), create, { null }, { path, output ->
            download(path, output)
            null
        }).mapValues { it.value.file }
    }

    /** Both callbacks address only a channel already held by the caller. */
    suspend fun stageCached(
        document: File,
        remotePath: String,
        previous: Map<String, CachedImage>,
        create: (String) -> File,
        stat: suspend (String) -> ArtifactRemoteStat?,
        download: suspend (String, OutputStream) -> ArtifactRemoteStat?,
        force: Boolean = false,
    ): Map<String, CachedImage> = stageCachedWithResult(document, remotePath, previous, create, stat, download, force).images

    suspend fun stageCachedWithResult(
        document: File,
        remotePath: String,
        previous: Map<String, CachedImage>,
        create: (String) -> File,
        stat: suspend (String) -> ArtifactRemoteStat?,
        download: suspend (String, OutputStream) -> ArtifactRemoteStat?,
        force: Boolean = false,
    ): StagingResult = withContext(Dispatchers.IO) {
        val destinations = documentDestinations(document)
            ?: return@withContext StagingResult(previous.filterValues { it.file.isFile }, !force)
        stageCachedWithResult(destinations, remotePath, previous, create, stat, download, force)
    }

    private fun documentDestinations(document: File): List<String>? {
        // Match the parser's bounded input instead of reading a huge file just
        // to discover image references it will never render.
        val source = document.inputStream().use { it.readNBytes(128 * 1024).decodeToString() }
        return SharedAgentMarkdown.parse(source)?.blocks?.let(::destinations)
    }

    /** Also accepts an already parsed document, without another native parse. */
    suspend fun stageCached(
        destinations: List<String>,
        remotePath: String,
        previous: Map<String, CachedImage>,
        create: (String) -> File,
        stat: suspend (String) -> ArtifactRemoteStat?,
        download: suspend (String, OutputStream) -> ArtifactRemoteStat?,
        force: Boolean = false,
        thumbnail: (File, File) -> Boolean = ::thumbnail,
    ): Map<String, CachedImage> = stageCachedWithResult(destinations, remotePath, previous, create, stat, download, force, thumbnail).images

    suspend fun stageCachedWithResult(
        destinations: List<String>,
        remotePath: String,
        previous: Map<String, CachedImage>,
        create: (String) -> File,
        stat: suspend (String) -> ArtifactRemoteStat?,
        download: suspend (String, OutputStream) -> ArtifactRemoteStat?,
        force: Boolean = false,
        thumbnail: (File, File) -> Boolean = ::thumbnail,
    ): StagingResult = withContext(Dispatchers.IO) {
        val images = mutableMapOf<String, CachedImage>()
        val paths = mutableMapOf<String, CachedImage>()
        val cachedPaths = previous.values.associateBy { it.remotePath }
        val created = mutableSetOf<File>()
        var remaining = MAX_TOTAL_BYTES
        var downloadBudget = MAX_TOTAL_BYTES
        var forcedDownloadsComplete = true
        var hadTransientFailure = false
        try {
            for (destination in destinations.distinct().take(MAX_IMAGES)) {
                currentCoroutineContext().ensureActive()
                if (remaining <= 0) break
                val path = remotePath(destination, remotePath) ?: continue
                val staged = paths[path]
                if (staged != null) { images[destination] = staged; continue }
                val cached = cachedPaths[path]?.takeIf { it.file.isFile }
                val observed = try { if (cached != null && !force) stat(path) else null }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) {
                    currentCoroutineContext().ensureActive()
                    if (isDefinitive(failure)) continue
                    hadTransientFailure = true
                    // A lost live channel must not discard the last thumbnail.
                    null
                }
                if (observed?.directory == true) continue
                val limit = minOf(MAX_IMAGE_BYTES, remaining)
                if (observed?.size?.let { it < 0 || it > limit } == true) continue
                fun reuse(): Boolean {
                    val image = cached ?: return false
                    val cost = maxOf(image.size ?: 0, image.sourceBytes ?: image.file.length())
                    if (cost < 0 || cost > minOf(MAX_IMAGE_BYTES, remaining)) return false
                    images[destination] = image
                    paths[path] = image
                    remaining -= cost
                    return true
                }
                if (!force && cached != null && (observed == null ||
                        (cached.size != null && cached.modifiedAtMillis != null &&
                            cached.size == observed.size && cached.modifiedAtMillis == observed.modifiedAtMillis))) {
                    reuse()
                    continue
                }
                val partial = create("image-download")
                val target = create("image.png")
                var interrupted = false
                try {
                    val downloadLimit = minOf(limit, downloadBudget)
                    if (downloadLimit <= 0) throw ArtifactSizeLimitExceeded(MAX_TOTAL_BYTES + 1)
                    var fetched: ArtifactRemoteStat? = null
                    partial.outputStream().use { raw ->
                        val bounded = object : OutputStream() {
                            var count = 0L
                            override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)
                            override fun write(bytes: ByteArray, offset: Int, length: Int) {
                                if (count + length > downloadLimit) throw ArtifactSizeLimitExceeded(count + length)
                                raw.write(bytes, offset, length)
                                count += length
                            }
                        }
                        fetched = download(path, bounded)
                    }
                    if (thumbnail(partial, target)) {
                        val identity = fetched ?: observed
                        val image = CachedImage(target, path, identity?.size, identity?.modifiedAtMillis, partial.length())
                        val cost = maxOf(image.size ?: 0, partial.length())
                        if (cost in 0..limit) {
                            images[destination] = image
                            paths[path] = image
                            created += target
                            remaining -= cost
                        }
                    }
                } catch (cancelled: CancellationException) { throw cancelled
                } catch (failure: Exception) {
                    currentCoroutineContext().ensureActive()
                    interrupted = !isDefinitive(failure)
                    // Broken/missing images keep their alt text; the document opens.
                } finally {
                    downloadBudget -= partial.length()
                    partial.delete()
                    if (images[destination]?.file != target) target.delete()
                }
                if (interrupted) {
                    hadTransientFailure = true
                    if (force) forcedDownloadsComplete = false
                    reuse()
                }
            }
            StagingResult(images, forcedDownloadsComplete, hadTransientFailure)
        } catch (failure: Throwable) {
            created.forEach { it.delete() }
            throw failure
        }
    }

    /** A missing, forbidden, unsupported or oversized image. Anything else, including a closed files
     *  connection's IllegalStateException, may succeed on a retry. */
    private fun isDefinitive(failure: Exception): Boolean = when (failure) {
        is FileNotFoundException, is NoSuchFileException, is AccessDeniedException,
        is SecurityException, is UnsupportedOperationException, is ArtifactSizeLimitExceeded -> true
        is SFTPException -> failure.statusCode in definitiveStatuses
        else -> false
    }

    private val definitiveStatuses = setOf(
        Response.StatusCode.NO_SUCH_FILE, Response.StatusCode.NO_SUCH_PATH,
        Response.StatusCode.PERMISSION_DENIED, Response.StatusCode.OP_UNSUPPORTED,
    )

    private fun thumbnail(source: File, target: File): Boolean {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.path, options)
        if (options.outWidth <= 0 || options.outHeight <= 0) return false
        options.inSampleSize = 1
        while (maxOf(options.outWidth, options.outHeight) / options.inSampleSize > 2048) options.inSampleSize *= 2
        options.inJustDecodeBounds = false
        val bitmap = BitmapFactory.decodeFile(source.path, options) ?: return false
        return try {
            target.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        } finally { bitmap.recycle() }
    }
}
