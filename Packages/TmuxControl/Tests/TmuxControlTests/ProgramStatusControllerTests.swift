import XCTest
@testable import TmuxControl
import TmuxControlCore

@MainActor
final class ProgramStatusControllerTests: XCTestCase {
    private let query = "\u{1B}]7501;?\u{1B}\\"

    /// The same hydrated control-mode fixture as the attention harness:
    /// @1 editor (%10), @3 logs (%30/%31).
    private func hydratedController(controlPath: TmuxController.ControlPath) -> TmuxController {
        let controller = TmuxController(controlPath: controlPath)
        controller.programStatusEnabled = true
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
        controller.ingest(Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(Array("%begin 0 2 1\r\n%end 0 2 1\r\n".utf8))
        controller.ingest(Array("%begin 0 3 1\r\n%end 0 3 1\r\n".utf8))
        controller.ingest(Array((
            "%begin 0 4 1\r\n"
                + "__tessera_windows__\t@1\t1\t%10\tb25d,80x24,0,0,10\tb25d,80x24,0,0,10\t0\teditor\r\n"
                + "__tessera_windows__\t@3\t3\t%30\t9205,80x24,0,0{40x24,0,0,30,39x24,41,0,31}\tb25d,80x24,0,0,30\t1\tlogs\r\n"
                + "%end 0 4 1\r\n"
        ).utf8))
        controller.ingest(Array((
            "%begin 0 5 1\r\n"
                + "@1\t%10\t1\t\teditor\thost\r\n"
                + "@3\t%30\t1\t\tlogs-top\thost\r\n"
                + "@3\t%31\t0\t\tlogs-bottom\thost\r\n"
                + "%end 0 5 1\r\n"
        ).utf8))
        controller.ingest(Array("%begin 0 6 1\r\n@1\r\n%end 0 6 1\r\n".utf8))
        controller.ingest(Array("%begin 0 7 1\r\n%end 0 7 1\r\n".utf8))
        return controller
    }

    /// `%output` escapes control bytes as octal.
    private func paneOutput(_ pane: Int, _ body: String) -> [UInt8] {
        Array("%output %\(pane) \\033]7501;\(body)\\007\r\n".utf8)
    }

    func test_rawQueryIsAnsweredBeforeTheTerminalSeesItsBytes() {
        let controller = TmuxController(controlPath: .inline)
        controller.programStatusEnabled = true
        var events: [String] = []
        controller.sendBytes = { events.append("send " + String(decoding: $0, as: UTF8.self)) }
        controller.feedTerminal = { events.append("terminal \(String(decoding: $0, as: UTF8.self))") }

        controller.ingest(Array((query + "\u{1B}[c").utf8))

        XCTAssertEqual(events, ["send \(query)", "terminal \(query)\u{1B}[c"])
    }

    func test_rawReportsPublishAndDisablingDiscardsThemAndTheReply() {
        let controller = TmuxController(controlPath: .inline)
        controller.programStatusEnabled = true
        var sent: [[UInt8]] = []
        controller.sendBytes = { sent.append($0) }
        controller.feedTerminal = { _ in }

        controller.ingest(Array("\u{1B}]7501;state=blocked:kind=question:app=deploy\u{7}".utf8))
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.attention, .needsInput(.question))
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.primaryEntry?.app, "deploy")

        controller.programStatusEnabled = false
        XCTAssertTrue(controller.programStatus.terminals.isEmpty)
        controller.ingest(Array((query + "\u{1B}]7501;state=done\u{7}").utf8))
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(controller.programStatus.terminals.isEmpty)
    }

    func test_sideChannelPassthroughNeverAnswersTheQuery() {
        let controller = TmuxController(controlPath: .sideChannel)
        controller.programStatusEnabled = true
        var sent: [[UInt8]] = []
        controller.sendBytes = { sent.append($0) }
        controller.feedTerminal = { _ in }

        controller.ingest(Array((query + "\u{1B}]7501;state=working\u{7}").utf8))

        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(controller.programStatus.terminals.isEmpty)
    }

    func test_paneReportsArriveThroughOutputAndAcknowledgementChecksResults() throws {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let controller = hydratedController(controlPath: path)
            var sent: [[UInt8]] = []
            controller.sendBytes = { sent.append($0) }
            sent.removeAll()

            // A hidden window's pane reports; tmux panes never get replies.
            controller.ingest(paneOutput(31, "state=blocked:kind=permission"))
            controller.ingest(paneOutput(10, "?"))
            controller.ingest(paneOutput(10, "state=done:app=cargo"))
            XCTAssertFalse(sent.contains(Array(query.utf8)), "\(path)")
            XCTAssertEqual(controller.programStatus.terminal(.pane(PaneId(31)))?.attention, .needsInput(.permission))
            let done = try XCTUnwrap(controller.programStatus.terminal(.pane(PaneId(10))))
            XCTAssertEqual(done.attention, .finished)

            controller.acknowledgeProgramStatus(
                terminal: .pane(PaneId(10)),
                through: try XCTUnwrap(done.latestUnreadResultToken)
            )
            XCTAssertNil(controller.programStatus.terminal(.pane(PaneId(10)))?.attention)
            // Blocked records are never acknowledged.
            controller.acknowledgeProgramStatus(terminal: .pane(PaneId(31)), through: .max)
            XCTAssertEqual(controller.programStatus.terminal(.pane(PaneId(31)))?.attention, .needsInput(.permission))
        }
    }

    func test_pausedPaneAndTransportLossLeaveHistoryWithoutAttention() {
        let controller = hydratedController(controlPath: .inline)
        controller.ingest(paneOutput(30, "state=blocked"))
        controller.ingest(paneOutput(31, "state=error"))
        controller.ingest(Array("%pause %30\r\n".utf8))
        XCTAssertEqual(controller.programStatus.terminal(.pane(PaneId(30)))?.entries.first?.isHistorical, true)
        XCTAssertNil(controller.programStatus.terminal(.pane(PaneId(30)))?.attention)
        XCTAssertEqual(controller.programStatus.terminal(.pane(PaneId(31)))?.attention, .failed)

        controller.reset()

        XCTAssertEqual(controller.programStatus.terminals.count, 2)
        XCTAssertTrue(controller.programStatus.terminals.allSatisfy { $0.attention == nil })
        XCTAssertTrue(controller.programStatus.terminals.flatMap(\.entries).allSatisfy(\.isHistorical))
    }

    func test_enteringControlModeRetiresTheRawTerminalsRecords() {
        let controller = TmuxController(controlPath: .inline)
        controller.programStatusEnabled = true
        controller.feedTerminal = { _ in }
        controller.ingest(Array("\u{1B}]7501;state=working\u{7}".utf8))
        XCTAssertNotNil(controller.programStatus.terminal(.raw))

        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])

        XCTAssertNil(controller.programStatus.terminal(.raw))
    }
}
