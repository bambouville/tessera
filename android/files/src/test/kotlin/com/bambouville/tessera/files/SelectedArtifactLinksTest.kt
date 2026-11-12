package com.bambouville.tessera.files

import com.bambouville.tessera.core.bridge.SharedArtifactsLinkClass
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import org.junit.Assert.assertEquals
import org.junit.Test

/** The shared core's own classifier: the terminal and Agent Center route links through this. */
class SelectedArtifactLinksTest {
    @Test fun remoteLoopbackOpensATerminalLinkPageOnTheGivenHost() {
        assertEquals(SelectedArtifactLinkRoute.Page(ArtifactOpenRequest.Page(
            "host", "http", 5173, "/app?q=1", ArtifactOpenOrigin.TerminalLink, "session",
        )), SelectedArtifactLinks.route(" http://localhost:5173/app?q=1\n", "host", "session", openerAvailable = true))
        assertEquals(SelectedArtifactLinkRoute.Default,
            SelectedArtifactLinks.route("http://localhost:5173/app", "host", "session", openerAvailable = false))
    }

    @Test fun externalRefusedAndPathsKeepTheirRoutes() {
        assertEquals(SelectedArtifactLinkRoute.Default,
            SelectedArtifactLinks.route("https://example.com/", "host", null, openerAvailable = true))
        assertEquals(SelectedArtifactLinkRoute.Refused,
            SelectedArtifactLinks.route("http://viewer@127.0.0.1:3000/", "host", null, openerAvailable = true))
        assertEquals(SelectedArtifactLinkRoute.Default,
            SelectedArtifactLinks.route("/work/a.txt", "host", null, openerAvailable = true))
    }

    @Test fun theClassifierSeesTheTrimmedSelection() {
        SelectedArtifactLinks.route(" \thttp://[::1]:8080/\n", "host", null, true) { input ->
            assertEquals("http://[::1]:8080/", input)
            SharedArtifactsLinkClass.Unsupported
        }
    }
}
