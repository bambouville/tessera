// Packages/TesseraCore/Sources/TesseraInputCore/ModifierArming.swift
// The pure arming state machine behind the software accessory bar's modifier
// chips. Extracted from `Tessera/Keyboard/ModifierState.swift`, which keeps the
// responder-chain plumbing (dismiss/reclaim of the software keyboard) and wraps
// this struct observably.
//
// Every transition here is total and synchronous: `tap` toggles, `consume`
// snapshots-then-clears under one-shot, `cancel` clears unconditionally. No
// platform type appears in the surface, so the Kotlin peer can hold the same
// three transitions.

/// Whether an armed modifier survives the key it modified.
public enum ModifierBehaviorMode: String, CaseIterable, Codable, Sendable {
    /// The default: one armed modifier applies to exactly one key event.
    case oneShot
    /// The modifier stays armed until it is tapped off or cancelled.
    case sticky
}

/// Armed accessory-bar modifiers plus the rule for how long they survive.
public struct ModifierArming: Equatable, Hashable, Codable, Sendable {
    /// Sticky vs one-shot. Persisted on Apple platforms as
    /// `AppearancePreferences.modifierBehavior`.
    public var behavior: ModifierBehaviorMode

    /// The currently armed set, including Command. Command is representable
    /// here because the ⌘ chip arms Tessera's *own* shortcut dispatcher; see
    /// `wireModifiers` for the subset that may reach the terminal.
    public private(set) var armed: TerminalModifiers

    public init(
        behavior: ModifierBehaviorMode = .oneShot,
        armed: TerminalModifiers = .none
    ) {
        self.behavior = behavior
        self.armed = armed
    }

    /// The ⌘ chip sends nothing to the remote — no terminal encoding carries
    /// Command — so the wire never sees it even while it is armed. Encoders
    /// take this, never `armed`.
    public var wireModifiers: TerminalModifiers { armed.terminalOnly }

    /// True while the ⌘ chip has armed the local app-shortcut dispatcher.
    public var isCommandArmed: Bool { armed.cmd }

    public var isAnyArmed: Bool { armed.isAnyArmed }

    /// Toggles one modifier. Tapping an armed modifier disarms it, which is how
    /// a user backs out of a chord they started by mistake.
    @discardableResult
    public mutating func tap(_ modifier: TerminalModifier) -> TerminalModifiers {
        switch modifier {
        case .control: armed.ctrl.toggle()
        case .alternate: armed.alt.toggle()
        case .shift: armed.shift.toggle()
        case .command: armed.cmd.toggle()
        }
        return armed
    }

    /// Returns what was armed and applies the behavior rule: one-shot clears,
    /// sticky keeps. The snapshot is returned either way, so a caller always
    /// encodes with the modifiers the user could see on the bar.
    @discardableResult
    public mutating func consume() -> TerminalModifiers {
        let snapshot = armed

        if behavior == .oneShot {
            armed = .none
        }

        return snapshot
    }

    /// Clears regardless of behavior — the escape hatch out of a sticky chord.
    public mutating func cancel() {
        armed = .none
    }

    /// The app-shortcut key a typed byte becomes while Command is armed, or
    /// `nil` when this event is not an app chord and must go to the wire.
    ///
    /// Only a single printable-ASCII byte qualifies: pastes and composed
    /// Unicode commits arrive as multi-byte payloads and must not be swallowed
    /// as a chord, and a control byte is already a terminal sequence.
    public func commandChordKey(for bytes: [UInt8]) -> String? {
        guard armed.cmd, bytes.count == 1 else { return nil }
        let byte = bytes[0]
        // ASCII, and not a control character: 0x20...0x7E.
        guard byte > 0x1F, byte < 0x7F else { return nil }
        return String(UnicodeScalar(byte)).lowercased()
    }
}
