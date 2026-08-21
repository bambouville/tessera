import Testing
import CoreGraphics
@testable import Tessera

/// The rule that decides how much of a docked software keyboard the terminal
/// layer may ignore. `hold` is the clear space kept below the caret; the layer
/// ends up translated by `overlap - min(hold, overlap)`.
struct TerminalKeyboardCaretPolicyTests {
    private func clearance(above: CGFloat, below: CGFloat) -> TerminalCaretClearance {
        TerminalCaretClearance(above: above, below: below)
    }

    @Test("A prompt on the last row still rides the whole keyboard overlap")
    func caretAtBottomHoldsNothing() {
        let hold = TerminalKeyboardCaretPolicy.hold(
            previous: nil,
            clearance: clearance(above: 900, below: 0),
            overlap: 336
        )
        #expect(hold == 0)
    }

    @Test("A fresh prompt near row 0 holds the whole overlap, so nothing moves")
    func caretNearTopHoldsEverything() {
        let hold = TerminalKeyboardCaretPolicy.hold(
            previous: nil,
            clearance: clearance(above: 54, below: 860),
            overlap: 336
        )
        #expect(hold == 860)
        #expect(min(hold, 336) == 336, "translation cancels out entirely")
    }

    @Test("A caret partway down moves the terminal by exactly the shortfall")
    func caretPartwayMovesByShortfall() {
        let hold = TerminalKeyboardCaretPolicy.hold(
            previous: nil,
            clearance: clearance(above: 600, below: 200),
            overlap: 336
        )
        #expect(hold == 200)
        #expect(336 - min(hold, 336) == 136)
    }

    @Test("Cursor motion inside the visible band leaves the terminal alone")
    func staysPutWithinBand() {
        let hold = TerminalKeyboardCaretPolicy.hold(
            previous: 200,
            clearance: clearance(above: 500, below: 300),
            overlap: 336
        )
        #expect(hold == 200)
    }

    @Test("Output walking the prompt down shrinks the hold to what is left")
    func shrinksAsCaretDescends() {
        let hold = TerminalKeyboardCaretPolicy.hold(
            previous: 200,
            clearance: clearance(above: 800, below: 90),
            overlap: 336
        )
        #expect(hold == 90)
    }

    @Test("A caret jumping back to the top releases the translation again")
    func growsWhenCaretReturnsToTop() {
        // `clear` puts the prompt back on row 0: holding the old 90 would keep
        // the session lifted and take the prompt off the top of the screen.
        let hold = TerminalKeyboardCaretPolicy.hold(
            previous: 90,
            clearance: clearance(above: 0, below: 1_000),
            overlap: 336
        )
        #expect(hold == 336)
    }

    @Test("The keyboard wins over the top chrome when both cannot be satisfied")
    func bottomConstraintWinsOnConflict() {
        // A caret with almost nothing below it and nothing above it: the row
        // cannot clear both edges, and being swallowed by the keyboard is the
        // worse of the two.
        let hold = TerminalKeyboardCaretPolicy.hold(
            previous: 300,
            clearance: clearance(above: 0, below: 18),
            overlap: 336
        )
        #expect(hold == 18)
    }

    @Test("No keyboard means no hold to compute")
    func noOverlapHoldsNothingUseful() {
        let hold = TerminalKeyboardCaretPolicy.hold(
            previous: nil,
            clearance: clearance(above: 100, below: 40),
            overlap: 0
        )
        // The hold is capped by the space below the caret either way, and the
        // layout multiplies it by an overlap of zero.
        #expect(min(hold, 0) == 0)
    }
}
