package com.bambouville.tessera.files

/**
 * Share-in upload model: everything the ingress sheet decides before a byte
 * moves. Deliberately free of Android types so the ordering, destination and
 * completion-delivery rules are plain unit tests rather than instrumented ones
 * — those rules are the part that has to match iOS exactly.
 *
 * The iOS counterparts are `UploadHostCandidate` / `UploadDestination` /
 * `UploadCompletionDelivery` in `Tessera/Files/UploadRequest.swift`; keep the
 * two in step.
 */

/**
 * One selectable destination host. Rows stay LIVE while the sheet is up — the
 * owner refreshes them from the session registry, so a host that finishes
 * auto-reconnecting walks connecting… → connected in place.
 */
data class ShareUploadTarget(
    /** Saved-host id. Also keys the per-host last-destination memory. */
    val id: String,
    /** Row title, the host's display name. */
    val label: String,
    /** Row subtitle, `user@hostname:port`. */
    val detail: String,
    /** A live session to this host is connected. */
    val isConnected: Boolean = false,
    /** No connected session yet, but one is connecting or auto-restoring. */
    val isConnecting: Boolean = false,
    /** This host owns the session the user was last looking at. */
    val isActiveSession: Boolean = false,
    /** Its live session gave up reconnecting. */
    val isFailed: Boolean = false,
    /** cwd reported by its live session, when known. null disables the cwd destination. */
    val sessionCwd: String? = null,
)

/** Where a shared file lands on the host. */
sealed interface ShareUploadDestination {
    /** The selected host's live-session cwd (absolute path). */
    data class SessionCwd(val path: String) : ShareUploadDestination

    /** `~/.cache/tessera` — the reaped temp dir, for files that exist to be referenced by path. */
    data object Temp : ShareUploadDestination
}

/** What the sheet does with a text-only share. */
enum class ShareTextMode {
    /** Type the text straight into the selected host's live session. */
    PasteIntoSession,

    /** Stage the text as a `.txt` and upload it like any other file. */
    UploadAsFile,
}

/** Why a share upload did not happen. */
sealed interface ShareUploadFailure {
    /**
     * Something already occupies the destination name. Reported instead of
     * failing the transfer so the caller can ask before overwriting — the
     * share-in path has no browser open to show what is about to be replaced.
     */
    data class Conflict(val name: String, val kind: RemoteFileKind) : ShareUploadFailure

    data class Message(val detail: String) : ShareUploadFailure
}

/** Outcome of the effect that follows a completed share upload. */
enum class ShareUploadDeliveryOutcome { NONE, TERMINAL, CLIPBOARD, CLIPBOARD_FALLBACK }

object ShareUploadPolicy {
    /**
     * Presentation order: the host you are looking at, then connected, then
     * connecting, then everything else alphabetically. Identical to the iOS
     * sheet's `sortedCandidates`.
     */
    fun ordered(targets: List<ShareUploadTarget>): List<ShareUploadTarget> = targets.sortedWith(
        compareByDescending<ShareUploadTarget> { it.isActiveSession }
            .thenByDescending { it.isConnected }
            .thenByDescending { it.isConnecting }
            .thenBy(String.CASE_INSENSITIVE_ORDER) { it.label },
    )

    /**
     * Rows keep the order they had when the sheet opened, with fresh row data
     * swapped in. Hosts walking connecting… → connected mid-sheet must not swap
     * tiers under the user's finger — they tap a POSITION. Hosts that appear
     * later append rather than reshuffle.
     */
    fun frozen(order: List<String>, live: List<ShareUploadTarget>): List<ShareUploadTarget> {
        if (order.isEmpty()) return ordered(live)
        val byId = live.associateBy(ShareUploadTarget::id)
        val known = order.toSet()
        return order.mapNotNull(byId::get) + ordered(live.filterNot { it.id in known })
    }

    /**
     * A host whose session is up or on its way. Only wording depends on this —
     * the button admits it has to open a session first, and the paste promise
     * says "once its session connects" instead of "after upload".
     */
    fun hasLiveSession(target: ShareUploadTarget?): Boolean =
        target != null && (target.isConnected || target.isConnecting)

    /**
     * Any saved host can take a pasted path — the offer is about the payload,
     * not about what happens to be connected while the sheet is up. The
     * injection target resolves when the upload completes: the same gesture
     * that uploads opens a cold host, the routed share waits for that session,
     * and a path that still finds no terminal falls back to the clipboard
     * rather than being lost. Gating this on a live session withdrew the
     * one-gesture "share a photo, get its remote path" flow exactly when the
     * user had not opened the host yet, which is when a share arrives.
     */
    fun canPastePath(target: ShareUploadTarget?): Boolean = target != null

    /** Right-hand status text on a host row. */
    fun status(target: ShareUploadTarget, textMode: ShareTextMode? = null): String = when {
        target.isActiveSession -> "connected · active session"
        target.isConnected -> "connected"
        target.isConnecting -> "connecting…"
        target.isFailed -> "reconnect failed"
        // Name the gesture the button is about to perform, not a generic one.
        textMode == ShareTextMode.PasteIntoSession -> "connect on paste…"
        else -> "connect on upload…"
    }

