package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactsFilter
import com.bambouville.tessera.core.bridge.SharedArtifactsState
import com.bambouville.tessera.core.bridge.SharedArtifacts
import com.bambouville.tessera.core.bridge.SharedArtifactsPersistenceFiles
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.CoreBridge
import com.bambouville.tessera.core.bridge.CoreBridgeState
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ArtifactsStateFileTest {
    @get:Rule val temporary = TemporaryFolder()
    private fun decode(json: String): SharedArtifactsState = JSONObject(json).let { value ->
        SharedArtifactsState(filter = SharedArtifactsFilter.entries.first { it.wireValue == value.getString("filter") })
    }

    private fun encode(state: SharedArtifactsState): String = JSONObject().put("filter", state.filter.wireValue).toString()

    @Test fun metadataOnlySnapshotsWriteNoBlobBytesAndANewBodyIsWrittenExactlyOnce() {
        val file = File(temporary.root, "artifacts/state.json")
        val diff = "x".repeat(256 * 1024)
        val digest = digest(diff)
        val writes = mutableListOf<Pair<String, Long>>()
        // A fixture codec isolates disk ordering/counts from policy, which has
        // separate native replay coverage in SharedArtifactsNativeTest.
        val stateFile = ArtifactsStateFile(file, split = { state ->
            SharedArtifactsPersistenceFiles(encode(state), mapOf(digest to diff))
        }, blobDigests = { listOf(digest) }, join = { json, blobs ->
            assertEquals(mapOf(digest to diff), blobs)
            decode(json)
        }, replace = { from, to ->
            writes += to.name to from.length()
            replaceArtifactFile(from, to)
        })
        stateFile.save(SharedArtifactsState(), 1)
        stateFile.save(SharedArtifactsState(filter = SharedArtifactsFilter.Docs), 2)
        stateFile.save(SharedArtifactsState(filter = SharedArtifactsFilter.Pages), 3)
        assertEquals(1, writes.count { it.first.endsWith(".diff") })
        assertEquals(256L * 1024, writes.filter { it.first.endsWith(".diff") }.sumOf { it.second })
        assertEquals(3, writes.count { it.first == "state.json" })
        assertEquals(SharedArtifactsFilter.Pages, stateFile.load().filter)
        assertTrue(file.length() < 1024)
        assertEquals("$digest.diff", writes.first().first)
    }

    @Test fun collectionRunsOnlyAfterASuccessfulManifestAndFailedSnapshotsCanRetry() {
        val file = File(temporary.root, "artifacts/state.json")
        val firstDigest = digest("first")
        val nextDigest = digest("next")
        var failManifest = false
        val firstBlob = File(file.parentFile, "changes/$firstDigest.diff")
        val nextBlob = File(file.parentFile, "changes/$nextDigest.diff")
        val stateFile = ArtifactsStateFile(file, split = { state ->
            SharedArtifactsPersistenceFiles(encode(state), when (state.filter) {
                SharedArtifactsFilter.Docs -> mapOf(firstDigest to "first")
                SharedArtifactsFilter.Pages -> mapOf(nextDigest to "next")
                else -> emptyMap()
            })
        }, blobDigests = { emptyList() }, join = { json, _ -> decode(json) }, replace = { from, to ->
            if (to == file) {
                if (failManifest) throw IOException("manifest interrupted")
                assertTrue(firstBlob.isFile || nextBlob.isFile)
            }
            replaceArtifactFile(from, to)
        })
        stateFile.save(SharedArtifactsState(filter = SharedArtifactsFilter.Docs), 1)
        failManifest = true
        try { stateFile.save(SharedArtifactsState(filter = SharedArtifactsFilter.Pages), 2); error("replace unexpectedly succeeded") }
        catch (_: IOException) { }
        assertEquals(SharedArtifactsFilter.Docs, stateFile.load().filter)
        assertTrue(firstBlob.isFile)
        assertTrue(nextBlob.isFile)
        failManifest = false
        stateFile.save(SharedArtifactsState(filter = SharedArtifactsFilter.Pages), 2)
        assertFalse(firstBlob.exists())
        assertTrue(nextBlob.isFile)
        stateFile.save(SharedArtifactsState(), 3)
        assertTrue(File(file.parentFile, "changes").listFiles()!!.isEmpty())
    }

    @Test fun blobReadsAreBoundedStrictUTF8AndIndependentOfOtherMissingBlobs() {
        val file = File(temporary.root, "artifacts/state.json")
        file.parentFile!!.mkdirs()
        file.writeText("{}")
        val digests = listOf(digest("+valid\n")) + (1..4).map { it.toString().repeat(64) }
        val changes = File(file.parentFile, "changes").also { it.mkdirs() }
        File(changes, "${digests[0]}.diff").writeText("+valid\n")
        File(changes, "${digests[1]}.diff").writeBytes(ByteArray(256 * 1024 + 1))
        File(changes, "${digests[2]}.diff").writeBytes(byteArrayOf(0xff.toByte()))
        File(changes, "${digests[4]}.diff").mkdir()
        var calls = 0
        val stateFile = ArtifactsStateFile(file, split = { SharedArtifactsPersistenceFiles("{}", emptyMap()) },
            blobDigests = { digests + "../../state.json" }, join = { _, blobs ->
                calls++
                assertEquals(mapOf(digests[0] to "+valid\n"), blobs)
                SharedArtifactsState(filter = SharedArtifactsFilter.Changes)
            })
        assertEquals(SharedArtifactsFilter.Changes, stateFile.load().filter)
        assertEquals(1, calls)
    }

    @Test fun productionCodecMigratesLegacyInlineDiffsAndDropsOnlyInvalidBlobTabs() {
        val core = CoreBridge.inspect()
        assumeTrue("host-built shared core unavailable: $core", core is CoreBridgeState.Ready)
        val file = File(temporary.root, "artifacts/state.json")
        file.parentFile!!.mkdirs()
        fun change(id: String, diff: String) = SharedArtifactTab(id, "h1", "dev", SharedArtifactsTarget.Change("/$id.kt", diff, "edit"),
            SharedArtifactsKind.Changes, id, "agentEdit", null, 1, 1, false, null, false, null)
        val a = change("a", "+a\n")
        val b = change("b", "+b\n")
        val state = SharedArtifactsState(tabs = listOf(a, b), selectedId = "b")
        file.writeText(SharedArtifacts.encodeState(state))
        val stateFile = ArtifactsStateFile(file)
        assertEquals(state, stateFile.load())
        stateFile.save(stateFile.load(), 1)
        assertFalse(file.readText().contains("\"diff\":"))
        val blob = File(file.parentFile, "changes/${digest("+a\n")}.diff")
        for (replacement in listOf(null, "+tampered".encodeToByteArray(), ByteArray(256 * 1024 + 1), byteArrayOf(0xff.toByte()))) {
            if (replacement == null) assertTrue(blob.delete()) else blob.writeBytes(replacement)
            assertEquals(SharedArtifactsState(tabs = listOf(b), selectedId = "b"), stateFile.load())
            blob.writeText("+a\n")
        }
        stateFile.save(SharedArtifactsState(tabs = listOf(b), selectedId = "b"), 2)
        assertFalse(blob.exists())
        assertEquals(1, File(file.parentFile, "changes").listFiles()!!.size)
    }

    private fun digest(text: String): String = MessageDigest.getInstance("SHA-256").digest(text.encodeToByteArray())
        .joinToString("") { "%02x".format(it) }

    @Test fun atomicReplacementAndGenerationOrderingPreserveTheNewestFlush() {
        val file = File(temporary.root, "artifacts/state.json")
        val stateFile = ArtifactsStateFile(file, ::decode, ::encode)
        stateFile.save(SharedArtifactsState(filter = SharedArtifactsFilter.Docs), 1)
        stateFile.save(SharedArtifactsState(filter = SharedArtifactsFilter.Pages), 3)
        stateFile.save(SharedArtifactsState(filter = SharedArtifactsFilter.Files), 2)
        assertEquals(SharedArtifactsFilter.Pages, stateFile.load().filter)
        assertEquals(listOf("state.json"), file.parentFile!!.listFiles()!!.map { it.name })
    }

    @Test fun failedReplaceKeepsThePreviousFileAndCleansItsOwnTemporary() {
        val file = File(temporary.root, "artifacts/state.json")
        ArtifactsStateFile(file, ::decode, ::encode).save(SharedArtifactsState(), 0)
        val previous = file.readText()
        val failing = ArtifactsStateFile(file, ::decode, ::encode) { from, to ->
            assertTrue(from.isFile)
            assertEquals(file, to)
            assertEquals(previous, to.readText())
            throw IOException("interrupted before rename")
        }
        try { failing.save(SharedArtifactsState(filter = SharedArtifactsFilter.Docs), 1); error("replace unexpectedly succeeded") }
        catch (_: IOException) { }
        assertEquals(previous, file.readText())
        assertEquals(listOf("state.json"), file.parentFile!!.listFiles()!!.map { it.name })
    }

    @Test fun missingAndCorruptStateRecoverAndTheNextWriteReplacesTheCorruption() {
        val file = File(temporary.root, "artifacts/state.json")
        val stateFile = ArtifactsStateFile(file, ::decode, ::encode)
        assertEquals(SharedArtifactsState(), stateFile.load())
        assertFalse(file.exists())
        file.parentFile!!.mkdirs()
        file.writeText("{interrupted")
        assertEquals(SharedArtifactsState(), stateFile.load())
        stateFile.save(SharedArtifactsState(filter = SharedArtifactsFilter.Changes), 1)
        assertEquals(SharedArtifactsFilter.Changes, stateFile.load().filter)
    }
}
