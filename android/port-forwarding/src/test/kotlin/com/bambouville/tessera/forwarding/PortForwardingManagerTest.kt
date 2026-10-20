package com.bambouville.tessera.forwarding

import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The parts of forwarding that stay on this platform: failure publication and
 * the persistence codec. Listener containment is `LocalForwardLeaseTest`; the
 * service-liveness state machine is `ForwardedServiceMonitorTest`.
 *
 * Rule validation, transport capabilities, and the restart rule now come from
 * the shared core over the native bridge, which a JVM unit test cannot load;
 * those cases live in `PortForwardingTests` in
 * `Packages/TesseraCore/Tests/TesseraDomainCoreTests`, and the manager
 * lifecycle cases that reach them moved to `PortForwardingManagerInstrumentedTest`.
 */
class PortForwardingManagerTest {
    @Test
    fun attachFailureCanBePublishedForEveryConfiguredRule() = runBlocking {
        val rules = listOf(localRule(port = 8120), localRule(port = 8121))
        val manager = PortForwardingManager()

        manager.reportTransportUnavailable(rules, "side channel unavailable")

        assertEquals(rules.map { it.id }.toSet(), manager.states.value.keys)
        assertTrue(manager.states.value.values.all { it.status is PortForwardingStatus.Failed })
        manager.close()
    }

    @Test
    fun ruleCodecRoundTripsAllRuleKindsWithoutCredentials() {
        val rules = listOf(
            localRule(port = 8100).copy(label = "database"),
            PortForwardRule(
                direction = PortForwardDirection.REMOTE,
                bind = PortForwardEndpoint("0.0.0.0", 0),
                target = PortForwardEndpoint("127.0.0.1", 3000),
                label = "preview | remote",
            ),
            PortForwardRule(
                direction = PortForwardDirection.DYNAMIC,
                bind = PortForwardEndpoint("::1", 1080),
                label = "SOCKS\nlocal",
            ),
        )

        val encoded = PortForwardRuleCodec.encode(rules)

        assertEquals(rules, PortForwardRuleCodec.decode(encoded))
        assertTrue("password" !in encoded)
        assertTrue("privateKey" !in encoded)
    }

    @Test
    fun ruleCodecDropsMalformedRulesWithoutLosingValidNeighbors() {
        val valid = localRule(port = 8110)
        val encoded = PortForwardRuleCodec.encode(listOf(valid))
        // 70000 is not a port on either platform; the shared model cannot even
        // hold it. "not-a-rule" has no fields at all.
        val invalid = "v1|${UUID.randomUUID()}|true|true|LOCAL|MTI3LjAuMC4x|70000|true|bG9jYWxob3N0|80|"

        assertEquals(listOf(valid), PortForwardRuleCodec.decode("$encoded\n$invalid\nnot-a-rule"))
    }

    private fun localRule(
        bindHost: String = "127.0.0.1",
        port: Int = 8080,
    ) = PortForwardRule(
        id = UUID.randomUUID(),
        bind = PortForwardEndpoint(bindHost, port),
        target = PortForwardEndpoint("localhost", 80),
    )
}
