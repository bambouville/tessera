package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.agent.platform.withoutTerminalEscapes
import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.core.bridge.SharedAgentSnapshot
import com.bambouville.tessera.core.bridge.SharedAgentSnapshotKind
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentLivePromptTest {
    @Test fun signatureTokensMatchSharedCore() {
        assertEquals("live-prompt-1f7d80ce51bbda6d", livePromptActionToken("claude\u001fquestion\u001fWhich database?\u001f1. Postgres"))
        assertEquals("live-prompt-3c4431348c5a03c9", livePromptActionToken("codex-deferred\u001f2"))
        assertEquals("live-prompt-b9ff9210a4e0b999", livePromptActionToken("é☐"))
    }

    @Test fun bottomRowsKeepWholeUtf8Rows() {
        assertEquals("last\n😀", bottomPromptRows("discard\nlast\n😀", 9))
        assertEquals("😀", bottomPromptRows("discard\nlast\n😀", 4))
        assertEquals("", bottomPromptRows("a very long row", 3))
        assertTrue(bottomPromptRows("x\n" + "a".repeat(16_380) + "\nend").encodeToByteArray().size <= 16_384)
        assertEquals(null, boundedPromptCursor(null))
        assertTrue(boundedPromptCursor("é".repeat(2_000))!!.encodeToByteArray().size <= 2_048)
    }

    /** The cases of AgentPromptScreenTests.testEscapesAreRemovedAndOnlyTheirCellsRemain in shared Core. */
    @Test fun escapesAreRemovedAsSharedCoreRemovesThem() {
        val cases = listOf(
            "\u001b[38;5;246m3.\u001b[39m Stop" to "3. Stop",
            "\u001b[1;38;2;215;119;87m❯\u001b[0m 1." to "❯ 1.",
            "\u001b]8;;https://example.com\u0007link\u001b]8;;\u0007 text" to "link text",
            "\u001b]8;id=1;https://example.com\u001b\\link\u001b]8;;\u001b\\" to "link",
            "\u001b(Bplain\u001b7\u001b=" to "plain",
            "row\u001b[38;5\nnext" to "row\nnext",
            "row\u001b\nnext" to "row\nnext",
            "\u001b❯ 1." to "❯ 1.",
            "\u001b]8;;unterminated\nnext" to "\nnext",
            "\u001b]8;;a\u001b[31mred" to "red",
            "\u001b[31m\u001b[0m" to "",
            "end\u001b" to "end",
            "\u001b\u001b[31mred" to "red",
            "plain ☐ row" to "plain ☐ row",
        )
        for ((raw, plain) in cases) assertEquals(raw, plain, withoutTerminalEscapes(raw))
        assertEquals("a\nb", bottomPromptRows("\u001b[1mdiscard\u001b[0m\na\n\u001b[2mb\u001b[22m", 3))
        // Backgrounds stay, each row on its own (Claude's current tab).
        val backgrounds = listOf(
            "a\u001b[38;5;16m\u001b[48;5;153mb\u001b[39m\u001b[49mc" to "a\u001b[0;48;5;153mb\u001b[0mc",
            "\u001b[44mab\ncd\u001b[0m" to "\u001b[0;44mab\u001b[0m\n\u001b[0;44mcd\u001b[0m",
            "\u001b[7mx\u001b[27my" to "\u001b[0;7mx\u001b[0my",
            "\u001b[7;104mx\u001b[0my" to "\u001b[0;7;104mx\u001b[0my",
            "\u001b[48:2::1:2:3mx" to "\u001b[0;48;2;1;2;3mx\u001b[0m",
            "\u001b[48;2;1;2;3mx\u001b[48;2;1;2;3my" to "\u001b[0;48;2;1;2;3mxy\u001b[0m",
            "\u001b[38;5;48mx\u001b[38;2;48;5;153my" to "xy",
            "\u001b[48;5mx\u001b[48;5;256my\u001b[?7mz" to "xyz",
            "\u001b[44m\u001b[0m\u001b[45m" to "",
            "\u001b[44m\u001b[38;5\nx" to "\n\u001b[0;44mx\u001b[0m",
        )
        for ((raw, kept) in backgrounds) {
            assertEquals(raw, kept, bottomPromptRows(raw))
            assertEquals(raw, withoutTerminalEscapes(raw), withoutTerminalEscapes(kept))
        }
    }

    @Test fun cardDecodesEveryLiveField() {
        val wire = """{
          "title":"Choose", "detail":"details", "token":{"rawValue":"live-prompt-x"},
          "kind":"multiSelect", "question":"Which?", "progress":"1 of 2",
          "isBlocking":false, "acceptsText":true, "pendingCount":2,
          "entry":{"optionID":"2","text":"draft"},
          "controls":[{"kind":"next","label":"Next","isSelected":true}],
          "options":[{"id":"1","label":"Postgres","isDefault":true,"detail":"database",
                      "role":"choice","isChecked":true,"acceptsText":false},
                     {"id":"2","label":"Other","isDefault":false,"role":"freeform","acceptsText":true}]
        }""".trimIndent()
        val card = AgentPresentation.promptFromWire(JSONObject(wire).toSharedObject())
        assertNotNull(card)
        assertEquals("multiSelect", card!!.kind)
        assertEquals("Which?", card.question)
        assertEquals("1 of 2", card.progress)
        assertEquals("details", card.detail)
        assertFalse(card.isBlocking)
        assertTrue(card.acceptsText)
        assertEquals(2, card.pendingCount)
        assertEquals(AgentPromptEntry("2", "draft"), card.entry)
        assertEquals(AgentPromptControl("next", "Next", true), card.controls.single())
        assertEquals(AgentPromptOption("1", "Postgres", true, "database", "choice", true, false), card.options.first())
        assertTrue(card.options.last().acceptsText)
    }

    @Test fun refusalCodesAreUserFacingAndStable() {
        assertEquals("stalePrompt", promptPlanRefusalCode("stalePrompt"))
        assertEquals("stalePrompt", promptPlanRefusalCode("unsupported"))
        assertEquals("terminalDraft", promptPlanRefusalCode("occupied"))
        assertEquals("verification_failed", promptPlanRefusalCode("verificationFailed"))
    }

    @Test fun deferredCardNeedsNoOptions() {
        val card = AgentPresentation.promptFromWire(JSONObject("""
            {"title":"Questions waiting","token":{"rawValue":"live-prompt-3c4431348c5a03c9"},
             "kind":"deferred","pendingCount":2,"options":[],
             "controls":[{"kind":"open","label":"Answer","isSelected":false}]}
        """).toSharedObject())
        assertNotNull(card)
        assertTrue(card!!.options.isEmpty())
        assertEquals("open", card.controls.single().kind)
    }

    @Test fun threadSummaryDecodesLiveWatchFlag() {
        val payload = JSONObject("""
            {"list":{"threads":[{"id":{"hostID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
              "providerID":{"rawValue":"codex"},"providerSessionID":"session"},
              "providerName":"Codex","livePromptWatch":true,"availability":{"actions":true}}]}}
        """).toSharedObject()
        val rows = AgentPresentation.list(SharedAgentSnapshot(1, SharedAgentSnapshotKind.List, payload))
        assertTrue(rows.single().livePromptWatch)
    }
}

private fun JSONObject.toSharedObject(): SharedAgentValue.ObjectValue = SharedAgentValue.ObjectValue(
    keys().asSequence().associateWith { key -> get(key).toSharedValue() })

private fun Any.toSharedValue(): SharedAgentValue = when (this) {
    is JSONObject -> toSharedObject()
    is JSONArray -> SharedAgentValue.ArrayValue((0 until length()).map { get(it).toSharedValue() })
    is String -> SharedAgentValue.StringValue(this)
    is Number -> SharedAgentValue.NumberValue(toString())
    is Boolean -> SharedAgentValue.BooleanValue(this)
    else -> SharedAgentValue.Null
}
