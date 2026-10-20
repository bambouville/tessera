package com.bambouville.tessera.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * Adapter-level only. The bar codec (defaults, stored-empty, unknown-ID
 * dropping, legacy migration) is now the shared core's, pinned by
 * `AccessoryKeyCatalogTests` on the Swift side; a JVM unit test cannot dlopen
 * the Android .so to reach it. What is still worth pinning here is the
 * vocabulary this adapter spells by hand: a typo in a canonical ID silently
 * drops a chip, because the shared codec drops unknown IDs individually.
 */
class AccessoryBarLayoutTest {
    @Test
    fun persistedIdsMatchTheSharedCatalogSpelling() {
        assertEquals(
            listOf(
                "esc", "enter", "ctrl", "tab", "left", "right", "down", "up", "alt",
                "ctrlC", "ctrlJ", "ctrlL",
                "shift", "home", "end", "pgup", "pgdn",
                "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
                "pipe", "tilde", "slash", "backslash", "dollar", "lbrace", "rbrace",
                "lbracket", "rbracket", "lt", "gt",
            ),
            AccessoryBarKey.entries.persistedAccessoryBarIds(),
        )
    }

    @Test
    fun everyPaletteGroupResolvesAndTogetherTheyCoverTheEnum() {
        val grouped = AccessoryBarKey.navigation + AccessoryBarKey.modifiers +
            AccessoryBarKey.controlShortcuts + AccessoryBarKey.functionKeys + AccessoryBarKey.symbols
        assertEquals(AccessoryBarKey.entries.size, grouped.distinct().size)
        grouped.forEach { key ->
            assertSame(key, AccessoryBarKey.fromPersisted(key.persistedId))
        }
    }

    @Test
    fun aLegacyOrUnknownIdIsNotAcceptedAsASecondVocabulary() {
        // "page-up" resolves only through the shared catalog's migration map,
        // never here — one wire name per key on this side of the bridge.
        assertNull(AccessoryBarKey.fromPersisted("page-up"))
        assertNull(AccessoryBarKey.fromPersisted("control-c"))
        assertNull(AccessoryBarKey.fromPersisted("cmd"))
    }
}
