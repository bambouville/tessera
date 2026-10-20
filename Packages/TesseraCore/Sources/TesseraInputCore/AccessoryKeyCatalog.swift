// Packages/TesseraCore/Sources/TesseraInputCore/AccessoryKeyCatalog.swift
// The canonical accessory-bar key catalog: which keys exist, what they are
// called in storage, which order a fresh bar ships in, and — through
// `TerminalKeySequenceEncoder` — exactly what each one puts on the wire.
//
// The IDs are the Apple `AccessoryChip` raw values, because those are what is
// already written into users' `accessoryBarKeys` arrays. Android's older
// hyphenated spellings ("page-up", "control-c") are recorded as data in
// `legacyAndroidIDMap` rather than accepted as a second vocabulary: one wire
// name per key, one migration table.
//
// Bytes are never derived from a label. `AccessoryKeyCatalog.encode` keys off
// the catalog ID and routes every key through `TerminalKeySequenceEncoder`, so
// a display-notation preference cannot change what a chip sends.

/// A built-in accessory-bar key. Raw values are the persisted catalog IDs and
/// match `AccessoryChip.rawValue` on Apple platforms case for case.
public enum AccessoryKey: String, CaseIterable, Hashable, Codable, Sendable {
    // navigation
    case left, down, up, right, home, end, pgup, pgdn, tab
    // modifiers
    case ctrl, alt, shift
    /// Command. Unlike the other three this sends nothing to the remote — no
    /// terminal encoding carries ⌘ — it arms the app's own shortcut dispatcher
    /// so the next key runs an app action. `encode` returns nil for it, as it
    /// does for every modifier.
    case cmd
    // simple key-bytes modifiers
    case esc
    /// Return. The bar carries it because a software keyboard's own Return is
    /// out of reach whenever the keyboard is down, which is most of the time
    /// on a phone driving a TUI.
    case enter
    case ctrlC, ctrlJ, ctrlL
    // function keys
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    // symbols
    case pipe, tilde, slash, backslash, dollar, lbrace, rbrace, lbracket, rbracket, lt, gt

    /// Modifier keys arm state instead of sending bytes.
    public var isModifier: Bool { modifier != nil }

    /// The modifier this key arms, or nil for a key that produces bytes.
    public var modifier: TerminalModifier? {
        switch self {
        case .ctrl: .control
        case .alt: .alternate
        case .shift: .shift
        case .cmd: .command
        default: nil
        }
    }

    /// The portable terminal key this chip stands for, or nil for a modifier.
    public var terminalKey: TerminalKey? {
        switch self {
        case .ctrl, .alt, .shift, .cmd: nil
        case .esc: .escape
        case .enter: .enter
        case .ctrlJ: .controlJ
        case .ctrlC: .controlC
        case .ctrlL: .controlL
        case .tab: .tab
        case .left: .left
        case .down: .down
        case .up: .up
        case .right: .right
        case .home: .home
        case .end: .end
        case .pgup: .pageUp
        case .pgdn: .pageDown
        case .f1: .f1
        case .f2: .f2
        case .f3: .f3
        case .f4: .f4
        case .f5: .f5
        case .f6: .f6
        case .f7: .f7
        case .f8: .f8
        case .f9: .f9
        case .f10: .f10
        case .f11: .f11
        case .f12: .f12
        case .pipe: .pipe
        case .tilde: .tilde
        case .slash: .slash
        case .backslash: .backslash
        case .dollar: .dollar
        case .lbrace: .leftBrace
        case .rbrace: .rightBrace
        case .lbracket: .leftBracket
        case .rbracket: .rightBracket
        case .lt: .lessThan
        case .gt: .greaterThan
        }
    }
}

public enum AccessoryKeyCatalog {
    /// Every built-in key, in palette order.
    public static var allKeys: [AccessoryKey] { AccessoryKey.allCases }

    /// Every built-in catalog ID, in palette order.
    public static var allIDs: [String] { AccessoryKey.allCases.map(\.rawValue) }

    // MARK: - Default bar orders

    /// ⌘ is deliberately absent from both defaults even though it sits with the
    /// other modifiers in the palette. It is the one modifier chip that sends
    /// nothing to the remote — it arms the app's own shortcuts — so shipping it
    /// next to ⌃/⌥ by default would put two different kinds of key on one row
    /// of chips with nothing to tell them apart. Users who want app chords
    /// without a hardware keyboard add it from Settings → Keyboard.
    ///
    /// ↩ sits next to esc rather than at the end: the row already overflows a
    /// portrait phone, and the two keys that commit and cancel a prompt are
    /// the ones that must not be behind a scroll.
    public static let defaultPhoneBarOrder: [AccessoryKey] = [
        .esc, .enter, .ctrl, .tab, .left, .right, .down, .up, .alt,
        .ctrlC, .ctrlJ, .ctrlL,
    ]

    /// The wide default. The phone bar carries ⌃C / ⌃J where this one carries
    /// | and ~, which is why a bar regression can be invisible on one idiom.
    public static let defaultTabletBarOrder: [AccessoryKey] = [
        .esc, .ctrl, .alt, .tab, .left, .down, .up, .right, .pipe, .tilde,
    ]

    // MARK: - Custom-shortcut escape hatch

    /// A user's own shortcut occupies a bar slot as `custom:<uuid>`.
    ///
    /// The prefix is chosen so `AccessoryKey.init(rawValue:)` fails on it: the
    /// bar decodes through `compactMap`, so a build that predates custom chips
    /// drops the entry and keeps the rest of the bar rather than losing the
    /// whole array. Forward and backward compatible without a migration.
    public static let customIDPrefix = "custom:"

