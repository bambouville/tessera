package com.bambouville.tessera.feature.session

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class IntegrationWarningPresentationDelayTest {
    private val hold = FALLBACK_INTEGRATION_WARNING_DELAY_MILLIS

    @Test fun warningIsHiddenUntilItHasHeldForTheWholeDelay() = runTest {
        val raw = MutableStateFlow<String?>(null)
        val presented = mutableListOf<String?>()
        val collector = launch { raw.presentedAfterContinuousHold(hold).collect { presented += it } }
        runCurrent()
        assertEquals(listOf<String?>(null), presented)

        raw.value = "a"
        runCurrent()
        advanceTimeBy(hold - 1)
        runCurrent()
        assertEquals("a warning must not surface before the delay", listOf<String?>(null), presented)

        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(null, "a"), presented)
        collector.cancel()
    }

    @Test fun clearingHidesImmediatelyAndRestartsTheHold() = runTest {
        val raw = MutableStateFlow<String?>("a")
        val presented = mutableListOf<String?>()
        val collector = launch { raw.presentedAfterContinuousHold(hold).collect { presented += it } }
        advanceTimeBy(hold)
        runCurrent()
        assertEquals(listOf(null, "a"), presented)

        raw.value = null
        runCurrent()
        assertEquals("clearing must not wait for any delay", listOf(null, "a", null), presented)

        // A fresh warning starts a fresh hold; the earlier one earns nothing.
        raw.value = "a"
        runCurrent()
        advanceTimeBy(hold - 1)
        runCurrent()
        assertEquals(listOf(null, "a", null), presented)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(null, "a", null, "a"), presented)
        collector.cancel()
    }

    @Test fun anotherSessionsWarningEarnsItsOwnHold() = runTest {
        val raw = MutableStateFlow<String?>("a")
        val presented = mutableListOf<String?>()
        val collector = launch { raw.presentedAfterContinuousHold(hold).collect { presented += it } }
        advanceTimeBy(hold)
        runCurrent()
        assertEquals(listOf(null, "a"), presented)

        // The binding moves straight from one warning to another's: the old
        // one hides at once and the new one waits out its own delay.
        raw.value = "b"
        runCurrent()
        assertEquals(listOf(null, "a", null), presented)
        advanceTimeBy(hold - 1)
        runCurrent()
        assertEquals(listOf(null, "a", null), presented)
        advanceTimeBy(1)
        runCurrent()
        assertEquals(listOf(null, "a", null, "b"), presented)
        collector.cancel()
    }

    @Test fun aTransientWarningNeverSurfaces() = runTest {
        val raw = MutableStateFlow<String?>(null)
        val presented = mutableListOf<String?>()
        val collector = launch { raw.presentedAfterContinuousHold(hold).collect { presented += it } }
        runCurrent()

        // Probing flips through warning states on its way to ready. Each
        // interruption restarts the hold, so the sum of the pieces never counts.
        repeat(4) {
            raw.value = "a"
            runCurrent()
            advanceTimeBy(hold - 1)
            runCurrent()
            raw.value = null
            runCurrent()
        }
        advanceTimeBy(hold * 4)
        runCurrent()
        assertEquals(listOf<String?>(null), presented)
        collector.cancel()
    }

    @Test fun holdMustNotBeNegative() {
        assertThrows(IllegalArgumentException::class.java) {
            MutableStateFlow<String?>("a").presentedAfterContinuousHold(-1)
        }
    }

    @Test fun delayFallsBackToCoreValueWithoutTheNativeBridge() {
        // JVM unit tests have no packaged Swift core; previews behave the same.
        assertEquals(5_000L, integrationWarningPresentationDelayMillis())
    }
}
