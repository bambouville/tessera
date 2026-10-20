package com.bambouville.tessera.core.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A runtime hosting the authority session (§6.17), through JNI into the
 * shared core built for this machine: a read's stamp is reduced inside its
 * feed and arrives as the session's result in the read's own event.
 */
class SharedTmuxRuntimeAuthoritySessionNativeTest {
    private fun stamp(raw: String, pane: Int = 1) =
        "%subscription-changed tessera-authority \$0 @1 0 %$pane : $raw\r\n".encodeToByteArray()

    private val mac = SharedTmuxGridAuthoritySnapshot.Peer("MAC", "Mac", 7)

    private fun lossNote(redelivered: Boolean) = SharedTmuxRenderEffect.Diagnostic(
        "${SharedTmuxEventDecoder.AUTHORITY_RESULT_DIAGNOSTIC} redelivered=$redelivered",
    )

    /** A runtime whose listener adopts results as the adapter does, failing the next [failures] that carry one. */
    private class AdoptingListener(private val session: SharedTmuxAuthoritySession) : (SharedTmuxEvent) -> Unit {
        val events = mutableListOf<SharedTmuxEvent>()
        var failures = 0

        override fun invoke(event: SharedTmuxEvent) {
            if (event.authoritySession != null && failures > 0) {
                failures -= 1
                throw IllegalStateException("the listener failed before adopting")
            }
            events += event
            event.authoritySession?.let(session::adopt)
        }
    }

    private fun attachedRuntime(session: SharedTmuxAuthoritySession, listener: AdoptingListener): SharedTmuxRuntime =
        SharedTmuxRuntime.create(listener).also { runtime ->
            session.attached(nowMillis = 0, localDeviceId = "SELF")
            assertEquals(CoreCallResult.Accepted, runtime.attachAuthoritySession(session))
            assertEquals(
                CoreCallResult.Accepted,
                runtime.feed("%session-changed \$0 work\r\n%window-add @1\r\n".encodeToByteArray(), 1),
            )
        }

