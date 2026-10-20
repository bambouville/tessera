import Foundation
import XCTest
@testable import TmuxControlCore

/// A capture that finishes while its surface still has the previous layout's
/// grid must wait for its committed dimensions before repainting.
final class RenderLedgerSurfaceGridTests: XCTestCase {
    private let paneSurface = SurfaceId("pane-1")
    private let history = (1...6).map { "history-\($0)" }
    private let screen = (1...4).map { "screen-\($0)" }

    // MARK: - Assembly

    func testTallerSurfaceWithoutPaneRowsLosesTheNewestHistoryRow() {
        // The field failure, reproduced in the model: the deep frame leaves
        // history-6 on screen above the pane, the grid scrub erases it, and
        // the surface's shrink to the pane's grid drops the empty last row.
        var terminal = ScreenModel(rows: 5)
        terminal.feed(assemble(captureLines: history + screen, clientRows: 5, paneRows: nil))
        terminal.feed(assemble(captureLines: screen, clientRows: 5, paneRows: nil))
        terminal.shrink(to: 4)
        XCTAssertEqual(terminal.scrollback, Array(history.dropLast()))
        XCTAssertEqual(terminal.screenRows, screen)
    }

    func testTallerSurfaceKeepsEveryHistoryRowInScrollback() {
        var terminal = ScreenModel(rows: 5)
        terminal.feed(assemble(captureLines: history + screen, clientRows: 5, paneRows: 4))
        XCTAssertEqual(terminal.scrollback, history)
        XCTAssertEqual(terminal.screenRows, screen + [""])
        XCTAssertEqual(terminal.cursorRow, 3, "tmux's cursor row addresses the pane from the surface's top")

        terminal.feed(assemble(captureLines: screen, clientRows: 5, paneRows: 4))
        XCTAssertEqual(terminal.scrollback, history, "the scrub must not scroll anything")
        terminal.shrink(to: 4)
        XCTAssertEqual(terminal.scrollback, history)
        XCTAssertEqual(terminal.screenRows, screen)
    }

    func testShortHistoryInATallerSurfaceStillMovesToScrollback() {
        var terminal = ScreenModel(rows: 8)
        terminal.feed(assemble(captureLines: ["history-1"] + screen, clientRows: 8, paneRows: 4))
        XCTAssertEqual(terminal.scrollback, ["history-1"])
        XCTAssertEqual(terminal.screenRows, screen + ["", "", "", ""])
    }

    func testMatchingGridPaintsTheSameBytesAsBefore() {
        XCTAssertEqual(
            assemble(captureLines: history + screen, clientRows: 4, paneRows: 4),
            assemble(captureLines: history + screen, clientRows: 4, paneRows: nil)
        )
        XCTAssertEqual(
            assemble(captureLines: history + screen, clientRows: 3, paneRows: 4),
            assemble(captureLines: history + screen, clientRows: 3, paneRows: nil),
            "a shorter surface has no surplus rows to fill"
        )
    }

    func testTallerSurfaceKeepsHistoryAboveTheSavedPrimaryUnderAnAlternateScreen() throws {
        let state = try XCTUnwrap(TmuxRenderedPaneStateParser.parse(metadata(height: 4, alt: true)))
        let bytes = TmuxRepaintAssembly.assemble(
            state: state,
            captureLines: ["alt-1", "alt-2", "alt-3", "alt-4"],
            historyLines: history,
            savedPrimaryLines: screen,
            altScreenLines: ["alt-1", "alt-2", "alt-3", "alt-4"],
            terminalIsInAltScreen: false,
            clientRows: 5,
            paneRows: 4
        )
        var terminal = ScreenModel(rows: 5)
        terminal.feed(bytes)
        XCTAssertTrue(terminal.isAlternate)
        XCTAssertEqual(terminal.screenRows, ["alt-1", "alt-2", "alt-3", "alt-4", ""])
        XCTAssertEqual(terminal.scrollback, history)
        XCTAssertEqual(terminal.savedPrimaryRows, screen + [""])
    }

    // MARK: - Metadata

