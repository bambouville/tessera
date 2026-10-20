package com.bambouville.tessera.feature.pairing

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.UUID

class CanonicalCrossDeviceJsonTest {
    @Test fun commandUsesSwiftSortedKeysAndOmitsAbsentFields() {
        val encoded = CanonicalCrossDeviceJson.command(
            "decideSAS", 7,
            mapOf("matches" to CanonicalCrossDeviceJson.JsonValue.Boolean(true)),
        ).decodeToString()
        assertEquals("{\"generation\":7,\"kind\":\"decideSAS\",\"matches\":true,\"v\":1}", encoded)
    }

    @Test fun uuidUsesTheSharedUppercaseSpelling() {
        assertEquals("12345678-1234-1234-1234-123456789ABC", CanonicalCrossDeviceJson.uuid(UUID.fromString("12345678-1234-1234-1234-123456789abc")))
    }

    @Test fun receiveBytesMatchesTheFrozenSwiftCanonicalVector() {
        val encoded = CanonicalCrossDeviceJson.command(
            "receiveBytes",
            7,
            mapOf("bytes" to CanonicalCrossDeviceJson.JsonValue.String("AAH/")),
        ).decodeToString()
        assertEquals("{\"bytes\":\"AAH/\",\"generation\":7,\"kind\":\"receiveBytes\",\"v\":1}", encoded)
    }

    @Test fun stringsUseJsonEscapesWithoutEscapingForwardSlashes() {
        assertEquals("\"quote\\\" slash/ line\\n tab\\t\"", CanonicalCrossDeviceJson.stringValue("quote\" slash/ line\n tab\t"))
    }
}
