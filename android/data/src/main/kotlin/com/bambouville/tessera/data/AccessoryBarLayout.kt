package com.bambouville.tessera.data

import android.content.res.Configuration
import com.bambouville.tessera.core.bridge.SharedAccessoryBarDefaults
import com.bambouville.tessera.core.bridge.SharedInputEncoding

/**
 * Device-local software-keyboard accessory layout.
 *
 * The IDs are the shared catalog's canonical spellings — Swift authority
 * `Packages/TesseraCore/Sources/TesseraInputCore/AccessoryKeyCatalog.swift`,
 * reached through `SharedInputEncoding`. Android's older hyphenated spellings
 * ("page-up", "control-c") live on only inside the catalog's
 * `legacyAndroidIdMap`, which the shared bar codec applies on load, so a
 * layout stored by an earlier build migrates in place on first read.
 *
 * What stays here is presentation: which keys the palette groups together and
 * what each one is called on screen. Both the order codec and the chord
 * labels are asked of the shared core rather than restated.
 *
 * These IDs deliberately do not include hardware-keyboard commands: the row is
 * a touch/IME affordance. The catalog's `cmd` chip — which arms the app's own
 * shortcut dispatcher rather than sending bytes — has no Android peer for the
 * same reason, so it is absent from this enum and simply drops out of any
 * layout that names it.
 */
enum class AccessoryBarKey(
    val persistedId: String,
    /** Shown when the key is not a chord the shared renderer can spell. */
    private val fallbackLabel: String,
    private val chordModifiers: List<String> = emptyList(),
    private val chordKey: String? = null,
) {
    Escape("esc", "esc", chordKey = SharedInputEncoding.ChordToken.ESCAPE),
    Enter("enter", "↩", chordKey = SharedInputEncoding.ChordToken.RETURN),
    Control("ctrl", "⌃", chordModifiers = listOf(SharedInputEncoding.ChordToken.CONTROL)),
    Tab("tab", "⇥", chordKey = SharedInputEncoding.ChordToken.TAB),
    Left("left", "←", chordKey = SharedInputEncoding.ChordToken.LEFT),
    Right("right", "→", chordKey = SharedInputEncoding.ChordToken.RIGHT),
    Down("down", "↓", chordKey = SharedInputEncoding.ChordToken.DOWN),
    Up("up", "↑", chordKey = SharedInputEncoding.ChordToken.UP),
    Alt("alt", "⌥", chordModifiers = listOf(SharedInputEncoding.ChordToken.OPTION)),
    ControlC(
        "ctrlC",
        "⌃C",
        chordModifiers = listOf(SharedInputEncoding.ChordToken.CONTROL),
        chordKey = SharedInputEncoding.ChordToken.character('c'),
    ),
    ControlJ(
        "ctrlJ",
        "⌃J",
        chordModifiers = listOf(SharedInputEncoding.ChordToken.CONTROL),
        chordKey = SharedInputEncoding.ChordToken.character('j'),
    ),
    ControlL(
        "ctrlL",
        "⌃L",
        chordModifiers = listOf(SharedInputEncoding.ChordToken.CONTROL),
        chordKey = SharedInputEncoding.ChordToken.character('l'),
    ),
    Shift("shift", "⇧", chordModifiers = listOf(SharedInputEncoding.ChordToken.SHIFT)),
    Home("home", "home"),
    End("end", "end"),
    PageUp("pgup", "pgup"),
    PageDown("pgdn", "pgdn"),
    F1("f1", "F1"), F2("f2", "F2"), F3("f3", "F3"), F4("f4", "F4"),
    F5("f5", "F5"), F6("f6", "F6"), F7("f7", "F7"), F8("f8", "F8"),
    F9("f9", "F9"), F10("f10", "F10"), F11("f11", "F11"), F12("f12", "F12"),
    Pipe("pipe", "|"), Tilde("tilde", "~"), Slash("slash", "/"), Backslash("backslash", "\\"),
    Dollar("dollar", "$"), LeftBrace("lbrace", "{"), RightBrace("rbrace", "}"),
    LeftBracket("lbracket", "["), RightBracket("rbracket", "]"),
    LessThan("lt", "<"), GreaterThan("gt", ">"),
    ;

    /** The modifier this chip arms, or null for a chip that sends bytes. */
    val armsModifier: com.bambouville.tessera.core.bridge.SharedModifierName?
        get() = when (this) {
            Control -> com.bambouville.tessera.core.bridge.SharedModifierName.Control
            Alt -> com.bambouville.tessera.core.bridge.SharedModifierName.Alternate
            Shift -> com.bambouville.tessera.core.bridge.SharedModifierName.Shift
            else -> null
        }

    /**
     * The on-screen label in one notation. Display only: nothing this returns
     * reaches the wire, which is the separation the shared chord renderer
     * exists to hold — bytes come from the catalog ID, never from a label.
     */
    fun label(notation: SharedInputEncoding.ChordNotation): String =
        if (chordModifiers.isEmpty() && chordKey == null) {
            fallbackLabel
        } else {
            SharedInputEncoding.renderChord(notation, chordModifiers, chordKey)
        }

    companion object {
        val navigation = listOf(Escape, Enter, Tab, Left, Down, Up, Right, Home, End, PageUp, PageDown)
        val modifiers = listOf(Control, Alt, Shift)
        val controlShortcuts = listOf(ControlC, ControlJ, ControlL)
        val functionKeys = listOf(F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12)
        val symbols = listOf(
            Pipe, Tilde, Slash, Backslash, Dollar, LeftBrace, RightBrace,
            LeftBracket, RightBracket, LessThan, GreaterThan,
        )

        fun fromPersisted(id: String): AccessoryBarKey? = entries.firstOrNull { it.persistedId == id }

        /**
         * Resolves a stored layout through the shared bar codec.
         *
         * [stored] is null when the user never edited the bar — that is the
         * distinction the codec exists to preserve, and it is not the same as
         * a stored empty list, which is a deliberately empty row and stays
         * empty. Unknown IDs are dropped individually rather than costing the
         * whole bar; the older Kotlin "anything non-empty that normalizes to
         * empty falls back to defaults" rule is deliberately abandoned, since
         * a row of only unrecognised slots is still a row the user chose.
         *
         * Legacy Android IDs migrate in the same pass. `custom:<uuid>` slots
         * survive the codec but have no Android chip yet, so they drop out
         * here rather than rendering as a blank key.
         */
        fun resolve(
            stored: List<String>?,
            defaults: SharedAccessoryBarDefaults = SharedAccessoryBarDefaults.Phone,
        ): List<AccessoryBarKey> = SharedInputEncoding
            .accessoryBarOrder(stored, defaults)
            .ids
            .mapNotNull(::fromPersisted)
            .distinct()

        /** The platform default row, straight from the shared catalog. */
        fun defaultOrder(
            defaults: SharedAccessoryBarDefaults = SharedAccessoryBarDefaults.Phone,
        ): List<AccessoryBarKey> = resolve(null, defaults)

        /** Every label in one notation, computed once so a row does not pay per chip. */
        fun labels(notation: SharedInputEncoding.ChordNotation): Map<AccessoryBarKey, String> =
            entries.associateWith { it.label(notation) }
    }
}