    func testMetadataCarriesThePaneGrid() throws {
        let state = try XCTUnwrap(TmuxRenderedPaneStateParser.parse(metadata(height: 50, width: 82)))
        XCTAssertEqual(state.paneWidth, 82)
        XCTAssertEqual(state.paneHeight, 50)

        let legacy = metadata(height: 50).split(separator: "\t", omittingEmptySubsequences: false)
            .dropLast(2).joined(separator: "\t")
        XCTAssertNil(TmuxRenderedPaneStateParser.parse(legacy)?.paneHeight)

        let mangled = try XCTUnwrap(TmuxRenderedPaneStateParser.parse(
            metadata(height: 50, width: 82).replacingOccurrences(of: "\t", with: " ")
        ))
        XCTAssertEqual(mangled.paneTitle, "pane")
        XCTAssertEqual(mangled.historySize, 6)
        XCTAssertEqual(mangled.paneHeight, 50)

        let spacedTitle = try XCTUnwrap(TmuxRenderedPaneStateParser.parse(
            metadata(height: 50, width: 82, title: "my long title").replacingOccurrences(of: "\t", with: " ")
        ))
        XCTAssertNil(spacedTitle.paneTitle, "a separator inside a string drops the strings")
        XCTAssertEqual(spacedTitle.historySize, 6)
        XCTAssertEqual(spacedTitle.paneHeight, 50)
    }

    // MARK: - Ledger

