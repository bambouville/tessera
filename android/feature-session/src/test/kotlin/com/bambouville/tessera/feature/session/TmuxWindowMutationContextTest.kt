package com.bambouville.tessera.feature.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TmuxWindowMutationContextTest {
    private val connection = Any()
    private val runtime = Any()

    @Test
    fun exactTransportRuntimeGenerationAndSessionRemainCurrent() {
        assertTrue(current())
    }

    @Test
    fun replacementConnectionRejectsStaleCompletion() {
        assertFalse(current(currentConnection = Any()))
    }

    @Test
    fun replacementRuntimeRejectsStaleCompletion() {
        assertFalse(current(currentRuntime = Any()))
    }

    @Test
    fun reconnectGenerationRejectsStaleCompletion() {
        assertFalse(current(currentGeneration = 8L))
    }

    @Test
    fun sessionChangeAndCloseRejectStaleCompletion() {
        assertFalse(current(currentSession = "other"))
        assertFalse(current(closed = true))
    }

    private fun current(
        closed: Boolean = false,
        currentConnection: Any? = connection,
        currentRuntime: Any? = runtime,
        currentGeneration: Long = 7L,
        currentSession: String? = "work",
    ): Boolean = TmuxWindowMutationContext.isCurrent(
        closed = closed,
        expectedConnection = connection,
        expectedRuntime = runtime,
        expectedGeneration = 7L,
        expectedSession = "work",
        currentConnection = currentConnection,
        currentRuntime = currentRuntime,
        currentGeneration = currentGeneration,
        currentSession = currentSession,
    )
}
