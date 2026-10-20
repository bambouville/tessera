package com.bambouville.tessera.feature.session

import com.bambouville.tessera.agent.platform.AgentEndpointTransport
import com.bambouville.tessera.agent.platform.AgentEndpointResult
import com.bambouville.tessera.agent.platform.AgentSessionKey
import com.bambouville.tessera.agent.platform.AgentTmuxControlAck
import com.bambouville.tessera.networking.SshRouteOwner
import com.bambouville.tessera.terminal.TerminalTextSnapshot
import java.io.Closeable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.assertSame
import org.junit.Test
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.CompletableDeferred
import com.bambouville.tessera.core.bridge.SharedTerminalScreenEvidence

class SshAgentSessionEndpointOutputTest {
    @Test fun leavingDuringWindowFocusPreventsTheLaterPaneSelection() = runBlocking {
        val route = unusedRouteOwner()
        val windowAck = CompletableDeferred<CompletableDeferred<AgentTmuxControlAck>>()
        var presented = true
        var panes = 0
        val port = TmuxAgentControlPort()
        port.attach(sender = { error("unexpected sender") },
            windowSelector = { _, ack -> windowAck.complete(ack); true },
            paneSelector = { _, _, ack -> panes++; ack.complete(AgentTmuxControlAck(true, emptyList())); true })
        val endpoint = SshAgentSessionEndpoint(AgentSessionKey("leaving", 1), "host", AgentEndpointTransport.MOSH_TMUX,
            route = route, tmuxSession = "fixture", tmuxControl = port)
        try {
            endpoint.updateActiveTmuxTarget(1, 4)
            val focusing = async { endpoint.focus(endpoint.binding.value) { presented } }
            val ack = withTimeout(1_000) { windowAck.await() }
            presented = false
            ack.complete(AgentTmuxControlAck(true, emptyList()))
            assertEquals(AgentEndpointResult.StaleBinding, withTimeout(1_000) { focusing.await() })
            assertEquals(0, panes)
        } finally { endpoint.close(); route.close() }
    }

    @Test fun absentMoshDriverAndClosedSshRouteReportNoInputAdmission() = runBlocking {
        val mosh = com.bambouville.tessera.networking.mosh.AndroidMoshTransport(
            bootstrapper = com.bambouville.tessera.networking.mosh.MoshBootstrapper { error("unused") })
        for (transport in listOf(AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH)) {
            val route = unusedRouteOwner()
            var writes = 0
            val endpoint = SshAgentSessionEndpoint(AgentSessionKey("unadmitted", 1), "host", transport, route = route,
                rawWriter = { writes++; mosh.send(it) })
            try {
                val result = endpoint.sendInput(endpoint.binding.value, "hello".encodeToByteArray()) as AgentEndpointResult.Failed
                assertEquals("raw_input_unavailable", result.code)
                assertTrue(result.inputNotAdmitted)
                assertEquals(if (transport == AgentEndpointTransport.SSH) 0 else 1, writes)
            } finally { endpoint.close(); route.close() }
        }
        mosh.close()
    }

    @Test fun rawWriterFailureAfterPossibleAdmissionRemainsAmbiguous() = runBlocking {
        val route = unusedRouteOwner()
        var writes = 0
        val endpoint = SshAgentSessionEndpoint(AgentSessionKey("ambiguous", 1), "host", AgentEndpointTransport.MOSH,
            route = route, rawWriter = { writes++; throw java.io.IOException("failed after write") })
        try {
            val result = endpoint.sendInput(endpoint.binding.value, "hello".encodeToByteArray()) as AgentEndpointResult.Failed
            assertEquals("raw_write_failed", result.code)
            org.junit.Assert.assertFalse(result.inputNotAdmitted)
            assertEquals(1, writes)
        } finally { endpoint.close(); route.close() }
    }

