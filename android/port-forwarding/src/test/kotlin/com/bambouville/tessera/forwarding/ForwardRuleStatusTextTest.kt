package com.bambouville.tessera.forwarding

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The panel row's status line. The English matches iOS word for word, so
 * these strings are asserted exactly.
 */
class ForwardRuleStatusTextTest {
    private val rule = PortForwardRule(
        id = UUID.randomUUID(),
        bind = PortForwardEndpoint("127.0.0.1", 18_080),
        target = PortForwardEndpoint("localhost", 3_000),
    )
    private val listening = PortForwardingStatus.Listening(BoundForwardEndpoint("127.0.0.1", 18_080))

    @Test fun aConfirmedTargetReadsServing() {
        assertEquals(
            "serving · 0 active",
            text(PortForwardingState(rule, listening, ForwardedServiceState.Serving)),
        )
    }

    @Test fun aRefusedTargetNamesItsRemotePort() {
        assertEquals(
            "listening · nothing serving on remote port 3000",
            text(PortForwardingState(rule, listening, ForwardedServiceState.NotServing)),
        )
    }

    @Test fun onlyAProbedRuleSaysItIsChecking() {
        val unknown = PortForwardingState(rule, listening)

        assertEquals("listening · checking…", text(unknown, probed = true))
        // A rule nothing probes would never resolve, so it promises nothing.
        assertEquals("listening · 0 active", text(unknown, probed = false))
    }

    @Test fun aServerThatForbidsForwardingKeepsThePlainListeningLine() {
        assertEquals(
            "listening · 0 active",
            text(PortForwardingState(rule, listening, forwardingProhibited = true), probed = true),
        )
    }

    @Test fun otherStatusesKeepTheirExistingText() {
        assertEquals("Stopped", forwardRuleStatusText(rule, null, probed = true))
        assertEquals("Starting", text(PortForwardingState(rule, PortForwardingStatus.Starting)))
        assertEquals(
            "2 active connections",
            text(
                PortForwardingState(
                    rule,
                    PortForwardingStatus.Active(BoundForwardEndpoint("127.0.0.1", 18_080), 2),
                    ForwardedServiceState.Serving,
                ),
            ),
        )
        assertEquals(
            "1 active connection",
            text(PortForwardingState(rule, PortForwardingStatus.Active(BoundForwardEndpoint("127.0.0.1", 18_080), 1))),
        )
        assertEquals(
            "gone",
            text(PortForwardingState(rule, PortForwardingStatus.Failed(PortForwardingFailure.Transport("gone")))),
        )
    }

    private fun text(state: PortForwardingState, probed: Boolean = true) =
        forwardRuleStatusText(rule, state, probed)
}
