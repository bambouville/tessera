package com.bambouville.tessera.feature.session.bell

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BellPolicyTest {
    private val preferences = BellPreferences(
        soundEnabled = true,
        visualEnabled = true,
        notificationEnabled = true,
    )

    @Test
    fun foregroundOffscreenBellGlowsSoundsAndMarksUnreadWithoutNotification() {
        val decision = BellPolicy.decide(
            BellEvent(BellSource.TmuxWindow("session-a", 7), false, "dev", "build"),
            preferences,
            BellAppVisibility.FOREGROUND,
        )

        assertTrue(decision.playSound)
        assertTrue(decision.showVisual)
        assertFalse(decision.postBackgroundNotification)
        assertTrue(decision.markSessionUnread)
    }

    @Test
    fun backgroundBellPostsSilentNotificationAndDoesNotPretendToGlow() {
        val decision = BellPolicy.decide(
            BellEvent(BellSource.Session("session-a"), true, "dev"),
            preferences,
            BellAppVisibility.BACKGROUND,
        )

        assertTrue(decision.playSound)
        assertFalse(decision.showVisual)
        assertTrue(decision.postBackgroundNotification)
        assertTrue(decision.markSessionUnread)
    }

    @Test
    fun limiterIsPerSourceAndUnreadClearsOnlyTheOpenedSession() {
        var now = 100L
        val limiter = BellRateLimiter(BellClock { now })
        val first = BellSource.TmuxWindow("session-a", 1)
        val other = BellSource.TmuxWindow("session-a", 2)
        assertTrue(limiter.admit(first))
        assertFalse(limiter.admit(first))
        assertTrue(limiter.admit(other))
        now += 2_000
        assertTrue(limiter.admit(first))

        val unread = BellUnreadStore()
        unread.markUnread(first)
        unread.markUnread(other)
        unread.markUnread(BellSource.Session("session-b"))
        assertTrue(unread.state.value.isUnread("session-a"))
        assertTrue(unread.state.value.isUnread("session-b"))
        assertTrue(unread.state.value.isWindowUnread("session-a", 1))
        assertTrue(unread.state.value.isWindowUnread("session-a", 2))
        unread.markSessionRead("session-a")
        assertTrue(unread.state.value.isUnread("session-a"))
        unread.markTmuxWindowRead("session-a", 1)
        assertTrue(unread.state.value.isUnread("session-a"))
        assertFalse(unread.state.value.isWindowUnread("session-a", 1))
        assertTrue(unread.state.value.isWindowUnread("session-a", 2))
        unread.markTmuxWindowRead("session-a", 2)
        assertFalse(unread.state.value.isUnread("session-a"))
        assertTrue(unread.state.value.isUnread("session-b"))
    }
}
