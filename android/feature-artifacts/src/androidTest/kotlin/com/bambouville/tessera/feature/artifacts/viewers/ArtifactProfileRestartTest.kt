package com.bambouville.tessera.feature.artifacts.viewers

import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * WebView deletes a profile only in a process that has not loaded it, so this
 * needs two instrumentation processes: `seed` (with `artifactsProfileSeedWaitMs`
 * long enough for WebView to save its profile list), then `reconcile`. A seed
 * without the wait, then `fresh`, covers a profile list lost to process death.
 * Selected with `-e artifactsProfilePhase`; skipped in ordinary connected runs.
 */
@RunWith(AndroidJUnit4::class)
class ArtifactProfileRestartTest {
    private val phase = InstrumentationRegistry.getArguments().getString("artifactsProfilePhase")
    private val name = "artifacts-$HOST"

    @Test fun seedARemovedHostsProfile() {
        assumeTrue(phase == "seed")
        requireMultiProfile()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val cookies = ProfileStore.getInstance().getOrCreateProfile(name).cookieManager
            cookies.setCookie("http://127.0.0.1:5173/", "session=removed-host; Path=/")
            served().use { cookies.setCookie(it.pageUrl, "session=removed-host; Path=/") }
            cookies.flush()
            assertTrue(ProfileStore.getInstance().allProfileNames.contains(name))
        }
        // WebView commits its profile list on a timer, not when a profile is created.
        Thread.sleep(InstrumentationRegistry.getArguments().getString("artifactsProfileSeedWaitMs")?.toLongOrNull() ?: 0)
    }

    @Test fun theNextStartDeletesIt() {
        assumeTrue(phase == "reconcile")
        requireMultiProfile()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val store = ProfileStore.getInstance()
            assertTrue("the seed phase's profile must survive the restart", store.allProfileNames.contains(name))
            reconcileArtifactProfiles(emptySet())
            assertFalse(store.allProfileNames.contains(name))
        }
    }

    @Test fun aNewHostsProfileNeverInheritsALostProfilesData() {
        assumeTrue(phase == "fresh")
        requireMultiProfile()
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val titles = LinkedBlockingQueue<String>()
        val interceptor = served()
        var view: WebView? = null
        instrumentation.runOnMainSync {
            view = createArtifactWebView(instrumentation.targetContext, "fresh-${UUID.randomUUID()}", ready = { it.loadUrl(interceptor.pageUrl) }).apply {
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                webViewClient = object : WebViewClient() {
                    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest) =
                        interceptor.shouldInterceptRequest(view, request)
                }
                webChromeClient = object : WebChromeClient() {
                    override fun onReceivedTitle(view: WebView, title: String) { titles.add(title) }
                }
            }
        }
        try {
            // The page's first script reports what the new profile handed it.
            val seen = generateSequence { titles.poll(10, TimeUnit.SECONDS) }.firstOrNull { it.startsWith("seen ") }
            assertEquals("seen cookie=", seen)
            var cookie: String? = "unread"
            instrumentation.runOnMainSync { cookie = WebViewCompat.getProfile(checkNotNull(view)).cookieManager.getCookie("http://127.0.0.1:5173/") }
            assertTrue("a new host's profile inherited cookies: $cookie", cookie.isNullOrEmpty())
        } finally {
            instrumentation.runOnMainSync { view?.destroy() }
            interceptor.close()
        }
    }

    private fun served() = ArtifactSftpInterceptor(TAB, "/site/index.html", ArtifactRemoteReader { _, _, _ ->
        "<!doctype html><title>loading</title><script>document.title = 'seen cookie=' + document.cookie</script>".toByteArray()
    })

    private fun requireMultiProfile() {
        var supported = false
        InstrumentationRegistry.getInstrumentation().runOnMainSync { supported = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) }
        // Run only when asked for, so an unsupported WebView must fail rather than skip.
        assertTrue("the installed WebView must support MULTI_PROFILE", supported)
    }

    private companion object {
        const val HOST = "restart-fixture"
        const val TAB = "restart-tab"
    }
}
