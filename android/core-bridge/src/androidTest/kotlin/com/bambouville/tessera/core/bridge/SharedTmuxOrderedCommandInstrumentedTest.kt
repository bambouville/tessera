package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Actual JNI admission/callback/parser coverage; no transport or painter acknowledgements. */
@RunWith(AndroidJUnit4::class)
class SharedTmuxOrderedCommandInstrumentedTest {
    @Test
    fun reentrantSideChannelSizeThenPolicyPreservesWireAndReplyOrder() {
        reentrantSizeThenPolicy(
            profile = SharedTmuxRenderProfile.SideChannel,
            ledgerCommands = listOf("refresh-client -C 100,30"),
            expectedPolicyTag = 2L,
        )
    }

    @Test
    fun reentrantInlineSizeFenceThenPolicyPreservesEveryIgnoredReply() {
        reentrantSizeThenPolicy(
            profile = SharedTmuxRenderProfile.Inline,
            ledgerCommands = listOf("refresh-client -C 100,30", "select-window"),
            expectedPolicyTag = 3L,
        )
    }

    @Test
    fun legacyAdmissionAndIgnoredLedgerRepliesRemainCompatible() {
        Probe().use { probe ->
            probe.attach(SharedTmuxRenderProfile.SideChannel)
            val eventCount = probe.events.size
            val legacy = "display-message -p 'legacy'"
            val legacyTag = acceptedTag(probe.runtime.sendCommand(legacy))
            assertEquals(1L, legacyTag)
            assertEquals("legacy admission must not deliver a wire callback", eventCount, probe.events.size)
            assertTrue(probe.writes.isEmpty())

            // The legacy caller still owns its physical write. The new API
            // delivers only its own command, while both APIs share reply FIFO.
            probe.writes += Wire(legacy, legacyTag)
            assertEquals(CoreCallResult.Accepted,
                probe.runtime.submitFact(SharedTmuxRenderFact.ClientSize(56, 48)))
            val policy = "show-options -wA -v -t @7 window-size"
            val policyTag = acceptedTag(probe.runtime.queueCommand(policy))
            assertEquals(3L, policyTag)
            assertEquals(listOf(legacy, "refresh-client -C 56,48", policy), probe.writes.map { it.command })
            assertEquals(listOf(Wire(policy, policyTag)), probe.platformWrites())

            probe.reply(1, listOf("legacy"))
            assertEquals(listOf(SharedTmuxRenderEffect.CommandReply(legacyTag, true, listOf("legacy"))),
                probe.replies())
            probe.reply(2, emptyList())
            assertEquals("fire-and-forget ledger replies must remain ignored", 1, probe.replies().size)
            probe.reply(3, listOf("largest"))
            assertEquals(listOf(
                SharedTmuxRenderEffect.CommandReply(legacyTag, true, listOf("legacy")),
                SharedTmuxRenderEffect.CommandReply(policyTag, true, listOf("largest")),
            ), probe.replies())
            assertEquals(1, probe.maximumCallbackDepth)
        }
    }

    @Test
    fun cancellingQueuedUnwrittenSuffixSuppressesWireAndDoesNotReuseTags() {
        Probe().use { probe ->
            val survivor = "show-options -wA -v -t @7 window-size"
            val cancelled = "display-message -p 'must-not-write'"
            val afterCancellation = "display-message -p 'after-cancellation'"
            var survivorTag = 0L
            var cancelledTag = 0L
            var finalTag = 0L
            probe.onNextEvent = {
                survivorTag = acceptedTag(probe.runtime.queueCommand(survivor))
                cancelledTag = acceptedTag(probe.runtime.queueCommand(cancelled))
                assertEquals(CoreCallResult.InvalidArguments,
                    probe.runtime.submitFact(SharedTmuxRenderFact.UnwrittenCommandsCancelled(listOf(survivorTag))))
                assertEquals(CoreCallResult.Accepted,
                    probe.runtime.submitFact(SharedTmuxRenderFact.UnwrittenCommandsCancelled(listOf(cancelledTag))))
                finalTag = acceptedTag(probe.runtime.queueCommand(afterCancellation))
                assertTrue("reentrant wire delivery must wait for this callback to return", probe.writes.isEmpty())
            }
            probe.triggerCallback()
            assertEquals(listOf(1L, 2L, 3L), listOf(survivorTag, cancelledTag, finalTag))
            assertEquals(listOf(Wire(survivor, survivorTag), Wire(afterCancellation, finalTag)), probe.writes)

            probe.reply(1, listOf("manual"))
            probe.reply(2, listOf("after-cancellation"))
            assertEquals(listOf(
                SharedTmuxRenderEffect.CommandReply(survivorTag, true, listOf("manual")),
                SharedTmuxRenderEffect.CommandReply(finalTag, true, listOf("after-cancellation")),
            ), probe.replies())
            assertEquals(1, probe.maximumCallbackDepth)
        }
    }

    @Test
    fun transportLossDropsOldQueuedWireAndReplyReservation() {
        Probe().use { probe ->
            val oldCommand = "display-message -p 'old-transport'"
            val replacement = "display-message -p 'replacement-transport'"
            var oldTag = 0L
            var replacementTag = 0L
            probe.onNextEvent = {
                oldTag = acceptedTag(probe.runtime.queueCommand(oldCommand))
                assertEquals(CoreCallResult.Accepted, probe.runtime.submitFact(SharedTmuxRenderFact.TransportLost))
                replacementTag = acceptedTag(probe.runtime.queueCommand(replacement))
                assertTrue(probe.writes.isEmpty())
            }
            probe.triggerCallback()
            assertEquals(1L, oldTag)
            assertEquals(2L, replacementTag)
            assertEquals(listOf(Wire(replacement, replacementTag)), probe.writes)

            probe.reply(1, listOf("replacement-transport"))
            assertEquals(listOf(SharedTmuxRenderEffect.CommandReply(
                replacementTag, true, listOf("replacement-transport"))), probe.replies())
            assertEquals(1, probe.maximumCallbackDepth)
        }
    }

