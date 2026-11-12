package com.bambouville.tessera.feature.artifacts.viewers

import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.Profile
import androidx.webkit.ProfileStore
import androidx.webkit.WebStorageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraProgressTrack
import com.bambouville.tessera.design.TesseraType
import com.bambouville.tessera.feature.artifacts.R
import java.net.URI
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asExecutor

data class ArtifactWebViewState(
    val url: String,
    val title: String = "",
    val canGoBack: Boolean = false,
    val canGoForward: Boolean = false,
    val isLoading: Boolean = true,
    val progress: Int = 0,
    val failure: String? = null,
)

/** Remember one per viewer when the browser screen supplies its own chrome. Call on the UI thread. */
class ArtifactWebViewController {
    private var owner: Any? = null
    private var view: WebView? = null
    private var beforeReload: () -> Unit = {}
    private var afterStop: () -> Unit = {}

    fun goBack(): Boolean {
        val current = view ?: return false
        if (!current.canGoBack()) return false
        current.goBack()
        return true
    }

    fun goForward(): Boolean {
        val current = view ?: return false
        if (!current.canGoForward()) return false
        current.goForward()
        return true
    }

    fun reload() {
        beforeReload()
        view?.reload()
    }

    fun stopLoading() {
        val current = view ?: return
        current.stopLoading()
        afterStop()
    }

    internal fun attach(owner: Any, view: WebView, beforeReload: () -> Unit, afterStop: () -> Unit) {
        this.owner = owner
        this.view = view
        this.beforeReload = beforeReload
        this.afterStop = afterStop
    }

    internal fun discard(view: WebView) {
        // Keep reload available until this viewer's composition is disposed.
        if (this.view === view) this.view = null
    }

    internal fun detach(owner: Any) {
        if (this.owner !== owner) return
        this.owner = null
        this.view = null
        beforeReload = {}
        afterStop = {}
    }
}

