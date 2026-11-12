package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64

/** Original wire bytes and display search semantics remain in shared Core. */
object SharedAgentPageSearch {
    fun matches(wire: ByteArray, epoch: String, thread: String, threadID: JSONObject, query: String): JSONArray {
        require(wire.size <= 300_000)
        val input = JSONObject().put("wire", Base64.getEncoder().encodeToString(wire))
            .put("epoch", epoch).put("thread", thread).put("threadID", threadID).put("query", query)
            .toString().encodeToByteArray()
        require(input.size <= 410_000)
        NativeLibraries.ensureLoaded()
        return JSONArray(NativeCoreBindings.agentPageSearch(input.toDirectBuffer(), input.size)).withoutRoundedOrders()
    }
}

/**
 * Android's org.json reads an integer past Long.MAX_VALUE as a rounded
 * Double. A rounded order would open the conversation at another record, so
 * a result keeps only exact orders; without one it opens at the newest page.
 */
internal fun JSONArray.withoutRoundedOrders(): JSONArray {
    for (index in 0 until length()) {
        val result = optJSONObject(index) ?: continue
        for (field in listOf("sequence", "sourceOffset")) {
            val value = result.opt(field) ?: continue
            if (value !is Int && value !is Long && value !is java.math.BigInteger) result.remove(field)
        }
    }
    return this
}

/** One Agent Host search response, matched exactly by shared Core. */
object SharedAgentHostSearch {
    data class Skipped(val thread: String, val code: String, val pagedFallback: Boolean)
    /** [oversizedRecords]: matches the host left out as too large to send. */
    data class Reply(val results: JSONArray, val skipped: List<Skipped>, val cursor: String?, val oversizedRecords: Long = 0)

    /** [threads] maps each held host handle to its Core thread ID. */
    fun matches(wire: ByteArray, epoch: String, requestID: String, query: String, threads: Map<String, JSONObject>): Reply {
        require(wire.size <= 4_194_304 && threads.size <= 4096)
        val held = JSONArray()
        for ((handle, threadID) in threads) held.put(JSONObject().put("handle", handle).put("threadID", threadID))
        val input = JSONObject().put("wire", Base64.getEncoder().encodeToString(wire))
            .put("epoch", epoch).put("requestID", requestID).put("query", query).put("threads", held)
            .toString().encodeToByteArray()
        require(input.size <= 6_000_000)
        NativeLibraries.ensureLoaded()
        val output = JSONObject(NativeCoreBindings.agentHostSearch(input.toDirectBuffer(), input.size))
        val skipped = output.getJSONArray("skipped").let { rows ->
            (0 until rows.length()).map { index ->
                rows.getJSONObject(index).let { Skipped(it.getString("thread"), it.getString("code"), it.getBoolean("pagedFallback")) }
            }
        }
        return Reply(output.getJSONArray("results").withoutRoundedOrders(), skipped, output.optString("cursor").takeIf { output.has("cursor") && !output.isNull("cursor") },
            output.optLong("oversizedRecords", 0))
    }
}
