package com.bambouville.tessera

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.Lifecycle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.data.AndroidHostRepository
import com.bambouville.tessera.data.AndroidSessionRestoreRepository
import com.bambouville.tessera.data.HostDraft
import com.bambouville.tessera.data.SessionRestoreRecord
import com.bambouville.tessera.data.TransportKinds
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.After
import java.util.UUID
import com.bambouville.tessera.feature.session.LiveSessionStore

/**
 * The system back gesture is in-app navigation, not an exit.
 *
 * Android routes the edge swipe through the same dispatcher as the three-button
 * back key, so a screen that registers no callback silently hands the gesture to
 * the activity — which is how a swipe from inside a live terminal used to leave
 * the app instead of returning to the tab bar. These press the dispatcher
 * directly, which is exactly what the gesture and the key both do.
 */
@RunWith(AndroidJUnit4::class)
class BackNavigationInstrumentedTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    /**
     * A session opened here outlives this Activity now, and every case in this
     * module shares one process — so a terminal left open by this class is a
     * terminal the next class launches into. Whoever opens one puts it back.
     */
    @After
    fun endEverySessionThisClassOpened() {
        LiveSessionStore.resetForTests()
    }

    @Test
    fun backLeavesTheTerminalForTheTabBar() {
        val token = System.currentTimeMillis().toString()
        val displayName = "Back $token"
        // A UUID, because that is what a session id is. The shared persist plan
        // takes them as `[UUID]`, so a readable fixture string reached the ABI,
        // failed to decode, and came back as the core's one -1 — which the JNI
        // reports as `shared restore persist plan failed` from whichever write
        // happened to run next.
        val sessionId = UUID.randomUUID().toString()
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val hosts = AndroidHostRepository(context)
        val restore = AndroidSessionRestoreRepository(context)
        // A dormant restore record is what puts a host on the Sessions tab, and
        // a Sessions row presents its terminal without opening a transport —
        // the only route into the session screen that automation may take. The
        // hostname is unroutable regardless, so nothing here can reach a host.
        val host = runBlocking {
            hosts.save(
                HostDraft(
                    displayName = displayName,
                    hostname = "back-$token.example",
                    port = 2222,
                    username = "tester",
                    transportKind = TransportKinds.SSH,
                ),
            )
        }
        val record = SessionRestoreRecord(
            sessionId = sessionId,
            hostId = host.id,
            transportKind = TransportKinds.SSH,
            tmuxTarget = null,
            lastSelection = null,
            reconnectRequired = true,
            updatedAtEpochMilliseconds = System.currentTimeMillis(),
        )

        try {
            waitForTag("root-sessions")
            compose.onNodeWithTag("root-sessions").performClick()
            seedUntilTheSessionRowSurvives(displayName) {
                runBlocking {
                    if (restore.record(sessionId) == null) restore.save(record)
                }
            }
            compose.onNodeWithText(displayName).performClick()

            waitForTag("session-switcher-button")
            compose.onNodeWithTag("session-switcher-button").assertIsDisplayed()
            // The tab bar is gone while a session is presented; that absence is
            // what the gesture has to undo.
            assertTrue(compose.onAllNodesWithTag("root-sessions").fetchSemanticsNodes().isEmpty())

            pressBack()

            waitForTag("root-sessions")
            compose.onNodeWithTag("root-sessions").assertIsDisplayed()
            // And it stayed inside the app. Had the gesture reached the
            // activity, Android would have moved the task to the background,
            // which is the bug this test exists for.
            assertEquals(Lifecycle.State.RESUMED, compose.activityRule.scenario.state)
        } finally {
            runBlocking {
                restore.deleteForHost(host.id)
                hosts.observeHosts().first().firstOrNull { it.id == host.id }?.let {
                    hosts.delete(it.id)
                }
            }
        }
    }

    @Test
    fun backLeavesASettingsSectionForTheSettingsList() {
        compose.onNodeWithTag("root-settings").performClick()
        waitForText("appearance")
        compose.onNodeWithText("appearance").performClick()
        waitForText("color theme")

        pressBack()

        waitForText("sync & continuity")
        compose.onNodeWithText("sync & continuity").assertIsDisplayed()
    }

    @Test
    fun backLeavesADestinationPageForTheSettingsList() {
        // Diagnostics, known hosts and pairing return early from the settings
        // landing, so the section page's own handler is not composed over them.
        // Each carries the shared sub-page header, and that is what answers.
        compose.onNodeWithTag("root-settings").performClick()
        waitForText("diagnostics")
        compose.onNodeWithText("diagnostics").performScrollTo().performClick()
        waitForText("debug log")

        pressBack()

        waitForText("sync & continuity")
        compose.onNodeWithText("sync & continuity").assertIsDisplayed()
    }

    /**
     * Wait for the seeded session row, re-seeding its restore record as needed.
     *
     * The app prunes every restore record no foreground-restore document claims,
     * once, on the first composition that has hosts, continuity state and an
     * unlocked screen. A record written from a test lands on either side of that
     * pass depending on how fast the continuity flows settle, so offer it again
     * until it survives — the pass is latched, so at most one re-seed is needed.
     */
    private fun seedUntilTheSessionRowSurvives(displayName: String, seed: () -> Unit) {
        val deadline = System.currentTimeMillis() + 20_000
        while (System.currentTimeMillis() < deadline) {
            seed()
            compose.waitForIdle()
            if (compose.onAllNodesWithText(displayName).fetchSemanticsNodes().isNotEmpty()) return
            Thread.sleep(250)
        }
        throw AssertionError("Session row for $displayName never appeared")
    }

    /** Drive the dispatcher the edge swipe and the back key both arrive on. */
    private fun pressBack() {
        compose.activityRule.scenario.onActivity { it.onBackPressedDispatcher.onBackPressed() }
        compose.waitForIdle()
    }

    private fun waitForTag(tag: String) {
        compose.waitUntil(timeoutMillis = 15_000) {
            compose.onAllNodesWithTag(tag).fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun waitForText(text: String) {
        compose.waitUntil(timeoutMillis = 15_000) {
            compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
        }
    }
}
