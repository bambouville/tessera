package com.bambouville.tessera.files

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bambouville.tessera.design.LocalTesseraTokens
import com.bambouville.tessera.design.TesseraButton
import com.bambouville.tessera.design.TesseraButtonStyle
import com.bambouville.tessera.design.TesseraDialog
import com.bambouville.tessera.design.TesseraSegmented
import com.bambouville.tessera.design.TesseraStatusDot
import com.bambouville.tessera.design.TesseraToggleRow
import com.bambouville.tessera.design.TesseraType

/** What the user settled on. The owner performs it; the sheet never connects. */
data class ShareUploadChoice(
    val targetId: String,
    val destination: ShareUploadDestination,
    val pastePath: Boolean,
    val textMode: ShareTextMode?,
)

/**
 * Share-in ingress sheet: pick host, pick destination, go — the Android
 * counterpart of iOS's `UploadSheetView`, and the only place a shared payload
 * is routed to a host.
 *
 * It never opens a connection itself. A disconnected host's button reads
 * "connect & upload", and tapping it is the explicit gesture that lets the
 * owner open that host's session.
 */
@Composable
fun ShareUploadSheet(
    /** File names in the share, in arrival order. Empty for a text-only share. */
    fileNames: List<String>,
    /** Total bytes across [fileNames] when the providers reported any. */
    totalBytes: Long?,
    /** Sanitized shared text, when the share carried text instead of files. */
    sharedText: String?,
    targets: List<ShareUploadTarget>,
    /** Days a temp upload survives; rendered in the temp row's promise. */
    reaperDays: Int,
    /** Pre-selected host — a direct-share shortcut names one. */
    initialTargetId: String?,
    /** Remembered destination for a host, `"cwd"` or `"temp"`. */
    rememberedDestination: (String) -> String?,
    onRememberDestination: (String, String) -> Unit,
    onConfirm: (ShareUploadChoice) -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val tokens = LocalTesseraTokens.current
    val context = LocalContext.current
    val preferences = remember(context) { context.getSharedPreferences("tessera.files", Context.MODE_PRIVATE) }
    val isTextShare = fileNames.isEmpty() && !sharedText.isNullOrEmpty()

    // Captured once. Live refreshes update each row in place but must not
    // reshuffle the list — hosts walking connecting… → connected mid-sheet made
    // rows swap tiers under the user's finger, and people tap a POSITION.
    val frozenOrder = remember { ShareUploadPolicy.ordered(targets).map(ShareUploadTarget::id) }
    val rows = ShareUploadPolicy.frozen(frozenOrder, targets)

    var selectedId by remember {
        mutableStateOf(initialTargetId?.takeIf { id -> targets.any { it.id == id } } ?: rows.firstOrNull()?.id)
    }
    val selection = rows.firstOrNull { it.id == selectedId } ?: rows.firstOrNull()
    val canPaste = ShareUploadPolicy.canPastePath(selection)
    val hasLiveSession = ShareUploadPolicy.hasLiveSession(selection)

    var textMode by remember {
        mutableStateOf(if (isTextShare) ShareTextMode.PasteIntoSession else null)
    }
    var destination by remember { mutableStateOf<ShareUploadDestination>(ShareUploadDestination.Temp) }
    var pastePath by remember { mutableStateOf(false) }
    // The remembered choice was cwd but none was known when it was adopted;
    // upgrade back to cwd if the host reports one while the sheet is up.
    var forcedTempForMissingCwd by remember { mutableStateOf(false) }
    var adoptedForId by remember { mutableStateOf<String?>(null) }

    // Adopt the selected host's remembered defaults, once per host.
    LaunchedEffect(selection?.id, selection?.sessionCwd) {
        val target = selection ?: return@LaunchedEffect
        if (adoptedForId != target.id) {
            adoptedForId = target.id
            val remembered = rememberedDestination(target.id)
            destination = ShareUploadPolicy.defaultDestination(target, remembered)
            forcedTempForMissingCwd =
                remembered == ShareUploadPolicy.REMEMBERED_CWD && target.sessionCwd == null
            val pasteKey = ShareUploadPolicy.rememberedPastePathKey(target.id)
            pastePath = ShareUploadPolicy.defaultPastePath(
                remembered = if (preferences.contains(pasteKey)) preferences.getBoolean(pasteKey, false) else null,
                isTemp = destination is ShareUploadDestination.Temp,
                canPaste = canPaste,
            )
        } else if (ShareUploadPolicy.upgradeToCwd(forcedTempForMissingCwd, target.sessionCwd)) {
            destination = ShareUploadDestination.SessionCwd(requireNotNull(target.sessionCwd))
            forcedTempForMissingCwd = false
        }
    }

    val pastingText = textMode == ShareTextMode.PasteIntoSession
    // Any saved host can receive pasted text: a closed one is opened first and
    // the text lands when its session connects, exactly as a cold upload does.
    val confirmEnabled = selection != null

    TesseraDialog(
        title = if (isTextShare) "share text" else "upload to host",
        onDismissRequest = onCancel,
        // Dismissing by tapping away would silently drop the payload the user
        // just shared from another app; Cancel is the one exit.
        dismissOnClickOutside = false,
        modifier = modifier.testTag("share-upload-sheet"),
        actions = {
            TesseraButton(
                text = "Cancel",
                onClick = onCancel,
                style = TesseraButtonStyle.Default,
                compact = true,
            )
            TesseraButton(
                text = ShareUploadPolicy.ctaTitle(selection, textMode),
                onClick = {
                    val target = selection ?: return@TesseraButton
                    if (!pastingText) {
                        onRememberDestination(target.id, ShareUploadPolicy.rememberedValue(destination))
                    }
                    onConfirm(
                        ShareUploadChoice(
                            targetId = target.id,
                            destination = destination,
                            pastePath = pastePath && canPaste,
                            textMode = textMode,
                        ),
                    )
                },
                style = TesseraButtonStyle.Primary,
                enabled = confirmEnabled,
                compact = true,
                modifier = Modifier.testTag("share-upload-confirm"),
            )
        },
    ) {
        PayloadRow(fileNames = fileNames, totalBytes = totalBytes, sharedText = sharedText)

        if (isTextShare) {
            SectionLabel("Text")
            TesseraSegmented(
                options = listOf("Paste into session", "Upload as file"),
                selectedIndex = if (pastingText) 0 else 1,
                onSelect = { index ->
                    textMode = if (index == 0) ShareTextMode.PasteIntoSession else ShareTextMode.UploadAsFile
                    if (index == 0) pastePath = false
                },
            )
        }

        SectionLabel(if (rows.isEmpty()) "No saved hosts" else "Host")
        if (rows.isEmpty()) {
            Text(
                "Add a host first — a share has nowhere to go until one exists.",
                style = TesseraType.bodySmall,
                color = tokens.fgMuted,
            )
        }
        rows.forEach { target ->
            HostRow(
                target = target,
                selected = target.id == selection?.id,
                textMode = textMode,
                onClick = { selectedId = target.id },
            )
        }

        // The button says "Connect & paste"; this says what that costs.
        if (pastingText && selection != null && !hasLiveSession) {
            Text(
                "${selection.label} has no live session — it opens first, and " +
                    "the text is typed once it connects.",
                style = TesseraType.bodySmall,
                color = tokens.fgMuted,
            )
        }

        if (!pastingText) {
            SectionLabel("Destination")
            val cwd = selection?.sessionCwd
            DestinationRow(
                title = cwd ?: "no session cwd",
                detail = "session cwd",
                selected = destination is ShareUploadDestination.SessionCwd,
                enabled = cwd != null,
                testTag = "share-destination-cwd",
                onClick = {
                    destination = ShareUploadDestination.SessionCwd(requireNotNull(cwd))
                    forcedTempForMissingCwd = false
                },
            )
            DestinationRow(
                title = "~/${RemoteFilesConstants.TEMP_DIRECTORY}/",
                detail = if (reaperDays > 0) "temp · auto-cleans after $reaperDays d" else "temp",
                selected = destination is ShareUploadDestination.Temp,
                enabled = true,
                testTag = "share-destination-temp",
                onClick = {
                    destination = ShareUploadDestination.Temp
                    forcedTempForMissingCwd = false
                    // Temp files exist only to be referenced by path, so picking
                    // temp re-enables paste; the toggle can still be turned off.
                    pastePath = true
                },
            )

            TesseraToggleRow(
                title = "Paste path into session",
                subtitle = pasteSubtitle(selection),
                checked = pastePath && canPaste,
                onCheckedChange = { value ->
                    pastePath = value
                    selection?.let { target ->
                        preferences.edit()
                            .putBoolean(ShareUploadPolicy.rememberedPastePathKey(target.id), value)
                            .apply()
                    }
                },
                enabled = canPaste,
                contentPadding = PaddingValues(vertical = 4.dp),
                modifier = Modifier.alpha(if (canPaste) 1f else 0.45f),
            )
        }
    }
}

