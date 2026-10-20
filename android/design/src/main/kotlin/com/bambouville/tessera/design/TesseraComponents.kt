package com.bambouville.tessera.design

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.material3.ripple
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/** 1dp separator in the `border` token. The app's only rule weight. */
@Composable
fun TesseraHairline(modifier: Modifier = Modifier) {
    Box(
        modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(LocalTesseraTokens.current.border),
    )
}

/**
 * Uppercase micro section label. Applies the case change, tracking, and muted
 * colour together so no call site has to remember the combination — the previous
 * hand-rolled kickers drifted into three different sizes and two colours.
 */
@Composable
fun TesseraKicker(text: String, modifier: Modifier = Modifier) {
    Text(
        text.uppercase(),
        modifier = modifier,
        style = TesseraType.kicker,
        color = LocalTesseraTokens.current.fgMuted,
    )
}

/** The Tessera mark: an outer rounded square in `fg` with an inset accent square. */
@Composable
fun TesseraLogoMark(size: androidx.compose.ui.unit.Dp, modifier: Modifier = Modifier) {
    val tokens = LocalTesseraTokens.current
    Canvas(modifier.size(size)) {
        val scale = this.size.minDimension / 140f
        drawRoundRect(
            color = tokens.fg,
            topLeft = Offset(22f * scale, 22f * scale),
            size = Size(96f * scale, 96f * scale),
            cornerRadius = CornerRadius(22f * scale, 22f * scale),
        )
        drawRoundRect(
            color = tokens.accent,
            topLeft = Offset(34f * scale, 34f * scale),
            size = Size(26f * scale, 26f * scale),
            cornerRadius = CornerRadius(5f * scale, 5f * scale),
        )
    }
}

/**
 * Root-page header: a large mono title with optional trailing actions.
 *
 * `hero` is reserved for the Hosts landing page, matching the single oversized
 * header iOS allows itself.
 */
@Composable
fun TesseraPageHeader(
    title: String,
    modifier: Modifier = Modifier,
    hero: Boolean = false,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 18.dp, end = 10.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            title,
            modifier = Modifier.weight(1f),
            style = if (hero) TesseraType.hero else TesseraType.page,
            color = LocalTesseraTokens.current.fg,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        trailing()
    }
}

/**
 * Sub-page header with the back affordance in Android's leading position.
 *
 * iOS puts the dismiss control wherever the presentation came from; on Android the
 * back control belongs at the start of the bar, at a full touch target, in `fg`
 * rather than a muted tint — a navigation affordance the user cannot find is worse
 * than one that is slightly louder than the page.
 *
 * The header also owns the system back gesture, because on Android the edge swipe
 * and this chevron are the same act. Wiring it here rather than at each call site
 * is what keeps a new sub-page from shipping with a gesture that leaves the app
 * instead of the page — which is how known hosts, diagnostics and the per-host
 * forwarding editor each shipped. Every call site composes the header only while
 * its page is on screen, so the innermost one open is always the one that answers.
 */
@Composable
fun TesseraSubPageHeader(
    title: String,
    onBack: () -> Unit,
    backContentDescription: String,
    modifier: Modifier = Modifier,
    trailing: @Composable RowScope.() -> Unit = {},
) {
    BackHandler(onBack = onBack)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 4.dp, end = 10.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        TesseraIconButton(
            icon = TesseraIcons.ChevronLeft,
            contentDescription = backContentDescription,
            onClick = onBack,
            prominent = true,
        )
        Text(
            title,
            modifier = Modifier.weight(1f).padding(start = 2.dp),
            style = TesseraType.sheet,
            color = LocalTesseraTokens.current.fg,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        trailing()
    }
}

enum class TesseraButtonStyle { Primary, Default, Danger }

@Composable
fun TesseraButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    style: TesseraButtonStyle = TesseraButtonStyle.Default,
    enabled: Boolean = true,
    compact: Boolean = false,
    icon: ImageVector? = null,
) {
    val tokens = LocalTesseraTokens.current
    val container = when (style) {
        TesseraButtonStyle.Primary -> tokens.fg
        TesseraButtonStyle.Default -> tokens.inputBg
        TesseraButtonStyle.Danger -> Color.Transparent
    }
    val content = when (style) {
        TesseraButtonStyle.Primary -> if (tokens.isLight) Color.White else Color.Black
        TesseraButtonStyle.Default -> tokens.fg
        TesseraButtonStyle.Danger -> tokens.red
    }
    val border = when (style) {
        TesseraButtonStyle.Primary -> tokens.fg
        TesseraButtonStyle.Default -> tokens.borderStrong
        TesseraButtonStyle.Danger -> tokens.red
    }
    // A disabled control must read as *less* present, not more. Fading the primary
    // style's solid fill produces a mid-grey slab that outweighs every enabled
    // control near it, so disabled drops to one flat dim outline for all styles.
    Row(
        modifier = modifier
            .minimumInteractiveComponentSize()
            .heightIn(min = if (compact) 40.dp else 48.dp)
            .clip(RoundedCornerShape(6.dp))
            .background(if (enabled) container else tokens.inputBgSoft)
            .border(1.dp, if (enabled) border else tokens.border, RoundedCornerShape(6.dp))
            .clickable(
                enabled = enabled,
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(),
                role = Role.Button,
                onClick = onClick,
            )
            .padding(horizontal = if (compact) 12.dp else 16.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val tint = if (enabled) content else tokens.fgDim
        icon?.let { Icon(it, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp)) }
        Text(text, style = TesseraType.button, color = tint, maxLines = 1)
    }
}

/**
 * Square icon affordance. 48dp so every glyph in a header or row meets the
 * platform touch minimum; the drawn icon stays at 22dp so the bar keeps the
 * app's light visual weight.
 */
