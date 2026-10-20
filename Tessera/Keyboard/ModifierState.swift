// Tessera/Keyboard/ModifierState.swift
// Observable wrapper over `TesseraInputCore.ModifierArming`.
//
// Every arming transition — tap, consume, cancel — belongs to the pure core
// struct so the Android bar cannot drift from it. What stays here is the part
// that is genuinely Apple: SwiftUI observation, `AccessoryChip` as the tap
// vocabulary, and the responder-chain plumbing that dismisses and reclaims the
// software keyboard.
import Observation
import TesseraInputCore

/// Sticky vs one-shot behavior for armed modifier chips.
typealias ModifierBehavior = ModifierBehaviorMode

@Observable
final class ModifierState {
    /// The arming state machine. Stored (not `@ObservationIgnored`) so the
    /// computed accessors below still publish changes to SwiftUI.
    private var arming = ModifierArming()

    private(set) var suppressesSoftwareKeyboardReclaim = false
    @ObservationIgnored private var resignSoftwareKeyboard: (() -> Bool)?
    @ObservationIgnored private var becomeSoftwareKeyboard: (() -> Bool)?

    var armed: ArmedModifiers { arming.armed }

    var behavior: ModifierBehavior {
        get { arming.behavior }
        set { arming.behavior = newValue }
    }

    @discardableResult
    func tap(_ chip: AccessoryChip) -> ArmedModifiers {
        guard let modifier = chip.armedModifier else {
            precondition(false, "ModifierState.tap requires a modifier chip")
            return arming.armed
        }
        return arming.tap(modifier)
    }

    @discardableResult
    func consume() -> ArmedModifiers {
        arming.consume()
    }

    func cancel() {
        arming.cancel()
    }

    /// The app-shortcut key a typed byte becomes while ⌘ is armed, or nil when
    /// the event belongs to the wire. See `ModifierArming.commandChordKey`.
    func commandChordKey(for bytes: [UInt8]) -> String? {
        arming.commandChordKey(for: bytes)
    }

    @discardableResult
    func dismissSoftwareKeyboard() -> Bool {
        noteSoftwareKeyboardDismissed()
        return resignSoftwareKeyboard?() ?? false
    }

    /// UIKit's own hide key has already dismissed its input view. Record the
    /// intent without sending a second resignation through its responder chain.
    func noteSoftwareKeyboardDismissed() {
        suppressesSoftwareKeyboardReclaim = true
    }

    /// Pane-selection taps request input before the destination view owns it.
    /// Do not invoke the last pane's stored responder callback in that case.
    func requestSoftwareKeyboardOnTerminalTap() {
        suppressesSoftwareKeyboardReclaim = false
    }

    func noteSoftwareKeyboardRequested(
        resign: @escaping () -> Bool,
        become: @escaping () -> Bool = { false }
    ) {
        resignSoftwareKeyboard = resign
        becomeSoftwareKeyboard = become
        suppressesSoftwareKeyboardReclaim = false
    }

    @discardableResult
    func showSoftwareKeyboard() -> Bool {
        suppressesSoftwareKeyboardReclaim = false
        return becomeSoftwareKeyboard?() ?? false
    }
}
