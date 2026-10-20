package com.bambouville.tessera.feature.session

import com.bambouville.tessera.data.continuity.SessionRestorePolicy
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Platform decisions remain testable on the JVM. The kill script, retry ladder and mosh
 * end-event rule are pinned by the shared-core tests because JVM tests cannot reach JNI.
 */
class MoshSessionRecoveryPolicyServerLossTest {
    @Test
    fun `tmux rebuilds under every restore policy even with a custom command`() {
        for (policy in SessionRestorePolicy.entries) {
            assertDecision(MoshSessionRecoveryPolicy.ServerLossDecision.REBUILD, true, "run-custom-job", policy)
        }
    }

    @Test
    fun `bare login shell rebuilds under every restore policy`() {
        for (policy in SessionRestorePolicy.entries) {
            assertDecision(MoshSessionRecoveryPolicy.ServerLossDecision.REBUILD, false, null, policy)
        }
    }

    @Test
    fun `blank custom command rebuilds under every restore policy`() {
        for (policy in SessionRestorePolicy.entries) {
            for (command in listOf("", " ", "\t\r\n ")) {
                assertDecision(MoshSessionRecoveryPolicy.ServerLossDecision.REBUILD, false, command, policy)
            }
        }
    }

    @Test
    fun `custom command rebuilds with explicit always policy`() {
        assertDecision(MoshSessionRecoveryPolicy.ServerLossDecision.REBUILD, false, "  run-custom-job\n", SessionRestorePolicy.ALWAYS)
    }

    @Test
    fun `custom command is kept as failure with ask policy`() {
        assertDecision(MoshSessionRecoveryPolicy.ServerLossDecision.KEEP_FOR_LAUNCH_COMMAND, false, "run-custom-job", SessionRestorePolicy.ASK)
    }

    @Test
    fun `custom command is kept as failure with never policy`() {
        assertDecision(MoshSessionRecoveryPolicy.ServerLossDecision.KEEP_FOR_LAUNCH_COMMAND, false, "run-custom-job", SessionRestorePolicy.NEVER)
    }

    private fun assertDecision(
        expected: MoshSessionRecoveryPolicy.ServerLossDecision,
        hasTmuxTarget: Boolean,
        command: String?,
        policy: SessionRestorePolicy,
    ) {
        assertEquals(expected, MoshSessionRecoveryPolicy.serverLossDecision(hasTmuxTarget, command, policy))
    }
}
