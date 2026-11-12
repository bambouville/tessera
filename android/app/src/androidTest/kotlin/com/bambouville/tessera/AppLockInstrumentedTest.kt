package com.bambouville.tessera

import android.os.ParcelFileDescriptor
import android.os.SystemClock
import androidx.compose.ui.test.junit4.v2.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.data.AndroidAppPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/**
 * App lock asks the owner on the system's own prompt. It sets and clears a
 * screen-lock PIN, so it runs only where the runner passes
 * `-e tesseraDisposableDevice true`.
 */
@RunWith(AndroidJUnit4::class)
class AppLockInstrumentedTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test fun unlockTakesTheScreenLockOnTheSystemPrompt() {
        assumeTrue(
            "sets a screen-lock PIN: disposable devices only",
            InstrumentationRegistry.getArguments().getString("tesseraDisposableDevice") == "true",
        )
        val context = instrumentation.targetContext
        val preferences = AndroidAppPreferences(context)
        val unlock = context.getString(R.string.app_lock_unlock)
        shell("locksettings set-pin $PIN")
        try {
            runBlocking { preferences.updateAppLockEnabled(true) }
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                compose.waitUntil(15_000) { compose.onAllNodesWithText(unlock).fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText(unlock).performClick()
                awaitSystemPrompt()
                // A window over the app, not an activity on top of it: no stop, so no excursion.
                assertTrue("the prompt stops the app: ${scenario.state}", scenario.state.isAtLeast(Lifecycle.State.STARTED))
                shell("input text $PIN")
                shell("input keyevent KEYCODE_ENTER")
                compose.waitUntil(15_000) { compose.onAllNodesWithText(unlock).fetchSemanticsNodes().isEmpty() }
            }
        } finally {
            runBlocking { preferences.updateAppLockEnabled(false) }
            shell("locksettings clear --old $PIN")
        }
    }

    /** The system prompt is the active window while it is up. */
    private fun awaitSystemPrompt() {
        val deadline = SystemClock.uptimeMillis() + 10_000
        while (instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString() != "com.android.systemui") {
            assertTrue("the system prompt shows", SystemClock.uptimeMillis() < deadline)
            Thread.sleep(100)
        }
    }

    private fun shell(command: String): String =
        ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command))
            .use { it.readBytes().decodeToString() }

    private companion object {
        const val PIN = "2468"
    }
}
