import Foundation
import XCTest
import TesseraAgentCore
@testable import TesseraCoreABI

final class TerminalScreenEvidenceABITests: XCTestCase {
    func testEveryAdmittedGridBudgetFitsTheComposerABI() throws {
        // Cross the former 256 KiB JSON ceiling and exercise the cell ceiling.
        for (columns, rows) in [(240, 120), (256, 255), (65_534, 1), (65_536, 1)] {
            var cells = Array(repeating: Array(repeating: TerminalScreenEvidence.Cell(text: " ", width: 1, style: 0), count: columns), count: rows)
            if columns < 65_536 { cells[0][0] = .init(text: "›", width: 1, style: 0) }
            // Typed content avoids the empty-composer footer grammar while
            // still exercising shared row/column/schema admission completely.
            cells[0][2] = .init(text: "x", width: 1, style: 0)
            let screen = TerminalScreenEvidence(columns: columns, cells: cells,
                wrappedRows: Array(repeating: false, count: rows), cursorRow: 0, cursorColumn: 3,
                cursorVisible: true, isAlternate: false)
            let plain = try XCTUnwrap(screen.plainText)
            let screenObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(screen))
            let input = try JSONSerialization.data(withJSONObject: ["provider": "codex", "text": "x",
                "visibleText": plain, "cursorRow": 0, "cursorColumn": 3, "cursorVisible": true,
                "safetyOnly": true, "requireEmpty": false, "screen": screenObject])
            XCTAssertLessThanOrEqual(input.count, 2 * 1_024 * 1_024)
            XCTAssertGreaterThan(input.count, 256 * 1_024)
            XCTAssertEqual(input.withUnsafeBytes {
                tesseraAgentComposerAssess(inputBytes: $0.baseAddress?.assumingMemoryBound(to: UInt8.self), inputCount: $0.count)
            }, columns == 65_536 ? -1 : 1)
        }
    }

    func testTypedNativeScreenCrossesABIWithoutANSIOrStyleLoss() throws {
        let columns = 32
        func row(_ text: String, suggestion: Bool = false) -> [TerminalScreenEvidence.Cell] {
            var cells = text.enumerated().map { index, char in
                TerminalScreenEvidence.Cell(text: String(char), width: 1,
                    style: suggestion && index > 2 ? 32 : suggestion && index == 2 ? 8 : 0)
            }
            cells += Array(repeating: .init(text: " ", width: 1, style: 0), count: columns - cells.count)
            return cells
        }
        for (suggestion, complete, expected) in [(true, true, Int32(1)), (false, true, Int32(4)), (true, false, Int32(-1))] {
            let screen = TerminalScreenEvidence(columns: columns, cells: [row("❯ suggested", suggestion: suggestion), row("────────")],
                wrappedRows: [false, false], cursorRow: 0, cursorColumn: 2, cursorVisible: true,
                isAlternate: false, complete: complete)
            let screenObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(screen))
            let input = try JSONSerialization.data(withJSONObject: ["provider": "claude", "text": "next",
                "visibleText": "", "cursorRow": 0, "cursorColumn": 2, "cursorVisible": true,
                "safetyOnly": true, "requireEmpty": true, "screen": screenObject])
            XCTAssertEqual(input.withUnsafeBytes {
                tesseraAgentComposerAssess(inputBytes: $0.baseAddress?.assumingMemoryBound(to: UInt8.self), inputCount: $0.count)
            }, expected)
        }
    }
}
