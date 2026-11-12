package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentRowAnswerFoldsTest {
    private val atlas = AgentRowPromptKey("host:claude:atlas", "live-prompt-a")
    private val billing = AgentRowPromptKey("host:claude:billing", "live-prompt-b")
    private val none = AgentRowAnswerFolds()

    @Test fun waitingRowsShowTheirAnswersByDefault() {
        // Beside a detail that shows another thread, or none at all.
        assertEquals(AgentRowAnswerFold.Open, none.fold(atlas, shownThreadKey = billing.threadKey, detailBeside = true))
        assertEquals(AgentRowAnswerFold.Open, none.fold(atlas, shownThreadKey = null, detailBeside = true))
        assertFalse(AgentRowAnswerFold.Open.folded)
    }

    @Test fun theThreadOpenBesideTheListFoldsItsRowAndPointsAtTheThread() {
        val fold = none.fold(atlas, shownThreadKey = atlas.threadKey, detailBeside = true)
        assertEquals(AgentRowAnswerFold.AnswerBeside, fold)
        assertTrue(fold.folded)
        assertTrue(agentRowAnswersFoldedByDefault(atlas.threadKey, atlas.threadKey, detailBeside = true))
        assertFalse(agentRowAnswersFoldedByDefault(atlas.threadKey, billing.threadKey, detailBeside = true))
    }

    @Test fun aSinglePaneListNeverFoldsByDefault() {
        // The phone keeps its selected thread after Back; that is not "beside".
        assertFalse(agentRowAnswersFoldedByDefault(atlas.threadKey, atlas.threadKey, detailBeside = false))
        assertEquals(AgentRowAnswerFold.Open, none.fold(atlas, shownThreadKey = atlas.threadKey, detailBeside = false))
        assertEquals(AgentRowAnswerFold.Open, none.fold(atlas, shownThreadKey = null, detailBeside = false))
        // A hand fold still works there, and has no thread to point at.
        assertEquals(AgentRowAnswerFold.Folded, none.choosing(atlas, open = false).fold(atlas, atlas.threadKey, detailBeside = false))
    }

    @Test fun aHandChoiceHoldsWhereverItsThreadIsShown() {
        val foldedByHand = none.choosing(atlas, open = false)
        assertEquals(false, foldedByHand.choice(atlas))
        assertEquals(AgentRowAnswerFold.Folded, foldedByHand.fold(atlas, shownThreadKey = null, detailBeside = true))
        // Only that row.
        assertEquals(AgentRowAnswerFold.Open, foldedByHand.fold(billing, shownThreadKey = null, detailBeside = true))
        // Opening its thread beside keeps it folded, now pointing at the thread.
        assertEquals(AgentRowAnswerFold.AnswerBeside, foldedByHand.fold(atlas, shownThreadKey = atlas.threadKey, detailBeside = true))

        val openedBeside = none.choosing(atlas, open = true)
        assertEquals(AgentRowAnswerFold.Open, openedBeside.fold(atlas, shownThreadKey = atlas.threadKey, detailBeside = true))
        // Selecting another thread leaves it open: a choice is not an inversion of the default.
        assertEquals(AgentRowAnswerFold.Open, openedBeside.fold(atlas, shownThreadKey = billing.threadKey, detailBeside = true))
        assertEquals(AgentRowAnswerFold.Open, openedBeside.fold(atlas, shownThreadKey = atlas.threadKey, detailBeside = false))
    }

    @Test fun theAgentsNextQuestionArrivesInItsDefaultState() {
        val folded = none.choosing(atlas, open = false)
        val next = atlas.copy(actionToken = "live-prompt-a2")
        assertNull(folded.choice(next))
        assertEquals(AgentRowAnswerFold.Open, folded.fold(next, shownThreadKey = null, detailBeside = true))
        assertEquals(AgentRowAnswerFold.AnswerBeside, folded.fold(next, atlas.threadKey, detailBeside = true))
        // Choosing for the new question replaces the thread's old choice.
        val chosenNext = folded.choosing(next, open = true)
        assertEquals(true, chosenNext.choice(next))
        assertNull(chosenNext.choice(atlas))
    }

    @Test fun aChoiceIsForgottenOnceItsQuestionIsGone() {
        val chosen = none.choosing(atlas, open = false).choosing(billing, open = false)
        // Still waiting on the same question, or on one not projected yet: kept,
        // and unchanged state is the same instance (no extra recomposition).
        val waiting = mapOf(atlas.threadKey to atlas.actionToken, billing.threadKey to null)
        assertSame(chosen, chosen.retainingCurrent(waiting))

        // Answered (no longer waiting), or waiting on another question: dropped.
        val answered = chosen.retainingCurrent(mapOf(billing.threadKey to null))
        assertNull(answered.choice(atlas))
        assertEquals(false, answered.choice(billing))
        val another = chosen.retainingCurrent(mapOf(atlas.threadKey to "live-prompt-a2", billing.threadKey to null))
        assertNull(another.choice(atlas))

        // The same screen asked again later carries the same token, and still
        // arrives in its default state.
        assertEquals(AgentRowAnswerFold.Open, answered.fold(atlas, shownThreadKey = null, detailBeside = true))
    }

    @Test fun waitingQuestionsComeFromTheListOrTheProjection() {
        fun row(session: String, attention: String) = AgentThreadRow(
            key = "host:claude:$session", title = session, provider = "Claude", model = null, preview = null,
            status = "waitingForInput", attention = attention, location = "", queuedCount = null,
            isFork = false, actionAvailable = true, spawnAvailable = false, forkAvailable = false,
        )
        fun detail(row: AgentThreadRow, token: String?) = AgentThreadDetail(row, emptyList(), emptyList(), emptyList(), null, false,
            prompt = token?.let { AgentPrompt("Proceed?", null, it, listOf(AgentPromptOption("1", "Yes", true))) })
        val listed = row("atlas", "needsYou")
        val lagging = row("billing", "none")
        val idle = row("photos", "none")
        val waiting = agentWaitingQuestions(
            threads = listOf(listed, lagging, idle),
            projectedDetails = mapOf(
                listed.key to detail(listed, "live-prompt-a"),
                // The list summary lags its projection: still waiting.
                lagging.key to detail(lagging.copy(attention = "needsYou"), "live-prompt-b"),
                idle.key to detail(idle, null),
            ),
        )
        assertEquals(mapOf(listed.key to "live-prompt-a", lagging.key to "live-prompt-b"), waiting)
        // A listed waiting row without a projection waits on an unknown question.
        assertEquals(mapOf(listed.key to null), agentWaitingQuestions(listOf(listed), emptyMap()))
    }
}
