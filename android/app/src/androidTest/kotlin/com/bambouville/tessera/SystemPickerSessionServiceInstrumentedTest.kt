package com.bambouville.tessera

import android.app.ActivityManager
import android.content.Context
import android.os.SystemClock
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The keep-alive service against a stop that overtakes its start. A session
 * that connects and closes while the main thread is busy — a restored session
 * at launch, then the Activity going away — used to call stopService() before
 * the service ran, and Android killed the app with
 * ForegroundServiceDidNotStartInTimeException.
 */
@RunWith(AndroidJUnit4::class)
class SystemPickerSessionServiceInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext

    @Test
    fun aStopThatOvertakesTheStartLeavesTheServiceToStopItself() {
        // A foreground start needs a foreground app (Android 12+).
        ActivityScenario.launch(MainActivity::class.java).use {
            instrumentation.waitForIdleSync()
            // The crash needs the service absent: stopService() on a running
            // one is an ordinary stop.
            awaitServiceSettled()
            assertEquals("no start in flight before the race", 0, SystemPickerSessionService.pendingStarts)
            assertFalse("the service is absent before the race", serviceRunning())
            var issued = -1
            // One main-thread turn: the service cannot run between the two.
            instrumentation.runOnMainSync {
                SystemPickerSessionService.setSessionsActive(context, 1)
                issued = SystemPickerSessionService.pendingStarts
                SystemPickerSessionService.setSessionsActive(context, 0)
            }
            assertEquals("the foreground start was issued, so the race is real", 1, issued)

            awaitServiceSettled()
            assertEquals(0, SystemPickerSessionService.pendingStarts)
            assertFalse("the service stopped itself once started", serviceRunning())
        }
    }

    private fun awaitServiceSettled() {
        val deadline = SystemClock.uptimeMillis() + 10_000
        while ((SystemPickerSessionService.pendingStarts > 0 || serviceRunning()) &&
            SystemClock.uptimeMillis() < deadline
        ) {
            SystemClock.sleep(50)
        }
    }

    @Suppress("DEPRECATION") // Still lists the caller's own services.
    private fun serviceRunning(): Boolean =
        context.getSystemService(ActivityManager::class.java)
            .getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == SystemPickerSessionService::class.java.name }
}