fun List<AccessoryBarKey>.persistedAccessoryBarIds(): List<String> = map(AccessoryBarKey::persistedId)

/**
 * Whether this configuration is a tablet layout.
 *
 * Both the tmux peer label and the default accessory row ask this, and a
 * device that is a tablet for one and a phone for the other would be a bug
 * nobody would think to look for — so there is one predicate.
 */
fun Configuration.isTabletLayout(): Boolean =
    smallestScreenWidthDp >= TABLET_SMALLEST_WIDTH_DP ||
        screenLayout and Configuration.SCREENLAYOUT_SIZE_MASK >= Configuration.SCREENLAYOUT_SIZE_LARGE

/**
 * Which default row a bar that was never edited gets, chosen the way iOS
 * chooses it.
 *
 * `AccessoryChip.defaultBarOrder(for:)` picks by `UIUserInterfaceIdiom`, and
 * the two rows genuinely differ — the phone row carries ⌃C / ⌃J / ⌃L where the
 * wide row carries | and ~ — so a tablet handed the phone row is a real
 * divergence rather than a cosmetic one. The shared core has carried the
 * tablet order since the catalog was shared and Android's own instrumented
 * test reads it, but no production call site ever asked for it.
 */
fun Configuration.accessoryBarDefaults(): SharedAccessoryBarDefaults =
    if (isTabletLayout()) SharedAccessoryBarDefaults.Tablet else SharedAccessoryBarDefaults.Phone

const val TABLET_SMALLEST_WIDTH_DP = 600
