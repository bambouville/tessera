package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifacts
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheEntry
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheMetadata
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.core.bridge.SharedArtifactsViewer
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactRemoteReader
import com.bambouville.tessera.feature.artifacts.viewers.ArtifactSftpInterceptor
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.files.ArtifactSizeLimitExceeded
import com.bambouville.tessera.files.RemoteMarkdownImages
import com.bambouville.tessera.files.RemoteMarkdownImages.CachedImage
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

internal data class ArtifactLoadResult(val content: ArtifactContent, val cache: SharedArtifactsCacheMetadata? = null, val forcedImagesComplete: Boolean = false, val imagesFellShort: Boolean = false)

internal sealed interface ArtifactCacheLookup {
    data object Busy : ArtifactCacheLookup
    data object Missing : ArtifactCacheLookup
    data class Cached(val document: ArtifactContent.Document) : ArtifactCacheLookup
}

internal class ArtifactContentLoader(
    val cacheRoot: File,
    private val files: (String) -> ArtifactLiveFiles?,
    private val key: (SharedArtifactTab) -> String = SharedArtifacts::cacheKey,
    private val viewer: (String) -> SharedArtifactsViewer = { SharedArtifacts.kind(it).second },
    private val stageImages: (suspend (File, String, (String) -> File, suspend (String, OutputStream) -> Unit) -> Map<String, File>)? = null,
    private val committedTabs: List<SharedArtifactTab> = emptyList(),
    private val evictions: (List<SharedArtifactsCacheEntry>, Long, Set<String>) -> List<String> = SharedArtifacts::cacheEvictions,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val deleteDirectory: (File) -> Boolean = { it.deleteRecursively() },
    private val stageCachedImages: suspend (File, String, Map<String, CachedImage>, (String) -> File,
        suspend (String) -> ArtifactRemoteStat?, suspend (String, OutputStream) -> ArtifactRemoteStat?, Boolean) -> RemoteMarkdownImages.StagingResult = RemoteMarkdownImages::stageCachedWithResult,
) {
    private val locks = ConcurrentHashMap<String, Mutex>()
    private val recoveryLock = Mutex()
    private val evictionLock = Mutex()
    private var recovered = false
    private val protectionLock = Any()
    private var protectedKeys: Set<String> = emptySet()
    private val evictingKeys = mutableSetOf<String>()

    suspend fun recover(tabs: List<SharedArtifactTab> = committedTabs) = withContext(ioDispatcher) {
        recoveryLock.withLock {
            if (recovered) return@withLock
            val committed = tabs.filter { it.target is SharedArtifactsTarget.File }.associate { key(it) to cacheFile(it).name }
            cacheRoot.listFiles().orEmpty().filter(File::isDirectory).forEach {
                if (isEvictionTombstone(it)) {
                    deleteDirectory(it)
                    return@forEach
                }
                if (!it.name.matches(Regex("[a-f0-9]{64}"))) return@forEach
                committed[it.name]?.let { name ->
                    val payload = File(it, name)
                    if (payload.isFile) runCatching { recordPayload(it, payload) }
                }
                removeAbandonedStaging(it, setOfNotNull(committed[it.name]))
            }
            recovered = true
        }
    }

    fun protect(tabs: List<SharedArtifactTab>, selectedId: String?, loading: Set<String>): Boolean {
        val keys = tabs.filter { it.target is SharedArtifactsTarget.File && (it.pinned || it.id == selectedId || it.id in loading) }.map(key).toSet()
        return synchronized(protectionLock) {
            val changed = protectedKeys != keys
            protectedKeys = keys
            changed
        }
    }

    fun cacheDirectory(tab: SharedArtifactTab): File {
        val cacheKey = key(tab)
        require(cacheKey.matches(Regex("[a-f0-9]{64}")))
        return File(cacheRoot, cacheKey)
    }
    fun cacheFile(tab: SharedArtifactTab): File = File(cacheDirectory(tab), basename(tab.target.path))
    suspend fun hasCache(tab: SharedArtifactTab): Boolean = withContext(ioDispatcher) {
        recover()
        if (tab.target !is SharedArtifactsTarget.File) return@withContext false
        val cacheKey = key(tab)
        locks.getOrPut(cacheKey) { Mutex() }.withLock {
            !isEvicting(cacheKey) && cacheFile(tab).isFile
        }
    }

    /** The subset of [files] that no longer exist, checked off the caller's thread. */
    suspend fun missing(files: Collection<File>): Set<File> = withContext(ioDispatcher) { files.filterNot(File::isFile).toSet() }

    suspend fun cached(tab: SharedArtifactTab, reloadToken: Long): ArtifactContent.Document? = withContext(ioDispatcher) {
        recover()
        locks.getOrPut(key(tab)) { Mutex() }.withLock { cachedDocument(tab, reloadToken) }
    }

    /** Restoration must not wait for an in-flight remote read of the same key. */
    suspend fun cachedIfIdle(tab: SharedArtifactTab, reloadToken: Long): ArtifactCacheLookup = withContext(ioDispatcher) {
        recover()
        val lock = locks.getOrPut(key(tab)) { Mutex() }
        if (!lock.tryLock()) return@withContext ArtifactCacheLookup.Busy
        try { cachedDocument(tab, reloadToken)?.let { ArtifactCacheLookup.Cached(it) } ?: ArtifactCacheLookup.Missing }
        finally { lock.unlock() }
    }

    private fun cachedDocument(tab: SharedArtifactTab, reloadToken: Long): ArtifactContent.Document? {
        if (isEvicting(key(tab))) return null
        val file = cacheFile(tab)
        if (!file.isFile || file.length() > MAX_BYTES) return null
        val directory = file.parentFile ?: return null
        val images = imageManifest(directory, tab.target.path).mapValues { it.value.file }
        return ArtifactContent.Document(file, tab.target.path.substringAfterLast('/'), reloadToken, images)
    }

    private fun imageManifest(directory: File, documentPath: String): Map<String, CachedImage> = runCatching {
        val manifest = File(directory, "images.json")
        if (manifest.length() > IMAGE_MANIFEST_BYTES) return@runCatching emptyMap<String, CachedImage>()
        val bytes = manifest.inputStream().use { it.readNBytes(IMAGE_MANIFEST_BYTES + 1) }
        if (bytes.size > IMAGE_MANIFEST_BYTES) return@runCatching emptyMap<String, CachedImage>()
        val json = JSONObject(bytes.decodeToString(throwOnInvalidSequence = true))
        json.keys().asSequence().mapNotNull { destination ->
            runCatching {
                val entry = json.optJSONObject(destination)
                val name = entry?.getString("file") ?: json.getString(destination)
                if (!name.matches(Regex("[a-zA-Z0-9.-]+")) || name == "." || name == "..") return@runCatching null
                val path = RemoteMarkdownImages.remotePath(destination, documentPath) ?: return@runCatching null
                if (entry?.has("path") == true && entry.getString("path") != path) return@runCatching null
                val size = entry?.takeUnless { it.isNull("size") }?.getLong("size")
                val sourceBytes = entry?.takeUnless { it.isNull("bytes") }?.getLong("bytes") ?: size
                if (listOfNotNull(size, sourceBytes).any { it !in 0..RemoteMarkdownImages.MAX_IMAGE_BYTES }) return@runCatching null
                val modified = entry?.takeUnless { it.isNull("mtime") }?.getLong("mtime")
                File(directory, "images/$name").takeIf(File::isFile)?.let { destination to CachedImage(it, path, size, modified, sourceBytes) }
            }.getOrNull()
        }.take(32).toMap()
    }.getOrDefault(emptyMap())

    private fun boundedImageManifest(images: Map<String, CachedImage>, documentPath: String): Pair<String, Map<String, CachedImage>> {
        val json = JSONObject()
        val accepted = mutableMapOf<String, CachedImage>()
        var bytes = 2 // Braces, plus each entry and its comma below.
        images.entries.take(32).forEach { (destination, image) ->
            if (RemoteMarkdownImages.remotePath(destination, documentPath) != image.remotePath) return@forEach
            // The destination and document already determine the remote path.
            val entry = JSONObject().put("file", image.file.name).put("size", image.size)
                .put("mtime", image.modifiedAtMillis).put("bytes", image.sourceBytes)
            val entryBytes = JSONObject().put(destination, entry).toString().encodeToByteArray().size - 2 + if (accepted.isEmpty()) 0 else 1
            if (entryBytes > IMAGE_MANIFEST_BYTES - bytes) return@forEach
            json.put(destination, entry)
            accepted[destination] = image
            bytes += entryBytes
        }
        return json.toString() to accepted
    }

    suspend fun load(tab: SharedArtifactTab, reloadToken: Long, staged: File? = null, forceImages: Boolean = false, fetchDocument: Boolean = true,
        onDocumentAccepted: (suspend (SharedArtifactsCacheMetadata) -> Unit)? = null): ArtifactLoadResult = withContext(ioDispatcher) {
        recover()
        when (val target = tab.target) {
            is SharedArtifactsTarget.Change -> return@withContext ArtifactLoadResult(ArtifactContent.Change(target.path, target.diff))
            is SharedArtifactsTarget.Page -> return@withContext ArtifactLoadResult(ArtifactContent.Unavailable(ArtifactUnavailable.NoForwarding))
            is SharedArtifactsTarget.File -> Unit
        }
        val live = files(tab.hostId)?.takeIf { it.hasLiveArtifactChannel }
        val cacheKey = key(tab)
        locks.getOrPut(cacheKey) { Mutex() }.withLock {
            // An entry mid-eviction is already renamed away, and its deletion takes
            // no key lock. A fetch waits so its fresh copy is not counted as evicted.
            while ((live != null || staged != null) && isEvicting(cacheKey)) delay(20)
            val directory = cacheDirectory(tab)
            val targetFile = cacheFile(tab)
            removeAbandonedStaging(directory, setOfNotNull(targetFile.name, staged?.name))
            if (live == null && staged == null) return@withLock offline(tab, reloadToken)
            check(directory.isDirectory || directory.mkdirs())
            var partial: File? = null
            try {
                val fetched = if (fetchDocument || staged != null || !targetFile.isFile || targetFile.length() > MAX_BYTES) {
                    val staging = stagingDirectory(directory)
                    check(staging.isDirectory || staging.mkdirs())
                    val download = File.createTempFile("artifact-", ".tmp", staging).also { partial = it }
                    var size = 0L
                    val stat = FileOutputStream(download).use { output ->
                        val bounded = BoundedArtifactOutput(output, MAX_BYTES)
                        val remote = if (staged != null) {
                            if (staged.length() > MAX_BYTES) throw ArtifactSizeLimitExceeded(staged.length())
                            staged.inputStream().use { it.copyTo(bounded) }
                            null
                        } else {
                            live?.readArtifactOnLiveChannel(tab.target.path, bounded, MAX_BYTES)
                                ?: return@withLock offline(tab, reloadToken)
                        }
                        size = bounded.count
                        output.fd.sync()
                        remote
                    }
                    currentCoroutineContext().ensureActive()
                    // Record the identity before replacement, including staging-like filenames.
                    recordPayload(directory, targetFile)
                    replaceArtifactFile(download, targetFile)
                    SharedArtifactsCacheMetadata(0, stat?.modifiedAtMillis, size).also { cache ->
                        // Replacement has committed even if cancellation arrives at the dispatch back to the store.
                        if (onDocumentAccepted != null) withContext(NonCancellable) { onDocumentAccepted(cache) }
                    }
                } else null
                currentCoroutineContext().ensureActive()
                val fileViewer = viewer(tab.target.path)
                var forcedImagesComplete = fileViewer != SharedArtifactsViewer.Markdown
                var imagesFellShort = false
                if (fileViewer == SharedArtifactsViewer.Markdown && live != null) {
                    val imageDirectory = File(directory, "images").apply { mkdirs() }
                    val previous = imageManifest(directory, tab.target.path)
                    val create: (String) -> File = { name -> File(imageDirectory, "${UUID.randomUUID()}-$name") }
                    val download: suspend (String, OutputStream) -> ArtifactRemoteStat? = { path, output ->
                        live.readArtifactOnLiveChannel(path, output, RemoteMarkdownImages.MAX_IMAGE_BYTES)
                            ?: throw ArtifactOfflineException()
                    }
                    val stagingResult = stageImages?.let { stage ->
                        val images = stage(targetFile, tab.target.path, create) { path, output -> download(path, output); Unit }
                            .mapNotNull { (destination, image) ->
                                RemoteMarkdownImages.remotePath(destination, tab.target.path)?.let { destination to CachedImage(image, it, null, null) }
                            }.toMap()
                        RemoteMarkdownImages.StagingResult(images, true)
                    } ?: stageCachedImages(targetFile, tab.target.path, previous, create, { path ->
                        live.statArtifactOnLiveChannel(path) ?: throw ArtifactOfflineException()
                    }, download, forceImages)
                    val stagedImages = stagingResult.images
                    val (json, images) = if (stagedImages == previous) "" to previous else boundedImageManifest(stagedImages, tab.target.path)
                    if (images != previous) {
                        val manifest = File.createTempFile("images-", ".tmp", directory)
                        var committed = false
                        try {
                            manifest.writeText(json)
                            replaceArtifactFile(manifest, File(directory, "images.json"))
                            committed = true
                        } finally {
                            manifest.delete()
                            if (!committed) {
                                val saved = previous.values.map(CachedImage::file).toSet()
                                stagedImages.values.filter { it.file !in saved }.forEach { it.file.delete() }
                            }
                        }
                    }
                    val keep = images.values.map { it.file.name }.toSet()
                    imageDirectory.listFiles()?.filter { it.name !in keep && it.name !in setOf(".staging", ".artifact-content") }?.forEach(File::delete)
                    forcedImagesComplete = stagingResult.forcedDownloadsComplete
                    imagesFellShort = stagingResult.hadTransientFailure
                }
                val document = checkNotNull(cachedDocument(tab, reloadToken))
                if (fileViewer == SharedArtifactsViewer.Html && live != null) {
                    val interceptor = ArtifactSftpInterceptor(tab.id, tab.target.path, ArtifactRemoteReader { root, path, maximum ->
                        val output = ByteArrayOutputStream()
                        files(tab.hostId)?.readArtifactPageOnLiveChannel(root, path, output, maximum.toLong())
                            ?: throw ArtifactOfflineException()
                        output.toByteArray()
                    })
                    ArtifactLoadResult(ArtifactContent.ServedPage(interceptor.pageUrl, interceptor), fetched)
                } else ArtifactLoadResult(document, fetched, forcedImagesComplete, imagesFellShort)
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (tooLarge: ArtifactSizeLimitExceeded) {
                ArtifactLoadResult(ArtifactContent.Unavailable(ArtifactUnavailable.TooLarge(tooLarge.bytes)))
            } catch (_: FileNotFoundException) {
                ArtifactLoadResult(ArtifactContent.Unavailable(ArtifactUnavailable.Missing))
            } catch (_: ArtifactOfflineException) { offline(tab, reloadToken)
            } catch (failure: Exception) {
                if (files(tab.hostId) == null) offline(tab, reloadToken)
                else ArtifactLoadResult(ArtifactContent.Unavailable(ArtifactUnavailable.Failed(artifactFailureMessage(failure, R.string.artifacts_read_file_failed, limit = 200))))
            } finally { partial?.delete() }
        }
    }

    suspend fun evict(tabs: List<SharedArtifactTab>, selectedId: String?, loading: Set<String>): Set<String> = withContext(ioDispatcher) {
        recover()
        evictionLock.withLock {
            val directories = cacheRoot.listFiles().orEmpty().filter(File::isDirectory)
            val tombstones = directories.filter(::isEvictionTombstone)
            tombstones.forEach { deleteDirectory(it) }
            var pendingBytes = tombstones.sumOf(::directoryBytes)
            val byKey = tabs.filter { it.target is SharedArtifactsTarget.File }.groupBy(key)
            val entries = directories.filter { it.name.matches(Regex("[a-f0-9]{64}")) }.map { directory ->
                val matching = byKey[directory.name].orEmpty()
                SharedArtifactsCacheEntry(directory.name, directoryBytes(directory), matching.maxOfOrNull { it.viewedAt } ?: 0,
                    matching.any { it.pinned })
            }.toMutableList()
            val protected = tabs.filter { it.pinned || it.id == selectedId || it.id in loading }.map(key).toSet()
            val attempted = mutableSetOf<String>()
            val evicted = mutableSetOf<String>()
            while (true) {
                val currentProtection = synchronized(protectionLock) { protectedKeys }
                val victims = evictions(entries, (CACHE_BUDGET - pendingBytes).coerceAtLeast(0), protected + currentProtection + attempted)
                    .filter { it !in attempted && entries.any { entry -> entry.key == it } }
                if (victims.isEmpty()) break
                for (cacheKey in victims) {
                    attempted.add(cacheKey)
                    val tombstone = File(cacheRoot, ".evicting-$cacheKey-${UUID.randomUUID()}")
                    val reserved = locks.getOrPut(cacheKey) { Mutex() }.withLock {
                        val available = synchronized(protectionLock) {
                            if (cacheKey in protectedKeys || cacheKey in protected) false else evictingKeys.add(cacheKey)
                        }
                        if (!available) return@withLock false
                        var moved = false
                        try {
                            moved = File(cacheRoot, cacheKey).renameTo(tombstone)
                            moved
                        } finally {
                            if (!moved) synchronized(protectionLock) { evictingKeys.remove(cacheKey) }
                        }
                    }
                    if (!reserved) continue
                    try {
                        // Readers see absence before any recursive deletion. Main's
                        // protection monitor never covers filesystem operations.
                        deleteDirectory(tombstone)
                        pendingBytes += directoryBytes(tombstone)
                        entries.removeAll { it.key == cacheKey }
                        evicted.add(cacheKey)
                    } finally { synchronized(protectionLock) { evictingKeys.remove(cacheKey) } }
                }
            }
            evicted
        }
    }

    private fun isEvicting(cacheKey: String): Boolean = synchronized(protectionLock) { cacheKey in evictingKeys }
    private fun isEvictionTombstone(directory: File): Boolean = directory.name.matches(Regex("\\.evicting-[a-f0-9]{64}-[a-f0-9-]{36}"))
    private fun directoryBytes(directory: File): Long = directory.walkTopDown().filter(File::isFile).sumOf(File::length)
    private fun offline(tab: SharedArtifactTab, token: Long) = ArtifactLoadResult(
        cachedDocument(tab, token) ?: ArtifactContent.Unavailable(ArtifactUnavailable.Offline),
    )
    private fun payloadIdentity(directory: File): String? {
        val identity = File(directory, "images/.artifact-content")
        return runCatching { if (identity.isFile && identity.length() <= 1_024) identity.readText() else null }.getOrNull()
            ?.takeIf { it.isNotEmpty() && it.none { char -> char == '/' || char == '\\' || char.isISOControl() } }
    }
    private fun removeAbandonedStaging(directory: File, keep: Set<String>) {
        val committed = payloadIdentity(directory)
        fun clean(staging: File) {
            staging.listFiles()?.filter {
                it.isFile && it.name !in keep && it.name != committed && it.name.startsWith("artifact-") && it.name.endsWith(".tmp")
            }?.forEach(File::delete)
        }
        clean(stagingDirectory(directory))
        // Legacy root-level names need a known payload identity. An unmarked
        // orphan could itself be a committed artifact-*.tmp document.
        if (keep.isNotEmpty() || committed != null) clean(directory)
    }
    private fun stagingDirectory(directory: File) = File(directory, "images/.staging")
    private fun recordPayload(directory: File, payload: File) {
        if (payloadIdentity(directory) == payload.name) return
        val staging = stagingDirectory(directory)
        check(staging.isDirectory || staging.mkdirs())
        val identity = File.createTempFile("artifact-", ".tmp", staging)
        try {
            FileOutputStream(identity).use { output ->
                output.write(payload.name.encodeToByteArray())
                output.fd.sync()
            }
            replaceArtifactFile(identity, File(directory, "images/.artifact-content"))
        } finally { identity.delete() }
    }
    private fun basename(path: String): String {
        var name = path.substringAfterLast('/').filterNot { it == '\\' || it.isISOControl() }.ifBlank { "artifact" }
        if (name in setOf(".", "..", "images", "images.json")) name = "artifact-$name"
        while (name.encodeToByteArray().size > 240) name = name.dropLast(1)
        return name
    }
    companion object {
        const val MAX_BYTES: Long = 64L * 1024 * 1024
        const val CACHE_BUDGET: Long = 256L * 1024 * 1024
        // Covers the bounded Markdown parser's destinations with JSON quoting
        // and 32 metadata entries; the writer also budgets every entry.
        private const val IMAGE_MANIFEST_BYTES = 2 * 1024 * 1024
    }
}

internal class ArtifactOfflineException : java.io.IOException("offline")
internal class BoundedArtifactOutput(private val output: OutputStream, private val limit: Long) : OutputStream() {
    var count: Long = 0
        private set
    override fun write(value: Int) = write(byteArrayOf(value.toByte()), 0, 1)
    override fun write(bytes: ByteArray, offset: Int, length: Int) {
        if (count + length > limit) throw ArtifactSizeLimitExceeded(count + length)
        output.write(bytes, offset, length)
        count += length
    }
}
