package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.CoreBridge
import com.bambouville.tessera.core.bridge.CoreBridgeState
import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsDocumentLink
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test

class ArtifactDocumentLinksTest {
    private fun tab(target: SharedArtifactsTarget = SharedArtifactsTarget.File("/work/atlas/docs/guide.md")) =
        SharedArtifactTab("t", "h1", "dev", target, SharedArtifactsKind.Docs, "guide.md", "files", "s1", 1, 1, false, null, false, null)

    @Test fun eachResolvedLinkTakesItsRouteOnTheDocumentsHost() {
        var asked: Triple<String, String, String?>? = null
        fun route(result: SharedArtifactsDocumentLink) = artifactDocumentLinkRoute("../a.md", tab(), "/home/me") { link, path, home ->
            asked = Triple(link, path, home)
            result
        }
        assertEquals(
            ArtifactDocumentLinkRoute.Open(ArtifactOpenRequest.File("h1", "/work/atlas/a.md", ArtifactOpenOrigin.DocumentLink, "s1")),
            route(SharedArtifactsDocumentLink.File("/work/atlas/a.md")),
        )
        assertEquals(Triple("../a.md", "/work/atlas/docs/guide.md", "/home/me"), asked)
        assertEquals(
            ArtifactDocumentLinkRoute.Open(ArtifactOpenRequest.Page("h1", "http", 3000, "/x#y", ArtifactOpenOrigin.DocumentLink, "s1")),
            route(SharedArtifactsDocumentLink.Page("http", 3000, "/x#y")),
        )
        assertEquals(ArtifactDocumentLinkRoute.External, route(SharedArtifactsDocumentLink.External))
        assertEquals(ArtifactDocumentLinkRoute.Refused, route(SharedArtifactsDocumentLink.Refused))
        assertEquals(ArtifactDocumentLinkRoute.Ignored, route(SharedArtifactsDocumentLink.Ignored))
    }

    @Test fun aCoreFailureOpensNothingAndOnlyAFileTabHasLinks() {
        assertEquals(ArtifactDocumentLinkRoute.Refused,
            artifactDocumentLinkRoute("http://localhost:3000", tab(), null) { _, _, _ -> error("core unavailable") })
        assertEquals(ArtifactDocumentLinkRoute.Ignored,
            artifactDocumentLinkRoute("a.md", tab(SharedArtifactsTarget.Page("http", 3000, "/")), null) { _, _, _ -> error("not asked") })
    }

    @Test fun theSharedCoreResolvesRelativePathsAndLocalhostPages() {
        val state = CoreBridge.inspect()
        assumeTrue("host-built shared core unavailable: $state", state is CoreBridgeState.Ready)
        assertEquals(
            ArtifactDocumentLinkRoute.Open(ArtifactOpenRequest.File("h1", "/work/atlas/README.md", ArtifactOpenOrigin.DocumentLink, "s1")),
            artifactDocumentLinkRoute("../README.md#setup", tab(), null),
        )
        assertEquals(
            ArtifactDocumentLinkRoute.Open(ArtifactOpenRequest.Page("h1", "http", 3000, "/billing", ArtifactOpenOrigin.DocumentLink, "s1")),
            artifactDocumentLinkRoute("http://localhost:3000/billing", tab(), null),
        )
        assertEquals(ArtifactDocumentLinkRoute.External, artifactDocumentLinkRoute("https://example.com", tab(), null))
        assertEquals(ArtifactDocumentLinkRoute.Refused, artifactDocumentLinkRoute("javascript:alert(1)", tab(), null))
    }
}
