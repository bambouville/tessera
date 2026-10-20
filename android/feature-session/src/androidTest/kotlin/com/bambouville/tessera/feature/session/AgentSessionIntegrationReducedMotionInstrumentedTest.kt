package com.bambouville.tessera.feature.session

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onRoot
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationKind
import com.bambouville.tessera.agent.platform.AgentSessionIntegrationStatus
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.data.SavedHost
import com.bambouville.tessera.data.TmuxModes
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** With the system's animations removed the ring appears steady at once. */
@RunWith(AndroidJUnit4::class)
class AgentSessionIntegrationReducedMotionInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>(
        object : MotionDurationScale {
            override val scaleFactor: Float = 0f
        },
    )

    @Test fun removedAnimationsShowOnlyTheSteadyRing() {
        var visible by mutableStateOf(false)
        compose.setContent {
            TesseraTheme {
                SessionChrome(
                    host = SavedHost(
                        id = "fixture-host",
                        displayName = "fixture",
                        hostname = "fixture.invalid",
                        port = 22,
                        username = "dev",
                        jumpHostId = null,
                        identityId = null,
                        tmuxMode = TmuxModes.OFF,
                    ),
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    compact = true,
                    integrationStatus = AgentSessionIntegrationStatus(
                        AgentSessionIntegrationKind.Outdated,
                        AgentSessionKey("exact-live-session", 4),
                        showsWarning = true,
                    ),
                    integrationWarningVisible = visible,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
            }
        }
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        visible = true
        compose.mainClock.advanceTimeByFrame()
        val onset = rootPixels()
        compose.mainClock.advanceTimeBy(200)
        val early = rootPixels()
        compose.mainClock.advanceTimeBy(3_000)
        val settled = rootPixels()

        assertEquals(
            1,
            compose.onAllNodesWithTag(SESSION_STATUS_ATTENTION_RING_TAG, useUnmergedTree = true)
                .fetchSemanticsNodes().size,
        )
        assertEquals(0, onset.indices.count { onset[it] != settled[it] })
        assertEquals(0, early.indices.count { early[it] != settled[it] })
    }

    private fun rootPixels(): IntArray = compose.onRoot().captureToImage().asAndroidBitmap().let { bitmap ->
        IntArray(bitmap.width * bitmap.height).also {
            bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        }
    }
}
