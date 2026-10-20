package com.bambouville.tessera.feature.pairing

import android.os.Bundle
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test

/** Opt-in UI input only; no credential is compiled into an APK or logged. */
class FixturePasswordInputTest {
    @Test fun enterApprovedFixturePassword() {
        val args = InstrumentationRegistry.getArguments()
        val password = args.getString("fixturePassword") ?: return
        val expectedHost = requireNotNull(args.getString("fixtureHost"))
        require(expectedHost.isNotBlank())
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        fun flatten(node: AccessibilityNodeInfo): List<AccessibilityNodeInfo> = buildList {
            add(node)
            for (i in 0 until node.childCount) node.getChild(i)?.let { addAll(flatten(it)) }
        }
        var root = automation.rootInActiveWindow
        repeat(50) {
            if (root == null) {
                SystemClock.sleep(100)
                root = automation.rootInActiveWindow
            }
        }
        val nodes = flatten(checkNotNull(root))
        require(nodes.any { it.text?.toString() == "Password for tessera on $expectedHost" })
        val editor = nodes.single { it.isEditable && it.isPassword }
        check(editor.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, password)
        }))
        SystemClock.sleep(500)
        val updated = flatten(checkNotNull(automation.rootInActiveWindow))
        // Compose accessibility exposes only the visible part of a scrolled
        // single-line password field. Server authentication is the full-value oracle.
        var connect = updated.single { it.text?.toString() == "Connect" }
        while (!connect.isClickable) connect = checkNotNull(connect.parent)
        check(connect.performAction(AccessibilityNodeInfo.ACTION_CLICK))
        println("FIXTURE_PASSWORD_UI_SUBMITTED: ACTION_SET_TEXT accepted; secret not logged")
    }
}
