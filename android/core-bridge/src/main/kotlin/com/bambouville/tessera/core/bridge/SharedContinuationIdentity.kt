package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject

/**
 * Continuation route identity.
 *
 * Swift authority:
 * `Packages/TesseraCore/Sources/TesseraProtocolCore/ContinuationRouteIdentity.swift`.
 * The ABI seam is `Sources/TesseraCoreABI/ContinuationIdentityABI.swift`.
 *
 * The recovery stores that hold interrupted continuations must recognise a
 * route across process death, but their contents travel in diagnostics and
 * backups, so they store `routeKey#<fingerprint>` instead of repeating
 * user/address/port for every hop. Neither half names a transport: a sender
 * on mosh and a receiver on ssh describe the same route.
 *
 * The canonical rendering length-prefixes each field in UTF-8 BYTES. The first
 * implementation on this platform counted UTF-16 code units; byte counting is
 * the deliberate portable choice, and a stale pre-upgrade recovery record that
 * no longer matches merely retires early.
 */

/** How a hop is carried. */
enum class SharedContinuationTransport(val wireValue: String) {
    Ssh("ssh"),
    Mosh("mosh"),
}

/** One hop of a route. */
data class SharedContinuationEndpoint(
    /** Canonical UUID string. */
    val hostId: String,
    val name: String,
    val user: String,
    val address: String,
    val port: Int,
    val transport: SharedContinuationTransport,
    val hostKeyFingerprint: String? = null,
)

data class SharedContinuationRouteIdentity(
    /** `routeKey#fingerprint` (transport-free) — what a recovery record stores. */
    val identity: String,
    val fingerprint: String,
    val connectionKey: String,
)

/** Typed facade over `Sources/TesseraCoreABI/ContinuationIdentityABI.swift`. */
object SharedContinuationIdentity {
    /** Route identity for a typed endpoint plus its jump chain. */
    fun routeIdentity(
        endpoint: SharedContinuationEndpoint,
        via: List<SharedContinuationEndpoint> = emptyList(),
    ): SharedContinuationRouteIdentity {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("endpoint", endpoint.toJson())
            .put("via", JSONArray().also { array -> via.forEach { array.put(it.toJson()) } })
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.continuationRouteIdentity(request.toDirectBuffer(), request.size),
        )
        return SharedContinuationRouteIdentity(
            identity = value.getString("identity"),
            fingerprint = value.getString("fingerprint"),
            connectionKey = value.getString("connectionKey"),
        )
    }

    /**
     * Route identity derived from a received descriptor's canonical JSON.
     *
     * It agrees byte for byte with [routeIdentity] for the same route — that
     * agreement is the point of routing both through one implementation, and
     * is what lets a recipient match a descriptor against a record the origin
     * wrote.
     */
    fun descriptorRouteIdentity(descriptorJson: ByteArray): String {
        require(descriptorJson.isNotEmpty())
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.continuationDescriptorRouteIdentity(
            descriptorJson.toDirectBuffer(),
            descriptorJson.size,
        )
    }
}

private fun SharedContinuationEndpoint.toJson(): JSONObject = JSONObject()
    .put("hostID", hostId)
    .put("name", name)
    .put("user", user)
    .put("address", address)
    .put("port", port)
    .put("transport", transport.wireValue)
    .put("hostKeyFP", hostKeyFingerprint ?: JSONObject.NULL)
