package com.bambouville.tessera.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Adapter level only. The trust verdict, the fingerprint spelling and the
 * `known_hosts` codec are the shared core's (`TesseraTrustCore`) and are pinned
 * by its Swift tests; what stays testable here is the mapping between this
 * store's Room key and the core's `host:port` storage key.
 *
 * That mapping is load-bearing for import: `KnownHostsScreen` builds the plan
 * with `normalizeEndpoints = true`, so the plan's candidate keys, its
 * add/replace/unchanged lookup and its ambiguity grouping are all in the space
 * these assertions describe. If the two ever drift apart, a host this store
 * already pins is planned as an `Add` that `trustIfUnchanged` then refuses.
 */
class KnownHostsRepositoryTest {
    @Test
    fun endpointNormalizationHandlesDnsAndIpv6() {
        assertEquals(
            "example.com:22",
            AndroidKnownHostsRepository.normalizeEndpoint(" Example.COM. ", 22),
        )
        assertEquals(
            "[2001:db8::1]:2222",
            AndroidKnownHostsRepository.normalizeEndpoint("2001:DB8::1", 2222),
        )
    }

    @Test
    fun sharedStorageKeyUnwrapsTheRoomKeyIpv6Brackets() {
        // The core stores IPv6 literals bare and re-applies brackets only when
        // rendering known_hosts text; this store brackets them in the key.
        assertEquals("2001:db8::1:2222", KnownHostKeys.sharedEndpointKey("[2001:db8::1]:2222"))
        assertEquals("example.com:22", KnownHostKeys.sharedEndpointKey("example.com:22"))
        assertEquals("2001:db8::1" to 2222, KnownHostKeys.splitEndpoint("[2001:db8::1]:2222"))
        assertEquals("example.com" to 22, KnownHostKeys.splitEndpoint("example.com:22"))
    }

    @Test
    fun aValueThatIsNotAnEndpointKeyIsPassedThroughRatherThanMangled() {
        assertNull(KnownHostKeys.splitEndpoint("example.com"))
        assertNull(KnownHostKeys.splitEndpoint("example.com:0"))
        assertNull(KnownHostKeys.splitEndpoint("example.com:not-a-port"))
        assertEquals("example.com", KnownHostKeys.sharedEndpointKey("example.com"))
    }
}
