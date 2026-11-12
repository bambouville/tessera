package com.bambouville.tessera.feature.session

import com.bambouville.tessera.files.ArtifactLiveFiles
import com.bambouville.tessera.files.ArtifactLiveFilesRegistry
import com.bambouville.tessera.files.ArtifactRemoteStat
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactSessionFilesOwnershipTest {
    private class Files : ArtifactLiveFiles {
        override val hasLiveArtifactChannel = true
        override val artifactHome = "/home/fixture"
        override val artifactDirectory = "/work"
        var reads = 0
        override suspend fun readArtifactOnLiveChannel(path: String, output: OutputStream, maxBytes: Long): ArtifactRemoteStat {
            reads += 1
            output.write(1)
            return ArtifactRemoteStat(path, 1, 2, false)
        }
        override suspend fun statArtifactOnLiveChannel(path: String): ArtifactRemoteStat? = error("no follow work while offline")
        override suspend fun probeOnLiveChannel(command: String): String? = error("no probe or connection while offline")
    }

    @Test fun onlyConnectedAndReconnectingSessionsOwnAnAlreadyOpenFilesChannel() = runBlocking {
        val host = UUID.randomUUID().toString()
        val state = MutableStateFlow<SshSessionUiState>(SshSessionUiState.Connected)
        val controller = (unsafe.allocateInstance(SshSessionController::class.java) as SshSessionController).apply {
            setPrivate("mutableState", state)
        }
        val files = Files()
        val registration = ArtifactLiveFilesRegistry.register(host, "session", files, sessionLive = {
            controller.hasLiveArtifactFilesOwner
        })
        try {
            val retained = checkNotNull(ArtifactLiveFilesRegistry.files(host))
            for (live in listOf(SshSessionUiState.Connected, SshSessionUiState.Connecting)) {
                state.value = live
                assertTrue(retained.hasLiveArtifactChannel)
                assertNotNull(retained.readArtifactOnLiveChannel("/work/a.md", ByteArrayOutputStream(), 100))
            }
            assertEquals(2, files.reads)
            for (offline in listOf(SshSessionUiState.Failed("failed"), SshSessionUiState.Disconnected, SshSessionUiState.Terminated)) {
                state.value = offline
                assertNull(ArtifactLiveFilesRegistry.files(host))
                assertFalse(retained.hasLiveArtifactChannel)
                assertNull(retained.readArtifactOnLiveChannel("/work/a.md", ByteArrayOutputStream(), 100))
                assertNull(retained.statArtifactOnLiveChannel("/work/a.md"))
                assertNull(retained.probeOnLiveChannel("probe"))
                assertTrue(files.hasLiveArtifactChannel)
            }
            assertEquals(2, files.reads)
            state.value = SshSessionUiState.Connected
            assertNotNull(ArtifactLiveFilesRegistry.files(host))
            controller.setPrivate("closed", true)
            assertNull(ArtifactLiveFilesRegistry.files(host))
            assertNull(retained.readArtifactOnLiveChannel("/work/a.md", ByteArrayOutputStream(), 100))
            assertEquals(SshSessionUiState.Connected, state.value)
            assertEquals(2, files.reads)
        } finally { registration.close() }
    }

    private fun Any.setPrivate(name: String, value: Any?) { javaClass.getDeclaredField(name).apply { isAccessible = true }.set(this, value) }
    private companion object {
        val unsafe = sun.misc.Unsafe::class.java.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null) as sun.misc.Unsafe
    }
}