    func testWidthOnlyForegroundResizeWaitsForItsSurfaceToReachThePaneGrid() throws {
        var ledger = TmuxRenderLedger()
        let state = gridSnapshot(height: 45, width: 56)
        let line = metadata(height: 45, width: 56)
        let initial = try captureGridDeep(&ledger, snapshot: state, height: 45, metadataLine: line)
        XCTAssertFalse(feeds(in: surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(initial)), columns: 56, rows: 45, snapshot: state
        )).isEmpty)

        _ = ledger.reduce(.appBackground, snapshot: state)
        XCTAssertTrue(ledger.reduce(.appForeground, snapshot: state).contains(
            .sendCommand(RenderCommands.renderedPaneMetadata(target: PaneId(1)))
        ))
        XCTAssertTrue(reply(&ledger, snapshot: state, lines: [line]).contains(
            .sendCommand(RenderCommands.viewport(target: PaneId(1)))
        ))
        let captured = reply(&ledger, snapshot: state, lines: (1...45).map { "screen-\($0)" })
        let held = surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(captured)), columns: 100, rows: 45, snapshot: state
        )
        XCTAssertTrue(feeds(in: held).isEmpty, "a width-only resize must wait just as a row resize does")
        XCTAssertTrue(held.contains(.diagnostic(
            "render-ledger surface-grid-wait surface=pane-1 columns=100 paneColumns=56 rows=45 paneRows=45"
        )))
        let timer = try XCTUnwrap(armedTimer(held, milliseconds: 40))
        let settled = ledger.reduce(.timerFired(token: timer), snapshot: state)
        let painted = surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(settled)), columns: 56, rows: 45, snapshot: state
        )
        XCTAssertEqual(feeds(in: painted).map(\.source), [.viewportRefresh])
        XCTAssertFalse(painted.contains { if case .bindSurface = $0 { return true }; return false })
    }

    func testPersistentWidthMismatchHasABoundedWaitAndRemembersBothWidths() throws {
        var ledger = TmuxRenderLedger(configuration: .init(
            surfaceGridPollMilliseconds: 40,
            surfaceGridWaitMilliseconds: 120
        ))
        let state = gridSnapshot(height: 45, width: 56)
        let line = metadata(height: 45, width: 56)
        var request = try XCTUnwrap(resolveRequest(try captureGridDeep(
            &ledger, snapshot: state, height: 45, metadataLine: line
        )))
        for poll in 1...3 {
            let held = surfaceState(&ledger, request: request, columns: 100, rows: 45, snapshot: state)
            XCTAssertTrue(feeds(in: held).isEmpty, "poll \(poll)")
            let timer = try XCTUnwrap(armedTimer(held, milliseconds: 40))
            request = try XCTUnwrap(resolveRequest(ledger.reduce(.timerFired(token: timer), snapshot: state)))
        }
        let expired = surfaceState(&ledger, request: request, columns: 100, rows: 45, snapshot: state)
        XCTAssertTrue(expired.contains(.diagnostic(
            "render-ledger surface-grid-wait-expired surface=pane-1 columns=100 paneColumns=56 rows=45 paneRows=45 waitedMs=120"
        )))
        XCTAssertEqual(feeds(in: expired).map(\.source), [.deepRepaint, .repaintScrub])

        let again = try captureGridDeep(&ledger, snapshot: state, height: 45, metadataLine: line)
        let immediate = surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(again)), columns: 100, rows: 45, snapshot: state
        )
        XCTAssertFalse(feeds(in: immediate).isEmpty)
        XCTAssertNil(armedTimer(immediate, milliseconds: 40))

        let remoteChanged = try captureGridDeep(
            &ledger, snapshot: state, height: 45, metadataLine: metadata(height: 45, width: 55)
        )
        let waitsForChangedPaneWidth = surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(remoteChanged)), columns: 100, rows: 45, snapshot: state
        )
        XCTAssertTrue(feeds(in: waitsForChangedPaneWidth).isEmpty)
        XCTAssertNotNil(armedTimer(waitsForChangedPaneWidth, milliseconds: 40))

        let changed = try captureGridDeep(&ledger, snapshot: state, height: 45, metadataLine: line)
        let waitsForChangedWidth = surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(changed)), columns: 99, rows: 45, snapshot: state
        )
        XCTAssertTrue(feeds(in: waitsForChangedWidth).isEmpty)
        XCTAssertNotNil(armedTimer(waitsForChangedWidth, milliseconds: 40))

        let matched = try captureGridDeep(&ledger, snapshot: state, height: 45, metadataLine: line)
        XCTAssertFalse(feeds(in: surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(matched)), columns: 56, rows: 45, snapshot: state
        )).isEmpty)
        let later = try captureGridDeep(&ledger, snapshot: state, height: 45, metadataLine: line)
        let waitsAgain = surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(later)), columns: 100, rows: 45, snapshot: state
        )
        XCTAssertTrue(feeds(in: waitsAgain).isEmpty)
        XCTAssertNotNil(armedTimer(waitsAgain, milliseconds: 40))
    }

    func testUnknownPaneWidthKeepsTheRowOnlyWait() throws {
        var ledger = TmuxRenderLedger()
        let state = gridSnapshot(height: 4)
        let initial = try captureGridDeep(&ledger, snapshot: state, height: 4, metadataLine: metadata(height: 4, width: 0))
        let held = surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(initial)), columns: 100, rows: 5, snapshot: state
        )
        XCTAssertTrue(feeds(in: held).isEmpty)
        let timer = try XCTUnwrap(armedTimer(held, milliseconds: 40))
        let asked = ledger.reduce(.timerFired(token: timer), snapshot: state)
        let painted = surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(asked)), columns: 100, rows: 4, snapshot: state
        )
        XCTAssertFalse(feeds(in: painted).isEmpty, "an unknown pane width cannot block the matched rows")
    }

    func testUnknownSurfaceWidthDoesNotWaitForColumns() throws {
        var ledger = TmuxRenderLedger()
        let state = gridSnapshot(height: 4)
        let initial = try captureGridDeep(&ledger, snapshot: state, height: 4)
        let painted = surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(initial)), columns: 0, rows: 4, snapshot: state
        )
        XCTAssertFalse(feeds(in: painted).isEmpty)
        XCTAssertNil(armedTimer(painted, milliseconds: 40))
    }

    func testGridPaneWaitsForItsSurfaceToReachThePaneGrid() throws {
        var ledger = TmuxRenderLedger()
        let state = gridSnapshot(height: 4)
        let waiting = try captureGridDeep(&ledger, snapshot: state, height: 4)
        let request = try XCTUnwrap(resolveRequest(waiting))

        let held = surfaceState(&ledger, request: request, rows: 5, snapshot: state)
        XCTAssertTrue(feeds(in: held).isEmpty, "a frame for a four-row pane must not paint into five rows")
        XCTAssertTrue(held.contains(.diagnostic("render-ledger surface-grid-wait surface=pane-1 columns=40 paneColumns=40 rows=5 paneRows=4")))
        let token = try XCTUnwrap(armedTimer(held, milliseconds: 40))

        XCTAssertEqual(
            ledger.reduce(.message(.output(paneId: PaneId(1), data: Array("live".utf8))), snapshot: state),
            [],
            "output after the capture's cut waits behind the frame"
        )

        let asked = ledger.reduce(.timerFired(token: token), snapshot: state)
        let secondRequest = try XCTUnwrap(resolveRequest(asked))
        XCTAssertNotEqual(secondRequest, request)
        XCTAssertEqual(surfaceState(&ledger, request: request, rows: 4, snapshot: state), [
            .diagnostic("render-ledger stale-surface-state surface=pane-1 request=\(request)"),
        ])

        let painted = surfaceState(&ledger, request: secondRequest, rows: 4, snapshot: state)
        XCTAssertTrue(painted.contains(.diagnostic("render-ledger surface-grid-settled surface=pane-1 columns=40 paneColumns=40 rows=4 paneRows=4 polls=1")))
        let fed = feeds(in: painted)
        XCTAssertEqual(fed.map(\.source), [.deepRepaint, .repaintScrub, .paneOutput])
        var terminal = ScreenModel(rows: 4)
        for feed in fed.prefix(2) { terminal.feed(try XCTUnwrap(ledger.renderBytes(for: feed.reference))) }
        XCTAssertEqual(terminal.scrollback, history)
        XCTAssertEqual(terminal.screenRows, screen)
        XCTAssertEqual(
            try XCTUnwrap(ledger.renderBytes(for: fed[2].reference)),
            Array("live".utf8)
        )
    }

    func testPersistentMismatchPaintsAfterTheWaitAndThenWithoutWaiting() throws {
        var ledger = TmuxRenderLedger(configuration: .init(
            surfaceGridPollMilliseconds: 40,
            surfaceGridWaitMilliseconds: 120
        ))
        let state = gridSnapshot(height: 4)
        var request = try XCTUnwrap(resolveRequest(try captureGridDeep(&ledger, snapshot: state, height: 4)))
        for poll in 1...3 {
            let held = surfaceState(&ledger, request: request, rows: 5, snapshot: state)
            XCTAssertTrue(feeds(in: held).isEmpty, "poll \(poll)")
            let token = try XCTUnwrap(armedTimer(held, milliseconds: 40))
            request = try XCTUnwrap(resolveRequest(ledger.reduce(.timerFired(token: token), snapshot: state)))
        }
        let expired = surfaceState(&ledger, request: request, rows: 5, snapshot: state)
        XCTAssertTrue(expired.contains(.diagnostic(
            "render-ledger surface-grid-wait-expired surface=pane-1 columns=40 paneColumns=40 rows=5 paneRows=4 waitedMs=120"
        )))
        var terminal = ScreenModel(rows: 5)
        for feed in feeds(in: expired) { terminal.feed(try XCTUnwrap(ledger.renderBytes(for: feed.reference))) }
        XCTAssertEqual(terminal.scrollback, history, "the fallback frame still keeps every history row")
        XCTAssertEqual(terminal.screenRows, screen + [""])

        // The same pair again paints at once.
        let again = try captureGridDeep(&ledger, snapshot: state, height: 4, reason: "again")
        let immediate = surfaceState(&ledger, request: try XCTUnwrap(resolveRequest(again)), rows: 5, snapshot: state)
        XCTAssertEqual(feeds(in: immediate).map(\.source), [.deepRepaint, .repaintScrub])
        XCTAssertNil(armedTimer(immediate, milliseconds: 40))

        // A matching frame forgets the pair, so a later mismatch waits again.
        let matched = try captureGridDeep(&ledger, snapshot: state, height: 4, reason: "matched")
        XCTAssertFalse(feeds(in: surfaceState(
            &ledger, request: try XCTUnwrap(resolveRequest(matched)), rows: 4, snapshot: state
        )).isEmpty)
        let later = try captureGridDeep(&ledger, snapshot: state, height: 4, reason: "later")
        let waitsAgain = surfaceState(&ledger, request: try XCTUnwrap(resolveRequest(later)), rows: 5, snapshot: state)
        XCTAssertTrue(feeds(in: waitsAgain).isEmpty)
        XCTAssertNotNil(armedTimer(waitsAgain, milliseconds: 40))
    }

    func testClientResizeDuringTheWaitRecapturesThePane() throws {
        var ledger = TmuxRenderLedger()
        let state = gridSnapshot(height: 4)
        let request = try XCTUnwrap(resolveRequest(try captureGridDeep(&ledger, snapshot: state, height: 4)))
        let token = try XCTUnwrap(armedTimer(surfaceState(&ledger, request: request, rows: 5, snapshot: state), milliseconds: 40))

        _ = ledger.reduce(.clientSize(columns: 80, rows: 6), snapshot: state)
        let asked = ledger.reduce(.timerFired(token: token), snapshot: state)
        let resync = surfaceState(&ledger, request: try XCTUnwrap(resolveRequest(asked)), rows: 5, snapshot: state)
        XCTAssertTrue(resync.contains(.diagnostic("render-ledger size-resync surface=pane-1 attempt=1")))
        XCTAssertTrue(resync.contains(.sendCommand(RenderCommands.renderedPaneMetadata(target: PaneId(1)))))
        XCTAssertTrue(feeds(in: resync).isEmpty)
    }

    func testLegacyMetadataWithoutAPaneGridPaintsAtOnce() throws {
        var ledger = TmuxRenderLedger()
        let state = gridSnapshot(height: 4)
        let legacy = metadata(height: 4).split(separator: "\t", omittingEmptySubsequences: false)
            .dropLast(2).joined(separator: "\t")
        let waiting = try captureGridDeep(&ledger, snapshot: state, height: 4, metadataLine: legacy)
        let painted = surfaceState(&ledger, request: try XCTUnwrap(resolveRequest(waiting)), rows: 5, snapshot: state)
        XCTAssertEqual(feeds(in: painted).map(\.source), [.deepRepaint, .repaintScrub])
    }

    func testMoshHistoryNeverWaitsForTheGrid() throws {
        var ledger = TmuxRenderLedger()
        let state = singleSnapshot(height: 4)
        _ = ledger.reduce(.surfacesDeclared([.init(surfaceID: .live, presentation: .single)]), snapshot: state)
        _ = ledger.reduce(.transportAttached(.sideChannel), snapshot: state)
        let start = ledger.reduce(.scrollbackRequested(.live, pointsY: 1, isInertial: false), snapshot: state)
        XCTAssertTrue(start.contains(.sendCommand(RenderCommands.renderedPaneMetadata(target: PaneId(1)))))
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: [metadata(height: 4)]), [])
        let waiting = reply(&ledger, snapshot: state, lines: history + screen)
        let request = try XCTUnwrap(resolveRequest(waiting, surfaceID: .live))
        let painted = ledger.reduce(
            .surfaceState(.live, request: request, altScreen: false, mouseMode: .off, columns: 80, rows: 5),
            snapshot: state
        )
        XCTAssertEqual(feeds(in: painted).map(\.source), [.moshHistory])
        XCTAssertFalse(painted.contains { effect in
            if case .diagnostic(let message) = effect { return message.contains("surface-grid") }
            return false
        })
    }

    func testOutputOverflowDuringTheWaitSpendsOnlyTheRestOfIt() throws {
        var ledger = TmuxRenderLedger(configuration: .init(
            surfaceGridPollMilliseconds: 40,
            surfaceGridWaitMilliseconds: 120,
            maximumForegroundOutputBytes: 4
        ))
        let state = gridSnapshot(height: 4)
        let request = try XCTUnwrap(resolveRequest(try captureGridDeep(&ledger, snapshot: state, height: 4)))
        let token = try XCTUnwrap(armedTimer(surfaceState(&ledger, request: request, rows: 5, snapshot: state), milliseconds: 40))
        XCTAssertEqual(
            ledger.reduce(.message(.output(paneId: PaneId(1), data: Array("too much".utf8))), snapshot: state),
            [.diagnostic("render-ledger post-capture-output-overflow surface=pane-1")]
        )
        let asked = ledger.reduce(.timerFired(token: token), snapshot: state)
        let recapture = surfaceState(&ledger, request: try XCTUnwrap(resolveRequest(asked)), rows: 5, snapshot: state)
        XCTAssertTrue(recapture.contains(.diagnostic("render-ledger post-capture-output-resync surface=pane-1")))
        XCTAssertTrue(recapture.contains(.sendCommand(RenderCommands.renderedPaneMetadata(target: PaneId(1)))))

        var next = try XCTUnwrap(resolveRequest(answerGridDeep(&ledger, snapshot: state, metadataLine: metadata(height: 4))))
        var polls = 0
        while true {
            let effects = surfaceState(&ledger, request: next, rows: 5, snapshot: state)
            guard let timer = armedTimer(effects, milliseconds: 40) else {
                XCTAssertTrue(effects.contains(.diagnostic(
                    "render-ledger surface-grid-wait-expired surface=pane-1 columns=40 paneColumns=40 rows=5 paneRows=4 waitedMs=120"
                )))
                XCTAssertEqual(feeds(in: effects).map(\.source), [.deepRepaint, .repaintScrub])
                break
            }
            polls += 1
            XCTAssertLessThan(polls, 3, "the recapture must not start the wait over")
            next = try XCTUnwrap(resolveRequest(ledger.reduce(.timerFired(token: timer), snapshot: state)))
        }
        XCTAssertEqual(polls, 2)
    }

    func testBackgroundDuringAWaitingDeepenStillSettlesTheReader() throws {
        var ledger = TmuxRenderLedger()
        let state = gridSnapshot(height: 4)
        let first = try captureGridDeep(&ledger, snapshot: state, height: 4, historySize: 3_000)
        let painted = surfaceState(&ledger, request: try XCTUnwrap(resolveRequest(first)), rows: 4, snapshot: state)
        let owner = try XCTUnwrap(painted.compactMap { effect -> RenderOwner? in
            guard case .inlineHistorySettled(_, let owner, 2_000, 3_000, true) = effect else { return nil }
            return owner
        }.first)

        let deepen = ledger.reduce(.scrollbackRequested(paneSurface, pointsY: 1, isInertial: false), snapshot: state)
        XCTAssertTrue(deepen.contains(.sendCommand(RenderCommands.renderedPaneMetadata(target: PaneId(1)))))
        let waiting = answerGridDeep(
            &ledger,
            snapshot: state,
            metadataLine: metadata(height: 4, historySize: 3_000),
            depth: 10_000
        )
        let held = surfaceState(&ledger, request: try XCTUnwrap(resolveRequest(waiting)), rows: 5, snapshot: state)
        XCTAssertNotNil(armedTimer(held, milliseconds: 40))
        XCTAssertTrue(feeds(in: held).isEmpty)

        let backgrounded = ledger.reduce(.appBackground, snapshot: state)
        let settled = backgrounded.compactMap { effect -> RenderOwner? in
            guard case .inlineHistorySettled(paneSurface, let owner, 2_000, 3_000, true) = effect else { return nil }
            return owner
        }
        XCTAssertEqual(settled, [owner], "the reader's gesture gets exactly one settle")
    }

    func testClientResizeOrReattachForgetsALastingMismatch() throws {
        var ledger = TmuxRenderLedger(configuration: .init(
            surfaceGridPollMilliseconds: 40,
            surfaceGridWaitMilliseconds: 40
        ))
        let state = gridSnapshot(height: 4)
        let firstWait = surfaceState(
            &ledger,
            request: try XCTUnwrap(resolveRequest(try captureGridDeep(&ledger, snapshot: state, height: 4))),
            rows: 5,
            snapshot: state
        )
        let token = try XCTUnwrap(armedTimer(firstWait, milliseconds: 40))
        let expired = surfaceState(
            &ledger,
            request: try XCTUnwrap(resolveRequest(ledger.reduce(.timerFired(token: token), snapshot: state))),
            rows: 5,
            snapshot: state
        )
        XCTAssertFalse(feeds(in: expired).isEmpty)

        // The size replay's own replies come first in the FIFO.
        for effect in ledger.reduce(.clientSize(columns: 80, rows: 5), snapshot: state) {
            if case .sendCommand = effect { _ = reply(&ledger, snapshot: state, lines: []) }
        }
        let afterResize = try captureGridDeep(&ledger, snapshot: state, height: 4, reason: "resized")
        let resizedWait = surfaceState(&ledger, request: try XCTUnwrap(resolveRequest(afterResize)), rows: 5, snapshot: state)
        let resizedToken = try XCTUnwrap(
            armedTimer(resizedWait, milliseconds: 40),
            "a new client size is a new geometry to wait for"
        )
        XCTAssertFalse(feeds(in: surfaceState(
            &ledger,
            request: try XCTUnwrap(resolveRequest(ledger.reduce(.timerFired(token: resizedToken), snapshot: state))),
            rows: 5,
            snapshot: state
        )).isEmpty)

        _ = ledger.reduce(.transportLost, snapshot: state)
        let attached = ledger.reduce(.transportAttached(.inline), snapshot: state)
        XCTAssertTrue(attached.contains(.sendCommand(RenderCommands.renderedPaneMetadata(target: PaneId(1)))))
        let reattached = answerGridDeep(&ledger, snapshot: state, metadataLine: metadata(height: 4))
        XCTAssertNotNil(
            armedTimer(surfaceState(&ledger, request: try XCTUnwrap(resolveRequest(reattached)), rows: 5, snapshot: state), milliseconds: 40),
            "a new transport's surface may still be settling"
        )
    }
}

