import Foundation
import XCTest
@testable import TesseraInputCore

/// The accessory bar's arming rules. Ported from the Apple `ModifierStateTests`
/// so the pure transitions are pinned once, in the layer both platforms share.
final class ModifierArmingTests: XCTestCase {

    // MARK: - Tap

    func test_initialArmedIsNone() {
        let arming = ModifierArming()

        XCTAssertEqual(arming.armed, .none)
        XCTAssertEqual(arming.behavior, .oneShot)
        XCTAssertFalse(arming.isAnyArmed)
    }

    func test_tapControlArmsControl() {
        var arming = ModifierArming()

        XCTAssertEqual(arming.tap(.control), TerminalModifiers(ctrl: true))
        XCTAssertEqual(arming.armed, TerminalModifiers(ctrl: true))
    }

    func test_tapControlAgainClearsControl() {
        var arming = ModifierArming()
        arming.tap(.control)

        XCTAssertEqual(arming.tap(.control), .none)
        XCTAssertEqual(arming.armed, .none)
    }

    func test_tapControlThenAlternateArmsBoth() {
        var arming = ModifierArming()
        arming.tap(.control)

        XCTAssertEqual(arming.tap(.alternate), TerminalModifiers(ctrl: true, alt: true))
        XCTAssertEqual(arming.armed, TerminalModifiers(ctrl: true, alt: true))
    }

    // MARK: - Consume

    func test_consumeOneShotReturnsArmedAndResets() {
        var arming = ModifierArming()
        arming.tap(.control)
        arming.tap(.shift)

        XCTAssertEqual(arming.consume(), TerminalModifiers(ctrl: true, shift: true))
        XCTAssertEqual(arming.armed, .none)
    }

    func test_consumeStickyReturnsArmedAndLeavesState() {
        var arming = ModifierArming(behavior: .sticky)
        arming.tap(.alternate)

        XCTAssertEqual(arming.consume(), TerminalModifiers(alt: true))
        XCTAssertEqual(arming.armed, TerminalModifiers(alt: true))
        // Sticky survives an arbitrary number of key events…
        XCTAssertEqual(arming.consume(), TerminalModifiers(alt: true))
        XCTAssertEqual(arming.consume(), TerminalModifiers(alt: true))
        // …until it is cancelled or tapped off.
        arming.cancel()
        XCTAssertEqual(arming.armed, .none)
    }

    func test_cancelClearsRegardlessOfMode() {
        for behavior in ModifierBehaviorMode.allCases {
            var arming = ModifierArming(behavior: behavior)
            arming.tap(.control)
            arming.tap(.alternate)
            arming.tap(.shift)
            arming.tap(.command)

            arming.cancel()

            XCTAssertEqual(arming.armed, .none, "\(behavior.rawValue)")
        }
    }

    /// Switching behavior mid-chord must not disturb what is already armed —
    /// the bar rereads the preference on every appearance and on every tap.
    func test_changingBehaviorDoesNotDisturbTheArmedSet() {
        var arming = ModifierArming()
        arming.tap(.control)

        arming.behavior = .sticky
        XCTAssertEqual(arming.armed, TerminalModifiers(ctrl: true))
        XCTAssertEqual(arming.consume(), TerminalModifiers(ctrl: true))
        XCTAssertEqual(arming.armed, TerminalModifiers(ctrl: true))

        arming.behavior = .oneShot
        XCTAssertEqual(arming.consume(), TerminalModifiers(ctrl: true))
        XCTAssertEqual(arming.armed, .none)
    }

    // MARK: - The ⌘ chip

    /// ⌘ arms the app's own dispatcher. It is armed like any other chip and is
    /// visible in `armed`, but `wireModifiers` — what encoders take — never
    /// carries it, so no terminal ever sees a Command press.
    func test_commandArmsTheLocalDispatcherAndNeverReachesTheWire() {
        var arming = ModifierArming()
        arming.tap(.command)

        XCTAssertTrue(arming.isCommandArmed)
        XCTAssertTrue(arming.isAnyArmed)
        XCTAssertTrue(arming.armed.cmd)
        XCTAssertFalse(arming.wireModifiers.cmd)
        XCTAssertEqual(arming.wireModifiers, .none)

        arming.tap(.control)
        XCTAssertEqual(arming.wireModifiers, TerminalModifiers(ctrl: true))
        XCTAssertEqual(
            AccessoryKeyCatalog.encode(.up, modifiers: arming.armed),
            AccessoryKeyCatalog.encode(.up, modifiers: arming.wireModifiers)
        )
    }

    func test_commandChordAcceptsOnlyOnePrintableAsciiByte() {
        var arming = ModifierArming()

        // Nothing is a chord while ⌘ is not armed.
        XCTAssertNil(arming.commandChordKey(for: Array("c".utf8)))

        arming.tap(.command)
        XCTAssertEqual(arming.commandChordKey(for: Array("c".utf8)), "c")
        // Glyph-mode chords are written uppercase; the binding key is not.
        XCTAssertEqual(arming.commandChordKey(for: Array("N".utf8)), "n")
        XCTAssertEqual(arming.commandChordKey(for: Array("1".utf8)), "1")
        XCTAssertEqual(arming.commandChordKey(for: [0x20]), " ")

        // Pastes and composed-Unicode commits are multi-byte and must not be
        // swallowed as a chord.
        XCTAssertNil(arming.commandChordKey(for: Array("paste".utf8)))
        XCTAssertNil(arming.commandChordKey(for: Array("é".utf8)))
        XCTAssertNil(arming.commandChordKey(for: []))
        // A control byte is already a terminal sequence.
        XCTAssertNil(arming.commandChordKey(for: [0x03]))
        XCTAssertNil(arming.commandChordKey(for: [0x1B]))
        XCTAssertNil(arming.commandChordKey(for: [0x7F]))
        XCTAssertNil(arming.commandChordKey(for: [0x80]))
    }

    // MARK: - Software-keyboard pipeline

    /// The one-shot modifier is consumed only when the shared encoder accepted
    /// one complete, eligible key event — the rule that keeps a ⌃ armed across
    /// a paste instead of silently evaporating.
    func test_oneShotSurvivesAnIneligibleEventAndClearsOnAnEligibleOne() {
        var arming = ModifierArming()
        arming.tap(.control)

        let paste = Array("paste".utf8)
        XCTAssertNil(
            TerminalSoftwareModifierEncoder.encodeNextKey(paste, modifiers: arming.armed)
        )
        XCTAssertTrue(arming.armed.ctrl)

        XCTAssertEqual(
            TerminalSoftwareModifierEncoder.encodeNextKey(
                Array("c".utf8),
                modifiers: arming.consume()
            ),
            [0x03]
        )
        XCTAssertEqual(arming.armed, .none)
    }

    // MARK: - Codable

    func test_armingRoundTripsThroughJSON() throws {
        var arming = ModifierArming(behavior: .sticky)
        arming.tap(.control)
        arming.tap(.command)

        let data = try JSONEncoder().encode(arming)
        XCTAssertEqual(try JSONDecoder().decode(ModifierArming.self, from: data), arming)
        XCTAssertEqual(ModifierBehaviorMode.allCases.map(\.rawValue), ["oneShot", "sticky"])
    }
}
