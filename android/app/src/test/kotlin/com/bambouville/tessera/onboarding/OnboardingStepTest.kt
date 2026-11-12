package com.bambouville.tessera.onboarding

import com.bambouville.tessera.R
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingStepTest {
    @Test
    fun theElevenStepsKeepTheIPhoneOrderWithAgentCenterOnOrOff() {
        val expected = listOf(
            OnboardingStepID.AddHost, OnboardingStepID.Keys, OnboardingStepID.Tmux, OnboardingStepID.AgentCenter,
            OnboardingStepID.SwipePad, OnboardingStepID.Files, OnboardingStepID.Artifacts, OnboardingStepID.OpenInArtifacts,
            OnboardingStepID.Share, OnboardingStepID.Screenshot, OnboardingStepID.TerminalControls,
        )
        for (enabled in listOf(false, true)) {
            val steps = onboardingSteps(enabled)
            assertEquals(11, steps.size)
            assertEquals(expected, steps.map { it.id })
            assertTrue(steps.all { it.title != 0 && it.body != 0 })
            assertTrue(steps.all { it.target != null || it.illustration != null })
        }
    }

    @Test
    fun spotlightsFollowTheNewPlacesAndAgentCenterPreference() {
        val enabled = onboardingSteps(true)
        assertEquals(OnboardingTarget.AddHost, enabled[0].target)
        assertEquals(OnboardingTarget.Settings, enabled[1].target)
        assertEquals(OnboardingTarget.Agents, enabled[3].target)
        assertEquals(OnboardingTarget.Artifacts, enabled[6].target)
        assertNull(onboardingSteps(false)[3].target)
        assertEquals(OnboardingIllustration.Agents, onboardingSteps(false)[3].illustration)
        assertNotNull(enabled[1].illustration) // Centered fallback still teaches keys when settings is off screen.
    }

    @Test
    fun showMeRunsOnlyStepsTwoSixSevenAndEightInWalkthroughOrder() {
        val expected = listOf(OnboardingStepID.Keys, OnboardingStepID.Files, OnboardingStepID.Artifacts, OnboardingStepID.OpenInArtifacts)
        for (enabled in listOf(false, true)) {
            val full = onboardingSteps(enabled)
            assertEquals(expected, whatsNewSteps(enabled).map { it.id })
            assertEquals(listOf(full[1], full[5], full[6], full[7]), whatsNewSteps(enabled))
        }
    }

    @Test
    fun androidUsesItsMenusAndControlsInsteadOfAnUnshippedSwipePadOrShortcutGrid() {
        val steps = onboardingSteps(false)
        assertEquals(OnboardingIllustration.PromptControls, steps[4].illustration)
        assertEquals(OnboardingIllustration.OpenInArtifacts, steps[7].illustration)
        assertEquals(R.string.app_onboarding_open_body, steps[7].body)
        assertEquals(R.string.app_onboarding_screenshot_body, steps[9].body)
        assertEquals(OnboardingIllustration.TerminalControls, steps.last().illustration)
        assertEquals(R.string.app_onboarding_controls_body, steps.last().body)
    }
}
