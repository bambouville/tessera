package com.bambouville.tessera.feature.artifacts.viewers

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ArtifactFileExportTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun exportsKeepTheRealFilenameSoTheReceivingAppShowsIt() {
        assertEquals("PLAN.md", artifactExportName("PLAN.md"))
        assertEquals("release notes (final).pdf", artifactExportName("release notes (final).pdf"))
        assertEquals("topology.png", artifactExportName("/srv/build/topology.png"))
        assertEquals("évaluation 日本.md", artifactExportName("évaluation 日本.md"))
        assertEquals("ab.md", artifactExportName("a\u0000b.md"))
        for (bad in listOf("", "  ", ".", "..", "/srv/")) assertEquals(bad, "file", artifactExportName(bad))
    }

    @Test fun longNamesFitTheFilesystemAndKeepTheirExtension() {
        val name = "日".repeat(120) + ".pdf"
        val exported = artifactExportName(name)
        assertTrue(exported.toByteArray(Charsets.UTF_8).size <= 200)
        assertTrue(exported.endsWith(".pdf"))
        assertTrue(exported.startsWith("日"))
        assertFalse("no split surrogate pair", exported.any { Character.isSurrogate(it) })
        val emoji = artifactExportName("😀".repeat(80) + ".png")
        assertTrue(emoji.endsWith(".png"))
        assertEquals(0, emoji.removeSuffix(".png").length % 2)
    }

    @Test fun exportsOlderThanADayAreReaped() {
        val root = temporary.newFolder("exports", "artifacts")
        val now = 10L * 24 * 60 * 60 * 1000
        val old = File(root, "old").apply { mkdirs(); File(this, "PLAN.md").writeText("x"); setLastModified(now - 25L * 60 * 60 * 1000) }
        val legacy = File(root, "artifact-123-PLAN.md").apply { writeText("x"); setLastModified(now - 25L * 60 * 60 * 1000) }
        val fresh = File(root, "fresh").apply { mkdirs(); File(this, "PLAN.md").writeText("x"); setLastModified(now - 60_000) }
        reapArtifactExports(root, now)
        assertFalse(old.exists())
        assertFalse(legacy.exists())
        assertTrue(File(fresh, "PLAN.md").isFile)
    }
}
