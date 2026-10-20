package com.bambouville.tessera.feature.pairing

import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import androidx.test.ext.junit.runners.AndroidJUnit4

/**
 * The closure must agree with BootstrapManifestV2.hostSelectionClosure in the
 * shared Swift core; the equivalent Swift case is
 * testHostSelectionClosureFollowsChainedJumpHosts. If these drift, the sender's
 * checkboxes stop describing what the core actually copies.
 */
@RunWith(AndroidJUnit4::class)
class HostSelectionClosureTest {
    private val alpha = "11111111-0000-0000-0000-000000000001"
    private val bravo = "11111111-0000-0000-0000-000000000002"
    private val charlie = "11111111-0000-0000-0000-000000000003"
    private val unrelated = "11111111-0000-0000-0000-000000000009"

    // alpha routes through bravo, which routes through charlie.
    private val chain = mapOf(alpha to bravo, bravo to charlie)

    @Test
    fun followsTheWholeChainNotOneHop() {
        assertEquals(setOf(alpha, bravo, charlie), hostSelectionClosure(setOf(alpha), chain))
    }

    @Test
    fun leavesHostsWithoutAJumpUntouched() {
        assertEquals(setOf(unrelated), hostSelectionClosure(setOf(unrelated), chain))
        assertEquals(setOf(charlie), hostSelectionClosure(setOf(charlie), chain))
    }

    @Test
    fun terminatesOnACyclicMapRatherThanSpinning() {
        // The manifest is validated acyclic before it reaches the UI, but the
        // closure must not hang if a malformed map ever gets this far.
        val cyclic = mapOf(alpha to bravo, bravo to alpha)
        assertEquals(setOf(alpha, bravo), hostSelectionClosure(setOf(alpha), cyclic))
    }
}
