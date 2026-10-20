package com.bambouville.tessera

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.files.SharedUriIngress
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SessionHarnessInstrumentedTest {
    @get:Rule
    val compose = createAndroidComposeRule<TesseraHarnessActivity>()

    @Test
    fun accessoryDefaultsScrollWhenNeededWhileKeyboardToggleStaysFixed() {
        // The production row is shared by phones and tablets. A phone starts
        // with the tail off-screen while a tablet may fit all default keys, but
        // both sizes must keep the keyboard action outside the scrollable row.
        compose.onNodeWithTag("accessory-key-keyboard").assertIsDisplayed()

        compose.onNodeWithTag("accessory-key-ctrlJ").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("accessory-key-keyboard").assertIsDisplayed()
    }

    @Test
    fun settingsAccessoryPreviewScrollsAndTapRemoveUpdatesPalette() {
        compose.onNodeWithTag("harness-settings").performScrollTo().performClick()
        compose.onNodeWithTag("accessory-editor-preview").performScrollTo()

        val preview = compose.onNodeWithTag("accessory-editor-preview")
        val range = preview.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange]
        val beforeScroll = range.value()
        if (range.maxValue() > beforeScroll) {
            compose.onNodeWithTag("accessory-editor-preview").performTouchInput { swipeLeft() }
            compose.waitUntil(timeoutMillis = 5_000) {
                preview.fetchSemanticsNode().config[SemanticsProperties.HorizontalScrollAxisRange].value() > beforeScroll
            }
        }

        val paletteEscape = compose.onNodeWithTag("accessory-editor-palette-key-esc")
        paletteEscape.assertIsNotEnabled()
        compose.onNodeWithTag("accessory-editor-preview-key-esc").performScrollTo().performClick()
        paletteEscape.assertIsEnabled()
    }

    @Test
    fun settingsAccessoryLongPressReordersWithoutBecomingAScroll() {
        compose.onNodeWithTag("harness-settings").performScrollTo().performClick()
        compose.onNodeWithTag("accessory-editor-preview").performScrollTo()
        val escape = compose.onNodeWithTag("accessory-editor-preview-key-esc")
        val control = compose.onNodeWithTag("accessory-editor-preview-key-ctrl")
        assertTrue(escape.fetchSemanticsNode().boundsInRoot.left < control.fetchSemanticsNode().boundsInRoot.left)

        // One whole slot plus a margin, measured rather than assumed: the drag
        // now reorders when the lifted chip's centre crosses its neighbour's,
        // so a fixed pixel constant would pass on one screen density and fail
        // on the next.
        val slot = control.fetchSemanticsNode().boundsInRoot.left -
            escape.fetchSemanticsNode().boundsInRoot.left
        escape.performTouchInput {
            down(center)
            advanceEventTime(700)
            moveBy(Offset(slot * 1.2f, 0f), delayMillis = 100)
            up()
        }
        compose.waitUntil(timeoutMillis = 5_000) {
            escape.fetchSemanticsNode().boundsInRoot.left > control.fetchSemanticsNode().boundsInRoot.left
        }
    }

    @Test
    fun keyboardButtonShowsAndHidesSoftwareKeyboard() {
        if (compose.onAllNodesWithContentDescription("Hide keyboard").fetchSemanticsNodes().isNotEmpty()) {
            compose.onNodeWithContentDescription("Hide keyboard").performClick()
            waitForKeyboard(visible = false)
        }

        waitForControlDisplayed("Show keyboard")
        compose.onNodeWithContentDescription("Show keyboard").performClick()
        waitForKeyboard(visible = true)
        waitForControlDisplayed("Hide keyboard")
        compose.onNodeWithContentDescription("Hide keyboard").performClick()
        waitForKeyboard(visible = false)
        waitForControlDisplayed("Show keyboard")
    }

    @Test
    fun accessoryKeyTapLeavesSoftwareKeyboardVisibilityAlone() {
        // Keyboard visibility belongs to the rightmost tile alone. An arrow tap
        // with the keyboard down must send its bytes without summoning it, and
        // the same tap with the keyboard up must not dismiss it.
        hideKeyboardIfShown()
        compose.onNodeWithTag("accessory-key-left").performScrollTo().performClick()
        assertKeyboardVisibilityHolds(visible = false)

        showKeyboard()
        compose.onNodeWithTag("accessory-key-left").performScrollTo().performClick()
        assertKeyboardVisibilityHolds(visible = true)
    }

    @Test
    fun noResizeFreshCursorKeepsGridAndCancelsTerminalLift() {
        selectFixture("fresh")
        val before = viewportProbe()
        showKeyboard()
        compose.waitUntil(timeoutMillis = 10_000) {
            val probe = viewportProbe()
            val ime = probeValue(probe, "ime")
            ime > 0 && probeValue(probe, "counter") == ime
        }

        val after = viewportProbe()
        assertEquals(probeValue(before, "rows"), probeValue(after, "rows"))
        assertEquals(probeValue(before, "columns"), probeValue(after, "columns"))
        assertTrue(probeValue(after, "cursor") in 0 until probeValue(after, "rows"))

        hideKeyboard()
        val restored = viewportProbe()
        assertEquals(probeValue(before, "rows"), probeValue(restored, "rows"))
        assertEquals(0, probeValue(restored, "counter"))
    }

    @Test
    fun noResizeMiddleAndTailUsePartialAndFullTerminalLiftsWithoutGridChange() {
        selectFixture("middle")
        val middleBefore = viewportProbe()
        showKeyboard()
        compose.waitUntil(timeoutMillis = 10_000) {
            val probe = viewportProbe()
            val ime = probeValue(probe, "ime")
            ime > 0 && probeValue(probe, "counter") in 1 until ime
        }
        val middleAfter = viewportProbe()
        assertEquals(probeValue(middleBefore, "rows"), probeValue(middleAfter, "rows"))
        assertEquals(probeValue(middleBefore, "columns"), probeValue(middleAfter, "columns"))
        hideKeyboard()

        selectFixture("tail")
        val tailBefore = viewportProbe()
        showKeyboard()
        compose.waitUntil(timeoutMillis = 10_000) {
            val probe = viewportProbe()
            probeValue(probe, "ime") > 0
        }
        val tailAfter = viewportProbe()
        assertEquals(probeValue(tailBefore, "rows"), probeValue(tailAfter, "rows"))
        assertEquals(probeValue(tailBefore, "columns"), probeValue(tailAfter, "columns"))
        assertTrue(probeValue(tailAfter, "cursor") >= probeValue(tailAfter, "rows") - 2)
        assertTrue(
            "bottom cursor must retain more of the IME lift than the middle cursor: $tailAfter",
            probeValue(tailAfter, "counter") < probeValue(tailAfter, "ime"),
        )
        hideKeyboard()
    }

    @Test
    fun alternateFixtureKeepsFullLiftAndBottomStatusMode() {
        selectFixture("alt")
        showKeyboard()
        compose.waitUntil(timeoutMillis = 10_000) {
            val probe = viewportProbe()
            probeValue(probe, "ime") > 0 &&
                probeValue(probe, "counter") == 0 &&
                probeFlag(probe, "alt")
        }
        val after = viewportProbe()
        assertEquals(1, probeValue(after, "cursor"))
        assertEquals("alt", probeText(after, "fixture"))
        hideKeyboard()
    }

    /**
     * Mouse reporting alone is not a full-screen app. The mosh+tmux visible client sits on the
     * primary screen with tmux's `mouse on` in force and still scrolls locally, so its prompt
     * follows the caret like any shell; the full lift used to push that prompt off the top of
     * the screen. Only the shared scroll route's alternate-screen verdict keeps the whole lift.
     */
    @Test
    fun mouseFixtureOnPrimaryScreenFollowsTheCaret() {
        selectFixture("mouse")
        showKeyboard()
        // The canvas cancels as much of the lift as the blank rows below the
        // caret allow; on a short landscape tablet that is less than the whole
        // IME, so the oracle is the caret's own row staying on screen, not a
        // full cancel. The old full lift (counter 0) pushes it off the top.
        awaitProbe("mouse fixture keeps its caret row on screen") { probe ->
            val ime = probeValue(probe, "ime")
            val counter = probeValue(probe, "counter")
            ime > 0 && probeFlag(probe, "mouse") && counter > 0 &&
                ime - counter <= probeValue(probe, "caretTop")
        }
        val after = viewportProbe()
        assertEquals(1, probeValue(after, "cursor"))
        assertEquals("mouse", probeText(after, "fixture"))
        hideKeyboard()
    }

    @Test
    fun resizeOnChangesAndRestoresDirectTerminalRows() {
        selectFixture("fresh")
        // The debug-only control starts off, matching the shipping default.
        compose.onNodeWithTag("harness-resize-terminal").performScrollTo().performClick()
        val before = viewportProbe()
        showKeyboard()
        awaitProbe("keyboard shrinks the direct terminal from $before") { probe ->
            probeValue(probe, "ime") > 0 && probeValue(probe, "rows") < probeValue(before, "rows")
        }
        hideKeyboard()
        awaitProbe("hidden keyboard restores the direct terminal to $before") { probe ->
            probeValue(probe, "rows") == probeValue(before, "rows")
        }
    }

    @Test
    fun peerAuthorityAndLaunchRecoveryRemainReachableOnPhone() {
        compose.onNodeWithTag("harness-tmux-peer").performScrollTo().performClick()
        compose.onNodeWithText("continued on iPad").assertIsDisplayed()
        compose.onNodeWithText("take back control").assertIsDisplayed()
        compose.onNodeWithTag("continued-elsewhere-surface").performClick()
        compose.onNodeWithText("taking back control…").assertIsDisplayed()

        compose.onNodeWithTag("harness-launch-failed").performScrollTo().performClick()
        compose.onNodeWithText("connection failed").assertIsDisplayed()
        compose.onNodeWithText("edit host").assertIsDisplayed()
        compose.onNodeWithText("retry").assertIsDisplayed()
        compose.onNodeWithText("back").assertIsDisplayed()
    }

    @Test
    fun textOnlyShareIsCapturedAsTextRatherThanDropped() {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            clipData = ClipData.newPlainText("shared text", "https://example.com/a")
        }

        val payload = SharedUriIngress.from(intent)

        assertEquals("https://example.com/a", payload?.text)
        assertTrue(payload?.uris.orEmpty().isEmpty())
    }

    @Test
    fun sharedTextLosesTheControlCharactersAPtyWouldExecute() {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, "  rm -rf /tmp/x\n\u0007  ")
        }

        // A trailing newline would submit the line the moment it is typed.
        assertEquals("rm -rf /tmp/x", SharedUriIngress.from(intent)?.text)
    }

    @Test
    fun aMultiLineShareBecomesOneLineWithItsWordsStillSeparated() {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, "cd /srv\napt update\n")
        }

        // Dropping the newline outright would paste "cd /srvapt update".
        assertEquals("cd /srv apt update", SharedUriIngress.from(intent)?.text)
    }

    @Test
    fun aCaptionAlongsideASharedFileIsNotMistakenForTheShare() {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            clipData = ClipData.newRawUri("photo", Uri.parse("content://media/external/images/1"))
            putExtra(Intent.EXTRA_TEXT, "look at this")
        }

        val payload = SharedUriIngress.from(intent)

        assertEquals(1, payload?.uris?.size)
        assertNull(payload?.text)
    }

    @Test
    fun anIntentThatCarriesNeitherFilesNorTextIsIgnored() {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            clipData = ClipData.newPlainText("shared text", "   ")
        }

        assertNull(SharedUriIngress.from(intent))
    }

    @Test
    fun asecondShareAppendsItsFilesInsteadOfReplacingTheFirst() {
        val first = SharedUriIngress.Payload(
            uris = listOf(Uri.parse("content://media/external/images/1")),
        )
        val second = SharedUriIngress.Payload(
            uris = listOf(Uri.parse("content://media/external/images/2")),
        )

        assertEquals(2, SharedUriIngress.append(first, second).uris.size)
    }

    /**
     * Samples across the IME's animation window: a show or hide that only
     * starts a few frames after the tap must not pass as "unchanged".
     */
    private fun assertKeyboardVisibilityHolds(visible: Boolean, millis: Long = 1_500) {
        val deadline = SystemClock.uptimeMillis() + millis
        do {
            compose.waitForIdle()
            assertEquals(
                "an accessory key tap must leave software keyboard visibility alone",
                visible,
                keyboardVisible(),
            )
            SystemClock.sleep(50)
        } while (SystemClock.uptimeMillis() < deadline)
    }

    private fun keyboardVisible(): Boolean =
        ViewCompat.getRootWindowInsets(compose.activity.window.decorView)
            ?.isVisible(WindowInsetsCompat.Type.ime()) == true

    private fun waitForKeyboard(visible: Boolean) {
        compose.waitUntil(timeoutMillis = 10_000) {
            val insets = ViewCompat.getRootWindowInsets(compose.activity.window.decorView)
            insets?.isVisible(WindowInsetsCompat.Type.ime()) == visible
        }
    }

    private fun waitForControlDisplayed(description: String) {
        compose.waitUntil(timeoutMillis = 10_000) {
            runCatching {
                compose.onNodeWithContentDescription(description).assertIsDisplayed()
                true
            }.getOrDefault(false)
        }
    }

    private fun selectFixture(fixture: String) {
        hideKeyboardIfShown()
        compose.onNodeWithTag("harness-fixture-$fixture").performScrollTo().performClick()
        compose.waitUntil(timeoutMillis = 10_000) {
            val probe = viewportProbe()
            probeText(probe, "fixture") == fixture &&
                probeText(probe, "rendered") == fixture &&
                probeValue(probe, "rows") > 0
        }
    }

    private fun showKeyboard() {
        waitForControlDisplayed("Show keyboard")
        compose.onNodeWithContentDescription("Show keyboard").performClick()
        // An AndroidView may regain focus one frame after the accessory tap when
        // a resize-mode recomposition replaced its parent. Retry the explicit
        // request rather than treating that focus hand-off as a layout result.
        val shown = runCatching {
            compose.waitUntil(timeoutMillis = 3_000) {
                val insets = ViewCompat.getRootWindowInsets(compose.activity.window.decorView)
                insets?.isVisible(WindowInsetsCompat.Type.ime()) == true
            }
        }.isSuccess
        if (!shown) {
            compose.onNodeWithContentDescription("Show keyboard").performClick()
        }
        waitForKeyboard(visible = true)
    }

    private fun hideKeyboard() {
        waitForControlDisplayed("Hide keyboard")
        compose.onNodeWithContentDescription("Hide keyboard").performClick()
        waitForKeyboard(visible = false)
        // Insets report hidden a frame before Compose swaps the accessory's
        // semantic action. Subsequent fixture selection must not click a stale,
        // off-screen Hide control.
        waitForControlDisplayed("Show keyboard")
    }

    private fun hideKeyboardIfShown() {
        if (compose.onAllNodesWithContentDescription("Hide keyboard").fetchSemanticsNodes().isNotEmpty()) {
            hideKeyboard()
        }
    }

    /** Waits for [condition]; a timeout names the last probe it saw. */
    private fun awaitProbe(description: String, condition: (String) -> Boolean) {
        var last = ""
        val met = runCatching {
            compose.waitUntil(timeoutMillis = 10_000) {
                last = viewportProbe()
                condition(last)
            }
        }.isSuccess
        assertTrue("$description; last probe: $last", met)
    }

    private fun viewportProbe(): String = compose.onNodeWithTag("terminal-viewport-probe")
        .fetchSemanticsNode()
        .config[SemanticsProperties.Text]
        .joinToString(separator = "") { it.text }

    private fun probeValue(probe: String, key: String): Int = probe
        .let { probeText(it, key).toInt() }

    private fun probeFlag(probe: String, key: String): Boolean = probeText(probe, key).toBoolean()

    private fun probeText(probe: String, key: String): String = probe
        .split(';')
        .first { it.startsWith("$key=") }
        .substringAfter('=')
}
