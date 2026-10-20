package com.bambouville.tessera.feature.session

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.Choreographer
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.viewinterop.AndroidView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.core.bridge.SharedTmuxRenderHistoryPlacement
import com.bambouville.tessera.core.bridge.SharedTmuxRenderOwner
import com.bambouville.tessera.terminal.RenderOwner
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Real touch dispatch + the production Compose history controller, with delayed capture delivery. */
@RunWith(AndroidJUnit4::class)
class MoshPrimaryScrollInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var terminal: TermuxTerminalSurface
    private val delivery = mutableStateOf<TmuxRenderHistoryReady?>(null)
    private var requests = 0
    private var token = 0L
    private var pending = false
    private var appliedDeliveries = 0
    private var onHistoryApplied: (() -> Unit)? = null
    private val handler = Handler(Looper.getMainLooper())

    private fun mount(captureDelay: Long) {
        compose.runOnIdle { terminal = TermuxTerminalSurface(compose.activity, initialCursorBlink = false) }
        compose.setContent {
            AndroidView(factory = { terminal.view }, modifier = Modifier.fillMaxSize())
            MoshPrimaryLiveHistoryController(
                primaryTerminal = terminal, delivery = delivery.value, enabled = true,
                onHistoryRequested = { _, _, _ ->
                    requests++
                    if (!pending) {
                        pending = true
                        handler.postDelayed({
                            token++
                            val owner = RenderOwner(1, 1, token, 1)
                            terminal.bind(owner)
                            terminal.feed(owner, buildString {
                                repeat(800) { row ->
                                    append("\u001b[48;5;${if (row % 2 == 0) 22 else 52}m")
                                    append("%04d | MOSH HISTORY |\u001b[K\r\n".format(row))
                                }
                                append("\u001b[0m\u001b[?25l")
                            }.encodeToByteArray())
                            delivery.value = TmuxRenderHistoryReady(token, "live", SharedTmuxRenderOwner(1, 1, token),
                                800, terminal.view.mEmulator.screen.activeTranscriptRows,
                                SharedTmuxRenderHistoryPlacement.Bottom)
                            pending = false
                        }, captureDelay)
                    }
                },
                onReturnedToLiveTail = {
                    delivery.value = null
                    terminal.view.cancelHistoryScroll()
                    terminal.bind(RenderOwner(1, 1, ++token, 1))
                    terminal.feed(terminal.boundOwner, "\u001b[2J\u001b[HLive after tail return\u001b[?25l".encodeToByteArray())
                },
                onHistoryDeliveryApplied = { _, _ -> appliedDeliveries++; onHistoryApplied?.invoke() },
            )
        }
        compose.waitUntil(5_000) { terminal.view.mEmulator != null }
        compose.runOnIdle {
            terminal.feed("\u001b[2J\u001b[HLive Mosh screen -- swipe down for history\u001b[?25l".encodeToByteArray())
        }
        Thread.sleep(300)
    }

    private fun swipe(advanceComposition: Boolean = false, reverse: Boolean = false) {
        val down = SystemClock.uptimeMillis()
        val x = terminal.view.width * .5f
        val y = terminal.view.height * (if (reverse) .85f else .25f)
        val distance = terminal.view.height * (if (reverse) -.75f else .4f)
        fun event(action: Int, atY: Float) {
            val e = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, x, atY, 0)
            e.source = InputDevice.SOURCE_TOUCHSCREEN
            instrumentation.runOnMainSync { terminal.view.dispatchTouchEvent(e) }
            e.recycle()
        }
        event(MotionEvent.ACTION_DOWN, y)
        for (step in 1..10) {
            Thread.sleep(16)
            event(MotionEvent.ACTION_MOVE, y + distance * step / 10)
            // Present the capture early in the drag, then deliver the remaining
            // moves at touch cadence so the idle wait cannot erase release velocity.
            if (advanceComposition && step == 2) {
                compose.waitUntil(5_000) { appliedDeliveries > 0 }
            }
        }
        event(MotionEvent.ACTION_UP, y + distance)
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val bitmap = instrumentation.uiAutomation.takeScreenshot()
        File(instrumentation.targetContext.filesDir, "$name.png").outputStream().use {
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)
        }
        bitmap.recycle()
    }

    private fun close() {
        instrumentation.runOnMainSync { handler.removeCallbacksAndMessages(null); terminal.close() }
    }

    @Test fun delayedFirstCapturePreservesDragAndRelease() {
        mount(500)
        try {
            capture("first-before")
            swipe()
            Thread.sleep(800)
            capture("first-after")
            val first = terminal.view.scrollPositionPixels
            swipe()
            Thread.sleep(800)
            capture("second-after")
            val second = terminal.view.scrollPositionPixels
            File(instrumentation.targetContext.filesDir, "first-scroll.txt").writeText("first=$first second=$second\n")
            assertTrue("First swipe must retain its distance across capture: first=$first second=$second", first < -terminal.view.height * .2f)
        } finally { close() }
    }

    @Test fun captureDuringDragKeepsNativeReleaseMoving() {
        mount(30)
        try {
            swipe(advanceComposition = true)
            val positions = mutableListOf<Float>()
            repeat(20) {
                Thread.sleep(16)
                instrumentation.runOnMainSync { positions += terminal.view.scrollPositionPixels }
            }
            File(instrumentation.targetContext.filesDir, "release-positions.txt").writeText(positions.joinToString("\n"))
            val distances = positions.zipWithNext { a, b -> a - b }.filter { it > 0 }
            assertTrue("Release must move across actual frames: $positions", distances.size >= 5)
            assertTrue("Native release must decelerate: $distances", distances.takeLast(3).average() < distances.take(3).average())
            capture("mid-drag-release")
        } finally { close() }
    }

    @Test fun slowCaptureDoesNotSpendReleaseMotionBeforeHistoryIsVisible() {
        mount(1_500)
        val positions = mutableListOf<Float>()
        val frames = CountDownLatch(30)
        lateinit var sampler: Choreographer.FrameCallback
        instrumentation.runOnMainSync {
            sampler = Choreographer.FrameCallback {
                positions += terminal.view.scrollPositionPixels
                frames.countDown()
                if (frames.count > 0) Choreographer.getInstance().postFrameCallback(sampler)
            }
            onHistoryApplied = { Choreographer.getInstance().postFrameCallback(sampler) }
        }
        try {
            capture("slow-before")
            swipe()
            compose.waitUntil(5_000) { appliedDeliveries > 0 }
            // Sampling starts at the presentation acknowledgement, independently
            // of screenshot capture/compression on this instrumentation thread.
            capture("slow-delivered")
            assertTrue("Presented history must deliver frames", frames.await(3, TimeUnit.SECONDS))
            capture("slow-settled")
            File(instrumentation.targetContext.filesDir, "slow-release-positions.txt")
                .writeText(positions.joinToString("\n"))
            assertTrue("A first flick must still move after slow history arrives: $positions",
                positions.zipWithNext { a, b -> a - b }.count { it > 0 } >= 5)
        } finally {
            instrumentation.runOnMainSync {
                onHistoryApplied = null
                Choreographer.getInstance().removeFrameCallback(sampler)
            }
            close()
        }
    }

    @Test fun scrollWorksAgainAfterUserInputInvalidatesHistory() {
        mount(30)
        try {
            swipe()
            Thread.sleep(600)
            capture("invalidate-history")
            val before = requests
            compose.runOnIdle {
                // Production noteTmuxRenderUserInput clears delivery and binds a new live owner.
                delivery.value = null
                terminal.bind(RenderOwner(1, 1, ++token, 1))
                terminal.feed(terminal.boundOwner, "\u001b[2J\u001b[HLive after typing\u001b[?25l".encodeToByteArray())
            }
            Thread.sleep(200)
            capture("invalidate-live")
            swipe()
            Thread.sleep(600)
            capture("invalidate-rescroll")
            assertTrue("History must be requested again after typing: before=$before after=$requests", requests > before)
            assertTrue("Second history gesture must move", terminal.view.topRow < 0)
        } finally { close() }
    }

    @Test fun reverseToLiveThenSwipeHistoryAgain() {
        mount(300)
        try {
            swipe()
            Thread.sleep(1_200)
            capture("reentry-first")
            val first = terminal.view.scrollPositionPixels
            repeat(3) {
                if (terminal.view.topRow < 0) {
                    swipe(reverse = true)
                    Thread.sleep(700)
                    compose.waitForIdle()
                }
            }
            capture("reentry-tail")
            assertTrue("Reverse must return to the live painter", delivery.value == null && terminal.view.topRow == 0)
            swipe()
            Thread.sleep(1_200)
            capture("reentry-second")
            val second = terminal.view.scrollPositionPixels
            File(instrumentation.targetContext.filesDir, "reentry-positions.txt").writeText("first=$first second=$second requests=$requests\n")
            assertTrue("Identical fresh reveal must retain substantial motion: first=$first second=$second", second < first * .5f)
        } finally { close() }
    }
}
