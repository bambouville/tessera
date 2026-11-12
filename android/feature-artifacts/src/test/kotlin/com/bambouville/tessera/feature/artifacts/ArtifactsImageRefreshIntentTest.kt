package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactLiveFilesRegistry
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.files.RemoteMarkdownImages
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardRuleStore
import com.bambouville.tessera.forwarding.PortForwardingLease
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.OutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class ArtifactsImageRefreshIntentTest {
    @get:Rule val temporary = TemporaryFolder()

    private class Rules : PortForwardRuleStore {
        override fun observe(hostId: String) = MutableStateFlow(emptyList<PortForwardRule>())
        override suspend fun replace(hostId: String, rules: List<PortForwardRule>) = error("must not save a rule")
        override suspend fun delete(hostId: String) = Unit
    }
    private class Files : ArtifactLiveFiles {
        var live = true
        override val hasLiveArtifactChannel get() = live
        var connectionGeneration = 1L
        override val artifactConnectionGeneration get() = connectionGeneration
        override val artifactHome: String? = null
        override val artifactDirectory: String? = null
        var mtime = 10L
        var documentReads = 0
        var documentStats = 0
        var cancelledDocuments = 0
        var documentBytes = 0
        var imageBytes = 0
        var document = "doc"
        var imageReads = 0
        var cancelledImages = 0
        var imageStats = 0
        var image = "old"
        var failImage = false
        var imageFailure: Exception? = null
        var failStat = false
        var statStarted = false
        var statGate: CompletableDeferred<Unit>? = null
        var documentGate: CompletableDeferred<Unit>? = null
        var imageGate: CompletableDeferred<Unit>? = null
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat {
            check(live)
            if (path.endsWith(".md")) {
                documentStats++
                statStarted = true
                val observed = ArtifactRemoteStat(path, 3, mtime, false)
                statGate?.await()
                if (failStat) throw FileNotFoundException(path)
                return observed
            }
            imageStats++
            return ArtifactRemoteStat(path, 3, 10, false)
        }
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? {
            if (!live) return null
            if (path.endsWith(".md")) {
                documentReads++
                val gate = documentGate
                documentGate = null
                try { gate?.await() }
                catch (cancelled: CancellationException) { cancelledDocuments++; throw cancelled }
                val bytes = document.encodeToByteArray()
                output.write(bytes)
                documentBytes += bytes.size
                return ArtifactRemoteStat(path, bytes.size.toLong(), mtime, false)
            }
            imageReads++
            val gate = imageGate
            imageGate = null
            try { gate?.await() }
            catch (cancelled: CancellationException) { cancelledImages++; throw cancelled }
            if (path.endsWith("/shot.png")) {
                imageFailure?.let { throw it }
                if (failImage) throw IOException("held channel lost")
            }
            output.write(image.encodeToByteArray())
            imageBytes += image.encodeToByteArray().size
            return ArtifactRemoteStat(path, 3, 10, false)
        }
        override suspend fun probeOnLiveChannel(command: String): String? = error("must never probe or connect")
        override suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease? = error("must never forward or connect")
    }
    private data class Fixture(val store: ArtifactsStore, val files: Files, val forcedStages: MutableList<Boolean>)
    private fun TestScope.fixture(
        files: Files = Files(),
        images: List<String> = listOf("shot.png"),
        liveFiles: () -> ArtifactLiveFiles? = { files },
        beforeImages: suspend () -> Unit = {},
        awaitInitialDocument: Boolean = true,
    ): Fixture {
        val tab = SharedArtifactTab("doc", "h", "h", SharedArtifactsTarget.File("/work/report.md"), SharedArtifactsKind.Docs,
            "report.md", "files", null, 1, 1, false, SharedArtifactsCacheMetadata(1, 10, 3), false, null)
        val initial = SharedArtifactsState(tabs = listOf(tab), selectedId = tab.id)
        val hosts = ArtifactsLiveHosts(findFiles = { liveFiles() }, findContext = { null }, findForwarding = { emptyList() })
        val dispatcher = StandardTestDispatcher(testScheduler)
        val forcedStages = mutableListOf<Boolean>()
        val loader = ArtifactContentLoader(temporary.newFolder(), hosts::files, key = { "a".repeat(64) },
            viewer = { SharedArtifactsViewer.Markdown }, evictions = { _, _, _ -> emptyList() }, ioDispatcher = dispatcher,
            stageCachedImages = { _, path, previous, create, stat, download, force ->
                try {
                    beforeImages()
                    RemoteMarkdownImages.stageCachedWithResult(images, path, previous, create, stat, download, force) { source, target ->
                        source.copyTo(target)
                        true
                    }
                } finally { forcedStages += force }
            })
        val stateFile = ArtifactsStateFile(temporary.newFile().apply { writeText("initial") }, decode = { initial }, encode = { "saved" })
        val store = ArtifactsStore(stateFile, hosts, loader, ArtifactPageForwarder(hosts, Rules(), ioDispatcher = dispatcher), backgroundScope,
            persistenceDispatcher = dispatcher, clock = { 1_000 }, cachePresentation = { _, live, _ ->
                SharedArtifactsCachePresentation(SharedArtifactsCacheState.Live, 1, live)
            }, reduceAction = { state, action ->
                val next = when (action) {
                    is SharedArtifactsAction.Fetched -> state.copy(tabs = state.tabs.map {
                        if (it.id == action.tabId) it.copy(cache = action.cache.copy(fetchedAt = action.nowMillis), unseenChange = false) else it
                    })
                    is SharedArtifactsAction.RemoteStatObserved -> state.copy(tabs = state.tabs.map {
                        if (it.id == action.tabId) it.copy(cache = it.cache?.copy(isStale = true)) else it
                    })
                    is SharedArtifactsAction.AgentEditObserved -> state.copy(tabs = state.tabs.map {
                        if (it.hostId == action.hostId && it.target.path == action.path) it.copy(cache = it.cache?.copy(isStale = true), unseenChange = true) else it
                    })
                    is SharedArtifactsAction.Select -> state.copy(selectedId = action.tabId)
                    else -> error("unexpected action: $action")
                }
                SharedArtifactsReduction(next, next.selectedId, emptyList(), null)
            })
        store.updateHosts(listOf(SharedArtifactsQuickOpenHost("h", "h")))
        store.setForeground(true)
        store.noteVisible("doc")
        if (awaitInitialDocument) await { store.content("doc") is ArtifactContent.Document }
        return Fixture(store, files, forcedStages)
    }

    @Test fun anOrdinaryImageShortfallRetriesOnlyTheMissingImageOnceOnAnotherChannelAndForegroundReturn() = runTest {
        val files = Files().apply { imageFailure = IllegalStateException("closed channel") }
        var liveFiles = files
        val (store, _, stages) = fixture(files, listOf("one.png", "two.png", "three.png", "four.png", "shot.png"), { liveFiles })
        val initial = store.content("doc") as ArtifactContent.Document
        assertEquals(4, initial.stagedImages.size)
        assertEquals(1, files.documentReads)
        assertEquals(5, files.imageReads)
        assertEquals(12, files.imageBytes)
        repeat(10) {
            store.noteVisible(null)
            store.select("doc")
            store.noteVisible("doc")
            runCurrent()
        }
        assertEquals(listOf(false), stages)
        assertEquals(0, files.imageStats)
        assertEquals(0, files.documentStats)
        assertEquals(5, files.imageReads)
        assertEquals(1, files.documentReads)
        assertEquals(3, files.documentBytes)

        val replacement = Files().apply { failImage = true }
        liveFiles = replacement
        store.setForeground(true)
        await { store.content("doc") !== initial }
        val retried = store.content("doc") as ArtifactContent.Document
        assertEquals(initial.file, retried.file)
        assertEquals(initial.stagedImages, retried.stagedImages)
        assertEquals(listOf(false, false), stages)
        assertEquals(4, replacement.imageStats)
        assertEquals(1, replacement.imageReads)
        assertEquals(0, replacement.imageBytes)
        assertEquals(0, replacement.documentReads)
        assertEquals(0, replacement.documentStats)
        assertEquals(0, replacement.documentBytes)
        repeat(10) {
            store.noteVisible(null)
            store.select("doc")
            store.noteVisible("doc")
            store.setForeground(true)
            runCurrent()
        }
        assertEquals(listOf(false, false), stages)
        assertEquals(4, replacement.imageStats)
        assertEquals(1, replacement.imageReads)
        assertEquals(0, replacement.documentReads)
        assertEquals(0, replacement.documentStats)

        replacement.failImage = false
        replacement.image = "new"
        store.setForeground(false)
        runCurrent()
        store.setForeground(true)
        await { store.content("doc") !== retried }
        val completed = store.content("doc") as ArtifactContent.Document
        assertEquals(initial.file, completed.file)
        initial.stagedImages.forEach { (name, file) -> assertEquals(file, completed.stagedImages[name]) }
        assertEquals("new", completed.stagedImages.getValue("shot.png").readText())
        assertEquals(listOf(false, false, false), stages)
        assertEquals(8, replacement.imageStats)
        assertEquals(2, replacement.imageReads)
        assertEquals(3, replacement.imageBytes)
        assertEquals(0, replacement.documentReads)
        assertEquals(0, replacement.documentStats)
        assertEquals(0, replacement.documentBytes)
        repeat(10) { store.select("doc"); store.noteVisible("doc"); runCurrent() }
        store.setForeground(false)
        runCurrent()
        store.setForeground(true)
        runCurrent()
        assertSame(completed, store.content("doc"))
        assertEquals(3, stages.size)
        assertEquals(8, replacement.imageStats)
        assertEquals(2, replacement.imageReads)
        assertEquals(0, replacement.documentReads)
        assertEquals(0, replacement.documentStats)
    }

    @Test fun anOrdinaryDefinitiveImageFailureNeverRetriesOnANewImageOpportunity() = runTest {
        val files = Files().apply { imageFailure = java.nio.file.AccessDeniedException("/work/shot.png") }
        var liveFiles = files
        val (store, _, stages) = fixture(files = files, liveFiles = { liveFiles })
        val shown = store.content("doc") as ArtifactContent.Document
        assertTrue(shown.stagedImages.isEmpty())
        val replacement = Files()
        liveFiles = replacement
        store.setForeground(true)
        runCurrent()
        store.setForeground(false)
        runCurrent()
        store.setForeground(true)
        repeat(10) { store.select("doc"); store.noteVisible("doc"); runCurrent() }
        assertSame(shown, store.content("doc"))
        assertEquals(listOf(false), stages)
        assertEquals(1, files.imageReads)
        assertEquals(1, files.documentReads)
        assertEquals(0, replacement.imageReads)
        assertEquals(0, replacement.imageStats)
        assertEquals(0, replacement.documentReads)
    }

    @Test fun anOrdinaryShortfallThatArrivesLateRetriesOnTheForegroundItDidNotSpend() = runTest {
        val gate = CompletableDeferred<Unit>()
        val files = Files().apply { failImage = true; imageGate = gate }
        val (store, _, stages) = fixture(files = files, awaitInitialDocument = false)
        try {
            await { files.imageReads == 1 }
            store.setForeground(false)
            runCurrent()
            store.setForeground(true)
            runCurrent()
            gate.complete(Unit)
            await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
            assertEquals(listOf(false, false), stages)
            assertEquals(1, files.documentReads)
            assertEquals(2, files.imageReads)
            repeat(10) { store.select("doc"); store.noteVisible("doc"); runCurrent() }
            assertEquals(2, files.imageReads)
            assertEquals(0, files.imageStats)
            assertEquals(1, files.documentReads)
        } finally { gate.complete(Unit) }
    }

    @Test fun aConnectionGenerationChangeInsideTheSameRegistryEntryRetriesOnceAndStablePollsDoNothing() = runTest {
        val files = Files()
        val registration = ArtifactLiveFilesRegistry.register("h", "image-retry", files, sessionLive = { true })
        try {
            val entry = checkNotNull(ArtifactLiveFilesRegistry.files("h"))
            val (store, _, stages) = fixture(files = files, liveFiles = { ArtifactLiveFilesRegistry.files("h") })
            files.failImage = true
            store.refresh("doc")
            await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
            val initial = store.content("doc")
            files.connectionGeneration += 1
            assertSame(entry, ArtifactLiveFilesRegistry.files("h"))
            advanceTimeBy(1_001)
            await { store.content("doc") !== initial }
            assertEquals(listOf(false, true, true), stages)
            assertEquals(3, files.imageReads)
            assertEquals(2, files.documentReads)
            repeat(10) {
                advanceTimeBy(1_001)
                runCurrent()
                store.select("doc")
                store.noteVisible("doc")
                runCurrent()
            }
            assertEquals(listOf(false, true, true), stages)
            assertEquals(3, files.imageReads)
            assertEquals(0, files.imageStats)
            assertEquals(2, files.documentReads)
            val retried = store.content("doc")
            files.failImage = false
            files.connectionGeneration += 1
            advanceTimeBy(1_001)
            await { store.content("doc") !== retried }
            assertEquals(listOf(false, true, true, true), stages)
            assertEquals(4, files.imageReads)
            assertEquals(2, files.documentReads)
            val complete = store.content("doc")
            files.connectionGeneration += 1
            advanceTimeBy(1_001)
            runCurrent()
            assertSame(complete, store.content("doc"))
            assertEquals(4, files.imageReads)
            assertEquals(2, files.documentReads)
        } finally { registration.close() }
    }

    @Test fun anAutomaticImageRetryKeepsTheReadableDocumentUntilTheNewImagesAreReady() = runTest {
        val files = Files().apply { failImage = true }
        val (store, _, stages) = fixture(files = files)
        val shown = store.content("doc") as ArtifactContent.Document
        val gate = CompletableDeferred<Unit>()
        files.failImage = false
        files.image = "new"
        files.imageGate = gate
        store.setForeground(false)
        runCurrent()
        store.setForeground(true)
        try {
            await { files.imageReads == 2 }
            assertSame(shown, store.content("doc"))
            assertEquals("doc", shown.file.readText())
            repeat(10) { store.select("doc"); store.noteVisible("doc"); runCurrent(); assertSame(shown, store.content("doc")) }
            assertEquals(2, files.imageReads)
            assertEquals(1, files.documentReads)
            gate.complete(Unit)
            await { store.content("doc") !== shown }
            val completed = store.content("doc") as ArtifactContent.Document
            assertNotSame(shown, completed)
            assertEquals(shown.file, completed.file)
            assertEquals(shown.displayName, completed.displayName)
            assertEquals("new", completed.stagedImages.getValue("shot.png").readText())
            assertEquals(listOf(false, false), stages)
            assertEquals(1, files.documentReads)
        } finally { gate.complete(Unit) }
    }

    @Test fun aThrowingOrCancelledAutomaticImageRetryLeavesTheSameReadableDocumentAndSpendsItsOpportunity() = runTest {
        for (failure in listOf(IOException("staging failed"), CancellationException("staging cancelled"))) {
            var stagingFailure: Exception? = null
            val files = Files()
            val (store, _, stages) = fixture(files = files, beforeImages = { stagingFailure?.let { throw it } })
            files.failImage = true
            store.refresh("doc")
            await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
            val shown = store.content("doc") as ArtifactContent.Document
            stagingFailure = failure
            store.setForeground(false)
            runCurrent()
            store.setForeground(true)
            await { stages.size == 3 }
            assertSame(shown, store.content("doc"))
            assertTrue(shown.file.isFile)
            assertEquals(listOf(false, true, true), stages)
            repeat(10) { store.select("doc"); store.noteVisible("doc"); runCurrent() }
            assertSame(shown, store.content("doc"))
            assertEquals(3, stages.size)
            assertEquals(2, files.imageReads)
            assertEquals(2, files.documentReads)
        }
    }

    @Test fun anAutomaticForcedRetryOnAnotherLiveChannelKeepsTheDocumentMountedUntilStagingFinishes() = runTest {
        val files = Files()
        var liveFiles = files
        val (store, _, stages) = fixture(files = files, liveFiles = { liveFiles })
        files.failImage = true
        store.refresh("doc")
        await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
        val shown = store.content("doc") as ArtifactContent.Document
        val gate = CompletableDeferred<Unit>()
        val replacement = Files().apply { image = "new"; imageGate = gate }
        liveFiles = replacement
        store.setForeground(true)
        try {
            await { replacement.imageReads == 1 }
            assertSame(shown, store.content("doc"))
            assertEquals("old", shown.stagedImages.getValue("shot.png").readText())
            assertEquals(0, replacement.documentReads)
            gate.complete(Unit)
            await { store.content("doc") !== shown }
            val completed = store.content("doc") as ArtifactContent.Document
            assertEquals(shown.file, completed.file)
            assertEquals(shown.displayName, completed.displayName)
            assertEquals("new", completed.stagedImages.getValue("shot.png").readText())
            assertEquals(listOf(false, true, true), stages)
            assertEquals(2, files.documentReads)
            assertEquals(0, replacement.documentReads)
            assertEquals(0, replacement.imageStats)
        } finally { gate.complete(Unit) }
    }

    @Test fun cancellationDuringImagesConsumesOnlyTheCommittedDocumentIntentAndReconnectReadsNoDocumentBytes() = runTest {
        val (store, files, stages) = fixture()
        val previous = store.content("doc") as ArtifactContent.Document
        val image = CompletableDeferred<Unit>()
        files.imageGate = image
        files.document = "accepted document"
        files.mtime = 20
        store.refresh("doc")
        try {
            await { files.imageReads == 2 }
            assertEquals("accepted document", previous.file.readText())
            assertEquals(2, files.documentReads)
            val bytes = files.documentBytes
            files.live = false
            store.setForeground(true)
            await { files.cancelledImages == 1 }
            store.refresh("doc")
            runCurrent()
            assertEquals(2, files.documentReads)
            assertEquals(bytes, files.documentBytes)
            files.live = true
            files.image = "new"
            store.setForeground(true)
            await { stages.size == 3 && store.content("doc") is ArtifactContent.Document }
            assertEquals(2, files.documentReads)
            assertEquals(bytes, files.documentBytes)
            assertEquals(20L, store.state.value.tabs.single().cache?.remoteMTime)
            assertEquals(listOf(false, true, true), stages)
            assertEquals(3, files.imageReads)
            assertEquals(0, files.imageStats)
            assertEquals("new", (store.content("doc") as ArtifactContent.Document).stagedImages.getValue("shot.png").readText())
            store.select("doc")
            runCurrent()
            assertEquals(3, stages.size)
            assertEquals(2, files.documentReads)
        } finally { image.complete(Unit) }
    }

    @Test fun aFollowerStatSuspendedAcrossRefreshNeverCancelsTheManualLoad() = runTest {
        val (store, files, stages) = fixture()
        val stat = CompletableDeferred<Unit>()
        files.statGate = stat
        files.mtime = 20
        advanceTimeBy(3_001); runCurrent()
        assertTrue(files.statStarted)
        val document = CompletableDeferred<Unit>()
        files.documentGate = document
        files.image = "new"
        store.refresh("doc")
        runCurrent()
        assertEquals(2, files.documentReads)
        stat.complete(Unit)
        runCurrent()
        assertEquals(0, files.cancelledDocuments)
        assertEquals(2, files.documentReads)
        document.complete(Unit)
        await { store.content("doc") is ArtifactContent.Document }
        assertEquals("new", (store.content("doc") as ArtifactContent.Document).stagedImages.getValue("shot.png").readText())
        assertEquals(listOf(false, true), stages)
        assertEquals(2, files.imageReads)
        files.statGate = null
        files.mtime = 30
        advanceTimeBy(3_001); runCurrent()
        await { stages.size == 3 && store.content("doc") is ArtifactContent.Document }
        assertEquals(listOf(false, true, false), stages)
        assertEquals(2, files.imageReads)
        assertEquals(1, files.imageStats)
    }

    @Test fun aMissingFollowerStatCannotReplaceTheManualRefreshPresentation() = runTest {
        val (store, files, _) = fixture()
        val stat = CompletableDeferred<Unit>()
        files.statGate = stat
        files.failStat = true
        advanceTimeBy(3_001); runCurrent()
        val document = CompletableDeferred<Unit>()
        files.documentGate = document
        store.refresh("doc")
        runCurrent()
        stat.complete(Unit)
        runCurrent()
        assertEquals(ArtifactContent.Loading, store.content("doc"))
        assertEquals(0, files.cancelledDocuments)
        document.complete(Unit)
        await { store.content("doc") is ArtifactContent.Document }
        assertEquals(2, files.imageReads)
    }

    @Test fun failedForcedImagesKeepTheirOldFilesAndTheNextLoadForcesAgainUntilSuccess() = runTest {
        val (store, files, stages) = fixture()
        val previous = (store.content("doc") as ArtifactContent.Document).stagedImages.getValue("shot.png")
        files.failImage = true
        store.refresh("doc")
        runCurrent()
        await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
        assertEquals(previous, (store.content("doc") as ArtifactContent.Document).stagedImages.getValue("shot.png"))
        assertEquals("old", previous.readText())
        assertEquals(2, files.imageReads)
        files.failImage = false
        files.image = "new"
        files.mtime = 20
        advanceTimeBy(3_001); runCurrent()
        await { stages.size == 3 && store.content("doc") is ArtifactContent.Document }
        assertEquals(listOf(false, true, true), stages)
        assertEquals(3, files.imageReads)
        assertEquals(0, files.imageStats)
        assertFalse(previous.exists())
        assertEquals("new", (store.content("doc") as ArtifactContent.Document).stagedImages.getValue("shot.png").readText())
        files.mtime = 30
        advanceTimeBy(3_001); runCurrent()
        await { stages.size == 4 && store.content("doc") is ArtifactContent.Document }
        assertEquals(listOf(false, true, true, false), stages)
        assertEquals(3, files.imageReads)
        assertEquals(1, files.imageStats)
    }

    @Test fun repeatedImageRetriesUseTheAcceptedDocumentUntilAnotherDocumentRefreshIsRequested() = runTest {
        val (store, files, stages) = fixture()
        files.failImage = true
        store.refresh("doc")
        await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
        assertEquals(2, files.documentReads)
        val accepted = store.state.value.tabs.single().cache
        repeat(10) { retry ->
            files.live = false
            store.setForeground(true)
            runCurrent()
            files.live = true
            store.setForeground(true)
            await { stages.size == retry + 3 && store.content("doc") is ArtifactContent.Document }
            assertEquals(2, files.documentReads)
            assertEquals(accepted, store.state.value.tabs.single().cache)
        }
        assertEquals(listOf(false) + List(11) { true }, stages)
        assertEquals(12, files.imageReads)
        assertEquals(0, files.imageStats)

        // A new explicit document intent still downloads the document even while images are pending.
        store.refresh("doc")
        await { stages.size == 13 && store.content("doc") is ArtifactContent.Document }
        assertEquals(3, files.documentReads)
        files.failImage = false
        store.select("doc")
        runCurrent()
        assertEquals(13, stages.size)
        assertEquals(13, files.imageReads)
        assertEquals(3, files.documentReads)
        files.live = false
        store.setForeground(true)
        runCurrent()
        files.live = true
        store.setForeground(true)
        await { stages.size == 14 && store.content("doc") is ArtifactContent.Document }
        assertEquals(3, files.documentReads)
        assertTrue(stages.last())
        store.select("doc")
        runCurrent()
        assertEquals(14, stages.size) // Completing staging clears its own intent.
    }

    @Test fun aForcedImageShortfallDoesNoWorkOnTenRevisitsAndRetriesOncePerOpportunity() = runTest {
        val (store, files, stages) = fixture(images = listOf("one.png", "two.png", "three.png", "four.png", "shot.png"))
        assertEquals(5, files.imageReads)
        files.failImage = true
        store.refresh("doc")
        await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
        assertEquals(10, files.imageReads)
        assertEquals(2, files.documentReads)
        val bytes = files.documentBytes
        repeat(10) {
            store.noteVisible(null)
            store.select("doc")
            store.noteVisible("doc")
            runCurrent()
            assertEquals(2, stages.size)
            assertEquals(10, files.imageReads)
            assertEquals(2, files.documentReads)
            assertEquals(bytes, files.documentBytes)
        }
        files.live = false
        store.setForeground(true)
        runCurrent()
        assertEquals(10, files.imageReads)
        files.live = true
        store.setForeground(true)
        await { stages.size == 3 && store.content("doc") is ArtifactContent.Document }
        assertEquals(15, files.imageReads)
        assertEquals(2, files.documentReads)
        store.select("doc")
        store.noteVisible("doc")
        store.setForeground(true)
        runCurrent()
        assertEquals(3, stages.size)
        assertEquals(15, files.imageReads)

        store.setForeground(false)
        runCurrent()
        store.setForeground(true)
        await { stages.size == 4 && store.content("doc") is ArtifactContent.Document }
        assertEquals(listOf(false, true, true, true), stages)
        assertEquals(20, files.imageReads)
        assertEquals(2, files.documentReads)
        assertEquals(bytes, files.documentBytes)
        assertEquals(0, files.imageStats)
        store.select("doc")
        store.noteVisible("doc")
        store.setForeground(true)
        runCurrent()
        assertEquals(4, stages.size)
        assertEquals(20, files.imageReads)
        files.live = false
        store.setForeground(true)
        runCurrent()
        store.setForeground(false)
        runCurrent()
        files.live = true
        store.setForeground(true)
        await { stages.size == 5 && store.content("doc") is ArtifactContent.Document }
        assertEquals(25, files.imageReads) // Reconnect and foreground together still stage only once.
        assertEquals(2, files.documentReads)
        assertEquals(bytes, files.documentBytes)
        assertEquals(0, files.imageStats)
    }

    @Test fun aLateImageShortfallSpendsItsStartingOpportunityInsteadOfTheForegroundReturn() = runTest {
        val (store, files, stages) = fixture()
        val image = CompletableDeferred<Unit>()
        files.imageGate = image
        files.failImage = true
        store.refresh("doc")
        try {
            await { files.imageReads == 2 }
            store.setForeground(false)
            runCurrent()
            store.setForeground(true)
            runCurrent()
            assertEquals(2, files.imageReads)
            assertEquals(0, files.cancelledImages)
            image.complete(Unit)
            await { store.content("doc") is ArtifactContent.Document }
            store.select("doc")
            await { stages.size == 3 && store.content("doc") is ArtifactContent.Document }
            assertEquals(listOf(false, true, true), stages)
            assertEquals(3, files.imageReads)
            assertEquals(2, files.documentReads)
            repeat(10) {
                store.select("doc")
                store.noteVisible("doc")
                runCurrent()
            }
            assertEquals(3, stages.size)
            assertEquals(3, files.imageReads)
            assertEquals(2, files.documentReads)
        } finally { image.complete(Unit) }
    }

    @Test fun replacingALiveFilesChannelRetriesPendingImagesWithoutReadingTheDocument() = runTest {
        val files = Files()
        var liveFiles = files
        val (store, _, stages) = fixture(files = files, liveFiles = { liveFiles })
        files.failImage = true
        store.refresh("doc")
        await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
        val replacement = Files().apply { image = "new" }
        liveFiles = replacement
        store.setForeground(true)
        await { stages.size == 3 && store.content("doc") is ArtifactContent.Document }
        assertEquals(listOf(false, true, true), stages)
        assertEquals(2, files.documentReads)
        assertEquals(2, files.imageReads)
        assertEquals(0, replacement.documentReads)
        assertEquals(1, replacement.imageReads)
        assertEquals("new", (store.content("doc") as ArtifactContent.Document).stagedImages.getValue("shot.png").readText())
        store.select("doc")
        store.noteVisible("doc")
        runCurrent()
        assertEquals(3, stages.size)
        assertEquals(1, replacement.imageReads)
    }

    @Test fun anotherLiveSessionForTheHostLeavesACompleteVisibleDocumentAlone() = runTest {
        val files = Files()
        var liveFiles = files
        val (store, _, stages) = fixture(files = files, liveFiles = { liveFiles })
        store.noteVisible("doc")
        runCurrent()
        val shown = store.content("doc")
        assertTrue(shown is ArtifactContent.Document)
        val stagesBefore = stages.size
        val documentReads = files.documentReads
        val replacement = Files()
        liveFiles = replacement
        store.setForeground(true)
        runCurrent()
        liveFiles = files
        store.setForeground(true)
        runCurrent()
        assertEquals(stagesBefore, stages.size)
        assertEquals(documentReads, files.documentReads)
        assertEquals(0, replacement.documentReads)
        assertEquals(0, replacement.imageReads)
        assertTrue(store.content("doc") === shown)
    }

    @Test fun aStaleDocumentStillLoadsOnTheSameOpportunityAfterAnImageShortfall() = runTest {
        val (store, files, stages) = fixture()
        files.failImage = true
        store.refresh("doc")
        await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
        files.document = "edited document"
        store.agentEditObserved("h", "/work/report.md", "+new", "edit", null, 2_000)
        store.select("doc")
        await { stages.size == 3 && store.content("doc") is ArtifactContent.Document }
        assertEquals(listOf(false, true, true), stages)
        assertEquals(3, files.documentReads)
        assertEquals(3, files.imageReads)
        assertEquals("edited document", (store.content("doc") as ArtifactContent.Document).file.readText())
        store.select("doc")
        runCurrent()
        assertEquals(3, stages.size)
        assertEquals(3, files.documentReads)
        assertEquals(3, files.imageReads)
    }

    @Test fun aDefinitiveImageFailureClearsTheIntentAndTheNextSelectionDoesNoWork() = runTest {
        val (store, files, stages) = fixture()
        files.imageFailure = java.nio.file.AccessDeniedException("/work/shot.png")
        store.refresh("doc")
        await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
        assertTrue((store.content("doc") as ArtifactContent.Document).stagedImages.isEmpty())
        assertEquals(2, files.documentReads)
        assertEquals(2, files.imageReads)
        store.select("doc")
        runCurrent()
        assertEquals(2, stages.size)
        assertEquals(2, files.documentReads)
        assertEquals(2, files.imageReads)
    }

    @Test fun livenessReplacementCarriesTheRefreshIntentAndOfflineRefreshOpensNothing() = runTest {
        val (store, files, stages) = fixture()
        val document = CompletableDeferred<Unit>()
        files.documentGate = document
        store.refresh("doc")
        runCurrent()
        files.live = false
        store.setForeground(true)
        runCurrent()
        assertEquals(1, files.cancelledDocuments)
        val reads = files.documentReads
        store.refresh("doc")
        runCurrent()
        assertEquals(reads, files.documentReads)
        assertEquals(1, files.imageReads)
        files.live = true
        files.image = "new"
        store.setForeground(true)
        runCurrent()
        await { stages.size == 2 && store.content("doc") is ArtifactContent.Document }
        assertEquals(3, files.documentReads) // The cancelled fetch never consumed its document intent.
        assertEquals(listOf(false, true), stages)
        assertEquals(2, files.imageReads)
        assertEquals(0, files.imageStats)
        assertEquals("new", (store.content("doc") as ArtifactContent.Document).stagedImages.getValue("shot.png").readText())
    }

    private fun TestScope.await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000L
        do {
            runCurrent()
            if (condition()) return
            Thread.sleep(1)
        } while (System.nanoTime() < deadline)
        assertTrue("asynchronous image staging did not finish", condition())
    }
}
