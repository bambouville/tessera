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

        controller.ingest(Array("%session-changed $0 dev\r\n%window-add @1\r\n".utf8))
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

    func test_splitNotificationBatchPreservesLayout() async {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            for cooperative in [false, true] {
                for batched in [false, true] {
                    let (controller, _, sent) = makeController(controlPath: path)
                    enterTmuxModeWithSinglePaneFixture(controller, sent: sent)
                    let notifications = [
                        "%window-pane-changed @1 %6\r\n",
                        "%layout-change @1 8205,80x24,0,0{40x24,0,0,5,39x24,41,0,6} 8205,80x24,0,0{40x24,0,0,5,39x24,41,0,6} *\r\n",
                    ]
                    for chunk in batched ? [notifications.joined()] : notifications {
                        if cooperative {
                            _ = await controller.ingestCooperatively(Array(chunk.utf8))
                        } else {
                            controller.ingest(Array(chunk.utf8))
                        }
                    }
                    let context = "path=\(path) cooperative=\(cooperative) batched=\(batched)"
                    XCTAssertEqual(controller.windows.first?.layout?.paneCount, 2, context)
                    XCTAssertEqual(controller.snapshot.windows.first?.layout?.paneCount, 2, context)
                    XCTAssertEqual(controller.windows.first?.activePaneId, PaneId(6), context)
                    XCTAssertEqual(controller.windows.first?.panes.map(\.id), [PaneId(5), PaneId(6)], context)
                    sent.clear()
                    controller.sendInput(Array("x".utf8))
                    XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("send-keys -t %6"), context)
                }
            }
        }
    }

    func test_nestedNewerLayoutSurvivesOlderAdapterCallbacks() async {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let (controller, _, sent) = makeController(controlPath: path)
            enterTmuxModeWithSinglePaneFixture(controller, sent: sent)
            var nested = false
            controller.paneDidOutput = { _ in
                guard !nested else { return }
                nested = true
                controller.ingest(Array("%layout-change @1 0000,80x24,0,0{26x24,0,0,5,26x24,27,0,6,26x24,54,0,7} 0000,80x24,0,0{26x24,0,0,5,26x24,27,0,6,26x24,54,0,7} *\r\n".utf8))
                XCTAssertEqual(controller.snapshot.windows.first?.layout?.paneCount, 3, "nested path=\(path)")
            }
            controller.ingest(Array((
                "%window-pane-changed @1 %6\r\n" +
                "%output %6 x\r\n" +
                "%layout-change @1 8205,80x24,0,0{40x24,0,0,5,39x24,41,0,6} 8205,80x24,0,0{40x24,0,0,5,39x24,41,0,6} *\r\n"
            ).utf8))
            XCTAssertTrue(nested)
            XCTAssertEqual(controller.snapshot.windows.first?.layout?.paneCount, 3, "final path=\(path)")
        }
    }

    func test_titleBeforeLayoutCannotRestoreRemovedPanes() async {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            for cooperative in [false, true] {
                let (controller, _, sent) = makeController(controlPath: path)
                enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
                let bytes = Array((
                    "%output %5 \\033]2;new title\\007\r\n"
                    + "%layout-change @1 b25d,80x24,0,0,5 b25d,80x24,0,0,5 *\r\n"
                ).utf8)
                if cooperative { _ = await controller.ingestCooperatively(bytes) }
                else { controller.ingest(bytes) }
                XCTAssertEqual(controller.windows.first?.layout?.paneIds, [PaneId(5)])
                XCTAssertEqual(controller.windows.first?.panes.map(\.id), [PaneId(5)])
                XCTAssertEqual(controller.snapshot.windows.first?.panes.map(\.id), [PaneId(5)])
            }
        }
    }

    func test_windowDetailsReplyCannotUndoLaterSplitOrClose() async {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            for cooperative in [false, true] {
                for close in [false, true] {
                    let (controller, _, _) = makeController(controlPath: path)
                    enterTmuxModeAndDrainAttachInit(controller)
                    controller.ingest(Array("%window-add @5\r\n".utf8))
                    var bytes = responseFrame(100, body: [
                        "__tessera_window_details__\t@5\t0\t%20\tb25d,80x24,0,0,20\tb25d,80x24,0,0,20\t0\tshell",
                    ])
                    bytes += Array((close ? "%unlinked-window-close @5\r\n" :
                        "%window-pane-changed @5 %21\r\n"
                        + "%layout-change @5 8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21} 8205,80x24,0,0{40x24,0,0,20,39x24,41,0,21} *\r\n"
                    ).utf8)
                    if cooperative { _ = await controller.ingestCooperatively(bytes) }
                    else { controller.ingest(bytes) }
                    if close {
                        XCTAssertTrue(controller.windows.isEmpty)
                        XCTAssertTrue(controller.snapshot.windows.isEmpty)
                    } else {
                        XCTAssertEqual(controller.windows.first?.layout?.paneCount, 2)
                        XCTAssertEqual(controller.windows.first?.activePaneId, PaneId(21))
                        XCTAssertEqual(controller.windows.first?.panes.map(\.id), [PaneId(20), PaneId(21)])
                    }
                }
            }
        }
    }

    func test_splitActivePaneVerticalSendsCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.splitActivePane(.vertical)

        expectSent(sent, "split-window -v -t %5 -e COLORTERM=truecolor\n")
    }

    func test_splitExplicitPaneSendsTargetedCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.splitPane(PaneId(6), axis: .horizontal)

        expectSent(sent, "split-window -h -t %6 -e COLORTERM=truecolor\n")
    }

    func test_splitExplicitPaneBeforeSendsHorizontalPlacementFlag() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.splitPane(PaneId(6), axis: .horizontal, before: true)

        expectSent(sent, "split-window -h -b -t %6 -e COLORTERM=truecolor\n")
    }

    func test_splitExplicitPaneBeforeSendsVerticalPlacementFlag() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.splitPane(PaneId(6), axis: .vertical, before: true)

        expectSent(sent, "split-window -v -b -t %6 -e COLORTERM=truecolor\n")
    }

    /// `-b` is the whole difference between "Split Right" and "Split Left", so
    /// pin that the default placement never emits it — a stray `-b` would put
    /// every split on the wrong side while every other assertion still passed.
    func test_splitExplicitPaneDefaultsToAppendWithoutPlacementFlag() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.splitPane(PaneId(6), axis: .vertical, before: false)

        expectSent(sent, "split-window -v -t %6 -e COLORTERM=truecolor\n")
    }

    /// The tab palette exists to split a window the user is *not* looking at.
    /// Every other split test targets the active window, so this pins that a
    /// pane in a second, inactive window is a legal target and that placement
    /// survives the trip.
    func test_splitExplicitPaneInInactiveWindowSendsTargetedCommand() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.ingest(Array("%window-add @2\r\n".utf8))
        controller.ingest(Array(
            "%layout-change @2 b25d,80x24,0,0,7 b25d,80x24,0,0,7 *\r\n".utf8
        ))
        XCTAssertEqual(controller.activeWindowId, WindowId(1))
        sent.clear()

        controller.splitPane(PaneId(7), axis: .vertical, before: true)

        expectSent(sent, "split-window -v -b -t %7 -e COLORTERM=truecolor\n")
    }

    /// A session change keeps the old tabs on screen while marking the list
    /// stale, and a bare `%id` resolves against whichever session owns that
    /// pane now. So a split has to be refused until the authoritative list
    /// lands — the rule `killWindow`, `renameWindow` and `selectWindow`
    /// already follow, and the one a tab palette can reach with one tap.
    func test_splitIsRefusedWhileWindowListIsUnhydrated() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        XCTAssertTrue(controller.isWindowListHydrated)

        controller.ingest(Array("%session-changed $1 work\r\n".utf8))
        XCTAssertFalse(controller.isWindowListHydrated)
        XCTAssertTrue(
            controller.windows.contains { window in
                window.panes.contains { $0.id == PaneId(6) }
            },
            "the stale tab must still be listed, or this proves nothing"
        )
        sent.clear()

        controller.splitPane(PaneId(6), axis: .horizontal)

        expectSent(sent, "")
    }

    func test_splitUnknownPaneIsNoOp() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.splitPane(PaneId(99), axis: .vertical)

        expectSent(sent, "")
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

    func test_selectPanePreservingWindowZoomSelectsDifferentPaneAtomically() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        controller.ingest(Array(
            "%layout-change @1 8205,80x24,0,0{40x24,0,0,5,39x24,41,0,6} b25d,80x24,0,0,5 *Z\r\n".utf8
        ))
        sent.clear()

        controller.selectPanePreservingWindowZoom(PaneId(6))

        expectSent(sent, "select-pane -Z -t %6\n")
    }

    func test_selectPanePreservingWindowZoomUsesSafeFlagWhenCachedWindowIsUnzoomed() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        controller.selectPanePreservingWindowZoom(PaneId(6))

        expectSent(sent, "select-pane -Z -t %6\n")
    }

    func test_selectPanePreservingWindowZoomDoesNotToggleCurrentZoomedPane() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        controller.ingest(Array(
            "%layout-change @1 8205,80x24,0,0{40x24,0,0,5,39x24,41,0,6} b25d,80x24,0,0,5 *Z\r\n".utf8
        ))
        sent.clear()

        controller.selectPanePreservingWindowZoom(PaneId(5))

        expectSent(sent, "select-pane -Z -t %5\n")
    }

    func test_sideChannelSelectPaneMirrorsToVerifiedVisibleMoshClientAndPreservesZoom() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        controller.gridAuthorityIdentity = .init(id: "device-1", displayName: "iPhone")
        XCTAssertEqual(controller._debugPendingCommandCount, 0)

        controller.selectPanePreservingWindowZoom(PaneId(6))
        XCTAssertEqual(String(decoding: sent.bytes, as: UTF8.self), "select-pane -Z -t %6\n")

        controller.ingest(responseFrame(15))
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains(
            TmuxRuntimeHydrationQuery.activePaneCommand(windowID: WindowId(1)) + "\n"
        ))
        controller.ingest(responseFrame(
            16,
            body: ["__tessera_active_pane__\t@1\t%6"]
        ))
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains(
            "show-options -qv -t $0 @tessera-visible-device-1\n"
        ))
        let stamped = "/dev/ttys-visible|222|1700000002"
        controller.ingest(responseFrame(17, body: [stamped]))
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains(
            "list-clients -t $0 -F '#{client_name}|#{client_pid}|#{client_created}'\n"
        ))
        controller.ingest(responseFrame(18, body: [
            "/dev/ttys-control|111|1700000001",
            stamped,
        ]))

        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains(
            "switch-client -Z -c '/dev/ttys-visible' -t '$0:@1.%6'\n"
        ))
    }

    func test_sideChannelSelectPaneMirrorsToVerifiedVisibleMoshClientWithoutZoomFlag() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        controller.gridAuthorityIdentity = .init(id: "device-1", displayName: "iPhone")

        controller.selectPane(PaneId(6))
        XCTAssertEqual(String(decoding: sent.bytes, as: UTF8.self), "select-pane -t %6\n")

        controller.ingest(responseFrame(15))
        controller.ingest(responseFrame(
            16,
            body: ["__tessera_active_pane__\t@1\t%6"]
        ))
        let stamped = "/dev/ttys-visible|222|1700000002"
        controller.ingest(responseFrame(17, body: [stamped]))
        controller.ingest(responseFrame(18, body: [
            "/dev/ttys-control|111|1700000001",
            stamped,
        ]))

        let commands = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertTrue(commands.contains("switch-client -c '/dev/ttys-visible' -t '$0:@1.%6'\n"))
        XCTAssertFalse(commands.contains("switch-client -Z"))
    }

    func test_sideChannelSelectPaneRejectsStaleActivePaneProof() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        controller.gridAuthorityIdentity = .init(id: "device-1", displayName: "iPhone")

        controller.selectPanePreservingWindowZoom(PaneId(6))
        controller.ingest(responseFrame(15))
        controller.ingest(responseFrame(
            16,
            body: ["__tessera_active_pane__\t@1\t%5"]
        ))

        let commands = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertFalse(commands.contains("show-options -qv"))
        XCTAssertFalse(commands.contains("switch-client"))
    }

    func test_sideChannelNewerWindowSelectionSupersedesPendingPaneMirror() {
        let (controller, _, sent) = makeController(controlPath: .sideChannel)
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        controller.gridAuthorityIdentity = .init(id: "device-1", displayName: "iPhone")

        controller.selectPanePreservingWindowZoom(PaneId(6))
        controller.selectWindow(WindowId(1))
        controller.ingest(responseFrame(15)) // stale pane selection completion
        controller.ingest(responseFrame(16)) // current window selection completion

        let commands = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertFalse(commands.contains(TmuxRuntimeHydrationQuery.activePaneCommand(
            windowID: WindowId(1)
        )))
        XCTAssertTrue(commands.contains(TmuxRuntimeHydrationQuery.activeWindowCommand + "\n"))
        XCTAssertFalse(commands.contains("switch-client -Z"))
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
        var observed: [(PaneId?, [UInt8])] = []
        controller.inputObserver = { observed.append(($0, $1)) }

        controller.sendInput([0x61, 0x62], toPane: PaneId(6))

        expectSent(sent, "send-keys -t %6 -H 61 62\n")
        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.0, PaneId(6))
        XCTAssertEqual(observed.first?.1, [0x61, 0x62])
    }

    func test_sendInputAcknowledgedWaitsForTmuxSuccess() async {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        let resultTask = Task {
            await controller.sendInputAcknowledged([0x61, 0x62], toPane: PaneId(6))
        }
        await Task.yield()

        expectSent(sent, "send-keys -t %6 -H 61 62\n")
        controller.ingest(responseFrame(1))

        let result = await resultTask.value
        XCTAssertTrue(result)
    }

    func test_sendInputAcknowledgedReportsTmuxError() async {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        let resultTask = Task {
            await controller.sendInputAcknowledged([0x0d], toPane: PaneId(6))
        }
        await Task.yield()

        expectSent(sent, "send-keys -t %6 -H 0d\n")
        controller.ingest(errorFrame(1, body: ["pane is gone"]))

        let result = await resultTask.value
        XCTAssertFalse(result)
    }

    /// Typing into the active pane with a report (an uploaded path): the
    /// command is queued before the call returns, and the report is tmux's
    /// reply.
    func test_sendInputWithCompletionQueuesNowAndReportsTmuxSuccess() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        var reports: [Bool] = []

        controller.sendInput([0x61, 0x62], correlation: nil) { reports.append($0) }

        expectSent(sent, "send-keys -t %5 -H 61 62\n")
        XCTAssertTrue(reports.isEmpty, "no report before tmux replies")
        controller.ingest(responseFrame(1))
        XCTAssertEqual(reports, [true])
    }

    func test_sendInputWithCompletionReportsTmuxErrorAndAMissingPane() {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)
        var reports: [Bool] = []

        controller.sendInput([0x61], correlation: nil) { reports.append($0) }
        controller.ingest(errorFrame(1, body: ["pane is gone"]))
        XCTAssertEqual(reports, [false])

        let (bare, _, bareSent) = makeController()
        enterTmuxModeAndDrainAttachInit(bare)
        bareSent.clear()
        XCTAssertNil(bare.activePaneId)
        bare.sendInput([0x61], correlation: nil) { reports.append($0) }
        XCTAssertEqual(reports, [false, false], "no active pane: nothing sent")
        XCTAssertTrue(bareSent.bytes.isEmpty)
    }

    func test_sendKeyAcknowledgedKeepsEnterSemantic() async {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        let resultTask = Task {
            await controller.sendKeyAcknowledged(.enter, toPane: PaneId(6))
        }
        await Task.yield()

        expectSent(sent, "send-keys -t %6 Enter\n")
        controller.ingest(responseFrame(1))
        let result = await resultTask.value
        XCTAssertTrue(result)
    }

    func test_sendKeyAcknowledgedKeepsEscapeSemantic() async {
        let (controller, _, sent) = makeController()
        enterTmuxModeWithTwoPaneFixture(controller, sent: sent)

        let resultTask = Task {
            await controller.sendKeyAcknowledged(.escape, toPane: PaneId(6))
        }
        await Task.yield()

        expectSent(sent, "send-keys -t %6 Escape\n")
        controller.ingest(responseFrame(1))
        let result = await resultTask.value
        XCTAssertTrue(result)
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
