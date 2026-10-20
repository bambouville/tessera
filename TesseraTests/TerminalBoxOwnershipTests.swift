import XCTest
import SwiftTerm
import TmuxControl
import TmuxControlCore
import MoshBridge
@testable import Tessera

/// Focused contract tests for the terminal-surface ingress seam. These use a
/// real SwiftTerm view so the scrollback trim is verified at the same boundary
/// that production repaint bytes use.
@MainActor
final class TerminalBoxOwnershipTests: XCTestCase {
    private let ownerA = TerminalRenderOwner(
        windowId: WindowId(1), paneId: PaneId(11), epoch: 1
    )
    private let ownerB = TerminalRenderOwner(
        windowId: WindowId(2), paneId: PaneId(22), epoch: 1
    )
    private let ownerAAfterReconnect = TerminalRenderOwner(
        windowId: WindowId(1), paneId: PaneId(11), epoch: 2
    )

    func testAllMotionMouseCaptureSurvivesFreshSurfaceRebindAndResize() throws {
        let state = try XCTUnwrap(TmuxRenderedPaneStateParser.parse(
            ["%11", "2", "2", "Codex", "work", "fixture", "1", "0", "0", "3",
             "1", "0", "0", "0", "1", "0", "0", "1", "1", "0", "0", "0", "40", "4"]
                .joined(separator: "\t")
        ))
        // New app surfaces and replacement connection epochs both enter this
        // owned repaint path without receiving the TUI's original mode sets.
        for _ in 0..<2 {
            let view = MouseCaptureTerminalView(frame: .zero)
            view.resize(cols: 40, rows: 4)
            let box = TerminalBox(traceLabel: "mouse-recovery-test")
            box.attach(view)
            box.markRenderReady()
            let terminal = view.getTerminal()
            for owner in [ownerA, ownerAAfterReconnect] {
                box.bind(owner: owner, restoringScrollbackLimit: 128)
                let repaint = TmuxRepaintAssembly.assemble(
                    state: state, captureLines: ["TRANSCRIPT", "KEEP MY DRAFT"],
                    historyLines: [], savedPrimaryLines: [], altScreenLines: nil,
                    terminalIsInAltScreen: terminal.isCurrentBufferAlternate,
                    clientRows: terminal.rows
                )
                box.feed(owner: owner, repaint[...])
                XCTAssertEqual(terminal.mouseMode, .anyEvent)
                XCTAssertTrue(terminal.isCurrentBufferAlternate)
                XCTAssertTrue(visibleTerminalText(terminal).joined(separator: "\n").contains("KEEP MY DRAFT"))
                view.sentBytes.removeAll()
                terminal.sendEvent(buttonFlags: 64, x: 7, y: 2)
                XCTAssertEqual(String(decoding: view.sentBytes, as: UTF8.self), "\u{1B}[<64;8;3M")
                terminal.resize(cols: 56, rows: 30)
                XCTAssertEqual(terminal.mouseMode, .anyEvent)
                view.sentBytes.removeAll()
                terminal.sendEvent(buttonFlags: 65, x: 7, y: 8)
                XCTAssertEqual(String(decoding: view.sentBytes, as: UTF8.self), "\u{1B}[<65;8;9M")
            }
        }
    }

    private final class MouseCaptureTerminalView: TerminalView {
        var sentBytes: [UInt8] = []
        override func send(source: Terminal, data: ArraySlice<UInt8>) {
            sentBytes.append(contentsOf: data)
        }
    }

    func testNativeMoshFramesRestoreTrackingAfterEncodingAndResize() {
        let view = MouseCaptureTerminalView(frame: .zero)
        view.resize(cols: 12, rows: 3)
        let box = TerminalBox(traceLabel: "mosh-mouse-frame-test")
        box.attach(view)
        box.markRenderReady()
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        let terminal = view.getTerminal()

        // Reproduce the parser interaction with the actual legacy Mosh frame.
        let legacy = MoshBridgeProbe.mouseFrameProbe(mode: 1003, encoding: 1006, scenario: 4)
        XCTAssertFalse(legacy.isEmpty)
        box.feed(owner: ownerA, Array(legacy)[...])
        XCTAssertEqual(terminal.mouseMode, .off)

        let modes: [(Int, Terminal.MouseMode)] = [(9, .x10), (1000, .vt200), (1002, .buttonEventTracking), (1003, .anyEvent)]
        for (mode, expected) in modes {
            for encoding in [1006, 0, 1006, 1005, 1015] {
                for scenario in 0...2 {
                    let frame = MoshBridgeProbe.mouseFrameProbe(mode: mode, encoding: encoding, scenario: scenario)
                    XCTAssertFalse(frame.isEmpty)
                    box.feed(owner: ownerA, Array(frame)[...])
                    XCTAssertEqual(terminal.mouseMode, expected, "mode=\(mode) encoding=\(encoding) scenario=\(scenario)")
                    if encoding == 1006 {
                        view.sentBytes.removeAll()
                        terminal.sendEvent(buttonFlags: 64, x: 7, y: 2)
                        XCTAssertEqual(String(decoding: view.sentBytes, as: UTF8.self), "\u{1B}[<64;8;3M")
                    }
                }
            }
        }
        let disabled = MoshBridgeProbe.mouseFrameProbe(mode: 0, encoding: 0, scenario: 1)
        box.feed(owner: ownerA, Array(disabled)[...])
        XCTAssertEqual(terminal.mouseMode, .off, "A real tracking reset must stay off")
        XCTAssertTrue(MoshBridgeProbe.mouseFrameProbe(mode: 1003, encoding: 1006, scenario: 3).isEmpty)
    }

    func testForeignOwnerFeedNeverReachesTerminalViewAndIsCounted() {
        let (box, terminal) = makeBox()
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)

        box.feed(owner: ownerA, bytes("OWNER_A\r\n"))
        box.feed(owner: ownerB, bytes("FOREIGN_OWNER_B\r\n"))

