package com.bambouville.tessera.feature.hosts

import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The forwarding round trip moved to `HostImportCodecInstrumentedTest`:
 * decoding a rule validates it through the shared core, which a JVM unit test
 * cannot load. What stays here needs no rules and therefore no native library.
 */
class HostImportCodecTest {
    @Test
    fun legacyV1RemainsImportableWithoutRules() {
        val decoded = HostImportCodec.decode(
            """{"format":"tessera-host-v1","hostname":"example.test","username":"alice"}""",
        )

        assertEquals("example.test", decoded.host.hostname)
        assertEquals(TransportKinds.SSH, decoded.host.transportKind)
        assertTrue(decoded.forwardingRules.isEmpty())
    }

    @Test
    fun transportRoundTripsIndependentlyOfTmuxMode() {
        val host = SavedHost(
            id = "h1",
            displayName = "box",
            hostname = "example.test",
            port = 22,
            username = "alice",
            jumpHostId = null,
            identityId = null,
            transportKind = TransportKinds.MOSH,
            tmuxMode = TmuxModes.PINNED,
            tmuxTarget = "dev",
        )

        val decoded = HostImportCodec.decode(HostImportCodec.encode(host))

        assertEquals(TransportKinds.MOSH, decoded.host.transportKind)
        assertEquals(TmuxModes.PINNED, decoded.host.tmuxMode)
        assertEquals("dev", decoded.host.tmuxTarget)
    }

    @Test
    fun transportFieldIsIndependentOfTmuxOff() {
        val decoded = HostImportCodec.decode(
            """{"format":"tessera-host-v2","hostname":"example.test","username":"alice","transport":"mosh"}""",
        )

        assertEquals(TransportKinds.MOSH, decoded.host.transportKind)
        assertEquals(TmuxModes.OFF, decoded.host.tmuxMode)
    }
}
