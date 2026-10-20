package com.bambouville.tessera.feature.agentcenter

import android.annotation.SuppressLint
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.core.bridge.SharedAgentMarkdown
import com.bambouville.tessera.core.bridge.SharedAgentReadStatus
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.design.TesseraTokens
import com.bambouville.tessera.markdown.TesseraMarkdownText
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

@RunWith(AndroidJUnit4::class)
class AgentCenterComposeTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()

    private fun setFixtureContent(content: @Composable () -> Unit) {
        compose.activityRule.scenario.onActivity { it.installFixture(content) }
    }

    @Test fun followingLatestNeverPinsAnOldViewportRecord() {
        var anchor: String? = "not-observed"
        val shown = detail("8", true).copy(live = historyBlocks(0 until 100), prompt = null, hasMore = false)
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {},
                Modifier.fillMaxSize().safeDrawingPadding(), onViewportAnchor = { anchor = it })
        } }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals("Following live must not retain an older visible record", null, anchor) }
        compose.onNodeWithTag("agent-transcript-list").performTouchInput { swipeDown(durationMillis = 600) }
        compose.waitUntil(5_000) { anchor != null }
        compose.onNodeWithTag("agent-return-latest").performClick()
        compose.waitUntil(5_000) { anchor == null }
    }

    @Test fun initialTranscriptLoadDoesNotClaimTheConversationIsUnavailable() {
        var loading by mutableStateOf(true)
        val shown = detail("8", true).copy(live = emptyList(), prompt = null, hasMore = false)
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {},
                Modifier.fillMaxSize().safeDrawingPadding(), loadingTranscript = loading)
        } }
        // Boot-time configuration changes must not erase the test surface.
        compose.activityRule.scenario.recreate()
        compose.activityRule.scenario.onActivity {
            assertEquals(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING,
                it.window.attributes.softInputMode and android.view.WindowManager.LayoutParams.SOFT_INPUT_MASK_ADJUST)
        }
        compose.onNodeWithText("loading conversation…").assertIsDisplayed()
        compose.onAllNodesWithText("live projection is unavailable").assertCountEquals(0)
        compose.runOnIdle { loading = false }
        compose.onNodeWithText("live projection is unavailable").assertIsDisplayed()
    }

    @Test fun readProgressAndFailureKeepContentAndExposeRetry() {
        fun status(state: String, recovery: String, code: String) = requireNotNull(SharedAgentReadStatus.decode(
            org.json.JSONObject().put("v", 1).put("state", state).put("domain", "source")
                .put("recovery", recovery).put("code", code)))
        var current by mutableStateOf<SharedAgentReadStatus?>(status("preparing", "continue", "readPending"))
        var shown by mutableStateOf(detail("8", true).copy(live = emptyList(), prompt = null, hasMore = false))
        var retried = 0
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {},
                Modifier.fillMaxSize().safeDrawingPadding(), readStatus = current,
                loadingTranscript = current?.isProgress == true, onReturnToLatest = { retried++ })
        } }
        fun transcriptTop() = compose.onNodeWithTag("agent-transcript-list").fetchSemanticsNode().boundsInRoot.top
        fun capture(name: String) {
            val instrumentation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation()
            compose.waitForIdle(); instrumentation.waitForIdleSync()
            val bitmap = instrumentation.uiAutomation.takeScreenshot()
            for (prefix in listOf("agent-window-", "agent-window-immediate-")) {
                java.io.File(instrumentation.targetContext.filesDir, "$prefix$name.png").outputStream().use {
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
            }
            bitmap.recycle()
        }
        compose.onNodeWithTag("agent-read-status").assertTextContains("Preparing conversation", substring = true)
        compose.onAllNodesWithText("live projection is unavailable").assertCountEquals(0)
        compose.onAllNodesWithText("Retry").assertCountEquals(0)
        capture("read-preparing")
        compose.runOnIdle {
            shown = shown.copy(live = historyBlocks(0 until 3))
            current = status("verifying", "continue", "readPending")
        }
        compose.onNodeWithTag("agent-transcript-list").assertIsDisplayed()
        // A working agent's refreshes pass through progress constantly; over
        // a transcript on screen its row pushed the conversation down and back.
        compose.onAllNodesWithTag("agent-read-status").assertCountEquals(0)
        val progressTop = transcriptTop()
        compose.runOnIdle { current = null }
        compose.waitForIdle()
        assertEquals(progressTop, transcriptTop(), 0.5f)
        compose.runOnIdle { current = status("verifying", "continue", "readPending") }
        compose.waitForIdle()
        assertEquals(progressTop, transcriptTop(), 0.5f)
        capture("read-verifying")
        compose.runOnIdle { current = status("failed", "manual", "sourceNotAuthorized") }
        compose.onNodeWithTag("agent-transcript-list").assertIsDisplayed()
        compose.onNodeWithTag("agent-read-retry").assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(1, retried) }
        compose.onAllNodesWithText("Live updates paused at the history memory limit.").assertCountEquals(0)
        capture("read-failed")
    }

    @Test fun historyPrependPreservesTheVisibleMessageOffset() {
        var shown by mutableStateOf(detail("8", true).copy(
            live = historyBlocks(60 until 90), prompt = null, cursor = "60", hasMore = true,
        ))
        var loading by mutableStateOf(false)
        var requests = 0
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {
                requests += 1
                loading = true
            }, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding(), loadingTranscript = loading)
        } }
        compose.waitForIdle()
        assertEquals("Opening a long transcript must start at its newest message", 0, requests)
        // Establish real reader intent before the exact test-only position.
        // A programmatic scrollToIndex is no longer mistaken for a user pan.
        compose.onNodeWithTag("agent-transcript-list").performTouchInput { swipeDown(durationMillis = 600) }
        compose.onNodeWithTag("agent-transcript-list").performScrollToIndex(0)
        compose.waitUntil(5_000) { requests == 1 }
        // The first item is guaranteed visible after scrollToIndex(0);
        // a sixth item need not fit at every viewport/font configuration.
        val anchor = compose.onNodeWithText("History message 60", substring = true)
        anchor.assertIsDisplayed()
        val before = anchor.fetchSemanticsNode().boundsInRoot.top
        captureTranscriptFixture("history-before")
        compose.runOnIdle {
            shown = shown.copy(live = historyBlocks(30 until 90), cursor = "30")
            loading = false
        }
        compose.waitForIdle()
        anchor.assertIsDisplayed()
        assertEquals(before, anchor.fetchSemanticsNode().boundsInRoot.top, 2f)
        captureTranscriptFixture("history-after")
        assertEquals("A prepend must move the prefetch edge away without another request", 1, requests)
        compose.onAllNodesWithText("load older").assertCountEquals(0)
    }

    @Test fun shortHistoryRetriesFailureAndStopsWhenExhausted() {
        var shown by mutableStateOf(detail("8", true).copy(
            live = historyBlocks(88 until 90), prompt = null, cursor = "88", hasMore = true,
        ))
        var loading by mutableStateOf(false)
        var requests = 0
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {
                requests += 1
                loading = true
            }, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding(), loadingTranscript = loading)
        } }
        compose.waitUntil(5_000) { requests == 1 }
        compose.runOnIdle { loading = false } // A transient failure keeps its cursor.
        compose.waitUntil(5_000) { requests == 2 }
        compose.runOnIdle {
            shown = shown.copy(hasMore = false, cursor = "0")
            loading = false
        }
        compose.waitForIdle()
        assertEquals(2, requests)
        captureTranscriptFixture("history-retried")
        compose.onAllNodesWithText("load older").assertCountEquals(0)
    }

    @Test fun metadataOnlyPagesContinueUntilVisibleMessagesArrive() {
        var shown by mutableStateOf(detail("8", true).copy(
            live = emptyList(), prompt = null, cursor = "metadata", hasMore = true,
        ))
        var requested = false
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {
                requested = true
                shown = shown.copy(live = historyBlocks(1..2), cursor = "0", hasMore = false)
            }, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding())
        } }
        compose.waitUntil(5_000) { requested }
        compose.onNodeWithText("History message 2", substring = true).assertIsDisplayed()
    }

    @Test fun emptyNativeWindowFillsHistoryAfterAnInterruptedInitialLoad() {
        var shown by mutableStateOf(detail("8", true).copy(
            live = emptyList(), prompt = null, cursor = "metadata", hasMore = true,
            window = AgentHistoryWindow(3, atLiveHead = true, hasNewer = false, after = null,
                transition = "before", olderPageFits = true),
        ))
        var requests = 0
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {},
                Modifier.fillMaxSize().safeDrawingPadding(), onFillHistory = {
                    requests++
                    shown = shown.copy(live = historyBlocks(1..2), cursor = "0", hasMore = false)
                })
        } }
        captureTranscriptFixture("empty-native-before-fill")
        compose.waitUntil(5_000) { requests == 1 }
        compose.onNodeWithText("History message 2", substring = true).assertIsDisplayed()
        captureTranscriptFixture("empty-native-filled")
    }

    @Test fun collapsedToolHeaderKeepsItsKeyWhenAnOlderRunMerges() {
        fun projected(first: Int): AgentThreadDetail {
            val tools = (first..60).map { AgentBlock("tool", "Read file $it", kind = "toolCall", recordID = "tool$it") }
            val ids = tools.map { "${it.recordID}#0" }
            return detail("8", true).copy(live = tools + historyBlocks(61 until 90), prompt = null,
                cursor = first.toString(), hasMore = true,
                toolRuns = listOf(AgentToolRunDescriptor(ids.first(), ids, "${tools.size} tool calls", null)))
        }
        var shown by mutableStateOf(projected(60))
        var loading by mutableStateOf(false)
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, { loading = true }, {}, {}, {},
                Modifier.fillMaxSize().safeDrawingPadding(), loadingTranscript = loading)
        } }
        compose.onNodeWithTag("agent-transcript-list").performTouchInput { swipeDown(durationMillis = 600) }
        compose.onNodeWithTag("agent-transcript-list").performScrollToIndex(0)
        compose.waitUntil(5_000) { loading }
        val header = compose.onNodeWithTag("agent-tool-run-tool60#0")
        header.assertIsDisplayed()
        val before = header.fetchSemanticsNode().boundsInRoot.top
        compose.runOnIdle { shown = projected(30) }
        compose.waitForIdle()
        header.assertIsDisplayed()
        assertEquals(before, header.fetchSemanticsNode().boundsInRoot.top, 2f)
    }

    @Test fun olderPagesCoalescingIntoTheTopRunKeepPagingWithoutLooping() {
        // Each older page is tool activity that Core merges into the top run:
        // the rows, the first visible item and its key do not change.
        fun projected(first: Int, version: Long): AgentThreadDetail {
            val tools = (first..60).map { AgentBlock("tool", "Read file $it", kind = "toolCall", recordID = "tool$it") }
            val ids = tools.map { "${it.recordID}#0" }
            return detail("8", true).copy(live = tools + historyBlocks(61 until 90), prompt = null,
                cursor = first.toString(), hasMore = first > 0,
                toolRuns = listOf(AgentToolRunDescriptor(ids.first(), ids, "${tools.size} tool calls", null)),
                window = AgentHistoryWindow(version, atLiveHead = true, hasNewer = false, after = null, transition = "before"))
        }
        var shown by mutableStateOf(projected(60, 1))
        var loading by mutableStateOf(false)
        val requested = mutableListOf<String>()
        val anchors = mutableListOf<String?>()
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {
                requested += shown.cursor.orEmpty()
                loading = true
            }, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding(), loadingTranscript = loading,
                onViewportAnchor = { anchors += it })
        } }
        compose.onNodeWithTag("agent-transcript-list").performTouchInput { swipeDown(durationMillis = 600) }
        compose.onNodeWithTag("agent-transcript-list").performScrollToIndex(0)
        compose.waitUntil(5_000) { requested.size == 1 }
        val header = compose.onNodeWithTag("agent-tool-run-tool60#0")
        header.assertIsDisplayed()
        val top = header.fetchSemanticsNode().boundsInRoot.top
        for ((index, first) in listOf(50, 40, 30).withIndex()) {
            compose.runOnIdle { shown = projected(first, index + 2L); loading = false }
            compose.waitUntil(5_000) { requested.size == index + 2 }
            header.assertIsDisplayed()
            assertEquals(top, header.fetchSemanticsNode().boundsInRoot.top, 2f)
        }
        compose.onNodeWithText("31 tool calls").assertIsDisplayed()
        // Automatic history demand stops after four pages per reader gesture,
        // even though nothing on screen moved.
        compose.runOnIdle { shown = projected(20, 5); loading = false }
        compose.waitForIdle()
        Thread.sleep(1_500)
        compose.waitForIdle()
        assertEquals(listOf("60", "50", "40", "30"), requested)
        // The reader asks again on the same unchanged row, and paging resumes.
        compose.onNodeWithTag("agent-transcript-list").performTouchInput { swipeDown(durationMillis = 600) }
        compose.waitUntil(5_000) { requested.size == 5 }
        assertEquals("20", requested.last())
        compose.runOnIdle { shown = projected(0, 6); loading = false }
        header.assertIsDisplayed()
        assertEquals(top, header.fetchSemanticsNode().boundsInRoot.top, 2f)
        // Exhausted history never asks again.
        compose.onNodeWithTag("agent-transcript-list").performTouchInput { swipeDown(durationMillis = 600) }
        compose.waitForIdle()
        Thread.sleep(1_500)
        compose.waitForIdle()
        assertEquals(5, requested.size)
        // The grown run still pins the record its row was first read at.
        compose.runOnIdle {
            org.junit.Assert.assertTrue("reading the top run must pin it: $anchors", "tool60" in anchors)
            val pinned = anchors.drop(anchors.indexOf("tool60"))
            assertEquals(setOf("tool60"), pinned.toSet())
        }
    }

    private fun historyBlocks(range: IntRange) = range.map {
        AgentBlock("assistant", "History message $it\nA stable reading position while earlier messages arrive.", recordID = "history$it")
    }

    @Test fun claudeInsertionUsesSharedVisiblePasteEventsWithoutDuplicatingText() {
        val text = "first\n\nsecond\n"
        val bytes = requireNotNull(com.bambouville.tessera.core.bridge.SharedAgentComposerEvidence.insertion("claude", text))
        val chunks = bytes.decodeToString().split("\u001b[200~").drop(1).map { it.removeSuffix("\u001b[201~") }
        assertEquals(text, chunks.joinToString(""))
        org.junit.Assert.assertTrue(chunks.all { it.count { char -> char == '\n' } <= 1 })
    }

    @Test fun projectorPermissionDiagnosticsCrossTheNativeBridgeWithoutPrivateFields() {
        val wire = """{"v":1,"kind":"error","error":"permissionDenied","diagnostics":{"provider":"codex","pathKind":"windowsDrive","reason":"ownerMismatch","stage":"sourcePolicy","ownerUID":"0","path":"private-path","text":"private-transcript"}}"""
        assertEquals(mapOf(
            "error" to "permissionDenied", "provider" to "codex", "pathKind" to "windowsDrive",
            "reason" to "ownerMismatch", "stage" to "sourcePolicy", "ownerUID" to "0",
        ), com.bambouville.tessera.core.bridge.SharedAgentIntegrationParsing.projectorDiagnostics(wire.encodeToByteArray()))
    }

    @Test fun sharedCoreTranscriptFixtureHasNoArtifactsOrDuplicateAnswer() {
        val file = java.io.File("/data/local/tmp/tessera-agent-transcript-fixture.json")
        org.junit.Assume.assumeTrue("runner must provide the Core-generated fixture", file.exists())
        val event = com.bambouville.tessera.core.bridge.SharedAgentEventDecoder.decode(file.readBytes())
            as com.bambouville.tessera.core.bridge.SharedAgentRuntimeEvent.Snapshot
        val shown = requireNotNull(AgentPresentation.detail(event.snapshot))
        assertEquals(1, shown.live.count { "one final answer" in it.body })
        org.junit.Assert.assertTrue(shown.live.none { "<oai-mem-citation>" in it.body })
        // Assistant prose shaped like an agent envelope stays prose; only a
        // structured provider record carries attribution (audit M4/M10).
        assertEquals("text", shown.live.single { "Message Type: FINAL_ANSWER" in it.body }.kind)
        val reviewer = shown.live.single { it.kind == "subagentGroup" }
        assertEquals("reviewer", reviewer.recordID)
        org.junit.Assert.assertFalse("Message Type:" in reviewer.body)
        assertEquals("3 tool calls", shown.toolRuns.single().summaryTitle)
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, Modifier.safeDrawingPadding())
        } }
        compose.onNodeWithTag("agent-transcript-list").performTouchInput { swipeDown(durationMillis = 600) }
        compose.onNodeWithText("3 tool calls").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("agent-tool-run-call-1#0").performClick()
        compose.onAllNodesWithText("TOOL CALL · EXEC").assertCountEquals(3)
        captureTranscriptFixture("expanded")
        compose.onNodeWithTag("agent-tool-run-call-1#0").performScrollTo().performClick()
        captureTranscriptFixture("collapsed")
        compose.onNodeWithTag("agent-block-expand-${reviewer.recordID}").performScrollTo().performClick()
        compose.onNodeWithText("Structured reviewer records keep their attribution after expansion.").performScrollTo().assertIsDisplayed()
        captureTranscriptFixture("reviewer")
    }

    private fun captureTranscriptFixture(name: String) {
        compose.waitForIdle()
        val shot = checkNotNull(androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
        java.io.FileOutputStream("/sdcard/Download/agent-transcript-$name.png").use {
            check(shot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
        }
        shot.recycle()
    }

    @Test fun toolRunStartsCollapsedAndKeepsExpansionWhenOlderToolsArrive() {
        val blocks = listOf(
            AgentBlock("Bash", "pwd", "toolCall", "call"),
            AgentBlock("result", "/repo", "toolResult", "result"),
        )
        val descriptor = AgentToolRunDescriptor("call#0", listOf("call#0", "result#0"), "1 tool call", "latest: Bash · pwd")
        var shown by mutableStateOf(detail(capabilities = "8", actions = true).copy(
            live = blocks, prompt = null, toolRuns = listOf(descriptor),
        ))
        setFixtureContent {
            TesseraTheme {
                AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, Modifier)
            }
        }
        compose.onNodeWithText("1 tool call").assertIsDisplayed()
        compose.onNodeWithText("latest: Bash · pwd").assertIsDisplayed()
        compose.onNodeWithText("TOOL CALL · BASH").assertDoesNotExist()
        compose.onNodeWithText("details").performClick()
        compose.onNodeWithText("TOOL CALL · BASH").assertExists()
        compose.runOnIdle {
            shown = shown.copy(
                live = listOf(AgentBlock("Read", "older", "toolCall", "older")) + blocks,
                toolRuns = listOf(descriptor.copy(key = "older#0", entryIDs = listOf("older#0") + descriptor.entryIDs, summaryTitle = "2 tool calls")),
            )
        }
        compose.onNodeWithText("TOOL CALL · BASH").assertExists()
        compose.onNodeWithText("TOOL CALL · READ").assertExists()
        compose.onNodeWithText("collapse").performScrollTo().performClick()
        compose.onNodeWithText("TOOL CALL · BASH").assertDoesNotExist()
    }

    @Test fun compactionSummaryStartsAsOneCollapsedRowAndExpandsAsMarkdown() {
        val summary = "_Shortened preview · some content is omitted_\n\n" +
            "This session is being continued from a previous conversation that ran out of context.\n\n" +
            "Summary:\n1. **Primary Request** and intent"
        setFixtureContent {
            TesseraTheme {
                AgentDetailPane(detail(capabilities = "8", actions = true).copy(prompt = null,
                    live = listOf(AgentBlock("context compacted", summary, "compactSummary", "compact"))),
                    "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, Modifier)
            }
        }
        compose.onNodeWithText("CONTEXT COMPACTED").assertIsDisplayed()
        compose.onNodeWithText("This session is being continued", substring = true).assertDoesNotExist()
        compose.onNodeWithText("Shortened preview", substring = true).assertDoesNotExist()
        compose.onNodeWithTag("agent-block-expand-compact").performClick()
        compose.onNodeWithText("This session is being continued", substring = true).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Primary Request", substring = true).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("**Primary Request**", substring = true).assertDoesNotExist()
        compose.onNodeWithText("collapse").performScrollTo().performClick()
        compose.onNodeWithText("This session is being continued", substring = true).assertDoesNotExist()
    }

    @Test fun outgoingBubbleStaysVisibleAcrossLongTranscriptReplacementAndReceipt() {
        fun records(version: Int) = (0..30).map { index ->
            AgentBlock("assistant", "Snapshot $version message $index\n" + "conversation text ".repeat(20), recordID = "$version-$index")
        }
        var shown by mutableStateOf(detail("8", true).copy(prompt = null, live = records(0)))
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, Modifier.safeDrawingPadding())
        } }
        compose.runOnIdle { shown = shown.copy(outgoingMessages = listOf(AgentOutgoingMessage("pending", "new message", "sending"))) }
        compose.onNodeWithTag("agent-outgoing-sending").assertIsDisplayed()
        repeat(3) { update ->
            compose.runOnIdle { shown = shown.copy(live = records(update + 1)) }
            compose.onNodeWithTag("agent-outgoing-sending").assertIsDisplayed()
        }
        compose.runOnIdle {
            shown = shown.copy(outgoingMessages = emptyList(), live = records(4) + AgentBlock("user", "new message", recordID = "receipt"))
        }
        compose.onNodeWithText("new message").assertIsDisplayed()
        compose.onNodeWithTag("agent-outgoing-sending").assertDoesNotExist()
    }

    /** Core keeps an observed send as advisory state; the transcript row is its only display. */
    @Test fun observedSendShowsOnlyAsItsTranscriptRow() {
        val live = listOf(AgentBlock("assistant", "ready", recordID = "reply"), AgentBlock("user", "sent once", recordID = "receipt"))
        setFixtureContent { TesseraTheme {
            AgentDetailPane(detail("8", true).copy(prompt = null, live = live,
                outgoingMessages = listOf(AgentOutgoingMessage("sent", "sent once", "observed"))),
                "", {}, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, Modifier.safeDrawingPadding())
        } }
        compose.onNodeWithText("sent once").assertIsDisplayed()
        compose.onAllNodesWithText("sent once").assertCountEquals(1)
        compose.onNodeWithTag("agent-outgoing-observed").assertDoesNotExist()
    }

    // The pane runs inside a subcomposition, as the screen hosts it.
    @SuppressLint("UnusedBoxWithConstraintsScope")
    @Test fun pendingScrollSurvivesSubcompositionAndMultilineResize() {
        var draft by mutableStateOf("")
        var shown by mutableStateOf(detail("8", true).copy(prompt = null, outgoingMessages = listOf(
            AgentOutgoingMessage("pending", "pending during layout", "sending"),
        )))
        setFixtureContent { TesseraTheme {
            androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
                AgentDetailPane(shown, draft, { draft = it }, {}, {}, { _, _ -> }, {}, {}, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding())
            }
        } }
        compose.onNodeWithTag("agent-outgoing-sending").assertIsDisplayed()
        repeat(4) { count ->
            compose.onNodeWithTag("agent-composer").performTextReplacement("line\n".repeat(count + 1))
            compose.runOnIdle { shown = shown.copy(outgoingMessages = listOf(AgentOutgoingMessage("pending-$count", "pending during layout", "sending"))) }
            captureTranscriptFixture("pending-layout-$count")
            compose.waitUntil(3_000) { runCatching { compose.onNodeWithTag("agent-outgoing-sending").assertIsDisplayed() }.isSuccess }
        }
    }

    // The pane runs inside a subcomposition, as the screen hosts it.
    @SuppressLint("UnusedBoxWithConstraintsScope")
    @Test fun liveSnapshotReplacementFollowsNewContentWhileAtTail() {
        fun records(version: Int) = (0..30).map { index ->
            AgentBlock("assistant", "Snapshot $version message $index\n" + "conversation text ".repeat(20), recordID = "$version-$index")
        }
        var shown by mutableStateOf(detail("8", true).copy(prompt = null, live = records(0)))
        var visibleTail: String? = null
        setFixtureContent { TesseraTheme {
            androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
                AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, { visibleTail = it }, {}, {}, {}, {}, Modifier.fillMaxSize().safeDrawingPadding())
            }
        } }
        compose.waitUntil(10_000) { visibleTail == "0-30" }
        repeat(4) { update ->
            compose.runOnIdle { shown = shown.copy(live = records(update + 1)) }
            compose.waitUntil(10_000) { visibleTail == "${update + 1}-30" }
        }
    }

    @Test fun visibleFinishIsReadWithNoRecordsOrWhenTheTailWasAlreadyShown() {
        val finished = detail("8", true).row.copy(status = "finished", attention = "unreadCompletion")
        // A finish whose thread has no transcript records at all.
        var shown by mutableStateOf(detail("8", true).copy(prompt = null, live = emptyList(), row = finished, attentionEpoch = 3))
        val completions = mutableListOf<Long>()
        val newestVisible = mutableListOf<String>()
        setFixtureContent { TesseraTheme {
            AgentDetailPane(shown, "", {}, {}, {}, { _, _ -> }, { newestVisible += it }, {}, {}, {}, {},
                Modifier.fillMaxSize().safeDrawingPadding(), onCompletionVisible = { completions += shown.attentionEpoch })
        } }
        compose.waitUntil(5_000) { completions == listOf(3L) }
        // The newest record is already on screen while the agent works...
        compose.runOnIdle {
            shown = shown.copy(row = finished.copy(status = "working", attention = "none"),
                live = listOf(AgentBlock("assistant", "Done", recordID = "r1")))
        }
        compose.waitUntil(5_000) { newestVisible.lastOrNull() == "r1" }
        val tailReports = newestVisible.size
        // ...and its Stop lands without a new record: only the completion hook sees it.
        compose.runOnIdle { shown = shown.copy(row = finished, attentionEpoch = 4, deliveryGeneration = 9) }
        compose.waitUntil(5_000) { completions == listOf(3L, 4L) }
        compose.runOnIdle { assertEquals("the tail path cannot read a finish that adds no record", tailReports, newestVisible.size) }
        // A later frame of the same finish is not a second read.
        compose.runOnIdle { shown = shown.copy(deliveryGeneration = 10) }
        compose.waitForIdle()
        compose.runOnIdle { assertEquals(listOf(3L, 4L), completions) }
    }

    @Test fun promptDetailShowsLiveConversationAndImeComposerOnPhone() {
        var sent = 0
        setFixtureContent {
            var draft by remember { mutableStateOf("") }
            TesseraTheme {
                AgentDetailPane(
                    detail = detail(capabilities = "8", actions = true), draft = draft, onDraftChange = { draft = it },
                    onSend = { sent++ }, onInterrupt = {}, onPromptAnswer = { _, _ -> }, onNewestVisible = {}, onLoadMore = {},
                    onOpenTerminal = {}, onFork = {}, onStartSpeech = {},
                    modifier = Modifier.fillMaxSize().safeDrawingPadding(),
                )
            }
        }

        compose.onNodeWithText("Safe").assertIsDisplayed()
        compose.onNodeWithText("Fast").assertIsDisplayed()
        compose.onNodeWithText("Ready").assertIsDisplayed()
        compose.onNodeWithTag("agent-dictation").assertIsDisplayed()
        compose.onNodeWithTag("agent-send").assertDoesNotExist()
        compose.onNodeWithTag("agent-composer").performTextReplacement("ship it")
        compose.onNodeWithTag("agent-send").assertIsDisplayed()
        compose.onNodeWithTag("agent-dictation").assertDoesNotExist()
        compose.onNodeWithTag("agent-composer").performClick().performKeyInput { pressKey(Key.Enter) }
        compose.onNodeWithTag("agent-composer").assertTextContains("ship it\n")
        captureTranscriptFixture("prompt-ime-newline")
        compose.runOnIdle { assertEquals(0, sent) }
        compose.onNodeWithTag("agent-send").performClick()
        compose.runOnIdle { assertEquals(1, sent) }
    }

    @Test fun markdownRendererUsesTheSharedAstRatherThanLiteralFallback() {
        val source = "# Deployment summary\n\nThe **migration** completed with `0` failures.\n\n- [x] Back up state\n- [ ] Verify the remote host\n\n| Check | Result |\n| :--- | ---: |\n| Tests | passing |\n\n```sh\ntessera status\n```"
        assertNotNull(SharedAgentMarkdown.parse(source))

        setFixtureContent {
            TesseraTheme {
                androidx.compose.foundation.layout.Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
                ) { TesseraMarkdownText(source) }
            }
        }

        compose.onNodeWithText("Deployment summary").assertIsDisplayed()
        compose.onNodeWithText("The migration completed with 0 failures.").assertIsDisplayed()
        compose.onNodeWithText("Back up state").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Verify the remote host").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Check").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Result").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Tests").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("passing").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("tessera status").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("**migration**", substring = true).assertDoesNotExist()
        compose.onNodeWithText("# Deployment summary", substring = true).assertDoesNotExist()
    }

    @Test fun listSelectsTheSnapshotThreadWithoutCreatingAnEndpoint() {
        var selected: String? = null
        val detail = detail(capabilities = "8", actions = true)
        setFixtureContent {
            TesseraTheme {
                AgentListPane(
                    state = AgentCenterUiState(loading = false, threads = listOf(detail.row), selectedThreadKey = null),
                    onSearch = {}, onSelect = { selected = it }, onGroupingChange = {}, onSpawn = {}, modifier = Modifier,
                )
            }
        }

        compose.onNodeWithText("Fixture").performClick()
        compose.onNodeWithText(agentRelativeTime(detail.row.lastActivityMillis!!)).assertIsDisplayed()
        compose.runOnIdle { assertEquals(detail.row.key, selected) }
    }

    @Test fun listExposesSharedGroupingAndAuthoritativeSummaryMetadata() {
        var grouping: String? = null
        val detail = detail(capabilities = "8", actions = true)
        setFixtureContent {
            TesseraTheme {
                AgentListPane(
                    state = AgentCenterUiState(loading = false, grouping = "host", threads = listOf(detail.row)),
                    onSearch = {}, onSelect = {}, onGroupingChange = { grouping = it }, onSpawn = {}, modifier = Modifier,
                )
            }
        }

        compose.onNodeWithTag("agent-grouping").assertIsDisplayed()
        compose.onNodeWithText("fixture-host").assertIsDisplayed()
        // Context takes the place of line changes; cost stays supplementary.
        compose.onNodeWithText("62% context · $1.20").assertIsDisplayed()
        compose.onNodeWithText("changes", substring = true).assertDoesNotExist()
        compose.onNodeWithText("project").assertDoesNotExist()
        compose.onNodeWithText("attention").performClick()
        compose.runOnIdle { assertEquals("attention", grouping) }
    }

    @Test fun statusDotsUseIOSTonesAndOnlyWorkingGlows() {
        val row = detail(capabilities = "8", actions = true).row
        val rows = listOf(
            row.copy(key = "needs", title = "Needs you row", status = "idle", attention = "needsYou"),
            row.copy(key = "working", title = "Working row", status = "working", attention = "none"),
            row.copy(key = "finished", title = "Finished row", status = "finished", attention = "unreadCompletion"),
            row.copy(key = "idle", title = "Idle row", status = "idle", attention = "none"),
        )
        lateinit var tokens: TesseraTokens
        setFixtureContent { TesseraTheme {
            tokens = LocalTesseraTokens.current
            AgentListPane(AgentCenterUiState(loading = false, grouping = "attention", threads = rows), {}, {}, {}, {}, Modifier.safeDrawingPadding())
        } }
        compose.onNodeWithText("Idle row").performScrollTo().assertIsDisplayed()
        val pixels = compose.onRoot().captureToImage().toPixelMap()
        fun dot(key: String) = compose.onNodeWithTag("agent-status-dot-$key", useUnmergedTree = true).fetchSemanticsNode().boundsInRoot
        fun near(actual: Color, expected: Color) = abs(actual.red - expected.red) < 0.03f &&
            abs(actual.green - expected.green) < 0.03f && abs(actual.blue - expected.blue) < 0.03f
        for ((key, expected) in mapOf(
            "needs" to tokens.amber,
            "working" to tokens.green,
            "finished" to tokens.green,
            "idle" to tokens.fgFaint.compositeOver(tokens.bg),
        )) {
            val centre = dot(key).center
            val actual = pixels[centre.x.toInt(), centre.y.toInt()]
            assertTrue("$key dot is $actual, expected $expected", near(actual, expected))
        }
        // The halo reaches past the dot's own bounds; a quiet dot leaves the row background there.
        val outside = with(compose.density) { 2.dp.toPx() }
        val working = dot("working")
        val idle = dot("idle")
        assertFalse("working dot has no halo", near(pixels[(working.left - outside).toInt(), working.center.y.toInt()], tokens.bg))
        assertTrue("idle dot glows", near(pixels[(idle.left - outside).toInt(), idle.center.y.toInt()], tokens.bg))
        captureTranscriptFixture("list-status-dots")
    }

    @Test fun hostGroupingUsesSavedHostNamesAndDoesNotInventTags() {
        val row = detail(capabilities = "8", actions = true).row
        val rows = listOf(
            row.copy(key = "mac-1", title = "Mac conversation", host = "mac"),
            row.copy(key = "windows-1", title = "Windows first", host = "windows"),
            row.copy(key = "windows-2", title = "Windows second", host = "windows"),
        )
        setFixtureContent { TesseraTheme {
            AgentListPane(AgentCenterUiState(loading = false, grouping = "host", threads = rows), {}, {}, {}, {}, Modifier.safeDrawingPadding())
        } }
        compose.onNodeWithText("mac").assertIsDisplayed()
        compose.onNodeWithText("windows").performScrollTo().assertIsDisplayed()
        compose.onAllNodesWithText("windows", substring = false).assertCountEquals(1)
        compose.onNodeWithText("Windows second").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("unlabeled host").assertDoesNotExist()
    }

    @Test fun compactListKeepsUrgentAnswersAtZeroDepthWithTerminalFallback() {
        val detail = detail(capabilities = "1", actions = false)
        setFixtureContent {
            TesseraTheme {
                AgentListPane(
                    // No selected detail: this is a projection arriving while
                    // the phone remains on its list route.
                    state = AgentCenterUiState(loading = false, threads = listOf(detail.row), projectedDetails = mapOf(detail.row.key to detail)),
                    onSearch = {}, onSelect = {}, onGroupingChange = {}, onSpawn = {}, modifier = Modifier,
                )
            }
        }

        compose.onNodeWithText("Open terminal to answer").assertIsDisplayed()
        compose.onNodeWithText("open terminal").assertIsDisplayed()
    }

    @Test fun candidateKeepsItsLiveTailAndOnlyOpensTheExistingTerminal() {
        var opened: AgentTerminalCandidate? = null
        val candidate = AgentTerminalCandidate(
            key = "host:claude:pane", hostID = "fixture-host", providerID = "claude", provider = "Claude",
            title = "unproven terminal", host = "fixture-host", status = "waitingForInput", location = "main · pane %2",
            liveTail = "approval requested", binding = null,
        )
        setFixtureContent {
            TesseraTheme {
                AgentListPane(
                    state = AgentCenterUiState(loading = false, candidates = listOf(candidate)),
                    onSearch = {}, onSelect = {}, onGroupingChange = {}, onSpawn = {},
                    onOpenCandidateTerminal = { opened = it }, modifier = Modifier,
                )
            }
        }

        compose.onNodeWithText("Transcript identity unavailable; review in terminal.").assertIsDisplayed()
        compose.onNodeWithText("approval requested").assertIsDisplayed()
        compose.onNodeWithText("open terminal").performClick()
        compose.runOnIdle { assertEquals(candidate.key, opened?.key) }
    }

    @Test fun actionCapableCandidateRendersOnlyItsBoundedPromptOptions() {
        val candidate = AgentTerminalCandidate(
            key = "host:claude:pane", hostID = "fixture-host", providerID = "claude", provider = "Claude",
            title = "unproven terminal", host = "fixture-host", status = "waitingForInput", location = "main · pane %2",
            liveTail = "", binding = SharedAgentValue.ObjectValue(mapOf(
                "agentPID" to SharedAgentValue.NumberValue("42"),
                "capabilities" to SharedAgentValue.NumberValue("8"),
            )),
            prompt = AgentPrompt("Approve deployment", null, "candidate-token", listOf(AgentPromptOption("approve", "Approve", true))),
        )
        var answered = false
        setFixtureContent {
            TesseraTheme {
                AgentListPane(
                    state = AgentCenterUiState(loading = false, candidates = listOf(candidate)),
                    onSearch = {}, onSelect = {}, onGroupingChange = {}, onSpawn = {},
                    onCandidatePromptAnswer = { _, _, _ -> answered = true }, modifier = Modifier,
                )
            }
        }

        compose.onNodeWithText("Approve deployment").assertIsDisplayed()
        compose.onNodeWithText("Approve").performClick()
        compose.runOnIdle { assertEquals(true, answered) }
    }

    @Test fun degradedDetailShowsTerminalFallbackAndDoesNotEnableComposer() {
        setFixtureContent {
            TesseraTheme {
                AgentDetailPane(
                    detail = detail(capabilities = "1", actions = false), draft = "", onDraftChange = {}, onSend = {},
                    onInterrupt = {}, onPromptAnswer = { _, _ -> }, onNewestVisible = {}, onLoadMore = {}, onOpenTerminal = {},
                    onFork = {}, onStartSpeech = {}, modifier = Modifier,
                )
            }
        }

        compose.onNodeWithText("Open terminal to answer").assertIsDisplayed()
        compose.onNodeWithTag("agent-composer").assertIsNotEnabled()
    }

    @Test fun spawnSheetRendersAllLaunchFieldsButIsDisabledWithoutExecutor() {
        setFixtureContent {
            TesseraTheme {
                AgentSpawnSheet(AgentLaunchKind.Spawn, onDismiss = {}, selected = detail("8", true), onLaunchRequested = null)
            }
        }

        compose.onNodeWithTag("agent-launch-task").assertIsDisplayed()
        compose.onNodeWithTag("agent-launch-name").assertIsDisplayed()
        compose.onNodeWithTag("agent-launch-directory").assertIsDisplayed()
        compose.onNodeWithTag("agent-launch-directory-choice").assertIsDisplayed()
        compose.onNodeWithText("spawn").assertIsNotEnabled()
    }

    @Test fun spawnSheetOnlyAcceptsAJustProvenDirectory() {
        setFixtureContent {
            TesseraTheme {
                AgentSpawnSheet(AgentLaunchKind.Spawn, onDismiss = {}, selected = detail("8", true), onLaunchRequested = {})
            }
        }

        compose.onNodeWithTag("agent-launch-task").performTextReplacement("Review the fixture")
        compose.onNodeWithTag("agent-launch-directory").performTextReplacement("/not-proven")
        compose.onNodeWithText("spawn").assertIsNotEnabled()
        compose.onNodeWithTag("agent-launch-directory-choice").performClick()
        compose.onNodeWithText("spawn").assertIsEnabled()
    }

    @Test fun compactSpawnSheetUsesExplicitCancelAndCanLaunchAnyRouteCapableProvider() {
        var dismissed = false
        var request: AgentLaunchRequest? = null
        setFixtureContent {
            TesseraTheme {
                AgentSpawnSheet(
                    AgentLaunchKind.Spawn,
                    onDismiss = { dismissed = true },
                    selected = detail("8", true),
                    onLaunchRequested = { request = it },
                )
            }
        }

        compose.onNodeWithTag("agent-launch-task").performTextReplacement("Review the fixture")
        // The selected transcript is Claude, but launch is a property of its
        // live route, so Codex remains a deliberate spawn target.
        compose.onNodeWithText("Codex").performClick()
        compose.onNodeWithText("spawn").performClick()
        compose.runOnIdle {
            assertEquals("codex", request?.providerID)
            assertEquals(true, dismissed)
        }
    }

    @Test fun compactSpawnSheetHasAnExplicitCancelRoute() {
        var dismissed = false
        setFixtureContent {
            TesseraTheme {
                AgentSpawnSheet(AgentLaunchKind.Spawn, onDismiss = { dismissed = true }, selected = detail("8", true), onLaunchRequested = {})
            }
        }

        compose.onNodeWithText("cancel").performClick()
        compose.runOnIdle { assertEquals(true, dismissed) }
    }

    @Test fun detailRendersBoundedSharedMetadata() {
        setFixtureContent {
            TesseraTheme {
                AgentDetailPane(
                    detail = detail(capabilities = "8", actions = true), draft = "", onDraftChange = {}, onSend = {},
                    onInterrupt = {}, onPromptAnswer = { _, _ -> }, onNewestVisible = {}, onLoadMore = {}, onOpenTerminal = {},
                    onFork = {}, onStartSpeech = {}, modifier = Modifier,
                )
            }
        }

        compose.onNodeWithText("host fixture-host · sshTmux · session main · window @1 · pane %2").assertIsDisplayed()
        compose.onNodeWithText("mode plan · 62% context · $1.20").assertIsDisplayed()
    }

    @Test fun forkSheetDefaultsToTheSameExactTargetFields() {
        setFixtureContent {
            TesseraTheme {
                AgentSpawnSheet(AgentLaunchKind.Fork, onDismiss = {}, selected = detail("8", true), onLaunchRequested = null)
            }
        }

        compose.onNodeWithText("fork agent").assertIsDisplayed()
        compose.onNodeWithText("Window @1 · pane %2").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("fork").assertIsNotEnabled()
    }

    private fun detail(capabilities: String, actions: Boolean): AgentThreadDetail {
        val row = AgentThreadRow(
            key = "host:claude:thread", title = "Fixture", provider = "Claude", model = null, preview = null,
            status = "waitingForInput", attention = "needsYou", location = "fixture", queuedCount = null,
            isFork = false, actionAvailable = actions, spawnAvailable = true, forkAvailable = true,
            hostID = "fixture-host", providerID = "claude", providerSessionID = "fixture-thread",
            host = "fixture-host", permissionMode = "plan", contextPercent = "62.0", totalCost = "1.20",
            linesAdded = "14", linesRemoved = "3",
            lastActivityMillis = 1_704_067_200_000L,
        )
        return AgentThreadDetail(
            row = row,
            live = listOf(AgentBlock("assistant", "Ready", recordID = "1")),
            activity = listOf(
                AgentBlock("tool", "Checked", recordID = "2", displayTimeMillis = 1_704_112_040_000L),
                AgentBlock("system", "Background synchronization", kind = "system", recordID = "system-1"),
            ),
            changes = listOf(AgentBlock("modified", "file", recordID = "3")),
            binding = SharedAgentValue.ObjectValue(mapOf(
                "liveSessionID" to SharedAgentValue.StringValue("fixture-live"),
                "carrierGeneration" to SharedAgentValue.NumberValue("1"),
                "transport" to SharedAgentValue.StringValue("sshTmux"),
                "tmuxSession" to SharedAgentValue.StringValue("main"),
                "windowID" to SharedAgentValue.StringValue("@1"),
                "paneID" to SharedAgentValue.StringValue("%2"),
                "capabilities" to SharedAgentValue.NumberValue(capabilities),
            )),
            hasMore = false,
            prompt = AgentPrompt("Choose deployment", null, livePromptActionToken("fresh-fixture-signature"), listOf(
                AgentPromptOption("safe", "Safe", true), AgentPromptOption("fast", "Fast", false),
            ), fresh = AgentFreshPrompt(
                signature = "fresh-fixture-signature",
                options = listOf(
                    AgentFreshPromptOption("safe", "Safe", "1", true),
                    AgentFreshPromptOption("fast", "Fast", "2", false),
                ),
            )),
            provenDirectories = listOf("/fixture"),
        )
    }
}
