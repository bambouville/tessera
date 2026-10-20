package com.bambouville.tessera.core.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The version 2 session and the show-edge tracker through JNI into the
 * shared core built for this machine: request encoding, the native
 * reduction and response decoding in one round trip each.
 */
class SharedTmuxAuthoritySessionNativeTest {
    @Test
    fun aShowOverAPeerClaimsAfterItsOwnRead() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            val attached = session.attached(nowMillis = 0, localDeviceId = "SELF")
            assertEquals(listOf(SharedTmuxAuthoritySessionEffect.QueryAuthority(1)), attached.effects)
            assertEquals(SharedTmuxAuthorityPresentation.None, attached.state.presentation)
            session.localSize(1, SharedTmuxGridSize(columns = 92, rows = 38))
            session.windowFacts(
                2, hydrated = true,
                activeWindow = SharedTmuxAuthorityActiveWindow(id = 0, size = SharedTmuxGridSize(105, 31), authoritative = true),
            )
            // A show never resolves on an older read: it issues its own.
            val shown = session.shown(nowMillis = 3)
            assertEquals(listOf(SharedTmuxAuthoritySessionEffect.QueryAuthority(2)), shown.effects)
            assertEquals(SharedTmuxAuthorityPresentation.Resuming(awaitingConnection = false), shown.state.presentation)

