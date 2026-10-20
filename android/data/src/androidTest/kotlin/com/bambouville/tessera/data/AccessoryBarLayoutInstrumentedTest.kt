package com.bambouville.tessera.data

import android.content.res.Configuration
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bambouville.tessera.core.bridge.SharedAccessoryBarDefaults
import com.bambouville.tessera.core.bridge.SharedArmedModifiers
import com.bambouville.tessera.core.bridge.SharedInputEncoding
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The bar adapter against the real shared catalog. This has to be an
 * instrumented test: every `SharedInputEncoding` entry point loads the
 * native library, which a JVM unit test cannot do.
 *
 * The encoder's own behavior is pinned in Swift
 * (`Packages/TesseraCore/Tests/TesseraInputCoreTests`). What is pinned here is
 * the seam: that this platform's IDs are the catalog's IDs, that a layout
 * stored under the old hyphenated spellings still resolves, and that the
 * chips now reach the shared encoder rather than a local copy of it.
 */
@RunWith(AndroidJUnit4::class)
class AccessoryBarLayoutInstrumentedTest {
    @Test
    fun everyChipIdIsAKnownCatalogId() {
        val catalog = SharedInputEncoding.catalog()
        AccessoryBarKey.entries.forEach { key ->
            assertTrue(
                "${key.name} spells an ID the catalog does not know, so its chip would vanish",
                key.persistedId in catalog.ids,
            )
        }
    }

    @Test
    fun everyCatalogKeyExceptCommandHasAChip() {
        // `everyChipIdIsAKnownCatalogId` catches a typo on this side. This is
        // the direction that catches the other drift: a key added to the shared
        // catalog and given an iOS chip but never an Android one. Nothing fails
        // when that happens — the key is simply missing from one platform's
        // palette — which is exactly why it needs an assertion.
        val catalog = SharedInputEncoding.catalog()
        assertEquals(
            "cmd is the single deliberate omission: it arms the app's own shortcut " +
                "dispatcher rather than sending bytes, and the Android row is a " +
                "touch/IME affordance with no hardware-keyboard commands on it",
            catalog.ids.filterNot { it == "cmd" }.toSet(),
            AccessoryBarKey.entries.map(AccessoryBarKey::persistedId).toSet(),
        )
    }

    @Test
    fun theIdiomPicksTheDefaultRowTheWayItDoesOnIos() {
        val phone = Configuration().apply {
            smallestScreenWidthDp = 411
            screenLayout = Configuration.SCREENLAYOUT_SIZE_NORMAL
        }
        val tablet = Configuration().apply {
            smallestScreenWidthDp = 800
            screenLayout = Configuration.SCREENLAYOUT_SIZE_NORMAL
        }
        assertEquals(SharedAccessoryBarDefaults.Phone, phone.accessoryBarDefaults())
        assertEquals(SharedAccessoryBarDefaults.Tablet, tablet.accessoryBarDefaults())
        // A large-layout device under the 600dp line is still a tablet, which is
        // the half of the test the smallest-width check alone would miss.
        val largeLayout = Configuration().apply {
            smallestScreenWidthDp = 480
            screenLayout = Configuration.SCREENLAYOUT_SIZE_LARGE
        }
        assertEquals(SharedAccessoryBarDefaults.Tablet, largeLayout.accessoryBarDefaults())
        assertEquals(
            AccessoryBarKey.defaultOrder(SharedAccessoryBarDefaults.Tablet),
            AccessoryBarKey.resolve(null, tablet.accessoryBarDefaults()),
        )
    }

    @Test
    fun modifierChipsAreExactlyTheCatalogsModifiersMinusCommand() {
        val catalog = SharedInputEncoding.catalog()
        val chipModifiers = AccessoryBarKey.entries.filter { it.armsModifier != null }
        assertEquals(
            catalog.modifierIds.filterNot { it == "cmd" }.toSet(),
            chipModifiers.map(AccessoryBarKey::persistedId).toSet(),
        )
        chipModifiers.forEach { key ->
            assertNull(
                "a modifier arms state and must send nothing",
                SharedInputEncoding.encodeAccessoryKey(key.persistedId),
            )
        }
    }

