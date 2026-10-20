package com.bambouville.tessera.data.continuity

import com.bambouville.tessera.core.bridge.SharedRestorePersistEntry
import com.bambouville.tessera.core.bridge.SharedRestorePersistPlan
import com.bambouville.tessera.core.bridge.SharedRestorePersistSource
import com.bambouville.tessera.data.TransportKinds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The window's sequencing, not its verdicts.
 *
 * Every verdict is the shared core's and is pinned by
 * `ForegroundRestoreCohortTests` in `Packages/TesseraCore`; a JVM test cannot
 * dlopen the Android core, and restating those rules in a fake would only
 * create a second authority to drift from. So the decisions are scripted here
 * and what is asserted is the order of the guards around them — which is what
 * every shipped restore bug on iOS was actually made of.
 */
class ForegroundRestoreWindowTest {
    @Test
    fun aWindowDoesNotSurviveTheBackgroundEdge() {
        // iOS 4072faa8, HIGH: cohort and openedAt were never cleared, so wake 2
        // ran wake 1's clock. The alive floor read as long spent, every entry
        // retired on the first pass, and the detection window was zero. Any app
        // visit shorter than the floor hit it.
        val decisions = ScriptedDecisions()
        val window = ForegroundRestoreWindow(decisions)

        window.armPreservedSnapshots(true)
        window.openIfNeeded(1_000, listOf(snapshot("a"), snapshot("b")))
        decisions.chargeDelta = 2_000
        window.charge(3_000, isPrompting = false)
        assertEquals(2_000, window.elapsedMilliseconds)

        window.closeForBackgroundEdge()

        assertFalse(window.isOpen)
        assertEquals(0, window.elapsedMilliseconds)
        assertEquals(emptyList<ForegroundRestoreSnapshot>(), window.cohort)
        // The latch is what the next foreground is armed by; the background
        // edge write re-arms it, and clearing it here would strand the wake.
        assertTrue(window.hasPreservedSnapshots)

        // Wake 2 seeds fresh, and its clock starts at zero.
        assertTrue(window.openIfNeeded(60_000, listOf(snapshot("a"))))
        assertEquals(0, window.elapsedMilliseconds)
    }

    @Test
    fun nothingJoinsAnOpenWindow() {
        // The defect that sank iOS's first attempt at keeping the window open:
        // a replacement that fails re-entering as a fresh candidate, forever.
        val window = ForegroundRestoreWindow(ScriptedDecisions())

        assertTrue(window.openIfNeeded(0, listOf(snapshot("a"))))
        assertFalse(window.openIfNeeded(1_000, listOf(snapshot("a"), snapshot("b"))))

        assertEquals(listOf("a"), window.cohort.map(ForegroundRestoreSnapshot::sessionId))
    }

    @Test
    fun evaluateRetiresWhatReachedAVerdictAndLeavesTheRest() {
        val decisions = ScriptedDecisions()
        val window = ForegroundRestoreWindow(decisions)
        window.openIfNeeded(0, listOf(snapshot("a"), snapshot("b"), snapshot("c")))

        decisions.evaluation = ForegroundRestoreEvaluation(
            dead = listOf(snapshot("a")),
            retiredSessionIds = listOf("a", "b"),
        )
        val evaluation = window.evaluate(live = emptyList(), retiresDeadImmediately = true)

        assertEquals(listOf("a"), evaluation.dead.map(ForegroundRestoreSnapshot::sessionId))
        assertEquals(listOf("c"), window.cohort.map(ForegroundRestoreSnapshot::sessionId))
    }

    @Test
    fun anAskPolicyDeadEntryKeepsItsPlaceUntilItIsRetiredByAnAnswer() {
        // iOS 4072faa8: answering the sheet was not treated as a verdict, so
        // entries stayed dead forever, the next tick re-raised the same sheet,
        // and a second tap stacked a duplicate tab.
        val decisions = ScriptedDecisions()
        val window = ForegroundRestoreWindow(decisions)
        window.openIfNeeded(0, listOf(snapshot("a")))

        decisions.evaluation = ForegroundRestoreEvaluation(dead = listOf(snapshot("a")))
        window.evaluate(live = emptyList(), retiresDeadImmediately = false)
        assertEquals(listOf("a"), window.cohort.map(ForegroundRestoreSnapshot::sessionId))

        assertEquals(1, window.retire(listOf("a")))
        assertEquals(emptyList<ForegroundRestoreSnapshot>(), window.cohort)
    }

