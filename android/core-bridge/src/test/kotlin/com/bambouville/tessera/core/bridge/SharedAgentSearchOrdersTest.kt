package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import java.math.BigInteger

class SharedAgentSearchOrdersTest {
    @Test
    fun aResultKeepsOnlyExactOrders() {
        val past = BigInteger("18446744073709551615")
        val results = JSONArray()
            .put(JSONObject().put("recordID", "small").put("sequence", 12_345).put("sourceOffset", 4_096L))
            .put(JSONObject().put("recordID", "wide").put("sequence", past).put("sourceOffset", Long.MAX_VALUE))
            // What Android's org.json makes of 9223372036854775809.
            .put(JSONObject().put("recordID", "rounded").put("sequence", 9.223372036854776E18).put("sourceOffset", 1.5))
            .put(JSONObject().put("recordID", "text").put("sequence", "12").put("sourceOffset", JSONObject.NULL))
            .put("not a result")

        val kept = results.withoutRoundedOrders()

        assertEquals(5, kept.length())
        assertEquals(12_345, kept.getJSONObject(0).get("sequence"))
        assertEquals(4_096L, kept.getJSONObject(0).get("sourceOffset"))
        assertEquals(past, kept.getJSONObject(1).get("sequence"))
        assertEquals(Long.MAX_VALUE, kept.getJSONObject(1).get("sourceOffset"))
        for (index in 2..3) {
            val result = kept.getJSONObject(index)
            assertFalse(result.getString("recordID"), result.has("sequence"))
            assertFalse(result.getString("recordID"), result.has("sourceOffset"))
            assertEquals(1, result.length())
        }
        assertEquals("not a result", kept.getString(4))
    }
}
