package com.bambouville.tessera.forwarding

import android.util.Log
import androidx.activity.ComponentActivity
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.design.TesseraTheme
import java.io.BufferedReader
import java.net.InetAddress
import java.net.ServerSocket
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The tunnel browse action, end to end, against a real loopback HTTP server.
 *
 * The server is the point: the `WebView` reaches it over a genuine TCP socket
 * with a cleartext URL, so the test covers the network security config and the
 * WebView wiring rather than a fixture. Its request counter is the oracle —
 * a browser that presented but never fetched leaves it at zero.
 *
 * Host-free: nothing here opens an SSH session.
 */
@RunWith(AndroidJUnit4::class)
class TunnelWebBrowserInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private var server: LoopbackWebServer? = null

    @After fun tearDown() {
        server?.close()
    }

    @Test fun onlyALiveBrowsableTunnelOffersAPageAndOpeningItFetchesOne() {
        val served = LoopbackWebServer().also { server = it }
        val port = served.port

        val web = rule(port = port, target = 3_000, label = "dev server")
        val postgres = rule(port = 15_432, target = 5_432, label = "postgres")
        val idle = rule(port = 9_090, target = 9_090, label = "metrics")

        compose.setContent {
            TesseraTheme {
                PortForwardingPanel(
                    rules = listOf(web, postgres, idle),
                    states = mapOf(
                        web.id to PortForwardingState(web, listening(port)),
                        postgres.id to PortForwardingState(postgres, listening(15_432)),
                        idle.id to PortForwardingState(idle, PortForwardingStatus.Idle),
                    ),
                    onRulesChanged = {},
                )
            }
        }

        // Read the panel only once it has a first frame. An assertion about what
        // is *absent* is answered the same way by a hierarchy that has not come
        // up yet, so the presence of the browsable rule is what gates the rest.
        awaitTagCount("tunnel-open-$port", 1)

        // Postgres is refused by the shared policy (the target port names the
        // service); the idle rule is addressable but has no listener behind it.
        assertEquals(
            0,
            compose.onAllNodesWithTag("tunnel-open-15432").fetchSemanticsNodes().size,
        )
        assertEquals(
            0,
            compose.onAllNodesWithTag("tunnel-open-9090").fetchSemanticsNodes().size,
        )

        compose.onNodeWithTag("tunnel-open-$port").assertIsDisplayed().performClick()

        // The browser lives in its own window. While that window attaches there
        // is a gap in which the registry holds no resumed compose root at all,
        // and an assertion landing in it fails with "No compose hierarchies
        // found" — the dialog's absence read as the app's. Wait for the chrome
        // with roots optional instead of asserting across the swap.
        awaitTagCount("tunnel-browser-address", 1)

        compose.onNodeWithTag("tunnel-browser-address").assertIsDisplayed()
        compose.onNodeWithTag("tunnel-browser-web").assertIsDisplayed()

        // Where Compose put the page: below the chrome, never behind it.
        val chromeBottom = compose.onNodeWithTag("tunnel-browser-back")
            .fetchSemanticsNode().boundsInWindow.bottom
        val pageTop = compose.onNodeWithTag("tunnel-browser-web")
            .fetchSemanticsNode().boundsInWindow.top
        assertTrue(
            "the page (top=$pageTop) overlaps the chrome bar (bottom=$chromeBottom)",
            pageTop >= chromeBottom,
        )

        compose.waitUntil(timeoutMillis = 20_000) { served.requests.get() > 0 }
        assertTrue("the browser never fetched the page", served.requests.get() > 0)

        // And where the window actually drew it. `AndroidView` hands a real
        // View to the window, and this WebView has twice ended up painting
        // over the chrome — once carrying its own MATCH_PARENT layout params,
        // once after the composable touched the dialog window's insets
        // controller — each time with every assertion above still green,
        // because semantics know nothing about what covers what.
        //
        // So the fixture paints itself a colour Tessera's palette never uses
        // and the pixels answer directly: that colour must appear where the
        // page belongs and nowhere in the chrome. Asking instead whether the
        // chrome "looks flat" is not an oracle — a page with any texture of
        // its own satisfies it while covering the bar, which a deliberate
        // 240px offset proved on this emulator.
        assertTrue(
            "the page did not render where the browser put it",
            signaturePixels("tunnel-browser-web") > 0,
        )

        // Sampled over a window, not once: the WebView paints its first frames
        // at its own full size before Compose's layout pass places it, so one
        // early capture reads that transient as the permanent bug. A real
        // occlusion never clears and still fails here.
        var attempts = 0
        var bleed = signaturePixels("tunnel-browser-address")
        while (bleed > 0 && attempts < 40) {
            attempts++
            Thread.sleep(250)
            compose.waitForIdle()
            bleed = signaturePixels("tunnel-browser-address")
        }
        Log.i(TAG, "chrome bar cleared after $attempts resample(s), bleed=$bleed")
        assertTrue(
            "the page is drawing over the chrome bar ($bleed page pixels in it)",
            bleed == 0,
        )

        // Hold the rendered page on screen so the runner's screencap loop has
        // something to record; the assertions above are the gate, this is the
        // evidence.
        Thread.sleep(4_000)

        compose.onNodeWithTag("tunnel-browser-done").performClick()
        // Dismissal crosses the same window boundary in the other direction.
        awaitTagCount("tunnel-browser-web", 0)
        assertEquals(
            0,
            compose.onAllNodesWithTag("tunnel-browser-web").fetchSemanticsNodes().size,
        )
    }

    /**
     * How many pixels of [tag]'s own region are the fixture page's signature
     * colour. Sampled with a tolerance because the WebView's colour management
     * does not hand back the exact bytes the page asked for.
     */
    private fun signaturePixels(tag: String): Int {
        val shot = compose.onNodeWithTag(tag).captureToImage().asAndroidBitmap()
        var hits = 0
        for (x in 0 until shot.width step 2) {
            for (y in 0 until shot.height step 2) {
                val pixel = shot.getPixel(x, y)
                val red = (pixel shr 16) and 0xFF
                val green = (pixel shr 8) and 0xFF
                val blue = pixel and 0xFF
                if (red > 200 && green < 60 && blue > 200) hits++
            }
        }
        return hits
    }

    /** Waits for a tag to reach [count] nodes without requiring a root to exist yet. */
    private fun awaitTagCount(tag: String, count: Int) {
        compose.waitUntil(timeoutMillis = 15_000) {
            compose.onAllNodesWithTag(tag)
                .fetchSemanticsNodes(atLeastOneRootRequired = false)
                .size == count
        }
    }

    private fun listening(port: Int) = PortForwardingStatus.Listening(
        BoundForwardEndpoint(host = "127.0.0.1", port = port),
    )

    private companion object {
        const val TAG = "TunnelBrowserTest"
    }

    private fun rule(port: Int, target: Int, label: String) = PortForwardRule(
        id = UUID.randomUUID(),
        direction = PortForwardDirection.LOCAL,
        bind = PortForwardEndpoint("127.0.0.1", port),
        target = PortForwardEndpoint("localhost", target),
        label = label,
    )
}

