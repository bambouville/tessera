import XCTest
@testable import TmuxControl

/// M2: per-pane render-sink routing and refreshPane wire shapes.
@MainActor
final class PaneRenderingTests: XCTestCase {

    /// Drive the controller into tmux mode with a 2-pane active window @1
    /// (panes %10 active, %11), returning the captured shared-terminal feed.
    private func makeGridController() -> (
        TmuxController,
        sharedFeed: ByteSink,
        sent: ByteSink
    ) {
        let sharedFeed = ByteSink()
        let sent = ByteSink()
        let controller = TmuxController(controlPath: .inline)
        controller.feedTerminal = { slice in sharedFeed.append(contentsOf: slice) }
        controller.sendBytes = { bytes in sent.append(contentsOf: bytes) }

        // Enter -CC, drain the handshake + attach-init (empty responses).
        var chunk: [UInt8] = [0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70]
        chunk.append(contentsOf: Array("%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        controller.ingest(chunk)
        for number in 2...8 {
            controller.ingest(Array("%begin 0 \(number) 1\r\n%end 0 \(number) 1\r\n".utf8))
        }
        // Order matters: add @1 (latches active), make it a 2-pane GRID via
        // %layout-change BEFORE any focus notification fires a shared refresh.
        // Once @1 is a grid, refreshRenderedWindow is gated off, so no stray
        // display-message pending commands sit in the FIFO ahead of refreshPane.
        controller.ingest(Array("%window-add @1\r\n".utf8))
        // %window-add for a still-unnamed window fires a queryWindowName
        // (display-message -t @1 '#{window_name}'); drain its reply so it does
        // not sit in the FIFO ahead of the later refreshPane command.
        controller.ingest(Array("%begin 0 9 1\r\nmain\r\n%end 0 9 1\r\n".utf8))
        controller.ingest(Array(
            "%layout-change @1 8205,80x24,0,0{40x24,0,0,10,39x24,41,0,11} 8205,80x24,0,0{40x24,0,0,10,39x24,41,0,11} *\r\n".utf8
        ))
        controller.ingest(Array("%window-pane-changed @1 %10\r\n".utf8))
        controller.ingest(Array("%session-window-changed $0 @1\r\n".utf8))
        return (controller, sharedFeed, sent)
    }

    func test_paneSink_routesOutputAndBypassesSharedTerminal() {
        let (controller, sharedFeed, _) = makeGridController()
        let paneFeed = ByteSink()
        controller.setPaneSink(PaneId(11)) { slice in paneFeed.append(contentsOf: slice) }

        controller.ingest(Array("%output %11 hello\r\n".utf8))

        // The parser strips the line's CRLF terminator; the payload is "hello".
        XCTAssertEqual(String(decoding: paneFeed.bytes, as: UTF8.self), "hello")
        XCTAssertTrue(sharedFeed.bytes.isEmpty, "a pane with a sink must not paint the shared terminal")
    }

    func test_paneWithoutSink_fallsThroughToSharedPath() {
        let (controller, _, _) = makeGridController()
        // Only %11 has a sink; %10 output should NOT route to %11's sink.
        let paneFeed = ByteSink()
        controller.setPaneSink(PaneId(11)) { slice in paneFeed.append(contentsOf: slice) }

        controller.ingest(Array("%output %10 world\r\n".utf8))
        XCTAssertTrue(paneFeed.bytes.isEmpty, "%10 output must not leak into %11's sink")
    }

    func test_refreshPane_sendsDisplayMessageThenCapture() {
        let (controller, _, sent) = makeGridController()
        controller.setPaneSink(PaneId(11)) { _ in }
        sent.clear()

        controller.refreshPane(paneId: PaneId(11), deep: true)
        let metadataCommand = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertTrue(
            metadataCommand.hasPrefix("display-message -p -t %11 '"),
            "refreshPane must first query pane metadata; got: \(metadataCommand)"
        )

        // Reply with a minimal valid metadata line (paneId, cursorX, cursorY).
        sent.clear()
        // Find this command's number from the FIFO order: it is the first (and
        // only) pending command. tmux frames are flags-bit0 set for responses.
        controller.ingest(Array("%begin 0 20 1\r\n%11\t0\t0\r\n%end 0 20 1\r\n".utf8))

        let captureCommand = String(decoding: sent.bytes, as: UTF8.self)
        XCTAssertTrue(
            captureCommand.contains("capture-pane") && captureCommand.contains("-t %11"),
            "after metadata, refreshPane must capture the pane; got: \(captureCommand)"
        )
    }

    func test_outputDroppedWhilePaneRefreshInFlight() {
        let (controller, _, sent) = makeGridController()
        let paneFeed = ByteSink()
        controller.setPaneSink(PaneId(11)) { slice in paneFeed.append(contentsOf: slice) }
        sent.clear()

        // Start a refresh (sets pendingPaneRefreshes[%11]); no response yet.
        controller.refreshPane(paneId: PaneId(11), deep: false)
        // Live output that arrives mid-refresh must be dropped (stale).
        controller.ingest(Array("%output %11 stale\r\n".utf8))
        XCTAssertTrue(paneFeed.bytes.isEmpty, "output must be dropped while a pane refresh is in flight")
    }

    func test_gridForegroundRefreshCoalescesEachPaneWithoutLosingOutput() {
        let (controller, sharedFeed, sent) = makeGridController()
        let paneFeed = ByteSink()
        controller.setPaneSink(PaneId(11)) { slice in paneFeed.append(contentsOf: slice) }
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %11 retained-grid-output\r\n".utf8))
        XCTAssertTrue(paneFeed.bytes.isEmpty)

        controller.refreshActiveWindowOnForeground()
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).hasPrefix("display-message -p -t %11"))
        sent.clear()
        controller.ingest(Array("%begin 0 20 1\r\n%11\t0\t0\r\n%end 0 20 1\r\n".utf8))
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("capture-pane -p -e -N -t %11"))
        sent.clear()
        controller.ingest(Array("%begin 0 21 1\r\ngrid viewport\r\n%end 0 21 1\r\n".utf8))

