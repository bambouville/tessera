import XCTest
import UIKit
@testable import Tessera

/// The recorder's exclusion rules. Backing research:
/// `docs/keyboard-interception-research.md`.
///
/// The design point these tests protect: only *one* of the four rules is a
/// static table. The rest are structural or derived from the press itself, so
/// a stale table can produce a worse error message but never a false reject of
/// a chord that actually works.
final class ShortcutValidationTests: XCTestCase {

    // MARK: - Structural rule

    /// Every app chord must contain ⌘. Not a platform limit — a product one:
    /// SwiftTerm's `pressesBegan` claims every ⌃ and ⌥ chord for the remote
    /// (`optionAsMetaKey` defaults to true), so binding one costs the user a
    /// key the shell needs.
    func testChordsWithoutCommandAreRejected() {
        let cases: [KeyBinding] = [
            KeyBinding([.control], .character("e")),
            KeyBinding([.option], .character("f")),
            KeyBinding([.shift], .character("a")),
            KeyBinding([], .character("x")),
            KeyBinding([.control, .shift], .character("t")),
        ]
        for binding in cases {
            XCTAssertEqual(
                binding.validate(), .rejected(.needsCommand),
                "\(binding.rendered(.glyph)) should require ⌘"
            )
        }
    }

    func testOrdinaryCommandChordsAreAccepted() {
        XCTAssertEqual(KeyBinding.cmd("y").validate(), .ok)
        XCTAssertEqual(KeyBinding.cmdShift("y").validate(), .ok)
        XCTAssertEqual(KeyBinding([.command, .control], .character("y")).validate(), .ok)
    }

    // MARK: - Runtime detection (the ⌥ remap trap)

    /// `⌘⌥[` was tried on device and the selector never fired — because Option
    /// remaps the base character (US layout: ⌥[ → “), so a `UIKeyCommand`
    /// registered for "[" can never match. Detected from the press itself,
    /// which makes it layout-independent.
    func testOptionRemappedKeysAreRejectedFromTheProducedCharacter() {
        let binding = KeyBinding([.command, .option], .character("["))
        XCTAssertEqual(
            binding.validate(producedCharacters: "“"),
            .rejected(.optionRemapsTheKey)
        )
    }

    /// The same chord on a layout where Option does *not* remap the key stays
    /// usable — the rule is evidence, not a blanket ban on ⌥.
    func testOptionChordsSurviveWhenTheCharacterIsUnchanged() {
        let binding = KeyBinding([.command, .option], .character("l"))
        XCTAssertEqual(binding.validate(producedCharacters: "l"), .ok)
    }

    /// Without a recorded press there is nothing to compare, so validation must
    /// not invent a rejection — this is the path stored bindings take on load.
    func testOptionChordsAreNotRejectedWithoutEvidence() {
        let binding = KeyBinding([.command, .option], .character("["))
        XCTAssertEqual(binding.validate(), .ok)
    }

    // MARK: - Advisory tables

    func testSystemReservedChordsAreRejectedWithAReason() {
        for binding in KeyBinding.reservedBySystem.keys {
            guard case .rejected(let reason) = binding.validate() else {
                return XCTFail("\(binding.rendered(.glyph)) should be rejected")
            }
            guard case .reservedBySystem(let why) = reason else {
                // ⌘W is both reserved and… only reserved. Any other
                // classification means the tables overlap confusingly.
                return XCTFail("\(binding.rendered(.glyph)) rejected for the wrong reason: \(reason)")
            }
            XCTAssertFalse(why.isEmpty, "every reservation needs a sentence the recorder can show")
        }
    }

    func testArrowAndControlTabChordsReportWhyTheyCannotBeCaptured() {
        for key in [BindingKey.up, .down, .left, .right] {
            let binding = KeyBinding([.command], key)
            guard case .rejected(.notCapturable(let why)) = binding.validate() else {
                return XCTFail("⌘\(key) should be reported as uncapturable")
            }
            XCTAssertTrue(why.contains("arrow"))
        }
        let controlTab = KeyBinding([.command, .control], .tab)
        guard case .rejected(.notCapturable(let why)) = controlTab.validate() else {
            return XCTFail("⌃⇥ should be reported as uncapturable")
        }
        XCTAssertTrue(why.contains("focus"))
    }

    // MARK: - Conflicts

    /// A conflict is not a rejection — the recorder offers to take the chord.
    func testConflictsNameTheCurrentOwnerAndAreNotRejections() {
        let existing: [ShortcutAction: KeyBinding] = [.tmuxNewWindow: .cmd("t")]
        XCTAssertEqual(
            KeyBinding.cmd("t").validate(existing: existing),
            .conflict(.tmuxNewWindow)
        )
        XCTAssertEqual(KeyBinding.cmd("y").validate(existing: existing), .ok)
    }

    /// Rejections outrank conflicts: a chord iPadOS keeps is not offered as
    /// "take it from tmux".
    func testRejectionOutranksConflict() {
        let existing: [ShortcutAction: KeyBinding] = [
            .tmuxNewWindow: KeyBinding([.command], .character("h"))
        ]
        guard case .rejected(.reservedBySystem) =
            KeyBinding([.command], .character("h")).validate(existing: existing)
        else {
            return XCTFail("system reservation must win over a conflict")
        }
    }

    // MARK: - Recording

    /// Bindings are built from `charactersIgnoringModifiers`, which is what
    /// keeps ⇧-chords from being stored as their shifted glyph.
    func testBindingKeyPrefersTheUnmodifiedCharacter() {
        XCTAssertEqual(
            BindingKey.from(keyCode: .keyboardOpenBracket, charactersIgnoringModifiers: "["),
            .character("[")
        )
        XCTAssertEqual(
            BindingKey.from(keyCode: .keyboardE, charactersIgnoringModifiers: "E"),
            .character("e"),
            "stored bindings are case-insensitive; ⇧ lives in the modifier set"
        )
        XCTAssertEqual(
            BindingKey.from(keyCode: .keyboardUpArrow, charactersIgnoringModifiers: ""),
            .up
        )
        XCTAssertNil(
            BindingKey.from(keyCode: .keyboardLeftShift, charactersIgnoringModifiers: ""),
            "a bare modifier press is not a binding"
        )
    }

    func testBindingsRoundTripThroughJSON() throws {
        let cases: [KeyBinding] = [
            .cmd("n"),
            .cmdShift("["),
            KeyBinding([.command, .control, .option, .shift], .return),
            KeyBinding([.command], .function(5)),
            KeyBinding([.command], .character("-")),
        ]
        for binding in cases {
            let data = try JSONEncoder().encode(binding)
            let decoded = try JSONDecoder().decode(KeyBinding.self, from: data)
            XCTAssertEqual(decoded, binding)
            XCTAssertEqual(decoded.modifierFlags, binding.modifierFlags)
        }
    }
}
