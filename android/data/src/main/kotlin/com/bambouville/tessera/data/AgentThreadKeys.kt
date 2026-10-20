package com.bambouville.tessera.data

import java.util.Locale
import java.util.UUID

/**
 * Agent Core identifies a thread by `hostID:providerID:providerSessionID` and
 * compares the host segment as a UUID, so `3D3A…` and `3d3a…` are one thread.
 * Every persisted or forwarded key uses the lower-case spelling Android's
 * endpoint bindings mint; provider-session IDs stay provider-owned and
 * case-sensitive.
 */
fun canonicalAgentThreadKey(hostID: String, providerID: String, providerSessionID: String): String {
    val canonicalHost = hostID.takeIf { runCatching { UUID.fromString(it) }.isSuccess }
        ?.lowercase(Locale.ROOT)
        ?: hostID
    return listOf(canonicalHost, providerID, providerSessionID).filter(String::isNotBlank).joinToString(":")
}

/** Re-spells a stored key; anything that is not a three-part key is returned unchanged. */
fun canonicalAgentThreadKey(threadKey: String): String {
    val parts = threadKey.split(":", limit = 3)
    if (parts.size != 3 || parts.any(String::isBlank)) return threadKey
    return canonicalAgentThreadKey(parts[0], parts[1], parts[2])
}
