package com.bambouville.tessera.feature.agentcenter

import com.bambouville.tessera.core.bridge.SharedAgentValue
import com.bambouville.tessera.core.bridge.SharedArtifactsLinkClass
import com.bambouville.tessera.design.ArtifactOpenOrigin
import com.bambouville.tessera.design.ArtifactOpenRequest
import com.bambouville.tessera.design.ArtifactOpener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The transcript menu decision against the real shared link classifier and
 * the terminal's real path gate (no stand-ins for either).
 */
class AgentTranscriptSelectionTest {
    private val connected = AgentSelectionContext("host-1", "live-1", sessionConnected = true, openerAvailable = true)
    private val disconnected = connected.copy(sessionConnected = false)
    private val unbound = AgentSelectionContext("host-1", null, sessionConnected = false, openerAvailable = true)

    @Test fun remoteLoopbackLinkOpensAPageTabOnTheThreadHostAndNeverOffersReveal() {
        val menu = agentSelectionMenu(" \nhttp://localhost:5173/app?q=1#view\t", connected)
        assertEquals(AgentSelectionMenu.Link(ArtifactOpenRequest.Page(
            "host-1", "http", 5173, "/app?q=1#view", ArtifactOpenOrigin.TerminalLink, "live-1",
        )), menu)
    }

    @Test fun linkOnAnUnboundOrDisconnectedThreadStillOpensThroughTheHostLevelOpener() {
        assertEquals(AgentSelectionMenu.Link(ArtifactOpenRequest.Page(
            "host-1", "http", 3000, "/", ArtifactOpenOrigin.TerminalLink, null,
        )), agentSelectionMenu("http://127.0.0.1:3000/", unbound))
        assertEquals(AgentSelectionMenu.Link(ArtifactOpenRequest.Page(
            "host-1", "http", 3000, "/", ArtifactOpenOrigin.TerminalLink, "live-1",
        )), agentSelectionMenu("http://127.0.0.1:3000/", disconnected))
    }

    @Test fun absolutePathOffersBothItemsOnlyWhileTheBoundSessionIsConnected() {
        assertEquals(AgentSelectionMenu.Path(open = true, reveal = true), agentSelectionMenu("/var/log/nginx/error.log", connected))
        assertEquals(AgentSelectionMenu.Path(open = true, reveal = false), agentSelectionMenu("/var/log/nginx/error.log", disconnected))
        assertEquals(AgentSelectionMenu.Path(open = true, reveal = false), agentSelectionMenu("/var/log/nginx/error.log", unbound))
    }

    @Test fun homeAndRelativePathsUseTheTerminalGate() {
        for (path in listOf("~/projects/app/README.md", "src/main/App.kt", "README.md", ".env", "docs/review\n    v3.pdf")) {
            assertEquals(path, AgentSelectionMenu.Path(open = true, reveal = true), agentSelectionMenu(path, connected))
            assertEquals(path, AgentSelectionMenu.Path(open = true, reveal = false), agentSelectionMenu(path, unbound))
        }
    }

    @Test fun plainProseExternalAndRefusedLinksAddNothing() {
        for (text in listOf(
            "", "   ", "plain prose sentence", "noextension", "two words",
            "https://github.com/bambouville/tessera/pull/1", "http://viewer@127.0.0.1:3000/",
            "x".repeat(9_000) + "/a.txt",
        )) {
            for (context in listOf(connected, disconnected, unbound)) {
                assertEquals(text.take(40), AgentSelectionMenu.None, agentSelectionMenu(text, context))
            }
        }
    }

    @Test fun aMissingOpenerOrHostLeavesOnlyWhatCanStillRun() {
        val noOpener = connected.copy(openerAvailable = false)
        assertEquals(AgentSelectionMenu.None, agentSelectionMenu("http://localhost:5173/", noOpener))
        assertEquals(AgentSelectionMenu.Path(open = false, reveal = true), agentSelectionMenu("/srv/app.log", noOpener))
        assertEquals(AgentSelectionMenu.None, agentSelectionMenu("/srv/app.log", noOpener.copy(sessionConnected = false)))
        assertEquals(AgentSelectionMenu.None, agentSelectionMenu("/srv/app.log", connected.copy(hostId = " ")))
        // A connected flag without a bound session can never offer Reveal.
        assertEquals(AgentSelectionMenu.Path(open = true, reveal = false),
            agentSelectionMenu("/srv/app.log", unbound.copy(sessionConnected = true)))
    }

