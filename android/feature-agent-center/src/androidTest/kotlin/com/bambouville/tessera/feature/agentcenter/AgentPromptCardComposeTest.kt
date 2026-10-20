package com.bambouville.tessera.feature.agentcenter

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Live prompt cards as Core publishes them from real Claude Code, Codex and
 * Kimi screens, answered in place. Screenshots land in
 * /sdcard/Download/agent-prompt-*.png for the aggregate visual review.
 */
@RunWith(AndroidJUnit4::class)
class AgentPromptCardComposeTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()

    private var answers = mutableListOf<AgentPromptAnswerChoice>()
    private var pending by mutableStateOf(false)

    private fun show(prompt: AgentPrompt) {
        val shown = detail(prompt)
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme {
                    AgentDetailPane(shown, "", {}, {}, {}, { _, answer -> answers += answer }, {}, {}, {}, {}, {},
                        Modifier.fillMaxSize().safeDrawingPadding(), promptActionPending = pending)
                }
            }
        }
        compose.waitForIdle()
    }

    @Test fun questionOffersEveryOptionAndATypedAnswer() {
        show(question())
        compose.onNodeWithText("Which database should the service use for the new ledger?").assertIsDisplayed()
        for (id in 1..5) compose.onNodeWithTag("agent-answer-$id").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Mature, transactional, already deployed.").assertIsDisplayed()
        capture("question")
        compose.onNodeWithTag("agent-answer-2").performScrollTo().performClick()
        compose.onNodeWithTag("agent-answer-4").performScrollTo().performClick()
        compose.onNodeWithTag("agent-answer-send").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithTag("agent-answer-text").performTextInput("CockroachDB")
        compose.onNodeWithTag("agent-answer-send").assertIsEnabled()
        capture("question-freeform-typing")
        compose.onNodeWithTag("agent-answer-send").performClick()
        compose.onNodeWithTag("agent-answer-control-cancel").performScrollTo().performClick()
        compose.runOnIdle {
            assertEquals(listOf(AgentPromptAnswerChoice.Option("2"), AgentPromptAnswerChoice.Text("CockroachDB"),
                AgentPromptAnswerChoice.Control("cancel")), answers)
        }
    }

    @Test fun terminalEntryMultiSelectReviewAndPermissionCards() {
        show(question().copy(entry = AgentPromptEntry("4", "CockroachDB, with a read replica")))
        compose.onNodeWithText("In the terminal: CockroachDB, with a read replica").performScrollTo().assertIsDisplayed()
        capture("typed")

        show(multiSelect())
        for (id in 1..3) compose.onNodeWithTag("agent-answer-$id").performScrollTo().assertIsDisplayed()
        capture("multi-select")
        compose.onNodeWithTag("agent-answer-control-next").performScrollTo().performClick()

        show(review())
        compose.onNodeWithText("Ready to submit your answers?").assertIsDisplayed()
        capture("review")
        compose.onNodeWithTag("agent-answer-1").performScrollTo().performClick()

        show(permission())
        for (id in 1..4) compose.onNodeWithTag("agent-answer-$id").performScrollTo().assertIsDisplayed()
        capture("permission")
        compose.runOnIdle {
            assertEquals(listOf(AgentPromptAnswerChoice.Control("next"), AgentPromptAnswerChoice.Option("1")), answers)
        }
    }

    @Test fun textOnlyAndDeferredCardsKeepWorkingAndDisableWhilePending() {
        show(textEntry())
        compose.onNodeWithTag("agent-answer-text").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("The agent keeps working while this waits").assertIsDisplayed()
        capture("text")

        show(deferred())
        compose.onNodeWithText("2 questions waiting").assertIsDisplayed()
        compose.onNodeWithText("Codex keeps working while they wait").assertIsDisplayed()
        capture("deferred")
        compose.onNodeWithTag("agent-answer-control-open").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(listOf(AgentPromptAnswerChoice.Control("open")), answers) }

        pending = true
        show(deferred())
        compose.onNodeWithTag("agent-answer-control-open").performScrollTo().assertIsNotEnabled()
    }

    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        compose.waitForIdle(); instrumentation.waitForIdleSync()
        val shot = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        java.io.FileOutputStream("/sdcard/Download/agent-prompt-$name.png").use {
            check(shot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
        }
        shot.recycle()
    }

    private fun live(signature: String, prompt: AgentPrompt) = prompt.copy(
        actionToken = livePromptActionToken(signature),
        fresh = AgentFreshPrompt(signature, emptyList(), prompt.kind),
    )

    private val database = listOf(
        AgentPromptOption("1", "Postgres (Recommended)", true, "Mature, transactional, already deployed."),
        AgentPromptOption("2", "SQLite", false, "Embedded file, zero operations."),
        AgentPromptOption("3", "DynamoDB", false, "Managed key-value store."),
        AgentPromptOption("4", "Type something.", false, role = "freeform", acceptsText = true),
        AgentPromptOption("5", "Chat about this", false, role = "chat"),
    )

    private fun question() = live("fixture-question", AgentPrompt("Database", null, "", database, kind = "question",
        question = "Which database should the service use for the new ledger?",
        controls = listOf(AgentPromptControl("cancel", "Cancel")), acceptsText = true))

    private fun multiSelect() = live("fixture-multi", AgentPrompt("Features", null, "", listOf(
        AgentPromptOption("1", "Search", false, "Full-text search.", isChecked = true),
        AgentPromptOption("2", "Export", true, "CSV export.", isChecked = false),
        AgentPromptOption("3", "Sharing", false, "Share links.", isChecked = true),
        AgentPromptOption("4", "Type something", false, role = "freeform", isChecked = false),
        AgentPromptOption("5", "Chat about this", false, role = "chat"),
    ), kind = "multiSelect", question = "Which features should ship first?",
        progress = "☒ Database ☐ Features ☐ PR ✔ Submit",
        controls = listOf(AgentPromptControl("next", "Next"), AgentPromptControl("cancel", "Cancel"))))

    private fun review() = live("fixture-review", AgentPrompt("Review your answers",
        "● Which database should the service use?\n  → Postgres\n● Which features should ship first?\n  → Search, Sharing",
        "", listOf(AgentPromptOption("1", "Submit answers", true), AgentPromptOption("2", "Cancel", false)),
        kind = "review", question = "Ready to submit your answers?", progress = "☒ Database ☒ Features ☒ PR ✔ Submit"))

    private fun textEntry() = live("fixture-text", AgentPrompt("Question", null, "", emptyList(), kind = "textEntry",
        question = "Describe the rollout window you prefer.", progress = "2 of 2",
        controls = listOf(AgentPromptControl("skip", "Skip")), entry = AgentPromptEntry(null, ""),
        acceptsText = true, isBlocking = false))

    private fun deferred() = live("fixture-deferred", AgentPrompt("Questions waiting", null, "", emptyList(),
        kind = "deferred", question = "2 questions", controls = listOf(AgentPromptControl("open", "Answer")),
        isBlocking = false, pendingCount = 2))

    private fun permission() = live("fixture-permission", AgentPrompt("Permission requested", "cwd: ~/work\n$ python3 hello.py", "",
        listOf(AgentPromptOption("1", "Approve once", true), AgentPromptOption("2", "Approve for this session", false),
            AgentPromptOption("3", "Reject", false), AgentPromptOption("4", "Reject with feedback", false)),
        kind = "permission", question = "Run this command?"))

    private fun detail(prompt: AgentPrompt) = AgentThreadDetail(
        row = AgentThreadRow(
            key = "host:claude:prompt", title = "files panel flicker", provider = "Claude", model = "opus", preview = null,
            status = if (prompt.isBlocking) "waitingForInput" else "working", attention = "needsYou", location = "dev · pane %10",
            queuedCount = null, isFork = false, actionAvailable = true, spawnAvailable = true, forkAvailable = true,
            hostID = "fixture-host", providerID = "claude", providerSessionID = "prompt-thread", host = "fixture-host",
        ),
        live = listOf(AgentBlock("assistant", "I found a context-menu backdrop transition that needs an opaque backstop.", recordID = "a1")),
        activity = emptyList(), changes = emptyList(),
        binding = SharedAgentValue.ObjectValue(mapOf(
            "liveSessionID" to SharedAgentValue.StringValue("fixture-live"),
            "carrierGeneration" to SharedAgentValue.NumberValue("1"),
            "transport" to SharedAgentValue.StringValue("sshTmux"),
            "tmuxSession" to SharedAgentValue.StringValue("dev"),
            "windowID" to SharedAgentValue.StringValue("@2"),
            "paneID" to SharedAgentValue.StringValue("%10"),
            "capabilities" to SharedAgentValue.NumberValue("8"),
        )),
        hasMore = false,
        prompt = prompt,
    )
}
