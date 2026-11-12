package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedArtifactsLinkClass
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.files.SelectedArtifactLinkRoute
import com.bambouville.tessera.terminal.TerminalSelectionPathAction
import org.junit.Assert.assertEquals
import org.junit.Test

class SelectedArtifactPageRequestTest {
    @Test fun loopbackClassificationOpensAPageWithTheSessionHostAndCompletePath() {
        val route = selectedArtifactLinkRoute(
            TerminalSelectionPathAction.QuickOpen, " \nhttps://[::1]:5173/app?q=1#view\t", "host", "session", true,
        ) { input ->
            assertEquals("https://[::1]:5173/app?q=1#view", input)
            SharedArtifactsLinkClass.RemoteLoopback("https", 5173, "/app?q=1#view")
        }
        assertEquals(SelectedArtifactLinkRoute.Page(ArtifactOpenRequest.Page(
            "host", "https", 5173, "/app?q=1#view", ArtifactOpenOrigin.TerminalLink, "session",
        )), route)
    }

    @Test fun externalLinksAndPathsKeepTheExistingFileFlow() {
        for ((input, classification) in listOf(
            "https://example.com/app" to SharedArtifactsLinkClass.External,
            "docs/readme.md" to SharedArtifactsLinkClass.Unsupported,
            "/work/a.txt" to SharedArtifactsLinkClass.Unsupported,
        )) {
            for (openerAvailable in listOf(true, false)) {
                assertEquals(SelectedArtifactLinkRoute.Default, selectedArtifactLinkRoute(
                    TerminalSelectionPathAction.QuickOpen, input, "host", null, openerAvailable,
                ) { classification })
            }
        }
    }

    @Test fun refusedLinksAreConsumedEvenWithoutAnArtifactOpener() {
        for (openerAvailable in listOf(true, false)) {
            assertEquals(SelectedArtifactLinkRoute.Refused, selectedArtifactLinkRoute(
                TerminalSelectionPathAction.QuickOpen, " \nhttp://viewer@127.0.0.1:3000/\t", "host", "session", openerAvailable,
            ) { input ->
                assertEquals("http://viewer@127.0.0.1:3000/", input)
                SharedArtifactsLinkClass.Refused
            })
        }
    }

    @Test fun revealDoesNotClassifyAndAMissingOpenerKeepsTheLoopbackFallback() {
        assertEquals(SelectedArtifactLinkRoute.Default, selectedArtifactLinkRoute(TerminalSelectionPathAction.RevealInFiles, "http://localhost:5173", "host", "session", true) {
            error("Reveal in Files must not classify links")
        })
        assertEquals(SelectedArtifactLinkRoute.Default, selectedArtifactLinkRoute(TerminalSelectionPathAction.QuickOpen, "http://localhost:5173", "host", "session", false) {
            SharedArtifactsLinkClass.RemoteLoopback("http", 5173, "/")
        })
    }
}
