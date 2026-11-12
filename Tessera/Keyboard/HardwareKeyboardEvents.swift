// Tessera/Keyboard/HardwareKeyboardEvents.swift
// GCKeyboard has one callback slot. Owning it here lets terminal passthrough
// and passive keyboard affordances coexist across every mounted session.
import Foundation
import GameController

@MainActor
final class HardwareKeyboardSubscription {
    fileprivate var handler: (@MainActor (GCKeyCode, Bool) -> Void)?

    fileprivate init(handler: @escaping @MainActor (GCKeyCode, Bool) -> Void) {
        self.handler = handler
    }

    func cancel() { handler = nil }
}

@MainActor
final class HardwareKeyboardEvents {
    static let shared = HardwareKeyboardEvents()

    /// Weak ownership makes dropping a token unsubscribe immediately, without
    /// requiring its deinit to synchronously enter the main actor.
    private struct Subscriber {
        weak var subscription: HardwareKeyboardSubscription?
    }

    private var subscribers: [Subscriber] = []
    private weak var installedKeyboard: GCKeyboard?
    private var connectObserver: NSObjectProtocol?
    private let observesHardware: Bool

    /// Tests use the same fan-out without taking the real keyboard's slot.
    init(observesHardware: Bool = true) {
        self.observesHardware = observesHardware
    }

    func subscribe(
        _ handler: @escaping @MainActor (GCKeyCode, Bool) -> Void
    ) -> HardwareKeyboardSubscription {
        let token = HardwareKeyboardSubscription(handler: handler)
        subscribers.removeAll { $0.subscription?.handler == nil }
        subscribers.append(Subscriber(subscription: token))
        if observesHardware {
            if connectObserver == nil {
                connectObserver = NotificationCenter.default.addObserver(
                    forName: .GCKeyboardDidConnect, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.installIfNeeded(force: true) }
                }
            }
            installIfNeeded()
        }
        return token
    }

    var isCommandPressed: Bool {
        isPressed(.leftGUI) || isPressed(.rightGUI)
    }

    /// ⌘ is down and nothing else is — read from the keyboard, so it also
    /// covers keys pressed while a subscriber was ignoring the stream (the
    /// chord recorder). Caps Lock is excluded: it can report its latch.
    var isOnlyCommandPressed: Bool {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return false }
        let command = [input.button(forKeyCode: .leftGUI), input.button(forKeyCode: .rightGUI)]
            .compactMap { $0 }
        guard command.contains(where: \.isPressed) else { return false }
        let capsLock = input.button(forKeyCode: .capsLock)
        return !input.buttons.values.contains { button in
            button.isPressed && button !== capsLock && !command.contains { $0 === button }
        }
    }

    /// Live state, not the delivered stream: false without a keyboard.
    func isPressed(_ keyCode: GCKeyCode) -> Bool {
        GCKeyboard.coalesced?.keyboardInput?.button(forKeyCode: keyCode)?.isPressed == true
    }

    /// Snapshot membership, but re-check each weak token at delivery time: an
    /// earlier subscriber may cancel or release a later one during its callback.
    func deliver(keyCode: GCKeyCode, pressed: Bool) {
        subscribers.removeAll { $0.subscription?.handler == nil }
        let current = subscribers
        for subscriber in current {
            subscriber.subscription?.handler?(keyCode, pressed)
        }
    }

    private func installIfNeeded(force: Bool = false) {
        guard let keyboard = GCKeyboard.coalesced,
              let input = keyboard.keyboardInput,
              force || installedKeyboard !== keyboard else { return }
        installedKeyboard = keyboard
        input.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            // Preserve the terminal coordinator's asynchronous main-queue hop.
            DispatchQueue.main.async {
                self?.deliver(keyCode: keyCode, pressed: pressed)
            }
        }
    }

    deinit {
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
    }
}
