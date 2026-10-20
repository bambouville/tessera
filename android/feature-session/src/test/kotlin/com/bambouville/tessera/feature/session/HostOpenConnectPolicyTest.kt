package com.bambouville.tessera.feature.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HostOpenConnectPolicyTest {
    @Test
    fun hostOpenStartsOnlyADisconnectedTransport() {
        assertTrue(shouldConnectFromHostOpen(SshSessionUiState.Disconnected))
        assertFalse(shouldConnectFromHostOpen(SshSessionUiState.Connecting))
        assertFalse(shouldConnectFromHostOpen(SshSessionUiState.Connected))
        assertFalse(shouldConnectFromHostOpen(SshSessionUiState.Terminated))
        assertFalse(shouldConnectFromHostOpen(SshSessionUiState.Failed("fixture")))
    }

    @Test
    fun aLaterPresentedHostOpenCanStartTheSameSessionAgain() {
        assertFalse(hasPendingPresentedHostOpen(request = 1, consumed = 0, isPresented = false))
        assertTrue(hasPendingPresentedHostOpen(request = 1, consumed = 0, isPresented = true))
        assertFalse(hasPendingPresentedHostOpen(request = 1, consumed = 1, isPresented = true))
        assertTrue(hasPendingPresentedHostOpen(request = 2, consumed = 1, isPresented = true))
    }
}
