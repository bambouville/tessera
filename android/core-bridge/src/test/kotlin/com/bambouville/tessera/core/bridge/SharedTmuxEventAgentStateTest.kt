package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The envelope decode for pane lifecycle.
 *
 * Core publishes `@tessera_agent_state` for every pane of the attached tmux
 * session; rendered output only ever carries the pane on screen. Dropping this
 * array here would leave Agent Center blind to every agent working in a window
 * the user is not looking at, which is how it presented as empty on a host
 * running one agent per window.
 */
class SharedTmuxEventAgentStateTest {
    private fun envelope(agentStates: JSONArray?): ByteArray =
        JSONObject()
            .put("version", 3)
            .put("snapshot", JSONObject().put("windows", JSONArray()).put("revision", 1))
            .put("bells", JSONArray())
            .put("renderEffects", JSONArray())
            .putOpt("agentStates", agentStates)
            .toString()
            .encodeToByteArray()

    private fun state(windowId: Int, paneId: Int, json: String): JSONObject =
        JSONObject()
            .put("windowID", JSONObject().put("rawValue", windowId))
            .put("paneID", JSONObject().put("rawValue", paneId))
            .put("json", json)

    @Test
    fun agentStatesArriveWithTheirPaneAddress() {
        val payload = """{"version":9,"provider":"claude","event":"Stop","state":"idle"}"""

        val event = SharedTmuxRuntime.parse(
            envelope(JSONArray().put(state(7, 70, payload)).put(state(3, 30, payload))),
        )

        assertEquals(
            listOf(
                SharedTmuxPaneAgentState(windowId = 7, paneId = 70, json = payload),
                SharedTmuxPaneAgentState(windowId = 3, paneId = 30, json = payload),
            ),
            event.agentStates,
        )
    }

    /** An envelope from a core that predates the feed must still decode. */
    @Test
    fun anEnvelopeWithoutTheFieldDecodesToNoAgentStates() {
        assertTrue(SharedTmuxRuntime.parse(envelope(null)).agentStates.isEmpty())
    }

    /** A half-addressed row can never be routed, so it is dropped, not guessed. */
    @Test
    fun anIncompleteAgentStateIsDroppedRatherThanRoutedToTheWrongPane() {
        val incomplete = JSONArray()
            .put(JSONObject().put("paneID", JSONObject().put("rawValue", 70)).put("json", "{}"))
            .put(JSONObject().put("windowID", JSONObject().put("rawValue", 7)).put("json", "{}"))
            .put(state(7, 70, ""))

        assertTrue(SharedTmuxRuntime.parse(envelope(incomplete)).agentStates.isEmpty())
    }
}
