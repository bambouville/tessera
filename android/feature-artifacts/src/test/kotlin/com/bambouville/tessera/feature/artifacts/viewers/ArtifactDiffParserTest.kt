package com.bambouville.tessera.feature.artifacts.viewers

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ArtifactDiffParserTest {
    @Test fun hunkHeadersSupplyIndependentOldAndNewLineNumbers() {
        val lines = ArtifactDiffParser.parse("@@ -10,3 +20,4 @@ function\n unchanged\n-old\n+new\n+extra\n tail\n")
        assertEquals(ArtifactDiffLineKind.Hunk, lines[0].kind)
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Context, "unchanged", 10, 20), lines[1])
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Removed, "old", 11, null), lines[2])
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Added, "new", null, 21), lines[3])
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Added, "extra", null, 22), lines[4])
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Context, "tail", 12, 23), lines[5])
    }

    @Test fun fileHeadersAreMetadataWhileMatchingCodeInsideAHunkIsNot() {
        val lines = ArtifactDiffParser.parse("--- a/file\n+++ b/file\n@@ -1 +1 @@\n--- actual code\n+++ actual code\n")
        assertEquals(ArtifactDiffLineKind.Header, lines[0].kind)
        assertEquals(ArtifactDiffLineKind.Header, lines[1].kind)
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Removed, "-- actual code", 1, null), lines[3])
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Added, "++ actual code", null, 1), lines[4])
    }

    @Test fun omittedCountsAndMultipleHunksResetTheNumbers() {
        val lines = ArtifactDiffParser.parse("@@ -2 +3 @@\n-old\n+new\n@@ -40,1 +42,1 @@\n same")
        assertEquals(2, lines[1].oldLineNumber)
        assertEquals(3, lines[2].newLineNumber)
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Context, "same", 40, 42), lines.last())
    }

    /** An agent edit known only by its old and new text starts at 0. */
    @Test fun aHunkWithNoPositionKeepsItsLinesUnnumbered() {
        val lines = ArtifactDiffParser.parse("@@ -0,1 +0,2 @@\n-old\n+new\n+extra\n")
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Hunk, "⋯"), lines[0])
        // An edit that only removes is no position either; a new file is.
        assertEquals("⋯", ArtifactDiffParser.parse("@@ -0,2 +0,0 @@\n-a\n-b")[0].text)
        assertEquals("@@ -0,0 +1,2 @@", ArtifactDiffParser.parse("@@ -0,0 +1,2 @@\n+a\n+b")[0].text)
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Removed, "old", null, null), lines[1])
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Added, "new", null, null), lines[2])
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Added, "extra", null, null), lines[3])
    }

    @Test fun additionsAndRemovalsSupportZeroLengthSides() {
        val added = ArtifactDiffParser.parse("@@ -0,0 +1,2 @@\n+first\n+second")
        assertNull(added[1].oldLineNumber)
        assertEquals(1, added[1].newLineNumber)
        assertEquals(2, added[2].newLineNumber)
        val removed = ArtifactDiffParser.parse("@@ -1,2 +0,0 @@\n-first\n-second")
        assertEquals(1, removed[1].oldLineNumber)
        assertEquals(2, removed[2].oldLineNumber)
        assertNull(removed[2].newLineNumber)
    }

    @Test fun noNewlineAnnotationsDoNotConsumeLineNumbers() {
        val lines = ArtifactDiffParser.parse("@@ -5 +5 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file")
        assertEquals(ArtifactDiffLineKind.Note, lines[2].kind)
        assertEquals(5, lines[3].newLineNumber)
        assertEquals(ArtifactDiffLineKind.Note, lines.last().kind)
    }

    @Test fun plainSnapshotsKeepPrefixesAndWhitespaceWithoutInventingNumbers() {
        val lines = ArtifactDiffParser.parse("-old\n+  indented  \n \n")
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Removed, "old"), lines[0])
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Added, "  indented  "), lines[1])
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Context, ""), lines[2])
        assertEquals(emptyList<ArtifactDiffLine>(), ArtifactDiffParser.parse(""))
    }

    @Test fun malformedHeadersAndOverflowCannotInventOrWrapLineNumbers() {
        val malformed = ArtifactDiffParser.parse("@@ -bad +2 @@\n+raw\n@@ -999999999999999999 +2 @@\n+raw")
        assertEquals(ArtifactDiffLineKind.Header, malformed[0].kind)
        assertNull(malformed[1].newLineNumber)
        assertEquals(ArtifactDiffLineKind.Header, malformed[2].kind)
        val overflow = ArtifactDiffParser.parse("@@ -0,0 +2147483647,2 @@\n+last\n+beyond")
        assertEquals(Int.MAX_VALUE, overflow[1].newLineNumber)
        assertNull(overflow[2].newLineNumber)
    }

    @Test fun newFileHeadersAndCrLfDoNotCarryPreviousHunkNumbers() {
        val lines = ArtifactDiffParser.parse("@@ -1 +1 @@\r\n-old\r\n+new\r\n--- a/next\r\n+++ b/next\r\n@@ -8 +9 @@\r\n next\r\n")
        assertEquals(ArtifactDiffLineKind.Header, lines[3].kind)
        assertEquals(ArtifactDiffLineKind.Header, lines[4].kind)
        assertEquals(ArtifactDiffLine(ArtifactDiffLineKind.Context, "next", 8, 9), lines.last())
    }

    @Test fun longDiffsKeepAllLogicalLinesForLazyRendering() {
        val lines = ArtifactDiffParser.parse("@@ -0,0 +1,10000 @@\n" + (1..10_000).joinToString("\n") { "+line $it" })
        assertEquals(10_001, lines.size)
        assertEquals(10_000, lines.last().newLineNumber)
    }
}
