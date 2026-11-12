package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.security.MessageDigest
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ArtifactsPersistenceRecoveryTest {
    @get:Rule val temporary = TemporaryFolder()
    private val diff = "+saved é\n"
    private val digest = MessageDigest.getInstance("SHA-256").digest(diff.encodeToByteArray()).joinToString("") { "%02x".format(it) }
    private val edit = SharedArtifactTab("edit", "h", "h", SharedArtifactsTarget.Change("/a.kt", diff, "edit"),
        SharedArtifactsKind.Changes, "a.kt", "agentEdit", null, 1, 1, false, null, false, null)
    private val saved = SharedArtifactsState(tabs = listOf(edit), selectedId = edit.id, filter = SharedArtifactsFilter.Docs)

    private class Rules : PortForwardRuleStore {
        override fun observe(hostId: String) = MutableStateFlow(emptyList<PortForwardRule>())
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) = error("must not save a rule")
        override suspend fun delete(hostId: String) = Unit
    }

    private fun stateFile(
        file: File,
        readBlob: (File) -> ByteArray? = ::readArtifactBlobBytes,
        readState: (File) -> ByteArray = File::readBytes,
        replace: (File, File) -> Unit = ::replaceArtifactFile,
    ) = ArtifactsStateFile(file, split = { state ->
        SharedArtifactsPersistenceFiles("${state.filter.wireValue}:${state.tabs.isNotEmpty()}",
            if (state.tabs.isEmpty()) emptyMap() else mapOf(digest to diff))
    }, blobDigests = { json -> if (json.endsWith(":true")) listOf(digest) else emptyList() }, join = { json, blobs ->
        val filter = SharedArtifactsFilter.entries.first { it.wireValue == json.substringBefore(':') }
        if (blobs[digest] == diff) saved.copy(filter = filter) else SharedArtifactsState(filter = filter)
    }, readBlobBytes = readBlob, readStateBytes = readState, replace = replace)

    @Test fun unavailableBlobOrManifestKeepsEveryFileAndFencesTheWriter() = runTest {
        for (manifest in listOf(false, true)) for (security in listOf(false, true)) {
            val file = File(temporary.newFolder(), "state.json")
            stateFile(file).save(saved, 1)
            val blob = File(file.parentFile, "changes/$digest.diff")
            val oldManifest = file.readText()
            fun unavailable(): Nothing = if (security) throw SecurityException("denied") else throw IOException("temporarily unavailable")
            var writes = 0
            val blocked = stateFile(file, readBlob = { if (!manifest) unavailable() else readArtifactBlobBytes(it) },
                readState = { if (manifest) unavailable() else it.readBytes() }, replace = { _, _ -> writes++; error("fenced writer replaced a file") })
            assertThrows(if (security) SecurityException::class.java else IOException::class.java) { blocked.load() }
            var failures = 0
            val writer = ArtifactsStateWriter(blocked, backgroundScope, StandardTestDispatcher(testScheduler)) { failures++ }
            writer.enqueue(SharedArtifactsState(), 2)
            runCurrent()
            assertEquals(1, failures)
            assertEquals(0, writes)
            assertEquals(oldManifest, file.readText())
            assertEquals(diff, blob.readText())
            assertEquals(1, File(file.parentFile, "changes").listFiles()!!.size)
        }
    }

    @Test fun unavailableLaterBlobPreventsDeletionOfEarlierInvalidContent() {
        val file = File(temporary.newFolder(), "state.json").apply { writeText("saved") }
        val invalidDigest = "0".repeat(64)
        val changes = File(file.parentFile, "changes").apply { mkdirs() }
        val invalid = File(changes, "$invalidDigest.diff").apply { writeText("invalid") }
        val valid = File(changes, "$digest.diff").apply { writeText(diff) }
        val reader = ArtifactsStateFile(file, split = { error("must not encode while fenced") },
            blobDigests = { listOf(invalidDigest, digest) }, join = { _, _ -> error("unavailable load joined") },
            readBlobBytes = { if (it == valid) throw IOException("unavailable") else readArtifactBlobBytes(it) })
        assertThrows(IOException::class.java) { reader.load() }
        assertTrue(invalid.isFile)
        assertTrue(valid.isFile)
        assertThrows(IOException::class.java) { reader.save(SharedArtifactsState(), 1) }
        assertEquals("saved", file.readText())
    }

    @Test fun foregroundRetriesRestoreThroughInitializationAndSupersedeFencedGenerations() = runTest {
        for (manifest in listOf(false, true)) {
            val file = File(temporary.newFolder(), "state.json")
            stateFile(file).save(saved, 1)
            val oldManifest = file.readText()
            var unavailable = true
            var loadReads = 0
            var writes = 0
            val reader = stateFile(file, readBlob = {
                if (!manifest) { loadReads++; if (unavailable) throw IOException("unavailable blob") }
                readArtifactBlobBytes(it)
            }, readState = {
                if (manifest) { loadReads++; if (unavailable) throw IOException("unavailable state") }
                it.readBytes()
            }, replace = { from, to -> writes++; replaceArtifactFile(from, to) })
            val dispatcher = StandardTestDispatcher(testScheduler)
            var liveLookups = 0
            val hosts = ArtifactsLiveHosts(findFiles = { liveLookups++; null }, findContext = { null }, findForwarding = { emptyList() })
            val loader = ArtifactContentLoader(temporary.newFolder(), hosts::files, key = { "a".repeat(64) },
                evictions = { _, _, _ -> emptyList() }, ioDispatcher = dispatcher)
            val diagnostics = mutableListOf<String>()
            val store = ArtifactsStore(reader, hosts, loader, ArtifactPageForwarder(hosts, Rules()), backgroundScope,
                persistenceDispatcher = dispatcher, recordDiagnostic = { code, _ -> diagnostics += code },
                reduceAction = { state, action ->
                    val next = state.copy(filter = (action as SharedArtifactsAction.SetFilter).filter)
                    SharedArtifactsReduction(next, next.selectedId, emptyList(), null)
                })
            store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "h")))
            runCurrent()
            assertTrue(store.state.value.tabs.isEmpty())
            assertEquals(1, loadReads)
            store.setFilter(SharedArtifactsFilter.Pages)
            runCurrent()
            store.flush()
            runCurrent()
            assertEquals(listOf("artifacts_state_write_failed"), diagnostics)
            advanceTimeBy(6_000); runCurrent()
            assertEquals(1, loadReads) // No timer retries a failed read.
            assertEquals(0, writes)
            assertEquals(oldManifest, file.readText())
            unavailable = false
            store.setForeground(true)
            runCurrent()
            assertEquals(saved, store.state.value)
            assertEquals(ArtifactContent.Change("/a.kt", diff), store.content(edit.id))
            assertEquals(2, loadReads)
            assertEquals(1, writes)
            assertEquals(saved, stateFile(file).load())
            store.setForeground(true)
            runCurrent()
            assertEquals(2, loadReads)
            store.setFilter(SharedArtifactsFilter.Files)
            runCurrent()
            store.flush()
            runCurrent()
            assertEquals(saved.copy(filter = SharedArtifactsFilter.Files), stateFile(file).load())
            assertEquals(2, writes)
            assertTrue(liveLookups > 0) // Lookup has no connection factory to call.
        }
    }

    @Test fun cacheEvictionWaitsForTheFencedRestoreToSucceed() = runTest {
        val file = File(temporary.newFolder(), "state.json")
        stateFile(file).save(saved, 1)
        var unavailable = true
        val reader = stateFile(file, readState = {
            if (unavailable) throw IOException("unavailable state")
            it.readBytes()
        })
        val dispatcher = StandardTestDispatcher(testScheduler)
        val hosts = ArtifactsLiveHosts(findFiles = { null }, findContext = { null }, findForwarding = { emptyList() })
        var evictionPasses = 0
        val loader = ArtifactContentLoader(temporary.newFolder(), hosts::files, key = { "a".repeat(64) },
            evictions = { _, _, _ -> evictionPasses++; emptyList() }, ioDispatcher = dispatcher)
        val store = ArtifactsStore(reader, hosts, loader, ArtifactPageForwarder(hosts, Rules()), backgroundScope,
            persistenceDispatcher = dispatcher,
            reduceAction = { state, _ ->
                // A selection change is one of the reductions that asks for eviction.
                val next = state.copy(selectedId = if (state.selectedId == "other") null else "other")
                SharedArtifactsReduction(next, next.selectedId, emptyList(), null)
            })
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "h")))
        runCurrent()
        assertTrue(store.state.value.tabs.isEmpty())
        store.setFilter(SharedArtifactsFilter.Pages)
        runCurrent()
        assertEquals(0, evictionPasses)

        unavailable = false
        store.setForeground(true)
        runCurrent()
        assertEquals(saved, store.state.value)
        store.setFilter(SharedArtifactsFilter.Pages)
        runCurrent()
        assertTrue(evictionPasses > 0)
    }

    @Test fun failedWriterKeepsTheNewestGenerationUntilAnotherEnqueueCanRetry() = runTest {
        val file = File(temporary.newFolder(), "state.json")
        var unavailable = true
        val reader = stateFile(file, replace = { from, to ->
            if (unavailable) throw IOException("unavailable")
            replaceArtifactFile(from, to)
        })
        var failures = 0
        val writer = ArtifactsStateWriter(reader, backgroundScope, StandardTestDispatcher(testScheduler)) { failures++ }
        writer.enqueue(saved.copy(filter = SharedArtifactsFilter.Files), 3)
        runCurrent()
        assertEquals(1, failures)
        unavailable = false
        writer.enqueue(saved.copy(filter = SharedArtifactsFilter.Pages), 2)
        runCurrent()
        assertEquals(saved.copy(filter = SharedArtifactsFilter.Files), stateFile(file).load())
    }

    @Test fun retryKeepsTheFenceUntilPublicationAndOlderQueuedSnapshotsStayObsolete() {
        val file = File(temporary.newFolder(), "state.json")
        stateFile(file).save(saved, 1)
        var unavailable = true
        var writes = 0
        val reader = stateFile(file, readState = {
            if (unavailable) throw IOException("unavailable")
            it.readBytes()
        }, replace = { from, to -> writes++; replaceArtifactFile(from, to) })
        assertThrows(IOException::class.java) { reader.load() }
        unavailable = false
        assertEquals(saved, reader.load())
        assertThrows(IOException::class.java) { reader.save(SharedArtifactsState(), 1) }
        reader.resumeWrites(2)
        reader.save(SharedArtifactsState(), 1)
        assertEquals(0, writes)
        reader.save(saved, 2)
        reader.save(saved.copy(filter = SharedArtifactsFilter.Files), 4)
        reader.save(SharedArtifactsState(), 3)
        assertEquals(2, writes)
        assertEquals(saved.copy(filter = SharedArtifactsFilter.Files), stateFile(file).load())
    }

    @Test fun invalidUtf8AndOversizeRemainInvalidRatherThanUnavailableAndAbsenceStaysEmpty() {
        val file = File(temporary.newFolder(), "state.json")
        val reader = stateFile(file)
        assertEquals(SharedArtifactsState(), reader.load())
        assertFalse(file.exists())
        for ((index, bytes) in listOf(byteArrayOf(0xff.toByte()), ByteArray(256 * 1024 + 1), "tampered".encodeToByteArray()).withIndex()) {
            stateFile(file).save(saved, 1)
            val blob = File(file.parentFile, "changes/$digest.diff").apply { writeBytes(bytes) }
            assertTrue(reader.load().tabs.isEmpty())
            assertFalse(blob.exists())
            reader.save(saved, index + 1L)
            assertEquals(diff, blob.readText())
        }
        file.writeBytes(byteArrayOf(0xff.toByte()))
        assertEquals(SharedArtifactsState(), stateFile(file).load())
        assertTrue(File(file.parentFile, "changes/$digest.diff").isFile)
    }

    @Test fun aManifestOrBlobThatDisappearsDuringReadIsAbsentWithoutFencingWrites() {
        for (manifest in listOf(false, true)) {
            val file = File(temporary.newFolder(), "state.json")
            stateFile(file).save(saved, 1)
            val reader = stateFile(file, readState = {
                if (manifest) { assertTrue(it.delete()); throw FileNotFoundException(it.path) }
                it.readBytes()
            }, readBlob = {
                if (!manifest) { assertTrue(it.delete()); throw FileNotFoundException(it.path) }
                readArtifactBlobBytes(it)
            })
            assertTrue(reader.load().tabs.isEmpty())
            reader.save(saved, 1)
            assertEquals(saved, stateFile(file).load())
        }
    }
}
