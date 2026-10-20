package com.bambouville.tessera.feature.agentcenter

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.json.JSONObject

class AgentActionLifetimeTest {
    @Test fun independentThreadsCanActWhileAMovedPaneKeepsItsBusyGate() {
        val binding = JSONObject().put("liveSessionID", "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
            .put("carrierGeneration", 1).put("transport", "moshTmux").put("windowID", "@1").put("paneID", "%4")
        val moved = JSONObject(binding.toString()).put("liveSessionID", binding.getString("liveSessionID").lowercase()).put("windowID", "@2")
        assertTrue(agentActionTargetBusy("same-pane-successor", moved, "stalled", binding))
        assertTrue(agentActionTargetBusy("stalled", JSONObject(binding.toString()).put("paneID", "%5"), "stalled", binding))
        assertFalse(agentActionTargetBusy("sibling", JSONObject(binding.toString()).put("paneID", "%5"), "stalled", binding))
        assertFalse(agentActionTargetBusy("ssh", JSONObject(binding.toString()).put("liveSessionID", "another-carrier").put("transport", "ssh"), "stalled", binding))
        val raw = JSONObject(binding.toString()).apply { remove("windowID"); remove("paneID") }.put("transport", "mosh")
        assertTrue(agentActionTargetBusy("raw-sibling", raw, "raw", raw))
        assertFalse(agentActionTargetBusy("raw-sibling", raw, "stalled", binding))
    }

    @Test fun disabledOrCancelledInspectionCannotResumeIntoTerminalWrites() = runBlocking {
        for (scenario in listOf("disable", "cancel", "runtime-replaced", "active")) {
            val inspection = CompletableDeferred<Unit>()
            var enabled = true
            var runtimeAvailable = true
            var writes = 0
            val worker = launch(start = CoroutineStart.UNDISPATCHED) {
                // Model a native observation that finishes after cancellation.
                withContext(NonCancellable) { inspection.await() }
                requireAgentActionLifetime(enabled, runtimeAvailable)
                writes++
            }
            when (scenario) {
                "disable" -> enabled = false
                "cancel" -> worker.cancel()
                "runtime-replaced" -> runtimeAvailable = false
            }
            inspection.complete(Unit)
            worker.join()
            assertEquals(if (scenario == "active") 1 else 0, writes)
        }
    }
}
