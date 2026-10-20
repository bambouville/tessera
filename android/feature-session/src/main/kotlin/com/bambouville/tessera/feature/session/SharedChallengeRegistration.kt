package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.CoreCallResult
import java.util.UUID

// Production never changes these values. Live tests shorten both timings together.
// The core refuses challenge lifetimes above 60 seconds. Renew early because
// expiresAt is floored to whole seconds (55-second lifetime, 45-second renewal).
internal object SharedChallengeTiming {
    @Volatile var lifetimeSeconds: Long = 55
    @Volatile var renewAfterSeconds: Long = 45

    fun reset() {
        lifetimeSeconds = 55
        renewAfterSeconds = 45
    }
}

internal class SharedChallengeRegistration(
    initialId: UUID,
    private val nanoTime: () -> Long = System::nanoTime,
    private val wallMillis: () -> Long = System::currentTimeMillis,
    private val renewAfterSeconds: Long = SharedChallengeTiming.renewAfterSeconds,
) {
    private var currentId = initialId
    private var registeredAtNanos = nanoTime()
    private var registeredAtWallMillis = wallMillis()

    @Synchronized
    fun idForResponse(
        onRenewed: (ageSeconds: Long) -> Unit = {},
        reemit: (UUID) -> CoreCallResult,
    ): UUID {
        val now = nanoTime()
        val wallNow = wallMillis()
        val ageNanos = now - registeredAtNanos
        val wallAgeMillis = wallNow - registeredAtWallMillis
        // Core expiry uses wall time, so a forward clock jump can expire a
        // monotonically young registration. A backward jump only extends expiry.
        if (ageNanos >= renewAfterSeconds * NANOS_PER_SECOND ||
            wallAgeMillis >= renewAfterSeconds * MILLIS_PER_SECOND
        ) {
            val fresh = UUID.randomUUID()
            if (reemit(fresh) == CoreCallResult.Accepted) {
                currentId = fresh
                registeredAtNanos = now
                registeredAtWallMillis = wallNow
                onRenewed(maxOf(ageNanos / NANOS_PER_SECOND, wallAgeMillis / MILLIS_PER_SECOND))
            }
        }
        return currentId
    }

    @Synchronized
    fun matches(id: UUID): Boolean = currentId == id

    private companion object {
        const val NANOS_PER_SECOND = 1_000_000_000L
        const val MILLIS_PER_SECOND = 1_000L
    }
}
