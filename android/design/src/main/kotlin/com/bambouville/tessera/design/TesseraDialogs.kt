package com.bambouville.tessera.design

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/**
 * Tessera's standard modal.
 *
 * The structure is the point: title, hairline, a body that scrolls on its own, a
 * hairline, then the action row. Material's `AlertDialog` flows its confirm and
 * dismiss slots through a `FlowRow`, so three actions wrap into a ragged stack and
 * long bodies push the buttons off a short screen. Here the actions are pinned
 * outside the scroll region and cannot collide with the content above them.
 */
@Composable
fun TesseraDialog(
    title: String,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    dismissOnClickOutside: Boolean = true,
    /** Null for a dialog whose content is the whole interaction, such as a picker. */
    actions: (@Composable RowScope.() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Dialog(
        onDismissRequest = onDismissRequest,
        properties = DialogProperties(
            dismissOnClickOutside = dismissOnClickOutside,
            usePlatformDefaultWidth = false,
        ),
    ) {
        Surface(
            modifier = modifier
                .padding(horizontal = 20.dp, vertical = 32.dp)
                .widthIn(max = 420.dp)
                .imePadding(),
            shape = RoundedCornerShape(16.dp),
            // A modal needs to lift off the page it covers. In dark mode the panel
            // token is one step from black, which leaves the sheet reading as a
            // hairline outline over the same surface, so it steps up to the input
            // token instead; light mode's white panel already separates.
            color = if (tokens.isLight) tokens.panelBg else tokens.inputBg,
            border = BorderStroke(1.dp, tokens.borderStrong),
        ) {
            Column {
                Text(
                    title,
                    modifier = Modifier.fillMaxWidth().padding(start = 18.dp, end = 18.dp, top = 18.dp, bottom = 14.dp),
                    style = TesseraType.sheet,
                    color = tokens.fg,
                )
                TesseraHairline()
                Column(
                    modifier = Modifier
                        .weight(1f, fill = false)
                        .verticalScroll(rememberScrollState())
                        .padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    content = content,
                )
                actions?.let {
                    TesseraHairline()
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
                        verticalAlignment = Alignment.CenterVertically,
                        content = it,
                    )
                }
            }
        }
    }
}

/**
 * Full-screen form.
 *
 * A phone-width host or key editor is a form, not an alert: six fields plus pickers
 * do not fit a centred dialog once the IME is up, and anchored menus inside one land
 * on its own buttons. Material's guidance for exactly this case is a full-screen
 * dialog, with cancel and confirm living in a fixed header the content scrolls
 * under.
 */
@Composable
fun TesseraFormDialog(
    title: String,
    onCancel: () -> Unit,
    cancelLabel: String,
    submitLabel: String,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
    submitEnabled: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Dialog(
        onDismissRequest = onCancel,
        // The form owns the whole screen, so it paints edge to edge and applies the
        // system-bar insets itself. Letting the dialog window inset instead leaves
        // grey scrim bands above and below a page that is meant to read as full-screen.
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        Surface(modifier = modifier.fillMaxSize(), color = tokens.bg) {
            Column(
                Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .imePadding(),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 60.dp)
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    TesseraButton(text = cancelLabel, onClick = onCancel, compact = true)
                    Text(
                        title,
                        modifier = Modifier.weight(1f),
                        style = TesseraType.sheet,
                        color = tokens.fg,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                    TesseraButton(
                        text = submitLabel,
                        onClick = onSubmit,
                        style = TesseraButtonStyle.Primary,
                        enabled = submitEnabled,
                        compact = true,
                    )
                }
                TesseraHairline()
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                        .padding(horizontal = 18.dp, vertical = 18.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    content = content,
                )
            }
        }
    }
}

/** Destructive or plain confirmation with a single sentence of consequence. */
@Composable
fun TesseraConfirmDialog(
    title: String,
    body: String,
    confirmLabel: String,
    cancelLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
    destructive: Boolean = false,
    confirmEnabled: Boolean = true,
) {
    TesseraDialog(
        title = title,
        onDismissRequest = onDismiss,
        actions = {
            TesseraButton(text = cancelLabel, onClick = onDismiss, compact = true)
            TesseraButton(
                text = confirmLabel,
                onClick = onConfirm,
                style = if (destructive) TesseraButtonStyle.Danger else TesseraButtonStyle.Primary,
                enabled = confirmEnabled,
                compact = true,
            )
        },
    ) {
        Text(body, style = TesseraType.body, color = LocalTesseraTokens.current.fgMuted)
    }
}

/**
 * Single-choice picker presented as its own surface.
 *
 * Replaces the anchored `DropdownMenu`s that could overlap a dialog's action row:
 * a full list with 52dp rows is also far easier to hit on a phone than a popup
 * sized to its longest label.
 */
@Composable
fun TesseraOptionPicker(
    title: String,
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    onDismiss: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    TesseraDialog(title = title, onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth()) {
            options.forEachIndexed { index, option ->
                val selected = index == selectedIndex
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = 52.dp)
                        .clickable(role = Role.RadioButton) { onSelect(index) }
                        .padding(vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text(
                        option,
                        modifier = Modifier.weight(1f),
                        style = TesseraType.rowTitle,
                        color = if (selected) tokens.accent else tokens.fg,
                    )
                    if (selected) {
                        Icon(
                            TesseraIcons.Check,
                            contentDescription = null,
                            tint = tokens.accent,
                            modifier = Modifier.size(18.dp),
                        )
                    } else {
                        Box(Modifier.size(18.dp))
                    }
                }
                if (index != options.lastIndex) TesseraHairline()
            }
        }
    }
}

/**
 * Vertical action stack for a detail sheet whose actions are peers rather than a
 * confirm/cancel pair — Copy, Share, and Install all do different things and none
 * of them is the dialog's "OK".
 */
@Composable
fun TesseraActionStack(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        content = content,
    )
}
