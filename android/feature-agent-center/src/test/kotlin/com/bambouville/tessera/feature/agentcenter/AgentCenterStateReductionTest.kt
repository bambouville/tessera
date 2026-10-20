package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Test
import com.bambouville.tessera.core.bridge.SharedAgentValue
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNull

/**
 * Compose compares an [AgentThreadDetail] (it holds Lists) by identity. A
 * reducer that re-creates an unchanged detail makes the selected transcript
 * recompose on every other agent's list tick.
 */
class AgentCenterStateReductionTest {
    private fun row(key: String, title: String = "Title $key", status: String = "idle", preview: String? = null, activity: Long? = null) =
        AgentThreadRow(key = key, title = title, provider = "Claude", model = null, preview = preview, status = status,
            attention = "none", location = "", queuedCount = null, isFork = false, actionAvailable = true,
            spawnAvailable = false, forkAvailable = false, lastActivityMillis = activity, titleProvenance = "generated",
            titleSeed = "seed $key")

    private fun detail(row: AgentThreadRow) = AgentThreadDetail(row,
        live = listOf(AgentBlock("", "hello from ${row.key}", kind = "text", recordID = "${row.key}-1")),
        activity = emptyList(), changes = emptyList(), binding = null, hasMore = false)

    private val selected = detail(row("a"))
    private val sibling = detail(row("b", status = "working"))
    private val state = AgentCenterUiState(loading = false, threads = listOf(selected.row, sibling.row), selectedThreadKey = "a",
        detail = selected, projectedDetails = mapOf("a" to selected, "b" to sibling))

    private fun AgentCenterUiState.tick(rows: List<AgentThreadRow>) = withListSnapshot(rows, emptyList(),
        resolveAgentHistoricalSelection(selectedThreadKey, projectedDetails.keys, rows.map { it.key }, emptySet()))

    @Test fun siblingListTickKeepsEveryUnchangedDetailInstance() {
        // Core re-lists every row as fresh values; only summaries moved.
        val rows = listOf(selected.row.copy(lastActivityMillis = 2_000L),
            sibling.row.copy(status = "idle", preview = "done", lastActivityMillis = 3_000L))
        val next = state.tick(rows)
        assertEquals(rows, next.threads)
        assertSame(selected, next.detail)
        assertSame(selected, next.projectedDetails["a"])
        assertSame(sibling, next.projectedDetails["b"])
    }

    @Test fun listedTitleChangeRefreshesTheHeaderAndKeepsThePage() {
        val next = state.tick(listOf(selected.row.copy(title = "Renamed", titleProvenance = "native"), sibling.row.copy()))
        val shown = next.detail!!
        assertNotSame(selected, shown)
        assertEquals("Renamed", shown.row.title)
        assertEquals("native", shown.row.titleProvenance)
        assertSame(selected.live, shown.live)
        assertEquals(shown, next.projectedDetails["a"])
        assertSame(sibling, next.projectedDetails["b"])
    }

    @Test fun siblingThreadSnapshotLeavesTheSelectedDetail() {
        val update = detail(row("b", status = "waitingForInput", preview = "needs input"))
        val next = state.withThreadSnapshot(update)
        assertSame(selected, next.detail)
        assertSame(update, next.projectedDetails["b"])
        assertEquals(update.row, next.threads[1])
        assertSame(state.threads, state.withThreadSnapshot(detail(sibling.row)).threads)
    }
    private fun promptDetail(): AgentThreadDetail {
        val signature = "1 question waiting"
        return selected.copy(binding = SharedAgentValue.ObjectValue(mapOf(
            "paneID" to SharedAgentValue.StringValue("%2"))), prompt = AgentPrompt(
            "1 question waiting", null, livePromptActionToken(signature), emptyList(),
            fresh = AgentFreshPrompt(signature, emptyList(), "deferred"), kind = "deferred"))
    }

    @Test fun samePromptSnapshotKeepsItsParsedDisplayCapability() {
        val shown = promptDetail()
        val current = state.copy(detail = shown, projectedDetails = mapOf("a" to shown))
        val snapshot = shown.copy(prompt = shown.prompt!!.copy(fresh = null))
        val next = current.withThreadSnapshot(snapshot)
        assertTrue(next.detail!!.canAnswerPrompt())
        assertSame(shown.prompt!!.fresh, next.projectedDetails["a"]!!.prompt!!.fresh)
    }

    @Test fun changedPromptOrBindingCannotInheritDisplayCapability() {
        val shown = promptDetail()
        val current = state.copy(detail = shown, projectedDetails = mapOf("a" to shown))
        val cold = shown.copy(prompt = shown.prompt!!.copy(fresh = null))
        val changed = listOf(cold.copy(binding = null),
            cold.copy(prompt = cold.prompt!!.copy(actionToken = "new-token")),
            cold.copy(prompt = cold.prompt!!.copy(kind = "question")),
            cold.copy(row = cold.row.copy(actionAvailable = false)), cold.copy(prompt = null))
        changed.forEach { snapshot -> assertNull(current.withThreadSnapshot(snapshot).detail!!.prompt?.fresh) }
    }

}
