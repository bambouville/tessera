package com.bambouville.tessera.feature.pairing

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.core.bridge.SharedSetupFlow
import com.bambouville.tessera.core.bridge.SharedSetupFlow.Action
import com.bambouville.tessera.core.bridge.SharedSetupFlow.Phase
import com.bambouville.tessera.core.bridge.SharedSetupFlow.Stage
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SetupFlowPresentationInstrumentedTest {
    private val host = "11111111-1111-4111-8111-111111111111"
    private val jump = "22222222-2222-4222-8222-222222222222"
    private val other = "33333333-3333-4333-8333-333333333333"

    @Test fun samePurposeAndSelectionFixturesCrossTheAndroidAbi() {
        assertEquals(listOf(Stage.scan, Stage.verify, Stage.connect), SharedSetupFlow.project("continue", Phase.entry).stages)
        assertEquals(listOf(Stage.scan, Stage.verify, Stage.choose, Stage.transfer, Stage.connect),
            SharedSetupFlow.project("setUpAndContinue", Phase.entry).stages)
        val selection = SharedSetupFlow.Selection(setOf(host, jump, other), setOf(host), setOf(host), mapOf(host to jump))
        val result = SharedSetupFlow.project("bootstrap", Phase.choosing, listOf(Action.approve), selection)
        assertEquals(setOf(host, jump), result.copiedHostIds)
        assertEquals(setOf(host), result.grantedHostIds)
        assertEquals(setOf(jump), result.requiredRouteHostIds)
        assertTrue(result.allows(Action.approve))
        assertFalse(SharedSetupFlow.project("bootstrap", Phase.choosing, listOf(Action.approve),
            selection.copy(selectedHostIds = emptySet())).allows(Action.approve))
        assertTrue(SharedSetupFlow.project("bootstrap", Phase.choosing, listOf(Action.approve),
            selection.copy(mode = "grants", selectedHostIds = emptySet())).allows(Action.approve))
    }

    @Test fun receiptAndFailureFixturesRemainTruthfulAcrossTheAbi() {
        val result = SharedSetupFlow.project("bootstrap", Phase.completed, hosts = listOf(
            SharedSetupFlow.HostFact(host, SharedSetupFlow.Access.installed, accepted = false),
            SharedSetupFlow.HostFact(jump, SharedSetupFlow.Access.skipped, passwordNeeded = true),
            SharedSetupFlow.HostFact(other, SharedSetupFlow.Access.unknown),
        ))
        assertEquals(SharedSetupFlow.Outcome.notImported, result.hosts[host])
        assertEquals(SharedSetupFlow.Outcome.passwordNeeded, result.hosts[jump])
        assertEquals(SharedSetupFlow.Outcome.configurationCopied, result.hosts[other])
        assertEquals(Stage.verify, SharedSetupFlow.project("bootstrap", Phase.failed, stoppedAt = Stage.verify).currentStage)
        assertFalse(SharedSetupFlow.project("bootstrap", Phase.waitingForPeerCode, listOf(Action.confirmCode)).allows(Action.confirmCode))
        assertThrows(IllegalArgumentException::class.java) { SharedSetupFlow.project("future", Phase.entry) }
    }
}
