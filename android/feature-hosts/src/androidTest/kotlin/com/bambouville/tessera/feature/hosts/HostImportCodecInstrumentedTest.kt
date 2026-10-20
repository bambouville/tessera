package com.bambouville.tessera.feature.hosts

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.data.TransportKinds
import com.bambouville.tessera.forwarding.PortForwardDirection
import com.bambouville.tessera.forwarding.PortForwardEndpoint
import com.bambouville.tessera.forwarding.PortForwardRule
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The v2 host-import round trip, on a device where the shared core can be
 * loaded.
 *
 * Decoding a forwarding rule validates it — deliberately, so a hostile or
 * corrupt profile cannot introduce a rule the editor would have refused — and
 * that validation is now the shared core's, which a JVM unit test cannot reach
 * across JNI. The codec shape being checked is still this platform's own.
 */
@RunWith(AndroidJUnit4::class)
class HostImportCodecInstrumentedTest {
    @Test
    fun v2RoundTripsAllAndroidForwardingDirections() {
        val rules = listOf(
            rule(PortForwardDirection.LOCAL, 8080, PortForwardEndpoint("internal", 80)),
            rule(PortForwardDirection.REMOTE, 0, PortForwardEndpoint("127.0.0.1", 3000)),
            rule(PortForwardDirection.DYNAMIC, 1080, null),
        )

        val decoded = HostImportCodec.decode(HostImportCodec.encode(host(), rules))

        assertEquals("server", decoded.host.displayName)
        assertEquals(rules, decoded.forwardingRules)
    }

    private fun host() = SavedHost(
        id = "11111111-1111-1111-1111-111111111111",
        displayName = "server",
        hostname = "example.test",
        port = 22,
        username = "alice",
        jumpHostId = null,
        identityId = null,
        transportKind = TransportKinds.SSH,
        tmuxMode = TmuxModes.AUTOMATIC,
        tmuxTarget = null,
    )

    private fun rule(
        direction: PortForwardDirection,
        bindPort: Int,
        target: PortForwardEndpoint?,
    ) = PortForwardRule(
        id = UUID.randomUUID(),
        direction = direction,
        bind = PortForwardEndpoint("127.0.0.1", bindPort),
        target = target,
        label = direction.name.lowercase(),
    )
}
