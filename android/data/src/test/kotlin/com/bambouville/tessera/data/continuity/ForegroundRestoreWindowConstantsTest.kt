package com.bambouville.tessera.data.continuity

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The window's clock, pinned to iOS's.
 *
 * Nothing is broken here today. It exists because the two platforms arrive at
 * these numbers differently and only one of them can notice a change: on iOS
 * the backstop is *derived* — the SSH handshake budget plus a twenty-second
 * margin — and a test pins that ordering, so a session wedged in `connecting`
 * always reaches its watchdog verdict before it loses its cohort place.
 * Android has no connect budget to derive from, so its backstop is a plain
 * constant chosen to match. If iOS's budget moves, nothing on either side
 * notices unless this fails.
 *
 * The alive floor is not a tuning knob either: it stands in for the
 * reachability signal plain SSH does not have, and it is the only reason a
 * transport that died four milliseconds ago is not scored alive.
 */
class ForegroundRestoreWindowConstantsTest {
    @Test
    fun theAliveFloorMatchesIOS() {
        assertEquals(5_000L, ForegroundRestoreWindow.ALIVE_FLOOR_MILLISECONDS)
    }

    @Test
    fun theBackstopMatchesIOSDerivedBudget() {
        // iOS: SSHSession.handshakeBudgetSeconds (40) + 20.
        assertEquals(60_000L, ForegroundRestoreWindow.MAX_WINDOW_MILLISECONDS)
    }

    @Test
    fun theTickIsFastEnoughToSeeAVerdictWithinTheFloor() {
        assertEquals(500L, ForegroundRestoreWindow.TICK_MILLISECONDS)
        assertEquals(
            "the window must get several passes inside the alive floor",
            true,
            ForegroundRestoreWindow.ALIVE_FLOOR_MILLISECONDS
                / ForegroundRestoreWindow.TICK_MILLISECONDS >= 4,
        )
    }

    @Test
    fun aSingleChargeStepIsClampedLikeTheConnectWatchdog() {
        // A larger gap means the process was suspended, not that time was
        // spent waiting on this wake.
        assertEquals(2_000L, ForegroundRestoreWindow.MAX_CHARGE_MILLISECONDS)
    }
}
