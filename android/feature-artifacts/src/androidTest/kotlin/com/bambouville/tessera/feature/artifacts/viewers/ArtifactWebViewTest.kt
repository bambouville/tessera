package com.bambouville.tessera.feature.artifacts.viewers

import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inspector.WindowInspector
import android.webkit.WebView
import android.widget.TextView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.feature.artifacts.ArtifactsFixtureActivity
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ArtifactWebViewTest {
    @get:Rule val compose = createAndroidComposeRule<ArtifactsFixtureActivity>()
    private val hostId = "test-web-" + UUID.randomUUID()

    @After fun disposeFixture() {
        compose.activityRule.scenario.onActivity { it.installFixture {} }
        compose.waitForIdle()
        compose.runOnIdle { deleteArtifactProfile(hostId) }
    }

    @Test fun javascriptPanelsCannotCoverTheLockOverlayAndThePageKeepsRunning() {
        val title = AtomicReference("")
        val result = AtomicReference<String?>(null)
        val locked = mutableStateOf(false)
        val source = """
            <!doctype html><meta charset=utf-8><title>ready</title>
            <script>
            function runDialogs() {
                alert('artifact alert sentinel');
                const answer = confirm('artifact confirm sentinel');
                const text = prompt('artifact prompt sentinel', 'default');
                document.title = 'dialogs:' + answer + ':' + text;
                return answer === false && text === null;
            }
            </script><p>local fixture</p>
        """.trimIndent()
        // The synthetic origin has only this fake reader, with no transport or
        // network fallback. Use a real page so Chromium's dialog path executes.
        val interceptor = ArtifactSftpInterceptor("dialog-test", "/site/index.html", ArtifactRemoteReader { _, _, _ -> source.toByteArray() })
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.installFixture {
                    TesseraTheme {
                        Box(Modifier.fillMaxSize()) {
                            ArtifactWebView(interceptor.pageUrl, hostId, interceptor = interceptor, showControls = false, onTitleChanged = title::set)
                            if (locked.value) Box(Modifier.fillMaxSize().background(Color.Black).testTag("fixture-lock"))
                        }
                    }
                }
            }
            compose.waitUntil(10_000) { title.get() == "ready" }
            compose.runOnIdle { locked.value = true }
            compose.onNodeWithTag("fixture-lock").assertIsDisplayed()
            compose.runOnIdle {
                checkNotNull(findWebView(compose.activity.window.decorView)).evaluateJavascript("runDialogs()") { result.set(it) }
            }
            compose.waitUntil(10_000) { result.get() != null && title.get() == "dialogs:false:null" }
            assertEquals("true", result.get())
            compose.runOnIdle {
                assertFalse(WindowInspector.getGlobalWindowViews().any(::containsDialogMessage))
            }
            compose.onNodeWithTag("fixture-lock").assertIsDisplayed()
        } finally {
            compose.activityRule.scenario.onActivity { it.installFixture {} }
            compose.waitForIdle()
            interceptor.close()
        }
    }

    @Test fun anUnloadPromptNeverTrapsThePage() {
        val title = AtomicReference("")
        val pages = mapOf(
            "/site/index.html" to """
                <!doctype html><meta charset=utf-8><title>first</title>
                <meta name=viewport content="width=device-width, initial-scale=1">
                <script>addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = 'stay'; });</script>
                <a href="next.html" style="display:block;font-size:48px;padding:40px">next page</a>
            """.trimIndent(),
            "/site/next.html" to "<!doctype html><meta charset=utf-8><title>second</title><p>arrived</p>",
        )
        val interceptor = ArtifactSftpInterceptor("unload-test", "/site/index.html", ArtifactRemoteReader { _, path, _ ->
            checkNotNull(pages[path]) { "unexpected read $path" }.toByteArray()
        })
        try {
            compose.activityRule.scenario.onActivity { activity ->
                activity.installFixture {
                    TesseraTheme { ArtifactWebView(interceptor.pageUrl, hostId, interceptor = interceptor, showControls = false, onTitleChanged = title::set) }
                }
            }
            compose.waitUntil(10_000) { title.get() == "first" }
            // A real tap gives the page the user activation that arms its unload prompt.
            tapFirstLink()
            compose.waitUntil(10_000) { title.get() == "second" }
        } finally {
            compose.activityRule.scenario.onActivity { it.installFixture {} }
            compose.waitForIdle()
            interceptor.close()
        }
    }

    @Test fun deletingAMountedHostsProfileClearsItsDataAndLeavesTheProfileForTheNextStart() {
        var supported = false
        compose.runOnIdle { supported = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) }
        assumeTrue("the installed WebView must support MULTI_PROFILE", supported)
        val url = "http://127.0.0.1:5173/"
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme { ArtifactWebView("about:blank", hostId, showControls = false) }
            }
        }
        compose.waitForIdle()
        compose.runOnIdle {
            val view = checkNotNull(findWebView(compose.activity.window.decorView))
            val cookies = WebViewCompat.getProfile(view).cookieManager
            cookies.setCookie(url, "session=removed-host; Path=/")
            assertTrue(cookies.getCookie(url).orEmpty().contains("session=removed-host"))
            deleteArtifactProfile(hostId)
            // Loaded in this process: the profile stays until the next start's reconciliation.
            assertTrue(ProfileStore.getInstance().allProfileNames.contains("artifacts-$hostId"))
            assertEquals("artifacts-$hostId", WebViewCompat.getProfile(view).name)
        }
        compose.waitUntil(5_000) {
            compose.runOnUiThread { ProfileStore.getInstance().getProfile("artifacts-$hostId")?.cookieManager?.getCookie(url) == null }
        }
        compose.activityRule.scenario.onActivity { it.installFixture {} }
        compose.waitForIdle()
    }

    /** The page needs a device-width viewport, so CSS pixels times devicePixelRatio are screen pixels. */
    private fun tapFirstLink() {
        val measured = CountDownLatch(1)
        var center: List<Float> = emptyList()
        compose.runOnIdle {
            checkNotNull(findWebView(compose.activity.window.decorView)).evaluateJavascript(
                "(() => { const r = document.querySelector('a').getBoundingClientRect(); const d = window.devicePixelRatio;" +
                    " return [(r.left + r.width / 2) * d, (r.top + r.height / 2) * d]; })()",
            ) { value ->
                center = value.trim('[', ']').split(',').map { it.trim().toFloat() }
                measured.countDown()
            }
        }
        assertTrue("the page did not report its link", measured.await(5, TimeUnit.SECONDS))
        val origin = IntArray(2)
        compose.runOnIdle { checkNotNull(findWebView(compose.activity.window.decorView)).getLocationOnScreen(origin) }
        val x = origin[0] + center[0]
        val y = origin[1] + center[1]
        val down = SystemClock.uptimeMillis()
        for ((action, time) in listOf(MotionEvent.ACTION_DOWN to down, MotionEvent.ACTION_UP to down + 60)) {
            val event = MotionEvent.obtain(down, time, action, x, y, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            InstrumentationRegistry.getInstrumentation().sendPointerSync(event)
            event.recycle()
        }
    }

    private fun findWebView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            findWebView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    private fun containsDialogMessage(view: View): Boolean {
        if (view is TextView && view.text.toString().startsWith("artifact ") && view.text.toString().endsWith(" sentinel")) return true
        return view is ViewGroup && (0 until view.childCount).any { containsDialogMessage(view.getChildAt(it)) }
    }
}
