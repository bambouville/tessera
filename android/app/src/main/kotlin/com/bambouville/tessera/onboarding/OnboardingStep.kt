package com.bambouville.tessera.onboarding

import androidx.annotation.StringRes
import com.bambouville.tessera.R

enum class OnboardingTarget { AddHost, Hosts, Sessions, Agents, Artifacts, Settings }

internal const val WHATS_NEW_VERSION = "0.4.1"

internal enum class OnboardingPresentation { None, Welcome, WhatsNew }

/** No UI or storage dependencies: fresh installs take the welcome lane, including after a skipped tour. */
internal fun onboardingPresentation(
    hostCount: Int,
    hasSeenWelcome: Boolean,
    lastSeenWhatsNewVersion: String?,
    blocked: Boolean = false,
): OnboardingPresentation = when {
    blocked || hostCount < 0 -> OnboardingPresentation.None
    !hasSeenWelcome && hostCount == 0 -> OnboardingPresentation.Welcome
    hasSeenArtifactsRelease(lastSeenWhatsNewVersion) -> OnboardingPresentation.None
    else -> OnboardingPresentation.WhatsNew
}

/** An older app must not replace a receipt from a newer release with its own card. */
private fun hasSeenArtifactsRelease(version: String?): Boolean {
    val parts = version?.split('.')?.map { it.toIntOrNull() ?: return false } ?: return false
    if (parts.size != 3 || parts.any { it < 0 }) return false
    return parts[0] > 0 || parts[1] > 4 || (parts[1] == 4 && parts[2] >= 1)
}

internal enum class OnboardingStepID {
    AddHost, Keys, Tmux, AgentCenter, SwipePad, Files, Artifacts, OpenInArtifacts, Share, Screenshot, TerminalControls,
}

internal enum class OnboardingIllustration { Keys, Tmux, Agents, PromptControls, Files, OpenInArtifacts, Share, Screenshot, TerminalControls }

internal data class OnboardingStep(
    val id: OnboardingStepID,
    @param:StringRes val title: Int,
    @param:StringRes val body: Int,
    val target: OnboardingTarget? = null,
    val illustration: OnboardingIllustration? = null,
)

/** A6's eleven iPhone steps, with copy checked against Android's actual controls. */
internal fun onboardingSteps(agentCenterEnabled: Boolean): List<OnboardingStep> = listOf(
    OnboardingStep(
        OnboardingStepID.AddHost,
        R.string.app_onboarding_add_host_title,
        R.string.app_onboarding_add_host_body,
        target = OnboardingTarget.AddHost,
    ),
    OnboardingStep(
        OnboardingStepID.Keys,
        R.string.app_onboarding_keys_title,
        R.string.app_onboarding_keys_body,
        target = OnboardingTarget.Settings,
        illustration = OnboardingIllustration.Keys,
    ),
    OnboardingStep(
        OnboardingStepID.Tmux,
        R.string.app_onboarding_tmux_title,
        R.string.app_onboarding_tmux_body,
        illustration = OnboardingIllustration.Tmux,
    ),
    OnboardingStep(
        OnboardingStepID.AgentCenter,
        R.string.app_agent_center,
        R.string.app_onboarding_agents_body,
        target = if (agentCenterEnabled) OnboardingTarget.Agents else null,
        illustration = OnboardingIllustration.Agents,
    ),
    // Android has no radial Swipe Pad. Keep its place in the tour and teach the shipped prompt controls.
    OnboardingStep(
        OnboardingStepID.SwipePad,
        R.string.app_onboarding_prompts_title,
        R.string.app_onboarding_prompts_body,
        illustration = OnboardingIllustration.PromptControls,
    ),
    OnboardingStep(
        OnboardingStepID.Files,
        R.string.app_onboarding_files_title,
        R.string.app_onboarding_files_body,
        illustration = OnboardingIllustration.Files,
    ),
    OnboardingStep(
        OnboardingStepID.Artifacts,
        R.string.app_tab_artifacts,
        R.string.app_onboarding_artifacts_body,
        target = OnboardingTarget.Artifacts,
    ),
    OnboardingStep(
        OnboardingStepID.OpenInArtifacts,
        R.string.app_onboarding_open_title,
        R.string.app_onboarding_open_body,
        illustration = OnboardingIllustration.OpenInArtifacts,
    ),
    OnboardingStep(
        OnboardingStepID.Share,
        R.string.app_onboarding_share_title,
        R.string.app_onboarding_share_body,
        illustration = OnboardingIllustration.Share,
    ),
    OnboardingStep(
        OnboardingStepID.Screenshot,
        R.string.app_onboarding_screenshot_title,
        R.string.app_onboarding_screenshot_body,
        illustration = OnboardingIllustration.Screenshot,
    ),
    OnboardingStep(
        OnboardingStepID.TerminalControls,
        R.string.app_onboarding_controls_title,
        R.string.app_onboarding_controls_body,
        illustration = OnboardingIllustration.TerminalControls,
    ),
)

internal fun whatsNewSteps(agentCenterEnabled: Boolean): List<OnboardingStep> =
    onboardingSteps(agentCenterEnabled).filter { it.id in WhatsNewStepIDs }

private val WhatsNewStepIDs = setOf(
    OnboardingStepID.Keys, OnboardingStepID.Files, OnboardingStepID.Artifacts, OnboardingStepID.OpenInArtifacts,
)
