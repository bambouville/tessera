import Foundation
import TesseraInputCore

/// The terminal-input seam: one entry point per thing a platform used to do
/// with its own copy of the encoder.
///
/// Bytes are never derived from a label or a key name on the platform side.
/// Every chip resolves through `AccessoryKeyCatalog` by canonical ID, every
/// typed key through `TerminalSoftwareModifierEncoder`, and every pointer
/// event through `TerminalMouseSequenceEncoder` — which is how Shift+Tab
/// finally emits backtab on both platforms instead of on one.

// MARK: - Chip and typed-key encoding

/// Bytes for one accessory catalog entry.
///
/// `idBytes` is a canonical catalog ID (`AccessoryKey.rawValue`, e.g. `pgup`,
/// `ctrlC`), never a legacy Android spelling — migrate those through
/// `tessera_input_accessory_catalog`'s `legacyAndroidIDMap` first.
/// `modifierBits` is the `TESSERA_INPUT_MODIFIER_*` vector; Command is
/// stripped before encoding because no terminal sequence carries it.
///
/// Returns the byte count under the shared bytes contract, or -1 for invalid
/// arguments, an unknown ID, or a modifier chip (those arm state through
/// `tessera_input_modifier_arming_transition` and send nothing).
@_cdecl("tessera_input_encode_accessory_key")
public func tesseraInputEncodeAccessoryKey(
    idBytes: UnsafePointer<UInt8>?,
    idCount: Int,
    modifierBits: Int32,
    applicationCursorMode: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let id = SharedABI.requiredString(idBytes, idCount, maximum: 256),
          let modifiers = TerminalModifiers(abiBits: modifierBits),
          let encoded = AccessoryKeyCatalog.encode(
              id: id,
              modifiers: modifiers,
              applicationCursorMode: applicationCursorMode != 0
          )
    else { return -1 }
    return SharedABI.copyOut(encoded, outputBytes, outputCapacity)
}

/// Applies armed software modifiers to an ordinary typed key event.
///
/// This is the path Android never had: Ctrl/Alt/Shift over the software
/// keyboard's own bytes (Ctrl+Space → NUL, Ctrl+? → DEL, Alt → ESC prefix,
/// Shift → the US-layout shifted byte). Multi-byte payloads — pastes and
/// composed Unicode commits — pass through unchanged, exactly as the core
/// encoder defines.
///
/// Returns the byte count under the shared bytes contract, or -1 for invalid
/// arguments.
@_cdecl("tessera_input_apply_software_modifiers")
public func tesseraInputApplySoftwareModifiers(
    inputBytes: UnsafePointer<UInt8>?,
    inputCount: Int,
    modifierBits: Int32,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let input = SharedABI.requiredData(inputBytes, inputCount, maximum: 65_536),
          let modifiers = TerminalModifiers(abiBits: modifierBits)
    else { return -1 }
    // `encodeNextKey` owns the eligibility rule: only a one-byte key event is
    // transformed; pastes and composed commits come back unchanged (and the
    // caller's one-shot modifiers stay armed). Calling the ungated `encode`
    // here once let an Alt prefix corrupt a multi-byte paste at the bridge.
    let bytes = [UInt8](input)
    let encoded = TerminalSoftwareModifierEncoder.encodeNextKey(bytes, modifiers: modifiers) ?? bytes
    return SharedABI.copyOut(encoded, outputBytes, outputCapacity)
}

// MARK: - Pointer events

