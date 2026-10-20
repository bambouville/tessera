package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.*
import org.junit.Assert.*
import org.junit.Test

/** R3's clock is owned by the real shared session. */
class TmuxAuthorityIntentClockTest {
    @Test fun anIntentExpiresTwentySecondsAfterItBegan() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        s.shown(1000); assertEquals(21000L, s.state.nextDeadlineMillis)
        assertNotNull(s.tick(20999).state.pendingIntent); assertNull(s.tick(21000).state.pendingIntent)
    }
    @Test fun theSameTokenKeepsItsDeadlineAndANewOneRestarts() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        s.shown(0); val token = s.state.pendingIntent!!.token
        s.channelLiveness(15000, false); assertEquals(token, s.state.pendingIntent!!.token)
        assertEquals(20000L, s.state.nextDeadlineMillis); assertNull(s.tick(20000).state.pendingIntent)
        s.shown(20000); assertNotNull(s.tick(39999).state.pendingIntent); assertNull(s.tick(40000).state.pendingIntent)
    }
    @Test fun aPromptPausesTheClockAndTheTimeSpentDoesNotCount() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        s.shown(0); s.prompt(5000, SharedTmuxAuthorityPromptScope.SESSION, true)
        assertNull(s.state.nextDeadlineMillis); assertNotNull(s.tick(60000).state.pendingIntent)
        s.prompt(65000, SharedTmuxAuthorityPromptScope.SESSION, false)
        assertEquals(85000L, s.state.nextDeadlineMillis)
        assertNotNull(s.tick(84999).state.pendingIntent); assertNull(s.tick(85000).state.pendingIntent)
    }
    @Test fun answeringAPromptOrRetryRestartsTheWindow() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        s.shown(0); s.userStep(18000)
        assertNotNull(s.tick(37999).state.pendingIntent); assertNull(s.tick(38000).state.pendingIntent)
    }
    @Test fun noIntentMeansNothingToExpire() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        s.userStep(1000); assertNull(s.tick(100000).state.pendingIntent)
        s.shown(100001); s.cancelIntent(100002); assertNull(s.tick(200000).state.pendingIntent)
    }
}
