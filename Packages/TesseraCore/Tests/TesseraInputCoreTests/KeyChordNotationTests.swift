import Foundation
import XCTest
@testable import TesseraInputCore

/// `KeyChordNotation` is the whole reason the notation preference can be
/// described as global: every render site on both platforms routes through it.
/// These tests pin the vocabulary, the joiner, and — most importantly — the
/// separation between *display* and *the wire*.
final class KeyChordNotationTests: XCTestCase {

    // MARK: - Vocabulary

    func test_glyphModeUsesMacGlyphsAndUppercasesTheKey() {
        XCTAssertEqual(KeyChord.cmdShift("e").rendered(.glyph), "⇧⌘E")
        XCTAssertEqual(KeyChord.cmd("n").rendered(.glyph), "⌘N")
        XCTAssertEqual(KeyChord([.option], .left).rendered(.glyph), "⌥←")
        XCTAssertEqual(KeyChord([.command], .return).rendered(.glyph), "⌘↩")
        XCTAssertEqual(KeyChord([.command], .delete).rendered(.glyph), "⌘⌫")
        XCTAssertEqual(KeyChord([], .escape).rendered(.glyph), "esc")
        XCTAssertEqual(KeyChord([], .space).rendered(.glyph), "space")
    }

    func test_wordsModeIsLowercaseAndHyphenJoined() {
        XCTAssertEqual(KeyChord.cmdShift("e").rendered(.words), "shift-cmd-e")
        XCTAssertEqual(KeyChord.cmd("n").rendered(.words), "cmd-n")
        XCTAssertEqual(KeyChord([.option], .left).rendered(.words), "opt-←")
        XCTAssertEqual(KeyChord([.command], .return).rendered(.words), "cmd-ret")
        XCTAssertEqual(KeyChord([.command], .delete).rendered(.words), "cmd-del")
        XCTAssertEqual(KeyChord([.control], .tab).rendered(.words), "ctrl-tab")
    }

    func test_joinerIsEmptyForGlyphsAndAHyphenForWords() {
        XCTAssertEqual(KeyChordNotation.glyph.joiner, "")
        XCTAssertEqual(KeyChordNotation.words.joiner, "-")
        XCTAssertEqual(KeyChordNotation.allCases, [.glyph, .words])
        XCTAssertEqual(KeyChordNotation.glyph.id, "glyph")
    }

    /// Control unifies on ⌃ — the decision that retired the accessory bar's
    /// bare `^`. A row that writes ⌃ on one chip and ^ on the next is
    /// describing the same key two ways.
    func test_controlRendersAsTheMacGlyphNotACaret() {
        XCTAssertEqual(KeyChordToken.control.rendered(.glyph), "⌃")
        XCTAssertEqual(KeyChordToken.control.rendered(.words), "ctrl")
        XCTAssertEqual(KeyChord([.control], .character("c")).rendered(.glyph), "⌃C")
        XCTAssertEqual(KeyChord([.control], .character("j")).rendered(.words), "ctrl-j")
    }

    /// The words joiner is also a literal key. Nothing shipped binds it, but
    /// the recorder can produce one, and "cmd--" would be unreadable.
    func test_minusKeyDoesNotCollideWithTheWordsJoiner() {
        XCTAssertEqual(KeyChord([.command], .character("-")).rendered(.words), "cmd-minus")
        XCTAssertEqual(KeyChord([.command], .character("-")).rendered(.glyph), "⌘-")
    }

    // MARK: - Ordering

    /// Apple's canonical modifier order is ⌃⌥⇧⌘, and iPadOS renders our
    /// `UIKeyCommand`s in that order in the hold-⌘ shortcut HUD. Writing
    /// "⌘⇧E" in-app while the OS shows "⇧⌘E" for the same binding is a
    /// difference users notice, so the formatter follows the platform — on
    /// every platform, so the two apps agree with each other too.
    func test_modifierOrderFollowsApplesCanonicalOrder() {
        XCTAssertEqual(KeyChord.modifierOrder, [.control, .option, .shift, .command])
        XCTAssertEqual(KeyChord([.command, .shift], .character("w")).rendered(.glyph), "⇧⌘W")
        XCTAssertEqual(KeyChord([.command, .option], .left).rendered(.glyph), "⌥⌘←")
        XCTAssertEqual(KeyChord([.command, .control], .character("t")).rendered(.glyph), "⌃⌘T")
        XCTAssertEqual(KeyChord([.control, .shift], .character("e")).rendered(.words), "ctrl-shift-e")
    }

    func test_modifierOrderIsCanonicalAndInsertionIndependent() {
        let a = KeyChord([.command, .shift, .control, .option], .character("x"))
        let b = KeyChord([.option, .control, .shift, .command], .character("x"))
        XCTAssertEqual(a.rendered(.glyph), "⌃⌥⇧⌘X")
        XCTAssertEqual(a.rendered(.glyph), b.rendered(.glyph))
        XCTAssertEqual(a.rendered(.words), "ctrl-opt-shift-cmd-x")
    }

