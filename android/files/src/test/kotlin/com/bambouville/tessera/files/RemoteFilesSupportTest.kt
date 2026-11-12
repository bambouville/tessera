package com.bambouville.tessera.files

import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.design.ArtifactOpener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteFilesSupportTest {
    @Test
    fun `presentation progress clears on success failure and cancellation`() {
        val item = TransferItem(
            direction = TransferDirection.DOWNLOAD,
            displayName = "share.txt",
            remotePath = "/fixture/share.txt",
            localUri = null,
        )
        for (phase in TransferPhase.entries) {
            assertEquals(
                phase.name,
                phase in setOf(TransferPhase.QUEUED, TransferPhase.RUNNING, TransferPhase.CANCELLING),
                RemoteFilesBrowser.isPreparingPresentation(item.copy(phase = phase)),
            )
        }
        assertEquals(false, RemoteFilesBrowser.isPreparingPresentation(item.copy(direction = TransferDirection.UPLOAD)))
    }

    @Test
    fun `row tap explicitly maps every file kind`() {
        val expected = mapOf(
            RemoteFileKind.FILE to RemoteFileRowTap.QUICK_VIEW,
            RemoteFileKind.DIRECTORY to RemoteFileRowTap.NAVIGATE,
            RemoteFileKind.SYMLINK to RemoteFileRowTap.NAVIGATE,
            RemoteFileKind.OTHER to RemoteFileRowTap.NONE,
        )

        assertEquals(RemoteFileKind.entries.toSet(), expected.keys)
        expected.forEach { (kind, tap) ->
            assertEquals(kind.name, tap, RemoteFilesBrowser.rowTap(kind))
        }
    }

    @Test
    fun `file opens route to the saved host without a staged copy`() {
        val entry = RemoteFileEntry("notes.md", "/srv/notes.md", RemoteFileKind.FILE, 100, null, null)
        for (origin in listOf(ArtifactOpenOrigin.Files, ArtifactOpenOrigin.TerminalSelection)) {
            val requests = mutableListOf<ArtifactOpenRequest>()
            val opened = RemoteFilesBrowser.openArtifact(
                entry, RemoteFilePresentationAction.OPEN, "saved-host", ArtifactOpener { requests += it },
                origin, "live-session",
            )

            assertTrue(opened)
            assertEquals(listOf(ArtifactOpenRequest.File("saved-host", "/srv/notes.md", origin, "live-session")), requests)
            assertNull((requests.single() as ArtifactOpenRequest.File).stagedFile)
        }
    }

    @Test
    fun `missing opener leaves file opens on the presentation path`() {
        val entry = RemoteFileEntry("notes.md", "/srv/notes.md", RemoteFileKind.FILE, null, null, null)

        assertFalse(RemoteFilesBrowser.openArtifact(
            entry, RemoteFilePresentationAction.OPEN, "saved-host", null, ArtifactOpenOrigin.Files,
        ))
    }

    @Test
    fun `sharing never becomes an artifact open`() {
        val requests = mutableListOf<ArtifactOpenRequest>()
        val entry = RemoteFileEntry("notes.md", "/srv/notes.md", RemoteFileKind.FILE, null, null, null)

        assertFalse(RemoteFilesBrowser.openArtifact(
            entry, RemoteFilePresentationAction.SHARE, "saved-host", ArtifactOpener { requests += it }, ArtifactOpenOrigin.Files,
        ))
        assertTrue(requests.isEmpty())
    }

    @Test
    fun `directory navigation and unknown file kinds never open tabs`() {
        val requests = mutableListOf<ArtifactOpenRequest>()
        for (kind in RemoteFileKind.entries.filter { it != RemoteFileKind.FILE }) {
            val entry = RemoteFileEntry("item", "/srv/item", kind, null, null, null)
            assertFalse(kind.name, RemoteFilesBrowser.openArtifact(
                entry, RemoteFilePresentationAction.OPEN, "saved-host", ArtifactOpener { requests += it }, ArtifactOpenOrigin.Files,
            ))
        }
        assertTrue(requests.isEmpty())
    }

    @Test
    fun `an artifact requires saved host identity and an absolute path`() {
        val requests = mutableListOf<ArtifactOpenRequest>()
        val opener = ArtifactOpener { requests += it }
        val entry = RemoteFileEntry("notes.md", "/srv/notes.md", RemoteFileKind.FILE, null, null, null)
        for (hostId in listOf(null, "", " ")) {
            assertFalse(RemoteFilesBrowser.openArtifact(
                entry, RemoteFilePresentationAction.OPEN, hostId, opener, ArtifactOpenOrigin.Files,
            ))
        }
        assertFalse(RemoteFilesBrowser.openArtifact(
            entry.copy(path = "notes.md"), RemoteFilePresentationAction.OPEN, "saved-host", opener, ArtifactOpenOrigin.Files,
        ))
        assertTrue(requests.isEmpty())
    }

    @Test
    fun `quick open rejects control characters but preserves a valid remote path`() {
        assertEquals("/srv/projects/tessera", RemoteFilesBrowser.requestedPath("  /srv/projects/tessera  "))
        assertNull(RemoteFilesBrowser.requestedPath("/home/dev\nrm -rf /"))
        assertNull(RemoteFilesBrowser.requestedPath("   "))
    }

    @Test
    fun `quick open expands home shorthand without sending it to SFTP as a literal`() {
        assertEquals("/home/dev", RemoteFilesBrowser.requestedPath("~", "/home/dev"))
        assertEquals("/home/dev/projects/tessera", RemoteFilesBrowser.requestedPath("~/projects/tessera", "/home/dev"))
        assertEquals("/projects", RemoteFilesBrowser.requestedPath("~/projects", "/"))
        assertNull(RemoteFilesBrowser.requestedPath("~other", "/home/dev"))
        assertNull(RemoteFilesBrowser.requestedPath("~"))
    }

    @Test
    fun `filter matches names and paths without changing directory ordering`() {
        val entries = listOf(
            RemoteFileEntry("notes.md", "/home/dev/notes.md", RemoteFileKind.FILE, null, null, null),
            RemoteFileEntry("archive", "/srv/archive", RemoteFileKind.DIRECTORY, null, null, null),
            RemoteFileEntry("image.png", "/home/dev/image.png", RemoteFileKind.FILE, null, null, null),
        )

        assertEquals(listOf("notes.md"), RemoteFilesBrowser.filter(entries, "NOTES").map(RemoteFileEntry::name))
        assertEquals(listOf("archive"), RemoteFilesBrowser.filter(entries, "/srv/").map(RemoteFileEntry::name))
        assertEquals(entries, RemoteFilesBrowser.filter(entries, ""))
    }

    @Test
    fun `terminal path payload uses POSIX safe single quote encoding`() {
        val insertion = RemoteTerminalPath("/home/dev/it's ready.txt")

        assertEquals("'/home/dev/it'\"'\"'s ready.txt'", insertion.shellQuoted)
        assertTrue(insertion.rawPath.startsWith('/'))
    }

    @Test
    fun `failures the screen translates keep English messages and the types callers catch`() {
        // safeMessage records these in diagnostics, which stay English.
        assertEquals(
            listOf("Local destination is unavailable", "Local source is unavailable", "The staged remote file is unavailable"),
            FilesLocalFileUnavailableException.Reason.entries.map { FilesLocalFileUnavailableException(it).message },
        )
        assertEquals("Enter a valid file name", FilesInvalidNameException().message)
        assertThrows(IllegalStateException::class.java) {
            throw FilesLocalFileUnavailableException(FilesLocalFileUnavailableException.Reason.Staged)
        }
        assertThrows(IllegalArgumentException::class.java) { throw FilesInvalidNameException() }
    }
}
