package com.bambouville.tessera.agent.platform

import com.bambouville.tessera.core.bridge.SharedAgentIntegrationDecisionKind
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallFailure
import com.bambouville.tessera.core.bridge.SharedAgentIntegrationInstallation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentIntegrationVersionMappingTest {
    @Test
    fun newerHostInstallationIsObservedAsItselfNotAsOutdated() {
        assertEquals(
            SharedAgentIntegrationInstallation.RequiresAppUpdate,
            AgentIntegrationStatus.RequiresAppUpdate(12).sharedInstallation,
        )
        assertEquals(
            SharedAgentIntegrationInstallation.RequiresAppUpdate,
            AgentIntegrationStatus.RequiresAppUpdate(null).sharedInstallation,
        )
        assertEquals(SharedAgentIntegrationInstallation.Outdated, AgentIntegrationStatus.Outdated(8).sharedInstallation)
        assertEquals(SharedAgentIntegrationInstallation.Current, AgentIntegrationStatus.Current.sharedInstallation)
        assertEquals(SharedAgentIntegrationInstallation.Missing, AgentIntegrationStatus.Missing.sharedInstallation)
    }

    @Test
    fun appUpdateDecisionReachesTheSessionAsItsOwnKind() {
        assertEquals(
            AgentSessionIntegrationKind.AppUpdateRequired,
            SharedAgentIntegrationDecisionKind.AppUpdateRequired.sessionKind,
        )
        // Every Core decision keeps a distinct session kind; none collapses
        // into a neighbour that would offer an install.
        val mapped = SharedAgentIntegrationDecisionKind.entries.map { it.sessionKind }
        assertEquals(mapped.size, mapped.toSet().size)
        assertEquals(AgentSessionIntegrationKind.entries.toSet(), mapped.toSet())
    }

    @Test
    fun newerInstalledFailureTellsTheUserToUpdateTheApp() {
        val detail = SharedAgentIntegrationInstallFailure.NewerInstalled.failureDetail
        assertEquals(
            "This host has a newer Agent Center integration from a newer Tessera. Update this app instead.",
            detail,
        )
        assertFalse(SharedAgentIntegrationInstallFailure.NotCurrent.failureDetail.contains("newer"))
        assertTrue(SharedAgentIntegrationInstallFailure.entries.all { it.failureDetail.isNotBlank() })
    }
}
