package com.bambouville.tessera

import android.graphics.Bitmap
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.text.TextLayoutResult
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.platform.app.InstrumentationRegistry
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.feature.agentcenter.AgentComposerKeyboardFixture
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

/** Production compact scaffold, bottom tabs and detail; native IME; no sessions. */
class AgentComposerKeyboardInstrumentedTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun composerMatchesTranscriptAndMeetsNativeKeyboard(): Unit {
        val stage = InstrumentationRegistry.getArguments().getString("tesseraComposerStage") ?: "after"
        require(stage in setOf("before", "after"))
        compose.activityRule.scenario.onActivity {
            it.enableEdgeToEdge()
            it.window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)
        }
        compose.setContent {
            TesseraTheme {
                CompactRootScaffold(CompactRootTab.Agents, true, {}, Modifier.fillMaxSize()) { padding ->
                    AgentComposerKeyboardFixture(Modifier.fillMaxSize().agentCenterContentPadding(padding))
                }
            }
        }
        val field = compose.onNodeWithTag("agent-composer")
        field.performClick()
        compose.waitUntil(5_000) { imeBottom() > 0 }
        for (lines in listOf(1, 5)) {
            field.performTextReplacement((1..lines).joinToString("\n") { "Check the next instruction." })
            compose.waitForIdle()
            android.os.SystemClock.sleep(1_600)
            val root = compose.activity.window.decorView
            val location = IntArray(2).also(root::getLocationOnScreen)
            val keyboardTop = location[1] + root.height - imeBottom()
            val frame = compose.onNodeWithTag("agent-composer-frame").fetchSemanticsNode().boundsInWindow
            val gapDP = (keyboardTop - frame.bottom) / root.resources.displayMetrics.density
            val text = mutableListOf<TextLayoutResult>()
            field.performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(text) }
            val transcript = mutableListOf<TextLayoutResult>()
            compose.onNodeWithText("Ready for the next instruction.").performSemanticsAction(SemanticsActions.GetTextLayoutResult) { it(transcript) }
            assertEquals(1, text.size)
            assertEquals(1, transcript.size)
            val fontSize = text.single().layoutInput.style.fontSize.value
            val bodySize = transcript.single().layoutInput.style.fontSize.value
            val context = InstrumentationRegistry.getInstrumentation().targetContext
            val metrics = "stage=$stage lines=$lines gapDP=$gapDP font=$fontSize body=$bodySize keyboardTop=$keyboardTop frame=$frame"
            File(context.filesDir, "composer-$stage-$lines.txt").writeText(metrics)
            val shot = requireNotNull(InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot())
            File(context.filesDir, "composer-$stage-$lines.png").outputStream().use { check(shot.compress(Bitmap.CompressFormat.PNG, 100, it)) }
            shot.recycle()
            android.util.Log.i("TesseraComposer", metrics)
            if (stage == "before") {
                assertTrue("fixture must reproduce the extra keyboard gap: $metrics", gapDP > 40)
                assertTrue("fixture must reproduce smaller input: $metrics", fontSize < bodySize)
            } else {
                assertTrue("composer must sit just above the native keyboard: $metrics", gapDP in 0f..12f)
                assertEquals(bodySize, fontSize, 0.01f)
                assertEquals(transcript.single().layoutInput.style.fontFamily, text.single().layoutInput.style.fontFamily)
            }
        }
        android.util.Log.i("TesseraComposer", "TESSERA_COMPOSER_KEYBOARD_OK stage=$stage")
    }

    private fun imeBottom(): Int = ViewCompat.getRootWindowInsets(compose.activity.window.decorView)
        ?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0
}
