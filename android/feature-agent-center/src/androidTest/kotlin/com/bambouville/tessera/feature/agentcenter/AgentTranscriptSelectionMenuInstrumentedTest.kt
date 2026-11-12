package com.bambouville.tessera.feature.agentcenter

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.ClipboardManager
import android.content.Context
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performMouseInput
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.rightClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.design.ArtifactOpener
import com.bambouville.tessera.design.LocalArtifactOpener
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The transcript's long-press toolbar and right-click menu, on a real
 * floating ActionMode and a real Compose dropdown. Nothing here connects:
 * the session is a flag and both item routes are recorded.
 */
@RunWith(AndroidJUnit4::class)
class AgentTranscriptSelectionMenuInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()

    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val automation by lazy {
        instrumentation.uiAutomation.also { automation ->
            automation.serviceInfo = automation.serviceInfo.apply {
                flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
        }
    }
    private val opened = mutableListOf<ArtifactOpenRequest>()
    private val routed = mutableListOf<Pair<AgentSelectionPathAction, String>>()
    private val misses = mutableListOf<String>()
    private var draft by mutableStateOf("")

    /**
     * The clipboard as the test found it. Writing a sentinel would raise the
     * system's clipboard overlay over the transcript, so the check is that
     * our items leave whatever is there untouched (Copy would replace it).
     * Read once the fixture has focus: a background read always sees nothing.
     */
    private var clipboardBefore: String? = null

    private fun clipboard() = instrumentation.targetContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    private fun clipboardText(): String? {
        var text: String? = null
        instrumentation.runOnMainSync { text = clipboard().primaryClip?.getItemAt(0)?.text?.toString() }
        return text
    }

    private fun install(sessionConnected: Boolean) {
        val shown = detail()
        val actions = AgentTranscriptSelectionActions(
            isSessionConnected = { sessionConnected },
            onPathAction = { _, action, selection -> routed += action to selection },
            onMiss = { misses += it },
            onSessionUnavailable = { misses += "unavailable" },
        )
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme {
                    CompositionLocalProvider(LocalArtifactOpener provides ArtifactOpener { opened += it }) {
                        AgentDetailPane(shown, draft, { draft = it }, {}, {}, { _, _ -> }, {}, {}, {}, {}, {},
                            Modifier.fillMaxSize().safeDrawingPadding(), selectionActions = actions)
                    }
                }
            }
        }
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(PATH_TEXT).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
        compose.waitUntil(10_000) { compose.runOnUiThread { compose.activity.hasWindowFocus() } }
        clipboardBefore = clipboardText()
    }

    // --- Floating toolbar (a platform ActionMode window, read through accessibility) ---

    private fun windowNodes(): List<AccessibilityNodeInfo> {
        val windows = automation.windows
        check(windows.isNotEmpty()) { "UiAutomation reported no windows; the interactive-windows flag was not applied" }
        val nodes = mutableListOf<AccessibilityNodeInfo>()
        fun walk(node: AccessibilityNodeInfo?) {
            node ?: return
            nodes += node
            for (index in 0 until node.childCount) walk(node.getChild(index))
        }
        windows.forEach { walk(it.root) }
        return nodes
    }

    private fun toolbarNode(label: String): AccessibilityNodeInfo? =
        windowNodes().firstOrNull { it.text?.toString() == label || it.contentDescription?.toString() == label }

    private fun visibleLabels(): Set<String> =
        windowNodes().mapNotNull { it.text?.toString() }.filter { it in MENU_LABELS }.toSet()

    /**
     * The toolbar's labels once Copy shows, which means the toolbar is up. A
     * phone-width toolbar moves what does not fit behind its overflow button,
     * so the overflow's items count too; the toolbar is left on its main row.
     */
    private fun awaitToolbar(): Set<String> {
        compose.waitUntil(10_000) { toolbarNode("Copy") != null }
        // One more beat so a toolbar rebuilt by onPrepareActionMode has settled.
        compose.waitForIdle(); instrumentation.waitForIdleSync()
        val labels = visibleLabels()
        if (toolbarNode(OVERFLOW) == null) return labels
        press(OVERFLOW)
        compose.waitUntil(5_000) { toolbarNode(OVERFLOW_BACK) != null }
        val overflowed = visibleLabels()
        press(OVERFLOW_BACK)
        compose.waitUntil(5_000) { toolbarNode("Copy") != null }
        return labels + overflowed
    }

    private fun clickToolbar(label: String) {
        if (toolbarNode(label) == null && toolbarNode(OVERFLOW) != null) {
            press(OVERFLOW)
            compose.waitUntil(5_000) { toolbarNode(label) != null }
        }
        press(label)
    }

    private fun press(label: String) {
        val node = checkNotNull(toolbarNode(label)) { "no toolbar item $label" }
        val target = generateSequence(node) { it.parent }.firstOrNull { it.isClickable } ?: node
        assertTrue("toolbar item $label did not accept a click", target.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        compose.waitForIdle(); instrumentation.waitForIdleSync()
    }

    private fun longPress(text: String) {
        compose.onNodeWithText(text).performTouchInput { longClick(Offset(18f, height / 2f)) }
    }

    private fun screenshot(name: String) {
        compose.waitForIdle(); instrumentation.waitForIdleSync()
        val shot = checkNotNull(automation.takeScreenshot())
        java.io.File(instrumentation.targetContext.filesDir, "agent-selection-$name.png").outputStream().use {
            check(shot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
        }
        shot.recycle()
    }

    @Test fun longPressOnAPathAddsBothItemsAfterCopyAndRoutesTheSelectionNotTheClipboard() {
        install(sessionConnected = true)
        longPress(PATH_TEXT)
        val labels = awaitToolbar()
        screenshot("toolbar-path-connected")
        assertTrue("Copy must stay: $labels", "Copy" in labels)
        assertTrue("Open in Artifacts missing: $labels", OPEN in labels)
        assertTrue("Reveal in Files missing: $labels", REVEAL in labels)
        clickToolbar(REVEAL)
        compose.waitUntil(5_000) { routed.isNotEmpty() }
        assertEquals(listOf(AgentSelectionPathAction.RevealInFiles to PATH_TEXT), routed)
        assertEquals("our items must not touch the clipboard", clipboardBefore, clipboardText())
        compose.waitUntil(5_000) { toolbarNode(REVEAL) == null }
    }

    @Test fun aDisconnectedSessionKeepsOpenAndHidesReveal() {
        install(sessionConnected = false)
        longPress(PATH_TEXT)
        val labels = awaitToolbar()
        screenshot("toolbar-path-disconnected")
        assertTrue(OPEN in labels)
        assertFalse(REVEAL in labels)
        clickToolbar(OPEN)
        // README.md is relative: with no connected session nothing anchors it.
        compose.waitUntil(5_000) { misses.isNotEmpty() }
        assertEquals(listOf("Can't resolve README.md — no terminal directory is available for a relative path."), misses)
        assertTrue(opened.isEmpty())
        assertTrue(routed.isEmpty())
    }

    @Test fun selectAllOnALoopbackLinkOffersOnlyOpenAndOpensAPageTab() {
        install(sessionConnected = true)
        longPress(LINK_TEXT)
        // Smart selection may already grow the word to the whole link.
        if ("Select all" in awaitToolbar()) clickToolbar("Select all")
        val labels = awaitToolbar()
        screenshot("toolbar-link")
        assertTrue("Open in Artifacts missing: $labels", OPEN in labels)
        assertFalse("a link is never revealed: $labels", REVEAL in labels)
        clickToolbar(OPEN)
        compose.waitUntil(5_000) { opened.isNotEmpty() }
        assertEquals(listOf<ArtifactOpenRequest>(ArtifactOpenRequest.Page(
            "fixture-host", "http", 5173, "/app", ArtifactOpenOrigin.TerminalLink, "fixture-live",
        )), opened)
        assertEquals(clipboardBefore, clipboardText())
    }

    @Test fun proseAndTheComposerKeepTheirPlainMenus() {
        install(sessionConnected = true)
        longPress(PROSE_TEXT)
        var labels = awaitToolbar()
        screenshot("toolbar-prose")
        assertFalse("prose offers nothing: $labels", OPEN in labels || REVEAL in labels)
        clickToolbar("Select all")
        compose.waitForIdle()
        labels = awaitToolbar()
        assertFalse("selected prose offers nothing: $labels", OPEN in labels || REVEAL in labels)

        compose.onNodeWithTag("agent-composer").performClick()
        compose.onNodeWithTag("agent-composer").performTextInput("README.md")
        compose.onNodeWithTag("agent-composer").performTouchInput { longClick(Offset(24f, height / 2f)) }
        compose.waitUntil(10_000) { toolbarNode("Copy") != null || toolbarNode("Cut") != null || toolbarNode("Paste") != null }
        compose.waitForIdle(); instrumentation.waitForIdleSync()
        labels = windowNodes().mapNotNull { it.text?.toString() }.filter { it in MENU_LABELS }.toSet()
        screenshot("toolbar-composer")
        assertFalse("the composer's own menu never gains transcript items: $labels", OPEN in labels || REVEAL in labels)
    }

    @OptIn(ExperimentalTestApi::class)
    @Test fun rightClickOnASelectedPathShowsTheDropdownWithBothItems() {
        install(sessionConnected = true)
        compose.onNodeWithText(PATH_TEXT).performMouseInput {
            doubleClick(Offset(18f, height / 2f))
        }
        compose.waitForIdle()
        compose.onNodeWithText(PATH_TEXT).performMouseInput { rightClick(Offset(18f, height / 2f)) }
        compose.waitUntil(10_000) {
            compose.onAllNodesWithText(REVEAL).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
        }
        compose.onAllNodesWithText("Copy").fetchSemanticsNodes().let { assertTrue("Copy must stay in the dropdown", it.isNotEmpty()) }
        compose.onAllNodesWithText(OPEN).fetchSemanticsNodes().let { assertEquals(1, it.size) }
        screenshot("dropdown-path")
        compose.onNodeWithText(OPEN).performClick()
        compose.waitUntil(5_000) { routed.isNotEmpty() }
        assertEquals(listOf(AgentSelectionPathAction.OpenInArtifacts to PATH_TEXT), routed)
        assertEquals(clipboardBefore, clipboardText())
    }

    private fun detail(): AgentThreadDetail {
        val row = AgentThreadRow(
            key = "fixture-host:claude:thread", title = "Fixture", provider = "Claude", model = null, preview = null,
            status = "working", attention = "none", location = "~/app", queuedCount = null, isFork = false,
            actionAvailable = true, spawnAvailable = false, forkAvailable = false,
            hostID = "fixture-host", providerID = "claude", providerSessionID = "fixture-thread", host = "fixture-host",
        )
        return AgentThreadDetail(
            row = row,
            live = listOf(
                AgentBlock("assistant", PROSE_TEXT, kind = "text", recordID = "prose"),
                AgentBlock("assistant", PATH_TEXT, kind = "text", recordID = "path"),
                AgentBlock("assistant", LINK_TEXT, kind = "text", recordID = "link"),
            ),
            activity = emptyList(), changes = emptyList(),
            binding = SharedAgentValue.ObjectValue(mapOf(
                "liveSessionID" to SharedAgentValue.StringValue("fixture-live"),
                "transport" to SharedAgentValue.StringValue("sshTmux"),
                "paneID" to SharedAgentValue.StringValue("%2"),
            )),
            hasMore = false,
        )
    }

    private companion object {
        const val PATH_TEXT = "README.md"
        const val LINK_TEXT = "http://localhost:5173/app"
        const val PROSE_TEXT = "plain prose sentence"
        const val OPEN = "Open in Artifacts"
        const val REVEAL = "Reveal in Files"
        val MENU_LABELS = setOf("Cut", "Copy", "Paste", "Select all", "Share", OPEN, REVEAL)
        // The platform floating toolbar's overflow button, closed and open.
        const val OVERFLOW = "More options"
        const val OVERFLOW_BACK = "Back"
    }
}
