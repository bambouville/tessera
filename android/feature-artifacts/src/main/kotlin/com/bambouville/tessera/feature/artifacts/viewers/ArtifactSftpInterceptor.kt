package com.bambouville.tessera.feature.artifacts.viewers

import android.os.Looper
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayInputStream
import java.io.FileNotFoundException
import java.net.URI
import java.nio.file.NoSuchFileException
import java.util.Locale

/**
 * Reads only through a connection the host already has; implementations must
 * never reconnect. Canonicalize both allowedRoot and absolutePath on that held
 * channel, check containment, and read the canonical path. Enforce maxBytes;
 * missing entries and failed canonicalization are [FileNotFoundException].
 */
fun interface ArtifactRemoteReader {
    suspend fun read(allowedRoot: String, absolutePath: String, maxBytes: Int): ByteArray
}

/** A page's parent directory is the root of this tab's synthetic HTTPS site. */
class ArtifactSftpInterceptor(
    private val tabId: String,
    private val pagePath: String,
    private val reader: ArtifactRemoteReader,
    private val timeoutMillis: Long = 10_000L,
) : WebViewClient(), AutoCloseable {
    private val paths = ArtifactSftpPaths(tabId, pagePath)
    private val reads = ArtifactSftpReads()

    val pageUrl: String get() = paths.pageUrl

    // The store retains the tab's descriptor when its WebView is disposed.
    // Each new WebView gets its own lifetime without reviving cancelled reads.
    internal fun copyForWebView() = ArtifactSftpInterceptor(tabId, pagePath, reader, timeoutMillis)

    init {
        require(timeoutMillis in 1..30_000L)
    }

    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
        intercept(request.url.toString(), request.method, request.isForMainFrame)

    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
        close()
        discardArtifactWebRenderer(view, detail)
        return true
    }

    /** Called by ArtifactWebView's client on WebView's resource thread. */
    fun intercept(url: String, method: String = "GET"): WebResourceResponse? = intercept(url, method, mainFrame = false)

    internal fun intercept(url: String, method: String, mainFrame: Boolean): WebResourceResponse? {
        // Rotate before starting the new document's read, rather than in the
        // later UI callback which could cancel that same read.
        val generation = if (mainFrame) reads.resetGeneration() else reads.currentGeneration()
        val path = when (val resolved = paths.resolve(url)) {
            ArtifactSftpResolution.Network -> return null
            ArtifactSftpResolution.Forbidden -> return response(403, "Forbidden")
            ArtifactSftpResolution.Missing -> return response(404, "Not Found")
            is ArtifactSftpResolution.File -> resolved.absolutePath
        }
        if (method != "GET" && method != "HEAD") return response(405, "Method Not Allowed")
        // A caller accidentally delegating from a UI callback must not freeze
        // the activity. The normal shouldInterceptRequest lane is off-main.
        if (Looper.myLooper() == Looper.getMainLooper()) return response(503, "Service Unavailable")
        val bytes = when (val result = artifactSftpRead(generation, timeoutMillis) { reader.read(paths.root, path, MAX_BYTES) }) {
            is ArtifactSftpReadResult.Content -> result.bytes
            is ArtifactSftpReadResult.Failure -> return response(result.status, result.reason)
        }
        if (bytes.size > MAX_BYTES) return response(413, "Content Too Large")
        val mime = artifactMimeType(path)
        val extension = path.substringAfterLast('.').lowercase(Locale.ROOT)
        return WebResourceResponse(
            mime, if (mime.startsWith("text/") || extension in TEXT_ENCODINGS) artifactTextEncoding(bytes, mimeType = mime)?.charset?.name() else null,
            200, "OK", RESPONSE_HEADERS,
            ByteArrayInputStream(if (method == "HEAD") byteArrayOf() else bytes),
        )
    }

    internal fun resetReadGeneration() { reads.resetGeneration() }

    override fun close() = reads.close()

    private fun response(status: Int, reason: String) = WebResourceResponse(
        "text/plain", "UTF-8", status, reason, RESPONSE_HEADERS,
        ByteArrayInputStream(reason.toByteArray(Charsets.UTF_8)),
    )

    companion object {
        const val MAX_BYTES: Int = 16 * 1024 * 1024
        private val TEXT_ENCODINGS = setOf("js", "mjs", "cjs", "json", "map", "svg", "xml", "webmanifest")
        private val RESPONSE_HEADERS = mapOf(
            "Cache-Control" to "no-store",
            "X-Content-Type-Options" to "nosniff",
        )
    }
}

internal sealed interface ArtifactSftpReadResult {
    data class Content(val bytes: ByteArray) : ArtifactSftpReadResult
    data class Failure(val status: Int, val reason: String) : ArtifactSftpReadResult
}

