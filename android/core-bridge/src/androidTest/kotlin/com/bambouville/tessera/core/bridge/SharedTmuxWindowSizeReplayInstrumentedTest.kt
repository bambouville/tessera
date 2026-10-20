package com.bambouville.tessera.core.bridge

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SharedTmuxWindowSizeReplayInstrumentedTest {
    private val requested = SharedTmuxGridSize(columns = 132, rows = 44)
    private val wider = SharedTmuxGridSize(columns = 164, rows = 44)
    private val ownInventory = "@7\tcontrol\t11\t101\n@7\tvisible\t12\t102"

    @Test
    fun exactDimensionsSettleAndRepeatedAttemptsWait() {
        assertEquals(SharedTmuxWindowSizeReplay.Decision.FITTING,
            SharedTmuxWindowSizeReplay.decision(requested, requested, null))
        assertEquals(SharedTmuxWindowSizeReplay.Decision.REPLAY,
            SharedTmuxWindowSizeReplay.decision(requested, wider, null))
        assertEquals(SharedTmuxWindowSizeReplay.Decision.REPLAY,
            SharedTmuxWindowSizeReplay.decision(requested, null, null))
        assertEquals(SharedTmuxWindowSizeReplay.Decision.WAITING,
            SharedTmuxWindowSizeReplay.decision(requested, wider, requested))
        assertEquals(SharedTmuxWindowSizeReplay.Decision.WAITING,
            SharedTmuxWindowSizeReplay.decision(requested, null, requested))
        assertEquals(SharedTmuxWindowSizeReplay.Decision.REPLAY,
            SharedTmuxWindowSizeReplay.decision(
                SharedTmuxGridSize(106, 44), wider, requested,
            ))
        assertEquals(SharedTmuxWindowSizeReplay.Decision.REPLAY,
            SharedTmuxWindowSizeReplay.decision(requested, SharedTmuxGridSize(132, 43), null))
        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxWindowSizeReplay.decision(SharedTmuxGridSize(0, 44), null, null)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxWindowSizeReplay.decision(requested, SharedTmuxGridSize(164, 0), null)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxWindowSizeReplay.decision(SharedTmuxGridSize(65_536, 44), null, null)
        }
    }

    @Test
    fun replayCommandsAreThreeMutationsThenTheCanonicalConfirmation() {
        assertEquals(listOf(
            "resize-window -x 132 -y 44 -t @7",
            "select-window",
            "set-option -w -u -t @7 window-size",
            "display-message -p -t @7 'tessera-window-size\t#{window_id}\t#{window_width}\t#{window_height}'",
        ), SharedTmuxWindowSizeReplay.commands(windowId = 7, requested = requested))
        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxWindowSizeReplay.commands(windowId = -1, requested = requested)
        }
    }

    @Test
    fun confirmationRejectsWrongIdentityGeometryAndNoncanonicalReplies() {
        val reply = "tessera-window-size\t@7\t132\t44"
        for (terminator in listOf("", "\n", "\r\n")) {
            assertTrue(SharedTmuxWindowSizeReplay.confirms(7, requested, reply + terminator))
        }
        for (invalid in listOf(
            "",
            "tessera-window-size\t@8\t132\t44",
            "tessera-window-size\t@7\t164\t44",
            "tessera-window-size\t@7\t132\t43",
            "tessera-window-size\t@07\t132\t44",
            "tessera-window-size\t@7\t0132\t44",
            "tessera-window-size\t@7\t132\t044",
            "tessera-window-size\\t@7\\t132\\t44",
            " $reply",
            "$reply\n$reply",
            "$reply\n\n",
            "$reply\textra",
            "x".repeat(257),
        )) {
            assertFalse(invalid, SharedTmuxWindowSizeReplay.confirms(7, requested, invalid))
        }
        assertThrows(IllegalArgumentException::class.java) {
            SharedTmuxWindowSizeReplay.confirms(-1, requested, reply)
        }
    }

    @Test
    fun ownershipProofAcceptsTheExactTwoClientsAndValidUnrelatedRows() {
        for (terminator in listOf("", "\n", "\r\n")) {
            assertTrue(provesOwnership(ownInventory + terminator))
        }
        assertTrue(provesOwnership(ownInventory.replace("\n", "\r\n")))
        assertTrue(provesOwnership("@8\tforeign\t13\t103\n$ownInventory"))
        assertTrue(SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
            windowId = 7,
            controlIdentity = "客户端|11|101",
            visibleIdentity = "visible|12|102",
            inventory = "@7\t客户端\t11\t101\n@7\tvisible\t12\t102",
        ))
    }

    @Test
    fun ownershipProofRejectsForeignClientsMalformedRowsAndDuplicateIdentities() {
        for (invalid in listOf(
            "",
            "@7\tcontrol\t11\t101",
            "@7\tcontrol\t11\t101\n@8\tvisible\t12\t102",
            "@7\tcontrol\t11\t101\n@7\tforeign\t13\t103",
            "$ownInventory\n@7\tforeign\t13\t103",
            "$ownInventory\n@7\tcontrol\t11\t101",
            "$ownInventory\n@8\tcontrol\t11\t101",
            "$ownInventory\n@8\tforeign\t13\t103\n@9\tforeign\t13\t103",
            "$ownInventory\n@8\tforeign\t13",
            "$ownInventory\n@8\tforeign\t13\t103\textra",
            "$ownInventory\n@8 foreign 13 103",
            "$ownInventory\n@8\\tforeign\\t13\\t103",
            "$ownInventory\n@8\tforeign\t013\t103",
            "$ownInventory\n@8\tforeign\t13\t0",
            "$ownInventory\n@8\tbad|name\t13\t103",
            "$ownInventory\n@8\tbad\u0000name\t13\t103",
            "$ownInventory\n\n",
        )) {
            assertFalse(invalid, provesOwnership(invalid))
        }
        assertFalse(SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
            7, "control|11|101", "control|11|101", ownInventory,
        ))
    }

    @Test
    fun ownershipProofComparesUtf8IdentityBytesWithoutUnicodeNormalization() {
        val composed = "\u00e9"
        val decomposed = "e\u0301"
        assertFalse(composed.encodeToByteArray().contentEquals(decomposed.encodeToByteArray()))
        assertFalse(SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
            7, "$composed|11|101", "visible|12|102",
            "@7\t$decomposed\t11\t101\n@7\tvisible\t12\t102",
        ))
        assertFalse(SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
            7, "$decomposed|11|101", "visible|12|102",
            "@7\t$composed\t11\t101\n@7\tvisible\t12\t102",
        ))
        assertTrue(SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
            7, "$composed|11|101", "$decomposed|11|101",
            "@7\t$composed\t11\t101\n@7\t$decomposed\t11\t101",
        ))
    }

    @Test
    fun ownershipProofEnforcesIdentityBoundsInUtf8Bytes() {
        for (name in listOf("x".repeat(252), "\u00e9".repeat(126))) {
            val identity = "$name|1|1"
            assertEquals(256, identity.encodeToByteArray().size)
            assertTrue(SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
                7, identity, "visible|12|102",
                "@7\t$name\t1\t1\n@7\tvisible\t12\t102",
            ))
            assertTrue(SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
                7, "control|11|101", identity,
                "@7\tcontrol\t11\t101\n@7\t$name\t1\t1",
            ))
            val oversizedName = "${name}x"
            val oversizedIdentity = "$oversizedName|1|1"
            assertEquals(257, oversizedIdentity.encodeToByteArray().size)
            assertFalse(SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
                7, oversizedIdentity, "visible|12|102",
                "@7\t$oversizedName\t1\t1\n@7\tvisible\t12\t102",
            ))
            assertFalse(SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
                7, "control|11|101", oversizedIdentity,
                "@7\tcontrol\t11\t101\n@7\t$oversizedName\t1\t1",
            ))
        }
    }

    @Test
    fun ownershipProofRejectsAnOversizedOtherwiseValidInventory() {
        val inventory = StringBuilder(ownInventory)
        var previousLength = inventory.length
        var pid = 100
        while (inventory.length <= 65_536) {
            previousLength = inventory.length
            inventory.append("\n@8\tforeign$pid\t$pid\t1")
            pid++
        }
        val inBounds = inventory.substring(0, previousLength)
        val oversized = inventory.toString()
        assertTrue(inBounds.encodeToByteArray().size <= 65_536)
        assertTrue(oversized.encodeToByteArray().size > 65_536)
        assertTrue(provesOwnership(inBounds))
        assertFalse(provesOwnership(oversized))
    }

    private fun provesOwnership(inventory: String): Boolean =
        SharedTmuxWindowSizeReplay.provesExclusiveOwnership(
            windowId = 7,
            controlIdentity = "control|11|101",
            visibleIdentity = "visible|12|102",
            inventory = inventory,
        )
}
