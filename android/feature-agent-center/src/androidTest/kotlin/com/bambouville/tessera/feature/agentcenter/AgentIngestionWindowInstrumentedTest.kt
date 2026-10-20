package com.bambouville.tessera.feature.agentcenter

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.core.bridge.*
import com.bambouville.tessera.design.TesseraTheme
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Real JNI reducer + production Compose detail; no network, host, or private transcript. */
@RunWith(AndroidJUnit4::class)
class AgentIngestionWindowInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()
    private data class FrameLimitCase(val inventory: Boolean, val kind: String, val frames: Int, val bytes: Int, val total: Int)

    @Test fun initiallyDetachedWindowCanPage() {
        val fixture = WindowFixture(provider = "pi")
        try {
            fixture.start()
            compose.waitUntil(15_000) { fixture.detail?.live?.isNotEmpty() == true }
            for (page in 1..4) {
                compose.runOnUiThread { fixture.request("before") }
                compose.waitUntil(10_000) { fixture.oldest == 1100 - page * 100 && !fixture.loading }
            }
            compose.waitUntil(10_000) { fixture.detail?.window?.atLiveHead == false }
            compose.runOnUiThread { compose.activity.installFixture { TesseraTheme {
                AgentDetailPane(fixture.detail, "", {}, {}, {}, { _, _ -> }, {},
                    { fixture.request("before") }, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding(),
                    loadingTranscript = fixture.loading, onLoadNewer = { fixture.request("after") },
                    onReturnToLatest = { fixture.request("bootstrap") }, onViewportAnchor = fixture::anchor)
            } } }
            compose.waitForIdle()
            compose.onNodeWithTag("agent-transcript-list").performTouchInput { swipeDown(durationMillis = 600) }
            compose.waitUntil(10_000) { fixture.oldest < 700 }
            assertFalse(fixture.detail!!.window!!.atLiveHead)
        } finally { closeWithPane(fixture) }
    }

    /** A `window.capacity.v1` host lets shared Core keep more than the legacy
     * four pages. The fixture reports the host's advertised capacity exactly
     * as the presenter does before a bootstrap; Core's default (compact)
     * memory tier then allows up to sixteen retained pages. */
    @Test fun capacityHostRetainsMoreThanFourSegments() {
        val fixture = WindowFixture(hostWindowSegments = AgentIngestionConnection.MAXIMUM_WINDOW_SEGMENTS)
        try {
            fixture.start()
            compose.waitUntil(15_000) { fixture.detail?.live?.isNotEmpty() == true }
            for (page in 1..7) {
                compose.runOnUiThread { fixture.request("before") }
                compose.waitUntil(10_000) { fixture.oldest == 1100 - page * 100 && !fixture.loading }
            }
            fixture.failure?.let { throw AssertionError("Native window fixture failed", it) }
            assertEquals("every page stays retained", 8, fixture.maximumSegments)
            assertTrue(fixture.detail!!.live.size > 500)
            assertEquals(400, fixture.oldest)
            android.util.Log.i("TesseraAgentWindow", "capacity host maxSegments=${fixture.maximumSegments} live=${fixture.detail!!.live.size}")
        } finally { fixture.close() }
    }

    @Test fun chatFollowsSameRecordGrowth() {
        val fixture = WindowFixture(chatFollow = true)
        try {
            compose.runOnUiThread { compose.activity.installFixture { TesseraTheme {
                AgentDetailPane(fixture.detail, "", {}, {}, {}, { _, _ -> }, {},
                    { fixture.request("before") }, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding(),
                    loadingTranscript = fixture.loading, onLoadNewer = { fixture.request("after") },
                    onReturnToLatest = { fixture.request("bootstrap") }, onViewportAnchor = fixture::anchor)
            } } }
            fixture.start()
            compose.waitUntil(15_000) { fixture.detail?.live?.isNotEmpty() == true }
            compose.waitForIdle()
            val list = compose.onNodeWithTag("agent-transcript-list")
            val tail = compose.onNodeWithText("Chat tail", substring = true)
            capture("chat-initial-bottom")
            tail.assertIsDisplayed()
            assertTrue(tail.fetchSemanticsNode().boundsInRoot.bottom <= list.fetchSemanticsNode().boundsInRoot.bottom + 3)
            val version = fixture.detail!!.window!!.version
            compose.runOnUiThread { fixture.tailLines = 80; fixture.request("head") }
            compose.waitUntil(10_000) { (fixture.detail?.window?.version ?: 0) > version }
            compose.waitForIdle()
            capture("chat-same-record-growth")
            // Compose clips semantics bounds to the list, so query the final
            // line rather than mistaking a clipped, oversized text node for a
            // tail that really reached the viewport.
            compose.onNodeWithText("End of latest reply.").assertIsDisplayed()
            list.performTouchInput { swipeDown(durationMillis = 600) }
            compose.waitForIdle()
            val latest = compose.onNodeWithTag("agent-return-latest")
            latest.assertIsDisplayed()
            val anchorY = tail.fetchSemanticsNode().positionInRoot.y
            capture("chat-detached-before")
            val detachedVersion = fixture.detail!!.window!!.version
            compose.runOnUiThread { fixture.tailLines = 120; fixture.request("head") }
            compose.waitUntil(10_000) { fixture.detail!!.window!!.version > detachedVersion }
            compose.waitForIdle()
            capture("chat-detached-growth")
            assertEquals(anchorY, tail.fetchSemanticsNode().positionInRoot.y, 3f)
            latest.performClick()
            compose.waitForIdle()
            capture("chat-returned-to-latest")
            compose.onNodeWithText("End of latest reply.").assertIsDisplayed()
            val headVersion = fixture.detail!!.window!!.version
            compose.runOnUiThread { fixture.request("head", advance = 3) }
            compose.waitUntil(10_000) { fixture.detail!!.window!!.version > headVersion }
            compose.waitForIdle()
            capture("chat-coalesced-tools")
            compose.onNodeWithText("End of latest reply.").assertIsDisplayed()
        } finally { closeWithPane(fixture) }
    }

    /** Only every hundredth record is visible, so each page adds one row and
     * the transcript is shorter than the viewport. It sits against the
     * composer and pages older history itself (a list that cannot scroll
     * cannot be asked for history), stopping before a page would evict the
     * live head. */
    @Test fun shortTranscriptSitsAtTheEndAndFillsFromHistory() {
        val fixture = WindowFixture(sparse = 100)
        try {
            installPane(fixture)
            fixture.start()
            compose.waitUntil(15_000) { fixture.detail?.live?.isNotEmpty() == true }
            compose.waitUntil(20_000) { fixture.oldest == 800 && !fixture.loading }
            android.os.SystemClock.sleep(2_000)
            compose.waitForIdle()
            capture("short-transcript-filled")
            fixture.failure?.let { throw AssertionError("Native window fixture failed", it) }
            assertEquals("legacy capacity is four pages", 4, fixture.maximumSegments)
            assertEquals("no fifth page evicted the head", 800, fixture.oldest)
            assertEquals(1100, fixture.newest)
            assertFalse(fixture.detail!!.window!!.olderPageFits)
            assertTrue(fixture.detail!!.window!!.atLiveHead)
            val list = compose.onNodeWithTag("agent-transcript-list").fetchSemanticsNode().boundsInRoot
            val newest = compose.onNodeWithText("History record 1100", substring = true).fetchSemanticsNode().boundsInRoot
            val slack = 32 * compose.activity.resources.displayMetrics.density
            assertTrue("newest row ${newest.bottom} ends at the list end ${list.bottom}",
                newest.bottom <= list.bottom + 3 && newest.bottom >= list.bottom - slack)
        } finally { closeWithPane(fixture) }
    }

    /** A followed append is positioned in the frame that first draws it. A
     * follow that scrolled a frame later drew the end offscreen once, then
     * jumped: the transcript stuttered on every append. */
    @Test fun followedAppendLandsInTheFrameThatDrawsIt() {
        val fixture = WindowFixture(chatFollow = true)
        try {
            installPane(fixture)
            fixture.start()
            compose.waitUntil(15_000) { fixture.detail?.live?.isNotEmpty() == true }
            compose.waitForIdle()
            for (append in 1..3) {
                val version = fixture.detail!!.window!!.version
                val previousTail = compose.onNodeWithText("End of latest reply.").fetchSemanticsNode().id
                compose.mainClock.autoAdvance = false
                compose.runOnUiThread { fixture.request("head", advance = 3) }
                compose.waitUntil(10_000) { fixture.detail!!.window!!.version > version }
                compose.mainClock.advanceTimeByFrame()
                val tail = compose.onNodeWithText("End of latest reply.")
                // The append is a new lazy item: this frame composed it.
                assertNotEquals("append $append drew its own tail", previousTail, tail.fetchSemanticsNode().id)
                assertEndsAtListEnd(tail, "append $append")
                compose.mainClock.autoAdvance = true
                compose.waitForIdle()
            }
        } finally {
            compose.mainClock.autoAdvance = true
            closeWithPane(fixture)
        }
    }

    /** A following reader keeps history while the full head page rolls. A
     * revision that splits that head leaves a gap the host will not let the
     * viewport span; the reader goes back to the latest page rather than
     * being left on history behind a Return to latest. */
    /** A revision split drops the rows between the viewport and the head's
     * last part from the host's window. They stay shown while a (slow) newer
     * page retains them: the newest rows never vanish and history stays. */
    @Test fun followerKeepsTheNewestRowsWhenARevisionSplitsItsRolledHead() {
        val fixture = WindowFixture()
        try {
            installPane(fixture)
            fixture.start()
            compose.waitUntil(15_000) { fixture.detail?.live?.isNotEmpty() == true && !fixture.loading }
            compose.waitForIdle()
            compose.runOnUiThread { fixture.request("before") }
            compose.waitUntil(10_000) { fixture.oldest <= 1000 && !fixture.loading }
            compose.runOnUiThread { fixture.request("head", advance = 42) }
            compose.waitUntil(10_000) { fixture.newest == 1241 && !fixture.loading }
            assertTrue("the rolled head keeps history", fixture.oldest <= 1000 && fixture.detail!!.window!!.atLiveHead)
            // Head 1142..1241 splits after 1211: the viewport ends at 1199,
            // so 1200..1211 leave the retained window.
            fixture.afterDelayMillis = 3_000
            fixture.splitHead(70)
            compose.waitUntil(10_000) { fixture.detail!!.window!!.transition == "revisions" }
            compose.waitForIdle()
            fixture.failure?.let { throw AssertionError("Native window fixture failed", it) }
            assertTrue(fixture.detail!!.window!!.bridgesToHead)
            assertTrue(fixture.detail!!.window!!.atLiveHead)
            assertEquals(1241, fixture.newest)
            assertTrue(fixture.detail!!.live.any { it.recordID == "fixture-record-1205" })
            assertEndsAtListEnd(compose.onNodeWithText("History record 1241", substring = true), "bridged")
            compose.waitUntil(10_000) { fixture.detail!!.window!!.transition == "after" && !fixture.loading }
            compose.waitForIdle()
            fixture.failure?.let { throw AssertionError("Native window fixture failed", it) }
            assertFalse(fixture.detail!!.window!!.bridgesToHead)
            assertTrue(fixture.detail!!.window!!.atLiveHead)
            assertEquals(1241, fixture.newest)
            assertTrue("a newer page keeps the history", fixture.oldest <= 1000)
            assertEndsAtListEnd(compose.onNodeWithText("History record 1241", substring = true), "retained")
            compose.onNodeWithTag("agent-return-latest").assertDoesNotExist()
        } finally { closeWithPane(fixture) }
    }

    /** The IME and window resizes relayout the list without recomposing the
     * pane. A follow requested after that layout drew the end cut off for a
     * frame, on every frame of the keyboard animation. */
    @Test fun followedTranscriptKeepsItsEndInTheFrameThatResizesIt() {
        val fixture = WindowFixture(chatFollow = true)
        val height = mutableStateOf(1f)
        try {
            installPane(fixture, height)
            fixture.start()
            compose.waitUntil(15_000) { fixture.detail?.live?.isNotEmpty() == true }
            compose.waitForIdle()
            val frames = TailFrames("End of latest reply.")
            for (fraction in listOf(0.6f, 0.45f, 0.8f, 1f)) {
                frames.record("resized to $fraction") { compose.runOnUiThread { height.value = fraction } }
                assertEndsAtListEnd(compose.onNodeWithText("End of latest reply."), "resized to $fraction")
            }
            assertEquals("every drawn frame ends at the tail", emptyList<String>(), frames.misplaced)
        } finally { closeWithPane(fixture) }
    }

    /** Measures the tail before every draw. A resize applies without the
     * test clock, and a correction one layout later still draws the clipped
     * frame first: settled semantics cannot see that frame. */
    private inner class TailFrames(private val text: String) {
        val misplaced = java.util.Collections.synchronizedList(mutableListOf<String>())
        // Views belong to the UI thread, the hierarchy walk included.
        private val root = compose.runOnUiThread {
            generateSequence(listOf<android.view.View>(compose.activity.window.decorView)) { views ->
                views.flatMap { view -> (view as? android.view.ViewGroup)?.let { group -> (0 until group.childCount).map(group::getChildAt) }.orEmpty() }
                    .takeIf { it.isNotEmpty() }
            }.flatten().filterIsInstance<androidx.compose.ui.platform.ViewRootForTest>().first()
        }

        fun record(label: String, change: () -> Unit) {
            val slack = 32 * compose.activity.resources.displayMetrics.density
            val listener = android.view.ViewTreeObserver.OnPreDrawListener {
                val nodes = generateSequence(listOf(root.semanticsOwner.unmergedRootSemanticsNode)) { it.flatMap { node -> node.children }.takeIf { it.isNotEmpty() } }.flatten()
                val list = nodes.firstOrNull { it.config.getOrNull(SemanticsProperties.TestTag) == "agent-transcript-list" }
                val tail = nodes.firstOrNull { node -> node.config.getOrNull(SemanticsProperties.Text)?.any { it.text == text } == true }
                val bottom = tail?.let { it.positionInRoot.y + it.size.height }
                val end = list?.boundsInRoot?.bottom
                if (bottom == null || end == null || bottom > end + 3 || bottom < end - slack) misplaced += "$label: tail $bottom, list $end"
                true
            }
            val observer = (root as android.view.View).viewTreeObserver
            compose.runOnUiThread { observer.addOnPreDrawListener(listener) }
            try { change(); compose.waitForIdle() }
            finally { compose.runOnUiThread { observer.removeOnPreDrawListener(listener) } }
        }
    }

    /** Unclipped: `boundsInRoot` stops at the list edge whatever lies past it. */
    private fun assertEndsAtListEnd(node: SemanticsNodeInteraction, message: String) {
        val list = compose.onNodeWithTag("agent-transcript-list").fetchSemanticsNode().boundsInRoot
        val tail = node.fetchSemanticsNode()
        val bottom = tail.positionInRoot.y + tail.size.height
        val slack = 32 * compose.activity.resources.displayMetrics.density
        assertTrue("$message: the tail ends at $bottom, the list at ${list.bottom}",
            bottom <= list.bottom + 3 && bottom >= list.bottom - slack)
    }

    /** [height] resizes the pane in measure only, as the IME does: the pane
     * itself does not recompose for it. */
    private fun installPane(fixture: WindowFixture, height: State<Float>? = null) {
        compose.runOnUiThread { compose.activity.installFixture { TesseraTheme {
            AgentDetailPane(fixture.detail, "", {}, {}, {}, { _, _ -> }, {},
                { fixture.request("before") }, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding().layout { measurable, constraints ->
                    val maximum = height?.let { (constraints.maxHeight * it.value).toInt() } ?: constraints.maxHeight
                    val placeable = measurable.measure(constraints.copy(minHeight = minOf(constraints.minHeight, maximum), maxHeight = maximum))
                    layout(placeable.width, placeable.height) { placeable.place(0, 0) }
                },
                loadingTranscript = fixture.loading, onLoadNewer = { fixture.request("after") },
                onReturnToLatest = { fixture.request("bootstrap") }, onViewportAnchor = fixture::anchor,
                onFillHistory = { if (fixture.detail?.window?.olderPageFits == true) fixture.request("before") },
                onRetainBridgedRows = { if (fixture.detail?.window?.bridgesToHead == true) fixture.request("after") })
        } } }
    }

    @Test fun evictedHistoryAndLiveHeadRemainIndependentlyNavigable() {
        assertNull("fixture must not add a platform action bar", compose.activity.actionBar)
        for (capability in listOf("", "opencode-sqlite-v1", "opencode.sqlite.v1-v2", "opencode.sqlite.v3")) {
            val hello = JSONObject("""{"v":3,"capabilities":["bounded.windows","window.partitions"]}""")
            hello.getJSONArray("capabilities").put(capability)
            assertEquals(capability == "opencode.sqlite.v1-v2", AgentIngestionConnection.helloSupportsOpenCodeSessions(hello))
            assertFalse(AgentIngestionConnection.helloSupportsPiSessions(hello))
        }
        for (capability in listOf("", "kimi-wire-jsonl-v1", "kimi.wire.v1.4-v1.5", "kimi.wire.v2")) {
            val hello = JSONObject().put("v", 3).put("capabilities", JSONArray()
                .put("bounded.windows").put("window.partitions").put(capability))
            assertEquals(capability == "kimi.wire.v1.4-v1.5", AgentIngestionConnection.helloSupportsKimiSessions(hello))
            assertFalse(AgentIngestionConnection.helloSupportsPiSessions(hello))
            assertFalse(AgentIngestionConnection.helloSupportsOpenCodeSessions(hello))
        }
        for (capability in listOf("", "pi-rpc-v1", "pi.sessions.v1-v3", "pi.sessions.v4")) {
            val hello = JSONObject("""{"v":3,"capabilities":["bounded.windows","window.partitions"]}""")
            hello.getJSONArray("capabilities").put(capability)
            assertEquals(capability == "pi.sessions.v1-v3", AgentIngestionConnection.helloSupportsPiSessions(hello))
        }
        for (version in listOf("3", "2", "4", "3.5", "\"3\"", "null")) {
            val hello = JSONObject("""{"v":$version,"capabilities":["bounded.windows","window.partitions"]}""")
            assertEquals("Strict native handshake: $version", version == "3",
                runCatching { AgentIngestionConnection.validateHello(hello) }.isSuccess)
        }
        assertTrue(runCatching { AgentIngestionConnection.validateHello(
            JSONObject("""{"v":3,"capabilities":["bounded.windows"]}""")) }.isFailure)
        // Capacity is strict: only an advertised integer grows the window,
        // clamped to Core's 4..64 range; anything else reads as legacy.
        for ((capability, segments, expected) in listOf(
            Triple(false, null, 4), Triple(false, "64", 4), Triple(true, null, 4), Triple(true, "64", 64),
            Triple(true, "16", 16), Triple(true, "4", 4), Triple(true, "1", 4), Triple(true, "0", 4), Triple(true, "-3", 4),
            Triple(true, "65", 64), Triple(true, "4096", 64), Triple(true, "9007199254740993", 64),
            Triple(true, "16.0", 4), Triple(true, "16.5", 4), Triple(true, "1e1", 4), Triple(true, "\"16\"", 4),
            Triple(true, "null", 4), Triple(true, "true", 4))) {
            val hello = JSONObject("""{"v":3,"capabilities":["bounded.windows","window.partitions"${
                if (capability) ",\"window.capacity.v1\"" else ""}]${segments?.let { ",\"maxWindowSegments\":$it" } ?: ""}}""")
            assertEquals("window capacity $capability/$segments", expected, AgentIngestionConnection.helloMaxWindowSegments(hello))
        }
        assertTrue(runCatching { AgentIngestionConnection.helloMaxWindowSegments(JSONObject(
            """{"v":2,"capabilities":["bounded.windows","window.partitions","window.capacity.v1"],"maxWindowSegments":64}""")) }.isFailure)
        val searchFrames = listOf(
            """{"kind":"page.begin","id":"search","thread":"thread","serviceEpoch":"epoch","sourceIdentity":"pi-chain:fixture","operation":"bootstrap"}""",
            """{"kind":"page.record","id":"search","thread":"thread","serviceEpoch":"epoch","recordID":"canonical-id","order":9007199254740993,"sourceOffset":100,"revision":1,"record":{"type":"message","role":"system","providerSystemMessage":true,"blocks":[{"type":"text","text":"A visible CAFÉ notice"}]}}""",
            """{"kind":"page.end","id":"search","thread":"thread","serviceEpoch":"epoch","records":1,"hasOlder":false,"liveCursor":"live","hasNewer":false,"sourceEnd":1000}"""
        ).map { value -> value.encodeToByteArray().let { java.nio.ByteBuffer.allocate(it.size + 4).putInt(it.size).put(it).array() } }
        val searchWire = searchFrames.fold(byteArrayOf()) { bytes, frame -> bytes + frame }
        val searchThread = JSONObject().put("hostID", UUID.randomUUID().toString()).put("providerID", JSONObject().put("rawValue", "pi"))
            .put("providerSessionID", "search-fixture")
        val searchMatches = SharedAgentPageSearch.matches(searchWire, "epoch", "thread", searchThread, "cafe")
        assertEquals("canonical-id", searchMatches.getJSONObject(0).getString("recordID"))
        assertEquals(0, SharedAgentPageSearch.matches(searchWire, "epoch", "thread", searchThread, "漢".repeat(200)).length())
        assertTrue(runCatching { SharedAgentPageSearch.matches(searchWire, "wrong-epoch", "thread", searchThread, "cafe") }.isFailure)
        AgentIngestionConnection.validateTransactionFrame(true, "inventory.thread", 501, 299_999, 1_048_575)
        AgentIngestionConnection.validateTransactionFrame(true, "inventory.end", 502, 300_000, 1_048_576)
        AgentIngestionConnection.validateTransactionFrame(false, "page.end", 102, 300_000, 1_048_576)
        for ((inventory, kind, frames, bytes, total) in listOf(
            FrameLimitCase(true, "inventory.thread", 502, 100, 100),
            FrameLimitCase(true, "inventory.end", 503, 100, 100),
            FrameLimitCase(false, "page.end", 103, 100, 100),
            FrameLimitCase(true, "inventory.end", 502, 300_001, 300_001),
            FrameLimitCase(true, "inventory.end", 502, 100, 1_048_577),
            FrameLimitCase(true, "page.record", 2, 100, 100),
            FrameLimitCase(false, "inventory.thread", 2, 100, 100),
            FrameLimitCase(true, "inventory.unknown", 2, 100, 100))) {
            assertTrue("transaction boundary must fail closed: $kind/$frames/$bytes/$total", runCatching {
                AgentIngestionConnection.validateTransactionFrame(inventory, kind, frames, bytes, total)
            }.isFailure)
        }
        val fixture = WindowFixture()
        try {
            compose.runOnUiThread { compose.activity.installFixture { TesseraTheme {
                AgentDetailPane(fixture.detail, "", {}, {}, {}, { _, _ -> }, {},
                    { fixture.request("before") }, {}, {}, {},
                    Modifier.fillMaxSize().safeDrawingPadding(),
                    loadingTranscript = fixture.loading,
                    onLoadNewer = { fixture.request("after") },
                    onReturnToLatest = { fixture.request("bootstrap") },
                    onViewportAnchor = fixture::anchor)
            } } }
            fixture.start()
            compose.waitUntil(15_000) { fixture.detail?.live?.isNotEmpty() == true }
            // A fresh emulator can deliver a configuration change after boot.
            // Explicit recreation proves content ownership, without a sleep or
            // disabling configuration changes to hide the observed race.
            compose.activityRule.scenario.recreate()
            compose.waitForIdle()
            val list = compose.onNodeWithTag("agent-transcript-list")
            list.assertExists()
            // Touch-driven demand, not direct model mutation: cross the old
            // 512-record ceiling and force the shared four-segment eviction.
            repeat(120) {
                if (fixture.oldest < 600) return@repeat
                list.performTouchInput { swipeDown(durationMillis = 120) }
                compose.waitForIdle()
            }
            compose.waitUntil(10_000) { fixture.oldest < 600 && !fixture.loading }
            assertTrue(fixture.maximumSegments <= 4)
            assertTrue(fixture.detail!!.live.size <= 500)
            assertFalse(fixture.detail!!.window!!.atLiveHead)
            capture("deep-history")

            // Freeze the viewport while a genuine shared-Core head transaction
            // advances. No UI copy/append can satisfy these assertions.
            val oldIDs = fixture.detail!!.live.map { it.recordID }
            val oldVersion = fixture.detail!!.window!!.version
            val viewport = list.fetchSemanticsNode().boundsInRoot
            val visible = compose.onAllNodesWithText("History record", substring = true).fetchSemanticsNodes()
                .first { it.boundsInRoot.top >= viewport.top && it.boundsInRoot.bottom <= viewport.bottom }
            val visibleText = visible.config[SemanticsProperties.Text].joinToString("\n") { it.text }
            val anchorY = visible.boundsInRoot.top
            fixture.request("head", advance = 3)
            compose.waitUntil(10_000) { (fixture.detail?.window?.version ?: 0) > oldVersion && !fixture.loading }
            assertEquals(oldIDs, fixture.detail!!.live.map { it.recordID })
            assertFalse(fixture.detail!!.window!!.atLiveHead)
            val anchor = compose.onNodeWithText(visibleText)
            anchor.assertIsDisplayed()
            assertEquals(anchorY, anchor.fetchSemanticsNode().boundsInRoot.top, 3f)
            capture("history-with-live-head")

            val splitVersion = fixture.detail!!.window!!.version
            fixture.reviseRetained()
            compose.waitUntil(10_000) { (fixture.detail?.window?.version ?: 0) > splitVersion && !fixture.loading }
            anchor.assertIsDisplayed()
            assertEquals(anchorY, anchor.fetchSemanticsNode().boundsInRoot.top, 3f)
            assertTrue(fixture.maximumSegments <= 4)
            capture("history-with-resegmentation")

            val beforeForward = fixture.newest
            repeat(100) {
                if (fixture.newest > beforeForward) return@repeat
                list.performTouchInput { swipeUp(durationMillis = 120) }
                compose.waitForIdle()
            }
            compose.waitUntil(10_000) { fixture.newest > beforeForward && !fixture.loading }
            capture("forward-history")
            // A long forward gesture can naturally reach the head. Detach again
            // before testing the explicit Return to latest control.
            repeat(30) {
                if (fixture.detail?.window?.atLiveHead == false) return@repeat
                list.performTouchInput { swipeDown(durationMillis = 120) }
                compose.waitForIdle()
            }
            compose.waitUntil(10_000) { fixture.detail?.window?.atLiveHead == false && !fixture.loading }
            compose.onNodeWithTag("agent-return-latest").performClick()
            compose.waitUntil(10_000) { fixture.detail?.window?.atLiveHead == true && !fixture.loading }
            assertEquals(1202, fixture.newest)
            compose.onNodeWithText("History record 1202", substring = true).assertIsDisplayed()
            assertTrue(fixture.detail!!.live.any { it.body.contains("Shortened preview") })
            capture("latest")
            android.util.Log.i("TesseraAgentWindow", "TESSERA_AGENT_WINDOW_OK oldest=${fixture.minimumVisited} maxSegments=${fixture.maximumSegments}")
            fixture.failure?.let { throw AssertionError("Native window fixture failed", it) }
        } finally { closeWithPane(fixture) }
    }

    /** A pane left composed can still be paging when its fixture closes:
     * the loading glyph then animates forever and the rule's teardown idle
     * sync never returns. Remove the pane and settle before closing. */
    private fun closeWithPane(fixture: WindowFixture) {
        compose.runOnUiThread { compose.activity.installFixture { } }
        compose.waitForIdle()
        fixture.close()
    }

    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        // Keep the immediate compositor sample to diagnose semantics/paint
        // disagreement, then capture after native draw work has settled.
        val immediate = instrumentation.uiAutomation.takeScreenshot()
        File(instrumentation.targetContext.filesDir, "agent-window-immediate-$name.png").outputStream().use {
            immediate.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        immediate.recycle()
        compose.waitForIdle()
        instrumentation.waitForIdleSync()
        android.os.SystemClock.sleep(250)
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        File(instrumentation.targetContext.filesDir, "agent-window-$name.png").outputStream().use {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        bitmap.recycle()
    }

    @OptIn(CoordinatorOnlyAgentRouteAuthority::class)
    private class WindowFixture(private val chatFollow: Boolean = false, private val provider: String = "claude",
                                private val hostWindowSegments: Int? = null, private val sparse: Int = 0) : AutoCloseable {
        var tailLines = 0
        /** Holds newer reads, to observe what shows while one is pending. */
        var afterDelayMillis = 0L
        private val runtime = SharedAgentRuntime.create()
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        private val mutex = Mutex()
        private val host = "A11CE000-0000-4000-8000-000000000001"
        private val thread = JSONObject().put("hostID", host).put("providerID", JSONObject().put("rawValue", provider))
            .put("providerSessionID", "bounded-window-fixture")
        private var token = ""
        private var count = 1200
        private var liveCursor: String? = null
        private val segments = mutableMapOf<String, Pair<JSONObject, JSONArray>>()
        private var viewportIDs = emptyList<String>()
        private var headID: String? = null
        var detail by mutableStateOf<AgentThreadDetail?>(null); private set
        var loading by mutableStateOf(false); private set
        @Volatile var failure: Throwable? = null; private set
        var maximumSegments = 0; private set
        var minimumVisited = 1200; private set
        val oldest get() = detail?.live?.mapNotNull { it.recordID?.substringAfterLast('-')?.toIntOrNull() }?.minOrNull() ?: 1200
        val newest get() = detail?.live?.mapNotNull { it.recordID?.substringAfterLast('-')?.toIntOrNull() }?.maxOrNull() ?: -1

        fun start() { scope.launch {
            try {
                val configured = runtime.snapshot.value?.runtimeGeneration ?: 0
                send("configure", JSONObject().put("metadata", JSONArray()))
                withTimeout(5000) { runtime.snapshot.first { it != null && it.runtimeGeneration > configured } }
                // Without this, Core sizes the window for a legacy host.
                hostWindowSegments?.let { send("hostCapacity", JSONObject().put("hostWindowSegments", JSONObject().put(host, it))) }
                if (provider == "pi") check(runtime.registerPlatformConformingProviders(setOf("pi")))
                val binding = JSONObject().put("liveSessionID", UUID.randomUUID().toString()).put("carrierGeneration", 1)
                    .put("incarnation", JSONObject().put("rawValue", "window-fixture")).put("transport", "ssh").put("capabilities", 1)
                fun registration() = JSONObject().put("threadID", thread).put("hostID", host).put("binding", binding)
                    .put("sourceIdentity", "window-fixture").put("validatedDirectories", JSONArray())
                val proof = checkNotNull(runtime.issuePlatformRouteProof(registration().put("processIDs", JSONArray())))
                token = checkNotNull(runtime.exchangePlatformRouteProof(registration().put("mode", "observeOnly").put("proofHandle", proof)))
                send("bind", JSONObject().put("threadID", thread).put("bindingToken", token))
                if (chatFollow) delay(1000)
                load("bootstrap", 0)
            } catch (error: Throwable) { failure = error; android.util.Log.e("TesseraAgentWindow", "Fixture startup failed", error) }
        } }

        fun request(lane: String, advance: Int = 0) {
            if (loading || token.isEmpty()) return
            scope.launch { try { load(lane, advance) } catch (error: Throwable) { failure = error; android.util.Log.e("TesseraAgentWindow", "Fixture page failed", error) } }
        }

        fun anchor(record: String?) {
            if (token.isNotEmpty()) send("viewportAnchor", JSONObject().put("threadID", thread).put("recordID", record))
        }

        fun reviseRetained() = split { viewportIDs.first() to it / 2 }

        /** A revision grows the head past the page limit: the host splits it
         * at [offset] and keeps only its last part as the head. */
        fun splitHead(offset: Int) = split { checkNotNull(headID) to offset }

        private fun split(part: (Int) -> Pair<String, Int>) {
            scope.launch { mutex.withLock {
                loading = true
                try {
                    val id = part(0).first
                    val (original, records) = checkNotNull(segments[id])
                    val middle = part(records.length()).second
                    check(middle > 0 && middle < records.length())
                    val boundary = "offset_${records.getJSONObject(middle).getLong("sequence")}"
                    val parts = JSONArray()
                        .put(JSONObject().put("original", id).put("id", UUID.randomUUID().toString()).put("offset", 0).put("count", middle)
                            .put("before", original.getString("before")).put("after", boundary)
                            .put("hasOlder", original.getBoolean("hasOlder")).put("hasNewer", true))
                        .put(JSONObject().put("original", id).put("id", UUID.randomUUID().toString()).put("offset", middle)
                            .put("count", records.length() - middle).put("before", boundary).put("after", original.getString("after"))
                            .put("hasOlder", true).put("hasNewer", original.getBoolean("hasNewer")))
                    val patch = JSONObject(records.getJSONObject(0).toString()).put("revision", 2)
                    val version = detail!!.window!!.version + 1
                    val window = JSONObject().put("lane", "revisions").put("version", version).put("partitions", parts)
                    val range = JSONObject().put("epoch", "fixture").put("requestID", UUID.randomUUID().toString())
                        .put("operation", "updates").put("window", window).put("liveCursor", liveCursor).put("sourceEnd", count)
                    val page = JSONObject().put("sourceIdentity", "fixture-source").put("from", liveCursor)
                        .put("records", JSONArray().put(patch)).put("hasMore", false).put("ingestion", range)
                    val generation = runtime.snapshot.value?.runtimeGeneration ?: 0
                    send("projection", JSONObject().put("threadID", thread).put("bindingToken", token).put("projection", page))
                    val snapshot = withTimeout(5000) { runtime.snapshot.first {
                        it != null && it.runtimeGeneration > generation && it.kind == SharedAgentSnapshotKind.Projection
                    } }!!
                    detail = checkNotNull(AgentPresentation.detail(snapshot))
                    check(detail!!.window!!.version == version)
                    android.util.Log.i("TesseraAgentWindow", "lane=revisions partitionCount=2")
                } catch (error: Throwable) { failure = error; android.util.Log.e("TesseraAgentWindow", "Fixture split failed", error) }
                finally { loading = false }
            } }
        }

        private suspend fun load(lane: String, advance: Int) = mutex.withLock {
            loading = true
            try {
                if (lane == "after" && afterDelayMillis > 0) delay(afterDelayMillis)
                count += advance
                val current = detail
                val before = current?.cursor?.removePrefix("offset_")?.toIntOrNull() ?: count
                val after = current?.window?.after?.removePrefix("offset_")?.toIntOrNull() ?: count
                val end = when (lane) { "before" -> before; "after" -> minOf(count, after + 100); else -> count }
                val start = if (lane == "after") after else maxOf(0, end - 100)
                if (start >= end) return@withLock
                val records = JSONArray()
                for (index in start until end) {
                    val tail = chatFollow && index == count - 1
                    // Whitespace-only prose projects to no message at all.
                    val hidden = sparse > 0 && index % sparse != 0
                    val tool = index % 8 >= 3 && !tail && sparse == 0
                    val block = JSONObject().put("type", if (tool) "tool_result" else "text")
                        .put(if (tool) "preview" else "text", if (tool) "Synthetic output $index\nA bounded tool result."
                            else if (hidden) " "
                            else if (tail) "Chat tail\n" + (if (tailLines > 0) (1..tailLines).joinToString("\n") { "Streaming line $it in the same record." } else "Initial reply.")
                            else "History record $index\nScroll older and newer while the live head advances independently.")
                    val blocks = JSONArray().put(block)
                    if (tail) blocks.put(JSONObject().put("type", "text").put("text", "End of latest reply."))
                    records.put(JSONObject().put("sequence", index).put("recordID", "fixture-record-$index")
                        .put("revision", if (chatFollow) (current?.window?.version ?: 0) + 1 else 1)
                        .put("record", JSONObject().put("type", "message").put("role", if (tool) "tool" else "assistant")
                            .put("truncated", index % 8 == 0).put("blocks", blocks)))
                }
                val history = lane == "before" || lane == "after"
                val version = if (lane == "bootstrap") 1 else (current?.window?.version ?: 0) + 1
                val window = JSONObject().put("lane", lane).put("version", version).put("segmentID", UUID.randomUUID().toString())
                    .put("before", "offset_$start").put("after", "offset_$end").put("hasOlder", start > 0).put("hasNewer", end < count)
                val range = JSONObject().put("epoch", "fixture").put("requestID", UUID.randomUUID().toString())
                    .put("operation", if (lane == "bootstrap") "bootstrap" else if (history) "history" else "updates").put("window", window)
                if (!history) range.put("liveCursor", "live_$count").put("sourceEnd", count)
                val page = JSONObject().put("sourceIdentity", "fixture-source").put("records", records).put("ingestion", range)
                    .put("hasMore", (history || lane == "bootstrap") && start > 0)
                if ((history || lane == "bootstrap") && start > 0) page.put("cursor", "offset_$start")
                when (lane) { "before" -> page.put("from", current?.cursor); "after" -> page.put("from", current?.window?.after)
                    "head" -> page.put("from", liveCursor) }
                val generation = runtime.snapshot.value?.runtimeGeneration ?: 0
                send("projection", JSONObject().put("threadID", thread).put("bindingToken", token).put("projection", page))
                val snapshot = withTimeout(5000) { runtime.snapshot.first {
                    it != null && it.runtimeGeneration > generation && it.kind == SharedAgentSnapshotKind.Projection
                } }!!
                val next = checkNotNull(AgentPresentation.detail(snapshot))
                check(next.window?.version == version) { "Native page rejected: ${snapshot.payload.fields["code"]}" }
                detail = next
                if (!history) liveCursor = "live_$count"
                val rawThread = snapshot.payload.fields["thread"] as SharedAgentValue.ObjectValue
                val rawWindow = rawThread.fields["ingestionWindow"] as SharedAgentValue.ObjectValue
                viewportIDs = (rawWindow.fields["viewportSegmentIDs"] as SharedAgentValue.ArrayValue).values.map {
                    (it as SharedAgentValue.StringValue).value
                }
                headID = (rawWindow.fields["headSegmentID"] as? SharedAgentValue.StringValue)?.value
                segments[window.getString("segmentID")] = window to records
                segments.keys.retainAll(viewportIDs + listOfNotNull(headID))
                val segmentCount = viewportIDs.size
                maximumSegments = maxOf(maximumSegments, segmentCount)
                minimumVisited = minOf(minimumVisited, oldest)
                android.util.Log.i("TesseraAgentWindow", "lane=$lane version=$version start=$start end=$end segments=$segmentCount")
            } finally { loading = false }
        }

        private fun send(kind: String, command: JSONObject = JSONObject()) {
            check(runtime.sendCanonical(command.put("v", 1).put("kind", kind).toString().encodeToByteArray()) == CoreCallResult.Accepted)
        }
        override fun close() { scope.cancel(); runtime.close() }
    }
}
