package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Android only applies Core's descriptors; the Swift suite tests grouping semantics. */
class AgentTranscriptGroupingTest {
    private val blocks = listOf(
        AgentBlock("", "plan", "text", "m1"),
        AgentBlock("Bash", "pwd", "toolCall", "m1"),
        AgentBlock("result", "/", "toolResult", "m2"),
        AgentBlock("", "done", "text", "m3"),
    )
    private val run = AgentToolRunDescriptor("m1#1", listOf("m1#1", "m2#0"), "1 tool call", "latest: Bash · pwd")

    @Test fun coreDescriptorCollapsesAndPreservesEveryDetail() {
        val items = agentTranscriptItems(blocks, listOf(run))
        assertEquals(listOf("m1#0", "m1#1", "m3#0"), items.map { it.key })
        val group = items[1] as AgentTranscriptItem.ToolRun
        assertEquals(blocks.subList(1, 3), group.entries.map { it.block })
        assertEquals(run.summaryTitle, group.summaryTitle)
        assertEquals(run.latestSummary, group.latestSummary)
    }

    @Test fun missingOrStaleDescriptorNeverHidesContent() {
        for (runs in listOf(emptyList(), listOf(run.copy(entryIDs = listOf("m1#1", "missing"))), listOf(run.copy(entryIDs = emptyList())))) {
            val items = agentTranscriptItems(blocks, runs)
            assertTrue(items.all { it is AgentTranscriptItem.Block })
            assertEquals(blocks, items.map { (it as AgentTranscriptItem.Block).block })
        }
    }

    @Test fun olderPrependAndLiveAppendPreserveGroupIdentity() {
        val before = agentTranscriptItems(blocks.take(3), listOf(run)).last()
        val appended = blocks.take(3) + AgentBlock("Read", "x", "toolCall", "m4")
        val after = agentTranscriptItems(listOf(AgentBlock("", "older", "text", "old")) + appended,
            listOf(run.copy(entryIDs = run.entryIDs + "m4#0", summaryTitle = "2 tool calls", latestSummary = "latest: Read · x"))).last()
        assertEquals(before.key, after.key)
        assertEquals("latest: Read · x", (after as AgentTranscriptItem.ToolRun).latestSummary)
    }

    private fun tool(id: String) = AgentBlock("Read", id, "toolCall", id)
    private fun text(id: String) = AgentBlock("", id, "text", id)
    private fun runOf(vararg ids: String) =
        AgentToolRunDescriptor("${ids.first()}#0", ids.map { "$it#0" }, "${ids.size} tool calls", "latest: Read · ${ids.last()}")
    private fun keysOf(items: List<AgentTranscriptItem>) = items.map { it.key }

    @Test fun olderToolsMergingIntoTheTopRunKeepItsRowKeyAndExpansion() {
        val keys = AgentTranscriptRowKeys()
        val first = keys.apply(agentTranscriptItems(listOf(tool("t60"), tool("t61"), text("m")), listOf(runOf("t60", "t61"))))
        // The UI expands a run by recording every entry key it showed.
        val expanded = (first[0] as AgentTranscriptItem.ToolRun).entries.map { it.key }
        assertEquals(listOf("t60#0", "agent-tool-detail:t60#0", "agent-tool-detail:t61#0", "m#0"),
            keysOf(agentTranscriptDisplayItems(first, expanded)))

        // Core now keys the run by its new first entry, t58#0.
        val older = listOf(text("o"), tool("t58"), tool("t59"), tool("t60"), tool("t61"), text("m"))
        val second = keys.apply(agentTranscriptItems(older, listOf(runOf("t58", "t59", "t60", "t61"))))
        assertEquals(listOf("o#0", "t60#0", "m#0"), keysOf(second))
        val run = second[1] as AgentTranscriptItem.ToolRun
        assertEquals(listOf("t58#0", "t59#0", "t60#0", "t61#0"), run.entries.map { it.key })
        assertEquals("4 tool calls", run.summaryTitle)
        assertEquals(listOf("o#0", "t60#0", "agent-tool-detail:t58#0", "agent-tool-detail:t59#0",
            "agent-tool-detail:t60#0", "agent-tool-detail:t61#0", "m#0"),
            keysOf(agentTranscriptDisplayItems(second, expanded)))
    }