// MARK: - Fixtures

private extension RenderLedgerSurfaceGridTests {
    func assemble(captureLines: [String], clientRows: Int, paneRows: Int?) -> [UInt8] {
        TmuxRepaintAssembly.assemble(
            state: TmuxRenderedPaneStateParser.parse(metadata(height: 4))!,
            captureLines: captureLines,
            historyLines: [],
            savedPrimaryLines: [],
            altScreenLines: nil,
            terminalIsInAltScreen: false,
            clientRows: clientRows,
            paneRows: paneRows
        )
    }

    /// The full rendered-pane reply: cursor on the pane's last row, a
    /// full-pane scroll region and the pane grid last.
    func metadata(
        height: Int,
        width: Int = 40,
        alt: Bool = false,
        title: String = "pane",
        historySize: Int = 6
    ) -> String {
        [
            "%1", "0", "\(height - 1)", title, "window", "host", alt ? "1" : "0",
            "\(historySize)", "0", "\(height - 1)", "1", "0", "0", "0", "1", "0", "0", "0", "0", "0", "0", "0",
            "\(width)", "\(height)",
        ].joined(separator: "\t")
    }

    /// Declares a grid surface for pane 1 (first time only) and runs a deep
    /// refresh up to the platform's surface-state hop.
    func captureGridDeep(
        _ ledger: inout TmuxRenderLedger,
        snapshot state: TmuxSnapshot,
        height: Int,
        reason: String = "mount",
        metadataLine: String? = nil,
        historySize: Int = 6
    ) throws -> [RenderEffect] {
        if ledger.profile == nil {
            _ = ledger.reduce(.transportAttached(.inline), snapshot: state)
            _ = ledger.reduce(.surfacesDeclared([
                .init(surfaceID: paneSurface, presentation: .grid, windowID: WindowId(1), paneID: PaneId(1)),
            ]), snapshot: state)
        }
        let started = ledger.reduce(.refreshRequested(paneSurface, stage: .deep, reason: reason), snapshot: state)
        XCTAssertTrue(started.contains(.sendCommand(RenderCommands.renderedPaneMetadata(target: PaneId(1)))))
        return answerGridDeep(
            &ledger,
            snapshot: state,
            metadataLine: metadataLine ?? metadata(height: height, historySize: historySize)
        )
    }

