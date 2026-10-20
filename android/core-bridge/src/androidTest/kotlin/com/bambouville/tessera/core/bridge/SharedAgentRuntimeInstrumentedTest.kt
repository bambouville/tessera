package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SharedAgentRuntimeInstrumentedTest {
    @Test
    fun versionedSnapshotCallbackDecodesToImmutableTypedState() {
        val event = SharedAgentEventDecoder.decode(
            """{"version":1,"kind":"listSnapshot","generation":7,"list":{"threads":[]}}"""
                .encodeToByteArray(),
        )

        assertTrue(event is SharedAgentRuntimeEvent.Snapshot)
        val snapshot = (event as SharedAgentRuntimeEvent.Snapshot).snapshot
        assertEquals(7L, snapshot.runtimeGeneration)
        assertEquals(SharedAgentSnapshotKind.List, snapshot.kind)
        val list = snapshot.payload.fields.getValue("list") as SharedAgentValue.ObjectValue
        assertEquals(SharedAgentValue.ArrayValue(emptyList()), list.fields.getValue("threads"))
    }

    @Test
    fun malformedOrGenerationlessCallbacksFailClosed() {
        val invalid = listOf(
            """{"version":1,"kind":"listSnapshot","list":{}}""",
            """{"version":2,"kind":"listSnapshot","generation":1,"list":{}}""",
        )

        invalid.forEach { payload ->
            val result = runCatching { SharedAgentEventDecoder.decode(payload.encodeToByteArray()) }
            assertTrue(result.isFailure)
        }
    }

    @Test
    fun nativeAgentHandleIsIndependentAndStaleAfterClose() {
        val state = CoreBridge.inspectAgent()
        assertTrue(state is AgentBridgeState.Ready)
        SharedAgentRuntime.create().use { runtime ->
            runtime.close()
            assertEquals(CoreCallResult.StaleHandle, runtime.sendCanonical("{}".encodeToByteArray()))
        }
    }
}
