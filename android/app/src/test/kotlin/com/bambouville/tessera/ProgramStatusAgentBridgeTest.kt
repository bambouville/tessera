package com.bambouville.tessera

import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.feature.agentcenter.AgentCenterUiState
import com.bambouville.tessera.feature.agentcenter.AgentThreadDetail
import com.bambouville.tessera.feature.agentcenter.AgentThreadRow
import com.bambouville.tessera.feature.session.ProgramStatusAgentPane
import com.bambouville.tessera.feature.session.ProgramStatusPaneRef
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProgramStatusAgentBridgeTest {
    @Test
    fun projectsAllFourTransportsFromExistingLiveCarriers() {
        val transports = listOf("ssh", "mosh", "sshTmux", "moshTmux")
        val rows = transports.mapIndexed { index, _ -> row("thread$index", "host$index", "needsYou") }
        val state = AgentCenterUiState(
            threads = rows,
            projectedDetails = rows.mapIndexed { index, row ->
                row.key to detail(row, transports[index], pane = "%7", window = "@3")
            }.toMap(),
        )

        val input = programStatusAgentInput(state, rows.associate { it.hostID to "live" })

        assertEquals(4, input.waiting)
        assertEquals(0, input.finished)
        rows.forEachIndexed { index, row ->
            val raw = index < 2
            assertEquals(ProgramStatusAgentPane(if (raw) null else 3, true, false),
                input.panes[ProgramStatusPaneRef(row.hostID, if (raw) null else 7)])
        }
    }

    @Test
    fun countsReducedAttentionWithoutInferringFromStatusOrMissingBindings() {
        val rows = listOf(
            row("waiting", attention = "needsYou"),
            row("finished", attention = "unreadCompletion"),
            row("working", attention = "none").copy(status = "waitingForInput"),
            row("seen", attention = "none").copy(status = "finished"),
        )

        val input = programStatusAgentInput(AgentCenterUiState(threads = rows), mapOf("host" to "live"))

        assertEquals(1, input.waiting)
        assertEquals(1, input.finished)
        assertTrue(input.panes.isEmpty())
    }

    @Test
    fun rejectsEndedReplacedAndOtherHostBindingsButKeepsGlobalAttention() {
        val row = row("waiting", attention = "needsYou")
        val state = AgentCenterUiState(threads = listOf(row), projectedDetails = mapOf(row.key to detail(row, "sshTmux")))

        listOf(emptyMap(), mapOf("host" to "replacement"), mapOf("other" to "live")).forEach { live ->
            val input = programStatusAgentInput(state, live)
            assertEquals(1, input.waiting)
            assertTrue(input.panes.isEmpty())
        }
    }

    @Test
    fun usesSelectedDetailWhenProjectionHasNoBindingAndUsesCurrentRowAttention() {
        val row = row("thread", attention = "needsYou")
        val oldRow = row.copy(attention = "unreadCompletion")
        val state = AgentCenterUiState(
            threads = listOf(row),
            projectedDetails = mapOf(row.key to detail(oldRow, "sshTmux").copy(binding = null)),
            detail = detail(oldRow, "sshTmux", pane = "7", window = "3"),
        )

        val pane = programStatusAgentInput(state, mapOf("host" to "live")).panes[ProgramStatusPaneRef("host", 7)]!!

        assertEquals(3, pane.windowId)
        assertTrue(pane.needsInput)
        assertFalse(pane.unreadCompletion)
    }

    @Test
    fun malformedTmuxPaneNeverBecomesRawAndUnknownTransportHasNoCue() {
        val row = row("thread")
        listOf("", "%", "%-1", "%1.5", "%2147483648", "@7").forEach { pane ->
            val state = AgentCenterUiState(threads = listOf(row), detail = detail(row, "sshTmux", pane = pane))
            assertTrue(programStatusAgentInput(state, mapOf("host" to "live")).panes.isEmpty())
        }
        val state = AgentCenterUiState(threads = listOf(row), detail = detail(row, "unknown"))
        assertTrue(programStatusAgentInput(state, mapOf("host" to "live")).panes.isEmpty())
    }

    @Test
    fun multipleThreadsOnOnePaneRetainBothAttentionVerdictsInEitherOrder() {
        val waiting = row("waiting", attention = "needsYou")
        val finished = row("finished", attention = "unreadCompletion")
        listOf(listOf(waiting, finished), listOf(finished, waiting)).forEach { rows ->
            val state = AgentCenterUiState(threads = rows,
                projectedDetails = rows.associate { it.key to detail(it, "moshTmux") })
            val input = programStatusAgentInput(state, mapOf("host" to "live"))
            assertEquals(1, input.waiting)
            assertEquals(1, input.finished)
            assertEquals(mapOf(ProgramStatusPaneRef("host", 7) to ProgramStatusAgentPane(3, true, true)), input.panes)
        }
    }

    private fun row(key: String, host: String = "host", attention: String = "none") = AgentThreadRow(
        key = key, title = key, provider = "codex", model = null, preview = null, status = "working",
        attention = attention, location = "terminal", queuedCount = null, isFork = false,
        actionAvailable = false, spawnAvailable = false, forkAvailable = false, hostID = host,
    )

    private fun detail(row: AgentThreadRow, transport: String, pane: String = "%7", window: String = "@3") =
        AgentThreadDetail(
            row = row, live = emptyList(), activity = emptyList(), changes = emptyList(), hasMore = false,
            binding = SharedAgentValue.ObjectValue(mapOf(
                "liveSessionID" to SharedAgentValue.StringValue("live"),
                "transport" to SharedAgentValue.StringValue(transport),
                "paneID" to SharedAgentValue.StringValue(pane),
                "windowID" to SharedAgentValue.StringValue(window),
            )),
        )
}
