import XCTest
@testable import TmuxControlCore

final class RepaintMouseModeTests: XCTestCase {
    func testRepaintPreservesTheFullestRequestedMouseMode() throws {
        for (standard, button, all, expected) in [
            (true, true, true, 1003), (true, false, true, 1003),
            (false, false, true, 1003), (true, true, false, 1002),
            (false, true, false, 1002), (true, false, false, 1000),
        ] {
            let state = try XCTUnwrap(TmuxRenderedPaneStateParser.parse(metadata(
                standard: standard, button: button, all: all, sgr: true
            )))
            for alreadyAlternate in [false, true] {
                let bytes = TmuxRepaintAssembly.assemble(
                    state: state, captureLines: ["TRANSCRIPT", "KEEP MY DRAFT"],
                    historyLines: [], savedPrimaryLines: [], altScreenLines: nil,
                    terminalIsInAltScreen: alreadyAlternate, clientRows: 24
                )
                let text = String(decoding: bytes, as: UTF8.self)
                for mode in [1000, 1002, 1003] {
                    XCTAssertEqual(text.contains("\u{1B}[?\(mode)h"), mode == expected)
                }
                XCTAssertTrue(text.contains("\u{1B}[?1006h"))
            }
        }
    }

    func testMouseOffRepaintDoesNotRetainAnotherPanesMouseMode() throws {
        let state = try XCTUnwrap(TmuxRenderedPaneStateParser.parse(metadata(
            standard: false, button: false, all: false, sgr: false
        )))
        let text = String(decoding: TmuxRepaintAssembly.assemble(
            state: state, captureLines: ["NO MOUSE"], historyLines: [],
            savedPrimaryLines: [], altScreenLines: nil,
            terminalIsInAltScreen: true, clientRows: 24
        ), as: UTF8.self)
        for mode in [1000, 1002, 1003, 1006] {
            XCTAssertTrue(text.contains("\u{1B}[?\(mode)l"))
            XCTAssertFalse(text.contains("\u{1B}[?\(mode)h"))
        }
    }

    private func metadata(standard: Bool, button: Bool, all: Bool, sgr: Bool) -> String {
        ["%11", "2", "2", "Codex", "work", "fixture", "1", "0", "0", "23",
         "1", "0", "0", "0", "1", standard ? "1" : "0", button ? "1" : "0",
         all ? "1" : "0", sgr ? "1" : "0", "0", "0", "0", "80", "24"]
            .joined(separator: "\t")
    }
}
