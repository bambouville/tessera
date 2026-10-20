package com.bambouville.tessera.feature.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TmuxTransportEpochGateTest {
    @Test
    fun `only the exact open connection generation may consume reducer effects`() {
        val connectionA = Any()
        val connectionB = Any()

        assertTrue(
            TmuxTransportEpochGate.isCurrent(
                closed = false,
                expectedConnection = connectionA,
                expectedGeneration = 7,
                currentConnection = connectionA,
                currentGeneration = 7,
            ),
        )
        assertFalse(
            "an old A-g7 batch cannot enqueue onto replacement B-g8",
            TmuxTransportEpochGate.isCurrent(
                closed = false,
                expectedConnection = connectionA,
                expectedGeneration = 7,
                currentConnection = connectionB,
                currentGeneration = 8,
            ),
        )
        assertFalse(
            "even a reused connection object cannot cross its generation cut",
            TmuxTransportEpochGate.isCurrent(
                closed = false,
                expectedConnection = connectionA,
                expectedGeneration = 7,
                currentConnection = connectionA,
                currentGeneration = 8,
            ),
        )
        assertFalse(
            TmuxTransportEpochGate.isCurrent(
                closed = true,
                expectedConnection = connectionA,
                expectedGeneration = 7,
                currentConnection = connectionA,
                currentGeneration = 7,
            ),
        )
    }
}
