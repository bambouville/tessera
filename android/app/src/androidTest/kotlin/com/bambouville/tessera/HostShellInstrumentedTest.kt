package com.bambouville.tessera

import android.content.Context
import android.view.inputmethod.InputMethodManager
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performImeAction
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.data.AndroidHostRepository
import com.bambouville.tessera.data.AndroidIdentityRepository
import com.bambouville.tessera.lifecycle.DiagnosticLogStore
import com.bambouville.tessera.security.AndroidKeystoreCredentialStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.After
import com.bambouville.tessera.feature.session.LiveSessionStore

@RunWith(AndroidJUnit4::class)
class HostShellInstrumentedTest {
    @get:Rule
    val compose = createAndroidComposeRule<MainActivity>()

    /**
     * Same reason as `BackNavigationInstrumentedTest`: a class that launches the
     * app shell leaves the process with no live sessions behind it, because
     * sessions no longer end with the Activity that showed them.
     */
    @After
    fun endEverySessionThisClassOpened() {
        LiveSessionStore.resetForTests()
    }

    @Test
    fun savedHostSurvivesRecreationWithoutAutomationStartingConnection() {
        val token = System.currentTimeMillis().toString()
        val displayName = "Fixture $token"
        val hostname = "fixture-$token.example"
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AndroidHostRepository(context)

        try {
            waitForContentDescription("Add host")
            compose.onNodeWithContentDescription("Add host").performClick()
            compose.onNodeWithTag("host-name").performTextReplacement(displayName)
            compose.onNodeWithTag("host-address").performTextReplacement(hostname)
            compose.onNodeWithTag("host-username").performTextReplacement("tester")
            compose.onNodeWithTag("host-port").performTextReplacement("2222")
            compose.onNodeWithText("Save", useUnmergedTree = true).performClick()
            waitForText(displayName)
            compose.onNodeWithText(displayName).assertIsDisplayed()

            compose.activityRule.scenario.recreate()
            waitForText(displayName)
            compose.onNodeWithText(displayName).assertIsDisplayed()
            // A Hosts-row tap now starts its real transport immediately. UI
            // automation must not initiate a connection, so this persistence
            // test stops at the human-testable row instead of encoding the old
            // broken Disconnected-first behavior.

            runBlocking {
                val saved = repository.observeHosts().first().firstOrNull { it.hostname == hostname }
                assertNotNull(saved)
            }
        } finally {
            runBlocking {
                repository.observeHosts().first().firstOrNull { it.hostname == hostname }?.let {
                    repository.delete(it.id)
                }
            }
        }
    }

    @Test
    fun generatedIdentityExposesPublicKeyAndAppearsInHostAuthenticationPicker() {
        val token = System.currentTimeMillis().toString()
        val keyName = "Device key $token"
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val identities = AndroidIdentityRepository(context)
        val keyStore = AndroidKeystoreCredentialStore()

        try {
            compose.onNodeWithTag("root-keys").performClick()
            compose.onNodeWithTag("identity-name")
                .performClick()
                .performTextReplacement(keyName)
            compose.onNodeWithTag("identity-name").assertTextEquals(keyName)
            compose.waitForIdle()
            compose.onNodeWithTag("identity-generate").assertIsEnabled()
            compose.onNodeWithTag("identity-name").performImeAction()
            compose.waitForIdle()

            val identity = runBlocking {
                withTimeout(15_000) {
                    identities.observeIdentities()
                        .first { values -> values.any { it.displayName == keyName } }
                        .first { it.displayName == keyName }
                }
            }
            compose.waitForIdle()
            compose.onNodeWithTag("identity-details-${identity.id}")
                .performScrollTo()
                .assertIsDisplayed()
                .assertIsEnabled()
                .performClick()
            compose.onNodeWithTag("identity-details-dialog")
                .assertIsDisplayed()
            waitForText("Copy key")
            compose.onNodeWithText("Copy key").assertIsDisplayed()
            compose.onNodeWithText("Install on host").assertIsDisplayed()
            compose.onNodeWithText("Done").performClick()

            compose.onNodeWithTag("root-hosts").performClick()
            waitForContentDescription("Add host")
            compose.onNodeWithContentDescription("Add host").performClick()
            compose.onNodeWithTag("host-auth-selector").performClick()
            compose.onNodeWithText(keyName).assertIsDisplayed()
        } finally {
            runBlocking {
                identities.observeIdentities().first().firstOrNull { it.displayName == keyName }?.let { identity ->
                    keyStore.delete(identity.credentialReference)
                    identities.delete(identity.id)
                }
            }
        }
    }

