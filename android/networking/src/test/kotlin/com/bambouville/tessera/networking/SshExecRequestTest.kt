package com.bambouville.tessera.networking

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SshExecRequestTest {
    @Test
    fun typedProjectorOperationUsesBoundedStdinInsteadOfShellArguments() {
        val request = SshExecRequest(SshRemoteOperation.AGENT_PROJECT)

        assertEquals(SshRemoteOperation.AGENT_PROJECT, request.operation)
        assertEquals(262_144, request.maxStdinBytes)
        assertEquals(262_144, request.maxStdoutBytes)
        assertEquals(16_384, request.maxStderrBytes)
    }

    @Test
    fun integrationShellIsAnExplicitFixedOperation() {
        val request = SshExecRequest(SshRemoteOperation.AGENT_INTEGRATION_SHELL)

        assertEquals("/bin/sh -s", request.remoteCommand)
    }

    @Test
    fun streamBoundsCannotExceedTheCorePayloadCeiling() {
        assertThrows(IllegalArgumentException::class.java) {
            SshExecRequest(SshRemoteOperation.AGENT_PROJECT, maxStdoutBytes = 1_048_577)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SshExecRequest(SshRemoteOperation.AGENT_PROJECT, maxStderrBytes = 0)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SshExecRequest(SshRemoteOperation.AGENT_PROJECT, maxStdoutBytes = 8_388_608, maxStderrBytes = 1)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SshExecRequest(
                SshRemoteOperation.AGENT_INTEGRATION_SHELL,
                maxStdinBytes = SshExecRequest.MAX_STDIN_BYTES + 1,
            )
        }
    }
}
