package com.bambouville.tessera

import android.os.Bundle
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import java.io.ByteArrayOutputStream
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.core.graphics.createBitmap
import com.bambouville.tessera.data.AppPreferences
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraPageHeader
import com.bambouville.tessera.design.TesseraTheme
import com.bambouville.tessera.feature.agentcenter.AgentCenterHarnessScene
import com.bambouville.tessera.feature.agentcenter.AgentCenterVisualHarness
import com.bambouville.tessera.feature.session.SessionHarnessScene
import com.bambouville.tessera.feature.session.SessionVisualHarness
import com.bambouville.tessera.files.FilesHarnessScene
import com.bambouville.tessera.files.RemoteFilesVisualHarness
import com.bambouville.tessera.terminal.TerminalBackgroundImageStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Debug-only visual harness.
 *
 * Terminal chrome, the software-keyboard accessory, the tmux window/pane bars,
 * host-key prompts, and every Remote Files state exist only while an SSH session is
 * live — and UI automation must never open one. This activity renders those exact
 * shipping composables against typed mock state so they can be reviewed and
 * screenshotted on a device, mirroring the iOS `TESSERA_FILES_HARNESS` pattern.
 *
 * It is declared only in the debug manifest and built only from the debug source
 * set, so it cannot reach a release build. Nothing here touches the network, the
 * Keystore, or the app's real database.
 *
 *   adb shell am start -n com.bambouville.tessera.debug/com.bambouville.tessera.TesseraHarnessActivity
 *   adb shell am start ... -e scene tmux
 */
class TesseraHarnessActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val requested = intent.getStringExtra(SCENE_EXTRA)
        val forceDark = intent.getStringExtra(THEME_EXTRA)
        val resizeTerminalWithKeyboard = intent.getBooleanExtra(RESIZE_TERMINAL_EXTRA, false)
        val terminalFixture = intent.getStringExtra(TERMINAL_FIXTURE_EXTRA) ?: "fresh"
        val showControls = !intent.getBooleanExtra(HIDE_CONTROLS_EXTRA, false)
        enableEdgeToEdge()
        if (requested?.startsWith("setup-") == true) {
            setContent {
                TesseraTheme(darkTheme = forceDark == "dark") {
                    com.bambouville.tessera.feature.pairing.SetupFlowVisualHarness(requested)
                }
            }
            return
        }
        if (requested == "agent-composer") {
            setContent {
                TesseraTheme {
                    CompactRootScaffold(CompactRootTab.Agents, true, {}, Modifier.fillMaxSize()) { padding ->
                        com.bambouville.tessera.feature.agentcenter.AgentComposerKeyboardFixture(
                            Modifier.fillMaxSize().agentCenterContentPadding(padding))
                    }
                }
            }
            return
        }
        setContent {
            val dark = when (forceDark) {
                "dark" -> true
                "light" -> false
                else -> androidx.compose.foundation.isSystemInDarkTheme()
            }
            TesseraTheme(darkTheme = dark) {
                HarnessShell(
                    initialScene = requested,
                    resizeTerminalWithKeyboard = resizeTerminalWithKeyboard,
                    terminalFixture = terminalFixture,
                    showControls = showControls,
                )
            }
        }
    }

    private companion object {
        const val SCENE_EXTRA = "scene"
        const val THEME_EXTRA = "theme"
        const val RESIZE_TERMINAL_EXTRA = "resize_terminal_with_keyboard"
        const val TERMINAL_FIXTURE_EXTRA = "terminal_fixture"
        const val HIDE_CONTROLS_EXTRA = "hide_controls"
    }
}

private sealed interface HarnessScene {
    /** Stable, space-free identifier for `am start -e scene <slug>`. */
    val slug: String
    val label: String

    data class Session(val scene: SessionHarnessScene) : HarnessScene {
        override val slug: String get() = scene.slug
        override val label: String get() = scene.label
    }

    data class Files(val scene: FilesHarnessScene) : HarnessScene {
        override val slug: String get() = scene.slug
        override val label: String get() = scene.label
    }

    data object TerminalSettings : HarnessScene {
        override val slug = "settings"
        override val label = "terminal settings"
    }

    data class Agents(val scene: AgentCenterHarnessScene) : HarnessScene {
        override val slug: String get() = scene.slug
        override val label: String get() = scene.label
    }
}

private val allScenes: List<HarnessScene> =
    SessionHarnessScene.entries.map(HarnessScene::Session) +
        FilesHarnessScene.entries.map(HarnessScene::Files) +
        listOf(HarnessScene.TerminalSettings) +
        AgentCenterHarnessScene.entries.map(HarnessScene::Agents)