    @Test
    fun theClockIsChargedNotWallTimeAndStopsWhenTheWindowIsNot() {
        val decisions = ScriptedDecisions()
        val window = ForegroundRestoreWindow(decisions)

        // A closed window charges nothing however long the caller ticks it.
        decisions.chargeDelta = 500
        window.charge(10_000, isPrompting = false)
        assertEquals(0, window.elapsedMilliseconds)

        window.openIfNeeded(10_000, listOf(snapshot("a")))
        window.charge(10_500, isPrompting = false)
        window.charge(11_000, isPrompting = false)
        assertEquals(1_000, window.elapsedMilliseconds)

        // 90 wall seconds behind a prompt; the core charges none of it, and
        // the window must not outrun the budget it is meant to outlive.
        decisions.chargeDelta = 0
        window.charge(101_000, isPrompting = true)
        assertEquals(1_000, window.elapsedMilliseconds)
    }

    @Test
    fun closureAsksAboutChargedTimeAndTheRemainingCohort() {
        val decisions = ScriptedDecisions()
        val window = ForegroundRestoreWindow(decisions, maxWindowMilliseconds = 60_000)
        window.openIfNeeded(0, listOf(snapshot("a")))
        decisions.chargeDelta = 2_000
        window.charge(50_000, isPrompting = false)

        decisions.closure = ForegroundRestoreWindowClosure.OPEN
        assertEquals(ForegroundRestoreWindowClosure.OPEN, window.closure(hasUnansweredPrompt = true))

        assertEquals(
            ClosureCall(
                remainingCohortCount = 1,
                elapsedMilliseconds = 2_000,
                maxWindowMilliseconds = 60_000,
                hasUnansweredPrompt = true,
            ),
            decisions.lastClosureCall,
        )
    }

    @Test
    fun aClosedWindowReportsSettledRatherThanConsultingTheCore() {
        val decisions = ScriptedDecisions()
        val window = ForegroundRestoreWindow(decisions)

        assertEquals(
            ForegroundRestoreWindowClosure.SETTLED,
            window.closure(hasUnansweredPrompt = false),
        )
        assertNull(decisions.lastClosureCall)
    }

    @Test
    fun persistModeIsAskedWithTheFourFactsThatDecideIt() {
        // iOS c2b02c92, HIGH: the scene stays active under the lock overlay, so
        // persists keep landing while cohort seeding waits behind the unlock.
        // Latched-but-unopened is what a locked wake looks like, and getting
        // that fact to the core is the whole fix.
        val decisions = ScriptedDecisions()
        val window = ForegroundRestoreWindow(decisions)

        window.armPreservedSnapshots(true)
        window.persistMode(isActive = true)
        assertEquals(
            PersistModeCall(
                isActive = true,
                hasPreservedSnapshots = true,
                isWindowOpen = false,
                hasCohortEntries = false,
            ),
            decisions.lastPersistModeCall,
        )

        window.openIfNeeded(0, listOf(snapshot("a")))
        window.persistMode(isActive = false)
        assertEquals(
            PersistModeCall(
                isActive = false,
                hasPreservedSnapshots = true,
                isWindowOpen = true,
                hasCohortEntries = true,
            ),
            decisions.lastPersistModeCall,
        )
    }

    @Test
    fun closingTheWindowDropsTheLatchButTheBackgroundEdgeKeepsIt() {
        val window = ForegroundRestoreWindow(ScriptedDecisions())

        window.armPreservedSnapshots(true)
        window.openIfNeeded(0, listOf(snapshot("a")))
        window.closeForBackgroundEdge()
        assertTrue(window.hasPreservedSnapshots)

        window.openIfNeeded(1_000, listOf(snapshot("a")))
        window.close()
        assertFalse(window.hasPreservedSnapshots)
        assertFalse(window.isOpen)
    }

