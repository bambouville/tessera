package com.bambouville.tessera.core.bridge

import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject

/**
 * Terminal input, owned by `TesseraInputCore`.
 *
 * Swift authority: `Packages/TesseraCore/Sources/TesseraInputCore/` —
 * `AccessoryKeyCatalog`, `TerminalKeySequenceEncoder`,
 * `TerminalSoftwareModifierEncoder`, `TerminalMouseSequenceEncoder`,
 * `KeyChordNotation`, `ModifierArming`. The ABI seam is
 * `Sources/TesseraCoreABI/InputABI.swift`.
 *
 * Bytes are never derived from a label here. Every chip resolves through the
 * catalog by canonical ID, which is how Shift+Tab finally emits backtab on
 * this platform too.
 */

/** Modifier flags, matching `TESSERA_INPUT_MODIFIER_*` in TesseraCoreABI.h. */
object SharedTerminalModifiers {
    const val CONTROL = 1
    const val ALTERNATE = 2
    const val SHIFT = 4

    /**
     * Command arms the app's own shortcut dispatcher and reaches no terminal
     * encoding. It is representable so a full chord can round-trip, but the
     * shared encoders strip it before producing bytes.
     */
    const val COMMAND = 8

    fun bits(
        control: Boolean = false,
        alternate: Boolean = false,
        shift: Boolean = false,
        command: Boolean = false,
    ): Int = (if (control) CONTROL else 0) or
        (if (alternate) ALTERNATE else 0) or
        (if (shift) SHIFT else 0) or
        (if (command) COMMAND else 0)
}

/** Sticky vs one-shot, matching Swift `ModifierBehaviorMode`. */
enum class SharedModifierBehavior(val wireValue: String) {
    OneShot("oneShot"),
    Sticky("sticky");

    companion object {
        fun fromWire(value: String): SharedModifierBehavior =
            entries.firstOrNull { it.wireValue == value }
                ?: throw IllegalArgumentException("unknown shared modifier behavior")
    }
}

/** One armed modifier set, matching Swift `TerminalModifiers`. */
data class SharedArmedModifiers(
    val control: Boolean = false,
    val alternate: Boolean = false,
    val shift: Boolean = false,
    val command: Boolean = false,
) {
    val bits: Int
        get() = SharedTerminalModifiers.bits(control, alternate, shift, command)

    internal fun toJson(): JSONObject = JSONObject()
        .put("ctrl", control)
        .put("alt", alternate)
        .put("shift", shift)
        .put("cmd", command)

    internal companion object {
        fun fromJson(value: JSONObject): SharedArmedModifiers = SharedArmedModifiers(
            control = value.getBoolean("ctrl"),
            alternate = value.getBoolean("alt"),
            shift = value.getBoolean("shift"),
            command = value.getBoolean("cmd"),
        )
    }
}

/** Armed set plus the rule for how long it survives; Swift `ModifierArming`. */
data class SharedModifierArming(
    val behavior: SharedModifierBehavior = SharedModifierBehavior.OneShot,
    val armed: SharedArmedModifiers = SharedArmedModifiers(),
) {
    internal fun toJson(): JSONObject = JSONObject()
        .put("behavior", behavior.wireValue)
        .put("armed", armed.toJson())

    internal companion object {
        fun fromJson(value: JSONObject): SharedModifierArming = SharedModifierArming(
            behavior = SharedModifierBehavior.fromWire(value.getString("behavior")),
            armed = SharedArmedModifiers.fromJson(value.getJSONObject("armed")),
        )
    }
}

/** What one arming transition produced. */
data class SharedModifierArmingOutcome(
    val state: SharedModifierArming,
    /**
     * The snapshot `consume` returned — what the key that triggered the
     * transition should be encoded with. Null for tap and cancel.
     */
    val consumed: SharedArmedModifiers?,
    /** The post-transition armed set minus Command. */
    val wireModifiers: SharedArmedModifiers,
    val isCommandArmed: Boolean,
    val isAnyArmed: Boolean,
    /**
     * The app-shortcut key a supplied key event becomes while Command is
     * armed, or null when the event belongs on the wire instead.
     */
    val commandChordKey: String?,
)

/** The canonical accessory-key catalog. */
data class SharedAccessoryKeyCatalog(
    val ids: List<String>,
    val modifierIds: List<String>,
    val defaultPhoneBarOrder: List<String>,
    val defaultTabletBarOrder: List<String>,
    val customIdPrefix: String,
    /** Legacy Android persisted id -> canonical catalog id. */
    val legacyAndroidIdMap: Map<String, String>,
)

