package com.bambouville.tessera.onboarding

import org.junit.Assert.assertEquals
import org.junit.Test

class OnboardingPolicyTest {
    @Test
    fun firstPresentationMatrixSeparatesNewInstallsFromUpdates() {
        val versions = listOf(null, "", "0.3.9", "0.4.0", "0.4.1", "0.4.2", "0.5.0", "1.0.0", "invalid")
        val seenVersions = setOf("0.4.1", "0.4.2", "0.5.0", "1.0.0")
        for (hostCount in listOf(0, 1, 5)) {
            for (hasSeenWelcome in listOf(false, true)) {
                for (version in versions) {
                    val expected = when {
                        hostCount == 0 && !hasSeenWelcome -> OnboardingPresentation.Welcome
                        version in seenVersions -> OnboardingPresentation.None
                        else -> OnboardingPresentation.WhatsNew
                    }
                    assertEquals(
                        "hosts=$hostCount, welcome=$hasSeenWelcome, version=$version",
                        expected,
                        onboardingPresentation(hostCount, hasSeenWelcome, version),
                    )
                }
            }
        }
    }

    @Test
    fun appLockSetupPairingAndModalsBlockEveryLane() {
        for (hostCount in listOf(0, 1, 5)) {
            for (hasSeenWelcome in listOf(false, true)) {
                for (version in listOf(null, "0.4.0", "0.4.1")) {
                    assertEquals(OnboardingPresentation.None, onboardingPresentation(hostCount, hasSeenWelcome, version, blocked = true))
                }
            }
        }
    }

    @Test
    fun unloadedHostsWaitInsteadOfBeingMistakenForANewInstall() {
        assertEquals(OnboardingPresentation.None, onboardingPresentation(-1, false, null))
    }

    @Test
    fun completedOrSkippedWelcomeSuppressesTheReleaseCardWithOrWithoutHosts() {
        for (hostCount in listOf(0, 1, 5)) {
            assertEquals(OnboardingPresentation.None, onboardingPresentation(hostCount, true, WHATS_NEW_VERSION))
        }
    }

    @Test
    fun malformedReceiptsCannotHideTheReleaseCardFromAnUpdater() {
        for (version in listOf("0.4", "0.4.1.2", "0.-4.1", "0.4.-1", "0.4.1x", "999999999999.4.1")) {
            assertEquals(version, OnboardingPresentation.WhatsNew, onboardingPresentation(1, true, version))
        }
    }
}