    @Test
    fun aWriteTakesTheFreshestRecordForEverySessionThePlanNames() {
        // Which sessions a write contains is the shared core's rule and is
        // pinned by ProtocolVectors/session/v1/restore-decisions.json. What is
        // Android's own, and what this covers, is the step after: turning the
        // core's session ids back into snapshot rows. A session can appear in
        // all three collections at once, and taking the stale copy writes a
        // display name, transport or tmux target the user changed since.
        val decisions = ScriptedDecisions()
        decisions.persistPlan = SharedRestorePersistPlan(
            entries = listOf(
                SharedRestorePersistEntry("a", SharedRestorePersistSource.Stored),
                SharedRestorePersistEntry("b", SharedRestorePersistSource.Current),
                SharedRestorePersistEntry("c", SharedRestorePersistSource.Cohort),
            ),
            selectedSessionId = "b",
        )
        val window = ForegroundRestoreWindow(decisions)
        window.openIfNeeded(0, listOf(snapshot("c", displayName = "from-cohort")))

        val write = window.persistWrite(
            mode = ForegroundRestorePersistMode.MERGE_WITH_STORED,
            current = listOf(snapshot("b", displayName = "fresh")),
            stored = document(
                listOf(snapshot("a"), snapshot("b", displayName = "stale"), snapshot("c", displayName = "stale")),
                selectedSessionId = "a",
            ),
            preferred = "b",
        )

        // The plan's order is the write's order.
        assertEquals(listOf("a", "b", "c"), write.snapshots.map(ForegroundRestoreSnapshot::sessionId))
        assertEquals("name-a", write.snapshots[0].displayName)
        assertEquals("fresh", write.snapshots[1].displayName)
        assertEquals("from-cohort", write.snapshots[2].displayName)
        assertEquals("b", write.selectedSessionId)
    }

    @Test
    fun theWriteAsksTheCoreWithTheCohortItIsHolding() {
        // The cohort is the window's own state, so nothing else can supply it —
        // and an entry left out here is a snapshot deleted while its verdict is
        // still pending.
        val decisions = ScriptedDecisions()
        val window = ForegroundRestoreWindow(decisions)
        window.openIfNeeded(0, listOf(snapshot("a"), snapshot("b")))

        window.persistWrite(
            mode = ForegroundRestorePersistMode.KEEP_COHORT,
            current = listOf(snapshot("b")),
            stored = document(listOf(snapshot("z")), selectedSessionId = "z"),
            preferred = null,
        )

        val call = checkNotNull(decisions.lastPersistPlanCall)
        assertEquals(ForegroundRestorePersistMode.KEEP_COHORT, call.mode)
        assertEquals(listOf("b"), call.currentSessionIds)
        assertEquals(listOf("a", "b"), call.cohortSessionIds)
        assertEquals(listOf("z"), call.storedSessionIds)
        assertNull(call.preferredSelection)
        assertEquals("z", call.storedSelection)
        assertEquals(ForegroundRestoreDocument.MAX_SNAPSHOTS, call.maxSnapshots)
    }

    @Test
    fun aPlanNamingASessionNoCollectionHoldsWritesNothingForIt() {
        // The core answers in ids. A row it names that this side cannot produce
        // is dropped rather than written as a placeholder, because every field
        // of a snapshot is required and a fabricated one kills the process.
        val decisions = ScriptedDecisions()
        decisions.persistPlan = SharedRestorePersistPlan(
            entries = listOf(
                SharedRestorePersistEntry("a", SharedRestorePersistSource.Current),
                SharedRestorePersistEntry("ghost", SharedRestorePersistSource.Stored),
            ),
            selectedSessionId = null,
        )
        val window = ForegroundRestoreWindow(decisions)

        val write = window.persistWrite(
            mode = ForegroundRestorePersistMode.LIVE_ONLY,
            current = listOf(snapshot("a")),
            stored = null,
            preferred = null,
        )

        assertEquals(listOf("a"), write.snapshots.map(ForegroundRestoreSnapshot::sessionId))
    }

    private fun snapshot(
        sessionId: String,
        hostId: String = "host-$sessionId",
        displayName: String = "name-$sessionId",
    ) = ForegroundRestoreSnapshot(
        sessionId = sessionId,
        hostId = hostId,
        displayName = displayName,
        createdAtEpochMilliseconds = 1,
        transportKind = TransportKinds.SSH,
        tmuxTarget = null,
        lastSelection = null,
        reconnectRequired = true,
    )

