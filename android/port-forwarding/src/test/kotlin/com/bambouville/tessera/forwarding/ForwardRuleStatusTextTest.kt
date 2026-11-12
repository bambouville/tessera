package com.bambouville.tessera.forwarding

import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The panel row's status line. Its English (in `forwarding_status_*`)
 * matches iOS word for word; these tests pin which line each state reads.
 */
class ForwardRuleStatusTextTest {
    private val rule = PortForwardRule(
        id = UUID.randomUUID(),
        bind = PortForwardEndpoint("127.0.0.1", 18_080),
        target = PortForwardEndpoint("localhost", 3_000),
    )
    private val listening = PortForwardingStatus.Listening(BoundForwardEndpoint("127.0.0.1", 18_080))

    @Test fun artifactLoopbackClassificationUsesNamesAndNumericAddressesOnly() {
        listOf("localhost", "LOCALHOST", " localhost ", "127.0.0.1", "127.12.34.56", "127.255.255.255",
            "::1", "[::1]", "0:0:0:0:0:0:0:1", "[0:0:0:0:0:0:0:1]").forEach { host ->
            assertTrue(host, isArtifactLoopbackHost(host))
        }
        listOf("", "localhost.example", "127.0.0.1.example", "128.0.0.1", "0.0.0.0", "::", "[::]",
            "192.168.1.1", "127.0.0.256", "127..0.1", "127.0.0.-1", "127.0.0.+1", "127.1",
            "127.0.0.1:8080", "[::1]:8080", "example.org").forEach { host ->
            assertFalse(host, isArtifactLoopbackHost(host))
        }
    }

    @Test fun artifactPageUsesTheRemoteTargetPortAndTheSharedScheme() {
        assertEquals(
            ArtifactOpenRequest.Page("saved-host", "https", 3_000, "/", ArtifactOpenOrigin.Forwarding, "live-session"),
            forwardingArtifactPage(rule, "saved-host", "https", "live-session"),
        )
    }

    @Test fun rulesThatCannotNameRemoteLoopbackKeepTheTunnelBrowser() {
        assertNull(forwardingArtifactPage(rule.copy(target = PortForwardEndpoint("internal.example", 3_000)), "host", "http"))
        assertNull(forwardingArtifactPage(rule.copy(target = null), "host", "http"))
        assertNull(forwardingArtifactPage(rule, null, "http"))
        assertNull(forwardingArtifactPage(rule, " ", "http"))
        for (direction in listOf(PortForwardDirection.REMOTE, PortForwardDirection.DYNAMIC)) {
            assertNull(forwardingArtifactPage(rule.copy(direction = direction), "host", "http"))
        }
        for (port in listOf(-1, 0, 65_536)) {
            assertNull(forwardingArtifactPage(rule.copy(target = PortForwardEndpoint("localhost", port)), "host", "http"))
        }
    }

    @Test fun aConfirmedTargetReadsServing() {
        assertEquals(
            ForwardRuleStatusLine.Serving,
            text(PortForwardingState(rule, listening, ForwardedServiceState.Serving)),
        )
    }

    @Test fun aRefusedTargetNamesItsRemotePort() {
        assertEquals(
            ForwardRuleStatusLine.NothingServing(3_000),
            text(PortForwardingState(rule, listening, ForwardedServiceState.NotServing)),
        )
    }

    @Test fun onlyAProbedRuleSaysItIsChecking() {
        val unknown = PortForwardingState(rule, listening)

        assertEquals(ForwardRuleStatusLine.Checking, text(unknown, probed = true))
        // A rule nothing probes would never resolve, so it promises nothing.
        assertEquals(ForwardRuleStatusLine.Listening, text(unknown, probed = false))
    }

    @Test fun aServerThatForbidsForwardingKeepsThePlainListeningLine() {
        assertEquals(
            ForwardRuleStatusLine.Listening,
            text(PortForwardingState(rule, listening, forwardingProhibited = true), probed = true),
        )
    }

    @Test fun otherStatusesKeepTheirExistingText() {
        assertEquals(ForwardRuleStatusLine.Stopped, forwardRuleStatus(rule, null, probed = true))
        assertEquals(ForwardRuleStatusLine.Starting, text(PortForwardingState(rule, PortForwardingStatus.Starting)))
        assertEquals(
            ForwardRuleStatusLine.Active(2),
            text(
                PortForwardingState(
                    rule,
                    PortForwardingStatus.Active(BoundForwardEndpoint("127.0.0.1", 18_080), 2),
                    ForwardedServiceState.Serving,
                ),
            ),
        )
        assertEquals(
            ForwardRuleStatusLine.Active(1),
            text(PortForwardingState(rule, PortForwardingStatus.Active(BoundForwardEndpoint("127.0.0.1", 18_080), 1))),
        )
        assertEquals(
            ForwardRuleStatusLine.Failed(PortForwardingFailure.Transport("gone")),
            text(PortForwardingState(rule, PortForwardingStatus.Failed(PortForwardingFailure.Transport("gone")))),
        )
    }

    private fun text(state: PortForwardingState, probed: Boolean = true) =
        forwardRuleStatus(rule, state, probed)
}
