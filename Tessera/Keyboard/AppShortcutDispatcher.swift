// Tessera/Keyboard/AppShortcutDispatcher.swift
// Runs an app shortcut from a chord the user assembled on screen rather than
// pressed on a hardware keyboard.
//
// Why this exists: ⌃, ⌥ and ⇧ are *wire* modifiers — the accessory bar arms
// them and `SoftwareModifierEncoder` transforms the outgoing bytes. ⌘ has no
// such encoding; no terminal protocol carries Command. A ⌘ chip that armed a
// wire modifier would therefore do nothing at all.
//
// So ⌘ arms Tessera instead: the next key is matched against the shortcut
// registry and dispatched as an app action, and never reaches the remote. That
// makes every shortcut in Settings reachable on a device with no hardware
// keyboard — which is the only way an iPhone user can open the palette or the
// files panel at all.
//
// Dispatch goes through `UIApplication.sendAction`, i.e. the responder chain,
// which is the same path UIKit uses for a real `UIKeyCommand`. That means
// availability gating (`canPerformAction`: tmux attached, multi-pane, iPad
// only) applies identically to an on-screen chord — a ⌘T with no tmux session
// does nothing here exactly as it does on hardware.
import UIKit

enum AppShortcutDispatcher {

    /// Result of offering a chord to the app.
    enum Outcome: Equatable {
        /// An action ran.
        case handled
        /// A binding matched but the action isn't available right now (no tmux
        /// session, single pane). Still swallowed — matching hardware, where
        /// the chord is registered but `canPerformAction` refuses it.
        case matchedButUnavailable
        /// Nothing is bound to this chord.
        case unbound
    }

    /// The chord assembled from an armed modifier state plus one key.
    static func chord(armed: ArmedModifiers, key: BindingKey) -> KeyBinding {
        var modifiers: Set<KeyToken> = []
        if armed.cmd { modifiers.insert(.command) }
        if armed.shift { modifiers.insert(.shift) }
        if armed.ctrl { modifiers.insert(.control) }
        if armed.alt { modifiers.insert(.option) }
        return KeyBinding(modifiers, key)
    }

    /// Offers a chord to the responder chain.
    ///
    /// Returns `.unbound` without side effects when nothing matches, so the
    /// caller can decide what to do with the keystroke. Callers swallow it:
    /// on a Mac, ⌘ plus an unbound key does nothing rather than typing the
    /// letter, and leaking a stray character into a live shell is the worse
    /// failure.
    @MainActor
    @discardableResult
    static func dispatch(_ binding: KeyBinding, store: ShortcutStore) -> Outcome {
        // A user-defined shortcut wins only if no built-in claims the chord;
        // the recorder refuses to save a custom shortcut over a built-in, so
        // in practice these are disjoint.
        //
        // Iterated in `allCases` order rather than over the dictionary: two
        // actions may legitimately share a chord when they can't be on screen
        // together (⌘↩ is connect in the host editor and zoom-pane on a
        // mounted grid), and picking by dictionary order would make which one
        // fires depend on hashing. Actions the terminal doesn't own are skipped
        // so they can't mask one it does.
        for action in ShortcutAction.allCases
        where store.binding(for: action) == binding
            && TesseraTerminalContainer.shortcutSelector(for: action) != nil {
            return send(action: action, binding: binding)
        }

        // ⌘1–⌘9 is nine chords sharing one action, so it can't match by
        // equality — the stored binding only carries the modifiers.
        if case .character(let c) = binding.key,
           c.count == 1, let digit = Int(c), (1...9).contains(digit),
           let block = store.binding(for: .tmuxSelectWindow),
           block.modifiers == binding.modifiers {
            return send(action: .tmuxSelectWindow, binding: binding)
        }

        if let custom = store.customShortcut(matching: binding) {
            return sendCustom(custom, binding: binding)
        }

        return .unbound
    }

    @MainActor
    private static func send(action: ShortcutAction, binding: KeyBinding) -> Outcome {
        guard let selector = TesseraTerminalContainer.shortcutSelector(for: action) else {
            return .unbound
        }
        // The digit block's handler reads `sender.input`, so hand it a real
        // command rather than nil — the same object UIKit would have supplied.
        let sender = UIKeyCommand(
            input: binding.key.keyCommandInput,
            modifierFlags: binding.modifierFlags,
            action: selector
        )
        let handled = UIApplication.shared.sendAction(selector, to: nil, from: sender, for: nil)
        return handled ? .handled : .matchedButUnavailable
    }

    @MainActor
    private static func sendCustom(_ shortcut: CustomShortcut, binding: KeyBinding) -> Outcome {
        let selector = TesseraTerminalContainer.customShortcutSelector
        let sender = UIKeyCommand(
            title: shortcut.name,
            image: nil,
            action: selector,
            input: binding.key.keyCommandInput,
            modifierFlags: binding.modifierFlags,
            propertyList: shortcut.id.uuidString
        )
        let handled = UIApplication.shared.sendAction(selector, to: nil, from: sender, for: nil)
        return handled ? .handled : .matchedButUnavailable
    }
}

extension BindingKey {
    /// The binding key an accessory chip stands for, so a chip tap under an
    /// armed ⌘ can be looked up in the same registry a hardware press is.
    /// Modifier chips and multi-byte shortcuts have no single-key equivalent.
    static func from(chip: AccessoryChip) -> BindingKey? {
        switch chip {
        case .esc:   return .escape
        case .tab:   return .tab
        case .left:  return .left
        case .down:  return .down
        case .up:    return .up
        case .right: return .right
        case .home:  return .home
        case .end:   return .end
        case .pgup:  return .pageUp
        case .pgdn:  return .pageDown
        case .f1:  return .function(1)
        case .f2:  return .function(2)
        case .f3:  return .function(3)
        case .f4:  return .function(4)
        case .f5:  return .function(5)
        case .f6:  return .function(6)
        case .f7:  return .function(7)
        case .f8:  return .function(8)
        case .f9:  return .function(9)
        case .f10: return .function(10)
        case .f11: return .function(11)
        case .f12: return .function(12)
        case .pipe:      return .character("|")
        case .tilde:     return .character("~")
        case .slash:     return .character("/")
        case .backslash: return .character("\\")
        case .dollar:    return .character("$")
        case .lbrace:    return .character("{")
        case .rbrace:    return .character("}")
        case .lbracket:  return .character("[")
        case .rbracket:  return .character("]")
        case .lt:        return .character("<")
        case .gt:        return .character(">")
        case .ctrl, .alt, .shift, .cmd, .ctrlC, .ctrlJ:
            return nil
        }
    }
}