/**
 * Embeddable page content, with no dialog or system-bar ownership. A forwarded
 * page uses its leased http://127.0.0.1:<port> URL; an HTML file uses
 * [ArtifactSftpInterceptor.pageUrl]. The caller retains the forwarding lease.
 * Exhausted history falls through to the screen's back handler unless [onBack]
 * is supplied. Hide these controls and pass a remembered [controller] when the
 * browser screen draws its own chrome. Remember the interceptor for the tab;
 * changing it or the controller recreates the WebView. Another [url] on the
 * same origin keeps the WebView and its history: a new [navigation] value
 * loads it, as the address bar does.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun ArtifactWebView(
    url: String,
    hostId: String,
    modifier: Modifier = Modifier,
    interceptor: ArtifactSftpInterceptor? = null,
    reloadToken: Long = 0L,
    navigation: Long = 0L,
    showControls: Boolean = true,
    controller: ArtifactWebViewController? = null,
    onTitleChanged: (String) -> Unit = {},
    onStateChanged: (ArtifactWebViewState) -> Unit = {},
    onBack: (() -> Unit)? = null,
) {
    val titleChanged by rememberUpdatedState(onTitleChanged)
    val stateChanged by rememberUpdatedState(onStateChanged)
    val back by rememberUpdatedState(onBack)
    val tokens = LocalTesseraTokens.current

    key(hostId, artifactWebViewOrigin(url), interceptor, controller) {
        val initialUrl = remember { url }
        val owner = remember { Any() }
        var pageInterceptor by remember { mutableStateOf(interceptor?.copyForWebView()) }
        var state by remember { mutableStateOf(ArtifactWebViewState(url)) }
        var webView by remember { mutableStateOf<WebView?>(null) }
        // Recovery waits for an explicit reload or for the tab to be shown again.
        var rendererGone by remember { mutableStateOf(false) }
        var generation by remember { mutableIntStateOf(0) }
        var appliedReloadToken by remember { mutableLongStateOf(reloadToken) }
        // The address this viewer last loaded for the store: the store moves it
        // to another path (or loads one again) by a new url or navigation.
        var applied by remember { mutableStateOf(url to navigation) }

        fun publish(value: ArtifactWebViewState) {
            state = value
            stateChanged(value)
        }

        fun sync(view: WebView) {
            if (webView !== view) return
            publish(state.copy(
                url = view.url ?: state.url,
                canGoBack = view.canGoBack(),
                canGoForward = view.canGoForward(),
            ))
        }

        fun beforeReload() {
            if (rendererGone) {
                pageInterceptor = interceptor?.copyForWebView()
                generation++
                rendererGone = false
            }
            pageInterceptor?.resetReadGeneration()
            publish(state.copy(failure = null, isLoading = true, progress = 0))
        }

        LaunchedEffect(reloadToken) {
            if (appliedReloadToken != reloadToken) {
                appliedReloadToken = reloadToken
                beforeReload()
                webView?.reload()
            }
        }

        LaunchedEffect(navigation, url) {
            if (applied == (url to navigation)) return@LaunchedEffect
            applied = url to navigation
            publish(state.copy(url = url, failure = null, isLoading = true, progress = 0))
            // A gone renderer comes back on the new address; a live one loads it into its history.
            if (rendererGone) beforeReload() else webView?.loadUrl(url)
        }

        BackHandler(enabled = state.canGoBack || onBack != null) {
            val view = webView
            if (view != null && view.canGoBack()) view.goBack() else back?.invoke()
        }

        Column(modifier.fillMaxSize().background(tokens.bg).imePadding()) {
            if (showControls) {
                Row(
                    Modifier.fillMaxWidth().background(tokens.panelBg).padding(horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    TesseraIconButton(
                        TesseraIcons.ChevronLeft, stringResource(R.string.artifacts_back), { webView?.goBack() },
                        enabled = state.canGoBack,
                        modifier = Modifier.testTag("artifact-web-back"),
                    )
                    TesseraIconButton(
                        TesseraIcons.ChevronRight, stringResource(R.string.artifacts_forward), { webView?.goForward() },
                        enabled = state.canGoForward,
                    )
                    TesseraIconButton(
                        if (state.isLoading) TesseraIcons.Close else TesseraIcons.Refresh,
                        stringResource(if (state.isLoading) R.string.artifacts_stop else R.string.artifacts_reload),
                        {
                            if (state.isLoading) {
                                pageInterceptor?.resetReadGeneration()
                                webView?.stopLoading()
                                publish(state.copy(isLoading = false))
                            } else {
                                beforeReload()
                                webView?.reload()
                            }
                        },
                    )
                    Text(
                        state.url,
                        Modifier.weight(1f).padding(horizontal = 8.dp).testTag("artifact-web-address"),
                        style = TesseraType.rowMicro,
                        color = tokens.fgMuted,
                        maxLines = 1,
                        overflow = TextOverflow.MiddleEllipsis,
                    )
                }
                TesseraHairline()
            }
            Box(Modifier.fillMaxWidth().height(3.dp)) {
                if (state.isLoading) TesseraProgressTrack(state.progress / 100f)
            }
            state.failure?.let { failure ->
                Text(
                    failure,
                    Modifier.fillMaxWidth().background(tokens.panelBg).padding(12.dp),
                    style = TesseraType.bodySmall,
                    color = tokens.fgMuted,
                )
            }
            key(generation) {
                if (!rendererGone) AndroidView(
                    modifier = Modifier.fillMaxWidth().weight(1f).testTag("artifact-web-content"),
                    factory = { context ->
                        val activeInterceptor = pageInterceptor
                        createArtifactWebView(context, hostId, ready = { view ->
                            // A disposed tab's view is already destroyed. The
                            // address may have moved on while the profile was set up.
                            if (webView === view) view.loadUrl(state.url)
                        }).apply {
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            settings.useWideViewPort = true
                            settings.loadWithOverviewMode = true
                            settings.allowFileAccess = false
                            settings.allowContentAccess = false
                            CookieManager.getInstance().setAcceptThirdPartyCookies(this, false)
                            webChromeClient = object : WebChromeClient() {
                                // Native JavaScript panels own separate windows and
                                // can cover the activity's app-lock overlay.
                                override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean {
                                    result.cancel()
                                    return true
                                }

                                override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean {
                                    result.cancel()
                                    return true
                                }

                                override fun onJsPrompt(view: WebView, url: String, message: String, defaultValue: String?, result: JsPromptResult): Boolean {
                                    result.cancel()
                                    return true
                                }

                                // Leaving is never vetoed, as in WebKit without a panel delegate.
                                override fun onJsBeforeUnload(view: WebView, url: String, message: String, result: JsResult): Boolean {
                                    result.confirm()
                                    return true
                                }

                                override fun onReceivedTitle(view: WebView, title: String?) {
                                    if (webView !== view) return
                                    val learned = title.orEmpty()
                                    publish(state.copy(title = learned))
                                    if (learned.isNotBlank()) titleChanged(learned)
                                }

                                override fun onProgressChanged(view: WebView, newProgress: Int) {
                                    if (webView !== view) return
                                    publish(state.copy(progress = newProgress.coerceIn(0, 100)))
                                }
                            }
                            webViewClient = object : WebViewClient() {
                                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                                    activeInterceptor?.intercept(request.url.toString(), request.method, request.isForMainFrame)

                                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                                    if (webView !== view) return true
                                    when (artifactWebNavigation(initialUrl, request.url.toString(), request.isForMainFrame, request.hasGesture())) {
                                        ArtifactWebNavigation.InPage -> return false
                                        ArtifactWebNavigation.Blocked -> {
                                            publish(state.copy(failure = view.context.getString(R.string.artifacts_link_failed)))
                                            return true
                                        }
                                        ArtifactWebNavigation.External -> Unit
                                    }
                                    try {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, request.url).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                                    } catch (_: ActivityNotFoundException) {
                                        publish(state.copy(failure = view.context.getString(R.string.artifacts_no_app_for_link)))
                                    } catch (_: SecurityException) {
                                        publish(state.copy(failure = view.context.getString(R.string.artifacts_link_failed)))
                                    }
                                    return true
                                }

                                override fun onPageStarted(view: WebView, address: String, favicon: Bitmap?) {
                                    if (webView !== view) return
                                    publish(state.copy(url = address, isLoading = true, progress = 0, failure = null))
                                    sync(view)
                                }

                                override fun onPageFinished(view: WebView, address: String) {
                                    if (webView !== view) return
                                    publish(state.copy(url = address, isLoading = false, progress = 100))
                                    sync(view)
                                }

                                override fun doUpdateVisitedHistory(view: WebView, address: String, isReload: Boolean) {
                                    sync(view)
                                }

                                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                                    if (webView !== view || !request.isForMainFrame) return
                                    publish(state.copy(isLoading = false, failure = error.description?.toString() ?: view.context.getString(R.string.artifacts_page_no_answer)))
                                    sync(view)
                                }

                                override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) {
                                    if (webView !== view || !request.isForMainFrame) return
                                    publish(state.copy(isLoading = false, failure = view.context.getString(R.string.artifacts_page_returned, response.statusCode)))
                                    sync(view)
                                }

                                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                                    if (webView !== view) return true
                                    webView = null
                                    controller?.discard(view)
                                    activeInterceptor?.close()
                                    rendererGone = true
                                    publish(state.copy(canGoBack = false, canGoForward = false, isLoading = false,
                                        progress = 0, failure = view.context.getString(R.string.artifacts_page_no_answer)))
                                    discardArtifactWebRenderer(view, detail)
                                    return true
                                }
                            }
                            // AndroidView owns measurement, as in TunnelWebBrowserContent.
                            // MATCH_PARENT params here can cover the Compose chrome.
                            webView = this
                            controller?.attach(
                                owner,
                                this,
                                beforeReload = ::beforeReload,
                                afterStop = {
                                    pageInterceptor?.resetReadGeneration()
                                    publish(state.copy(isLoading = false))
                                },
                            )
                        }
                    },
                )
            }
        }

        DisposableEffect(Unit) {
            onDispose {
                pageInterceptor?.close()
                controller?.detach(owner)
                val view = webView
                webView = null
                if (view != null) {
                    view.stopLoading()
                    view.webChromeClient = null
                    (view.parent as? ViewGroup)?.removeView(view)
                    view.removeAllViews()
                    view.destroy()
                }
            }
        }
    }
}

/** The scheme and authority one viewer serves; any other part of the address may change under it. */
internal fun artifactWebViewOrigin(url: String): String = runCatching {
    val uri = URI(url)
    if (uri.scheme == null || uri.rawAuthority == null) url else "${uri.scheme.lowercase(Locale.ROOT)}://${uri.rawAuthority}"
}.getOrDefault(url)

