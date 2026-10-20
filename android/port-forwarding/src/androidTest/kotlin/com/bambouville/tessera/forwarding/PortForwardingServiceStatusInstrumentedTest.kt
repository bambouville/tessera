package com.bambouville.tessera.forwarding

import androidx.activity.ComponentActivity
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertTextEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.design.TesseraTheme
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A listening rule's row says whether anything serves behind the tunnel.
 *
 * On a device, so the rows consult the real shared-core `ForwardedWebPolicy`:
 * which rules the manager probes — and so which may say "checking…" — is its
 * answer, not a fixture's. Three rules per case keep every row on screen; the
 * list is lazy, and an off-screen row has no node to assert on.
 *
 * Host-free: nothing here opens an SSH session.
 */
@RunWith(AndroidJUnit4::class)
class PortForwardingServiceStatusInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun aListeningRowSaysWhetherAnythingServesBehindIt() {
        val serving = rule(port = 18_080, target = 3_000)
        val refused = rule(port = 18_081, target = 3_001)
        val checking = rule(port = 18_082, target = 3_002)
        var probeRequests = 0

        compose.setContent {
            TesseraTheme {
                PortForwardingPanel(
                    rules = listOf(serving, refused, checking),
                    states = mapOf(
                        serving.id to state(serving, ForwardedServiceState.Serving),
                        refused.id to state(refused, ForwardedServiceState.NotServing),
                        checking.id to state(checking, ForwardedServiceState.Unknown),
                    ),
                    onRulesChanged = {},
                    onProbeServices = { probeRequests += 1 },
                )
            }
        }
        awaitTag("tunnel-status-18082")

        compose.onNodeWithTag("tunnel-status-18080").assertTextEquals("serving · 0 active")
        compose.onNodeWithTag("tunnel-status-18081")
            .assertTextEquals("listening · nothing serving on remote port 3001")
        compose.onNodeWithTag("tunnel-status-18082").assertTextEquals("listening · checking…")

        // Nothing serving is no reason to withhold the page: it may be up by
        // the time the user taps.
        compose.onNodeWithTag("tunnel-open-18080").assertIsDisplayed()
        compose.onNodeWithTag("tunnel-open-18081").assertIsDisplayed()

        // Opening the panel asks for fresh answers, once.
        compose.runOnIdle { assertEquals(1, probeRequests) }
    }

    @Test fun aRowThatWouldNeverResolveKeepsThePlainListeningLine() {
        val prohibited = rule(port = 18_083, target = 3_003)
        // Never probed: https targets log a TLS error per bare connect, and
        // postgres an incomplete startup packet.
        val https = rule(port = 18_443, target = 443)
        val postgres = rule(port = 15_432, target = 5_432)

        compose.setContent {
            TesseraTheme {
                PortForwardingPanel(
                    rules = listOf(prohibited, https, postgres),
                    states = mapOf(
                        prohibited.id to state(prohibited, ForwardedServiceState.Unknown, prohibited = true),
                        https.id to state(https, ForwardedServiceState.Unknown),
                        postgres.id to state(postgres, ForwardedServiceState.Unknown),
                    ),
                    onRulesChanged = {},
                )
            }
        }
        awaitTag("tunnel-status-15432")

        compose.onNodeWithTag("tunnel-status-18083").assertTextEquals("listening · 0 active")
        compose.onNodeWithTag("tunnel-status-18443").assertTextEquals("listening · 0 active")
        compose.onNodeWithTag("tunnel-status-15432").assertTextEquals("listening · 0 active")
    }

    /** Waits for a tag without requiring a root to exist yet. */
    private fun awaitTag(tag: String) {
        compose.waitUntil(timeoutMillis = 15_000) {
            compose.onAllNodesWithTag(tag).fetchSemanticsNodes(atLeastOneRootRequired = false).size == 1
        }
    }

    private fun state(rule: PortForwardRule, service: ForwardedServiceState, prohibited: Boolean = false) =
        PortForwardingState(
            rule = rule,
            status = PortForwardingStatus.Listening(BoundForwardEndpoint("127.0.0.1", rule.bind.port)),
            service = service,
            forwardingProhibited = prohibited,
        )

    private fun rule(port: Int, target: Int) = PortForwardRule(
        id = UUID.randomUUID(),
        direction = PortForwardDirection.LOCAL,
        bind = PortForwardEndpoint("127.0.0.1", port),
        target = PortForwardEndpoint("localhost", target),
    )
}
