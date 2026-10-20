package com.bambouville.tessera.core.bridge

import org.json.JSONObject

/** Native reader classification, validated and presented by shared Core. */
data class SharedAgentReadStatus(
    val state: String, val domain: String, val recovery: String,
    val code: String, val message: String, val isProgress: Boolean,
    val survivesReaderClosure: Boolean,
) {
    companion object {
        fun decode(value: JSONObject): SharedAgentReadStatus? = try {
            val bytes = value.toString().encodeToByteArray()
            require(bytes.size in 1..4096)
            NativeLibraries.ensureLoaded()
            val result = JSONObject(NativeCoreBindings.agentIngestionReadStatus(bytes.toDirectBuffer(), bytes.size))
            SharedAgentReadStatus(result.getString("state"), result.getString("domain"), result.getString("recovery"),
                result.getString("code"), result.getString("message"), result.getBoolean("isProgress"),
                result.getBoolean("survivesReaderClosure"))
        } catch (_: RuntimeException) { null } catch (_: LinkageError) { null }
    }
}