/** A dead renderer must leave the hierarchy before WebView is destroyed. */
internal fun discardArtifactWebRenderer(view: WebView, detail: RenderProcessGoneDetail) {
    Log.w("artifacts", "artifacts_web_renderer_gone: crashed=${detail.didCrash()}")
    (view.parent as? ViewGroup)?.removeView(view)
    view.destroy()
}

/**
 * UI thread only. Assign the host profile before touching settings, cookies,
 * or navigation. [ready] runs on a later UI turn, once the profile may load a page.
 */
internal fun createArtifactWebView(context: Context, hostId: String, ready: (WebView) -> Unit): WebView {
    require(hostId.isNotBlank())
    val view = WebView(context)
    val main = Handler(Looper.getMainLooper())
    if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
        val store = ProfileStore.getInstance()
        val name = ARTIFACT_PROFILE_PREFIX + hostId
        // getProfile cannot ask: some WebView builds throw for a missing name.
        val created = name !in store.allProfileNames
        val profile = store.getOrCreateProfile(name)
        WebViewCompat.setProfile(view, profile.name)
        // WebView saves its profile list on a timer. After a process death
        // before that save, a new profile can be handed the lost profile's
        // directory, with another host's cookies, storage and cache. No page
        // of that profile loads until they are gone, including later tabs.
        pendingArtifactProfilePurges[name]?.let { waiting ->
            waiting += { ready(view) }
            return view
        }
        if (created) {
            view.clearCache(true)
            pendingArtifactProfilePurges[name] = mutableListOf({ ready(view) })
            clearArtifactProfileData(profile) { pendingArtifactProfilePurges.remove(name)?.forEach { it() } }
            return view
        }
    } else if (artifactProfileFallbackLogged.compareAndSet(false, true)) {
        Log.w("artifacts", "artifacts_web_profile_unavailable: MULTI_PROFILE is not supported")
    }
    main.post { ready(view) }
    return view
}

