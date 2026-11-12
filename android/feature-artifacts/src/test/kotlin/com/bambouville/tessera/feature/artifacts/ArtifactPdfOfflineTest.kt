package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.core.bridge.SharedArtifactsViewer
import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactRemoteStat
import com.bambouville.tessera.forwarding.PortForwardRule
import com.bambouville.tessera.forwarding.PortForwardingLease
import java.io.File
import java.io.OutputStream
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ArtifactPdfOfflineTest {
    @get:Rule val temporary = TemporaryFolder()

    private class DisconnectedFiles : ArtifactLiveFiles {
        var remoteAttempts = 0
        override val hasLiveArtifactChannel = false
        override val artifactHome: String? = null
        override val artifactDirectory: String? = null
        private fun contacted(): Nothing { remoteAttempts++; error("an offline PDF must never contact its host") }
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat? = contacted()
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat? = contacted()
        override suspend fun probeOnLiveChannel(command: String): String? = contacted()
        override suspend fun acquireForwardingLeaseOnLiveChannel(rule: PortForwardRule): PortForwardingLease? = contacted()
    }

    @Test fun offlinePdfUsesOnlyTheSavedFileAndNeverReadsOrForwardsThroughADisconnectedChannel() = runBlocking {
        val files = DisconnectedFiles()
        val tab = SharedArtifactTab("pdf", "archive", "archive", SharedArtifactsTarget.File("/reports/release.pdf"),
            SharedArtifactsKind.Files, "release.pdf", "files", null, 1, 1, false, null, false, null)
        val loader = ArtifactContentLoader(
            File(temporary.root, "cache"), { files }, key = { "b".repeat(64) }, viewer = { SharedArtifactsViewer.Pdf },
            stageImages = { _, _, _, _ -> error("PDFs must not stage Markdown resources") },
        )
        assertEquals(ArtifactContent.Unavailable(ArtifactUnavailable.Offline), loader.load(tab, 1).content)
        val cached = loader.cacheFile(tab)
        val directory = checkNotNull(cached.parentFile)
        assertTrue(directory.isDirectory || directory.mkdirs())
        // This tests the loader's offline boundary. The instrumented viewer
        // suite generates and renders a complete PDF with PdfDocument.
        cached.writeText("%PDF-1.7\nlocal cached bytes\n")
        val document = loader.load(tab, 2).content as ArtifactContent.Document
        assertEquals(cached, document.file)
        assertEquals("release.pdf", document.displayName)
        assertEquals(2L, document.reloadToken)
        assertEquals("%PDF-1.7\nlocal cached bytes\n", document.file.readText())
        assertEquals(0, files.remoteAttempts)
    }
}