private fun pasteSubtitle(target: ShareUploadTarget?): String = when {
    target == null -> "select a host first"
    target.isConnected -> "types the remote path into ${target.label} after upload"
    // Connecting, cold and failed all read the same: the path is typed when
    // that host's session is up, which the upload gesture itself brings about.
    else -> "types the remote path into ${target.label} once its session connects"
}

@Composable
private fun SectionLabel(text: String) {
    Text(text, style = TesseraType.rowMicro, color = LocalTesseraTokens.current.fgDim)
}

@Composable
private fun PayloadRow(fileNames: List<String>, totalBytes: Long?, sharedText: String?) {
    val tokens = LocalTesseraTokens.current
    val title = when {
        fileNames.size == 1 -> fileNames.first()
        fileNames.size > 1 -> "${fileNames.size} items"
        else -> sharedText.orEmpty()
    }
    val subtitle = when {
        fileNames.isEmpty() -> "${sharedText.orEmpty().length} characters · from Share"
        totalBytes != null -> "${formatBytes(totalBytes)} · from Share"
        else -> "from Share"
    }
    Column(
        Modifier
            .fillMaxWidth()
            .border(1.dp, tokens.border, RoundedCornerShape(8.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Text(
            title,
            style = TesseraType.rowTitle,
            color = tokens.fg,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Text(subtitle, style = TesseraType.rowMicro, color = tokens.fgMuted, maxLines = 1)
    }
}

@Composable
private fun HostRow(
    target: ShareUploadTarget,
    selected: Boolean,
    textMode: ShareTextMode?,
    onClick: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 52.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (selected) tokens.accentSoft else Color.Transparent)
            .border(1.dp, if (selected) tokens.accent else tokens.border, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 9.dp)
            .testTag("share-host-${target.id}"),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        TesseraStatusDot(
            color = when {
                target.isConnected -> tokens.green
                target.isConnecting -> tokens.amber
                target.isFailed -> tokens.red
                else -> tokens.fgFaint
            },
            size = 7.dp,
        )
        Column(Modifier.weight(1f)) {
            Text(
                target.label,
                style = TesseraType.rowTitle,
                color = tokens.fg,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                target.detail,
                style = TesseraType.rowMicro,
                color = tokens.fgMuted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(4.dp))
        Text(
            ShareUploadPolicy.status(target, textMode),
            style = TesseraType.rowMicro,
            color = tokens.fgDim,
            maxLines = 1,
        )
    }
}

@Composable
private fun DestinationRow(
    title: String,
    detail: String,
    selected: Boolean,
    enabled: Boolean,
    testTag: String,
    onClick: () -> Unit,
) {
    val tokens = LocalTesseraTokens.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(
                if (selected && enabled) tokens.accentSoft else Color.Transparent,
            )
            .border(
                1.dp,
                if (selected && enabled) tokens.accent else tokens.border,
                RoundedCornerShape(8.dp),
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .alpha(if (enabled) 1f else 0.4f)
            .testTag(testTag),
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        Text(
            title,
            style = TesseraType.rowMeta,
            color = tokens.fg,
            maxLines = 1,
            // A path identifies itself by its tail, and the destination sits on
            // its own line so the promise beneath it cannot squeeze it away.
            overflow = TextOverflow.StartEllipsis,
        )
        Text(detail, style = TesseraType.rowMicro, color = tokens.fgDim, maxLines = 1)
    }
}