    @Test fun tmuxPromptKeysAreNamedAndRawKeysKeepTheirBytes() = runBlocking {
        for (transport in AgentEndpointTransport.entries.filter { it != AgentEndpointTransport.SSH }) {
            val route = unusedRouteOwner()
            val commands = mutableListOf<String>()
            val raw = mutableListOf<ByteArray>()
            val endpoint = SshAgentSessionEndpoint(AgentSessionKey("keys", 1), "host", transport, route = route,
                rawWriter = { raw += it.copyOf() }, tmuxSession = "fixture",
                tmuxControl = TmuxAgentControlPort(directResponder = { commands += it; AgentTmuxControlAck(true, emptyList()) }))
            try {
                if (transport.name.endsWith("TMUX")) endpoint.updateActiveTmuxTarget(1, 4)
                val binding = endpoint.binding.value
                for (key in com.bambouville.tessera.agent.platform.AgentSemanticKey.entries) {
                    assertTrue(endpoint.sendSemanticKey(binding, key) is AgentEndpointResult.Success)
                    if (transport.name.endsWith("TMUX")) assertEquals("send-keys -t %4 ${key.tmuxName}", commands.last())
                    else org.junit.Assert.assertArrayEquals(key.encoded(), raw.last())
                }
                assertEquals(if (transport.name.endsWith("TMUX")) 10 else 0, commands.size)
                assertEquals(if (transport.name.endsWith("TMUX")) 0 else 10, raw.size)
            } finally { endpoint.close(); route.close() }
        }
    }

