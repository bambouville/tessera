// TesseraTests/TerminalPasteInputMirrorTests.swift
//
// Regression cover for the "typing after a paste eats the last pasted
// character" defect reported from an iPad on 2026-09-18 (v0.3.6 build 7).
//
// SwiftTerm's iOS view keeps a UITextInput mirror (`textInputStorage`) of the
// characters it has typed, because UIKit phrases its edits as offsets into a
// document: `deleteBackward()` and `replace(_:withText:)` both turn those
// offsets into backspaces addressed to the remote shell. `paste(_:)` wrote
// straight to the terminal without touching the mirror, so after a paste the
// mirror still described the line as it stood *before* it. UIKit then read a
// trailing space that was no longer at the end of the line, applied the
// double-space "." shortcut, and the compensating backspace landed on the last
// pasted character.
//
// The capture shows that signature exactly: `…commit.txt` became `…commit.tx`
// followed by two spaces — one backspace plus the two-space replacement text
// that `normalizedTextForPendingAutoPeriodDelete` emits for ". ".
//
// The fix drops the mirror whenever bytes reach the terminal by a route the
// mirror does not model. UIKit builds the substitution out of what the document
// says, so an empty document leaves it nothing to substitute; these tests hold
// the document state that guarantee rests on, and the edit shapes that would
// otherwise reach past the paste.
//
// They drive the byte stream, not pixels — the terminal renders on a
// CAMetalLayer and screenshots it as solid black.

import UIKit
import XCTest
import SwiftTerm
@testable import Tessera

@MainActor
final class TerminalPasteInputMirrorTests: XCTestCase {

    // MARK: - Harness

    /// Records everything the view addresses to the remote.
    private final class SendRecorder: NSObject, TerminalViewDelegate {
        var sent: [UInt8] = []
        /// One entry per write: each becomes one session command.
        var writes: [[UInt8]] = []

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            sent.append(contentsOf: data)
            writes.append(Array(data))
        }

        var sentText: String { String(decoding: sent, as: UTF8.self) }

        func reset() {
            sent.removeAll()
            writes.removeAll()
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    private let backspace: UInt8 = 0x7f

    private func makeTerminal() -> (TesseraResponderAwareTerminalView, SendRecorder) {
        let view = TesseraResponderAwareTerminalView(
            frame: CGRect(x: 0, y: 0, width: 900, height: 600)
        )
        view.layoutIfNeeded()
        let recorder = SendRecorder()
        view.terminalDelegate = recorder
        return (view, recorder)
    }

    /// What the input system can see of the line — the document UIKit reads
    /// before deciding whether a substitution is available.
    private func documentText(_ view: TesseraResponderAwareTerminalView) -> String {
        guard let whole = view.textRange(
            from: view.beginningOfDocument,
            to: view.endOfDocument
        ) else { return "" }
        return view.text(in: whole) ?? ""
    }

    /// Reproduces the line from the capture: text typed by hand, ending in the
    /// space that armed the shortcut, then the pasted path.
    private func typeThenPaste(
        _ view: TesseraResponderAwareTerminalView,
        typed: String = "test pasting ",
        pasted: String = "/tmp/tessera-mosh-history-commit.txt"
    ) {
        for character in typed {
            view.insertText(String(character))
        }
        UIPasteboard.general.string = pasted
        view.paste(nil)
    }

    // MARK: - The reported defect

    /// The defect's precondition. Before the fix the document still read
    /// `"test pasting "`, so UIKit could name the trailing space, ask for it to
    /// be deleted, and hand back ". " — and the deletion landed on the pasted
    /// `t` instead. With nothing in the document there is no space to name.
    func testPasteLeavesTheInputSystemNoTrailingSpaceToSubstitute() {
        let (view, _) = makeTerminal()
        typeThenPaste(view)

        XCTAssertEqual(
            documentText(view),
            "",
            """
            After a paste the view has typed nothing that is still at the end of \
            the line, and must say so: any character it still claims is a \
            character a UIKit substitution can try to delete through it.
            """
        )
        XCTAssertFalse(
            view.hasText,
            "hasText is the same claim in the form UIKeyInput asks for"
        )
    }

    /// The shape UIKit uses when it expresses the substitution as a range
    /// replacement: `replace(_:withText:)` emits one backspace per character of
    /// the range it is handed, so a range that outlived the paste would eat
    /// exactly the characters the report describes.
    func testRangeReplacementAfterAPasteSendsNoBackspaces() {
        let (view, recorder) = makeTerminal()
        typeThenPaste(view)

        recorder.reset()
        if let widest = view.textRange(
            from: view.beginningOfDocument,
            to: view.endOfDocument
        ) {
            view.replace(widest, withText: ". ")
        }

        XCTAssertFalse(
            recorder.sent.contains(backspace),
            """
            The widest range the input system can name after a paste covers \
            nothing, so no backspace is owed and none may be sent. \
            Sent: \(recorder.sentText.debugDescription)
            """
        )
    }

    func testPasteFollowedByAPlainSpaceSendsOnlyThatSpace() {
        let (view, recorder) = makeTerminal()
        typeThenPaste(view)

        recorder.reset()
        view.insertText(" ")

        XCTAssertEqual(
            recorder.sentText,
            " ",
            "A space typed after a paste is just a space on the wire"
        )
    }

    /// S5′: the session's authority gate decides per write. SwiftTerm's three
    /// writes would let a take-over land between the opening delimiter and
    /// the text, leaving the application inside a paste that never ends.
    func testABracketedPasteReachesTheSessionAsOneWrite() {
        let (view, recorder) = makeTerminal()
        view.feed(text: "\u{1b}[?2004h")
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)
        recorder.reset()

        UIPasteboard.general.string = "make\ntest"
        view.paste(nil)

        XCTAssertEqual(
            recorder.writes,
            [Array("\u{1b}[200~make\ntest\u{1b}[201~".utf8)],
            "Writes: \(recorder.writes.map { String(decoding: $0, as: UTF8.self) }.debugDescription)"
        )
    }

