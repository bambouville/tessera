package com.bambouville.tessera.files

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * The whitespace-tolerant fallback, driven by a fake listing so the walk is
 * covered without SSH. Mirrors the iOS `RemotePathResolverTests` cases that
 * run over `MockFileBridge`.
 */
class RemoteTolerantPathWalkTest {

    private val tree = mapOf(
        "/" to listOf("home"),
        "/home" to listOf("mock"),
        "/home/mock" to listOf("docs", "Design Files"),
        "/home/mock/docs" to listOf("reviewv3.pdf", "Q3 notes.md", "old"),
        "/home/mock/Design Files" to listOf("logo.png"),
        "/home/mock/docs/old" to emptyList(),
    )

    private suspend fun resolve(
        absolute: String,
        listing: Map<String, List<String>> = tree,
    ): String? = RemoteTolerantPathWalk.resolve(absolute, { it }) { listing[it] }

    @Test
    fun `selection that lost the spaces finds the name that never had them`() = runBlocking {
        assertEquals("/home/mock/docs/reviewv3.pdf", resolve("/home/mock/docs/reviewv3.pdf"))
    }

    @Test
    fun `selection that lost the spaces finds a name that kept them`() = runBlocking {
        assertEquals("/home/mock/docs/Q3 notes.md", resolve("/home/mock/docs/Q3notes.md"))
    }

    @Test
    fun `walk matches a directory whose own name lost its spaces`() = runBlocking {
        assertEquals(
            "/home/mock/Design Files/logo.png",
            resolve("/home/mock/DesignFiles/logo.png"),
        )
        assertEquals("/home/mock/Design Files", resolve("/home/mock/DesignFiles"))
    }

    @Test
    fun `a miss stays a miss`() = runBlocking {
        assertNull(resolve("/home/mock/docs/nothinghere.pdf"))
        assertNull(resolve("/"))
    }

    @Test
    fun `ambiguous collapsed names refuse to guess`() = runBlocking {
        val twins = tree + mapOf(
            "/home/mock/docs" to listOf("reviewv3.pdf", "review v3.pdf"),
        )
        assertThrows(IllegalStateException::class.java) {
            runBlocking { resolve("/home/mock/docs/re viewv3.pdf", twins) }
        }
        // An exact spelling short-circuits the ambiguity.
        assertEquals(
            "/home/mock/docs/review v3.pdf",
            resolve("/home/mock/docs/review v3.pdf", twins),
        )
    }
}
