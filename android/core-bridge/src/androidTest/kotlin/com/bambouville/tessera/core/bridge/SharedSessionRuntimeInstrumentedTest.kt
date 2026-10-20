package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.UUID
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertArrayEquals
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SharedSessionRuntimeInstrumentedTest {
    @Test
    fun sharedTmuxRuntimeOwnsTopologyAndPaneRouting() {
        val events = LinkedBlockingQueue<SharedTmuxEvent>()
        val trace = InstrumentationRegistry.getInstrumentation().context.assets
            .open("tmux/basic-topology.trace").use { it.readBytes() }
        SharedTmuxRuntime.create(events::add).use { runtime ->
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed(byteArrayOf(0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70) + trace),
            )
            val event = events.takeWithin()
            assertEquals("work", event.snapshot.sessionName)
            assertEquals(1, event.snapshot.activeWindowId)
            assertEquals(listOf("editor", "logs"), event.snapshot.windows.map { it.name })
            assertTrue(event.renderEffects.isEmpty())
        }
    }

    @Test
    fun sharedTmuxAuthoritySessionClaimsOnlyOnAShowAndSurvivesTheOwnStampRace() {
        val ipad = SharedTmuxGridAuthoritySnapshot.Peer("ipad", "iPad", 7)
        SharedTmuxAuthoritySession.create().use { session ->
            assertEquals(
                listOf(SharedTmuxAuthoritySessionEffect.QueryAuthority(1)),
                session.attached(0, localDeviceId = "android-test").effects,
            )
            assertEquals(
                listOf(SharedTmuxAuthoritySessionEffect.AuthorityChanged(ipad)),
                session.queryReplied(1, queryId = 1, rawValue = "v1 ipad 7 iPad").effects,
            )

            session.resetTransport(2, preservingPeer = true)
            assertEquals(
                listOf(SharedTmuxAuthoritySessionEffect.QueryAuthority(2)),
                session.attached(3).effects,
            )
            val shown = session.shown(4)
            assertEquals(listOf(SharedTmuxAuthoritySessionEffect.QueryAuthority(3)), shown.effects)
            assertEquals(SharedTmuxAuthorityIntentSource.SHOW, shown.state.pendingIntent?.source)
            val show = session.queryReplied(5, queryId = 3, rawValue = "v1 ipad 7 iPad").effects
                .filterIsInstance<SharedTmuxAuthoritySessionEffect.BeginClaim>()
                .single()
            assertEquals(SharedTmuxAuthorityClaimReason.SHOW, show.reason)
            session.observedAuthority(6, SharedTmuxGridAuthoritySnapshot.Peer("ipad", "iPad", 8))
            val replacement = session.ownStampObserved(7, show.generation).effects
                .filterIsInstance<SharedTmuxAuthoritySessionEffect.BeginClaim>()
                .single()
            assertEquals(SharedTmuxAuthorityClaimReason.OWN_WRITE_WON, replacement.reason)
            assertTrue(replacement.generation > show.generation)
        }
    }

    @Test
    fun oversizedTmuxAuthoritySessionRequestDoesNotAdvanceState() {
        NativeLibraries.ensureLoaded()
        val handle = NativeCoreBindings.createTmuxAuthorityLifecycleSeeded(0)
        assertTrue(handle != 0L)
        try {
            fun reduce(json: String): ByteArray? {
                val bytes = json.encodeToByteArray()
                return NativeCoreBindings.reduceTmuxAuthorityLifecycle(handle, bytes.toDirectBuffer(), bytes.size)
            }
            fun snapshot(): SharedTmuxAuthoritySessionState {
                val response = checkNotNull(reduce("""{"version":2,"event":"snapshot","nowMillis":0}"""))
                return checkNotNull(SharedTmuxAuthoritySession.parse(JSONObject(response.decodeToString()))).state
            }
            checkNotNull(reduce("""{"version":2,"event":"attached","nowMillis":0}"""))
            val before = snapshot()
            // Use the native entry point: the session wrapper reports a
            // rejected reply as queryFailed, which intentionally schedules a retry.
            assertNull(reduce(
                """{"version":2,"event":"queryReplied","nowMillis":1,"queryID":1,"rawAuthorityValue":"v1 peer 1 ${"p".repeat(65_536)}"}""",
            ))
            assertEquals(before, snapshot())
            assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, before.authority)
            assertEquals(0L, before.nextGeneration)
        } finally {
            NativeCoreBindings.destroyTmuxAuthorityLifecycle(handle)
        }
    }

    @Test
    fun sharedTmuxAuthorityCommandValuesComeFromCore() {
        assertEquals(
            "@tessera-visible-phone-one",
            SharedTmuxCommands.authorityVisibleClientOption("phone one"),
        )
        assertEquals(
            "v1 phone-one 9 Android-Phone",
            SharedTmuxCommands.authorityStampValue(
                "phone one", "Android Phone", 9,
            ),
        )
    }

    @Test
    fun sharedTmuxRuntimeParsesV3BellAndOrderedRenderEffects() {
        val event = SharedTmuxRuntime.parse(
            """
            {
              "version": 3,
              "snapshot": { "windows": [], "revision": 9 },
              "bells": [
                { "windowID": { "rawValue": 2 }, "isActiveWindow": false, "windowName": "build" },
                { "windowID": { "rawValue": 3 }, "isActiveWindow": true, "windowName": null }
              ],
              "renderEffects": [
                { "kind": "sendCommand", "command": "capture-pane -p" },
                {
                  "kind": "feed",
                  "surfaceID": "live",
                  "owner": { "windowID": 2, "epoch": 7 },
                  "bytesRef": { "id": 19 },
                  "source": "tmux-repaint-deep"
                },
                { "kind": "initialRenderReady" }
              ]
            }
            """.trimIndent().encodeToByteArray(),
        )
        assertEquals(
            listOf(
                SharedTmuxBell(windowId = 2, isActiveWindow = false, windowName = "build"),
                SharedTmuxBell(windowId = 3, isActiveWindow = true, windowName = null),
            ),
            event.bells,
        )
        assertEquals(
            listOf(
                SharedTmuxRenderEffect.SendCommand("capture-pane -p"),
                SharedTmuxRenderEffect.Feed(
                    surfaceId = "live",
                    owner = SharedTmuxRenderOwner(windowId = 2, paneId = null, epoch = 7),
                    bytesRef = 19,
                    source = SharedTmuxRenderFeedSource.DeepRepaint,
                ),
                SharedTmuxRenderEffect.InitialRenderReady,
            ),
            event.renderEffects,
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun sharedTmuxRuntimeRejectsV1CallbackEnvelopeAfterRenderLedgerUpgrade() {
        SharedTmuxRuntime.parse(
            """{"version":1,"snapshot":{"windows":[],"revision":10},"paneOutputs":[],"responseFrames":[]}"""
                .encodeToByteArray(),
        )
    }

    @Test
    fun typedProjectionRoutesConnectionChallengeAndTerminalEvents() {
        val events = LinkedBlockingQueue<SharedSessionEvent>()
        val commands = LinkedBlockingQueue<SharedBackendCommand>()
        SharedSessionRuntime.create(object : SharedSessionListener {
            override fun onEvent(event: SharedSessionEvent) { events += event }
            override fun onBackendCommand(command: SharedBackendCommand) { commands += command }
        }).use { runtime ->
            val intent = SharedConnectionIntent(UUID.randomUUID(), UUID.randomUUID(), 7)
            assertEquals(CoreCallResult.Accepted, runtime.connect(intent))
            assertEquals(SharedBackendCommand.Connect(intent), commands.takeWithin())
            assertEquals(SharedSessionState.CONNECTING, events.stateWithin())

            val challengeId = UUID.randomUUID()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.emitCredentialChallenge(
                    challengeId,
                    intent.requestId,
                    intent.policyGeneration,
                    credentialId = null,
                    kind = "password",
                ),
            )
            val challenge = events.takeWithin() as SharedSessionEvent.Challenge
            assertEquals("credential", challenge.kind)
            assertEquals(challengeId, challenge.challengeId)

            runtime.submitChallengeResponse(
                challengeId,
                intent.requestId,
                intent.policyGeneration,
                SharedChallengeDecision.APPROVE,
            )
            assertTrue(commands.takeWithin() is SharedBackendCommand.SubmitChallengeResponse)

            runtime.emitTransportConnected(intent)
            assertEquals(SharedSessionState.CONNECTED, events.stateWithin())
            val bytes = "shared-terminal".encodeToByteArray()
            runtime.emitTerminalBytes(
                bytes,
                receipt = SharedTerminalOutputReceipt(
                    deliveryId = 17,
                    repaintRequestId = 9,
                ),
                attemptId = intent.requestId,
            )
            val terminal = events.takeWithin() as SharedSessionEvent.TerminalBytes
            assertArrayEquals(bytes, terminal.bytes)
            assertEquals(17L, terminal.receipt?.deliveryId)
            assertEquals(9L, terminal.receipt?.repaintRequestId)
        }
    }

    @Test
    fun rejectedChallengeResponseDoesNotPoisonNextBackendCommand() {
        val events = LinkedBlockingQueue<SharedSessionEvent>()
        val commands = LinkedBlockingQueue<SharedBackendCommand>()
        SharedSessionRuntime.create(object : SharedSessionListener {
            override fun onEvent(event: SharedSessionEvent) { events += event }
            override fun onBackendCommand(command: SharedBackendCommand) { commands += command }
        }).use { runtime ->
            val intent = SharedConnectionIntent(UUID.randomUUID(), UUID.randomUUID(), 11)
            assertEquals(CoreCallResult.Accepted, runtime.connect(intent))
            assertEquals(SharedBackendCommand.Connect(intent), commands.takeWithin())
            assertEquals(SharedSessionState.CONNECTING, events.stateWithin())

            runtime.submitChallengeResponse(
                UUID.randomUUID(),
                intent.requestId,
                intent.policyGeneration,
                SharedChallengeDecision.APPROVE,
            )
            val rejection = events.takeWithin() as SharedSessionEvent.CommandRejected
            assertEquals("challenge_unknown", rejection.code)
            assertEquals("submit_challenge_response", rejection.commandCode)

            val challengeId = UUID.randomUUID()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.emitCredentialChallenge(
                    challengeId,
                    intent.requestId,
                    intent.policyGeneration,
                    credentialId = null,
                    kind = "password",
                ),
            )
            assertEquals(challengeId, (events.takeWithin() as SharedSessionEvent.Challenge).challengeId)
            runtime.submitChallengeResponse(
                challengeId,
                intent.requestId,
                intent.policyGeneration,
                SharedChallengeDecision.APPROVE,
            )
            val response = commands.takeWithin() as SharedBackendCommand.SubmitChallengeResponse
            assertEquals(challengeId, response.challengeId)
        }
    }

    @Test
    fun expiredChallengeRejectsResponseAndFreshRegistrationAcceptsIt() {
        val events = LinkedBlockingQueue<SharedSessionEvent>()
        val commands = LinkedBlockingQueue<SharedBackendCommand>()
        SharedSessionRuntime.create(object : SharedSessionListener {
            override fun onEvent(event: SharedSessionEvent) { events += event }
            override fun onBackendCommand(command: SharedBackendCommand) { commands += command }
        }).use { runtime ->
            val intent = SharedConnectionIntent(UUID.randomUUID(), UUID.randomUUID(), 13)
            assertEquals(CoreCallResult.Accepted, runtime.connect(intent))
            assertEquals(SharedBackendCommand.Connect(intent), commands.takeWithin())
            assertEquals(SharedSessionState.CONNECTING, events.stateWithin())

            val expiredId = UUID.randomUUID()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.emitCredentialChallenge(
                    expiredId,
                    intent.requestId,
                    intent.policyGeneration,
                    credentialId = null,
                    kind = "password",
                    lifetimeSeconds = 2,
                ),
            )
            assertEquals(expiredId, (events.takeWithin() as SharedSessionEvent.Challenge).challengeId)
            // expiresAt is floored to whole seconds: 3.5 seconds is safely past the full 2-second lifetime.
            Thread.sleep(3_500)
            runtime.submitChallengeResponse(
                expiredId,
                intent.requestId,
                intent.policyGeneration,
                SharedChallengeDecision.APPROVE,
            )
            val rejection = events.takeWithin() as SharedSessionEvent.CommandRejected
            assertEquals("challenge_expired", rejection.code)
            assertEquals("submit_challenge_response", rejection.commandCode)
            assertNull(commands.poll(250, TimeUnit.MILLISECONDS))

            val freshId = UUID.randomUUID()
            assertEquals(
                CoreCallResult.Accepted,
                runtime.emitCredentialChallenge(
                    freshId,
                    intent.requestId,
                    intent.policyGeneration,
                    credentialId = null,
                    kind = "password",
                ),
            )
            assertEquals(freshId, (events.takeWithin() as SharedSessionEvent.Challenge).challengeId)
            runtime.submitChallengeResponse(
                freshId,
                intent.requestId,
                intent.policyGeneration,
                SharedChallengeDecision.APPROVE,
            )
            val response = commands.takeWithin() as SharedBackendCommand.SubmitChallengeResponse
            assertEquals(freshId, response.challengeId)
            assertEquals(intent.requestId, response.attemptId)
            assertEquals(intent.policyGeneration, response.policyGeneration)
            assertEquals(SharedChallengeDecision.APPROVE, response.decision)
        }
    }

    @Test
    fun typedTmuxCommandsAndSessionEventsRoundTripThroughSharedAbi() {
        val events = LinkedBlockingQueue<SharedSessionEvent>()
        val commands = LinkedBlockingQueue<SharedBackendCommand>()
        SharedSessionRuntime.create(object : SharedSessionListener {
            override fun onEvent(event: SharedSessionEvent) { events += event }
            override fun onBackendCommand(command: SharedBackendCommand) { commands += command }
        }).use { runtime ->
            val intent = SharedConnectionIntent(UUID.randomUUID(), UUID.randomUUID(), 17)
            assertEquals(CoreCallResult.Accepted, runtime.connect(intent))
            assertEquals(SharedBackendCommand.Connect(intent), commands.takeWithin())
            assertEquals(SharedSessionState.CONNECTING, events.stateWithin())
            assertEquals(CoreCallResult.Accepted, runtime.emitTransportConnected(intent))
            assertEquals(SharedSessionState.CONNECTED, events.stateWithin())

            val receipt = SharedSessionCommandReceipt(UUID.randomUUID())
            val paneInput = "grid input".encodeToByteArray()
            assertEquals(CoreCallResult.Accepted, runtime.sendTmuxPaneInput("%9", paneInput, receipt))
            val input = commands.takeWithin() as SharedBackendCommand.SendTmuxPaneInput
            assertEquals("%9", input.paneId)
            assertArrayEquals(paneInput, input.bytes)
            assertEquals(receipt, input.receipt)

            assertEquals(CoreCallResult.Accepted, runtime.sendTmuxPaneKey("%9", SharedTmuxPaneKey.ESCAPE))
            assertEquals(
                SharedBackendCommand.SendTmuxPaneKey("%9", SharedTmuxPaneKey.ESCAPE, null),
                commands.takeWithin(),
            )
            assertEquals(CoreCallResult.Accepted, runtime.cycleTmuxPane(forward = false))
            assertEquals(SharedBackendCommand.CycleTmuxPane(false), commands.takeWithin())
            assertEquals(
                CoreCallResult.Accepted,
                runtime.claimTmuxGridAuthority(SharedTmuxGridAuthorityReason.FORCE_REFRESH, true),
            )
            assertEquals(
                SharedBackendCommand.ClaimTmuxGridAuthority(SharedTmuxGridAuthorityReason.FORCE_REFRESH, true),
                commands.takeWithin(),
            )
            assertEquals(
                CoreCallResult.Accepted,
                runtime.reclaimTmuxGridAuthority(SharedTmuxGridAuthorityReason.USER),
            )
            assertEquals(
                SharedBackendCommand.ReclaimTmuxGridAuthority(SharedTmuxGridAuthorityReason.USER),
                commands.takeWithin(),
            )
            assertEquals(CoreCallResult.Accepted, runtime.completeTmuxGridAuthorityRepaint(42))
            assertEquals(SharedBackendCommand.CompleteTmuxGridAuthorityRepaint(42), commands.takeWithin())

            val authority = SharedTmuxGridAuthoritySnapshot.Peer("android-1", "Pixel", 42)
            assertEquals(CoreCallResult.Accepted, runtime.emitGridAuthorityChanged(authority))
            assertEquals(authority, (events.takeWithin() as SharedSessionEvent.GridAuthorityChanged).snapshot)
            assertEquals(CoreCallResult.Accepted, runtime.emitRemoteWorkingDirectoryChanged("/srv/work"))
            assertEquals(
                "/srv/work",
                (events.takeWithin() as SharedSessionEvent.RemoteWorkingDirectoryChanged).path,
            )
            val forwarding = listOf(SharedForwardingState(UUID.randomUUID(), "running"))
            assertEquals(CoreCallResult.Accepted, runtime.emitForwardingStateChanged(forwarding))
            assertEquals(
                forwarding,
                (events.takeWithin() as SharedSessionEvent.ForwardingStateChanged).states,
            )
            val completion = SharedSessionCommandCompletion(receipt, SharedSessionCommandResult.Succeeded)
            assertEquals(CoreCallResult.Accepted, runtime.emitCommandCompleted(completion))
            assertEquals(
                completion,
                (events.takeWithin() as SharedSessionEvent.CommandCompleted).completion,
            )

            val failedReceipt = SharedSessionCommandReceipt(UUID.randomUUID())
            assertEquals(
                CoreCallResult.Accepted,
                runtime.sendTmuxPaneKey("%9", SharedTmuxPaneKey.ENTER, failedReceipt),
            )
            assertEquals(
                SharedBackendCommand.SendTmuxPaneKey("%9", SharedTmuxPaneKey.ENTER, failedReceipt),
                commands.takeWithin(),
            )
            val failedCompletion = SharedSessionCommandCompletion(
                failedReceipt,
                SharedSessionCommandResult.Failed(
                    SharedSessionFailure("backend_denied", mapOf("reason" to "locked")),
                ),
            )
            assertEquals(CoreCallResult.Accepted, runtime.emitCommandCompleted(failedCompletion))
            assertEquals(
                failedCompletion,
                (events.takeWithin() as SharedSessionEvent.CommandCompleted).completion,
            )
        }
    }

    @Test
    fun callbacksAfterCloseAreInert() {
        val runtime = SharedSessionRuntime.create(object : SharedSessionListener {
            override fun onEvent(event: SharedSessionEvent) = Unit
        })
        runtime.close()

        assertEquals(CoreCallResult.StaleHandle, runtime.emitDiagnostics("late_callback"))
        assertEquals(CoreCallResult.StaleHandle, runtime.disconnect())
    }

    private fun <T> LinkedBlockingQueue<T>.takeWithin(): T =
        poll(10, TimeUnit.SECONDS) ?: error("timed out waiting for shared-core callback")

    private fun LinkedBlockingQueue<SharedSessionEvent>.stateWithin(): SharedSessionState {
        while (true) {
            when (val event = takeWithin()) {
                is SharedSessionEvent.StateChanged -> return event.state
                else -> Unit
            }
        }
    }
}
