package com.bambouville.tessera.feature.artifacts

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraStatusDot
import com.bambouville.tessera.design.TesseraType

/** The text a tab's address field starts editing from: the whole address, selected. */
internal fun artifactAddressEditValue(address: String): TextFieldValue {
    val edit = artifactAddressEditStart(address)
    return TextFieldValue(edit.text, TextRange(edit.selectionStart, edit.selectionEnd))
}

/**
 * A tab's address. At rest it shows the host and address; a tap (or Ctrl+L)
 * turns it into a field holding the full address, all selected, so typing
 * replaces it and a second tap places the caret. Return sends the tab to the
 * typed address. Escape, back, or focus moving elsewhere restores it.
 */
@Composable
internal fun ArtifactAddressBar(
    tab: SharedArtifactTab,
    address: String,
    live: Boolean,
    editing: TextFieldValue?,
    onEdit: (TextFieldValue) -> Unit,
    /** Editing ends without navigating. [tappedAway] means focus already went somewhere else. */
    onCancel: (tappedAway: Boolean) -> Unit,
    onSubmit: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    val shape = RoundedCornerShape(8.dp)
    val addressLabel = stringResource(R.string.artifacts_address)
    if (editing == null) {
        Row(
            modifier.fillMaxWidth().heightIn(min = 48.dp)
                .clip(shape).background(tokens.inputBg)
                .border(1.dp, tokens.borderStrong, shape)
                .semantics(mergeDescendants = true) { contentDescription = "$addressLabel, ${tab.hostLabel}, $address" }
                .clickable(role = Role.Button) { onEdit(artifactAddressEditValue(address)) }
                .testTag("artifacts-address").padding(horizontal = 12.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            TesseraStatusDot(if (live) tokens.green else tokens.fgDim, size = 6.dp)
            Column(Modifier.weight(1f)) {
                Text(tab.hostLabel, style = TesseraType.rowMicro, color = tokens.fgDim, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(address, style = TesseraType.rowMeta, color = tokens.fg,
                    maxLines = 1, overflow = TextOverflow.MiddleEllipsis)
            }
        }
        return
    }
    val focus = remember { FocusRequester() }
    // Focus arrives a frame after the field does; only a later loss is tapping away.
    var hadFocus by remember { mutableStateOf(false) }
    val textFocus = LocalArtifactTextFocus.current
    DisposableEffect(textFocus) { onDispose { textFocus?.note("address", false) } }
    Row(
        modifier.fillMaxWidth().heightIn(min = 48.dp)
            .clip(shape).background(tokens.inputBg)
            .border(1.dp, tokens.accent, shape)
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
            if (editing.text.isEmpty()) {
                Text(stringResource(R.string.artifacts_address_placeholder), style = TesseraType.rowTitle, color = tokens.fgDim, maxLines = 1)
            }
            BasicTextField(
                value = editing,
                onValueChange = { onEdit(it) },
                modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)
                    .focusRequester(focus)
                    .onFocusChanged { state ->
                        textFocus?.note("address", state.isFocused)
                        if (state.isFocused) hadFocus = true
                        else if (hadFocus) { hadFocus = false; onCancel(true) }
                    }
                    .onPreviewKeyEvent { event ->
                        when (event.key) {
                            Key.Enter, Key.NumPadEnter -> {
                                if (event.type == KeyEventType.KeyDown) onSubmit(editing.text)
                                true
                            }
                            Key.Escape -> {
                                if (event.type == KeyEventType.KeyDown) onCancel(false)
                                true
                            }
                            else -> false
                        }
                    }
                    .semantics { contentDescription = addressLabel }
                    .testTag("artifacts-address-field"),
                textStyle = TesseraType.rowTitle.copy(color = tokens.fg),
                singleLine = true,
                cursorBrush = SolidColor(tokens.accent),
                keyboardOptions = KeyboardOptions(
                    keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false,
                ),
                keyboardActions = KeyboardActions(onGo = { onSubmit(editing.text) }),
            )
        }
    }
    LaunchedEffect(focus) { focus.requestFocus() }
}