/** Both admission and the read share WebView's deadline; no connection is opened here. */
internal fun artifactSftpRead(
    generation: ArtifactSftpReads.Generation?,
    timeoutMillis: Long,
    read: suspend () -> ByteArray,
): ArtifactSftpReadResult = try {
    ArtifactSftpReadResult.Content(runBlocking {
        withTimeout(timeoutMillis) {
            (generation ?: throw CancellationException("the document is closed")).read(read)
        }
    })
} catch (_: TimeoutCancellationException) {
    ArtifactSftpReadResult.Failure(504, "Gateway Timeout")
} catch (_: FileNotFoundException) {
    ArtifactSftpReadResult.Failure(404, "Not Found")
} catch (_: NoSuchFileException) {
    ArtifactSftpReadResult.Failure(404, "Not Found")
} catch (_: CancellationException) {
    ArtifactSftpReadResult.Failure(503, "Service Unavailable")
} catch (_: InterruptedException) {
    Thread.currentThread().interrupt()
    ArtifactSftpReadResult.Failure(503, "Service Unavailable")
} catch (_: Exception) {
    ArtifactSftpReadResult.Failure(502, "Bad Gateway")
}

/** Cancellation belongs to a page; the process-wide bound belongs to actual I/O. */
internal class ArtifactSftpReads(private val activeReads: Semaphore = sharedReads) : AutoCloseable {
    private val lock = Any()
    private var generation: Generation? = Generation(activeReads)

    fun currentGeneration(): Generation? = synchronized(lock) { generation }

    suspend fun read(read: suspend () -> ByteArray): ByteArray =
        (currentGeneration() ?: throw CancellationException("the document is closed")).read(read)

    fun resetGeneration(): Generation? {
        val (previous, next) = synchronized(lock) {
            val previous = generation ?: return null
            val next = Generation(activeReads)
            generation = next
            previous to next
        }
        previous.close()
        return next
    }

    override fun close() {
        val previous = synchronized(lock) { generation.also { generation = null } }
        previous?.close()
    }

    class Generation(private val activeReads: Semaphore) : AutoCloseable {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

        suspend fun read(read: suspend () -> ByteArray): ByteArray = coroutineScope {
            // This child completes on cancellation even when old blocking I/O
            // keeps the generation itself from completing. Cancel admission too.
            val lifetime = Job(scope.coroutineContext[Job])
            val request = coroutineContext[Job]!!
            val cancellation = lifetime.invokeOnCompletion { cause -> if (cause != null) request.cancel() }
            var acquired = false
            var pending: Deferred<ByteArray>? = null
            try {
                activeReads.acquire()
                acquired = true
                ensureActive()
                // Blocking I/O must stay outside the request's child tree so
                // cancellation cannot extend the wait beyond its deadline.
                val job = scope.async { read() }
                pending = job
                job.invokeOnCompletion { activeReads.release() }
                acquired = false
                job.await()
            } finally {
                pending?.cancel()
                if (acquired) activeReads.release()
                cancellation.dispose()
                lifetime.complete()
            }
        }

        override fun close() = scope.cancel()
    }

    private companion object {
        val sharedReads = Semaphore(4)
    }
}

internal sealed interface ArtifactSftpResolution {
    data object Network : ArtifactSftpResolution
    data object Forbidden : ArtifactSftpResolution
    data object Missing : ArtifactSftpResolution
    data class File(val absolutePath: String) : ArtifactSftpResolution
}

/** Uses java.net rather than android.net so the traversal policy is JVM-testable. */
internal class ArtifactSftpPaths(tabId: String, pagePath: String) {
    private val host: String
    val root: String
    val pageUrl: String

    init {
        require(tabId.matches(Regex("[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")))
        host = "${tabId.lowercase(Locale.ROOT)}.$HOST"
        require(pagePath.startsWith('/') && !pagePath.endsWith('/'))
        require(pagePath.none { it == '\\' || it.isISOControl() })
        val name = pagePath.substringAfterLast('/')
        require(name !in setOf(".", ".."))
        root = pagePath.substringBeforeLast('/').ifEmpty { "/" }
        pageUrl = URI("https", host, "/$name", null, null).toASCIIString()
    }

    fun resolve(url: String): ArtifactSftpResolution {
        val uri = try { URI(url) } catch (_: Exception) { return ArtifactSftpResolution.Network }
        if (artifactDeviceLocalHost(artifactUrlHost(uri))) return ArtifactSftpResolution.Forbidden
        if (!uri.host.equals(host, ignoreCase = true)) {
            return if (uri.host?.lowercase(Locale.ROOT)?.endsWith(".$HOST") == true) ArtifactSftpResolution.Forbidden
            else ArtifactSftpResolution.Network
        }
        if (!uri.scheme.equals("https", ignoreCase = true) || uri.port !in listOf(-1, 443)) return ArtifactSftpResolution.Forbidden
        if (uri.rawUserInfo != null) return ArtifactSftpResolution.Forbidden
        // URI.path decodes percent escapes once, before splitting. Encoded
        // slashes and encoded dot segments get the same checks as literal ones.
        val path = uri.path ?: return ArtifactSftpResolution.Missing
        if (path.any { it == '\\' || it == '\uFFFD' || it.isISOControl() }) return ArtifactSftpResolution.Forbidden
        val segments = path.split('/')
        if (segments.size < 2 || segments[0].isNotEmpty()) return ArtifactSftpResolution.Forbidden
        val relative = mutableListOf<String>()
        for (segment in segments.drop(1)) {
            when (segment) {
                "", "." -> Unit
                ".." -> if (relative.isEmpty()) return ArtifactSftpResolution.Forbidden else relative.removeAt(relative.lastIndex)
                else -> relative += segment
            }
        }
        if (relative.isEmpty() || path.endsWith('/')) return ArtifactSftpResolution.Missing
        return ArtifactSftpResolution.File(root.trimEnd('/') + "/" + relative.joinToString("/"))
    }

