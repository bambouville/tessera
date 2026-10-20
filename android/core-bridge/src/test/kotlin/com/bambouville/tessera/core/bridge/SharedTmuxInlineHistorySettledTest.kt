package com.bambouville.tessera.core.bridge

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * The wire shape of the inline (SSH+tmux) history settle.
 *
 * This effect is the ledger's promise that a gesture-triggered
 * `scrollbackRequested` has reached a terminal outcome — admitted, ignored,
 * exhausted or aborted. Dropping or mis-decoding it does not merely lose a
 * capture: the platform's latched history gesture is released here, and a
 * latch that is never released freezes every local scroll on that surface.
 */
class SharedTmuxInlineHistorySettledTest {
    private fun envelope(vararg effects: JSONObject): ByteArray =
        JSONObject()
            .put("version", 3)
            .put("snapshot", JSONObject().put("windows", JSONArray()).put("revision", 1))
            .put("bells", JSONArray())
            .put(
                "renderEffects",
                JSONArray().also { array -> effects.forEach(array::put) },
            )
            .toString()
            .encodeToByteArray()

    private fun settled(
        surfaceId: String = "live",
        windowId: Int = 1,
        paneId: Int = 16,
        epoch: Long = 4,
        depth: Int = 10_000,
        historySize: Int = 7_009,
        canDeepen: Boolean = false,
    ): JSONObject = JSONObject()
        .put("kind", "inlineHistorySettled")
        .put("surfaceID", surfaceId)
        .put(
            "owner",
            JSONObject()
                .put("windowID", windowId)
                .put("paneID", paneId)
                .put("epoch", epoch),
        )
        .put("depth", depth)
        .put("historySize", historySize)
        .put("canDeepen", canDeepen)

    @Test
    fun anExhaustedSettleDecodesWithItsCreditedDepthAndHistorySize() {
        val effects = SharedTmuxRuntime.parse(envelope(settled())).renderEffects

        assertEquals(
            listOf(
                SharedTmuxRenderEffect.InlineHistorySettled(
                    surfaceId = "live",
                    owner = SharedTmuxRenderOwner(windowId = 1, paneId = 16, epoch = 4),
                    depth = 10_000,
                    historySize = 7_009,
                    canDeepen = false,
                ),
            ),
            effects,
        )
    }

    /**
     * The open rung of the ladder. A platform that decoded `canDeepen` as
     * false here would stop at the first capture, which is the whole bug this
     * effect exists to fix.
     */
    @Test
    fun aSettleThatCanStillDeepenSaysSoOnTheWire() {
        val effects = SharedTmuxRuntime.parse(
            envelope(
                settled(
                    surfaceId = "pane:35",
                    paneId = 35,
                    depth = 2_000,
                    historySize = 9_460,
                    canDeepen = true,
                ),
            ),
        ).renderEffects

        assertEquals(
            listOf(
                SharedTmuxRenderEffect.InlineHistorySettled(
                    surfaceId = "pane:35",
                    owner = SharedTmuxRenderOwner(windowId = 1, paneId = 35, epoch = 4),
                    depth = 2_000,
                    historySize = 9_460,
                    canDeepen = true,
                ),
            ),
            effects,
        )
    }

    /** Ordering is the contract: the settle follows its capture's feed. */
    @Test
    fun theSettleDecodesInTheOrderTheLedgerEmittedIt() {
        val feed = JSONObject()
            .put("kind", "feed")
            .put("surfaceID", "live")
            .put(
                "owner",
                JSONObject().put("windowID", 1).put("paneID", 16).put("epoch", 4),
            )
            .put("bytesRef", JSONObject().put("id", 7))
            .put("source", "tmux-repaint-deep")

        val effects = SharedTmuxRuntime.parse(envelope(feed, settled())).renderEffects

        assertEquals(2, effects.size)
        assertEquals(
            SharedTmuxRenderFeedSource.DeepRepaint,
            (effects[0] as SharedTmuxRenderEffect.Feed).source,
        )
        assertEquals(
            SharedTmuxRenderEffect.InlineHistorySettled(
                surfaceId = "live",
                owner = SharedTmuxRenderOwner(windowId = 1, paneId = 16, epoch = 4),
                depth = 10_000,
                historySize = 7_009,
                canDeepen = false,
            ),
            effects[1],
        )
    }

    /**
     * An unknown effect kind still fails loudly. Silently skipping one would
     * let a newer core's ordered transaction arrive here half-applied.
     */
    @Test
    fun anUnknownEffectKindIsStillRejected() {
        val unknown = JSONObject()
            .put("kind", "inlineHistoryUnsettled")
            .put("surfaceID", "live")

        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxRuntime.parse(envelope(unknown))
        }
    }

    /** The raised ceiling is render bytes only; other payloads keep 1 MiB. */
    @Test
    fun renderBytesRideAHigherCeilingThanOrdinaryPayloads() {
        assertEquals(8_388_608L, CoreBridge.EXPECTED_MAX_RENDER_BYTES)
        assertEquals(1_048_576L, CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES)
    }
}
