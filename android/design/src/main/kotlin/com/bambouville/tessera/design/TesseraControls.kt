package com.bambouville.tessera.design

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

/**
 * Labelled input.
 *
 * Built on `BasicTextField` rather than `OutlinedTextField` because Material's
 * floating-label treatment fights the design: the label animates into the border,
 * the container is filled and rounded to Material's radius, and the whole control
 * is visually louder than the hairline surfaces around it. iOS states the label
 * above a plain bordered box; this is that, with Android focus and IME behaviour.
 */
@Composable
fun TesseraTextField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    /** Applied to the editable control rather than its decorative field shell. */
    inputModifier: Modifier = Modifier,
    label: String? = null,
    placeholder: String? = null,
    supporting: String? = null,
    /**
     * Test tag for the editable node. Tagging the outer column instead would put the
     * tag on a node that carries no `SetText` action, so a text-entry assertion would
     * find the field but be unable to type into it.
     */
    inputTestTag: String? = null,
    enabled: Boolean = true,
    singleLine: Boolean = true,
    isError: Boolean = false,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    leading: ImageVector? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val tokens = LocalTesseraTokens.current
    val interactionSource = remember { MutableInteractionSource() }
    val focused by interactionSource.collectIsFocusedAsState()
    val borderColor = when {
        isError -> tokens.red
        focused -> tokens.accent
        else -> tokens.borderStrong
    }
    Column(modifier) {
        label?.let {
            Text(
                it,
                modifier = Modifier.padding(bottom = 6.dp),
                style = TesseraType.fieldLabel,
                color = tokens.fgMuted,
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(tokens.inputBg)
                .border(1.dp, borderColor, RoundedCornerShape(8.dp))
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            leading?.let {
                Icon(it, contentDescription = null, tint = tokens.fgDim, modifier = Modifier.size(18.dp))
            }
            Box(Modifier.weight(1f), contentAlignment = Alignment.CenterStart) {
                if (value.isEmpty() && placeholder != null) {
                    Text(placeholder, style = TesseraType.rowTitle, color = tokens.fgDim, maxLines = 1)
                }
                BasicTextField(
                    value = value,
                    onValueChange = onValueChange,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 12.dp)
                        .then(inputModifier)
                        .then(if (inputTestTag == null) Modifier else Modifier.testTag(inputTestTag)),
                    enabled = enabled,
                    textStyle = TesseraType.rowTitle.copy(color = tokens.fg),
                    singleLine = singleLine,
                    cursorBrush = SolidColor(tokens.accent),
                    keyboardOptions = keyboardOptions,
                    keyboardActions = keyboardActions,
                    visualTransformation = visualTransformation,
                    interactionSource = interactionSource,
                )
            }
            trailing?.invoke()
        }
        supporting?.let {
            Text(
                it,
                modifier = Modifier.padding(top = 6.dp),
                style = TesseraType.bodySmall,
                color = if (isError) tokens.red else tokens.fgDim,
            )
        }
    }
}

/** Search input: the text field with a leading magnifier and a clear affordance. */
@Composable
fun TesseraSearchField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    clearContentDescription: String,
    modifier: Modifier = Modifier,
    inputModifier: Modifier = Modifier,
    inputTestTag: String? = null,
) {
    TesseraTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier,
        inputModifier = inputModifier,
        placeholder = placeholder,
        inputTestTag = inputTestTag,
        leading = TesseraIcons.Search,
        trailing = if (value.isEmpty()) null else {
            {
                TesseraIconButton(
                    icon = TesseraIcons.Close,
                    contentDescription = clearContentDescription,
                    onClick = { onValueChange("") },
                    modifier = Modifier.size(36.dp),
                )
            }
        },
    )
}

/**
 * Read-only field that opens a picker.
 *
 * Deliberately not an anchored dropdown: a popup anchored inside a dialog is what
 * put the host editor's authentication menu on top of its own Save/Cancel row.
 * This states the current value in place and hands selection to a picker that owns
 * the whole surface.
 */
