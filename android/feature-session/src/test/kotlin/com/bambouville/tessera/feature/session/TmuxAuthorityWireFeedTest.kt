package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.CoreCallResult
import org.junit.Assert.assertEquals
import org.junit.Test

class TmuxAuthorityWireFeedTest {
    @Test
    fun replyAndLayoutBoundariesSurviveEverySocketSplit() {
        val wire = "%begin 1 2 1\nlatest\n%end 1 2 1\n%layout-change @5 shape\n%output %7 tail\n"
        for (cut in 0..wire.length) {
            val callbacks = mutableListOf<String>()
            val reader = TmuxAuthorityWireFeed { callbacks += it.decodeToString(); CoreCallResult.Accepted }
            for (chunk in listOf(wire.substring(0, cut), wire.substring(cut)).filter { it.isNotEmpty() }) {
                val bytes = chunk.encodeToByteArray()
                assertEquals(CoreCallResult.Accepted, reader.feed(bytes, bytes.size, true))
            }
            assertEquals("cut=$cut: the bytes are neither lost nor repeated", wire, callbacks.joinToString(""))
            assertEquals("cut=$cut: no reply and later layout share a projection", false,
                callbacks.any { "%end" in it && "%layout-change" in it })
        }
    }

    @Test
    fun unchangedOutputKeepsItsBatchWithOrWithoutAClaim() {
        val wire = "%output %7 text\n".repeat(1000).encodeToByteArray()
        for (claim in listOf(false, true)) {
            val callbacks = mutableListOf<ByteArray>()
            val reader = TmuxAuthorityWireFeed { callbacks += it; CoreCallResult.Accepted }
            assertEquals(CoreCallResult.Accepted, reader.feed(wire, wire.size, claim))
            assertEquals(1, callbacks.size)
            assertEquals(wire.toList(), callbacks.single().toList())
        }
    }

    @Test
    fun ordinaryReadsStayBatchedAndOnlyCountedBytesReachTheCore() {
        val wire = "%end 1 2 1\n%layout-change @5 shape\n"
        val callbacks = mutableListOf<String>()
        val reader = TmuxAuthorityWireFeed { callbacks += it.decodeToString(); CoreCallResult.Accepted }
        val bytes = (wire + "unused socket buffer").encodeToByteArray()
        assertEquals(CoreCallResult.Accepted, reader.feed(bytes, wire.length, false))
        assertEquals(listOf(wire), callbacks)
    }

    @Test
    fun aClaimStartingDuringASplitTokenUsesTheFastPathsPrefix() {
        for (token in listOf("%end", "%error", "%layout-change", "%session-window-changed", "%window-pane-changed", "%session-changed")) {
            for (cut in 1 until token.length) {
                val callbacks = mutableListOf<String>()
                val reader = TmuxAuthorityWireFeed { callbacks += it.decodeToString(); CoreCallResult.Accepted }
                val first = ("%output %7 text\n".repeat(1000) + token.take(cut)).encodeToByteArray()
                // Bytes beyond count include an LF: they cannot reset the
                // real partial token that the next read must finish.
                val buffer = first + "ignored\n".encodeToByteArray()
                assertEquals(CoreCallResult.Accepted, reader.feed(buffer, first.size, false))
                assertEquals(1, callbacks.size)
                callbacks.clear()
                val boundary = token.drop(cut) + " 1 2 1\n"
                val tail = "%output %7 tail\n"
                val second = (boundary + tail).encodeToByteArray()
                assertEquals(CoreCallResult.Accepted, reader.feed(second, second.size, true))
                assertEquals("token=$token cut=$cut", listOf(boundary, tail), callbacks)
            }
        }
    }

    @Test
    fun fastPathContinuesPartialLinesAndResetsAtTheLastLf() {
        for (prefix in listOf("%output ", "x".repeat(40), "%end ", "%end\r")) {
            val callbacks = mutableListOf<String>()
            val reader = TmuxAuthorityWireFeed { callbacks += it.decodeToString(); CoreCallResult.Accepted }
            for (part in listOf(prefix, "%end", " body\n%layout-", "change")) {
                val bytes = part.encodeToByteArray()
                assertEquals(CoreCallResult.Accepted, reader.feed(bytes, bytes.size, false))
            }
            callbacks.clear()
            val end = " @5 shape\n"
            val tail = "%output %7 tail\n"
            val bytes = (end + tail).encodeToByteArray()
            assertEquals(CoreCallResult.Accepted, reader.feed(bytes, bytes.size, true))
            assertEquals("prefix=$prefix", listOf(end, tail), callbacks)
            callbacks.clear()
            assertEquals(CoreCallResult.Accepted, reader.feed(ByteArray(0), 0, false))
            assertEquals(emptyList<String>(), callbacks)
        }
    }

    @Test
    fun aRejectedBoundaryStopsBeforeAnyLaterBytes() {
        val first = "%error 1 2 1\n"
        val wire = (first + "%layout-change @5 shape\n").encodeToByteArray()
        val callbacks = mutableListOf<String>()
        val reader = TmuxAuthorityWireFeed { callbacks += it.decodeToString(); CoreCallResult.StaleHandle }
        assertEquals(CoreCallResult.StaleHandle, reader.feed(wire, wire.size, true))
        assertEquals(listOf(first), callbacks)
    }
}
