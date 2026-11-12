package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifacts
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.core.bridge.SharedArtifactsPersistenceFiles
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.io.IOException
import java.nio.charset.CharacterCodingException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.FileVisitResult
import java.nio.file.FileVisitor
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/** One consumer on the store's process lifetime scope; enqueue never encodes or waits for disk. */
internal class ArtifactsStateWriter(
    file: ArtifactsStateFile,
    scope: CoroutineScope,
    dispatcher: CoroutineDispatcher = Dispatchers.IO,
    onFailure: () -> Unit = {},
) {
    private data class Snapshot(val state: SharedArtifactsState, val generation: Long)
    private val pending = Channel<Snapshot>(Channel.UNLIMITED)

    init {
        scope.launch(dispatcher) {
            var unsaved: Snapshot? = null
            for (snapshot in pending) {
                val latest = unsaved?.takeIf { it.generation > snapshot.generation } ?: snapshot
                unsaved = latest
                try {
                    file.save(latest.state, latest.generation)
                    unsaved = null
                }
                catch (_: Exception) { onFailure() }
            }
        }
    }

    fun enqueue(state: SharedArtifactsState, generation: Long) {
        check(pending.trySend(Snapshot(state, generation)).isSuccess)
    }
}

/** Serialized generations prevent an older debounce from overwriting an onStop flush. */
internal class ArtifactsStateFile(
    private val file: File,
    private val split: (SharedArtifactsState) -> SharedArtifactsPersistenceFiles,
    private val blobDigests: (String) -> List<String>,
    private val join: (String, Map<String, String>) -> SharedArtifactsState,
    private val replace: (File, File) -> Unit = ::replaceArtifactFile,
    private val readBlobBytes: (File) -> ByteArray? = ::readArtifactBlobBytes,
    private val readStateBytes: (File) -> ByteArray = File::readBytes,
    private val statBlob: (File) -> BasicFileAttributes? = ::artifactBlobAttributes,
    private val walkBlobObstruction: (Path, FileVisitor<Path>) -> Unit = { root, visitor -> Files.walkFileTree(root, visitor) },
) {
    // Retain the existing codec injection seam for store/IO tests and callers.
    constructor(
        file: File,
        decode: ((String) -> SharedArtifactsState)? = null,
        encode: ((SharedArtifactsState) -> String)? = null,
        replace: (File, File) -> Unit = ::replaceArtifactFile,
    ) : this(file,
        split = { state -> if (encode != null) SharedArtifactsPersistenceFiles(encode(state), emptyMap()) else SharedArtifacts.splitState(state) },
        blobDigests = { json -> if (decode != null) emptyList() else SharedArtifacts.stateBlobDigests(json) },
        join = { json, blobs -> decode?.invoke(json) ?: SharedArtifacts.joinState(json, blobs) },
        replace = replace,
    )

    private var savedGeneration = -1L
    private var minimumGeneration = -1L
    private var writeFenced = false
    private val verifiedDigests = mutableSetOf<String>()
    private val changesDirectory get() = File(file.parentFile, "changes")
    private val digestName = Regex("[0-9a-f]{64}")

    @Synchronized fun load(): SharedArtifactsState {
        val previouslyFenced = writeFenced
        return try {
            val attributes = artifactFileAttributes(file)
            if (attributes == null || !attributes.isRegularFile || attributes.size() > SharedArtifacts.MAX_PAYLOAD_BYTES) SharedArtifactsState()
            else {
                val json = readStateBytes(file).decodeToString(throwOnInvalidSequence = true)
                val invalid = mutableListOf<File>()
                val blobs = blobDigests(json).distinct().mapNotNull { digest ->
                    if (!digestName.matches(digest)) null
                    else when (val blob = validatedBlob(digest)) {
                        Blob.Absent -> null
                        Blob.Invalid -> { invalid += File(changesDirectory, "$digest.diff"); null }
                        is Blob.Valid -> digest to blob.diff
                    }
                }.toMap()
                val restored = join(json, blobs)
                // Read the whole snapshot before deleting anything: a later blob
                // may be temporarily unreadable rather than corrupt.
                invalid.forEach { runCatching { it.delete() } }
                verifiedDigests.clear()
                verifiedDigests.addAll(blobs.keys)
                restored
            }
        } catch (_: CharacterCodingException) { SharedArtifactsState()
        } catch (failure: IOException) {
            writeFenced = true
            if (failure is NoSuchFileException || failure is FileNotFoundException && artifactFileAttributes(file) == null) {
                writeFenced = previouslyFenced
                SharedArtifactsState()
            } else throw failure
        } catch (failure: SecurityException) { writeFenced = true; throw failure
        } catch (_: Exception) { SharedArtifactsState()
        } catch (_: LinkageError) { SharedArtifactsState() }
    }

    /** Publish the restored state first; queued pre-restore snapshots stay obsolete. */
    @Synchronized fun resumeWrites(generation: Long) {
        minimumGeneration = maxOf(minimumGeneration, generation)
        writeFenced = false
    }

    @Synchronized fun save(state: SharedArtifactsState, generation: Long) {
        if (writeFenced) throw IOException("artifacts state is temporarily unavailable")
        if (generation < minimumGeneration || generation <= savedGeneration) return
        val files = split(state)
        check(file.parentFile?.let { it.isDirectory || it.mkdirs() } == true)
        if (files.blobs.isNotEmpty()) check(changesDirectory.isDirectory || changesDirectory.mkdirs())
        files.blobs.toSortedMap().forEach { (digest, diff) ->
            check(digestName.matches(digest))
            val blob = File(changesDirectory, "$digest.diff")
            val bytes = diff.encodeToByteArray()
            val reusable = if (digest in verifiedDigests) {
                val attributes = statBlob(blob)
                if (attributes != null && !attributes.isRegularFile) removeArtifactBlobObstruction(blob, walkBlobObstruction)
                attributes?.let { it.isRegularFile && it.size() == bytes.size.toLong() } == true
            } else validatedBlob(digest) is Blob.Valid
            if (!reusable) writeAtomic(blob, bytes)
            verifiedDigests.add(digest)
        }
        writeAtomic(file, files.stateJSON.encodeToByteArray())
        // A failed manifest replacement must keep every previously referenced blob.
        changesDirectory.listFiles()?.forEach { blob ->
            if (blob.extension == "diff" && digestName.matches(blob.nameWithoutExtension) &&
                blob.nameWithoutExtension !in files.blobs) {
                check(blob.delete())
                verifiedDigests.remove(blob.nameWithoutExtension)
            }
        }
        verifiedDigests.retainAll(files.blobs.keys)
        savedGeneration = generation
    }

    private fun writeAtomic(destination: File, bytes: ByteArray) {
        val pending = File.createTempFile("artifact-", ".tmp", destination.parentFile)
        try {
            FileOutputStream(pending).use { output ->
                output.write(bytes)
                output.fd.sync()
            }
            replace(pending, destination)
        } finally { pending.delete() }
    }

    private sealed interface Blob {
        data object Absent : Blob
        data object Invalid : Blob
        data class Valid(val diff: String) : Blob
    }

    private fun validatedBlob(digest: String): Blob {
        val blob = File(changesDirectory, "$digest.diff")
        return try {
            val attributes = statBlob(blob)
            if (attributes == null) Blob.Absent
            else if (!attributes.isRegularFile || attributes.size() > 256 * 1024) Blob.Invalid
            else readBlobBytes(blob)?.let { bytes ->
                val diff = bytes.decodeToString(throwOnInvalidSequence = true)
                val actual = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
                if (actual == digest) Blob.Valid(diff) else Blob.Invalid
            } ?: Blob.Invalid
        } catch (_: CharacterCodingException) { Blob.Invalid
        } catch (_: NoSuchFileException) { Blob.Absent
        } catch (failure: FileNotFoundException) {
            if (artifactFileAttributes(blob) == null) Blob.Absent else throw failure
        }
    }
}

