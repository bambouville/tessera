import XCTest
import SwiftTerm
@testable import TmuxControl

/// Cell-model oracle for the deep gray/BCE scrollback regression. This feeds
/// real repaint bytes into SwiftTerm and inspects every retained history row;
/// it is deterministic, sub-second, and verifies correctness rather than the
/// old harness's "some pixels changed" proxy.
@MainActor
final class TerminalScrollbackOracleTests: XCTestCase {
    private let esc = "\u{1B}"

    func test_repaintSeamsDoNotPlantColoredTailsInDeepScrollback() {
        for columns in [40, 73] {
            assertNoColoredTails(columns: columns, rows: 8, capturePairs: 36)
        }
    }

    private func assertNoColoredTails(
        columns: Int,
        rows: Int,
        capturePairs: Int
    ) {
        let delegate = NullTerminalDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: columns, rows: rows, scrollback: 512)
        )
        var capture: [String] = []
        for pair in 0..<capturePairs {
            let color = UInt8(17 + (pair % 180))
            let fullPrefix = String(format: "FULL_%03d_", pair)
            capture.append(
                "\(esc)[48;5;\(color)m"
                    + fullPrefix
                    + String(repeating: "#", count: columns - fullPrefix.count)
            )
            capture.append(String(format: "SHORT_%03d", pair))
        }

        let bytes = RepaintAssembly.assemble(
            state: makeState(),
            captureLines: capture,
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: false,
            clientRows: rows
        )
        terminal.feed(byteArray: bytes)

        var checkedShortRows = 0
        for row in 0..<1_024 {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            let cells = line.getData()
            let text = String(cells.map { $0.getCharacter() })
            guard text.contains("SHORT_") else { continue }
            checkedShortRows += 1

            guard let firstContent = cells.first(where: { $0.getCharacter() != " " }) else {
                XCTFail("short row unexpectedly empty at width \(columns)")
                continue
            }
            if case .ansi256 = firstContent.attribute.bg {
                // expected: capture-pane's active background applies to text
            } else {
                XCTFail("short-row content lost its intended background at width \(columns)")
            }

            XCTAssertEqual(
                cells.last?.attribute.bg,
                .defaultColor,
                "colored BCE tail survived in deep scrollback at width \(columns), row \(row)"
            )
        }
        XCTAssertEqual(checkedShortRows, capturePairs)
    }

    private func makeState() -> TmuxController.RenderedPaneState {
        TmuxController.RenderedPaneState(
            paneId: PaneId(1),
            cursorX: 0,
            cursorY: 0,
            paneTitle: nil,
            paneTitleIsDefault: true,
            windowName: nil,
            paneInAltScreen: false,
            historySize: nil,
            scrollRegionUpper: nil,
            scrollRegionLower: nil,
            cursorVisible: true,
            insertMode: nil,
            keypadCursor: nil,
            keypadApplication: nil,
            wrapMode: nil,
            mouseStandard: nil,
            mouseButton: nil,
            mouseAll: nil,
            mouseSgr: nil,
            originMode: nil,
            altSavedX: nil,
            altSavedY: nil
        )
    }
}

private final class NullTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
