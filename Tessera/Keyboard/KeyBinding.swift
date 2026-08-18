// Tessera/Keyboard/KeyBinding.swift
// The storable form of a key chord, its bridge to UIKit, and the rules that
// decide whether a recorded chord is usable.
//
// Why bindings store `charactersIgnoringModifiers` and not `characters`:
// `UIKeyCommand` matches on the character a key *produces*, and Option remaps
// the base character (US layout: ⌥[ → “). A command registered for input "["
// with `.alternate` therefore never matches anything the keyboard can emit —
// this is the documented `⌘⌥[` failure in TesseraTerminalView, and it is a
// character-mapping problem, not interception.
// See docs/keyboard-interception-research.md.
import Foundation
import UIKit

/// The key half of a binding. Kept separate from `KeyToken` (which is a display
/// concern) because this side has to round-trip through `UIKeyCommand.input`
/// and `UIKeyboardHIDUsage`.
enum BindingKey: Codable, Equatable, Hashable {
    case character(String)
    case up, down, left, right
    case escape, `return`, tab, space, delete
    case pageUp, pageDown, home, end
    case function(Int)

    /// The string `UIKeyCommand(input:)` matches against.
    var keyCommandInput: String {
        switch self {
        case .character(let c): return c
        case .up:       return UIKeyCommand.inputUpArrow
        case .down:     return UIKeyCommand.inputDownArrow
        case .left:     return UIKeyCommand.inputLeftArrow
        case .right:    return UIKeyCommand.inputRightArrow
        case .escape:   return UIKeyCommand.inputEscape
        case .return:   return "\r"
        case .tab:      return "\t"
        case .space:    return " "
        case .delete:   return "\u{8}"
        case .pageUp:   return UIKeyCommand.inputPageUp
        case .pageDown: return UIKeyCommand.inputPageDown
        case .home:     return UIKeyCommand.inputHome
        case .end:      return UIKeyCommand.inputEnd
        case .function(let n): return "UIKeyInputF\(n)"
        }
    }

    /// Display token. Anything without a dedicated glyph falls back to its
    /// literal characters.
    var displayToken: KeyToken {
        switch self {
        case .character(let c): return .character(c.first ?? "?")
        case .up:     return .up
        case .down:   return .down
        case .left:   return .left
        case .right:  return .right
        case .escape: return .escape
        case .return: return .return
        case .tab:    return .tab
        case .space:  return .space
        case .delete: return .delete
        case .pageUp:   return .character("⇞")
        case .pageDown: return .character("⇟")
        case .home:     return .character("↖")
        case .end:      return .character("↘")
        case .function(let n): return .character(Character("\(n)"))
        }
    }

    /// Built from a hardware key press. `charactersIgnoringModifiers` is
    /// deliberate — see the file comment.
    static func from(keyCode: UIKeyboardHIDUsage, charactersIgnoringModifiers: String) -> BindingKey? {
        switch keyCode {
        case .keyboardUpArrow:    return .up
        case .keyboardDownArrow:  return .down
        case .keyboardLeftArrow:  return .left
        case .keyboardRightArrow: return .right
        case .keyboardEscape:     return .escape
        case .keyboardReturnOrEnter, .keypadEnter: return .return
        case .keyboardTab:        return .tab
        case .keyboardSpacebar:   return .space
        case .keyboardDeleteOrBackspace: return .delete
        case .keyboardPageUp:     return .pageUp
        case .keyboardPageDown:   return .pageDown
        case .keyboardHome:       return .home
        case .keyboardEnd:        return .end
        case .keyboardF1:  return .function(1)
        case .keyboardF2:  return .function(2)
        case .keyboardF3:  return .function(3)
        case .keyboardF4:  return .function(4)
        case .keyboardF5:  return .function(5)
        case .keyboardF6:  return .function(6)
        case .keyboardF7:  return .function(7)
        case .keyboardF8:  return .function(8)
        case .keyboardF9:  return .function(9)
        case .keyboardF10: return .function(10)
        case .keyboardF11: return .function(11)
        case .keyboardF12: return .function(12)
        default:
            let trimmed = charactersIgnoringModifiers.lowercased()
            guard trimmed.count == 1, let scalar = trimmed.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar) else { return nil }
            return .character(trimmed)
        }
    }
}

/// A complete, storable shortcut: modifiers plus a key.
struct KeyBinding: Codable, Equatable, Hashable {
    var modifiers: Set<KeyToken>
    var key: BindingKey

    init(_ modifiers: Set<KeyToken>, _ key: BindingKey) {
        self.modifiers = modifiers.filter(\.isModifier)
        self.key = key
    }

    /// Convenience matching how the shipped chords are written.
    static func cmd(_ c: Character) -> KeyBinding { KeyBinding([.command], .character(String(c))) }
    static func cmdShift(_ c: Character) -> KeyBinding { KeyBinding([.command, .shift], .character(String(c))) }

    var chord: Chord { Chord(modifiers, key.displayToken) }

    func rendered(_ notation: ModifierNotation) -> String { chord.rendered(notation) }

