package com.bambouville.tessera.design

import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Where an artifact open came from. Sources only describe what they want
 * opened; the artifacts store decides whether that focuses an existing tab.
 *
 * It lives here, in the module every source already depends on (Files, the
 * session screen, Agent Center, port forwarding), so none of them depends on
 * `:feature-artifacts`, which depends on them.
 */
enum class ArtifactOpenOrigin {
    Files,
    TerminalSelection,
    TerminalLink,
    Forwarding,
    AgentEdit,
    QuickOpen,
    Palette,
    DocumentLink,
}

/**
 * A request to open something as a tab in the artifacts browser. A tab
 * belongs to the saved host, not to the session that asked, so [hostId] is
 * the identity and [sessionHint] is the asking session's ID, never shown.
 */
sealed interface ArtifactOpenRequest {
    val hostId: String
    val origin: ArtifactOpenOrigin
    val sessionHint: String?

    /** An absolute remote path. [stagedFile] is a copy the caller already downloaded. */
    data class File(
        override val hostId: String,
        val path: String,
        override val origin: ArtifactOpenOrigin,
        override val sessionHint: String? = null,
        val stagedFile: java.io.File? = null,
    ) : ArtifactOpenRequest

    /** A port on the host's own loopback; the store plans the local forward. */
    data class Page(
        override val hostId: String,
        val scheme: String,
        val port: Int,
        val path: String,
        override val origin: ArtifactOpenOrigin,
        override val sessionHint: String? = null,
    ) : ArtifactOpenRequest

    /** An agent edit snapshot. */
    data class Change(
        override val hostId: String,
        val path: String,
        val diff: String,
        val summary: String,
        override val origin: ArtifactOpenOrigin,
        override val sessionHint: String? = null,
    ) : ArtifactOpenRequest
}

/** Opens an artifact tab and shows the browser. */
fun interface ArtifactOpener {
    fun open(request: ArtifactOpenRequest)
}

/** Installed once at the app root; null where no browser exists (tests, harnesses). */
val LocalArtifactOpener = staticCompositionLocalOf<ArtifactOpener?> { null }
