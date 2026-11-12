package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentSessionIntegrationAction
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationForeground
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationKind
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationStatus
import com.bambouville.tessera.agent.platform.AgentSessionKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentSessionIntegrationPresentationTest {
    private val key = AgentSessionKey("live-session", 3)

    @Test fun inactiveShellKeepsTransientAndPersistentActionsDistinct() {
        val presentation = status(AgentSessionIntegrationKind.InactiveShell).integrationCopy()

        assertEquals(R.string.session_integration_enable_in_shell, presentation.actionLabel)
        assertEquals(AgentSessionIntegrationAction.Apply, presentation.action)
        assertEquals(R.string.session_integration_enable_automatically, presentation.secondaryActionLabel)
        assertEquals(
            AgentSessionIntegrationAction.PersistAndApply,
            presentation.secondaryAction,
        )
    }

    @Test fun installCopyReflectsWhetherThisExactShellCanBeActivated() {
        val activeShell = status(AgentSessionIntegrationKind.Missing, canApply = true).integrationCopy()
        val busyShell = status(AgentSessionIntegrationKind.Missing, canApply = false).integrationCopy()

        assertEquals(R.string.session_integration_install_and_enable, activeShell.actionLabel)
        // "…then loads them here so future agents report accurate status."
        assertEquals(R.string.session_integration_install_message_apply, activeShell.message)
        assertEquals(R.string.session_integration_install, busyShell.actionLabel)
        // "…Return to a bash or zsh prompt afterward to enable this terminal."
        assertEquals(R.string.session_integration_install_message_return_to_shell, busyShell.message)
    }

    @Test fun installCopyDoesNotTellARunningAgentToReturnToItsShell() {
        val runningAgent = status(
            AgentSessionIntegrationKind.Missing,
            foreground = AgentSessionIntegrationForeground.Agent,
        ).integrationCopy()

        // "…If this agent has not loaded the lifecycle hooks, relaunch it…"
        assertEquals(R.string.session_integration_install_message_agent_relaunch, runningAgent.message)
        assertNotEquals(R.string.session_integration_install_message_return_to_shell, runningAgent.message)
    }

    @Test fun helperUpdateDoesNotRequireAnAgentRelaunch() {
        val updated = status(AgentSessionIntegrationKind.Outdated,
            foreground = AgentSessionIntegrationForeground.Agent).integrationCopy()
        // "…without interrupting this agent. … If lifecycle status remains unavailable, relaunch…"
        assertEquals(R.string.session_integration_update_message_agent_relaunch, updated.message)
        val pending = status(AgentSessionIntegrationKind.InsideAgent).integrationCopy()
        assertEquals(R.string.session_integration_inside_agent_title, pending.title)
        // "…If status remains unavailable, relaunch the agent to load its hooks."
        assertEquals(R.string.session_integration_inside_agent_message, pending.message)
        // "…Relaunch is only needed if the agent has not loaded its lifecycle hooks."
        assertEquals(
            R.string.session_integration_confirm_install_only_message,
            AgentSessionIntegrationAction.InstallOnly.confirmationMessageRes,
        )
    }

    @Test fun tierCInventoryAgentDoesNotReceiveLifecycleRelaunchCopy() {
        val runningAgent = status(
            AgentSessionIntegrationKind.Missing,
            foreground = AgentSessionIntegrationForeground.Agent,
            agentRequiresLifecycleHook = false,
        ).integrationCopy()

        // "…OpenCode or Pi inventory refreshes automatically…", with no relaunch advice.
        assertEquals(R.string.session_integration_install_message_agent_center, runningAgent.message)
        assertNotEquals(R.string.session_integration_install_message_agent_relaunch, runningAgent.message)
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
        val presentation = status(AgentSessionIntegrationKind.AppUpdateRequired).integrationCopy()

        assertEquals(R.string.session_integration_app_update_title, presentation.title)
        assertEquals(R.string.session_integration_app_update_message, presentation.message)
        assertNull(presentation.detail)
        assertNull(presentation.action)
        assertNull(presentation.actionLabel)
        assertNull(presentation.secondaryAction)
        assertNull(presentation.secondaryActionLabel)
    }

    @Test fun everyKindHasAPresentation() {
        AgentSessionIntegrationKind.entries.forEach { kind ->
            assertNotEquals(kind.name, 0, status(kind).integrationCopy().title)
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
