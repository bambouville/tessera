package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentEndpointBinding
import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentTerminalObservation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentOnDisplayPromptWatchTest {
    @Test fun selectedVisibleThreadWithoutWatchForwardsOnDisplay() = runBlocking {
        val rig = Rig()
        rig.run(untilMillis = 3_000)
        assertEquals(listOf(0L, 1_000L, 2_000L), rig.forwarded.map { it.first })
        for ((_, command) in rig.forwarded) {
            assertEquals("livePromptObservation", command.getString("kind"))
            assertTrue(command.getBoolean("onDisplay"))
            assertEquals(42L, command.getLong("observedGeneration"))
            assertFalse(command.has("observedLifecycleSequence"))
            assertEquals("binding-token", command.getString("bindingToken"))
            assertEquals("codex", command.getJSONObject("promptObservation").getJSONObject("providerID").getString("rawValue"))
            assertEquals("session", command.getJSONObject("threadID").getString("providerSessionID"))
        }
    }

    @Test fun unselectedHiddenOrBackgroundThreadWithoutWatchStopsAfterFrameWindow() = runBlocking {
        for (scenario in listOf("unselected", "hidden", "background")) {
            val rig = Rig().apply {
                nowMillis = 1_500
                lifecycleNanos = 0
                when (scenario) {
                    "unselected" -> ui = ui.copy(selectedThreadKey = "other", detail = detail("other"))
                    "hidden" -> openDetail = null
                    "background" -> foreground = false
                }
            }
            rig.run()
            assertEquals(scenario, 0, rig.inspections)
            assertTrue(scenario, rig.forwarded.isEmpty())
        }
    }

    @Test fun hiddenThreadKeepsOnlyTheOnePointFiveSecondFrameWindow() = runBlocking {
        val rig = Rig().apply { openDetail = null; lifecycleNanos = 0; sequence = 7 }
        rig.run()
        assertEquals(listOf(0L, 250L, 500L, 750L, 1_000L, 1_250L), rig.forwarded.map { it.first })
        assertEquals(1_500L, rig.nowMillis)
        assertTrue(rig.forwarded.all { !it.second.has("onDisplay") })
    }

    @Test fun watchedUndisplayedThreadForwardsWithoutOnDisplayKey() = runBlocking {
        val rig = Rig(watch = true).apply { openDetail = null }
        rig.run(untilMillis = 3_000)
        assertEquals(3, rig.forwarded.size)
        assertTrue(rig.forwarded.all { !it.second.has("onDisplay") })
    }

    @Test fun displayRequiresEnabledForegroundComposedSelectedDetail() {
        val rig = Rig()
        assertTrue(rig.displayed())
        rig.enabled = false
        assertFalse(rig.displayed())
        rig.enabled = true; rig.foreground = false
        assertFalse(rig.displayed())
        rig.foreground = true; rig.openDetail = null
        assertFalse(rig.displayed())
        rig.openDetail = "other"
        assertFalse(rig.displayed())
        rig.openDetail = KEY; rig.ui = rig.ui.copy(selectedThreadKey = "other")
        assertFalse(rig.displayed())
        rig.ui = rig.ui.copy(selectedThreadKey = KEY, detail = detail("other"))
        assertFalse(rig.displayed())
        rig.ui = rig.ui.copy(detail = null)
        assertTrue("the same projected detail fallback Compose uses", rig.displayed())
        rig.ui = rig.ui.copy(projectedDetails = emptyMap())
        assertFalse(rig.displayed())
    }

    @Test fun displayedOnlyWatchUsesExistingFastThenSlowCadence() = runBlocking {
        val rig = Rig().apply { lifecycleNanos = 0 }
        rig.run(untilMillis = 4_000)
        assertEquals(List(8) { 250L } + listOf(1_000L, 1_000L), rig.pauses)
        assertEquals(listOf(2_000L, 3_000L), rig.forwarded.takeLast(2).map { it.first })
    }

    @Test fun selectionAwayOrSurfaceHiddenEndsDisplayedOnlyWatch() = runBlocking {
        for (scenario in listOf("selection", "hidden")) {
            val rig = Rig().apply {
                onPause = {
                    if (scenario == "selection") ui = ui.copy(selectedThreadKey = "other", detail = detail("other"))
                    else openDetail = null
                }
            }
            rig.run()
            assertEquals(scenario, 1, rig.forwarded.size)
            assertEquals(scenario, 1, rig.inspections)
        }
    }

    @Test fun demandAndRouteLifetimeAreRecheckedAfterCapture() = runBlocking {
        for (scenario in listOf("selection", "hidden", "background", "disabled", "route", "owner")) {
            val rig = Rig().apply {
                onInspect = {
                    when (scenario) {
                        "selection" -> ui = ui.copy(selectedThreadKey = "other", detail = detail("other"))
                        "hidden" -> openDetail = null
                        "background" -> foreground = false
                        "disabled" -> enabled = false
                        "route" -> routeCurrent = false
                        "owner" -> ownerCurrent = false
                    }
                }
            }
            rig.run()
            assertEquals(scenario, 1, rig.inspections)
            assertTrue(scenario, rig.forwarded.isEmpty())
        }
    }

    @Test fun watchedCaptureLosingDisplayOmitsOnDisplay() = runBlocking {
        val rig = Rig(watch = true).apply { onInspect = { openDetail = null } }
        rig.run(untilMillis = 1_000)
        assertEquals(1, rig.forwarded.size)
        assertFalse(rig.forwarded.single().second.has("onDisplay"))
    }

    @Test fun unsafeOrBlankCapturesNeverForward() = runBlocking {
        for (scenario in listOf("unauthoritative", "truncated", "waited", "blank", "missing")) {
            val rig = Rig().apply {
                observation = when (scenario) {
                    "unauthoritative" -> observation!!.copy(authoritative = false)
                    "truncated" -> observation!!.copy(truncated = true)
                    "waited" -> observation!!.copy(captureWaitedForFrame = true)
                    "blank" -> observation!!.copy(visibleTail = "\n  \n".encodeToByteArray())
                    else -> null
                }
            }
            rig.run(untilMillis = 1_000)
            assertEquals(scenario, 1, rig.inspections)
            assertTrue(scenario, rig.forwarded.isEmpty())
        }
    }

    @Test fun lifecycleFencePrecedesCaptureAndReplacesGeneration() = runBlocking {
        val rig = Rig().apply { sequence = 7; onInspect = { sequence = 8; generation = 43 } }
        rig.run(untilMillis = 1_000)
        val command = rig.forwarded.single().second
        assertEquals(7L, command.getLong("observedLifecycleSequence"))
        assertFalse(command.has("observedGeneration"))
    }

    @Test fun missingFenceSkipsCaptureAndForwarding() = runBlocking {
        val rig = Rig().apply { generation = null }
        rig.run(untilMillis = 1_000)
        assertEquals(0, rig.inspections)
        assertTrue(rig.forwarded.isEmpty())
    }

    @Test fun forwardedCaptureKeepsWholeBottomRowsAndBoundsCursor() = runBlocking {
        val rig = Rig().apply {
            observation = observation!!.copy(
                visibleTail = ("x".repeat(16_384) + "\nWhich database?\n1. Postgres").encodeToByteArray(),
                currentCursorLine = "é".repeat(2_000),
            )
        }
        rig.run(untilMillis = 1_000)
        val capture = rig.forwarded.single().second.getJSONObject("promptObservation")
        assertEquals("Which database?\n1. Postgres", capture.getString("visibleText"))
        assertEquals("é".repeat(1_024), capture.getString("currentCursorLine"))
    }

    @Test fun aStyledTmuxCaptureForwardsItsCellsWithinTheBound() = runBlocking {
        // `capture-pane -e -N` styles every cell run; the bound counts cells.
        val rows = (1..40).map { "  $it. " + "option".repeat(12) }
        val styled = rows.joinToString("\n") { row -> row.map { "\u001b[38;5;246m$it" }.joinToString("") + "\u001b[39m" }
        assertTrue(styled.encodeToByteArray().size > 16_384)
        val rig = Rig().apply {
            observation = observation!!.copy(visibleTail = styled.encodeToByteArray())
        }
        rig.run(untilMillis = 1_000)
        val capture = rig.forwarded.single().second.getJSONObject("promptObservation")
        assertEquals(rows.joinToString("\n"), capture.getString("visibleText"))
    }

    @Test fun cancelledCaptureCannotForwardEvenIfInspectionFinishes() = runBlocking {
        val rig = Rig()
        val reading = CompletableDeferred<Unit>()
        val finish = CompletableDeferred<Unit>()
        rig.onInspect = { withContext(NonCancellable) { reading.complete(Unit); finish.await() } }
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            try { rig.run() } catch (_: CancellationException) { /* Expected watch cancellation. */ }
        }
        reading.await()
        job.cancel()
        finish.complete(Unit)
        job.join()
        assertTrue(job.isCancelled)
        assertTrue(rig.forwarded.isEmpty())
    }

    /** Fake capture/command delivery with a virtual clock; no native runtime or host. */
    private class Rig(watch: Boolean = false) {
        val selected = detail(KEY, watch)
        var ui = AgentCenterUiState(selectedThreadKey = KEY, detail = selected, projectedDetails = mapOf(KEY to selected))
        var enabled = true
        var foreground = true
        var openDetail: String? = KEY
        var routeCurrent = true
        var ownerCurrent = true
        var nowMillis = 0L
        var lifecycleNanos: Long? = null
        var sequence: Long? = null
        var generation: Long? = 42
        var inspections = 0
        var observation: AgentTerminalObservation? = AgentTerminalObservation(
            AgentEndpointBinding(AgentSessionKey("carrier", 1), HOST, AgentEndpointTransport.SSH_TMUX),
            "Which database?\n1. Postgres".encodeToByteArray(), truncated = false, authoritative = true,
        )
        var onInspect: suspend () -> Unit = {}
        var onPause: () -> Unit = {}
        val forwarded = mutableListOf<Pair<Long, JSONObject>>()
        val pauses = mutableListOf<Long>()

        fun displayed() = isAgentThreadDisplayed(KEY, ui, enabled, foreground, openDetail)

        suspend fun run(untilMillis: Long = 5_000) = watchAgentLivePrompt(
            JSONObject().put("hostID", HOST).put("providerID", JSONObject().put("rawValue", "codex"))
                .put("providerSessionID", "session"),
            "binding-token", "codex",
            current = {
                if (nowMillis >= untilMillis || !enabled || !foreground || !routeCurrent || !ownerCurrent) null
                else AgentLivePromptWatchSnapshot(ui.projectedDetails[KEY]?.row?.livePromptWatch == true,
                    displayed(), lifecycleNanos, sequence, generation)
            },
            inspect = { inspections++; onInspect(); observation },
            forward = { forwarded += nowMillis to it },
            nanoTime = { nowMillis * 1_000_000 },
            pause = { pauses += it; nowMillis += it; onPause() },
        )
    }

    private companion object {
        const val HOST = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        const val KEY = "$HOST:codex:session"
        fun detail(key: String, watch: Boolean = false) = AgentThreadDetail(
            AgentThreadRow(key, "Thread", "Codex", null, null, "working", "none", "", null,
                false, false, false, false, hostID = HOST, providerID = "codex", providerSessionID = "session",
                livePromptWatch = watch),
            emptyList(), emptyList(), emptyList(), null, false, deliveryGeneration = 42,
        )
    }
}
