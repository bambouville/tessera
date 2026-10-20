package com.bambouville.tessera.feature.session

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraBanner
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraLogoMark
import com.bambouville.tessera.design.TesseraType
import kotlinx.coroutines.delay

internal enum class SessionLaunchPhase(val caption: String) {
    CONNECTING("connecting"),
    STARTING_TMUX("starting tmux"),
    ATTACHING_TMUX("attaching tmux"),
    ATTACHING_PANE("attaching pane"),
}

/**
 * Transport-neutral launch/recovery presentation shared by SSH and Mosh screens.
 * The owning controller supplies observable phases; this surface never guesses
 * transport state from elapsed time. The timer only exposes recovery actions if
 * one real phase stops advancing.
 */
@Composable
internal fun SessionLaunchOverlay(
    phase: SessionLaunchPhase,
    subtitle: String?,
    onEditHost: () -> Unit,
    onRetry: () -> Unit,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    failureReason: String? = null,
    animated: Boolean = true,
) {
    val tokens = LocalTesseraTokens.current
    var stalled by remember(phase, failureReason) { mutableStateOf(false) }
    LaunchedEffect(phase, failureReason) {
        if (failureReason == null) {
            delay(STALL_THRESHOLD_MS)
            stalled = true
        }
    }
    Box(
        modifier = modifier.fillMaxSize().background(tokens.bg),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            TesseraLogoMark(size = 58.dp)
            if (failureReason == null) {
                SessionProgressSpinner(
                    animated = animated,
                    color = tokens.accent,
                    strokeWidth = 2.dp,
                    modifier = Modifier.width(28.dp),
                )
                Text(phase.caption, style = TesseraType.code, color = tokens.fg)
                subtitle?.takeIf(String::isNotBlank)?.let {
                    Text(it, style = TesseraType.rowMeta, color = tokens.fgMuted, maxLines = 1)
                }
                if (stalled) {
                    TesseraBanner(
                        text = "Still ${phase.caption}. This stage has not completed; you can retry without force-closing Tessera.",
                        modifier = Modifier.fillMaxWidth(),
                    )
                    RecoveryActions(onEditHost, onRetry, onBack)
                }
            } else {
                Text(
                    "connection failed",
                    style = TesseraType.page,
                    color = tokens.fg,
                    textAlign = TextAlign.Center,
                )
                TesseraBanner(text = failureReason, modifier = Modifier.fillMaxWidth())
                RecoveryActions(onEditHost, onRetry, onBack)
            }
        }
    }
}

/**
 * Full-terminal veil shown while another device holds the shared tmux grid.
 *
 * [peerDisplayName] is already resolved by `SharedTmuxPeerLabel`, so it is a
 * label ("iPad", "another device"), never a raw peer stamp. Copy matches iOS
 * v0.3.6 so the two ends of a takeover say the same thing.
 *
 * R4: only a pointer tap, Enter or a printable key takes control back
 * ([VeilKeyPolicy]). Back, volume, system keys, bare modifiers and Ctrl/Meta
 * chords are left unconsumed, so Back still navigates.
 *
 * [acceptsFocus] is false for a session that is composed but not presented:
 * its veil neither requests nor holds focus, and takes no taps or keys.
 *
 * [awaitingConnection]: a take-back is waiting for the control channel. It
 * reads "takes control when reconnected" and offers [onCancelPending],
 * because the intent expires on its own after about 20 s.
 */
