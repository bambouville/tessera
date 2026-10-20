package com.bambouville.tessera.feature.agentcenter

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class AgentLifecycleProofRetryTest {
    @Test fun quietPaneRecoversWithoutAnotherLifecycleFrame(): Unit = runBlocking {
        val retries = AgentLifecycleProofRetry<String>(this, 1)
        val recovered = CompletableDeferred<Unit>()
        var attempts = 0
        retries.schedule("pane", { true }) {
            attempts++
            if (attempts < 3) true else { recovered.complete(Unit); false }
        }
        withTimeout(2_000) { recovered.await() }
        assertEquals(3, attempts)
        retries.clear()
    }

    @Test fun replacedFrameCancelsAProofAlreadyInFlight(): Unit = runBlocking {
        val retries = AgentLifecycleProofRetry<String>(this, 1)
        val started = CompletableDeferred<Unit>()
        val stopped = CompletableDeferred<Unit>()
        val latest = CompletableDeferred<Unit>()
        retries.schedule("pane", { true }) {
            try { started.complete(Unit); awaitCancellation() }
            finally { stopped.complete(Unit) }
        }
        withTimeout(2_000) { started.await() }
        retries.schedule("pane", { true }) { latest.complete(Unit); false }
        withTimeout(2_000) { stopped.await(); latest.await() }
        retries.clear()
    }

    @Test fun backgroundPausesButRetainsTheQuietFrame(): Unit = runBlocking {
        var foreground = false
        val retries = AgentLifecycleProofRetry<String>(this, 1, mayAttempt = { foreground })
        val recovered = CompletableDeferred<Unit>()
        retries.schedule("pane", { true }) { recovered.complete(Unit); false }
        delay(20)
        assertFalse(recovered.isCompleted)
        foreground = true
        withTimeout(2_000) { recovered.await() }
        retries.clear()
    }

    @Test fun retiredEndpointOrChangedPayloadNeverReplays(): Unit = runBlocking {
        val retries = AgentLifecycleProofRetry<String>(this, 1)
        var current = true
        var attempts = 0
        retries.schedule("pane", { current }) { attempts++; true }
        current = false
        delay(20)
        assertEquals(0, attempts)
        retries.clear()
    }
}
