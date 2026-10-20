package com.bambouville.tessera.files

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteFileQuickViewTest {
    @Test
    fun markdownExtensionsMatchIOSCaseInsensitively() {
        listOf("md", "markdown", "mdown", "mkdn", "mkd", "mdwn", "mdtext", "mdtxt", "rmd", "qmd").forEach { extension ->
            assertTrue(extension, RemoteFileQuickView.isMarkdown("notes.$extension"))
            assertTrue(extension, RemoteFileQuickView.isMarkdown("notes.${extension.uppercase()}"))
        }
    }

    @Test
    fun nonMarkdownNamesAndDirectoryExtensionsDoNotMatch() {
        listOf("README", "notes.txt", "x.mdx", "md", "/notes.md/README", "/notes.md/notes.txt", "notes.md\\README").forEach { name ->
            assertFalse(name, RemoteFileQuickView.isMarkdown(name))
        }
    }

    @Test
    fun markdownFileInDirectoryMatchesItsOwnExtension() {
        assertTrue(RemoteFileQuickView.isMarkdown("/documents/notes.Md"))
    }
}
