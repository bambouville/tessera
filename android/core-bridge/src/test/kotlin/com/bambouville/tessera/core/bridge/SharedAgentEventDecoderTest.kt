package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedAgentEventDecoderTest {
    @Test fun retirementEventsPreserveTokensSuccessorsAndReasons() {
        val thread = JSONObject().put("hostID", "host").put("providerID", JSONObject().put("rawValue", "codex"))
            .put("providerSessionID", "root")
        val successor = JSONObject(thread.toString()).put("providerSessionID", "next")
        val entries = JSONArray()
        for (reason in listOf("replaced", "absent", "cleared", "unbound")) {
            entries.put(JSONObject().put("threadID", thread).put("bindingToken", "token-$reason").put("reason", reason)
                .putOpt("successor", successor.takeIf { reason == "replaced" }))
        }
        val decoded = SharedAgentEventDecoder.decode(JSONObject().put("version", 1).put("kind", "routesRetired")
            .put("generation", 9).put("retirements", entries).toString().encodeToByteArray()) as SharedAgentRuntimeEvent.RoutesRetired
        assertEquals(9L, decoded.runtimeGeneration)
        assertEquals(listOf("replaced", "absent", "cleared", "unbound"), decoded.retirements.map { it.reason })
        assertEquals("token-replaced", decoded.retirements.first().bindingToken)
        assertEquals(SharedAgentValue.StringValue("next"), decoded.retirements.first().successor!!.fields["providerSessionID"])
        assertTrue(decoded.retirements.drop(1).all { it.successor == null })
    }

    @Test fun malformedRetirementsAreRefusedBeforeDelivery() {
        val thread = JSONObject().put("hostID", "host").put("providerID", JSONObject().put("rawValue", "codex"))
            .put("providerSessionID", "root")
        val valid = JSONObject().put("threadID", thread).put("bindingToken", "token").put("reason", "absent")
        for (entry in listOf(JSONObject(valid.toString()).put("bindingToken", JSONObject.NULL),
            JSONObject(valid.toString()).put("reason", "guessed"), JSONObject(valid.toString()).put("successor", 7),
            JSONObject(valid.toString()).put("threadID", JSONObject()))) {
            val wire = JSONObject().put("v", 1).put("kind", "routesRetired").put("generation", 1)
                .put("retirements", JSONArray().put(entry)).toString().encodeToByteArray()
            assertTrue(runCatching { SharedAgentEventDecoder.decode(wire) }.exceptionOrNull() is SharedAgentEventDecodeException)
        }
    }

    /**
     * Core admits ~768 KB of thread presentation into the 1 MiB ABI frame.
     * A transcript of many small tool records is far more than 32K JSON
     * values at that size; the decoder used to drop it silently.
     */
    @Test
    fun largeSnapshotOfSmallToolRecordsDecodes() {
        val messages = JSONArray()
        val entryIDs = JSONArray()
        var index = 0
        var payload = snapshot(messages, entryIDs)
        while (payload.size < 700_000) {
            val recordID = "tool-record-$index"
            messages.put(JSONObject()
                .put("recordID", recordID)
                .put("role", "tool")
                .put("displayTime", 780_000_000.5 + index)
                .put("blocks", JSONArray()
                    .put(JSONObject().put("toolCall", JSONObject().put("name", "Read").put("preview", "src/$index.kt")))
                    .put(JSONObject().put("toolResult", JSONObject().put("preview", "ok").put("isError", false)))))
            entryIDs.put("$recordID#0")
            index++
            if (index % 256 == 0) payload = snapshot(messages, entryIDs)
        }
        payload = snapshot(messages, entryIDs)
        assertTrue("fixture must stay inside the ABI frame", payload.size <= CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES)
        assertTrue("fixture must exceed the former 32K value budget", countValues(JSONObject(payload.decodeToString())) > 32_768)

        val event = SharedAgentEventDecoder.decode(payload)

        val snapshot = (event as SharedAgentRuntimeEvent.Snapshot).snapshot
        assertEquals(SharedAgentSnapshotKind.Thread, snapshot.kind)
        val thread = snapshot.payload.fields.getValue("thread") as SharedAgentValue.ObjectValue
        assertEquals(index, (thread.fields.getValue("messages") as SharedAgentValue.ArrayValue).values.size)
    }

    @Test
    fun stringLimitIsExactAtTheUtf8Boundary() {
        fun event(text: String) = JSONObject().put("v", 1).put("kind", "threadSnapshot").put("generation", 1)
            .put("text", text).toString().encodeToByteArray()
        // 87 382 three-byte characters are within the band that needs an
        // exact count: 262 146 bytes is two bytes over the limit.
        val threeByte = "€".repeat(87_382)
        assertEquals("stringTooLarge", (runCatching { SharedAgentEventDecoder.decode(event(threeByte)) }
            .exceptionOrNull() as SharedAgentEventDecodeException).code)
        assertTrue(runCatching { SharedAgentEventDecoder.decode(event("€".repeat(87_381))) }.isSuccess)
        assertTrue(runCatching { SharedAgentEventDecoder.decode(event("a".repeat(262_144))) }.isSuccess)
        assertTrue(runCatching { SharedAgentEventDecoder.decode(event("a".repeat(262_145))) }.isFailure)
    }

    @Test
    fun decodeFailureDiagnosticsNeverQuotePayload() {
        val failure = runCatching { SharedAgentEventDecoder.decode("{\"secret-token\"".encodeToByteArray()) }.exceptionOrNull()!!
        val fields = SharedAgentRuntime.decodeFailureDiagnostics(15, failure)
        assertEquals("malformedJSON", fields["code"])
        assertEquals("15", fields["bytes"])
        assertTrue(fields.values.none { it.contains("secret") })
        val refused = runCatching { SharedAgentEventDecoder.decode("{\"v\":2}".encodeToByteArray()) }.exceptionOrNull()!!
        assertEquals("version", SharedAgentRuntime.decodeFailureDiagnostics(7, refused)["code"])
    }

    private fun snapshot(messages: JSONArray, entryIDs: JSONArray): ByteArray = JSONObject()
        .put("v", 1).put("kind", "threadSnapshot").put("generation", 42)
        .put("thread", JSONObject()
            .put("summary", JSONObject()
                .put("id", JSONObject().put("hostID", "A11CE000-0000-4000-8000-000000000001")
                    .put("providerID", JSONObject().put("rawValue", "claude")).put("providerSessionID", "fixture"))
                .put("title", "Many small tools").put("status", "working"))
            .put("messages", messages))
        .put("toolRuns", JSONArray().put(JSONObject().put("id", "tool-record-0#0").put("entryIDs", entryIDs)
            .put("summaryTitle", "Read files").put("latestSummary", JSONObject.NULL)))
        .toString().encodeToByteArray()

    private fun countValues(value: Any?): Int = when (value) {
        is JSONObject -> value.keys().asSequence().sumOf { 1 + countValues(value.get(it)) }
        is JSONArray -> (0 until value.length()).sumOf { 1 + countValues(value.get(it)) }
        else -> 0
    }
}
