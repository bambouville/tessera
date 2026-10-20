package com.bambouville.tessera.feature.session

import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.CustomAccessibilityAction

internal enum class TmuxWindowSplitOption(val vertical: Boolean, val before: Boolean, val label: Int) {
    RIGHT(false, false, R.string.tmux_split_right),
    LEFT(false, true, R.string.tmux_split_left),
    DOWN(true, false, R.string.tmux_split_down),
    UP(true, true, R.string.tmux_split_up),
}

@Composable
internal fun TmuxWindowSplitMenuItems(onSplit: (TmuxWindowSplitOption) -> Unit) {
    TmuxWindowSplitOption.entries.forEach { option ->
        DropdownMenuItem(text = { Text(stringResource(option.label)) }, onClick = { onSplit(option) })
    }
}

@Composable
internal fun tmuxWindowSplitAccessibilityActions(onSplit: ((TmuxWindowSplitOption) -> Unit)?): List<CustomAccessibilityAction> {
    if (onSplit == null) return emptyList()
    return TmuxWindowSplitOption.entries.map { option ->
        CustomAccessibilityAction(stringResource(option.label)) { onSplit(option); true }
    }
}

/** Resolve only the active pane still owned by the chosen live window. */
internal fun tmuxWindowSplitTargetPane(window: com.bambouville.tessera.core.bridge.SharedTmuxWindow): Int? =
    window.activePaneId?.takeIf { id -> window.panes.any { it.id == id } }
