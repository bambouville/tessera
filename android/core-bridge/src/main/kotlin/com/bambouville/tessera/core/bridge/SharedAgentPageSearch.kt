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
        return JSONArray(NativeCoreBindings.agentPageSearch(input.toDirectBuffer(), input.size))
    }
}
