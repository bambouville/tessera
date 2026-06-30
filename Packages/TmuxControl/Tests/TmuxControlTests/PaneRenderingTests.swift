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
    func append<S: Sequence>(contentsOf seq: S) where S.Element == UInt8 {
        bytes.append(contentsOf: seq)
    }
    func clear() { bytes.removeAll(keepingCapacity: true) }
}
