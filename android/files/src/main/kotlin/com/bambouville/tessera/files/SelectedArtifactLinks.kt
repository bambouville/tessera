package com.bambouville.tessera.files

import com.bambouville.tessera.core.bridge.SharedArtifacts
import com.bambouville.tessera.core.bridge.SharedArtifactsLinkClass
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest

/** What selected text means as a link, before any path handling runs. */
sealed interface SelectedArtifactLinkRoute {
    /** A port on the host's own loopback: open it as an artifacts page tab. */
    data class Page(val request: ArtifactOpenRequest.Page) : SelectedArtifactLinkRoute
    /** A link the shared classifier refuses (device loopback with credentials, …). */
    data object Refused : SelectedArtifactLinkRoute
    /** Not an openable loopback link: the caller's own handling applies. */
    data object Default : SelectedArtifactLinkRoute
}

/**
 * One reading of selected text as an artifacts link, shared by the terminal's
 * selection toolbar and Agent Center's transcript menu so both build the
 * identical page request: the shared Core classifier decides, the tab belongs
 * to [hostId], and [sessionHint] only says where it was opened from.
 */
object SelectedArtifactLinks {
    fun route(
        selection: String,
        hostId: String,
        sessionHint: String?,
        openerAvailable: Boolean,
        classifyLink: (String) -> SharedArtifactsLinkClass = SharedArtifacts::classifyLink,
    ): SelectedArtifactLinkRoute = when (val link = classifyLink(selection.trim())) {
        SharedArtifactsLinkClass.Refused -> SelectedArtifactLinkRoute.Refused
        is SharedArtifactsLinkClass.RemoteLoopback -> if (openerAvailable) {
            SelectedArtifactLinkRoute.Page(ArtifactOpenRequest.Page(
                hostId, link.scheme, link.port, link.pathAndQuery, ArtifactOpenOrigin.TerminalLink, sessionHint,
            ))
        } else SelectedArtifactLinkRoute.Default
        SharedArtifactsLinkClass.External, SharedArtifactsLinkClass.Unsupported -> SelectedArtifactLinkRoute.Default
    }
}