    func testPastedTextItselfStillReachesTheTerminal() {
        let (view, recorder) = makeTerminal()
        UIPasteboard.general.string = "hello"
        view.paste(nil)

        XCTAssertTrue(
            recorder.sentText.contains("hello"),
            "Dropping the mirror must not disturb the paste itself"
        )
    }

    // MARK: - What the fix must not break

    /// With no paste in the way the mirror really does own the trailing space,
    /// and the compensation must still turn UIKit's delete-then-". " back into
    /// the two spaces the user typed.
    func testAutoPeriodStillCompensatesWhenTheMirrorOwnsTheLine() {
        let (view, recorder) = makeTerminal()
        view.insertText("a")
        view.insertText(" ")

        recorder.reset()
        view.deleteBackward()
        view.insertText(". ")

        XCTAssertEqual(
            recorder.sent,
            [backspace] + Array("  ".utf8),
            """
            One backspace over the space the mirror owns, then the two spaces \
            the user meant. Sent: \(recorder.sentText.debugDescription)
            """
        )
    }

    /// Backspace after a paste is the user asking to delete a character, and
    /// must still reach the remote: the empty mirror falls through to the raw
    /// backspace path rather than concluding there is nothing to delete.
    func testBackspaceAfterAPasteStillSendsOneBackspace() {
        let (view, recorder) = makeTerminal()
        typeThenPaste(view)

        recorder.reset()
        view.deleteBackward()

        XCTAssertEqual(
            recorder.sent,
            [backspace],
            "Delete after a paste still deletes one character"
        )
    }

    /// Composition state belongs to the keyboard, not to the line; a paste that
    /// lands mid-composition must leave no marked range behind for the next
    /// edit to be measured against.
    func testPasteClearsAnyMarkedText() {
        let (view, _) = makeTerminal()
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(view.markedTextRange, "precondition: composing")

        UIPasteboard.general.string = "/tmp/file.txt"
        view.paste(nil)

        XCTAssertNil(view.markedTextRange)
    }

    // MARK: - Host-driven injection

    /// The Files panel's "send path" and the swipe pad's macros and dictation
    /// results type a blob into the same line without going through the view,
    /// so they carry the same hazard and say so through
    /// `TerminalBox.noteOutOfBandInput()`.
    func testOutOfBandInputNotificationDropsTheMirror() {
        let (view, _) = makeTerminal()
        let box = TerminalBox(traceLabel: "paste-mirror-test")
        box.attach(view)

        view.insertText("a")
        view.insertText(" ")
        XCTAssertEqual(documentText(view), "a ", "precondition: the mirror is holding a trailing space")

        // Stands in for the injected bytes, which reach the session directly
        // rather than through the view.
        box.noteOutOfBandInput()

        XCTAssertEqual(
            documentText(view),
            "",
            """
            An injection the view never saw leaves the mirror describing a line \
            that no longer exists; once the host says so, nothing is left for a \
            substitution to delete through.
            """
        )
    }
}
