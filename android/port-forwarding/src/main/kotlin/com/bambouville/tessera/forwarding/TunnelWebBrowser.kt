package com.bambouville.tessera.forwarding

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.webkit.CookieManager
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.bambouville.tessera.core.bridge.SharedForwardedWebTarget
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraType

/**
 * The in-app browser a tunnel opens into, mirroring iOS
 * `Tessera/Forwarding/TunnelWebBrowser.swift`.
 *
 * A forwarded port is a web server the user already trusts but cannot reach
 * without leaving Tessera, so the page opens here rather than in Chrome: the
 * terminal stays one `done` away, and the chrome says which rule is being
 * browsed.
 *
 * Full-bleed on purpose — a platform-width dialog would give a dashboard or
 * notebook a fraction of a tablet's screen, and on a phone it would shrink the
 * page to a card.
 */
@Composable
fun TunnelWebBrowser(
    target: SharedForwardedWebTarget,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    ruleLabel: String = "",
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            // Edge to edge, so Compose sees the real window insets and
            // `safeDrawingPadding` below can keep the chrome clear of the
            // status and navigation bars. Left fitting, the dialog reports no
            // insets at all and the system clock is drawn over the address.
            //
            // Do not also reach for this window's `WindowInsetsController` to
            // style the bars. Bisected on an emulator: the moment this
            // composable touches the dialog window's insets controller, the
            // `AndroidView` WebView starts drawing over the chrome bar — the
            // page covers the only way back out, with every semantics
            // assertion still green. Bar contrast already comes from
            // `Theme.Tessera`, which pins `windowLightStatusBar=false` for the
            // dialog as well as the activity, so there was nothing to fix.
            decorFitsSystemWindows = false,
        ),
    ) {
        TunnelWebBrowserContent(
            target = target,
            onDismiss = onDismiss,
            modifier = modifier,
            ruleLabel = ruleLabel,
        )
    }
}

/**
 * The browser itself, outside any dialog, so a test (and a future split-pane
 * presentation) can host it directly.
 */
@Composable
internal fun TunnelWebBrowserContent(
    target: SharedForwardedWebTarget,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    ruleLabel: String = "",
) {
    val tokens = LocalTesseraTokens.current
    val state = remember(target.url) { TunnelBrowserState(target.url) }
    var webView by remember { mutableStateOf<WebView?>(null) }

    // Android's back gesture belongs to the page's history first; only an
    // exhausted history closes the browser, which is what every other Android
    // browser does.
    BackHandler(enabled = true) {
        val view = webView
        if (view != null && view.canGoBack()) view.goBack() else onDismiss()
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .background(tokens.bg)
            .safeDrawingPadding(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(tokens.panelBg)
                .padding(horizontal = 6.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            TesseraIconButton(
                icon = TesseraIcons.ChevronLeft,
                contentDescription = "back",
                onClick = { webView?.goBack() },
                enabled = state.canGoBack,
                modifier = Modifier.testTag("tunnel-browser-back"),
            )
            TesseraIconButton(
                icon = TesseraIcons.ChevronRight,
                contentDescription = "forward",
                onClick = { webView?.goForward() },
                enabled = state.canGoForward,
            )
            TesseraIconButton(
                icon = if (state.isLoading) TesseraIcons.Close else TesseraIcons.Refresh,
                contentDescription = if (state.isLoading) "stop" else "reload",
                onClick = {
                    val view = webView ?: return@TesseraIconButton
                    if (state.isLoading) view.stopLoading() else reload(view, state)
                },
            )

            Address(
                url = state.displayUrl,
                ruleLabel = ruleLabel,
                secure = target.isSecure,
                modifier = Modifier.weight(1f),
            )

            TesseraButton(
                text = "done",
                onClick = onDismiss,
                style = TesseraButtonStyle.Primary,
                compact = true,
                modifier = Modifier.testTag("tunnel-browser-done"),
            )
        }
        TesseraHairline()

        Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
            AndroidView(
                modifier = Modifier.fillMaxSize().testTag("tunnel-browser-web"),
                factory = { context ->
                    buildWebView(context, state).also {
                        webView = it
                        it.loadUrl(target.url)
                    }
                },
            )
            state.failure?.let { failure ->
                Failure(failure = failure, onRetry = { webView?.let { reload(it, state) } })
            }
        }
    }

    DisposableEffect(target.url) {
        onDispose {
            // Every tunnel presents as `127.0.0.1:<port>`, so leaving cookies
            // behind would hand a second host's page the first host's session
            // for the same port. WebView's store is process-global and nothing
            // else in Tessera uses one, so clearing it on the way out is the
            // closest thing to the ephemeral store iOS gets for free.
            CookieManager.getInstance().removeAllCookies(null)
            webView?.destroy()
            webView = null
        }
    }
}

