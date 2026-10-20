package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Locale

class AgentContextMeterTest {
    private val row = AgentThreadRow(key = "test", title = "title", provider = "Claude",
        model = null, preview = null, status = "working", attention = "none", location = "",
        queuedCount = null, isFork = false, actionAvailable = false, spawnAvailable = false, forkAvailable = false)

    @Test fun compactCountRoundsHalfUpAndPromotesUnits() {
        for ((count, expected) in listOf(-1L to "0", 0L to "0", 950L to "950", 999L to "999",
            1_000L to "1k", 1_499L to "1k", 1_500L to "2k", 84_320L to "84k", 84_500L to "85k",
            999_499L to "999k", 999_500L to "1M", 1_049_999L to "1M", 1_050_000L to "1.1M",
            1_200_000L to "1.2M", 9_007_199_254_740_991L to "9007199254.7M")) {
            assertEquals(expected, compactAgentTokenCount(count, Locale.US))
        }
    }

    @Test fun compactCountUsesLocaleDecimalSeparator() {
        for ((locale, expected) in listOf(Locale.US to "1.2M", Locale.GERMANY to "1,2M")) {
            assertEquals(expected, compactAgentTokenCount(1_200_000, locale))
            assertEquals("1M", compactAgentTokenCount(999_500, locale))
            assertEquals("85k", compactAgentTokenCount(84_500, locale))
        }
    }

    @Test fun percentThenTokensThenLinesEvenWhenFinished() {
        for (status in listOf("working", "idle", "finished")) {
            val tokens = row.copy(status = status, contextUsedTokens = "84320", linesAdded = "14", linesRemoved = "3")
            assertEquals("84k", tokens.compactContextTokens())
            assertEquals("84k tokens", tokens.summaryMeter("84k tokens"))
            val percent = tokens.copy(contextPercent = "15.0")
            assertNull(percent.compactContextTokens())
            assertEquals("15% context", percent.summaryMeter(null))
            assertEquals("+14 −3 changes", tokens.copy(contextUsedTokens = null).summaryMeter(null))
        }
        assertEquals("84k tokens · $1.20", row.copy(contextUsedTokens = "84320", totalCost = "1.20").summaryMeter("84k tokens"))
        assertNull(row.summaryMeter(null))
    }

    @Test fun absentZeroNegativeAndInvalidTokensHideTheFallback() {
        for (value in listOf(null, "0", "-1", "bad", "1.5", "9223372036854775808")) {
            assertNull(row.copy(contextUsedTokens = value).compactContextTokens())
        }
    }
}
