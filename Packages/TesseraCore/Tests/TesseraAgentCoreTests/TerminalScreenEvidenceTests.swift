import XCTest
@testable import TesseraAgentCore

final class TerminalScreenEvidenceTests: XCTestCase {
    func testClaudeHiddenHardwareCursorNeedsOneInversePhysicalCell() {
        for text in ["suggestion", "界e\u{301}😀"] {
            let empty = makeScreen(text: text, suggestion: true, softwareCursor: 2, cursorVisible: false)
            XCTAssertEqual(assess(empty), .readyReturn)
            XCTAssertEqual(assess(makeScreen(text: text, suggestion: false, softwareCursor: 2, cursorVisible: false)), .occupied)
            XCTAssertEqual(assess(makeScreen(text: text, suggestion: true, cursorVisible: false)), .blocked)
        }
        let inserted = makeScreen(text: "hello draft ", suggestion: false, softwareCursor: 13, cursorVisible: false)
        XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: "",
            cursorRow: 0, cursorColumn: 13, cursorVisible: false, requireEmpty: false, queueWhenWorking: false,
            text: "hello draft", screen: inserted), .readyReturn)
    }

    func testCodexEffortMarkersUseCellStylesWithoutDiscardingTypedDrafts() throws {
        for marker in ["›", "»"] {
            for text in ["Ask Codex to do anything", "Implement {feature}", "界e\u{301}😀"] {
                let empty = makeScreen(text: text, suggestion: true, codexMarker: marker)
                XCTAssertEqual(assess(empty, provider: "codex"), .readyReturn, marker)
                XCTAssertEqual(assess(makeScreen(text: text, suggestion: false, codexMarker: marker), provider: "codex"), .occupied, marker)
                XCTAssertEqual(try JSONDecoder().decode(TerminalScreenEvidence.self,
                    from: JSONEncoder().encode(empty)), empty)
            }
        }
    }

    func testTypedScreenRecognizesSuggestionWithoutANSIAndRejectsRealDraft() throws {
        for text in ["suggestion", "界e\u{301}😀"] {
            let screen = makeScreen(text: text, suggestion: true)
            XCTAssertEqual(assess(screen), .readyReturn)
            XCTAssertEqual(assess(makeScreen(text: text, suggestion: false)), .occupied)
            XCTAssertEqual(try JSONDecoder().decode(TerminalScreenEvidence.self,
                from: JSONEncoder().encode(screen)), screen)
        }
    }

    func testIncompleteGeometryAndControlsNeverBecomeEmptyComposerEvidence() {
        var screen = makeScreen(text: "suggestion", suggestion: true)
        screen = .init(columns: screen.columns, cells: screen.cells, wrappedRows: screen.wrappedRows,
            cursorRow: 0, cursorColumn: 2, cursorVisible: true, isAlternate: false, complete: false)
        XCTAssertEqual(assess(screen), .unavailable)
        XCTAssertNil(TerminalScreenEvidence(columns: 1, cells: [[.init(text: "\u{1b}", width: 1, style: 0)]],
            wrappedRows: [false], cursorRow: 0, cursorColumn: 0, cursorVisible: true, isAlternate: false).plainText)
        XCTAssertNil(TerminalScreenEvidence(columns: 1, cells: [[.init(text: "界", width: 2, style: 0)]],
            wrappedRows: [false], cursorRow: 0, cursorColumn: 0, cursorVisible: true, isAlternate: false).plainText)
        XCTAssertEqual(AgentComposerEvidence.safety(provider: "claude", visibleText: "",
            cursorRow: 0, cursorColumn: 3, cursorVisible: true, requireEmpty: true,
            queueWhenWorking: false, screen: makeScreen(text: "suggestion", suggestion: true)), .unavailable)
    }

    private func assess(_ screen: TerminalScreenEvidence, provider: String = "claude") -> AgentComposerEvidence.Safety {
        AgentComposerEvidence.safety(provider: provider, visibleText: "",
            cursorRow: screen.cursorRow, cursorColumn: screen.cursorColumn,
            cursorVisible: screen.cursorVisible, requireEmpty: true, queueWhenWorking: false, screen: screen)
    }

    private func makeScreen(text: String, suggestion: Bool, codexMarker: String? = nil,
                            softwareCursor: Int? = nil, cursorVisible: Bool = true) -> TerminalScreenEvidence {
        let columns = 32
        func row(_ text: String, style: UInt8 = 0) -> [TerminalScreenEvidence.Cell] {
            var result: [TerminalScreenEvidence.Cell] = []
            for character in text {
                let width = character == "界" || character == "😀" ? 2 : 1
                result.append(.init(text: String(character), width: width, style: style))
                if width == 2 { result.append(.init(text: "", width: 0, style: style)) }
            }
            while result.count < columns { result.append(.init(text: " ", width: 1, style: 0)) }
            return result
        }
        var composer = Array(row((codexMarker ?? "❯") + " ").prefix(2))
        composer += row(text, style: suggestion ? 32 : 0).prefix(columns - 2)
        if let softwareCursor {
            let cell = composer[softwareCursor]
            composer[softwareCursor] = .init(text: cell.text, width: cell.width, style: 8)
            if cell.width == 2 { composer[softwareCursor + 1] = .init(text: "", width: 0, style: 8) }
        }
        let footer = codexMarker == nil ? [row("────────"), row("ctx: 5%")] : [row(""), row("GPT-6.1-Sol ultra · ~/repo"), row("? for shortcuts")]
        let rows = [composer] + footer
        return .init(columns: columns, cells: rows,
            wrappedRows: Array(repeating: false, count: rows.count), cursorRow: 0, cursorColumn: softwareCursor ?? 2,
            cursorVisible: cursorVisible, isAlternate: false)
    }
}
