package com.bambouville.tessera.core.bridge

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Test

/** The Kotlin copy of the S5′ gate against the shared core's table, through the production JNI glue. */
class SharedAuthorityGateParityTest {
    private val samples: List<SharedBackendCommand> = listOf(
        SharedBackendCommand.Connect(SharedConnectionIntent(UUID.randomUUID(), UUID.randomUUID(), 1)),
        SharedBackendCommand.CancelConnect(UUID.randomUUID()),
        SharedBackendCommand.Disconnect,
        SharedBackendCommand.SendInput(byteArrayOf(0x61)),
        SharedBackendCommand.Resize(80, 24),
        SharedBackendCommand.SetFocused(true),
        SharedBackendCommand.SetVisibility(SharedSessionVisibility.ACTIVE),
        SharedBackendCommand.RequestFullRepaint,
        SharedBackendCommand.SubmitChallengeResponse(UUID.randomUUID(), UUID.randomUUID(), 1, SharedChallengeDecision.APPROVE),
        SharedBackendCommand.SelectTmuxWindow("@1"),
        SharedBackendCommand.SelectTmuxPane("%1"),
        SharedBackendCommand.SendTmuxPaneInput("%1", byteArrayOf(0x61), null),
        SharedBackendCommand.SendTmuxPaneKey("%1", SharedTmuxPaneKey.ENTER, null),
        SharedBackendCommand.CreateTmuxWindow,
        SharedBackendCommand.CloseTmuxWindow("@1"),
        SharedBackendCommand.CloseTmuxPane("%1"),
        SharedBackendCommand.SplitTmuxPane("%1", SharedTmuxSplitAxis.HORIZONTAL),
        SharedBackendCommand.CycleTmuxPane(true),
        SharedBackendCommand.SetTmuxPaneZoomed("%1", true),
        SharedBackendCommand.MoveTmuxWindow("@1", 0),
        SharedBackendCommand.RenumberTmuxWindows,
        SharedBackendCommand.RenameTmuxWindow("@1", "w"),
        SharedBackendCommand.SetTmuxGridPresentation(SharedTmuxGridPresentation.SINGLE_PANE),
        SharedBackendCommand.ClaimTmuxGridAuthority(SharedTmuxGridAuthorityReason.FORCE_REFRESH, true),
        SharedBackendCommand.ReclaimTmuxGridAuthority(SharedTmuxGridAuthorityReason.USER),
        SharedBackendCommand.CompleteTmuxGridAuthorityRepaint(1),
    )

    @Test fun everyKotlinCommandKindHasASample() {
        val kinds = SharedBackendCommand::class.java.declaredClasses
            .filter { SharedBackendCommand::class.java.isAssignableFrom(it) }
            .map { it.simpleName }.toSet()
        assertEquals(kinds, samples.map { it::class.java.simpleName }.toSet())
        assertEquals(samples.size, samples.map { it.kindCode }.toSet().size)
    }

    @Test fun kotlinGatesMatchTheSharedCore() {
        val core = SharedTmuxCommands.sessionAuthorityGates
        for (command in samples) {
            assertEquals(command.kindCode, core[command.kindCode], command.authorityGate.wireValue)
        }
        // The core's only kind that never reaches an Android backend.
        assertEquals(setOf("destroy"), core.keys - samples.map { it.kindCode }.toSet())
    }

    @Test fun agentCenterReadsPassAndLaunchWritesWaitThroughTheCore() {
        for (read in listOf("display-message -p -t %3 x", "capture-pane -p", "list-panes -s", "delete-buffer -b b")) {
            assertEquals(read, true, SharedTmuxCommands.agentCommandIsReadOnly(read))
        }
        for (write in listOf("set-buffer -b b 'eA=='", "new-window -d -P", "split-window -d -h -t %3 x", "")) {
            assertEquals(write, false, SharedTmuxCommands.agentCommandIsReadOnly(write))
        }
    }

    @Test fun provedPaneRepliesAreNeutralThroughTheProductionJniGlue() {
        for (command in listOf(
            "display-message -p -t %3 x", "capture-pane -p", "delete-buffer -b b",
            "send-keys -t %3 -H 61 FF", "send-keys -t %0 -H 00",
            "send-keys -t %3 Enter", "send-keys -t %3 Escape",
            "send-keys -t %3 Tab", "send-keys -t %3 BTab", "send-keys -t %3 Up", "send-keys -t %3 Down",
            "send-keys -t %3 Left", "send-keys -t %3 Right", "send-keys -t %3 S-Left", "send-keys -t %3 C-]",
        )) {
            assertEquals(command, true, SharedTmuxCommands.agentCommandIsAuthorityNeutral(command))
        }
        assertEquals(false, SharedTmuxCommands.agentCommandIsReadOnly("send-keys -t %3 -H 61"))
        for (command in listOf(
            "", "new-window -d", "set-buffer -b b x", "split-window -d -t %3 x",
            "select-window -t @3", "select-pane -t %3", "send-keys -t @3 Enter",
            "send-keys -t \$3 Enter", "send-keys -t :3 Enter", "send-keys -t .3 Enter",
            "send-keys -t % Enter", "send-keys -t %٣ Enter", "send-keys -t %3 -H",
            "send-keys -t %3 -H 6", "send-keys -t %3 -H 061", "send-keys -t %3 -H gg",
            "send-keys -t %3 Enter Escape", "send-keys -t %3 PageUp", "send-keys -t %3 C-c",
            "send-keys -t %3 Enter; new-window", "send-keys -t %3 Enter \\; new-window",
            "send-keys -t %3 Enter\n", "send-keys -t %3 Enter\r",
        ) + listOf("-X", "-R", "-M", "-F", "-N", "-l", "-K", "-c").map { "send-keys -t %3 $it Enter" }) {
            assertEquals(command, false, SharedTmuxCommands.agentCommandIsAuthorityNeutral(command))
        }
    }

    @Test fun onlyReceiptedPaneInputAndKeysAreUngatedInTheKotlinCopy() {
        for (receipt in listOf(null, SharedSessionCommandReceipt(UUID.randomUUID()))) {
            val gate = if (receipt == null) SharedCommandAuthorityGate.MUTATION else SharedCommandAuthorityGate.UNGATED
            for (command in listOf(
                SharedBackendCommand.SendTmuxPaneInput("%3", byteArrayOf(0x61), receipt),
                SharedBackendCommand.SendTmuxPaneKey("%3", SharedTmuxPaneKey.ENTER, receipt),
                SharedBackendCommand.SendTmuxPaneKey("%3", SharedTmuxPaneKey.ESCAPE, receipt),
            )) {
                assertEquals(command.kindCode, gate, command.authorityGate)
            }
        }
    }
}