/** A resolved accessory bar order. */
data class SharedAccessoryBarOrder(
    val ids: List<String>,
    /** True when nothing was stored and the platform default was used. */
    val usedDefaults: Boolean,
)

/** Which default order a form factor starts from. */
enum class SharedAccessoryBarDefaults(val wireValue: String) {
    Phone("phone"),
    Tablet("tablet"),
}

/** Pointer button, matching Swift `TerminalMouseButtonName`. */
enum class SharedMouseButton(val wireValue: String) {
    Primary("primary"),
    Middle("middle"),
    Secondary("secondary"),
}

/** Wheel direction, matching Swift `TerminalWheelDirectionName`. */
enum class SharedWheelDirection(val wireValue: String) {
    Up("up"),
    Down("down"),
    Left("left"),
    Right("right"),
}

/** xterm wire form, matching Swift `TerminalMouseEncoding`. */
enum class SharedMouseEncoding(val wireValue: String) {
    None("none"),
    X10("x10"),
    Sgr("sgr"),
}

/** One neutral pointer event. */
sealed interface SharedMouseEvent {
    val column: Int
    val row: Int
    val modifiers: SharedArmedModifiers

    data class Button(
        val button: SharedMouseButton,
        val pressed: Boolean,
        override val column: Int,
        override val row: Int,
        override val modifiers: SharedArmedModifiers = SharedArmedModifiers(),
    ) : SharedMouseEvent

    data class Motion(
        val button: SharedMouseButton?,
        override val column: Int,
        override val row: Int,
        override val modifiers: SharedArmedModifiers = SharedArmedModifiers(),
    ) : SharedMouseEvent

    data class Wheel(
        val direction: SharedWheelDirection,
        override val column: Int,
        override val row: Int,
        override val modifiers: SharedArmedModifiers = SharedArmedModifiers(),
    ) : SharedMouseEvent
}

/** Typed facade over `Sources/TesseraCoreABI/InputABI.swift`. */
object SharedInputEncoding {
    /** Notation for a rendered chord label; Swift `KeyChordNotation`. */
    enum class ChordNotation(val wireValue: String) {
        /** `⌘⇧E` — Mac glyphs, concatenated. */
        Glyph("glyph"),

        /** `cmd-shift-e` — short lowercase words, hyphen-joined. */
        Words("words"),
    }

    /**
     * One chord token. Modifiers use their names; a literal key is `c:<char>`.
     * These spellings are Swift `KeyChordToken`'s own stable wire form and are
     * what gets written into a user's stored bindings.
     */
    object ChordToken {
        const val COMMAND = "command"
        const val OPTION = "option"
        const val CONTROL = "control"
        const val SHIFT = "shift"
        const val TAB = "tab"
        const val RETURN = "ret"
        const val DELETE = "del"
        const val ESCAPE = "esc"
        const val SPACE = "space"
        const val LEFT = "left"
        const val DOWN = "down"
        const val UP = "up"
        const val RIGHT = "right"

        fun character(value: Char): String = "c:$value"
    }

    /**
     * The bytes one accessory chip sends, or null for a modifier chip — those
     * arm state through [modifierArmingTransition] and send nothing.
     *
     * [id] must be a canonical catalog id. Migrate a stored legacy Android
     * spelling through [catalog]'s `legacyAndroidIdMap` first (or let
     * [accessoryBarOrder] do it).
     */
    fun encodeAccessoryKey(
        id: String,
        modifiers: SharedArmedModifiers = SharedArmedModifiers(),
        applicationCursorMode: Boolean = false,
    ): ByteArray? {
        require(id.isNotBlank())
        NativeLibraries.ensureLoaded()
        val bytes = id.encodeToByteArray()
        return try {
            NativeCoreBindings.inputEncodeAccessoryKey(
                bytes.toDirectBuffer(),
                bytes.size,
                modifiers.bits,
                applicationCursorMode,
            )
        } catch (error: IllegalArgumentException) {
            null
        }
    }

    /**
     * Applies armed software modifiers to an ordinary typed key event: Ctrl +
     * Space becomes NUL, Ctrl + `?` becomes DEL, Alt adds an ESC prefix, Shift
     * applies the US-layout shifted byte.
     *
     * Multi-byte payloads — pastes and composed IME commits — pass through
     * unchanged, so a one-shot modifier is not spent on a paste.
     */
    fun applySoftwareModifiers(input: ByteArray, modifiers: SharedArmedModifiers): ByteArray {
        require(input.isNotEmpty())
        NativeLibraries.ensureLoaded()
        return NativeCoreBindings.inputApplySoftwareModifiers(
            input.toDirectBuffer(),
            input.size,
            modifiers.bits,
        )
    }