    /**
     * A disconnected host says so on the button: the payload rides a session
     * this app has to open first, and opening it is the user's gesture. Text
     * pasted into a cold host is the same bargain as a cold upload — the
     * routed share waits for the session and lands when it connects.
     */
    fun ctaTitle(target: ShareUploadTarget?, textMode: ShareTextMode? = null): String {
        val pasting = textMode == ShareTextMode.PasteIntoSession
        if (target == null) return if (pasting) "Paste" else "Upload"
        val live = hasLiveSession(target)
        return when {
            pasting && live -> "Paste"
            pasting -> "Connect & paste"
            live -> "Upload"
            else -> "Connect & upload"
        }
    }

    /**
     * The default destination for a freshly selected host: the remembered
     * choice when it is still reachable, otherwise temp. A remembered `cwd`
     * with no known cwd yet falls back to temp and is upgraded by
     * [upgradeToCwd] once one arrives.
     */
    fun defaultDestination(
        target: ShareUploadTarget?,
        remembered: String?,
    ): ShareUploadDestination {
        val cwd = target?.sessionCwd
        return if (remembered == REMEMBERED_CWD && cwd != null) {
            ShareUploadDestination.SessionCwd(cwd)
        } else {
            ShareUploadDestination.Temp
        }
    }

    /**
     * True when a sheet that was forced to temp for a missing cwd should adopt
     * the cwd the host has just reported. The user's remembered preference was
     * cwd; honor it now that one is known.
     */
    fun upgradeToCwd(forcedTempForMissingCwd: Boolean, cwd: String?): Boolean =
        forcedTempForMissingCwd && !cwd.isNullOrEmpty()

    /** UserDefaults-equivalent key for the per-host last destination choice. */
    fun defaultPastePath(remembered: Boolean?, isTemp: Boolean, canPaste: Boolean): Boolean =
        canPaste && (remembered ?: isTemp)

    fun rememberedPastePathKey(hostId: String): String = "tessera.files.lastPastePath.$hostId"

    fun rememberedDestinationKey(hostId: String): String = "tessera.files.lastDest.$hostId"

    fun rememberedValue(destination: ShareUploadDestination): String = when (destination) {
        is ShareUploadDestination.SessionCwd -> REMEMBERED_CWD
        ShareUploadDestination.Temp -> REMEMBERED_TEMP
    }

    const val REMEMBERED_CWD = "cwd"
    const val REMEMBERED_TEMP = "temp"
}

/**
 * What happens once the bytes have landed. Keeps "no silent loss" deterministic
 * and directly testable: a path that cannot reach the terminal always reaches
 * the clipboard instead.
 */
object ShareUploadDelivery {
    fun deliver(
        path: String,
        pastePath: Boolean,
        /** Returns false when no live terminal could take the path. */
        injectIntoTerminal: (String) -> Boolean,
        copyToClipboard: (String) -> Unit,
    ): ShareUploadDeliveryOutcome {
        if (!pastePath) return ShareUploadDeliveryOutcome.NONE
        if (injectIntoTerminal(path)) return ShareUploadDeliveryOutcome.TERMINAL
        copyToClipboard(path)
        return ShareUploadDeliveryOutcome.CLIPBOARD_FALLBACK
    }
}

/** Remote-path helpers shared by the sheet and the controller. */
object ShareUploadPaths {
    /**
     * `paste-<yyyyMMdd-HHmmss>-<4 hex>.<ext>`, matching iOS. The original
     * basename is deliberately dropped — a shared photo's filename is the one
     * piece of the payload that leaks something about where it came from, and
     * the path is about to be typed into a terminal in front of whoever is
     * looking at the screen.
     *
     * The `paste-` prefix is load-bearing: the reaper only ever deletes files
     * that carry it inside the temp directory.
     */
    fun tempFileName(displayName: String, stamp: String, token: String): String {
        val extension = displayName.substringAfterLast('.', "")
            .filter { it.isLetterOrDigit() }
            .take(16)
        val suffix = if (extension.isEmpty()) "" else ".$extension"
        return "${RemoteFilesConstants.PASTE_PREFIX}$stamp-$token$suffix"
    }

    /** True for a name the reaper is allowed to delete. */
    fun isReapable(name: String): Boolean = name.startsWith(RemoteFilesConstants.PASTE_PREFIX)

    fun tempDirectory(homePath: String): String =
        if (homePath == "/") "/${RemoteFilesConstants.TEMP_DIRECTORY}"
        else "${homePath.trimEnd('/')}/${RemoteFilesConstants.TEMP_DIRECTORY}"

    /** `~/…` for display; the shell never sees this form. */
    fun abbreviateHome(path: String, homePath: String?): String {
        if (homePath.isNullOrEmpty() || homePath == "/") return path
        val home = homePath.trimEnd('/')
        return when {
            path == home -> "~"
            path.startsWith("$home/") -> "~" + path.removePrefix(home)
            else -> path
        }
    }
}

/**
 * A share the user has already routed, waiting for its host's session to be in
 * a state that can run it.
 *
 * The ingress sheet produces exactly one of these and then gets out of the way:
 * the session screen owns the file connection, the terminal, and the transfer
 * strip, so it is the only place that can both upload and paste.
 */
data class PendingShareUpload(
    val hostId: String,
    val uris: List<android.net.Uri>,
    val text: String? = null,
    val textMode: ShareTextMode? = null,
    val destination: ShareUploadDestination = ShareUploadDestination.Temp,
    val pastePath: Boolean = false,
) {
    /** Types the text straight into the session instead of moving any bytes. */
    val isTextPaste: Boolean get() = textMode == ShareTextMode.PasteIntoSession && !text.isNullOrEmpty()
}
