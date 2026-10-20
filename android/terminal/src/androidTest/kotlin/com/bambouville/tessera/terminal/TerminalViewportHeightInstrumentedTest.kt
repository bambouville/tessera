package com.bambouville.tessera.terminal

import android.content.ComponentName
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import android.view.View
import android.widget.FrameLayout
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.core.bridge.SharedTmuxCellRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Physical viewport publications must survive a mount without adopting the old Mosh canvas. */
@RunWith(AndroidJUnit4::class)
class TerminalViewportHeightInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test
    fun measurementBeforeFirstAttachPublishesWhenTheQueuedPostIsAttached() = withViewport { fixture ->
        instrumentation.runOnMainSync {
            assertFalse(fixture.viewport.isAttachedToWindow)
            fixture.measureAndLayout(PHYSICAL_ROWS)
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            // View.post on a never-attached view uses its run queue. It must
            // not be mistaken for the attach-handler race exercised below.
            assertTrue(fixture.publications.isEmpty())
            fixture.attach(PHYSICAL_ROWS)
        }
        awaitAttached(fixture)
        instrumentation.runOnMainSync {
            fixture.assertTwoRowPhysicalGap()
            assertEquals(listOf(COLUMNS to PHYSICAL_ROWS), fixture.publications)
        }
    }

    @Test
    fun detachAfterAttachedMeasurementRepublishesHeightWhenReattachedAtTheSameBounds() = withViewport { fixture ->
        instrumentation.runOnMainSync { fixture.attach(CANVAS_ROWS) }
        awaitAttached(fixture)
        instrumentation.runOnMainSync {
            assertEquals(listOf(COLUMNS to CANVAS_ROWS), fixture.publications)
            assertTrue(fixture.viewport.isAttachedToWindow)
            // This post targets the current attach handler. Detach before
            // returning to the main looper, so its real runnable observes a
            // detached viewport rather than waiting in a first-attach queue.
            fixture.viewport.layoutParams = fixture.layoutParams(PHYSICAL_ROWS)
            fixture.measureAndLayout(PHYSICAL_ROWS)
            fixture.container.removeView(fixture.viewport)
            assertFalse(fixture.viewport.isAttachedToWindow)
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            assertEquals("the queued measurement ran detached", listOf(COLUMNS to CANVAS_ROWS), fixture.publications)
            fixture.attach(PHYSICAL_ROWS)
        }
        awaitAttached(fixture)
        instrumentation.runOnMainSync {
            // A fresh measure at identical bounds must recover the missed
            // physical height even though the Mosh-owned child grid is still
            // the previous canvas. Native canvas state cannot infer this gap.
            fixture.viewport.forceLayout()
            fixture.measureAndLayout(PHYSICAL_ROWS)
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            fixture.assertTwoRowPhysicalGap()
            Log.i("TerminalView", "TESSERA_VIEWPORT_HEIGHT_REATTACHED physical=${COLUMNS}x$PHYSICAL_ROWS " +
                "native=${fixture.surface.view.mEmulator.mColumns}x${fixture.surface.view.mEmulator.mRows} " +
                "published=${fixture.publications}")
            assertEquals("an active mounted viewport must recover its missed physical height",
                COLUMNS to PHYSICAL_ROWS, fixture.publications.lastOrNull())
            assertEquals("the recovered height is published once", 1,
                fixture.publications.count { it == (COLUMNS to PHYSICAL_ROWS) })
        }
    }

    @Test
    fun replacementReceiverGetsTheCurrentPhysicalHeightWithoutRepeatedMeasurementsDuplicatingIt() = withViewport { fixture ->
        val reboundPublications = mutableListOf<Pair<Int, Int>>()
        instrumentation.runOnMainSync { fixture.attach(PHYSICAL_ROWS) }
        awaitAttached(fixture)
        instrumentation.runOnMainSync {
            fixture.assertTwoRowPhysicalGap()
            assertEquals(listOf(COLUMNS to PHYSICAL_ROWS), fixture.publications)
            // A surviving AndroidView may be rebound to a replacement
            // controller without changing its physical bounds or Mosh grid.
            fixture.viewport.onViewportGridChanged = { columns, rows -> reboundPublications += columns to rows }
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            assertEquals("a replacement receiver needs the current physical height without another resize",
                listOf(COLUMNS to PHYSICAL_ROWS), reboundPublications)
            assertEquals("the retired receiver must not receive another publication",
                listOf(COLUMNS to PHYSICAL_ROWS), fixture.publications)
            repeat(3) {
                fixture.viewport.forceLayout()
                fixture.measureAndLayout(PHYSICAL_ROWS)
            }
        }
        instrumentation.waitForIdleSync()
        instrumentation.runOnMainSync {
            fixture.assertTwoRowPhysicalGap()
            assertEquals("stable measurements must not repeat a delivered height for the same receiver",
                listOf(COLUMNS to PHYSICAL_ROWS), reboundPublications)
        }
    }

    private fun withViewport(test: (Fixture) -> Unit) {
        val activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(ComponentName(instrumentation.context, TerminalTestActivity::class.java))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as TerminalTestActivity
        lateinit var fixture: Fixture
        var initializedFixture: Fixture? = null
        try {
            instrumentation.runOnMainSync {
                val container = FrameLayout(activity)
                val surface = TermuxTerminalSurface(activity, initialCursorBlink = false)
                surface.resize(COLUMNS, CANVAS_ROWS)
                val viewport = GeometryNeutralTerminalViewport(activity, surface)
                val canvas = SharedTmuxCellRect(COLUMNS, CANVAS_ROWS, 0, 0)
                viewport.setWindowGrid(canvas, canvas)
                fixture = Fixture(activity, container, surface, viewport)
                initializedFixture = fixture
                viewport.onViewportGridChanged = { columns, rows -> fixture.publications += columns to rows }
                activity.setContentView(container)
            }
            instrumentation.waitForIdleSync()
            test(fixture)
        } finally {
            instrumentation.runOnMainSync {
                initializedFixture?.let {
                    it.viewport.releaseTerminal()
                    it.surface.close()
                }
                activity.finish()
            }
        }
    }

    private fun awaitAttached(fixture: Fixture) {
        val deadline = SystemClock.uptimeMillis() + 5_000
        while (SystemClock.uptimeMillis() < deadline) {
            instrumentation.waitForIdleSync()
            var ready = false
            instrumentation.runOnMainSync {
                assertFalse("fixture activity was destroyed during the mount", fixture.activity.isDestroyed)
                ready = fixture.viewport.isAttachedToWindow && fixture.viewport.isLaidOut
            }
            if (ready) return
            SystemClock.sleep(20)
        }
        throw AssertionError("height fixture viewport did not attach")
    }

    private class Fixture(
        val activity: TerminalTestActivity,
        val container: FrameLayout,
        val surface: TermuxTerminalSurface,
        val viewport: GeometryNeutralTerminalViewport,
    ) {
        val publications = mutableListOf<Pair<Int, Int>>()

        fun layoutParams(rows: Int): FrameLayout.LayoutParams {
            val metrics = surface.gridMetrics()
            return FrameLayout.LayoutParams(metrics.pixelWidth(COLUMNS), metrics.pixelHeight(rows))
        }

        fun attach(rows: Int) = container.addView(viewport, layoutParams(rows))

        fun measureAndLayout(rows: Int) {
            val size = layoutParams(rows)
            viewport.measure(
                View.MeasureSpec.makeMeasureSpec(size.width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(size.height, View.MeasureSpec.EXACTLY),
            )
            viewport.layout(0, 0, size.width, size.height)
        }

        fun assertTwoRowPhysicalGap() {
            assertTrue(viewport.isAttachedToWindow)
            assertTrue(viewport.isShown)
            val metrics = surface.gridMetrics()
            assertEquals(COLUMNS, metrics.columnsFor(viewport.width))
            assertEquals(PHYSICAL_ROWS, metrics.rowsFor(viewport.height))
            assertEquals(COLUMNS, surface.view.mEmulator.mColumns)
            assertEquals(CANVAS_ROWS, surface.view.mEmulator.mRows)
        }
    }

    private companion object {
        const val COLUMNS = 56
        const val CANVAS_ROWS = 45
        const val PHYSICAL_ROWS = 47
    }
}
