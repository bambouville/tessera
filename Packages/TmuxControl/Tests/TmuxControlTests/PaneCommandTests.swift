import XCTest
@testable import TmuxControl

@MainActor
final class PaneCommandTests: XCTestCase {
    private func makeController(
        controlPath: TmuxController.ControlPath = .inline
    ) -> (
        TmuxController,
        fed: PaneCommandAccumulator<UInt8>,
        sent: PaneCommandAccumulator<UInt8>
    ) {
        let fed = PaneCommandAccumulator<UInt8>()
        let sent = PaneCommandAccumulator<UInt8>()
        let controller = TmuxController(controlPath: controlPath)
        controller.feedTerminal = { slice in fed.append(contentsOf: slice) }
        controller.sendBytes = { bytes in sent.append(contentsOf: bytes) }
        return (controller, fed, sent)
    }

    private func enterTmuxModeAndDrainAttachInit(_ controller: TmuxController) {
        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(chunk)

        for number in 2...8 {
            controller.ingest(responseFrame(number))
        }
    }

    private func enterTmuxModeWithTwoPaneFixture(
        _ controller: TmuxController,
        sent: PaneCommandAccumulator<UInt8>
    ) {
        enterTmuxModeAndDrainAttachInit(controller)

        controller.ingest(Array("%window-add @1\r\n".utf8))
        controller.ingest(Array("%window-pane-changed @1 %5\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        controller.ingest(Array(
            "%layout-change @1 8205,80x24,0,0{40x24,0,0,5,39x24,41,0,6} 8205,80x24,0,0{40x24,0,0,5,39x24,41,0,6} *\r\n".utf8
        ))

        let metadata = renderedPaneMetadataLine(paneId: 5)
        controller.ingest(responseFrame(9, body: ["editor"]))
        controller.ingest(responseFrame(10, body: [metadata]))
        controller.ingest(responseFrame(11, body: [metadata]))
        controller.ingest(responseFrame(12, body: ["viewport"]))
        controller.ingest(responseFrame(13, body: [metadata]))
        controller.ingest(responseFrame(14, body: ["deep"]))

        sent.clear()
    }

    private func enterTmuxModeWithSinglePaneFixture(
        _ controller: TmuxController,
        sent: PaneCommandAccumulator<UInt8>
    ) {
        enterTmuxModeAndDrainAttachInit(controller)

        controller.ingest(Array("%window-add @1\r\n".utf8))
        controller.ingest(Array("%window-pane-changed @1 %5\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        controller.ingest(Array(
            "%layout-change @1 b25d,80x24,0,0,5 b25d,80x24,0,0,5 *\r\n".utf8
        ))

        let metadata = renderedPaneMetadataLine(paneId: 5)
        controller.ingest(responseFrame(9, body: ["editor"]))
        controller.ingest(responseFrame(10, body: [metadata]))
        controller.ingest(responseFrame(11, body: [metadata]))
        controller.ingest(responseFrame(12, body: ["viewport"]))
        controller.ingest(responseFrame(13, body: [metadata]))
        controller.ingest(responseFrame(14, body: ["deep"]))

        sent.clear()
    }

    private func renderedPaneMetadataLine(paneId: Int) -> String {
        [
            "%\(paneId)",
            "0",
            "0",
            "pane title",
            "editor",
            "host",
            "0",
        ].joined(separator: "\t")
    }