/// One neutral pointer event, as JSON.
///
/// ```json
/// {"encoding":"sgr",
///  "event":{"kind":"button","button":"primary","action":"press",
///           "column":10,"row":4,
///           "modifiers":{"ctrl":false,"alt":false,"shift":false,"cmd":false}}}
/// ```
/// `kind` is `button` | `motion` | `wheel`. `button` is `primary` | `middle` |
/// `secondary` (required for `button`, optional for `motion`, absent for
/// `wheel`); `action` is `press` | `release` and applies to `button` only;
/// `direction` is `up` | `down` | `left` | `right` and applies to `wheel`
/// only. `encoding` is `none` | `x10` | `sgr`.
public struct TerminalMouseEventABIRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case button, motion, wheel
    }

    public struct Event: Codable, Equatable, Sendable {
        public var kind: Kind
        public var button: TerminalMouseButtonName?
        public var action: TerminalMouseButtonAction?
        public var direction: TerminalWheelDirectionName?
        public var column: Int
        public var row: Int
        public var modifiers: TerminalModifiers

        public init(
            kind: Kind,
            button: TerminalMouseButtonName? = nil,
            action: TerminalMouseButtonAction? = nil,
            direction: TerminalWheelDirectionName? = nil,
            column: Int,
            row: Int,
            modifiers: TerminalModifiers = .none
        ) {
            self.kind = kind
            self.button = button
            self.action = action
            self.direction = direction
            self.column = column
            self.row = row
            self.modifiers = modifiers
        }
    }

    public var encoding: TerminalMouseEncoding
    public var event: Event

    public init(encoding: TerminalMouseEncoding, event: Event) {
        self.encoding = encoding
        self.event = event
    }

    /// Nil when the kind and its payload disagree — a `wheel` with no
    /// direction, a `button` with no button or action. Rejecting rather than
    /// defaulting keeps a malformed adapter from silently sending button 0.
    var coreEvent: TerminalMouseEvent? {
        switch event.kind {
        case .button:
            guard let button = event.button?.core, let action = event.action else { return nil }
            return .button(
                button,
                action: action,
                column: event.column,
                row: event.row,
                modifiers: event.modifiers
            )
        case .motion:
            guard event.action == nil, event.direction == nil else { return nil }
            return .motion(
                button: event.button?.core,
                column: event.column,
                row: event.row,
                modifiers: event.modifiers
            )
        case .wheel:
            guard let direction = event.direction?.core, event.button == nil, event.action == nil
            else { return nil }
            return .wheel(
                direction,
                column: event.column,
                row: event.row,
                modifiers: event.modifiers
            )
        }
    }
}

/// Named spelling of `TerminalMouseButton`. The core enum's raw values are the
/// xterm button numbers; naming them on the wire keeps the JSON readable and
/// keeps a platform from inventing button 7.
public enum TerminalMouseButtonName: String, Codable, Equatable, Sendable {
    case primary, middle, secondary

    var core: TerminalMouseButton {
        switch self {
        case .primary: return .primary
        case .middle: return .middle
        case .secondary: return .secondary
        }
    }
}

/// Named spelling of `TerminalWheelDirection`, for the same reason.
public enum TerminalWheelDirectionName: String, Codable, Equatable, Sendable {
    case up, down, left, right

    var core: TerminalWheelDirection {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        }
    }
}

/// Encodes one pointer event into its xterm wire bytes.
///
/// Takes `TerminalMouseEventABIRequest` JSON and returns the raw sequence
/// under the shared bytes contract. `encoding: "none"` legitimately produces
/// zero bytes — mouse reporting is off — so 0 is a valid answer here, not an
/// error. Returns -1 for invalid arguments or an inconsistent event.
@_cdecl("tessera_input_encode_mouse_event")
public func tesseraInputEncodeMouseEvent(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        TerminalMouseEventABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 4_096
    ), let event = request.coreEvent
    else { return -1 }
    return SharedABI.copyOut(
        TerminalMouseSequenceEncoder.encode(event, using: request.encoding),
        outputBytes,
        outputCapacity
    )
}

// MARK: - Catalog

/// The whole accessory-key catalog as one document.
///
/// ```json
/// {"customIDPrefix":"custom:",
///  "defaultPhoneBarOrder":["esc","ctrl",...],
///  "defaultTabletBarOrder":["esc","ctrl",...],
///  "ids":["left","down",...],
///  "legacyAndroidIDMap":{"page-up":"pgup",...},
///  "modifierIDs":["ctrl","alt","shift","cmd"]}
/// ```
public struct AccessoryKeyCatalogABIResponse: Codable, Equatable, Sendable {
    public var ids: [String]
    public var modifierIDs: [String]
    public var defaultPhoneBarOrder: [String]
    public var defaultTabletBarOrder: [String]
    public var customIDPrefix: String
    public var legacyAndroidIDMap: [String: String]
}

/// Publishes the canonical catalog: IDs, the two default bar orders, the
/// `custom:<uuid>` prefix, and the legacy-Android migration table.
///
/// A platform reads this once and migrates its stored layout; it must not keep
/// a second hand-written list, which is exactly how "page-up" and "pgup" came
/// to name the same key. Returns the byte count under the string contract.
@_cdecl("tessera_input_accessory_catalog")
public func tesseraInputAccessoryCatalog(
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    let response = AccessoryKeyCatalogABIResponse(
        ids: AccessoryKeyCatalog.allIDs,
        modifierIDs: AccessoryKeyCatalog.allKeys.filter(\.isModifier).map(\.rawValue),
        defaultPhoneBarOrder: AccessoryKeyCatalog.defaultPhoneBarOrder.map(\.rawValue),
        defaultTabletBarOrder: AccessoryKeyCatalog.defaultTabletBarOrder.map(\.rawValue),
        customIDPrefix: AccessoryKeyCatalog.customIDPrefix,
        legacyAndroidIDMap: AccessoryKeyCatalog.legacyAndroidIDMap
    )
    return SharedABI.copyOutJSON(response, outputBytes, outputCapacity)
}

