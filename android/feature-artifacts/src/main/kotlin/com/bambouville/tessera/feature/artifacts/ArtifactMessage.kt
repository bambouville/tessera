package com.bambouville.tessera.feature.artifacts

import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.bambouville.tessera.files.FilesConnectionUnavailableException
import com.bambouville.tessera.files.FilesRouteUnavailableException

/**
 * Text a failure or notice shows. A host's or the system's own message stays
 * as it came; the browser's own words are a resource, resolved where they are
 * displayed so they follow the current locale.
 */
sealed interface ArtifactMessage {
    data class Verbatim(val text: String) : ArtifactMessage
    data class Resource(@param:StringRes val id: Int, val args: List<String> = emptyList()) : ArtifactMessage
}

/** Quick open's refusal of an input, by the shared core's reason code. */
internal fun artifactQuickOpenFailure(reason: String): ArtifactMessage = ArtifactMessage.Resource(when (reason) {
    "emptyInput" -> R.string.artifacts_error_empty_input
    "unknownHost" -> R.string.artifacts_error_unknown_host
    "ambiguousHost" -> R.string.artifacts_error_ambiguous_host
    "missingHost" -> R.string.artifacts_error_missing_host
    "missingCwd" -> R.string.artifacts_error_missing_cwd
    "unsupportedURL" -> R.string.artifacts_error_unsupported_url
    "invalidPort" -> R.string.artifacts_error_invalid_port
    else -> R.string.artifacts_error_unresolved
})

/** A failure the browser explains in its own words; [text] is what the user reads. */
internal class ArtifactFailureException(val text: ArtifactMessage.Resource) : IllegalStateException()

/**
 * What [failure] tells the user: the browser's own words, the Files module's
 * missing connection or terminal route in translated words, its message (at
 * most [limit] characters), or [fallback].
 */
internal fun artifactFailureMessage(failure: Throwable?, @StringRes fallback: Int, limit: Int = Int.MAX_VALUE): ArtifactMessage =
    (failure as? ArtifactFailureException)?.text
        ?: (failure as? FilesConnectionUnavailableException)?.let { ArtifactMessage.Resource(R.string.artifacts_files_connection_unavailable) }
        ?: (failure as? FilesRouteUnavailableException)?.let {
            ArtifactMessage.Resource(
                when (it.reason) {
                    FilesRouteUnavailableException.Reason.NotConnected -> R.string.artifacts_terminal_not_connected
                    FilesRouteUnavailableException.Reason.RouteUnavailable -> R.string.artifacts_route_unavailable
                },
            )
        }
        ?: failure?.message?.take(limit)?.let(ArtifactMessage::Verbatim)
        ?: ArtifactMessage.Resource(fallback)

@Composable
internal fun artifactMessageText(message: ArtifactMessage): String = when (message) {
    is ArtifactMessage.Verbatim -> message.text
    is ArtifactMessage.Resource ->
        if (message.args.isEmpty()) stringResource(message.id) else stringResource(message.id, *message.args.toTypedArray())
}
