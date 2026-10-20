package com.bambouville.tessera.core.bridge

import kotlinx.coroutines.flow.MutableStateFlow
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Event v3 carries the tmux snapshot only when it changed. The decoder keeps
 * the last one so every [SharedTmuxEvent] still has a snapshot, and an
 * unchanged snapshot is the same instance, so nothing downstream re-publishes
 * it at event rate. Every envelope names its snapshot by key, so a carrying
 * event that never reached the decoder is noticed and resynchronised rather
 * than silently replaced by an older snapshot.
 */
class SharedTmuxEventDecoderTest {
    private fun snapshotJson(revision: Int, windowName: String = "main"): JSONObject =
        JSONObject()
            .put("revision", revision)
            .put("sessionID", JSONObject().put("rawValue", 1))
            .put("activeWindowID", JSONObject().put("rawValue", 4))
            .put("authority", JSONObject().put("unknown", JSONObject()))
            .put(
                "windows",
                JSONArray().put(
                    JSONObject()
                        .put("id", JSONObject().put("rawValue", 4))
                        .put("index", 0)
                        .put("name", windowName)
                        .put("displayName", windowName)
                        .put("isZoomed", false)
                        .put(
                            "panes",
                            JSONArray().put(
                                JSONObject()
                                    .put("id", JSONObject().put("rawValue", 8))
                                    .put("isActive", true),
                            ),
                        ),
                ),
            )

    private fun envelope(
        snapshot: JSONObject? = null,
        renderEffects: JSONArray? = JSONArray(),
        wire: JSONArray? = null,
        subscriptions: JSONArray? = null,
        key: Pair<Int, Int>? = snapshot?.let { 0 to it.getInt("revision") },
        version: Int = 3,
    ): ByteArray = JSONObject()
        .put("version", version)
        .putOpt("snapshot", snapshot)
        .putOpt("snapshotKey", key?.let { (epoch, revision) -> JSONObject().put("epoch", epoch).put("revision", revision) })
        .put("bells", JSONArray())
        .putOpt("renderEffects", renderEffects)
        .putOpt("platformWireCommands", wire)
        .putOpt("subscriptionCommands", subscriptions)
        .toString()
        .encodeToByteArray()

    private class ResyncProbe(var accepts: Boolean = true) {
        var requests = 0
        val request: () -> Boolean = {
            requests += 1
            accepts
        }
    }

    private fun SharedTmuxEvent.desyncNotes(): List<String> = renderEffects
        .filterIsInstance<SharedTmuxRenderEffect.Diagnostic>()
        .map { it.message }
        .filter { it.startsWith(SharedTmuxEventDecoder.DESYNC_DIAGNOSTIC) }

    private fun wire(tag: Long, command: String) =
        JSONArray().put(JSONObject().put("tag", tag).put("command", command))

    @Test
    fun subscriptionCommandsArriveOnceWithOrWithoutACarriedSnapshot() {
        val decoder = SharedTmuxEventDecoder()
        val commands = listOf("refresh-client -B 'tessera-bell.8:%8:#{window_bell_flag}'", "refresh-client -B 'tessera-pane-meta.9'")
        val first = decoder.decode(envelope(snapshotJson(3), subscriptions = JSONArray(commands)))
        assertEquals(commands, first.subscriptionCommands)
        val elided = decoder.decode(envelope(key = 0 to 3, subscriptions = JSONArray(commands)))
        assertSame(first.snapshot, elided.snapshot)
        assertEquals(commands, elided.subscriptionCommands)
        assertTrue(decoder.decode(envelope(key = 0 to 3)).subscriptionCommands.isEmpty())
    }

    @Test
    fun anEventWithoutASnapshotCarriesTheLastOneForward() {
        val probe = ResyncProbe()
        val decoder = SharedTmuxEventDecoder(probe.request)
        val first = decoder.decode(envelope(snapshotJson(3))).snapshot
        val second = decoder.decode(envelope(key = 0 to 3))

        assertSame(first, second.snapshot)
        assertTrue(second.desyncNotes().isEmpty())
        assertEquals(3, first.revision)
        assertEquals(listOf(4), first.windows.map { it.id })

        val changed = decoder.decode(envelope(snapshotJson(4, windowName = "editor"))).snapshot
        assertEquals("editor", changed.windows.single().name)
        assertSame(changed, decoder.decode(envelope(key = 0 to 4)).snapshot)
        assertEquals(0, probe.requests)
    }

