package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.CoreCallResult

/**
 * The runtime ABI projects the final snapshot of one feed. While a claim
 * judges geometry, a reply and a later layout in the same socket read must
 * reach separate callbacks, just as two reads would. Split at reply ends
 * and geometry notifications; ordinary output keeps its existing batching.
 * The prefix buffer belongs to the reader, so a token split across socket
 * reads still identifies the same boundary without allocating per line.
 */
internal class TmuxAuthorityWireFeed(private val feed: (ByteArray) -> CoreCallResult) {
    private val prefix = ByteArray(32)
    private var prefixLength = 0
    private var prefixComplete = false

    fun feed(bytes: ByteArray, count: Int, preserveGeometryOrder: Boolean): CoreCallResult {
        if (!preserveGeometryOrder) {
            // Ordinary output keeps one feed and one copy. Only the trailing
            // partial line can cross into a claim's next read, so skip every
            // complete line and inspect at most the prefix buffer after the
            // last LF. With no LF, continue the prefix from the prior read.
            var lineStart = count
            while (lineStart > 0 && bytes[lineStart - 1] != LF) lineStart -= 1
            if (lineStart > 0) {
                prefixLength = 0
                prefixComplete = false
            }
            var index = lineStart
            while (index < count && !prefixComplete) notePrefixByte(bytes[index++])
            return if (count > 0) feed(bytes.copyOfRange(0, count)) else CoreCallResult.Accepted
        }
        var start = 0
        for (index in 0 until count) {
            val byte = bytes[index]
            if (byte == LF) {
                val boundary = isGeometryBoundary()
                prefixLength = 0
                prefixComplete = false
                if (boundary) {
                    val result = feed(bytes.copyOfRange(start, index + 1))
                    if (result != CoreCallResult.Accepted) return result
                    start = index + 1
                }
            } else if (!prefixComplete) notePrefixByte(byte)
        }
        return if (start < count) feed(bytes.copyOfRange(start, count)) else CoreCallResult.Accepted
    }

    private fun notePrefixByte(byte: Byte) {
        if (byte == SPACE || byte == CR || prefixLength == prefix.size) prefixComplete = true
        else prefix[prefixLength++] = byte
    }

    private fun isGeometryBoundary(): Boolean = GEOMETRY_BOUNDARIES.any { token ->
        if (token.size != prefixLength) false
        else {
            var matches = true
            for (index in token.indices) if (prefix[index] != token[index]) { matches = false; break }
            matches
        }
    }

    private companion object {
        const val LF: Byte = 10
        const val CR: Byte = 13
        const val SPACE: Byte = 32
        val GEOMETRY_BOUNDARIES = listOf(
            "%end", "%error", "%layout-change", "%session-window-changed",
            "%window-pane-changed", "%session-changed",
        ).map { it.toByteArray(Charsets.US_ASCII) }
    }
}
