package com.bambouville.tessera.core.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** The host Swift library and production JNI glue, without an Android host. */
class SharedTmuxAuthorityScopeNativeTest {
    @Test fun inlineCommandsKeepTheirLegacySpellings() {
        assertEquals("show-options -qv @tessera_authority", SharedTmuxCommands.authorityQueryCommand())
        assertEquals(listOf("set-option @tessera_authority 'v1 M 2 iPhone'"), SharedTmuxCommands.authorityWriteCommands("v1 M 2 iPhone"))
    }
    @Test fun ownerCommandsTargetTheStampAndMirrorOnlyTheWrite() {
        assertEquals("display-message -p '#{S:#{?#{==:#{session_id},\$42},#{session_id}|#{@tessera_authority},}}'",
            SharedTmuxCommands.authorityQueryCommand(42))
        assertEquals(listOf("set-option -t '\$42' @tessera_authority 'v1 M 123456789012345 iPhone'", "set-option @tessera_authority 'v1 M 123456789012345 iPhone'"),
            SharedTmuxCommands.authorityWriteCommands("v1 M 123456789012345 iPhone", 42))
    }
    @Test fun authorityCommandsRejectSubscriptionRequests() {
        NativeLibraries.ensureLoaded()
        val request = """{"op":"subscription"}""".encodeToByteArray()
        assertThrows(IllegalArgumentException::class.java) {
            NativeCoreBindings.tmuxAuthorityCommands(request.toDirectBuffer(), request.size)
        }
    }
    @Test fun runtimeRequestsCrossJniAndReplaceTheWholeFeedSet() {
        val events = mutableListOf<SharedTmuxEvent>()
        val runtime = SharedTmuxRuntime.create { events += it }
        runtime.use {
            assertEquals(CoreCallResult.Accepted, runtime.setSubscriptions(SharedTmuxSubscriptions(
                bell = true, paneMetadata = true, windowOrder = true, authority = true,
            )))
            assertTrue(events.isEmpty())
            assertEquals(CoreCallResult.Accepted, runtime.feed(
                ("%session-changed \$7 work\r\n%begin 1 1 1\r\n" +
                    "__tessera_windows__\t@5\t0\t%7\t\t\t0\tmain\r\n%end 1 1 1\r\n").encodeToByteArray(),
            ))
            val initial = events.last().subscriptionCommands
            assertEquals("refresh-client -B 'tessera-authority:@5:#{@tessera_authority}'", initial.first())
            assertTrue(initial.last().contains("-B 'tessera-pane-meta.7:%7:"))
            assertTrue(initial.last().contains("-B 'tessera-bell.7:%7:#{window_bell_flag}'"))
            assertEquals(2, initial.size)
            assertTrue(initial.none { it.contains("tessera-window-order") || it.contains(":%*:") })

            assertEquals(CoreCallResult.Accepted, runtime.setSubscriptions(SharedTmuxSubscriptions(
                authority = true, authorityOwnerSessionId = 42,
            )))
            assertEquals(listOf(
                "refresh-client -B 'tessera-bell.7' -B 'tessera-pane-meta.7'",
                "refresh-client -B 'tessera-authority:@5:#{S:#{?#{==:#{session_id},\$42},#{@tessera_authority},}}'",
            ), events.last().subscriptionCommands)
            assertEquals(CoreCallResult.Accepted, runtime.setSubscriptions(SharedTmuxSubscriptions()))
            assertEquals(listOf("refresh-client -B 'tessera-authority'"), events.last().subscriptionCommands)
        }
        assertEquals(CoreCallResult.StaleHandle, runtime.setSubscriptions(SharedTmuxSubscriptions(authority = true)))
    }
    @Test fun ownerReadReplyCrossesJniAndTellsAKilledOwner() {
        assertEquals(listOf("v1 M 2 Pixel #2 \uD83D\uDE00"), SharedTmuxCommands.authorityQueryReplyLines(listOf("\$42|v1 M 2 Pixel #2 \uD83D\uDE00"), 42))
        assertEquals(emptyList<String>(), SharedTmuxCommands.authorityQueryReplyLines(listOf("\$42|"), 42))
        assertNull(SharedTmuxCommands.authorityQueryReplyLines(listOf(""), 42))
        assertNull(SharedTmuxCommands.authorityQueryReplyLines(listOf("\$4|v1 M 2 x"), 42))
        assertEquals(emptyList<String>(), SharedTmuxCommands.authorityQueryReplyLines(emptyList()))
        assertEquals(listOf("v1 M 2 x"), SharedTmuxCommands.authorityQueryReplyLines(listOf("v1 M 2 x")))
    }
    @Test fun ownerResolutionCrossesJniWithStrictFallbacks() {
        assertEquals(listOf("display-message -p -t '=o'\\''wn:' '#{session_id} #{session_group}'", "display-message -p '#{session_id} #{session_group}'"),
            SharedTmuxCommands.authorityOwnerResolutionCommands("o'wn"))
        assertEquals(0, SharedTmuxCommands.authorityResolveOwner(listOf("\$0 own"), listOf("\$1 own")))
        for (reply in listOf(null, emptyList(), listOf(""), listOf("\$0 "), listOf("\$0 other"), listOf("\$1 own"), listOf("\$0 own", "\$2 own"), listOf("\$-1 own"))) {
            assertNull(SharedTmuxCommands.authorityResolveOwner(reply, listOf("\$1 own")))
        }
        assertNull(SharedTmuxCommands.authorityResolveOwner(listOf("\$0 own"), null))
        // A named group may contain spaces; only the id ends at the first one.
        assertEquals(0, SharedTmuxCommands.authorityResolveOwner(listOf("\$0 work group"), listOf("\$1 work group")))
        assertNull(SharedTmuxCommands.authorityResolveOwner(listOf("\$0 work group"), listOf("\$1 work")))
    }
    @Test fun productionSessionSeedsTheEpochAndExplicitSeedKeepsTestsDeterministic() {
        SharedTmuxAuthoritySession.create().use { session ->
            val base = session.state.nextGeneration
            assertTrue(base > 0)
            assertTrue(base < (1L shl 53))
            assertEquals(0L, base and 4095L)
        }
        SharedTmuxAuthoritySession.create(initialGeneration = 4096).use { session ->
            session.attached(0, "SELF")
            val shown = session.shown(1)
            val id = (shown.effects.single() as SharedTmuxAuthoritySessionEffect.QueryAuthority).queryId
            session.queryReplied(2, id, "v1 PEER 7 iPhone", "SELF")
            assertEquals(4097L, session.state.claim?.generation)
        }
    }
}
