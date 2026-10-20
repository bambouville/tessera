package com.bambouville.tessera.feature.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Only the jump-route fallback is still this platform's decision. The kill
 * script, the retry ladder and the mosh end-event rule moved to the shared core
 * and are pinned by `MoshBootstrapGrammarTests` / `SessionEndClassificationTests`
 * in `Packages/TesseraCore`; a JVM unit test cannot reach them across JNI.
 */
class MoshSessionRecoveryPolicyTest {
    @Test
    fun `jump fallback requires a live detached server and no UDP connection`() {
        assertTrue(MoshSessionRecoveryPolicy.shouldFallBackFromJumpRoute(2, false, 42))
        assertFalse(MoshSessionRecoveryPolicy.shouldFallBackFromJumpRoute(1, false, 42))
        assertFalse(MoshSessionRecoveryPolicy.shouldFallBackFromJumpRoute(2, true, 42))
        assertFalse(MoshSessionRecoveryPolicy.shouldFallBackFromJumpRoute(2, false, null))
        assertFalse(MoshSessionRecoveryPolicy.shouldFallBackFromJumpRoute(2, false, 0))
    }
}
