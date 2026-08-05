import XCTest
import SwiftTerm
import UIKit
@testable import TmuxControl
@testable import Tessera

/// Cell-model oracle for the deep gray/BCE scrollback regression. This feeds
/// real repaint bytes into SwiftTerm and inspects every retained history row;
/// it is deterministic, sub-second, and verifies correctness rather than the
/// old harness's "some pixels changed" proxy.
@MainActor
final class TerminalScrollbackOracleTests: XCTestCase {
    private let esc = "\u{1B}"

    func testAgentScrollGuardClaimsPageKeysOnlyWhileActive() {
        let container = TesseraTerminalContainer(frame: .zero)

        XCTAssertTrue(agentPageCommands(in: container).isEmpty)

        var blockedCount = 0
        container.onAgentScrollBlocked = { blockedCount += 1 }
        container.agentScrollBlockingActive = true

        let commands = agentPageCommands(in: container)
        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(
            Set(commands.map { $0.modifierFlags.rawValue }),
            Set([UIKeyModifierFlags().rawValue, UIKeyModifierFlags.shift.rawValue])
        )
        XCTAssertTrue(commands.allSatisfy(\.wantsPriorityOverSystemBehavior))
        XCTAssertTrue(
            commands.allSatisfy {
                guard let action = $0.action else { return false }
                return container.canPerformAction(action, withSender: $0)
            }
        )

        guard let first = commands.first, let action = first.action else {
            return XCTFail("agent page-key command must have an action")
        }
        XCTAssertTrue(
            UIApplication.shared.sendAction(
                action,
                to: container,
                from: first,
                for: nil
            )
        )
        XCTAssertEqual(blockedCount, 1)

        container.agentScrollBlockingActive = false
        XCTAssertTrue(agentPageCommands(in: container).isEmpty)
    }

    func testForceRedrawDrainsSwiftTermDirtyRowsThroughDisplayScheduler() async throws {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let terminal = view.getTerminal()
        terminal.clearUpdateRange()

        let box = TerminalBox(traceLabel: "force-redraw-test")
        box.attach(view)
        box.forceRedraw()

        XCTAssertNotNil(terminal.getUpdateRange())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(
            terminal.getUpdateRange(),
            "force redraw must pass dirty rows through SwiftTerm's display scheduler"
        )
    }

    func test_repaintSeamsDoNotPlantColoredTailsInDeepScrollback() {
        for columns in [40, 73] {
            assertNoColoredTails(columns: columns, rows: 8, capturePairs: 36)
        }
    }

    private func agentPageCommands(
        in container: TesseraTerminalContainer
    ) -> [UIKeyCommand] {
        (container.keyCommands ?? []).filter {
            $0.input == UIKeyCommand.inputPageUp
                || $0.input == UIKeyCommand.inputPageDown
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

    // MARK: - OSC color query responder

    func testColorQueryResponderAnswersForegroundAndBackgroundQueries() {
        let responder = TerminalOSCColorQueryResponder()
        let queries = Array("\(esc)]10;?\u{07}\(esc)]11;?\(esc)\\".utf8)

        let response = responder.responses(
            for: queries[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )

        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.contains("]10;rgb:d4d4/d4d4/d4d4"))
        XCTAssertTrue(text.contains("]11;rgb:1010/1010/1010"))
    }

    /// Regression: curly quotes are E2 80 9C / E2 80 9D — their trailing
    /// bytes are also the C1 ST/OSC codes. Treating them as control bytes
    /// opened a phantom OSC mid-prose, buffered the rest of the chunk as a
    /// "pending query", and then re-scanned that growing buffer on every
    /// later chunk (~8ms per %output message) while swallowing real queries.
    func testColorQueryResponderIgnoresCurlyQuoteProseAndStillAnswersLaterQuery() {
        let responder = TerminalOSCColorQueryResponder()
        let prose = Array("say \u{201C}hello\u{201D} and then some trailing text".utf8)

        let proseResponse = responder.responses(
            for: prose[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(proseResponse.isEmpty)

        let query = Array("\(esc)]11;?\u{07}".utf8)
        let queryResponse = responder.responses(
            for: query[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(
            String(decoding: queryResponse, as: UTF8.self).contains("]11;rgb:1010/1010/1010")
        )
    }

    /// A query split across two chunks must still be answered — the pending
    /// carry-over exists for exactly this — while the cap keeps a pathological
    /// unterminated tail from growing without bound.
    func testColorQueryResponderReassemblesSplitQueryAcrossChunks() {
        let responder = TerminalOSCColorQueryResponder()
        let query = Array("\(esc)]11;?\u{07}".utf8)

        let first = responder.responses(
            for: query[..<3],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(first.isEmpty)

        let second = responder.responses(
            for: query[3...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(
            String(decoding: second, as: UTF8.self).contains("]11;rgb:1010/1010/1010")
        )
    }

    /// Regression: a query whose leading ESC ends a long prose chunk must
    /// survive the pending cap. Only the 1–2 control-tail bytes are carried
    /// over, so the prose length no longer counts against the cap and the
    /// query completing in the next chunk is still answered.
    func testColorQueryResponderAnswersQuerySplitAtLeadingEscapeAfterLongProse() {
        let responder = TerminalOSCColorQueryResponder()
        var first = Array(repeating: UInt8(ascii: "x"), count: 300)
        first.append(0x1B)

        let firstResponse = responder.responses(
            for: first[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(firstResponse.isEmpty)

        let second = Array("]11;?\u{07}".utf8)
        let secondResponse = responder.responses(
            for: second[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(
            String(decoding: secondResponse, as: UTF8.self).contains("]11;rgb:1010/1010/1010")
        )
    }

    /// The pending cap itself: an unterminated foreign OSC longer than the
    /// cap is dropped rather than poisoning every later chunk, and a later
    /// stand-alone query is still answered.
    func testColorQueryResponderCapsUnterminatedPendingOSC() {
        let responder = TerminalOSCColorQueryResponder()
        var junk = Array("\u{1B}]junk;".utf8)
        junk.append(contentsOf: Array(repeating: UInt8(ascii: "j"), count: 400))

        let junkResponse = responder.responses(
            for: junk[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(junkResponse.isEmpty)

        let query = Array("\u{1B}]11;?\u{07}".utf8)
        let queryResponse = responder.responses(
            for: query[...],
            streamID: "test",
            defaultForegroundRGB: 0xD4D4D4,
            defaultBackgroundRGB: 0x101010
        )
        XCTAssertTrue(
            String(decoding: queryResponse, as: UTF8.self).contains("]11;rgb:1010/1010/1010")
        )
    }
}

private final class NullTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
