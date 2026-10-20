package com.bambouville.tessera.core.bridge

import org.junit.Assert.*
import org.junit.Test

class SharedBootstrapTransactionVersionsTest {
    @Test fun advertisementIsPurposeSpecific() {
        for (purpose in listOf("bootstrap", "setUpAndContinue")) {
            assertEquals(listOf(1, 2), SharedBootstrapTransactionVersions.supported(purpose))
        }
        for (purpose in listOf("continue", "enroll", "unknown")) {
            assertEquals(listOf(1), SharedBootstrapTransactionVersions.supported(purpose))
        }
    }

    @Test fun onlyNegotiatedV2PermitsTheExtension() {
        for (version in listOf(0, 1, 3)) {
            assertFalse(SharedBootstrapTransactionVersions.supportsAgentCenterEnabled(version))
        }
        assertTrue(SharedBootstrapTransactionVersions.supportsAgentCenterEnabled(2))
    }
}
