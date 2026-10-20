package com.bambouville.tessera.core.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CoreBridgeTest {
    @Test
    fun activeWindowHydrationMatcherAcceptsCurrentVersionedAndLegacyRows() {
        assertTrue(
            SharedTmuxCommands.activeWindowHydrationMatches(
                windowId = 17,
                lines = listOf("", "__tessera_active_window__\t@17\t3.6a"),
            ),
        )
        assertTrue(
            SharedTmuxCommands.activeWindowHydrationMatches(
                windowId = 17,
                lines = listOf("__tessera_active_window__\t@17"),
            ),
        )
    }

    @Test
    fun activeWindowHydrationMatcherRejectsWrongAmbiguousAndExtendedRows() {
        assertFalse(
            SharedTmuxCommands.activeWindowHydrationMatches(
                windowId = 17,
                lines = listOf("__tessera_active_window__\t@18\t3.6a"),
            ),
        )
        assertFalse(
            SharedTmuxCommands.activeWindowHydrationMatches(
                windowId = 17,
                lines = listOf(
                    "__tessera_active_window__\t@17\t3.6a",
                    "__tessera_active_window__\t@17\t3.6a",
                ),
            ),
        )
        assertFalse(
            SharedTmuxCommands.activeWindowHydrationMatches(
                windowId = 17,
                lines = listOf("__tessera_active_window__\t@17\t3.6a\textra"),
            ),
        )
    }

    @Test
    fun terminalOutputReceiptAcceptsTheSharedSignedCeiling() {
        val receipt = SharedTerminalOutputReceipt(
            deliveryId = Long.MAX_VALUE,
            repaintRequestId = Long.MAX_VALUE,
        )
        assertEquals(Long.MAX_VALUE, receipt.deliveryId)
        assertEquals(Long.MAX_VALUE, receipt.repaintRequestId)
    }

    @Test(expected = IllegalArgumentException::class)
    fun terminalOutputReceiptRejectsZeroRepaintRequest() {
        SharedTerminalOutputReceipt(deliveryId = 1, repaintRequestId = 0)
    }

    @Test
    fun acceptsExpectedRuntimeContract() {
        val result = CoreBridge.validateRuntime(
            abiVersion = CoreBridge.EXPECTED_ABI_VERSION,
            maxPayloadBytes = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES,
        )

        assertEquals(
            CoreBridgeState.Ready(
                CoreRuntimeInfo(
                    abiVersion = CoreBridge.EXPECTED_ABI_VERSION,
                    maxPayloadBytes = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES,
                ),
            ),
            result,
        )
    }

    @Test
    fun rejectsUnexpectedAbiVersion() {
        val result = CoreBridge.validateRuntime(
            abiVersion = CoreBridge.EXPECTED_ABI_VERSION + 1,
            maxPayloadBytes = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES,
        )

        assertTrue(result is CoreBridgeState.Failed)
    }

    @Test
    fun rejectsUnexpectedPayloadLimit() {
        val result = CoreBridge.validateRuntime(
            abiVersion = CoreBridge.EXPECTED_ABI_VERSION,
            maxPayloadBytes = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES - 1,
        )

        assertTrue(result is CoreBridgeState.Failed)
    }

    @Test
    fun crossDeviceContractRemainsV1WhenTerminalAbiMovesToV2() {
        val result = CoreBridge.validateCrossDeviceRuntime(
            abiVersion = CoreBridge.EXPECTED_CROSS_DEVICE_ABI_VERSION,
            maxPayloadBytes = CoreBridge.EXPECTED_CROSS_DEVICE_MAX_PAYLOAD_BYTES,
        )

        assertEquals(
            CrossDeviceBridgeState.Ready(
                CrossDeviceRuntimeInfo(
                    abiVersion = CoreBridge.EXPECTED_CROSS_DEVICE_ABI_VERSION,
                    maxPayloadBytes = CoreBridge.EXPECTED_CROSS_DEVICE_MAX_PAYLOAD_BYTES,
                ),
            ),
            result,
        )
    }

    @Test
    fun rejectsTerminalAbiVersionForIndependentlyVersionedCrossDeviceRuntime() {
        val result = CoreBridge.validateCrossDeviceRuntime(
            abiVersion = CoreBridge.EXPECTED_ABI_VERSION,
            maxPayloadBytes = CoreBridge.EXPECTED_CROSS_DEVICE_MAX_PAYLOAD_BYTES,
        )

        assertTrue(result is CrossDeviceBridgeState.Failed)
    }

    @Test
    fun renderFactsUseSortedKeysAndOmitAbsentOptionalOwners() {
        val fact = SharedTmuxRenderFact.SurfacesDeclared(
            listOf(
                SharedTmuxSurfaceDeclaration(
                    surfaceId = "grid-1",
                    presentation = SharedTmuxSurfacePresentation.Grid,
                    windowId = 3,
                    paneId = 4,
                ),
                SharedTmuxSurfaceDeclaration(
                    surfaceId = "live",
                    presentation = SharedTmuxSurfacePresentation.Single,
                ),
            ),
        )

        assertEquals(
            """{"kind":"surfacesDeclared","surfaces":[{"paneID":4,"presentation":"grid","surfaceID":"grid-1","windowID":3},{"presentation":"single","surfaceID":"live"}],"version":1}""",
            fact.canonicalBytes().decodeToString(),
        )
    }

    @Test
    fun historyPresentationFactsUseCanonicalOwnerEncoding() {
        val owner = SharedTmuxRenderOwner(windowId = 1, paneId = 1, epoch = 7)

        assertEquals(
            "{\"kind\":\"historyPresented\",\"owner\":{\"epoch\":7,\"paneID\":1,\"windowID\":1},\"surfaceID\":\"live\",\"version\":1}",
            SharedTmuxRenderFact.HistoryPresented("live", owner).canonicalBytes().decodeToString(),
        )
        assertEquals(
            "{\"kind\":\"historyPresentationFailed\",\"owner\":{\"epoch\":7,\"paneID\":1,\"windowID\":1},\"surfaceID\":\"live\",\"version\":1}",
            SharedTmuxRenderFact.HistoryPresentationFailed("live", owner).canonicalBytes().decodeToString(),
        )
    }

    @Test
    fun naturalTransportActivityUsesTheExactOwnerWireShape() {
        assertEquals(
            "{\"kind\":\"transportOutputObserved\",\"owner\":{\"epoch\":7,\"paneID\":1,\"windowID\":1},\"surfaceID\":\"live\",\"version\":1}",
            SharedTmuxRenderFact.TransportOutputObserved(
                "live", SharedTmuxRenderOwner(windowId = 1, paneId = 1, epoch = 7),
            ).canonicalBytes().decodeToString(),
        )
    }

    @Test
    fun renderFactNumbersMatchFoundationCanonicalSpelling() {
        fun encoded(pointsY: Double) = SharedTmuxRenderFact.ScrollbackRequested(
            surfaceId = "live",
            pointsY = pointsY,
            isInertial = false,
        ).canonicalBytes().decodeToString()

        assertEquals(
            """{"isInertial":false,"kind":"scrollbackRequested","pointsY":1,"surfaceID":"live","version":1}""",
            encoded(1.0),
        )
        assertEquals(
            """{"isInertial":false,"kind":"scrollbackRequested","pointsY":9.9e-05,"surfaceID":"live","version":1}""",
            encoded(0.000099),
        )
        assertEquals(
            """{"isInertial":false,"kind":"scrollbackRequested","pointsY":1e+16,"surfaceID":"live","version":1}""",
            encoded(1e16),
        )
        assertEquals(
            """{"isInertial":false,"kind":"scrollbackRequested","pointsY":-0,"surfaceID":"live","version":1}""",
            encoded(-0.0),
        )

        val boundaryCorpus: List<Pair<Double, String>> = listOf(
            Double.MIN_VALUE to "5e-324",
            -Double.MIN_VALUE to "-5e-324",
            Double.fromBits(2) to "1e-323",
            Double.fromBits(3) to "1.5e-323",
            Double.fromBits(0x000f_ffff_ffff_ffffL) to "2.225073858507201e-308",
            Double.fromBits(0x0010_0000_0000_0000L) to "2.2250738585072014e-308",
            Double.fromBits(0x0010_0000_0000_0001L) to "2.225073858507202e-308",
            Double.MAX_VALUE to "1.7976931348623157e+308",
            1e23 to "1e+23",
        )
        boundaryCorpus.forEach { (value, canonical) ->
            assertEquals(
                """{"isInertial":false,"kind":"scrollbackRequested","pointsY":$canonical,"surfaceID":"live","version":1}""",
                encoded(value),
            )
        }
    }

    @Test(expected = IllegalArgumentException::class)
    fun renderFactRejectsNegativeUnsignedTokenBeforeJni() {
        SharedTmuxRenderFact.TimerFired(-1).canonicalBytes()
    }

    @Test
    fun acceptsIndependentAgentRuntimeContract() {
        val result = CoreBridge.validateAgentRuntime(
            abiVersion = CoreBridge.EXPECTED_AGENT_ABI_VERSION,
            maxPayloadBytes = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES,
        )

        assertEquals(
            AgentBridgeState.Ready(
                AgentRuntimeInfo(
                    abiVersion = CoreBridge.EXPECTED_AGENT_ABI_VERSION,
                    maxPayloadBytes = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES,
                ),
            ),
            result,
        )
    }

    @Test
    fun rejectsUnexpectedAgentRuntimeContract() {
        val result = CoreBridge.validateAgentRuntime(
            abiVersion = CoreBridge.EXPECTED_AGENT_ABI_VERSION + 1,
            maxPayloadBytes = CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES,
        )

        assertTrue(result is AgentBridgeState.Failed)
    }

    @Test
    fun acceptsIndependentAgentIntegrationCommandContract() {
        val result = CoreBridge.validateAgentIntegration(
            abiVersion = CoreBridge.EXPECTED_AGENT_INTEGRATION_ABI_VERSION,
            maxConfigBytes = CoreBridge.EXPECTED_AGENT_INTEGRATION_MAX_CONFIG_BYTES,
        )

        assertEquals(
            AgentIntegrationBridgeState.Ready(
                AgentIntegrationInfo(
                    abiVersion = CoreBridge.EXPECTED_AGENT_INTEGRATION_ABI_VERSION,
                    maxConfigBytes = CoreBridge.EXPECTED_AGENT_INTEGRATION_MAX_CONFIG_BYTES,
                ),
            ),
            result,
        )
    }

    @Test
    fun distinguishesMissingFromPresentEmptyIntegrationConfig() {
        assertTrue(AgentIntegrationConfigSnapshot.Missing != AgentIntegrationConfigSnapshot.Present(""))
    }
}
