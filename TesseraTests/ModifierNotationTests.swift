import XCTest
import UIKit
@testable import Tessera

/// `ModifierNotation` is the whole reason the notation preference can be
/// described as global: ten render sites route through it. These tests pin the
/// vocabulary, the joiner, and — most importantly — the separation between
/// *display* and *the wire*.
final class ModifierNotationTests: XCTestCase {

    // MARK: - Vocabulary

    func testGlyphModeUsesMacGlyphsAndUppercasesTheKey() {
        XCTAssertEqual(Chord.cmdShift("e").rendered(.glyph), "⇧⌘E")
        XCTAssertEqual(Chord.cmd("n").rendered(.glyph), "⌘N")
        XCTAssertEqual(Chord([.option], .left).rendered(.glyph), "⌥←")
        XCTAssertEqual(Chord([.command], .return).rendered(.glyph), "⌘↩")
        XCTAssertEqual(Chord([.command], .delete).rendered(.glyph), "⌘⌫")
        XCTAssertEqual(Chord([], .escape).rendered(.glyph), "esc")
    }

    func testWordsModeIsLowercaseAndHyphenJoined() {
        XCTAssertEqual(Chord.cmdShift("e").rendered(.words), "shift-cmd-e")
        XCTAssertEqual(Chord.cmd("n").rendered(.words), "cmd-n")
        XCTAssertEqual(Chord([.option], .left).rendered(.words), "opt-←")
        XCTAssertEqual(Chord([.command], .return).rendered(.words), "cmd-ret")
        XCTAssertEqual(Chord([.command], .delete).rendered(.words), "cmd-del")
    }

    /// Control unifies on ⌃ — the decision that retired the bar's bare `^`.
    func testControlRendersAsTheMacGlyphNotACaret() {
        XCTAssertEqual(KeyToken.control.rendered(.glyph), "⌃")
        XCTAssertEqual(KeyToken.control.rendered(.words), "ctrl")
        XCTAssertEqual(AccessoryChip.ctrl.displayLabel(.glyph), "⌃")
        XCTAssertEqual(AccessoryChip.ctrl.displayLabel(.words), "ctrl")
    }

    /// The control-shortcut chips follow the setting too. They were briefly
    /// left as `^C` on the argument that caret notation is what the shell
    /// echoes — but the iPhone default bar ships ⌃ and ^C side by side, which
    /// describes the same key two ways on one row of chips.
    func testControlShortcutChipsFollowTheNotation() {
        XCTAssertEqual(AccessoryChip.ctrlC.displayLabel(.glyph), "⌃C")
        XCTAssertEqual(AccessoryChip.ctrlJ.displayLabel(.glyph), "⌃J")
        XCTAssertEqual(AccessoryChip.ctrlC.displayLabel(.words), "ctrl-c")
        XCTAssertEqual(AccessoryChip.ctrlJ.displayLabel(.words), "ctrl-j")
    }

    /// No chip may render a bare caret once control unified on ⌃ — that was
    /// exactly the inconsistency this pass closed, and it is easy to
    /// reintroduce by adding a `^X` chip later.
    func testNoChipStillUsesCaretNotation() {
        for chip in AccessoryChip.allCases {
            for notation in ModifierNotation.allCases {
                XCTAssertFalse(
                    chip.displayLabel(notation).hasPrefix("^"),
                    "\(chip.rawValue) still renders caret notation"
                )
            }
        }
    }

    /// Both defaults are checked, because the ^C/^J miss was invisible on iPad:
    /// only the iPhone bar ships those chips (iPad carries | and ~ instead).
    func testBothDefaultBarsRenderConsistentlyInBothNotations() {
        for idiom in [UIUserInterfaceIdiom.phone, .pad] {
            for notation in ModifierNotation.allCases {
                for chip in AccessoryChip.defaultBarOrder(for: idiom) {
                    let label = chip.displayLabel(notation)
                    XCTAssertFalse(label.isEmpty)
                    XCTAssertFalse(
                        label.hasPrefix("^"),
                        "\(idiom) default bar chip \(chip.rawValue) renders \(label)"
                    )
                }
            }
        }
    }

    /// The words joiner is also a literal key. Nothing shipped binds it, but
    /// the recorder can produce one, and "cmd--" would be unreadable.
    func testMinusKeyDoesNotCollideWithTheWordsJoiner() {
        XCTAssertEqual(Chord([.command], .character("-")).rendered(.words), "cmd-minus")
        XCTAssertEqual(Chord([.command], .character("-")).rendered(.glyph), "⌘-")
    }

    // MARK: - Ordering