@Composable
fun TesseraIconButton(
    icon: ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    danger: Boolean = false,
    enabled: Boolean = true,
    prominent: Boolean = false,
    /**
     * Overrides the glyph colour for a button whose colour carries state of
     * its own (the forwarding glyph turns green while a tunnel is serving).
     * [selected] still draws its highlight; disabled and danger still win.
     */
    tint: Color? = null,
) {
    val tokens = LocalTesseraTokens.current
    val iconTint = when {
        !enabled -> tokens.fgDim
        danger -> tokens.red
        tint != null -> tint
        selected -> tokens.accent
        prominent -> tokens.fg
        else -> tokens.fgMuted
    }
    Box(
        modifier = modifier
            .size(48.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) tokens.accentSoft else Color.Transparent)
            .semantics { this.contentDescription = contentDescription }
            .clickable(
                enabled = enabled,
                interactionSource = remember { MutableInteractionSource() },
                indication = ripple(bounded = false, radius = 22.dp),
                role = Role.Button,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(22.dp))
    }
}

/** Bordered square that carries a row's type glyph (host, key, file, folder). */
@Composable
fun TesseraRowGlyph(
    icon: ImageVector,
    modifier: Modifier = Modifier,
    tint: Color? = null,
    badge: Color? = null,
) {
    val tokens = LocalTesseraTokens.current
    Box(modifier.size(36.dp)) {
        Box(
            Modifier
                .size(36.dp)
                .clip(RoundedCornerShape(8.dp))
                .background(tokens.inputBgSoft)
                .border(1.dp, tokens.border, RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = tint ?: tokens.fgMuted, modifier = Modifier.size(19.dp))
        }
        badge?.let {
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .size(10.dp)
                    .clip(RoundedCornerShape(5.dp))
                    .background(tokens.bg),
                contentAlignment = Alignment.Center,
            ) {
                Box(Modifier.size(7.dp).clip(RoundedCornerShape(4.dp)).background(it))
            }
        }
    }
}

/**
 * Connection-state dot. Colour is the state; size never changes.
 *
 * [attention] surrounds the dot with a thin ring in [attentionColor] without
 * recolouring the dot, so connection state stays readable. The ring is drawn
 * outside the dot's box and never changes layout; it ripples briefly when it
 * appears (see [TesseraAttentionRingRippleRadius] for the room it needs) and
 * then holds still.
 */
@Composable
fun TesseraStatusDot(
    color: Color,
    modifier: Modifier = Modifier,
    size: androidx.compose.ui.unit.Dp = 8.dp,
    attention: Boolean = false,
    attentionColor: Color = LocalTesseraTokens.current.amber,
    attentionRingModifier: Modifier = Modifier,
) {
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Box(Modifier.matchParentSize().clip(RoundedCornerShape(size / 2)).background(color))
        if (attention) TesseraAttentionRing(attentionColor, attentionRingModifier)
    }
}

/** Accent-tinted status pill: "open", "connecting", "reconnect". */
@Composable
fun TesseraTag(
    text: String,
    modifier: Modifier = Modifier,
    tone: Color? = null,
) {
    val tokens = LocalTesseraTokens.current
    val color = tone ?: tokens.accent
    Text(
        text,
        modifier = modifier
            .clip(RoundedCornerShape(5.dp))
            .background(color.copy(alpha = 0.14f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
        style = TesseraType.rowMicro,
        color = color,
        maxLines = 1,
    )
}

/** Hairline-bordered container for grouped content. */
@Composable
fun TesseraCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Surface(
        modifier = modifier,
        color = tokens.panelBg,
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, tokens.border),
    ) {
        Column(Modifier.padding(14.dp), content = content)
    }
}

enum class TesseraBannerTone { Error, Warning, Info }

/** Inline message strip for validation failures and transport errors. */
@Composable
fun TesseraBanner(
    text: String,
    modifier: Modifier = Modifier,
    tone: TesseraBannerTone = TesseraBannerTone.Error,
) {
    val tokens = LocalTesseraTokens.current
    val color = when (tone) {
        TesseraBannerTone.Error -> tokens.red
        TesseraBannerTone.Warning -> tokens.amber
        TesseraBannerTone.Info -> tokens.accent
    }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(color.copy(alpha = 0.10f))
            .border(1.dp, color.copy(alpha = 0.35f), RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(9.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(TesseraIcons.Alert, contentDescription = null, tint = color, modifier = Modifier.size(17.dp))
        Text(text, style = TesseraType.bodySmall, color = tokens.fg)
    }
}

/**
 * Centred empty state.
 *
 * The mark slot exists because the two kinds of emptiness read differently: a page
 * the user has never populated gets the Tessera mark and an invitation, while a
 * filtered or transient emptiness gets a plain line icon and a fact.
 */
@Composable
fun TesseraEmptyState(
    title: String,
    body: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    mark: (@Composable () -> Unit)? = null,
    action: (@Composable () -> Unit)? = null,
) {
    val tokens = LocalTesseraTokens.current
    Column(
        modifier = modifier.padding(horizontal = 32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        when {
            mark != null -> mark()
            icon != null -> Icon(
                icon,
                contentDescription = null,
                tint = tokens.fgDim,
                modifier = Modifier.size(40.dp),
            )
        }
        Text(
            title,
            modifier = Modifier.padding(top = 20.dp),
            style = TesseraType.sheet,
            color = tokens.fg,
            textAlign = TextAlign.Center,
        )
        Text(
            body,
            modifier = Modifier.padding(top = 8.dp).widthIn(max = 340.dp),
            style = TesseraType.body,
            color = tokens.fgMuted,
            textAlign = TextAlign.Center,
        )
        action?.let {
            Spacer(Modifier.height(22.dp))
            it()
        }
    }
}
