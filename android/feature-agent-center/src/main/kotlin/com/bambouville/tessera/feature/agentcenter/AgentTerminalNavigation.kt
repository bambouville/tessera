package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.AgentTerminalFocusOutcome
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

enum class AgentTerminalNavigationOutcome { FOCUSED, UNAVAILABLE, CANCELLED, AUTHORITY_PENDING, FAILED }

/** Reveal the existing carrier, then retain its exact focus target until the
 * explicit show's authority settles. It never connects a host. */
suspend fun navigateToExistingAgentTerminal(
    isCurrentCarrier: () -> Boolean,
    focus: suspend () -> AgentTerminalFocusOutcome,
    reveal: () -> Unit,
    isCurrentTarget: () -> Boolean = isCurrentCarrier,
    isStillPresented: () -> Boolean = { true },
    timeoutMillis: Long = 10_000,
    intervalMillis: Long = 250,
    onOutcome: (AgentTerminalNavigationOutcome) -> Unit = {},
): Boolean {
    if (!isCurrentCarrier()) {
        onOutcome(AgentTerminalNavigationOutcome.UNAVAILABLE)
        return false
    }
    reveal()
    val outcome = withTimeoutOrNull(timeoutMillis) {
        while (true) {
            if (!isCurrentCarrier() || !isCurrentTarget() || !isStillPresented()) {
                return@withTimeoutOrNull AgentTerminalNavigationOutcome.CANCELLED
            }
            when (focus()) {
                AgentTerminalFocusOutcome.Success -> return@withTimeoutOrNull if (isCurrentCarrier() && isCurrentTarget() && isStillPresented()) {
                    AgentTerminalNavigationOutcome.FOCUSED
                } else AgentTerminalNavigationOutcome.CANCELLED
                AgentTerminalFocusOutcome.RouteGone -> return@withTimeoutOrNull AgentTerminalNavigationOutcome.CANCELLED
                is AgentTerminalFocusOutcome.Failed -> return@withTimeoutOrNull AgentTerminalNavigationOutcome.FAILED
                AgentTerminalFocusOutcome.AuthorityPending -> delay(intervalMillis)
            }
        }
        @Suppress("UNREACHABLE_CODE")
        AgentTerminalNavigationOutcome.CANCELLED
    } ?: AgentTerminalNavigationOutcome.AUTHORITY_PENDING
    onOutcome(outcome)
    return outcome == AgentTerminalNavigationOutcome.FOCUSED
}