    @Test
    fun settingsExposePairingKnownHostsDiagnosticsAndTerminalPreferences() {
        assertTrue(compose.onAllNodesWithTag("root-pair").fetchSemanticsNodes().isEmpty())
        compose.onNodeWithTag("root-settings").performClick()
        waitForText("sync & continuity")
        compose.onNodeWithText("sync & continuity").assertIsDisplayed().performClick()
        waitForText("pair another device")
        compose.onNodeWithText("pair another device").performClick()
        waitForText("pair another device")
        compose.onNodeWithText("pair another device").assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").performClick()

        waitForText("security")
        compose.onNodeWithText("security").performClick()
        compose.onNodeWithText("known hosts").assertIsDisplayed()
        compose.onNodeWithContentDescription("back to settings").performClick()

        waitForText("diagnostics")
        compose.onNodeWithText("diagnostics").performClick()
        // The report is handed off as a file and never drawn: the page shows its
        // size and last write, and the export action is live once app_launch
        // has been recorded.
        waitForText("refresh")
        compose.onNodeWithText("debug log").assertIsDisplayed()
        compose.onNodeWithText("updated", substring = true).assertIsDisplayed()
        compose.onNodeWithText("export log").assertIsDisplayed().assertIsEnabled()
        compose.onNodeWithContentDescription("back to settings").performClick()

        waitForText("terminal")
        compose.onNodeWithText("terminal").performClick()
        compose.onNodeWithText("text size").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("13sp").performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription("back to settings").performClick()

        compose.onNodeWithText("sync & continuity").performClick()
        compose.waitUntil(timeoutMillis = 15_000) {
            compose.onAllNodesWithText("restore on launch").fetchSemanticsNodes().isNotEmpty() ||
                compose.onAllNodesWithText("previous connections").fetchSemanticsNodes().isNotEmpty()
        }
        val restoreToggle = compose.onAllNodesWithText("restore on launch").fetchSemanticsNodes()
        if (restoreToggle.isNotEmpty()) {
            compose.onNodeWithText("restore on launch").performScrollTo().assertIsDisplayed()
        } else {
            compose.onNodeWithText("previous connections").performScrollTo().assertIsDisplayed()
        }
    }

