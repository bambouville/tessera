package com.bambouville.tessera.feature.artifacts

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import com.bambouville.tessera.core.bridge.SharedArtifactsFilter
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.design.TesseraIcons
import java.util.Locale

internal fun artifactKindIcon(kind: SharedArtifactsKind): ImageVector = when (kind) {
    SharedArtifactsKind.Docs, SharedArtifactsKind.Files -> TesseraIcons.File
    SharedArtifactsKind.Pages -> TesseraIcons.Tunnels
    SharedArtifactsKind.Changes -> TesseraIcons.Pencil
}

@StringRes
internal fun artifactKindLabel(kind: SharedArtifactsKind): Int = when (kind) {
    SharedArtifactsKind.Docs -> R.string.artifacts_filter_docs
    SharedArtifactsKind.Pages -> R.string.artifacts_filter_pages
    SharedArtifactsKind.Changes -> R.string.artifacts_filter_changes
    SharedArtifactsKind.Files -> R.string.artifacts_filter_files
}

@StringRes
internal fun artifactFilterLabel(filter: SharedArtifactsFilter): Int = when (filter) {
    SharedArtifactsFilter.All -> R.string.artifacts_filter_all
    SharedArtifactsFilter.Docs -> R.string.artifacts_filter_docs
    SharedArtifactsFilter.Pages -> R.string.artifacts_filter_pages
    SharedArtifactsFilter.Changes -> R.string.artifacts_filter_changes
    SharedArtifactsFilter.Files -> R.string.artifacts_filter_files
}

internal enum class ArtifactAgeUnit { JustNow, Minutes, Hours, Days }

/** A cached copy's age in its largest whole unit; [count] is 0 for [ArtifactAgeUnit.JustNow]. */
internal data class ArtifactAge(val unit: ArtifactAgeUnit, val count: Long)

internal fun artifactAge(fetchedAt: Long, nowMillis: Long): ArtifactAge {
    // Future clock values are still a fresh copy; subtraction cannot wrap.
    val elapsed = if (fetchedAt >= nowMillis) 0L else
        (nowMillis - fetchedAt).takeIf { it >= 0 } ?: Long.MAX_VALUE
    return when {
        elapsed < 60_000 -> ArtifactAge(ArtifactAgeUnit.JustNow, 0)
        elapsed < 3_600_000 -> ArtifactAge(ArtifactAgeUnit.Minutes, elapsed / 60_000)
        elapsed < 86_400_000 -> ArtifactAge(ArtifactAgeUnit.Hours, elapsed / 3_600_000)
        else -> ArtifactAge(ArtifactAgeUnit.Days, elapsed / 86_400_000)
    }
}

@Composable
internal fun artifactRelativeTime(fetchedAt: Long, nowMillis: Long): String {
    val age = artifactAge(fetchedAt, nowMillis)
    return when (age.unit) {
        ArtifactAgeUnit.JustNow -> stringResource(R.string.artifacts_age_just_now)
        ArtifactAgeUnit.Minutes -> stringResource(R.string.artifacts_age_minutes, age.count)
        ArtifactAgeUnit.Hours -> stringResource(R.string.artifacts_age_hours, age.count)
        // The quantity only picks the plural form; the full count is printed.
        ArtifactAgeUnit.Days -> pluralStringResource(
            R.plurals.artifacts_age_days, age.count.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), age.count,
        )
    }
}

/** Binary units, independent of locale; null when the size is unknown. */
internal fun artifactByteCount(bytes: Long): String? = when {
    bytes < 0 -> null
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> String.format(Locale.ROOT, "%.1f KiB", bytes / 1024.0)
    bytes < 1024L * 1024 * 1024 -> String.format(Locale.ROOT, "%.1f MiB", bytes / (1024.0 * 1024))
    else -> String.format(Locale.ROOT, "%.1f GiB", bytes / (1024.0 * 1024 * 1024))
}

/** The origin alone: a session hint is the opening session's ID, never a name. */
internal fun artifactOpenedFrom(origin: String): ArtifactMessage = when (origin) {
    "files", "Files" -> ArtifactMessage.Resource(R.string.artifacts_opened_from_files)
    "terminalSelection", "TerminalSelection" -> ArtifactMessage.Resource(R.string.artifacts_opened_from_terminal_selection)
    "terminalLink", "TerminalLink" -> ArtifactMessage.Resource(R.string.artifacts_opened_from_terminal_link)
    "forwarding", "Forwarding" -> ArtifactMessage.Resource(R.string.artifacts_opened_from_forwarding)
    "agentEdit", "AgentEdit" -> ArtifactMessage.Resource(R.string.artifacts_opened_from_agent_edit)
    "quickOpen", "QuickOpen" -> ArtifactMessage.Resource(R.string.artifacts_opened_from_quick_open)
    "palette", "Palette" -> ArtifactMessage.Resource(R.string.artifacts_opened_from_switcher)
    "documentLink", "DocumentLink" -> ArtifactMessage.Resource(R.string.artifacts_opened_from_document_link)
    else -> if (origin.isBlank()) ArtifactMessage.Resource(R.string.artifacts_opened_from_session)
        else ArtifactMessage.Resource(R.string.artifacts_opened_from_other, listOf(origin))
}

internal fun artifactQuickOpenInput(path: String, scheme: String? = null, port: Int? = null): String =
    if (port != null) "${scheme ?: "http"}://localhost:$port$path" else path
