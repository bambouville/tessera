package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedAgentMarkdownTest {
    @Test
    fun decodesTheSharedMarkdownJSONWithoutImplementingMarkdownLocally() {
        val json = JSONObject()
            .put("blocks", JSONArray().put(
                JSONObject()
                    .put("kind", "heading")
                    .put("level", 1)
                    .put("children", JSONArray().put(JSONObject().put("kind", "text").put("text", "Heading"))),
            ))
            .put("truncated", false)
            .toString()

        val document = SharedAgentMarkdown.decodeJSONForTesting(json)
        assertEquals("heading", document?.blocks?.single()?.kind)
        assertEquals(1, document?.blocks?.single()?.level)
        assertEquals("Heading", document?.blocks?.single()?.children?.single()?.text)
        assertFalse(document?.truncated ?: true)
    }

    @Test
    fun decoderRejectsOverdeepOrOverlargeNativeTrees() {
        fun deep(level: Int): JSONObject = JSONObject().put("kind", "paragraph").put(
            "children",
            if (level == 0) JSONArray() else JSONArray().put(deep(level - 1)),
        )
        assertNull(SharedAgentMarkdown.decodeJSONForTesting(JSONObject().put("blocks", JSONArray().put(deep(26))).put("truncated", false).toString()))

        val nodes = JSONArray()
        repeat(8_193) { nodes.put(JSONObject().put("kind", "text").put("text", "x")) }
        assertNull(SharedAgentMarkdown.decodeJSONForTesting(JSONObject().put("blocks", nodes).put("truncated", false).toString()))
    }

    @Test
    fun clippingStopsBeforeAPartialUTF8Scalar() {
        val source = "a".repeat(128 * 1024 - 1) + "🙂"
        val (bytes, clipped) = SharedAgentMarkdown.clippedInputForNative(source)
        assertTrue(clipped)
        assertEquals("a".repeat(128 * 1024 - 1), bytes.decodeToString())
    }

    @Test
    fun parseCacheIsLeastRecentlyUsedAndByteBounded() {
        fun document(text: String) = SharedAgentMarkdownDocument(
            listOf(SharedAgentMarkdownNode("paragraph", children = listOf(SharedAgentMarkdownNode("text", text = text)))),
            truncated = false,
        )
        val cache = SharedAgentMarkdownCache(64 * 1024)
        val first = document("first")
        cache.put("first", first)
        repeat(200) { cache.put("filler-$it ".repeat(20), document("filler $it")) }
        assertTrue("retained bytes must stay within the budget", cache.bytes <= 64 * 1024)
        assertNull("the least recently used entry is evicted first", cache["first"])

        val control = document("control")
        cache.put("kept", first)
        cache.put("control", control)
        // ~700 estimated bytes each: 200 inserts turn the 64 KiB cache over
        // twice, so only access order can keep "kept" resident.
        repeat(200) {
            assertTrue(cache["kept"] === first) // Touching keeps it most recently used.
            cache.put("more-$it ".repeat(20), document("more $it"))
        }
        assertTrue(cache["kept"] === first)
        assertNull("an untouched entry of the same age is evicted", cache["control"])
        cache.put("huge", document("x".repeat(20_000)))
        assertNull("an entry over a quarter of the budget is not retained", cache["huge"])

        cache.put("medium", document("m".repeat(4_000)))
        assertTrue(cache["medium"] != null)
        cache.resize(16 * 1024)
        assertTrue("shrinking trims to the new budget", cache.bytes <= 16 * 1024)
        assertNull("entries over a quarter of the new budget go", cache["medium"])
        cache.clear()
        assertEquals(0, cache.size)
        assertEquals(0, cache.bytes)
    }
}
