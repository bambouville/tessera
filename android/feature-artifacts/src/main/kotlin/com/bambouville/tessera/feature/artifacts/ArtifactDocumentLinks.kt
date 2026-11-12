package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifacts
import com.bambouville.tessera.core.bridge.SharedArtifactsDocumentLink
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest

internal sealed interface ArtifactDocumentLinkRoute {
    /** A path or localhost page on the document's host: a tab. */
    data class Open(val request: ArtifactOpenRequest) : ArtifactDocumentLinkRoute
    /** The internet or a mail address: the device opens it. */
    data object External : ArtifactDocumentLinkRoute
    data object Refused : ArtifactDocumentLinkRoute
    data object Ignored : ArtifactDocumentLinkRoute
}

/**
 * A document's links are its host's, as a browser reads a link in a file it
 * shows: its paths and localhost pages open as tabs, and only the internet or a
 * mail address leaves for the device. A link the shared core cannot read opens
 * nowhere.
 */
internal fun artifactDocumentLinkRoute(
    link: String,
    tab: SharedArtifactTab,
    home: String?,
    resolve: (String, String, String?) -> SharedArtifactsDocumentLink = SharedArtifacts::documentLink,
): ArtifactDocumentLinkRoute {
    val document = tab.target as? SharedArtifactsTarget.File ?: return ArtifactDocumentLinkRoute.Ignored
    return when (val resolved = runCatching { resolve(link, document.path, home) }.getOrNull()) {
        is SharedArtifactsDocumentLink.File -> ArtifactDocumentLinkRoute.Open(
            ArtifactOpenRequest.File(tab.hostId, resolved.path, ArtifactOpenOrigin.DocumentLink, tab.sessionHint),
        )
        is SharedArtifactsDocumentLink.Page -> ArtifactDocumentLinkRoute.Open(
            ArtifactOpenRequest.Page(tab.hostId, resolved.scheme, resolved.port, resolved.pathAndQuery, ArtifactOpenOrigin.DocumentLink, tab.sessionHint),
        )
        SharedArtifactsDocumentLink.External -> ArtifactDocumentLinkRoute.External
        SharedArtifactsDocumentLink.Ignored -> ArtifactDocumentLinkRoute.Ignored
        SharedArtifactsDocumentLink.Refused, null -> ArtifactDocumentLinkRoute.Refused
    }
}