            val peer = SharedTmuxGridAuthoritySnapshot.Peer("PEER", "iPhone", 3)
            val replied = session.queryReplied(4, queryId = 2, rawValue = "v1 PEER 3 iPhone", localDeviceId = "SELF")
            assertEquals(
                listOf(
                    SharedTmuxAuthoritySessionEffect.AuthorityChanged(peer),
                    SharedTmuxAuthoritySessionEffect.BeginClaim(
                        generation = 1, reason = SharedTmuxAuthorityClaimReason.SHOW, presentationVisible = true,
                    ),
                ),
                replied.effects,
            )
            assertEquals(peer, replied.state.authority)
        }
    }

    @Test
    fun aClaimFenceConfirmsOverTheWireOnceTheWindowReachesItsTarget() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            session.attached(nowMillis = 0, localDeviceId = "SELF")
            session.localSize(1, SharedTmuxGridSize(columns = 92, rows = 38))
            session.windowFacts(
                2, hydrated = true,
                activeWindow = SharedTmuxAuthorityActiveWindow(id = 0, size = SharedTmuxGridSize(105, 31), authoritative = true),
            )
            session.shown(nowMillis = 3)
            val replied = session.queryReplied(4, queryId = 2, rawValue = "v1 PEER 3 iPhone", localDeviceId = "SELF")
            assertTrue(replied.effects.contains(
                SharedTmuxAuthoritySessionEffect.BeginClaim(
                    generation = 1, reason = SharedTmuxAuthorityClaimReason.SHOW, presentationVisible = true,
                ),
            ))
            session.claimAdvertisedGeometry(5, generation = 1, columns = 92, rows = 38)
            val sent = session.claimFenceSent(6, generation = 1, windowId = 0)
            val fence = checkNotNull(sent.state.claimFence)
            assertEquals(1L, fence.generation)
            assertEquals(0, fence.windowId)
            assertTrue(fence.id > 0)
            assertFalse(fence.acknowledged)
            assertNull(fence.policyIsLatest)
            assertFalse(fence.probeOffTarget)
            assertFalse(fence.forceOutstanding)

            val policy = session.windowSizePolicyReplied(7, windowId = 0, rawPolicy = "latest", fenceId = fence.id)
            assertTrue(policy.effects.isEmpty())
            assertEquals(true, policy.state.claimFence?.policyIsLatest)
            val acknowledged = session.claimFenceAcknowledged(8, fenceId = fence.id)
            assertTrue(acknowledged.effects.isEmpty())
            assertEquals(true, acknowledged.state.claimFence?.acknowledged)
            assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, acknowledged.state.claim?.phase)

            val layout = session.windowFacts(
                9, hydrated = true,
                activeWindow = SharedTmuxAuthorityActiveWindow(id = 0, size = SharedTmuxGridSize(92, 38), authoritative = true),
            )
            assertTrue(layout.effects.isEmpty())
            assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, layout.state.claim?.phase)
            val confirmed = session.confirmClaimFence(nowMillis = 10)
            assertEquals(listOf(SharedTmuxAuthoritySessionEffect.RequestRepaint(1)), confirmed.effects)
            assertEquals(SharedTmuxAuthorityClaimPhase.AWAITING_REPAINT, confirmed.state.claim?.phase)
        }
    }

    @Test
    fun rawStampBatchesClassifyOnceInOrderAndDedupeReplays() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            session.attached(0, "SELF")
            // Answer the attach read: an edge would otherwise supersede it.
            session.queryReplied(0, queryId = 1, rawValue = "", localDeviceId = "SELF")
            val result = session.stampsObserved(1, listOf("v1 PEER 7 iPad", "v1 PEER 8 iPad"))
            assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("PEER", "iPad", 8), result.state.authority)
            assertEquals(listOf(7L, 8L), result.effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.AuthorityChanged>()
                .map { (it.authority as SharedTmuxGridAuthoritySnapshot.Peer).generation })
            assertEquals(false, session.stampObserved(2, "  v1 PEER 8 iPad  ").changed)
            assertEquals(emptyList<SharedTmuxAuthoritySessionEffect>(), session.stampObserved(3, "v1 SELF 9 Pixel").effects)
            assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("PEER", "iPad", 8), session.state.authority)
        }
    }

    @Test
    fun aStampEdgeSupersedesTheOutstandingRead() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            session.attached(0, "SELF")
            val peer = SharedTmuxGridAuthoritySnapshot.Peer("PEER", "iPad", 7)
            // Android reduces this edge in the runtime callback, ahead of
            // the attach read's reply still queued for Main.
            assertEquals(
                listOf(SharedTmuxAuthoritySessionEffect.AuthorityChanged(peer), SharedTmuxAuthoritySessionEffect.QueryAuthority(2)),
                session.stampObserved(1, "v1 PEER 7 iPad").effects,
            )
            val stale = session.queryReplied(2, queryId = 1, rawValue = "", localDeviceId = "SELF")
            assertEquals(emptyList<SharedTmuxAuthoritySessionEffect>(), stale.effects)
            assertEquals(peer, stale.state.authority)
        }
    }

    @Test
    fun aBatchPastTheRequestBoundClassifiesEveryStampInOrder() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            session.attached(0, "SELF")
            val name = "N".repeat(64)
            val stamps = List(SharedTmuxAuthoritySession.MAXIMUM_STAMPS_PER_REQUEST * 3) { "v1 PEER ${it + 1} $name" }
            val result = session.stampsObserved(1, stamps)
            assertEquals((1L..stamps.size).toList(), result.effects
                .filterIsInstance<SharedTmuxAuthoritySessionEffect.AuthorityChanged>()
                .map { (it.authority as SharedTmuxGridAuthoritySnapshot.Peer).generation })
            assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("PEER", name, stamps.size.toLong()), result.state.authority)
        }
    }

    @Test
    fun aDisplayedSlotShowsAfterTheSettleAndHidesAfterTheDebounce() {
        SharedTmuxShowEdges.create().use { edges ->
            assertEquals(emptyList<SharedTmuxShowEdge>(), edges.displayed(true, nowMillis = 0))
            assertEquals(
                listOf(SharedTmuxShowEdge.Show(SharedTmuxAuthorityShowSource.SHOW, stepAtMillis = 350)),
                edges.tick(nowMillis = 350),
            )
            assertEquals(emptyList<SharedTmuxShowEdge>(), edges.displayed(false, nowMillis = 1_000))
            assertEquals(listOf(SharedTmuxShowEdge.Hide), edges.tick(nowMillis = 2_500))
        }
    }
}