    public static func isCustomID(_ id: String) -> Bool {
        id.hasPrefix(customIDPrefix)
    }

    /// The bar slot ID for a custom shortcut. `uuid` is the canonical uppercase
    /// UUID string used everywhere at the core boundary.
    public static func customID(forUUID uuid: String) -> String {
        customIDPrefix + uuid
    }

    /// The UUID string inside a `custom:<uuid>` slot ID, or nil for a built-in
    /// or unrecognised entry. Callers validate the UUID themselves.
    public static func customUUIDString(fromID id: String) -> String? {
        guard isCustomID(id) else { return nil }
        return String(id.dropFirst(customIDPrefix.count))
    }

    // MARK: - Persistence codec

    /// Resolves a stored bar order into raw slot IDs.
    ///
    /// The distinction that matters and is easy to lose: **no stored value at
    /// all** means the user never touched the bar, so they get the platform
    /// default; a **stored empty array** is a deliberately empty row and must
    /// stay empty. Falling back to defaults on empty would silently resurrect
    /// chips a user removed one at a time.
    ///
    /// Raw IDs come back rather than `AccessoryKey`s so `custom:<uuid>` slots
    /// survive; call `builtInKeys(in:)` for the built-in subset.
    public static func resolveStoredOrder(
        _ stored: [String]?,
        defaults: [AccessoryKey]
    ) -> [String] {
        guard let stored else { return defaults.map(\.rawValue) }
        return stored
    }

    /// The built-in keys in a raw stored order. Unknown IDs — a chip from a
    /// newer build, a `custom:<uuid>` slot, or corruption — are dropped instead
    /// of failing the whole array.
    public static func builtInKeys(in rawIDs: [String]) -> [AccessoryKey] {
        rawIDs.compactMap(AccessoryKey.init(rawValue:))
    }

    /// Encodes a stored order back to raw IDs.
    public static func persistedIDs(for keys: [AccessoryKey]) -> [String] {
        keys.map(\.rawValue)
    }

    // MARK: - Legacy Android IDs

    /// Android shipped hyphenated persisted IDs before the catalog was shared.
    /// Recorded here as data so the Kotlin side can migrate stored layouts to
    /// the canonical vocabulary without a second source of truth.
    ///
    /// Two kinds of key are absent by construction. Android never had a ⌘ chip
    /// — its accessory row is a touch/IME affordance and hardware-keyboard
    /// commands are out of scope there. And a key added *after* the catalog
    /// was shared (`enter`, `ctrlL`) was never persisted under an Android
    /// spelling in the first place, so it has nothing to migrate from.
    public static let legacyAndroidIDMap: [String: String] = [
        "escape": "esc",
        "control": "ctrl",
        "alt": "alt",
        "shift": "shift",
        "tab": "tab",
        "left": "left",
        "right": "right",
        "down": "down",
        "up": "up",
        "control-c": "ctrlC",
        "control-j": "ctrlJ",
        "home": "home",
        "end": "end",
        "page-up": "pgup",
        "page-down": "pgdn",
        "f1": "f1",
        "f2": "f2",
        "f3": "f3",
        "f4": "f4",
        "f5": "f5",
        "f6": "f6",
        "f7": "f7",
        "f8": "f8",
        "f9": "f9",
        "f10": "f10",
        "f11": "f11",
        "f12": "f12",
        "pipe": "pipe",
        "tilde": "tilde",
        "slash": "slash",
        "backslash": "backslash",
        "dollar": "dollar",
        "left-brace": "lbrace",
        "right-brace": "rbrace",
        "left-bracket": "lbracket",
        "right-bracket": "rbracket",
        "less-than": "lt",
        "greater-than": "gt",
    ]

    /// Maps one legacy Android persisted ID onto its catalog key. Canonical IDs
    /// pass through unchanged, so a partially migrated array resolves in one
    /// pass.
    public static func key(forLegacyAndroidID id: String) -> AccessoryKey? {
        if let canonical = legacyAndroidIDMap[id] {
            return AccessoryKey(rawValue: canonical)
        }
        return AccessoryKey(rawValue: id)
    }

    // MARK: - Encoding

    /// The bytes this catalog entry sends, or nil for a modifier key — those
    /// arm `ModifierArming` instead of producing output.
    ///
    /// One entry point keyed by catalog ID is what the C ABI can expose later,
    /// which is why the platform encoders delegate here rather than each
    /// keeping their own switch over key cases.
    public static func encode(
        id: String,
        modifiers: TerminalModifiers = .none,
        applicationCursorMode: Bool = false
    ) -> [UInt8]? {
        guard let key = AccessoryKey(rawValue: id) else { return nil }
        return encode(
            key,
            modifiers: modifiers,
            applicationCursorMode: applicationCursorMode
        )
    }

    public static func encode(
        _ key: AccessoryKey,
        modifiers: TerminalModifiers = .none,
        applicationCursorMode: Bool = false
    ) -> [UInt8]? {
        guard let terminalKey = key.terminalKey else { return nil }
        return TerminalKeySequenceEncoder.encode(
            terminalKey,
            // Command never reaches the wire, so it is stripped before the
            // encoder ever sees the armed set.
            modifiers: modifiers.terminalOnly,
            mode: TerminalKeyMode(applicationCursorKeys: applicationCursorMode)
        )
    }
}
