package com.bambouville.tessera.feature.session

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.core.bridge.SharedTmuxWindow
import com.bambouville.tessera.design.TesseraTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real pointer arbitration on the production tablet strip, with no host connection. */
@RunWith(AndroidJUnit4::class)
class TmuxWindowOrderingUiInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private var originalHardwareKeyboardImeSetting: String? = null

    @After fun restoreKeyboardPreference() {
        val original = originalHardwareKeyboardImeSetting ?: return
        shell(if (original == "null") "settings delete secure show_ime_with_hard_keyboard"
            else "settings put secure show_ime_with_hard_keyboard $original")
    }

    private fun shell(command: String): String =
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)
            .let { descriptor -> android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use {
                it.readBytes().toString(Charsets.UTF_8).trim()
            } }

    @Test fun inactiveWindowSplitMenuAndAccessibilityCarryAllFourDirections() {
        val pane = com.bambouville.tessera.core.bridge.SharedTmuxPane(12, null, "sh", true)
        val window = SharedTmuxWindow(7, 2, "inactive", 12, listOf(pane), false, null)
        val calls = mutableListOf<Triple<Int, Boolean, Boolean>>()
        var allowed by mutableStateOf(true)
        compose.setContent {
            TesseraTheme {
                Surface(Modifier.systemBarsPadding()) {
                    TmuxChrome(windows = listOf(window), activeWindowId = 9, activeWindow = null,
                        allowsWindowOrdering = allowed,
                        onSelectWindow = {}, onNewWindow = {}, onRenameWindow = {}, onCloseWindow = {},
                        onMoveWindow = { _, _ -> }, onSplit = { _, _ -> }, onZoom = { _, _ -> },
                        onSelectPane = {}, onClosePane = {},
                        onSplitWindow = { id, vertical, before -> calls += Triple(id, vertical, before) })
                }
            }
        }
        compose.waitUntil(5_000) { compose.activity.hasWindowFocus() }
        val node = compose.onNodeWithText("1:inactive")
        val labels = listOf("Split Right", "Split Left", "Split Down", "Split Up")
        labels.forEach { label ->
            val actions = node.fetchSemanticsNode().config[SemanticsActions.CustomActions]
            compose.runOnIdle { assertTrue(actions.single { it.label == label }.action()) }
        }
        compose.runOnIdle { assertEquals(listOf(Triple(7, false, false), Triple(7, false, true), Triple(7, true, false), Triple(7, true, true)), calls) }
        node.performTouchInput { longClick(durationMillis = 850) }
        labels.forEach { compose.onNodeWithText(it).assertIsDisplayed() }
        capture("tablet-inactive-split-menu")
        compose.onNodeWithText("Split Left").performClick()
        compose.runOnIdle { assertEquals(Triple(7, false, true), calls.last()); allowed = false }
        assertTrue(node.fetchSemanticsNode().config[SemanticsActions.CustomActions].none { it.label in labels })
    }

    @Test fun dragCommitsOnceWithoutSelectingAndHoldOpensMenu() {
        var windows by mutableStateOf((1..3).map { id ->
            SharedTmuxWindow(id, id * 3, "window$id", null, emptyList(), false, null)
        })
        var commits = 0
        var selections = 0
        compose.setContent {
            TesseraTheme {
                Surface(Modifier.systemBarsPadding()) {
                    TmuxChrome(
                        windows = windows, activeWindowId = 2, activeWindow = null,
                        onSelectWindow = { selections++ }, onNewWindow = {},
                        onRenameWindow = {}, onCloseWindow = {},
                        onMoveWindow = { id, destination ->
                            commits++
                            windows = windows.toMutableList().apply {
                                add(destination, removeAt(indexOfFirst { it.id == id }))
                            }
                        },
                        onSplit = { _, _ -> }, onZoom = { _, _ -> },
                        onSelectPane = {}, onClosePane = {},
                    )
                }
            }
        }
        compose.waitForIdle()
        compose.waitUntil(5_000) { compose.activity.hasWindowFocus() }
        compose.onNodeWithText("1:window1").assertIsDisplayed()
        capture("tablet-before")
        val source = compose.onNodeWithText("1:window1").fetchSemanticsNode().boundsInRoot
        val target = compose.onNodeWithText("3:window3").fetchSemanticsNode().boundsInRoot
        // An active edge-scroll coroutine intentionally keeps Compose busy.
        // Inject through UiAutomation so the held capture does not require idle
        // before the finger can be released.
        val screenOrigin = IntArray(2)
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            compose.activity.findViewById<android.view.View>(android.R.id.content).getLocationOnScreen(screenOrigin)
        }
        val downTime = android.os.SystemClock.uptimeMillis()
        fun inject(action: Int, point: Offset) {
            val event = android.view.MotionEvent.obtain(downTime, android.os.SystemClock.uptimeMillis(), action,
                point.x + screenOrigin[0], point.y + screenOrigin[1], 0)
            event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            assertTrue(InstrumentationRegistry.getInstrumentation().uiAutomation.injectInputEvent(event, true))
            event.recycle()
        }
        inject(android.view.MotionEvent.ACTION_DOWN, source.center)
        android.os.SystemClock.sleep(320)
        inject(android.view.MotionEvent.ACTION_MOVE, Offset(source.center.x + 40f, source.center.y))
        android.os.SystemClock.sleep(32)
        val destination = Offset(target.right - 2f, target.center.y)
        inject(android.view.MotionEvent.ACTION_MOVE, destination)
        android.os.SystemClock.sleep(180)
        InstrumentationRegistry.getInstrumentation().runOnMainSync { assertEquals(0, commits) }
        capture("tablet-during-drag")
        inject(android.view.MotionEvent.ACTION_UP, destination)
        compose.waitUntil(5_000) { commits == 1 }
        compose.runOnIdle {
            assertEquals(listOf(2, 3, 1), windows.map { it.id })
            assertEquals(0, selections)
        }
        capture("tablet-after-drag")
        compose.onNodeWithText("3:window1").performTouchInput { longClick(durationMillis = 850) }
        compose.onNodeWithText("Move to start").assertIsDisplayed()
        capture("tablet-menu")
        compose.onNodeWithText("Move to start").performClick()
        compose.runOnIdle {
            assertEquals(listOf(1, 2, 3), windows.map { it.id })
            assertEquals(2, commits)
            assertEquals(0, selections)
        }
    }

    @Test fun compactSwitcherDragPreservesActiveAndExposesMenuAndAccessibilityMoves() {
        fun window(id: Int, position: Int) = SessionSwitcherWindow(
            id = id,
            index = id * 3,
            position = position,
            title = "$position:window$id",
            renameSeed = "window$id",
            panes = emptyList(),
            zoomed = false,
        )
        var windows by mutableStateOf((1..3).map { window(it, it) })
        val activeWindowId = 2
        var commits = 0
        var selections = 0
        compose.setContent {
            TesseraTheme {
                SessionSwitcherSheet(
                    windows = windows,
                    activeWindowId = activeWindowId,
                    activePaneId = null,
                    sessions = emptyList(),
                    currentSessionTitle = "fixture",
                    allowsTmuxMutation = true,
                    onHome = {},
                    onSelectSession = {},
                    onSelectWindow = { selections++ },
                    onSelectPane = {},
                    onNewWindow = {},
                    onRenameWindow = { _, _ -> },
                    onCloseWindow = {},
                    onMoveWindow = { id, destination ->
                        commits++
                        windows = windows.toMutableList().apply {
                            add(destination, removeAt(indexOfFirst { it.id == id }))
                        }.mapIndexed { index, entry -> window(entry.id, index + 1) }
                    },
                    onSplitPane = { _, _ -> },
                    onSetPaneZoomed = { _, _ -> },
                    onClosePane = {},
                    onDismiss = {},
                )
            }
        }
        // This fixture owns its disposable emulator. Keep the IME visible
        // even when the emulator advertises a hardware keyboard.
        originalHardwareKeyboardImeSetting = shell("settings get secure show_ime_with_hard_keyboard")
        shell("settings put secure show_ime_with_hard_keyboard 1")
        compose.onNodeWithTag("session-switcher-query").performClick()
        // InputMethodManager's requested visibility can precede the actual
        // dialog resize. Observe delivered window insets before testing layout.
        compose.waitUntil(5_000) {
            var insetVisible = false
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                insetVisible = android.view.inspector.WindowInspector.getGlobalWindowViews().any { view ->
                    val insets = view.rootWindowInsets
                    insets != null && insets.isVisible(android.view.WindowInsets.Type.ime()) &&
                        insets.getInsets(android.view.WindowInsets.Type.ime()).bottom > 0
                }
            }
            insetVisible
        }
        // IME insets animate outside Compose's test clock. Wait for the
        // platform transition before capturing bounds or injecting a drag.
        android.os.SystemClock.sleep(400)
        compose.waitForIdle()
        capture("compact-before")
        if (compose.activity.resources.configuration.orientation ==
            android.content.res.Configuration.ORIENTATION_LANDSCAPE
        ) {
            // The hidden peer is what exposed clipped item bounds sorting
            // before the pointer and incorrectly turning this into an end move.
            compose.onNodeWithText("3:window3").assertIsNotDisplayed()
        }
        compose.onNodeWithText("1:window1").assertIsDisplayed()
        val source = compose.onNodeWithText("1:window1").fetchSemanticsNode().boundsInRoot
        compose.onNodeWithText("2:window2").assertIsDisplayed()
        val target = compose.onNodeWithText("2:window2").fetchSemanticsNode().boundsInRoot
        val dialogRoot = compose.onNode(isRoot() and hasAnyDescendant(hasText("1:window1")))
        dialogRoot.performTouchInput {
            down(source.center)
            advanceEventTime(320)
            moveTo(Offset(source.center.x, source.center.y + 25f), delayMillis = 32)
            // The IME clips the second row on landscape tablets. Its visible
            // bottom crosses the full row midpoint while remaining touchable.
            moveTo(Offset(target.center.x, target.bottom - 2f), delayMillis = 180)
            up()
        }
        compose.waitUntil(5_000) { commits == 1 }
        compose.runOnIdle {
            assertEquals(listOf(2, 1, 3), windows.map { it.id })
            assertEquals(2, activeWindowId)
            assertEquals(0, selections)
        }
        val movedNode = compose.onNodeWithText("2:window1")
        movedNode.assertIsDisplayed()
        capture("compact-after-drag")

        val actions = movedNode.fetchSemanticsNode().config[SemanticsActions.CustomActions]
        assertTrue(actions.any { it.label == "Move to start" })
        assertTrue(actions.any { it.label == "Move up" })
        assertTrue(actions.none { it.label == "Move left" || it.label == "Move right" })
        movedNode.performTouchInput { longClick(durationMillis = 850) }
        compose.onNodeWithText("Move to start").assertIsDisplayed()
        compose.onNodeWithText("Move up").assertIsDisplayed()
        compose.onNodeWithText("Move down").assertIsDisplayed()
        capture("compact-menu")
        compose.onNodeWithText("Move to start").performClick()
        compose.runOnIdle {
            assertEquals(listOf(1, 2, 3), windows.map { it.id })
            assertEquals(2, commits)
            assertEquals(0, selections)
        }
    }

    @Test fun shortHoldAndImmediateSwipeNeverCommitAReorder() {
        val windows = (1..3).map { id ->
            SharedTmuxWindow(id, id * 3, "window$id", null, emptyList(), false, null)
        }
        var commits = 0
        var selections = 0
        compose.setContent {
            TesseraTheme {
                Surface(Modifier.systemBarsPadding()) {
                    TmuxChrome(
                        windows = windows, activeWindowId = 2, activeWindow = null,
                        onSelectWindow = { selections++ }, onNewWindow = {},
                        onRenameWindow = {}, onCloseWindow = {},
                        onMoveWindow = { _, _ -> commits++ },
                        onSplit = { _, _ -> }, onZoom = { _, _ -> },
                        onSelectPane = {}, onClosePane = {},
                    )
                }
            }
        }
        compose.onNodeWithText("1:window1").assertIsDisplayed()
        val source = compose.onNodeWithText("1:window1").fetchSemanticsNode().boundsInRoot

        compose.onRoot().performTouchInput {
            down(source.center)
            advanceEventTime(350)
            up()
        }
        compose.runOnIdle {
            assertEquals(0, commits)
            assertEquals(1, selections)
        }
        compose.onAllNodesWithText("Move to start").assertCountEquals(0)

        compose.onRoot().performTouchInput {
            down(source.center)
            moveTo(Offset(source.center.x + 30f, source.center.y), delayMillis = 32)
            moveTo(Offset(source.center.x + 100f, source.center.y), delayMillis = 32)
            up()
        }
        compose.runOnIdle {
            assertEquals(0, commits)
            assertEquals(1, selections)
        }
    }

    @Test fun scrolledStripCanDragThenOpenMenu() {
        var windows by mutableStateOf((1..20).map { id -> SharedTmuxWindow(id, id * 3, "window$id", null, emptyList(), false, null) })
        var commits = 0
        compose.setContent {
            TesseraTheme {
                Surface(Modifier.systemBarsPadding()) {
                    TmuxChrome(windows = windows, activeWindowId = 2, activeWindow = null,
                        onSelectWindow = {}, onNewWindow = {}, onRenameWindow = {}, onCloseWindow = {},
                        onMoveWindow = { id, destination ->
                            commits++
                            windows = windows.toMutableList().apply { add(destination, removeAt(indexOfFirst { it.id == id })) }
                        }, onSplit = { _, _ -> }, onZoom = { _, _ -> }, onSelectPane = {}, onClosePane = {})
                }
            }
        }
        compose.onNodeWithText("20:window20").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("1:window1").assertIsNotDisplayed()
        val source = compose.onNodeWithText("20:window20").fetchSemanticsNode().boundsInRoot
        val target = compose.onNodeWithText("19:window19").fetchSemanticsNode().boundsInRoot
        capture("strip-scrolled-before")
        compose.onRoot().performTouchInput {
            down(source.center)
            advanceEventTime(350)
            moveTo(Offset(source.center.x - 40f, source.center.y), delayMillis = 32)
            moveTo(Offset(target.center.x - 5f, target.center.y), delayMillis = 180)
            up()
        }
        compose.waitUntil(5_000) { commits == 1 }
        compose.runOnIdle { assertEquals(18, windows.indexOfFirst { it.id == 20 }) }
        compose.onNodeWithText("19:window20").performScrollTo().performTouchInput { longClick(durationMillis = 850) }
        compose.onNodeWithText("Move to end").assertIsDisplayed()
        capture("strip-scrolled-menu")
    }

    @Test fun scrolledSwitcherCanOpenMoveMenu() {
        val windows = (1..20).map { SessionSwitcherWindow(it, it * 3, it, "$it:window$it", "window$it", emptyList(), false) }
        compose.setContent {
            TesseraTheme {
                SessionSwitcherSheet(windows = windows, activeWindowId = 1, activePaneId = null,
                    sessions = emptyList(), currentSessionTitle = "fixture", allowsTmuxMutation = true,
                    onHome = {}, onSelectSession = {}, onSelectWindow = {}, onSelectPane = {}, onNewWindow = {},
                    onRenameWindow = { _, _ -> }, onCloseWindow = {}, onMoveWindow = { _, _ -> },
                    onSplitPane = { _, _ -> }, onSetPaneZoomed = { _, _ -> }, onClosePane = {}, onDismiss = {})
            }
        }
        compose.onNodeWithText("20:window20").performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("1:window1").assertIsNotDisplayed()
        compose.onNodeWithText("20:window20").performTouchInput { longClick(durationMillis = 850) }
        compose.onNodeWithText("Move to start").assertIsDisplayed()
        capture("switcher-scrolled-menu")
    }

    private fun capture(name: String) {
        // Public shell-owned evidence survives Gradle uninstalling the test APK.
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        automation.executeShellCommand("mkdir -p /sdcard/Pictures/tessera-window-ordering").close()
        automation.executeShellCommand("screencap -p /sdcard/Pictures/tessera-window-ordering/$name.png")
            .let { descriptor -> android.os.ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { it.readBytes() } }
    }
}
