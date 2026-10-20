package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.CoreCallResult
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedChallengeRegistrationTest {
    @Test
    fun youngRegistrationKeepsOriginalIdWithoutReemitting() {
        val clock = TestClock()
        val original = UUID.randomUUID()
        val registration = clock.registration(original)
        clock.nanos += 44_999_999_999L

        assertEquals(original, registration.idForResponse { error("young registration must not renew") })
        assertTrue(registration.matches(original))
    }

    @Test
    fun atOrAfterThresholdRenewsOnceAndMatchesOnlyFreshId() {
        for (ageSeconds in listOf(45L, 60L)) {
            val clock = TestClock()
            val original = UUID.randomUUID()
            val registration = clock.registration(original)
            clock.nanos += ageSeconds * 1_000_000_000L
            val emitted = mutableListOf<UUID>()
            val renewals = mutableListOf<Long>()

            val fresh = registration.idForResponse(onRenewed = { renewals += it }) {
                emitted += it
                CoreCallResult.Accepted
            }

            assertNotEquals(original, fresh)
            assertEquals(listOf(fresh), emitted)
            assertEquals(listOf(ageSeconds), renewals)
            assertTrue(registration.matches(fresh))
            // Only the adopted registration can complete the pending decision.
            assertFalse(registration.matches(original))
        }
    }

    @Test
    fun refusedReemitKeepsOriginalIdAndRegistrationTime() {
        for (refusal in listOf(CoreCallResult.InvalidArguments, CoreCallResult.StaleHandle)) {
            val clock = TestClock()
            val original = UUID.randomUUID()
            val registration = clock.registration(original)
            clock.nanos += 45_000_000_000L
            var refusedId: UUID? = null
            val renewals = mutableListOf<Long>()

            assertEquals(original, registration.idForResponse(onRenewed = { renewals += it }) {
                refusedId = it
                refusal
            })
            assertTrue(registration.matches(original))
            assertFalse(registration.matches(checkNotNull(refusedId)))
            assertTrue(renewals.isEmpty())

            // A refusal must leave the registration old enough to retry immediately.
            var retried = false
            val fresh = registration.idForResponse {
                retried = true
                CoreCallResult.Accepted
            }
            assertTrue(retried)
            assertNotEquals(original, fresh)
        }
    }

    @Test
    fun secondAnswerImmediatelyAfterRenewalDoesNotRenewAgain() {
        val clock = TestClock()
        val registration = clock.registration(UUID.randomUUID())
        clock.nanos += 45_000_000_000L
        val fresh = registration.idForResponse { CoreCallResult.Accepted }
        clock.nanos += 1_000_000_000L

        assertEquals(fresh, registration.idForResponse { error("renewed registration is still young") })
    }

    @Test
    fun renewedRegistrationUsesItsOwnThreshold() {
        val clock = TestClock()
        val registration = clock.registration(UUID.randomUUID())
        clock.nanos += 45_000_000_000L
        val first = registration.idForResponse { CoreCallResult.Accepted }
        clock.nanos += 44_999_999_999L
        assertEquals(first, registration.idForResponse { error("renewal threshold has not elapsed") })
        clock.nanos += 1L
        val second = registration.idForResponse { CoreCallResult.Accepted }

        assertNotEquals(first, second)
        assertTrue(registration.matches(second))
        assertFalse(registration.matches(first))
    }

    @Test
    fun wallJumpForwardRenewsWithYoungMonotonicAgeAndResetsBothClocks() {
        val clock = TestClock()
        val original = UUID.randomUUID()
        val registration = clock.registration(original)
        clock.nanos += 10_000_000_000L
        clock.wallMillis += 120_000L
        val emitted = mutableListOf<UUID>()

        val fresh = registration.idForResponse {
            emitted += it
            CoreCallResult.Accepted
        }

        assertNotEquals(original, fresh)
        assertEquals(listOf(fresh), emitted)
        assertFalse(registration.matches(original))
        assertTrue(registration.matches(fresh))
        clock.nanos += 1_000_000_000L
        clock.wallMillis += 44_999L
        assertEquals(fresh, registration.idForResponse { error("both registration clocks must reset") })
        clock.wallMillis += 1L
        assertNotEquals(fresh, registration.idForResponse { CoreCallResult.Accepted })
    }

    @Test
    fun wallJumpBackwardDoesNotRenewWithYoungMonotonicAge() {
        val clock = TestClock()
        val original = UUID.randomUUID()
        val registration = clock.registration(original)
        clock.nanos += 10_000_000_000L
        clock.wallMillis -= 120_000L

        assertEquals(original, registration.idForResponse { error("backward wall jump extends expiry") })
        assertTrue(registration.matches(original))
    }

    @Test
    fun monotonicThresholdRenewsWithUnchangedWallClock() {
        val clock = TestClock()
        val original = UUID.randomUUID()
        val registration = clock.registration(original)
        clock.nanos += 45_000_000_000L

        val fresh = registration.idForResponse { CoreCallResult.Accepted }

        assertNotEquals(original, fresh)
        assertTrue(registration.matches(fresh))
        assertFalse(registration.matches(original))
    }

    @Test
    fun refusedWallClockRenewalRetriesWithoutAdoptingFreshIdOrTime() {
        val clock = TestClock()
        val original = UUID.randomUUID()
        val registration = clock.registration(original)
        clock.nanos += 10_000_000_000L
        clock.wallMillis += 120_000L
        var refusedId: UUID? = null
        val renewals = mutableListOf<Long>()

        assertEquals(original, registration.idForResponse(onRenewed = { renewals += it }) {
            refusedId = it
            CoreCallResult.InvalidArguments
        })
        assertTrue(registration.matches(original))
        assertFalse(registration.matches(checkNotNull(refusedId)))
        assertTrue(renewals.isEmpty())
        assertNotEquals(original, registration.idForResponse { CoreCallResult.Accepted })
    }

    private class TestClock {
        var nanos = 1_000_000_000L
        var wallMillis = 1_000_000L

        fun registration(id: UUID) = SharedChallengeRegistration(
            id,
            nanoTime = { nanos },
            wallMillis = { wallMillis },
        )
    }
}