    @Test
    fun diagnosticsExportIncludesRotatedHistoryAndRedactsSecrets() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val first = DiagnosticLogStore(context)
        val second = DiagnosticLogStore(context)
        first.clear()
        try {
            first.record("before_rotation", mapOf("detail" to "token=do-not-export delivery=17"))
            repeat(3_200) { index ->
                val store = if (index % 2 == 0) first else second
                store.record("fill", mapOf("detail" to "x".repeat(160)))
            }
            second.record("after_rotation", mapOf("detail" to "password=also-secret"))
            second.record(
                "pairing_import_recorded",
                mapOf("role" to "recipient", "purpose" to "setUpAndContinue", "hosts" to "2", "result" to "staged"),
            )

            val report = first.read()
            assertTrue(report.contains("before_rotation"))
            assertTrue(report.contains("after_rotation"))
            assertTrue(report.contains("token=<redacted>"))
            assertTrue(report.contains("delivery=17"))
            assertTrue(report.contains("password=<redacted>"))
            assertTrue(report.contains("pairing_import_recorded role=recipient purpose=setUpAndContinue hosts=2 result=staged"))
            assertFalse(report.contains("do-not-export"))
            assertFalse(report.contains("also-secret"))
        } finally {
            first.clear()
        }
    }

    /**
     * The host editor is a full-screen form, and its route/authentication pickers own
     * their own surfaces. This is the regression guard for the defect that motivated
     * that change: the anchored dropdown used to open on top of the dialog's own
     * Save and Cancel row, so a selection could not be confirmed.
     */
    @Test
    fun hostEditorPickersAndActionsStayReachableTogether() {
        val token = System.currentTimeMillis().toString()
        val hostname = "picker-$token.example"
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = AndroidHostRepository(context)

        try {
            waitForContentDescription("Add host")
            compose.onNodeWithContentDescription("Add host").performClick()
            compose.onNodeWithTag("host-name").performTextReplacement("Picker $token")
            compose.onNodeWithTag("host-address").performTextReplacement(hostname)
            compose.onNodeWithTag("host-username").performTextReplacement("tester")

            // The form is its own dialog window, so the keyboard belongs to that
            // window's focused field: hiding through the activity's token fails
            // ("onFailed at PHASE_CLIENT_VIEW_SERVED") and left the keyboard up,
            // still animating in while the selector was scrolled into place.
            // The click then landed on the keyboard and no picker opened.
            compose.activityRule.scenario.onActivity { activity ->
                val focused = android.view.inspector.WindowInspector.getGlobalWindowViews()
                    .firstOrNull { it.hasWindowFocus() }
                    ?.findFocus()
                val input = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                assertTrue("no focused field to dismiss the keyboard from", focused != null)
                input.hideSoftInputFromWindow(focused!!.windowToken, 0)
            }
            // UiAutomation lists no windows at all until it opts in, so an
            // unflagged "no input-method window" check passes vacuously.
            val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
            automation.serviceInfo = automation.serviceInfo.apply {
                flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
            compose.waitUntil(timeoutMillis = 10_000) {
                // An empty list means no windows were read, not that the keyboard left.
                val windows = automation.windows
                windows.isNotEmpty() &&
                    windows.none { it.type == android.view.accessibility.AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            }
            compose.waitForIdle()
            compose.onNodeWithTag("host-auth-selector").performScrollTo().performClick()
            // The open selector and the dialog option intentionally share the same
            // visible label. Wait for the second node so this does not race the
            // picker-dialog composition after clicking the already-visible field.
            compose.waitUntil(timeoutMillis = 15_000) {
                compose.onAllNodesWithText("Password for each connection")
                    .fetchSemanticsNodes().size >= 2
            }
            compose.onAllNodesWithText("Password for each connection")[1].performClick()

            // Both actions remain hit-testable with the picker dismissed and the form
            // still populated.
            compose.onNodeWithText("Cancel", useUnmergedTree = true).assertIsDisplayed()
            compose.onNodeWithText("Save", useUnmergedTree = true).performClick()

            waitForText("Picker $token")
            compose.onNodeWithText("Picker $token").assertIsDisplayed()
        } finally {
            runBlocking {
                repository.observeHosts().first().firstOrNull { it.hostname == hostname }?.let {
                    repository.delete(it.id)
                }
            }
        }
    }

    private fun waitForContentDescription(description: String) {
        compose.waitUntil(timeoutMillis = 15_000) {
            compose.onAllNodesWithContentDescription(description)
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
    }

    private fun waitForText(text: String, useUnmergedTree: Boolean = false) {
        compose.waitUntil(timeoutMillis = 15_000) {
            compose.onAllNodesWithText(text, useUnmergedTree = useUnmergedTree)
                .fetchSemanticsNodes()
                .isNotEmpty()
        }
    }
}
