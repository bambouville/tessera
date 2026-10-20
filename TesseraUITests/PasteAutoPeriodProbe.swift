import XCTest

/// Repro rig for the reported "typing after a paste eats the last pasted
/// character" defect (iPad, v0.3.6 build 7, 2026-09-18).
///
/// The mechanism is iOS's double-space "." shortcut. UIKit expresses it against
/// the document a `UITextInput` advertises, and SwiftTerm's document is a mirror
/// of the characters the view itself typed. `paste(_:)` used to write straight
/// to the terminal without touching that mirror, so UIKit still saw the space
/// typed *before* the paste, asked for it back, and the compensating backspace
/// landed on the last pasted character. The capture shows the signature exactly:
/// one character gone, two spaces in its place.
///
/// Host-free: it drives the production SwiftTerm responder through the
/// `TESSERA_IPHONE_KEYBOARD_HARNESS` screen, whose `onSend` records the wire
/// instead of opening a connection, so the never-auto-connect rule holds.
///
/// The control arm is what makes the subject arm mean anything: whether UIKit
/// offers the shortcut at all depends on the keyboard the simulator is driving,
/// so a green subject arm proves nothing unless the control arm shows the rig
/// can provoke it. Read both, and read `[probe] … keyboard=` first.
final class PasteAutoPeriodProbe: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["TESSERA_IPHONE_KEYBOARD_HARNESS"] = "1"
        app.launchEnvironment["TESSERA_KEYBOARD_HARNESS_PASTE"] = "1"
    }

    // MARK: - Rig

    /// The terminal is a `UIScrollView` subclass, so it does not land in any of
    /// the convenience collections — look it up by identifier across all types,
    /// the way the other keyboard-harness tests do.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func launchAndFocus() {
        app.launch()
        let terminal = element("iphone-keyboard-terminal")
        XCTAssertTrue(terminal.waitForExistence(timeout: 30), "harness terminal never appeared")

        // The shortcut belongs to the keyboard, so it has to be up before any of
        // this means anything. The harness publishes its own visibility.
        let state = element("iphone-keyboard-state")
        if state.waitForExistence(timeout: 10), (state.value as? String) != "visible" {
            terminal.tap()
            let shown = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", "visible"),
                object: state
            )
            XCTAssertEqual(
                XCTWaiter().wait(for: [shown], timeout: 10),
                .completed,
                "software keyboard never came up — the shortcut cannot be provoked"
            )
        }
        XCTAssertTrue(element("harness-wire").waitForExistence(timeout: 10), "paste rig not armed")
        print("[probe] keyboard=\(app.keyboards.count) keys=\(app.keys.count) softwareSpaceKey=\(app.keys["space"].exists)")
        let labels = app.keys.allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }
        print("[probe] keyLabels=\(labels.joined(separator: ","))")
    }

    /// Every spelled byte the view has sent since launch. The rig asserts on the
    /// whole stream rather than clearing between steps, so a step that silently
    /// does nothing shows up instead of hiding.
    private func wire() -> String {
        element("harness-wire").label
    }

    private func paste() {
        element("harness-paste").tap()
    }

    /// Tap the on-screen key when there is one. `typeText` falls back to the
    /// hardware path, which skips the keyboard's own text processing — and the
    /// shortcut lives in that processing.
    private func type(_ text: String) {
        // Tap the on-screen key. `typeText` reaches the text input by a route
        // that skips the keyboard's own text processing, and the shortcut lives
        // in that processing — typing through it would measure nothing.
        if let key = softwareKey(for: text) {
            key.tap()
        } else {
            app.typeText(text)
        }
    }

    private func softwareKey(for text: String) -> XCUIElement? {
        let wanted = text == " " ? ["space", "Space", " "] : [text]
        for name in wanted {
            let byIdentifier = app.keys[name]
            if byIdentifier.exists { return byIdentifier }
            let byLabel = app.keys.matching(NSPredicate(format: "label == %@", name)).firstMatch
            if byLabel.exists { return byLabel }
        }
        return nil
    }

    // MARK: - Control arm

    /// Nothing has disturbed the mirror, so the shortcut is legitimate and
    /// SwiftTerm's compensation must undo it: one backspace over the space the
    /// mirror owns, then the two spaces the user meant.
    ///
    /// This arm is also the rig's own oracle. If it records `a sp sp`, this
    /// simulator's keyboard never offered the shortcut and the subject arm below
    /// is inconclusive rather than passing.
    func testDoubleSpaceWithoutAPasteStillFiresTheShortcut() {
        launchAndFocus()
        type("a")
        type(" ")
        type(" ")

        let observed = wire()
        print("[probe] control wire=\(observed)")
        XCTAssertEqual(
            observed,
            "a sp del sp sp",
            """
            Expected the "." shortcut to fire and SwiftTerm to compensate it. \
            A bare "a sp sp" means this simulator's keyboard does not offer the \
            shortcut, so the subject arm cannot be graded here.
            """
        )
    }

    // MARK: - Subject arm

    /// The reported sequence: type, end on a space, paste, then type a space.
    /// The pasted text is the last thing on the line, so any backspace after it
    /// is eating it.
    func testSpaceAfterAPasteDoesNotBackspaceOverIt() {
        launchAndFocus()
        type("a")
        type(" ")
        paste()
        let afterPaste = wire()
        XCTAssertTrue(afterPaste.hasSuffix("t x t"), "paste did not land — wire: \(afterPaste)")

        type(" ")
        let observed = wire()
        print("[probe] subject wire=\(observed)")

        let afterwards = String(observed.dropFirst(afterPaste.count))
        XCTAssertFalse(
            afterwards.contains("del"),
            """
            A space typed after a paste sent a backspace — it deletes the tail \
            of the pasted text, which is the reported defect. \
            After the paste: \(afterwards.debugDescription)
            """
        )
        XCTAssertEqual(
            afterwards.trimmingCharacters(in: .whitespaces),
            "sp",
            "the keystroke is just a space on the wire"
        )
    }
}
