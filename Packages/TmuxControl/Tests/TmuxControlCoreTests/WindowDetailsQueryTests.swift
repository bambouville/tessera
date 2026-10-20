import Foundation
import XCTest
@testable import TmuxControlCore

/// Creating a window is the one topology transition tmux control mode leaves
/// half-finished. Captured from a live tmux 3.4 server, `new-window` emits
/// exactly `%session-window-changed` then `%window-add` — and nothing else,
/// ever. These tests pin that recovery so neither client goes blind again.
final class WindowDetailsQueryTests: XCTestCase {
    private let hydration = "__tessera_windows__\t@0\t0\t%0\tbb01,50x30,0,0,0\tbb01,50x30,0,0,0\t0\tzsh"

    func test_createdWindowIsAnnouncedWithNoPanesAndNoLayout() {
        var engine = attached()
        engine.feedWire("%session-window-changed $0 @1\r\n%window-add @1\r\n")

        let created = engine.snapshot.windows.first { $0.id == WindowId(1) }
        XCTAssertEqual(engine.snapshot.activeWindowID, WindowId(1))
        XCTAssertNil(created?.activePaneID, "tmux never names the new window's pane")
        XCTAssertNil(created?.layout, "%layout-change does not fire for window creation")
        XCTAssertNil(created?.name)
    }

    func test_announcedWindowAsksForItsDetailsExactlyOnce() {
        var engine = attached()
        engine.feedWire("%session-window-changed $0 @1\r\n%window-add @1\r\n")

        XCTAssertEqual(
            engine.takePendingWindowDetailQueries(),
            [TmuxRuntimeHydrationQuery.windowDetailsCommand(windowID: WindowId(1))],
            "both notifications name the same undescribed window; it is asked about once"
        )
        XCTAssertEqual(engine.takePendingWindowDetailQueries(), [], "draining is destructive")
    }

    func test_detailsReplyDescribesTheWindowWithoutReplacingTheList() {
        var engine = attached()
        engine.feedWire("%session-window-changed $0 @1\r\n%window-add @1\r\n")
        _ = engine.takePendingWindowDetailQueries()

        engine.reply("__tessera_window_details__\t@1\t1\t%1\tcc02,50x30,0,0,1\tcc02,50x30,0,0,1\t0\tbash")

        let created = engine.snapshot.windows.first { $0.id == WindowId(1) }
        XCTAssertEqual(created?.activePaneID, PaneId(1))
        XCTAssertEqual(created?.panes.map(\.id), [PaneId(1)])
        XCTAssertEqual(created?.name, "bash")
        XCTAssertEqual(created?.index, 1)
        XCTAssertNotNil(created?.layout)
        XCTAssertEqual(
            engine.snapshot.windows.map(\.id),
            [WindowId(0), WindowId(1)],
            "a one-window reply must merge; folding it through the list ingest would delete @0"
        )
        XCTAssertEqual(engine.snapshot.activeWindowID, WindowId(1))
    }

    func test_aDescribedWindowIsNeverAskedAbout() {
        var engine = attached()
        engine.feedWire("%session-window-changed $0 @0\r\n")
        XCTAssertEqual(engine.takePendingWindowDetailQueries(), [])
    }

    func test_nothingIsAskedBeforeTheAttachHydrationAnswers() {
        var engine = TmuxRuntimeEngine()
        engine.feedWire("%session-changed $0 work\r\n%window-add @0\r\n")
        XCTAssertEqual(
            engine.takePendingWindowDetailQueries(),
            [],
            "every window is undescribed before hydration; the batch query already covers them"
        )
    }

    func test_aClosedWindowIsNoLongerAskedAbout() {
        var engine = attached()
        engine.feedWire("%session-window-changed $0 @1\r\n%window-add @1\r\n")
        engine.feedWire("%unlinked-window-close @1\r\n")
        XCTAssertEqual(engine.takePendingWindowDetailQueries(), [])
    }

    /// The row grammar is the `list-windows` row under a second tag, so one
    /// parser serves the batch hydration, the shared merge, and an adapter
    /// that still keeps a window model of its own.
    func test_theSharedRowParserServesBothTags() {
        let details = TmuxRuntimeHydrationQuery.windowDetails(lines: [
            "__tessera_window_details__\t@4\t2\t%9\tcc02,50x30,0,0,9\t\t1\tvim",
        ])
        XCTAssertEqual(details?.window.id, WindowId(4))
        XCTAssertEqual(details?.window.index, 2)
        XCTAssertEqual(details?.window.activePaneID, PaneId(9))
        XCTAssertEqual(details?.window.name, "vim")
        XCTAssertTrue(details?.window.isZoomed == true)
        XCTAssertEqual(details?.rawLayout, "cc02,50x30,0,0,9")
        XCTAssertNil(details?.rawVisibleLayout)
        XCTAssertNil(
            TmuxRuntimeHydrationQuery.windowDetails(lines: [hydration]),
            "the list tag must not be mistaken for the single-window tag"
        )
    }

    func test_needsWindowDetailsIsTheSharedPredicate() {
        let complete = TmuxWindowSnapshot(
            id: WindowId(1),
            index: 1,
            name: "bash",
            activePaneID: PaneId(1),
            panes: [TmuxPaneSnapshot(id: PaneId(1), isActive: true)],
            layout: WindowLayout.parse("cc02,50x30,0,0,1")
        )
        XCTAssertFalse(TmuxRuntimeHydrationQuery.needsWindowDetails(complete))
        XCTAssertTrue(TmuxRuntimeHydrationQuery.needsWindowDetails(
            TmuxWindowSnapshot(id: WindowId(1))
        ))
        // A hydration that names no pane is still a described window: asking
        // again would re-query every window an adapter just hydrated.
        var noPane = complete
        noPane = TmuxWindowSnapshot(
            id: complete.id,
            index: complete.index,
            name: complete.name,
            activePaneID: nil,
            panes: [],
            layout: complete.layout
        )
        XCTAssertFalse(TmuxRuntimeHydrationQuery.needsWindowDetails(noPane))
    }

    private func attached() -> TmuxRuntimeEngine {
        var engine = TmuxRuntimeEngine()
        engine.feedWire("%session-changed $0 work\r\n")
        engine.reply(hydration)
        return engine
    }
}

private extension TmuxRuntimeEngine {
    mutating func feedWire(_ text: String) { _ = feed(Array(text.utf8)) }

    /// One client-response frame, which is what carries a fixed query's reply.
    mutating func reply(_ line: String) {
        feedWire("%begin 1 1 1\r\n\(line)\r\n%end 1 1 1\r\n")
    }
}
