package com.termux.view

import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.Choreographer
import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.terminal.TerminalTestActivity
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class TerminalPixelScrollInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    private fun withTerminal(test: (TermuxTerminalSurface) -> Unit) {
        val (activity, surface) = launchDrawableTerminal()
        try {
            Thread.sleep(250)
            instrumentation.runOnMainSync {
                surface.feed(buildString {
                    repeat(600) { row ->
                        append("\u001b[48;5;${if (row % 2 == 0) 22 else 52}m")
                        append("%04d | scrolling should follow your finger |\u001b[K\r\n".format(row))
                    }
                    append("\u001b[0m\u001b[?25l")
                }.encodeToByteArray())
                surface.view.topRow = -100
            }
            test(surface)
        } finally {
            instrumentation.runOnMainSync { surface.close(); activity.finish() }
        }
    }

    /**
     * A freshly booted API 36 AVD applies a late CONFIG_ASSETS_PATHS change
     * around the first instrumentation launch and recreates the activity.
     * A surface set on the destroyed instance is never laid out, so a fling
     * finds no emulator and computeScroll never runs. Relaunch until the
     * view is laid out, focused and drawing.
     */
    private fun launchDrawableTerminal(): Pair<TerminalTestActivity, TermuxTerminalSurface> {
        val attempts = mutableListOf<String>()
        repeat(3) {
            val activity = instrumentation.startActivitySync(
                Intent.makeMainActivity(ComponentName(instrumentation.context, TerminalTestActivity::class.java))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            ) as TerminalTestActivity
            lateinit var surface: TermuxTerminalSurface
            instrumentation.runOnMainSync {
                surface = TermuxTerminalSurface(activity, initialCursorBlink = false)
                activity.setContentView(surface.view)
            }
            instrumentation.waitForIdleSync()
            val deadline = SystemClock.uptimeMillis() + 5_000
            var state = ""
            while (SystemClock.uptimeMillis() < deadline) {
                var ready = false
                instrumentation.runOnMainSync {
                    val view = surface.view
                    ready = !activity.isDestroyed && view.isLaidOut && view.width > 0 &&
                        view.hasWindowFocus() && view.mEmulator != null
                    state = "destroyed=${activity.isDestroyed} laidOut=${view.isLaidOut} " +
                        "size=${view.width}x${view.height} focus=${view.hasWindowFocus()} " +
                        "emulator=${view.mEmulator != null}"
                }
                if (ready) return activity to surface
                Thread.sleep(50)
            }
            attempts += state
            // The lane keeps TerminalView:I logcat as device.log.
            android.util.Log.i("TerminalView", "test activity not drawable, relaunching: $state")
            instrumentation.runOnMainSync { surface.close(); activity.finish() }
            instrumentation.waitForIdleSync()
        }
        throw AssertionError("terminal view never became drawable: $attempts")
    }

    private fun drag(view: TerminalView, delta: Float) {
        val event = MotionEvent.obtain(0, SystemClock.uptimeMillis(), MotionEvent.ACTION_MOVE, 200f, 400f, 0)
        view.mGestureRecognizer.mListener.onScroll(event, 0f, delta)
        event.recycle()
    }

    @Test fun pageBoundaryCarriesOverflowAndReleaseIntoReplacement() = withTerminal { surface ->
        val paging = CountDownLatch(1)
        val before = com.bambouville.tessera.terminal.RenderOwner(1, 1, 1, 1)
        val after = before.copy(epoch = 2)
        instrumentation.runOnMainSync {
            surface.bind(before)
            surface.feed(before, buildString { repeat(200) { append("OLD-$it\r\n") } }.encodeToByteArray())
            val view = surface.view
            view.topRow = -view.mEmulator.screen.activeTranscriptRows + 2
            view.setHistoryScrollRequest {
                if (view.topRow <= -view.mEmulator.screen.activeTranscriptRows) {
                    view.beginHistoryScroll()
                    paging.countDown()
                }
            }
            val event = MotionEvent.obtain(0, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, 300f, 800f, 0)
            view.mGestureRecognizer.mListener.onFling(event, 0f, 2400f)
            event.recycle()
        }
        assertTrue("Fling must request a deeper page", paging.await(2, TimeUnit.SECONDS))
        Thread.sleep(80)
        var placed = 0f
        instrumentation.runOnMainSync {
            val view = surface.view
            assertTrue("Missing page holds motion", view.isHistoryScrollPending)
            assertFalse("Page boundary must not cancel the release", view.mScroller.isFinished)
            val oldest = -view.mEmulator.screen.activeTranscriptRows * view.mRenderer.fontLineSpacing
            surface.bind(after)
            surface.feed(after, buildString { repeat(800) { append("NEW-$it\r\n") } }.encodeToByteArray())
            view.completeHistoryScroll(-1)
            placed = view.scrollPositionPixels
            assertTrue("Crossing-frame overflow survives refill", placed < oldest)
            assertFalse("Refill must retain the same native glide", view.mScroller.isFinished)
        }
        Thread.sleep(160)
        instrumentation.runOnMainSync {
            assertTrue("Native release continues after refill", surface.view.scrollPositionPixels < placed - 20)
            surface.view.setHistoryScrollRequest(null)
        }
    }

    @Test fun rejectedPageAndTypingReleasePendingMotion() = withTerminal { surface ->
        instrumentation.runOnMainSync {
            val view = surface.view
            view.topRow = -view.mEmulator.screen.activeTranscriptRows
            view.setHistoryScrollRequest { view.beginHistoryScroll() }
            drag(view, -30f)
            assertTrue(view.isHistoryScrollPending)
            // The controller handles an exhausted/frozen request without discarding its transcript.
            view.cancelHistoryScroll()
            val edge = view.scrollPositionPixels
            drag(view, 60f)
            assertEquals(edge + 60, view.scrollPositionPixels, .01f)
            drag(view, -20f)
            assertTrue(view.isHistoryScrollPending)
            view.followLiveOutput()
            assertFalse(view.isHistoryScrollPending)
            assertEquals(0f, view.scrollPositionPixels, 0f)
            view.setHistoryScrollRequest(null)
        }
    }

    @Test fun deferredHistoryReleaseCannotReviveAfterCancellation() = withTerminal { surface ->
        for (cancellation in listOf("touch", "typing", "disabled", "rejected", "owner")) {
            instrumentation.runOnMainSync {
                val view = surface.view
                view.setSmoothScrollingEnabled(true)
                view.topRow = -10
                view.setHistoryScrollRequest { view.beginHistoryScroll() }
                drag(view, -30f)
                val event = MotionEvent.obtain(0, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, 300f, 800f, 0)
                view.mGestureRecognizer.mListener.onFling(event, 0f, 2400f)
                event.recycle()
                assertTrue("Release waits for visible history", view.mScroller.isFinished)
                when (cancellation) {
                    "touch" -> view.mGestureRecognizer.mListener.onDown(300f, 800f)
                    "typing" -> view.followLiveOutput()
                    "disabled" -> view.setSmoothScrollingEnabled(false)
                    "rejected" -> view.cancelHistoryScroll()
                    "owner" -> view.setHistoryScrollRequest(null)
                }
                view.completeHistoryScroll(-10)
                assertTrue("$cancellation must retire deferred release", view.mScroller.isFinished)
                view.setHistoryScrollRequest(null)
            }
        }
    }

    @Test fun subRowDragActuallyMovesPixelsAndSelectionWithoutSnapping() = withTerminal { surface ->
        instrumentation.runOnMainSync {
            val view = surface.view
            val before = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(before))
            val position = view.scrollPositionPixels
            drag(view, 3f)
            val after = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(Canvas(after))
            assertEquals(position + 3f, view.scrollPositionPixels, 0.01f)
            var different = 0
            var shiftedMatches = 0
            var pixels = 0
            for (y in 100 until view.height - 100) for (x in 20 until view.width - 20 step 3) {
                if (before.getPixel(x, y) != after.getPixel(x, y)) different++
                if (before.getPixel(x, y + 3) == after.getPixel(x, y)) shiftedMatches++
                pixels++
            }
            assertTrue("Sub-row motion must be visible, not just internal state", different > pixels / 30)
            assertTrue("All glyphs and ANSI backgrounds shift together", shiftedMatches > pixels * .98)
            val pointBefore = view.getPointY(view.topRow + 4)
            view.scrollHistoryRows(0)
            assertEquals(position + 3f, view.scrollPositionPixels, 0.01f)
            view.scrollHistoryRows(1)
            assertEquals(position + 3f + view.mRenderer.fontLineSpacing, view.scrollPositionPixels, .01f)
            assertEquals(pointBefore - view.mRenderer.fontLineSpacing, view.getPointY(view.topRow + 3))
            before.recycle(); after.recycle()
        }
    }

    @Test fun fractionalWheelAndDragClampAtBothEdges() = withTerminal { surface ->
        instrumentation.runOnMainSync {
            val view = surface.view
            view.topRow = -1
            drag(view, 3f)
            val event = MotionEvent.obtain(0, 0, MotionEvent.ACTION_SCROLL, 100f, 100f, 0)
            view.doScroll(event, 3)
            assertEquals(0f, view.scrollPositionPixels, 0f)
            drag(view, -1_000_000f)
            assertEquals(-view.mEmulator.screen.activeTranscriptRows * view.mRenderer.fontLineSpacing.toFloat(), view.scrollPositionPixels, 0f)
            drag(view, 1_000_000f)
            assertEquals(0f, view.scrollPositionPixels, 0f)
            event.recycle()
        }
    }

    @Test fun outputRetainsFractionAndRemoteRoutesRemainDiscrete() = withTerminal { surface ->
        instrumentation.runOnMainSync {
            val view = surface.view
            drag(view, 7f)
            val position = view.scrollPositionPixels
            val height = view.mRenderer.fontLineSpacing
            surface.feed("new output\r\n".encodeToByteArray())
            assertEquals(position - height, view.scrollPositionPixels, .01f)
            val output = mutableListOf<ByteArray>()
            surface.onInput = { output += it }
            for (mouse in listOf(false, true)) {
                surface.feed(("\u001b[?1049h" + if (mouse) "\u001b[?1000h\u001b[?1006h" else "\u001b[?1000l").encodeToByteArray())
                assertEquals(0f, view.scrollPositionPixels, 0f)
                output.clear()
                drag(view, height.toFloat() * 2)
                assertTrue("Alternate screen must receive semantic input", output.isNotEmpty())
                assertEquals(0f, view.scrollPositionPixels, 0f)
                surface.feed("\u001b[?1049l".encodeToByteArray())
            }
        }
    }

    @Test fun nativePhysicsDeceleratesAndTouchTakesOwnership() = withTerminal { surface ->
        val samples = mutableListOf<Pair<Long, Float>>()
        var capturing = true
        var releaseSampleIndex = -1
        val coastFrames = CountDownLatch(15)
        lateinit var callback: Choreographer.FrameCallback
        instrumentation.runOnMainSync {
            callback = Choreographer.FrameCallback { time ->
                samples += time to surface.view.scrollPositionPixels
                if (releaseSampleIndex >= 0) coastFrames.countDown()
                if (capturing) Choreographer.getInstance().postFrameCallback(callback)
            }
            Choreographer.getInstance().postFrameCallback(callback)
        }
        var down = SystemClock.uptimeMillis()
        fun touch(action: Int, y: Float) {
            if (action == MotionEvent.ACTION_DOWN) down = SystemClock.uptimeMillis()
            val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, 300f, y, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            // Exercise the terminal's real touch handler. System-level gestures are
            // covered separately by the recorded visual lane.
            instrumentation.runOnMainSync { surface.view.onTouchEvent(event) }
            event.recycle()
        }
        try {
            // A freshly booted AVD can stall frames for hundreds of
            // milliseconds; decay needs a display that is drawing steadily.
            val settleDeadline = SystemClock.uptimeMillis() + 20_000
            var intervals = emptyList<Long>()
            while (SystemClock.uptimeMillis() < settleDeadline) {
                instrumentation.runOnMainSync {
                    intervals = samples.takeLast(11).zipWithNext { a, b -> (b.first - a.first) / 1_000_000 }
                }
                if (intervals.size == 10 && intervals.all { it in 1..50 }) break
                Thread.sleep(100)
            }
            assertTrue("Display frames never steadied: ${intervals}ms", intervals.size == 10 && intervals.all { it in 1..50 })
            instrumentation.runOnMainSync { drag(surface.view, -400f) }
            // Fix the release velocity to isolate native physics from emulator input timing.
            // Actual system swipes and GestureDetector release are recorded in the visual lane.
            var release = 0f
            instrumentation.runOnMainSync {
                val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, 300f, 800f, 0)
                surface.view.mGestureRecognizer.mListener.onFling(event, 0f, 2400f)
                event.recycle()
                assertFalse(
                    "Native physics starts at release: attached=${surface.view.isAttachedToWindow} " +
                        "shown=${surface.view.isShown} emulator=${surface.view.mEmulator != null}",
                    surface.view.mScroller.isFinished,
                )
                release = surface.view.scrollPositionPixels
                releaseSampleIndex = samples.size
            }
            assertTrue("The native display must deliver coast frames", coastFrames.await(3, TimeUnit.SECONDS))
            var glided = 0f
            instrumentation.runOnMainSync {
                glided = surface.view.scrollPositionPixels
                val coast = samples.drop(releaseSampleIndex)
                // A frame callback runs before that frame's draw, so each sample
                // holds what computeScroll produced at the previous frame's time.
                // Pair positions with that interval: with uneven frame spacing
                // the naive pairing makes a decelerating glide look faster.
                // The first interval starts at release, between frames; skip it.
                val velocities = (1 until coast.size - 1).mapNotNull { i ->
                    val seconds = (coast[i].first - coast[i - 1].first) / 1_000_000_000f
                    if (seconds <= 0f) null else (coast[i].second - coast[i + 1].second) / seconds
                }
                assertTrue("Capture enough actual display frames to measure decay", velocities.size >= 5)
                val moving = velocities.filter { it > 0 }
                val view = surface.view
                val host = view.context as? android.app.Activity
                assertTrue(
                    "Release must produce moving frames: $velocities attached=${view.isAttachedToWindow} " +
                        "shown=${view.isShown} visibility=${view.windowVisibility} focus=${view.hasWindowFocus()} " +
                        "destroyed=${host?.isDestroyed} finished=${view.mScroller.isFinished}",
                    moving.size >= 3,
                )
                val frameMillis = coast.zipWithNext { a, b -> (b.first - a.first) / 1_000_000 }
                assertTrue(
                    "Native release slows down: $velocities frames=${frameMillis}ms",
                    moving.takeLast(2).average() < moving.take(2).average(),
                )
            }
            assertTrue("Release must continue moving toward older content: release=$release after=$glided", glided < release - 3)
            instrumentation.runOnMainSync {
                val event = MotionEvent.obtain(0, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, 300f, 800f, 0)
                surface.view.mGestureRecognizer.mListener.onFling(event, 0f, 6000f)
                event.recycle()
                assertFalse("Cancellation must interrupt an active fling", surface.view.mScroller.isFinished)
            }
            touch(MotionEvent.ACTION_DOWN, 800f)
            var stopped = 0f
            instrumentation.runOnMainSync {
                assertTrue("Touch down immediately cancels the active fling", surface.view.mScroller.isFinished)
                stopped = surface.view.scrollPositionPixels
            }
            Thread.sleep(180)
            instrumentation.runOnMainSync { assertEquals("Touch stops glide without snapping", stopped, surface.view.scrollPositionPixels, .01f) }
            touch(MotionEvent.ACTION_CANCEL, 800f)
        } finally {
            touch(MotionEvent.ACTION_CANCEL, 800f)
            instrumentation.runOnMainSync {
                capturing = false
                Choreographer.getInstance().removeFrameCallback(callback)
                File(instrumentation.context.filesDir, "scroll-frames.csv").writeText(
                    "frame_ns,position_px\n" + samples.joinToString("\n") { "${it.first},${it.second}" },
                )
            }
        }
    }

    @Test fun disablingMomentumAndTypingCancelWithoutDelayedWrites() = withTerminal { surface ->
        instrumentation.runOnMainSync {
            val view = surface.view
            val event = MotionEvent.obtain(0, 0, MotionEvent.ACTION_UP, 300f, 600f, 0)
            view.mGestureRecognizer.mListener.onFling(event, 0f, 3000f)
            assertFalse(view.mScroller.isFinished)
            view.setSmoothScrollingEnabled(false)
            assertTrue(view.mScroller.isFinished)
            val position = view.scrollPositionPixels
            drag(view, 3f)
            assertEquals("Direct dragging stays pixel precise with momentum off", position + 3, view.scrollPositionPixels, .01f)
            view.setSmoothScrollingEnabled(true)
            view.mGestureRecognizer.mListener.onFling(event, 0f, 3000f)
            view.followLiveOutput()
            assertTrue(view.mScroller.isFinished)
            view.computeScroll()
            assertEquals(0f, view.scrollPositionPixels, 0f)
            event.recycle()
        }
    }
}
