package com.bambouville.tessera.core.bridge

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * The Kotlin side of `tessera_tmux_runtime_project_authority_releasing`
 * and `tessera_tmux_runtime_set_render_ledger_options`: the released work is
 * the core's canonical `{"renderEffects":[...]}` document, decoded exactly as
 * a callback's effects, and the option bits are the header's.
 */
class SharedTmuxClaimSettlementTest {
    @Test
    fun aSettlementReleasesItsEffectsInTheOrderTheCoreGaveThem() {
        val document = """{"renderEffects":[""" +
            """{"command":"display-message -p -t @1 'deep'","kind":"sendCommand"},""" +
            """{"kind":"diagnostic","message":"render-ledger released"}""" +
            """]}"""
        assertEquals(
            SharedTmuxClaimSettlement.Released(
                listOf(
                    SharedTmuxRenderEffect.SendCommand("display-message -p -t @1 'deep'"),
                    SharedTmuxRenderEffect.Diagnostic("render-ledger released"),
                ),
            ),
            SharedTmuxClaimSettlement.decode(document.encodeToByteArray()),
        )
        assertEquals(
            SharedTmuxClaimSettlement.Released(emptyList()),
            SharedTmuxClaimSettlement.decode("""{"renderEffects":[]}""".encodeToByteArray()),
        )
    }

    @Test
    fun anyOtherShapeIsNotASettlement() {
        for (document in listOf(
            """{}""",
            """{"renderEffects":[],"snapshot":{}}""",
            """{"renderEffects":[{"kind":"unknown"}]}""",
            """[]""",
        )) {
            assertThrows(document, Exception::class.java) {
                SharedTmuxClaimSettlement.decode(document.encodeToByteArray())
            }
        }
    }

    private fun canonicalJSON(value: org.json.JSONObject): String = value.keys().asSequence().toList().sorted()
        .joinToString(prefix = "{", postfix = "}") { key ->
            val field = value.get(key)
            "$key=" + if (field is org.json.JSONObject) canonicalJSON(field) else field.toString()
        }

    @Test
    fun authorityProjectionUsesTheSnapshotsCodableEnumShape() {
        fun same(expected: String, authority: SharedTmuxGridAuthoritySnapshot) = assertEquals(
            canonicalJSON(org.json.JSONObject(expected)), canonicalJSON(org.json.JSONObject(authority.runtimeJSON().decodeToString())),
        )
        same("""{"unknown":{}}""", SharedTmuxGridAuthoritySnapshot.Unknown)
        same("""{"mine":{"generation":8}}""", SharedTmuxGridAuthoritySnapshot.Mine(8))
        same("""{"peer":{"deviceID":"ipad","displayName":"iPad","generation":7}}""",
            SharedTmuxGridAuthoritySnapshot.Peer("ipad", "iPad", 7))
        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxGridAuthoritySnapshot.Mine(-1).runtimeJSON()
        }
    }

    @Test
    fun theRenderLedgerOptionBitsAreTheHeaders() {
        val header = File("../../Packages/TesseraCore/Sources/TesseraCoreCABIHeaders/include/TesseraCoreABI.h")
            .readText()
        fun defined(name: String): Int =
            Regex("""#define $name (\d+)u""").find(header)?.groupValues?.get(1)?.toInt()
                ?: error("$name is not defined in the header")
        assertEquals(
            defined("TESSERA_TMUX_RENDER_LEDGER_SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY"),
            SharedTmuxRenderLedgerOptions.SUPPRESSES_UNCHANGED_CLIENT_SIZE_REPLAY,
        )
        assertEquals(
            defined("TESSERA_TMUX_RENDER_LEDGER_INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM"),
            SharedTmuxRenderLedgerOptions.INLINE_CLIENT_SIZE_REPLAY_BELONGS_TO_CLAIM,
        )
        assertEquals(
            defined("TESSERA_TMUX_RENDER_LEDGER_PIPELINES_VISIBLE_CAPTURE"),
            SharedTmuxRenderLedgerOptions.PIPELINES_VISIBLE_CAPTURE,
        )
        assertEquals(
            "every header bit has a Kotlin name",
            3,
            Regex("""#define TESSERA_TMUX_RENDER_LEDGER_\w+ \d+u""").findAll(header).count(),
        )
    }
}
