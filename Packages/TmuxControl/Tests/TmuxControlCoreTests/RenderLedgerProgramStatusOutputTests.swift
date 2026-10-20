import Foundation
import XCTest
@testable import TmuxControlCore

final class RenderLedgerProgramStatusOutputTests: XCTestCase {
    private let pane = PaneId(1)
    private var snapshot: TmuxSnapshot {
        .init(sessionID: SessionId(0), sessionName: "work", activeWindowID: WindowId(1),
              windows: [.init(id: WindowId(1), name: "window", activePaneID: pane,
                              panes: [.init(id: pane, isActive: true)])], authority: .unknown)
    }

    private func commands(_ effects: [RenderEffect]) -> [String] {
        effects.compactMap { if case .sendCommand(let command) = $0 { return command }; return nil }
    }

    @discardableResult
    private func reply(_ ledger: inout TmuxRenderLedger, success: Bool = true,
                       lines: [String] = []) -> [RenderEffect] {
        let guardFrame = TmuxCommandGuard(time: 1, commandNumber: 1, flags: 1)
        return ledger.reduce(.correlation(.frameCompleted(.init(
            status: success ? .success : .error, begin: guardFrame, end: guardFrame,
            effectiveFlags: 1, guardMatches: true, lines: lines
        ))), snapshot: snapshot)
    }