        let rendered = allTerminalText(terminal)
        XCTAssertTrue(rendered.contains("OWNER_A"))
        XCTAssertFalse(rendered.contains("FOREIGN_OWNER_B"))
        XCTAssertEqual(box.droppedForeignFeeds, 1)
    }

    func testBindToDifferentOwnerEmptiesHistoryWhileKeepingVisibleViewport() {
        let (box, terminal) = makeBox()
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        fillHistory(in: box, owner: ownerA, rows: terminal.rows * 3)

        XCTAssertNotNil(terminal.getScrollInvariantLine(row: terminal.rows))
        let visibleBefore = visibleTerminalText(terminal)

        box.bind(owner: ownerB, restoringScrollbackLimit: 128)

        XCTAssertEqual(visibleTerminalText(terminal), visibleBefore)
        XCTAssertNil(
            terminal.getScrollInvariantLine(row: terminal.rows),
            "a new owner must retain the visible grid but not prior scrollback"
        )
        XCTAssertEqual(box.boundOwner, ownerB)
    }

    /// A deepen replaces the revealed page under a fresh owner, and that
    /// bind empties the buffer before the replacement feeds. The presentation
    /// must still know how far the reader was from the tail, so `bind`
    /// snapshots that distance before clearing and hands it over exactly once.
    func testBindSnapshotsReaderPositionBeforeClearingScrollback() throws {
        let (box, terminal) = makeBox()
        let view = try XCTUnwrap(box.view)
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        fillHistory(in: box, owner: ownerA, rows: terminal.rows * 6)
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        XCTAssertGreaterThan(maxOffsetY, 0)
        let readerOffsetY = (maxOffsetY / 2).rounded()
        view.contentOffset = CGPoint(x: 0, y: readerOffsetY)
        XCTAssertNil(
            box.takeScrollPositionBeforeRebind(for: ownerAAfterReconnect),
            "nothing is snapshotted for an owner until its own bind clears"
        )

        box.bind(owner: ownerAAfterReconnect, restoringScrollbackLimit: 128)

        XCTAssertNil(
            box.takeScrollPositionBeforeRebind(for: ownerB),
            "a snapshot never travels from one owner's clear to another owner's page"
        )
        let snapshot = box.takeScrollPositionBeforeRebind(for: ownerAAfterReconnect)
        XCTAssertEqual(snapshot?.offsetY, readerOffsetY, "a foreign take must not consume the binder's snapshot")
        XCTAssertEqual(snapshot?.maxOffsetY, maxOffsetY)
        XCTAssertNil(
            box.takeScrollPositionBeforeRebind(for: ownerAAfterReconnect),
            "the snapshot is consumed once"
        )
        XCTAssertLessThan(
            max(0, view.contentSize.height - view.bounds.height),
            maxOffsetY,
            "the clear itself has already discarded the distance the snapshot preserves"
        )
    }

    /// The ledger binds a replacement page's owner one effect batch before
    /// the page feeds. Until then the emptied buffer belongs to nobody, and
    /// only the bound owner's bytes (or an admitted painter feed) end that
    /// interval; a foreign feed or an empty owned page must not be confused
    /// with content, except that an empty page from the bound owner is
    /// still that owner's (zero-range) content.
    func testBindAwaitsContentUntilTheBoundOwnerOrPainterFeeds() {
        let (box, _) = makeBox()
        XCTAssertFalse(box.isAwaitingContentAfterRebind)

        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        XCTAssertTrue(box.isAwaitingContentAfterRebind, "a bind empties the buffer")
        XCTAssertFalse(box.feed(owner: ownerB, bytes("FOREIGN\r\n")))
        XCTAssertTrue(box.isAwaitingContentAfterRebind, "a foreign feed is dropped, not content")
        XCTAssertTrue(box.feed(owner: ownerA, bytes("OWNED\r\n")))
        XCTAssertFalse(box.isAwaitingContentAfterRebind)

        box.bind(owner: ownerAAfterReconnect, restoringScrollbackLimit: 128)
        XCTAssertTrue(box.isAwaitingContentAfterRebind)
        XCTAssertFalse(box.feed(owner: ownerAAfterReconnect, bytes("")))
        XCTAssertFalse(box.isAwaitingContentAfterRebind, "a zero-range page is still the owner's content")

        box.bind(owner: ownerB, restoringScrollbackLimit: 128)
        box.setAcceptsPainterFeeds(false)
        XCTAssertFalse(box.feed(owner: nil, bytes("REJECTED_PAINTER\r\n")))
        XCTAssertTrue(box.isAwaitingContentAfterRebind, "a rejected painter feed is not content")
        box.setAcceptsPainterFeeds(true)
        XCTAssertTrue(box.feed(owner: nil, bytes("PAINTER\r\n")))
        XCTAssertFalse(box.isAwaitingContentAfterRebind, "an admitted painter frame fills the buffer")
    }

    /// Two binds can land before any page feeds (the second one supersedes
    /// the first's page). The view then only knows an empty buffer, so the
    /// reader's real pre-clear distance must travel to the owner that
    /// finally presents.
    func testRebindOverAnEmptyBufferCarriesTheReaderSnapshotForward() throws {
        let (box, terminal) = makeBox()
        let view = try XCTUnwrap(box.view)
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        fillHistory(in: box, owner: ownerA, rows: terminal.rows * 6)
        let maxOffsetY = max(0, view.contentSize.height - view.bounds.height)
        let readerOffsetY = (maxOffsetY / 2).rounded()
        view.contentOffset = CGPoint(x: 0, y: readerOffsetY)

        box.bind(owner: ownerAAfterReconnect, restoringScrollbackLimit: 128)
        box.bind(owner: ownerB, restoringScrollbackLimit: 128)

        XCTAssertNil(box.takeScrollPositionBeforeRebind(for: ownerAAfterReconnect))
        let carried = box.takeScrollPositionBeforeRebind(for: ownerB)
        XCTAssertEqual(carried?.offsetY, readerOffsetY)
        XCTAssertEqual(carried?.maxOffsetY, maxOffsetY)

        // Once content has arrived, a later bind samples the live view again.
        box.feed(owner: ownerB, bytes("CONTENT\r\n"))
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        let sampled = box.takeScrollPositionBeforeRebind(for: ownerA)
        XCTAssertNotNil(sampled)
        XCTAssertNotEqual(sampled, carried, "a filled buffer is sampled, not carried")
    }

    func testBindToSameOwnerIsNoOp() {
        let (box, terminal) = makeBox()
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        fillHistory(in: box, owner: ownerA, rows: terminal.rows * 3)

        let historyLine = terminal.getScrollInvariantLine(row: terminal.rows)
        let visibleBefore = visibleTerminalText(terminal)
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)

        XCTAssertNotNil(historyLine)
        XCTAssertNotNil(terminal.getScrollInvariantLine(row: terminal.rows))
        XCTAssertEqual(visibleTerminalText(terminal), visibleBefore)
        XCTAssertEqual(box.boundOwner, ownerA)
    }

    func testNewEpochRejectsLateFeedForSameWindowAndPane() {
        let (box, terminal) = makeBox()
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        box.bind(owner: ownerAAfterReconnect, restoringScrollbackLimit: 128)

        box.feed(owner: ownerA, bytes("LATE_PRE_RECONNECT\r\n"))
        box.feed(owner: ownerAAfterReconnect, bytes("CURRENT_RECONNECT\r\n"))

        let rendered = allTerminalText(terminal)
        XCTAssertFalse(rendered.contains("LATE_PRE_RECONNECT"))
        XCTAssertTrue(rendered.contains("CURRENT_RECONNECT"))
        XCTAssertEqual(box.droppedForeignFeeds, 1)
    }

    func testFreshOwnerEpochReplacesFullHistoryInsteadOfAppendingIt() {
        let (box, terminal) = makeBox()
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        fillHistory(in: box, owner: ownerA, rows: terminal.rows * 3)
        box.feed(owner: ownerA, bytes("OLD_CAPTURE_MARKER\r\n"))

        box.bind(owner: ownerAAfterReconnect, restoringScrollbackLimit: 128)
        // `bind` intentionally preserves the current viewport. An
        // authoritative tmux repaint owns replacing that grid, so model the
        // same ED + home prelude emitted by the repaint assembler here.
        box.feed(
            owner: ownerAAfterReconnect,
            bytes("\u{1B}[2J\u{1B}[HNEW_CAPTURE_MARKER\r\n")
        )

        let rendered = allTerminalText(terminal)
        XCTAssertFalse(rendered.contains("OLD_CAPTURE_MARKER"))
        XCTAssertEqual(rendered.components(separatedBy: "NEW_CAPTURE_MARKER").count - 1, 1)
        XCTAssertEqual(box.boundOwner, ownerAAfterReconnect)
    }

    func testPainterFeedRemainsAllowedWhileSurfaceIsBound() {
        let (box, terminal) = makeBox()

        box.feed(owner: nil, bytes("PAINTER_OK\r\n"))
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        box.feed(owner: nil, bytes("BOUND_PAINTER_OK\r\n"))

        let rendered = allTerminalText(terminal)
        XCTAssertTrue(rendered.contains("PAINTER_OK"))
        XCTAssertTrue(rendered.contains("BOUND_PAINTER_OK"))
        XCTAssertEqual(box.droppedForeignFeeds, 0)
    }

    func testInlineControlModeClosesThePainterIngress() {
        let (box, terminal) = makeBox()
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        box.setAcceptsPainterFeeds(false)

        box.feed(bytes("UNTAGGED_INLINE_BYTES\r\n"))
        box.feed(owner: ownerA, bytes("TAGGED_INLINE_BYTES\r\n"))

        let rendered = allTerminalText(terminal)
        XCTAssertFalse(rendered.contains("UNTAGGED_INLINE_BYTES"))
        XCTAssertTrue(rendered.contains("TAGGED_INLINE_BYTES"))
        XCTAssertEqual(box.droppedForeignFeeds, 1)
    }

    func testPainterFeedIsRejectedForAHistoryOnlySurface() {
        let view = TerminalView(frame: .zero)
        view.resize(cols: 40, rows: 4)
        let box = TerminalBox(
            traceLabel: "history-only-ownership-test",
            acceptsPainterFeeds: false
        )
        box.attach(view)
        box.markRenderReady()
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)

        box.feed(owner: nil, bytes("UNTAGGED_PAINTER\r\n"))
        box.feed(owner: ownerA, bytes("LEDGER_OWNER_A\r\n"))

        let rendered = allTerminalText(view.getTerminal())
        XCTAssertFalse(rendered.contains("UNTAGGED_PAINTER"))
        XCTAssertTrue(rendered.contains("LEDGER_OWNER_A"))
        XCTAssertEqual(box.droppedForeignFeeds, 1)
    }

    func testOwnedPresentationWaitsUntilBufferedBytesReachAttachedTerminal() {
        let view = TerminalView(frame: .zero)
        view.resize(cols: 40, rows: 4)
        let box = TerminalBox(
            traceLabel: "pre-ready-owned-presentation-test",
            acceptsPainterFeeds: false
        )
        box.attach(view)
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        box.feed(owner: ownerA, bytes("BUFFERED_HISTORY_MARKER\r\n"))

        XCTAssertFalse(box.isReadyForOwnedPresentation)
        XCTAssertFalse(allTerminalText(view.getTerminal()).contains("BUFFERED_HISTORY_MARKER"))

        box.markRenderReady()

        XCTAssertTrue(box.isReadyForOwnedPresentation)
        XCTAssertTrue(allTerminalText(view.getTerminal()).contains("BUFFERED_HISTORY_MARKER"))
    }

    func testSurfaceStateAndResizeAreOwnedByTheSameSeam() throws {
        let (box, _) = makeBox()

        box.resize(columns: 80, rows: 7)

        let state = try XCTUnwrap(box.surfaceState)
        XCTAssertEqual(state.columns, 80)
        XCTAssertEqual(state.rows, 7)
        XCTAssertFalse(state.altScreen)
        XCTAssertEqual(state.mouseMode, .off)
    }

    func testDropSummaryAggregatesEverySurfaceMonotonicallyIncludingZero() {
        var messages: [String] = []
        let reporter = RenderDropSummaryReporter { messages.append($0) }
        let first = TerminalBox(traceLabel: "summary-a", acceptsPainterFeeds: false)
        let second = TerminalBox(traceLabel: "summary-b", acceptsPainterFeeds: false)
        reporter.register(first)
        reporter.register(second)

        reporter.record(boundary: "initial")
        XCTAssertEqual(
            messages.last,
            "render_ledger_summary boundary=initial dropped_foreign=0"
        )

        first.feed(owner: nil, bytes("DROP_A_1"))
        first.feed(owner: nil, bytes("DROP_A_2"))
        second.feed(owner: nil, bytes("DROP_B_1"))
        reporter.unregister(first)
        reporter.record(boundary: "after-detach")
        XCTAssertEqual(
            messages.last,
            "render_ledger_summary boundary=after-detach dropped_foreign=3"
        )

        // Re-registering the same surface observes only new refusals rather
        // than adding its existing counter a second time.
        reporter.register(first)
        reporter.record(boundary: "reattach")
        XCTAssertEqual(
            messages.last,
            "render_ledger_summary boundary=reattach dropped_foreign=3"
        )
    }

    func testMoshHistoryWaitsForForcedPainterOutputConsumption() throws {
        let harness = MoshRepaintFenceHarness()
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "HISTORY_A")

        XCTAssertEqual(harness.repaintCompletions.count, 1)
        XCTAssertTrue(harness.ready.isEmpty)

        harness.repaintCompletions[0](7)
        XCTAssertTrue(harness.ready.isEmpty)
        harness.adapter.noteTransportOutputResult(
            deliveryID: 6,
            repaintRequestID: 1,
            renderedFully: true
        )
        XCTAssertTrue(harness.ready.isEmpty)

        harness.adapter.noteTransportOutputResult(
            deliveryID: 7,
            repaintRequestID: 1,
            renderedFully: true
        )
        XCTAssertEqual(harness.ready.map(\.surfaceID), [.live])
        XCTAssertEqual(String(decoding: try XCTUnwrap(harness.ready.first).history.bytes, as: UTF8.self), "HISTORY_A")
    }

    func testMoshLiveHistoryTailReleaseWaitsForPresentationAndAcceptsZeroRangeTail() {
        XCTAssertFalse(
            MoshLiveHistoryTailReleasePolicy.shouldRelease(
                isHistoryRevealed: true,
                hasPendingPresentation: true,
                isRebinding: false,
                isAwaitingContent: false,
                offsetY: 18,
                maxOffsetY: 4
            ),
            "a transient SwiftTerm range during history feed is not a user return to tail"
        )
        XCTAssertFalse(
            MoshLiveHistoryTailReleasePolicy.shouldRelease(
                isHistoryRevealed: true,
                hasPendingPresentation: false,
                isRebinding: true,
                isAwaitingContent: false,
                offsetY: 0,
                maxOffsetY: 0
            ),
            "the empty-buffer tail reported from a rebind's scrollback clear is not a user return to tail"
        )
        XCTAssertFalse(
            MoshLiveHistoryTailReleasePolicy.shouldRelease(
                isHistoryRevealed: true,
                hasPendingPresentation: false,
                isRebinding: false,
                isAwaitingContent: true,
                offsetY: 0,
                maxOffsetY: 0
            ),
            "a gesture frame landing between a rebind's clear and its page feed is not a user return to tail"
        )
        XCTAssertTrue(
            MoshLiveHistoryTailReleasePolicy.shouldRelease(
                isHistoryRevealed: true,
                hasPendingPresentation: false,
                isRebinding: false,
                isAwaitingContent: false,
                offsetY: 0,
                maxOffsetY: 0
            ),
            "an acknowledged zero-range history page is already at its only live-tail position"
        )
        XCTAssertTrue(
            MoshLiveHistoryTailReleasePolicy.shouldRelease(
                isHistoryRevealed: true,
                hasPendingPresentation: false,
                isRebinding: false,
                isAwaitingContent: false,
                offsetY: 100,
                maxOffsetY: 100
            ),
            "an actual revealed reader reaching the live tail still releases history"
        )
    }

    func testMoshLiveHistorySmallUpwardDragRetainsHistoryUntilActualTail() {
        for offset: CGFloat in [76, 94, 99, 99.75] {
            XCTAssertFalse(MoshLiveHistoryTailReleasePolicy.shouldRelease(
                isHistoryRevealed: true,
                hasPendingPresentation: false,
                isRebinding: false,
                isAwaitingContent: false,
                offsetY: offset,
                maxOffsetY: 100
            ), "even a subpoint upward move must retain the newly revealed history")
        }
        for offset: CGFloat in [100, 100.25] {
            XCTAssertTrue(MoshLiveHistoryTailReleasePolicy.shouldRelease(
                isHistoryRevealed: true,
                hasPendingPresentation: false,
                isRebinding: false,
                isAwaitingContent: false,
                offsetY: offset,
                maxOffsetY: 100
            ), "reaching or bouncing past the actual bottom releases history")
        }
    }

    /// `TerminalBox.bind` exposes its scrollback clear so the live tail-release
    /// policy can tell the empty-buffer offset from a reader's real return.
    func testBindReportsRebindingOnlyWhileClearingScrollback() {
        let (box, _) = makeBox()
        let delegate = ReentrantBindTerminalViewDelegate()
        box.view?.terminalDelegate = delegate
        var observed: [Bool] = []
        delegate.onScrolled = { observed.append(box.isRebinding) }

        XCTAssertFalse(box.isRebinding)
        box.bind(owner: ownerA, restoringScrollbackLimit: 128)
        XCTAssertFalse(box.isRebinding)
        XCTAssertFalse(observed.isEmpty, "changeScrollback reports scrolled synchronously")
        XCTAssertTrue(observed.allSatisfy { $0 })
    }

    func testMoshHistoryFenceHandlesAlreadyConsumedAndRetriesNoOutput() async throws {
        let harness = MoshRepaintFenceHarness()
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "EARLY_CONSUMED")
        harness.adapter.noteTransportOutputResult(
            deliveryID: 9,
            repaintRequestID: 1,
            renderedFully: true
        )
        harness.repaintCompletions[0](9)
        XCTAssertEqual(harness.ready.count, 1)

        harness.stageHistory(
            surfaceID: SurfaceId("overlay:%22"),
            owner: harness.ownerB,
            text: "NO_REPAINT_OUTPUT"
        )
        XCTAssertEqual(harness.ready.count, 1)
        harness.repaintCompletions[1](nil)
        XCTAssertEqual(harness.ready.count, 1)

        try await Task.sleep(nanoseconds: 75_000_000)
        await waitForRepaintCount(3, in: harness)
        XCTAssertEqual(harness.repaintCompletions.count, 3)
        harness.repaintCompletions[2](10)
        XCTAssertTrue(harness.deliver(
            "RETRY_FRAME",
            deliveryID: 10,
            repaintRequestID: 3
        ))
        XCTAssertEqual(harness.ready.map(\.surfaceID), [.live, SurfaceId("overlay:%22")])
    }

    func testMoshHistoryRetriesWhenExpectedReceiptNeverArrives() async throws {
        let harness = MoshRepaintFenceHarness(receiptTimeoutNanoseconds: 20_000_000)
        let overlay = SurfaceId("overlay:%22")
        harness.stageHistory(
            surfaceID: overlay,
            owner: harness.ownerB,
            text: "ONE_CAPTURE_ONLY"
        )
        harness.repaintCompletions[0](41)

        try await Task.sleep(nanoseconds: 90_000_000)
        await waitForRepaintCount(2, in: harness)
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        XCTAssertTrue(harness.ready.isEmpty)

        harness.repaintCompletions[1](42)
        XCTAssertTrue(harness.deliver(
            "RETRY_AFTER_MISSING_RECEIPT",
            deliveryID: 42,
            repaintRequestID: 2
        ))
        XCTAssertEqual(harness.ready.map(\.surfaceID), [overlay])
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(harness.ready.first).history.bytes, as: UTF8.self),
            "ONE_CAPTURE_ONLY",
            "receipt recovery must reuse the staged capture rather than capture-pane again"
        )
    }

    func testMoshHistoryFencesStayGloballyOrderedAndOwnerKeyed() {
        let harness = MoshRepaintFenceHarness()
        let overlay = SurfaceId("overlay:%22")
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "LIVE")
        harness.stageHistory(surfaceID: overlay, owner: harness.ownerB, text: "OVERLAY")

        harness.adapter.noteTransportOutputResult(
            deliveryID: 12,
            repaintRequestID: 2,
            renderedFully: true
        )
        harness.repaintCompletions[1](12)
        XCTAssertTrue(harness.ready.isEmpty, "a later surface must not pass the first repaint fence")

        harness.adapter.noteTransportOutputResult(
            deliveryID: 11,
            repaintRequestID: 1,
            renderedFully: true
        )
        harness.repaintCompletions[0](11)
        XCTAssertEqual(harness.ready.map(\.surfaceID), [.live, overlay])
        XCTAssertEqual(harness.dropped.count, 0)
    }

    func testMoshHistoryRejectsLaterUncorrelatedPainterFrameUntilTail() async throws {
        let harness = MoshRepaintFenceHarness()
        harness.liveBox.bind(
            owner: harness.terminalOwnerA,
            restoringScrollbackLimit: 2_000
        )
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "HISTORY")

        // A second, unrelated authority/layout repaint is queued after the
        // history-specific repaint but before the first output is consumed.
        harness.controller.requestTransportFullFrame?()
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        harness.repaintCompletions[0](1)
        harness.repaintCompletions[1](2)

        XCTAssertTrue(harness.deliver("FRAME_A", deliveryID: 1, repaintRequestID: 1))
        XCTAssertEqual(harness.ready.count, 1)

        // History has now closed untagged painter ingress. The later frame is
        // consumed by the pump but cannot mutate the synthetic reader.
        XCTAssertFalse(harness.deliver("FRAME_B", deliveryID: 2, repaintRequestID: 2))
        XCTAssertEqual(harness.liveBox.droppedForeignFeeds, 0)
        XCTAssertEqual(harness.ready.count, 1)

        let tailOwner = RenderOwner(windowID: WindowId(1), paneID: PaneId(11), epoch: 3)
        harness.controller.renderBindSurface?(.live, tailOwner)
        harness.controller.requestTransportFullFrame?()
        await waitForRepaintCount(3, in: harness)
        XCTAssertFalse(harness.deliver("TAIL_BOUNDARY", deliveryID: 3, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 3)
        harness.repaintCompletions[2](4)
        XCTAssertTrue(harness.deliver("TAIL_FRAME", deliveryID: 4, repaintRequestID: 3))
        XCTAssertEqual(harness.liveBox.droppedForeignFeeds, 0)
    }

    func testMoshHistoryResetAndOwnerChangeRejectLateRepaintCompletions() {
        let harness = MoshRepaintFenceHarness()
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "RESET_ME")
        harness.adapter.reset()
        XCTAssertEqual(harness.canceledRepaintRequestIDs, [1])
        XCTAssertFalse(harness.adapter.acceptsTransportOutput(repaintRequestID: 1))
        harness.repaintCompletions[0](3)
        harness.adapter.noteTransportOutputResult(
            deliveryID: 3,
            repaintRequestID: 1,
            renderedFully: false
        )
        XCTAssertTrue(harness.ready.isEmpty)

        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "OLD_OWNER")
        harness.controller.renderBindSurface?(.live, harness.ownerB)
        XCTAssertEqual(harness.canceledRepaintRequestIDs, [1, 2])
        XCTAssertFalse(harness.adapter.acceptsTransportOutput(repaintRequestID: 2))
        harness.repaintCompletions[1](4)
        harness.adapter.noteTransportOutputResult(
            deliveryID: 4,
            repaintRequestID: 2,
            renderedFully: false
        )
        XCTAssertTrue(harness.ready.isEmpty)

        // An unpaired layout/tail repaint must not consume the next history
        // feed's correlated fence.
        XCTAssertFalse(harness.deliver("BOUNDARY", deliveryID: 5, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 3)
        harness.repaintCompletions[2](6)
        XCTAssertTrue(harness.deliver("OWNER_B", deliveryID: 6, repaintRequestID: 3))

        harness.controller.requestTransportFullFrame?()
        harness.repaintCompletions[3](nil)
        harness.stageHistory(surfaceID: .live, owner: harness.ownerB, text: "CURRENT_OWNER")
        harness.repaintCompletions[4](nil)
        XCTAssertTrue(harness.ready.isEmpty)
        XCTAssertEqual(harness.dropped.count, 0)
    }

    func testMoshGenericRepaintLeaseIsRevokedAcrossOwnerChangeBetweenSlices() async {
        let harness = MoshRepaintFenceHarness()
        harness.controller.renderBindSurface?(.live, harness.ownerA)
        harness.controller.requestTransportFullFrame?()
        XCTAssertEqual(harness.repaintCompletions.count, 0)
        XCTAssertFalse(harness.deliver("CAUSAL_BOUNDARY", deliveryID: 1, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 1)

        let lease = harness.adapter.makeTransportOutputLease(repaintRequestID: 1)
        var admissionChecks = 0
        let renderedFully = await harness.liveBox.feedTerminalOutputCooperatively(
            Array(repeating: UInt8(0x41), count: 2_048)[...],
            context: .moshLive(originalByteCount: 2_048),
            shellIntegration: SwipePadShellIntegrationTracker(),
            owner: lease.owner,
            acceptsNextSlice: {
                admissionChecks += 1
                if admissionChecks == 2 {
                    harness.controller.renderBindSurface?(.live, harness.ownerB)
                }
                return lease.acceptsNextSlice()
            }
        )

        XCTAssertFalse(renderedFully)
        XCTAssertEqual(admissionChecks, 2)
        XCTAssertEqual(harness.liveBox.boundOwner, TerminalRenderOwner(
            windowId: WindowId(2), paneId: PaneId(22), epoch: 2
        ))
        XCTAssertEqual(harness.retiredThroughRequestIDs.last, 1)
        XCTAssertFalse(harness.adapter.acceptsTransportOutput(repaintRequestID: 1))
    }

    func testMoshQuiescentInitialBindSchedulesOneOwnedRepaint() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        harness.controller.requestTransportFullFrame?()
        XCTAssertFalse(harness.liveBox.painterFeedsAdmitted)
        XCTAssertEqual(harness.repaintCompletions.count, 0)

        await waitForRepaintCount(1, in: harness)

        XCTAssertEqual(harness.repaintCompletions.count, 1)
        try XCTUnwrap(harness.repaintCompletions.first)(11)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 11, repaintRequestID: 1))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.liveText.contains("OWNER_A_FRAME"))
    }

    func testMoshHistoryJoinsInFlightInitialPainterHandoff() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "JOINED_HISTORY")

        XCTAssertEqual(
            harness.repaintCompletions.count,
            1,
            "history must join the unresolved owner-authoritative frame"
        )
        try XCTUnwrap(harness.repaintCompletions.first)(7)
        XCTAssertTrue(harness.ready.isEmpty)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 7, repaintRequestID: 1))
        XCTAssertEqual(harness.repaintCompletions.count, 1)
        XCTAssertEqual(harness.ready.map(\.surfaceID), [.live])
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(harness.ready.first).history.bytes, as: UTF8.self),
            "JOINED_HISTORY"
        )
    }

    func testMoshHistoryJoiningHandoffBackfillsReceiptBeforeDriverCompletion() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 9, repaintRequestID: 1))

        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "LATE_JOIN")
        XCTAssertEqual(harness.repaintCompletions.count, 1)
        XCTAssertTrue(harness.ready.isEmpty)

        try XCTUnwrap(harness.repaintCompletions.first)(9)
        XCTAssertEqual(harness.ready.map(\.surfaceID), [.live])
    }

    func testMoshOverlayHistoryJoinsLivePainterHandoff() async throws {
        let harness = MoshRepaintFenceHarness()
        let overlay = SurfaceId("overlay:%22")

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        harness.stageHistory(surfaceID: overlay, owner: harness.ownerB, text: "OVERLAY_HISTORY")

        XCTAssertEqual(harness.repaintCompletions.count, 1)
        try XCTUnwrap(harness.repaintCompletions.first)(11)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 11, repaintRequestID: 1))
        XCTAssertEqual(harness.ready.map(\.surfaceID), [overlay])
        XCTAssertEqual(harness.ready.first?.history.owner, harness.terminalOwnerB)
    }

    func testMoshJoinedHistoryFenceSurvivesNoOutputHandoffRetry() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "RETRIED_HISTORY")
        try XCTUnwrap(harness.repaintCompletions.first)(nil)

        XCTAssertTrue(harness.ready.isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        await waitForRepaintCount(2, in: harness)
        XCTAssertEqual(harness.repaintCompletions.count, 2)

        try XCTUnwrap(harness.repaintCompletions.last)(12)
        XCTAssertTrue(harness.deliver("RETRY_FRAME", deliveryID: 12, repaintRequestID: 2))
        XCTAssertEqual(harness.ready.map(\.surfaceID), [.live])
    }

    func testMoshGenericRepaintCoalescesIntoInFlightPainterHandoff() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        harness.controller.requestTransportFullFrame?()
        XCTAssertEqual(harness.repaintCompletions.count, 1)

        try XCTUnwrap(harness.repaintCompletions.first)(13)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 13, repaintRequestID: 1))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
    }

    func testMoshHistoryAfterSettledHandoffUsesNewRepaint() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))

        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "NEW_HISTORY")
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        XCTAssertTrue(harness.ready.isEmpty)
        try XCTUnwrap(harness.repaintCompletions.last)(2)
        XCTAssertTrue(harness.deliver("NEW_FRAME", deliveryID: 2, repaintRequestID: 2))
        XCTAssertEqual(harness.ready.map(\.surfaceID), [.live])
    }

    func testMoshOwnerIdentityChangeUsesNaturalOutputAsCausalRepaintBarrier() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        XCTAssertEqual(harness.repaintCompletions.count, 1)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        harness.controller.requestTransportFullFrame?()
        XCTAssertFalse(harness.liveBox.painterFeedsAdmitted)
        await Task.yield()
        XCTAssertEqual(
            harness.repaintCompletions.count,
            1,
            "a real window/pane switch must wait for post-bind Mosh output"
        )

        XCTAssertFalse(harness.deliver("OLD_QUEUED_DIFF", deliveryID: 10, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        XCTAssertFalse(harness.liveText.contains("OLD_QUEUED_DIFF"))

        try XCTUnwrap(harness.repaintCompletions.last)(11)
        XCTAssertTrue(harness.deliver("OWNER_B_FRAME", deliveryID: 11, repaintRequestID: 2))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.liveText.contains("OWNER_B_FRAME"))
        XCTAssertTrue(harness.deliver("OWNER_B_DIFF", deliveryID: 12, repaintRequestID: nil))
        XCTAssertTrue(harness.liveText.contains("OWNER_B_DIFF"))
    }

    func testMoshFenceFreePainterHandoffTransfersAcrossSamePaneEpochBind() async throws {
        let harness = MoshRepaintFenceHarness()
        let ownerBNextEpoch = RenderOwner(
            windowID: WindowId(2),
            paneID: PaneId(22),
            epoch: 3
        )
        let terminalOwnerBNextEpoch = TerminalRenderOwner(
            windowId: WindowId(2),
            paneId: PaneId(22),
            epoch: 3
        )

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        XCTAssertFalse(harness.deliver("P2B_CAUSAL_BOUNDARY", deliveryID: 2, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        let retirementsBeforeEpochTransfer = harness.retiredThroughRequestIDs

        // A layout-change can advance the owner epoch after the only natural
        // P2b boundary has already been consumed but before its forced frame
        // arrives. The exact in-flight request must follow the same pane into
        // the new epoch instead of being cancelled and re-requested.
        harness.controller.renderBindSurface?(.live, ownerBNextEpoch)
        XCTAssertEqual(harness.liveBox.boundOwner, terminalOwnerBNextEpoch)
        XCTAssertEqual(harness.retiredThroughRequestIDs, retirementsBeforeEpochTransfer)
        XCTAssertFalse(harness.canceledRepaintRequestIDs.contains(2))
        XCTAssertFalse(harness.deliver("UNTAGGED_DURING_TRANSFER", deliveryID: 3, repaintRequestID: nil))

        try XCTUnwrap(harness.repaintCompletions[1])(4)
        XCTAssertTrue(harness.deliver("P2B_TRANSFERRED_FRAME", deliveryID: 4, repaintRequestID: 2))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.liveText.contains("P2B_TRANSFERRED_FRAME"))
        XCTAssertFalse(harness.adapter.acceptsTransportOutput(repaintRequestID: 1))
    }

    func testMoshOverlayBindPreservesTransferredLivePainterHandoff() async throws {
        let harness = MoshRepaintFenceHarness()
        let overlay = SurfaceId("overlay:%22")
        let ownerBNextEpoch = RenderOwner(
            windowID: WindowId(2),
            paneID: PaneId(22),
            epoch: 3
        )
        let overlayOwnerBNextEpoch = RenderOwner(
            windowID: WindowId(2),
            paneID: PaneId(22),
            epoch: 4
        )

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))
        harness.controller.renderBindSurface?(overlay, harness.ownerA)

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        XCTAssertFalse(harness.deliver("OWNER_B_BOUNDARY", deliveryID: 2, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        harness.controller.renderBindSurface?(.live, ownerBNextEpoch)
        let retirementsBeforeOverlayBind = harness.retiredThroughRequestIDs

        // iPad declarations bind the live painter first and its detached
        // history overlay second. The latter is a different physical surface,
        // but it must not globally retire the same pane's transferred live
        // full-frame request.
        harness.controller.renderBindSurface?(overlay, overlayOwnerBNextEpoch)
        XCTAssertEqual(harness.retiredThroughRequestIDs, retirementsBeforeOverlayBind)
        XCTAssertFalse(harness.canceledRepaintRequestIDs.contains(2))

        try XCTUnwrap(harness.repaintCompletions[1])(3)
        XCTAssertTrue(harness.deliver("OWNER_B_FRAME", deliveryID: 3, repaintRequestID: 2))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.liveText.contains("OWNER_B_FRAME"))
    }

    func testMoshRetiringJoinedOverlayFenceDoesNotCancelLivePainterHandoff() async throws {
        let harness = MoshRepaintFenceHarness()
        let overlay = SurfaceId("overlay:%22")
        let overlayOwnerBNextEpoch = RenderOwner(
            windowID: WindowId(2),
            paneID: PaneId(22),
            epoch: 3
        )

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))
        harness.controller.renderBindSurface?(overlay, harness.ownerA)

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        XCTAssertFalse(harness.deliver("OWNER_B_BOUNDARY", deliveryID: 2, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        harness.stageHistory(surfaceID: overlay, owner: harness.ownerB, text: "JOINED_OVERLAY")

        // A declaration can advance the detached reader's epoch while its
        // history fence shares the live painter handoff. Dropping that stale
        // reader must not cancel the request whose frame still opens `.live`.
        harness.controller.renderBindSurface?(overlay, overlayOwnerBNextEpoch)
        XCTAssertFalse(harness.canceledRepaintRequestIDs.contains(2))

        try XCTUnwrap(harness.repaintCompletions[1])(3)
        XCTAssertTrue(harness.deliver("OWNER_B_FRAME", deliveryID: 3, repaintRequestID: 2))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.liveText.contains("OWNER_B_FRAME"))
        XCTAssertTrue(harness.ready.isEmpty)
    }

    func testMoshOverlayBindPreservesOwnedLiveRepaint() async throws {
        let harness = MoshRepaintFenceHarness()
        let overlay = SurfaceId("overlay:%11")
        let overlayOwnerANextEpoch = RenderOwner(
            windowID: WindowId(1),
            paneID: PaneId(11),
            epoch: 2
        )
        var scheduledRequestID: UInt64?
        var completedDeliveryID: UInt64?

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))
        harness.controller.renderBindSurface?(overlay, harness.ownerA)

        harness.adapter.requestOwnedTransportFullFrame(
            onScheduled: { scheduledRequestID = $0 },
            completion: { completedDeliveryID = $0 }
        )
        XCTAssertEqual(scheduledRequestID, 2)
        let retirementsBeforeOverlayBind = harness.retiredThroughRequestIDs

        harness.controller.renderBindSurface?(overlay, overlayOwnerANextEpoch)
        XCTAssertEqual(harness.retiredThroughRequestIDs, retirementsBeforeOverlayBind)
        XCTAssertFalse(harness.canceledRepaintRequestIDs.contains(2))

        try XCTUnwrap(harness.repaintCompletions[1])(2)
        XCTAssertTrue(harness.deliver("OWNED_LIVE_FRAME", deliveryID: 2, repaintRequestID: 2))
        XCTAssertEqual(completedDeliveryID, 2)
        XCTAssertTrue(harness.liveText.contains("OWNED_LIVE_FRAME"))
    }

    func testMoshUnfocusedPaneReaderBindPreservesOwnedLiveRepaint() async throws {
        let harness = MoshRepaintFenceHarness()
        var scheduledRequestID: UInt64?
        var completedDeliveryID: UInt64?

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))
        harness.adapter.requestOwnedTransportFullFrame(
            onScheduled: { scheduledRequestID = $0 },
            completion: { completedDeliveryID = $0 }
        )
        XCTAssertEqual(scheduledRequestID, 2)
        let retirementsBeforeReaderBind = harness.retiredThroughRequestIDs

        // A split reads an unfocused pane of the painter's window: that
        // reader's bind must not cancel the focused painter's frame.
        harness.controller.renderBindSurface?(
            SurfaceId("overlay:%12"),
            RenderOwner(windowID: WindowId(1), paneID: PaneId(12), epoch: 1)
        )
        XCTAssertEqual(harness.retiredThroughRequestIDs, retirementsBeforeReaderBind)
        XCTAssertFalse(harness.canceledRepaintRequestIDs.contains(2))

        try XCTUnwrap(harness.repaintCompletions[1])(2)
        XCTAssertTrue(harness.deliver("OWNED_LIVE_FRAME", deliveryID: 2, repaintRequestID: 2))
        XCTAssertEqual(completedDeliveryID, 2)

        // A reader of another window still retires the painter's requests.
        harness.controller.renderBindSurface?(SurfaceId("overlay:%22"), harness.ownerB)
        XCTAssertGreaterThan(harness.retiredThroughRequestIDs.count, retirementsBeforeReaderBind.count)
    }

    /// A grid-authority take-back forces tmux geometry, and tmux echoes
    /// `%layout-change` for that force while the claim's own frame is still
    /// outstanding. The side-channel ledger rebinds the live surface under a
    /// fresh epoch for the echo. Retiring the claim's request there reported a
    /// failed repaint, which aborted every mosh+tmux take-back and left the
    /// "continued elsewhere" veil up. Only the epoch moved, so the request is
    /// re-reserved against the new owner behind the replacement handoff.
    func testMoshAuthorityOwnedRepaintSurvivesLiveEpochRebind() async throws {
        let harness = MoshRepaintFenceHarness()
        let ownerANextEpoch = RenderOwner(
            windowID: WindowId(1),
            paneID: PaneId(11),
            epoch: 2
        )
        var scheduledRequestIDs: [UInt64] = []
        var completions: [UInt64?] = []

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("A_FRAME", deliveryID: 1, repaintRequestID: 1))

        harness.adapter.requestOwnedTransportFullFrame(
            retargetsAcrossSurfaceRebind: true,
            onScheduled: { scheduledRequestIDs.append($0) },
            completion: { completions.append($0) }
        )
        XCTAssertEqual(scheduledRequestIDs, [2])

        // The claim's own geometry force re-lays the tmux window out; the
        // side-channel ledger rebinds the same pane under a new epoch.
        harness.controller.renderBindSurface?(.live, ownerANextEpoch)
        XCTAssertTrue(completions.isEmpty)

        // The replacement painter handoff paints first; the claim's frame is
        // re-reserved behind it under a fresh request.
        await waitForRepaintCount(3, in: harness)
        XCTAssertEqual(harness.repaintCompletions.count, 3)
        try XCTUnwrap(harness.repaintCompletions[safe: 2])(2)
        XCTAssertTrue(harness.deliver("E2_FRAME", deliveryID: 2, repaintRequestID: 3))

        // Retiring the claim's frame here instead of re-reserving it is the
        // mosh+tmux take-back defect: no fourth request is ever made.
        XCTAssertEqual(scheduledRequestIDs, [2, 4])
        XCTAssertEqual(harness.repaintCompletions.count, 4)
        try XCTUnwrap(harness.repaintCompletions[safe: 3])(3)
        XCTAssertTrue(harness.deliver("AUTH_FRAME", deliveryID: 3, repaintRequestID: 4))
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first ?? nil, 3)
        XCTAssertTrue(harness.liveText.contains("AUTH_FRAME"))
    }

    /// A real window/pane switch is not the claim's own geometry echo: the
    /// frame it asked for can never describe the surface now on screen, so it
    /// must still report a failed repaint.
    func testMoshAuthorityOwnedRepaintStillFailsOnPaneSwitch() async throws {
        let harness = MoshRepaintFenceHarness()
        var completions: [UInt64?] = []

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))

        harness.adapter.requestOwnedTransportFullFrame(
            retargetsAcrossSurfaceRebind: true,
            onScheduled: { _ in },
            completion: { completions.append($0) }
        )

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(completions.first ?? nil)
    }

    /// The retarget rule is scoped to a *surface* rebind, not a transport one.
    /// `deactivate()` (transport lost / view gone) and `reset()` (presentation
    /// reset) must still retire a retargetable claim frame: the mosh framebuffer
    /// behind it is gone, so re-reserving would leave the claim waiting on a
    /// frame that can never arrive. iOS has no transport generation on
    /// `TerminalRenderOwner` — these two boundaries are what stand in for it,
    /// which is why they are pinned here.
    func testMoshAuthorityOwnedRepaintIsRetiredByTransportTeardown() async throws {
        for teardown in ["deactivate", "reset"] {
            let harness = MoshRepaintFenceHarness()
            var completions: [UInt64?] = []

            harness.controller.renderBindSurface?(.live, harness.ownerA)
            await waitForRepaintCount(1, in: harness)
            try XCTUnwrap(harness.repaintCompletions.first)(1)
            XCTAssertTrue(harness.deliver("A_FRAME", deliveryID: 1, repaintRequestID: 1))

            harness.adapter.requestOwnedTransportFullFrame(
                retargetsAcrossSurfaceRebind: true,
                onScheduled: { _ in },
                completion: { completions.append($0) }
            )
            XCTAssertTrue(completions.isEmpty, "\(teardown): not resolved before teardown")

            if teardown == "deactivate" {
                harness.adapter.deactivate()
            } else {
                harness.adapter.reset()
            }

            XCTAssertEqual(completions.count, 1, "\(teardown): exactly one terminal outcome")
            XCTAssertNil(completions.first ?? nil, "\(teardown): must fail, not re-reserve")
        }
    }

    /// Requests that the next notification simply re-issues stay retirable, so
    /// a rebind must not queue a redundant frame behind the replacement
    /// handoff.
    func testMoshUnflaggedOwnedRepaintStillRetiresOnEpochRebind() async throws {
        let harness = MoshRepaintFenceHarness()
        let ownerANextEpoch = RenderOwner(
            windowID: WindowId(1),
            paneID: PaneId(11),
            epoch: 2
        )
        var completions: [UInt64?] = []

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))

        harness.adapter.requestOwnedTransportFullFrame(
            onScheduled: { _ in },
            completion: { completions.append($0) }
        )

        harness.controller.renderBindSurface?(.live, ownerANextEpoch)
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(completions.first ?? nil)
    }

    func testMoshFenceFreePainterHandoffTransfersBeforeNaturalBoundary() throws {
        let harness = MoshRepaintFenceHarness()
        let ownerBNextEpoch = RenderOwner(
            windowID: WindowId(2),
            paneID: PaneId(22),
            epoch: 3
        )
        let terminalOwnerBNextEpoch = TerminalRenderOwner(
            windowId: WindowId(2),
            paneId: PaneId(22),
            epoch: 3
        )
        harness.liveBox.bind(
            owner: harness.terminalOwnerA,
            restoringScrollbackLimit: 2_000
        )

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        harness.controller.renderBindSurface?(.live, ownerBNextEpoch)
        XCTAssertEqual(harness.liveBox.boundOwner, terminalOwnerBNextEpoch)
        XCTAssertTrue(harness.repaintCompletions.isEmpty)

        XCTAssertFalse(harness.deliver("EPOCH_THREE_BOUNDARY", deliveryID: 1, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 1)
        try XCTUnwrap(harness.repaintCompletions.first)(2)
        XCTAssertTrue(harness.deliver("EPOCH_THREE_FRAME", deliveryID: 2, repaintRequestID: 1))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.liveText.contains("EPOCH_THREE_FRAME"))
    }

    func testMoshPainterHandoffTransfersBeforeAsyncScheduleCallback() throws {
        let harness = MoshRepaintFenceHarness(defersRepaintScheduling: true)
        let ownerBNextEpoch = RenderOwner(
            windowID: WindowId(2),
            paneID: PaneId(22),
            epoch: 3
        )
        let terminalOwnerBNextEpoch = TerminalRenderOwner(
            windowId: WindowId(2),
            paneId: PaneId(22),
            epoch: 3
        )
        harness.liveBox.bind(
            owner: harness.terminalOwnerA,
            restoringScrollbackLimit: 2_000
        )

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        XCTAssertFalse(harness.deliver("P2B_CAUSAL_BOUNDARY", deliveryID: 1, repaintRequestID: nil))
        XCTAssertEqual(harness.pendingRepaintScheduleCount, 1)
        XCTAssertTrue(harness.repaintCompletions.isEmpty)

        harness.controller.renderBindSurface?(.live, ownerBNextEpoch)
        XCTAssertEqual(harness.liveBox.boundOwner, terminalOwnerBNextEpoch)
        XCTAssertFalse(harness.canceledRepaintRequestIDs.contains(1))

        try harness.scheduleNextRepaint()
        XCTAssertEqual(harness.repaintCompletions.count, 1)
        try XCTUnwrap(harness.repaintCompletions.first)(2)
        XCTAssertTrue(harness.deliver("ASYNC_TRANSFERRED_FRAME", deliveryID: 2, repaintRequestID: 1))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.liveText.contains("ASYNC_TRANSFERRED_FRAME"))
    }

    func testMoshPainterHandoffDoesNotTransferAfterFrameDeliveryStarts() async throws {
        let harness = MoshRepaintFenceHarness()
        let ownerBNextEpoch = RenderOwner(
            windowID: WindowId(2),
            paneID: PaneId(22),
            epoch: 3
        )
        harness.liveBox.bind(
            owner: harness.terminalOwnerA,
            restoringScrollbackLimit: 2_000
        )

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        XCTAssertFalse(harness.deliver("P2B_CAUSAL_BOUNDARY", deliveryID: 1, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 1)
        try XCTUnwrap(harness.repaintCompletions.first)(2)

        let lease = harness.adapter.makeTransportOutputLease(
            deliveryID: 2,
            repaintRequestID: 1
        )
        let partialFrame = Array(
            ("OLD_PARTIAL_FRAME\r\n" + String(repeating: "X", count: 2_048)).utf8
        )
        var admissionChecks = 0
        let renderedFully = await harness.liveBox.feedTerminalOutputCooperatively(
            partialFrame[...],
            context: .moshLive(originalByteCount: partialFrame.count),
            shellIntegration: SwipePadShellIntegrationTracker(),
            owner: lease.owner,
            acceptsNextSlice: {
                admissionChecks += 1
                if admissionChecks == 2 {
                    harness.controller.renderBindSurface?(.live, ownerBNextEpoch)
                }
                return lease.acceptsNextSlice()
            }
        )
        XCTAssertFalse(renderedFully)
        XCTAssertEqual(admissionChecks, 2)
        harness.adapter.noteTransportOutputResult(
            deliveryID: 2,
            repaintRequestID: 1,
            renderedFully: false
        )
        XCTAssertTrue(harness.canceledRepaintRequestIDs.contains(1))
        await waitForRepaintCount(2, in: harness)

        try XCTUnwrap(harness.repaintCompletions[1])(3)
        XCTAssertTrue(harness.deliver(
            "\u{1b}[2J\u{1b}[HEPOCH_THREE_COMPLETE_FRAME",
            deliveryID: 3,
            repaintRequestID: 2
        ))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertFalse(harness.liveText.contains("OLD_PARTIAL_FRAME"))
        XCTAssertTrue(harness.liveText.contains("EPOCH_THREE_COMPLETE_FRAME"))
    }

    func testMoshHistoryFencePreventsSamePaneEpochHandoffTransfer() async throws {
        let harness = MoshRepaintFenceHarness()
        let ownerBNextEpoch = RenderOwner(
            windowID: WindowId(2),
            paneID: PaneId(22),
            epoch: 3
        )

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        XCTAssertFalse(harness.deliver("P2B_CAUSAL_BOUNDARY", deliveryID: 2, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        harness.stageHistory(surfaceID: .live, owner: harness.ownerB, text: "EPOCH_TWO_HISTORY")

        harness.controller.renderBindSurface?(.live, ownerBNextEpoch)
        XCTAssertTrue(harness.canceledRepaintRequestIDs.contains(2))
        XCTAssertFalse(harness.deliver("RETIRED_EPOCH_TWO_FRAME", deliveryID: 3, repaintRequestID: 2))
        await waitForRepaintCount(3, in: harness)

        try XCTUnwrap(harness.repaintCompletions[2])(4)
        XCTAssertTrue(harness.deliver("EPOCH_THREE_FRAME", deliveryID: 4, repaintRequestID: 3))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.ready.isEmpty)
    }

    func testMoshOwnerIdentityChangeIgnoresNaturalOutputProducedBeforeBind() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))

        // Delivery 20 was allocated by the producer but is still waiting in
        // the session event queue when the side-channel bind runs.
        harness.producedDeliveryHighWater = 20
        harness.controller.renderBindSurface?(.live, harness.ownerB)
        XCTAssertFalse(harness.deliver("PRE_BIND_QUEUED", deliveryID: 20, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 1)

        XCTAssertFalse(harness.deliver("POST_BIND_BOUNDARY", deliveryID: 21, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        try XCTUnwrap(harness.repaintCompletions.last)(22)
        XCTAssertTrue(harness.deliver("OWNER_B_FRAME", deliveryID: 22, repaintRequestID: 2))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertFalse(harness.liveText.contains("PRE_BIND_QUEUED"))
    }

    func testMoshOwnerChangeRetiresPreviousOwnersScrollIntent() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))
        harness.adapter.noteHistoryRequest(
            surfaceID: .live,
            pointsY: 37,
            isInertial: false
        )

        harness.controller.renderBindSurface?(.live, harness.ownerB)
        harness.stageHistory(surfaceID: .live, owner: harness.ownerB, text: "OWNER_B_HISTORY")
        XCTAssertFalse(harness.deliver("OWNER_B_BOUNDARY", deliveryID: 2, repaintRequestID: nil))
        await waitForRepaintCount(2, in: harness)
        try XCTUnwrap(harness.repaintCompletions[1])(3)
        XCTAssertTrue(harness.deliver("OWNER_B_FRAME", deliveryID: 3, repaintRequestID: 2))

        let history = try XCTUnwrap(harness.ready.last?.history)
        XCTAssertEqual(history.owner, harness.terminalOwnerB)
        XCTAssertEqual(history.scrollPoints, 0)
    }

    func testMoshSamePaneEpochRetryPreservesScrollIntent() async throws {
        let harness = MoshRepaintFenceHarness()
        let ownerANextEpoch = RenderOwner(
            windowID: WindowId(1),
            paneID: PaneId(11),
            epoch: 2
        )

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))
        harness.adapter.noteHistoryRequest(
            surfaceID: .live,
            pointsY: 37,
            isInertial: false
        )

        harness.controller.renderBindSurface?(.live, ownerANextEpoch)
        harness.stageHistory(
            surfaceID: .live,
            owner: ownerANextEpoch,
            text: "RETRIED_OWNER_A_HISTORY"
        )
        await waitForRepaintCount(2, in: harness)
        try XCTUnwrap(harness.repaintCompletions[1])(2)
        XCTAssertTrue(harness.deliver("OWNER_A_RETRY_FRAME", deliveryID: 2, repaintRequestID: 2))

        XCTAssertEqual(try XCTUnwrap(harness.ready.last).history.scrollPoints, 37)
    }

    func testMoshFirstLiveBindKeepsTheRequestsScrollIntent() async throws {
        let harness = MoshRepaintFenceHarness()
        // A fresh session's first request, its gesture already over, comes
        // before the live surface has ever had an owner.
        harness.adapter.noteHistoryRequest(surfaceID: .live, pointsY: 37, isInertial: false)

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "FIRST_HISTORY")
        await waitForRepaintCount(2, in: harness)
        try XCTUnwrap(harness.repaintCompletions[1])(2)
        XCTAssertTrue(harness.deliver("HISTORY_FRAME", deliveryID: 2, repaintRequestID: 2))

        XCTAssertEqual(try XCTUnwrap(harness.ready.last).history.scrollPoints, 37)
    }

    func testMoshSamePaneEpochRetryPreservesScrollIntentAlreadyAttachedToFence() async throws {
        let harness = MoshRepaintFenceHarness()
        let ownerANextEpoch = RenderOwner(
            windowID: WindowId(1),
            paneID: PaneId(11),
            epoch: 2
        )

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))
        harness.adapter.noteHistoryRequest(
            surfaceID: .live,
            pointsY: 37,
            isInertial: false
        )
        harness.stageHistory(
            surfaceID: .live,
            owner: harness.ownerA,
            text: "STALE_GEOMETRY_HISTORY"
        )
        XCTAssertEqual(harness.repaintCompletions.count, 2)

        harness.adapter.noteHistoryRequest(surfaceID: .live, pointsY: -7, isInertial: false)

        // `historyReady` already moved the gesture points into the old
        // repaint fence. A layout bind must recover those points before it
        // retires that fence, so the reducer's fresh capture can preserve the
        // user's exact scroll placement.
        harness.controller.renderBindSurface?(.live, ownerANextEpoch)
        XCTAssertTrue(harness.canceledRepaintRequestIDs.contains(2))
        await waitForRepaintCount(3, in: harness)
        harness.stageHistory(
            surfaceID: .live,
            owner: ownerANextEpoch,
            text: "RETRIED_GEOMETRY_HISTORY"
        )
        XCTAssertEqual(harness.repaintCompletions.count, 3)

        try XCTUnwrap(harness.repaintCompletions[2])(3)
        XCTAssertTrue(harness.deliver("OWNER_A_RETRY_FRAME", deliveryID: 3, repaintRequestID: 3))
        let history = try XCTUnwrap(harness.ready.last?.history)
        XCTAssertEqual(history.owner.epoch, 2)
        XCTAssertEqual(history.scrollPoints, 30)
    }

    func testMoshHistoryPlacementConsumesLateReverseIntentExactlyOnce() async throws {
        let harness = MoshRepaintFenceHarness()
        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("INITIAL_FRAME", deliveryID: 1, repaintRequestID: 1))
        harness.adapter.noteHistoryRequest(surfaceID: .live, pointsY: 80, isInertial: false)
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "HISTORY")
        harness.adapter.noteHistoryRequest(surfaceID: .live, pointsY: -30, isInertial: false)
        try XCTUnwrap(harness.repaintCompletions[1])(2)
        XCTAssertTrue(harness.deliver("HISTORY_FRAME", deliveryID: 2, repaintRequestID: 2))
        let history = try XCTUnwrap(harness.ready.last?.history)
        XCTAssertEqual(history.scrollPoints + harness.adapter.takePendingScrollPoints(surfaceID: .live), 50)
        XCTAssertEqual(harness.adapter.takePendingScrollPoints(surfaceID: .live), 0)
    }

    func testMoshOverlayOwnerChangeRetiresPreviousOwnersScrollIntent() throws {
        let harness = MoshRepaintFenceHarness()
        let overlay = SurfaceId("overlay:%22")

        harness.controller.renderBindSurface?(overlay, harness.ownerA)
        harness.adapter.noteHistoryRequest(
            surfaceID: overlay,
            pointsY: 43,
            isInertial: false
        )

        harness.controller.renderBindSurface?(overlay, harness.ownerB)
        harness.stageHistory(
            surfaceID: overlay,
            owner: harness.ownerB,
            text: "OWNER_B_OVERLAY_HISTORY"
        )
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver(
            "PAINTER_FRAME",
            deliveryID: 1,
            repaintRequestID: 1
        ))

        let history = try XCTUnwrap(harness.ready.last?.history)
        XCTAssertEqual(history.owner, harness.terminalOwnerB)
        XCTAssertEqual(history.scrollPoints, 0)
    }

    func testMoshRepeatedResetCompactsRetiredRequestTombstones() async {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        for expectedRepaintCount in 2...24 {
            harness.adapter.reset()
            await waitForRepaintCount(expectedRepaintCount, in: harness)
            XCTAssertEqual(
                harness.adapter.retiredTransportRequestTombstoneCountForTesting,
                0
            )
        }
        harness.adapter.deactivate()
        XCTAssertEqual(
            harness.adapter.retiredTransportRequestTombstoneCountForTesting,
            0
        )
    }

    func testMoshReturnToTailKeepsPainterClosedAndCoalescesLedgerRepaint() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))

        let tailOwner = RenderOwner(windowID: WindowId(1), paneID: PaneId(11), epoch: 3)
        harness.controller.renderBindSurface?(.live, tailOwner)
        harness.controller.requestTransportFullFrame?()
        XCTAssertFalse(harness.liveBox.painterFeedsAdmitted)
        XCTAssertEqual(harness.repaintCompletions.count, 1)

        await waitForRepaintCount(2, in: harness)

        XCTAssertEqual(
            harness.repaintCompletions.count,
            2,
            "tail return and its ledger repaint effect must share one forced frame"
        )
        try XCTUnwrap(harness.repaintCompletions.last)(2)
        XCTAssertTrue(harness.deliver("TAIL_FRAME", deliveryID: 2, repaintRequestID: 2))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
    }

    func testMoshSameOwnerReplacementIgnoresStaleForcedFrameCompletion() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        harness.adapter.reset()
        await waitForRepaintCount(2, in: harness)

        harness.repaintCompletions[0](99)
        XCTAssertFalse(harness.liveBox.painterFeedsAdmitted)
        harness.repaintCompletions[1](2)
        XCTAssertTrue(harness.deliver("REPLACEMENT_FRAME", deliveryID: 2, repaintRequestID: 2))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.liveText.contains("REPLACEMENT_FRAME"))
    }

    func testMoshDeactivateCancelsRetryAndReopensPainter() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        harness.adapter.deactivate()
        harness.repaintCompletions[0](nil)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(harness.repaintCompletions.count, 1)
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.deliver("NATURAL_AFTER_LOSS", deliveryID: 2, repaintRequestID: nil))
    }

    func testMoshQuiescentHandoffRetriesAfterNoOutput() async throws {
        let harness = MoshRepaintFenceHarness()

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        XCTAssertFalse(harness.liveBox.painterFeedsAdmitted)

        try XCTUnwrap(harness.repaintCompletions.first)(nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        await waitForRepaintCount(2, in: harness)
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        XCTAssertFalse(harness.liveBox.painterFeedsAdmitted)

        try XCTUnwrap(harness.repaintCompletions.last)(2)
        XCTAssertTrue(harness.deliver("RETRY_FRAME", deliveryID: 2, repaintRequestID: 2))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
    }

    func testMoshOwnedAuthorityRepaintQueuesBehindHandoffAndUsesExactOwner() async throws {
        let harness = MoshRepaintFenceHarness()
        var scheduled: [UInt64] = []
        var completions: [UInt64?] = []

        harness.controller.renderBindSurface?(.live, harness.ownerA)
        harness.adapter.requestOwnedTransportFullFrame(
            onScheduled: { scheduled.append($0) },
            completion: { completions.append($0) }
        )
        XCTAssertTrue(scheduled.isEmpty)

        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("HANDOFF_FRAME", deliveryID: 1, repaintRequestID: 1))
        XCTAssertEqual(scheduled, [2])
        XCTAssertEqual(harness.repaintCompletions.count, 2)

        // Exercise receipt-before-driver-completion ordering. The authority
        // frame is admitted as owner A even though it was requested outside
        // the ledger's history-fence path.
        let lease = harness.adapter.makeTransportOutputLease(
            deliveryID: 2,
            repaintRequestID: 2
        )
        XCTAssertEqual(lease.owner, harness.terminalOwnerA)
        XCTAssertTrue(harness.deliver("AUTHORITY_FRAME", deliveryID: 2, repaintRequestID: 2))
        XCTAssertTrue(completions.isEmpty)
        try XCTUnwrap(harness.repaintCompletions.last)(2)
        XCTAssertEqual(completions, [2])
    }

    func testMoshHistoryRequiresItsExactFullyRenderedReceipt() async throws {
        let harness = MoshRepaintFenceHarness()
        harness.stageHistory(surfaceID: .live, owner: harness.ownerA, text: "EXACT_HISTORY")
        harness.repaintCompletions[0](20)

        XCTAssertFalse(harness.deliver(
            "REJECTED_FRAME",
            deliveryID: 20,
            repaintRequestID: 1,
            forceRenderedResult: false
        ))
        XCTAssertTrue(harness.ready.isEmpty)

        // A larger unrelated delivery cannot satisfy or leapfrog request 1.
        XCTAssertTrue(harness.deliver("UNRELATED", deliveryID: 99, repaintRequestID: 999))
        XCTAssertTrue(harness.ready.isEmpty)

        try await Task.sleep(nanoseconds: 75_000_000)
        await waitForRepaintCount(2, in: harness)
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        harness.repaintCompletions[1](21)
        XCTAssertTrue(harness.deliver(
            "EXACT_RETRY_FRAME",
            deliveryID: 21,
            repaintRequestID: 2
        ))
        XCTAssertEqual(harness.ready.map(\.surfaceID), [.live])
    }

    /// `TerminalBox.bind` clears scrollback, and SwiftTerm reports `scrolled`
    /// synchronously from that clear. On mosh+tmux the live scroll handler
    /// turns a revealed-history reader landing on the tail into a
    /// returned-to-tail fact, and the ledger answers with a fresh-epoch bind
    /// while the outer bind is still on the stack. Before the fix the outer
    /// frame then overwrote the nested handoff with its own stale owner: the
    /// box stayed bound to the newer epoch, the handoff named the older one,
    /// every retry failed its owner guard, and the painter never reopened.
    func testMoshNestedBindDuringScrollbackClearKeepsPainterStateOnFinalOwner() async throws {
        let harness = MoshRepaintFenceHarness()
        harness.controller.renderBindSurface?(.live, harness.ownerA)
        await waitForRepaintCount(1, in: harness)
        try XCTUnwrap(harness.repaintCompletions.first)(1)
        XCTAssertTrue(harness.deliver("OWNER_A_FRAME", deliveryID: 1, repaintRequestID: 1))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)

        let ownerAEpoch2 = RenderOwner(windowID: WindowId(1), paneID: PaneId(11), epoch: 2)
        let ownerAEpoch3 = RenderOwner(windowID: WindowId(1), paneID: PaneId(11), epoch: 3)
        let terminalOwnerAEpoch3 = TerminalRenderOwner(
            windowId: WindowId(1), paneId: PaneId(11), epoch: 3
        )

        let delegate = ReentrantBindTerminalViewDelegate()
        harness.liveView.terminalDelegate = delegate
        var nestedBinds = 0
        delegate.onScrolled = { [weak harness] in
            guard let harness,
                  nestedBinds == 0,
                  harness.liveBox.boundOwner?.epoch == 2
            else { return }
            nestedBinds += 1
            harness.controller.renderBindSurface?(.live, ownerAEpoch3)
        }

        harness.controller.renderBindSurface?(.live, ownerAEpoch2)
        XCTAssertEqual(nestedBinds, 1)
        XCTAssertEqual(harness.liveBox.boundOwner, terminalOwnerAEpoch3)
        XCTAssertFalse(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(
            harness.adapter.painterStateForTesting.contains("bind-superseded @1/%11/e2 by @1/%11/e3"),
            harness.adapter.painterStateForTesting
        )

        // Same pane identity: the nested owner's handoff schedules its own
        // forced frame, and that frame is what reopens the painter.
        await waitForRepaintCount(2, in: harness)
        XCTAssertEqual(harness.repaintCompletions.count, 2)
        try XCTUnwrap(harness.repaintCompletions.last)(5)
        XCTAssertTrue(harness.deliver("OWNER_A_E3_FRAME\r\n", deliveryID: 5, repaintRequestID: 2))
        XCTAssertTrue(harness.liveBox.painterFeedsAdmitted)
        XCTAssertTrue(harness.deliver("NATURAL_E3\r\n", deliveryID: 6, repaintRequestID: nil))
        XCTAssertTrue(harness.liveText.contains("OWNER_A_E3_FRAME"))
        XCTAssertTrue(harness.liveText.contains("NATURAL_E3"))
    }

    func testMoshRebindRetiresDeferredHandoffAndRequiresNewBoundary() {
        let harness = MoshRepaintFenceHarness()
        harness.controller.renderBindSurface?(.live, harness.ownerA)
        harness.controller.requestTransportFullFrame?()
        harness.controller.renderBindSurface?(.live, harness.ownerB)

        XCTAssertEqual(harness.repaintCompletions.count, 0)
        XCTAssertFalse(harness.deliver("OWNER_B_BOUNDARY", deliveryID: 30, repaintRequestID: nil))
        XCTAssertEqual(harness.repaintCompletions.count, 1)
        harness.repaintCompletions[0](31)
        XCTAssertTrue(harness.deliver("OWNER_B_FRAME", deliveryID: 31, repaintRequestID: 1))
        XCTAssertEqual(harness.liveBox.boundOwner, harness.terminalOwnerB)
        XCTAssertFalse(harness.liveText.contains("OWNER_B_BOUNDARY"))
        XCTAssertTrue(harness.liveText.contains("OWNER_B_FRAME"))
    }

    private func makeBox() -> (TerminalBox, Terminal) {
        let view = TerminalView(frame: .zero)
        view.resize(cols: 40, rows: 4)
        let box = TerminalBox(traceLabel: "ownership-test")
        box.attach(view)
        box.markRenderReady()
        return (box, view.getTerminal())
    }

    private func waitForRepaintCount(
        _ expectedCount: Int,
        in harness: MoshRepaintFenceHarness
    ) async {
        for _ in 0..<100 where harness.repaintCompletions.count < expectedCount {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func fillHistory(
        in box: TerminalBox,
        owner: TerminalRenderOwner,
        rows: Int
    ) {
        for row in 0..<rows {
            box.feed(owner: owner, bytes("ROW_\(row)\r\n"))
        }
    }

    private func visibleTerminalText(_ terminal: Terminal) -> [String] {
        (0..<terminal.rows).map { row in
            terminal.getLine(row: row).map(text(of:)) ?? ""
        }
    }

    private func allTerminalText(_ terminal: Terminal) -> String {
        (0..<512).compactMap { row in
            terminal.getScrollInvariantLine(row: row).map(text(of:))
        }.joined(separator: "\n")
    }

    private func text(of line: BufferLine) -> String {
        String(line.getData().map { $0.getCharacter() })
    }

    private func bytes(_ string: String) -> ArraySlice<UInt8> {
        Array(string.utf8)[...]
    }
}

#if DEBUG
@MainActor
final class LiveScrollInitialRenderProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LiveScrollInitialRenderProbe._testReset()
    }

    override func tearDown() {
        LiveScrollInitialRenderProbe._testReset()
        super.tearDown()
    }

    func testReadinessTracksReadyResetAndReplacementPainterEpoch() {
        let sessionID = UUID()

        LiveScrollInitialRenderProbe._testObserve(sessionID: sessionID, isReady: true)
        XCTAssertTrue(LiveScrollInitialRenderProbe.isReady(for: sessionID))

        LiveScrollInitialRenderProbe._testObserve(sessionID: sessionID, isReady: false)
        XCTAssertFalse(
            LiveScrollInitialRenderProbe.isReady(for: sessionID),
            "a side-channel disconnect must revoke the prior painter epoch's fence"
        )

        LiveScrollInitialRenderProbe._testObserve(sessionID: sessionID, isReady: true)
        XCTAssertTrue(LiveScrollInitialRenderProbe.isReady(for: sessionID))

        LiveScrollInitialRenderProbe.clear(sessionID: sessionID)
        XCTAssertFalse(LiveScrollInitialRenderProbe.isReady(for: sessionID))
    }
}
#endif

