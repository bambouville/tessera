package com.bambouville.tessera.feature.artifacts.viewers

import android.webkit.WebView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ArtifactWebProfileTest {
    @Test fun reconcilingAnOrphanThisProcessLoadedClearsItsDataAndKeepsLiveAndUnrelatedProfiles() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var supported = false
        instrumentation.runOnMainSync { supported = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) }
        assumeTrue("the installed WebView must support MULTI_PROFILE", supported)
        val orphan = "test-orphan-${UUID.randomUUID()}"
        val live = "test-live-${UUID.randomUUID()}"
        val unrelated = "test-other-${UUID.randomUUID()}"
        val url = "http://127.0.0.1:5173/"
        instrumentation.runOnMainSync {
            val store = ProfileStore.getInstance()
            val previousHosts = store.allProfileNames.filter { it.startsWith("artifacts-") }.map { it.removePrefix("artifacts-") }
            for (name in listOf("artifacts-$orphan", "artifacts-$live", unrelated)) {
                store.getOrCreateProfile(name).cookieManager.setCookie(url, "session=$name; Path=/")
            }
            // WebView cannot delete a profile this process has loaded; this must not throw.
            reconcileArtifactProfiles((previousHosts + live).toSet())
            assertTrue(store.allProfileNames.contains("artifacts-$live"))
            assertTrue(store.allProfileNames.contains(unrelated))
        }
        awaitMain(instrumentation) { ProfileStore.getInstance().getProfile("artifacts-$orphan")?.cookieManager?.getCookie(url) == null }
        instrumentation.runOnMainSync {
            val store = ProfileStore.getInstance()
            assertTrue(checkNotNull(store.getProfile("artifacts-$live")).cookieManager.getCookie(url).orEmpty().contains("session=artifacts-$live"))
            assertTrue(checkNotNull(store.getProfile(unrelated)).cookieManager.getCookie(url).orEmpty().contains("session=$unrelated"))
            deleteArtifactProfile(live)
        }
    }

    @Test fun aHostProfileIsAssignedBeforeTheFirstLoadAndSharedOnlyByThatHost() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var supported = false
        instrumentation.runOnMainSync { supported = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) }
        assumeTrue("the installed WebView must support MULTI_PROFILE", supported)
        val firstHost = "test-${UUID.randomUUID()}"
        val secondHost = "test-${UUID.randomUUID()}"
        val views = mutableListOf<WebView>()
        val readied = mutableListOf<WebView>()
        try {
            instrumentation.runOnMainSync {
                val first = createArtifactWebView(instrumentation.targetContext, firstHost, ready = { readied += it }).also(views::add)
                val second = createArtifactWebView(instrumentation.targetContext, secondHost, ready = { readied += it }).also(views::add)
                val anotherTab = createArtifactWebView(instrumentation.targetContext, firstHost, ready = { readied += it }).also(views::add)
                // Navigation waits for a later UI turn, after the caller's settings.
                assertTrue(readied.isEmpty())
                assertNull(first.url)
                assertNull(second.url)
                assertEquals("artifacts-$firstHost", WebViewCompat.getProfile(first).name)
                assertEquals("artifacts-$secondHost", WebViewCompat.getProfile(second).name)
                assertEquals("artifacts-$firstHost", WebViewCompat.getProfile(anotherTab).name)
                val firstCookies = WebViewCompat.getProfile(first).cookieManager
                firstCookies.setCookie("http://127.0.0.1:5173/", "session=host-a; Path=/")
                firstCookies.flush()
                assertTrue(WebViewCompat.getProfile(anotherTab).cookieManager.getCookie("http://127.0.0.1:8080/").orEmpty().contains("session=host-a"))
                assertFalse(WebViewCompat.getProfile(second).cookieManager.getCookie("http://127.0.0.1:8080/").orEmpty().contains("session=host-a"))
                // Deleting a host while its WebViews live must safely defer it.
                deleteArtifactProfile(firstHost)
                assertEquals("artifacts-$firstHost", WebViewCompat.getProfile(first).name)
            }
            awaitMain(instrumentation) { readied.toSet() == views.toSet() }
        } finally {
            instrumentation.runOnMainSync {
                views.forEach(WebView::destroy)
                deleteArtifactProfile(firstHost)
                deleteArtifactProfile(secondHost)
                deleteArtifactProfile("missing-${UUID.randomUUID()}")
            }
        }
    }

    @Test fun everyViewOfANewProfileWaitsForItsPurge() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var supported = false
        instrumentation.runOnMainSync { supported = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) }
        assumeTrue("the installed WebView must support MULTI_PROFILE", supported)
        val host = "test-${UUID.randomUUID()}"
        val order = mutableListOf<String>()
        val views = mutableListOf<WebView>()
        try {
            instrumentation.runOnMainSync {
                views += createArtifactWebView(instrumentation.targetContext, host, ready = { order += "first" })
                views += createArtifactWebView(instrumentation.targetContext, host, ready = { order += "second" })
            }
            awaitMain(instrumentation) { order.size == 2 }
            // The second tab joins the first tab's purge instead of loading at once.
            assertEquals(listOf("first", "second"), order)
            instrumentation.runOnMainSync {
                views += createArtifactWebView(instrumentation.targetContext, host, ready = { order += "after" })
            }
            awaitMain(instrumentation) { order.size == 3 }
        } finally {
            instrumentation.runOnMainSync {
                views.forEach(WebView::destroy)
                deleteArtifactProfile(host)
            }
        }
    }

    @Test fun unsupportedProvidersStillCreateAWebViewWithoutClearingCookies() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        var supported = false
        instrumentation.runOnMainSync { supported = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE) }
        assumeTrue("this branch requires a WebView without MULTI_PROFILE", !supported)
        instrumentation.runOnMainSync {
            val cookies = android.webkit.CookieManager.getInstance()
            val origin = "https://${UUID.randomUUID()}.example.invalid/"
            cookies.setCookie(origin, "session=kept; Path=/")
            cookies.flush()
            val view = createArtifactWebView(instrumentation.targetContext, "legacy", ready = {})
            try {
                assertNull(view.url)
                deleteArtifactProfile("legacy")
                reconcileArtifactProfiles(emptySet())
                assertTrue(cookies.getCookie(origin).orEmpty().contains("session=kept"))
            } finally {
                view.destroy()
                cookies.setCookie(origin, "session=; Max-Age=0; Path=/")
            }
        }
    }

    private fun awaitMain(instrumentation: android.app.Instrumentation, condition: () -> Boolean) {
        val deadline = android.os.SystemClock.uptimeMillis() + 5_000
        while (true) {
            var met = false
            instrumentation.runOnMainSync { met = condition() }
            if (met) return
            check(android.os.SystemClock.uptimeMillis() < deadline) { "condition not met within 5 s" }
            Thread.sleep(50)
        }
    }
}
