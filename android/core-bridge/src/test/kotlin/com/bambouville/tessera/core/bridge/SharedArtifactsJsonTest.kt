package com.bambouville.tessera.core.bridge

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Structural JSON coverage deliberately requires no shared native library. */
class SharedArtifactsJsonTest {
    @Test fun persistenceFilesPreserveManifestAndByteExactBlobStringsWithoutPolicy() {
        val digest = "a".repeat(64)
        val files = SharedArtifactsPersistenceFiles("{\"tabs\":[]}", mapOf(digest to "\u0000+café 📄\n"))
        val encoded = ArtifactsJson.encode(files)
        assertEquals(files, ArtifactsJson.persistenceFiles(JSONObject(ArtifactsJson.canonical(encoded))))
        assertEquals("{\"tabs\":[]}", encoded.getString("stateJSON"))
        assertEquals(files.blobs[digest], encoded.getJSONObject("blobs").getString(digest))
        assertFalse(ArtifactsJson.encode(SharedArtifactsPersistenceFiles("{}", emptyMap())).isNull("blobs"))
    }

    @Test fun refusedLoopbackLinksDecodeWithoutPageFields() {
        assertEquals(SharedArtifactsLinkClass.Refused, ArtifactsJson.link(JSONObject("{\"type\":\"refused\"}")))
        assertEquals(SharedArtifactsLinkClass.External, ArtifactsJson.link(JSONObject("{\"type\":\"external\"}")))
        assertEquals(SharedArtifactsLinkClass.Unsupported, ArtifactsJson.link(JSONObject("{\"type\":\"unsupported\"}")))
    }

    @Test fun canonicalStringsKeepLiteralSlashesWithoutLosingBackslashesOrControls() {
        val text = "</script>\\/\n\b\u0000📄"
        val encoded = ArtifactsJson.canonical(JSONObject().put("x", text))
        assertEquals(text, JSONObject(encoded).getString("x"))
        assertTrue(encoded.startsWith("{\"x\":\"</script>"))
    }

    @Test fun typedTargetsAndAllOptionalTabFieldsSurviveJson() {
        val targets = listOf(SharedArtifactsTarget.File("/a 📄.md"), SharedArtifactsTarget.Page("https", 65535, "/x?a=b#c"), SharedArtifactsTarget.Change("/b.kt", "\u0000+ café\n", "edit"))
        val tabs = targets.mapIndexed { index, target -> SharedArtifactTab("t$index", "host", "dev", target,
            SharedArtifactsKind.entries[index], "📄 $index", "futureOrigin", "session", Long.MAX_VALUE - 10, Long.MAX_VALUE - 1,
            index == 0, SharedArtifactsCacheMetadata(9_007_199_254_740_993, null, 0, true), true, -1) }
        val state = SharedArtifactsState(tabs = tabs, selectedId = "t1", filter = SharedArtifactsFilter.Pages)
        val json = ArtifactsJson.canonical(ArtifactsJson.encode(state))
        assertEquals(state, ArtifactsJson.state(JSONObject(json)))
        assertEquals(json, ArtifactsJson.canonical(ArtifactsJson.encode(ArtifactsJson.state(JSONObject(json)))))
        assertTrue(JSONObject(json).has("selectedID"))
        assertFalse(JSONObject(json).has("selectedId"))
        assertFalse(ArtifactsJson.encode(SharedArtifactsState()).has("selectedID"))
        assertFalse(JSONObject(json).getJSONArray("tabs").getJSONObject(0).getJSONObject("cache").has("remoteMTime"))
    }

