package com.bambouville.tessera.core.bridge

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The version 2 lifecycle wire as Kotlin sees it. Responses are verbatim
 * captures of the core's encoder (`TmuxAuthoritySessionABITests` drives the
 * same sequences), plus fixtures pinning retained decoder fields; requests
 * are pinned to the field names the core decodes.
 */
class SharedTmuxAuthoritySessionTest {
    private fun parse(json: String): SharedTmuxAuthoritySessionResult =
        checkNotNull(SharedTmuxAuthoritySession.parse(JSONObject(json)))

    @Test
    fun freshSessionIsHiddenWithGeometryWithheld() {
        val result = parse(
            """{"presentation":{"kind":"none"},"effects":[],"channelLive":false,"authorityKind":"unknown","version":2,"nextGeneration":0,"geometryHold":"withheld","channelAttached":false,"gatesTyping":false,"hasAttached":false,"hidden":true}""",
        )
        val state = result.state
        assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, state.authority)
        assertTrue(state.hidden)
        assertEquals(SharedTmuxAuthorityGeometryHold.WITHHELD, state.geometryHold)
        assertEquals(SharedTmuxAuthorityPresentation.None, state.presentation)
        assertFalse(state.gatesTyping)
        assertFalse(state.channelLive)
        assertNull(state.mutationRefusal)
        assertNull(state.carriedShow)
        assertNull(state.nextDeadlineMillis)
        assertNull(state.currentQueryId)
        assertNull(state.claim)
        assertNull(result.trace)
        assertTrue(result.changed)
        assertTrue(result.effects.isEmpty())
    }

    @Test
    fun attachReadsWithATaggedQueryAndAnOverdueDeadline() {
        val result = parse(
            """{"geometryHold":"withheld","channelLive":true,"channelAttached":true,"gatesTyping":false,"hidden":true,"trace":"event=attached authority=unknown claim=none channel=live read=none->r1 effects=[queryAuthority(r1)]","version":2,"presentation":{"kind":"none"},"nextDeadlineMillis":5000,"currentQueryID":1,"hasAttached":true,"authorityKind":"unknown","effects":[{"queryID":1,"kind":"queryAuthority"}],"nextGeneration":0}""",
        )
        assertEquals(listOf(SharedTmuxAuthoritySessionEffect.QueryAuthority(1)), result.effects)
        assertEquals(5_000L, result.state.nextDeadlineMillis)
        assertEquals(1L, result.state.currentQueryId)
        assertTrue(result.state.channelLive)
        assertTrue(result.trace?.startsWith("event=attached ") == true)
    }

    @Test
    fun aShowReplacingADueRetryNamesOnlyItsOwnReadCurrent() {
        val result = parse(
            """{"trace":"event=shown(show) authority=unknown claim=none intent=none->i1:show hidden=true->false presentation=none->resuming read=none+retry1->r3 effects=[queryAuthority(r2),queryAuthority(r3)]","presentation":{"awaitingConnection":false,"kind":"resuming"},"geometryHold":"withheld","currentQueryID":3,"effects":[{"queryID":2,"kind":"queryAuthority"},{"queryID":3,"kind":"queryAuthority"}],"nextGeneration":0,"channelLive":true,"gatesTyping":true,"hidden":false,"channelAttached":true,"carriedShow":{"source":"show","stepAtMillis":350},"hasAttached":true,"claimMayAdvertiseGeometry":false,"pendingIntent":{"baselineKnown":false,"source":"show","token":1},"authorityKind":"unknown","version":2,"nextDeadlineMillis":5350}""",
        )
        assertEquals(
            listOf(SharedTmuxAuthoritySessionEffect.QueryAuthority(2), SharedTmuxAuthoritySessionEffect.QueryAuthority(3)),
            result.effects,
        )
        assertEquals(3L, result.state.currentQueryId)
    }

    @Test
    fun showClaimProjectsResumingOwnerGeometryAndTheCarriedStep() {
        val result = parse(
            """{"trace":"event=queryReplied(r2) authority=peer(MAC\/Mac#7) claim=none->g1:show\/awaitingFence vs MAC\/Mac#7 intent=i1:show->none hold=withheld->owner read=r2->none effects=[beginClaim(g1 show visible=true)]","hasAttached":true,"authorityDisplayName":"Mac","mutationRefusal":"yielded","gatesTyping":true,"channelAttached":true,"carriedShow":{"stepAtMillis":1000,"source":"show"},"authorityDeviceID":"MAC","claim":{"reason":"show","generation":1,"presentationVisible":true,"contestedPeer":{"displayName":"Mac","deviceID":"MAC","generation":7},"phase":"awaitingFence"},"version":2,"authorityKind":"peer","nextDeadlineMillis":4200,"nextGeneration":1,"geometryHold":"owner","effects":[{"reason":"show","generation":1,"kind":"beginClaim","presentationVisible":true}],"hidden":false,"authorityGeneration":7,"presentation":{"kind":"resuming","awaitingConnection":false},"channelLive":true}""",
        )
        val mac = SharedTmuxGridAuthoritySnapshot.Peer("MAC", "Mac", 7)
        assertEquals(
            listOf(SharedTmuxAuthoritySessionEffect.BeginClaim(1, SharedTmuxAuthorityClaimReason.SHOW, true)),
            result.effects,
        )
        val state = result.state
        assertEquals(mac, state.authority)
        assertEquals(
            SharedTmuxAuthorityLifecycleClaim(1, SharedTmuxAuthorityClaimReason.SHOW, SharedTmuxAuthorityClaimPhase.AWAITING_FENCE, true, mac),
            state.claim,
        )
        assertEquals(SharedTmuxAuthorityPresentation.Resuming(awaitingConnection = false), state.presentation)
        assertEquals(SharedTmuxAuthorityGeometryHold.OWNER, state.geometryHold)
        assertEquals(SharedTmuxAuthorityMutationRefusal.YIELDED, state.mutationRefusal)
        assertEquals(SharedTmuxAuthorityCarriedShow(SharedTmuxAuthorityShowSource.SHOW, 1_000), state.carriedShow)
        assertEquals(4_200L, state.nextDeadlineMillis)
        assertEquals(1L, state.nextGeneration)
    }

    @Test
    fun pendingShowIntentAndVeilPresentationsDecode() {
        val shown = parse(
            """{"hidden":false,"authorityKind":"peer","trace":"event=shown(show)","authorityDeviceID":"MAC","channelAttached":true,"hasAttached":true,"authorityDisplayName":"Mac","pendingIntent":{"baselineKnown":false,"token":1,"source":"show"},"presentation":{"awaitingConnection":false,"kind":"resuming"},"gatesTyping":true,"authorityGeneration":7,"geometryHold":"withheld","nextDeadlineMillis":6000,"effects":[{"queryID":2,"kind":"queryAuthority"}],"nextGeneration":0,"version":2,"mutationRefusal":"yielded","channelLive":true,"carriedShow":{"stepAtMillis":1000,"source":"show"}}""",
        )
        assertEquals(
            SharedTmuxAuthorityIntent(1, SharedTmuxAuthorityIntentSource.SHOW, null, false),
            shown.state.pendingIntent,
        )
        assertEquals(listOf(SharedTmuxAuthoritySessionEffect.QueryAuthority(2)), shown.effects)

        val veiled = parse(
            """{"geometryHold":"withheld","mutationRefusal":"yielded","nextGeneration":0,"presentation":{"kind":"veiled","peerName":"Mac"},"channelAttached":true,"channelLive":true,"hasAttached":true,"hidden":false,"authorityKind":"peer","gatesTyping":true,"authorityDeviceID":"MAC","authorityGeneration":7,"trace":"event=queryReplied(r1)","version":2,"authorityDisplayName":"Mac","effects":[{"authorityGeneration":7,"kind":"authorityChanged","authorityDeviceID":"MAC","authorityDisplayName":"Mac","authorityKind":"peer"}]}""",
        )
        assertEquals(SharedTmuxAuthorityPresentation.Veiled("Mac"), veiled.state.presentation)
        assertTrue(veiled.state.gatesTyping)
        assertEquals(
            listOf(SharedTmuxAuthoritySessionEffect.AuthorityChanged(SharedTmuxGridAuthoritySnapshot.Peer("MAC", "Mac", 7))),
            veiled.effects,
        )

        val reclaiming = parse(
            """{"claim":{"reason":"userTakeBack","phase":"awaitingFence","generation":2,"presentationVisible":true,"contestedPeer":{"displayName":"Mac","deviceID":"MAC","generation":7}},"authorityDisplayName":"Mac","channelAttached":true,"trace":"event=requestTakeBack","channelLive":true,"authorityDeviceID":"MAC","effects":[{"reason":"userTakeBack","generation":2,"kind":"beginClaim","presentationVisible":true}],"authorityKind":"peer","hidden":false,"hasAttached":true,"gatesTyping":true,"nextGeneration":2,"authorityGeneration":7,"presentation":{"kind":"reclaiming","awaitingConnection":false,"peerName":"Mac"},"mutationRefusal":"reclaiming","geometryHold":"owner","nextDeadlineMillis":5100,"version":2}""",
        )
        assertEquals(SharedTmuxAuthorityPresentation.Reclaiming("Mac", awaitingConnection = false), reclaiming.state.presentation)
        assertEquals(SharedTmuxAuthorityMutationRefusal.RECLAIMING, reclaiming.state.mutationRefusal)
    }

    @Test
    fun geometryReleaseAndTheStamplessPeerDecode() {
        val owner = parse(
            """{"channelAttached":true,"trace":"event=queryReplied(r1) authority=unknown->mine#3","channelLive":true,"effects":[{"authorityKind":"mine","kind":"authorityChanged","authorityGeneration":3},{"kind":"releaseGeometry","release":"advertise"}],"authorityKind":"mine","hidden":false,"hasAttached":true,"gatesTyping":false,"nextGeneration":0,"presentation":{"kind":"none"},"authorityGeneration":3,"geometryHold":"owner","version":2}""",
        )
        assertEquals(
            listOf(
                SharedTmuxAuthoritySessionEffect.AuthorityChanged(SharedTmuxGridAuthoritySnapshot.Mine(3)),
                SharedTmuxAuthoritySessionEffect.ReleaseGeometry(SharedTmuxAuthorityGeometryRelease.ADVERTISE),
            ),
            owner.effects,
        )
        assertEquals(SharedTmuxAuthorityGeometryHold.OWNER, owner.state.geometryHold)

        val stampless = parse(
            """{"authorityDisplayName":"another device","channelAttached":true,"trace":"event=windowFacts(hydrated @1 120x40)","channelLive":true,"authorityDeviceID":"-","effects":[{"authorityKind":"peer","kind":"authorityChanged","authorityDeviceID":"-","authorityGeneration":0,"authorityDisplayName":"another device"},{"kind":"raiseStamplessPeer"}],"authorityKind":"peer","hidden":false,"hasAttached":true,"gatesTyping":true,"nextGeneration":0,"presentation":{"kind":"veiled","peerName":"another device"},"authorityGeneration":0,"mutationRefusal":"yielded","geometryHold":"withheld","version":2}""",
        )
        assertEquals(
            listOf(
                SharedTmuxAuthoritySessionEffect.AuthorityChanged(SharedTmuxGridAuthoritySnapshot.Peer("-", "another device", 0)),
                SharedTmuxAuthoritySessionEffect.RaiseStamplessPeer,
            ),
            stampless.effects,
        )
        assertEquals(SharedTmuxAuthorityPresentation.Veiled("another device"), stampless.state.presentation)
    }

    @Test
    fun anAbortedClaimKeepsTheParkedShowCarried() {
        val result = parse(
            """{"carriedShow":{"stepAtMillis":1000,"source":"show"},"authorityDisplayName":"Mac","channelAttached":true,"trace":"event=abortClaim(g1 adapterFailure)","channelLive":true,"authorityDeviceID":"MAC","effects":[{"kind":"hideReclaimPresentation"},{"reason":"adapterFailure","kind":"claimAborted"}],"authorityKind":"peer","hidden":false,"hasAttached":true,"gatesTyping":true,"presentation":{"kind":"veiled","peerName":"Mac"},"nextGeneration":1,"authorityGeneration":7,"mutationRefusal":"yielded","geometryHold":"withheld","version":2}""",
        )
        assertEquals(
            listOf(
                SharedTmuxAuthoritySessionEffect.HideReclaimPresentation,
                SharedTmuxAuthoritySessionEffect.ClaimAborted("adapterFailure", null),
            ),
            result.effects,
        )
        assertEquals(SharedTmuxAuthorityCarriedShow(SharedTmuxAuthorityShowSource.SHOW, 1_000), result.state.carriedShow)
        assertNull(result.state.claim)
    }

    @Test
    fun theRemainingEffectsDecode() {
        val effects = JSONObject(
            """
            {"version":2,"authorityKind":"unknown","hasAttached":true,"channelAttached":true,"channelLive":false,
             "nextGeneration":4,"hidden":false,"presentation":{"kind":"resuming","awaitingConnection":true},
             "gatesTyping":false,"geometryHold":"withheld","effects":[
               {"kind":"requestRepaint","generation":4},
               {"kind":"commitAuthorityStamp","generation":4},
               {"kind":"claimSettled","generation":4},
               {"kind":"claimAborted","reason":"contestedByPeer","authorityKind":"peer","authorityDeviceID":"LAP","authorityDisplayName":"Laptop","authorityGeneration":2},
               {"kind":"releaseGeometry","release":"ownerReplay"},
               {"kind":"releaseGeometry","release":"none"},
               {"kind":"controlChannelUnresponsive"}
             ]}
            """.trimIndent(),
        )
        val result = checkNotNull(SharedTmuxAuthoritySession.parse(effects))
        assertEquals(
            listOf(
                SharedTmuxAuthoritySessionEffect.RequestRepaint(4),
                SharedTmuxAuthoritySessionEffect.CommitAuthorityStamp(4),
                SharedTmuxAuthoritySessionEffect.ClaimSettled(4),
                SharedTmuxAuthoritySessionEffect.ClaimAborted(
                    "contestedByPeer",
                    SharedTmuxGridAuthoritySnapshot.Peer("LAP", "Laptop", 2),
                ),
                SharedTmuxAuthoritySessionEffect.ReleaseGeometry(SharedTmuxAuthorityGeometryRelease.OWNER_REPLAY),
                SharedTmuxAuthoritySessionEffect.ReleaseGeometry(SharedTmuxAuthorityGeometryRelease.NONE),
                SharedTmuxAuthoritySessionEffect.ControlChannelUnresponsive,
            ),
            result.effects,
        )
        assertEquals(SharedTmuxAuthorityPresentation.Resuming(awaitingConnection = true), result.state.presentation)
        assertNull(result.trace)
    }

    @Test
    fun theUnchangedReplyParsesAsNoChangeAndOtherVersionsAreRefused() {
        assertNull(SharedTmuxAuthoritySession.parse(JSONObject("""{"version":2,"unchanged":true}""")))
        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxAuthoritySession.parse(JSONObject("""{"version":1,"unchanged":true}"""))
        }
        assertThrows(IllegalStateException::class.java) {
            SharedTmuxAuthoritySession.parse(
                JSONObject(
                    """{"version":2,"authorityKind":"unknown","hasAttached":false,"channelAttached":false,"channelLive":false,"nextGeneration":0,"hidden":true,"presentation":{"kind":"none"},"gatesTyping":false,"geometryHold":"withheld","effects":[{"kind":"replayOwnedGeometry"}]}""",
                ),
            )
        }
    }

    @Test
    fun requestsCarryVersionTwoTheClockAndTheCoreFieldNames() {
        val requests = SharedTmuxAuthoritySession.Requests
        fun assertRequest(expected: String, request: JSONObject?) {
            val actual = checkNotNull(request) { "dropped $expected" }
            val wanted = JSONObject(expected)
            assertEquals(wanted.keyNames(), actual.keyNames())
            for (key in wanted.keyNames()) assertEquals(key, wanted.get(key).toString(), actual.get(key).toString())
        }
        assertRequest("""{"version":2,"event":"tick","nowMillis":9}""", requests.bare("tick", 9))
        assertRequest(
            """{"version":2,"event":"attached","nowMillis":1,"localDeviceID":"SELF"}""",
            requests.attached(1, "SELF"),
        )
        assertRequest("""{"version":2,"event":"attached","nowMillis":1}""", requests.attached(1, null))
        assertRequest(
            """{"version":2,"event":"shown","nowMillis":5000,"source":"explicitOpen","stepAtMillis":4000}""",
            requests.shown(5_000, SharedTmuxAuthorityShowSource.EXPLICIT_OPEN, 4_000),
        )
        assertRequest(
            """{"version":2,"event":"prompt","nowMillis":2,"scope":"connect","active":true}""",
            requests.prompt(2, SharedTmuxAuthorityPromptScope.CONNECT, true),
        )
        assertRequest(
            """{"version":2,"event":"queryReplied","nowMillis":3,"queryID":7,"rawAuthorityValue":"v1 MAC 7 Mac"}""",
            requests.queryReplied(3, 7, "v1 MAC 7 Mac", null),
        )
        assertRequest(
            """{"version":2,"event":"queryReplied","nowMillis":3,"queryID":7,"rawAuthorityValue":"v1 phone 3 Pixel","localDeviceID":"phone"}""",
            requests.queryReplied(3, 7, "v1 phone 3 Pixel", "phone"),
        )
        assertRequest("""{"version":2,"event":"queryFailed","nowMillis":3,"queryID":7}""", requests.queryFailed(3, 7))
        assertRequest(
            """{"version":2,"event":"windowFacts","nowMillis":4,"windowListHydrated":true,"windowID":3,"windowAuthoritative":false,"windowColumns":120,"windowRows":40}""",
            requests.windowFacts(4, true, SharedTmuxAuthorityActiveWindow(3, SharedTmuxGridSize(120, 40), authoritative = false)),
        )
        assertRequest(
            """{"version":2,"event":"windowFacts","nowMillis":4,"windowListHydrated":false,"windowID":3,"windowAuthoritative":true}""",
            requests.windowFacts(4, false, SharedTmuxAuthorityActiveWindow(3, null, authoritative = true)),
        )
        assertRequest(
            """{"version":2,"event":"windowFacts","nowMillis":4,"windowListHydrated":true}""",
            requests.windowFacts(4, true, null),
        )
        assertRequest(
            """{"version":2,"event":"localSize","nowMillis":5,"columns":92,"rows":38}""",
            requests.localSize(5, SharedTmuxGridSize(92, 38)),
        )
        assertRequest("""{"version":2,"event":"localSize","nowMillis":5}""", requests.localSize(5, null))
        assertRequest(
            """{"version":2,"event":"sizeAdvertised","nowMillis":5,"columns":92,"rows":38}""",
            requests.sizeAdvertised(5, SharedTmuxGridSize(92, 38)),
        )
        assertRequest(
            """{"version":2,"event":"windowSizePolicyReplied","nowMillis":6,"windowID":3,"rawPolicy":"latest"}""",
            requests.windowSizePolicyReplied(6, 3, "latest"),
        )
        assertRequest(
            """{"version":2,"event":"windowSizePolicyReplied","nowMillis":6,"windowID":3,"rawPolicy":"latest"}""",
            requests.windowSizePolicyReplied(6, 3, "latest", fenceId = null),
        )
        assertRequest(
            """{"version":2,"event":"windowSizePolicyReplied","nowMillis":6,"windowID":3,"rawPolicy":"latest","fenceID":8}""",
            requests.windowSizePolicyReplied(6, 3, "latest", fenceId = 8),
        )
        assertRequest(
            """{"version":2,"event":"claimFenceSent","nowMillis":6,"generation":4,"windowID":3}""",
            requests.claimFenceSent(6, 4, 3),
        )
        assertRequest(
            """{"version":2,"event":"claimFenceAcknowledged","nowMillis":6,"fenceID":8}""",
            requests.claimFenceAcknowledged(6, 8),
        )
        assertRequest(
            """{"version":2,"event":"claimFenceForce","nowMillis":6,"fenceID":8,"outstanding":true}""",
            requests.claimFenceForce(6, 8, outstanding = true),
        )
        assertRequest(
            """{"version":2,"event":"claimFenceForce","nowMillis":6,"fenceID":8,"outstanding":false}""",
            requests.claimFenceForce(6, 8, outstanding = false),
        )
        assertRequest("""{"version":2,"event":"confirmClaimFence","nowMillis":6}""", requests.confirmClaimFence(6))
        assertRequest(
            """{"version":2,"event":"ordinaryRecovery","nowMillis":7,"active":false,"proven":true}""",
            requests.ordinaryRecovery(7, active = false, proven = true),
        )
        assertRequest(
            """{"version":2,"event":"paintable","nowMillis":8,"paintable":true}""",
            requests.paintable(8, true),
        )
        assertRequest(
            """{"version":2,"event":"channelLiveness","nowMillis":8,"channelLive":false}""",
            requests.channelLiveness(8, false),
        )
        assertRequest(
            """{"version":2,"event":"controlSessionChanged","nowMillis":8,"replacedKnownSession":true}""",
            requests.controlSessionChanged(8, true),
        )
        assertRequest(
            """{"version":2,"event":"resetTransport","nowMillis":8,"preservingPeer":true}""",
            requests.resetTransport(8, true),
        )
        assertRequest(
            """{"version":2,"event":"abort","nowMillis":9,"generation":4,"reason":"superseded"}""",
            requests.abort(9, 4, SharedTmuxAuthorityAbortReason.SUPERSEDED),
        )
        assertRequest(
            """{"version":2,"event":"settle","nowMillis":9,"generation":4}""",
            requests.generation("settle", 9, 4),
        )
        assertRequest(
            """{"version":2,"event":"observedAuthority","nowMillis":9,"authorityKind":"peer","authorityDeviceID":"MAC","authorityDisplayName":"Mac","authorityGeneration":7}""",
            requests.observedAuthority(9, SharedTmuxGridAuthoritySnapshot.Peer("MAC", "Mac", 7)),
        )
    }

    @Test
    fun subscriptionRequestsPreserveRawValuesAndBatchThemInOneSubmission() {
        val requests = mutableListOf<JSONObject>()
        val initial = checkNotNull(SharedTmuxAuthoritySession.parse(JSONObject(FRESH))).state
        val session = SharedTmuxAuthoritySession(1L, initial, reduceRequest = { _, request ->
            requests += request; UNCHANGED
        })
        session.stampObserved(1, "  v1 SELF 3 Pixel  ")
        assertEquals("stampObserved", requests.single().getString("event"))
        assertEquals("  v1 SELF 3 Pixel  ", requests.single().getString("raw"))
        session.stampsObserved(2, listOf("v1 PEER 7 iPad", "v1 PEER 8 iPad"))
        assertEquals(2, requests.size)
        assertEquals(listOf("v1 PEER 7 iPad", "v1 PEER 8 iPad"),
            requests.last().getJSONArray("rawValues").let { array -> List(array.length()) { array.getString(it) } })
        session.stampsObserved(3, emptyList()); assertEquals(2, requests.size)
    }

    @Test
    fun aBatchPastTheRequestBoundIsReducedInOrderPartByPart() {
        val requests = mutableListOf<JSONObject>()
        val initial = checkNotNull(SharedTmuxAuthoritySession.parse(JSONObject(FRESH))).state
        val session = SharedTmuxAuthoritySession(1L, initial, reduceRequest = { _, request ->
            requests += request; UNCHANGED
        })
        val stamps = List(SharedTmuxAuthoritySession.MAXIMUM_STAMPS_PER_REQUEST * 2 + 1) { "v1 PEER $it iPad" }
        assertFalse(session.stampsObserved(4, stamps).changed)
        assertEquals(3, requests.size)
        assertEquals(stamps, requests.flatMap { request ->
            request.optJSONArray("rawValues")?.let { array -> List(array.length()) { array.getString(it) } }
                ?: listOf(request.getString("raw"))
        })
        // The runtime bounds a value to 216 bytes (`maximumWireBytes`); a control byte
        // escapes to six, the worst case for a full request.
        val worst = SharedTmuxAuthoritySession.Requests.stampsObserved(
            Long.MAX_VALUE, List(SharedTmuxAuthoritySession.MAXIMUM_STAMPS_PER_REQUEST) { "\u0001".repeat(216) },
        )
        assertTrue(worst.toString().encodeToByteArray().size < 64 * 1024)
    }

    @Test
    fun requestsDropTheSizesTheWireRejects() {
        val requests = SharedTmuxAuthoritySession.Requests
        assertNull(requests.localSize(5, SharedTmuxGridSize(0, 38)))
        assertNull(requests.localSize(5, SharedTmuxGridSize(92, -1)))
        assertNull(requests.sizeAdvertised(5, SharedTmuxGridSize(0, 0)))
        val facts = requests.windowFacts(4, true, SharedTmuxAuthorityActiveWindow(3, SharedTmuxGridSize(0, 40), authoritative = true))
        assertEquals(
            setOf("version", "event", "nowMillis", "windowListHydrated", "windowID", "windowAuthoritative"),
            facts.keyNames(),
        )
    }

    @Test
    fun aNonPositiveSizeIsANoOpThatNeverCrossesTheWireOrThrows() {
        val sent = mutableListOf<String>()
        val warnings = mutableListOf<String>()
        val session = SharedTmuxAuthoritySession(
            1L,
            parse(FRESH).state,
            reduceRequest = { _, request ->
                sent += request.getString("event")
                UNCHANGED
            },
            warn = { warnings += it },
        )
        val dropped = session.localSize(5, SharedTmuxGridSize(0, 38))
        assertFalse(dropped.changed)
        assertEquals(parse(FRESH).state, dropped.state)
        assertFalse(session.sizeAdvertised(6, SharedTmuxGridSize(92, 0)).changed)
        session.windowFacts(7, true, SharedTmuxAuthorityActiveWindow(3, SharedTmuxGridSize(-1, 40), authoritative = true))
        assertEquals(listOf("windowFacts"), sent)
        assertEquals("logged once", 1, warnings.size)
        session.localSize(8, SharedTmuxGridSize(92, 38))
        session.localSize(9, null)
        assertEquals(listOf("windowFacts", "localSize", "localSize"), sent)
    }

    @Test
    fun aReplyTheCoreRejectsIsReportedAsAFailedRead() {
        val sent = mutableListOf<JSONObject>()
        val warnings = mutableListOf<String>()
        val session = SharedTmuxAuthoritySession(
            1L,
            parse(FRESH).state,
            reduceRequest = { _, request ->
                sent += request
                when (request.getString("event")) {
                    "queryFailed" -> RETRYING.encodeToByteArray()
                    else -> null
                }
            },
            warn = { warnings += it },
        )
        val result = session.queryReplied(300, 2, "v1 MAC 7 " + "N".repeat(70_000))
        assertEquals(listOf("queryReplied", "queryFailed"), sent.map { it.getString("event") })
        assertEquals(2L, sent[1].getLong("queryID"))
        assertEquals(300L, sent[1].getLong("nowMillis"))
        assertEquals(550L, result.state.nextDeadlineMillis)
        assertEquals(1, warnings.size)
        assertFalse("never the stamp itself", warnings.single().contains("MAC"))
        // Every other rejection is still an adapter bug.
        assertThrows(IllegalStateException::class.java) { session.tick(400) }
    }

    @Test
    fun aPeerIdPastTheStampBoundIsIgnoredWithoutCrossingOrThrowing() {
        val warnings = mutableListOf<String>()
        val sent = mutableListOf<JSONObject>()
        val session = SharedTmuxAuthoritySession(
            1L,
            parse(FRESH).state,
            reduceRequest = { _, request -> sent += request; UNCHANGED },
            warn = { warnings += it },
        )
        val id = "D".repeat(17_000)
        val ignored = session.observedAuthority(200, SharedTmuxGridAuthoritySnapshot.Peer(id, "Mac", 7))
        assertFalse(ignored.changed)
        assertEquals(parse(FRESH).state, ignored.state)
        session.observedAuthority(300, SharedTmuxGridAuthoritySnapshot.Peer("D".repeat(129), "Mac", 7))
        assertEquals("the parser would refuse it: nothing crosses", emptyList<JSONObject>(), sent)
        assertEquals("logged once", 1, warnings.size)
        assertFalse("never the identity itself", warnings.single().contains("DDDD"))
        session.observedAuthority(400, SharedTmuxGridAuthoritySnapshot.Peer("D".repeat(128), "Mac", 7))
        assertEquals("D".repeat(128), sent.single().getString("authorityDeviceID"))
    }

    @Test
    fun aLongPeerNameIsCutAsTheParserCutsIt() {
        val sent = mutableListOf<JSONObject>()
        val session = SharedTmuxAuthoritySession(
            1L,
            parse(FRESH).state,
            reduceRequest = { _, request -> sent += request; UNCHANGED },
            warn = { throw AssertionError("a long name is not a rejection: $it") },
        )
        session.observedAuthority(200, SharedTmuxGridAuthoritySnapshot.Peer("MAC", "N".repeat(65), 7))
        session.observedAuthority(300, SharedTmuxGridAuthoritySnapshot.Peer("MAC", "N".repeat(63) + "\uD83D\uDE00", 7))
        session.observedAuthority(400, SharedTmuxGridAuthoritySnapshot.Peer("MAC", "Mac", 7))
        assertEquals(
            listOf("N".repeat(64), "N".repeat(63), "Mac"),
            sent.map { it.getString("authorityDisplayName") },
        )
        assertEquals(listOf("MAC", "MAC", "MAC"), sent.map { it.getString("authorityDeviceID") })
    }

    @Test
    fun anObservationTheCoreRejectsForAnyOtherReasonStillThrows() {
        val warnings = mutableListOf<String>()
        val sent = mutableListOf<JSONObject>()
        val session = SharedTmuxAuthoritySession(
            1L,
            parse(FRESH).state,
            reduceRequest = { _, request -> sent += request; null },
            warn = { warnings += it },
        )
        // The core rejects these exactly as it rejected an over-bound ID:
        // an adapter bug, which must not be swallowed with it.
        assertThrows(IllegalStateException::class.java) {
            session.observedAuthority(-1, SharedTmuxGridAuthoritySnapshot.Mine(7))
        }
        assertThrows(IllegalStateException::class.java) {
            session.observedAuthority(100, SharedTmuxGridAuthoritySnapshot.Peer("MAC", "Mac", -1))
        }
        assertEquals(2, sent.size)
        assertEquals(emptyList<String>(), warnings)
    }

    @Test
    fun claimGridFieldsPredicateAndRefenceDecode() {
        val wire = JSONObject(FRESH).put("claimMayAdvertiseGeometry", false).put(
            "claim", JSONObject(
                """{"generation":7,"reason":"show","phase":"awaitingFence","presentationVisible":true,
                   "geometryRefenced":true,"geometryLanded":true,
                   "targetGrid":{"columns":92,"rows":38},
                   "advertisedGrids":[{"columns":92,"rows":38},{"columns":100,"rows":40}]}""",
            ),
        ).put("effects", org.json.JSONArray("""[{"kind":"refenceClaim","generation":7},{"kind":"claimAborted","reason":"geometryLost"}]"""))
        val result = checkNotNull(SharedTmuxAuthoritySession.parse(wire))
        assertFalse("the explicit predicate wins", result.state.claimMayAdvertiseGeometry)
        val claim = checkNotNull(result.state.claim)
        assertNull(claim.contestedPeer)
        assertTrue(claim.geometryRefenced)
        assertTrue(claim.geometryLanded)
        assertEquals(SharedTmuxGridSize(92, 38), claim.targetGrid)
        assertEquals(listOf(SharedTmuxGridSize(92, 38), SharedTmuxGridSize(100, 40)), claim.advertisedGrids)
        assertEquals(
            listOf(SharedTmuxAuthoritySessionEffect.RefenceClaim(7), SharedTmuxAuthoritySessionEffect.ClaimAborted("geometryLost", null)),
            result.effects,
        )
        wire.remove("claimMayAdvertiseGeometry")
        assertTrue(checkNotNull(SharedTmuxAuthoritySession.parse(wire)).state.claimMayAdvertiseGeometry)
        wire.getJSONObject("claim").put("presentationVisible", false)
        assertFalse(checkNotNull(SharedTmuxAuthoritySession.parse(wire)).state.claimMayAdvertiseGeometry)
        for (field in listOf("geometryRefenced", "geometryLanded", "targetGrid", "advertisedGrids")) {
            wire.getJSONObject("claim").remove(field)
        }
        val legacy = checkNotNull(SharedTmuxAuthoritySession.parse(wire)).state.claim!!
        assertFalse(legacy.geometryRefenced)
        assertFalse(legacy.geometryLanded)
        assertNull(legacy.targetGrid)
        assertTrue(legacy.advertisedGrids.isEmpty())
    }

    @Test
    fun claimFenceDecodesItsProofAndOptionalPolicy() {
        val fence = JSONObject(
            """{"generation":7,"id":9,"windowID":3,"acknowledged":true,"probeOffTarget":true,"forceOutstanding":false}""",
        )
        val wire = JSONObject(FRESH).put("claimFence", fence)
        val expected = SharedTmuxAuthorityClaimFence(
            generation = 7, id = 9, windowId = 3, acknowledged = true,
            policyIsLatest = null, probeOffTarget = true, forceOutstanding = false,
        )
        assertEquals(expected, checkNotNull(SharedTmuxAuthoritySession.parse(wire)).state.claimFence)
        fence.put("policyIsLatest", JSONObject.NULL)
        assertEquals(expected, checkNotNull(SharedTmuxAuthoritySession.parse(wire)).state.claimFence)
        for (latest in listOf(true, false)) {
            fence.put("policyIsLatest", latest)
            assertEquals(expected.copy(policyIsLatest = latest), checkNotNull(SharedTmuxAuthoritySession.parse(wire)).state.claimFence)
        }
        wire.remove("claimFence")
        assertNull(checkNotNull(SharedTmuxAuthoritySession.parse(wire)).state.claimFence)
    }

    @Test
    fun claimEventsCarryTheV1NamesAndFieldsWithTheV2Clock() {
        val sent = mutableListOf<JSONObject>()
        val session = SharedTmuxAuthoritySession(
            1L, parse(FRESH).state,
            reduceRequest = { _, request -> sent += request; UNCHANGED },
            warn = { throw AssertionError(it) },
        )
        session.claimAdvertisedGeometry(10, 7, 92, 38)
        session.claimObservedGeometry(11, 7, 130, 50, settleProbe = true)
        session.claimGeometryLost(12, 7)
        session.claimStalled(13, 7, canProgress = false)
        val expected = listOf(
            """{"version":2,"event":"claimAdvertisedGeometry","nowMillis":10,"generation":7,"columns":92,"rows":38}""",
            """{"version":2,"event":"claimObservedGeometry","nowMillis":11,"generation":7,"columns":130,"rows":50,"settleProbe":true}""",
            """{"version":2,"event":"claimGeometryLost","nowMillis":12,"generation":7}""",
            """{"version":2,"event":"claimStalled","nowMillis":13,"generation":7,"canProgress":false}""",
        )
        assertEquals(4, sent.size)
        expected.zip(sent).forEach { (json, actual) ->
            val wanted = JSONObject(json)
            assertEquals(wanted.keyNames(), actual.keyNames())
            wanted.keyNames().forEach { key -> assertEquals(wanted.get(key).toString(), actual.get(key).toString()) }
        }
        val observed = checkNotNull(SharedTmuxAuthoritySession.Requests.claimObservedGeometry(14, 7, 92, 38, false))
        assertFalse(observed.getBoolean("settleProbe"))
        assertTrue(SharedTmuxAuthoritySession.Requests.claimStalled(15, 7, true).getBoolean("canProgress"))
    }

    @Test
    fun invalidClaimGeometryNeverCrossesJniAndWarnsOnce() {
        val sent = mutableListOf<JSONObject>()
        val warnings = mutableListOf<String>()
        val session = SharedTmuxAuthoritySession(
            1L, parse(FRESH).state,
            reduceRequest = { _, request -> sent += request; UNCHANGED },
            warn = { warnings += it },
        )
        assertFalse(session.claimAdvertisedGeometry(10, 7, 0, 38).changed)
        assertFalse(session.claimObservedGeometry(11, 7, 92, -1, false).changed)
        assertTrue(sent.isEmpty())
        assertEquals(1, warnings.size)
        assertNull(SharedTmuxAuthoritySession.Requests.claimAdvertisedGeometry(10, 7, 92, 0))
        assertNull(SharedTmuxAuthoritySession.Requests.claimObservedGeometry(11, 7, -1, 38, true))
    }

    @Test
    fun unchangedReplyRetainsClaimGeometryAndTheLatePredicate() {
        val wire = JSONObject(FRESH).put("claimMayAdvertiseGeometry", false).put(
            "claim", JSONObject("""{"generation":7,"reason":"show","phase":"awaitingFence","presentationVisible":false,
                "targetGrid":{"columns":92,"rows":38},"advertisedGrids":[{"columns":92,"rows":38}],
                "geometryLanded":true,"geometryRefenced":true}"""),
        )
        val initial = checkNotNull(SharedTmuxAuthoritySession.parse(wire)).state
        val session = SharedTmuxAuthoritySession(1L, initial, reduceRequest = { _, _ -> UNCHANGED })
        val result = session.claimAdvertisedGeometry(5_000, 7, 130, 50)
        assertFalse(result.changed)
        assertEquals(initial, result.state)
        assertFalse(result.state.claimMayAdvertiseGeometry)
        assertEquals(SharedTmuxGridSize(92, 38), result.state.claim?.targetGrid)
        assertTrue(result.effects.isEmpty())
    }

    // Ports of decoder properties absent from the original v2 tests.

    @Test
    fun foregroundQueryDecodesWithoutMutatingSettledAuthority() {
        val result = checkNotNull(SharedTmuxAuthoritySession.parse(JSONObject("""
            {
              "version": 2,
              "channelLive": true,
              "hidden": false,
              "presentation": { "kind": "none" },
              "gatesTyping": false,
              "geometryHold": "withheld",
              "authorityKind": "mine",
              "authorityGeneration": 4,
              "hasAttached": true,
              "channelAttached": true,
              "nextGeneration": 4,
              "effects": [ { "kind": "queryAuthority", "queryID": 4 } ],
              "trace": "event=foregrounded authority=mine#4 claim=none effects=[queryAuthority]"
            }
        """.trimIndent())))

        assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(4), result.state.authority)
        assertEquals(listOf(SharedTmuxAuthoritySessionEffect.QueryAuthority(4)), result.effects)
        assertEquals(4L, result.state.nextGeneration)
        assertTrue(result.state.hasAttached)
        assertTrue(result.state.channelAttached)
        assertNull(result.state.claim)
        assertNull(result.state.pendingIntent)
        assertTrue(result.trace?.contains("event=foregrounded") == true)
    }

    @Test
    fun pendingShowIntentDecodesWithoutABaseline() {
        val result = checkNotNull(SharedTmuxAuthoritySession.parse(JSONObject("""
            {
              "version": 2,
              "channelLive": true,
              "hidden": false,
              "presentation": { "kind": "none" },
              "gatesTyping": false,
              "geometryHold": "withheld",
              "authorityKind": "peer",
              "authorityDeviceID": "ipad",
              "authorityDisplayName": "iPad",
              "authorityGeneration": 7,
              "hasAttached": true,
              "channelAttached": false,
              "nextGeneration": 0,
              "pendingIntent": { "token": 3, "source": "explicitOpen", "baselineKnown": false },
              "effects": []
            }
        """.trimIndent())))

        assertEquals(
            SharedTmuxAuthorityIntent(
                token = 3,
                source = SharedTmuxAuthorityIntentSource.EXPLICIT_OPEN,
                baseline = null,
                baselineKnown = false,
            ),
            result.state.pendingIntent,
        )
        assertFalse(result.state.channelAttached)
        assertTrue(result.effects.isEmpty())
        assertNull(result.trace)
    }

    @Test
    fun tapIntentDecodesTheVeilItNamed() {
        val result = checkNotNull(SharedTmuxAuthoritySession.parse(JSONObject("""
            {
              "version": 2,
              "channelLive": true,
              "hidden": false,
              "presentation": { "kind": "none" },
              "gatesTyping": false,
              "geometryHold": "withheld",
              "authorityKind": "peer",
              "authorityDeviceID": "ipad",
              "authorityDisplayName": "iPad",
              "authorityGeneration": 7,
              "hasAttached": false,
              "channelAttached": false,
              "nextGeneration": 0,
              "pendingIntent": {
                "token": 1,
                "source": "tap",
                "baselineKnown": true,
                "baseline": { "deviceID": "ipad", "displayName": "iPad", "generation": 7 }
              },
              "effects": []
            }
        """.trimIndent())))

        assertEquals(SharedTmuxAuthorityIntentSource.TAP, result.state.pendingIntent?.source)
        assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("ipad", "iPad", 7), result.state.pendingIntent?.baseline)
        assertTrue(result.state.pendingIntent?.baselineKnown ?: false)
        assertFalse(result.state.channelAttached)
    }

    @Test
    fun escapeSettlementAndOwnerReplayEffectsDecode() {
        val result = checkNotNull(SharedTmuxAuthoritySession.parse(JSONObject("""
            {
              "version": 2,
              "channelLive": true,
              "hidden": false,
              "presentation": { "kind": "none" },
              "gatesTyping": false,
              "geometryHold": "withheld",
              "authorityKind": "peer",
              "authorityDeviceID": "ipad",
              "authorityDisplayName": "iPad",
              "authorityGeneration": 7,
              "claim": {
                "generation": 5,
                "reason": "userTakeBack",
                "phase": "awaitingFence",
                "presentationVisible": true,
                "contestedPeer": { "deviceID": "ipad", "displayName": "iPad", "generation": 7 }
              },
              "hasAttached": true,
              "channelAttached": true,
              "nextGeneration": 5,
              "effects": [
                { "kind": "claimAborted", "reason": "superseded" },
                { "kind": "beginClaim", "generation": 5, "reason": "userTakeBack", "presentationVisible": true },
                { "kind": "claimAborted", "reason": "contestedByPeer", "authorityKind": "peer",
                  "authorityDeviceID": "ipad", "authorityDisplayName": "iPad", "authorityGeneration": 8 },
                { "kind": "beginClaim", "generation": 6, "reason": "ownWriteWon", "presentationVisible": true },
                { "kind": "beginClaim", "generation": 7, "reason": "explicitOpen", "presentationVisible": true },
                { "kind": "claimSettled", "generation": 6 },
                { "kind": "releaseGeometry", "release": "ownerReplay" }
              ]
            }
        """.trimIndent())))

        assertEquals(
            listOf(
                SharedTmuxAuthoritySessionEffect.ClaimAborted("superseded", null),
                SharedTmuxAuthoritySessionEffect.BeginClaim(5, SharedTmuxAuthorityClaimReason.USER_TAKE_BACK, true),
                SharedTmuxAuthoritySessionEffect.ClaimAborted(
                    "contestedByPeer",
                    SharedTmuxGridAuthoritySnapshot.Peer("ipad", "iPad", 8),
                ),
                SharedTmuxAuthoritySessionEffect.BeginClaim(6, SharedTmuxAuthorityClaimReason.OWN_WRITE_WON, true),
                SharedTmuxAuthoritySessionEffect.BeginClaim(7, SharedTmuxAuthorityClaimReason.EXPLICIT_OPEN, true),
                SharedTmuxAuthoritySessionEffect.ClaimSettled(6),
                SharedTmuxAuthoritySessionEffect.ReleaseGeometry(SharedTmuxAuthorityGeometryRelease.OWNER_REPLAY),
            ),
            result.effects,
        )
        assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("ipad", "iPad", 7), result.state.claim?.contestedPeer)
    }

    @Test
    fun removedDepartureEffectsAndReasonsAreRejected() {
        fun envelope(effect: String) = JSONObject("""
            {
              "version": 2,
              "channelLive": true,
              "hidden": false,
              "presentation": { "kind": "none" },
              "gatesTyping": false,
              "geometryHold": "withheld",
              "authorityKind": "unknown",
              "hasAttached": true,
              "channelAttached": true,
              "nextGeneration": 1,
              "effects": [ $effect ]
            }
        """.trimIndent())

        assertThrows(IllegalStateException::class.java) {
            checkNotNull(SharedTmuxAuthoritySession.parse(envelope("""{ "kind": "requestPeerPresenceProof" }""")))
        }
        assertThrows(IllegalStateException::class.java) {
            checkNotNull(SharedTmuxAuthoritySession.parse(envelope("""{ "kind": "presentClaimProgress", "generation": 1 }""")))
        }
        for (removed in listOf("initialAttach", "reconnectRecovery", "peerDeparted")) {
            assertThrows(NoSuchElementException::class.java) {
                checkNotNull(SharedTmuxAuthoritySession.parse(
                    envelope("""{ "kind": "beginClaim", "generation": 1, "reason": "$removed" }"""),
                ))
            }
        }
    }

    private companion object {
        val UNCHANGED = """{"version":2,"unchanged":true}""".encodeToByteArray()
        const val FRESH =
            """{"presentation":{"kind":"none"},"effects":[],"channelLive":false,"authorityKind":"unknown","version":2,"nextGeneration":0,"geometryHold":"withheld","channelAttached":false,"gatesTyping":false,"hasAttached":false,"hidden":true}"""
        const val RETRYING =
            """{"presentation":{"kind":"none"},"effects":[],"channelLive":true,"authorityKind":"unknown","version":2,"nextGeneration":0,"geometryHold":"withheld","channelAttached":true,"gatesTyping":false,"hasAttached":true,"hidden":false,"nextDeadlineMillis":550,"trace":"event=queryFailed(r2)"}"""
    }
}

/** Android's org.json has no `keySet()`. */
private fun JSONObject.keyNames(): Set<String> = keys().asSequence().toSet()
