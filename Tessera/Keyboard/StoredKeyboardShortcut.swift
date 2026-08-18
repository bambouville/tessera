// Tessera/Keyboard/StoredKeyboardShortcut.swift
// Binds a SwiftUI `.keyboardShortcut` to the user's keymap.
//
// Most app chords are `UIKeyCommand`s generated from `ShortcutAction` +
// `ShortcutStore` by `TesseraTerminalContainer`. Five are not: they ride
// `.keyboardShortcut` on hidden buttons because they have to work when no
// terminal holds first responder (new host, quick-switch palette, agent center,
// settings) or because they live on the host editor (connect).
//
// Those five were left written out as literals — `.keyboardShortcut("n",
// modifiers: .command)` — after the keymap landed, so the editor recorded a new
// chord, persisted it, and the shipped one stayed in effect: ⌘N kept opening the
// host editor, an unbind released nothing, and a rebound palette answered to
// both chords. `KeyBinding.keyEquivalent` was written for exactly this bridge
// and had no call sites; this is it.
import SwiftUI

extension EventModifiers {
    /// SwiftUI's modifier set for a stored chord.
    init(_ tokens: Set<KeyToken>) {
        var flags: EventModifiers = []
        if tokens.contains(.command) { flags.insert(.command) }
        if tokens.contains(.shift)   { flags.insert(.shift) }
        if tokens.contains(.control) { flags.insert(.control) }
        if tokens.contains(.option)  { flags.insert(.option) }
        self = flags
    }
}

@MainActor
enum StoredShortcut {
    /// The chord in effect for `action`.
    ///
    /// A missing store (previews, harnesses, tests) falls back to the shipped
    /// default, matching `TesseraTerminalContainer.resolvedBinding`. A
    /// present-but-nil override is a deliberate unbind and stays nil.
    static func binding(_ action: ShortcutAction, in store: ShortcutStore?) -> KeyBinding? {
        guard let store else { return action.defaultBinding }
        return store.binding(for: action)
    }
}

extension View {
    /// Applies the user's binding for `action` to this view.
    ///
    /// - A deliberate unbind attaches no shortcut at all, so the old chord is
    ///   actually released.
    /// - A binding whose key has no `KeyEquivalent` (an arrow, a function key)
    ///   attaches nothing rather than guessing. `KeyBinding.validate` rejects
    ///   arrows outright, so this is unreachable for a recorded chord.
    @MainActor
    @ViewBuilder
    func storedKeyboardShortcut(
        _ action: ShortcutAction,
        in store: ShortcutStore?
    ) -> some View {
        if let bridge = StoredShortcut.binding(action, in: store)?.keyEquivalent {
            keyboardShortcut(
                KeyEquivalent(bridge.character),
                modifiers: EventModifiers(bridge.modifiers)
            )
        } else {
            self
        }
    }
}
