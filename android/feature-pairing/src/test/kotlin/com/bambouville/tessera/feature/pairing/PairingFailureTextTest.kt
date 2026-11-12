package com.bambouville.tessera.feature.pairing

import com.bambouville.tessera.design.DisplayText
import org.junit.Assert.assertEquals
import org.junit.Test

/** A refusal shows in the screen's words, logs its old code, and keeps an English message. */
class PairingFailureTextTest {
    private val refusal = PairingRefusalException(
        "Saved hosts contain a cyclic or missing jump-host route",
        DisplayText.Resource(R.string.pairing_failed_cyclic_routes),
    )

    @Test
    fun aRefusalShowsItsOwnText() {
        assertEquals(DisplayText.Resource(R.string.pairing_failed_cyclic_routes), pairingFailureText(refusal, R.string.pairing_failed_generic))
        assertEquals("Saved hosts contain a cyclic or missing jump-host route", refusal.message)
    }

    @Test
    fun anotherFailureShowsItsMessageOrTheFallback() {
        assertEquals(DisplayText.Verbatim("socket closed"), pairingFailureText(java.io.IOException("socket closed"), R.string.pairing_failed_generic))
        assertEquals(DisplayText.Resource(R.string.pairing_failed_generic), pairingFailureText(java.io.IOException(), R.string.pairing_failed_generic))
    }

    /** Release builds rename app classes; diagnostics keep the platform type a refusal was thrown as. */
    @Test
    fun aRefusalLogsThePlatformTypeItReplaced() {
        assertEquals("IllegalArgumentException", pairingFailureCode(refusal))
        assertEquals("IOException", pairingFailureCode(java.io.IOException()))
    }
}