internal fun artifactFileAttributes(file: File): BasicFileAttributes? = try {
    Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
} catch (_: NoSuchFileException) { null }

internal fun artifactBlobAttributes(file: File): BasicFileAttributes? = try {
    Files.readAttributes(file.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
} catch (_: NoSuchFileException) { null }

private fun removeArtifactBlobObstruction(blob: File, walk: (Path, FileVisitor<Path>) -> Unit) {
    // The default walk does not follow links, including links inside an obstructing directory.
    try {
        walk(blob.toPath(), object : SimpleFileVisitor<Path>() {
            override fun visitFile(file: Path, attributes: BasicFileAttributes): FileVisitResult {
                Files.deleteIfExists(file)
                return FileVisitResult.CONTINUE
            }
            override fun visitFileFailed(file: Path, failure: IOException): FileVisitResult {
                if (failure !is NoSuchFileException) throw failure
                return FileVisitResult.CONTINUE
            }
            override fun postVisitDirectory(directory: Path, failure: IOException?): FileVisitResult {
                if (failure != null && failure !is NoSuchFileException) throw failure
                Files.deleteIfExists(directory)
                return FileVisitResult.CONTINUE
            }
        })
    } catch (_: NoSuchFileException) { }
}

internal fun readArtifactBlobBytes(blob: File): ByteArray? {
    val limit = 256 * 1024
    return blob.inputStream().use { it.readNBytes(limit + 1).takeIf { bytes -> bytes.size <= limit } }
}

internal fun replaceArtifactFile(from: File, to: File) {
    try {
        Files.move(from.toPath(), to.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    } catch (_: AtomicMoveNotSupportedException) {
        Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
    }
}
