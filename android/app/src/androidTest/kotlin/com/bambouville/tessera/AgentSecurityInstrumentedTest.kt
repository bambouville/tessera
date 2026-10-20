package com.bambouville.tessera

import android.app.Activity
import android.app.Application
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.speech.SpeechRecognizer
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import android.accessibilityservice.AccessibilityService
import com.bambouville.tessera.feature.agentcenter.AndroidAgentSpeechAdapter
import com.bambouville.tessera.feature.agentcenter.AgentCenterWindowPrivacy
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.collectAsState
import com.bambouville.tessera.data.AndroidAppPreferences
import com.bambouville.tessera.data.AppPreferences
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import android.view.InputDevice
import android.view.MotionEvent
import android.view.WindowManager
import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Host-free platform proof using a disposable install and synthetic content. */
class AgentSecurityInstrumentedTest {
    @Test fun privateRecentsAndOnDeviceSpeech() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val automation = instrumentation.uiAutomation
        val visible = mutableStateOf(false)
        val preferences = AndroidAppPreferences(context)
        // A disposable install has never touched the setting: content stays visible by default.
        runBlocking { preferences.values.first() }.let { untouched ->
            assertFalse(untouched.hideContentInAppSwitcher)
            assertFalse(untouched.hidesContentInAppSwitcher)
        }
        // Opt in before the first Recents visit so the launcher never caches an
        // unprotected task snapshot that would mask the protected result.
        runBlocking { preferences.updateHideContentInAppSwitcher(true) }
        // Every MainActivity instance shows only the synthetic transcript. On a
        // freshly booted emulator an assets-paths configuration change can
        // recreate the activity after launch, and the new instance's own
        // content would replace anything set once through the scenario.
        val application = context.applicationContext as Application
        val syntheticContent = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityPostCreated(activity: Activity, savedInstanceState: Bundle?) {
                if (activity !is MainActivity) return
                activity.setContent {
                    val settings = preferences.values.collectAsState(initial = AppPreferences())
                    // Mirrors MainActivity's Agent Center wiring: the effective policy.
                    if (visible.value) AgentCenterWindowPrivacy(settings.value.hidesContentInAppSwitcher)
                    Box(Modifier.fillMaxSize().background(Color.Magenta)) { Text("Synthetic private transcript") }
                }
            }
            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityResumed(activity: Activity) = Unit
            override fun onActivityPaused(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        }
        application.registerActivityLifecycleCallbacks(syntheticContent)
        try { ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                val speech = AndroidAgentSpeechAdapter(activity)
                assertEquals(SpeechRecognizer.isOnDeviceRecognitionAvailable(activity), speech.isAvailable)
                if (!speech.isAvailable) speech.start({ fail("unavailable speech returned text") }, { fail("unavailable speech requested permission") })
                speech.close()
            }
            // Overview takes input focus once the launcher shows it. Until then
            // a capture shows the app itself, which FLAG_SECURE blanks just as
            // it blanks the Recents tile, and a BACK finishes the activity.
            val launcherPackage = automation.executeShellCommand(
                "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME",
            ).let { ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().use { reader -> reader.readText() } }
                .lines().last { '/' in it }.substringBefore('/').trim()
            fun activePackage(): String? = automation.rootInActiveWindow?.packageName?.toString()
            fun expectedPackage(inOverview: Boolean) = if (inOverview) launcherPackage else context.packageName
            fun reachesActive(inOverview: Boolean, timeoutMillis: Long): Boolean {
                val deadline = android.os.SystemClock.uptimeMillis() + timeoutMillis
                while (true) {
                    if (activePackage() == expectedPackage(inOverview)) return true
                    if (android.os.SystemClock.uptimeMillis() > deadline) return false
                    android.os.SystemClock.sleep(100)
                }
            }
            fun awaitActive(inOverview: Boolean, step: String) {
                if (!reachesActive(inOverview, 10_000)) {
                    fail("$step: active window stayed ${activePackage()}, not ${expectedPackage(inOverview)}")
                }
            }
            fun openOverview(step: String) {
                // A launcher still settling after boot can drop the toggle;
                // press again only while the app still holds focus.
                repeat(3) {
                    assertTrue(automation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_RECENTS))
                    if (reachesActive(inOverview = true, 5_000)) return
                }
                fail("$step: Overview never took focus from ${activePackage()}")
            }
            val appLabel = context.applicationInfo.loadLabel(context.packageManager).toString()
            fun labelledNodes(): String {
                val labels = mutableListOf<String>()
                val nodes = ArrayDeque<android.view.accessibility.AccessibilityNodeInfo>()
                automation.rootInActiveWindow?.let(nodes::add)
                while (nodes.isNotEmpty() && labels.size < 40) {
                    val node = nodes.removeFirst()
                    val label = node.contentDescription ?: node.text
                    if (label != null) labels += "${node.className?.toString()?.substringAfterLast('.')}=\"$label\""
                    for (index in 0 until node.childCount) node.getChild(index)?.let(nodes::add)
                }
                return "${activePackage()} $labels"
            }
            fun leaveOverview(step: String) {
                // Overview can drop a BACK: recreated by that configuration
                // change, it may settle scrolled to Clear All and ignore it.
                // Tapping the app's tile, as a user returns, reopens the task.
                val tile = automation.rootInActiveWindow?.findAccessibilityNodeInfosByText(appLabel).orEmpty()
                    .filter { it.contentDescription?.toString() == appLabel }
                    .map { node -> Rect().also(node::getBoundsInScreen) }
                    .maxByOrNull { it.width() * it.height() }
                    ?: return fail("$step: Overview shows no $appLabel tile; labelled nodes: ${labelledNodes()}")
                val downTime = android.os.SystemClock.uptimeMillis()
                for ((action, eventTime) in listOf(MotionEvent.ACTION_DOWN to downTime, MotionEvent.ACTION_UP to downTime + 80)) {
                    val event = MotionEvent.obtain(downTime, eventTime, action, tile.exactCenterX(), tile.exactCenterY(), 0)
                    event.source = InputDevice.SOURCE_TOUCHSCREEN
                    assertTrue(automation.injectInputEvent(event, true))
                    event.recycle()
                }
                awaitActive(inOverview = false, step)
            }
            fun capture(name: String, inOverview: Boolean = false): Int {
                awaitActive(inOverview, name)
                automation.waitForIdle(200, 5000)
                android.os.SystemClock.sleep(1200)
                val shot = requireNotNull(instrumentation.uiAutomation.takeScreenshot())
                // The screenshot must show the surface its name claims.
                assertEquals(name, expectedPackage(inOverview), activePackage())
                File(context.filesDir, "security-$name.png").outputStream().use { shot.compress(Bitmap.CompressFormat.PNG, 100, it) }
                var magenta = 0
                for (y in 0 until shot.height step 4) for (x in 0 until shot.width step 4) {
                    val pixel = shot.getPixel(x, y)
                    if (android.graphics.Color.red(pixel) > 180 && android.graphics.Color.blue(pixel) > 180 && android.graphics.Color.green(pixel) < 80) magenta++
                }
                shot.recycle()
                return magenta
            }
            val foreground = capture("foreground")
            assertTrue(foreground > 10000)
            scenario.onActivity { visible.value = true }
            android.os.SystemClock.sleep(600)
            scenario.onActivity { assertTrue(it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) }
            // First test the production policy from onCreate, before creating
            // any unprotected task snapshot that the launcher could cache.
            openOverview("open protected Recents")
            val after = capture("recents-after", inOverview = true)
            assertTrue("private snapshot must hide transcript: $after", after < 100)
            leaveOverview("return from protected Recents")
            // Change the persisted preference while the surface stays composed.
            runBlocking { preferences.updateHideContentInAppSwitcher(false) }
            assertFalse(runBlocking { AndroidAppPreferences(context).values.first().hideContentInAppSwitcher })
            android.os.SystemClock.sleep(600)
            scenario.onActivity { assertEquals(0, it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) }
            assertTrue("disabled protection must allow capture", capture("returned") > 10000)
            // App lock forces the same protection without rewriting the opt-in.
            runBlocking { preferences.updateAppLockEnabled(true) }
            android.os.SystemClock.sleep(600)
            scenario.onActivity { assertTrue(it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) }
            assertTrue("app lock must block capture", capture("app-lock") < 100)
            assertFalse(runBlocking { preferences.values.first().hideContentInAppSwitcher })
            runBlocking { preferences.updateAppLockEnabled(false) }
            android.os.SystemClock.sleep(600)
            scenario.onActivity { assertEquals(0, it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) }
            runBlocking { preferences.updateHideContentInAppSwitcher(true) }
            android.os.SystemClock.sleep(600)
            scenario.onActivity { assertTrue(it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0) }
            assertTrue("reenabled protection must block capture", capture("reenabled") < 100)
            scenario.onActivity { visible.value = false }
            android.os.SystemClock.sleep(600)
            scenario.onActivity { assertEquals(0, it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) }
            assertTrue("leaving Agent Center restores capture", capture("disposed") > 10000)
            // Default OFF: Recents shows the real content again, Agent Center included.
            runBlocking { preferences.updateHideContentInAppSwitcher(false) }
            scenario.onActivity { visible.value = true }
            android.os.SystemClock.sleep(600)
            scenario.onActivity { assertEquals(0, it.window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE) }
            openOverview("open default Recents")
            val visibleRecents = capture("recents-off", inOverview = true)
            assertTrue("default Recents preview must show content: $visibleRecents", visibleRecents > 1000)
            leaveOverview("return from default Recents")
        } } finally {
            application.unregisterActivityLifecycleCallbacks(syntheticContent)
            runBlocking {
                preferences.updateAppLockEnabled(false)
                preferences.updateHideContentInAppSwitcher(false)
            }
        }
    }
}