    @Test fun everyActionUsesTheSwiftWireSpellingAndPreservesExplicitFalse() {
        val request = SharedArtifactsOpenRequest("t", "h", "dev", SharedArtifactsTarget.File("/a"), "a", "files")
        val actions = listOf(SharedArtifactsAction.Open(request, 1), SharedArtifactsAction.Select("t", 2), SharedArtifactsAction.Close("t", 3),
            SharedArtifactsAction.CloseAll("h", 4), SharedArtifactsAction.Pin("t", false, 5), SharedArtifactsAction.SetFilter(SharedArtifactsFilter.Changes, 6),
            SharedArtifactsAction.TitleLearned("t", "title", 7), SharedArtifactsAction.Fetched("t", SharedArtifactsCacheMetadata(8, null, 0), 8),
            SharedArtifactsAction.RemoteStatObserved("t", null, null, false, 9), SharedArtifactsAction.AgentEditObserved("h", "/a", 10),
            SharedArtifactsAction.HostRemoved("h", 11), SharedArtifactsAction.HostRelabelled("h", "renamed", 12),
            SharedArtifactsAction.Open(request.copy(newTab = true), 13),
            SharedArtifactsAction.Navigate("t", SharedArtifactsTarget.Page("https", 8001, "/laptop.html?x#y"), "localhost:8001", 14))
        actions.forEach { assertEquals(it, ArtifactsJson.action(ArtifactsJson.encode(it))) }
        // newTab is optional on the wire and omitted when false, as the Swift codec writes it.
        assertFalse(ArtifactsJson.encode(actions[0]).getJSONObject("open").has("newTab"))
        assertTrue(ArtifactsJson.encode(actions[12]).getJSONObject("open").getBoolean("newTab"))
        val navigate = ArtifactsJson.encode(actions[13])
        assertEquals("navigate", navigate.getString("type"))
        assertEquals("page", navigate.getJSONObject("target").getString("type"))
        val pin = ArtifactsJson.encode(actions[4])
        assertEquals("t", pin.getString("tabID"))
        assertTrue(pin.has("pinned"))
        assertFalse(pin.getBoolean("pinned"))
        val stat = ArtifactsJson.encode(actions[8])
        assertTrue(stat.has("visible"))
        assertFalse(stat.getBoolean("visible"))
        assertFalse(stat.has("remoteMTime"))
        assertFalse(stat.has("size"))
        assertEquals("h", ArtifactsJson.encode(actions[3]).getString("hostID"))
        assertTrue(ArtifactsJson.encode(actions[0]).has("open"))
    }

    @Test fun quickOpenContextsAndAllIntentTagsRoundTripWithoutPolicy() {
        val context = SharedArtifactsQuickOpenContext(listOf(SharedArtifactsQuickOpenHost("h", "dev", "/home/me")), "h", "/work", listOf(SharedArtifactsListeningPort(5173, "::1", null)))
        assertEquals(context, ArtifactsJson.context(ArtifactsJson.encode(context)))
        val forward = SharedArtifactsActiveForward("h", SharedForwardRule("11111111-1111-1111-1111-111111111111",
            bind = SharedForwardEndpoint("127.0.0.1", 15173), target = SharedForwardEndpoint("localhost", 5173), label = "vite"))
        val withForwards = context.copy(activeForwards = listOf(forward))
        val encoded = ArtifactsJson.encode(withForwards)
        assertEquals("h", encoded.getJSONArray("activeForwards").getJSONObject(0).getString("hostID"))
        assertEquals(withForwards, ArtifactsJson.context(JSONObject(ArtifactsJson.canonical(encoded))))
        encoded.remove("activeForwards")
        assertEquals(context, ArtifactsJson.context(encoded))
        val intents = listOf(SharedArtifactsQuickOpenIntent.File("h", "/a"), SharedArtifactsQuickOpenIntent.Directory("h", "/a/"),
            SharedArtifactsQuickOpenIntent.Page("h", "http", 5173, "/?a#b"), SharedArtifactsQuickOpenIntent.Search("a"), SharedArtifactsQuickOpenIntent.Invalid("missingCwd"))
        intents.forEach { assertEquals(it, ArtifactsJson.intent(ArtifactsJson.encode(it))) }
    }
}
