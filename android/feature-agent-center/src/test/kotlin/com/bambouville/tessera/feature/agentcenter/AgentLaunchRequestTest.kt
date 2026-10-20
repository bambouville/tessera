package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentLaunchRequestTest {
    private val target = AgentLaunchTarget(
        liveSessionID = "live-1",
        carrierGeneration = 1,
        hostID = "host-1",
        transport = "sshTmux",
        hostLabel = "fixture",
        tmuxSession = "main",
        windowID = "@4",
        paneID = "%8",
        provenDirectories = listOf("/repo", "/srv/tessera"),
    )

    @Test fun forkCapturesEveryUserSelectionWithoutBuildingACommand() {
        val request = AgentLaunchDraft(
            task = "  inspect the migration  ",
            name = " reviewer ",
            directory = " /srv/tessera ",
            placement = AgentLaunchPlacement.SplitDown,
            newWorktree = true,
            branch = " feature/review ",
        ).toRequestOrNull(AgentLaunchKind.Fork, "claude", target)

        requireNotNull(request)
        assertEquals(AgentLaunchKind.Fork, request.kind)
        assertEquals("inspect the migration", request.task)
        assertEquals("reviewer", request.name)
        assertEquals("claude", request.providerID)
        assertEquals("live-1", request.target.liveSessionID)
        assertEquals(AgentLaunchPlacement.SplitDown, request.placement)
        assertEquals(AgentLaunchIsolation.NewWorktree("feature/review"), request.isolation)
    }

    @Test fun splitNeedsExactWindowAndPaneButNewWindowDoesNotInventThem() {
        val noPane = target.copy(windowID = null, paneID = null)
        val split = AgentLaunchDraft(task = "x", directory = "/repo", placement = AgentLaunchPlacement.SplitRight)
            .toRequestOrNull(AgentLaunchKind.Spawn, "claude", noPane)
        val newWindow = AgentLaunchDraft(task = "x", directory = "/repo")
            .toRequestOrNull(AgentLaunchKind.Spawn, "claude", noPane)

        assertNull(split)
        assertTrue(newWindow != null)
    }

    @Test fun newWorktreeRequiresABranch() {
        val request = AgentLaunchDraft(task = "x", directory = "/repo", newWorktree = true)
            .toRequestOrNull(AgentLaunchKind.Spawn, "claude", target)

        assertNull(request)
    }
}
