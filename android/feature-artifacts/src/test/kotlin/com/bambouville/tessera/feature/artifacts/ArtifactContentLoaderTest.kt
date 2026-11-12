package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheEntry
import com.bambouville.tessera.core.bridge.SharedArtifactsCacheMetadata
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.core.bridge.SharedArtifactsViewer
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.files.ArtifactSizeLimitExceeded
import com.bambouville.tessera.files.RemoteMarkdownImages
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.io.RandomAccessFile
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ArtifactContentLoaderTest {
    @get:Rule val temporary = TemporaryFolder()
    private val key = "a".repeat(64)
    private val tab = SharedArtifactTab("t", "h", "dev", SharedArtifactsTarget.File("/work/a.txt"), SharedArtifactsKind.Docs,
        "a.txt", "files", null, 1, 1, false, null, false, null)

    private class Slot {
        var currentOrNull: ByteArray? = null
        var connectionAttempts = 0
        fun connected(): Nothing { connectionAttempts += 1; error("artifacts must never connect") }
    }
    private class Files(private val slot: Slot) : ArtifactLiveFiles {
        var reads = 0
        var reportedSize: Long? = null
        var failAfterWrite = false
        override val hasLiveArtifactChannel get() = slot.currentOrNull != null
        override val artifactHome: String? = "/home/me"
        override val artifactDirectory: String? = "/work"
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat? = slot.currentOrNull?.let {
            ArtifactRemoteStat(path, reportedSize ?: it.size.toLong(), 12_000, false)
        }
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? {
            val current = slot.currentOrNull ?: return null
            reads += 1
            if ((reportedSize ?: current.size.toLong()) > maxBytes) throw ArtifactSizeLimitExceeded(checkNotNull(reportedSize))
            output.write(current)
            if (failAfterWrite) throw java.io.IOException("interrupted transfer")
            return statArtifactOnLiveChannel(path)
        }
        override suspend fun probeOnLiveChannel(command: String): String? = null
    }
    private fun loader(files: Files) = ArtifactContentLoader(File(temporary.root, "noBackup/artifacts/cache"), { files.takeIf { it.hasLiveArtifactChannel } },
        key = { key }, viewer = { SharedArtifactsViewer.Text }, stageImages = { _, _, _, _ -> emptyMap() })

    private class MarkdownFiles : ArtifactLiveFiles {
        var live = true
        var disconnectAfterDocument = false
        var documentReads = 0
        var imageBytes = 0L
        var imagePayload: ByteArray? = null
        val imageReads = mutableListOf<String>()
        val imageStats = mutableListOf<String>()
        val images = (1..4).associate { index ->
            val path = "/work/shot-$index.png"
            path to ArtifactRemoteStat(path, 1024 * 1024, 12_000, false)
        }.toMutableMap()
        override val hasLiveArtifactChannel get() = live
        override val artifactHome: String? = "/home/me"
        override val artifactDirectory: String? = "/work"
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat? {
            imageStats += path
            return images[path].takeIf { live }
        }
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? {
            if (path.endsWith(".md")) {
                if (!live) return null
                documentReads += 1
                val document = "# report $documentReads".encodeToByteArray()
                output.write(document)
                if (disconnectAfterDocument) live = false
                return ArtifactRemoteStat(path, document.size.toLong(), documentReads.toLong(), false)
            }
            imageReads += path
            if (!live) return null
            val stat = images.getValue(path)
            val payload = imagePayload ?: ByteArray(checkNotNull(stat.size).toInt())
            check(payload.size <= maxBytes)
            output.write(payload)
            imageBytes += payload.size
            return stat
        }
        override suspend fun probeOnLiveChannel(command: String): String? = error("images must not probe or connect")
        fun reset() { documentReads = 0; imageBytes = 0; imageReads.clear(); imageStats.clear() }
    }

    @Test fun imageOnlyRetriesReuseTheDocumentStayOfflineWithoutAChannelAndRefetchAMissingCache() = runBlocking {
        val files = MarkdownFiles()
        val markdown = tab.copy(target = SharedArtifactsTarget.File("/work/report.md"))
        val forces = mutableListOf<Boolean>()
        val loader = ArtifactContentLoader(temporary.newFolder(), { files }, key = { key }, viewer = { SharedArtifactsViewer.Markdown },
            stageCachedImages = { _, _, _, _, _, _, force ->
                forces += force
                RemoteMarkdownImages.StagingResult(emptyMap(), false)
            })
        val first = loader.load(markdown, 1)
        assertTrue(first.content is ArtifactContent.Document)
        assertTrue(first.cache != null)
        assertEquals(1, files.documentReads)
        val retry = loader.load(markdown, 2, forceImages = true, fetchDocument = false)
        assertTrue(retry.content is ArtifactContent.Document)
        assertNull(retry.cache) // Retrying an image must not claim a fresh document or clear stale metadata.
        assertEquals(1, files.documentReads)
        assertEquals(listOf(false, true), forces)

        files.live = false
        assertTrue(loader.load(markdown, 3, forceImages = true, fetchDocument = false).content is ArtifactContent.Document)
        assertEquals(1, files.documentReads)
        assertEquals(listOf(false, true), forces)
        files.live = true
        assertTrue(loader.cacheFile(markdown).delete())
        val repaired = loader.load(markdown, 4, forceImages = true, fetchDocument = false)
        assertTrue(repaired.content is ArtifactContent.Document)
        assertTrue(repaired.cache != null)
        assertEquals(2, files.documentReads)
        assertEquals(listOf(false, true, true), forces)
        assertTrue(files.imageReads.isEmpty())
        assertTrue(files.imageStats.isEmpty())
    }

    @Test fun ordinaryImageShortfallsReachTheStoreAndImageOnlyRetriesKeepTheSameDocumentPath() = runBlocking {
        val files = MarkdownFiles().apply {
            images.clear()
            images["/work/shot.png"] = ArtifactRemoteStat("/work/shot.png", 3, 12_000, false)
            imagePayload = "new".encodeToByteArray()
            disconnectAfterDocument = true
        }
        val markdown = tab.copy(target = SharedArtifactsTarget.File("/work/report.md"))
        var dropBeforeStaging = false
        val loader = ArtifactContentLoader(temporary.newFolder(), { files.takeIf { it.hasLiveArtifactChannel } }, key = { key },
            viewer = { SharedArtifactsViewer.Markdown }, stageCachedImages = { _, path, previous, create, stat, download, force ->
                if (dropBeforeStaging) files.live = false
                RemoteMarkdownImages.stageCachedWithResult(listOf("shot.png"), path, previous, create, stat, download, force) { source, target ->
                    source.copyTo(target)
                    true
                }
            })
        val first = loader.load(markdown, 1)
        val document = first.content as ArtifactContent.Document
        assertTrue(first.imagesFellShort)
        assertTrue(first.forcedImagesComplete)
        assertTrue(document.stagedImages.isEmpty())
        assertEquals(1, files.documentReads)
        assertEquals(listOf("/work/shot.png"), files.imageReads)
        assertEquals(0L, files.imageBytes)

        files.live = true
        files.disconnectAfterDocument = false
        files.reset()
        val retry = loader.load(markdown, 2, fetchDocument = false)
        val completed = retry.content as ArtifactContent.Document
        assertFalse(retry.imagesFellShort)
        assertNull(retry.cache)
        assertEquals(document.file, completed.file)
        assertEquals(document.displayName, completed.displayName)
        assertEquals("new", completed.stagedImages.getValue("shot.png").readText())
        assertEquals(0, files.documentReads)
        assertEquals(listOf("/work/shot.png"), files.imageReads)
        assertEquals(3L, files.imageBytes)
        assertTrue(files.imageStats.isEmpty())

        files.reset()
        dropBeforeStaging = true
        val interruptedStat = loader.load(markdown, 3, fetchDocument = false)
        assertTrue(interruptedStat.imagesFellShort)
        assertTrue(interruptedStat.forcedImagesComplete)
        assertEquals(completed.stagedImages, (interruptedStat.content as ArtifactContent.Document).stagedImages)
        assertEquals(listOf("/work/shot.png"), files.imageStats)
        assertTrue(files.imageReads.isEmpty())
        assertEquals(0, files.documentReads)
        assertEquals(0L, files.imageBytes)
    }

    @Test fun markdownRefreshPersistsImageIdentityAndRefetchesOnlyTheChangedImageAfterRestart() = runBlocking {
        val files = MarkdownFiles()
        val root = temporary.newFolder()
        val markdown = tab.copy(target = SharedArtifactsTarget.File("/work/report.md"))
        var references = (1..4).map { "shot-$it.png" }
        var thumbnails = 0
        fun makeLoader() = ArtifactContentLoader(root, { files }, key = { key }, viewer = { SharedArtifactsViewer.Markdown },
            stageCachedImages = { _, path, previous, create, stat, download, force ->
                RemoteMarkdownImages.stageCachedWithResult(references, path, previous, create, stat, download, force) { _, target ->
                    thumbnails += 1
                    target.writeText("thumbnail-$thumbnails")
                    true
                }
            })
        val loader = makeLoader()
        val first = loader.load(markdown, 1).content as ArtifactContent.Document
        assertEquals(4L * 1024 * 1024, files.imageBytes)
        assertEquals(4, thumbnails)
        assertEquals(references.toSet(), first.stagedImages.keys)
        val manifest = File(loader.cacheDirectory(markdown), "images.json")
        val json = org.json.JSONObject(manifest.readText()).getJSONObject("shot-2.png")
        assertFalse(json.has("path"))
        assertEquals(1024 * 1024L, json.getLong("size"))
        assertEquals(12_000L, json.getLong("mtime"))
        assertEquals(1024 * 1024L, json.getLong("bytes"))
        assertTrue(manifest.setLastModified(946_684_800_000L))
        val modifiedAt = manifest.lastModified()
        val restarted = makeLoader()
        files.reset()
        val unchanged = restarted.load(markdown, 2).content as ArtifactContent.Document
        assertEquals(0L, files.imageBytes)
        assertTrue(files.imageReads.isEmpty())
        assertEquals(4, files.imageStats.size)
        assertEquals(4, thumbnails)
        assertEquals(first.stagedImages, unchanged.stagedImages)
        assertEquals(modifiedAt, manifest.lastModified())

        files.reset()
        val changedPath = "/work/shot-2.png"
        files.images[changedPath] = files.images.getValue(changedPath).copy(modifiedAtMillis = 20_000)
        val changed = restarted.load(markdown, 3).content as ArtifactContent.Document
        assertEquals(listOf(changedPath), files.imageReads)
        assertEquals(1024 * 1024L, files.imageBytes)
        assertEquals(5, thumbnails)
        assertFalse(first.stagedImages.getValue("shot-2.png").exists())
        assertTrue(changed.stagedImages.getValue("shot-2.png").isFile)
        references.filter { it != "shot-2.png" }.forEach { assertEquals(first.stagedImages[it], changed.stagedImages[it]) }

        files.reset()
        references = references.drop(1)
        val removed = restarted.load(markdown, 4).content as ArtifactContent.Document
        assertEquals(0L, files.imageBytes)
        assertEquals(changed.stagedImages - "shot-1.png", removed.stagedImages)
        assertFalse(first.stagedImages.getValue("shot-1.png").exists())
        assertTrue(removed.stagedImages.values.all(File::isFile))
        assertTrue(File(loader.cacheDirectory(markdown), "images/.artifact-content").isFile)

        files.reset()
        files.images["/work/new.png"] = ArtifactRemoteStat("/work/new.png", 512, 30_000, false)
        references = references + "new.png"
        val added = restarted.load(markdown, 5).content as ArtifactContent.Document
        assertEquals(listOf("/work/new.png"), files.imageReads)
        assertEquals(512L, files.imageBytes)
        assertEquals(6, thumbnails)
        assertTrue(added.stagedImages.values.all(File::isFile))

        files.reset()
        files.disconnectAfterDocument = true
        val disconnected = restarted.load(markdown, 6).content as ArtifactContent.Document
        assertEquals(added.stagedImages, disconnected.stagedImages)
        assertEquals(0L, files.imageBytes)
        assertTrue(files.imageReads.isEmpty())
        assertEquals(6, thumbnails)
        files.reset()
        val offline = makeLoader().load(markdown, 7).content as ArtifactContent.Document
        assertEquals(added.stagedImages, offline.stagedImages)
        assertEquals(0, files.documentReads)
        assertTrue(files.imageReads.isEmpty() && files.imageStats.isEmpty())
        assertTrue(offline.stagedImages.values.all(File::isFile))
    }

    @Test fun longDocumentDirectoriesAndDestinationsKeepAll32ImagesAfterRestart() = runBlocking {
        for (longDirectory in listOf(true, false)) {
            val directory = if (longDirectory) "/" + List(10) { "d".repeat(209) }.joinToString("/") else "/work"
            if (longDirectory) assertEquals(2_100, directory.encodeToByteArray().size)
            val references = (1..32).map { (if (longDirectory) "shot" else "s".repeat(2_100)) + "-$it.png" }
            val markdown = tab.copy(target = SharedArtifactsTarget.File("$directory/report.md"))
            val files = MarkdownFiles().apply {
                images.clear()
                references.forEach { name -> images["$directory/$name"] = ArtifactRemoteStat("$directory/$name", 64, 12_000, false) }
            }
            val root = temporary.newFolder()
            var thumbnails = 0
            fun makeLoader() = ArtifactContentLoader(root, { files.takeIf { it.hasLiveArtifactChannel } }, key = { key },
                viewer = { SharedArtifactsViewer.Markdown }, stageCachedImages = { _, path, previous, create, stat, download, force ->
                    RemoteMarkdownImages.stageCachedWithResult(references, path, previous, create, stat, download, force) { _, target ->
                        thumbnails++
                        target.writeText("thumbnail")
                        true
                    }
                })
            val loader = makeLoader()
            val first = loader.load(markdown, 1).content as ArtifactContent.Document
            assertEquals(references.toSet(), first.stagedImages.keys)
            assertEquals(32, thumbnails)
            assertEquals(0, files.imageStats.size)
            assertEquals(32, files.imageReads.size)
            val manifest = File(loader.cacheDirectory(markdown), "images.json")
            if (longDirectory) {
                assertTrue(manifest.length() < 8 * 1024)
                // The prior writer repeated the 2,100-byte directory 32 times.
                val legacy = org.json.JSONObject().apply {
                    first.stagedImages.forEach { (destination, image) ->
                        put(destination, org.json.JSONObject().put("file", image.name).put("path", "$directory/$destination")
                            .put("size", 64).put("mtime", 12_000).put("bytes", 64))
                    }
                }
                manifest.writeText(legacy.toString())
            }
            assertTrue(manifest.length() > 64 * 1024)
            files.reset()
            val restarted = makeLoader()
            val unchanged = restarted.load(markdown, 2).content as ArtifactContent.Document
            assertEquals(first.stagedImages, unchanged.stagedImages)
            assertEquals(32, files.imageStats.size)
            assertTrue(files.imageReads.isEmpty())
            assertEquals(32, thumbnails)
            files.live = false
            assertEquals(first.stagedImages, checkNotNull(makeLoader().cached(markdown, 3)).stagedImages)
        }
    }

    @Test fun imageManifestDropsOnlyAnOversizedOrMalformedEntry() = runBlocking {
        val files = MarkdownFiles()
        val markdown = tab.copy(target = SharedArtifactsTarget.File("/work/report.md"))
        val huge = "x".repeat(2 * 1024 * 1024) + ".png"
        val loader = ArtifactContentLoader(temporary.newFolder(), { files }, key = { key }, viewer = { SharedArtifactsViewer.Markdown },
            stageCachedImages = { _, path, _, create, _, _, _ ->
                val images = listOf(huge, "valid.png").associateWith { destination ->
                    val file = create("image.png").apply { writeText("thumbnail") }
                    RemoteMarkdownImages.CachedImage(file, checkNotNull(RemoteMarkdownImages.remotePath(destination, path)), 5, 12_000)
                }
                RemoteMarkdownImages.StagingResult(images, true)
            })
        val loaded = loader.load(markdown, 1).content as ArtifactContent.Document
        assertEquals(setOf("valid.png"), loaded.stagedImages.keys)
        val manifest = File(loader.cacheDirectory(markdown), "images.json")
        assertTrue(manifest.length() < 1024)
        val json = org.json.JSONObject(manifest.readText()).put("malformed.png", 42)
            .put("wrong-host-path.png", org.json.JSONObject().put("file", loaded.stagedImages.getValue("valid.png").name).put("path", "/elsewhere.png"))
        manifest.writeText(json.toString())
        assertEquals(loaded.stagedImages, checkNotNull(loader.cached(markdown, 2)).stagedImages)
        assertEquals(1, File(loader.cacheDirectory(markdown), "images").listFiles()!!.count { it.extension == "png" })
    }

    @Test fun onlyExplicitRefreshBypassesImageReuseAndOfflineRefreshNeverConnects() = runBlocking {
        val files = MarkdownFiles().apply {
            images.clear()
            images["/work/shot.png"] = ArtifactRemoteStat("/work/shot.png", 3, 12_000, false)
            imagePayload = "old".encodeToByteArray()
        }
        val markdown = tab.copy(target = SharedArtifactsTarget.File("/work/report.md"))
        val loader = ArtifactContentLoader(temporary.newFolder(), { files.takeIf { it.hasLiveArtifactChannel } }, key = { key },
            viewer = { SharedArtifactsViewer.Markdown }, stageCachedImages = { _, path, previous, create, stat, download, force ->
                RemoteMarkdownImages.stageCachedWithResult(listOf("shot.png"), path, previous, create, stat, download, force) { source, target ->
                    source.copyTo(target)
                    true
                }
            })
        val first = loader.load(markdown, 1).content as ArtifactContent.Document
        files.imagePayload = "new".encodeToByteArray()
        files.reset()
        val automatic = loader.load(markdown, 2).content as ArtifactContent.Document
        assertEquals(first.stagedImages, automatic.stagedImages)
        assertEquals("old", automatic.stagedImages.getValue("shot.png").readText())
        assertTrue(files.imageReads.isEmpty())
        assertEquals(1, files.imageStats.size)
        files.reset()
        val explicit = loader.load(markdown, 3, forceImages = true).content as ArtifactContent.Document
        assertEquals("new", explicit.stagedImages.getValue("shot.png").readText())
        assertEquals(listOf("/work/shot.png"), files.imageReads)
        assertTrue(files.imageStats.isEmpty())
        assertFalse(first.stagedImages.getValue("shot.png").exists())
        files.reset()
        files.live = false
        val offline = loader.load(markdown, 4, forceImages = true).content as ArtifactContent.Document
        assertEquals(explicit.stagedImages, offline.stagedImages)
        assertEquals(0, files.documentReads)
        assertTrue(files.imageReads.isEmpty() && files.imageStats.isEmpty())
    }

    private class RecordingDirectory(directory: File) : File(directory.path) {
        var reads = 0
        var beforeRead: () -> Unit = {}
        override fun listFiles(): Array<File>? { reads += 1; beforeRead(); return super.listFiles() }
    }

    @Test fun constructionDoesNotInspectOrModifyTheCache() {
        val root = RecordingDirectory(temporary.newFolder())
        val directory = File(root, key).apply { mkdirs() }
        val stale = File(directory, "images/.staging/artifact-interrupted.tmp").apply { parentFile!!.mkdirs(); writeText("partial") }
        ArtifactContentLoader(root, { error("construction must not request a connection") }, key = { key }, committedTabs = listOf(tab))
        assertEquals(0, root.reads)
        assertTrue(stale.exists())
    }

    @Test fun recoveryRunsOnceAndFinishesBeforeTheFirstLoadCanLookUpALiveChannel() = runBlocking {
        val root = RecordingDirectory(temporary.newFolder())
        val directory = File(root, key).apply { mkdirs() }
        File(directory, "a.txt").writeText("saved")
        val stale = File(directory, "images/.staging/artifact-interrupted.tmp").apply { parentFile!!.mkdirs(); writeText("partial") }
        var lookups = 0
        val loader = ArtifactContentLoader(root, {
            lookups += 1
            assertFalse(stale.exists())
            assertEquals("a.txt", File(directory, "images/.artifact-content").readText())
            null
        }, key = { key }, committedTabs = listOf(tab))
        assertTrue(loader.load(tab, 1).content is ArtifactContent.Document)
        assertTrue(loader.cached(tab, 2) is ArtifactContent.Document)
        assertTrue(loader.hasCache(tab))
        loader.recover(listOf(tab))
        assertEquals(1, root.reads)
        assertEquals(1, lookups)
    }

    @Test fun cacheReadsAlsoWaitForRecoveryWithoutStartingALoad() = runBlocking {
        for (readDocument in listOf(true, false)) {
            val root = RecordingDirectory(temporary.newFolder())
            val directory = File(root, key).apply { mkdirs() }
            File(directory, "a.txt").writeText("saved")
            val stale = File(directory, "images/.staging/artifact-interrupted.tmp").apply { parentFile!!.mkdirs(); writeText("partial") }
            val loader = ArtifactContentLoader(root, { error("a cache read must not request a connection") }, key = { key }, committedTabs = listOf(tab))
            if (readDocument) assertTrue(loader.cached(tab, 1) is ArtifactContent.Document) else assertTrue(loader.hasCache(tab))
            assertFalse(stale.exists())
            assertEquals(1, root.reads)
        }
    }

    @Test fun recoveryDoesNotRewriteAnAlreadyValidPayloadIdentity() = runBlocking {
        val root = temporary.newFolder()
        val directory = File(root, key).apply { mkdirs() }
        File(directory, "a.txt").writeText("saved")
        val identity = File(directory, "images/.artifact-content").apply { parentFile!!.mkdirs(); writeText("a.txt") }
        assertTrue(identity.setLastModified(946_684_800_000L))
        val modifiedAt = identity.lastModified()
        val loader = ArtifactContentLoader(root, { null }, key = { key }, committedTabs = listOf(tab))
        loader.recover()
        assertEquals("a.txt", identity.readText())
        assertEquals(modifiedAt, identity.lastModified())
        assertFalse(File(directory, "images/.staging").exists())
    }

    @Test(timeout = 10_000) fun concurrentLoadsAndCacheReadsSuspendUntilTheSingleRecoveryCompletes() = runBlocking {
        val root = RecordingDirectory(temporary.newFolder())
        val directory = File(root, key).apply { mkdirs() }
        File(directory, "a.txt").writeText("saved")
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val lookups = AtomicInteger()
        root.beforeRead = { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
        // Undispatched callers reach the recovery mutex on this thread, so
        // an accidentally unguarded cache read would finish before the asserts.
        val loader = ArtifactContentLoader(root, { lookups.incrementAndGet(); null }, key = { key },
            committedTabs = listOf(tab), ioDispatcher = Dispatchers.Unconfined)
        val recovery = async(Dispatchers.IO) { loader.recover() }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val load = async(start = CoroutineStart.UNDISPATCHED) { loader.load(tab, 1) }
            val cached = async(start = CoroutineStart.UNDISPATCHED) { loader.cached(tab, 2) }
            val hasCache = async(start = CoroutineStart.UNDISPATCHED) { loader.hasCache(tab) }
            assertFalse(load.isCompleted)
            assertFalse(cached.isCompleted)
            assertFalse(hasCache.isCompleted)
            assertEquals(0, lookups.get())
            release.countDown()
            recovery.await()
            assertTrue(load.await().content is ArtifactContent.Document)
            assertTrue(cached.await() is ArtifactContent.Document)
            assertTrue(hasCache.await())
            assertEquals(1, root.reads)
        } finally { release.countDown() }
    }

    @Test fun offlineLookupNeverCallsAConnectingSlotAndUsesTheExistingCache() = runBlocking {
        val slot = Slot()
        val files = Files(slot)
        val loader = loader(files)
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Offline), loader.load(tab, 1).content)
        slot.currentOrNull = "hello".encodeToByteArray()
        val fetched = loader.load(tab, 2)
        val document = fetched.content as ArtifactContent.Document
        assertEquals(File(temporary.root, "noBackup/artifacts/cache/$key/a.txt"), document.file)
        assertEquals("hello", document.file.readText())
        assertEquals(12_000L, fetched.cache?.remoteMTime)
        assertEquals(5L, fetched.cache?.size)
        slot.currentOrNull = null
        val offline = loader.load(tab.copy(cache = SharedArtifactsCacheMetadata(1, 12_000, 5)), 3).content as ArtifactContent.Document
        assertEquals("hello", offline.file.readText())
        assertEquals(3L, offline.reloadToken)
        assertEquals(0, slot.connectionAttempts)
        assertEquals(1, files.reads)
    }

    @Test fun knownOversizedFilesAreRejectedAndFailedDownloadsNeverReplaceTheCache() = runBlocking {
        val slot = Slot().apply { currentOrNull = "old".encodeToByteArray() }
        val files = Files(slot)
        val loader = loader(files)
        loader.load(tab, 1)
        slot.currentOrNull = "new".encodeToByteArray()
        files.failAfterWrite = true
        assertTrue(loader.load(tab, 2).content is ArtifactContent.Unavailable)
        assertEquals("old", loader.cacheFile(tab).readText())
        files.failAfterWrite = false
        files.reportedSize = ArtifactContentLoader.MAX_BYTES + 1
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.TooLarge(ArtifactContentLoader.MAX_BYTES + 1)), loader.load(tab, 3).content)
        assertEquals("old", loader.cacheFile(tab).readText())
        assertFalse(loader.cacheDirectory(tab).listFiles()!!.any { it.extension == "tmp" })
        assertEquals(0, slot.connectionAttempts)
    }

    @Test fun theStreamingCapAlsoStopsAFilesAdapterThatIgnoresItsLimit() {
        val output = ByteArrayOutputStream()
        val bounded = BoundedArtifactOutput(output, 4)
        bounded.write(byteArrayOf(1, 2, 3))
        try { bounded.write(byteArrayOf(4, 5)); error("over-limit write was accepted") }
        catch (failure: ArtifactSizeLimitExceeded) { assertEquals(5L, failure.bytes) }
        assertEquals(3, output.size())
    }

    @Test fun startupSweepsEveryKeyAndPreservesCommittedDocumentsAndImages() = runBlocking {
        val root = File(temporary.root, "cache").apply { mkdirs() }
        val first = File(root, key).apply { mkdirs() }
        val second = File(root, "b".repeat(64)).apply { mkdirs() }
        val document = File(first, "artifact-saved.tmp").apply { writeText("committed") }
        val image = File(first, "images/image-saved.png").apply { parentFile!!.mkdirs(); writeText("image") }
        val manifest = File(first, "images.json").apply { writeText("{}") }
        File(second, "images/.artifact-content").apply { parentFile!!.mkdirs(); writeText("b.txt") }
        val stale = listOf(File(first, "artifact-interrupted.tmp"), File(second, "artifact-interrupted.tmp"))
        stale.forEach { it.writeText("partial") }
        val committed = tab.copy(target = SharedArtifactsTarget.File("/work/artifact-saved.tmp"))
        ArtifactContentLoader(root, { error("startup must not request a connection") }, key = { key },
            committedTabs = listOf(committed)).recover()
        assertTrue(stale.none(File::exists))
        assertEquals("committed", document.readText())
        assertTrue(image.isFile && manifest.isFile)
        ArtifactContentLoader(root, { error("startup must not request a connection") }, key = { key }).recover()
        assertEquals("committed", document.readText())
    }

    @Test fun anOfflineLoadAlsoCleansAbandonedStagingCreatedAfterStartup() = runBlocking {
        val slot = Slot()
        val loader = loader(Files(slot))
        val directory = loader.cacheDirectory(tab).apply { mkdirs() }
        val payload = loader.cacheFile(tab).apply { writeText("saved") }
        val stale = File(directory, "artifact-interrupted.tmp").apply { writeText("partial") }
        assertTrue(loader.load(tab, 1).content is ArtifactContent.Document)
        assertFalse(stale.exists())
        assertEquals("saved", payload.readText())
        assertEquals(0, slot.connectionAttempts)
    }

    @Test fun aCommittedPayloadWithAStagingNameSurvivesTheNextLoader() = runBlocking {
        val files = Files(Slot().apply { currentOrNull = "document".encodeToByteArray() })
        val named = tab.copy(target = SharedArtifactsTarget.File("/work/artifact-report.tmp"))
        val loader = loader(files)
        loader.load(named, 1)
        val stale = File(loader.cacheDirectory(named), "artifact-abandoned.tmp").apply { writeText("partial") }
        val restarted = loader(files)
        restarted.recover()
        assertFalse(stale.exists())
        assertEquals("document", restarted.cacheFile(named).readText())
    }

    @Test fun startupCleansOwnedStagingEvenWhenAKeyNeverReachedStatePersistence() = runBlocking {
        val root = temporary.newFolder()
        val directory = File(root, key).apply { mkdirs() }
        val staging = File(directory, "images/.staging").apply { mkdirs() }
        val partial = File(staging, "artifact-interrupted.tmp").apply { writeText("partial") }
        ArtifactContentLoader(root, { error("recovery must not request a connection") }).recover()
        assertFalse(partial.exists())
    }

    @Test fun startupPreservesAnUnmarkedLegacyOrphanThatCouldBeACommittedDocument() = runBlocking {
        val root = temporary.newFolder()
        val directory = File(root, key).apply { mkdirs() }
        val document = File(directory, "artifact-report.tmp").apply { writeText("committed") }
        ArtifactContentLoader(root, { error("recovery must not request a connection") }).recover()
        assertEquals("committed", document.readText())
    }

    @Test fun markdownImageCleanupCannotDeleteAnImagePrefixedDocument() = runBlocking {
        val slot = Slot().apply { currentOrNull = "# image report".encodeToByteArray() }
        val files = Files(slot)
        val named = tab.copy(target = SharedArtifactsTarget.File("/work/image-report.md"))
        var previousImage: File? = null
        val loader = ArtifactContentLoader(File(temporary.root, "cache"), { files }, key = { key },
            viewer = { SharedArtifactsViewer.Markdown }, stageImages = { document, _, create, _ ->
                assertTrue(document.isFile)
                if (previousImage == null) {
                    val image = create("image.png").apply { writeText("image") }
                    previousImage = image
                    mapOf("figure.png" to image)
                } else emptyMap()
            })
        val first = loader.load(named, 1).content as ArtifactContent.Document
        assertEquals("# image report", first.file.readText())
        val second = loader.load(named, 2).content as ArtifactContent.Document
        assertEquals("# image report", second.file.readText())
        assertFalse(checkNotNull(previousImage).exists())
        assertTrue(second.stagedImages.isEmpty())
        assertTrue(File(loader.cacheDirectory(named), "images/.artifact-content").isFile)
        assertEquals(0, slot.connectionAttempts)
    }

    @Test(timeout = 10_000) fun protectReturnsWhileRecursiveDeletionIsBlocked() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val protected = CountDownLatch(1)
        val loader = ArtifactContentLoader(temporary.newFolder(), { null }, key = { key },
            evictions = { entries, _, _ -> entries.map { it.key } }, deleteDirectory = {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                it.deleteRecursively()
            })
        loader.cacheFile(tab).apply { parentFile!!.mkdirs(); writeText("saved") }
        val eviction = async(Dispatchers.IO) { loader.evict(listOf(tab), null, emptySet()) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            val protection = async(Dispatchers.Default) {
                val changed = loader.protect(listOf(tab.copy(pinned = true)), null, emptySet())
                protected.countDown()
                changed
            }
            assertTrue("protect waited for disk deletion", protected.await(1, TimeUnit.SECONDS))
            assertTrue(protection.await())
            assertFalse(loader.cacheDirectory(tab).exists())
        } finally { release.countDown() }
        assertEquals(setOf(key), eviction.await())
    }

    @Test(timeout = 20_000) fun aReservedEntryIsAbsentWhenItBecomesSelectedPinnedOrLoading() = runBlocking {
        for (protection in listOf("selected", "pinned", "loading")) {
            val slot = Slot()
            val files = Files(slot)
            val entered = CountDownLatch(1)
            val release = CountDownLatch(1)
            val loader = ArtifactContentLoader(temporary.newFolder(), { files.takeIf { it.hasLiveArtifactChannel } }, key = { key },
                viewer = { SharedArtifactsViewer.Text }, evictions = { entries, _, _ -> entries.map { it.key } }, deleteDirectory = {
                    File(it, "images/figure.png").delete()
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                    it.deleteRecursively()
                })
            loader.cacheFile(tab).apply { parentFile!!.mkdirs(); writeText("saved") }
            File(loader.cacheDirectory(tab), "images/figure.png").apply { parentFile!!.mkdirs(); writeText("image") }
            File(loader.cacheDirectory(tab), "images.json").writeText("{\"figure.png\":\"figure.png\"}")
            val eviction = async(Dispatchers.IO) { loader.evict(listOf(tab), null, emptySet()) }
            val live = try {
                assertTrue(entered.await(5, TimeUnit.SECONDS))
                val protectedTab = tab.copy(pinned = protection == "pinned")
                val protecting = async(Dispatchers.Default) {
                    loader.protect(listOf(protectedTab), tab.id.takeIf { protection == "selected" },
                        if (protection == "loading") setOf(tab.id) else emptySet())
                }
                withTimeout(1_000) {
                    assertTrue(protecting.await())
                    assertNull(loader.cached(tab, 1))
                    assertFalse(loader.hasCache(tab))
                    assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Offline), loader.load(tab, 2).content)
                }
                slot.currentOrNull = "refetched".encodeToByteArray()
                // A live load waits for the deletion rather than reporting offline.
                val pending = async(Dispatchers.IO) { loader.load(tab, 3).content }
                delay(200)
                assertFalse(pending.isCompleted)
                assertEquals(0, files.reads)
                pending
            } finally { release.countDown() }
            assertEquals(setOf(key), eviction.await())
            val refetched = withTimeout(5_000) { live.await() } as ArtifactContent.Document
            assertEquals("refetched", refetched.file.readText())
            assertTrue(loader.evict(listOf(tab), null, emptySet()).isEmpty())
            assertEquals("refetched", checkNotNull(loader.cached(tab, 5)).file.readText())
            assertEquals(1, files.reads)
            assertEquals(0, slot.connectionAttempts)
        }
    }

    @Test(timeout = 10_000) fun deletionEnforcesTheBudgetAndPreservesSelectedPinnedAndLoadingEntries() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val tabs = ('a'..'f').map { id -> tab.copy(id = id.toString(), viewedAt = id.code.toLong(), pinned = id == 'b') }
        val loader = ArtifactContentLoader(temporary.newFolder(), { error("eviction must not request a connection") },
            key = { it.id.repeat(64) }, evictions = ::lruEvictions, deleteDirectory = {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                it.deleteRecursively()
            })
        tabs.forEach { cached ->
            loader.cacheFile(cached).apply {
                parentFile!!.mkdirs()
                RandomAccessFile(this, "rw").use { it.setLength(60L * 1024 * 1024) }
            }
        }
        loader.protect(tabs, "c", setOf("d"))
        val eviction = async(Dispatchers.IO) { loader.evict(tabs, "c", setOf("d")) }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertTrue(loader.cacheRoot.walkTopDown().filter(File::isFile).sumOf(File::length) > ArtifactContentLoader.CACHE_BUDGET)
        } finally { release.countDown() }
        assertEquals(setOf("a".repeat(64), "e".repeat(64)), eviction.await())
        assertTrue(loader.cacheRoot.walkTopDown().filter(File::isFile).sumOf(File::length) <= ArtifactContentLoader.CACHE_BUDGET)
        assertEquals(setOf("b", "c", "d", "f"), tabs.filter { loader.cacheFile(it).isFile }.map { it.id }.toSet())
        assertTrue(loader.cacheRoot.listFiles()!!.none { it.name.startsWith(".evicting-") })
        assertTrue(loader.evict(tabs, "c", setOf("d")).isEmpty())
    }

    @Test fun failedDeletionsRemainInTheBudgetAndAreRemovedByStartupRecovery() = runBlocking {
        val tabs = ('a'..'f').map { id -> tab.copy(id = id.toString(), viewedAt = id.code.toLong(), pinned = id == 'b') }
        var tombstone: File? = null
        val loader = ArtifactContentLoader(temporary.newFolder(), { error("eviction must not request a connection") },
            key = { it.id.repeat(64) }, evictions = ::lruEvictions, deleteDirectory = {
                if (it.name.contains("a".repeat(64))) { tombstone = it; false } else it.deleteRecursively()
            })
        tabs.forEach { cached ->
            loader.cacheFile(cached).apply {
                parentFile!!.mkdirs()
                RandomAccessFile(this, "rw").use { it.setLength(60L * 1024 * 1024) }
            }
        }
        loader.protect(tabs, "c", setOf("d"))
        assertEquals(setOf("a".repeat(64), "e".repeat(64), "f".repeat(64)), loader.evict(tabs, "c", setOf("d")))
        assertTrue(checkNotNull(tombstone).isDirectory)
        assertFalse(loader.hasCache(tabs.first()))
        assertNull(loader.cached(tabs.first(), 1))
        assertTrue(loader.cacheRoot.walkTopDown().filter(File::isFile).sumOf(File::length) <= ArtifactContentLoader.CACHE_BUDGET)
        assertTrue(loader.evict(tabs, "c", setOf("d")).isEmpty())
        val unrelated = File(loader.cacheRoot, ".evicting-unrelated").apply { mkdirs() }
        val restarted = ArtifactContentLoader(loader.cacheRoot, { error("recovery must not request a connection") },
            key = { it.id.repeat(64) }, committedTabs = tabs)
        restarted.recover()
        assertFalse(checkNotNull(tombstone).exists())
        assertTrue(unrelated.isDirectory)
        assertEquals(setOf("b", "c", "d"), tabs.filter { restarted.cacheFile(it).isFile }.map { it.id }.toSet())
        assertNull(restarted.cached(tabs.first(), 2))
    }

    private fun lruEvictions(entries: List<SharedArtifactsCacheEntry>, budget: Long, protected: Set<String>): List<String> {
        var remaining = entries.sumOf { it.size }
        return buildList {
            for (entry in entries.sortedBy { it.viewedAt }) {
                if (remaining <= budget) break
                if (entry.pinned || entry.key in protected) continue
                add(entry.key)
                remaining -= entry.size
            }
        }
    }
}
