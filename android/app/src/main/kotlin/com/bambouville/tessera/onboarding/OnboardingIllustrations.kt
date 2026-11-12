package com.bambouville.tessera.onboarding

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.R
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraType

/** Static diagrams, never live controls or sessions. The prose above carries their accessible explanation. */
@Composable
internal fun OnboardingIllustrationView(illustration: OnboardingIllustration) {
    Column(
        Modifier.fillMaxWidth().clearAndSetSemantics { },
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        when (illustration) {
            OnboardingIllustration.Keys -> IllustrationPanel {
                DiagramRow(TesseraIcons.Settings, stringResource(R.string.app_tab_settings), stringResource(R.string.app_settings_security))
                TesseraHairline()
                DiagramRow(TesseraIcons.Keys, stringResource(R.string.app_settings_keys), stringResource(R.string.app_illus_keys_detail))
                DiagramRow(TesseraIcons.Shield, stringResource(R.string.app_settings_known_hosts), stringResource(R.string.app_illus_known_hosts_detail))
            }
            OnboardingIllustration.Tmux -> IllustrationPanel {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    DiagramChip("shell", selected = true)
                    DiagramChip("build")
                    DiagramChip("+")
                }
                TesseraHairline()
                DiagramText("~/project $ git status")
                DiagramText("on branch main")
                DiagramText("working tree clean")
                TesseraHairline()
                DiagramRow(TesseraIcons.SplitHorizontal, stringResource(R.string.app_illus_windows_panes), stringResource(R.string.app_illus_windows_panes_detail))
            }
            OnboardingIllustration.Agents -> IllustrationPanel {
                DiagramRow(TesseraIcons.Agents, stringResource(R.string.app_agent_center), stringResource(R.string.app_illus_agent_center_detail))
                TesseraHairline()
                DiagramRow(TesseraIcons.Pulse, "Claude Code · api-01", stringResource(R.string.app_illus_working))
                DiagramRow(TesseraIcons.Alert, "Codex · build-box", stringResource(R.string.app_illus_needs_input))
            }
            OnboardingIllustration.PromptControls -> IllustrationPanel {
                DiagramText(stringResource(R.string.app_illus_allow_command))
                DiagramChip(stringResource(R.string.app_illus_allow_once), selected = true)
                DiagramChip(stringResource(R.string.app_illus_always_allow))
                DiagramChip(stringResource(R.string.app_illus_deny))
                DiagramText(stringResource(R.string.app_illus_type_reply))
            }
            OnboardingIllustration.Files -> IllustrationPanel {
                DiagramRow(TesseraIcons.Folder, stringResource(R.string.app_illus_files), "~/project/docs")
                TesseraHairline()
                DiagramRow(TesseraIcons.File, "README.md", stringResource(R.string.app_open_in_artifacts))
                DiagramRow(TesseraIcons.File, "notes.txt", "12 KB")
                DiagramRow(TesseraIcons.Download, "report.pdf", stringResource(R.string.app_illus_downloading))
            }
            OnboardingIllustration.OpenInArtifacts -> {
                IllustrationPanel {
                    DiagramText(stringResource(R.string.app_illus_selection_toolbar))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        DiagramChip(stringResource(R.string.app_illus_copy))
                        DiagramChip(stringResource(R.string.app_illus_paste))
                    }
                    DiagramChip(stringResource(R.string.app_open_in_artifacts), selected = true)
                    DiagramText(stringResource(R.string.app_illus_reveal_in_files))
                }
                IllustrationPanel {
                    DiagramRow(TesseraIcons.MoreVertical, "README.md", stringResource(R.string.app_illus_file_menu))
                    TesseraHairline()
                    DiagramChip(stringResource(R.string.app_open_in_artifacts), selected = true)
                    DiagramText(stringResource(R.string.app_illus_share))
                    DiagramText(stringResource(R.string.app_illus_download))
                    DiagramText(stringResource(R.string.app_illus_insert_path))
                }
            }
            OnboardingIllustration.Share -> IllustrationPanel {
                DiagramRow(TesseraIcons.Share, stringResource(R.string.app_illus_remote_to_app), stringResource(R.string.app_illus_share_in_menu))
                TesseraHairline()
                DiagramRow(TesseraIcons.Upload, stringResource(R.string.app_illus_app_to_tessera), stringResource(R.string.app_illus_choose_destination))
                DiagramChip(stringResource(R.string.app_illus_upload), selected = true)
            }
            OnboardingIllustration.Screenshot -> IllustrationPanel {
                DiagramRow(TesseraIcons.Share, stringResource(R.string.app_illus_screenshot_to_tessera), stringResource(R.string.app_illus_android_share_sheet))
                DiagramRow(TesseraIcons.Check, stringResource(R.string.app_illus_paste_path), stringResource(R.string.app_illus_after_upload))
                TesseraHairline()
                DiagramText("$ claude")
                DiagramText("~/.cache/tessera/paste-….png")
            }
            OnboardingIllustration.TerminalControls -> IllustrationPanel {
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    DiagramChip("esc")
                    DiagramChip("tab")
                    DiagramChip("ctrl", selected = true)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                    DiagramChip("←")
                    DiagramChip("↓")
                    DiagramChip("↑")
                    DiagramChip("→")
                }
                TesseraHairline()
                DiagramText(stringResource(R.string.app_illus_tap_modifier))
                DiagramText(stringResource(R.string.app_illus_sticky_in_settings))
            }
        }
    }
}

@Composable
private fun IllustrationPanel(content: @Composable ColumnScope.() -> Unit) {
    val tokens = LocalTesseraTokens.current
    Surface(
        Modifier.fillMaxWidth(), color = tokens.inputBgSoft, shape = RoundedCornerShape(10.dp),
        border = BorderStroke(1.dp, tokens.border),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(9.dp), content = content)
    }
}

@Composable
private fun DiagramRow(icon: ImageVector, title: String, detail: String) {
    val tokens = LocalTesseraTokens.current
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(18.dp), tint = tokens.fgMuted)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, style = TesseraType.rowMeta, color = tokens.fg, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(detail, style = TesseraType.bodySmall, color = tokens.fgMuted)
        }
    }
}

@Composable
private fun DiagramText(text: String) {
    Text(text, style = TesseraType.code, color = LocalTesseraTokens.current.fgMuted)
}

@Composable
private fun DiagramChip(text: String, selected: Boolean = false) {
    val tokens = LocalTesseraTokens.current
    Surface(
        color = if (selected) tokens.inputBg else tokens.panelBg,
        shape = RoundedCornerShape(5.dp),
        border = BorderStroke(1.dp, if (selected) tokens.fgMuted else tokens.borderStrong),
    ) {
        Text(text, Modifier.padding(horizontal = 10.dp, vertical = 7.dp), style = TesseraType.rowMeta, color = tokens.fg)
    }
}