/**
 * UI thread only. WebView never unloads a profile this process has used, so a
 * loaded profile cannot be deleted before the next start. Its cookies and
 * storage go now; the next start's reconciliation deletes the profile itself.
 */
fun deleteArtifactProfile(hostId: String) {
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return
    deleteArtifactProfiles(ChromiumArtifactProfiles, listOf(hostId))
}

/** UI thread only. Call at startup with every saved host's ID, before any artifacts WebView loads. */
fun reconcileArtifactProfiles(liveHostIds: Set<String>) {
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return
    reconcileArtifactProfiles(ChromiumArtifactProfiles, liveHostIds)
}

internal interface ArtifactProfileStore {
    val names: List<String>
    /** Throws IllegalStateException while this process has the profile loaded. */
    fun delete(name: String)
    fun clearData(name: String)
}

internal fun reconcileArtifactProfiles(store: ArtifactProfileStore, liveHostIds: Set<String>) {
    val orphans = store.names.filter { it.startsWith(ARTIFACT_PROFILE_PREFIX) }
        .map { it.removePrefix(ARTIFACT_PROFILE_PREFIX) }
        .filter { it.isNotEmpty() && it !in liveHostIds }
    deleteArtifactProfiles(store, orphans)
}

internal fun deleteArtifactProfiles(store: ArtifactProfileStore, hostIds: Collection<String>) {
    for (hostId in hostIds) {
        val name = ARTIFACT_PROFILE_PREFIX + hostId
        try {
            store.delete(name)
        } catch (_: IllegalStateException) {
            try { store.clearData(name) } catch (_: RuntimeException) {}
        } catch (_: RuntimeException) {
        }
    }
}

