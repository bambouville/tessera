package com.bambouville.tessera.forwarding

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForwardingChromePresentationTest {
    @Test
    fun sessionWithoutRulesSpendsNoChromeOnForwarding() {
        val presentation = ForwardingChromePresentation.of(
            rules = emptyList(),
            states = emptyMap(),
            panelOpen = false,
        )

        assertFalse(presentation.visible)
        assertEquals(0, presentation.activeCount)
    }

    @Test
    fun aConfiguredRuleShowsTheGlyphEvenBeforeAnyListenerIsUp() {
        val presentation = ForwardingChromePresentation.of(
            rules = listOf(localRule()),
            states = emptyMap(),
            panelOpen = false,
        )

        assertTrue(presentation.visible)
        assertEquals(0, presentation.activeCount)
    }

    /**
     * The glyph is the toggle for the editor panel, not only a status readout,
     * so a rule the user switched off still needs a way back to the panel that
     * would switch it on again.
     */
    @Test
    fun aDisabledRuleKeepsItsWayBackToThePanel() {
        val presentation = ForwardingChromePresentation.of(
            rules = listOf(localRule().copy(enabled = false)),
            states = emptyMap(),
            panelOpen = false,
        )

        assertTrue(presentation.visible)
    }

    /**
     * Mosh without an authenticated SSH side channel fails every rule. The
     * reason lives in the panel, so the route to it has to survive.
     */
    @Test
    fun aFailedRuleKeepsTheRouteToItsExplanation() {
        val rule = localRule()
        val presentation = ForwardingChromePresentation.of(
            rules = listOf(rule),
            states = mapOf(
                rule.id to PortForwardingState(
                    rule,
                    PortForwardingStatus.Failed(
                        PortForwardingFailure.Unsupported("Mosh has no authenticated SSH side channel"),
                    ),
                ),
            ),
            panelOpen = false,
        )

        assertTrue(presentation.visible)
        assertEquals(0, presentation.activeCount)
    }

    @Test
    fun deletingTheLastRuleFromInsideThePanelLeavesTheToggleReachable() {
        val presentation = ForwardingChromePresentation.of(
            rules = emptyList(),
            states = emptyMap(),
            panelOpen = true,
        )

        assertTrue(presentation.visible)
    }

    @Test
    fun onlyListeningAndActiveRulesAreCountedOut() {
        val listening = localRule(port = 8080)
        val active = localRule(port = 8081)
        val starting = localRule(port = 8082)
        val idle = localRule(port = 8083)
        val bound = BoundForwardEndpoint("127.0.0.1", 8080)

        val presentation = ForwardingChromePresentation.of(
            rules = listOf(listening, active, starting, idle),
            states = mapOf(
                listening.id to PortForwardingState(listening, PortForwardingStatus.Listening(bound)),
                active.id to PortForwardingState(active, PortForwardingStatus.Active(bound, 2)),
                starting.id to PortForwardingState(starting, PortForwardingStatus.Starting),
                idle.id to PortForwardingState(idle, PortForwardingStatus.Idle),
            ),
            panelOpen = false,
        )

        assertTrue(presentation.visible)
        assertEquals(2, presentation.activeCount)
    }

    @Test
    fun onlyConfirmedOrActiveRulesCountAsServing() {
        val serving = localRule(port = 8080)
        val notServing = localRule(port = 8081)
        val unknown = localRule(port = 8082)
        val active = localRule(port = 8083)
        val bound = BoundForwardEndpoint("127.0.0.1", 8080)

        val presentation = ForwardingChromePresentation.of(
            rules = listOf(serving, notServing, unknown, active),
            states = mapOf(
                serving.id to PortForwardingState(
                    serving,
                    PortForwardingStatus.Listening(bound),
                    ForwardedServiceState.Serving,
                ),
                notServing.id to PortForwardingState(
                    notServing,
                    PortForwardingStatus.Listening(bound),
                    ForwardedServiceState.NotServing,
                ),
                unknown.id to PortForwardingState(unknown, PortForwardingStatus.Listening(bound)),
                // Live connections imply something answered, whatever the
                // last probe said.
                active.id to PortForwardingState(
                    active,
                    PortForwardingStatus.Active(bound, 1),
                    ForwardedServiceState.NotServing,
                ),
            ),
            panelOpen = false,
        )

        assertEquals(4, presentation.activeCount)
        assertEquals(2, presentation.servingCount)
        assertTrue(presentation.serving)
        assertEquals("4 active tunnels, 2 serving", presentation.accessibilityLabel)
    }

    @Test
    fun aRuleThatIsNotCarryingIsNeverServing() {
        val stopped = localRule(port = 8080)
        val failed = localRule(port = 8081)
        val presentation = ForwardingChromePresentation.of(
            rules = listOf(stopped, failed),
            states = mapOf(
                stopped.id to PortForwardingState(stopped, PortForwardingStatus.Idle, ForwardedServiceState.Serving),
                failed.id to PortForwardingState(
                    failed,
                    PortForwardingStatus.Failed(PortForwardingFailure.Transport("gone")),
                    ForwardedServiceState.Serving,
                ),
            ),
            panelOpen = false,
        )

        assertEquals(0, presentation.servingCount)
        assertFalse(presentation.serving)
        assertEquals("Port forwarding", presentation.accessibilityLabel)
    }

    @Test
    fun theLabelNamesServingOnlyWhenSomethingServes() {
        assertEquals("Port forwarding", ForwardingChromePresentation(visible = true, activeCount = 0).accessibilityLabel)
        assertEquals("2 active tunnels", ForwardingChromePresentation(visible = true, activeCount = 2).accessibilityLabel)
        assertEquals(
            "2 active tunnels, 1 serving",
            ForwardingChromePresentation(visible = true, activeCount = 2, servingCount = 1).accessibilityLabel,
        )
        // The two-argument constructor the chrome tests use still means "none serving".
        assertEquals(0, ForwardingChromePresentation(visible = true, activeCount = 1).servingCount)
    }

    private fun localRule(port: Int = 8080) = PortForwardRule(
        id = UUID.randomUUID(),
        bind = PortForwardEndpoint("127.0.0.1", port),
        target = PortForwardEndpoint("localhost", 80),
    )
}
