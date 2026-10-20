package com.bambouville.tessera.files

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.bambouville.tessera.core.bridge.SharedAgentMarkdown
import com.bambouville.tessera.core.bridge.SharedAgentMarkdownNode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.OutputStream
import java.net.URI

/** Paths always address the document's remote host, never Android storage. */
internal object RemoteMarkdownImages {
    const val MAX_IMAGE_BYTES = 8 * 1024 * 1024L
    private const val MAX_TOTAL_BYTES = 32 * 1024 * 1024L
    private const val MAX_IMAGES = 32

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
        // Match the parser's bounded input instead of reading a huge file just
        // to discover image references it will never render.
        val source = document.inputStream().use { it.readNBytes(128 * 1024).decodeToString() }
        val nodes = SharedAgentMarkdown.parse(source)?.blocks ?: return@withContext emptyMap()
        val images = mutableMapOf<String, File>()
        val paths = mutableMapOf<String, File>()
        var remaining = MAX_TOTAL_BYTES
        try {
            for (destination in destinations(nodes).take(MAX_IMAGES)) {
                currentCoroutineContext().ensureActive()
                if (remaining <= 0) break
                val path = remotePath(destination, remotePath) ?: continue
                val cached = paths[path]
                if (cached != null) { images[destination] = cached; continue }
                val partial = create("image-download")
                val target = create("image.png")
                val limit = minOf(MAX_IMAGE_BYTES, remaining)
                try {
                    partial.outputStream().use { raw ->
                        val bounded = object : OutputStream() {
                            var count = 0L
                            override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)
                            override fun write(bytes: ByteArray, offset: Int, length: Int) {
                                check(count + length <= limit) { "Image exceeds preview limit" }
                                raw.write(bytes, offset, length)
                                count += length
                            }
                        }
                        download(path, bounded)
                    }
                    if (thumbnail(partial, target)) {
                        images[destination] = target
                        paths[path] = target
                    }
                } catch (failure: Exception) {
                    currentCoroutineContext().ensureActive()
                    // Broken/missing images keep their alt text; the document opens.
                } finally {
                    remaining -= partial.length()
                    partial.delete()
                    if (target !in images.values) target.delete()
                }
            }
            images
        } catch (failure: Throwable) {
            images.values.forEach { it.delete() }
            throw failure
        }
    }

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