    @Test fun aWholePageCoalescingIntoTheTopRunLeavesRowsAndFirstKeyUnchanged() {
        val keys = AgentTranscriptRowKeys()
        val tail = listOf(tool("t60"), tool("t61"), text("m"))
        val first = keys.apply(agentTranscriptItems(tail, listOf(runOf("t60", "t61"))))
        val page = (50..59).map { tool("t$it") }
        val merged = agentTranscriptItems(page + tail, listOf(runOf(*(50..61).map { "t$it" }.toTypedArray())))
        val second = keys.apply(merged)
        assertEquals(keysOf(first), keysOf(second))
        assertNotSame(first[0], second[0])
        assertEquals(12, (second[0] as AgentTranscriptItem.ToolRun).entries.size)
        // A repeated snapshot keeps the instance so the card can skip recomposition.
        assertSame(second[0], keys.apply(agentTranscriptItems(page + tail, listOf(runOf(*(50..61).map { "t$it" }.toTypedArray()))))[0])
    }

    @Test fun anAbsorbedStandaloneCardLendsItsRowKeyToTheRun() {
        val keys = AgentTranscriptRowKeys()
        val thinking = AgentBlock("thinking", "plan", "thinking", "th")
        assertEquals(listOf("th#0", "m#0"), keysOf(keys.apply(agentTranscriptItems(listOf(thinking, text("m")), emptyList()))))
        // Core groups thinking with adjacent older tool activity.
        val older = listOf(tool("t1"), thinking, text("m"))
        val run = AgentToolRunDescriptor("t1#0", listOf("t1#0", "th#0"), "1 tool call", "latest: Read · t1")
        assertEquals(listOf("th#0", "m#0"), keysOf(keys.apply(agentTranscriptItems(older, listOf(run)))))
        // Further older activity, including another thinking card, keeps it.
        val grown = listOf(thinking.copy(recordID = "th2"), tool("t0"), tool("t1"), thinking, text("m"))
        val merged = AgentToolRunDescriptor("th2#0", listOf("th2#0", "t0#0", "t1#0", "th#0"), "2 tool calls", null)
        assertEquals(listOf("th#0", "m#0"), keysOf(keys.apply(agentTranscriptItems(grown, listOf(merged)))))
    }

    @Test fun rememberedRowKeysNeverDuplicateAnotherRowsKey() {
        val keys = AgentTranscriptRowKeys()
        assertEquals(listOf("p#0"), keysOf(keys.apply(agentTranscriptItems(listOf(tool("p"), tool("q"), tool("r")), listOf(runOf("p", "q", "r"))))))
        // An unexpected regroup: q's remembered key p#0 is now another run's own key.
        val regrouped = keys.apply(agentTranscriptItems(listOf(tool("q"), text("z"), tool("p"), tool("r")),
            listOf(runOf("q"), runOf("p", "r"))))
        assertEquals(listOf("q#0", "z#0", "p#0"), keysOf(regrouped))
        // Two runs remembering the same vanished key: only the first inherits it.
        assertEquals(listOf("p#0"), keysOf(keys.apply(agentTranscriptItems(listOf(tool("p"), tool("q"), tool("r")), listOf(runOf("p", "q", "r"))))))
        val split = keys.apply(agentTranscriptItems(listOf(tool("q"), text("z"), tool("r")), listOf(runOf("q"), runOf("r"))))
        assertEquals(listOf("p#0", "z#0", "r#0"), keysOf(split))
        // A standalone card keeps its own key even when a run remembers it.
        assertEquals(listOf("p#0"), keysOf(keys.apply(agentTranscriptItems(listOf(tool("p"), tool("q")), listOf(runOf("p", "q"))))))
        val demoted = keys.apply(agentTranscriptItems(listOf(AgentBlock("thinking", "p", "thinking", "p"), text("z"), tool("q")),
            listOf(runOf("q"))))
        assertEquals(listOf("p#0", "z#0", "q#0"), keysOf(demoted))
    }
}
