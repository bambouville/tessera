package com.bambouville.tessera.feature.agentcenter

import android.content.res.Configuration
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isMetaPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertContentDescriptionEquals
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.design.TesseraTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AgentComposerShortcutComposeTest {
    @get:Rule val compose = createAndroidComposeRule<AgentFixtureActivity>()

    private class Fixture(initialDraft: String = "") {
        var draft by mutableStateOf(initialDraft)
        var qwertyKeyboard by mutableStateOf(true)
        var hardKeyboardVisible by mutableStateOf(true)
        var enabled by mutableStateOf(true)
        var sending by mutableStateOf(false)
        var uploading by mutableStateOf(false)
        var sends = 0
        var terminalOpens = 0
        var files = 0
        var photos = 0
    }

    private fun show(initialDraft: String = ""): Fixture {
        val fixture = Fixture(initialDraft)
        compose.activityRule.scenario.onActivity { activity ->
            activity.installFixture {
                val base = LocalConfiguration.current
                val keyboard = Configuration(base).apply {
                    this.keyboard = if (fixture.qwertyKeyboard) Configuration.KEYBOARD_QWERTY else Configuration.KEYBOARD_NOKEYS
                    hardKeyboardHidden = if (fixture.hardKeyboardVisible) Configuration.HARDKEYBOARDHIDDEN_NO
                        else Configuration.HARDKEYBOARDHIDDEN_YES
                }
                CompositionLocalProvider(LocalConfiguration provides keyboard) {
                    TesseraTheme {
                        Box(Modifier.fillMaxSize().onKeyEvent { event ->
                            if (event.type == KeyEventType.KeyDown && event.key == Key.Enter &&
                                (event.isCtrlPressed || event.isMetaPressed)) {
                                fixture.terminalOpens++
                                true
                            } else false
                        }) {
                            Composer(
                                draft = fixture.draft,
                                onDraftChange = { fixture.draft = it },
                                onSend = { fixture.sends++ },
                                onInterrupt = {},
                                onStartSpeech = {},
                                enabled = fixture.enabled,
                                onAttach = { fixture.files++ },
                                onAttachPhoto = { fixture.photos++ },
                                onQueue = null,
                                sending = fixture.sending,
                                uploading = fixture.uploading,
                            )
                        }
                    }
                }
            }
        }
        return fixture
    }

    @Test fun attachmentMenuRoutesFileAndPhotoSeparately() {
        val fixture = show()
        compose.onNodeWithTag("agent-attach").assertContentDescriptionEquals("add attachment").performClick()
        compose.onNodeWithTag("agent-attach-file").performClick()
        compose.runOnIdle { assertEquals(1, fixture.files); assertEquals(0, fixture.photos) }
        compose.onNodeWithTag("agent-attach").performClick()
        compose.onNodeWithTag("agent-attach-photo").performClick()
        compose.runOnIdle { assertEquals(1, fixture.files); assertEquals(1, fixture.photos) }
    }

    @Test fun ctrlEnterSendsOnceWithoutAddingNewline() {
        val fixture = show("ship it")
        compose.onNodeWithTag("agent-composer").performClick().performKeyInput {
            keyDown(Key.CtrlLeft)
            pressKey(Key.Enter)
            keyUp(Key.CtrlLeft)
        }
        compose.runOnIdle {
            assertEquals(1, fixture.sends)
            assertEquals("ship it", fixture.draft)
            assertEquals(0, fixture.terminalOpens)
        }
    }

    @Test fun metaEnterSendsOnceWithoutAddingNewline() {
        val fixture = show("ship it")
        compose.onNodeWithTag("agent-composer").performClick().performKeyInput {
            keyDown(Key.MetaLeft)
            pressKey(Key.Enter)
            keyUp(Key.MetaLeft)
        }
        compose.runOnIdle {
            assertEquals(1, fixture.sends)
            assertEquals("ship it", fixture.draft)
            assertEquals(0, fixture.terminalOpens)
        }
    }

    @Test fun ctrlNumPadEnterSendsOnceWithoutAddingNewline() {
        val fixture = show("ship it")
        compose.onNodeWithTag("agent-composer").performClick().performKeyInput {
            keyDown(Key.CtrlLeft)
            pressKey(Key.NumPadEnter)
            keyUp(Key.CtrlLeft)
        }
        compose.runOnIdle {
            assertEquals(1, fixture.sends)
            assertEquals("ship it", fixture.draft)
            assertEquals(0, fixture.terminalOpens)
        }
    }

    @Test fun blankCtrlEnterIsConsumedBeforeRootTerminalShortcut() {
        val fixture = show()
        compose.onNodeWithTag("agent-composer").performClick().performKeyInput {
            keyDown(Key.CtrlLeft)
            pressKey(Key.Enter)
            keyUp(Key.CtrlLeft)
        }
        compose.runOnIdle {
            assertEquals(0, fixture.sends)
            assertEquals(0, fixture.terminalOpens)
            assertEquals("", fixture.draft)
        }
    }

    @Test fun plainShiftAndNumPadEnterInsertNewlinesWithoutSending() {
        val fixture = show("line")
        compose.onNodeWithTag("agent-composer").performClick().performKeyInput { pressKey(Key.Enter) }
        compose.onNodeWithTag("agent-composer").assertTextContains("line\n")
        compose.onNodeWithTag("agent-composer").performKeyInput {
            keyDown(Key.ShiftLeft)
            pressKey(Key.Enter)
            keyUp(Key.ShiftLeft)
        }
        compose.runOnIdle {
            assertEquals("line\n\n", fixture.draft)
            assertEquals(0, fixture.sends)
        }
        compose.onNodeWithTag("agent-composer").performKeyInput { pressKey(Key.NumPadEnter) }
        compose.runOnIdle {
            assertEquals("line\n\n\n", fixture.draft)
            assertEquals(0, fixture.sends)
        }
    }

    @Test fun shortcutHintRequiresHardwareKeyboardAndSendMode() {
        val fixture = show("ship it")
        fun hintCount() = compose.onAllNodesWithTag("agent-send-shortcut-hint", useUnmergedTree = true)
        hintCount().assertCountEquals(1)
        compose.onNodeWithTag("agent-send").assertContentDescriptionEquals("send")
        compose.onAllNodesWithText("ctrl ↵", useUnmergedTree = true).assertCountEquals(0)
        compose.runOnIdle { fixture.qwertyKeyboard = false }
        hintCount().assertCountEquals(0)
        compose.runOnIdle { fixture.qwertyKeyboard = true; fixture.hardKeyboardVisible = false }
        hintCount().assertCountEquals(0)
        compose.runOnIdle { fixture.hardKeyboardVisible = true; fixture.draft = "" }
        hintCount().assertCountEquals(0)
        compose.runOnIdle { fixture.draft = "ship it"; fixture.sending = true }
        hintCount().assertCountEquals(0)
        compose.runOnIdle { fixture.sending = false }
        hintCount().assertCountEquals(1)
        compose.runOnIdle { fixture.enabled = false }
        hintCount().assertCountEquals(0)
        compose.runOnIdle { fixture.enabled = true }
        hintCount().assertCountEquals(1)
        compose.runOnIdle { fixture.uploading = true }
        hintCount().assertCountEquals(0)
        compose.runOnIdle { fixture.uploading = false }
        hintCount().assertCountEquals(1)
        compose.runOnIdle { fixture.draft = "unsafe\u0001" }
        hintCount().assertCountEquals(0)
        compose.runOnIdle { fixture.draft = "ship it" }
        hintCount().assertCountEquals(1)
    }
}
