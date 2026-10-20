package com.bambouville.tessera.core.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM unit tests load the shared Swift core built for this machine
 * (`:core-bridge:buildHostCore`), through the same JNI shim as the app.
 */
class HostNativeCoreTest {
    @Test
    fun theAuthoritySessionReducesThroughTheNativeCore() {
        SharedTmuxAuthoritySession.create().use { session ->
            val attached = session.attached(nowMillis = 0)
            assertTrue(attached.state.hasAttached)
            assertTrue(attached.state.channelAttached)

            val peer = session.observedAuthority(1, SharedTmuxGridAuthoritySnapshot.Peer("ipad", "iPad", 7))
            assertEquals(SharedTmuxGridAuthoritySnapshot.Peer("ipad", "iPad", 7), peer.state.authority)
        }
    }

    @Test
    fun aCompactClientTakesTheViewportOfASinglePane() {
        val viewport = SharedTmuxGridSize(columns = 50, rows = 30)
        assertEquals(
            viewport,
            SharedTmuxGeometry.compactClientSize(
                viewport = viewport, layout = null, focusPaneId = null, window = null, focus = null,
            ),
        )
    }
}