    /// Answers a deep refresh whose metadata query is already on the wire.
    func answerGridDeep(
        _ ledger: inout TmuxRenderLedger,
        snapshot state: TmuxSnapshot,
        metadataLine line: String,
        depth: Int = 2_000
    ) -> [RenderEffect] {
        XCTAssertTrue(reply(&ledger, snapshot: state, lines: [line])
            .contains(.sendCommand(RenderCommands.deepPrimary(target: PaneId(1), depth: depth))))
        let settle = reply(&ledger, snapshot: state, lines: history + screen)
        XCTAssertTrue(settle.contains(.sendCommand(RenderCommands.viewport(target: PaneId(1)))))
        XCTAssertEqual(reply(&ledger, snapshot: state, lines: [line]), [])
        return reply(&ledger, snapshot: state, lines: screen)
    }

    func surfaceState(
        _ ledger: inout TmuxRenderLedger,
        request: UInt64,
        columns: Int = 40,
        rows: Int,
        snapshot state: TmuxSnapshot
    ) -> [RenderEffect] {
        ledger.reduce(
            .surfaceState(paneSurface, request: request, altScreen: false, mouseMode: .off, columns: columns, rows: rows),
            snapshot: state
        )
    }

    func gridSnapshot(height: Int, width: Int = 40) -> TmuxSnapshot {
        let first = CellRect(width: width, height: height, x: 0, y: 0)
        let second = CellRect(width: width - 1, height: height, x: width + 1, y: 0)
        let layout = WindowLayout(root: .split(
            axis: .horizontal,
            rect: CellRect(width: width * 2, height: height, x: 0, y: 0),
            children: [.leaf(paneId: PaneId(1), rect: first), .leaf(paneId: PaneId(2), rect: second)]
        ))
        return .init(
            sessionID: SessionId(0),
            sessionName: "work",
            activeWindowID: WindowId(1),
            windows: [.init(
                id: WindowId(1),
                name: "grid",
                activePaneID: PaneId(1),
                panes: [
                    .init(id: PaneId(1), isActive: true, contentRect: first),
                    .init(id: PaneId(2), contentRect: second),
                ],
                layout: layout
            )],
            authority: .unknown
        )
    }

