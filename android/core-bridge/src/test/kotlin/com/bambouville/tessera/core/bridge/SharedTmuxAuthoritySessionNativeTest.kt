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

    /**
     * §6.9: a relaunch hands back what an earlier process kept. Our stamp
     * still stands over a grid this device owned, so the read replays it with
     * no veil, and the record to keep next comes back merged.
     */
    @Test
    fun aRelaunchReplaysTheGridsItsStandingStampOwned() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            val owned = SharedTmuxGridSize(columns = 105, rows = 31)
            val local = SharedTmuxGridSize(columns = 92, rows = 38)
            val restored = session.restoreOwnedGeometry(
                0,
                listOf(
                    SharedTmuxOwnedGeometryRecord(generation = 3, sizes = listOf(owned)),
                    SharedTmuxOwnedGeometryRecord(generation = 4, sizes = listOf(SharedTmuxGridSize(columns = 0, rows = 24))),
                    SharedTmuxOwnedGeometryRecord(generation = 5, sizes = emptyList()),
                ),
            )
            assertEquals("event=restoreOwnedGeometry(g3) authority=unknown claim=none restored=0->1", restored.trace)
            assertNull(restored.state.ownedGeometryRecord)
            session.attached(1, localDeviceId = "SELF")
            session.adoptShown(2)
            session.localSize(3, local)
            session.windowFacts(
                4, hydrated = true,
                activeWindow = SharedTmuxAuthorityActiveWindow(id = 0, size = owned, authoritative = true),
            )
            session.windowSizePolicyReplied(5, windowId = 0, rawPolicy = "latest")
            val replied = session.queryReplied(6, queryId = 1, rawValue = "v1 SELF 3 Android-Tablet", localDeviceId = "SELF")
            assertEquals(
                listOf(
                    SharedTmuxAuthoritySessionEffect.AuthorityChanged(SharedTmuxGridAuthoritySnapshot.Mine(3)),
                    SharedTmuxAuthoritySessionEffect.ReleaseGeometry(SharedTmuxAuthorityGeometryRelease.OWNER_REPLAY),
                ),
                replied.effects,
            )
            assertEquals(SharedTmuxAuthorityPresentation.None, replied.state.presentation)
            assertEquals(SharedTmuxOwnedGeometryRecord(generation = 3, sizes = listOf(owned, local)), replied.state.ownedGeometryRecord)
            assertFalse("nothing pending, nothing restored: no change", session.restoreOwnedGeometry(7, emptyList()).changed)
        }
    }

    @Test
    fun aRelaunchWithoutARecordForTheStandingStampStillVeils() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            val owned = SharedTmuxGridSize(columns = 105, rows = 31)
            session.restoreOwnedGeometry(0, listOf(SharedTmuxOwnedGeometryRecord(generation = 2, sizes = listOf(owned))))
            session.attached(1, localDeviceId = "SELF")
            session.adoptShown(2)
            session.localSize(3, SharedTmuxGridSize(columns = 92, rows = 38))
            session.windowFacts(
                4, hydrated = true,
                activeWindow = SharedTmuxAuthorityActiveWindow(id = 0, size = owned, authoritative = true),
            )
            session.windowSizePolicyReplied(5, windowId = 0, rawPolicy = "latest")
            val replied = session.queryReplied(6, queryId = 1, rawValue = "v1 SELF 3 Android-Tablet", localDeviceId = "SELF")
            assertTrue(replied.effects.contains(SharedTmuxAuthoritySessionEffect.RaiseStamplessPeer))
            assertTrue(replied.state.presentation is SharedTmuxAuthorityPresentation.Veiled)
            assertNull(replied.state.ownedGeometryRecord)
        }
    }

    @Test
    fun keepingJoinsItsGenerationAndKeepsTheNewest() {
        val size = SharedTmuxGridSize(columns = 80, rows = 24)
        val other = SharedTmuxGridSize(columns = 92, rows = 38)
        var kept = emptyList<SharedTmuxOwnedGeometryRecord>()
        for (generation in 1L..(SharedTmuxOwnedGeometryRecord.RESTORE_LIMIT + 3L)) {
            kept = SharedTmuxOwnedGeometryRecord.keeping(SharedTmuxOwnedGeometryRecord(generation, listOf(size)), kept)
        }
        // Another window's record under the same stamp: its grids join, ranked newer.
        kept = SharedTmuxOwnedGeometryRecord.keeping(SharedTmuxOwnedGeometryRecord(generation = 10, sizes = listOf(other)), kept)
        assertEquals((SharedTmuxOwnedGeometryRecord.RESTORE_LIMIT + 3L downTo 4L).toList(), kept.map { it.generation })
        assertEquals(listOf(size, other), kept.single { it.generation == 10L }.sizes)
        kept = SharedTmuxOwnedGeometryRecord.keeping(SharedTmuxOwnedGeometryRecord(generation = 10, sizes = listOf(other, size)), kept)
        assertEquals("a repeat moves to newest", listOf(other, size), kept.single { it.generation == 10L }.sizes)
        // `TmuxOwnedSizeHistory.limit` grids stay, the newest.
        val full = (1..SharedTmuxOwnedGeometryRecord.SIZE_LIMIT).map { SharedTmuxGridSize(columns = 80 + it, rows = 24) }
        val grown = SharedTmuxOwnedGeometryRecord.keeping(
            SharedTmuxOwnedGeometryRecord(generation = 3, sizes = listOf(SharedTmuxGridSize(columns = 200, rows = 50))),
            listOf(SharedTmuxOwnedGeometryRecord(generation = 3, sizes = full)),
        )
        assertEquals(full.drop(1) + SharedTmuxGridSize(columns = 200, rows = 50), grown.single().sizes)
    }

    /** The Kotlin limits are the core's: a store at both limits restores whole, and an empty restore clears it. */
    @Test
    fun aRestoreAtBothLimitsIsCarriedAndAnEmptyOneClearsIt() {
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { session ->
            val limit = SharedTmuxOwnedGeometryRecord.RESTORE_LIMIT
            val records = (1L..limit.toLong()).map { generation ->
                SharedTmuxOwnedGeometryRecord(
                    generation,
                    (1..SharedTmuxOwnedGeometryRecord.SIZE_LIMIT).map { SharedTmuxGridSize(columns = 80 + it, rows = 24) },
                )
            }
            val restored = session.restoreOwnedGeometry(0, records)
            assertTrue(restored.changed)
            assertTrue(restored.trace, restored.trace!!.endsWith("restored=0->$limit"))
            val cleared = session.restoreOwnedGeometry(1, emptyList())
            assertTrue(cleared.trace, cleared.trace!!.endsWith("restored=$limit->0"))
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