    var modifierFlags: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift)   { flags.insert(.shift) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option)  { flags.insert(.alternate) }
        return flags
    }

    /// SwiftUI equivalent, for the handful of chords that ride
    /// `.keyboardShortcut` on hidden buttons rather than `UIKeyCommand`.
    var keyEquivalent: KeyEquivalentBridge? {
        guard case .character(let c) = key, let first = c.first else {
            switch key {
            case .return: return KeyEquivalentBridge(character: "\r", modifiers: eventModifiers)
            case .escape: return KeyEquivalentBridge(character: "\u{1b}", modifiers: eventModifiers)
            case .tab:    return KeyEquivalentBridge(character: "\t", modifiers: eventModifiers)
            case .space:  return KeyEquivalentBridge(character: " ", modifiers: eventModifiers)
            default: return nil
            }
        }
        return KeyEquivalentBridge(character: first, modifiers: eventModifiers)
    }

    private var eventModifiers: Set<KeyToken> { modifiers }

    /// Built from a live key press during recording.
    static func from(key: UIKey) -> KeyBinding? {
        guard let bindingKey = BindingKey.from(
            keyCode: key.keyCode,
            charactersIgnoringModifiers: key.charactersIgnoringModifiers
        ) else { return nil }

        var mods: Set<KeyToken> = []
        if key.modifierFlags.contains(.command)   { mods.insert(.command) }
        if key.modifierFlags.contains(.shift)     { mods.insert(.shift) }
        if key.modifierFlags.contains(.control)   { mods.insert(.control) }
        if key.modifierFlags.contains(.alternate) { mods.insert(.option) }
        return KeyBinding(mods, bindingKey)
    }
}

/// Carries a SwiftUI shortcut across the module boundary without importing
/// SwiftUI into the model layer.
struct KeyEquivalentBridge {
    var character: Character
    var modifiers: Set<KeyToken>
}

// MARK: - Validation

/// Why a recorded chord can't be used, in the words the recorder shows.
enum BindingRejection: Equatable {
    case needsCommand
    case optionRemapsTheKey
    case reservedBySystem(String)
    case notCapturable(String)

    var headline: String {
        switch self {
        case .needsCommand:        return String(localized: "needs ⌘")
        case .optionRemapsTheKey:  return String(localized: "⌥ changes this key")
        case .reservedBySystem:    return String(localized: "iPadOS keeps this one")
        case .notCapturable:       return String(localized: "can't be captured here")
        }
    }

    var detail: String {
        switch self {
        case .needsCommand:
            return String(localized: "without it the terminal loses this key — ^E is end-of-line in every shell.")
        case .optionRemapsTheKey:
            return String(localized: "holding ⌥ makes this key produce a different character, so the shortcut would never match. try it without ⌥, or pick a letter.")
        case .reservedBySystem(let why), .notCapturable(let why):
            return why
        }
    }
}

enum BindingValidation: Equatable {
    case ok
    /// Usable, but another action already owns it.
    case conflict(ShortcutAction)
    case rejected(BindingRejection)
}

extension KeyBinding {
    /// Chords iPadOS claims before any app is asked. Advisory: documentation-
    /// derived, varies with OS version and Stage Manager, and deliberately
    /// *not* the only defense — the recorder's non-arrival detection catches
    /// anything this table misses. A wrong entry degrades to a worse message,
    /// never to a false reject of a chord that actually works.
    static let reservedBySystem: [KeyBinding: String] = [
        KeyBinding([.command], .space):
            String(localized: "⌘space opens Spotlight before Tessera is asked."),
        KeyBinding([.command], .tab):
            String(localized: "⌘tab is the app switcher."),
        KeyBinding([.command], .character("h")):
            String(localized: "⌘H goes to the Home screen."),
        KeyBinding([.command], .character("w")):
            String(localized: "Stage Manager closes the window on ⌘W. Tessera uses ⇧⌘W to close a tmux window for exactly this reason."),
        KeyBinding([.command, .shift], .character("3")):
            String(localized: "⇧⌘3 takes a screenshot."),
        KeyBinding([.command, .shift], .character("4")):
            String(localized: "⇧⌘4 takes a screenshot."),
        KeyBinding([.command, .option], .character("d")):
            String(localized: "⌘⌥D shows and hides the Dock."),
    ]

    /// Chords that reach neither `keyCommands` nor an ancestor's
    /// `pressesBegan`, with the mechanism. All three are already recorded as
    /// dead ends in `TesseraTerminalView.swift` — this stops them being
    /// re-tried by a user instead of by a developer.
    static func notCapturableReason(for binding: KeyBinding) -> String? {
        switch binding.key {
        case .tab where binding.modifiers.contains(.control):
            return String(localized: "iPadOS's focus engine claims the Tab key app-wide, so this never reaches Tessera.")
        case .up, .down, .left, .right:
            return String(localized: "the terminal's text input claims the arrow keys first. try a letter or a punctuation key.")
        default:
            return nil
        }
    }

    /// - Parameters:
    ///   - producedCharacters: `UIKey.characters` at record time. Supplying it
    ///     enables the ⌥-remap check, which is the one failure mode that can be
    ///     detected from the press itself rather than guessed from a table.
    ///   - existing: current bindings, for conflict reporting.
    func validate(
        producedCharacters: String? = nil,
        existing: [ShortcutAction: KeyBinding] = [:]
    ) -> BindingValidation {
        // 1. Structural rule. Not a platform limit — a product one: chords
        //    without ⌘ steal keys the shell owns.
        guard modifiers.contains(.command) else {
            return .rejected(.needsCommand)
        }

        // 2. Runtime-detected: Option remapped the base character, so a
        //    UIKeyCommand for it can never match. Layout-independent.
        if modifiers.contains(.option),
           case .character(let base) = key,
           let produced = producedCharacters,
           produced.lowercased() != base.lowercased(),
           !produced.isEmpty {
            return .rejected(.optionRemapsTheKey)
        }

        // 3. Advisory tables.
        if let why = Self.reservedBySystem[self] {
            return .rejected(.reservedBySystem(why))
        }
        if let why = Self.notCapturableReason(for: self) {
            return .rejected(.notCapturable(why))
        }

        // 4. Conflicts are not rejections — the user may take the chord.
        if let owner = existing.first(where: { $0.value == self })?.key {
            return .conflict(owner)
        }
        return .ok
    }
}