    func singleSnapshot(height: Int) -> TmuxSnapshot {
        let rect = CellRect(width: 80, height: height, x: 0, y: 0)
        let layout = WindowLayout(root: .leaf(paneId: PaneId(1), rect: rect))
        return .init(
            sessionID: SessionId(0),
            sessionName: "work",
            activeWindowID: WindowId(1),
            windows: [.init(
                id: WindowId(1),
                name: "single",
                activePaneID: PaneId(1),
                panes: [.init(id: PaneId(1), isActive: true, contentRect: rect)],
                layout: layout,
                visibleLayout: layout
            )],
            authority: .unknown
        )
    }

    func reply(_ ledger: inout TmuxRenderLedger, snapshot state: TmuxSnapshot, lines: [String]) -> [RenderEffect] {
        let guardFrame = TmuxCommandGuard(time: 1, commandNumber: 1, flags: 1)
        return ledger.reduce(.correlation(.frameCompleted(.init(
            status: .success,
            begin: guardFrame,
            end: guardFrame,
            effectiveFlags: 1,
            guardMatches: true,
            lines: lines
        ))), snapshot: state)
    }

    func resolveRequest(_ effects: [RenderEffect], surfaceID: SurfaceId? = nil) -> UInt64? {
        for effect in effects {
            if case .resolveSurfaceState(let id, let request) = effect, id == (surfaceID ?? paneSurface) {
                return request
            }
        }
        return nil
    }

