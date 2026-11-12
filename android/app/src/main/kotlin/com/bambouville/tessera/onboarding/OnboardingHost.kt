package com.bambouville.tessera.onboarding

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.focusGroup
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.union
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.focus.focusProperties
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.R
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.roundToInt

/** The controller for About's buttons; null outside an [OnboardingHost]. */
val LocalOnboardingController: ProvidableCompositionLocal<OnboardingController?> = staticCompositionLocalOf { null }

private val LocalOnboardingAnchors = staticCompositionLocalOf<OnboardingAnchors?> { null }

private data class AnchorBounds(val target: OnboardingTarget, val bounds: Rect, val clippedBounds: Rect)

private class OnboardingAnchors {
    // Each composition owns its entry: disposing an old tab cannot remove a newly mounted anchor.
    val entries = mutableStateMapOf<Any, AnchorBounds>()
}

/** Registers this element's bounds as the spotlight for [target]. No-op outside an [OnboardingHost]. */
fun Modifier.onboardingAnchor(target: OnboardingTarget): Modifier = composed {
    val anchors = LocalOnboardingAnchors.current
    if (anchors == null) return@composed this
    val owner = remember { Any() }
    DisposableEffect(anchors, target) {
        onDispose { anchors.entries.remove(owner) }
    }
    onGloballyPositioned { coordinates ->
        if (coordinates.isAttached) {
            val origin = coordinates.localToWindow(Offset.Zero)
            anchors.entries[owner] = AnchorBounds(
                target,
                Rect(origin.x, origin.y, origin.x + coordinates.size.width, origin.y + coordinates.size.height),
                coordinates.boundsInWindow(),
            )
        } else {
            anchors.entries.remove(owner)
        }
    }
}

/**
 * Overlays welcome, release notes and the walkthrough over [content]. [blocked] suspends presentation,
 * navigation and back handling without consuming a receipt. Pass a loaded [hostCount], or -1 while loading.
 */
@Composable
fun OnboardingHost(
    controller: OnboardingController,
    hostCount: Int,
    blocked: Boolean,
    onNavigate: (OnboardingTarget) -> Unit,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val anchors = remember { OnboardingAnchors() }
    var windowOrigin by remember { mutableStateOf(Offset.Zero) }
    val visible = !blocked && controller.phase != OnboardingPhase.Inactive
    val focusManager = LocalFocusManager.current
    val keyboard = LocalSoftwareKeyboardController.current
    LaunchedEffect(controller, hostCount, blocked, controller.preferences) {
        controller.beginIfNeeded(hostCount, blocked)
    }
    val target = if (controller.phase == OnboardingPhase.Touring) {
        controller.steps.getOrNull(controller.stepIndex)?.target
    } else null
    LaunchedEffect(controller, visible, target, controller.stepIndex) {
        if (visible) {
            focusManager.clearFocus(force = true)
            keyboard?.hide()
            target?.let(onNavigate)
        }
    }

    CompositionLocalProvider(LocalOnboardingController provides controller, LocalOnboardingAnchors provides anchors) {
        Box(modifier.fillMaxSize().onGloballyPositioned { windowOrigin = it.localToWindow(Offset.Zero) }) {
            // The tour is passive: the cutout never exposes live controls to touch or accessibility.
            Box(
                Modifier.focusProperties {
                    onEnter = { if (visible) cancelFocusChange() }
                }.focusGroup().then(if (visible) Modifier.clearAndSetSemantics { } else Modifier),
            ) { content() }
            if (visible) {
                OnboardingLayer(controller, anchors, windowOrigin)
                // Composed after the shell's handlers so the gesture belongs to this overlay.
                BackHandler {
                    if (controller.phase == OnboardingPhase.Touring) controller.back() else controller.finish()
                }
            }
        }
    }
}

