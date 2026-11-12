import SwiftTerm
import TmuxControlCore
import UIKit
import XCTest
@testable import Tessera

@MainActor
final class SessionPathInputTests: XCTestCase {
    func testGridPathInputClearsFocusedAndFallbackMirrorsWithoutTouchingOtherPanes() throws {
        let focused = TerminalBox(traceLabel: "path-focused-test")
        let fallback = TerminalBox(traceLabel: "path-fallback-test")
        let other = TerminalBox(traceLabel: "path-other-test")
        let focusedView = makeEditor(box: focused, text: "cat ")
        let fallbackView = makeEditor(box: fallback, text: "fallback ")
        let otherView = makeEditor(box: other, text: "other ")
        XCTAssertEqual(try documentText(focusedView), "cat ")
        XCTAssertEqual(try documentText(fallbackView), "fallback ")

        // typeRemotePath uses this resolution immediately before acknowledged
        // input. The transport itself is deliberately absent from this test.
        let boxes = SessionDuoInput.pathInputBoxes(target: focused, fallback: fallback)
        XCTAssertEqual(boxes.map(ObjectIdentifier.init), [ObjectIdentifier(focused), ObjectIdentifier(fallback)])
        boxes.forEach { $0.noteOutOfBandInput() }

        XCTAssertEqual(try documentText(focusedView), "")
        XCTAssertEqual(try documentText(fallbackView), "")
        XCTAssertEqual(try documentText(otherView), "other ")
    }

    func testSingleSurfacePathInputResolvesTheFallbackOnlyOnce() {
        let fallback = TerminalBox(traceLabel: "path-single-test")
        for target: TerminalBox? in [fallback, nil] {
            XCTAssertEqual(SessionDuoInput.pathInputBoxes(target: target, fallback: fallback)
                .map(ObjectIdentifier.init), [ObjectIdentifier(fallback)])
        }
    }

    /// Phones mount the focused grid pane's own surface too, so the resolver
    /// has no idiom input: the pane's mirror is the one to clear.
    func testGridInputResolvesTheFocusedPaneBox() {
        let shared = TerminalBox(traceLabel: "path-shared-test")
        let pane = TerminalBox(traceLabel: "path-pane-test")
        let boxes = [PaneId(3): pane]
        let resolve = { (grid: Bool, paneID: PaneId?) in
            SessionDuoInput.inputBox(gridActive: grid, activePaneID: paneID, shared: shared) { boxes[$0] }
        }
        XCTAssertTrue(resolve(true, PaneId(3)) === pane)
        XCTAssertNil(resolve(true, PaneId(4)), "an unregistered pane has no editor yet")
        XCTAssertNil(resolve(true, nil))
        XCTAssertTrue(resolve(false, PaneId(3)) === shared)
        XCTAssertEqual(SessionDuoInput.pathInputBoxes(target: resolve(true, PaneId(3)), fallback: shared)
            .map(ObjectIdentifier.init), [ObjectIdentifier(pane), ObjectIdentifier(shared)])
    }

    private func makeEditor(box: TerminalBox, text: String) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 669, height: 400))
        box.attach(view)
        view.insertText(text)
        return view
    }

    private func documentText(_ view: TerminalView) throws -> String {
        let range = try XCTUnwrap(view.textRange(from: view.beginningOfDocument, to: view.endOfDocument))
        return view.text(in: range) ?? ""
    }
}