    @Test
    fun everyNonModifierChipEncodesThroughTheSharedCatalog() {
        AccessoryBarKey.entries.filter { it.armsModifier == null }.forEach { key ->
            val bytes = SharedInputEncoding.encodeAccessoryKey(key.persistedId)
            assertNotNull("${key.name} produced no bytes", bytes)
            assertTrue("${key.name} produced an empty sequence", bytes!!.isNotEmpty())
        }
    }

    @Test
    fun shiftTabFinallyEmitsBacktabOnThisPlatform() {
        // The old Kotlin encoder had no Shift+Tab case and sent a bare HT.
        assertArrayEquals(
            byteArrayOf(0x1b, 0x5b, 0x5a),
            SharedInputEncoding.encodeAccessoryKey(
                id = AccessoryBarKey.Tab.persistedId,
                modifiers = SharedArmedModifiers(shift = true),
            ),
        )
    }

    @Test
    fun aLayoutStoredUnderTheOldHyphenatedIdsMigratesOnLoad() {
        assertEquals(
            listOf(
                AccessoryBarKey.PageUp,
                AccessoryBarKey.ControlC,
                AccessoryBarKey.Escape,
                AccessoryBarKey.LeftBracket,
            ),
            AccessoryBarKey.resolve(listOf("page-up", "control-c", "escape", "left-bracket")),
        )
    }

    @Test
    fun nothingStoredTakesTheDefaultWhileAStoredEmptyRowStaysEmpty() {
        assertEquals(AccessoryBarKey.defaultOrder(), AccessoryBarKey.resolve(null))
        assertEquals(emptyList<AccessoryBarKey>(), AccessoryBarKey.resolve(emptyList()))
        // The abandoned rule: a row of nothing but unrecognised slots used to
        // fall back to the defaults, resurrecting chips the user removed.
        assertEquals(emptyList<AccessoryBarKey>(), AccessoryBarKey.resolve(listOf("nonsense")))
        assertEquals(
            listOf(AccessoryBarKey.Up, AccessoryBarKey.Escape),
            AccessoryBarKey.resolve(listOf("up", "nonsense", "escape", "up")),
        )
    }

    @Test
    fun theTabletDefaultIsAvailableAndDiffersFromThePhoneRow() {
        val phone = AccessoryBarKey.defaultOrder(SharedAccessoryBarDefaults.Phone)
        val tablet = AccessoryBarKey.defaultOrder(SharedAccessoryBarDefaults.Tablet)
        assertEquals(
            listOf(
                "esc", "enter", "ctrl", "tab", "left", "right", "down", "up", "alt",
                "ctrlC", "ctrlJ", "ctrlL",
            ),
            phone.persistedAccessoryBarIds(),
        )
        assertTrue(tablet != phone)
    }

    @Test
    fun notationChangesEveryLabelAndNeverTheBytes() {
        val glyph = AccessoryBarKey.labels(SharedInputEncoding.ChordNotation.Glyph)
        val words = AccessoryBarKey.labels(SharedInputEncoding.ChordNotation.Words)
        assertEquals("⌃C", glyph[AccessoryBarKey.ControlC])
        assertEquals("ctrl-c", words[AccessoryBarKey.ControlC])
        assertEquals("⇥", glyph[AccessoryBarKey.Tab])
        assertEquals("tab", words[AccessoryBarKey.Tab])
        // A key with no chord spelling keeps its own label in both notations.
        assertEquals("F5", glyph[AccessoryBarKey.F5])
        assertEquals("F5", words[AccessoryBarKey.F5])
        // Return has a chord spelling with no modifier, so it follows the
        // notation too rather than being spelled a second way here.
        assertEquals("↩", glyph[AccessoryBarKey.Enter])
        assertEquals("ret", words[AccessoryBarKey.Enter])
        assertArrayEquals(
            SharedInputEncoding.encodeAccessoryKey(AccessoryBarKey.ControlC.persistedId),
            byteArrayOf(0x03),
        )
    }
}
