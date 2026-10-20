package com.bambouville.tessera.agent.platform

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentLifecycleOscScannerTest {
    @Test
    fun acceptsSplitBelTerminatedLifecycleFrame() {
        val payload = "{\"version\":9}".encodeToByteArray()
        val bytes = "\u001b]1337;TesseraAgentState=${Base64.getEncoder().encodeToString(payload)}\u0007".encodeToByteArray()
        val scanner = AgentLifecycleOscScanner()

        assertTrue(scanner.feed(bytes.copyOfRange(0, 10)).isEmpty())
        assertEquals(listOf(payload.toList()), scanner.feed(bytes.copyOfRange(10, bytes.size)).map { it.toList() })
    }

    @Test
    fun unrelatedAndOversizedOscNeverProduceLifecycleFrame() {
        val scanner = AgentLifecycleOscScanner()
        assertTrue(scanner.feed("\u001b]0;terminal title\u0007".encodeToByteArray()).isEmpty())
        assertTrue(scanner.feed("\u001b]1337;TesseraAgentState=${"a".repeat(20_000)}\u0007".encodeToByteArray()).isEmpty())
    }
}