    @Test
    fun aReadsStampArrivesAsTheSessionsResult() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            val listener = AdoptingListener(session)
            attachedRuntime(session, listener).use { runtime ->
                val events = listener.events
                val delivered = events.size
                val adoptions = session.adoptions
                assertEquals(CoreCallResult.Accepted, runtime.feed(stamp("v1 MAC 7 Mac"), 10))
                assertEquals("one event, adopted once", delivered + 1, events.size)
                assertEquals(adoptions + 1, session.adoptions)
                val event = events.last()
                assertTrue(event.authorityStamps.isEmpty())
                val result = checkNotNull(event.authoritySession)
                assertEquals(mac, result.state.authority)
                assertEquals(mac, event.snapshot.authority)
                val adopted = session.state
                assertEquals("the adopted result is the core's state", session.snapshot(10), adopted)

                // A repeat the session already holds costs nothing at all.
                assertEquals(CoreCallResult.Accepted, runtime.feed(stamp("v1 MAC 7 Mac", pane = 2), 20))
                assertNull(events.last().authoritySession)
                assertTrue(events.last().authorityStamps.isEmpty())

                // Detached, the edge is the adapter's again.
                assertEquals(CoreCallResult.Accepted, runtime.attachAuthoritySession(null))
                assertEquals(CoreCallResult.Accepted, runtime.feed(stamp("v1 PEER 8 iPad"), 30))
                assertEquals(listOf("v1 PEER 8 iPad"), events.last().authorityStamps)
                assertNull(events.last().authoritySession)
                assertFalse(events.flatMap { it.renderEffects }.any { it == lossNote(true) || it == lossNote(false) })
            }
        }
    }

    /**
     * The read's event never reached the session (its listener failed
     * first, as a dropped callback or an undecodable event would). The core
     * has moved on and a repeat of the stamp reduces nothing, so the feed
     * asks for the result again: the session adopts it late, effects and
     * all, rather than keep the gates of a verdict the core left behind.
     */
    @Test
    fun aResultTheSessionNeverAdoptedIsDeliveredAgain() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            val listener = AdoptingListener(session)
            attachedRuntime(session, listener).use { runtime ->
                listener.failures = 1
                val adopted = session.adoptions
                assertEquals(CoreCallResult.Accepted, runtime.feed(stamp("v1 MAC 7 Mac"), 10))

                assertEquals(adopted + 1, session.adoptions)
                assertEquals(mac, session.state.authority)
                val event = listener.events.last()
                assertTrue(checkNotNull(event.authoritySession).effects.isNotEmpty())
                assertEquals(mac, event.snapshot.authority)
                assertEquals(CoreCallResult.Accepted, runtime.feed("%window-renamed @1 x\r\n".encodeToByteArray(), 20))
                assertTrue(listener.events.last().renderEffects.contains(lossNote(true)))
            }
        }
    }

    /** Lost twice, the result stays lost; the feed still succeeds and the loss is recorded. */
    @Test
    fun aResultLostAgainIsRecorded() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            val listener = AdoptingListener(session)
            attachedRuntime(session, listener).use { runtime ->
                listener.failures = 2
                val adopted = session.adoptions
                assertEquals(CoreCallResult.Accepted, runtime.feed(stamp("v1 MAC 7 Mac"), 10))
                assertEquals(adopted, session.adoptions)
                assertEquals(CoreCallResult.Accepted, runtime.feed("%window-renamed @1 x\r\n".encodeToByteArray(), 20))
                assertTrue(listener.events.last().renderEffects.contains(lossNote(false)))
            }
        }
    }

    /**
     * A switch between known sessions is reduced at its step inside the
     * feed (§6.18), and the event says so: the adapter reduces neither the
     * switch nor its facts again, but resolves, hydrates and subscribes.
     */
    @Test
    fun aSwitchIsReducedInTheFeedAndNamedInTheEvent() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            val listener = AdoptingListener(session)
            attachedRuntime(session, listener).use { runtime ->
                assertEquals(CoreCallResult.Accepted, runtime.feed(stamp("v1 MAC 7 Mac"), 10))
                assertEquals(mac, session.state.authority)
                assertFalse(listener.events.last().controlSessionSwitched)
                assertTrue(listener.events.last().authorityReducedInFeed)

                assertEquals(CoreCallResult.Accepted, runtime.feed("%session-changed \$3 other\r\n".encodeToByteArray(), 20))

                val event = listener.events.last()
                assertTrue(event.controlSessionSwitched)
                assertTrue(event.authorityReducedInFeed)
                assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, session.state.authority)
                assertTrue("the new session's attach read", session.state.currentQueryId != null)

                // Output says nothing to the session.
                assertEquals(CoreCallResult.Accepted, runtime.feed("%output %1 hi\r\n".encodeToByteArray(), 30))
                assertFalse(listener.events.last().authorityReducedInFeed)
                assertFalse(listener.events.last().controlSessionSwitched)
            }
        }
    }

    @Test
    fun aClosedSessionIsRefusedAndAClosedAttachedOneIsNoLongerReduced() {
        val events = mutableListOf<SharedTmuxEvent>()
        SharedTmuxRuntime.create { events += it }.use { runtime ->
            val closed = SharedTmuxAuthoritySession.create(initialGeneration = 0).also { it.close() }
            assertEquals(CoreCallResult.InvalidArguments, runtime.attachAuthoritySession(closed))

            val session = SharedTmuxAuthoritySession.create(initialGeneration = 0)
            session.attached(nowMillis = 0, localDeviceId = "SELF")
            assertEquals(CoreCallResult.Accepted, runtime.attachAuthoritySession(session))
            assertEquals(CoreCallResult.Accepted, runtime.feed("%session-changed \$0 work\r\n".encodeToByteArray(), 1))
            session.close()
            assertEquals(CoreCallResult.Accepted, runtime.feed(stamp("v1 MAC 7 Mac"), 10))
            assertEquals(listOf("v1 MAC 7 Mac"), events.last().authorityStamps)
            assertNull(events.last().authoritySession)
        }
    }
}
