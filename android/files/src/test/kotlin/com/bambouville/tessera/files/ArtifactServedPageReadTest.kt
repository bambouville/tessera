package com.bambouville.tessera.files

import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.io.OutputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactServedPageReadTest {
    private class Channel : AutoCloseable {
        var live = true
        val canonical = mutableMapOf<String, String>()
        val calls = mutableListOf<String>()
        var bytes = "page".toByteArray()
        var size: Long? = bytes.size.toLong()
        override fun close() { live = false }
    }

    private suspend fun RemoteFilesConnectionSlot<Channel>.read(
        root: String? = "/srv/site",
        path: String = "/srv/site/index.html",
        output: OutputStream = ByteArrayOutputStream(),
        maximum: Long = 1024,
        canonicalizeFailure: Exception? = null,
    ): ArtifactRemoteStat? = readArtifactOnHeldChannel(
        root, path, output, maximum,
        canonicalize = { live, value ->
            live.calls += "realpath:$value"
            if (canonicalizeFailure != null) throw canonicalizeFailure
            live.canonical[value] ?: value
        },
        stat = { live, value ->
            live.calls += "stat:$value"
            ArtifactRemoteStat(value, live.size, 123, false)
        },
        download = { live, value, bounded ->
            live.calls += "read:$value"
            bounded.write(live.bytes)
        },
    )

    @Test fun symlinksLeavingThePageRootCannotBeStattedOrRead() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>(isUsable = { it.live })
        val channel = slot.obtain { Channel() }
        channel.canonical["/srv/site/private/id_ed25519"] = "/home/u/.ssh/id_ed25519"
        try {
            val result = runCatching { slot.read(path = "/srv/site/private/id_ed25519") }
            assertTrue(result.exceptionOrNull() is FileNotFoundException)
            assertEquals(listOf("realpath:/srv/site", "realpath:/srv/site/private/id_ed25519"), channel.calls)
        } finally { slot.closeAndJoin() }
    }

    @Test fun canonicalContainmentRequiresAComponentBoundary() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>()
        val channel = slot.obtain { Channel() }
        channel.canonical["/srv/site/private/key"] = "/srv/site-backup/private/key"
        try {
            assertTrue(runCatching { slot.read(path = "/srv/site/private/key") }.exceptionOrNull() is FileNotFoundException)
            assertTrue(channel.calls.none { it.startsWith("read:") || it.startsWith("stat:") })
        } finally { slot.closeAndJoin() }
    }

    @Test fun aSymlinkedRootAndContainedAssetAreBothCanonicalizedBeforeReading() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>()
        val channel = slot.obtain { Channel() }
        channel.canonical["/srv/site"] = "/opt/releases/current"
        channel.canonical["/srv/site/images/logo.svg"] = "/opt/releases/current/assets/logo.svg"
        val output = ByteArrayOutputStream()
        try {
            val stat = slot.read(path = "/srv/site/images/logo.svg", output = output)
            assertEquals("/opt/releases/current/assets/logo.svg", stat?.path)
            assertEquals("page", output.toString("UTF-8"))
            assertEquals(listOf(
                "realpath:/srv/site", "realpath:/srv/site/images/logo.svg",
                "stat:/opt/releases/current/assets/logo.svg", "read:/opt/releases/current/assets/logo.svg",
            ), channel.calls)
        } finally { slot.closeAndJoin() }
    }

    @Test fun aRootAtTheFilesystemRootCanReadItsCanonicalChild() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>()
        val channel = slot.obtain { Channel() }
        channel.canonical["/index.html"] = "/public/index.html"
        try {
            assertEquals("/public/index.html", slot.read(root = "/", path = "/index.html")?.path)
            assertEquals("read:/public/index.html", channel.calls.last())
        } finally { slot.closeAndJoin() }
    }

    @Test fun eitherRealpathFailureIsMissingAndNeverFallsBackToTheLexicalPath() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>()
        val channel = slot.obtain { Channel() }
        try {
            assertTrue(runCatching { slot.read(canonicalizeFailure = IOException("SFTP REALPATH failed")) }.exceptionOrNull() is FileNotFoundException)
            assertEquals(listOf("realpath:/srv/site"), channel.calls)
            channel.calls.clear()
            val failure = runCatching {
                slot.readArtifactOnHeldChannel("/srv/site", "/srv/site/index.html", ByteArrayOutputStream(), 1024,
                    canonicalize = { _, value -> if (value == "/srv/site") value else throw IOException("missing") },
                    stat = { _, _ -> error("failed REALPATH must not stat") },
                    download = { _, _, _ -> error("failed REALPATH must not read") })
            }
            assertTrue(failure.exceptionOrNull() is FileNotFoundException)
        } finally { slot.closeAndJoin() }
    }

    @Test fun invalidCanonicalRepliesAreMissing() = runBlocking {
        for (canonical in listOf("relative/key", "/srv/site/../secret", "/srv/site/./key", "/srv/site/\u0000key")) {
            val slot = RemoteFilesConnectionSlot<Channel>()
            val channel = slot.obtain { Channel() }
            channel.canonical["/srv/site/index.html"] = canonical
            try {
                assertTrue(canonical, runCatching { slot.read() }.exceptionOrNull() is FileNotFoundException)
                assertTrue(channel.calls.none { it.startsWith("read:") || it.startsWith("stat:") })
            } finally { slot.closeAndJoin() }
        }
    }

    @Test fun absentDeadOrClosedChannelsReturnOfflineWithoutAnySftpWork() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>(isUsable = { it.live })
        try {
            // No opening callback is available to the served-page helper.
            assertNull(slot.read())
            val channel = slot.obtain { Channel().apply { live = false } }
            assertNull(slot.read())
            assertTrue(channel.calls.isEmpty())
            slot.closeAndJoin()
            assertNull(slot.read())
        } finally { slot.closeAndJoin() }
    }

    @Test fun documentDownloadsRetainTheirExistingUnrestrictedPath() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>()
        val channel = slot.obtain { Channel() }
        try {
            assertEquals("/home/u/report.md", slot.read(root = null, path = "/home/u/report.md")?.path)
            assertEquals(listOf("stat:/home/u/report.md", "read:/home/u/report.md"), channel.calls)
        } finally { slot.closeAndJoin() }
    }

    @Test fun byteLimitsAreCheckedBeforeReadingAndWhileWriting() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>()
        val channel = slot.obtain { Channel() }
        try {
            assertTrue(runCatching { slot.read(maximum = 3) }.exceptionOrNull() is ArtifactSizeLimitExceeded)
            assertTrue(channel.calls.none { it.startsWith("read:") })
            channel.size = null
            val output = ByteArrayOutputStream()
            assertTrue(runCatching { slot.read(maximum = 3, output = output) }.exceptionOrNull() is ArtifactSizeLimitExceeded)
            assertEquals(0, output.size())
        } finally { slot.closeAndJoin() }
    }

    @Test fun canonicalizationCancellationRemainsCancellation() = runBlocking {
        val slot = RemoteFilesConnectionSlot<Channel>()
        slot.obtain { Channel() }
        try {
            assertTrue(runCatching { slot.read(canonicalizeFailure = CancellationException("closed tab")) }.exceptionOrNull() is CancellationException)
        } finally { slot.closeAndJoin() }
    }
}
