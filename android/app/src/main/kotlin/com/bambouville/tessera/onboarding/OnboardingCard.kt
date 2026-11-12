package com.bambouville.tessera.onboarding

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bambouville.tessera.R
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraKicker
import com.bambouville.tessera.design.TesseraLogoMark
import com.bambouville.tessera.design.TesseraType

@Composable
internal fun OnboardingCard(controller: OnboardingController, centered: Boolean) {
    val tokens = LocalTesseraTokens.current
    val firstAction = remember { FocusRequester() }
    Surface(
        modifier = Modifier.fillMaxWidth().testTag(if (centered) "onboarding-centered" else "onboarding-callout")
            .focusProperties { onExit = { cancelFocusChange() } }.focusGroup(),
        shape = RoundedCornerShape(16.dp),
        color = tokens.panelBg,
        border = BorderStroke(1.dp, tokens.borderStrong),
    ) {
        key(controller.phase, controller.stepIndex) {
            LaunchedEffect(Unit) { firstAction.requestFocus() }
            Column {
                // Only the body scrolls; all actions stay above safeDrawing and the IME, even on a phone in landscape.
                Column(
                    Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    when (controller.phase) {
                        OnboardingPhase.Welcome -> {
                            TesseraLogoMark(64.dp, Modifier.align(Alignment.CenterHorizontally))
                            CardTitle(stringResource(R.string.app_onboarding_welcome_title), centered = true)
                            Text(
                                stringResource(R.string.app_onboarding_welcome_body),
                                style = TesseraType.body, color = tokens.fgMuted, textAlign = TextAlign.Center,
                            )
                        }
                        OnboardingPhase.WhatsNew -> WhatsNewBody()
                        OnboardingPhase.Touring -> {
                            val step = controller.steps[controller.stepIndex]
                            TesseraKicker(
                                stringResource(R.string.app_onboarding_step_count, controller.stepIndex + 1, controller.steps.size),
                            )
                            CardTitle(stringResource(step.title))
                            Text(stringResource(step.body), style = TesseraType.body, color = tokens.fgMuted)
                            if (centered) step.illustration?.let { OnboardingIllustrationView(it) }
                        }
                        OnboardingPhase.Inactive -> Unit
                    }
                }
                TesseraHairline()
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (controller.phase == OnboardingPhase.Touring) {
                        Row(
                            Modifier.align(Alignment.CenterHorizontally).clearAndSetSemantics { },
                            horizontalArrangement = Arrangement.spacedBy(5.dp),
                        ) {
                            controller.steps.forEachIndexed { index, _ ->
                                Box(Modifier.size(5.dp).clip(RoundedCornerShape(3.dp))
                                    .background(if (index == controller.stepIndex) tokens.fg else tokens.fgFaint))
                            }
                        }
                    }
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        when (controller.phase) {
                            OnboardingPhase.Welcome -> {
                                TesseraButton(stringResource(R.string.app_onboarding_start_tour), controller::replayWalkthrough, Modifier.weight(1f).focusRequester(firstAction), style = TesseraButtonStyle.Primary)
                                TesseraButton(stringResource(R.string.app_onboarding_skip), controller::finish)
                            }
                            OnboardingPhase.WhatsNew -> {
                                TesseraButton(stringResource(R.string.app_onboarding_show_me), controller::showMoves, Modifier.weight(1f).focusRequester(firstAction), style = TesseraButtonStyle.Primary)
                                TesseraButton(stringResource(R.string.app_done), controller::finish)
                            }
                            OnboardingPhase.Touring -> {
                                TesseraButton(stringResource(R.string.app_onboarding_skip), controller::finish, Modifier.focusRequester(firstAction))
                                Spacer(Modifier.weight(1f))
                                if (controller.stepIndex > 0) TesseraIconButton(
                                    TesseraIcons.ChevronLeft, stringResource(R.string.app_onboarding_back), controller::back, tint = tokens.fg,
                                )
                                TesseraButton(
                                    stringResource(
                                        if (controller.stepIndex == controller.steps.lastIndex) R.string.app_done else R.string.app_onboarding_next,
                                    ),
                                    controller::next,
                                    style = TesseraButtonStyle.Primary,
                                )
                            }
                            OnboardingPhase.Inactive -> Unit
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CardTitle(title: String, centered: Boolean = false) {
    Text(
        title, Modifier.fillMaxWidth().semantics { heading() },
        style = TesseraType.sheet, color = LocalTesseraTokens.current.fg,
        textAlign = if (centered) TextAlign.Center else TextAlign.Start,
    )
}

@Composable
private fun WhatsNewBody() {
    val tokens = LocalTesseraTokens.current
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) { TesseraLogoMark(56.dp) }
    CardTitle(stringResource(R.string.app_whats_new_title))
    Text(stringResource(R.string.app_whats_new_body), style = TesseraType.body, color = tokens.fgMuted)
    PlacesBar("before", listOf("hosts", "sessions", "agents", "keys", "settings"))
    PlacesBar("now", listOf("hosts", "sessions", "agents", "artifacts", "settings"))
    MoveRow(stringResource(R.string.app_tab_artifacts), stringResource(R.string.app_whats_new_artifacts_body), TesseraIcons.File)
    MoveRow(stringResource(R.string.app_whats_new_keys_title), stringResource(R.string.app_whats_new_keys_body), TesseraIcons.Keys)
    MoveRow(stringResource(R.string.app_open_in_artifacts), stringResource(R.string.app_whats_new_open_body), TesseraIcons.File)
    Text(stringResource(R.string.app_whats_new_again), style = TesseraType.bodySmall, color = tokens.fgDim)
}

@Composable
private fun PlacesBar(label: String, places: List<String>) {
    val tokens = LocalTesseraTokens.current
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        TesseraKicker(
            stringResource(if (label == "before") R.string.app_whats_new_before else R.string.app_whats_new_now),
        )
        Surface(color = tokens.inputBgSoft, shape = RoundedCornerShape(8.dp), border = BorderStroke(1.dp, tokens.border)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp, vertical = 10.dp)) {
                places.forEach { place ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        val icon = when (place) {
                            "hosts" -> TesseraIcons.Hosts
                            "sessions" -> TesseraIcons.Sessions
                            "agents" -> TesseraIcons.Agents
                            "keys" -> TesseraIcons.Keys
                            "settings" -> TesseraIcons.Settings
                            else -> TesseraIcons.File
                        }
                        Icon(icon, null, Modifier.size(19.dp), tint = tokens.fgMuted)
                        Text(
                            stringResource(
                                when (place) {
                                    "hosts" -> R.string.app_tab_hosts
                                    "sessions" -> R.string.app_tab_sessions
                                    "agents" -> R.string.app_tab_agents
                                    "keys" -> R.string.app_settings_keys
                                    "settings" -> R.string.app_tab_settings
                                    else -> R.string.app_tab_artifacts
                                },
                            ),
                            style = TesseraType.navLabel.copy(fontSize = 10.sp, lineHeight = 14.sp),
                            color = if (place == "artifacts") tokens.fg else tokens.fgMuted,
                            textDecoration = if (label == "before" && place == "keys") TextDecoration.LineThrough else null,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun MoveRow(title: String, body: String, icon: androidx.compose.ui.graphics.vector.ImageVector) {
    val tokens = LocalTesseraTokens.current
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(icon, null, Modifier.size(20.dp), tint = tokens.fgMuted)
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, style = TesseraType.section, color = tokens.fg)
            Text(body, style = TesseraType.bodySmall, color = tokens.fgMuted)
        }
    }
}
