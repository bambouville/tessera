import Foundation
import TesseraInputCore

/// Apple compatibility spelling retained while the implementation and public
/// cross-platform contract live in `TesseraInputCore`.
typealias ArmedModifiers = TerminalModifiers

extension TerminalModifiers {
    /// True when a modifier that transforms terminal bytes is armed.
    var isAny: Bool { hasTerminalModifier }
}

enum AccessoryChipEncoder {
    /// Byte production goes through the shared catalog, keyed by the chip's raw
    /// value — which *is* the canonical catalog ID. Nothing here reads a display
    /// label, so the notation preference cannot change what a chip sends.
    static func encode(
        _ chip: AccessoryChip,
        armed: ArmedModifiers,
        applicationCursor: Bool
    ) -> [UInt8] {
        guard let bytes = AccessoryKeyCatalog.encode(
            id: chip.rawValue,
            modifiers: armed,
            applicationCursorMode: applicationCursor
        ) else {
            preconditionFailure(
                "modifiers should be routed through ModifierState, not the encoder"
            )
        }
        return bytes
    }
}

/// The app spelling delegates byte-for-byte to the portable implementation so
/// the existing iPhone software-keyboard path and tests remain unchanged.
enum SoftwareModifierEncoder {
    static func encodeNextKey(
        _ bytes: [UInt8],
        armed: ArmedModifiers
    ) -> [UInt8]? {
        TerminalSoftwareModifierEncoder.encodeNextKey(
            bytes,
            modifiers: armed
        )
    }

    static func encode(_ bytes: [UInt8], armed: ArmedModifiers) -> [UInt8] {
        TerminalSoftwareModifierEncoder.encode(bytes, modifiers: armed)
    }
}

extension ModifierState {
    /// Handles a typed key while Command is armed on the accessory bar.
    /// Command is an app modifier, never a terminal wire modifier — which key
    /// events qualify as a chord is decided by `ModifierArming`.
    @MainActor
    func consumeCommandChord(_ bytes: [UInt8], store: ShortcutStore) -> Bool {
        guard let character = commandChordKey(for: bytes) else { return false }

        let snapshot = armed
        _ = consume()
        AppShortcutDispatcher.dispatch(
            AppShortcutDispatcher.chord(armed: snapshot, key: .character(character)),
            store: store
        )
        return true
    }

    /// A one-shot modifier is consumed only when the shared encoder accepted
    /// one complete, eligible software-keyboard key event.
    func encodeSoftwareKeyboardPayload(_ bytes: [UInt8]) -> [UInt8] {
        guard let encoded = SoftwareModifierEncoder.encodeNextKey(
            bytes,
            armed: armed
        ) else {
            return bytes
        }
        _ = consume()
        return encoded
    }
}
