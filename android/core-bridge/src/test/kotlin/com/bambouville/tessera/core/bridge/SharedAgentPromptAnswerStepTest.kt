package com.bambouville.tessera.core.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SharedAgentPromptAnswerStepTest {
    @Test fun promptPlanRetainsNamedKeysAndTextSteps() {
        for (key in listOf(null, "Enter", "Escape", "Tab", "BTab", "Up", "Down", "Left", "Right", "S-Left", "C-]")) {
            val fields = mutableMapOf<String, SharedAgentValue>("action" to SharedAgentValue.StringValue("send"),
                "bytes" to SharedAgentValue.StringValue("\r"), "phase" to SharedAgentValue.StringValue("confirm"))
            key?.let { fields["semanticKey"] = SharedAgentValue.StringValue(it) }
            val decoded = SharedAgentPromptAnswerStep.decode(SharedAgentValue.ObjectValue(mapOf("step" to SharedAgentValue.ObjectValue(fields))))!!
            assertEquals(key, decoded.semanticKey)
            assertEquals("\r", decoded.bytes)
            assertEquals("confirm", decoded.phase)
        }
    }

    @Test fun absentOrMalformedStepDoesNotInventAKey() {
        assertNull(SharedAgentPromptAnswerStep.decode(SharedAgentValue.ObjectValue(emptyMap())))
        assertNull(SharedAgentPromptAnswerStep.decode(SharedAgentValue.ObjectValue(mapOf("step" to SharedAgentValue.StringValue("Enter")))))
    }
}