    func testCommandsAndFactCodablePreserveVersionOne() throws {
        XCTAssertEqual(RenderCommands.sideChannelPaneOutput(enabled: true), "refresh-client -f '!no-output'")
        XCTAssertEqual(RenderCommands.sideChannelPaneOutput(enabled: false), "refresh-client -f no-output")
        for enabled in [true, false] {
            let fact = RenderFact.programStatusPaneOutput(enabled: enabled)
            XCTAssertEqual(try JSONDecoder().decode(RenderFact.self, from: JSONEncoder().encode(fact)), fact)
        }
        XCTAssertEqual(try JSONDecoder().decode(RenderFact.self,
            from: Data(#"{"version":1,"kind":"transportLost"}"#.utf8)), .transportLost)
    }

    func testEnableDisableAndReattachUseOneFIFOCommand() {
        var ledger = TmuxRenderLedger()
        XCTAssertEqual(ledger.reduce(.programStatusPaneOutput(enabled: true)), [])
        XCTAssertEqual(commands(ledger.reduce(.transportAttached(.sideChannel))), ["refresh-client -f '!no-output'"])
        XCTAssertEqual(ledger.programStatusPaneOutputState, .requested)
        XCTAssertEqual(ledger.reduce(.programStatusPaneOutput(enabled: true)), [])
        reply(&ledger)
        XCTAssertEqual(ledger.programStatusPaneOutputState, .on)
        XCTAssertEqual(commands(ledger.reduce(.programStatusPaneOutput(enabled: false))), ["refresh-client -f no-output"])
        reply(&ledger)
        XCTAssertEqual(ledger.programStatusPaneOutputState, .off)
        _ = ledger.reduce(.programStatusPaneOutput(enabled: true))
        reply(&ledger)
        _ = ledger.reduce(.transportLost)
        XCTAssertEqual(ledger.programStatusPaneOutputState, .off)
        XCTAssertEqual(commands(ledger.reduce(.transportAttached(.sideChannel))), ["refresh-client -f '!no-output'"])
        XCTAssertEqual(commands(ledger.reduce(.transportAttached(.sideChannel))), ["refresh-client -f '!no-output'"])
    }

    func testOlderToggleRepliesCannotSettleNewerRequests() {
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.transportAttached(.sideChannel))
        _ = ledger.reduce(.programStatusPaneOutput(enabled: true))
        _ = ledger.reduce(.programStatusPaneOutput(enabled: false))
        reply(&ledger, success: false)
        XCTAssertEqual(ledger.programStatusPaneOutputState, .requested)
        reply(&ledger)
        XCTAssertEqual(ledger.programStatusPaneOutputState, .off)
    }

    func testPauseResumesImmediatelyWithoutPaintingWhileRequestedOrOn() {
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.transportAttached(.sideChannel))
        _ = ledger.reduce(.programStatusPaneOutput(enabled: true))
        let pause = TmuxRuntimeBatch.OrderedEvent.message(.pause(paneId: pane))
        XCTAssertEqual(ledger.reduce(pause, snapshot: snapshot), [.sendCommand(RenderCommands.continuePane(pane))])
        reply(&ledger)
        reply(&ledger)
        XCTAssertEqual(ledger.programStatusPaneOutputState, .on)
        XCTAssertEqual(ledger.reduce(pause, snapshot: snapshot), [.sendCommand(RenderCommands.continuePane(pane))])
    }

    func testInlineIgnoresFact() {
        var ledger = TmuxRenderLedger()
        _ = ledger.reduce(.transportAttached(.inline))
        XCTAssertEqual(ledger.reduce(.programStatusPaneOutput(enabled: true)), [])
        XCTAssertFalse(ledger.isProgramStatusPaneOutput)
        XCTAssertEqual(commands(ledger.reduce(.transportAttached(.sideChannel))), [])
    }

    private func revealedHistory() throws -> TmuxRenderLedger {
        var ledger = TmuxRenderLedger(configuration: .init(moshPageDepth: 10))
        _ = ledger.reduce(.surfacesDeclared([.init(surfaceID: .live, presentation: .single)]), snapshot: snapshot)
        _ = ledger.reduce(.transportAttached(.sideChannel), snapshot: snapshot)
        _ = ledger.reduce(.scrollbackRequested(.live, pointsY: 1, isInertial: false), snapshot: snapshot)
        reply(&ledger, lines: ["%1\t0\t0\tpane\twindow\thost\t0\t50\t0\t23\t1\t0\t0\t0\t1\t0\t0\t0\t0\t0\t0"])
        let capture = reply(&ledger, lines: (1...34).map { "row-\($0)" })
        let request = try XCTUnwrap(capture.compactMap { effect -> UInt64? in
            if case .resolveSurfaceState(_, let request) = effect { return request }; return nil
        }.first)
        _ = ledger.reduce(.surfaceState(.live, request: request, altScreen: false,
                                        mouseMode: .off, columns: 80, rows: 24), snapshot: snapshot)
        _ = ledger.reduce(.historyPresented(.live, owner: try XCTUnwrap(ledger.owner(for: .live))), snapshot: snapshot)
        return ledger
    }

    func testMonitorOutputPreservesHistoryAndSSPStillFreezesIt() throws {
        let output = TmuxRuntimeBatch.OrderedEvent.message(.output(paneId: pane, data: Array("output".utf8)))
        var off = try revealedHistory()
        let baseline = off.reduce(output, snapshot: snapshot)
        XCTAssertEqual(baseline, [.diagnostic("render-ledger side-channel-frozen surface=live")])
        for settled in [false, true] {
            var on = try revealedHistory()
            let owner = try XCTUnwrap(on.owner(for: .live))
            _ = on.reduce(.programStatusPaneOutput(enabled: true), snapshot: snapshot)
            if settled { reply(&on) }
            XCTAssertEqual(on.reduce(output, snapshot: snapshot), [])
            XCTAssertEqual(on.owner(for: .live), owner)
            XCTAssertEqual(on.reduce(.transportOutputObserved(.live, owner: owner), snapshot: snapshot), baseline)
        }
    }

    func testRefusalKeepsCompatibilityOutputAndPausePath() throws {
        var ledger = try revealedHistory()
        _ = ledger.reduce(.programStatusPaneOutput(enabled: true))
        reply(&ledger, success: false)
        XCTAssertEqual(ledger.programStatusPaneOutputState, .refused)
        XCTAssertEqual(ledger.reduce(.programStatusPaneOutput(enabled: true)), [])
        XCTAssertEqual(ledger.reduce(.message(.output(paneId: pane, data: [65])), snapshot: snapshot),
                       [.diagnostic("render-ledger side-channel-frozen surface=live")])
        XCTAssertEqual(ledger.reduce(.message(.pause(paneId: pane)), snapshot: snapshot), [])
        XCTAssertEqual(commands(ledger.reduce(.transportAttached(.sideChannel))), ["refresh-client -f '!no-output'"])
    }
}
