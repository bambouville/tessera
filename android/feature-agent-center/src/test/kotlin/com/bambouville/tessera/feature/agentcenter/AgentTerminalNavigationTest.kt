package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.agent.platform.AgentTerminalFocusOutcome
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.coroutines.runBlocking

class AgentTerminalNavigationTest {
    @Test fun navigationRevealsBeforeTheExactFocus() = runBlocking {
        val events = mutableListOf<String>()
        assertTrue(navigateToExistingAgentTerminal(isCurrentCarrier = { true },
            focus = { events += "focus"; AgentTerminalFocusOutcome.Success }, reveal = { events += "reveal" }))
        assertEquals(listOf("reveal", "focus"), events)
    }

    @Test fun yieldedAuthorityRetainsTheTargetAndFocusesExactlyOnceAfterSettlement() = runBlocking {
        val pending = CompletableDeferred<Unit>()
        var revealed = false
        var settled = false
        var commands = 0
        val navigation = async {
            navigateToExistingAgentTerminal(isCurrentCarrier = { true }, reveal = { revealed = true }, intervalMillis = 10,
                focus = {
                    assertTrue(revealed)
                    if (!settled) { pending.complete(Unit); AgentTerminalFocusOutcome.AuthorityPending }
                    else { commands++; AgentTerminalFocusOutcome.Success }
                })
        }
        withTimeout(1_000) { pending.await() }
        assertEquals(0, commands)
        settled = true
        assertTrue(withTimeout(1_000) { navigation.await() })
        assertEquals(1, commands)
    }

    @Test fun carrierPaneReplacementOrLeavingCancelsPendingFocus() = runBlocking {
        for (changed in listOf("carrier", "pane", "left")) {
            val pending = CompletableDeferred<Unit>()
            var carrier = true
            var pane = true
            var presented = true
            var attempts = 0
            var outcome: AgentTerminalNavigationOutcome? = null
            val navigation = async {
                navigateToExistingAgentTerminal(isCurrentCarrier = { carrier }, isCurrentTarget = { pane },
                    isStillPresented = { presented }, reveal = {}, intervalMillis = 10,
                    focus = { attempts++; pending.complete(Unit); AgentTerminalFocusOutcome.AuthorityPending },
                    onOutcome = { outcome = it })
            }
            withTimeout(1_000) { pending.await() }
            when (changed) { "carrier" -> carrier = false; "pane" -> pane = false; else -> presented = false }
            assertFalse(withTimeout(1_000) { navigation.await() })
            assertEquals(AgentTerminalNavigationOutcome.CANCELLED, outcome)
            assertEquals(1, attempts)
        }
    }

    @Test fun authorityTimeoutKeepsTheRevealedTerminalAndReportsPending() = runBlocking {
        var reveals = 0
        var outcome: AgentTerminalNavigationOutcome? = null
        assertFalse(navigateToExistingAgentTerminal(isCurrentCarrier = { true }, reveal = { reveals++ },
            focus = { AgentTerminalFocusOutcome.AuthorityPending }, timeoutMillis = 30, intervalMillis = 10,
            onOutcome = { outcome = it }))
        assertEquals(1, reveals)
        assertEquals(AgentTerminalNavigationOutcome.AUTHORITY_PENDING, outcome)
    }

    @Test fun unavailableIsReportedOnlyForAMissingCarrierBeforeReveal() = runBlocking {
        for (scenario in listOf("missing", "gone-after-reveal", "focus-failed")) {
            var reveals = 0
            var outcome: AgentTerminalNavigationOutcome? = null
            assertFalse(navigateToExistingAgentTerminal(isCurrentCarrier = { scenario != "missing" },
                reveal = { reveals++ }, focus = {
                    if (scenario == "gone-after-reveal") AgentTerminalFocusOutcome.RouteGone else AgentTerminalFocusOutcome.Failed("selection")
                }, onOutcome = { outcome = it }))
            assertEquals(if (scenario == "missing") 0 else 1, reveals)
            assertEquals(when (scenario) {
                "missing" -> AgentTerminalNavigationOutcome.UNAVAILABLE
                "gone-after-reveal" -> AgentTerminalNavigationOutcome.CANCELLED
                else -> AgentTerminalNavigationOutcome.FAILED
            }, outcome)
        }
    }

    @Test fun allTransportsRevealOnlyTheExactLiveCarrierRegardlessOfUuidSpelling() {
        val host = "2c0f0101-1e67-45be-a031-8ebc7c345680"
        val live = "20e2b41f-1e9e-49c1-a0e5-b80de7d33a73"
        for (transport in listOf("ssh", "sshTmux", "mosh", "moshTmux")) {
            val row = AgentThreadRow("key", "thread", "Codex", null, null, "idle", "none", "", null, false,
                true, false, false, hostID = host.uppercase(), providerID = "codex", providerSessionID = "thread")
            val detail = AgentThreadDetail(row, emptyList(), emptyList(), emptyList(), SharedAgentValue.ObjectValue(mapOf(
                "liveSessionID" to SharedAgentValue.StringValue(live.uppercase()),
                "transport" to SharedAgentValue.StringValue(transport),
            )), false)
            // This was MainActivity's silent no-op after a successful pane focus.
            assertFalse(host == detail.row.hostID)
            assertTrue(detail.targetsLiveSession(host, live))
            assertFalse(detail.targetsLiveSession("another-host", live))
            assertFalse(detail.targetsLiveSession(host, "another-carrier"))
            assertFalse(detail.targetsLiveSession(host, null))
            assertFalse(detail.copy(binding = null).targetsLiveSession(host, live))
        }
    }
}
