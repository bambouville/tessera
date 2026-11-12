package com.bambouville.tessera.feature.agentcenter

import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A waiting row's foldable answers: open by default, folded while its thread
 * is open in the detail beside the list, chosen per question by the chevron.
 */
@RunWith(AndroidJUnit4::class)
class AgentRowAnswersComposeTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()

    private val atlas = waiting("atlas", "Atlas retries", "live-prompt-atlas-1", "atlas-yes", "atlas-no")
    private val billing = waiting("billing", "Billing migration", "live-prompt-billing-1", "billing-yes", "billing-no")
    private var state by mutableStateOf(AgentCenterUiState(loading = false))
    private var folds by mutableStateOf(AgentRowAnswerFolds())
    private val drafts = AgentPromptDrafts()
    private val selections = mutableListOf<String>()

    private fun show(detailBeside: Boolean, selected: String?, vararg details: AgentThreadDetail) {
        state = AgentCenterUiState(loading = false, threads = details.map { it.row }, selectedThreadKey = selected,
            projectedDetails = details.associateBy { it.row.key })
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme {
                    AgentListPane(
                        state = state, onSearch = {}, onSelect = { selections += it }, onGroupingChange = {}, onSpawn = {},
                        modifier = Modifier.width(340.dp).fillMaxHeight(),
                        detailBeside = detailBeside,
                        answerFolds = folds,
                        onToggleAnswers = { key, open -> folds = folds.choosing(key, open) },
                        promptDrafts = drafts,
                    )
                }
            }
        }
        compose.waitForIdle()
    }

    private fun string(id: Int) = compose.activity.getString(id)
    private fun toggle(detail: AgentThreadDetail) = compose.onNodeWithTag("agent-row-answers-${detail.row.key}")
    private fun label(detail: AgentThreadDetail) = compose.onNodeWithTag("agent-row-answer-beside-${detail.row.key}", useUnmergedTree = true)
    private fun answer(id: String) = compose.onNodeWithTag("agent-answer-$id")

    @Test fun theThreadOpenBesideFoldsItsRowAndTheChevronFlipsEachRow() {
        show(detailBeside = true, selected = atlas.row.key, atlas, billing)
        // Shown beside: folded, pointing at the thread. The other row shows its answers.
        answer("atlas-yes").assertDoesNotExist()
        label(atlas).assertIsDisplayed()
        toggle(atlas).assertContentDescriptionEquals(string(R.string.agent_row_answers_show))
            .assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp)
        answer("billing-yes").assertIsDisplayed()
        label(billing).assertDoesNotExist()
        toggle(billing).assertContentDescriptionEquals(string(R.string.agent_row_answers_fold))
            .assertWidthIsAtLeast(48.dp).assertHeightIsAtLeast(48.dp)

        toggle(atlas).performClick()
        answer("atlas-yes").assertIsDisplayed()
        label(atlas).assertDoesNotExist()
        toggle(atlas).assertContentDescriptionEquals(string(R.string.agent_row_answers_fold))

        toggle(billing).performClick()
        answer("billing-yes").assertDoesNotExist()
        // Folded by hand: nothing to point at.
        label(billing).assertDoesNotExist()
        toggle(billing).assertContentDescriptionEquals(string(R.string.agent_row_answers_show))
        // Folding is not selecting.
        compose.runOnIdle { assertTrue(selections.toString(), selections.isEmpty()) }

        // The agent's next question on atlas arrives in its default state.
        val next = atlas.copy(prompt = atlas.prompt!!.copy(actionToken = "live-prompt-atlas-2"))
        compose.runOnIdle { state = state.copy(projectedDetails = state.projectedDetails + (atlas.row.key to next)) }
        compose.waitForIdle()
        answer("atlas-yes").assertDoesNotExist()
        label(atlas).assertIsDisplayed()
        // billing still waits on the question folded by hand.
        answer("billing-yes").assertDoesNotExist()
    }

    @Test fun aSinglePaneListNeverFoldsByDefault() {
        // The phone's list after Back still has a selected thread.
        show(detailBeside = false, selected = atlas.row.key, atlas, billing)
        answer("atlas-yes").assertIsDisplayed()
        answer("billing-yes").assertIsDisplayed()
        label(atlas).assertDoesNotExist()
        toggle(atlas).assertContentDescriptionEquals(string(R.string.agent_row_answers_fold))

        toggle(atlas).performClick()
        answer("atlas-yes").assertDoesNotExist()
        label(atlas).assertDoesNotExist()
        toggle(atlas).assertContentDescriptionEquals(string(R.string.agent_row_answers_show))
        compose.runOnIdle {
            assertEquals(false, folds.choice(AgentRowPromptKey(atlas.row.key, atlas.prompt!!.actionToken)))
            assertEquals(emptyList<String>(), selections)
        }
    }

    @Test fun aTypedAnswerOutlivesItsRowFolding() {
        // Answerable: a typed answer needs the live prompt's fresh capture.
        val typing = waiting("typing", "Atlas retries", "typing-signature", "typing-yes", "typing-other", textOption = "typing-other")
            .let { detail ->
                val prompt = detail.prompt!!
                detail.copy(row = detail.row.copy(actionAvailable = true), prompt = prompt.copy(
                    actionToken = livePromptActionToken("typing-signature"),
                    fresh = AgentFreshPrompt("typing-signature", emptyList(), prompt.kind)))
            }
        show(detailBeside = true, selected = null, typing, billing)
        answer("typing-other").performClick()
        compose.onNodeWithTag("agent-answer-text").performTextInput("retry with backoff")

        // Opening the thread beside the list folds its row, removing the field.
        compose.runOnIdle { state = state.copy(selectedThreadKey = typing.row.key) }
        compose.waitForIdle()
        compose.onNodeWithTag("agent-answer-text").assertDoesNotExist()
        label(typing).assertIsDisplayed()

        toggle(typing).performClick()
        compose.onNodeWithTag("agent-answer-text").assertTextEquals("retry with backoff")
    }

    private fun waiting(
        session: String,
        title: String,
        token: String,
        vararg options: String,
        textOption: String? = null,
    ): AgentThreadDetail {
        val row = AgentThreadRow(
            key = canonicalAgentThreadKey("fixture-host", "claude", session), title = title, provider = "Claude", model = null,
            preview = "Proceed?", status = "waitingForInput", attention = "needsYou", location = "fixture", queuedCount = null,
            isFork = false, actionAvailable = false, spawnAvailable = false, forkAvailable = false,
            hostID = "fixture-host", providerID = "claude", providerSessionID = session, host = "fixture-host",
        )
        return AgentThreadDetail(row, emptyList(), emptyList(), emptyList(), null, false,
            prompt = AgentPrompt("Proceed?", null, token, options.map {
                AgentPromptOption(it, it, isDefault = it == options.first(), acceptsText = it == textOption)
            }))
    }
}
