package com.bambouville.tessera.feature.pairing

internal object BootstrapAgentCenterSetting {
    // Released manifest decoders reject unknown settings. The transport must
    // establish support before opting into this extension.
    fun exportFields(enabled: Boolean, peerSupportsAgentCenterEnabled: Boolean = false): Map<String, CanonicalCrossDeviceJson.JsonValue> =
        if (peerSupportsAgentCenterEnabled) {
            mapOf("agentCenterEnabled" to CanonicalCrossDeviceJson.JsonValue.Boolean(enabled))
        } else emptyMap()

    fun importedValue(value: Any?): Boolean? = value as? Boolean
}