    func armedTimer(_ effects: [RenderEffect], milliseconds: Int) -> UInt64? {
        effects.compactMap { effect -> UInt64? in
            guard case .armTimer(let token, milliseconds) = effect else { return nil }
            return token
        }.last
    }

    func feeds(in effects: [RenderEffect]) -> [(reference: RenderBytesRef, source: RenderFeedSource)] {
        effects.compactMap { effect in
            guard case .feed(_, _, let reference, let source) = effect else { return nil }
            return (reference, source)
        }
    }
}

/// Just enough of a terminal to follow a repaint: text, CR/LF with
/// scrollback, cursor position, erase-display and the alternate screen.
/// Shrinking follows SwiftTerm (xterm.js): rows below the cursor are
/// dropped first, then the top row scrolls into history.
private struct ScreenModel {
    private(set) var rows: Int
    private(set) var scrollback: [String] = []
    private(set) var cursorRow = 0
    private var cursorColumn = 0
    private var lines: [[Character]]
    private var savedPrimary: (lines: [[Character]], row: Int, column: Int)?

    init(rows: Int) {
        self.rows = rows
        lines = Array(repeating: [], count: rows)
    }

    var isAlternate: Bool { savedPrimary != nil }
    var screenRows: [String] { lines.map { String($0) } }
    var savedPrimaryRows: [String]? { savedPrimary?.lines.map { String($0) } }

