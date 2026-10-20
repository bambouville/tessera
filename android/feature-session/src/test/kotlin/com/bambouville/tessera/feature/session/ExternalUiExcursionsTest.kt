package com.bambouville.tessera.feature.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExternalUiExcursionsTest {
    @Test
    fun nestedExcursionsStayActiveUntilTheLastEnds() {
        val excursions = ExternalUiExcursions()
        val picker = excursions.slot()
        val prompt = excursions.slot()

        picker(true)
        prompt(true)
        assertEquals(2, excursions.count)
        picker(false)
        assertTrue("one finishing must not clear the other", excursions.active)
        prompt(false)
        assertFalse(excursions.active)
    }

    @Test
    fun aSlotOnlyMovesTheCountOnItsOwnEdges() {
        val excursions = ExternalUiExcursions()
        val picker = excursions.slot()
        val other = excursions.slot()

        other(true)
        // An ON_RESUME cleanup or a result after recreation reports false
        // without a matching true; it must not end someone else's excursion.
        picker(false)
        assertEquals(1, excursions.count)
        picker(true)
        picker(true)
        assertEquals(2, excursions.count)
        picker(false)
        picker(false)
        assertEquals(1, excursions.count)
        other(false)
        assertEquals(0, excursions.count)
    }

    @Test
    fun aScreenDisposedMidExcursionReleasesItsSlotOnce() {
        val excursions = ExternalUiExcursions()
        val keys = excursions.slot()
        val picker = excursions.slot()

        picker(true)
        keys(true)
        // Keys leaves composition while its credential prompt is up: the
        // screen's onDispose releases the slot it will never hear back from.
        keys(false)
        assertEquals(1, excursions.count)
        // The prompt's late result (or a second dispose) is then a no-op.
        keys(false)
        assertEquals(1, excursions.count)
        picker(false)
        assertFalse("nothing leaked: the next stop can hide again", excursions.active)
        assertEquals(0, excursions.count)
    }
}