/// Minimal SwiftTerm delegate so a test can act inside the synchronous
/// `scrolled` callback that `changeScrollback` issues from `TerminalBox.bind`.
@MainActor
private final class ReentrantBindTerminalViewDelegate: NSObject, TerminalViewDelegate {
    var onScrolled: (() -> Void)?

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) { onScrolled?() }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private extension Array {
    /// Indexing a repaint-completion list that is *supposed* to have grown is
    /// exactly where a regression shows up. Trapping there kills the test
    /// process and reports "Executed 0 tests"; this reports the real failure.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
private final class MoshRepaintFenceHarness {
    typealias RepaintCompletion = @MainActor (UInt64?) -> Void

    private struct DeferredRepaintSchedule {
        let requestID: UInt64
        let onScheduled: @MainActor (UInt64) -> Void
        let completion: RepaintCompletion
    }

    let controller = TmuxController(controlPath: .sideChannel)
    let adapter = MoshRenderLedgerSurfaceAdapter()
    let liveBox = TerminalBox(traceLabel: "mosh-repaint-fence-test")
    let overlayBox = TerminalBox(traceLabel: "mosh-repaint-overlay-fence-test")
    let liveView = TerminalView(frame: .zero)
    let overlayView = TerminalView(frame: .zero)
    let ownerA = RenderOwner(windowID: WindowId(1), paneID: PaneId(11), epoch: 1)
    let ownerB = RenderOwner(windowID: WindowId(2), paneID: PaneId(22), epoch: 2)
    var repaintCompletions: [RepaintCompletion] = []
    var producedDeliveryHighWater: UInt64 = 0
    var canceledRepaintRequestIDs: [UInt64] = []
    var retiredThroughRequestIDs: [UInt64] = []
    var ready: [(surfaceID: SurfaceId, history: MoshLedgerHistory)] = []
    var dropped: [(surfaceID: SurfaceId, reason: String)] = []
    private let defersRepaintScheduling: Bool
    private var nextRepaintRequestID: UInt64 = 0
    private var deferredRepaintSchedules: [DeferredRepaintSchedule] = []

    var pendingRepaintScheduleCount: Int { deferredRepaintSchedules.count }

    var terminalOwnerA: TerminalRenderOwner {
        TerminalRenderOwner(windowId: WindowId(1), paneId: PaneId(11), epoch: 1)
    }

    var terminalOwnerB: TerminalRenderOwner {
        TerminalRenderOwner(windowId: WindowId(2), paneId: PaneId(22), epoch: 2)
    }

    var liveText: String {
        let terminal = liveView.getTerminal()
        return (0..<128).compactMap { row in
            terminal.getScrollInvariantLine(row: row).map { line in
                String(line.getData().map { $0.getCharacter() })
            }
        }.joined(separator: "\n")
    }

    init(
        defersRepaintScheduling: Bool = false,
        receiptTimeoutNanoseconds: UInt64 = 4_000_000_000
    ) {
        self.defersRepaintScheduling = defersRepaintScheduling
        liveView.resize(cols: 40, rows: 8)
        overlayView.resize(cols: 40, rows: 8)
        liveBox.attach(liveView)
        overlayBox.attach(overlayView)
        liveBox.markRenderReady()
        overlayBox.markRenderReady()
        adapter.repaintReceiptTimeoutNanoseconds = receiptTimeoutNanoseconds
        adapter.install(
            on: controller,
            scrollbackLimit: { 2_000 },
            boxForSurface: { [liveBox, overlayBox] surfaceID in
                surfaceID == .live ? liveBox : overlayBox
            },
            fallbackSurfaceState: { _ in nil },
            onHistoryReady: { [weak self] surfaceID, history in
                self?.ready.append((surfaceID, history))
            },
            onHistoryDropped: { [weak self] surfaceID, _, reason in
                self?.dropped.append((surfaceID, reason))
            },
            onRequestTransportFullFrame: { [weak self] onScheduled, completion in
                guard let self else { return }
                self.nextRepaintRequestID += 1
                let requestID = self.nextRepaintRequestID
                if self.defersRepaintScheduling {
                    self.deferredRepaintSchedules.append(DeferredRepaintSchedule(
                        requestID: requestID,
                        onScheduled: onScheduled,
                        completion: completion
                    ))
                } else {
                    onScheduled(requestID)
                    self.repaintCompletions.append(completion)
                }
            },
            onCancelTransportFullFrame: { [weak self] requestID in
                self?.canceledRepaintRequestIDs.append(requestID)
            },
            onRetireAllTransportFullFrames: { [weak self] in
                guard let self else { return 0 }
                let upperBound = self.nextRepaintRequestID
                self.retiredThroughRequestIDs.append(upperBound)
                return upperBound
            },
            currentTransportOutputDeliveryID: { [weak self] in
                self?.producedDeliveryHighWater ?? 0
            },
            onSaveWindowModes: { _, _ in }
        )
    }

    func scheduleNextRepaint() throws {
        let schedule = try XCTUnwrap(deferredRepaintSchedules.first)
        deferredRepaintSchedules.removeFirst()
        schedule.onScheduled(schedule.requestID)
        repaintCompletions.append(schedule.completion)
    }

    func stageHistory(surfaceID: SurfaceId, owner: RenderOwner, text: String) {
        controller.renderFeedSurface?(
            surfaceID,
            owner,
            Array(text.utf8)[...],
            .moshHistory
        )
        controller.requestTransportFullFrame?()
        controller.renderHistoryReady?(
            surfaceID,
            owner,
            240,
            300,
            .bottom
        )
    }

    @discardableResult
    func deliver(
        _ text: String,
        deliveryID: UInt64,
        repaintRequestID: UInt64?,
        forceRenderedResult: Bool? = nil
    ) -> Bool {
        producedDeliveryHighWater = max(producedDeliveryHighWater, deliveryID)
        let lease = adapter.makeTransportOutputLease(
            deliveryID: deliveryID,
            repaintRequestID: repaintRequestID
        )
        let admitted = lease.acceptsNextSlice()
        let renderedFully = forceRenderedResult ?? admitted
        if admitted && renderedFully {
            liveBox.feed(owner: lease.owner, Array(text.utf8)[...])
        }
        adapter.noteTransportOutputResult(
            deliveryID: deliveryID,
            repaintRequestID: repaintRequestID,
            renderedFully: renderedFully
        )
        return admitted && renderedFully
    }
}
