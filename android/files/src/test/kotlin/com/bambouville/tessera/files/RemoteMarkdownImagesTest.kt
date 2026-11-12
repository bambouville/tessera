package com.bambouville.tessera.files

import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.OutputStream
import java.net.SocketException
import java.nio.file.AccessDeniedException
import java.nio.file.NoSuchFileException
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class RemoteMarkdownImagesTest {
    @get:Rule val temporary = TemporaryFolder()

    private class Reader {
        val stats = mutableMapOf<String, ArtifactRemoteStat>()
        val payloads = mutableMapOf<String, ByteArray>()
        val downloads = mutableListOf<String>()
        var statCalls = 0
        var bytes = 0L
        var live = true
        suspend fun stat(path: String): ArtifactRemoteStat? {
            statCalls += 1
            return stats[path].takeIf { live }
        }
        suspend fun download(path: String, output: OutputStream): ArtifactRemoteStat? {
            check(live) { "there is no channel to download from" }
            downloads += path
            val stat = checkNotNull(stats[path])
            val payload = payloads[path] ?: ByteArray(checkNotNull(stat.size).toInt())
            output.write(payload)
            bytes += payload.size
            return stat
        }
        fun reset() { statCalls = 0; downloads.clear(); bytes = 0 }
    }

    @Test fun pathsResolveAgainstTheRemoteDocumentAndDecodeOnlyOnce() {
        assertEquals("/docs/../images/a b.png", RemoteMarkdownImages.remotePath("../images/a%20b.png", "/docs/readme.md"))
        assertEquals("/opt/a.png", RemoteMarkdownImages.remotePath("/opt/a.png", "/docs/readme.md"))
        assertEquals("/opt/a%20b.png", RemoteMarkdownImages.remotePath("file:///opt/a%2520b.png", "/readme.md"))
        assertEquals("/图.png", RemoteMarkdownImages.remotePath("图.png", "/readme.md"))
        assertEquals("/docs/images/my plot.png", RemoteMarkdownImages.remotePath("images/my plot.png", "/docs/readme.md"))
        assertEquals("/docs/images/plot[1].png", RemoteMarkdownImages.remotePath("images/plot[1].png", "/docs/readme.md"))
        assertEquals("/docs/images/100%.png", RemoteMarkdownImages.remotePath("images/100%.png", "/docs/readme.md"))
        assertEquals("/docs/a+b.png", RemoteMarkdownImages.remotePath("a+b.png", "/docs/readme.md"))
    }

    @Test fun rejectsOtherHostsSchemesAndControlCharacters() {
        listOf("https://example.com/a", "//example.com/a", "file://host/a", "data:image/png;base64,AA", "a%00.png", "a%0A.png", "", "#fragment")
            .forEach { assertNull(it, RemoteMarkdownImages.remotePath(it, "/docs/readme.md")) }
    }

    @Test fun unchangedImagesDownloadAndDecodeNothingAndOnlyChangedMetadataRefetches() = runBlocking {
        val destinations = (1..4).map { "shot-$it.png" }
        val reader = Reader().apply {
            destinations.forEach { name -> stats["/docs/$name"] = ArtifactRemoteStat("/docs/$name", 1024 * 1024, 10_000, false) }
        }
        var creates = 0
        var thumbnails = 0
        val create: (String) -> File = { name -> creates += 1; File(temporary.root, "${UUID.randomUUID()}-$name") }
        val thumbnail: (File, File) -> Boolean = { _, target -> thumbnails += 1; target.writeText("thumbnail-$thumbnails"); true }
        val first = RemoteMarkdownImages.stageCached(destinations, "/docs/report.md", emptyMap(), create, reader::stat, reader::download, thumbnail = thumbnail)
        assertEquals(0, reader.statCalls)
        assertEquals(4L * 1024 * 1024, reader.bytes)
        assertEquals(4, thumbnails)
        reader.reset()
        creates = 0
        val unchanged = RemoteMarkdownImages.stageCached(destinations, "/docs/report.md", first, create, reader::stat, reader::download, thumbnail = thumbnail)
        assertEquals(0L, reader.bytes)
        assertEquals(0, creates)
        assertEquals(4, thumbnails)
        assertEquals(first, unchanged)
        assertEquals(4, reader.statCalls)

        val path = "/docs/shot-2.png"
        reader.stats[path] = checkNotNull(reader.stats[path]).copy(modifiedAtMillis = 20_000)
        val changed = RemoteMarkdownImages.stageCached(destinations, "/docs/report.md", unchanged, create, reader::stat, reader::download, thumbnail = thumbnail)
        assertEquals(listOf(path), reader.downloads)
        assertEquals(1024 * 1024L, reader.bytes)
        assertEquals(5, thumbnails)
        assertTrue(changed.getValue("shot-2.png").file != first.getValue("shot-2.png").file)
        assertTrue(first.values.all { it.file.isFile }) // The manifest owner commits before deleting old files.
        destinations.filter { it != "shot-2.png" }.forEach { assertEquals(first[it], changed[it]) }

        reader.reset()
        reader.stats[path] = reader.stats.getValue(path).copy(size = 512)
        RemoteMarkdownImages.stageCached(destinations, "/docs/report.md", changed, create, reader::stat, reader::download, thumbnail = thumbnail)
        assertEquals(listOf(path), reader.downloads)
        assertEquals(512L, reader.bytes)
        assertEquals(6, thumbnails)
    }

    @Test fun aLostChannelKeepsCachedImagesAndAliasesShareOneStatAndThumbnail() = runBlocking {
        val reader = Reader().apply { stats["/docs/shot.png"] = ArtifactRemoteStat("/docs/shot.png", 10, 12_000, false) }
        val destinations = listOf("shot.png", "file:///docs/shot.png")
        val create: (String) -> File = { File(temporary.root, "${UUID.randomUUID()}-$it") }
        val first = RemoteMarkdownImages.stageCached(destinations, "/docs/report.md", emptyMap(), create, reader::stat, reader::download) { _, target ->
            target.writeText("thumbnail"); true
        }
        assertEquals(0, reader.statCalls)
        assertEquals(1, reader.downloads.size)
        assertEquals(first.getValue(destinations[0]), first.getValue(destinations[1]))
        reader.reset()
        reader.live = false
        val offline = RemoteMarkdownImages.stageCached(destinations, "/docs/report.md", first,
            { error("offline reuse must not create files") }, reader::stat,
            { _, _ -> error("offline reuse must not download") }) { _, _ -> error("offline reuse must not decode") }
        assertEquals(first, offline)
        assertEquals(1, reader.statCalls)
        assertTrue(first.values.all { it.file.isFile })
    }

    @Test fun firstOpenNeverStatsUncachedOrMissingThumbnailsAndRefreshStatsEachCachedPathOnce() = runBlocking {
        val destinations = (1..32).map { "shot-$it.png" }
        val reader = Reader().apply {
            destinations.forEach { name -> stats["/docs/$name"] = ArtifactRemoteStat("/docs/$name", 3, 10_000, false) }
        }
        val create: (String) -> File = { name -> File(temporary.root, "${UUID.randomUUID()}-$name") }
        val thumbnail: (File, File) -> Boolean = { source, target -> source.copyTo(target); true }
        val first = RemoteMarkdownImages.stageCached(destinations, "/docs/report.md", emptyMap(), create,
            reader::stat, reader::download, thumbnail = thumbnail)
        assertEquals(32, first.size)
        assertEquals(0, reader.statCalls)
        assertEquals(32, reader.downloads.size)
        assertTrue(first.values.all { it.size == 3L && it.modifiedAtMillis == 10_000L && it.sourceBytes == 3L })
        reader.reset()
        val unchanged = RemoteMarkdownImages.stageCached(destinations + "file:///docs/shot-1.png", "/docs/report.md", first,
            create, reader::stat, reader::download, thumbnail = thumbnail)
        assertEquals(32, unchanged.size)
        assertEquals(32, reader.statCalls)
        assertTrue(reader.downloads.isEmpty())
        assertTrue(first.getValue("shot-1.png").file.delete())
        reader.reset()
        val repaired = RemoteMarkdownImages.stageCached(destinations, "/docs/report.md", first, create,
            reader::stat, reader::download, thumbnail = thumbnail)
        assertEquals(31, reader.statCalls)
        assertEquals(listOf("/docs/shot-1.png"), reader.downloads)
        assertTrue(repaired.values.all { it.file.isFile })
    }

    @Test fun explicitRefreshDownloadsSameMetadataWhileAutomaticRefreshReusesAndChannelLossKeepsTheCache() = runBlocking {
        val path = "/docs/shot.png"
        val reader = Reader().apply {
            stats[path] = ArtifactRemoteStat(path, 3, 10_000, false)
            payloads[path] = "old".encodeToByteArray()
        }
        val create: (String) -> File = { name -> File(temporary.root, "${UUID.randomUUID()}-$name") }
        val thumbnail: (File, File) -> Boolean = { source, target -> source.copyTo(target); true }
        val first = RemoteMarkdownImages.stageCached(listOf("shot.png"), "/docs/report.md", emptyMap(), create,
            reader::stat, reader::download, thumbnail = thumbnail)
        reader.payloads[path] = "new".encodeToByteArray()
        reader.reset()
        val automatic = RemoteMarkdownImages.stageCached(listOf("shot.png"), "/docs/report.md", first, create,
            reader::stat, reader::download, thumbnail = thumbnail)
        assertEquals(first, automatic)
        assertEquals("old", automatic.getValue("shot.png").file.readText())
        assertEquals(1, reader.statCalls)
        assertTrue(reader.downloads.isEmpty())
        reader.reset()
        val explicit = RemoteMarkdownImages.stageCached(listOf("shot.png", "file:///docs/shot.png"), "/docs/report.md", automatic,
            create, reader::stat, reader::download, force = true, thumbnail = thumbnail)
        assertEquals(0, reader.statCalls)
        assertEquals(listOf(path), reader.downloads)
        assertEquals("new", explicit.getValue("shot.png").file.readText())
        assertEquals(explicit["shot.png"], explicit["file:///docs/shot.png"])
        assertEquals("old", first.getValue("shot.png").file.readText())
        val interrupted = RemoteMarkdownImages.stageCachedWithResult(listOf("shot.png"), "/docs/report.md", explicit, create,
            { error("an explicit refresh must not stat") }, { _, _ -> throw IOException("held channel lost") },
            force = true, thumbnail = thumbnail)
        assertEquals(explicit.filterKeys { it == "shot.png" }, interrupted.images)
        assertFalse(interrupted.forcedDownloadsComplete)
        assertTrue(interrupted.hadTransientFailure)
        assertEquals(2, temporary.root.listFiles()!!.size)
        reader.reset()
        val retried = RemoteMarkdownImages.stageCachedWithResult(listOf("shot.png"), "/docs/report.md", interrupted.images, create,
            reader::stat, reader::download, force = true, thumbnail = thumbnail)
        assertTrue(retried.forcedDownloadsComplete)
        assertFalse(retried.hadTransientFailure)
        assertEquals(listOf(path), reader.downloads)
        assertEquals(0, reader.statCalls)
        assertEquals("new", retried.images.getValue("shot.png").file.readText())
        assertTrue(explicit.getValue("shot.png").file.isFile)
    }

    @Test fun aForcedImageWithoutAPreviousThumbnailStillReportsATransientFailureForRetry() = runBlocking {
        var reads = 0
        val staged = RemoteMarkdownImages.stageCachedWithResult(listOf("new.png"), "/docs/report.md", emptyMap(),
            { name -> File(temporary.root, "${UUID.randomUUID()}-$name") }, { error("forced images must not stat") },
            { _, _ -> reads++; throw IOException("held channel lost") }, force = true) { _, _ -> error("failed image must not decode") }
        assertTrue(staged.images.isEmpty())
        assertFalse(staged.forcedDownloadsComplete)
        assertEquals(1, reads)
        assertTrue(temporary.root.listFiles()!!.isEmpty())
    }

    private fun imageFailures(): List<Pair<Exception, Boolean>> = listOf(
        SFTPException(Response.StatusCode.NO_SUCH_FILE, "missing") to false,
        SFTPException(Response.StatusCode.NO_SUCH_PATH, "missing path") to false,
        SFTPException(Response.StatusCode.PERMISSION_DENIED, "denied") to false,
        SFTPException(Response.StatusCode.OP_UNSUPPORTED, "unsupported") to false,
        FileNotFoundException("missing") to false,
        NoSuchFileException("missing") to false,
        AccessDeniedException("denied") to false,
        SecurityException("denied") to false,
        UnsupportedOperationException("unsupported") to false,
        ArtifactSizeLimitExceeded(RemoteMarkdownImages.MAX_IMAGE_BYTES + 1) to false,
        SFTPException(Response.StatusCode.FAILURE, "generic failure") to true,
        SFTPException(Response.StatusCode.NO_CONNECTION, "not connected") to true,
        SFTPException(Response.StatusCode.CONNECITON_LOST, "connection lost") to true,
        SocketException("network lost") to true,
        IOException("network lost") to true,
        IllegalStateException("not connected") to true,
    )

    @Test fun forcedImageFailuresClearDefinitiveIntentsAndKeepTransientIntentsForRetry() = runBlocking {
        for ((failure, transient) in imageFailures()) {
            val directory = temporary.newFolder()
            val cached = File(directory, "cached.png").apply { writeText("old") }
            val previous = mapOf("shot.png" to RemoteMarkdownImages.CachedImage(cached, "/docs/shot.png", 3, 10))
            var downloads = 0
            val result = RemoteMarkdownImages.stageCachedWithResult(listOf("shot.png"), "/docs/report.md", previous,
                { name -> File(directory, "${UUID.randomUUID()}-$name") }, { error("forced images must not stat") },
                { _, _ -> downloads++; throw failure }, force = true) { _, _ -> error("failed images must not decode") }
            assertEquals(failure.toString(), !transient, result.forcedDownloadsComplete)
            assertEquals(failure.toString(), transient, result.hadTransientFailure)
            assertEquals(if (transient) previous else emptyMap<String, RemoteMarkdownImages.CachedImage>(), result.images)
            assertEquals(1, downloads)
            assertEquals("old", cached.readText())
            assertEquals(listOf(cached), directory.listFiles()!!.toList())
        }
    }

    @Test fun definitiveImageStatFailuresDropTheThumbnailAndTransientFailuresReuseItWithoutDownloads() = runBlocking {
        for ((failure, transient) in imageFailures()) {
            val cached = temporary.newFile().apply { writeText("old") }
            val previous = mapOf("shot.png" to RemoteMarkdownImages.CachedImage(cached, "/docs/shot.png", 3, 10))
            var stats = 0
            val result = RemoteMarkdownImages.stageCachedWithResult(listOf("shot.png"), "/docs/report.md", previous,
                { error("failed stats must not create files") }, { stats++; throw failure },
                { _, _ -> error("failed stats must not download") }) { _, _ -> error("failed stats must not decode") }
            assertEquals(if (transient) previous else emptyMap<String, RemoteMarkdownImages.CachedImage>(), result.images)
            assertEquals(1, stats)
            assertEquals(failure.toString(), transient, result.hadTransientFailure)
            assertTrue(result.forcedDownloadsComplete)
            assertEquals("old", cached.readText())
        }
    }

    @Test fun ordinaryDownloadsReportTransientFailuresSeparatelyFromForcedCompletion() = runBlocking {
        for ((failure, transient) in imageFailures()) {
            val directory = temporary.newFolder()
            var downloads = 0
            val result = RemoteMarkdownImages.stageCachedWithResult(listOf("shot.png"), "/docs/report.md", emptyMap(),
                { name -> File(directory, "${UUID.randomUUID()}-$name") }, { error("uncached images must not stat") },
                { _, _ -> downloads++; throw failure }) { _, _ -> error("failed downloads must not decode") }
            assertEquals(failure.toString(), transient, result.hadTransientFailure)
            assertTrue(result.forcedDownloadsComplete)
            assertTrue(result.images.isEmpty())
            assertEquals(1, downloads)
            assertTrue(directory.listFiles()!!.isEmpty())
        }
    }

    @Test fun undecodableImagesAreDefinitiveOnBothOrdinaryAndForcedLoads() = runBlocking {
        for (force in listOf(false, true)) {
            var downloads = 0
            val directory = temporary.newFolder()
            val result = RemoteMarkdownImages.stageCachedWithResult(listOf("shot.png"), "/docs/report.md", emptyMap(),
                { name -> File(directory, "${UUID.randomUUID()}-$name") }, { error("uncached images must not stat") },
                { path, output -> downloads++; output.write(1); ArtifactRemoteStat(path, 1, 10, false) }, force) { _, _ -> false }
            assertFalse(result.hadTransientFailure)
            assertTrue(result.forcedDownloadsComplete)
            assertTrue(result.images.isEmpty())
            assertEquals(1, downloads)
            assertTrue(directory.listFiles()!!.isEmpty())
        }
    }

    @Test fun cachedImagesStillConsumeTheImageCountAndSourceByteBudgets() = runBlocking {
        val reader = Reader()
        val previous = (1..40).associate { index ->
            val path = "/docs/$index.png"
            val file = temporary.newFile("$index.png").apply { writeText("thumbnail") }
            reader.stats[path] = ArtifactRemoteStat(path, 1024, 10_000, false)
            "$index.png" to RemoteMarkdownImages.CachedImage(file, path, 1024, 10_000)
        }
        val byCount = RemoteMarkdownImages.stageCached(previous.keys.toList(), "/docs/report.md", previous,
            { error("unchanged images must not create files") }, reader::stat,
            { _, _ -> error("unchanged images must not download") }) { _, _ -> error("unchanged images must not decode") }
        assertEquals(32, byCount.size)
        assertEquals(32, reader.statCalls)
        val large = previous.mapValues { (_, image) -> image.copy(size = RemoteMarkdownImages.MAX_IMAGE_BYTES) }
        reader.stats.replaceAll { _, stat -> stat.copy(size = RemoteMarkdownImages.MAX_IMAGE_BYTES) }
        reader.reset()
        val byBytes = RemoteMarkdownImages.stageCached(large.keys.toList(), "/docs/report.md", large,
            { error("cached source bytes must enforce the budget") }, reader::stat,
            { _, _ -> error("cached source bytes must enforce the budget") }) { _, _ -> error("cached images must not decode") }
        assertEquals(4, byBytes.size)
        assertEquals(4, reader.statCalls)
        assertEquals(0L, reader.bytes)
        // A small/moving remote stat must not erase the bytes actually read.
        val underreported = large.mapValues { (_, image) -> image.copy(size = 1, sourceBytes = RemoteMarkdownImages.MAX_IMAGE_BYTES) }
        reader.stats.replaceAll { _, stat -> stat.copy(size = 1) }
        reader.reset()
        val actualBytes = RemoteMarkdownImages.stageCached(underreported.keys.toList(), "/docs/report.md", underreported,
            { error("cached source bytes must enforce the budget") }, reader::stat,
            { _, _ -> error("cached source bytes must enforce the budget") }) { _, _ -> error("cached images must not decode") }
        assertEquals(4, actualBytes.size)
        assertEquals(4, reader.statCalls)
    }

    @Test fun aFailedTransferDoesNotSpendTheCachedImageBudgetOrDeleteCachedThumbnails() = runBlocking {
        val previous = (1..4).associate { index ->
            val path = "/docs/$index.png"
            val file = temporary.newFile("$index.png").apply { writeText("thumbnail") }
            "$index.png" to RemoteMarkdownImages.CachedImage(file, path, RemoteMarkdownImages.MAX_IMAGE_BYTES, 10_000)
        }
        var downloads = 0
        val images = RemoteMarkdownImages.stageCached(listOf("new.png") + previous.keys, "/docs/report.md", previous,
            { name -> File(temporary.root, "${UUID.randomUUID()}-$name") },
            { path ->
                if (downloads > 0) throw IOException("live channel lost")
                ArtifactRemoteStat(path, RemoteMarkdownImages.MAX_IMAGE_BYTES, 10_000, false)
            }, { _, output ->
                downloads += 1
                output.write(ByteArray(1024 * 1024))
                throw IOException("live channel lost")
            }) { _, _ -> error("interrupted images must not decode") }
        assertEquals(previous, images)
        assertEquals(1, downloads)
        assertTrue(previous.values.all { it.file.isFile })
        assertEquals(4, temporary.root.listFiles()!!.size)
    }

    @Test fun missingOrBrokenRemoteImagesKeepTheirAltTextRatherThanAnOutdatedThumbnail() = runBlocking {
        val cached = temporary.newFile("cached.png").apply { writeText("saved") }
        val previous = mapOf("shot.png" to RemoteMarkdownImages.CachedImage(cached, "/docs/shot.png", 5, 10_000))
        val missing = RemoteMarkdownImages.stageCached(listOf("shot.png"), "/docs/report.md", previous,
            { error("missing images must not create files") }, { throw java.io.FileNotFoundException() },
            { _, _ -> error("missing images must not download") }) { _, _ -> error("missing images must not decode") }
        assertTrue(missing.isEmpty())
        val broken = RemoteMarkdownImages.stageCached(listOf("shot.png"), "/docs/report.md", previous,
            { name -> File(temporary.root, "${UUID.randomUUID()}-$name") },
            { path -> ArtifactRemoteStat(path, 5, 20_000, false) },
            { path, output -> output.write(ByteArray(5)); ArtifactRemoteStat(path, 5, 20_000, false) }) { _, _ -> false }
        assertTrue(broken.isEmpty())
        val oversized = RemoteMarkdownImages.stageCached(listOf("shot.png"), "/docs/report.md", previous,
            { name -> File(temporary.root, "${UUID.randomUUID()}-$name") },
            { path -> ArtifactRemoteStat(path, 5, 20_000, false) },
            { _, _ -> throw ArtifactSizeLimitExceeded(RemoteMarkdownImages.MAX_IMAGE_BYTES + 1) }) { _, _ ->
            error("oversized images must not decode")
        }
        assertTrue(oversized.isEmpty())
        assertEquals("saved", cached.readText())
    }

    @Test fun cancellationDeletesOnlyNewThumbnailsAndNeverThePreviousCache() = runBlocking {
        val cached = temporary.newFile("cached.png").apply { writeText("saved") }
        val previous = mapOf("cached.png" to RemoteMarkdownImages.CachedImage(cached, "/docs/cached.png", 5, 10_000))
        val created = mutableListOf<File>()
        try {
            RemoteMarkdownImages.stageCached(listOf("cached.png", "new.png", "cancel.png"), "/docs/report.md", previous,
                { name -> File(temporary.root, "${UUID.randomUUID()}-$name").also(created::add) },
                { path ->
                    if (path.endsWith("cancel.png")) throw CancellationException("cancel refresh")
                    ArtifactRemoteStat(path, 5, 10_000, false)
                }, { path, output ->
                    if (path.endsWith("cancel.png")) throw CancellationException("cancel refresh")
                    output.write(ByteArray(5)); ArtifactRemoteStat(path, 5, 10_000, false)
                }) { _, target ->
                target.writeText("new"); true
            }
            error("cancellation was swallowed")
        } catch (_: CancellationException) { }
        assertEquals("saved", cached.readText())
        assertEquals(4, created.size)
        assertTrue(created.none(File::exists))
    }

    @Test fun unknownMetadataRefetchesAndTheStreamingLimitStillRejectsOversizedImages() = runBlocking {
        val old = temporary.newFile("old.png").apply { writeText("old") }
        val previous = mapOf("shot.png" to RemoteMarkdownImages.CachedImage(old, "/docs/shot.png", 3, null))
        var reads = 0
        val images = RemoteMarkdownImages.stageCached(listOf("shot.png", "large.png"), "/docs/report.md", previous,
            { name -> File(temporary.root, "${UUID.randomUUID()}-$name") },
            { path -> ArtifactRemoteStat(path, 3, null, false) },
            { path, output ->
                reads += 1
                output.write(ByteArray(if (path.endsWith("large.png")) RemoteMarkdownImages.MAX_IMAGE_BYTES.toInt() + 1 else 3))
                ArtifactRemoteStat(path, 3, null, false)
            }) { _, target -> target.writeText("thumbnail"); true }
        assertEquals(2, reads)
        assertEquals(setOf("shot.png"), images.keys)
        assertTrue(images.getValue("shot.png").file != old)
        assertFalse(temporary.root.listFiles()!!.any { it.name.endsWith("image-download") })
        assertEquals("old", old.readText())
    }
}
