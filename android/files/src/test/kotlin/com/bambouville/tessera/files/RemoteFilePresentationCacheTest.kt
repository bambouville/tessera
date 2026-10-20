package com.bambouville.tessera.files

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteFilePresentationCacheTest {
    @Test
    fun markdownUsesInAppTextPreviewRegardlessOfMimeOrSample() {
        listOf("notes.md", "notes.markdown", "notes.MD", "notes.MARKDOWN").forEach { name ->
            listOf("text/markdown", "application/octet-stream", "application/markdown").forEach { mime ->
                assertTrue("$name ($mime)", shouldPreviewText(name, mime, byteArrayOf()))
                assertTrue("$name ($mime)", shouldPreviewText(name, mime, byteArrayOf(0)))
            }
        }
    }

    @Test
    fun additionalMarkdownExtensionsUseInAppTextPreviewForEmptyFiles() {
        listOf("mdown", "mkdn", "mkd", "mdwn", "mdtext", "mdtxt", "rmd", "qmd").forEach { extension ->
            assertTrue(extension, shouldPreviewText("notes.$extension", "application/octet-stream", byteArrayOf()))
        }
    }

    @Test
    fun shellDotfileUsesInAppTextPreview() {
        assertTrue(shouldPreviewText(".bash_logout", "application/octet-stream", "echo logout\n".encodeToByteArray()))
    }

    @Test
    fun binaryPayloadStaysOnSystemViewerPath() {
        assertFalse(shouldPreviewText("capture.bin", "application/octet-stream", byteArrayOf(0, 1, 2, 3)))
    }
}
