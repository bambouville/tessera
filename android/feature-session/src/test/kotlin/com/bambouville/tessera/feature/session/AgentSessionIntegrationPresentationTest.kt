package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentSessionIntegrationAction
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationForeground
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationKind
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationStatus
import com.bambouville.tessera.agent.platform.AgentSessionKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentSessionIntegrationPresentationTest {
    private val key = AgentSessionKey("live-session", 3)

    @Test fun inactiveShellKeepsTransientAndPersistentActionsDistinct() {
        val presentation = status(AgentSessionIntegrationKind.InactiveShell).presentation()

        assertEquals("Enable in this shell", presentation.actionLabel)
        assertEquals(AgentSessionIntegrationAction.Apply, presentation.action)
        assertEquals("Enable automatically", presentation.secondaryActionLabel)
        assertEquals(
            AgentSessionIntegrationAction.PersistAndApply,
            presentation.secondaryAction,
        )
    }

    @Test fun installCopyReflectsWhetherThisExactShellCanBeActivated() {
        val activeShell = status(AgentSessionIntegrationKind.Missing, canApply = true).presentation()
        val busyShell = status(AgentSessionIntegrationKind.Missing, canApply = false).presentation()

        assertEquals("Install and enable", activeShell.actionLabel)
        assertTrue(activeShell.message.contains("loads them here"))
        assertEquals("Install integration", busyShell.actionLabel)
        assertTrue(busyShell.message.contains("Return to a bash or zsh prompt"))
    }

    @Test fun installCopyDoesNotTellARunningAgentToReturnToItsShell() {
        val runningAgent = status(
            AgentSessionIntegrationKind.Missing,
            foreground = AgentSessionIntegrationForeground.Agent,
        ).presentation()

        assertTrue(runningAgent.message.contains("If this agent has not loaded"))
        assertFalse(runningAgent.message.contains("Return to a bash or zsh prompt"))
    }

    @Test fun helperUpdateDoesNotRequireAnAgentRelaunch() {
        val updated = status(AgentSessionIntegrationKind.Outdated,
            foreground = AgentSessionIntegrationForeground.Agent).presentation()
        assertTrue(updated.message.contains("without interrupting this agent"))
        assertTrue(updated.message.contains("If lifecycle status remains unavailable"))
        val pending = status(AgentSessionIntegrationKind.InsideAgent).presentation()
        assertEquals("Agent lifecycle not yet confirmed", pending.title)
        assertTrue(pending.message.contains("If status remains unavailable"))
        assertTrue(AgentSessionIntegrationAction.InstallOnly.confirmationMessage()
            .contains("Relaunch is only needed if"))
    }

    @Test fun tierCInventoryAgentDoesNotReceiveLifecycleRelaunchCopy() {
        val runningAgent = status(
            AgentSessionIntegrationKind.Missing,
            foreground = AgentSessionIntegrationForeground.Agent,
            agentRequiresLifecycleHook = false,
        ).presentation()

        assertTrue(runningAgent.message.contains("OpenCode or Pi inventory refreshes automatically"))
        assertFalse(runningAgent.message.contains("Relaunch"))
    }

    @Test fun onlyActionableOrFailedSessionStatesShowTheChromeWarning() {
        listOf(
            AgentSessionIntegrationKind.Checking,
            AgentSessionIntegrationKind.Ready,
            AgentSessionIntegrationKind.BusyProgram,
        ).forEach { assertFalse(status(it).showsWarning) }

        listOf(
            AgentSessionIntegrationKind.Missing,
            AgentSessionIntegrationKind.Outdated,
            AgentSessionIntegrationKind.InactiveShell,
            AgentSessionIntegrationKind.InsideAgent,
            AgentSessionIntegrationKind.AwayFromShell,
            AgentSessionIntegrationKind.UnsupportedShell,
            AgentSessionIntegrationKind.ManualCheckRequired,
            AgentSessionIntegrationKind.Repairing,
            AgentSessionIntegrationKind.Unavailable,
            AgentSessionIntegrationKind.AppUpdateRequired,
        ).forEach { assertTrue(status(it).showsWarning) }
    }

    @Test fun newerHostIntegrationAsksForAnAppUpdateWithoutAnyAction() {
        val presentation = status(AgentSessionIntegrationKind.AppUpdateRequired).presentation()

        assertEquals("Update Tessera for this host", presentation.title)
        assertEquals(
            "This host's Agent Center integration comes from a newer Tessera. " +
                "Update this app to keep agent status accurate.",
            presentation.message,
        )
        assertNull(presentation.action)
        assertNull(presentation.actionLabel)
        assertNull(presentation.secondaryAction)
        assertNull(presentation.secondaryActionLabel)
    }

    @Test fun everyKindHasAPresentation() {
        AgentSessionIntegrationKind.entries.forEach { kind ->
            assertTrue(kind.name, status(kind).presentation().title.isNotBlank())
        }
    }

    private fun status(
        kind: AgentSessionIntegrationKind,
        canApply: Boolean = false,
        foreground: AgentSessionIntegrationForeground? = null,
        agentRequiresLifecycleHook: Boolean? = null,
    ) = AgentSessionIntegrationStatus(
        kind,
        key,
        primaryAction = when (kind) {
            AgentSessionIntegrationKind.Missing,
            AgentSessionIntegrationKind.Outdated,
            -> if (canApply) AgentSessionIntegrationAction.InstallAndApply else AgentSessionIntegrationAction.InstallOnly
            AgentSessionIntegrationKind.InactiveShell -> AgentSessionIntegrationAction.Apply
            AgentSessionIntegrationKind.Unavailable -> AgentSessionIntegrationAction.Retry
            else -> null
        },
        secondaryAction = if (kind == AgentSessionIntegrationKind.InactiveShell) {
            AgentSessionIntegrationAction.PersistAndApply
        } else null,
        showsWarning = kind !in setOf(
            AgentSessionIntegrationKind.Checking,
            AgentSessionIntegrationKind.Ready,
            AgentSessionIntegrationKind.BusyProgram,
        ),
        foreground = foreground,
        agentRequiresLifecycleHook = agentRequiresLifecycleHook,
    )
}
