package com.bambouville.tessera.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteSelectionPathResolverTest {
    @Test
    fun `selection cleanup accepts one quoted path and compiler suffixes`() {
        assertEquals("/tmp/a file.png", RemoteSelectionPathResolver.pathCandidate("  '/tmp/a file.png'  "))
        assertEquals("src/App.kt", RemoteSelectionPathResolver.pathCandidate("src/App.kt:23:5:"))
        assertEquals("server.log", RemoteSelectionPathResolver.pathCandidate("server.log:"))
    }

    @Test
    fun `selection cleanup rejects prose controls and oversized input`() {
        assertNull(RemoteSelectionPathResolver.pathCandidate("see docs/readme.md,"))
        assertNull(RemoteSelectionPathResolver.pathCandidate("hello world"))
        assertNull(RemoteSelectionPathResolver.pathCandidate("/tmp/a\nrm -rf /"))
        assertNull(RemoteSelectionPathResolver.pathCandidate("a".repeat(1_025)))
    }

    @Test
    fun `plausibility gate avoids ordinary copy text`() {
        assertTrue(RemoteSelectionPathResolver.isPlausiblePath("/var/log/nginx"))
        assertTrue(RemoteSelectionPathResolver.isPlausiblePath("docs/layout.png"))
        assertTrue(RemoteSelectionPathResolver.isPlausiblePath(".env"))
        assertTrue(RemoteSelectionPathResolver.isPlausiblePath("README.md"))
        assertFalse(RemoteSelectionPathResolver.isPlausiblePath("plain prose sentence"))
        assertFalse(RemoteSelectionPathResolver.isPlausiblePath("noextension"))
    }

    @Test
    fun `expansion anchors selection and never guesses another home`() {
        assertEquals(
            "/home/dev/projects/build/out.log",
            RemoteSelectionPathResolver.expand("build/out.log", "/home/dev", "/home/dev/projects"),
        )
        assertEquals(
            "/home/dev/a/c",
            RemoteSelectionPathResolver.expand("~/a/./b/../c", "/home/dev", null),
        )
        assertEquals(
            "/home/dev/sibling",
            RemoteSelectionPathResolver.expand("../sibling", null, "/home/dev/projects"),
        )
        assertNull(RemoteSelectionPathResolver.expand("relative", "/home/dev", null))
        assertNull(RemoteSelectionPathResolver.expand("~other/file", "/home/dev", "/tmp"))
        assertNull(RemoteSelectionPathResolver.expand("/tmp/a\u0000b", null, null))
    }

    // Wrapped selections (agent TUI output) — mirrors the shared-core
    // `RemotePathResolutionTests` cases so both platforms read one selection
    // the same way.

    @Test
    fun `collapsed reading rejoins a wrapped path`() {
        assertEquals(
            "/home/qi/docs/reviewv3.pdf",
            RemoteSelectionPathResolver.collapsedPathCandidate("/home/qi/docs/review\n    v3.pdf"),
        )
        assertEquals(
            "docs/review-v3.pdf",
            RemoteSelectionPathResolver.collapsedPathCandidate("docs/rev\n\tiew-v3.pdf"),
        )
        // Tail cleanup survives the rejoin.
        assertEquals(
            "src/App.tsx",
            RemoteSelectionPathResolver.collapsedPathCandidate("src/App\n  .tsx:23:5,"),
        )
    }

    @Test
    fun `collapsed reading only adds a second candidate`() {
        assertNull(RemoteSelectionPathResolver.collapsedPathCandidate("  /tmp/x  "))
        assertEquals(listOf("/tmp/x"), RemoteSelectionPathResolver.pathCandidates("  /tmp/x  "))
        assertEquals(
            listOf("/tmp/a file.png", "/tmp/afile.png"),
            RemoteSelectionPathResolver.pathCandidates("'/tmp/a file.png'"),
        )
        assertEquals(
            listOf("docs/reviewv3.pdf"),
            RemoteSelectionPathResolver.pathCandidates("docs/review v3.pdf"),
        )
    }

    @Test
    fun `collapsed reading caps fragments and still rejects terminal debris`() {
        val prose = (1..(RemoteSelectionPathResolver.MAX_COLLAPSED_FRAGMENTS + 1))
            .joinToString(" ") { "word$it/x" }
        assertNull(RemoteSelectionPathResolver.collapsedPathCandidate(prose))
        assertNull(RemoteSelectionPathResolver.collapsedPathCandidate("/tmp/a\u001B[31m b.png"))
        assertNull(RemoteSelectionPathResolver.collapsedPathCandidate("/tmp/a\u0000b c.png"))
        assertFalse(RemoteSelectionPathResolver.isPlausiblePath("/tmp/\u001B[31mred file.png"))
    }

    @Test
    fun `menu gate opens for a wrapped path and still ignores prose`() {
        assertTrue(RemoteSelectionPathResolver.isPlausiblePath("/home/qi/docs/review\n    v3.pdf"))
        assertTrue(RemoteSelectionPathResolver.isPlausiblePath("review\n v3.pdf"))
        assertFalse(RemoteSelectionPathResolver.isPlausiblePath("plain prose sentence"))
        assertFalse(RemoteSelectionPathResolver.isPlausiblePath("two words"))
    }

    @Test
    fun `collapsing whitespace ignores every break a path can take`() {
        assertEquals("reviewv3.pdf", RemoteSelectionPathResolver.collapseWhitespace("review v3.pdf"))
        assertEquals("abc", RemoteSelectionPathResolver.collapseWhitespace("a\t b\u00A0c\r\n"))
    }

    @Test
    fun `entries match across spaces in either direction and prefer exact`() {
        val entries = listOf("reviewv3.pdf", "notes.md", "Screen Shot 2026.png")
        assertEquals(
            listOf("reviewv3.pdf"),
            RemoteSelectionPathResolver.entriesNamed("review v3.pdf", entries) { it },
        )
        assertEquals(
            listOf("Screen Shot 2026.png"),
            RemoteSelectionPathResolver.entriesNamed("ScreenShot2026.png", entries) { it },
        )
        assertEquals(
            emptyList<String>(),
            RemoteSelectionPathResolver.entriesNamed("missing.txt", entries) { it },
        )
        val twins = listOf("reviewv3.pdf", "review v3.pdf")
        assertEquals(
            listOf("review v3.pdf"),
            RemoteSelectionPathResolver.entriesNamed("review v3.pdf", twins) { it },
        )
        assertEquals(2, RemoteSelectionPathResolver.entriesNamed("r eviewv3.pdf", twins) { it }.size)
    }
}