    /**
     * The xterm wire bytes for one pointer event. An encoding of
     * [SharedMouseEncoding.None] correctly produces an empty array: mouse
     * reporting is off.
     */
    fun encodeMouseEvent(event: SharedMouseEvent, encoding: SharedMouseEncoding): ByteArray {
        NativeLibraries.ensureLoaded()
        val payload = JSONObject().put("encoding", encoding.wireValue)
        val body = JSONObject()
            .put("column", event.column)
            .put("row", event.row)
            .put("modifiers", event.modifiers.toJson())
        when (event) {
            is SharedMouseEvent.Button -> body
                .put("kind", "button")
                .put("button", event.button.wireValue)
                .put("action", if (event.pressed) "press" else "release")
            is SharedMouseEvent.Motion -> {
                body.put("kind", "motion")
                event.button?.let { body.put("button", it.wireValue) }
            }
            is SharedMouseEvent.Wheel -> body
                .put("kind", "wheel")
                .put("direction", event.direction.wireValue)
        }
        val encoded = payload.put("event", body).toString().encodeToByteArray()
        return NativeCoreBindings.inputEncodeMouseEvent(encoded.toDirectBuffer(), encoded.size)
    }

    /**
     * The canonical catalog. Read it rather than keeping a second local list —
     * a hand-written copy is how "page-up" and "pgup" came to name one key.
     */
    fun catalog(): SharedAccessoryKeyCatalog {
        NativeLibraries.ensureLoaded()
        val value = JSONObject(NativeCoreBindings.inputAccessoryCatalog())
        fun ids(key: String): List<String> = value.getJSONArray(key).let { array ->
            List(array.length()) { array.getString(it) }
        }
        val legacy = value.getJSONObject("legacyAndroidIDMap")
        return SharedAccessoryKeyCatalog(
            ids = ids("ids"),
            modifierIds = ids("modifierIDs"),
            defaultPhoneBarOrder = ids("defaultPhoneBarOrder"),
            defaultTabletBarOrder = ids("defaultTabletBarOrder"),
            customIdPrefix = value.getString("customIDPrefix"),
            legacyAndroidIdMap = buildMap {
                legacy.keys().forEach { key -> put(key, legacy.getString(key)) }
            },
        )
    }

    /**
     * Resolves a stored bar order into canonical slot ids, migrating legacy
     * Android spellings in the same pass.
     *
     * The distinction this preserves, and which the previous Kotlin codec lost:
     * [stored] null means the user never touched the bar and gets the platform
     * default; a stored EMPTY list is a deliberately empty row and stays empty.
     * Unknown ids are dropped individually rather than costing the whole bar.
     */
    fun accessoryBarOrder(
        stored: List<String>?,
        defaults: SharedAccessoryBarDefaults,
    ): SharedAccessoryBarOrder {
        NativeLibraries.ensureLoaded()
        val request = JSONObject()
            .put("defaults", defaults.wireValue)
            .put(
                "stored",
                stored?.let { entries -> JSONArray().also { entries.forEach(it::put) } }
                    ?: JSONObject.NULL,
            )
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.inputAccessoryBarOrder(request.toDirectBuffer(), request.size),
        )
        val ids = value.getJSONArray("ids")
        return SharedAccessoryBarOrder(
            ids = List(ids.length()) { ids.getString(it) },
            usedDefaults = value.getBoolean("usedDefaults"),
        )
    }

    /**
     * A chord label. Display only — nothing this returns reaches the wire,
     * which is the invariant the shared notation type exists to hold.
     *
     * [modifiers] and [key] are [ChordToken] values.
     */
    fun renderChord(
        notation: ChordNotation,
        modifiers: List<String>,
        key: String?,
    ): String {
        require(modifiers.isNotEmpty() || key != null) { "a chord needs at least one token" }
        NativeLibraries.ensureLoaded()
        val chord = JSONObject()
            .put("modifiers", JSONArray().also { array -> modifiers.forEach(array::put) })
            .put("key", key ?: JSONObject.NULL)
        val request = JSONObject()
            .put("notation", notation.wireValue)
            .put("chord", chord)
            .toString()
            .encodeToByteArray()
        return NativeCoreBindings.inputRenderChord(request.toDirectBuffer(), request.size)
    }

    /**
     * Applies one arming transition. Pure state-in/state-out, so this side can
     * hold the state in whatever observable it likes without the core keeping
     * a second copy.
     *
     * [keyBytes] is optional: supplying the key event being dispatched fills
     * [SharedModifierArmingOutcome.commandChordKey].
     */
    fun modifierArmingTransition(
        state: SharedModifierArming,
        event: SharedModifierArmingEvent,
        keyBytes: ByteArray? = null,
    ): SharedModifierArmingOutcome {
        NativeLibraries.ensureLoaded()
        val body = JSONObject().put("kind", event.kind)
        event.modifier?.let { body.put("modifier", it) }
        val request = JSONObject()
            .put("state", state.toJson())
            .put("event", body)
            .put(
                "keyBytes",
                keyBytes?.let { Base64.encodeToString(it, Base64.NO_WRAP) }
                    ?: JSONObject.NULL,
            )
            .toString()
            .encodeToByteArray()
        val value = JSONObject(
            NativeCoreBindings.inputModifierArmingTransition(
                request.toDirectBuffer(),
                request.size,
            ),
        )
        return SharedModifierArmingOutcome(
            state = SharedModifierArming.fromJson(value.getJSONObject("state")),
            consumed = if (value.isNull("consumed")) {
                null
            } else {
                SharedArmedModifiers.fromJson(value.getJSONObject("consumed"))
            },
            wireModifiers = SharedArmedModifiers.fromJson(value.getJSONObject("wireModifiers")),
            isCommandArmed = value.getBoolean("isCommandArmed"),
            isAnyArmed = value.getBoolean("isAnyArmed"),
            commandChordKey = if (value.isNull("commandChordKey")) {
                null
            } else {
                value.getString("commandChordKey")
            },
        )
    }
}