    mutating func feed(_ bytes: [UInt8]) {
        let scalars = Array(String(decoding: bytes, as: UTF8.self).unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\u{1B}" {
                guard index + 1 < scalars.count else { return }
                guard scalars[index + 1] == "[" else {
                    index += 2
                    continue
                }
                var end = index + 2
                var parameters = ""
                while end < scalars.count, !(0x40...0x7E).contains(scalars[end].value) {
                    parameters.unicodeScalars.append(scalars[end])
                    end += 1
                }
                guard end < scalars.count else { return }
                control(final: scalars[end], parameters: parameters)
                index = end + 1
                continue
            }
            switch scalar {
            case "\r": cursorColumn = 0
            case "\n": lineFeed()
            default: put(Character(scalar))
            }
            index += 1
        }
    }

    mutating func shrink(to newRows: Int) {
        while rows > newRows {
            if lines.count - 1 > cursorRow {
                lines.removeLast()
            } else {
                scrollback.append(String(lines.removeFirst()))
                cursorRow -= 1
            }
            rows -= 1
        }
    }

    private mutating func control(final: Unicode.Scalar, parameters: String) {
        switch (final, parameters) {
        case ("H", _):
            let values = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 1 }
            cursorRow = min(rows - 1, max(0, (values.first ?? 1) - 1))
            cursorColumn = max(0, (values.count > 1 ? values[1] : 1) - 1)
        case ("J", "2"):
            lines = Array(repeating: [], count: rows)
        case ("h", "?1049"):
            guard savedPrimary == nil else { return }
            savedPrimary = (lines, cursorRow, cursorColumn)
            lines = Array(repeating: [], count: rows)
        case ("l", "?1049"):
            guard let saved = savedPrimary else { return }
            (lines, cursorRow, cursorColumn) = saved
            savedPrimary = nil
        default:
            // SGR, modes and scroll regions do not move rows in these frames.
            break
        }
    }

    private mutating func lineFeed() {
        guard cursorRow == rows - 1 else {
            cursorRow += 1
            return
        }
        let top = lines.removeFirst()
        if savedPrimary == nil { scrollback.append(String(top)) }
        lines.append([])
    }

    private mutating func put(_ character: Character) {
        while lines[cursorRow].count < cursorColumn { lines[cursorRow].append(" ") }
        if cursorColumn < lines[cursorRow].count {
            lines[cursorRow][cursorColumn] = character
        } else {
            lines[cursorRow].append(character)
        }
        cursorColumn += 1
    }
}