    /**
     * Scenario A: the event carrying revision 4 never reached the decoder.
     * Its successors name key 0/4, which proves it; they are still delivered,
     * flagged, with the held snapshot, and one resync is requested for them.
     */
    @Test
    fun aLostCarryingEventIsDetectedByItsKeyAndResyncedOnce() {
        val probe = ResyncProbe()
        val decoder = SharedTmuxEventDecoder(probe.request)
        val held = decoder.decode(envelope(snapshotJson(3))).snapshot
        // Lost: envelope(snapshotJson(4, windowName = "editor")).

        val stale = decoder.decode(envelope(renderEffects = JSONArray().put(JSONObject().put("kind", "initialRenderReady")), key = 0 to 4))
        assertSame(held, stale.snapshot)
        assertEquals(
            listOf("tmux-runtime snapshot-desync reason=key-mismatch held=0/3 event=0/4 resync=requested"),
            stale.desyncNotes(),
        )
        assertEquals("the stale event keeps its effects", SharedTmuxRenderEffect.InitialRenderReady, stale.renderEffects.last())
        assertEquals(1, probe.requests)

        // Queued behind it under the same key: the request already covers it.
        val queued = decoder.decode(envelope(key = 0 to 4))
        assertEquals(listOf("already-requested"), queued.desyncNotes().map { it.substringAfterLast("resync=") })
        assertEquals(1, probe.requests)

        // The answer arrives under a new epoch and is in step from then on.
        val answer = decoder.decode(envelope(snapshotJson(4, windowName = "editor"), key = 1 to 4))
        assertEquals("editor", answer.snapshot.windows.single().name)
        assertTrue(answer.desyncNotes().isEmpty())
        val next = decoder.decode(envelope(key = 1 to 4))
        assertSame(answer.snapshot, next.snapshot)
        assertTrue(next.desyncNotes().isEmpty())
        assertEquals(1, probe.requests)
    }