/** One arming transition: tap a modifier, consume, or cancel. */
sealed class SharedModifierArmingEvent(
    internal val kind: String,
    internal val modifier: String?,
) {
    /** Toggles one modifier. Tapping an armed modifier disarms it. */
    class Tap(modifier: SharedModifierName) : SharedModifierArmingEvent("tap", modifier.wireValue)

    /** A key was dispatched: one-shot clears, sticky keeps. */
    data object Consume : SharedModifierArmingEvent("consume", null)

    /** Clears regardless of behavior — the escape hatch out of a sticky chord. */
    data object Cancel : SharedModifierArmingEvent("cancel", null)
}

/** Modifier names on the wire, matching Swift `TerminalModifier`. */
enum class SharedModifierName(val wireValue: String) {
    Control("control"),
    Alternate("alternate"),
    Shift("shift"),
    Command("command"),
}

/** Matches `TESSERA_INPUT_SCROLL_ROUTE_*` and Swift `TerminalScrollRoute`. */
enum class SharedScrollRoute(val wireValue: Int) {
    /** Move the local transcript (on mosh+tmux, the capture-pane overlay). */
    LocalScrollback(0),
    /** Report mouse-wheel ticks to the remote program. */
    MouseWheel(1),
    /** Arrow keys for a full-screen program without a mouse mode. */
    ArrowKeys(2),
}

/**
 * Where one scroll gesture goes, owned by `TerminalScrollRouting` in
 * `TesseraInputCore` — the same rule the iOS dispatcher applies. The screen
 * decides, never mouse tracking alone: on mosh+tmux the visible client sits on
 * the primary screen with the server's `mouse on` in force (mosh never relays
 * the alternate screen), and a wheel report there puts tmux into copy-mode
 * instead of moving the overlay the side channel painted.
 *
 * `mouseReportingImpliesAltScreen` is the session's one input: true only while
 * it has no local scrollback to offer (plain mosh, or mosh+tmux before its
 * pane grid), so a remote program that asked for the mouse still gets the
 * wheel.
 */
object SharedScrollRouting {
    @JvmStatic
    fun route(
        bufferIsAlternate: Boolean,
        mouseReporting: Boolean,
        mouseReportingImpliesAltScreen: Boolean,
    ): SharedScrollRoute {
        NativeLibraries.ensureLoaded()
        val code = NativeCoreBindings.inputScrollRoute(
            bufferIsAlternate,
            mouseReporting,
            mouseReportingImpliesAltScreen,
        )
        return SharedScrollRoute.values().firstOrNull { it.wireValue == code }
            ?: throw IllegalStateException("shared core rejected scroll routing inputs: $code")
    }
}
