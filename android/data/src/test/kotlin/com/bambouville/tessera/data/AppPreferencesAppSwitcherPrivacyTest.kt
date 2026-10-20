package com.bambouville.tessera.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the cross-platform app-switcher policy (iOS `AppSwitcherPrivacyPolicy`):
 * off by default, an explicit opt-in, and forced on by app lock.
 */
class AppPreferencesAppSwitcherPrivacyTest {
    @Test
    fun untouchedPreferencesLeaveAppSwitcherContentVisible() {
        val defaults = AppPreferences()
        assertFalse(defaults.hideContentInAppSwitcher)
        assertFalse(defaults.hidesContentInAppSwitcher)
    }

    @Test
    fun optInHidesAppSwitcherContent() {
        assertTrue(AppPreferences(hideContentInAppSwitcher = true).hidesContentInAppSwitcher)
    }

    @Test
    fun appLockForcesAppSwitcherPrivacyWithoutRewritingTheOptIn() {
        val locked = AppPreferences(appLockEnabled = true)
        assertTrue(locked.hidesContentInAppSwitcher)
        assertFalse(locked.hideContentInAppSwitcher)
        assertTrue(AppPreferences(appLockEnabled = true, hideContentInAppSwitcher = true).hidesContentInAppSwitcher)
    }
}
