package com.bambouville.tessera.core.bridge

/** Mirrors PairingTransactionVersionsV1. Negotiation and authentication stay in Swift. */
object SharedBootstrapTransactionVersions {
    fun supported(purpose: String): List<Int> = when (purpose) {
        "bootstrap", "setUpAndContinue" -> listOf(1, 2)
        else -> listOf(1)
    }

    /** The argument comes from the shared runtime's authenticated authorization event. */
    fun supportsAgentCenterEnabled(selectedVersion: Int): Boolean = selectedVersion == 2
}
