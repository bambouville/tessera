package com.bambouville.tessera.feature.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TmuxRenderClientModeStoreTest {
    @Test
    fun bracketedPasteIsRestoredPerWindowAndPaneWithoutLeakingToNewOwners() {
        val store = TmuxRenderClientModeStore()

        store.save(windowId = 1, paneId = 11, bracketedPaste = true)
        store.save(windowId = 1, paneId = 12, bracketedPaste = false)
        store.save(windowId = 2, paneId = 21, bracketedPaste = true)

        assertTrue(store.bracketedPaste(windowId = 1, paneId = 11))
        assertFalse(store.bracketedPaste(windowId = 1, paneId = 12))
        assertTrue(store.bracketedPaste(windowId = 2, paneId = 21))
        assertFalse(store.bracketedPaste(windowId = 2, paneId = 22))
        assertFalse(store.bracketedPaste(windowId = 3, paneId = 11))
    }
}
