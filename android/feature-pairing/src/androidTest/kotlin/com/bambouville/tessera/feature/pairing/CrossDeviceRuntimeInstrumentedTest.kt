package com.bambouville.tessera.feature.pairing

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.core.bridge.CoreCallResult
import com.bambouville.tessera.core.bridge.CoreBridge
import com.bambouville.tessera.core.bridge.CoreBridgeState
import com.bambouville.tessera.core.bridge.CrossDeviceRuntime
import android.util.Base64
import java.util.Collections
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CrossDeviceRuntimeInstrumentedTest {
    private data class TaggedEvent(val side: String, val value: JSONObject)

    @Test fun nativeAbiReportsTheFrozenRuntimeContract() {
        val state = CoreBridge.inspect()
        assertTrue(state is CoreBridgeState.Ready)
        state as CoreBridgeState.Ready
        assertEquals(CoreBridge.EXPECTED_ABI_VERSION, state.runtime.abiVersion)
        assertEquals(1_048_576L, state.runtime.maxPayloadBytes)
    }

    @Test fun nativeCrossDeviceAbiCreatesEmitsOfferAndDestroys() {
        val events = Collections.synchronizedList(mutableListOf<JSONObject>())
        val latch = CountDownLatch(2)
        val runtime = CrossDeviceRuntime.create { event ->
            events += JSONObject(event.bytes.decodeToString())
            latch.countDown()
        }
        val endpoint = CanonicalCrossDeviceJson.objectValue(mapOf(
            "host" to CanonicalCrossDeviceJson.JsonValue.String("127.0.0.1"),
            "port" to CanonicalCrossDeviceJson.JsonValue.Number(40123),
            "transport" to CanonicalCrossDeviceJson.JsonValue.String("tcp"),
        ))
        assertEquals(CoreCallResult.Accepted, runtime.sendCanonical(CanonicalCrossDeviceJson.command(
            "createOrigin", 0, mapOf(
                "purpose" to CanonicalCrossDeviceJson.JsonValue.String("continue"),
                "expiresAt" to CanonicalCrossDeviceJson.JsonValue.Number(System.currentTimeMillis() / 1_000 + 60),
                "endpointCandidates" to CanonicalCrossDeviceJson.JsonValue.Array(listOf(CanonicalCrossDeviceJson.JsonValue.Raw(endpoint))),
                "supportedTransactionVersions" to CanonicalCrossDeviceJson.JsonValue.Array(listOf(CanonicalCrossDeviceJson.JsonValue.Number(1))),
            ),
        )))
        assertEquals(CoreCallResult.Accepted, runtime.sendCanonical(CanonicalCrossDeviceJson.command("start", 0)))
        assertTrue("cross-device callbacks timed out", latch.await(10, TimeUnit.SECONDS))
        assertTrue(events.any { it.getString("kind") == "configured" })
        assertTrue(events.any { it.getString("kind") == "qrOffer" })
        runtime.close()
        assertEquals(CoreCallResult.StaleHandle, runtime.sendCanonical(CanonicalCrossDeviceJson.command("start", 0)))
    }

    @Test fun twoNativeRuntimesCompleteWhenOriginConfirmsSasFirst() = completeContinuation(originFirst = true)

    @Test fun twoNativeRuntimesCompleteWhenRecipientConfirmsSasFirst() = completeContinuation(originFirst = false)

    private fun completeContinuation(originFirst: Boolean) {
        val events = LinkedBlockingQueue<TaggedEvent>()
        val origin = CrossDeviceRuntime.create { event -> events.put(TaggedEvent("origin", JSONObject(event.bytes.decodeToString()))) }
        val recipient = CrossDeviceRuntime.create { event -> events.put(TaggedEvent("recipient", JSONObject(event.bytes.decodeToString()))) }
        try {
            val endpoint = CanonicalCrossDeviceJson.objectValue(mapOf(
                "host" to CanonicalCrossDeviceJson.JsonValue.String("127.0.0.1"),
                "port" to CanonicalCrossDeviceJson.JsonValue.Number(40123),
                "transport" to CanonicalCrossDeviceJson.JsonValue.String("tcp"),
            ))
            assertAccepted(origin, "createOrigin", mapOf(
                "purpose" to CanonicalCrossDeviceJson.JsonValue.String("continue"),
                "expiresAt" to CanonicalCrossDeviceJson.JsonValue.Number(System.currentTimeMillis() / 1_000 + 120),
                "endpointCandidates" to CanonicalCrossDeviceJson.JsonValue.Array(listOf(CanonicalCrossDeviceJson.JsonValue.Raw(endpoint))),
                "supportedTransactionVersions" to CanonicalCrossDeviceJson.JsonValue.Array(listOf(CanonicalCrossDeviceJson.JsonValue.Number(1))),
            ))
            assertAccepted(origin, "start")
            val offer = awaitKind(events, "origin", "qrOffer").payloadBytes().decodeToString()
            assertAccepted(recipient, "createRecipient", mapOf(
                "qrText" to CanonicalCrossDeviceJson.JsonValue.String(offer),
                "supportedTransactionVersions" to CanonicalCrossDeviceJson.JsonValue.Array(listOf(CanonicalCrossDeviceJson.JsonValue.Number(1))),
            ))
            assertAccepted(recipient, "start")

            val sas = mutableMapOf<String, String>()
            val completed = mutableSetOf<String>()
            var sasAccepted = false
            var firstDecisionSide: String? = null
            var pendingSecondDecisionSide: String? = null
            var descriptorSent = false
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(25)
            while (completed.size < 2 && System.nanoTime() < deadline) {
                val tagged = events.poll(1, TimeUnit.SECONDS) ?: continue
                val event = tagged.value
                when (event.getString("kind")) {
                    "outboundRecord" -> {
                        val peer = if (tagged.side == "origin") recipient else origin
                        val record = event.payloadBytes()
                        val split = (record.size / 2).coerceAtLeast(1)
                        for (chunk in listOf(record.copyOfRange(0, split), record.copyOfRange(split, record.size)).filter { it.isNotEmpty() }) {
                            assertEquals(CoreCallResult.Accepted, peer.sendCanonical(CanonicalCrossDeviceJson.command(
                                "receiveBytes", 0,
                                mapOf("bytes" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.base64(chunk))),
                            )))
                        }
                        if (tagged.side == firstDecisionSide && pendingSecondDecisionSide != null) {
                            val second = if (pendingSecondDecisionSide == "origin") origin else recipient
                            assertAccepted(second, "decideSAS", mapOf("matches" to CanonicalCrossDeviceJson.JsonValue.Boolean(true)))
                            pendingSecondDecisionSide = null
                        }
                    }
                    "sasAvailable" -> {
                        sas[tagged.side] = event.getString("code")
                        if (sas.size == 2 && !sasAccepted) {
                            assertEquals(sas["origin"], sas["recipient"])
                            firstDecisionSide = if (originFirst) "origin" else "recipient"
                            pendingSecondDecisionSide = if (originFirst) "recipient" else "origin"
                            val first = if (originFirst) origin else recipient
                            assertAccepted(first, "decideSAS", mapOf("matches" to CanonicalCrossDeviceJson.JsonValue.Boolean(true)))
                            sasAccepted = true
                        }
                    }
                    "pairingApproved" -> if (tagged.side == "origin" && !descriptorSent) {
                        val hostId = UUID.fromString("12345678-1234-1234-1234-123456789abc")
                        val descriptor = CanonicalCrossDeviceJson.objectValue(mapOf(
                            "address" to CanonicalCrossDeviceJson.JsonValue.String("fixture.example"),
                            "connectionKey" to CanonicalCrossDeviceJson.JsonValue.String("ssh:alice@fixture.example:22"),
                            "hostID" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.uuid(hostId)),
                            "launchMode" to CanonicalCrossDeviceJson.JsonValue.String("customCommand"),
                            "name" to CanonicalCrossDeviceJson.JsonValue.String("fixture"),
                            "port" to CanonicalCrossDeviceJson.JsonValue.Number(22),
                            "transport" to CanonicalCrossDeviceJson.JsonValue.String("ssh"),
                            "user" to CanonicalCrossDeviceJson.JsonValue.String("alice"),
                            "v" to CanonicalCrossDeviceJson.JsonValue.Number(1),
                            "via" to CanonicalCrossDeviceJson.JsonValue.Array(emptyList()),
                        )).encodeToByteArray()
                        assertAccepted(origin, "provideContinuationDescriptor", mapOf(
                            "descriptor" to CanonicalCrossDeviceJson.JsonValue.String(CanonicalCrossDeviceJson.base64(descriptor)),
                        ))
                        descriptorSent = true
                    }
                    "continuationDescriptorReceived" -> if (tagged.side == "recipient") {
                        val descriptor = JSONObject(event.payloadBytes().decodeToString())
                        assertEquals("fixture.example", descriptor.getString("address"))
                        assertAccepted(recipient, "continuationDescriptorDurablyAccepted", mapOf(
                            "atMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(System.currentTimeMillis()),
                        ))
                    }
                    "continuationConnectionRequired" -> if (tagged.side == "recipient") {
                        val descriptor = JSONObject(event.payloadBytes().decodeToString())
                        assertAccepted(recipient, "continuationConnectionCompleted", mapOf(
                            "hostID" to CanonicalCrossDeviceJson.JsonValue.String(descriptor.getString("hostID")),
                            "atMilliseconds" to CanonicalCrossDeviceJson.JsonValue.Number(System.currentTimeMillis()),
                        ))
                    }
                    "continuationCompleted" -> completed += tagged.side
                    "terminal", "commandRejected" -> throw AssertionError("${tagged.side} terminated: $event")
                }
            }
            assertEquals(setOf("origin", "recipient"), completed)
        } finally {
            origin.close()
            recipient.close()
        }
    }

    private fun assertAccepted(runtime: CrossDeviceRuntime, kind: String, fields: Map<String, CanonicalCrossDeviceJson.JsonValue> = emptyMap()) {
        assertEquals(CoreCallResult.Accepted, runtime.sendCanonical(CanonicalCrossDeviceJson.command(kind, 0, fields)))
    }

    private fun awaitKind(events: LinkedBlockingQueue<TaggedEvent>, side: String, kind: String): JSONObject {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
        while (System.nanoTime() < deadline) {
            val value = events.poll(1, TimeUnit.SECONDS) ?: continue
            if (value.side == side && value.value.getString("kind") == kind) return value.value
        }
        throw AssertionError("Timed out waiting for $side $kind")
    }

    private fun JSONObject.payloadBytes(): ByteArray = Base64.decode(getString("payload"), Base64.NO_WRAP)
}