    @Test fun aClassifierFailureAddsNothingInsteadOfBreakingTheMenu() {
        assertEquals(AgentSelectionMenu.None, agentSelectionMenu("/srv/app.log", connected, classifyLink = { error("core unavailable") }))
        assertEquals(AgentSelectionMenu.None, agentSelectionMenu("/srv/app.log", connected,
            classifyLink = { SharedArtifactsLinkClass.Unsupported }, isPlausiblePath = { false }))
    }

    @Test fun hostLevelOpenTakesOnlyAbsolutePathsAndOtherwiseMissesWithTheTerminalMessage() {
        assertEquals(AgentHostLevelPathOpen.Open(ArtifactOpenRequest.File(
            "host-1", "/srv/app/logs/out.log", ArtifactOpenOrigin.TerminalSelection, "live-1",
        )), agentHostLevelPathOpen(" '/srv/app/./logs/../logs/out.log:12' ", "host-1", "live-1"))
        assertEquals(AgentHostLevelPathOpen.Miss(
            "Can't resolve src/App.kt — no terminal directory is available for a relative path.",
        ), agentHostLevelPathOpen("src/App.kt", "host-1", null))
        assertEquals(AgentHostLevelPathOpen.Miss(
            "Can't resolve ~/notes.md — no terminal directory is available for a relative path.",
        ), agentHostLevelPathOpen("~/notes.md", "host-1", "live-1"))
    }

    @Test fun itemsRouteConnectedPathsToTheSessionAndEverythingElseToTheHostOpener() {
        var connectedNow = true
        val opened = mutableListOf<ArtifactOpenRequest>()
        val routed = mutableListOf<Pair<AgentSelectionPathAction, String>>()
        val misses = mutableListOf<String>()
        var unavailable = 0
        var left = 0
        val scope = AgentTranscriptSelectionScope(
            AgentTranscriptSelectionActions(
                isSessionConnected = { connectedNow },
                onPathAction = { detail, action, selection ->
                    assertEquals("host-1", detail.row.hostID)
                    routed += action to selection
                },
                onMiss = { misses += it },
                onSessionUnavailable = { unavailable++ },
            ),
            detail = { thread("live-1") },
            opener = ArtifactOpener { opened += it },
            beforeLeaving = { left++ },
        )
        assertEquals(AgentSelectionMenu.Path(open = true, reveal = true), scope.menu("src/App.kt"))
        scope.openPath("src/App.kt")
        scope.revealPath("/srv/app.log")
        assertEquals(listOf(AgentSelectionPathAction.OpenInArtifacts to "src/App.kt",
            AgentSelectionPathAction.RevealInFiles to "/srv/app.log"), routed)
        assertTrue(opened.isEmpty())

        // The session dropped between the menu and the tap: nothing dials it.
        connectedNow = false
        scope.revealPath("/srv/app.log")
        scope.openPath("/srv/app.log")
        scope.openPath("src/App.kt")
        assertEquals(1, unavailable)
        assertEquals(2, routed.size)
        assertEquals(listOf<ArtifactOpenRequest>(ArtifactOpenRequest.File(
            "host-1", "/srv/app.log", ArtifactOpenOrigin.TerminalSelection, "live-1",
        )), opened)
        assertEquals(listOf("Can't resolve src/App.kt — no terminal directory is available for a relative path."), misses)

        val link = scope.menu("http://localhost:8000/") as AgentSelectionMenu.Link
        scope.openLink(link.request)
        assertEquals(link.request, opened.last())
        assertEquals(3, left)
    }

    @Test fun boundTmuxPaneIsReadOnlyFromAWellFormedPaneID() {
        assertEquals(7, thread("live-1", paneID = "%7").boundTmuxPaneID())
        for (malformed in listOf(null, "7", "%", "%-1", "%x")) {
            assertEquals(malformed, null, thread("live-1", paneID = malformed).boundTmuxPaneID())
        }
    }

    private fun thread(liveSessionID: String?, paneID: String? = "%2"): AgentThreadDetail {
        val row = AgentThreadRow(
            key = "host-1:claude:t", title = "Fixture", provider = "Claude", model = null, preview = null,
            status = "working", attention = "none", location = "~/app", queuedCount = null, isFork = false,
            actionAvailable = true, spawnAvailable = false, forkAvailable = false, hostID = "host-1",
            providerID = "claude", providerSessionID = "t",
        )
        val fields = buildMap<String, SharedAgentValue> {
            liveSessionID?.let { put("liveSessionID", SharedAgentValue.StringValue(it)) }
            put("transport", SharedAgentValue.StringValue("sshTmux"))
            paneID?.let { put("paneID", SharedAgentValue.StringValue(it)) }
        }
        return AgentThreadDetail(row, emptyList(), emptyList(), emptyList(), SharedAgentValue.ObjectValue(fields), false)
    }
}