    private func responseFrame(
        _ number: Int,
        body: [String] = [],
        flags: Int = 1,
        time: Int = 0,
        status: String = "%end"
    ) -> [UInt8] {
        var lines = ["%begin \(time) \(number) \(flags)"]
        lines.append(contentsOf: body)
        lines.append("\(status) \(time) \(number) \(flags)")
        return Array((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    private func errorFrame(
        _ number: Int,
        body: [String],
        flags: Int = 1,
        time: Int = 0
    ) -> [UInt8] {
        responseFrame(number, body: body, flags: flags, time: time, status: "%error")
    }

    private func expectSent(
        _ sent: PaneCommandAccumulator<UInt8>,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(String(decoding: sent.bytes, as: UTF8.self), expected, file: file, line: line)
    }

    func test_splitActivePaneHorizontalSendsCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.splitActivePane(.horizontal)

        expectSent(sent, "split-window -h -t %5 -e COLORTERM=truecolor\n")
    }

    func test_splitActivePaneVerticalSendsCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.splitActivePane(.vertical)

        expectSent(sent, "split-window -v -t %5 -e COLORTERM=truecolor\n")
    }

    func test_sideChannelSplitSinglePaneTurnsOnPaneBorderBeforeSplit() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeWithSinglePaneFixture(controller, sent: sent)

        controller.splitActivePane(.vertical)

        expectSent(
            sent,
            "set -t @1 pane-border-status top\n"
                + "set -t @1 pane-border-format \"\(TmuxController.moshPaneBorderFormat)\"\n"
                + "split-window -v -t %5 -e COLORTERM=truecolor\n"
        )
    }

    func test_sideChannelSplitMultiPaneDoesNotResendPaneBorder() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.splitActivePane(.vertical)

        expectSent(sent, "split-window -v -t %5 -e COLORTERM=truecolor\n")
    }

    func test_selectPaneSendsCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.selectPane(PaneId(6))

        expectSent(sent, "select-pane -t %6\n")
    }

    func test_killActivePaneSendsCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.killActivePane()

        expectSent(sent, "kill-pane -t %5\n")
    }

    func test_killPaneSendsCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.killPane(PaneId(6))

        expectSent(sent, "kill-pane -t %6\n")
    }

    func test_sideChannelKillActivePaneDoesNotTurnOffPaneBorderBeforePaneIsRemoved() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.killActivePane()

        expectSent(sent, "kill-pane -t %5\n")
    }

    func test_sideChannelKillPaneDoesNotTurnOffPaneBorderBeforePaneIsRemoved() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.killPane(PaneId(6))

        expectSent(sent, "kill-pane -t %6\n")
    }

    func test_togglePaneZoomSendsCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.togglePaneZoom()

        expectSent(sent, "resize-pane -Z -t %5\n")
    }

    func test_cyclePaneForwardAndBackwardFromActivePaneSelectsOtherPane() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.cyclePane(forward: true)
        expectSent(sent, "select-pane -t %6\n")

        sent.clear()
        controller.cyclePane(forward: false)
        expectSent(sent, "select-pane -t %6\n")
    }

    func test_cyclePaneForwardWrapsFromLastPaneToFirstPane() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        controller.ingest(Array("%window-pane-changed @1 %6\r\n".utf8))
        sent.clear()

        controller.cyclePane(forward: true)

        expectSent(sent, "select-pane -t %5\n")
    }

    func test_sendInputToExplicitPaneSendsHexCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.sendInput([0x61, 0x62], toPane: PaneId(6))

        expectSent(sent, "send-keys -t %6 -H 61 62\n")
    }

    func test_paneCommandsAreNoOpsInPassthrough() {
        let (controller, _, sent) = makeController()

        controller.splitActivePane(.horizontal)
        controller.splitActivePane(.vertical)
        controller.selectPane(PaneId(6))
        controller.killActivePane()
        controller.killPane(PaneId(6))
        controller.togglePaneZoom()
        controller.cyclePane(forward: true)
        controller.cyclePane(forward: false)
        controller.sendInput([0x61, 0x62], toPane: PaneId(6))

        XCTAssertEqual(sent.bytes, [])
    }

    func test_splitErrorRoutesErrorBodyToOnCommandError() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        var received: String?
        controller.onCommandError = { message in
            received = message
        }

        controller.splitActivePane(.horizontal)
        controller.ingest(errorFrame(1, body: ["create pane failed: pane too small"]))

        expectSent(sent, "split-window -h -t %5 -e COLORTERM=truecolor\n")
        XCTAssertEqual(received, "create pane failed: pane too small")
    }
}

private final class PaneCommandAccumulator<Element> {
    private(set) var bytes: [Element] = []

    func append(contentsOf sequence: some Sequence<Element>) {
        bytes.append(contentsOf: sequence)
    }

    func clear() {
        bytes.removeAll(keepingCapacity: true)
    }
}
