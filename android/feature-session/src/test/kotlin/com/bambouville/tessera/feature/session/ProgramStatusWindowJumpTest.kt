package com.bambouville.tessera.feature.session

import com.bambouville.tessera.core.bridge.SharedTmuxGridAuthoritySnapshot
import com.bambouville.tessera.core.bridge.SharedTmuxSnapshot
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProgramStatusWindowJumpTest {
    private fun snapshot(window: Int) = SharedTmuxSnapshot(
        sessionName = "test", activeWindowId = window, windows = emptyList(),
        authority = SharedTmuxGridAuthoritySnapshot.Mine(generation = 1),
        revision = 1, rawJson = ByteArray(0),
    )

    @Test fun acceptedWindowReturnsOnlyWhileRequestIsCurrent() = runBlocking {
        val selected = snapshot(2)
        assertEquals(selected, awaitProgramStatusWindow(flowOf(snapshot(1), selected), 2, { true }))
        assertNull(awaitProgramStatusWindow(flowOf(selected), 2, { false }))
    }

    @Test fun rejectedWindowTimesOutAndLaterVisitHasNoPendingCollector() = runBlocking {
        val snapshots = MutableStateFlow<SharedTmuxSnapshot?>(snapshot(1))
        assertNull(awaitProgramStatusWindow(snapshots, 2, { true }, timeoutMillis = 10))
        assertEquals(0, snapshots.subscriptionCount.value)
        snapshots.value = snapshot(2)
        assertEquals(0, snapshots.subscriptionCount.value)
    }

    @Test fun staleRequestCarrierOrNavigationStopsBeforeSelectingAPane() = runBlocking {
        for (reason in listOf("request replaced", "carrier replaced", "newer navigation")) {
            val snapshots = MutableStateFlow<SharedTmuxSnapshot?>(snapshot(1))
            var current = true
            val waiting = async(start = CoroutineStart.UNDISPATCHED) {
                awaitProgramStatusWindow(snapshots, 2, { current })
            }
            current = false
            snapshots.value = snapshot(2)
            assertNull(reason, withTimeout(1_000) { waiting.await() })
            assertEquals(0, snapshots.subscriptionCount.value)
        }
    }

    @Test fun lostTransportOrAnotherWindowConsumesTheRequest() = runBlocking {
        assertNull(awaitProgramStatusWindow(flowOf(snapshot(1), null, snapshot(2)), 2, { it != null }))
        assertNull(awaitProgramStatusWindow(flowOf(snapshot(1), snapshot(3), snapshot(2)), 2,
            { it?.activeWindowId == 1 || it?.activeWindowId == 2 }))
    }
}