    private companion object {
        const val HOST = "artifact.tessera.invalid"
    }
}

/** URI.host is absent for some browser-valid IPv4 spellings and escaped hosts. */
internal fun artifactUrlHost(uri: URI): String? = uri.host ?: uri.authority?.substringAfterLast('@')?.let {
    if (it.startsWith('[')) it.substringBefore(']') + "]" else it.substringBefore(':')
}

/** No DNS lookup: these are device-local literals, including browser IPv4 spellings. */
internal fun artifactDeviceLocalHost(value: String?): Boolean {
    val host = value?.lowercase(Locale.ROOT)?.removePrefix("[")?.removeSuffix("]")?.trimEnd('.') ?: return false
    if (host == "localhost" || host.endsWith(".localhost")) return true
    if (':' in host) {
        var address = host.substringBefore('%')
        val tail = address.substringAfterLast(':')
        if ('.' in tail) {
            val octets = tail.split('.').map { it.toIntOrNull()?.takeIf { value -> value in 0..255 } ?: return false }
            if (octets.size != 4) return false
            address = address.substringBeforeLast(':') + ":" + ((octets[0] shl 8) or octets[1]).toString(16) +
                ":" + ((octets[2] shl 8) or octets[3]).toString(16)
        }
        val halves = address.split("::")
        if (halves.size > 2) return false
        fun groups(value: String): List<Int>? = if (value.isEmpty()) emptyList() else value.split(':').map { part ->
            if (part.length !in 1..4) return null
            part.toIntOrNull(16)?.takeIf { it in 0..0xffff } ?: return null
        }
        val left = groups(halves[0]) ?: return false
        val right = if (halves.size == 2) groups(halves[1]) ?: return false else emptyList()
        val missing = 8 - left.size - right.size
        if (halves.size == 1 && missing != 0 || halves.size == 2 && missing < 1) return false
        val groups = left + List(missing) { 0 } + right
        if (groups.all { it == 0 } || groups.take(7).all { it == 0 } && groups[7] == 1) return true
        return groups.take(5).all { it == 0 } && groups[5] in listOf(0, 0xffff) &&
            (groups[6] ushr 8 == 127 || groups[6] == 0 && groups[7] == 0)
    }
    val parts = host.split('.')
    if (parts.size !in 1..4) return false
    val numbers = parts.map { part ->
        when {
            part.startsWith("0x") -> part.drop(2).toLongOrNull(16)
            part.length > 1 && part.startsWith('0') -> part.toLongOrNull(8)
            else -> part.toLongOrNull()
        }?.takeIf { it >= 0 } ?: return false
    }
    if (numbers.dropLast(1).any { it > 255 }) return false
    val lastBits = 8 * (5 - numbers.size)
    if (numbers.last() >= (1L shl lastBits)) return false
    val address = numbers.dropLast(1).fold(0L) { result, part -> (result shl 8) or part }
        .let { (it shl lastBits) or numbers.last() }
    return address == 0L || address ushr 24 == 127L
}

internal fun artifactMimeType(path: String): String = when (path.substringAfterLast('.').lowercase(Locale.ROOT)) {
    "html", "htm" -> "text/html"
    "css" -> "text/css"
    "js", "mjs", "cjs" -> "text/javascript"
    "json", "map" -> "application/json"
    "webmanifest" -> "application/manifest+json"
    "xml" -> "application/xml"
    "txt", "log", "md", "markdown", "mdown", "mkd", "mdx", "rst", "adoc", "org" -> "text/plain"
    "svg" -> "image/svg+xml"
    "png" -> "image/png"
    "jpg", "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "webp" -> "image/webp"
    "avif" -> "image/avif"
    "bmp" -> "image/bmp"
    "ico" -> "image/x-icon"
    "pdf" -> "application/pdf"
    "wasm" -> "application/wasm"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "ttf" -> "font/ttf"
    "otf" -> "font/otf"
    "mp3" -> "audio/mpeg"
    "wav" -> "audio/wav"
    "ogg" -> "audio/ogg"
    "mp4" -> "video/mp4"
    "webm" -> "video/webm"
    else -> "application/octet-stream"
}
