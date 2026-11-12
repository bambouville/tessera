// Tessera/Keyboard/CommandHoldDetector.swift
// Observes a command-only hold without consuming input. An injected scheduler
// keeps the chord-spoiling and release rules independent of UIKit and GCKeyboard.
import Foundation

@MainActor
final class CommandHoldDetector {
    enum Key: Hashable {
        case leftCommand, rightCommand
        case other(Int)

        fileprivate var isCommand: Bool {
            self == .leftCommand || self == .rightCommand
        }
    }

    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)

    /// Long enough that normally typed ⌘K or ⌘⇧K never flashes the sheet.
    nonisolated static let defaultHoldDelay: TimeInterval = 0.8

    var isAllowed: () -> Bool
    private let holdDelay: TimeInterval
    private let schedule: Schedule
    private let onShow: () -> Void
    private let onHide: () -> Void
    private var heldKeys: Set<Key> = []
    private var spoiled = false
    private var isShown = false
    private var isArmed = false
    private var cancelReveal: (() -> Void)?
    private var generation = 0

    init(
        holdDelay: TimeInterval = CommandHoldDetector.defaultHoldDelay,
        schedule: @escaping Schedule,
        isAllowed: @escaping () -> Bool,
        onShow: @escaping () -> Void,
        onHide: @escaping () -> Void
    ) {
        self.holdDelay = holdDelay
        self.schedule = schedule
        self.isAllowed = isAllowed
        self.onShow = onShow
        self.onHide = onHide
    }

    func keyChanged(_ key: Key, pressed: Bool) {
        if pressed {
            let commandWasHeld = hasCommand
            guard heldKeys.insert(key).inserted else { return }
            if key.isCommand {
                // The second command key belongs to the same hold.
                guard !commandWasHeld else { return }
                if heldKeys.contains(where: { !$0.isCommand }) {
                    spoil()
                } else {
                    arm()
                }
            } else if hasCommand {
                spoil()
            }
        } else {
            heldKeys.remove(key)
            if key.isCommand, !hasCommand {
                cancelPendingReveal()
                hide()
                spoiled = false
            }
        }
    }

    func reset() {
        cancelPendingReveal()
        hide()
        heldKeys.removeAll()
        spoiled = false
    }

    /// GameController can drop a key-up (focus left mid-press), and a
    /// remembered key that is no longer down would spoil every later hold.
    /// The owner reconciles against the keyboard's live state before
    /// forwarding a fresh ⌘ press.
    func forgetKeys(notPressed isPressed: (Key) -> Bool) {
        heldKeys = heldKeys.filter { $0.isCommand || isPressed($0) }
    }

    private var hasCommand: Bool { heldKeys.contains(where: \.isCommand) }

    private func arm() {
        cancelPendingReveal()
        let armedGeneration = generation
        isArmed = true
        cancelReveal = schedule(holdDelay) { [weak self] in
            guard let self, self.generation == armedGeneration,
                  self.isArmed, self.hasCommand, !self.spoiled else { return }
            self.isArmed = false
            self.cancelReveal = nil
            guard self.isAllowed(), !self.isShown else { return }
            self.isShown = true
            self.onShow()
        }
    }

    private func spoil() {
        spoiled = true
        cancelPendingReveal()
        hide()
    }

    private func cancelPendingReveal() {
        generation += 1
        isArmed = false
        cancelReveal?()
        cancelReveal = nil
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        onHide()
    }
}
