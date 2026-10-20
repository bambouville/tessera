package com.bambouville.tessera.files

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraIcons
import com.bambouville.tessera.design.TesseraProgressTrack
import com.bambouville.tessera.design.TesseraType

/**
 * The in-flight transfers of a session, shown over the terminal while the files
 * panel is closed.
 *
 * iOS keeps its upload sheet on screen for the whole transfer, so the progress
 * bar, the cancel and the background hand-off all live on that sheet. Android
 * routes the share to the session and dismisses the sheet before a byte moves,
 * which leaves the same needs with nowhere to live — and a share to the temp
 * directory deliberately does not open the panel, so without this the upload is
 * invisible until its toast. The strip is the non-modal answer: it reports and
 * it cancels, and because it never blocks the terminal there is no modal to
 * "continue in background" out of.
 */
@Composable
fun RemoteTransferStrip(
    items: List<TransferItem>,
    onCancel: (TransferItem) -> Unit,
    onOpenPanel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val head = items.firstOrNull() ?: return
    val tokens = LocalTesseraTokens.current
    val total = head.totalBytes
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(8.dp))
            .background(tokens.panelBg)
            .border(1.dp, tokens.border, RoundedCornerShape(8.dp))
            // The panel is the full queue; the strip is a peek at the head of
            // it, so tapping through to the real thing is the obvious gesture.
            .clickable(onClick = onOpenPanel)
            .padding(horizontal = 12.dp, vertical = 10.dp)
            .testTag("transfer-strip"),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (head.direction == TransferDirection.UPLOAD) {
                    TesseraIcons.Upload
                } else {
                    TesseraIcons.Download
                },
                contentDescription = null,
                tint = tokens.fgDim,
                modifier = Modifier.size(15.dp),
            )
            Text(
                head.displayName,
                modifier = Modifier.weight(1f).padding(start = 8.dp, end = 8.dp),
                style = TesseraType.rowMeta,
                color = tokens.fg,
                maxLines = 1,
                // A generated paste-<stamp>-<token> name identifies itself by
                // both ends, so neither end may be the part that is dropped.
                overflow = TextOverflow.MiddleEllipsis,
            )
            if (head.phase != TransferPhase.CANCELLING) {
                TesseraButton(
                    text = "cancel",
                    onClick = { onCancel(head) },
                    compact = true,
                    modifier = Modifier.testTag("transfer-strip-cancel"),
                )
            }
        }
        Spacer(Modifier.height(8.dp))
        TesseraProgressTrack(
            progress = if (total != null && total > 0) {
                head.transferredBytes.toFloat() / total
            } else {
                null
            },
        )
        Spacer(Modifier.height(6.dp))
        Text(
            stripDetail(head, remaining = items.size - 1),
            style = TesseraType.rowMicro,
            color = tokens.fgDim,
            maxLines = 1,
        )
    }
}

/** Byte counts, then what this row is doing and what waits behind it. */
private fun stripDetail(item: TransferItem, remaining: Int): String {
    val total = item.totalBytes
    val bytes = if (total != null && total > 0) {
        "${formatBytes(item.transferredBytes)} / ${formatBytes(total)}"
    } else {
        formatBytes(item.transferredBytes)
    }
    val phase = when (item.phase) {
        TransferPhase.QUEUED -> "queued"
        TransferPhase.CANCELLING -> "cancelling…"
        else -> if (item.direction == TransferDirection.UPLOAD) "uploading" else "downloading"
    }
    return bytes + " · " + phase + if (remaining > 0) " · +$remaining more" else ""
}

/** Transfers worth reporting over the terminal: the ones still moving. */
fun List<TransferItem>.inFlight(): List<TransferItem> = filter {
    it.phase == TransferPhase.QUEUED ||
        it.phase == TransferPhase.RUNNING ||
        it.phase == TransferPhase.CANCELLING
}
