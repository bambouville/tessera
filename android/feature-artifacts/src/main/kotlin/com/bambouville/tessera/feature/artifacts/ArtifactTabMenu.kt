package com.bambouville.tessera.feature.artifacts

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraHairline
import com.bambouville.tessera.design.TesseraIconButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraType

/** True while the app lock covers the browser; its popups must not stay above it. */
internal val LocalArtifactsLocked = compositionLocalOf { false }

@Composable
internal fun ArtifactTabMenu(
    tab: SharedArtifactTab,
    canKeepAsRule: Boolean,
    /** Only where no + is on screen: a tab on a phone. */
    onNewTab: (() -> Unit)?,
    onPin: () -> Unit,
    onClose: () -> Unit,
    onCloseAll: () -> Unit,
    onKeepAsRule: () -> Unit,
    onCopyPath: () -> Unit,
    onOpenBrowser: (() -> Unit)?,
) {
    var expanded by remember(tab.id) { mutableStateOf(false) }
    // Popup menus own windows above the activity's lock overlay.
    val locked = LocalArtifactsLocked.current
    LaunchedEffect(locked) { if (locked) expanded = false }
    val tokens = LocalTesseraTokens.current
    Box {
        TesseraIconButton(TesseraIcons.MoreVertical, stringResource(R.string.artifacts_tab_menu), { expanded = true }, Modifier.testTag("artifacts-tab-menu"))
        DropdownMenu(
            expanded = expanded && !locked, onDismissRequest = { expanded = false },
            containerColor = tokens.panelBg,
            tonalElevation = 0.dp, shadowElevation = 0.dp,
            border = BorderStroke(1.dp, tokens.borderStrong),
        ) {
            onNewTab?.let { newTab ->
                ArtifactMenuItem(stringResource(R.string.artifacts_new_tab), "artifacts-menu-new-tab") { expanded = false; newTab() }
                TesseraHairline()
            }
            ArtifactMenuItem(stringResource(if (tab.pinned) R.string.artifacts_unpin_tab else R.string.artifacts_pin_tab), "artifacts-menu-pin") {
                expanded = false; onPin()
            }
            if (canKeepAsRule) ArtifactMenuItem(stringResource(R.string.artifacts_keep_as_rule), "artifacts-menu-keep") {
                expanded = false; onKeepAsRule()
            }
            ArtifactMenuItem(stringResource(R.string.artifacts_copy_path), "artifacts-menu-copy") { expanded = false; onCopyPath() }
            if (tab.kind == SharedArtifactsKind.Pages) ArtifactMenuItem(
                stringResource(R.string.artifacts_open_in_browser), "artifacts-menu-browser", enabled = onOpenBrowser != null,
            ) {
                expanded = false; onOpenBrowser?.invoke()
            }
            TesseraHairline()
            ArtifactMenuItem(stringResource(R.string.artifacts_close_tab), "artifacts-menu-close", danger = true) { expanded = false; onClose() }
            ArtifactMenuItem(stringResource(R.string.artifacts_close_all_on_host, tab.hostLabel), "artifacts-menu-close-host", danger = true) {
                expanded = false; onCloseAll()
            }
        }
    }
}

@Composable
private fun ArtifactMenuItem(text: String, tag: String, danger: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val tokens = LocalTesseraTokens.current
    DropdownMenuItem(
        text = { Text(text, style = TesseraType.button, color = if (!enabled) tokens.fgDim else if (danger) tokens.red else tokens.fg) },
        onClick = onClick, enabled = enabled,
        modifier = Modifier.heightIn(min = 48.dp).testTag(tag),
    )
}
