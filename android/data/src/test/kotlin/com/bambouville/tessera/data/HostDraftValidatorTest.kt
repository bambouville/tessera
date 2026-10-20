package com.bambouville.tessera.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * The pinned-tmux-target grammar moved to the shared core
 * (`TmuxTargetValidation`), so it is pinned by `ProtocolCoreTests` and reached
 * from here through JNI, which a JVM unit test cannot load. Note the deliberate
 * tightening that arrived with it: `:` is no longer accepted, because tmux
 * reads it as target syntax however the shell quotes it.
 */
class HostDraftValidatorTest {
    @Test
    fun normalizesFieldsAndDefaultsDisplayName() {
        val normalized = HostDraftValidator.normalize(
            HostDraft(
                displayName = "  ",
                hostname = " host.example ",
                username = " tessera ",
            ),
        )

        assertEquals("host.example", normalized.displayName)
        assertEquals("host.example", normalized.hostname)
        assertEquals("tessera", normalized.username)
        assertEquals(22, normalized.port)
    }

    @Test
    fun rejectsUnsafeEndpointFields() {
        assertThrows(IllegalArgumentException::class.java) {
            HostDraftValidator.normalize(
                HostDraft(displayName = "host", hostname = "bad host", username = "tessera"),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            HostDraftValidator.normalize(
                HostDraft(displayName = "host", hostname = "host", username = "bad user"),
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            HostDraftValidator.normalize(
                HostDraft(displayName = "host", hostname = "host", username = "tessera", port = 0),
            )
        }
    }

    @Test
    fun removesIpv6AddressBracketsBeforeTransportUse() {
        val normalized = HostDraftValidator.normalize(
            HostDraft(
                displayName = "IPv6",
                hostname = "[2001:db8::1]",
                username = "tessera",
            ),
        )

        assertEquals("2001:db8::1", normalized.hostname)
    }
}
