package com.bambouville.tessera.feature.session

import android.app.UiAutomation
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.View
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MoshOutageAnnouncementInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()

    @Test fun theClaimedOutageAppearsAsAPoliteLiveRegion() {
        var spoken by mutableStateOf<String?>(null)
        show { MoshOutageAnnouncement(spoken) }
        compose.onAllNodesWithTag(TAG, useUnmergedTree = true).assertCountEquals(0)
        compose.runOnIdle { spoken = TEXT }
        val node = compose.onNodeWithTag(TAG, useUnmergedTree = true)
        node.assert(SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite))
        node.assert(SemanticsMatcher.expectValue(SemanticsProperties.ContentDescription, listOf(TEXT)))
    }

    /**
     * Turns a probe accessibility service on, as a screen reader would be, so
     * it changes the device's accessibility settings (and puts them back):
     * it runs only where the runner passes `-e tesseraDisposableDevice true`.
     */
    @Test fun aScreenReaderHearsTheClaimedOutageOnce() {
        assumeTrue(
            "changes accessibility settings: disposable devices only",
            InstrumentationRegistry.getArguments().getString("tesseraDisposableDevice") == "true",
        )
        // A default UiAutomation would suppress the very service under test.
        val automation = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand(command))
            .use { it.readBytes().decodeToString().trim() }
        val services = shell("settings get secure enabled_accessibility_services")
        val enabled = shell("settings get secure accessibility_enabled")
        try {
            shell("settings put secure enabled_accessibility_services $PROBE")
            shell("settings put secure accessibility_enabled 1")
            val deadline = SystemClock.uptimeMillis() + 10_000
            while (AnnouncementProbeService.connected == null) {
                assertTrue("the probe service connects", SystemClock.uptimeMillis() < deadline)
                Thread.sleep(100)
            }
            AnnouncementProbeService.spoken.clear()
            AnnouncementProbeService.log.clear()
            var spoken by mutableStateOf<String?>(null)
            show { MoshOutageAnnouncement(spoken) }
            assertTrue("nothing is spoken before the claim", listen(1_000).none { it.description != null })

            compose.runOnIdle { spoken = TEXT }
            val heard = listen(1_000)
            assertEquals(
                AnnouncementProbeService.log.joinToString("\n"),
                listOf(AnnouncementProbeService.LiveRegionChange(View.ACCESSIBILITY_LIVE_REGION_POLITE, TEXT)),
                heard.filter { it.description == TEXT },
            )
            assertTrue("the text is spoken once", listen(1_000).none { it.description == TEXT })
        } finally {
            if (services == "null") shell("settings delete secure enabled_accessibility_services")
            else shell("settings put secure enabled_accessibility_services $services")
            if (enabled == "null") shell("settings delete secure accessibility_enabled")
            else shell("settings put secure accessibility_enabled $enabled")
        }
    }

    /** Shows [content] and waits for its first frame: an empty hierarchy holds no node either. */
    private fun show(content: @Composable () -> Unit) {
        compose.setContent { Box(Modifier.fillMaxSize().testTag(HOST)) { content() } }
        compose.waitUntil(5_000) {
            compose.onAllNodesWithTag(HOST).fetchSemanticsNodes(atLeastOneRootRequired = false).size == 1
        }
    }

    /**
     * What the probe hears over [millis] of frames. The test drives Compose's
     * clock, so nothing recomposes, and no event is sent, unless it advances.
     */
    private fun listen(millis: Long): List<AnnouncementProbeService.LiveRegionChange> {
        val heard = mutableListOf<AnnouncementProbeService.LiveRegionChange>()
        repeat((millis / 100).toInt()) {
            compose.mainClock.advanceTimeBy(100)
            compose.waitForIdle()
            AnnouncementProbeService.spoken.poll(100, TimeUnit.MILLISECONDS)?.let(heard::add)
            AnnouncementProbeService.spoken.drainTo(heard)
        }
        return heard
    }

    private companion object {
        const val TAG = "mosh-outage-announcement"
        const val HOST = "mosh-outage-host"
        const val TEXT = "Mosh connection interrupted. Reconnecting."
        const val PROBE = "com.bambouville.tessera.feature.session.test/" +
            "com.bambouville.tessera.feature.session.AnnouncementProbeService"
    }
}