/// Resolves a stored accessory-bar order into canonical slot IDs.
///
/// ```json
/// {"stored":["escape","control-c","custom:1E7C…"],  // null when nothing stored
///  "defaults":"phone"}                              // "phone" | "tablet"
/// ```
/// →
/// ```json
/// {"ids":["esc","ctrlC","custom:1E7C…"],"usedDefaults":false}
/// ```
///
/// The distinction the codec exists to preserve: **absent** (`stored: null`)
/// means the user never touched the bar and gets the platform default; a
/// **stored empty array** is a deliberately empty row and stays empty.
/// Unknown IDs are dropped individually, so one bad entry does not cost the
/// whole bar. Legacy Android spellings in `stored` are migrated in the same
/// pass.
public struct AccessoryBarOrderABIRequest: Codable, Equatable, Sendable {
    public enum Defaults: String, Codable, Sendable {
        case phone, tablet
    }

    public var stored: [String]?
    public var defaults: Defaults

    public init(stored: [String]?, defaults: Defaults) {
        self.stored = stored
        self.defaults = defaults
    }
}

public struct AccessoryBarOrderABIResponse: Codable, Equatable, Sendable {
    public var ids: [String]
    public var usedDefaults: Bool
}

@_cdecl("tessera_input_accessory_bar_order")
public func tesseraInputAccessoryBarOrder(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        AccessoryBarOrderABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 65_536
    ) else { return -1 }
    let defaults = request.defaults == .phone
        ? AccessoryKeyCatalog.defaultPhoneBarOrder
        : AccessoryKeyCatalog.defaultTabletBarOrder
    // Migration runs before the codec so a half-migrated array — some legacy
    // spellings, some canonical — resolves in this one pass.
    let migrated = request.stored.map { stored in
        stored.compactMap { id -> String? in
            if AccessoryKeyCatalog.isCustomID(id) { return id }
            return AccessoryKeyCatalog.key(forLegacyAndroidID: id)?.rawValue
        }
    }
    return SharedABI.copyOutJSON(
        AccessoryBarOrderABIResponse(
            ids: AccessoryKeyCatalog.resolveStoredOrder(migrated, defaults: defaults),
            usedDefaults: request.stored == nil
        ),
        outputBytes,
        outputCapacity
    )
}

// MARK: - Chord rendering

/// One chord to render, plus the notation to render it in.
///
/// ```json
/// {"notation":"glyph",
///  "chord":{"modifiers":["command","shift"],"key":"c:e"}}
/// ```
/// Tokens use `KeyChordToken`'s own stable wire spelling: `command`, `option`,
/// `control`, `shift`, `tab`, `ret`, `del`, `esc`, `space`, `left`, `down`,
/// `up`, `right`, or `c:<character>` for a literal key.
public struct KeyChordABIRequest: Codable, Equatable, Sendable {
    public struct Chord: Codable, Equatable, Sendable {
        public var modifiers: [KeyChordToken]
        public var key: KeyChordToken?

        public init(modifiers: [KeyChordToken], key: KeyChordToken?) {
            self.modifiers = modifiers
            self.key = key
        }

        var core: KeyChord { KeyChord(Set(modifiers), key) }
    }

    public var notation: KeyChordNotation
    public var chord: Chord

    public init(notation: KeyChordNotation, chord: Chord) {
        self.notation = notation
        self.chord = chord
    }
}

/// Renders a chord label.
///
/// Display only: nothing this returns ever reaches the wire, which is the
/// invariant the notation type was extracted to preserve. Returns the byte
/// count under the string contract, or -1 for invalid arguments.
@_cdecl("tessera_input_render_chord")
public func tesseraInputRenderChord(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        KeyChordABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 4_096
    ) else { return -1 }
    let rendered = request.chord.core.rendered(request.notation)
    // An empty chord renders to an empty string, and the string contract
    // cannot distinguish "0 bytes" from a length query. Reject it rather than
    // hand a caller an answer it cannot read back.
    guard !rendered.isEmpty else { return -1 }
    return SharedABI.copyOut(rendered, outputBytes, outputCapacity)
}

// MARK: - Modifier arming