    private fun reentrantSizeThenPolicy(
        profile: SharedTmuxRenderProfile,
        ledgerCommands: List<String>,
        expectedPolicyTag: Long,
    ) {
        Probe().use { probe ->
            probe.attach(profile)
            val policy = "show-options -wA -v -t @7 window-size"
            var policyTag = 0L
            probe.onNextEvent = {
                assertEquals(CoreCallResult.Accepted,
                    probe.runtime.submitFact(SharedTmuxRenderFact.ClientSize(100, 30)))
                policyTag = acceptedTag(probe.runtime.queueCommand(policy))
                assertEquals(expectedPolicyTag, policyTag)
                assertTrue("both reentrant callbacks must remain queued", probe.writes.isEmpty())
            }
            probe.triggerCallback()
            assertEquals(ledgerCommands + policy, probe.writes.map { it.command })
            assertEquals(listOf(Wire(policy, policyTag)), probe.platformWrites())
            assertEquals(1, probe.maximumCallbackDepth)
            val wireEvent = probe.events.single { it.platformWireCommands.isNotEmpty() }
            assertTrue("pure wire delivery must not repeat render effects", wireEvent.renderEffects.isEmpty())
            assertTrue(wireEvent.topologyQueries.isEmpty())
            assertTrue(wireEvent.bells.isEmpty())
            assertTrue(wireEvent.agentStates.isEmpty())

            // A server-origin frame must consume neither the resize's ignored
            // reservation nor the policy's platform reservation.
            probe.reply(90, listOf("hook-output"), client = false)
            assertTrue(probe.replies().isEmpty())
            ledgerCommands.indices.forEach { index ->
                probe.reply(index + 1, emptyList())
                assertTrue("ledger reply ${index + 1} leaked to platform", probe.replies().isEmpty())
            }
            probe.reply(ledgerCommands.size + 1, listOf("latest"))
            assertEquals(listOf(SharedTmuxRenderEffect.CommandReply(policyTag, true, listOf("latest"))),
                probe.replies())

            val following = "display-message -p 'following'"
            val followingTag = acceptedTag(probe.runtime.queueCommand(following))
            assertEquals(policyTag + 1, followingTag)
            assertEquals(Wire(following, followingTag), probe.writes.last())
            probe.reply(ledgerCommands.size + 2, listOf("following"), success = false)
            assertEquals(SharedTmuxRenderEffect.CommandReply(followingTag, false, listOf("following")),
                probe.replies().last())
            assertEquals(2, probe.replies().size)
        }
    }

    private fun acceptedTag(submission: SharedTmuxCommandSubmission): Long {
        assertTrue("command rejected: $submission", submission is SharedTmuxCommandSubmission.Accepted)
        return (submission as SharedTmuxCommandSubmission.Accepted).tag
    }

    private data class Wire(val command: String, val tag: Long?)

    private class Probe : AutoCloseable {
        val events = mutableListOf<SharedTmuxEvent>()
        val writes = mutableListOf<Wire>()
        var onNextEvent: (() -> Unit)? = null
        var maximumCallbackDepth = 0
            private set
        private var callbackDepth = 0
        private var callbackFailure: Throwable? = null
        val runtime = SharedTmuxRuntime.create { event ->
            callbackDepth += 1
            maximumCallbackDepth = maxOf(maximumCallbackDepth, callbackDepth)
            try {
                events += event
                event.renderEffects.filterIsInstance<SharedTmuxRenderEffect.SendCommand>().forEach {
                    writes += Wire(it.command, null)
                }
                event.platformWireCommands.forEach { writes += Wire(it.command, it.tag) }
                val action = onNextEvent
                onNextEvent = null
                action?.invoke()
            } catch (failure: Throwable) {
                // JNI clears exceptions at this borrowed Swift/C callback.
                // Retain the assertion and rethrow after the native call.
                if (callbackFailure == null) callbackFailure = failure
            } finally {
                callbackDepth -= 1
            }
        }

        fun attach(profile: SharedTmuxRenderProfile) {
            assertEquals(CoreCallResult.Accepted,
                runtime.submitFact(SharedTmuxRenderFact.TransportAttached(profile)))
            checkCallbackFailure()
            assertTrue(writes.isEmpty())
        }

        fun triggerCallback() {
            assertEquals(CoreCallResult.Accepted, runtime.submitFact(SharedTmuxRenderFact.AppForeground))
            checkCallbackFailure()
            assertEquals("callback was not delivered", null, onNextEvent)
        }

        fun platformWrites(): List<Wire> = events.flatMap { event ->
            event.platformWireCommands.map { Wire(it.command, it.tag) }
        }

        fun replies(): List<SharedTmuxRenderEffect.CommandReply> = events.flatMap { it.renderEffects }
            .filterIsInstance<SharedTmuxRenderEffect.CommandReply>()

        fun reply(sequence: Int, lines: List<String>, client: Boolean = true, success: Boolean = true) {
            val flags = if (client) 1 else 0
            val ending = if (success) "end" else "error"
            val wire = buildString {
                append("%begin $sequence 1 $flags\r\n")
                lines.forEach { append(it); append("\r\n") }
                append("%$ending $sequence 1 $flags\r\n")
            }
            assertEquals(CoreCallResult.Accepted, runtime.feed(wire.encodeToByteArray()))
            checkCallbackFailure()
        }

        private fun checkCallbackFailure() {
            callbackFailure?.let { throw it }
        }

        override fun close() = runtime.close()
    }
}
