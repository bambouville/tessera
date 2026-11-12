package com.bambouville.tessera.feature.artifacts

import com.bambouville.tessera.core.bridge.SharedArtifactTab
import com.bambouville.tessera.core.bridge.SharedArtifactsKind
import com.bambouville.tessera.core.bridge.SharedArtifactsTarget
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ArtifactFollowerTest {
    private fun tab(target: SharedArtifactsTarget = SharedArtifactsTarget.File("/a.md")) = SharedArtifactTab(
        "t", "h", "dev", target, SharedArtifactsKind.Docs, "a.md", "files", null, 1, 1, false, null, false, null,
    )

    @Test fun followsAtThreeSecondsAndStopsWhenHiddenBackgroundedOrOffline() = runTest {
        var live = true
        val observed = mutableListOf<String>()
        val follower = ArtifactFollower(backgroundScope, { live }, { observed += it })
        follower.update(tab(), true)
        runCurrent()
        advanceTimeBy(2_999); runCurrent(); assertEquals(0, observed.size)
        advanceTimeBy(1); runCurrent(); assertEquals(listOf("t"), observed)
        follower.update(null, true)
        advanceTimeBy(6_000); runCurrent(); assertEquals(1, observed.size)
        follower.update(tab(), true); runCurrent()
        follower.update(tab(), false)
        advanceTimeBy(6_000); runCurrent(); assertEquals(1, observed.size)
        follower.update(tab(), true); runCurrent()
        live = false
        advanceTimeBy(3_000); runCurrent(); assertEquals(1, observed.size)
        live = true
        follower.update(tab(), true); runCurrent()
        advanceTimeBy(3_000); runCurrent(); assertEquals(2, observed.size)
        follower.update(tab(SharedArtifactsTarget.Page("http", 5173, "/")), true)
        advanceTimeBy(6_000); runCurrent(); assertEquals(2, observed.size)
    }

    @Test fun unchangedVisibleIdentityKeepsItsOriginalDeadline() = runTest {
        var calls = 0
        val follower = ArtifactFollower(backgroundScope, { true }, { calls += 1 })
        follower.update(tab(), true); runCurrent()
        advanceTimeBy(2_000)
        follower.update(tab().copy(viewedAt = 50), true); runCurrent()
        advanceTimeBy(1_000); runCurrent()
        assertEquals(1, calls)
    }
}
