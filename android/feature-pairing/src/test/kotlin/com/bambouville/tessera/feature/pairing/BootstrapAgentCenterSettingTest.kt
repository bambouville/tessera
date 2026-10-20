package com.bambouville.tessera.feature.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject

class BootstrapAgentCenterSettingTest {
    @Test fun coordinatorAuthorizationPayloadControlsManifestExtension() {
        // Exercise the production event reader, including its exact key and v1 fallback.
        for ((payload, expected) in listOf(
            """{"transactionVersion":2}""" to true,
            """{"transactionVersion":1}""" to false,
            """{"transactionVersion":3}""" to false,
            """{}""" to false,
            """{"version":2}""" to false,
        )) {
            val supported = bootstrapPeerSupportsAgentCenterEnabled(JSONObject(payload))
            assertEquals(payload, expected, supported)
            for (enabled in listOf(true, false)) {
                val fields = BootstrapAgentCenterSetting.exportFields(enabled, supported)
                assertEquals(payload, expected, fields.containsKey("agentCenterEnabled"))
            }
        }
    }

    @Test fun oldAndUnknownReceiversOmitTheSetting() {
        for (enabled in listOf(true, false)) {
            assertTrue(BootstrapAgentCenterSetting.exportFields(enabled).isEmpty())
        }
    }

    @Test fun capableReceiverGetsExplicitTrueAndFalse() {
        for (enabled in listOf(true, false)) {
            assertEquals("{\"agentCenterEnabled\":$enabled}", CanonicalCrossDeviceJson.objectValue(
                BootstrapAgentCenterSetting.exportFields(enabled, peerSupportsAgentCenterEnabled = true),
            ))
        }
    }

    @Test fun absentOrNonBooleanSettingKeepsLocalValue() {
        for (value in listOf(null, "true", 1)) {
            assertNull(BootstrapAgentCenterSetting.importedValue(value))
        }
    }

    @Test fun importPreservesExplicitTrueAndFalse() {
        for (enabled in listOf(true, false)) {
            assertEquals(enabled, BootstrapAgentCenterSetting.importedValue(enabled))
        }
    }
}
