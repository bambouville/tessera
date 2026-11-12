package com.bambouville.tessera.core.bridge

import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test

class SharedArtifactsNativeTest {
    @Before fun requireNativeCore() {
        val state = CoreBridge.inspect()
        assumeTrue("host-built shared core unavailable: $state", state is CoreBridgeState.Ready)
    }

    @Test fun everySharedGoldenCaseRunsThroughTheTypedFacade() {
        val relative = "Packages/TesseraCore/Tests/TesseraCoreABITests/Fixtures/artifacts-abi-golden.json"
        val root = generateSequence(File(checkNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .firstOrNull { File(it, relative).isFile } ?: error("shared artifacts golden fixture is missing")
        val cases = JSONObject(File(root, relative).readText()).getJSONArray("cases")
        val symbols = mutableSetOf<String>()
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val symbol = case.getString("symbol")
            symbols += symbol
            fun expanded(text: String): String = if (case.has("repeatedDiffBytes"))
                text.replace("__artifacts_diff_256k__", "x".repeat(case.getInt("repeatedDiffBytes"))) else text
            val request = case.optString("requestJSON").takeUnless { case.isNull("requestJSON") }?.let { JSONObject(expanded(it)) }
            val expectedText = expanded(case.getString("responseJSON"))
            val expected = if (expectedText.startsWith('[')) null else JSONObject(expectedText)
            val actual: Any
            val wanted: Any
            when (symbol) {
                "tessera_artifacts_reduce" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.reduce(ArtifactsJson.state(r.getJSONObject("state")), ArtifactsJson.action(r.getJSONObject("action")))
                    wanted = ArtifactsJson.reduction(checkNotNull(expected))
                }
                "tessera_artifacts_overview" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.overview(ArtifactsJson.state(r.getJSONObject("state")), SharedArtifactsFilter.entries.first { it.wireValue == r.getString("filter") }, r.getString("query"))
                    wanted = ArtifactsJson.overview(checkNotNull(expected))
                }
                "tessera_artifacts_quick_open_parse" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.quickOpenParse(r.getString("input"), ArtifactsJson.context(r.getJSONObject("context")))
                    wanted = ArtifactsJson.intent(checkNotNull(expected))
                }
                "tessera_artifacts_quick_open_suggestions" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.quickOpenSuggestions(r.getString("input"), ArtifactsJson.state(r.getJSONObject("state")), ArtifactsJson.context(r.getJSONObject("context")),
                        ArtifactsJson.list(r.getJSONArray("recents"), ArtifactsJson::recent), r.getInt("limit"))
                    wanted = ArtifactsJson.list(JSONArray(expectedText), ArtifactsJson::suggestion)
                }
                "tessera_artifacts_classify_link" -> {
                    actual = SharedArtifacts.classifyLink(checkNotNull(request).getString("urlString"))
                    wanted = ArtifactsJson.link(checkNotNull(expected))
                }
                "tessera_artifacts_document_link" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.documentLink(r.getString("link"), r.getString("documentPath"), if (r.has("home")) r.getString("home") else null)
                    wanted = ArtifactsJson.documentLink(checkNotNull(expected))
                }
                "tessera_artifacts_listening_ports_command" -> {
                    actual = SharedArtifacts.listeningPortsCommand()
                    wanted = checkNotNull(expected).getString("command")
                }
                "tessera_artifacts_listening_ports_parse" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.listeningPortsParse(r.getString("output"), if (r.isNull("sshPort")) null else r.getInt("sshPort"))
                    wanted = ArtifactsJson.list(JSONArray(expectedText), ArtifactsJson::listeningPort)
                }
                "tessera_artifacts_forward_plan" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.forwardPlan(r.getInt("remotePort"), ArtifactsJson.list(r.getJSONArray("hostRules"), ArtifactsJson::rule))
                    wanted = ArtifactsJson.forwardPlan(checkNotNull(expected))
                }
                "tessera_artifacts_keep_as_rule" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.keepAsRule(ArtifactsJson.rule(r.getJSONObject("ephemeral")), r.getString("label"), r.getString("ruleID"))
                    wanted = ArtifactsJson.rule(checkNotNull(expected))
                }
                "tessera_artifacts_cache_key" -> {
                    actual = SharedArtifacts.cacheKey(ArtifactsJson.tab(checkNotNull(request).getJSONObject("tab")))
                    wanted = checkNotNull(expected).getString("key")
                }
                "tessera_artifacts_cache_evictions" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.cacheEvictions(ArtifactsJson.list(r.getJSONArray("entries"), ArtifactsJson::entry), r.getLong("budgetBytes"), ArtifactsJson.strings(r.getJSONArray("protectedKeys")).toSet())
                    wanted = ArtifactsJson.strings(checkNotNull(expected).getJSONArray("keys"))
                }
                "tessera_artifacts_cache_presentation" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.cachePresentation(ArtifactsJson.tab(r.getJSONObject("tab")), r.getBoolean("liveConnection"), r.getLong("nowMillis"))
                    wanted = ArtifactsJson.presentation(checkNotNull(expected))
                }
                "tessera_artifacts_decode_state" -> {
                    actual = SharedArtifacts.decodeState(checkNotNull(request).toString())
                    wanted = ArtifactsJson.state(checkNotNull(expected))
                }
                "tessera_artifacts_encode_state" -> {
                    actual = SharedArtifacts.encodeState(ArtifactsJson.state(checkNotNull(request)))
                    wanted = expectedText
                }
                "tessera_artifacts_split_state" -> {
                    actual = SharedArtifacts.splitState(ArtifactsJson.state(checkNotNull(request)))
                    wanted = ArtifactsJson.persistenceFiles(checkNotNull(expected))
                }
                "tessera_artifacts_state_blob_digests" -> {
                    actual = SharedArtifacts.stateBlobDigests(checkNotNull(request).toString())
                    wanted = ArtifactsJson.strings(checkNotNull(expected).getJSONArray("digests"))
                }
                "tessera_artifacts_join_state" -> {
                    val files = ArtifactsJson.persistenceFiles(checkNotNull(request))
                    actual = SharedArtifacts.joinState(files.stateJSON, files.blobs)
                    wanted = ArtifactsJson.state(checkNotNull(expected))
                }
                "tessera_artifacts_kind" -> {
                    val r = checkNotNull(request)
                    actual = SharedArtifacts.kind(r.getString("path"), if (r.isNull("mimeHint")) null else r.getString("mimeHint"))
                    wanted = ArtifactsJson.kind(checkNotNull(expected))
                }
                else -> error("unreplayed golden case: ${case.getString("name")} ($symbol)")
            }
            assertEquals(case.getString("name"), wanted, actual)
        }
        assertTrue("empty fixtures must not pass", cases.length() >= 14)
        assertEquals(19, symbols.size)
    }

    @Test fun richTypedStateRoundTripsThroughTheLenientSharedCodec() {
        var state = SharedArtifactsState()
        val targets = listOf(SharedArtifactsTarget.File("/work/naïve 📄.md"), SharedArtifactsTarget.Page("https", 8443, "/app?a=1#b"), SharedArtifactsTarget.Change("/work/A.kt", "+ café\n", "edit"))
        targets.forEachIndexed { index, target ->
            state = SharedArtifacts.reduce(state, SharedArtifactsAction.Open(SharedArtifactsOpenRequest("t$index", "h1", "dev", target, "📄 $index", "agentEdit", "s1"), 1_700_000_000_000L + index)).state
        }
        state = SharedArtifacts.reduce(state, SharedArtifactsAction.Fetched("t0", SharedArtifactsCacheMetadata(0, 1_699_999_999_000, 17), 1_700_000_000_100)).state
        state = SharedArtifacts.reduce(state, SharedArtifactsAction.Pin("t0", true, 1_700_000_000_101)).state
        state = SharedArtifacts.reduce(state, SharedArtifactsAction.AgentEditObserved("h1", "/work/naïve 📄.md", 1_700_000_000_102)).state
        assertEquals(state, SharedArtifacts.decodeState(SharedArtifacts.encodeState(state)))
        assertEquals(SharedArtifactsTarget.Page("https", 8443, "/app?a=1#b"), state.tabs[1].target)
        assertTrue(state.tabs[0].unseenChange)
        assertEquals(1_699_999_999_000, state.tabs[0].cache?.remoteMTime)
        assertFalse(SharedArtifacts.cachePresentation(state.tabs[0], false, 1_700_000_000_103).canRefresh)
    }

    @Test fun embeddedDiffsCrossTheGenericOneMiBCeiling() {
        val diff = "\u0001".repeat(200_000)
        val state = SharedArtifacts.reduce(SharedArtifactsState(), SharedArtifactsAction.Open(
            SharedArtifactsOpenRequest("t1", "h1", "dev", SharedArtifactsTarget.Change("/a.kt", diff, "edit"), "a.kt", "agentEdit"), 1,
        )).state
        assertTrue(SharedArtifacts.encodeState(state).encodeToByteArray().size > CoreBridge.EXPECTED_MAX_PAYLOAD_BYTES)
        assertEquals(state, SharedArtifacts.decodeState(SharedArtifacts.encodeState(state)))
    }

    @Test fun nativeArtifactsBoundaryRejectsNonDirectAndOversizedBuffers() {
        for ((buffer, count) in listOf(ByteBuffer.wrap("{}".encodeToByteArray()) to 2,
            ByteBuffer.allocateDirect(1) to SharedArtifacts.MAX_PAYLOAD_BYTES + 1,
            ByteBuffer.allocateDirect(1) to -1)) {
            try { NativeCoreBindings.artifactsDecodeState(buffer, count); error("invalid buffer accepted") }
            catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun savesBoundDiffBytesAndProtectedTabsThroughTheSharedCodec() {
        val prefix = "x".repeat(256 * 1024 - 1)
        val original = prefix + "é tail"
        val tabs = List(70) { index ->
            val target = if (index == 0) SharedArtifactsTarget.Change("/a.kt", original, "edit")
                else SharedArtifactsTarget.File("/file$index.md")
            SharedArtifactTab("t$index", "h1", "dev", target,
                if (index == 0) SharedArtifactsKind.Changes else SharedArtifactsKind.Docs,
                "tab $index", "agentEdit", null, index.toLong(), index.toLong(), index != 0, null, false, null)
        }
        val state = SharedArtifactsState(tabs = tabs, selectedId = "t0", tabCap = 100)
        val json = SharedArtifacts.encodeState(state)
        val saved = ArtifactsJson.state(JSONObject(json))
        assertEquals(64, saved.tabs.size)
        assertEquals(64, saved.tabCap)
        assertEquals("t0", saved.selectedId)
        assertEquals(listOf("t0") + (7..69).map { "t$it" }, saved.tabs.map { it.id })
        val diff = (saved.tabs.first().target as SharedArtifactsTarget.Change).diff
        val digest = MessageDigest.getInstance("SHA-256").digest(original.encodeToByteArray()).joinToString("") { "%02x".format(it) }
        assertEquals("\\ diff truncated; sha256: $digest\n", diff)
        assertTrue(diff.encodeToByteArray().size <= 256 * 1024)
        assertFalse(diff.contains('\uFFFD'))
        assertEquals(saved, SharedArtifacts.decodeState(json))
        assertEquals(json, ArtifactsJson.canonical(JSONObject(json)))
        assertEquals(json, SharedArtifacts.encodeState(SharedArtifacts.decodeState(json)))
    }

    @Test fun sharedPrefixDiffsStayDistinctAndReopenTheSameTabsAfterRestore() {
        val prefix = "+café\n".repeat(256 * 1024 / 7 + 1)
        val first = SharedArtifactsTarget.Change("/a.kt", prefix + "+first\n", "first")
        val second = SharedArtifactsTarget.Change("/a.kt", prefix + "+second\n", "second")
        fun open(state: SharedArtifactsState, id: String, target: SharedArtifactsTarget, now: Long) =
            SharedArtifacts.reduce(state, SharedArtifactsAction.Open(SharedArtifactsOpenRequest(id, "h1", "dev", target, "a.kt", "agentEdit"), now)).state
        val opened = open(open(SharedArtifactsState(), "first", first, 1), "second", second, 2)
        assertEquals(listOf("first", "second"), opened.tabs.map { it.id })
        assertEquals("second", opened.selectedId)
        val restored = SharedArtifacts.decodeState(SharedArtifacts.encodeState(opened))
        assertEquals(opened, restored)
        val reopened = open(restored, "ignored", first, 3)
        assertEquals(listOf("first", "second"), reopened.tabs.map { it.id })
        assertEquals("first", reopened.selectedId)
        reopened.tabs.forEach {
            assertTrue((it.target as SharedArtifactsTarget.Change).diff.encodeToByteArray().size <= 256 * 1024)
        }
    }

    @Test fun explicitNewTabsOpenBesideTheirPortAndNavigateRetargetsInPlace() {
        fun page(path: String) = SharedArtifactsTarget.Page("http", 8001, path)
        fun request(id: String, target: SharedArtifactsTarget, newTab: Boolean) =
            SharedArtifactsOpenRequest(id, "h1", "dev", target, "localhost:8001", "quickOpen", newTab = newTab)
        val root = SharedArtifacts.reduce(SharedArtifactsState(), SharedArtifactsAction.Open(request("root", page("/"), true), 1)).state
        val beside = SharedArtifacts.reduce(root, SharedArtifactsAction.Open(request("laptop", page("/laptop.html"), true), 2))
        assertEquals(listOf("root", "laptop"), beside.state.tabs.map { it.id })
        assertEquals(listOf("/", "/laptop.html"), beside.state.tabs.map { it.target.path })
        assertEquals("/laptop.html", beside.navigatedPath)
        // An automatic open of the identical location focuses that tab.
        val reopened = SharedArtifacts.reduce(beside.state, SharedArtifactsAction.Open(request("ignored", page("/laptop.html"), false), 3))
        assertEquals(2, reopened.state.tabs.size)
        assertEquals("laptop", reopened.focusedTabId)
        val navigated = SharedArtifacts.reduce(reopened.state, SharedArtifactsAction.Navigate("root", page("/docs/?q"), "docs", 4))
        assertEquals("root", navigated.focusedTabId)
        assertEquals("/docs/?q", navigated.navigatedPath)
        assertEquals(page("/docs/?q"), navigated.state.tabs.first { it.id == "root" }.target)
        assertEquals("docs", navigated.state.tabs.first { it.id == "root" }.title)
    }

    @Test fun splitAndJoinValidateBlobsAndBoundTheTotalRetainedUTF8Bytes() {
        val diff = "é".repeat(128 * 1024)
        val tabs = List(18) { index -> SharedArtifactTab("t$index", "h1", "dev",
            SharedArtifactsTarget.Change("/$index.kt", diff, "edit"), SharedArtifactsKind.Changes, "t$index", "agentEdit", null,
            index.toLong(), index.toLong(), index == 0, null, false, null) }
        val files = SharedArtifacts.splitState(SharedArtifactsState(tabs = tabs, selectedId = "t1"))
        assertEquals(1, files.blobs.size)
        assertFalse(files.stateJSON.contains("\"diff\":"))
        val restored = SharedArtifacts.joinState(files.stateJSON, files.blobs)
        assertEquals(listOf("t0", "t1") + (4..<18).map { "t$it" }, restored.tabs.map { it.id })
        assertEquals(4 * 1024 * 1024, restored.tabs.sumOf { (it.target as SharedArtifactsTarget.Change).diff.encodeToByteArray().size })
        val digest = files.blobs.keys.single()
        assertEquals(listOf(digest), SharedArtifacts.stateBlobDigests(files.stateJSON))
        assertTrue(SharedArtifacts.joinState(files.stateJSON, emptyMap()).tabs.isEmpty())
        assertTrue(SharedArtifacts.joinState(files.stateJSON, mapOf(digest to "+tampered")).tabs.isEmpty())
        assertTrue(SharedArtifacts.joinState(files.stateJSON, mapOf(digest to "x".repeat(256 * 1024 + 1))).tabs.isEmpty())
        for (entry in listOf(NativeArtifactsPersistenceBindings::encodeState, NativeArtifactsPersistenceBindings::splitState,
            NativeArtifactsPersistenceBindings::blobDigests, NativeArtifactsPersistenceBindings::joinState)) {
            for ((buffer, count) in listOf(ByteBuffer.wrap("{}".encodeToByteArray()) to 2,
                ByteBuffer.allocateDirect(1) to SharedArtifacts.MAX_PAYLOAD_BYTES + 1,
                ByteBuffer.allocateDirect(1) to -1, ByteBuffer.allocateDirect(2).put(0, 0xff.toByte()).put(1, 0xfe.toByte()) to 2)) {
                try { entry(buffer, count); error("invalid buffer accepted") } catch (_: IllegalArgumentException) { }
            }
        }
    }
}
