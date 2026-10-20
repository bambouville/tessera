package com.bambouville.tessera.feature.session

import androidx.activity.ComponentActivity
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.forwarding.ForwardingChromePresentation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The glyph is gated in both bars, so both are asserted: the compact phone bar
 * and the wide tablet bar build their trailing controls from separate `when`
 * arms and a gate added to one has been missed on the other before. The same
 * goes for its colour and read-out, which say whether anything is serving.
 */
@RunWith(AndroidJUnit4::class)
class SessionForwardingChromeInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun compactSessionWithoutForwardingRulesShowsNoTunnelGlyph() {
        compose.setContent {
            TesseraTheme {
                SessionChrome(
                    host = host,
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    compact = true,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
            }
        }

        assertEquals(0, compose.onAllNodesWithTag(TAG).fetchSemanticsNodes().size)
    }

    @Test fun wideSessionWithoutForwardingRulesShowsNoTunnelGlyph() {
        compose.setContent {
            TesseraTheme {
                SessionChrome(
                    host = host,
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    compact = false,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
            }
        }

        assertEquals(0, compose.onAllNodesWithTag(TAG).fetchSemanticsNodes().size)
    }

    @Test fun aConfiguredSessionKeepsTheGlyphAndItsToggle() {
        var toggles = 0
        compose.setContent {
            TesseraTheme {
                SessionChrome(
                    host = host,
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    compact = true,
                    forwarding = ForwardingChromePresentation(visible = true, activeCount = 1),
                    onToggleForwarding = { toggles += 1 },
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
            }
        }

        compose.onNodeWithTag(TAG).assertIsDisplayed().performClick()
        compose.runOnIdle { assertEquals(1, toggles) }
    }

    @Test fun compactServingGlyphTurnsGreenAndReadsOutWhatServes() {
        showChrome(
            compact = true,
            forwarding = ForwardingChromePresentation(visible = true, activeCount = 2, servingCount = 1),
        )

        compose.onNodeWithTag(TAG).assertContentDescriptionEquals("2 active tunnels, 1 serving")
        assertTrue("the serving glyph is not green", greenGlyphPixels() > 0)
    }

    @Test fun wideServingGlyphTurnsGreenAndReadsOutWhatServes() {
        showChrome(
            compact = false,
            forwarding = ForwardingChromePresentation(visible = true, activeCount = 1, servingCount = 1),
        )

        compose.onNodeWithTag(TAG).assertContentDescriptionEquals("1 active tunnels, 1 serving")
        assertTrue("the serving glyph is not green", greenGlyphPixels() > 0)
    }

    /**
     * A listener that is up but unconfirmed is not green, and neither is an
     * open panel: its highlight is the panel's alone, and the glyph colour
     * says only whether something answers behind a tunnel.
     */
    @Test fun anUnconfirmedTunnelKeepsThePlainGlyphEvenWithThePanelOpen() {
        showChrome(
            compact = true,
            forwardingOpen = true,
            forwarding = ForwardingChromePresentation(visible = true, activeCount = 2),
        )

        compose.onNodeWithTag(TAG).assertContentDescriptionEquals("2 active tunnels")
        assertEquals(0, greenGlyphPixels())
    }

    @Test fun wideUnconfirmedTunnelKeepsThePlainGlyph() {
        showChrome(
            compact = false,
            forwarding = ForwardingChromePresentation(visible = true, activeCount = 1),
        )

        compose.onNodeWithTag(TAG).assertContentDescriptionEquals("1 active tunnels")
        assertEquals(0, greenGlyphPixels())
    }

    private var green: Color = Color.Unspecified

    private fun showChrome(
        compact: Boolean,
        forwarding: ForwardingChromePresentation,
        forwardingOpen: Boolean = false,
    ) {
        compose.setContent {
            TesseraTheme {
                green = LocalTesseraTokens.current.green
                SessionChrome(
                    host = host,
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    forwardingOpen = forwardingOpen,
                    compact = compact,
                    forwarding = forwarding,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
            }
        }
        compose.waitUntil(timeoutMillis = 15_000) {
            compose.onAllNodesWithTag(TAG).fetchSemanticsNodes(atLeastOneRootRequired = false).size == 1
        }
    }

    /**
     * Pixels of the glyph's own bounds that are the token green. Its bounds
     * only: the connection dot beside it is the same green while connected.
     */
    private fun greenGlyphPixels(): Int {
        val shot = compose.onNodeWithTag(TAG).captureToImage().asAndroidBitmap()
        val target = green.toArgb()
        val red = (target shr 16) and 0xFF
        val greenChannel = (target shr 8) and 0xFF
        val blue = target and 0xFF
        var hits = 0
        for (x in 0 until shot.width) {
            for (y in 0 until shot.height) {
                val pixel = shot.getPixel(x, y)
                if (kotlin.math.abs(((pixel shr 16) and 0xFF) - red) <= 24 &&
                    kotlin.math.abs(((pixel shr 8) and 0xFF) - greenChannel) <= 24 &&
                    kotlin.math.abs((pixel and 0xFF) - blue) <= 24
                ) {
                    hits++
                }
            }
        }
        return hits
    }

    private companion object {
        const val TAG = "session-forwarding-button"

        val host = SavedHost(
            id = "fixture-host",
            displayName = "fixture",
            hostname = "fixture.invalid",
            port = 22,
            username = "dev",
            jumpHostId = null,
            identityId = null,
            tmuxMode = TmuxModes.OFF,
        )
    }
}
