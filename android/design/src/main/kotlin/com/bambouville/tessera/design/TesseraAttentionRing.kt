package com.bambouville.tessera.design

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

/** Outer diameter of the steady attention ring around a status dot. */
val TesseraAttentionRingDiameter = 12.dp

/** Farthest the onset ripple reaches from the dot's centre. Containers that
 * clip must leave this much room around the dot or the ripple is cut off. */
val TesseraAttentionRingRippleRadius = TesseraAttentionRingDiameter

private val AttentionRingStroke = 1.5.dp
private const val AttentionRipples = 3
private const val AttentionRippleMillis = 800

/**
 * True when the system "Remove animations" setting (animator duration scale 0)
 * is on. Motion that only draws attention must be skipped entirely then, not
 * merely shortened.
 */
fun tesseraSystemAnimationsRemoved(context: Context): Boolean = runCatching {
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
}.getOrDefault(false)

/**
 * A thin ring drawn around a status dot, outside the dot's layout box. When it
 * enters composition it ripples outward [AttentionRipples] times (scale 1→2,
 * fading out) and then stays as a static ring. It never blinks continuously.
 */
@Composable
internal fun TesseraAttentionRing(color: Color, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val ripple = remember { Animatable(0f) }
    var rippling by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        // Compose mirrors the system animator scale here; the settings read
        // covers hosts that do not install a MotionDurationScale.
        val composeScale = coroutineContext[MotionDurationScale]?.scaleFactor
        if (composeScale == 0f || tesseraSystemAnimationsRemoved(context)) return@LaunchedEffect
        rippling = true
        try {
            repeat(AttentionRipples) {
                ripple.snapTo(0f)
                ripple.animateTo(1f, tween(AttentionRippleMillis, easing = LinearOutSlowInEasing))
            }
        } finally {
            rippling = false
        }
    }
    // requiredSize lets the ring overflow the dot's smaller box, centred,
    // without changing the size the dot reports to its parent.
    Spacer(
        modifier
            .requiredSize(TesseraAttentionRingDiameter)
            .drawBehind {
                val stroke = AttentionRingStroke.toPx()
                val radius = (size.minDimension - stroke) / 2f
                drawCircle(color, radius = radius, style = Stroke(stroke))
                if (rippling) {
                    val progress = ripple.value
                    drawCircle(
                        color.copy(alpha = color.alpha * (1f - progress)),
                        radius = radius * (1f + progress),
                        style = Stroke(stroke),
                    )
                }
            },
    )
}