@Composable
private fun HarnessShell(
    initialScene: String?,
    resizeTerminalWithKeyboard: Boolean,
    terminalFixture: String,
    showControls: Boolean,
) {
    val tokens = LocalTesseraTokens.current
    var selected by remember {
        mutableStateOf(allScenes.firstOrNull { it.slug == initialScene } ?: allScenes.first())
    }
    // These controls are debug-harness state, not Settings. They let one instrumentation
    // activity exercise both keyboard policies and cursor placements without a host.
    var selectedTerminalFixture by remember { mutableStateOf(terminalFixture) }
    var resizeWithKeyboard by remember { mutableStateOf(resizeTerminalWithKeyboard) }
    Surface(Modifier.fillMaxSize(), color = tokens.bg) {
        Column(Modifier.fillMaxSize()) {
            Box(
                Modifier
                    .weight(1f)
                    .then(if (selected is HarnessScene.Session) Modifier else Modifier.statusBarsPadding()),
            ) {
                when (val scene = selected) {
                    is HarnessScene.Session -> SessionVisualHarness(
                        scene = scene.scene,
                        modifier = Modifier.fillMaxSize(),
                        resizeTerminalWithKeyboard = resizeWithKeyboard,
                        terminalFixture = selectedTerminalFixture,
                    )
                    is HarnessScene.Files -> RemoteFilesVisualHarness(scene.scene, Modifier.fillMaxSize())
                    HarnessScene.TerminalSettings -> TerminalSettingsVisualHarness(Modifier.fillMaxSize())
                    is HarnessScene.Agents -> AgentCenterVisualHarness(scene.scene, Modifier.fillMaxSize())
                }
            }
            if (showControls) {
                TesseraHairline()
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(tokens.panelBg)
                        .horizontalScroll(rememberScrollState())
                        .navigationBarsPadding()
                        .padding(horizontal = 8.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                allScenes.forEach { scene ->
                    TesseraButton(
                        text = scene.label,
                        onClick = { selected = scene },
                        modifier = Modifier.testTag("harness-${scene.slug}"),
                        style = if (scene == selected) TesseraButtonStyle.Primary else TesseraButtonStyle.Default,
                        compact = true,
                    )
                }
                if (selected is HarnessScene.Session &&
                    (selected as HarnessScene.Session).scene == SessionHarnessScene.TerminalConnected
                ) {
                    listOf("fresh", "middle", "tail", "alt", "mouse").forEach { fixture ->
                        TesseraButton(
                            text = fixture,
                            onClick = { selectedTerminalFixture = fixture },
                            modifier = Modifier.testTag("harness-fixture-$fixture"),
                            style = if (selectedTerminalFixture == fixture) {
                                TesseraButtonStyle.Primary
                            } else {
                                TesseraButtonStyle.Default
                            },
                            compact = true,
                        )
                    }
                    TesseraButton(
                        text = if (resizeWithKeyboard) "resize: on" else "resize: off",
                        onClick = { resizeWithKeyboard = !resizeWithKeyboard },
                        modifier = Modifier.testTag("harness-resize-terminal"),
                        style = if (resizeWithKeyboard) TesseraButtonStyle.Primary else TesseraButtonStyle.Default,
                        compact = true,
                    )
                }
                }
            }
        }
    }
}

@Composable
private fun TerminalSettingsVisualHarness(modifier: Modifier = Modifier) {
    val tokens = LocalTesseraTokens.current
    val context = androidx.compose.ui.platform.LocalContext.current
    var preferences by remember {
        mutableStateOf(
            AppPreferences(
                terminalBackgroundUsesImage = false,
                terminalBackgroundDim = 0.5f,
                terminalBackgroundBlur = 0,
                smoothScrollingEnabled = true,
                smoothScrollingSpeed = 0.5f,
            ),
        )
    }
    LaunchedEffect(Unit) {
        val imported = withContext(Dispatchers.IO) {
            TerminalBackgroundImageStore(context).importImage(settingsBackgroundFixture())
        }
        if (imported != null) {
            preferences = preferences.copy(
                terminalBackgroundUsesImage = true,
                terminalBackgroundImageId = imported.imageId,
            )
        }
    }
    Column(
        modifier
            .background(tokens.bg)
            .statusBarsPadding()
            .verticalScroll(rememberScrollState()),
    ) {
        TesseraPageHeader("terminal settings")
        TesseraHairline()
        TesseraKicker("appearance", Modifier.padding(start = 18.dp, top = 18.dp, bottom = 6.dp))
        TerminalBackgroundSettings(
            preferences = preferences,
            onExternalUiActiveChanged = {},
            onUsesImageChanged = { preferences = preferences.copy(terminalBackgroundUsesImage = it) },
            onImageChanged = { preferences = preferences.copy(terminalBackgroundImageId = it) },
            onDimChanged = { preferences = preferences.copy(terminalBackgroundDim = it) },
            onBlurChanged = { preferences = preferences.copy(terminalBackgroundBlur = it) },
            onFillModeChanged = { preferences = preferences.copy(terminalBackgroundFillMode = it) },
            modifier = Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp),
        )
        TesseraHairline(Modifier.padding(start = 18.dp))
        SmoothScrollingSettings(
            enabled = preferences.smoothScrollingEnabled,
            speed = preferences.smoothScrollingSpeed,
            onEnabledChanged = { preferences = preferences.copy(smoothScrollingEnabled = it) },
            onSpeedChanged = { preferences = preferences.copy(smoothScrollingSpeed = it) },
        )
        TesseraHairline(Modifier.padding(start = 18.dp))
        AccessoryBarEditor(
            persistedKeys = preferences.accessoryBarKeys,
            notation = preferences.modifierNotation,
            onKeysChanged = { preferences = preferences.copy(accessoryBarKeys = it) },
            modifier = Modifier.padding(horizontal = 18.dp, vertical = 12.dp),
        )
        androidx.compose.foundation.layout.Spacer(Modifier.height(32.dp))
    }
}

private fun settingsBackgroundFixture(): ByteArray {
    val bitmap = createBitmap(720, 960, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(Color.rgb(2, 8, 18))
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    paint.color = Color.rgb(16, 83, 187)
    canvas.drawCircle(560f, 220f, 260f, paint)
    paint.color = Color.rgb(19, 185, 190)
    canvas.drawCircle(130f, 780f, 220f, paint)
    return ByteArrayOutputStream().use { bytes ->
        check(bitmap.compress(Bitmap.CompressFormat.JPEG, 90, bytes))
        bytes.toByteArray()
    }
}
