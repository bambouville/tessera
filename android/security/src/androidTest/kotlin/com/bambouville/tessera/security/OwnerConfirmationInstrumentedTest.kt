package com.bambouville.tessera.security

import android.content.ComponentName
import android.content.Intent
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The owner prompt on the device's own system UI. It sets and clears a
 * screen-lock PIN, so it runs only where the runner passes
 * `-e tesseraDisposableDevice true`.
 */
@RunWith(AndroidJUnit4::class)
class OwnerConfirmationInstrumentedTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var activity: OwnerConfirmationTestActivity
    private var pinSet = false

    @Before fun startOnADisposableDevice() {
        assumeTrue(
            "sets a screen-lock PIN: disposable devices only",
            InstrumentationRegistry.getArguments().getString("tesseraDisposableDevice") == "true",
        )
        activity = instrumentation.startActivitySync(
            Intent.makeMainActivity(ComponentName(instrumentation.context, OwnerConfirmationTestActivity::class.java))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        ) as OwnerConfirmationTestActivity
    }

    @After fun clearThePin() {
        if (pinSet) shell("locksettings clear --old $PIN")
        if (::activity.isInitialized) instrumentation.runOnMainSync { activity.finish() }
    }

    @Test fun theOwnerConfirmsWithTheScreenLockAndBackHomeOrTheCallerCancels() = runBlocking<Unit> {
        assertFalse("without a screen lock there is nothing to confirm with", canConfirmDeviceOwner(activity))
        assertFalse(confirmDeviceOwner(activity, TITLE, DESCRIPTION))

        shell("locksettings set-pin $PIN")
        pinSet = true
        assertTrue(canConfirmDeviceOwner(activity))

        val confirmed = prompt()
        awaitPrompt(true)
        // The prompt is a system window over the caller, not an activity on
        // top of it: the caller is never stopped, so it is no excursion.
        assertFalse("the prompt stops its caller: ${activity.callbacks}", "stop" in activity.callbacks)
        shell("input text $PIN")
        shell("input keyevent KEYCODE_ENTER")
        assertTrue("the PIN confirms the owner", withTimeout(15_000) { confirmed.await() })
        awaitPrompt(false)
        assertFalse("the prompt stops its caller: ${activity.callbacks}", "stop" in activity.callbacks)
        Log.i(TAG, "caller callbacks through a confirmation: ${activity.callbacks}")

        val dismissed = prompt()
        awaitPrompt(true)
        shell("input keyevent KEYCODE_BACK")
        assertFalse("Back is no confirmation", withTimeout(15_000) { dismissed.await() })
        awaitPrompt(false)

        val abandoned = prompt()
        awaitPrompt(true)
        abandoned.cancelAndJoin()
        awaitPrompt(false)

        // Home is the caller's own real stop, and the prompt goes with it.
        val left = prompt()
        awaitPrompt(true)
        shell("input keyevent KEYCODE_HOME")
        assertFalse("leaving is no confirmation", withTimeout(15_000) { left.await() })
        // The prompt answers before the caller's own stop arrives.
        val deadline = SystemClock.uptimeMillis() + 10_000
        while ("stop" !in activity.callbacks) {
            assertTrue("Home stops the caller: ${activity.callbacks}", SystemClock.uptimeMillis() < deadline)
            Thread.sleep(100)
        }
        Log.i(TAG, "caller callbacks through Home: ${activity.callbacks}")
    }

    private fun prompt(): Deferred<Boolean> =
        CoroutineScope(Dispatchers.Main).async { confirmDeviceOwner(activity, TITLE, DESCRIPTION) }

    /** The system prompt is the active window while it is up. */
    private fun awaitPrompt(shown: Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        while ((instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString() == SYSTEM_UI) != shown) {
            assertTrue(if (shown) "the system prompt shows" else "the system prompt goes", SystemClock.uptimeMillis() < deadline)
            Thread.sleep(100)
        }
    }

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
            .use { it.readBytes().decodeToString() }

    private companion object {
        const val PIN = "1357"
        const val TITLE = "Confirm the owner"
        const val DESCRIPTION = "Tessera's owner prompt test"
        const val SYSTEM_UI = "com.android.systemui"
        const val TAG = "OwnerConfirmationTest"
    }
}
