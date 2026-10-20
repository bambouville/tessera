package com.bambouville.tessera.feature.agentcenter

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.design.TesseraTheme
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Production notice surface, with no session or network connection. */
@RunWith(AndroidJUnit4::class)
class AgentSendAnywayInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()

    @Test fun eligibleNoticeRequiresAnExplicitTapAndRetainsDismissal() {
        var visible by mutableStateOf(true)
        var sends = 0
        var dismissals = 0
        compose.activityRule.scenario.onActivity { activity -> activity.installFixture {
            TesseraTheme {
                if (visible) AgentNoticeDialog(
                    notice = agentNotSentNotice(AgentNotSentReason.INPUT_NOT_READY, "Claude Code", AgentUnsentDraft.RESTORED) +
                        " Send anyway skips prompt verification.",
                    onDismiss = { dismissals++; visible = false },
                    onSendAnyway = { sends++; visible = false },
                )
            }
        } }
        compose.onNodeWithText("Send anyway").assertIsDisplayed().assertIsEnabled()
        compose.onNodeWithText("ok").assertIsDisplayed().assertIsEnabled()
        compose.runOnIdle { assertEquals(0, sends); assertEquals(0, dismissals) }
        capture("eligible")
        compose.onNodeWithText("Send anyway").performClick()
        compose.runOnIdle { assertEquals(1, sends); assertEquals(0, dismissals) }
        compose.onAllNodesWithText("Send anyway").assertCountEquals(0)
        compose.runOnIdle { visible = true }
        compose.onNodeWithText("ok").performClick()
        compose.runOnIdle { assertEquals(1, sends); assertEquals(1, dismissals) }
        compose.onAllNodesWithText("Send anyway").assertCountEquals(0)
    }

    @Test fun ordinaryFailureHasOnlyTheDismissAction() {
        compose.activityRule.scenario.onActivity { activity -> activity.installFixture {
            TesseraTheme {
                AgentNoticeDialog(
                    notice = agentNotSentNotice(AgentNotSentReason.ROUTE_CHANGED, "Claude Code", AgentUnsentDraft.RESTORED),
                    onDismiss = {},
                )
            }
        } }
        compose.onNodeWithText("ok").assertIsDisplayed().assertIsEnabled()
        compose.onAllNodesWithText("Send anyway").assertCountEquals(0)
        capture("unavailable")
    }

    private fun capture(scene: String) {
        compose.waitForIdle()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.waitForIdleSync()
        // Window entrance fades run outside Compose's test clock.
        android.os.SystemClock.sleep(500)
        val bitmap = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        val context = instrumentation.targetContext
        val surface = if (context.resources.configuration.smallestScreenWidthDp >= 600) "tablet" else "phone"
        File(context.filesDir, "agent-send-anyway-$surface-$scene.png").outputStream().use {
            check(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
        }
        bitmap.recycle()
    }
}
