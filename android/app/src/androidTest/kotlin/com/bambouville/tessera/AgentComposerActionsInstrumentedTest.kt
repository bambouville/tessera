package com.bambouville.tessera

import android.graphics.Bitmap
import android.content.ContentValues
import android.provider.MediaStore
import android.view.accessibility.AccessibilityNodeInfo
import android.accessibilityservice.AccessibilityService
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.feature.agentcenter.AgentComposerKeyboardFixture
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Native composer controls, independent of a host or the user's app data. */
class AgentComposerActionsInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun sendAcknowledgesTheTapAndExposesAttachments(): Unit {
        val requests = mutableListOf<Boolean>()
        compose.activityRule.scenario.onActivity {
            it.enableEdgeToEdge()
            it.window.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
        }
        compose.setContent {
            TesseraTheme {
                CompactRootScaffold(CompactRootTab.Agents, true, {}, Modifier.fillMaxSize()) { padding ->
                    AgentComposerKeyboardFixture(Modifier.fillMaxSize().agentCenterContentPadding(padding)) { requests += it }
                }
            }
        }
        compose.onNodeWithTag("agent-composer").performTextInput("Check the next instruction.")
        compose.waitUntil(5_000) {
            androidx.core.view.ViewCompat.getRootWindowInsets(compose.activity.window.decorView)
                ?.getInsets(androidx.core.view.WindowInsetsCompat.Type.ime())?.bottom?.let { it > 0 } == true
        }
        android.os.SystemClock.sleep(1_600)
        compose.waitForIdle()
        compose.onNodeWithTag("agent-send").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("agent-send-progress").assertExists()
        compose.onNodeWithTag("agent-send").assertDoesNotExist()
        capture("sending")
        assertEquals(listOf(false), requests)
        compose.onNodeWithTag("agent-composer").performTextReplacement("Concurrent edit")
        compose.mainClock.advanceTimeBy(4_500)
        compose.waitUntil(7_000) { compose.onAllNodesWithTag("agent-send-progress").fetchSemanticsNodes().isEmpty() }
        compose.onNodeWithTag("agent-composer").assertTextEquals("Concurrent edit")
        compose.onNodeWithTag("agent-send").performTouchInput { longClick() }
        compose.onNodeWithText("Queue message").performClick()
        compose.onNodeWithTag("agent-send-progress").assertExists()
        capture("queueing")
        assertEquals(listOf(false, true), requests)
        compose.mainClock.advanceTimeBy(4_500)
        compose.waitUntil(7_000) { compose.onAllNodesWithTag("agent-send-progress").fetchSemanticsNodes().isEmpty() }

        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val resolver = instrumentation.targetContext.contentResolver
        val file = requireNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "tessera-attachment-fixture.txt")
            put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }))
        try {
            resolver.openOutputStream(file)!!.use { it.write("Tessera native attachment fixture\n".toByteArray()) }
            resolver.update(file, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            compose.onNodeWithTag("agent-attach").performClick()
            waitForSystemNode { it.packageName?.toString()?.endsWith(".documentsui") == true }
            capture("picker")
            instrumentation.uiAutomation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
            compose.waitUntil(5_000) { compose.onAllNodesWithTag("agent-attach").fetchSemanticsNodes().isNotEmpty() }
            assertEquals("", compose.onNodeWithTag("agent-composer").fetchSemanticsNode()
                .config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
            compose.onNodeWithTag("agent-attach").performClick()
            // The document provider's navigation drawer is native, not a
            // Tessera imitation. Select the owned Downloads fixture.
            clickSystemNode { it.contentDescription?.toString() in setOf("Show roots", "Show navigation drawer") }
            clickSystemNode { it.text?.toString() == "Downloads" }
            clickSystemNode { it.text?.toString() == "tessera-attachment-fixture.txt" }
            compose.waitUntil(5_000) { compose.onAllNodesWithTag("agent-upload-progress").fetchSemanticsNodes().isNotEmpty() }
            capture("uploading")
            compose.onNodeWithTag("agent-composer").performTextReplacement("Review this file")
            compose.mainClock.advanceTimeBy(4_500)
            compose.waitUntil(7_000) { compose.onAllNodesWithTag("agent-upload-progress").fetchSemanticsNodes().isEmpty() }
            compose.onNodeWithTag("agent-composer").assertTextEquals("Review this file\n\"/fixture/private-upload/tessera-attachment-fixture.txt\"")
            assertEquals("attaching must never send", listOf(false, true), requests)
            capture("attached")
        } finally { resolver.delete(file, null, null) }
    }

    private fun capture(name: String) {
        // Native picker/IME callbacks arrive on wall time while Compose tests
        // drive frames virtually. Let both clocks settle before capturing.
        compose.mainClock.advanceTimeBy(1_000)
        repeat(6) {
            android.os.SystemClock.sleep(200)
            compose.mainClock.advanceTimeByFrame()
            compose.waitForIdle()
        }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val root = compose.activity.window.decorView
        val frame = if (name == "picker") null else compose.onNodeWithTag("agent-composer-frame").fetchSemanticsNode().boundsInWindow
        val metrics = "stage=$name rootHeight=${root.height} rootScrollY=${root.scrollY} softInput=${compose.activity.window.attributes.softInputMode} frame=$frame"
        File(instrumentation.targetContext.filesDir, "composer-$name.txt").writeText(metrics)
        android.util.Log.i("TesseraComposerActions", metrics)
        val shot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(instrumentation.targetContext.filesDir, "composer-$name.png").outputStream().use {
            check(shot.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        shot.recycle()
    }

}

    private fun waitForSystemNode(predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val deadline = android.os.SystemClock.uptimeMillis() + 8_000
        while (android.os.SystemClock.uptimeMillis() < deadline) {
            // UiAutomation answers from a cache that only accessibility
            // events invalidate, and Compose's can come many seconds late: a
            // cached composer still read empty 10 s after the upload filled
            // it. Read the live tree on every pass.
            val live = android.os.Build.VERSION.SDK_INT >= 34 && automation.clearCache()
            val nodes = ArrayDeque<AccessibilityNodeInfo>()
            automation.rootInActiveWindow?.let(nodes::add)
            while (nodes.isNotEmpty()) {
                val node = nodes.removeFirst()
                if (!live && !node.refresh()) continue
                if (node.isVisibleToUser && predicate(node)) return node
                for (index in 0 until node.childCount) node.getChild(index)?.let(nodes::add)
            }
            android.os.SystemClock.sleep(100)
        }
        error("Native document picker control not found")
    }

    private fun clickSystemNode(predicate: (AccessibilityNodeInfo) -> Boolean) {
        repeat(5) {
            // A label can also show where nothing clicks: DocumentsUI reopens
            // on the root picked last, and its title then reads "Downloads"
            // ahead of the drawer's row. Take the first match that clicks.
            val node = waitForSystemNode { predicate(it) && it.clickableSelfOrAncestor() != null }
                .clickableSelfOrAncestor()
            if (node?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) return
            android.os.SystemClock.sleep(200)
        }
        error("Native picker target became stale before its click")
    }

    private fun AccessibilityNodeInfo.clickableSelfOrAncestor(): AccessibilityNodeInfo? {
        var node: AccessibilityNodeInfo? = this
        while (node != null && !node.isClickable) node = node.parent
        return node
    }

/** Real frame clock and manifest window configuration; no Compose test recomposer. */
class AgentComposerNativeWindowInstrumentedTest {
    @Test fun pickerReturnKeepsComposerAboveKeyboard() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val intent = android.content.Intent(context, TesseraHarnessActivity::class.java)
            .putExtra("scene", "agent-composer").addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
        val resolver = context.contentResolver
        val file = requireNotNull(resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, "tessera-attachment-fixture.txt")
            put(MediaStore.MediaColumns.MIME_TYPE, "text/plain")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }))
        try {
            resolver.openOutputStream(file)!!.use { it.write("Native real-clock composer fixture".toByteArray()) }
            resolver.update(file, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            androidx.test.core.app.ActivityScenario.launch<TesseraHarnessActivity>(intent).use { scenario ->
                val field = waitForSystemNode { it.className?.toString() == "android.widget.EditText" }
                field.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                val textArgs = android.os.Bundle().apply {
                    putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "")
                }
                assertTrue(field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, textArgs))
                android.os.SystemClock.sleep(1_500)
                capture("focused", scenario)
                clickSystemNode { it.contentDescription?.toString() == "attach file" }
                waitForSystemNode { it.packageName?.toString()?.endsWith(".documentsui") == true }
                capture("picker", scenario)
                android.os.SystemClock.sleep(600)
                clickSystemNode { it.contentDescription?.toString() in setOf("Show roots", "Show navigation drawer") }
                clickSystemNode { it.text?.toString() == "Downloads" }
                clickSystemNode { it.text?.toString() == "tessera-attachment-fixture.txt" }
                waitForSystemNode { it.contentDescription?.toString() == "uploading attachment" }
                android.os.SystemClock.sleep(1_000)
                capture("uploading", scenario)
                android.os.SystemClock.sleep(3_500)
                val attached = waitForSystemNode { it.className?.toString() == "android.widget.EditText" && it.text?.contains("/fixture/private-upload/") == true }
                assertTrue(attached.text.toString().startsWith("\"/fixture/private-upload/"))
                capture("attached", scenario)
            }
        } finally { resolver.delete(file, null, null) }
    }

    private fun capture(name: String, scenario: androidx.test.core.app.ActivityScenario<TesseraHarnessActivity>) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        if (name != "picker") {
            val field = waitForSystemNode { it.className?.toString() == "android.widget.EditText" }
            // UiAutomation caches nodes until an accessibility event replaces
            // them, and Compose sends none when a node only moves. After the
            // picker returns, the cached field keeps its pre-picker bounds
            // for seconds while the screen already shows it above the
            // keyboard, so read live bounds. A frame still pending right
            // after the return gets a short settle.
            val bounds = android.graphics.Rect()
            var metrics = ""
            var admitted = false
            var reads = 0
            val deadline = android.os.SystemClock.uptimeMillis() + 1_000
            do {
                reads += 1
                assertTrue("composer field left the window", field.refresh())
                field.getBoundsInScreen(bounds)
                scenario.onActivity { activity ->
                    val root = activity.window.decorView
                    val ime = androidx.core.view.ViewCompat.getRootWindowInsets(root)
                        ?.getInsets(androidx.core.view.WindowInsetsCompat.Type.ime())?.bottom ?: 0
                    val keyboardTop = root.height - ime
                    val gap = (keyboardTop - bounds.bottom) / root.resources.displayMetrics.density
                    metrics = "stage=$name rootHeight=${root.height} ime=$ime bounds=$bounds gapDP=$gap reads=$reads"
                    admitted = ime > 0 && gap in 0f..25f
                }
                if (!admitted) android.os.SystemClock.sleep(100)
            } while (!admitted && android.os.SystemClock.uptimeMillis() < deadline)
            File(instrumentation.targetContext.filesDir, "composer-$name.txt").writeText(metrics)
            android.util.Log.i("TesseraComposerActions", metrics)
            assertTrue(metrics, admitted)
        } else File(instrumentation.targetContext.filesDir, "composer-$name.txt").writeText("Native document picker")
        val shot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
        File(instrumentation.targetContext.filesDir, "composer-$name.png").outputStream().use {
            check(shot.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        shot.recycle()
    }
}
