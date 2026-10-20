package com.bambouville.tessera.data.continuity

import com.bambouville.tessera.data.SessionRestoreRecord

/**
 * Controller hook: carry the existing restore record into the process-death
 * document with only display metadata supplied by the resolved saved host.
 */
fun SessionRestoreRecord.toForegroundRestoreSnapshot(displayName: String): ForegroundRestoreSnapshot =
    ForegroundRestoreSnapshot(
        sessionId = sessionId,
        hostId = hostId,
        displayName = displayName.ifBlank { hostId },
        // Existing records have no separate creation timestamp. This is the
        // best durable fallback; controller integration should replace it with
        // an immutable first-connected timestamp when it begins writing the
        // foreground document.
        createdAtEpochMilliseconds = updatedAtEpochMilliseconds,
        transportKind = normalizedRestoreTransportKind(transportKind),
        tmuxTarget = tmuxTarget,
        lastSelection = lastSelection,
        reconnectRequired = reconnectRequired,
    )
