import XCTest
@testable import TmuxControl
import TmuxControlCore

@MainActor
final class ProgramStatusSideChannelControllerTests: XCTestCase {
    func testSideChannelReportsBypassOutputConsumersAndResumePause() throws {
        let controller = TmuxController(controlPath: .sideChannel)
        var commands: [String] = []
        var outputPulses = 0
        var outputObservations = 0
        var terminalFeeds = 0
        var terminalQueries = 0
        controller.sendBytes = { commands.append(String(decoding: $0, as: UTF8.self)) }
        controller.paneDidOutput = { _ in outputPulses += 1 }
        controller.paneOutputObserver = { _, _ in outputObservations += 1 }
        controller.feedTerminal = { _ in terminalFeeds += 1 }
        controller.terminalResponseForOutput = { _, _ in terminalQueries += 1; return [65] }
        controller.programStatusEnabled = true
        controller.ingest(Array("\u{1B}P1000p".utf8))
        XCTAssertEqual(commands.filter { $0.contains("refresh-client -f '!no-output'") }.count, 1)
        commands.removeAll()
        controller.ingest(Array("%output %31 \\033]7501;state=blocked:kind=permission:app=deploy\\007\r\n".utf8))
        XCTAssertEqual(controller.programStatus.terminal(.pane(PaneId(31)))?.attention, .needsInput(.permission))
        XCTAssertEqual(controller.programStatus.terminal(.pane(PaneId(31)))?.primaryEntry?.app, "deploy")
        XCTAssertEqual(outputPulses, 0)
        XCTAssertEqual(outputObservations, 0)
        XCTAssertEqual(terminalFeeds, 0)
        XCTAssertEqual(terminalQueries, 0)
        XCTAssertTrue(commands.isEmpty)
        controller.ingest(Array("%pause %31\r\n".utf8))
        XCTAssertEqual(commands, [RenderCommands.continuePane(PaneId(31)) + "\n"])
        XCTAssertTrue(try XCTUnwrap(controller.programStatus.terminal(.pane(PaneId(31)))?.entries.first).isHistorical)
        commands.removeAll()
        controller.programStatusEnabled = false
        XCTAssertEqual(commands, ["refresh-client -f no-output\n"])
        XCTAssertTrue(controller.programStatus.terminals.isEmpty)
    }

    func testRawPaneBellsAreIgnoredButBellSubscriptionsRemain() {
        let controller = TmuxController(controlPath: .sideChannel)
        controller.programStatusEnabled = true
        controller.ingest(Array("\u{1B}P1000p".utf8))
        controller.ingest(Array((
            "%session-changed $1 work\r\n%window-add @1\r\n%window-add @2\r\n"
                + "%window-pane-changed @1 %10\r\n%window-pane-changed @2 %31\r\n"
                + "%session-window-changed $1 @1\r\n"
        ).utf8))
        var bells = 0
        controller.onBell = { _, _, _ in bells += 1 }
        controller.ingest(Array("%output %31 audible\\007\r\n".utf8))
        controller.ingest(Array("%output %31 \\033]7501;state=done\\007\r\n".utf8))
        XCTAssertEqual(bells, 0)
        XCTAssertTrue(controller.bellingWindows.isEmpty)
        XCTAssertEqual(controller.programStatus.terminal(.pane(PaneId(31)))?.attention, .finished)
        controller.ingest(Array((
            "%subscription-changed tessera-bell $1 @2 1 %31 : 0\r\n"
                + "%subscription-changed tessera-bell $1 @2 1 %31 : 1\r\n"
        ).utf8))
        XCTAssertEqual(bells, 1)
        XCTAssertEqual(controller.bellingWindows, [2])
    }

    func testPreferenceSurvivesSideChannelReattach() {
        let controller = TmuxController(controlPath: .sideChannel)
        var commands: [String] = []
        controller.sendBytes = { commands.append(String(decoding: $0, as: UTF8.self)) }
        controller.programStatusEnabled = true
        controller.ingest(Array("\u{1B}P1000p".utf8))
        controller.sideChannelDisconnected()
        commands.removeAll()
        controller.ingest(Array("\u{1B}P1000p".utf8))
        XCTAssertTrue(controller.programStatusEnabled)
        XCTAssertEqual(commands.filter { $0.contains("refresh-client -f '!no-output'") }.count, 1)
    }
}