@Composable
fun TesseraSelectField(
    label: String,
    value: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    inputTestTag: String? = null,
    enabled: Boolean = true,
) {
    val tokens = LocalTesseraTokens.current
    Column(modifier) {
        Text(
            label,
            modifier = Modifier.padding(bottom = 6.dp),
            style = TesseraType.fieldLabel,
            color = tokens.fgMuted,
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 48.dp)
                .then(if (inputTestTag == null) Modifier else Modifier.testTag(inputTestTag))
                .clip(RoundedCornerShape(8.dp))
                .background(tokens.inputBg)
                .border(1.dp, tokens.borderStrong, RoundedCornerShape(8.dp))
                .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                value,
                modifier = Modifier.weight(1f),
                style = TesseraType.rowTitle,
                color = if (enabled) tokens.fg else tokens.fgDim,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Icon(
                TesseraIcons.ChevronDown,
                contentDescription = null,
                tint = tokens.fgDim,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

/**
 * Equal-width choice strip for two to four mutually exclusive options that are
 * short enough to read at a glance (a session mode, a transport).
 */
@Composable
fun TesseraSegmented(
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 44.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(tokens.inputBgSoft)
            .border(1.dp, tokens.border, RoundedCornerShape(8.dp))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        options.forEachIndexed { index, option ->
            val selected = index == selectedIndex
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .heightIn(min = 38.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(if (selected) tokens.accentSoft else Color.Transparent)
                    .border(
                        1.dp,
                        if (selected) tokens.accent.copy(alpha = 0.45f) else Color.Transparent,
                        RoundedCornerShape(6.dp),
                    )
                    .selectableRole(selected) { onSelect(index) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    option,
                    style = TesseraType.button,
                    color = if (selected) tokens.accent else tokens.fgMuted,
                    maxLines = 1,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

private fun Modifier.selectableRole(selected: Boolean, onClick: () -> Unit): Modifier =
    this.semantics { this.role = Role.RadioButton }.clickable(onClick = onClick)

/** Switch row: mono title, sans explanation, accent switch. */
@Composable
fun TesseraToggleRow(
    title: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    enabled: Boolean = true,
    /**
     * Settings rows carry the page gutter; a row nested inside a card must not, or
     * its title hangs indented from the fields above and below it.
     */
    contentPadding: PaddingValues = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
) {
    val tokens = LocalTesseraTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            // One switch for TalkBack, named by the title and subtitle text it merges.
            .toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange)
            .padding(contentPadding),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f).padding(end = 14.dp)) {
            Text(title, style = TesseraType.rowTitle, color = tokens.fg)
            subtitle?.let {
                Text(
                    it,
                    modifier = Modifier.padding(top = 3.dp),
                    style = TesseraType.bodySmall,
                    color = tokens.fgMuted,
                )
            }
        }
        Switch(
            checked = checked,
            onCheckedChange = null,
            enabled = enabled,
            modifier = Modifier.minimumInteractiveComponentSize().clearAndSetSemantics {},
            colors = SwitchDefaults.colors(
                checkedThumbColor = if (tokens.isLight) Color.White else Color.Black,
                checkedTrackColor = tokens.accent,
                checkedBorderColor = tokens.accent,
                uncheckedThumbColor = tokens.fgDim,
                uncheckedTrackColor = tokens.inputBgSoft,
                uncheckedBorderColor = tokens.borderStrong,
            ),
        )
    }
}

/** Row that navigates to a sub-page. */
@Composable
fun TesseraNavigationRow(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    subtitle: String? = null,
    icon: ImageVector? = null,
) {
    val tokens = LocalTesseraTokens.current
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = 56.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(start = 18.dp, end = 10.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        icon?.let {
            Icon(it, contentDescription = null, tint = tokens.fgMuted, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = TesseraType.rowTitle, color = tokens.fg)
            subtitle?.let {
                Text(
                    it,
                    modifier = Modifier.padding(top = 3.dp),
                    style = TesseraType.bodySmall,
                    color = tokens.fgMuted,
                )
            }
        }
        Icon(
            TesseraIcons.ChevronRight,
            contentDescription = null,
            tint = tokens.fgDim,
            modifier = Modifier.size(18.dp),
        )
    }
}

/**
 * Flat value slider.
 *
 * Hand-drawn rather than Material's: the expressive `Slider` renders a tick dot per
 * step (32 of them for the text-size range, which is what made the settings track
 * look like a dotted rule) and a tall pill handle. This keeps the platform's
 * gesture and accessibility contract — drag, tap-to-position, and a `setProgress`
 * semantics action for TalkBack — over Tessera's hairline geometry.
 */
@Composable
fun TesseraSlider(
    value: Float,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    stepSize: Float = 0f,
    contentDescription: String? = null,
    onValueChangeFinished: ((Float) -> Unit)? = null,
) {
    val tokens = LocalTesseraTokens.current
    val thumbRadius = 10.dp
    val currentOnValueChange by rememberUpdatedState(onValueChange)
    val currentOnValueChangeFinished by rememberUpdatedState(onValueChangeFinished)
    val currentValue by rememberUpdatedState(value)

    fun quantize(raw: Float): Float {
        val clamped = raw.coerceIn(valueRange.start, valueRange.endInclusive)
        if (stepSize <= 0f) return clamped
        val steps = ((clamped - valueRange.start) / stepSize).roundToInt()
        return (valueRange.start + steps * stepSize).coerceIn(valueRange.start, valueRange.endInclusive)
    }

    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(44.dp)
            .semantics {
                contentDescription?.let { this.contentDescription = it }
                progressBarRangeInfo = ProgressBarRangeInfo(value, valueRange)
                setProgress { target ->
                    if (!enabled) false else {
                        val finalValue = quantize(target)
                        currentOnValueChange(finalValue)
                        currentOnValueChangeFinished?.invoke(finalValue)
                        true
                    }
                }
            },
        contentAlignment = Alignment.CenterStart,
    ) {
        val fraction = if (valueRange.endInclusive > valueRange.start) {
            ((value - valueRange.start) / (valueRange.endInclusive - valueRange.start)).coerceIn(0f, 1f)
        } else {
            0f
        }
        androidx.compose.foundation.Canvas(
            modifier = Modifier
                .fillMaxWidth()
                .height(44.dp)
                .pointerInput(enabled, valueRange, stepSize) {
                    if (!enabled) return@pointerInput
                    detectTapGestures { offset ->
                        val finalValue = quantize(positionToValue(offset.x, size.width, thumbRadius.toPx(), valueRange))
                        currentOnValueChange(finalValue)
                        currentOnValueChangeFinished?.invoke(finalValue)
                    }
                }
                .pointerInput(enabled, valueRange, stepSize) {
                    if (!enabled) return@pointerInput
                    var latestValue = currentValue
                    detectHorizontalDragGestures(
                        onDragEnd = { currentOnValueChangeFinished?.invoke(latestValue) },
                        onDragCancel = { currentOnValueChangeFinished?.invoke(latestValue) },
                    ) { change, _ ->
                        latestValue = quantize(positionToValue(change.position.x, size.width, thumbRadius.toPx(), valueRange))
                        currentOnValueChange(latestValue)
                    }
                },
        ) {
            val radius = thumbRadius.toPx()
            val trackHeight = 3.dp.toPx()
            val left = radius
            val right = size.width - radius
            val centerY = size.height / 2f
            drawRoundRect(
                color = tokens.fgFaint,
                topLeft = Offset(left, centerY - trackHeight / 2f),
                size = Size((right - left).coerceAtLeast(0f), trackHeight),
                cornerRadius = CornerRadius(trackHeight / 2f, trackHeight / 2f),
            )
            val activeWidth = (right - left) * fraction
            drawRoundRect(
                color = if (enabled) tokens.accent else tokens.fgDim,
                topLeft = Offset(left, centerY - trackHeight / 2f),
                size = Size(activeWidth.coerceAtLeast(0f), trackHeight),
                cornerRadius = CornerRadius(trackHeight / 2f, trackHeight / 2f),
            )
            val thumbX = left + activeWidth
            drawCircle(color = tokens.bg, radius = radius, center = Offset(thumbX, centerY))
            drawCircle(
                color = if (enabled) tokens.fg else tokens.fgDim,
                radius = radius - 1.dp.toPx(),
                center = Offset(thumbX, centerY),
            )
        }
    }
}

private fun positionToValue(
    x: Float,
    width: Int,
    thumbRadiusPx: Float,
    valueRange: ClosedFloatingPointRange<Float>,
): Float {
    val usable = (width - 2 * thumbRadiusPx).coerceAtLeast(1f)
    val fraction = ((x - thumbRadiusPx) / usable).coerceIn(0f, 1f)
    return valueRange.start + fraction * (valueRange.endInclusive - valueRange.start)
}

/** Flat progress track. Null progress renders the indeterminate sweep. */
@Composable
fun TesseraProgressTrack(
    progress: Float?,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    if (progress == null) {
        androidx.compose.material3.LinearProgressIndicator(
            modifier = modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)),
            color = tokens.accent,
            trackColor = tokens.fgFaint,
            strokeCap = androidx.compose.ui.graphics.StrokeCap.Round,
        )
    } else {
        androidx.compose.material3.LinearProgressIndicator(
            progress = { progress.coerceIn(0f, 1f) },
            modifier = modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(2.dp)),
            color = tokens.accent,
            trackColor = tokens.fgFaint,
            strokeCap = androidx.compose.ui.graphics.StrokeCap.Round,
            gapSize = 0.dp,
            drawStopIndicator = {},
        )
    }
}