    private fun document(
        snapshots: List<ForegroundRestoreSnapshot>,
        selectedSessionId: String? = null,
    ) = ForegroundRestoreDocument(
        savedAtEpochMilliseconds = 1,
        snapshots = snapshots,
        selectedSessionId = selectedSessionId,
    )

    private data class ClosureCall(
        val remainingCohortCount: Int,
        val elapsedMilliseconds: Long,
        val maxWindowMilliseconds: Long,
        val hasUnansweredPrompt: Boolean,
    )

    private data class PersistModeCall(
        val isActive: Boolean,
        val hasPreservedSnapshots: Boolean,
        val isWindowOpen: Boolean,
        val hasCohortEntries: Boolean,
    )

    private data class PersistPlanCall(
        val mode: ForegroundRestorePersistMode,
        val currentSessionIds: List<String>,
        val cohortSessionIds: List<String>,
        val storedSessionIds: List<String>,
        val preferredSelection: String?,
        val storedSelection: String?,
        val maxSnapshots: Int,
    )

    private class ScriptedDecisions : ForegroundRestoreDecisions {
        var evaluation = ForegroundRestoreEvaluation()
        var closure = ForegroundRestoreWindowClosure.OPEN
        var chargeDelta = 0L
        var persistMode = ForegroundRestorePersistMode.LIVE_ONLY
        var persistPlan = SharedRestorePersistPlan(entries = emptyList(), selectedSessionId = null)
        var lastClosureCall: ClosureCall? = null
        var lastPersistModeCall: PersistModeCall? = null
        var lastPersistPlanCall: PersistPlanCall? = null

        override fun evaluate(
            cohort: List<ForegroundRestoreSnapshot>,
            live: List<ForegroundRestoreLiveSession>,
            elapsedSinceWindowOpenedMilliseconds: Long,
            aliveFloorMilliseconds: Long,
            retiresDeadImmediately: Boolean,
        ): ForegroundRestoreEvaluation = evaluation

        override fun windowClosure(
            remainingCohortCount: Int,
            elapsedSinceWindowOpenedMilliseconds: Long,
            maxWindowMilliseconds: Long,
            hasUnansweredPrompt: Boolean,
        ): ForegroundRestoreWindowClosure {
            lastClosureCall = ClosureCall(
                remainingCohortCount = remainingCohortCount,
                elapsedMilliseconds = elapsedSinceWindowOpenedMilliseconds,
                maxWindowMilliseconds = maxWindowMilliseconds,
                hasUnansweredPrompt = hasUnansweredPrompt,
            )
            return closure
        }

        override fun chargeDeltaMilliseconds(
            nowEpochMilliseconds: Long,
            lastChargeAtEpochMilliseconds: Long?,
            isPrompting: Boolean,
            maxTickMilliseconds: Long,
        ): Long = if (lastChargeAtEpochMilliseconds == null || isPrompting) 0 else chargeDelta

        override fun persistMode(
            isActive: Boolean,
            hasPreservedSnapshots: Boolean,
            isWindowOpen: Boolean,
            hasCohortEntries: Boolean,
        ): ForegroundRestorePersistMode {
            lastPersistModeCall = PersistModeCall(
                isActive = isActive,
                hasPreservedSnapshots = hasPreservedSnapshots,
                isWindowOpen = isWindowOpen,
                hasCohortEntries = hasCohortEntries,
            )
            return persistMode
        }

        override fun persistPlan(
            mode: ForegroundRestorePersistMode,
            currentSessionIds: List<String>,
            cohortSessionIds: List<String>,
            storedSessionIds: List<String>,
            preferredSelection: String?,
            storedSelection: String?,
            maxSnapshots: Int,
        ): SharedRestorePersistPlan {
            lastPersistPlanCall = PersistPlanCall(
                mode = mode,
                currentSessionIds = currentSessionIds,
                cohortSessionIds = cohortSessionIds,
                storedSessionIds = storedSessionIds,
                preferredSelection = preferredSelection,
                storedSelection = storedSelection,
                maxSnapshots = maxSnapshots,
            )
            return persistPlan
        }
    }
}
