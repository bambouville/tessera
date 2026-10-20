package com.bambouville.tessera.feature.session

import android.view.KeyCharacterMap
import android.view.KeyEvent
import com.bambouville.tessera.core.bridge.*
import org.junit.Assert.*
import org.junit.Test

/** Projections and geometry judgments from the real shared session. */
class TmuxAuthorityPresentationTest {
    private val peer = SharedTmuxGridAuthoritySnapshot.Peer("ipad-id", "iPad", 4)
    private val local = SharedTmuxGridSize(80, 24)
    private fun SharedTmuxAuthoritySession.read(now: Long = 0, raw: String = "v1 android-id 2 Pixel"): SharedTmuxAuthoritySessionResult {
        val query = attached(now, "android-id").effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
        return queryReplied(now, query.queryId, raw, "android-id")
    }
    private fun SharedTmuxAuthoritySession.geometry(size: SharedTmuxGridSize? = local, authoritative: Boolean = true) {
        localSize(0, local)
        windowFacts(0, true, SharedTmuxAuthorityActiveWindow(5, size, authoritative))
    }

    @Test fun aShowProjectsResumingThroughABufferedPeerUntilItsClaimSettles() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        s.geometry(); s.attached(0, "android-id")
        val show = s.shown(0)
        val observed = s.observedAuthority(0, peer)
        val query = show.effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
        val claim = s.queryReplied(0, query.queryId, "v1 ipad-id 4 iPad", "android-id")
        val g = claim.state.claim!!.generation
        s.confirmFence(0, g, local)
        s.repaintSucceeded(0, g); s.stampCommitSucceeded(0, g)
        val settled = s.settle(0, g)
        assertEquals(listOf(TmuxAuthorityPresentation.Resuming(), TmuxAuthorityPresentation.Resuming(), TmuxAuthorityPresentation.Resuming(), TmuxAuthorityPresentation.None),
            listOf(show, observed, claim, settled).map { it.state.presentation.forAndroid() })
    }
    @Test fun anExplicitOpenResumesLikeAShow() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        assertEquals(TmuxAuthorityPresentation.Resuming(true), s.shown(0, SharedTmuxAuthorityShowSource.EXPLICIT_OPEN).state.presentation.forAndroid())
        val read = s.attached(0, "android-id").effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
        assertEquals(TmuxAuthorityPresentation.Resuming(), s.queryReplied(0, read.queryId, "v1 ipad-id 4 iPad", "android-id").state.presentation.forAndroid())
    }
    @Test fun aShowWithoutAChannelSaysItWillTakeControlWhenReconnected() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        assertEquals(TmuxAuthorityPresentation.Resuming(true), s.shown(0).state.presentation.forAndroid())
        s.attached(0); s.channelLiveness(0, false)
        assertEquals(TmuxAuthorityPresentation.Resuming(true), s.state.presentation.forAndroid())
    }
    @Test fun aPeerWithoutIntentOrClaimIsVeiled() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        s.adoptShown(0)
        assertEquals(TmuxAuthorityPresentation.Veiled("iPad"), s.observedAuthority(0, peer).state.presentation.forAndroid())
    }
    @Test fun aTapIsReclaimingAndWaitsVisiblyForTheChannel() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        s.adoptShown(0); s.observedAuthority(0, peer)
        assertEquals(TmuxAuthorityPresentation.Reclaiming("iPad", true), s.requestTakeBack(0).state.presentation.forAndroid())
        val read = s.attached(0, "android-id").effects.filterIsInstance<SharedTmuxAuthoritySessionEffect.QueryAuthority>().single()
        assertEquals(TmuxAuthorityPresentation.Reclaiming("iPad"), s.queryReplied(0, read.queryId, "v1 ipad-id 4 iPad", "android-id").state.presentation.forAndroid())
    }
    @Test fun aClaimWhosePresentationTimedOutShowsTheVeilAgain() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
        s.adoptShown(0); s.attached(0); s.observedAuthority(0, peer); s.requestTakeBack(0)
        assertEquals(TmuxAuthorityPresentation.Veiled("iPad"), s.tick(3000).state.presentation.forAndroid())
        assertNotNull(s.state.claim); assertFalse(s.state.claim!!.presentationVisible)
    }
    @Test fun onlyNoneEnablesTheWindowChrome() {
        assertFalse(TmuxAuthorityPresentation.None.gatesInput)
        listOf(TmuxAuthorityPresentation.Resuming(), TmuxAuthorityPresentation.Resuming(true), TmuxAuthorityPresentation.Veiled(null), TmuxAuthorityPresentation.Reclaiming(null), TmuxAuthorityPresentation.Reclaiming(null, true)).forEach { assertTrue(it.gatesInput) }
    }
    @Test fun typingWaitsForALiveChannelsDecisionButNotForAMissingChannel() {
        for (authority in listOf(SharedTmuxGridAuthoritySnapshot.Unknown, SharedTmuxGridAuthoritySnapshot.Mine(2), peer)) {
            SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
                s.observedAuthority(0, authority); s.shown(0)
                assertEquals(authority is SharedTmuxGridAuthoritySnapshot.Peer, s.state.gatesTyping)
                s.attached(0); assertTrue(s.state.gatesTyping)
            }
        }
    }
    @Test fun onlyAReadNamingThisDeviceMayBeItsOwnStamp() {
        for ((raw, mine) in listOf(
            "" to false, "v1 ipad-id 4 iPad" to false, "garbage" to false, "android-id" to false,
            "v1 android-id 2 Pixel" to true, "  v1  android-id 12 Android-Phone \n" to true,
        )) SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
            s.geometry(); s.adoptShown(0)
            assertEquals(mine, s.read(raw = raw).state.authority is SharedTmuxGridAuthoritySnapshot.Mine)
        }
    }
    @Test fun geometryEvidenceComparesTheWindowWithLocalAndRecentlyOwnedSizes() = SharedTmuxAuthoritySession.create(initialGeneration = 0).use {
        val owned = listOf(SharedTmuxGridSize(203, 30), SharedTmuxGridSize(100, 30))
        for (policy in listOf("latest", "manual", null)) {
            for (window in owned + local) SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
                s.adoptShown(0)
                for ((index, size) in owned.withIndex()) {
                    s.localSize(index.toLong(), size); s.windowFacts(index.toLong(), true, SharedTmuxAuthorityActiveWindow(5, size, true))
                    assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), s.read(index.toLong()).state.authority)
                }
                s.localSize(2, local); s.windowFacts(2, true, SharedTmuxAuthorityActiveWindow(5, window, true))
                policy?.let { s.windowSizePolicyReplied(2, 5, it) }
                assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), s.read(2).state.authority)
                assertNull(s.state.nextDeadlineMillis)
            }
        }
        for (missing in listOf("layout", "local", "hydration", "authoritative")) SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
            s.adoptShown(0); s.localSize(0, if (missing == "local") null else local)
            s.windowFacts(0, missing != "hydration", SharedTmuxAuthorityActiveWindow(5, if (missing == "layout") null else local, missing != "authoritative"))
            assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, s.read().state.authority)
            assertEquals(SharedTmuxAuthorityGeometryHold.WITHHELD, s.state.geometryHold)
            assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, s.tick(9999).state.authority)
            assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), s.tick(10000).state.authority)
            assertNull(s.state.claim)
        }
        SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
            s.geometry(SharedTmuxGridSize(90, 40)); s.adoptShown(0); s.windowSizePolicyReplied(0, 5, "latest")
            assertTrue(s.read().state.authority is SharedTmuxGridAuthoritySnapshot.Peer)
        }
    }
    @Test fun theOwnedHistoryKeepsTheNewestEightDistinctSizesNewestLast() {
        val sizes = (1..12).map { SharedTmuxGridSize(100 + it, 30) }
        for (refresh in listOf(false, true)) {
            val recorded = sizes.take(10) + (if (refresh) listOf(sizes[4]) + sizes.takeLast(2) else emptyList())
            val history = recorded.fold(emptyList<SharedTmuxGridSize>()) { previous, size -> (previous - size + size).takeLast(8) }
            for (size in sizes) SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
                s.adoptShown(0)
                for ((index, owned) in recorded.withIndex()) {
                    s.localSize(index.toLong(), owned); s.windowFacts(index.toLong(), true, SharedTmuxAuthorityActiveWindow(5, owned, true)); s.read(index.toLong())
                }
                s.localSize(20, local); s.windowFacts(20, true, SharedTmuxAuthorityActiveWindow(5, size, true)); s.windowSizePolicyReplied(20, 5, "latest")
                assertEquals("refresh=$refresh size=$size", size in history, s.read(20).state.authority is SharedTmuxGridAuthoritySnapshot.Mine)
            }
        }
    }
    @Test fun aMismatchCountsAsForeignOnlyUnderTheLatestPolicy() {
        for (policy in listOf("latest", "manual", "smallest", "largest", null)) SharedTmuxAuthoritySession.create(initialGeneration = 0).use { s ->
            s.geometry(SharedTmuxGridSize(120, 40)); s.adoptShown(0)
            policy?.let { s.windowSizePolicyReplied(0, 5, it) }
            val read = s.read()
            if (policy == null) {
                assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, read.state.authority)
                assertEquals(SharedTmuxAuthorityGeometryHold.WITHHELD, read.state.geometryHold)
                assertEquals(SharedTmuxGridAuthoritySnapshot.Unknown, s.tick(9999).state.authority)
                assertEquals(SharedTmuxGridAuthoritySnapshot.Mine(2), s.tick(10000).state.authority)
            } else {
                assertEquals(policy == "latest", read.state.authority is SharedTmuxGridAuthoritySnapshot.Peer)
                assertEquals(policy == "latest", s.tick(10000).state.authority is SharedTmuxGridAuthoritySnapshot.Peer)
            }
        }
    }

    @Test
    fun theVeilTakesBackOnlyOnEnterOrAPrintableKey() {
        fun admits(keyCode: Int, char: Int = 0, ctrl: Boolean = false, meta: Boolean = false) =
            VeilKeyPolicy.admitsTakeBack(keyCode, char, ctrl, meta)

        assertTrue(admits(KeyEvent.KEYCODE_ENTER))
        assertTrue(admits(KeyEvent.KEYCODE_NUMPAD_ENTER))
        assertTrue(admits(KeyEvent.KEYCODE_A, 'a'.code))
        assertTrue(admits(KeyEvent.KEYCODE_SPACE, ' '.code))

        assertFalse(admits(KeyEvent.KEYCODE_BACK))
        assertFalse(admits(KeyEvent.KEYCODE_VOLUME_UP))
        assertFalse(admits(KeyEvent.KEYCODE_VOLUME_DOWN))
        assertFalse(admits(KeyEvent.KEYCODE_ESCAPE, 27))
        assertFalse(admits(KeyEvent.KEYCODE_TAB, '\t'.code))
        assertFalse(admits(KeyEvent.KEYCODE_SHIFT_LEFT))
        assertFalse(admits(KeyEvent.KEYCODE_CTRL_LEFT))
        assertFalse(admits(KeyEvent.KEYCODE_DPAD_UP))
        assertFalse("Ctrl chords never take back", admits(KeyEvent.KEYCODE_C, 'c'.code, ctrl = true))
        assertFalse("Meta chords never take back", admits(KeyEvent.KEYCODE_W, 'w'.code, meta = true))
        assertFalse("Ctrl+Enter is a chord", admits(KeyEvent.KEYCODE_ENTER, ctrl = true))
        assertFalse("dead keys wait for their base", admits(KeyEvent.KEYCODE_GRAVE, '`'.code or KeyCharacterMap.COMBINING_ACCENT))
    }

    @Test
    fun backMediaAndBareModifiersNeverTakeBackSoNavigationStillRuns() {
        // D8: on API 33-35 without the predictive-back callback, Back reaches
        // the veil as a key. Left unconsumed, it still runs the BackHandler.
        fun admits(keyCode: Int, char: Int = 0) = VeilKeyPolicy.admitsTakeBack(keyCode, char, false, false)

        assertFalse("Back, even from a keyboard that maps a character to it", admits(KeyEvent.KEYCODE_BACK, 'b'.code))
        for (key in listOf(
            KeyEvent.KEYCODE_VOLUME_MUTE, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_MEDIA_NEXT,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS, KeyEvent.KEYCODE_MEDIA_STOP, KeyEvent.KEYCODE_HEADSETHOOK,
            KeyEvent.KEYCODE_MUTE, KeyEvent.KEYCODE_BRIGHTNESS_UP, KeyEvent.KEYCODE_HOME, KeyEvent.KEYCODE_APP_SWITCH,
            KeyEvent.KEYCODE_POWER, KeyEvent.KEYCODE_MENU, KeyEvent.KEYCODE_SHIFT_RIGHT, KeyEvent.KEYCODE_CTRL_RIGHT,
            KeyEvent.KEYCODE_ALT_LEFT, KeyEvent.KEYCODE_ALT_RIGHT, KeyEvent.KEYCODE_META_LEFT, KeyEvent.KEYCODE_META_RIGHT,
            KeyEvent.KEYCODE_CAPS_LOCK, KeyEvent.KEYCODE_FUNCTION, KeyEvent.KEYCODE_F5, KeyEvent.KEYCODE_FORWARD_DEL,
        )) {
            assertFalse("keyCode $key", admits(key))
        }
    }

    @Test
    fun theTerminalDrawsOnlyOnTheShownSessionAndNeverUnderItsVeil() {
        // P9: one rule mounts the veil and pauses the terminals beneath it.
        // `resuming` keeps the terminal readable, so it keeps drawing.
        fun veil(presentation: TmuxAuthorityPresentation, launch: Boolean = false, connected: Boolean = true) =
            tmuxAuthorityVeilShown(presentation, launchOverlayShown = launch, connected = connected)

        val veiled = TmuxAuthorityPresentation.Veiled("iPad")
        val reclaiming = TmuxAuthorityPresentation.Reclaiming("iPad")
        val awaiting = TmuxAuthorityPresentation.Reclaiming("iPad", awaitingConnection = true)
        assertTrue(veil(veiled))
        assertTrue(veil(reclaiming))
        assertFalse(veil(TmuxAuthorityPresentation.None))
        assertFalse(veil(TmuxAuthorityPresentation.Resuming()))
        assertFalse(veil(TmuxAuthorityPresentation.Resuming(awaitingConnection = true), connected = false))
        assertFalse("the launch overlay covers it instead", veil(veiled, launch = true))
        assertFalse("a disconnected session shows its status, not a veil", veil(veiled, connected = false))
        assertTrue("a take-back waiting for the connection still veils", veil(awaiting, connected = false))

        assertTrue(terminalDrawingEnabled(presented = true, veilShown = veil(TmuxAuthorityPresentation.Resuming())))
        assertFalse(terminalDrawingEnabled(presented = true, veilShown = veil(veiled)))
        assertFalse("a hidden session never draws", terminalDrawingEnabled(presented = false, veilShown = false))
        assertFalse(terminalDrawingEnabled(presented = false, veilShown = veil(veiled)))
    }
}
