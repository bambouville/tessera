package com.bambouville.tessera.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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

}