/// One arming transition.
///
/// ```json
/// {"state":{"armed":{"alt":false,"cmd":false,"ctrl":true,"shift":false},
///           "behavior":"oneShot"},
///  "event":{"kind":"consume"},
///  "keyBytes":"ZQ=="}
/// ```
/// `kind` is `tap` (requires `modifier`: `control` | `alternate` | `shift` |
/// `command`), `consume`, or `cancel`. `keyBytes` is optional base64 for the
/// key event being dispatched; supplying it fills `commandChordKey` in the
/// response.
public struct ModifierArmingABIRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case tap, consume, cancel
    }

    public struct Event: Codable, Equatable, Sendable {
        public var kind: Kind
        public var modifier: TerminalModifier?

        public init(kind: Kind, modifier: TerminalModifier? = nil) {
            self.kind = kind
            self.modifier = modifier
        }
    }

    public var state: ModifierArming
    public var event: Event
    public var keyBytes: Data?

    public init(state: ModifierArming, event: Event, keyBytes: Data? = nil) {
        self.state = state
        self.event = event
        self.keyBytes = keyBytes
    }
}

/// The state after the transition, plus everything a caller decides with.
///
/// `consumed` is the snapshot `consume` returned — what the key that triggered
/// the transition should be encoded with — and is null for `tap`/`cancel`.
/// `wireModifiers` is the post-transition armed set minus Command, because no
/// terminal sequence carries ⌘. `commandChordKey` is the app-shortcut key a
/// supplied `keyBytes` becomes while Command is armed, and null when the event
/// belongs on the wire instead.
public struct ModifierArmingABIResponse: Codable, Equatable, Sendable {
    public var state: ModifierArming
    public var consumed: TerminalModifiers?
    public var wireModifiers: TerminalModifiers
    public var isCommandArmed: Bool
    public var isAnyArmed: Bool
    public var commandChordKey: String?
}

/// Applies one arming transition and reports the new state.
///
/// Pure state-in/state-out: the core holds no arming state across calls, so a
/// platform can drive it from an observable of its own without a handle.
/// Returns the byte count under the string contract, or -1 for invalid
/// arguments (including a `tap` with no modifier).
@_cdecl("tessera_input_modifier_arming_transition")
public func tesseraInputModifierArmingTransition(
    requestBytes: UnsafePointer<UInt8>?,
    requestCount: Int,
    outputBytes: UnsafeMutablePointer<UInt8>?,
    outputCapacity: Int
) -> Int32 {
    guard let request = SharedABI.decode(
        ModifierArmingABIRequest.self,
        requestBytes,
        requestCount,
        maximum: 65_536
    ) else { return -1 }

    var arming = request.state
    var consumed: TerminalModifiers?
    switch request.event.kind {
    case .tap:
        guard let modifier = request.event.modifier else { return -1 }
        arming.tap(modifier)
    case .consume:
        guard request.event.modifier == nil else { return -1 }
        consumed = arming.consume()
    case .cancel:
        guard request.event.modifier == nil else { return -1 }
        arming.cancel()
    }

    // The chord question is asked of the state that was armed when the key
    // arrived, not of what a one-shot consume just cleared.
    let chordState = request.event.kind == .consume ? request.state : arming
    return SharedABI.copyOutJSON(
        ModifierArmingABIResponse(
            state: arming,
            consumed: consumed,
            wireModifiers: arming.wireModifiers,
            isCommandArmed: arming.isCommandArmed,
            isAnyArmed: arming.isAnyArmed,
            commandChordKey: request.keyBytes.flatMap {
                chordState.commandChordKey(for: [UInt8]($0))
            }
        ),
        outputBytes,
        outputCapacity
    )
}

// MARK: - Scroll routing

/// `TESSERA_INPUT_SCROLL_ROUTE_*` for one scroll gesture — the
/// `TerminalScrollRouting` rule, so Termux's view and the iOS dispatcher
/// answer "where does this swipe go?" identically. Flags are 0/1; any other
/// value is -1 so a tri-state cannot be passed by accident.
@_cdecl("tessera_input_scroll_route")
public func tesseraInputScrollRoute(
    bufferIsAlternate: Int32,
    mouseReporting: Int32,
    mouseReportingImpliesAltScreen: Int32
) -> Int32 {
    guard let alternate = abiFlag(bufferIsAlternate),
          let reporting = abiFlag(mouseReporting),
          let implies = abiFlag(mouseReportingImpliesAltScreen)
    else { return -1 }
    switch TerminalScrollRouting.route(
        bufferIsAlternate: alternate,
        mouseReporting: reporting,
        mouseReportingImpliesAltScreen: implies
    ) {
    case .localScrollback: return 0
    case .mouseWheel: return 1
    case .arrowKeys: return 2
    }
}

private func abiFlag(_ value: Int32) -> Bool? {
    switch value {
    case 0: return false
    case 1: return true
    default: return nil
    }
}
