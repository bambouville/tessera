package com.bambouville.tessera.feature.session

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.design.tesseraSystemAnimationsRemoved
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
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

@RunWith(AndroidJUnit4::class)
class AgentSessionIntegrationChromeInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun heldWarningRingsTheStatusDotAndRoutesThroughTheSwitcher() {
        var switcherOpened = 0
        var compact by mutableStateOf(true)
        compose.setContent {
            TesseraTheme {
                SessionChrome(
                    host = host,
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    compact = compact,
                    integrationStatus = warning,
                    integrationWarningVisible = true,
                    onOpenSwitcher = { switcherOpened += 1 },
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
            }
        }

        listOf(true, false).forEachIndexed { index, layout ->
            compact = layout
            assertRing(present = true)
            assertEquals(0, compose.onAllNodesWithTag("agent-integration-warning").fetchSemanticsNodes().size)
            assertEquals(
                listOf("$SESSION_SWITCHER_LABEL. Agent integration not installed"),
                switcherDescriptions(),
            )
            compose.onNodeWithTag("session-switcher-button").assertIsDisplayed().performClick()
            compose.runOnIdle { assertEquals("compact=$layout", index + 1, switcherOpened) }
        }
    }

    @Test fun unheldOrDisconnectedWarningShowsNoRing() {
        var visible by mutableStateOf(false)
        var state by mutableStateOf<SshSessionUiState>(SshSessionUiState.Connected)
        compose.setContent {
            TesseraTheme {
                SessionChrome(
                    host = host,
                    state = state,
                    filesOpen = false,
                    compact = true,
                    integrationStatus = warning,
                    integrationWarningVisible = visible,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
            }
        }

        assertRing(present = false)
        assertEquals(listOf(SESSION_SWITCHER_LABEL), switcherDescriptions())

        visible = true
        assertRing(present = true)

        // Amber already means "connecting"; the ring belongs to a live session.
        state = SshSessionUiState.Connecting
        assertRing(present = false)
        assertEquals(listOf(SESSION_SWITCHER_LABEL), switcherDescriptions())
    }

    @Test fun readySessionHasNoRingEvenIfTheCallerHeldAWarning() {
        compose.setContent {
            TesseraTheme {
                SessionChrome(
                    host = host,
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    compact = true,
                    integrationStatus = AgentSessionIntegrationStatus(
                        AgentSessionIntegrationKind.Ready,
                        AgentSessionKey("exact-live-session", 4),
                        showsWarning = false,
                    ),
                    integrationWarningVisible = true,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
            }
        }

        assertRing(present = false)
        assertEquals(0, compose.onAllNodesWithTag("agent-integration-warning").fetchSemanticsNodes().size)
    }

    @Test fun ringNeverMovesTheHostName() {
        var compact by mutableStateOf(true)
        var visible by mutableStateOf(false)
        compose.setContent {
            TesseraTheme {
                SessionChrome(
                    host = host,
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    compact = compact,
                    integrationStatus = warning,
                    integrationWarningVisible = visible,
                    onBack = {},
                    onConnect = {},
                    onPaste = {},
                    onToggleFiles = {},
                    onCloseSession = {},
                )
            }
        }

        listOf(true, false).forEach { layout ->
            compact = layout
            visible = false
            assertRing(present = false)
            val before = hostNameBounds()
            visible = true
            assertRing(present = true)
            assertEquals("compact=$layout", before, hostNameBounds())
        }
    }

    @Test fun ringRipplesOnOnsetThenHoldsStill() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeFalse("system animations are removed on this device", tesseraSystemAnimationsRemoved(context))
        var visible by mutableStateOf(false)
        compose.setContent {
            TesseraTheme {
                SessionChrome(
                    host = host,
                    state = SshSessionUiState.Connected,
                    filesOpen = false,
                    compact = true,
                    integrationStatus = warning,
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
        val withoutRing = rootPixels()

        compose.mainClock.autoAdvance = false
        visible = true
        compose.mainClock.advanceTimeByFrame()
        compose.mainClock.advanceTimeBy(200)
        val rippling = rootPixels()
        captureScreen("attention-ring-rippling")
        // Three 800 ms ripples, then nothing moves again.
        compose.mainClock.advanceTimeBy(3_000)
        val settled = rootPixels()
        captureScreen("attention-ring-settled")
        compose.mainClock.advanceTimeBy(2_000)
        val stillSettled = rootPixels()

        assertTrue("the steady ring must draw", differingPixels(withoutRing, settled) > 20)
        assertTrue("onset must ripple beyond the steady ring", differingPixels(rippling, settled) > 20)
        assertEquals("the ring must not keep blinking", 0, differingPixels(settled, stillSettled))
    }

    @Test fun switcherNoticeOpensItsDetailsApartFromItsAction() {
        var details = 0
        var actions = 0
        compose.setContent {
            TesseraTheme {
                SessionSwitcherSheet(
                    windows = emptyList(), activeWindowId = null, activePaneId = null,
                    sessions = emptyList(), currentSessionTitle = "fixture",
                    notice = SessionSwitcherNotice("Agent integration not installed", "Install it.", "Install"),
                    onNoticeAction = { actions += 1 },
                    onNoticeDetails = { details += 1 },
                    onHome = {}, onSelectSession = {}, onSelectWindow = {}, onSelectPane = {}, onNewWindow = {},
                    onRenameWindow = { _, _ -> }, onCloseWindow = {}, onMoveWindow = { _, _ -> },
                    onSplitPane = { _, _ -> }, onSetPaneZoomed = { _, _ -> }, onClosePane = {}, onDismiss = {},
                )
            }
        }

        compose.onNodeWithTag("session-switcher-notice-action").performClick()
        compose.runOnIdle { assertEquals(listOf(1, 0), listOf(actions, details)) }
        compose.onNodeWithTag("session-switcher-notice").performClick()
        compose.runOnIdle { assertEquals(listOf(1, 1), listOf(actions, details)) }
    }

    private fun assertRing(present: Boolean) {
        compose.waitForIdle()
        assertEquals(
            if (present) 1 else 0,
            compose.onAllNodesWithTag(SESSION_STATUS_ATTENTION_RING_TAG, useUnmergedTree = true)
                .fetchSemanticsNodes().size,
        )
    }

    private fun switcherDescriptions(): List<String> =
        compose.onNodeWithTag("session-switcher-button").fetchSemanticsNode()
            .config.getOrElse(SemanticsProperties.ContentDescription) { emptyList() }

    private fun hostNameBounds() = compose.onNodeWithText(host.displayName, useUnmergedTree = true)
        .fetchSemanticsNode().boundsInRoot

    private fun rootPixels(): IntArray = compose.onRoot().captureToImage().asAndroidBitmap().let { bitmap ->
        IntArray(bitmap.width * bitmap.height).also {
            bitmap.getPixels(it, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        }
    }

    private fun captureScreen(name: String) {
        // Public shell-owned evidence survives Gradle uninstalling the test APK.
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.executeShellCommand("mkdir -p /sdcard/Pictures/tessera-attention-ring").close()
        automation.executeShellCommand("screencap -p /sdcard/Pictures/tessera-attention-ring/$name.png")
            .let { descriptor -> android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes() } }
    }

    private companion object {
        fun differingPixels(first: IntArray, second: IntArray): Int {
            assertEquals(first.size, second.size)
            return first.indices.count { first[it] != second[it] }
        }

        val warning = AgentSessionIntegrationStatus(
            AgentSessionIntegrationKind.Missing,
            AgentSessionKey("exact-live-session", 4),
            showsWarning = true,
        )
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
