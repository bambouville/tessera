package com.bambouville.tessera.agent.platform

import org.json.JSONObject

/** Fixed providers whose Tier-C capability can be enabled by a live data route. */
enum class AgentTierCProvider(val providerID: String) {
    OpenCode("opencode"),
    Pi("pi"),
    Kimi("kimi");

    companion object {
        fun fromWire(value: String): AgentTierCProvider? = entries.firstOrNull { it.providerID == value }
    }
}

/** Opaque inventory metadata; a transcript reference is never decoded on Android. */
data class AgentTierCInventoryRecord(
    val provider: AgentTierCProvider,
    val providerSessionID: String,
    val transcriptRef: String,
)

data class AgentTierCInventoryResult(
    val provider: AgentTierCProvider,
    val records: List<AgentTierCInventoryRecord>,
    val cursor: String?,
    val hasMore: Boolean,
)

/**
 * Executes only the installed, fixed projector executable. It intentionally
 * has no terminal observation/input API, so Tier-C discovery cannot fall back
 * to reading a terminal View or agent PTY.
 */
object AgentTierCRemoteInventory {
    private const val MAX_OUTPUT_BYTES = 262_144
    private const val MAX_FRAMES = 101
    private const val MAX_FRAME_BYTES = 65_536
    private const val MAX_SESSION_BYTES = 512
    private const val MAX_REF_BYTES = 2_048
    private const val INVENTORY_TIMEOUT_MILLIS = 5_000L

    suspend fun inventory(
        endpoint: AgentRemoteDataChannel,
        binding: AgentEndpointBinding,
        provider: AgentTierCProvider,
        cursor: String? = null,
    ): AgentEndpointResult<AgentTierCInventoryResult> {
        val request = JSONObject()
            .put("v", 1)
            .put("kind", "inventory")
            .put("provider", provider.providerID)
            .put("limitBytes", MAX_OUTPUT_BYTES)
            .put("limitRecords", 100)
            .putOpt("cursor", cursor)
            .toString().plus("\n").encodeToByteArray()
        val opened = endpoint.execute(binding, AgentExecRequest("tessera-agent-project", request))
        val stream = (opened as? AgentEndpointResult.Success)?.value ?: return opened.castFailure()
        return when (val drained = AgentRemoteStreamDrain.drain(stream, MAX_OUTPUT_BYTES, INVENTORY_TIMEOUT_MILLIS)) {
            is AgentRemoteStreamDrain.Result.Complete -> {
                if (drained.exit.code != 0) AgentEndpointResult.Failed("tierc_inventory_exit")
                else AgentTierCInventoryFrames.parse(provider, drained.stdout)
            }
            AgentRemoteStreamDrain.Result.TimedOut -> AgentEndpointResult.Failed("tierc_inventory_timeout")
            is AgentRemoteStreamDrain.Result.Failed -> AgentEndpointResult.Failed("tierc_inventory_failed")
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun <T> AgentEndpointResult<*>.castFailure(): AgentEndpointResult<T> = when (this) {
        is AgentEndpointResult.Unavailable -> AgentEndpointResult.Unavailable(reason)
        is AgentEndpointResult.StaleBinding -> AgentEndpointResult.StaleBinding
        is AgentEndpointResult.Failed -> AgentEndpointResult.Failed(code)
        is AgentEndpointResult.Success<*> -> error("success handled above")
    }

    internal object AgentTierCInventoryFrames {
        fun parse(provider: AgentTierCProvider, bytes: ByteArray): AgentEndpointResult<AgentTierCInventoryResult> {
            if (bytes.isEmpty() || bytes.size > MAX_OUTPUT_BYTES) return AgentEndpointResult.Failed("tierc_inventory_malformed")
            val lines = bytes.decodeToString().lineSequence().filter(String::isNotBlank).toList()
            if (lines.isEmpty() || lines.size > MAX_FRAMES || lines.any { it.encodeToByteArray().size > MAX_FRAME_BYTES }) {
                return AgentEndpointResult.Failed("tierc_inventory_malformed")
            }
            val frames = runCatching { lines.map(::JSONObject) }.getOrElse {
                return AgentEndpointResult.Failed("tierc_inventory_malformed")
            }
            if (frames.any { it.optString("kind") == "error" }) return AgentEndpointResult.Failed("tierc_inventory_rejected")
            val end = frames.lastOrNull() ?: return AgentEndpointResult.Failed("tierc_inventory_malformed")
            if (end.optInt("v", -1) != 1 || end.optString("kind") != "end") return AgentEndpointResult.Failed("tierc_inventory_malformed")
            val hasMore = end.optBoolean("hasMore", false)
            val cursor = end.optString("cursor").takeIf(String::isNotEmpty)
            if (hasMore && (cursor == null || !boundedOpaque(cursor, MAX_REF_BYTES))) {
                return AgentEndpointResult.Failed("tierc_inventory_malformed")
            }
            val records = ArrayList<AgentTierCInventoryRecord>()
            for ((sequence, frame) in frames.dropLast(1).withIndex()) {
                if (frame.optInt("v", -1) != 1 || frame.optString("kind") != "inventory" ||
                    frame.optInt("sequence", -1) != sequence || frame.optString("provider") != provider.providerID
                ) return AgentEndpointResult.Failed("tierc_inventory_malformed")
                val sessionID = frame.optString("providerSessionID")
                val transcriptRef = frame.optString("transcriptRef")
                if (!boundedOpaque(sessionID, MAX_SESSION_BYTES) || !boundedOpaque(transcriptRef, MAX_REF_BYTES)) {
                    return AgentEndpointResult.Failed("tierc_inventory_malformed")
                }
                records += AgentTierCInventoryRecord(provider, sessionID, transcriptRef)
            }
            return AgentEndpointResult.Success(AgentTierCInventoryResult(provider, records, cursor, hasMore))
        }

        private fun boundedOpaque(value: String, maximumBytes: Int): Boolean =
            value.isNotEmpty() && value.encodeToByteArray().size <= maximumBytes &&
                value.none { it.code < 0x20 || it.code == 0x7f }
    }
}
