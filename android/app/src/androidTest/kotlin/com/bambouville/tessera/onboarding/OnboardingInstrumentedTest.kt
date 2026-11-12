package com.bambouville.tessera.onboarding

import androidx.activity.OnBackPressedDispatcher
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.AboutSettings
import com.bambouville.tessera.data.AppPreferences
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OnboardingInstrumentedTest {
    @get:Rule
    val compose = createComposeRule()

    private lateinit var controller: OnboardingController
    private lateinit var backDispatcher: OnBackPressedDispatcher
    private var receipts = 0

    @Composable
    private fun testController(snapshot: AppPreferences? = AppPreferences()): OnboardingController {
        val scope = rememberCoroutineScope()
        backDispatcher = requireNotNull(LocalOnBackPressedDispatcherOwner.current).onBackPressedDispatcher
        controller = remember {
            OnboardingController(scope) { receipts += 1 }.also { value -> snapshot?.let(value::updatePreferences) }
        }
        return controller
    }

    @Test
    fun delayedPreferencesDoNotFlashTheWelcomeToAnUpdater() {
        compose.setContent {
            TesseraTheme {
                OnboardingHost(testController(snapshot = null), hostCount = 0, blocked = false, onNavigate = {}) { }
            }
        }
        compose.onNodeWithText("welcome to Tessera").assertDoesNotExist()
        compose.onNodeWithText("what's new in 0.4.1").assertDoesNotExist()
        compose.runOnIdle {
            controller.updatePreferences(AppPreferences(hasSeenWelcome = true, lastSeenWhatsNewVersion = "0.4.0"))
        }
        compose.onNodeWithText("what's new in 0.4.1").assertIsDisplayed()
        compose.onNodeWithText("welcome to Tessera").assertDoesNotExist()
    }

    @Test
    fun welcomeWaitsBehindABlockerAndSkipRequestsACompletionReceipt() {
        val blocked = mutableStateOf(true)
        compose.setContent {
            TesseraTheme {
                OnboardingHost(testController(), hostCount = 0, blocked = blocked.value, onNavigate = {}) { }
            }
        }
        compose.onNodeWithText("welcome to Tessera").assertDoesNotExist()
        compose.runOnIdle { blocked.value = false }
        compose.onNodeWithText("welcome to Tessera").assertIsDisplayed()
        compose.onNodeWithText("skip").performClick()
        compose.onNodeWithText("welcome to Tessera").assertDoesNotExist()
        compose.runOnIdle {
            assertEquals(1, receipts)
            assertEquals(OnboardingPhase.Inactive, controller.phase)
            // Simulate the atomic DataStore receipt arriving, then a modal opening/closing.
            controller.updatePreferences(AppPreferences(hasSeenWelcome = true, lastSeenWhatsNewVersion = WHATS_NEW_VERSION))
            blocked.value = true
        }
        compose.runOnIdle { blocked.value = false }
        compose.onNodeWithText("what's new in 0.4.1").assertDoesNotExist()
    }

    @Test
    fun showMeRecordsSeenAndUsesOnlyTheFourMovedAndNewSteps() {
        compose.setContent {
            TesseraTheme {
                OnboardingHost(testController(), hostCount = 1, blocked = false, onNavigate = {}) { }
            }
        }
        compose.onNodeWithText("what's new in 0.4.1").assertIsDisplayed()
        compose.onNodeWithText("show me").performClick()
        compose.runOnIdle { assertEquals(1, receipts) }
        listOf("keys, protected your way", "files from your phone", "artifacts", "open in artifacts").forEachIndexed { index, title ->
            compose.onNodeWithText(title).assertIsDisplayed()
            compose.onNodeWithText(if (index == 3) "done" else "next").performClick()
        }
        compose.onNodeWithTag("onboarding-centered").assertDoesNotExist()
    }

    @Test
    fun releaseDoneRecordsSeenWithoutStartingATour() {
        compose.setContent {
            TesseraTheme {
                OnboardingHost(testController(), hostCount = 1, blocked = false, onNavigate = {}) { }
            }
        }
        compose.onNodeWithText("done").performClick()
        compose.runOnIdle {
            assertEquals(1, receipts)
            assertEquals(OnboardingPhase.Inactive, controller.phase)
        }
    }

    @Test
    fun completingTheWelcomeTourRequestsItsReceiptOnlyAtTheEnd() {
        compose.setContent {
            TesseraTheme {
                OnboardingHost(testController(), hostCount = 0, blocked = false, onNavigate = {}) { }
            }
        }
        compose.onNodeWithText("start the tour").performClick()
        compose.runOnIdle { assertEquals(0, receipts) }
        repeat(10) { compose.onNodeWithText("next").performClick() }
        compose.onNodeWithText("terminal controls").assertIsDisplayed()
        compose.onNodeWithText("done").performClick()
        compose.runOnIdle {
            assertEquals(1, receipts)
            assertEquals(OnboardingPhase.Inactive, controller.phase)
        }
    }

    @Test
    fun tourUsesRegisteredBoundsAndBackGestureReturnsToThePreviousStep() {
        val navigations = mutableListOf<OnboardingTarget>()
        compose.setContent {
            TesseraTheme {
                OnboardingHost(
                    testController(AppPreferences(hasSeenWelcome = true, lastSeenWhatsNewVersion = WHATS_NEW_VERSION)),
                    hostCount = 1, blocked = false, onNavigate = { navigations += it },
                ) {
                    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                        TesseraButton("add host", {}, Modifier.align(Alignment.BottomCenter).onboardingAnchor(OnboardingTarget.AddHost))
                    }
                }
            }
        }
        compose.runOnIdle { controller.replayWalkthrough() }
        compose.onNodeWithTag("onboarding-spotlight").assertExists()
        compose.onNodeWithText("next").performClick()
        compose.onNodeWithText("keys, protected your way").assertIsDisplayed()
        compose.onNodeWithTag("onboarding-centered").assertExists()
        compose.runOnIdle { backDispatcher.onBackPressed() }
        compose.onNodeWithText("add your first host").assertIsDisplayed()
        compose.runOnIdle { assertEquals(listOf(OnboardingTarget.AddHost, OnboardingTarget.Settings, OnboardingTarget.AddHost), navigations) }
    }

    @Test
    fun anAnchorOutsideTheWindowUsesTheCenteredFallback() {
        compose.setContent {
            TesseraTheme {
                OnboardingHost(
                    testController(AppPreferences(hasSeenWelcome = true, lastSeenWhatsNewVersion = WHATS_NEW_VERSION)),
                    hostCount = 1, blocked = false, onNavigate = {},
                ) {
                    TesseraButton("add host", {}, Modifier.offset(y = (-10_000).dp).onboardingAnchor(OnboardingTarget.AddHost))
                }
            }
        }
        compose.runOnIdle { controller.replayWalkthrough() }
        compose.onNodeWithTag("onboarding-centered").assertIsDisplayed()
        compose.onNodeWithTag("onboarding-spotlight").assertDoesNotExist()
    }

    @Test
    fun activeTourSuspendsWithoutLosingItsStepOrNavigatingWhileBlocked() {
        val blocked = mutableStateOf(true)
        val navigations = mutableListOf<OnboardingTarget>()
        compose.setContent {
            TesseraTheme {
                OnboardingHost(testController(), hostCount = 0, blocked = blocked.value, onNavigate = { navigations += it }) { }
            }
        }
        compose.runOnIdle { controller.replayWalkthrough() }
        compose.onNodeWithText("add your first host").assertDoesNotExist()
        compose.runOnIdle {
            assertTrue(navigations.isEmpty())
            blocked.value = false
        }
        compose.onNodeWithText("next").performClick()
        compose.runOnIdle { blocked.value = true }
        compose.onNodeWithText("keys, protected your way").assertDoesNotExist()
        compose.runOnIdle { blocked.value = false }
        compose.onNodeWithText("keys, protected your way").assertIsDisplayed()
        compose.onNodeWithContentDescription("back").assertIsDisplayed()
    }

    @Test
    fun keyboardFocusCannotEnterTheShellThroughThePassiveOverlay() {
        val shellFocus = FocusRequester()
        var shellFocused = false
        var shellClicks = 0
        compose.setContent {
            TesseraTheme {
                OnboardingHost(
                    testController(AppPreferences(hasSeenWelcome = true, lastSeenWhatsNewVersion = WHATS_NEW_VERSION)),
                    hostCount = 1, blocked = false, onNavigate = {},
                ) {
                    TesseraButton("shell action", { shellClicks += 1 }, Modifier
                        .focusProperties { canFocus = true }
                        .focusRequester(shellFocus)
                        .onFocusChanged { shellFocused = it.isFocused })
                }
            }
        }
        compose.runOnIdle { shellFocus.requestFocus() }
        compose.runOnIdle {
            assertTrue("The oracle must first prove that the shell button can take focus", shellFocused)
            controller.replayWalkthrough()
        }
        compose.onNodeWithText("add your first host").assertIsDisplayed()
        compose.runOnIdle {
            shellFocus.requestFocus()
            assertFalse(shellFocused)
        }
        compose.onRoot().performKeyInput {
            repeat(20) { pressKey(Key.Tab) }
            pressKey(Key.Enter)
        }
        compose.runOnIdle {
            assertFalse(shellFocused)
            assertEquals(0, shellClicks)
        }
    }

    @Test
    fun aboutHidesRowsWithoutAControllerAndRoutesBothActionsWhenProvided() {
        val provided = mutableStateOf(false)
        compose.setContent {
            TesseraTheme {
                val value = testController()
                CompositionLocalProvider(LocalOnboardingController provides if (provided.value) value else null) {
                    AboutSettings(Modifier.verticalScroll(rememberScrollState()))
                }
            }
        }
        compose.onNodeWithText("replay walkthrough").assertDoesNotExist()
        compose.onNodeWithText("what's new in 0.4.1").assertDoesNotExist()
        compose.runOnIdle { provided.value = true }
        compose.onNodeWithText("replay walkthrough").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(OnboardingPhase.Touring, controller.phase) }
        compose.onNodeWithText("what's new in 0.4.1").performScrollTo().performClick()
        compose.runOnIdle { assertEquals(OnboardingPhase.WhatsNew, controller.phase) }
    }
}