    @Test fun yieldedFocusWaitsWithoutSelectionAndSelectsTheExactTargetAfterSettlement() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val route = unusedRouteOwner()
            val commands = mutableListOf<String>()
            var yielded = true
            val port = TmuxAgentControlPort()
            port.attach(sender = { error("unexpected sender") },
                windowSelector = { window, ack -> commands += "window:$window"; ack.complete(AgentTmuxControlAck(true, emptyList())); true },
                paneSelector = { pane, zoom, ack -> commands += "pane:$pane:$zoom"; ack.complete(AgentTmuxControlAck(true, emptyList())); true },
                refusal = { if (yielded) "yielded" else null })
            val endpoint = SshAgentSessionEndpoint(AgentSessionKey("focus", 1), "host", transport, route = route,
                tmuxSession = "fixture", tmuxControl = port)
            try {
                endpoint.updateActiveTmuxTarget(1, 4)
                assertEquals(AgentEndpointResult.Failed("tmux_controlled_elsewhere"), endpoint.focus(endpoint.binding.value))
                assertTrue(commands.isEmpty())
                yielded = false
                assertTrue(endpoint.focus(endpoint.binding.value) is AgentEndpointResult.Success)
                assertEquals(listOf("window:@1", "pane:%4:true"), commands)
            } finally { endpoint.close(); route.close() }
        }
    }

    @Test fun quietNewPaneSurvivesLifecycleFlowBackpressure() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val route = unusedRouteOwner()
            val endpoint = SshAgentSessionEndpoint(AgentSessionKey("late-pane", 1), "test-host", transport,
                route = route, tmuxSession = "fixture-session")
            val blocked = CompletableDeferred<Unit>()
            val release = CompletableDeferred<Unit>()
            val discovered = CompletableDeferred<Unit>()
            val collector = launch(start = CoroutineStart.UNDISPATCHED) {
                endpoint.lifecycleFrames.collect { frame ->
                    if (!blocked.isCompleted) { blocked.complete(Unit); release.await() }
                    if (frame.binding.paneID == "%201") discovered.complete(Unit)
                }
            }
            try {
                endpoint.noteTmuxAgentState(1, 1, "first")
                withTimeout(2_000) { blocked.await() }
                repeat(200) { endpoint.noteTmuxAgentState(2, it + 2, "state-$it") }
                release.complete(Unit)
                withTimeout(2_000) { discovered.await() }
                assertEquals("state-199", endpoint.retainedLifecycleFrame(
                    endpoint.binding.value.copy(windowID = "@2", paneID = "%201"))?.payload?.decodeToString())
            } finally { collector.cancelAndJoin(); endpoint.close(); route.close() }
        }
    }

    @Test fun rawComposerCapturePreservesCellStyleAndColumnForBothTransports() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH)) {
            val route = unusedRouteOwner()
            val endpoint = SshAgentSessionEndpoint(AgentSessionKey("styled-raw", 1), "test-host", transport, route = route)
            try {
                val text = "❯ suggested"
                val cells = text.mapIndexed { index, char -> SharedTerminalScreenEvidence.Cell(char.toString(), 1, if (index >= 2) 32 else 0) }
                val screen = SharedTerminalScreenEvidence(text.length, listOf(cells), listOf(false), 0, 2, true, false)
                endpoint.noteRawSnapshot(TerminalTextSnapshot(text, text, listOf(text),
                    cursorRow = 0, cursorVisible = true, cursorColumn = 2, screenEvidence = screen))
                val observed = (endpoint.inspect(endpoint.binding.value) as AgentEndpointResult.Success).value
                assertEquals(text, observed.visibleTail.decodeToString())
                assertEquals(text, observed.currentCursorLine)
                assertSame(screen, observed.screenEvidence)
                assertEquals(2, observed.cursorColumn)
                assertTrue(observed.authoritative)
            } finally { endpoint.close(); route.close() }
        }
    }

    @Test fun unavailableFreshCaptureWaitsForCompleteFrameWithoutUsingCachedComposer() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH, AgentEndpointTransport.MOSH)) {
            val route = unusedRouteOwner()
            val endpoint = SshAgentSessionEndpoint(AgentSessionKey("frame-raw", 1), "test-host", transport, route = route)
            try {
                endpoint.noteRawSnapshot(TerminalTextSnapshot("stale", "stale", cursorRow = 0, cursorColumn = 2, cursorVisible = true))
                var captures = 0
                endpoint.setRawSnapshotSource {
                    captures++
                    if (captures < 3) TerminalTextSnapshot("", null, framePending = true) else TerminalTextSnapshot("fresh", "fresh", cursorRow = 0, cursorColumn = 2, cursorVisible = true)
                }
                val observed = (endpoint.inspect(endpoint.binding.value) as AgentEndpointResult.Success).value
                assertEquals(3, captures)
                assertTrue(observed.captureWaitedForFrame)
                assertEquals("fresh", observed.currentCursorLine)
            } finally { endpoint.close(); route.close() }
        }
    }

    @Test fun cancellingFrameWaitStopsBeforePublishingEvidence() = runBlocking {
        val route = unusedRouteOwner()
        val endpoint = SshAgentSessionEndpoint(AgentSessionKey("cancel-frame", 1), "test-host", AgentEndpointTransport.MOSH, route = route)
        try {
            val entered = CompletableDeferred<Unit>()
            var captures = 0
            endpoint.setRawSnapshotSource { captures++; entered.complete(Unit); TerminalTextSnapshot("", null, framePending = true) }
            val read = async { endpoint.inspect(endpoint.binding.value) }
            entered.await()
            read.cancelAndJoin()
            assertTrue(read.isCancelled)
            assertEquals(1, captures)
        } finally { endpoint.close(); route.close() }
    }

    @Test fun permanentCaptureFailureDoesNotPollOrReuseCachedInput() = runBlocking {
        val route = unusedRouteOwner()
        val endpoint = SshAgentSessionEndpoint(AgentSessionKey("missing-raw", 1), "test-host", AgentEndpointTransport.SSH, route = route)
        try {
            endpoint.noteRawSnapshot(TerminalTextSnapshot("stale", "stale"))
            var captures = 0
            endpoint.setRawSnapshotSource { captures++; null }
            assertTrue(endpoint.inspect(endpoint.binding.value) is AgentEndpointResult.Unavailable)
            assertEquals(1, captures)
        } finally { endpoint.close(); route.close() }
    }

    @Test fun tmuxComposerCaptureRetriesWhenOnlyCursorColumnMoves() = runBlocking {
        for (transport in listOf(AgentEndpointTransport.SSH_TMUX, AgentEndpointTransport.MOSH_TMUX)) {
            val route = unusedRouteOwner()
            var cursors = 0
            var captures = 0
            val styled = "❯ \u001b[2;3msuggested\u001b[0m"
            val endpoint = SshAgentSessionEndpoint(AgentSessionKey("styled-tmux", 1), "test-host", transport, route = route,
                tmuxSession = "test-session", tmuxControl = TmuxAgentControlPort(directResponder = { command ->
                    if (command.startsWith("display-message")) {
                        assertTrue(command.contains("#{cursor_y}:#{cursor_x}:#{cursor_flag}"))
                        cursors++
                        AgentTmuxControlAck(true, listOf(if (cursors == 2) "0:3:1" else "0:2:1"))
                    } else {
                        assertTrue(command.startsWith("capture-pane -p -e -N"))
                        captures++
                        AgentTmuxControlAck(true, listOf(styled))
                    }
                }))
            try {
                endpoint.updateActiveTmuxTarget(1, 2)
                val observed = (endpoint.inspect(endpoint.binding.value) as AgentEndpointResult.Success).value
                assertEquals(2, captures)
                assertEquals(4, cursors)
                assertEquals(2, observed.cursorColumn)
                assertEquals("❯ suggested", observed.currentCursorLine)
                assertTrue(observed.authoritative)
            } finally { endpoint.close(); route.close() }
        }
    }

    /** The cursor row is its cells, as on iOS: escapes go before the bound, which splits no glyph. */
    @Test fun tmuxCursorRowIsItsCellsWithinTheBound() = runBlocking {
        val link = "\u001b]8;;https://example.com/" + "x".repeat(2_100) + "\u001b\\❯ 1. Yes\u001b]8;;\u001b\\"
        for ((row, expected) in listOf(link to "❯ 1. Yes", "a".repeat(2_047) + "😀" to "a".repeat(2_047))) {
            val route = unusedRouteOwner()
            val endpoint = SshAgentSessionEndpoint(AgentSessionKey("cursor-row", 1), "test-host", AgentEndpointTransport.SSH_TMUX, route = route,
                tmuxSession = "test-session", tmuxControl = TmuxAgentControlPort(directResponder = { command ->
                    if (command.startsWith("display-message")) AgentTmuxControlAck(true, listOf("0:0:1"))
                    else AgentTmuxControlAck(true, listOf(row, "  2. No"))
                }))
            try {
                endpoint.updateActiveTmuxTarget(1, 2)
                val observed = (endpoint.inspect(endpoint.binding.value) as AgentEndpointResult.Success).value
                assertEquals(expected, observed.currentCursorLine)
            } finally { endpoint.close(); route.close() }
        }
    }

    @Test(timeout = 5_000)
    fun attachmentUsesRenewedAuxiliaryRouteExactlyOnce() = runBlocking {
        val original = unusedRouteOwner()
        val replacement = unusedRouteOwner()
        var uploads = 0
        val endpoint = SshAgentSessionEndpoint(
            key = AgentSessionKey("renewed-attachment", 1),
            hostID = "test-host",
            transport = AgentEndpointTransport.MOSH,
            route = original,
            renewAuxiliaryRoute = { previous -> assertSame(original, previous); replacement },
            attachmentUpload = { uploadRoute, uri ->
                assertSame(replacement, uploadRoute)
                assertEquals("content://fixture/attachment", uri)
                uploads += 1
                AgentEndpointResult.Success("uploaded-path")
            },
        )
        try {
            assertEquals(
                AgentEndpointResult.Success("uploaded-path"),
                endpoint.uploadAttachment(endpoint.binding.value, "content://fixture/attachment"),
            )
            assertEquals(1, uploads)
        } finally {
            endpoint.close()
            original.close()
            replacement.close()
        }
    }

    @Test
    fun ordinaryTmuxOutputPacketCountDoesNotScheduleControlOrLifecycleWork() {
        var controlCommands = 0
        val endpoint = SshAgentSessionEndpoint(
            key = AgentSessionKey("packet-independent-output", 1),
            hostID = "test-host",
            transport = AgentEndpointTransport.SSH_TMUX,
            route = unusedRouteOwner(),
            tmuxSession = "test-session",
            tmuxControl = TmuxAgentControlPort(
                directResponder = {
                    controlCommands += 1
                    AgentTmuxControlAck(success = true, lines = emptyList())
                },
            ),
        )

        repeat(10_000) { packet ->
            endpoint.noteTmuxOutput(
                windowID = 1,
                paneID = 2,
                bytes = "ordinary terminal output $packet\r\n".encodeToByteArray(),
            )
        }

        assertEquals(0, controlCommands)
        assertTrue(endpoint.lifecycleFrames.replayCache.isEmpty())
        endpoint.close()
    }

    /**
     * Output ingestion never uses the SSH route. The endpoint nevertheless
     * requires its route owner, so construct an unconnected owner without
     * opening a socket; any unexpected route use makes the test fail.
     */
    private fun unusedRouteOwner(): SshRouteOwner {
        val sshClientType = Class.forName("net.schmizz.sshj.SSHClient")
        val sshClient = sshClientType.getDeclaredConstructor().newInstance()
        val constructor = SshRouteOwner::class.java.declaredConstructors.single {
            it.parameterTypes.size == 2
        }
        constructor.isAccessible = true
        return constructor.newInstance(sshClient, emptyList<Closeable>()) as SshRouteOwner
    }
}