private object ChromiumArtifactProfiles : ArtifactProfileStore {
    override val names: List<String> get() {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return emptyList()
        return ProfileStore.getInstance().allProfileNames
    }
    override fun delete(name: String) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return
        ProfileStore.getInstance().deleteProfile(name)
    }
    override fun clearData(name: String) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return
        val store = ProfileStore.getInstance()
        if (name in store.allProfileNames) clearArtifactProfileData(store.getOrCreateProfile(name))
    }
}

/** UI thread only. [done] runs on the UI thread once cookies and storage are gone. */
private fun clearArtifactProfileData(profile: Profile, done: () -> Unit = {}) {
    if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return done()
    val cookies = profile.cookieManager
    val main = Handler(Looper.getMainLooper())
    val pending = AtomicInteger(2)
    val finished = Runnable {
        if (pending.decrementAndGet() != 0) return@Runnable
        // flush() blocks on disk, so it never runs on the UI thread.
        Dispatchers.IO.asExecutor().execute { cookies.flush() }
        main.post(done)
    }
    profile.geolocationPermissions.clearAll()
    cookies.removeAllCookies { finished.run() }
    if (WebViewFeature.isFeatureSupported(WebViewFeature.DELETE_BROWSING_DATA)) {
        WebStorageCompat.deleteBrowsingData(profile.webStorage, finished)
    } else {
        // Without this feature, storage deletion has no completion signal.
        profile.webStorage.deleteAllData()
        finished.run()
    }
}

private const val ARTIFACT_PROFILE_PREFIX = "artifacts-"
// UI thread only: readiness callbacks waiting for a new profile's purge.
private val pendingArtifactProfilePurges = mutableMapOf<String, MutableList<() -> Unit>>()
private val artifactProfileFallbackLogged = AtomicBoolean(false)

internal enum class ArtifactWebNavigation { InPage, External, Blocked }

internal fun artifactWebNavigation(initialUrl: String, targetUrl: String, mainFrame: Boolean, hasGesture: Boolean): ArtifactWebNavigation {
    val target = runCatching { URI(targetUrl) }.getOrNull() ?: return ArtifactWebNavigation.Blocked
    val scheme = target.scheme?.lowercase(Locale.ROOT)
    if (!mainFrame) return if (scheme in setOf("http", "https")) ArtifactWebNavigation.InPage else ArtifactWebNavigation.Blocked
    if (artifactSameOrigin(initialUrl, targetUrl)) return ArtifactWebNavigation.InPage
    if (artifactDeviceLocalHost(artifactUrlHost(target))) return ArtifactWebNavigation.Blocked
    // Web pages cannot use file/content/intent/javascript links to reach app
    // storage or intent extras. A script also cannot launch an external app.
    return if (hasGesture && scheme in setOf("http", "https", "mailto", "tel", "sms", "geo")) ArtifactWebNavigation.External
        else ArtifactWebNavigation.Blocked
}

internal fun artifactSameOrigin(first: String, second: String): Boolean = runCatching {
    val a = URI(first)
    val b = URI(second)
    fun port(value: URI) = if (value.port >= 0) value.port else if (value.scheme.equals("https", true)) 443 else 80
    a.host != null && b.host != null && a.scheme.equals(b.scheme, true) && a.host.equals(b.host, true) && port(a) == port(b)
}.getOrDefault(false)