/**
 * Stands where a forwarded port's listener would stand. Port 0 so a rerun
 * never collides with a socket the previous one has in TIME_WAIT.
 */
private class LoopbackWebServer : AutoCloseable {
    private val socket = ServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
    val port: Int get() = socket.localPort
    val requests = AtomicInteger(0)

    init {
        thread(isDaemon = true, name = "tunnel-browser-fixture") {
            while (!socket.isClosed) {
                try {
                    socket.accept().use { client ->
                        val reader = BufferedReader(client.getInputStream().reader())
                        // Drain the request head; the body is never used.
                        while (true) {
                            val line = reader.readLine() ?: break
                            if (line.isEmpty()) break
                        }
                        requests.incrementAndGet()
                        val body = BODY
                        client.getOutputStream().apply {
                            write(
                                (
                                    "HTTP/1.1 200 OK\r\n" +
                                        "Content-Type: text/html; charset=utf-8\r\n" +
                                        "Content-Length: ${body.toByteArray().size}\r\n" +
                                        "Connection: close\r\n\r\n" + body
                                    ).toByteArray(),
                            )
                            flush()
                        }
                    }
                } catch (_: Exception) {
                    // A closed socket during teardown is the normal exit.
                }
            }
        }
    }

    override fun close() {
        socket.close()
    }

    private companion object {
        const val BODY = "<!doctype html><meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" +
            // Magenta on purpose: no Tessera surface, token or terminal theme
            // uses it, so any of it inside the chrome bar's own bounds is the
            // page drawing where it must not.
            "<style>body{font:16px system-ui;margin:0;padding:32px;background:#ff00ff;color:#101014}" +
            "h1{font-size:22px;margin:0 0 6px}code{font-family:monospace;color:#201040}</style>" +
            "<h1>tunnelled dev server</h1>" +
            "<div>served over loopback at <code>/</code></div>"
    }
}
