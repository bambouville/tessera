package com.bambouville.tessera.agent.platform

import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentProcessProofTest {
    @Test
    fun lifecycleTrustRequiresTheSameProviderPidAndProcessStartIdentity() {
        val proof = AgentProcessProof(
            processIDs = setOf(4242, 100),
            provider = AgentProofProvider.KIMI,
            processStart = "proc:987654",
        )

        assertTrue(proof.matchesProcessIdentity(4242, AgentProofProvider.KIMI, "proc:987654"))
        assertFalse(proof.matchesProcessIdentity(4242, AgentProofProvider.KIMI, "proc:987655"))
        assertFalse(proof.matchesProcessIdentity(4242, AgentProofProvider.CODEX, "proc:987654"))
        assertFalse(proof.matchesProcessIdentity(9999, AgentProofProvider.KIMI, "proc:987654"))
    }

    @Test
    fun processProofRejectsMissingOrControlCharacterStartIdentity() {
        assertThrows(IllegalArgumentException::class.java) {
            AgentProcessProof(setOf(42), AgentProofProvider.CODEX, "")
        }
        assertThrows(IllegalArgumentException::class.java) {
            AgentProcessProof(setOf(42), AgentProofProvider.CODEX, "proc:42\nforged")
        }
    }
}