@Composable
internal fun ContinuedElsewhereOverlay(
    peerDisplayName: String,
    onTakeBack: () -> Unit,
    modifier: Modifier = Modifier,
    isReclaiming: Boolean = false,
    acceptsFocus: Boolean = true,
    awaitingConnection: Boolean = false,
    onCancelPending: () -> Unit = {},
) {
    val tokens = LocalTesseraTokens.current
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(acceptsFocus) { if (acceptsFocus) focusRequester.requestFocus() }
    Box(
        modifier = modifier
            .background(tokens.bg.copy(alpha = 0.88f))
            .focusRequester(focusRequester)
            .onPreviewKeyEvent { event ->
                if (!acceptsFocus) return@onPreviewKeyEvent false
                val native = event.nativeKeyEvent
                val admits = VeilKeyPolicy.admitsTakeBack(
                    keyCode = native.keyCode,
                    unicodeChar = native.unicodeChar,
                    ctrlPressed = native.isCtrlPressed,
                    metaPressed = native.isMetaPressed,
                )
                when {
                    !admits -> false
                    isReclaiming -> true
                    event.type == KeyEventType.KeyDown -> {
                        onTakeBack()
                        true
                    }
                    else -> true
                }
            }
            .focusable(enabled = acceptsFocus),
        contentAlignment = Alignment.Center,
    ) {
        // Own the entire pointer surface while a peer has authority. Without a
        // hit target in the empty area, Compose can route taps/gestures through
        // this visual overlay into the terminal or tmux chrome below it.
        Box(
            Modifier
                .fillMaxSize()
                .testTag("continued-elsewhere-surface")
                .clickable(
                    enabled = acceptsFocus,
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = { if (!isReclaiming) onTakeBack() },
                ),
        )
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            TesseraLogoMark(size = 48.dp)
            Text(
                when {
                    awaitingConnection -> "takes control when reconnected"
                    isReclaiming -> "taking back control…"
                    peerDisplayName.isBlank() || peerDisplayName == "another device" -> "continued elsewhere"
                    else -> "continued on $peerDisplayName"
                },
                style = TesseraType.sheet,
                color = tokens.fg,
            )
            // A claim is several server round trips. Holding the card steady
            // and swapping only the headline keeps the veil from looking inert
            // while it runs, which is what made users tap take-back repeatedly.
            if (awaitingConnection) {
                TesseraButton(
                    "cancel",
                    onClick = onCancelPending,
                    compact = true,
                    modifier = Modifier.testTag("tmux-authority-cancel-pending"),
                )
            } else if (!isReclaiming) {
                Text(
                    "This session is being controlled from another device.",
                    style = TesseraType.rowMeta,
                    color = tokens.fgMuted,
                    textAlign = TextAlign.Center,
                )
                TesseraButton(
                    "take back control",
                    onClick = onTakeBack,
                    style = TesseraButtonStyle.Primary,
                )
            }
        }
    }
}

/**
 * The `resuming` projection: the terminal stays visible and readable under
 * this small pill while a show's fresh authority read (and any claim it
 * starts) runs. Input is gated meanwhile. With [awaitingConnection] the show
 * is waiting for the control channel, so it says when it will take effect
 * and can be cancelled.
 */
@Composable
internal fun TmuxResumingIndicator(
    awaitingConnection: Boolean,
    onCancelPending: () -> Unit,
    modifier: Modifier = Modifier,
    animated: Boolean = true,
) {
    val tokens = LocalTesseraTokens.current
    val shape = RoundedCornerShape(14.dp)
    Row(
        modifier = modifier
            .testTag("tmux-authority-resuming")
            .clip(shape)
            .background(tokens.panelBg.copy(alpha = 0.92f))
            .border(1.dp, tokens.border, shape)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (!awaitingConnection) {
            SessionProgressSpinner(
                animated = animated,
                color = tokens.fgMuted,
                strokeWidth = 1.5.dp,
                modifier = Modifier.size(12.dp),
            )
        }
        Text(
            if (awaitingConnection) "takes control when reconnected" else "Resuming…",
            style = TesseraType.rowMeta,
            color = tokens.fg,
        )
        if (awaitingConnection) {
            TesseraButton(
                "cancel",
                onClick = onCancelPending,
                compact = true,
                modifier = Modifier.testTag("tmux-authority-cancel-pending"),
            )
        }
    }
}

/**
 * The indeterminate sweep is a frame-clock animation: it recomposes and
 * redraws every frame for as long as it is composed, and a hidden session is
 * still composed (at alpha 0). It runs only on the session on screen in a
 * foreground app (§6.4 P9); otherwise a still arc of the same size holds its
 * place, so nothing moves when the session is shown.
 */
@Composable
private fun SessionProgressSpinner(
    animated: Boolean,
    color: Color,
    strokeWidth: Dp,
    modifier: Modifier = Modifier,
) {
    if (animated) {
        CircularProgressIndicator(modifier = modifier, color = color, strokeWidth = strokeWidth)
    } else {
        CircularProgressIndicator(
            progress = { STILL_SPINNER_FRACTION },
            modifier = modifier,
            color = color,
            strokeWidth = strokeWidth,
            trackColor = Color.Transparent,
            gapSize = 0.dp,
        )
    }
}

@Composable
private fun RecoveryActions(
    onEditHost: () -> Unit,
    onRetry: () -> Unit,
    onBack: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        TesseraButton("edit host", onClick = onEditHost, compact = true)
        TesseraButton("retry", onClick = onRetry, compact = true, style = TesseraButtonStyle.Primary)
        TesseraButton("back", onClick = onBack, compact = true)
    }
}

private const val STALL_THRESHOLD_MS = 12_000L
private const val STILL_SPINNER_FRACTION = 0.25f