@Composable
private fun OnboardingLayer(controller: OnboardingController, anchors: OnboardingAnchors, windowOrigin: Offset) {
    val density = LocalDensity.current
    val direction = LocalLayoutDirection.current
    val insets = WindowInsets.safeDrawing.union(WindowInsets.ime)
    val leftInset = insets.getLeft(density, direction)
    val topInset = insets.getTop(density)
    val rightInset = insets.getRight(density, direction)
    val bottomInset = insets.getBottom(density)
    val target = if (controller.phase == OnboardingPhase.Touring) {
        controller.steps.getOrNull(controller.stepIndex)?.target
    } else null
    // Read snapshot state in composition, including bounds changes caused by scrolling or tab replacement.
    val candidates = anchors.entries.values.filter { it.target == target }
    val walkthroughTitle = stringResource(R.string.app_onboarding_pane_title)
    SubcomposeLayout(Modifier.fillMaxSize().semantics { paneTitle = walkthroughTitle }) { constraints ->
        val width = constraints.maxWidth
        val height = constraints.maxHeight
        val margin = 16.dp.roundToPx()
        val gap = 16.dp.roundToPx()
        val safe = Rect(leftInset.toFloat(), topInset.toFloat(), (width - rightInset).toFloat(), (height - bottomInset).toFloat())
        val viewport = Rect(
            safe.left + margin, safe.top + margin,
            (safe.right - margin).coerceAtLeast(safe.left + margin),
            (safe.bottom - margin).coerceAtLeast(safe.top + margin),
        )
        val anchor = candidates.asReversed().firstOrNull { it.isFullyVisible(windowOrigin, safe) }
            ?.bounds?.relativeTo(windowOrigin)
        val above = anchor?.let { (it.top - gap - viewport.top).coerceAtLeast(0f) } ?: 0f
        val below = anchor?.let { (viewport.bottom - it.bottom - gap).coerceAtLeast(0f) } ?: 0f
        // Short landscape/IME viewports use the centered, scrolling card rather than a clipped callout.
        val spotlight = anchor?.takeIf { maxOf(above, below) >= 220.dp.toPx() }
        val placeBelow = below > above
        val cardWidth = min(440.dp.roundToPx(), viewport.width.roundToInt()).coerceAtLeast(0)
        val maxCardHeight = (if (spotlight == null) viewport.height else maxOf(above, below)).roundToInt().coerceAtLeast(0)
        val card = subcompose("card") {
            OnboardingCard(controller, centered = spotlight == null)
        }.single().measure(Constraints(minWidth = cardWidth, maxWidth = cardWidth, maxHeight = maxCardHeight))
        val cardX = (viewport.left + (viewport.width - card.width) / 2f).roundToInt()
        val cardY = when {
            spotlight == null -> (viewport.top + (viewport.height - card.height) / 2f).roundToInt()
            placeBelow -> (spotlight.bottom + gap).roundToInt()
            else -> (spotlight.top - gap - card.height).roundToInt()
        }
        val scrim = subcompose("scrim") { OnboardingScrim(spotlight) }
            .single().measure(Constraints.fixed(width, height))
        val arrow = if (spotlight != null) subcompose("arrow") {
            OnboardingArrow(pointsUp = placeBelow)
        }.single().measure(Constraints.fixed(16.dp.roundToPx(), 9.dp.roundToPx())) else null
        layout(width, height) {
            scrim.place(0, 0)
            card.place(cardX, cardY)
            if (arrow != null && spotlight != null) {
                val x = (spotlight.center.x - arrow.width / 2f).roundToInt()
                    .coerceIn(cardX + 16.dp.roundToPx(), maxOf(cardX + 16.dp.roundToPx(), cardX + card.width - arrow.width - 16.dp.roundToPx()))
                arrow.place(x, if (placeBelow) cardY - arrow.height + 1 else cardY + card.height - 1)
            }
        }
    }
}

private fun Rect.relativeTo(origin: Offset): Rect = Rect(left - origin.x, top - origin.y, right - origin.x, bottom - origin.y)

private fun AnchorBounds.isFullyVisible(origin: Offset, safe: Rect): Boolean {
    val local = bounds.relativeTo(origin)
    return bounds.width > 0f && bounds.height > 0f &&
        local.left >= safe.left && local.top >= safe.top && local.right <= safe.right && local.bottom <= safe.bottom &&
        abs(clippedBounds.left - bounds.left) < 1f && abs(clippedBounds.top - bounds.top) < 1f &&
        abs(clippedBounds.right - bounds.right) < 1f && abs(clippedBounds.bottom - bounds.bottom) < 1f
}

@Composable
private fun OnboardingScrim(spotlight: Rect?) {
    val tokens = com.bambouville.tessera.design.LocalTesseraTokens.current
    Canvas(
        Modifier.fillMaxSize()
            .testTag(if (spotlight == null) "onboarding-dim" else "onboarding-spotlight")
            .pointerInput(Unit) { detectTapGestures { /* Passive tour: consume taps even inside the cutout. */ } },
    ) {
        val hole = spotlight?.inflate(4.dp.toPx())
        val path = Path().apply {
            fillType = PathFillType.EvenOdd
            addRect(Rect(Offset.Zero, size))
            if (hole != null) addRoundRect(RoundRect(hole, CornerRadius(10.dp.toPx())))
        }
        drawPath(path, Color.Black.copy(alpha = 0.76f))
        if (hole != null) drawRoundRect(
            tokens.fgMuted, hole.topLeft, hole.size, CornerRadius(10.dp.toPx()), style = Stroke(1.dp.toPx()),
        )
    }
}

@Composable
private fun OnboardingArrow(pointsUp: Boolean) {
    val tokens = com.bambouville.tessera.design.LocalTesseraTokens.current
    Canvas(Modifier) {
        val path = Path().apply {
            moveTo(0f, if (pointsUp) size.height else 0f)
            lineTo(size.width / 2f, if (pointsUp) 0f else size.height)
            lineTo(size.width, if (pointsUp) size.height else 0f)
            close()
        }
        drawPath(path, tokens.panelBg)
        drawPath(path, tokens.borderStrong, style = Stroke(1.dp.toPx()))
    }
}
