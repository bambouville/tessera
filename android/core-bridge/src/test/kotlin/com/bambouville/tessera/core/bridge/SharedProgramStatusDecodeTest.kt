package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SharedProgramStatusDecodeTest {
    private fun entry(state: String = "idle", token: Long = 5) = JSONObject()
        .put("idPath", JSONArray())
        .put("state", state)
        .put("historical", false)
        .put("unreadResult", false)
        .put("updateToken", token)

    private fun terminal(entries: JSONArray) = JSONObject().put("entries", entries)

    private fun document(terminals: JSONArray, version: Int = 1) = JSONObject()
        .put("version", version).put("revision", 12).put("terminals", terminals)
        .toString().encodeToByteArray()

    @Test
    fun fullDocumentPreservesTerminalsOptionalFieldsPrimaryAndTokens() {
        val token = 9_007_199_254_740_991L
        val blocked = entry("blocked", token - 1)
            .put("idPath", JSONArray().put("build").put("test"))
            .put("kind", "question").put("progress", 42).put("app", "cargo")
            .put("title", "deploy prod").put("message", "waiting")
            .put("historical", true).put("unreadResult", true)
            .put("resultToken", token).put("attention", "needsInput")
        val raw = terminal(JSONArray().put(entry("working")).put(blocked))
            .put("primary", 1).put("latestUnreadResultToken", token)
        val pane = terminal(JSONArray().put(entry("done").put("attention", "finished"))).put("paneID", 31).put("primary", 0)
        val snapshot = SharedProgramStatusSnapshot.decode(document(JSONArray().put(raw).put(pane)))

        assertEquals(12L, snapshot.revision)
        assertEquals(listOf(SharedProgramStatusTerminal.Raw, SharedProgramStatusTerminal.Pane(31)), snapshot.terminals.map { it.terminal })
        val rawSnapshot = checkNotNull(snapshot.terminal(SharedProgramStatusTerminal.Raw))
        val primary = checkNotNull(rawSnapshot.primaryEntry)
        assertSame(rawSnapshot.entries[1], primary)
        assertEquals(SharedProgramStatusTerminal.Raw, primary.terminal)
        assertEquals(listOf("build", "test"), primary.idPath)
        assertEquals(SharedProgramStatusState.BLOCKED, primary.state)
        assertEquals(SharedProgramStatusBlockedKind.QUESTION, primary.kind)
        assertEquals(42, primary.progress)
        assertEquals("cargo", primary.app)
        assertEquals("deploy prod", primary.title)
        assertEquals("waiting", primary.message)
        assertTrue(primary.isHistorical)
        assertTrue(primary.isUnreadResult)
        assertEquals(token - 1, primary.updateToken)
        assertEquals(token, primary.resultToken)
        assertEquals(token, rawSnapshot.latestUnreadResultToken)
        assertEquals(SharedProgramStatusAttention.NEEDS_INPUT, rawSnapshot.attention)
        assertEquals(SharedProgramStatusBlockedKind.QUESTION, rawSnapshot.blockedKind)
        val minimal = rawSnapshot.entries[0]
        assertEquals(emptyList<String>(), minimal.idPath)
        assertNull(minimal.kind)
        assertNull(minimal.progress)
        assertNull(minimal.app)
        assertNull(minimal.title)
        assertNull(minimal.message)
        assertNull(minimal.resultToken)
        assertNull(minimal.attention)
        val paneSnapshot = checkNotNull(snapshot.pane(31))
        assertEquals(SharedProgramStatusTerminal.Pane(31), paneSnapshot.entries.single().terminal)
        assertEquals(SharedProgramStatusAttention.FINISHED, paneSnapshot.attention)
        assertNull(paneSnapshot.blockedKind)
        assertNull(paneSnapshot.latestUnreadResultToken)
        assertNull(snapshot.pane(32))
    }

    @Test
    fun unknownEnumsDropEntriesWithoutRetargetingPrimary() {
        for (key in listOf("state", "kind", "attention")) {
            val rows = JSONArray().put(entry().put(key, "future")).put(entry("error", 7).put("attention", "failed"))
            val droppedPrimary = terminal(rows).put("primary", 0)
            val snapshot = SharedProgramStatusSnapshot.decode(document(JSONArray().put(droppedPrimary)))
            assertEquals(1, snapshot.terminals.single().entries.size)
            assertNull(snapshot.terminals.single().primaryEntry)
            assertNull(snapshot.terminals.single().attention)

            // The original index 1 still points at the survivor after index 0 was dropped.
            droppedPrimary.put("primary", 1)
            val surviving = SharedProgramStatusSnapshot.decode(document(JSONArray().put(droppedPrimary))).terminals.single()
            assertSame(surviving.entries.single(), surviving.primaryEntry)
            assertEquals(SharedProgramStatusAttention.FAILED, surviving.attention)
            assertNull(surviving.blockedKind)
        }
    }

    @Test
    fun everyKnownEnumDecodesAndPrimaryMayBeAbsentOrOutOfRange() {
        val rows = JSONArray()
        SharedProgramStatusState.entries.forEach { rows.put(entry(it.wireValue)) }
        SharedProgramStatusBlockedKind.entries.forEach { rows.put(entry("blocked").put("kind", it.wireValue)) }
        SharedProgramStatusAttention.entries.forEach { rows.put(entry().put("attention", it.wireValue)) }
        val row = terminal(rows)
        val snapshot = SharedProgramStatusSnapshot.decode(document(JSONArray().put(row))).terminals.single()
        assertEquals(11, snapshot.entries.size)
        assertNull(snapshot.primaryEntry)
        row.put("primary", 99)
        assertNull(SharedProgramStatusSnapshot.decode(document(JSONArray().put(row))).terminals.single().primaryEntry)
    }

    @Test
    fun unsupportedVersionAndMalformedDocumentThrow() {
        assertThrows(IllegalArgumentException::class.java) {
            SharedProgramStatusSnapshot.decode(document(JSONArray(), version = 2))
        }
        assertThrows(org.json.JSONException::class.java) {
            SharedProgramStatusSnapshot.decode("{}".encodeToByteArray())
        }
    }

    @Test
    fun fractionalAndStringNumbersAreRejectedRatherThanTruncated() {
        for (invalid in listOf(1.5, "1")) {
            for (key in listOf("version", "revision")) {
                val value = JSONObject(document(JSONArray()).decodeToString()).put(key, invalid)
                assertThrows(IllegalArgumentException::class.java) {
                    SharedProgramStatusSnapshot.decode(value.toString().encodeToByteArray())
                }
            }
            for (key in listOf("paneID", "primary", "latestUnreadResultToken")) {
                assertThrows(IllegalArgumentException::class.java) {
                    SharedProgramStatusSnapshot.decode(document(JSONArray().put(terminal(JSONArray()).put(key, invalid))))
                }
            }
            for (key in listOf("progress", "updateToken", "resultToken")) {
                assertThrows(IllegalArgumentException::class.java) {
                    SharedProgramStatusSnapshot.decode(document(JSONArray().put(terminal(JSONArray().put(entry().put(key, invalid))))))
                }
            }
        }
    }

    @Test
    fun emptyMonitorAndEmptyTerminalDecode() {
        assertEquals(emptyList<SharedProgramStatusTerminalSnapshot>(), SharedProgramStatusSnapshot.decode(document(JSONArray())).terminals)
        val empty = SharedProgramStatusSnapshot.decode(document(JSONArray().put(terminal(JSONArray())))).terminals.single()
        assertTrue(empty.entries.isEmpty())
        assertNull(empty.primaryEntry)
        assertNull(empty.attention)
        assertEquals(SharedProgramStatusSnapshot(0, emptyList()), SharedProgramStatusSnapshot.EMPTY)
    }

    private fun envelope(revision: Long?, wireOnly: Boolean): ByteArray {
        val value = JSONObject().put("version", 3).putOpt("programStatusRevision", revision)
        if (wireOnly) {
            value.put("platformWireCommands", JSONArray().put(JSONObject().put("tag", 1).put("command", "list-windows")))
        } else {
            value.put("snapshot", JSONObject().put("windows", JSONArray()).put("revision", 1))
                .put("bells", JSONArray()).put("renderEffects", JSONArray())
        }
        return value.toString().encodeToByteArray()
    }

    @Test
    fun stateAndWireOnlyEnvelopesDecodeRevisionWhenPresent() {
        for (wireOnly in listOf(false, true)) {
            assertEquals(123L, SharedTmuxRuntime.parse(envelope(123, wireOnly)).programStatusRevision)
            assertNull(SharedTmuxRuntime.parse(envelope(null, wireOnly)).programStatusRevision)
        }
    }
}
