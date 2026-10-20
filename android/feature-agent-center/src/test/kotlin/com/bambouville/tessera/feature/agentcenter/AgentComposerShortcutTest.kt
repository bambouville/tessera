package com.bambouville.tessera.feature.agentcenter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentComposerShortcutTest {
    private fun dispatch(
        draft: String,
        ctrl: Boolean = false,
        meta: Boolean = false,
        enter: Boolean = true,
        down: Boolean = true,
        isRepeat: Boolean = false,
        enabled: Boolean = true,
        sending: Boolean = false,
        uploading: Boolean = false,
        onSend: () -> Unit,
    ) = handleComposerSendShortcut(enter, down, isRepeat, ctrl, meta, draft, enabled, sending, uploading, onSend)

    @Test fun ctrlEnterSendsOnceAndLeavesDraftToTheOwner() {
        val draft = "ship it"
        var sends = 0
        assertTrue(dispatch(draft, ctrl = true) { sends++ })
        assertEquals(1, sends)
    }

    @Test fun repeatedCommandEnterIsConsumedWithoutSending() {
        var sends = 0
        assertTrue(dispatch("ship it", ctrl = true, isRepeat = true) { sends++ })
        assertEquals(0, sends)
    }

    @Test fun metaEnterSendsOnce() {
        var sends = 0
        assertTrue(dispatch("ship it", meta = true) { sends++ })
        assertEquals(1, sends)
    }

    @Test fun blockedCommandEnterIsConsumedWithoutSending() {
        for (case in listOf(
            Blocked(""), Blocked("  \n"), Blocked("unsafe\u0001"),
            Blocked("ship it", enabled = false), Blocked("ship it", sending = true),
            Blocked("ship it", uploading = true),
        )) {
            var sends = 0
            assertTrue(dispatch(case.draft, ctrl = true, enabled = case.enabled,
                sending = case.sending, uploading = case.uploading) { sends++ })
            assertEquals(case.toString(), 0, sends)
        }
    }

    @Test fun plainAndShiftEnterRemainForTheTextField() {
        var sends = 0
        // Shift is intentionally absent: it does not change the command-chord decision.
        assertFalse(dispatch("ship it") { sends++ })
        assertEquals(0, sends)
    }

    @Test fun keyUpAndOtherKeysDoNotSend() {
        var sends = 0
        assertFalse(dispatch("ship it", ctrl = true, down = false) { sends++ })
        assertFalse(dispatch("ship it", meta = true, enter = false) { sends++ })
        assertEquals(0, sends)
    }

    private data class Blocked(
        val draft: String,
        val enabled: Boolean = true,
        val sending: Boolean = false,
        val uploading: Boolean = false,
    )
}
