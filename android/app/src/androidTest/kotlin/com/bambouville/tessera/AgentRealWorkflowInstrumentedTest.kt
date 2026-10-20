package com.bambouville.tessera

import android.os.SystemClock
import android.view.MotionEvent
import android.view.WindowManager
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Real production UI only: no injected state, test endpoint, provider writes,
 * reset, or connection action. Arguments and evidence stay in private storage.
 * Public UiAutomation avoids Espresso's hidden InputManager reflection, which
 * is incompatible with newer Android releases on physical Pixels.
 */
@RunWith(AndroidJUnit4::class)
class AgentRealWorkflowInstrumentedTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val args get() = InstrumentationRegistry.getArguments()
    private val automation get() = instrumentation.uiAutomation
    private val evidence get() = File(instrumentation.targetContext.cacheDir, "agent-real-acceptance").apply { mkdirs() }

    @Test fun detectedRowHasTitleMessagesLiveUpdatesAndRangedHistory() {
        assumeTrue("Explicit real-device/host authorization required", args.getString("tesseraRealAgent") == "authorized")
        fun required(key: String) = requireNotNull(args.getString(key)?.takeIf { it.isNotBlank() }) { "Missing $key" }
        val title = required("agentTitle")
        val provider = required("agentProvider")
        val host = required("agentHost")
        val marker = required("agentLiveMarker")
        var latestMarker = marker
        val hold = args.getString("agentHoldSeconds")?.toLongOrNull()?.coerceIn(0, 900) ?: 0
        val log = File(instrumentation.targetContext.filesDir, "tessera-diagnostics.log")
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        scenario.onActivity { it.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
        try {
            if (args.getString("reopenTemporaryHost") == "authorized") {
                check(args.getString("temporaryHost") == "authorized")
                check(android.os.Build.HARDWARE == "ranchu" || android.os.Build.HARDWARE == "goldfish")
                await { find { it.text?.toString() == "• Temporary Mac Test" } != null }
                click { it.text?.toString().equals("reopen", ignoreCase = true) }
                await { find { isSessionSwitcher(it) } != null }
            }
            args.getString("connectTemporaryHost")?.let { label ->
                check(args.getString("temporaryHost") == "authorized")
                check(android.os.Build.HARDWARE == "ranchu" || android.os.Build.HARDWARE == "goldfish")
                click { it.text?.toString() == label }
                await { find { isSessionSwitcher(it) } != null }
            }
            await { find { label(it) == "agents" } != null || find { isSessionSwitcher(it) } != null }
            if (find { isSessionSwitcher(it) } != null) click { label(it) == "Back" }
            click { label(it) == "agents" }
            capture("real-list")
            if (find { label(it) == "back to agents" } != null) click { label(it) == "back to agents" }
            val row: (AccessibilityNodeInfo) -> Boolean = {
                val description = it.contentDescription?.toString().orEmpty()
                title in description && description.contains(provider, ignoreCase = true) && "host $host" in description
            }
            await { find(row) != null }
            click(row)
            await { find { it.text?.toString() == title } != null && scrollable() != null }
            assertTrue("Conversation unavailable", find { label(it) == "live projection is unavailable" } == null)
            assertTrue("Live marker must arrive after opening", find { marker in label(it) } == null)
            capture("real-open")
            await(120_000) {
                assertTrue("Title changed while awaiting live output", find { it.text?.toString() == title } != null)
                assertTrue("Live follow detached without a history gesture",
                    find { label(it).equals("Return to latest", ignoreCase = true) } == null)
                find { marker in label(it) } != null
            }
            capture("real-live")
            args.getString("agentUpgradeMarker")?.let { upgradeMarker ->
                capture("real-before-upgrade")
                await(300_000) { find { upgradeMarker in label(it) } != null }
                assertTrue("Title changed during handover", find { it.text?.toString() == title } != null)
                capture("real-after-upgrade")
                latestMarker = upgradeMarker
            }
            val before = if (log.exists()) log.readLines().toSet() else emptySet()
            fun olderCommitted() = log.exists() && log.useLines { lines -> lines.any {
                it !in before && "agent_ingestion_window_read" in it &&
                    "operation=before" in it && "accepted=true" in it
            } }
            var attempts = 0
            while (!olderCommitted() && attempts++ < 24) {
                swipeDown(requireNotNull(scrollable()) { "Missing rendered transcript" })
                SystemClock.sleep(600)
            }
            await(10_000) { olderCommitted() }
            assertTrue("History must remain visible", scrollable() != null)
            capture("real-history")
            click { label(it).equals("Return to latest", ignoreCase = true) }
            await { find { latestMarker in label(it) } != null }
            capture("real-return-latest")
            if (args.getString("agentReceiptProbe") == "read-only") {
                var runtime: AgentSessionViewModel? = null
                scenario.onActivity { activity ->
                    runtime = MainActivity::class.java.getDeclaredMethod("getAgentRuntime").also { it.isAccessible = true }
                        .invoke(activity) as AgentSessionViewModel
                }
                probeReadOnlyReceipt(requireNotNull(runtime))
                capture("real-receipt-boundary")
            }
        } finally {
            // Bounded operator hold permits all rows in one unlock. No system
            // setting, data, or live session is reset, even on test failure.
            capture("real-final")
            SystemClock.sleep(hold * 1000)
            scenario.onActivity { it.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
            scenario.close()
        }
    }

    /** Supplementary production-read diagnostic, NOT send/receipt E2E proof.
     * No action lease, outgoing message, terminal insertion or key is created. */
    private fun probeReadOnlyReceipt(runtime: AgentSessionViewModel) = kotlinx.coroutines.runBlocking {
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
            val presenter = runtime.presenter
            fun field(owner: Any, name: String): Any? = owner.javaClass.getDeclaredField(name)
                .also { it.isAccessible = true }.get(owner)
            val method = presenter.javaClass.declaredMethods.single { it.name == "projectNative" }
                .also { it.isAccessible = true }
            repeat(10) { index ->
                val key = requireNotNull(presenter.state.value.selectedThreadKey)
                val source = requireNotNull((field(presenter, "projectionSources") as Map<*, *>)[key])
                val endpointKey = field(source, "endpointKey") as com.bambouville.tessera.agent.platform.AgentSessionKey
                val endpoint = requireNotNull(runtime.coordinator.directory.resolve(endpointKey))
                val boundary = kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn<org.json.JSONObject?> { continuation ->
                    method.invoke(presenter, endpoint, field(source, "binding"),
                        org.json.JSONObject(field(source, "threadID") as String), field(source, "provider"),
                        field(source, "transcriptRef"), key, field(source, "bindingToken"), null, true, "before", continuation)
                }
                assertTrue("Fresh read-only receipt boundary unavailable", boundary != null)
                android.util.Log.i("AgentRealAcceptance", "stage=read-only-receipt index=$index")
                kotlinx.coroutines.delay(500)
            }
        }
    }

    private fun label(node: AccessibilityNodeInfo) = node.contentDescription?.toString()?.takeIf { it.isNotBlank() }
        ?: node.text?.toString().orEmpty()
    // The switcher appends a held integration notice to its description.
    private fun isSessionSwitcher(node: AccessibilityNodeInfo) =
        label(node).startsWith("Switch session, window, or pane")
    private fun find(predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
        fun visit(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
            if (node.isVisibleToUser && predicate(node)) return node
            for (index in 0 until node.childCount) node.getChild(index)?.let { visit(it)?.let { found -> return found } }
            return null
        }
        return automation.rootInActiveWindow?.let(::visit)
    }
    private fun scrollable() = find { it.isScrollable }
    private fun await(timeout: Long = 60_000, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeout
        while (!condition() && SystemClock.uptimeMillis() < deadline) SystemClock.sleep(100)
        assertTrue("Real app acceptance condition timed out", condition())
    }
    private fun click(predicate: (AccessibilityNodeInfo) -> Boolean) {
        await { find(predicate) != null }
        var node = requireNotNull(find(predicate))
        while (!node.isClickable) node = requireNotNull(node.parent) { "No clickable UI ancestor" }
        assertTrue(node.performAction(AccessibilityNodeInfo.ACTION_CLICK))
    }
    private fun swipeDown(node: AccessibilityNodeInfo) {
        val bounds = android.graphics.Rect().also(node::getBoundsInScreen)
        val x = bounds.exactCenterX()
        val start = bounds.top + bounds.height() * .2f
        val distance = bounds.height() * .65f
        val down = SystemClock.uptimeMillis()
        for (step in 0..12) {
            val action = when (step) { 0 -> MotionEvent.ACTION_DOWN; 12 -> MotionEvent.ACTION_UP; else -> MotionEvent.ACTION_MOVE }
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, start + distance * step / 12, 0)
            try { assertTrue(automation.injectInputEvent(event, true)) } finally { event.recycle() }
            SystemClock.sleep(25)
        }
    }
    private fun capture(name: String) {
        val tree = StringBuilder()
        fun record(node: AccessibilityNodeInfo, depth: Int) {
            tree.appendLine("${" ".repeat(depth)}click=${node.isClickable} visible=${node.isVisibleToUser} text=${node.text} description=${node.contentDescription}")
            for (index in 0 until node.childCount) node.getChild(index)?.let { record(it, depth + 1) }
        }
        automation.rootInActiveWindow?.let { record(it, 0) }
        File(evidence, "$name.txt").writeText(tree.toString())
        val bitmap = automation.takeScreenshot() ?: return
        File(evidence, "$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        android.util.Log.i("AgentRealAcceptance", "stage=$name")
    }
}
