package com.bambouville.tessera.feature.session

import android.view.ViewTreeObserver
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.terminal.TermuxTerminalSurface
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicInteger

/**
 * P9 on a real Termux view: while the session is hidden or veiled, what
 * output and the cursor blinker do (invalidate the terminal) neither redraws
 * it nor schedules a frame, and the first frame after the gate opens paints
 * the current screen.
 */
@RunWith(AndroidJUnit4::class)
class TerminalDrawingGateInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun aHeldTerminalNeitherDrawsNorSchedulesAFrameUntilTheGateOpens() {
        lateinit var surface: TermuxTerminalSurface
        // No blinker: its own invalidations would race the dirty-state reads.
        compose.runOnIdle { surface = TermuxTerminalSurface(compose.activity, initialCursorBlink = false) }
        val drawing = mutableStateOf(true)
        val mounted = mutableStateOf(true)
        compose.setContent {
            if (mounted.value) {
                TerminalViewport(terminal = surface, drawingEnabled = drawing.value, modifier = Modifier.fillMaxSize())
            }
        }
        compose.waitUntil(timeoutMillis = 5_000) { compose.runOnUiThread<Boolean> { !surface.view.isDirty } }
        val gate = compose.runOnUiThread<TerminalDrawingGate> {
            generateSequence(surface.view.parent) { it.parent }.filterIsInstance<TerminalDrawingGate>().first()
        }

        compose.runOnIdle { drawing.value = false }
        compose.waitForIdle()
        val windowDraws = AtomicInteger()
        val counter = ViewTreeObserver.OnDrawListener { windowDraws.incrementAndGet() }
        compose.runOnIdle {
            surface.view.viewTreeObserver.addOnDrawListener(counter)
            surface.view.invalidate()
        }
        // Several frame intervals for a frame that must never come.
        Thread.sleep(250)
        compose.waitForIdle()
        compose.runOnIdle {
            assertTrue("the terminal keeps its last frame", surface.view.isDirty)
            assertTrue(gate.holdsInvalidation)
            assertEquals("no frame was scheduled for a terminal nobody can see", 0, windowDraws.get())
        }

        compose.runOnIdle { drawing.value = true }
        compose.waitUntil(timeoutMillis = 5_000) { compose.runOnUiThread<Boolean> { !surface.view.isDirty } }
        compose.runOnIdle {
            assertFalse(gate.holdsInvalidation)
            assertTrue("opening the gate drew it", windowDraws.get() > 0)
            surface.view.viewTreeObserver.removeOnDrawListener(counter)
        }
        compose.runOnIdle { mounted.value = false }
        compose.runOnIdle { surface.close() }
    }
}
