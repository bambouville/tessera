package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedProgramStatusAttention
import com.bambouville.tessera.core.bridge.SharedProgramStatusBlockedKind
import com.bambouville.tessera.core.bridge.SharedProgramStatusEntry
import com.bambouville.tessera.core.bridge.SharedProgramStatusSnapshot
import com.bambouville.tessera.core.bridge.SharedProgramStatusState
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminal
import com.bambouville.tessera.core.bridge.SharedProgramStatusTerminalSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxPane
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ProgramStatusCenterTest {
    private val raw = SharedProgramStatusTerminal.Raw
    private val host = "host-1"
    private val approval = SharedProgramStatusBlockedKind.PERMISSION
    private val question = SharedProgramStatusBlockedKind.QUESTION

    /** Fixtures carry Core's verdict; these tests never classify OSC records. */
    private fun entry(
        state: SharedProgramStatusState,
        terminal: SharedProgramStatusTerminal = raw,
        kind: SharedProgramStatusBlockedKind? = null,
        attention: SharedProgramStatusAttention? = null,
        historical: Boolean = false,
        progress: Int? = null,
        app: String? = null,
        title: String? = null,
        token: Long? = null,
    ) = SharedProgramStatusEntry(
        terminal = terminal,
        idPath = emptyList(),
        state = state,
        kind = kind,
        progress = progress,
        app = app,
        title = title,
        message = null,
        isHistorical = historical,
        isUnreadResult = token != null,
        updateToken = 1,
        resultToken = token,
        attention = attention,
    )

    private fun terminal(entry: SharedProgramStatusEntry) = SharedProgramStatusTerminalSnapshot(
        terminal = entry.terminal,
        entries = listOf(entry),
        primaryEntry = entry,
        latestUnreadResultToken = entry.resultToken,
    )

    private fun state(
        vararg terminals: SharedProgramStatusTerminalSnapshot,
        label: String = "devbox",
        locations: Map<Int, ProgramStatusPaneLocation> = emptyMap(),
    ) = ProgramStatusSessionState(label, SharedProgramStatusSnapshot(1, terminals.toList()), locations)

    private fun blocked(pane: Int? = null, kind: SharedProgramStatusBlockedKind? = approval) = terminal(entry(
        SharedProgramStatusState.BLOCKED, pane?.let { SharedProgramStatusTerminal.Pane(it) } ?: raw,
        kind = kind, attention = SharedProgramStatusAttention.NEEDS_INPUT,
    ))

    private fun done(pane: Int? = null, token: Long? = 7) = terminal(entry(
        SharedProgramStatusState.DONE, pane?.let { SharedProgramStatusTerminal.Pane(it) } ?: raw,
        attention = SharedProgramStatusAttention.FINISHED.takeIf { token != null }, token = token,
    ))

    private fun failed(pane: Int? = null) = terminal(entry(
        SharedProgramStatusState.ERROR, pane?.let { SharedProgramStatusTerminal.Pane(it) } ?: raw,
        attention = SharedProgramStatusAttention.FAILED, token = 8,
    ))

    @Test
    fun nativeLiveStateOwnsTheAgentCue() {
        val working = terminal(entry(SharedProgramStatusState.WORKING))
        assertNull(ProgramAttentionMerge.attention(false, true, working))
        assertNull(ProgramAttentionMerge.attention(true, false, working))
        assertEquals(ProgramAttention(ProgramAttentionTone.NEEDS_INPUT, approval),
            ProgramAttentionMerge.attention(true, false, blocked()))
        assertEquals(ProgramAttention(ProgramAttentionTone.FAILED),
            ProgramAttentionMerge.attention(false, true, failed()))
        assertEquals(ProgramAttention(ProgramAttentionTone.NEEDS_INPUT),
            ProgramAttentionMerge.attention(true, false, done()))
        assertEquals(ProgramAttention(ProgramAttentionTone.FINISHED),
            ProgramAttentionMerge.attention(false, true, null))
        assertNull(ProgramAttentionMerge.attention(false, false, terminal(entry(SharedProgramStatusState.IDLE))))
    }

    @Test
    fun anyLiveChildOwnsCueButHistoricalWorkDoesNot() {
        val result = done()
        val liveChild = entry(SharedProgramStatusState.WORKING).copy(idPath = listOf("child"))
        assertEquals(ProgramAttention(ProgramAttentionTone.FINISHED),
            ProgramAttentionMerge.attention(true, false, result.copy(entries = result.entries + liveChild)))
        val historical = terminal(entry(SharedProgramStatusState.WORKING, historical = true))
        assertEquals(ProgramAttention(ProgramAttentionTone.FINISHED),
            ProgramAttentionMerge.attention(false, true, historical))
        // A historical blocked record carries no cue; agent input is the fallback.
        val oldBlocked = blocked().primaryEntry!!.copy(isHistorical = true, attention = null)
        assertEquals(ProgramAttention(ProgramAttentionTone.NEEDS_INPUT),
            ProgramAttentionMerge.attention(true, false, terminal(oldBlocked)))
        // Synthetic equal-tone input isolates native-first selection outside the
        // live-state override; valid Core snapshots use the case above instead.
        val historicalBlocked = blocked().let { snapshot ->
            val old = snapshot.primaryEntry!!.copy(isHistorical = true)
            snapshot.copy(entries = listOf(old), primaryEntry = old)
        }
        assertEquals(ProgramAttention(ProgramAttentionTone.NEEDS_INPUT, approval),
            ProgramAttentionMerge.attention(true, false, historicalBlocked))
    }

    @Test
    fun genericProgramsCountWithoutAgentCenter() {
        val sessions = mapOf(host to state(blocked(kind = question), failed(2), done(3)))
        val counts = ProgramStatusQueries.counts(sessions)
        assertEquals(1, counts.needsInput)
        assertEquals(1, counts.failed)
        assertEquals(1, counts.finished)
        assertEquals(3, counts.total)
        assertEquals(ProgramAttentionTone.NEEDS_INPUT, counts.tone)
        assertEquals(question, counts.uniformNeedsInputKind)
        assertEquals(listOf(CountKind.NEED_INPUT, CountKind.FAILED, CountKind.FINISHED),
            ProgramStatusWordsModel.countParts(counts).map { it.kind })
        assertEquals(CountKind.NEED_ANSWER, ProgramStatusWordsModel.countParts(counts, true).first().kind)
        assertEquals(counts, ProgramStatusQueries.sessionCounts(sessions, host))
        assertEquals(0, ProgramStatusQueries.counts(emptyMap()).total)
        assertNull(ProgramAttentionCounts().tone)
        assertEquals(ProgramAttentionTone.FAILED, ProgramAttentionCounts(failed = 1, finished = 2).tone)
        assertEquals(ProgramAttentionTone.FINISHED, ProgramAttentionCounts(finished = 2).tone)
    }

    @Test
    fun agentCountsAreReplacedByMergedVerdictsAndClamped() {
        val working = terminal(entry(SharedProgramStatusState.WORKING, SharedProgramStatusTerminal.Pane(1)))
        val sessions = mapOf(host to state(working, failed(2), done(3), blocked(4)))
        val agents = ProgramStatusAgentInput(waiting = 1, finished = 2, panes = mapOf(
            ProgramStatusPaneRef(host, 1) to ProgramStatusAgentPane(10, false, true),
            ProgramStatusPaneRef(host, 2) to ProgramStatusAgentPane(10, false, true),
            ProgramStatusPaneRef(host, 3) to ProgramStatusAgentPane(10, true, false),
        ))
        val counts = ProgramStatusQueries.counts(sessions, agents)
        assertEquals(2, counts.needsInput) // agent input beats done; native blocked adds one.
        assertEquals(1, counts.failed)
        assertEquals(0, counts.finished) // working suppresses one; failed replaces the other.
        assertNull(counts.uniformNeedsInputKind) // Initial agent waiting is generic.
        val inconsistent = agents.copy(waiting = 0, finished = 0)
        val clamped = ProgramStatusQueries.counts(sessions, inconsistent)
        assertEquals(1, clamped.needsInput) // Equal-tone agent input keeps the aggregate's count.
        assertEquals(0, clamped.finished)
        val waitingButNativeWorking = inconsistent.copy(panes = mapOf(
            ProgramStatusPaneRef(host, 1) to ProgramStatusAgentPane(10, true, false)))
        assertEquals(0, ProgramStatusQueries.counts(mapOf(host to state(working)), waitingButNativeWorking).needsInput)
        // An equal tone does not add a second count or replace the aggregate's generic kind.
        val sameTone = ProgramStatusAgentInput(waiting = 1, panes = mapOf(
            ProgramStatusPaneRef(host, null) to ProgramStatusAgentPane(null, true, false)))
        val equal = ProgramStatusQueries.counts(mapOf(host to state(blocked())), sameTone)
        assertEquals(1, equal.total)
        assertNull(equal.uniformNeedsInputKind)
        assertEquals(approval, ProgramStatusQueries.sessionCounts(mapOf(host to state(blocked())), host, sameTone)
            .uniformNeedsInputKind)
    }

    @Test
    fun uniformKindsProduceSpecificPartsAndMixedKindsProduceGenericParts() {
        val counts = ProgramAttentionCounts()
        counts.add(ProgramAttention(ProgramAttentionTone.NEEDS_INPUT, approval), 2)
        counts.add(ProgramAttention(ProgramAttentionTone.FINISHED))
        assertEquals(listOf(
            ProgramCountPart(CountKind.NEED_APPROVAL, 2, ProgramAttentionTone.NEEDS_INPUT),
            ProgramCountPart(CountKind.FINISHED, 1, ProgramAttentionTone.FINISHED),
        ), ProgramStatusWordsModel.countParts(counts, true))
        counts.add(ProgramAttention(ProgramAttentionTone.NEEDS_INPUT, question))
        assertNull(counts.uniformNeedsInputKind)
        assertEquals(ProgramCountPart(CountKind.NEED_INPUT, 3, ProgramAttentionTone.NEEDS_INPUT),
            ProgramStatusWordsModel.countParts(counts, true).first())
        val generic = ProgramAttentionCounts(needsInput = 1)
        generic.add(ProgramAttention(ProgramAttentionTone.NEEDS_INPUT, approval))
        assertNull(generic.uniformNeedsInputKind)
        counts.add(null, 100)
        assertEquals(4, counts.total)
    }

    @Test
    fun windowCueAndStatusPickMostUrgentPaneAndIgnoreOtherWindows() {
        val sessions = mapOf(host to state(done(1), failed(2), blocked(3), blocked(4, question),
            locations = mapOf(1 to ProgramStatusPaneLocation(10, 1, "build"),
                2 to ProgramStatusPaneLocation(10, 1, "build"),
                3 to ProgramStatusPaneLocation(10, 1, "build"),
                4 to ProgramStatusPaneLocation(20, 2, "deploy"))))
        val agents = ProgramStatusAgentInput(panes = mapOf(
            ProgramStatusPaneRef(host, 2) to ProgramStatusAgentPane(99, false, true)))
        assertEquals(ProgramWindowCue(true, ProgramAttentionTone.NEEDS_INPUT),
            ProgramStatusQueries.windowCue(sessions, host, 10, agents))
        val words = ProgramStatusQueries.windowStatus(sessions, host, 10, agents)!!
        assertEquals(ProgramStatusPhrase.Blocked(approval), words.phrase)
        assertEquals(ProgramAttentionTone.NEEDS_INPUT, words.tone)
        assertEquals(ProgramStatusPhrase.Failed, ProgramStatusQueries.paneStatus(sessions, host, 2, agents)?.phrase)
        assertEquals(ProgramWindowCue(false, null), ProgramStatusQueries.windowCue(sessions, host, 99, agents))
        assertNull(ProgramStatusQueries.windowStatus(sessions, host, 99, agents))
        assertNull(ProgramStatusQueries.paneStatus(sessions, host, 99, agents))
    }

    @Test
    fun mergedTerminalsIncludeAgentOnlyRawAndPaneTargetsWithoutDuplication() {
        val agents = ProgramStatusAgentInput(panes = linkedMapOf(
            ProgramStatusPaneRef(host, null) to ProgramStatusAgentPane(null, false, true),
            ProgramStatusPaneRef(host, 2) to ProgramStatusAgentPane(20, true, false),
            ProgramStatusPaneRef("other", 3) to ProgramStatusAgentPane(30, true, false)))
        val merged = ProgramStatusQueries.mergedTerminals(mapOf(host to state(done())), host, agents)
        assertEquals(listOf(null, 2), merged.map { it.paneId })
        assertTrue(merged.all { it.hasAgent })
        assertNotNull(merged.first().program)
        assertNull(merged.last().program)
        assertEquals(2, ProgramStatusQueries.sessionCounts(emptyMap(), host, agents).total)
        assertEquals(ProgramStatusPhrase.Blocked(null),
            ProgramStatusQueries.windowStatus(emptyMap(), host, 20, agents)?.phrase)
    }

    @Test
    fun statusFallsBackToFirstProgramAndPreservesOnlyMatchingEntryProgress() {
        val working = terminal(entry(SharedProgramStatusState.WORKING, SharedProgramStatusTerminal.Pane(1),
            app = "cargo", progress = 42))
        val sessions = mapOf(host to state(working, locations = mapOf(1 to ProgramStatusPaneLocation(10, 1, "build"))))
        assertEquals(ProgramStatusStatusWords("cargo", ProgramStatusPhrase.Working, 42, null),
            ProgramStatusQueries.windowStatus(sessions, host, 10))
        val native = blocked().let { snapshot ->
            val updated = snapshot.primaryEntry!!.copy(progress = 42, app = "cargo")
            snapshot.copy(entries = listOf(updated), primaryEntry = updated)
        }
        assertEquals(42, ProgramStatusWordsModel.status(ProgramTerminalAttention(null, null, true,
            native.programAttention, native))?.progress)
        assertNull(ProgramStatusWordsModel.status(ProgramTerminalAttention(null, null, true,
            ProgramAttention(ProgramAttentionTone.NEEDS_INPUT), done()))?.progress)
        assertNull(ProgramStatusWordsModel.status(ProgramTerminalAttention(null, null, true, null, null)))
    }

    @Test
    fun presentedResultsAreAcknowledgedOnPresentPublishAndActivateOnlyWhileActive() {
        val center = ProgramStatusCenter()
        val calls = mutableListOf<Pair<SharedProgramStatusTerminal, Long>>()
        val acknowledge: (SharedProgramStatusTerminal, Long) -> Unit = { terminal, token -> calls.add(terminal to token) }
        center.publish(host, state(done()), acknowledge)
        assertTrue(calls.isEmpty())
        center.setApplicationActive(false)
        center.setPresented(host, setOf(raw))
        center.publish(host, state(done(token = 9)), acknowledge)
        assertTrue(calls.isEmpty())
        center.setApplicationActive(true)
        assertEquals(listOf(raw to 9L), calls)
        center.setPresented(host, setOf(raw)) // Equality-gated presentation.
        assertEquals(1, calls.size)
        center.publish(host, state(done(token = 10)), acknowledge)
        assertEquals(raw to 10L, calls.last())
        center.setPresented(host, emptySet())
        center.publish(host, state(done(token = 11)), acknowledge)
        assertEquals(2, calls.size)
        center.setPresented(host, setOf(raw))
        assertEquals(raw to 11L, calls.last())
        center.remove(host)
        center.setApplicationActive(true)
        assertEquals(3, calls.size)
    }

    @Test
    fun blockedAndCheckedResultsWithoutTokensAreNeverAcknowledged() {
        val center = ProgramStatusCenter()
        val calls = mutableListOf<Long>()
        center.setPresented(host, setOf(raw, SharedProgramStatusTerminal.Pane(2)))
        center.publish(host, state(blocked(), done(2, token = null))) { _, token -> calls.add(token) }
        center.setApplicationActive(true)
        assertTrue(calls.isEmpty())
        assertEquals(ProgramAttentionTone.NEEDS_INPUT,
            ProgramStatusQueries.sessionCounts(center.sessions.value, host).tone)
    }

    @Test
    fun coveredTerminalKeepsNewResultsUnreadUntilItIsPresentedAgain() {
        for (result in listOf(done(), failed())) {
            val center = ProgramStatusCenter()
            val calls = mutableListOf<Long>()
            val visible = presentedProgramStatusTerminals(true, false, null, false, false)
            center.setPresented(host, visible)
            center.setPresented(host, presentedProgramStatusTerminals(
                true, false, null, false, false, terminalCovered = true))
            center.publish(host, state(result)) { _, token -> calls.add(token) }
            assertTrue(calls.isEmpty())
            assertEquals(1, ProgramStatusQueries.programItems(center.sessions.value).size)
            center.setPresented(host, visible)
            assertEquals(listOf(result.latestUnreadResultToken), calls)
        }
    }

    @Test
    fun acknowledgementMaySynchronouslyRepublishCheckedSnapshot() {
        val center = ProgramStatusCenter()
        val calls = mutableListOf<Long>()
        center.setPresented(host, setOf(raw))
        center.publish(host, state(done())) { _, token ->
            calls.add(token)
            val checked = done(token = null).let { snapshot ->
                val updated = snapshot.primaryEntry!!.copy(attention = null)
                snapshot.copy(entries = listOf(updated), primaryEntry = updated)
            }
            center.publish(host, state(checked)) { _, _ -> throw AssertionError("No unread token") }
        }
        assertEquals(listOf(7L), calls)
        assertNull(center.sessions.value[host]?.snapshot?.terminal(raw)?.latestUnreadResultToken)
    }

    @Test
    fun acknowledgementReentryRechecksActivityPresentationAndSessionBeforeNextToken() {
        for (mutation in listOf<(ProgramStatusCenter) -> Unit>(
            { it.setApplicationActive(false) },
            { it.setPresented(host, emptySet()) },
            { it.remove(host) },
        )) {
            val center = ProgramStatusCenter()
            val calls = mutableListOf<Long>()
            center.setPresented(host, linkedSetOf(raw, SharedProgramStatusTerminal.Pane(2)))
            center.publish(host, state(done(token = 7), done(2, token = 8))) { _, token ->
                calls.add(token)
                mutation(center)
            }
            assertEquals(listOf(7L), calls)
        }
    }

    @Test
    fun openingARowReprovesSessionTerminalAndCurrentLocation() {
        val center = ProgramStatusCenter()
        val calls = mutableListOf<Triple<String, Int?, Int?>>()
        center.onOpenTerminal = { hostId, windowId, paneId -> calls.add(Triple(hostId, windowId, paneId)) }
        center.publish(host, state(blocked(1), locations = mapOf(1 to ProgramStatusPaneLocation(10, 1, "build")))) { _, _ -> }
        val item = ProgramStatusQueries.programItems(center.sessions.value).single()
        assertEquals("$host|%1", item.id)
        center.open(item)
        assertEquals(listOf(Triple(host, 10, 1)), calls)
        center.publish(host, state(blocked(1), locations = mapOf(1 to ProgramStatusPaneLocation(20, 2, "moved")))) { _, _ -> }
        center.open(item)
        assertEquals(Triple(host, 20, 1), calls.last())
        center.publish(host, state(blocked(1))) { _, _ -> }
        center.open(item) // Pane still reports, but no live route.
        center.publish(host, state(blocked(2), locations = mapOf(2 to ProgramStatusPaneLocation(10, 1, "live")))) { _, _ -> }
        center.open(item) // A removed pane has no live route.
        center.remove(host)
        center.open(item)
        assertEquals(2, calls.size)
        center.publish(host, state(blocked())) { _, _ -> }
        center.openTerminal(host, raw)
        assertEquals(Triple<String, Int?, Int?>(host, null, null), calls.last())
        assertEquals("$host|raw", ProgramStatusQueries.programItems(center.sessions.value).single().id)
    }

    @Test
    fun emptySnapshotKeepsLiveRouteForFallbackAgentsAndEqualPublishKeepsProjectionIdentity() {
        val center = ProgramStatusCenter()
        val state = state(blocked())
        center.publish(host, state) { _, _ -> }
        val previous = center.sessions.value
        center.publish(host, state.copy()) { _, _ -> }
        assertSame(previous, center.sessions.value)
        center.publish(host, ProgramStatusSessionState("devbox", SharedProgramStatusSnapshot.EMPTY, emptyMap())) { _, _ -> }
        assertTrue(host in center.sessions.value)
        assertTrue(ProgramStatusQueries.programItems(center.sessions.value).isEmpty())
    }

    @Test
    fun concurrentPublishAndRemoveDoNotLoseOtherHosts() {
        val center = ProgramStatusCenter()
        val executor = Executors.newFixedThreadPool(4)
        val start = CountDownLatch(1)
        try {
            val futures = (1..24).map { id -> executor.submit {
                check(start.await(5, TimeUnit.SECONDS))
                center.publish("host-$id", state(blocked())) { _, _ -> }
                if (id % 2 == 0) center.remove("host-$id")
            } }
            start.countDown()
            futures.forEach { it.get(10, TimeUnit.SECONDS) }
            assertEquals((1..24).filter { it % 2 != 0 }.map { "host-$it" }.toSet(), center.sessions.value.keys)
        } finally {
            start.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun programItemsIncludeAgentTerminalsAndSortByToneHostAndWindowPosition() {
        val sessions = linkedMapOf(
            "z" to state(blocked(1), label = "Zulu", locations = mapOf(1 to ProgramStatusPaneLocation(10, 1, "z"))),
            "a" to state(done(1), blocked(2), blocked(3), failed(4), blocked(5), label = "Alpha",
                locations = mapOf(1 to ProgramStatusPaneLocation(10, 1, "a"),
                    2 to ProgramStatusPaneLocation(30, 3, "c"),
                    3 to ProgramStatusPaneLocation(20, 2, "b"))),
            "raw" to state(blocked(), label = "Alpha"),
        )
        val agents = ProgramStatusAgentInput(panes = mapOf(
            ProgramStatusPaneRef("a", 5) to ProgramStatusAgentPane(null, false, false),
            ProgramStatusPaneRef("raw", null) to ProgramStatusAgentPane(null, true, false)))
        assertEquals(listOf("a|%5", "raw|raw", "a|%3", "a|%2", "z|%1", "a|%4", "a|%1"),
            ProgramStatusQueries.programItems(sessions, agents).map { it.id })
        assertEquals("raw|raw", ProgramStatusQueries.programItems(sessions).first { it.terminal == raw }.id)
    }

    @Test
    fun attentionRowsIncludeFallbackOnlyAndNativeOnlyAgentsWithMergedWords() {
        val sessions = mapOf(host to state(blocked(2), failed(3), done(4),
            locations = (1..4).associateWith { ProgramStatusPaneLocation(10, 1, "build") }))
        // Agent Center's aggregate: the two fallback panes that need input.
        val agents = ProgramStatusAgentInput(waiting = 2, panes = mapOf(
            ProgramStatusPaneRef(host, 1) to ProgramStatusAgentPane(10, true, false),
            ProgramStatusPaneRef(host, 2) to ProgramStatusAgentPane(10, false, false),
            ProgramStatusPaneRef(host, 3) to ProgramStatusAgentPane(10, false, false),
            ProgramStatusPaneRef(host, 4) to ProgramStatusAgentPane(10, true, false),
        ))
        val rows = ProgramStatusQueries.programItems(sessions, agents)
        assertEquals(4, rows.size)
        assertTrue(rows.all { it.hasAgent && it.location?.windowId == 10 })
        val fallback = rows.single { it.id == "$host|%1" }
        assertNull(fallback.entry)
        assertEquals(ProgramStatusPhrase.Blocked(null), fallback.status.phrase)
        assertEquals(ProgramStatusPhrase.Blocked(approval), rows.single { it.id == "$host|%2" }.status.phrase)
        assertEquals(ProgramStatusPhrase.Failed, rows.single { it.id == "$host|%3" }.status.phrase)
        val merged = rows.single { it.id == "$host|%4" }
        assertNull(merged.entry) // Native done text must not replace fallback needs input.
        assertEquals(ProgramStatusPhrase.Blocked(null), merged.status.phrase)
        val counts = ProgramStatusQueries.counts(sessions, agents)
        assertEquals(rows.size, counts.total)
        assertEquals(3, counts.needsInput)
        assertEquals(1, counts.failed)
    }

    @Test
    fun fallbackOnlyAgentRouteCanOpenWithoutNativeRecordsAndListsDoNotAcknowledge() {
        val center = ProgramStatusCenter()
        val locations = mapOf(1 to ProgramStatusPaneLocation(10, 1, "build"))
        center.publish(host, state(locations = locations)) { _, _ -> throw AssertionError("No result") }
        val agents = ProgramStatusAgentInput(panes = mapOf(
            ProgramStatusPaneRef(host, 1) to ProgramStatusAgentPane(10, true, false)))
        val row = ProgramStatusQueries.programItems(center.sessions.value, agents).single()
        val calls = mutableListOf<Int?>()
        center.onOpenTerminal = { _, _, pane -> calls.add(pane) }
        center.open(row)
        assertEquals(listOf(1), calls)
        center.publish(host, state()) { _, _ -> }
        center.open(row)
        center.remove(host)
        center.open(row)
        assertEquals(listOf(1), calls)
    }

    @Test
    fun windowNamesTintOnlyInactiveResultsWhileAgentIconsCarryInput() {
        for (tone in ProgramAttentionTone.entries) {
            val cue = ProgramWindowCue(true, tone)
            assertEquals(tone, cue.iconTone(false))
            assertEquals(tone.takeIf { it != ProgramAttentionTone.NEEDS_INPUT }, cue.titleTone(false))
            assertEquals(tone.takeIf { it == ProgramAttentionTone.NEEDS_INPUT }, cue.iconTone(true))
            assertNull(cue.titleTone(true))
        }
    }

    @Test
    fun detailEntriesIncludeCheckedAndHistoricalRecordsWithAttentionFirst() {
        val checked = terminal(entry(SharedProgramStatusState.DONE, SharedProgramStatusTerminal.Pane(1)))
        val historical = terminal(entry(SharedProgramStatusState.WORKING,
            SharedProgramStatusTerminal.Pane(2), historical = true))
        val sessions = mapOf(host to state(checked, historical, failed(3), blocked(4),
            locations = mapOf(1 to ProgramStatusPaneLocation(20, 2, "b"),
                2 to ProgramStatusPaneLocation(10, 1, "a"))))
        val rows = ProgramStatusQueries.detailEntries(sessions, host)
        assertEquals(listOf(4, 3, 2, 1), rows.map { (it.entry.terminal as SharedProgramStatusTerminal.Pane).paneId })
        assertTrue(ProgramStatusQueries.detailEntries(sessions, "missing").isEmpty())
    }

    @Test
    fun wordsUseHistoricalStateAndTitleAppWindowNameFallbacks() {
        val working = entry(SharedProgramStatusState.WORKING, app = "cargo", progress = 42)
        assertEquals(ProgramStatusPhrase.Working, ProgramStatusWordsModel.state(working))
        assertEquals(42, ProgramStatusWordsModel.progressPercent(working))
        assertEquals(ProgramStatusPhrase.Literal("cargo"), ProgramStatusWordsModel.name(working, "build"))
        assertEquals(ProgramStatusPhrase.Literal("deploy prod"),
            ProgramStatusWordsModel.name(working.copy(title = "deploy prod"), "build"))
        val bare = entry(SharedProgramStatusState.IDLE)
        assertEquals(ProgramStatusPhrase.Ready, ProgramStatusWordsModel.state(bare))
        assertEquals(ProgramStatusPhrase.Program, ProgramStatusWordsModel.name(bare, null))
        assertEquals(ProgramStatusPhrase.Program, ProgramStatusWordsModel.name(bare.copy(title = "", app = ""), ""))
        assertEquals(ProgramStatusPhrase.Literal("build"), ProgramStatusWordsModel.name(bare, "build"))
        assertEquals(ProgramStatusPhrase.Blocked(SharedProgramStatusBlockedKind.AUTH),
            ProgramStatusWordsModel.state(entry(SharedProgramStatusState.BLOCKED, kind = SharedProgramStatusBlockedKind.AUTH)))
        assertEquals(ProgramStatusPhrase.Unavailable, ProgramStatusWordsModel.state(working.copy(isHistorical = true)))
        assertNull(ProgramStatusWordsModel.progressPercent(working.copy(isHistorical = true)))
    }

    @Test
    fun paneLocationsUseVisiblePositionsDisplayNamesAndUnhydratedActivePane() {
        val snapshot = SharedTmuxSnapshot(
            sessionName = "orbital",
            activeWindowId = 7,
            windows = listOf(
                SharedTmuxWindow(id = 7, index = 3, name = "build", activePaneId = 70,
                    panes = listOf(SharedTmuxPane(71, null, null, false)), zoomed = false,
                    layout = null, displayName = "cargo watch"),
                SharedTmuxWindow(id = 9, index = 12, name = "shell", activePaneId = 90,
                    panes = emptyList(), zoomed = false, layout = null, displayName = "vim README"),
            ),
            authority = SharedTmuxGridAuthoritySnapshot.Mine(generation = 1),
            revision = 1,
            rawJson = ByteArray(0),
        )
        assertEquals(mapOf(
            70 to ProgramStatusPaneLocation(7, 1, "cargo watch"),
            71 to ProgramStatusPaneLocation(7, 1, "cargo watch"),
            90 to ProgramStatusPaneLocation(9, 2, "vim README"),
        ), programStatusPaneLocations(snapshot))
        assertTrue(programStatusPaneLocations(snapshot.copy(windows = emptyList())).isEmpty())
    }
}
