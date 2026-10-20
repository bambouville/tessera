package com.bambouville.tessera.core.bridge

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The show-edge wire as Kotlin sees it. Responses are verbatim captures of
 * the core's encoder (`TmuxShowEdgesABITests` drives the same sequence).
 */
class SharedTmuxShowEdgesTest {
    @Test
    fun aSettlingShowReportsItsDeadline() {
        val reply = SharedTmuxShowEdges.parse(
            JSONObject("""{"nextDeadlineMillis":350,"isShown":false,"edges":[],"displayed":true,"showPending":true,"version":1,"transparent":false}"""),
        )
        assertTrue(reply.edges.isEmpty())
        assertEquals(
            SharedTmuxShowEdgesState(
                displayed = true,
                isShown = false,
                showPending = true,
                transparent = false,
                nextDeadlineMillis = 350,
            ),
            reply.state,
        )
    }

    @Test
    fun aShowCarriesItsSourceAndStep() {
        val reply = SharedTmuxShowEdges.parse(
            JSONObject("""{"edges":[{"stepAtMillis":350,"kind":"show","source":"show"}],"displayed":true,"version":1,"isShown":true,"showPending":false,"transparent":false}"""),
        )
        assertEquals(listOf(SharedTmuxShowEdge.Show(SharedTmuxAuthorityShowSource.SHOW, 350)), reply.edges)
        assertNull(reply.state?.nextDeadlineMillis)
        assertEquals(true, reply.state?.isShown)

        val open = SharedTmuxShowEdges.parse(
            JSONObject("""{"edges":[{"stepAtMillis":1350,"kind":"show","source":"explicitOpen"}],"displayed":true,"version":1,"isShown":true,"showPending":false,"transparent":false}"""),
        )
        assertEquals(listOf(SharedTmuxShowEdge.Show(SharedTmuxAuthorityShowSource.EXPLICIT_OPEN, 1_350)), open.edges)
    }

    @Test
    fun aReturnAfterAnUnreportedDebounceHidesFirst() {
        val reply = SharedTmuxShowEdges.parse(
            JSONObject("""{"nextDeadlineMillis":90350,"isShown":false,"edges":[{"kind":"hide"}],"displayed":true,"showPending":true,"version":1,"transparent":false}"""),
        )
        assertEquals(listOf(SharedTmuxShowEdge.Hide), reply.edges)
        assertEquals(90_350L, reply.state?.nextDeadlineMillis)
    }

    @Test
    fun theUnchangedReplyHasNoStateAndOtherVersionsAreRefused() {
        val reply = SharedTmuxShowEdges.parse(JSONObject("""{"version":1,"unchanged":true}"""))
        assertTrue(reply.edges.isEmpty())
        assertNull(reply.state)
        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxShowEdges.parse(JSONObject("""{"version":2,"unchanged":true}"""))
        }
        assertThrows(IllegalStateException::class.java) {
            SharedTmuxShowEdges.parse(
                JSONObject("""{"edges":[{"kind":"flicker"}],"displayed":true,"version":1,"isShown":true,"showPending":false,"transparent":false}"""),
            )
        }
    }

    @Test
    fun requestsCarryTheClockAndTheDisplayedFact() {
        val displayed = SharedTmuxShowEdges.requestJson("displayed", 1_000, displayed = false)
        assertEquals(setOf("version", "event", "nowMillis", "displayed"), displayed.keyNames())
        assertEquals(1, displayed.getInt("version"))
        assertEquals("displayed", displayed.getString("event"))
        assertEquals(1_000L, displayed.getLong("nowMillis"))
        assertEquals(false, displayed.getBoolean("displayed"))
        val tick = SharedTmuxShowEdges.requestJson("tick", 2_000)
        assertEquals(setOf("version", "event", "nowMillis"), tick.keyNames())
        // The state a tracker reports before its first reduction is the core's fresh snapshot.
        val fresh = SharedTmuxShowEdges.parse(
            JSONObject("""{"edges":[],"displayed":false,"version":1,"isShown":false,"showPending":false,"transparent":false}"""),
        )
        assertEquals(SharedTmuxShowEdgesState.INITIAL, fresh.state)
    }
}

/** Android's org.json has no `keySet()`. */
private fun JSONObject.keyNames(): Set<String> = keys().asSequence().toSet()