@Composable
private fun Address(
    url: String,
    ruleLabel: String,
    secure: Boolean,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    Column(
        modifier = modifier
            .background(tokens.inputBg, RoundedCornerShape(7.dp))
            .border(1.dp, tokens.border, RoundedCornerShape(7.dp))
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                // Insecure is the normal case for a tunnel — the SSH channel is
                // the encryption — so the state is stated, never warned about.
                text = if (secure) "🔒 " else "⇄ ",
                style = TesseraType.rowMicro,
                color = tokens.fgMuted,
            )
            Text(
                text = url,
                style = TesseraType.rowMicro,
                color = tokens.fg,
                maxLines = 1,
                overflow = TextOverflow.MiddleEllipsis,
                modifier = Modifier.testTag("tunnel-browser-address"),
            )
        }
        if (ruleLabel.isNotBlank()) {
            Text(text = ruleLabel, style = TesseraType.rowMicro, color = tokens.fgMuted, maxLines = 1)
        }
    }
}

@Composable
private fun Failure(failure: String, onRetry: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    // A card over the content, not a scrim: a navigation that fails from a
    // page that loaded leaves that page underneath, which is what every
    // browser does and what iOS does here.
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier
                .widthIn(max = 420.dp)
                .background(tokens.panelBg, RoundedCornerShape(10.dp))
                .border(1.dp, tokens.border, RoundedCornerShape(10.dp))
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("this tunnel did not answer", style = TesseraType.section, color = tokens.fg)
            Text(
                text = failure,
                style = TesseraType.rowMicro,
                color = tokens.fgMuted,
                textAlign = TextAlign.Center,
            )
            Text(
                text = "check that the rule is listening and that the remote service is up.",
                style = TesseraType.rowMicro,
                color = tokens.fgDim,
                textAlign = TextAlign.Center,
            )
            TesseraButton(
                text = "retry",
                onClick = onRetry,
                style = TesseraButtonStyle.Primary,
                compact = true,
            )
        }
    }
}

/** Everything the chrome reads off the page. */
internal class TunnelBrowserState(initialUrl: String) {
    var canGoBack by mutableStateOf(false)
    var canGoForward by mutableStateOf(false)
    var isLoading by mutableStateOf(true)
    var displayUrl by mutableStateOf(initialUrl)
    var failure by mutableStateOf<String?>(null)
}

private fun reload(view: WebView, state: TunnelBrowserState) {
    state.failure = null
    view.reload()
}

@SuppressLint("SetJavaScriptEnabled")
private fun buildWebView(
    context: android.content.Context,
    state: TunnelBrowserState,
): WebView = WebView(context).apply {
    // No layout params of its own: `AndroidView` sizes the holder from the
    // Compose constraints and measures this view inside it, and a view that
    // brings its own MATCH_PARENT pair has once ended up covering the chrome
    // bar the user needs to get back out. (Re-tested against this layout after
    // the dialog was made edge to edge, those params alone no longer reproduce
    // it — the rule stands, the mechanism has moved, and the instrumented
    // test now guards the symptom rather than this one cause.)
    //
    // A forwarded dev server is an application, not a document: without
    // scripting and DOM storage most of them render an empty shell.
    settings.javaScriptEnabled = true
    settings.domStorageEnabled = true
    settings.useWideViewPort = true
    settings.loadWithOverviewMode = true
    webViewClient = object : WebViewClient() {
        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            state.isLoading = true
            state.displayUrl = url
            sync(view)
        }

        override fun onPageFinished(view: WebView, url: String) {
            state.isLoading = false
            state.displayUrl = url
            state.failure = null
            sync(view)
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            // Subresource failures are the page's problem, not the tunnel's;
            // only a failed main document means there is no page to show.
            if (!request.isForMainFrame) return
            state.isLoading = false
            state.failure = error.description?.toString() ?: "the connection failed"
            sync(view)
        }

        private fun sync(view: WebView) {
            state.canGoBack = view.canGoBack()
            state.canGoForward = view.canGoForward()
        }
    }
}
