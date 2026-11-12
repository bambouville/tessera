package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsPersistenceFiles
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import java.io.File
import java.io.IOException
import java.nio.file.AccessDeniedException
import java.nio.file.FileVisitResult
import java.nio.file.FileVisitor
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ArtifactsBlobRepairTest {
    @get:Rule val temporary = TemporaryFolder()
    private val diff = "+saved edit\n"
    private val digest = MessageDigest.getInstance("SHA-256").digest(diff.encodeToByteArray()).joinToString("") { "%02x".format(it) }
    private val tab = SharedArtifactTab("edit", "host", "dev", SharedArtifactsTarget.Change("/work/a.kt", diff, "edit"),
        SharedArtifactsKind.Changes, "a.kt", "agentEdit", null, 1, 1, false, null, false, null)
    private val state = SharedArtifactsState(tabs = listOf(tab), selectedId = tab.id)

    private fun stateFile(
        file: File,
        read: (File) -> ByteArray? = ::readArtifactBlobBytes,
        replace: (File, File) -> Unit = ::replaceArtifactFile,
        stat: (File) -> BasicFileAttributes? = ::artifactFileAttributes,
        walk: (Path, FileVisitor<Path>) -> Unit = { root, visitor -> Files.walkFileTree(root, visitor) },
    ) = ArtifactsStateFile(file, split = { snapshot ->
        SharedArtifactsPersistenceFiles("{}", if (snapshot.tabs.isEmpty()) emptyMap() else mapOf(digest to diff))
    }, blobDigests = { listOf(digest) }, join = { _, blobs ->
        if (blobs[digest] == diff) state else SharedArtifactsState()
    }, replace = replace, readBlobBytes = read, statBlob = stat, walkBlobObstruction = walk)

    @Test fun aChildVanishingBeforeDeletionStillWritesTheBlobAndManifest() = assertVanishingObstruction("child")
    @Test fun aDirectoryVanishingBeforeDeletionStillWritesTheBlobAndManifest() = assertVanishingObstruction("directory")
    @Test fun aChildVanishingBeforeItsVisitStillWritesTheBlobAndManifest() = assertVanishingObstruction("failed-child")
    @Test fun aRootVanishingBeforeTheWalkStillWritesTheBlobAndManifest() = assertVanishingObstruction("root")
    @Test fun aRootVanishingDuringTheWalkStillWritesTheBlobAndManifest() = assertVanishingObstruction("root-failure")

    private fun assertVanishingObstruction(vanishing: String) {
        val file = File(temporary.newFolder(), "state.json")
        val blob = File(file.parentFile, "changes/$digest.diff")
        val writes = mutableListOf<String>()
        var walks = 0
        var reads = 0
        val writer = stateFile(file, read = { reads++; readArtifactBlobBytes(it) }, replace = { from, to ->
            if (to == file) assertEquals(diff, blob.readText())
            writes += to.name
            replaceArtifactFile(from, to)
        }, walk = { root, visitor ->
            walks++
            if (vanishing.startsWith("root")) {
                Files.delete(root)
                if (vanishing == "root-failure") throw NoSuchFileException(root.toString())
                Files.walkFileTree(root, visitor)
            } else Files.walkFileTree(root, object : SimpleFileVisitor<Path>() {
                override fun visitFile(path: Path, attributes: BasicFileAttributes): FileVisitResult {
                    if (vanishing == "child" || vanishing == "failed-child") Files.delete(path)
                    return if (vanishing == "failed-child") visitor.visitFileFailed(path, NoSuchFileException(path.toString()))
                    else visitor.visitFile(path, attributes)
                }
                override fun postVisitDirectory(directory: Path, failure: IOException?): FileVisitResult {
                    if (vanishing == "directory") Files.delete(directory)
                    return visitor.postVisitDirectory(directory, failure)
                }
                override fun visitFileFailed(path: Path, failure: IOException): FileVisitResult = visitor.visitFileFailed(path, failure)
            })
        })
        writer.save(state, 1)
        assertTrue(blob.delete())
        assertTrue(blob.mkdir())
        if (!vanishing.startsWith("root")) {
            File(blob, "nested/entry").apply { parentFile!!.mkdirs(); writeText("obstruction") }
        }
        writes.clear()
        writer.save(state, 2)
        assertEquals(vanishing, 1, walks)
        assertEquals(vanishing, 0, reads)
        assertEquals(vanishing, listOf("$digest.diff", "state.json"), writes)
        assertEquals(vanishing, diff, blob.readText())
        assertEquals(vanishing, state, stateFile(file).load())
    }

    @Test fun obstructionRemovalPropagatesOtherWalkFailuresWithoutWritingABlobOrManifest() {
        for (callback in listOf("file", "directory", "walk")) {
            val file = File(temporary.newFolder(), "state.json")
            val blob = File(file.parentFile, "changes/$digest.diff")
            val denied = AccessDeniedException(blob.path)
            val writes = mutableListOf<String>()
            val writer = stateFile(file, replace = { from, to -> writes += to.name; replaceArtifactFile(from, to) },
                walk = { root, visitor ->
                    when (callback) {
                        "file" -> visitor.visitFileFailed(root, denied)
                        "directory" -> visitor.postVisitDirectory(root, denied)
                        else -> throw denied
                    }
                })
            writer.save(state, 1)
            assertTrue(blob.delete())
            assertTrue(blob.mkdir())
            writes.clear()
            try { writer.save(state, 2); error("a failed obstruction removal was accepted") }
            catch (failure: AccessDeniedException) { assertTrue(failure === denied) }
            assertTrue(writes.isEmpty())
            assertTrue(blob.isDirectory)
        }
    }

    @Test fun vanishedTruncatedAndNonRegularVerifiedBlobsAreRewrittenBeforeTheManifestWithoutReads() {
        for (damage in listOf("deleted", "truncated", "directory")) {
            val file = File(temporary.newFolder(), "state.json")
            val blob = File(file.parentFile, "changes/$digest.diff")
            var reads = 0
            var stats = 0
            val writes = mutableListOf<String>()
            val writer = stateFile(file, read = { reads++; readArtifactBlobBytes(it) }, stat = {
                stats++
                artifactFileAttributes(it)
            }, replace = { from, to ->
                if (to == file) assertEquals(diff, blob.readText())
                writes += to.name
                replaceArtifactFile(from, to)
            })
            writer.save(state, 1)
            if (damage == "truncated") blob.writeText(diff.dropLast(1)) else {
                assertTrue(blob.delete())
                if (damage == "directory") assertTrue(blob.mkdir())
            }
            reads = 0; stats = 0; writes.clear()
            writer.save(state, 2)
            assertEquals(0, reads)
            assertEquals(1, stats)
            assertEquals(listOf("$digest.diff", "state.json"), writes)
            writes.clear(); stats = 0
            writer.save(state, 3)
            assertEquals(0, reads)
            assertEquals(1, stats)
            assertEquals(listOf("state.json"), writes)
            assertEquals(state, stateFile(file).load())
        }
    }

    @Test fun aNonEmptyDirectoryAtAVerifiedBlobIsReplacedWithoutFollowingItsNestedSymlinks() {
        val file = File(temporary.newFolder(), "state.json")
        val blob = File(file.parentFile, "changes/$digest.diff")
        val outside = temporary.newFolder()
        val sentinel = File(outside, "keep.txt").apply { writeText("untouched") }
        var reads = 0
        var stats = 0
        val writes = mutableListOf<String>()
        val writer = stateFile(file, read = { reads++; readArtifactBlobBytes(it) }, stat = {
            stats++
            artifactFileAttributes(it)
        }, replace = { from, to ->
            if (to == file) assertEquals(diff, blob.readText())
            writes += to.name
            replaceArtifactFile(from, to)
        })
        writer.save(state, 1)
        assertTrue(blob.delete())
        assertTrue(File(blob, "nested").mkdirs())
        File(blob, "nested/obstruction").writeText("not a diff")
        Files.createSymbolicLink(File(blob, "outside").toPath(), outside.toPath())
        reads = 0; stats = 0; writes.clear()
        writer.save(state, 2)
        assertTrue(Files.isRegularFile(blob.toPath(), LinkOption.NOFOLLOW_LINKS))
        assertEquals(diff, blob.readText())
        assertEquals("untouched", sentinel.readText())
        assertEquals(listOf("$digest.diff", "state.json"), writes)
        assertEquals(0, reads)
        assertEquals(1, stats)
        assertEquals(state, stateFile(file).load())
    }

    @Test fun aSameLengthSymlinkAtAVerifiedBlobIsReplacedWithoutReadingOrChangingItsTarget() {
        val file = File(temporary.newFolder(), "state.json")
        val blob = File(file.parentFile, "changes/$digest.diff")
        val targetBytes = "?".repeat(diff.encodeToByteArray().size)
        val target = temporary.newFile().apply { writeText(targetBytes) }
        var reads = 0
        val writes = mutableListOf<String>()
        // Exercise the production stat default, rather than injecting a no-follow stat.
        val writer = ArtifactsStateFile(file, split = { SharedArtifactsPersistenceFiles("{}", mapOf(digest to diff)) },
            blobDigests = { listOf(digest) }, join = { _, blobs -> if (blobs[digest] == diff) state else SharedArtifactsState() },
            readBlobBytes = { reads++; readArtifactBlobBytes(it) }, replace = { from, to ->
                if (to == file) {
                    assertFalse(Files.isSymbolicLink(blob.toPath()))
                    assertEquals(diff, blob.readText())
                }
                writes += to.name
                replaceArtifactFile(from, to)
            })
        writer.save(state, 1)
        assertTrue(blob.delete())
        Files.createSymbolicLink(blob.toPath(), target.toPath())
        writes.clear()
        writer.save(state, 2)
        assertTrue(Files.isRegularFile(blob.toPath(), LinkOption.NOFOLLOW_LINKS))
        assertFalse(Files.isSymbolicLink(blob.toPath()))
        assertEquals(diff, blob.readText())
        assertEquals(targetBytes, target.readText())
        assertEquals(listOf("$digest.diff", "state.json"), writes)
        assertEquals(0, reads)
        assertEquals(state, stateFile(file).load())
    }

    @Test fun aSuccessfulSaveForgetsUnreferencedDigestsEvenIfTheirFilesAlreadyVanished() {
        val file = File(temporary.newFolder(), "state.json")
        val blob = File(file.parentFile, "changes/$digest.diff")
        var reads = 0
        val writer = stateFile(file, read = { reads++; readArtifactBlobBytes(it) })
        writer.save(state, 1)
        assertTrue(blob.delete())
        writer.save(SharedArtifactsState(), 2)
        blob.writeText("?".repeat(diff.encodeToByteArray().size))
        writer.save(state, 3)
        assertEquals(1, reads)
        assertEquals(diff, blob.readText())
    }

    @Test fun rejectedBlobsAreRemovedAndReopeningTheEditSurvivesTheNextLaunch() {
        for (bytes in listOf("+saved".encodeToByteArray(), "+other edit\n".encodeToByteArray(),
                byteArrayOf(0xff.toByte()), ByteArray(256 * 1024 + 1))) {
            val file = File(temporary.newFolder(), "state.json")
            stateFile(file).save(state, 1)
            val blob = File(file.parentFile, "changes/$digest.diff").apply { writeBytes(bytes) }
            val reopened = stateFile(file)
            assertTrue(reopened.load().tabs.isEmpty())
            assertFalse("load must remove a rejected blob", blob.exists())
            reopened.save(state, 1)
            assertEquals(diff, blob.readText())
            assertEquals(state, stateFile(file).load())
        }
    }

    @Test fun anUnverifiedCorruptFileIsAtomicallyRepairedBeforeTheManifestIsReplaced() {
        val file = File(temporary.newFolder(), "state.json")
        val blob = File(file.parentFile, "changes/$digest.diff").apply { parentFile!!.mkdirs(); writeText("truncated") }
        val writes = mutableListOf<String>()
        stateFile(file, replace = { from, to ->
            if (to == file) assertEquals(diff, blob.readText())
            if (to == blob) assertEquals("truncated", blob.readText())
            writes += to.name
            replaceArtifactFile(from, to)
        }).save(state, 1)
        assertEquals(listOf("$digest.diff", "state.json"), writes)
        assertEquals(state, stateFile(file).load())
    }

    @Test fun writtenAndLoadVerifiedBlobsAreNeverReadAgainBySaves() {
        val file = File(temporary.newFolder(), "state.json")
        var reads = 0
        val writer = stateFile(file, read = { reads++; readArtifactBlobBytes(it) })
        writer.save(state, 1)
        writer.save(state, 2)
        writer.save(state.copy(tabs = listOf(tab.copy(viewedAt = 20))), 3)
        assertEquals(0, reads)
        val restarted = stateFile(file, read = { reads++; readArtifactBlobBytes(it) })
        assertEquals(state, restarted.load())
        assertEquals(1, reads)
        restarted.save(state, 1)
        restarted.save(state, 2)
        assertEquals(1, reads)
    }

    @Test fun aValidUnverifiedBlobFromAnEarlierProcessIsReadOnceAndNeverRewritten() {
        val file = File(temporary.newFolder(), "state.json")
        stateFile(file).save(state, 1)
        var reads = 0
        var blobWrites = 0
        val writer = stateFile(file, read = { reads++; readArtifactBlobBytes(it) }, replace = { from, to ->
            if (to.extension == "diff") blobWrites++
            replaceArtifactFile(from, to)
        })
        writer.save(state, 1)
        writer.save(state, 2)
        assertEquals(1, reads)
        assertEquals(0, blobWrites)
        assertEquals(state, stateFile(file).load())
    }

    @Test fun collectionForgetsVerificationBeforeTheSameDigestIsSavedAgain() {
        val file = File(temporary.newFolder(), "state.json")
        val writer = stateFile(file)
        writer.save(state, 1)
        writer.save(SharedArtifactsState(), 2)
        File(file.parentFile, "changes/$digest.diff").writeText("bad orphan")
        writer.save(state, 3)
        writer.save(SharedArtifactsState(), 2)
        assertEquals(state, stateFile(file).load())
    }

    @Test(timeout = 10_000) fun existingBlobValidationUsesTheSerializedWritersDispatcher() {
        val file = File(temporary.newFolder(), "state.json")
        stateFile(file).save(state, 1)
        val reads = AtomicInteger()
        val saved = CountDownLatch(2)
        // Compare threads, not names: coroutine debug mode suffixes the running thread's name. Record them rather than
        // asserting in the writer, whose errors would escape the test.
        var writerThread: Thread? = null
        val dispatcher = Executors.newSingleThreadExecutor { Thread(it, "artifact-blob-writer").also { t -> writerThread = t } }
            .asCoroutineDispatcher()
        val ioThreads = ConcurrentLinkedQueue<Thread>()
        val scope = CoroutineScope(SupervisorJob())
        val writer = ArtifactsStateWriter(stateFile(file, read = {
            ioThreads.add(Thread.currentThread())
            reads.incrementAndGet()
            readArtifactBlobBytes(it)
        }, replace = { from, to ->
            ioThreads.add(Thread.currentThread())
            replaceArtifactFile(from, to)
            if (to == file) saved.countDown()
        }), scope, dispatcher)
        try {
            writer.enqueue(state, 1)
            writer.enqueue(state, 2)
            assertTrue(saved.await(5, TimeUnit.SECONDS))
            assertEquals(1, reads.get())
            assertTrue(ioThreads.isNotEmpty() && ioThreads.all { it === writerThread })
        } finally { scope.cancel(); dispatcher.close() }
    }
}
