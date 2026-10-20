package com.bambouville.tessera.data.continuity

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Removing Tessera's task from recents must not overrule the restore setting.
 *
 * This is the divergence from iOS: there, a force-quit from the app switcher is
 * just a termination and the next launch restores. On Android the same gesture
 * currently deletes both restore stores outright, so the most natural way a
 * user tests "restart the app" is guaranteed to restore nothing.
 *
 * The device-level twin is
 * `SessionRestoreLifecycleInstrumentedTest.removingTheTaskKeepsTheDocumentWhenRestoreIsOn`.
 */
class SessionRestoreTaskRemovalTest {
    @Test
    fun removingTheTaskKeepsTheDocumentWhileRestoreIsOn() {
        assertFalse(SessionRestoreTaskRemoval.retiresStoredSessions(SessionRestorePolicy.ALWAYS))
    }

    @Test
    fun removingTheTaskKeepsTheDocumentWhileRestoreAsks() {
        // "Ask" still means the sessions are worth offering on the next launch.
        // Compact width coerces this to ALWAYS, so on a phone the two cases are
        // the same one; on a tablet the prompt is the whole point of keeping it.
        assertFalse(SessionRestoreTaskRemoval.retiresStoredSessions(SessionRestorePolicy.ASK))
    }

    @Test
    fun removingTheTaskRetiresTheDocumentWhenRestoreIsOff() {
        // The one case where the wipe is right, and the only one that should
        // survive the fix: NEVER already clears the store everywhere else.
        assertTrue(SessionRestoreTaskRemoval.retiresStoredSessions(SessionRestorePolicy.NEVER))
    }
}
