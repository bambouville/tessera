package com.bambouville.tessera

import android.os.Bundle
import android.content.Intent
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test

/** Opt-in capture driver. Camera mode never receives or injects QR text. */
class PairingCaptureInputTest {
    @Test fun enterCapturedQr() {
        val arguments = InstrumentationRegistry.getArguments()
        val camera = arguments.getString("cameraScan") == "true"
        val code = arguments.getString("qrText")
        if (!camera && code == null) return
        if (!camera) require(code!!.startsWith("tessera://pair/v1?offer="))
        require(!camera || code == null) { "Camera evidence must not inject a QR payload" }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val automation = instrumentation.uiAutomation
        instrumentation.targetContext.startActivity(Intent(instrumentation.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        fun find(node: AccessibilityNodeInfo, predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo? {
            if (predicate(node)) return node
            for (index in 0 until node.childCount) {
                val child = node.getChild(index) ?: continue
                find(child, predicate)?.let { return it }
            }
            return null
        }
        fun awaitNode(attempts: Int = 100, scroll: Boolean = true, predicate: (AccessibilityNodeInfo) -> Boolean): AccessibilityNodeInfo {
            repeat(attempts) { attempt ->
                automation.rootInActiveWindow?.let { root ->
                    find(root, predicate)?.let { return it }
                    if (scroll && attempt > 0 && attempt % 10 == 0) {
                        find(root) { it.isScrollable }?.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
                    }
                }
                SystemClock.sleep(100)
            }
            automation.takeScreenshot()?.let { bitmap ->
                java.io.File(instrumentation.targetContext.cacheDir, "qr-camera-timeout.png").outputStream().use {
                    bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
                }
                bitmap.recycle()
            }
            fun visibleText(node: AccessibilityNodeInfo): List<String> = buildList {
                node.text?.toString()?.takeIf { it.isNotBlank() }?.let(::add)
                for (index in 0 until node.childCount) node.getChild(index)?.let { addAll(visibleText(it)) }
            }
            println("QR_DRIVER_TIMEOUT_UI: " + automation.rootInActiveWindow?.let(::visibleText))
            error("Expected QR control did not appear")
        }
        fun click(text: String) {
            var node = awaitNode { it.text?.toString() == text }
            while (!node.isClickable) node = checkNotNull(node.parent)
            check(node.performAction(AccessibilityNodeInfo.ACTION_CLICK))
            SystemClock.sleep(350)
        }
        click("settings")
        click("sync & continuity")
        click("pair another device")
        val entry = awaitNode {
            it.text?.toString() in setOf("start a fresh verified pairing", "enter code instead")
        }
        if (entry.text?.toString() == "start a fresh verified pairing") click("start a fresh verified pairing")
        if (camera) {
            click("scan pairing code")
            awaitNode(attempts = 600, scroll = false) { it.text?.toString() == "Do the codes match?" }
            println("CAMERA_SCAN_VERIFIED: real scanner reached authenticated comparison without text injection")
        } else {
            click("enter code instead")
            val editor = awaitNode { it.isEditable }
            check(editor.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, code)
            }))
            SystemClock.sleep(500)
            // Compose exposes only the visible single-line text to accessibility.
            // The subsequent authenticated handshake is the full-code oracle.
            click("use pairing code")
        }
        // Keep the instrumentation process alive while both screens are captured
        // and the human-visible comparison/consent is exercised externally.
        SystemClock.sleep(arguments.getString("holdMillis")?.toLong() ?: 600_000)
    }
}