    /// Apple's canonical modifier order is ⌃⌥⇧⌘, and iPadOS renders our
    /// `UIKeyCommand`s in that order in the hold-⌘ shortcut HUD. Writing
    /// "⌘⇧E" in-app while the OS shows "⇧⌘E" for the same binding is a
    /// difference users notice, so the formatter follows the platform.
    ///
    /// (The pre-formatter codebase was split — the legend had four
    /// command-first rows and five shift-first rows. A single formatter forces
    /// one answer; this is it.)
    func testModifierOrderFollowsApplesCanonicalOrder() {
        XCTAssertEqual(Chord([.command, .shift], .character("w")).rendered(.glyph), "⇧⌘W")
        XCTAssertEqual(Chord([.command, .option], .left).rendered(.glyph), "⌥⌘←")
        XCTAssertEqual(Chord([.command, .control], .character("t")).rendered(.glyph), "⌃⌘T")
        // The user-facing sub-case that motivated words mode reads as intended.
        XCTAssertEqual(Chord([.control, .shift], .character("e")).rendered(.words), "ctrl-shift-e")
    }

    /// Modifier order is canonical regardless of how the set was built, so a
    /// chord recorded modifier-by-modifier renders like a hand-written one.
    func testModifierOrderIsCanonicalAndInsertionIndependent() {
        let a = Chord([.command, .shift, .control, .option], .character("x"))
        let b = Chord([.option, .control, .shift, .command], .character("x"))
        XCTAssertEqual(a.rendered(.glyph), "⌃⌥⇧⌘X")
        XCTAssertEqual(a.rendered(.glyph), b.rendered(.glyph))
        XCTAssertEqual(a.rendered(.words), "ctrl-opt-shift-cmd-x")
    }

    func testNonModifiersCannotSneakIntoTheModifierSet() {
        let chord = Chord([.command, .left], .character("k"))
        XCTAssertEqual(chord.modifiers, [.command])
        XCTAssertEqual(chord.rendered(.glyph), "⌘K")
    }

    // MARK: - Composites

    func testPairsAndRanges() {
        let pair = ChordPair(first: .cmdShift("k"), second: .cmdShift("j"))
        XCTAssertEqual(pair.rendered(.glyph), "⇧⌘K / ⇧⌘J")
        XCTAssertEqual(pair.rendered(.words), "shift-cmd-k / shift-cmd-j")

        let range = ChordRange(modifiers: [.command], from: "1", to: "9")
        XCTAssertEqual(range.rendered(.glyph), "⌘1 – ⌘9")
        XCTAssertEqual(range.rendered(.glyph, compact: true), "⌘1–9")
        // Repeating a word modifier on both ends is unreadable, so words mode
        // is compact whether or not the caller asks.
        XCTAssertEqual(range.rendered(.words), "cmd-1–9")
        XCTAssertEqual(range.rendered(.words, compact: true), "cmd-1–9")
    }

    // MARK: - Display must never reach the wire

    /// The bytes a chip sends are keyed off the `AccessoryChip` case, never off
    /// a display label. If a future refactor starts formatting the wire, this
    /// fails rather than shipping a preference that changes what the terminal
    /// receives.
    func testNotationNeverChangesTheBytesAChipSends() {
        let armed = ArmedModifiers.none
        // Modifier chips never reach the encoder — `AccessoryChipEncoder`
        // preconditions on it, because they arm state instead of sending bytes.
        for chip in AccessoryChip.allCases where !chip.isModifier {
            let bytes = AccessoryChipEncoder.encode(chip, armed: armed, applicationCursor: false)
            let appBytes = AccessoryChipEncoder.encode(chip, armed: armed, applicationCursor: true)

            // Labels genuinely differ for the four modifier-notation chips…
            _ = chip.displayLabel(.glyph)
            _ = chip.displayLabel(.words)

            // …while the encoding is a pure function of the case and cursor mode.
            XCTAssertEqual(
                bytes,
                AccessoryChipEncoder.encode(chip, armed: armed, applicationCursor: false),
                "\(chip.rawValue) encoding must be independent of display state"
            )
            XCTAssertEqual(
                appBytes,
                AccessoryChipEncoder.encode(chip, armed: armed, applicationCursor: true),
                "\(chip.rawValue) app-cursor encoding must be independent of display state"
            )
        }
    }

    /// Only keys that *are* modifier notation may move — the four bare
    /// modifiers, ⌘, and the two control shortcuts. A future chip that quietly
    /// starts varying its label would be a spelling change the user never
    /// asked for.
    func testExactlySevenChipsVaryWithNotation() {
        let varying = AccessoryChip.allCases.filter {
            $0.displayLabel(.glyph) != $0.displayLabel(.words)
        }
        XCTAssertEqual(Set(varying), Set([.ctrl, .alt, .shift, .cmd, .tab, .ctrlC, .ctrlJ]))
    }
}