    /** A first event lost or never sent: the decoder holds the engine's own initial snapshot. */
    @Test
    fun aStateEventBeforeAnySnapshotDeliversTheInitialOneAndAsksForAResync() {
        val probe = ResyncProbe()
        val decoder = SharedTmuxEventDecoder(probe.request)
        val event = decoder.decode(envelope(key = 0 to 0))

        assertSame(SharedTmuxEventDecoder.INITIAL_SNAPSHOT, event.snapshot)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, event.snapshot.authority)
        assertTrue(event.snapshot.windows.isEmpty())
        assertEquals(listOf("reason=key-mismatch held=none event=0/0 resync=requested"), event.desyncNotes().map { it.substringAfter("desync ") })
        assertEquals(1, probe.requests)
        assertEquals(
            event.snapshot,
            SharedTmuxRuntime.parse(
                envelope(JSONObject(SharedTmuxEventDecoder.INITIAL_SNAPSHOT_JSON)),
            ).snapshot,
        )
    }

    /**
     * Scenario B: the handle's first event (which carried the snapshot) was
     * lost. Wire-only events must still deliver their commands, which hold
     * reply slots, instead of failing for want of a snapshot.
     */
    @Test
    fun wireCommandsAreDeliveredBeforeAnySnapshotIsKnown() {
        val probe = ResyncProbe()
        val decoder = SharedTmuxEventDecoder(probe.request)
        val event = decoder.decode(envelope(renderEffects = null, wire = wire(2, "display-message -p x"), key = 0 to 0))

        assertEquals(listOf(SharedTmuxPlatformWireCommand(2, "display-message -p x")), event.platformWireCommands)
        assertEquals(0, probe.requests)
    }

    /** A carried snapshot that fails to decode is never replaced by the stale one silently. */
    @Test
    fun aSnapshotThatFailsToDecodeKeepsTheEventAndAsksForAResync() {
        val probe = ResyncProbe()
        val decoder = SharedTmuxEventDecoder(probe.request)
        val held = decoder.decode(envelope(snapshotJson(3))).snapshot
        val broken = snapshotJson(4).put("windows", "not a list")

        val event = decoder.decode(envelope(broken, renderEffects = JSONArray().put(JSONObject().put("kind", "initialRenderReady"))))
        assertSame(held, event.snapshot)
        assertEquals(SharedTmuxRenderEffect.InitialRenderReady, event.renderEffects.last())
        assertEquals(
            listOf("reason=undecodable-snapshot held=0/3 event=0/4 resync=requested error=JSONException"),
            event.desyncNotes().map { it.substringAfter("desync ") },
        )
        assertEquals(1, probe.requests)

        // Even an event naming the old key is now flagged: the held key is forgotten.
        assertEquals(1, decoder.decode(envelope(key = 0 to 3)).desyncNotes().size)
        assertEquals(2, probe.requests)
    }

    /** An answer that fails to decode as well must not ask for another answer. */
    @Test
    fun aFailingAnswerCannotAskForAnotherAnswer() {
        val probe = ResyncProbe()
        val decoder = SharedTmuxEventDecoder(probe.request)
        decoder.decode(envelope(snapshotJson(3)))
        val broken = { revision: Int -> snapshotJson(revision).put("windows", "not a list") }

        decoder.decode(envelope(broken(4)))
        assertEquals(1, probe.requests)
        val answer = decoder.decode(envelope(broken(4), key = 1 to 4))
        assertEquals(listOf("disarmed"), answer.desyncNotes().map { it.substringAfter("resync=").substringBefore(" ") })
        assertEquals(1, probe.requests)

        // Ordinary traffic may still ask: one request per incoming event, never a loop.
        decoder.decode(envelope(key = 1 to 4))
        assertEquals(2, probe.requests)
        // Back in step, a later failure may ask once more.
        decoder.decode(envelope(snapshotJson(5), key = 2 to 5))
        decoder.decode(envelope(broken(6), key = 2 to 6))
        assertEquals(3, probe.requests)
    }

    @Test
    fun aRefusedRequestLetsTheNextEventAskAgain() {
        val probe = ResyncProbe(accepts = false)
        val decoder = SharedTmuxEventDecoder(probe.request)
        decoder.decode(envelope(snapshotJson(3)))

        assertEquals("refused", decoder.decode(envelope(key = 0 to 4)).desyncNotes().single().substringAfterLast("resync="))
        assertEquals("refused", decoder.decode(envelope(key = 0 to 4)).desyncNotes().single().substringAfterLast("resync="))
        assertEquals(2, probe.requests)
    }

    /**
     * An event that cannot be decoded at all is not delivered, but it is
     * recorded on the next delivered state event and asks for a resync.
     */
    @Test
    fun anUndecodableEventAsksForAResyncAndIsReportedOnTheNextStateEvent() {
        val probe = ResyncProbe()
        val decoder = SharedTmuxEventDecoder(probe.request)
        decoder.decode(envelope(snapshotJson(3)))

        assertThrows(IllegalArgumentException::class.java) {
            decoder.decode(envelope(key = 0 to 3, version = 2))
        }
        assertEquals(1, probe.requests)
        // A wire event in between neither reports nor consumes the note.
        assertTrue(decoder.decode(envelope(renderEffects = null, wire = wire(3, "x"))).renderEffects.isEmpty())
        val answer = decoder.decode(envelope(snapshotJson(3), key = 1 to 3))
        assertEquals(
            listOf("reason=undecodable-event held=0/3 event=none resync=requested error=IllegalArgumentException"),
            answer.desyncNotes().map { it.substringAfter("desync ") },
        )
    }

    @Test
    fun aVersionTwoEnvelopeIsRejected() {
        val v2 = JSONObject(envelope(snapshotJson(1)).decodeToString()).put("version", 2)
        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxEventDecoder().decode(v2.toString().encodeToByteArray())
        }
    }

    /**
     * A wire-only event is transport and nothing else: only its commands (and
     * a snapshot, which only a handle's first event carries) are decoded, and
     * its key is never compared, since the engine can move without emitting.
     */
    @Test
    fun aWireOnlyEventDeliversOnlyItsCommands() {
        val probe = ResyncProbe()
        val decoder = SharedTmuxEventDecoder(probe.request)
        val snapshot = decoder.decode(envelope(snapshotJson(2))).snapshot
        // No renderEffects member at all: the full decode path requires one.
        val event = decoder.decode(envelope(renderEffects = null, wire = wire(7, "show-options -wv"), key = 0 to 9))
        assertEquals(0, probe.requests)

        assertEquals(listOf(SharedTmuxPlatformWireCommand(7, "show-options -wv")), event.platformWireCommands)
        assertSame(snapshot, event.snapshot)
        assertTrue(event.renderEffects.isEmpty())
        assertTrue(event.bells.isEmpty())
        assertTrue(event.agentStates.isEmpty())
        assertTrue(event.topologyQueries.isEmpty())
        assertTrue(event.authorityStamps.isEmpty())
    }

    @Test
    fun rawStampEdgesKeepArrivalOrderAndNeverLeakIntoTheNextEvent() {
        val decoder = SharedTmuxEventDecoder()
        val first = JSONObject(envelope(snapshotJson(2)).decodeToString())
            .put("authorityStamps", JSONArray(listOf("v1 peer 7 iPad", "v1 own 8 Pixel")))
        val event = decoder.decode(first.toString().encodeToByteArray())
        assertEquals(listOf("v1 peer 7 iPad", "v1 own 8 Pixel"), event.authorityStamps)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, event.snapshot.authority)
        assertTrue(decoder.decode(envelope(key = 0 to 2)).authorityStamps.isEmpty())
        val wireOnly = first.put("platformWireCommands", wire(1, "display-message -p x"))
        assertTrue(decoder.decode(wireOnly.toString().encodeToByteArray()).authorityStamps.isEmpty())
    }

    /** A handle's first event may be wire-only, and then it seeds the snapshot. */
    @Test
    fun aFirstWireOnlyEventSeedsTheSnapshot() {
        val decoder = SharedTmuxEventDecoder()
        val event = decoder.decode(envelope(snapshot = snapshotJson(0), wire = wire(1, "display-message -p x")))
        assertEquals(0, event.snapshot.revision)
        val next = decoder.decode(envelope(key = 0 to 0))
        assertSame(event.snapshot, next.snapshot)
        assertTrue(next.desyncNotes().isEmpty())
    }

    @Test
    fun anInvalidWireCommandIsRejected() {
        val decoder = SharedTmuxEventDecoder()
        decoder.decode(envelope(snapshotJson(1)))
        assertThrows(IllegalArgumentException::class.java) {
            decoder.decode(envelope(wire = wire(0, "display-message")))
        }
    }

    /** The republished bytes are the core's own, not a re-serialisation. */
    @Test
    fun rawJsonIsTheCoresExactSnapshotBytes() {
        val snapshot = """{"windows":[{"id":{"rawValue":1},"panes":[],"isZoomed":false,""" +
            """"name":"a \"quoted\" {brace} [x] é ✓","displayName":"tab"}],"revision":5,""" +
            """"authority":{"unknown":{}}}"""
        val document = """{"agentStates":[],"bells":[],"renderEffects":[{"kind":"diagnostic",""" +
            """"message":"\"snapshot\":{}"}],"snapshot":$snapshot,"topologyQueries":[],"version":3}"""

        val decoded = SharedTmuxEventDecoder().decode(document.encodeToByteArray()).snapshot

        assertArrayEquals(snapshot.encodeToByteArray(), decoded.rawJson)
        assertEquals("a \"quoted\" {brace} [x] é ✓", decoded.windows.single().name)
    }

    @Test
    fun topLevelMemberBytesFindsOnlyATopLevelMember() {
        fun member(json: String, key: String) =
            topLevelMemberBytes(json.encodeToByteArray(), key)?.decodeToString()

        assertEquals("{\"a\":[1,{\"b\":\"}\"}]}", member("""{"x":1,"snapshot":{"a":[1,{"b":"}"}]}}""", "snapshot"))
        assertEquals("true", member("""{ "snapshot" : true , "y" : 2 }""", "snapshot"))
        assertEquals("-1.5e3", member("""{"snapshot":-1.5e3}""", "snapshot"))
        assertEquals("\"s\\\"\"", member("""{"snapshot":"s\""}""", "snapshot"))
        assertNull(member("""{"outer":{"snapshot":{}},"list":["snapshot"]}""", "snapshot"))
        assertNull(member("""{"snap":{}}""", "snapshot"))
        assertNull(member("""[{"snapshot":{}}]""", "snapshot"))
        assertNull(member("""{"snapshot":{"unterminated":""", "snapshot"))
    }

    /** Two decodes of one topology are the same snapshot, whatever their bytes. */
    @Test
    fun snapshotEqualityIgnoresTheRawBytes() {
        val first = SharedTmuxRuntime.parse(envelope(snapshotJson(3))).snapshot
        val second = SharedTmuxRuntime.parse(envelope(snapshotJson(3))).snapshot
        val renamed = SharedTmuxRuntime.parse(envelope(snapshotJson(4, windowName = "editor"))).snapshot

        assertFalse(first.rawJson === second.rawJson)
        assertEquals(first, second)
        assertEquals(first.hashCode(), second.hashCode())
        assertEquals(first, first.copy(rawJson = ByteArray(0)))
        assertNotEquals(first, renamed)
        assertNotEquals(first, first.copy(revision = 4))
        assertNotEquals(first, first.copy(authority = SharedTmuxGridAuthoritySnapshot.Mine(1)))
        assertNotEquals(first, first.copy(isActiveWindowAuthoritative = true))

        // StateFlow conflates by equality: an equal snapshot is not a new value.
        val flow = MutableStateFlow<SharedTmuxSnapshot?>(first)
        flow.value = second
        assertSame(first, flow.value)
        flow.value = renamed
        assertSame(renamed, flow.value)
    }

    /**
     * The core says whether tmux named the active window or only guessed it
     * (the first `%window-add`, the fallback after a close). A payload from
     * before the field existed is a guess, never tmux's answer.
     */
    @Test
    fun activeWindowAuthorityIsDecodedAndAnOlderPayloadReadsAsProvisional() {
        val older = SharedTmuxRuntime.parse(envelope(snapshotJson(3))).snapshot
        val provisional = SharedTmuxRuntime.parse(
            envelope(snapshotJson(3).put("isActiveWindowAuthoritative", false)),
        ).snapshot
        val named = SharedTmuxRuntime.parse(
            envelope(snapshotJson(3).put("isActiveWindowAuthoritative", true)),
        ).snapshot

        assertFalse(older.isActiveWindowAuthoritative)
        assertEquals(older, provisional)
        assertTrue(named.isActiveWindowAuthoritative)
        assertEquals(4, named.activeWindowId)
        // Equality, and so StateFlow conflation, sees the flag and nothing else moved.
        assertNotEquals(provisional, named)
        assertEquals(named, provisional.copy(isActiveWindowAuthoritative = true))
        assertEquals(named.hashCode(), provisional.copy(isActiveWindowAuthoritative = true).hashCode())
        assertFalse(SharedTmuxEventDecoder.INITIAL_SNAPSHOT.isActiveWindowAuthoritative)

        // Through the decoder: the core sends a flip as a new revision, and it
        // replaces the held snapshot rather than being taken for a repeat.
        val decoder = SharedTmuxEventDecoder()
        val held = decoder.decode(envelope(snapshotJson(3))).snapshot
        val flipped = decoder.decode(envelope(snapshotJson(4).put("isActiveWindowAuthoritative", true))).snapshot
        assertFalse(held.isActiveWindowAuthoritative)
        assertTrue(flipped.isActiveWindowAuthoritative)
        assertSame(flipped, decoder.decode(envelope(key = 0 to 4)).snapshot)
        val flow = MutableStateFlow<SharedTmuxSnapshot?>(held)
        flow.value = flipped
        assertSame(flipped, flow.value)
    }

    @Test
    fun theRepublishGateSkipsOnlyAnAcceptedRepeatUnderTheSameGeneration() {
        val gate = TmuxSnapshotRepublishGate()
        val payload = "{}".encodeToByteArray()
        assertFalse(gate.isRepeat(payload, 1))

        gate.record(payload, 1, accepted = true)
        assertTrue(gate.isRepeat(payload, 1))
        assertFalse("a new generation must hear it again", gate.isRepeat(payload, 2))
        assertFalse("an equal but distinct payload is a re-sent snapshot", gate.isRepeat(payload.copyOf(), 1))

        gate.record(payload, 2, accepted = false)
        assertFalse("a refused publication is never a repeat", gate.isRepeat(payload, 2))
    }
}
