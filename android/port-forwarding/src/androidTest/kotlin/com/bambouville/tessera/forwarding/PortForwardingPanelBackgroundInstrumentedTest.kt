package com.bambouville.tessera.forwarding

import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * In a session the panel takes the terminal's place on the session's black
 * scaffold. In the light theme its dark header and intro text vanished into
 * that black until the panel painted its own page colour, as Files does.
 *
 * Host-free: nothing here opens an SSH session.
 */
@RunWith(AndroidJUnit4::class)
class PortForwardingPanelBackgroundInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun aLightPanelOnTheSessionsBlackScaffoldPaintsItsOwnPage() {
        var page = Color.Unspecified
        compose.setContent {
            TesseraTheme(darkTheme = false) {
                page = LocalTesseraTokens.current.bg
                Box(Modifier.fillMaxSize().background(Color.Black)) {
                    PortForwardingPanel(
                        rules = emptyList(),
                        states = emptyMap(),
                        onRulesChanged = {},
                        modifier = Modifier.fillMaxSize().testTag(TAG),
                    )
                }
            }
        }

        val shot = compose.onNodeWithTag(TAG).captureToImage().asAndroidBitmap()
        // The corner sits in the header's padding, under no text or control.
        assertNotEquals(Color.Black.toArgb(), page.toArgb())
        assertEquals(page.toArgb(), shot.getPixel(1, 1))
    }

    private companion object {
        const val TAG = "forwarding-panel"
    }
}