        XCTAssertEqual(paneFeed.chunks.count, 2)
        XCTAssertEqual(paneFeed.chunks[0], Array("retained-grid-output".utf8))
        XCTAssertTrue(String(decoding: paneFeed.chunks[1], as: UTF8.self).contains("grid viewport"))
        XCTAssertTrue(sharedFeed.bytes.isEmpty)

        paneFeed.clear()
        controller.ingest(Array("%output %11 live-grid-output\r\n".utf8))
        XCTAssertEqual(paneFeed.bytes, Array("live-grid-output".utf8))
    }

    func test_gridForegroundRefreshSupersedesOlderPaneCaptureByRequestIdentity() async throws {
        let (controller, _, sent) = makeGridController()
        let paneFeed = ByteSink()
        controller.setPaneSink(PaneId(11)) { slice in paneFeed.append(contentsOf: slice) }
        sent.clear()

        controller.refreshPane(paneId: PaneId(11), deep: false)
        sent.clear()
        controller.ingest(Array("%begin 0 20 1\r\n%11\t0\t0\r\n%end 0 20 1\r\n".utf8))
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("capture-pane"))

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %11 retained-after-old-capture\r\n".utf8))
        controller.refreshActiveWindowOnForeground()
        sent.clear()

        // The old capture response arrives first. Its request id is stale and
        // must neither consume retained bytes nor complete the new recovery.
        controller.ingest(Array("%begin 0 21 1\r\nold viewport\r\n%end 0 21 1\r\n".utf8))
        XCTAssertTrue(paneFeed.bytes.isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("display-message -p -t %11"))
        sent.clear()
        controller.ingest(Array("%begin 0 22 1\r\n%11\t0\t0\r\n%end 0 22 1\r\n".utf8))
        sent.clear()
        controller.ingest(Array("%begin 0 23 1\r\nnew viewport\r\n%end 0 23 1\r\n".utf8))

        XCTAssertEqual(paneFeed.chunks.count, 2)
        XCTAssertEqual(paneFeed.chunks[0], Array("retained-after-old-capture".utf8))
        XCTAssertTrue(String(decoding: paneFeed.chunks[1], as: UTF8.self).contains("new viewport"))
        XCTAssertFalse(String(decoding: paneFeed.bytes, as: UTF8.self).contains("old viewport"))
    }

    func test_gridForegroundCaptureFailureRetriesWithoutReopeningLiveOutput() async throws {
        let (controller, _, sent) = makeGridController()
        controller.renderRefreshRetryDelay = 0.01
        let paneFeed = ByteSink()
        controller.setPaneSink(PaneId(11)) { slice in paneFeed.append(contentsOf: slice) }
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %11 retained-grid-retry\r\n".utf8))
        controller.refreshActiveWindowOnForeground()
        sent.clear()
        controller.ingest(Array("%begin 0 20 1\r\nfailed\r\n%error 0 20 1\r\n".utf8))
        controller.ingest(Array("%output %11 still-gated\r\n".utf8))
        XCTAssertTrue(paneFeed.bytes.isEmpty)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("display-message -p -t %11"))
        sent.clear()
        controller.ingest(Array("%begin 0 21 1\r\n%11\t0\t0\r\n%end 0 21 1\r\n".utf8))
        sent.clear()
        controller.ingest(Array("%begin 0 22 1\r\ngrid recovered\r\n%end 0 22 1\r\n".utf8))

        XCTAssertEqual(
            paneFeed.chunks.first,
            Array("retained-grid-retrystill-gated".utf8)
        )
        XCTAssertTrue(String(decoding: paneFeed.bytes, as: UTF8.self).contains("grid recovered"))
    }

    func test_gridForegroundRefreshDeepLoadsNewlyMountedFocusedPane() {
        let (controller, _, sent) = makeGridController()
        controller.setPaneSink(PaneId(10)) { _ in }
        sent.clear()

        controller.prepareForAppInactivity()
        controller.refreshActiveWindowOnForeground()
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("display-message -p -t %10"))
        sent.clear()
        controller.ingest(Array("%begin 0 20 1\r\n%10\t0\t0\t\t\t\t0\t100\r\n%end 0 20 1\r\n".utf8))

        XCTAssertTrue(
            String(decoding: sent.bytes, as: UTF8.self).contains("capture-pane -p -e -N -S -2000 -t %10"),
            "a focused pane whose inactive mount skipped deep load must recover its scrollback"
        )
    }

    func test_gridForegroundRenderWaitsForOlderBackgroundQuery() async throws {
        let (controller, _, sent) = makeGridController()
        let paneFeed = ByteSink()
        controller.setPaneSink(PaneId(10)) { paneFeed.append(contentsOf: $0) }
        sent.clear()

        var olderResult: Result<[String], TmuxController.CommandError>?
        controller.sendBackgroundControlQuery(
            "display-message -p -t %10 '#{cursor_y}'"
        ) { olderResult = $0 }
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("#{cursor_y}"))
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %10 retained-grid-output\r\n".utf8))
        controller.refreshActiveWindowOnForeground()
        XCTAssertEqual(sent.bytes, [], "grid metadata must wait for the older observer reply")

        var rejectedResult: Result<[String], TmuxController.CommandError>?
        controller.sendBackgroundControlQuery(
            "display-message -p -t %10 '#{pane_current_command}'"
        ) { rejectedResult = $0 }
        guard case .failure(.cancelled)? = rejectedResult else {
            return XCTFail("new observers must fail fast while grid recovery owns the queue")
        }

        controller.ingest(Array("%begin 0 20 1\r\n51\r\n%end 0 20 1\r\n".utf8))
        guard case .success(let lines)? = olderResult else {
            return XCTFail("the older observer should receive its own result")
        }
        XCTAssertEqual(lines, ["51"])

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("display-message -p -t %10"))
        sent.clear()
        controller.ingest(Array("%begin 0 21 1\r\n%10\t0\t0\r\n%end 0 21 1\r\n".utf8))
        controller.ingest(Array("%begin 0 22 1\r\ngrid history\r\n%end 0 22 1\r\n".utf8))
        XCTAssertTrue(
            String(decoding: sent.bytes, as: UTF8.self)
                .contains("display-message -p -t %10")
        )
        XCTAssertTrue(
            String(decoding: sent.bytes, as: UTF8.self)
                .contains("capture-pane -p -e -N -t %10")
        )
        sent.clear()
        controller.ingest(Array("%begin 0 23 1\r\n%10\t0\t0\r\n%end 0 23 1\r\n".utf8))
        controller.ingest(Array("%begin 0 24 1\r\ngrid viewport\r\n%end 0 24 1\r\n".utf8))

        XCTAssertEqual(paneFeed.chunks.first, Array("retained-grid-output".utf8))
        XCTAssertTrue(String(decoding: paneFeed.bytes, as: UTF8.self).contains("grid viewport"))
    }

    func test_gridForegroundCompletionCannotReleaseReplacementSharedRefresh() async throws {
        let (controller, sharedFeed, sent) = makeGridController()
        controller.setPaneSink(PaneId(10)) { _ in }
        sent.clear()

        controller.prepareForAppInactivity()
        controller.ingest(Array("%output %10 retained-grid-output\r\n".utf8))
        controller.refreshActiveWindowOnForeground()
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("display-message -p -t %10"))

        // The active window collapses to one pane while its grid foreground
        // metadata is still in flight. The shared surface takes ownership of
        // the same barrier before SwiftUI dismantles the old pane sink.
        controller.ingest(Array(
            "%layout-change @1 b25f,80x24,0,0,10 b25f,80x24,0,0,10 *\r\n".utf8
        ))
        controller.resyncRenderedWindowAfterGridCollapse(cols: 80, rows: 24)
        // PaneGridView dismantles surfaces one at a time through this API.
        // Removing the last old pane must not release the replacement shared
        // refresh owner before its authoritative capture lands.
        controller.setPaneSink(PaneId(10), nil)

        // First response belongs to the obsolete grid request. It must not
        // release the replacement shared owner or let incremental output paint.
        controller.ingest(Array("%begin 0 20 1\r\n%10\t0\t0\r\n%end 0 20 1\r\n".utf8))
        controller.ingest(Array("%output %10 must-stay-gated\r\n".utf8))
        XCTAssertTrue(sharedFeed.bytes.isEmpty)

        // The shared metadata/capture pair is now authoritative and releases
        // the barrier only after the full viewport has painted.
        sent.clear()
        controller.ingest(Array("%begin 0 21 1\r\n%end 0 21 1\r\n".utf8)) // refresh-client -C
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("display-message -p -t @1"))
        sent.clear()
        controller.ingest(Array("%begin 0 22 1\r\n%10\t0\t0\r\n%end 0 22 1\r\n".utf8))
        XCTAssertTrue(String(decoding: sent.bytes, as: UTF8.self).contains("capture-pane -p -e -N -t @1"))
        controller.ingest(Array("%begin 0 23 1\r\nauthoritative shared viewport\r\n%end 0 23 1\r\n".utf8))

        XCTAssertTrue(String(decoding: sharedFeed.bytes, as: UTF8.self).contains("authoritative shared viewport"))
        controller.ingest(Array("%begin 0 24 1\r\n%10\t0\t0\r\n%end 0 24 1\r\n".utf8))
        controller.ingest(Array("%begin 0 25 1\r\nauthoritative shared history\r\n%end 0 25 1\r\n".utf8))
        controller.ingest(Array("%output %10 live-after-shared-recovery\r\n".utf8))
        XCTAssertTrue(String(decoding: sharedFeed.bytes, as: UTF8.self).contains("live-after-shared-recovery"))
    }

    func test_clearAllPaneSinks_stopsRoutingToSinks() {
        let (controller, _, _) = makeGridController()
        let paneFeed = ByteSink()
        controller.setPaneSink(PaneId(11)) { slice in paneFeed.append(contentsOf: slice) }
        controller.clearAllPaneSinks()
        XCTAssertTrue(controller.renderingPaneIds.isEmpty)

        // A cleared sink must receive no further output. (Byte-identity of the
        // shared single-pane path with no sinks is already pinned by the
        // unmodified golden swap tests.)
        controller.ingest(Array("%output %11 after\r\n".utf8))
        XCTAssertTrue(paneFeed.bytes.isEmpty, "a cleared sink must not receive further output")
    }
}

private final class ByteSink {
    private(set) var bytes: [UInt8] = []
    private(set) var chunks: [[UInt8]] = []
    func append<S: Sequence>(contentsOf seq: S) where S.Element == UInt8 {
        let chunk = Array(seq)
        chunks.append(chunk)
        bytes.append(contentsOf: chunk)
    }
    func clear() {
        bytes.removeAll(keepingCapacity: true)
        chunks.removeAll(keepingCapacity: true)
    }
}