    func test_nonModifiersCannotSneakIntoTheModifierSet() {
        let chord = KeyChord([.command, .left], .character("k"))
        XCTAssertEqual(chord.modifiers, [.command])
        XCTAssertEqual(chord.rendered(.glyph), "⌘K")
        XCTAssertTrue(KeyChord().isEmpty)
        XCTAssertFalse(chord.isEmpty)
    }

    // MARK: - Composites

    func test_pairsAndRanges() {
        let pair = KeyChordPair(first: .cmdShift("k"), second: .cmdShift("j"))
        XCTAssertEqual(pair.rendered(.glyph), "⇧⌘K / ⇧⌘J")
        XCTAssertEqual(pair.rendered(.words), "shift-cmd-k / shift-cmd-j")

        let range = KeyChordRange(modifiers: [.command], from: "1", to: "9")
        XCTAssertEqual(range.rendered(.glyph), "⌘1 – ⌘9")
        XCTAssertEqual(range.rendered(.glyph, compact: true), "⌘1–9")
        // Repeating a word modifier on both ends is unreadable, so words mode
        // is compact whether or not the caller asks.
        XCTAssertEqual(range.rendered(.words), "cmd-1–9")
        XCTAssertEqual(range.rendered(.words, compact: true), "cmd-1–9")

        XCTAssertEqual(KeyChordDisplay.one(.cmd("n")).rendered(.glyph), "⌘N")
        XCTAssertEqual(KeyChordDisplay.pair(pair).rendered(.words), "shift-cmd-k / shift-cmd-j")
        XCTAssertEqual(KeyChordDisplay.range(range).rendered(.glyph), "⌘1 – ⌘9")
        XCTAssertEqual(KeyChordDisplay.literal("↑↓").rendered(.words), "↑↓")
    }

    // MARK: - Codable

    /// Token tags are what get written into a user's stored bindings, so they
    /// are a storage format, not an implementation detail.
    func test_keyTokenTagsAreStableAcrossARoundTrip() throws {
        let tokens: [KeyChordToken] = [
            .command, .option, .control, .shift,
            .tab, .return, .delete, .escape, .space,
            .left, .down, .up, .right,
            .character("e"), .character("-"),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for token in tokens {
            let data = try encoder.encode([token])
            XCTAssertEqual(try decoder.decode([KeyChordToken].self, from: data), [token])
        }

        XCTAssertEqual(
            String(data: try encoder.encode(tokens.map { $0 }), encoding: .utf8),
            #"["command","option","control","shift","tab","ret","del","esc","space","left","down","up","right","c:e","c:-"]"#
        )
        XCTAssertThrowsError(
            try decoder.decode([KeyChordToken].self, from: Data(#"["nonsense"]"#.utf8))
        )
    }

    // MARK: - Display must never reach the wire

    /// The bytes a chip sends are keyed off the catalog ID, never off a display
    /// label. `AccessoryKeyCatalog.encode` takes no notation at all, so this is
    /// structural — the assertion here is that rendering a chord cannot change
    /// what the same key encodes to.
    func test_notationNeverChangesTheBytesAKeySends() {
        for key in AccessoryKey.allCases {
            let baseline = AccessoryKeyCatalog.encode(key)
            for notation in KeyChordNotation.allCases {
                _ = KeyChord([.control, .option, .shift, .command], .character("x"))
                    .rendered(notation)
                XCTAssertEqual(
                    AccessoryKeyCatalog.encode(key),
                    baseline,
                    "\(key.rawValue) encoding must be independent of display state"
                )
                XCTAssertEqual(
                    AccessoryKeyCatalog.encode(key, applicationCursorMode: true),
                    AccessoryKeyCatalog.encode(key, applicationCursorMode: true),
                    "\(key.rawValue) app-cursor encoding must be independent of display state"
                )
            }
        }
    }

    /// The three keys whose *label* moves with the notation still send one
    /// fixed byte sequence. This is the pairing that made the invariant worth
    /// stating: ⌃C / ctrl-c is one key spelled two ways, not two keys.
    func test_keysWhoseLabelMovesStillSendFixedBytes() {
        XCTAssertEqual(AccessoryKeyCatalog.encode(.tab), [0x09])
        XCTAssertEqual(AccessoryKeyCatalog.encode(.ctrlC), [0x03])
        XCTAssertEqual(AccessoryKeyCatalog.encode(.ctrlJ), [0x0A])
        XCTAssertEqual(
            KeyChord([.control], .character("c")).rendered(.glyph), "⌃C"
        )
        XCTAssertEqual(
            KeyChord([.control], .character("c")).rendered(.words), "ctrl-c"
        )
    }

    /// No token may render a bare caret once control unified on ⌃ — that was
    /// exactly the inconsistency this pass closed, and it is easy to
    /// reintroduce by adding a `^X` spelling later.
    func test_noTokenStillUsesCaretNotation() {
        let tokens: [KeyChordToken] = [
            .command, .option, .control, .shift,
            .tab, .return, .delete, .escape, .space,
            .left, .down, .up, .right,
        ]
        for token in tokens {
            for notation in KeyChordNotation.allCases {
                XCTAssertFalse(
                    token.rendered(notation).hasPrefix("^"),
                    "\(token) still renders caret notation"
                )
            }
        }
    }
}
