package com.bambouville.tessera.files

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteMarkdownImagesTest {
    @Test fun pathsResolveAgainstTheRemoteDocumentAndDecodeOnlyOnce() {
        assertEquals("/docs/../images/a b.png", RemoteMarkdownImages.remotePath("../images/a%20b.png", "/docs/readme.md"))
        assertEquals("/opt/a.png", RemoteMarkdownImages.remotePath("/opt/a.png", "/docs/readme.md"))
        assertEquals("/opt/a%20b.png", RemoteMarkdownImages.remotePath("file:///opt/a%2520b.png", "/readme.md"))
        assertEquals("/图.png", RemoteMarkdownImages.remotePath("图.png", "/readme.md"))
        assertEquals("/docs/images/my plot.png", RemoteMarkdownImages.remotePath("images/my plot.png", "/docs/readme.md"))
        assertEquals("/docs/images/plot[1].png", RemoteMarkdownImages.remotePath("images/plot[1].png", "/docs/readme.md"))
        assertEquals("/docs/images/100%.png", RemoteMarkdownImages.remotePath("images/100%.png", "/docs/readme.md"))
        assertEquals("/docs/a+b.png", RemoteMarkdownImages.remotePath("a+b.png", "/docs/readme.md"))
    }

    @Test fun rejectsOtherHostsSchemesAndControlCharacters() {
        listOf("https://example.com/a", "//example.com/a", "file://host/a", "data:image/png;base64,AA", "a%00.png", "a%0A.png", "", "#fragment")
            .forEach { assertNull(it, RemoteMarkdownImages.remotePath(it, "/docs/readme.md")) }
    }
}
