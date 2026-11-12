package com.bambouville.tessera.feature.artifacts.viewers

import android.content.Context
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.feature.artifacts.ArtifactsFixtureActivity
import java.io.FileNotFoundException
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ArtifactWebRendererRecoveryTest {
    @get:Rule val compose = createAndroidComposeRule<ArtifactsFixtureActivity>()
    private val hostId = "test-renderer-${UUID.randomUUID()}"
    private val controller = ArtifactWebViewController()
    private val state = AtomicReference<ArtifactWebViewState?>(null)
    private val documentReads = AtomicInteger()
    private val interceptors = mutableListOf<ArtifactSftpInterceptor>()

    @After fun disposeFixture() {
        try {
            compose.activityRule.scenario.onActivity { it.installFixture {} }
            compose.waitForIdle()
            compose.runOnIdle {
                // A controller retained by the tab cannot resurrect disposed content.
                controller.reload()
                controller.stopLoading()
                assertFalse(controller.goBack())
                assertFalse(controller.goForward())
                assertNull(findWebView(compose.activity.window.decorView))
            }
        } finally {
            interceptors.forEach { it.close() }
            compose.runOnUiThread { deleteArtifactProfile(hostId) }
        }
    }

    @Test fun aRendererCrashDiscardsTheViewUntilTheTabIsShownAgain() {
        val interceptor = servedPage()
        val shown = mutableStateOf(true)
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme {
                    if (shown.value) ArtifactWebView(interceptor.pageUrl, hostId, interceptor = interceptor,
                        controller = controller, showControls = false, onStateChanged = state::set)
                }
            }
        }
        val first = loaded(interceptor.pageUrl, "first", reads = 1)
        loseRenderer(crashed = true)
        compose.onNodeWithText("this page did not answer").assertIsDisplayed()
        compose.runOnIdle {
            assertFalse(controller.goBack())
            assertFalse(controller.goForward())
            controller.stopLoading()
            shown.value = false
        }
        compose.waitForIdle()
        assertEquals(1, documentReads.get())
        compose.runOnIdle {
            state.set(null)
            shown.value = true
        }
        val second = loaded(interceptor.pageUrl, "first", reads = 2)
        assertNotSame(first, second)
        // An OOM kill on the replacement also waits, rather than spinning.
        loseRenderer(crashed = false)
        assertEquals(2, documentReads.get())
    }

    @Test fun controllerReloadRecoversTheCurrentUrlAndOldCallbacksCannotOverwriteIt() {
        val interceptor = servedPage()
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme { ArtifactWebView(interceptor.pageUrl, hostId, interceptor = interceptor,
                    controller = controller, showControls = false, onStateChanged = state::set) }
            }
        }
        val first = loaded(interceptor.pageUrl, "first", reads = 1)
        compose.runOnIdle { controller.reload() }
        assertSame(first, loaded(interceptor.pageUrl, "first", reads = 2))
        val nextUrl = interceptor.pageUrl.substringBeforeLast('/') + "/next.html"
        compose.runOnIdle { first.loadUrl(nextUrl) }
        loaded(nextUrl, "second", reads = 3)
        val oldClient = compose.runOnUiThread { first.webViewClient }
        val oldChrome = compose.runOnUiThread { checkNotNull(first.webChromeClient) }
        loseRenderer(crashed = true)
        compose.runOnIdle { controller.reload() }
        val replacement = loaded(nextUrl, "second", reads = 4)
        assertNotSame(first, replacement)
        compose.runOnIdle {
            oldClient.onPageStarted(first, interceptor.pageUrl, null)
            oldClient.onPageFinished(first, interceptor.pageUrl)
            oldClient.doUpdateVisitedHistory(first, interceptor.pageUrl, false)
            oldChrome.onReceivedTitle(first, "discarded title")
            oldChrome.onProgressChanged(first, 1)
            // A duplicate notification must not discard the replacement.
            assertTrue(oldClient.onRenderProcessGone(first, RendererGone(crashed = true)))
        }
        loaded(nextUrl, "second", reads = 4)
        loseRenderer(crashed = false)
        compose.runOnIdle { controller.reload() }
        assertNotSame(replacement, loaded(nextUrl, "second", reads = 5))
    }

    @Test fun embeddedReloadAndReloadTokenBothCreateFreshViews() {
        val interceptor = servedPage()
        val reloadToken = mutableLongStateOf(0L)
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme { ArtifactWebView(interceptor.pageUrl, hostId, interceptor = interceptor,
                    reloadToken = reloadToken.longValue, onStateChanged = state::set) }
            }
        }
        val first = loaded(interceptor.pageUrl, "first", reads = 1)
        compose.runOnIdle { reloadToken.longValue++ }
        assertSame(first, loaded(interceptor.pageUrl, "first", reads = 2))
        loseRenderer(crashed = true)
        compose.onNodeWithContentDescription("reload").performClick()
        val second = loaded(interceptor.pageUrl, "first", reads = 3)
        assertNotSame(first, second)
        loseRenderer(crashed = false)
        compose.runOnIdle { reloadToken.longValue++ }
        assertNotSame(second, loaded(interceptor.pageUrl, "first", reads = 4))
    }

    @Test fun theClientWithoutAnSftpInterceptorAlsoRecoversAtTheSameUrl() {
        // As in the forwarded visual fixture, a data URL needs no listener,
        // connection factory, Files channel, or new forwarding lease.
        val url = "data:text/html;charset=utf-8,${Uri.encode("<title>forwarded</title><p>held forwarding fixture</p>")}"
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                TesseraTheme { ArtifactWebView(url, hostId, controller = controller,
                    showControls = false, onStateChanged = state::set) }
            }
        }
        val first = loaded(url, "forwarded", reads = 0)
        loseRenderer(crashed = false)
        compose.runOnIdle { controller.reload() }
        assertNotSame(first, loaded(url, "forwarded", reads = 0))
    }

    @Test fun standaloneInterceptorDetachesAndDestroysItsViewAndClosesItsReads() {
        val interceptor = servedPage()
        compose.runOnIdle {
            val view = RecordingWebView(compose.activity)
            val parent = FrameLayout(compose.activity).apply { addView(view) }
            try {
                view.webViewClient = interceptor
                assertTrue(interceptor.onRenderProcessGone(view, RendererGone(crashed = true)))
                assertEquals(0, parent.childCount)
                assertNull(view.parent)
                assertEquals(1, view.destroys)
            } finally {
                if (view.destroys == 0) {
                    parent.removeView(view)
                    view.destroy()
                }
            }
        }
        runBlocking(Dispatchers.IO) {
            assertEquals(503, checkNotNull(interceptor.intercept(interceptor.pageUrl)).statusCode)
        }
        assertEquals(0, documentReads.get())
    }

    private fun servedPage(): ArtifactSftpInterceptor {
        val pages = mapOf("/site/index.html" to "first", "/site/next.html" to "second")
        // This reader has only an already-held, in-memory document source;
        // recovery has no connector or transport that could reconnect.
        return ArtifactSftpInterceptor("renderer-test", "/site/index.html", ArtifactRemoteReader { _, path, _ ->
            val title = pages[path] ?: throw FileNotFoundException(path)
            documentReads.incrementAndGet()
            "<!doctype html><meta charset=utf-8><meta http-equiv=Content-Security-Policy content=\"default-src 'none'\"><title>$title</title><p>held document</p>".toByteArray()
        }).also { interceptors += it }
    }

    private fun loaded(url: String, title: String, reads: Int): WebView {
        compose.waitUntil(10_000) {
            documentReads.get() >= reads &&
                state.get()?.let { it.url == url && it.title == title && !it.isLoading && it.failure == null } == true
        }
        var result: WebView? = null
        compose.runOnIdle {
            val view = checkNotNull(findWebView(compose.activity.window.decorView))
            result = view
            assertEquals(url, view.url)
            if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
                assertEquals("artifacts-$hostId", WebViewCompat.getProfile(view).name)
            }
        }
        assertEquals(reads, documentReads.get())
        return checkNotNull(result)
    }

    private fun loseRenderer(crashed: Boolean) {
        val before = documentReads.get()
        compose.runOnIdle {
            val view = checkNotNull(findWebView(compose.activity.window.decorView))
            assertTrue(view.webViewClient.onRenderProcessGone(view, RendererGone(crashed)))
            assertNull(view.parent)
        }
        compose.waitForIdle()
        compose.runOnIdle {
            assertNull(findWebView(compose.activity.window.decorView))
            assertEquals("this page did not answer", state.get()?.failure)
            assertFalse(checkNotNull(state.get()).isLoading)
        }
        // The oracle counts work, rather than timing how fast a reload is.
        assertEquals(before, documentReads.get())
    }

    private fun findWebView(view: View): WebView? {
        if (view is WebView) return view
        if (view is ViewGroup) for (index in 0 until view.childCount) {
            findWebView(view.getChildAt(index))?.let { return it }
        }
        return null
    }

    // The framework hands out no other instance to test with.
    @Suppress("DEPRECATION")
    private class RendererGone(private val crashed: Boolean) : RenderProcessGoneDetail() {
        override fun didCrash() = crashed
        override fun rendererPriorityAtExit() = WebView.RENDERER_PRIORITY_BOUND
    }

    private class RecordingWebView(context: Context) : WebView(context) {
        var destroys = 0
        override fun destroy() {
            destroys++
            super.destroy()
        }
    }
}
