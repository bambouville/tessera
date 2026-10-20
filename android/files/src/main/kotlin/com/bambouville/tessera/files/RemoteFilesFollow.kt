package com.bambouville.tessera.files

/**
 * Where the browser sits relative to the terminal's working directory.
 *
 * iOS peer: `FilesPanelController.FollowState`. `UNAVAILABLE` is not an error —
 * it means no transport is currently reporting a cwd (tmux metadata not
 * hydrated, no OSC 7, probe missing), and the browser stays freely navigable.
 */
enum class RemoteFilesFollowState { FOLLOWING, MANUAL, UNAVAILABLE }

/**
 * Pure follow rules. The transport that discovers a cwd differs per session —
 * tmux pane metadata, OSC 7, or the shell probe — but what the browser does
 * with the answer must not, so the decisions live here and are pinned by tests.
 */
internal object RemoteFilesFollow {

    fun state(terminalDirectory: String?, enabled: Boolean): RemoteFilesFollowState = when {
        terminalDirectory == null -> RemoteFilesFollowState.UNAVAILABLE
        enabled -> RemoteFilesFollowState.FOLLOWING
        else -> RemoteFilesFollowState.MANUAL
    }

    /**
     * A reported cwd reduced to the one shape the browser navigates with, or
     * null when the report says nothing usable. Terminal OSC 7 arrives already
     * decoded from its `file://` URI; a probe answer arrives as a bare path.
     */
    fun normalized(path: String?): String? {
        // Empty is silence, not root: only a value that already carried a path
        // may be trimmed down to "/".
        val reported = path?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val value = reported.trimEnd('/').ifEmpty { "/" }
        return value.takeIf { it.startsWith('/') && it.none(Char::isISOControl) }
    }

    /**
     * Which directory a load should land on. An explicit request always wins —
     * refresh and reveal both pass one — so follow only decides where an
     * unaimed open goes: the terminal's directory while following, and
     * otherwise wherever the browser already was.
     */
    fun openTarget(
        requested: String?,
        followEnabled: Boolean,
        terminalDirectory: String?,
        currentPath: String?,
        homePath: String?,
    ): String? = requested
        ?: terminalDirectory?.takeIf { followEnabled }
        ?: currentPath
        ?: terminalDirectory
        ?: homePath
}
