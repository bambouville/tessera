import Foundation
import XCTest
@testable import TmuxControlCore

final class RuntimeWindowOrderingTests: XCTestCase {
    func testRejectedBoundsCannotConfirmMatchingListIndexes() throws {
        var engine = hydrated()
        let token = try XCTUnwrap(engine.beginReorder(expecting: ids(2, 0, 1, 3)))
        XCTAssertTrue(engine.confirmReorder(token: token))
        XCTAssertNotNil(engine.takePendingOrderRefreshCommand())
        let rows = (0..<4).map { id in
            "__tessera_windows__\t@\(id)\t\(id)\t%\(id + 10)\t\t\t0\t" + String(repeating: "x", count: id == 2 ? 8193 : 1)
        }
        engine.reply(rows.joined(separator: "\n"))
        XCTAssertFalse(TmuxRuntimeHydrationQuery.didIngestWindowList(lines: rows, snapshot: engine.snapshot))
        engine.completeOrderRefresh(succeeded: false)
        XCTAssertTrue(engine.snapshot.isReorderPending)
        XCTAssertFalse(engine.snapshot.isWindowListHydrated)
    }

    func testSessionChangeAndDisconnectInvalidateHydrationButKeepVisibleTopology() {
        var engine = hydrated()
        XCTAssertTrue(engine.snapshot.isWindowListHydrated)
        _ = engine.feed(Array("%session-changed $9 other\n".utf8))
        XCTAssertFalse(engine.snapshot.isWindowListHydrated)
        XCTAssertEqual(engine.snapshot.windows.count, 4)
        XCTAssertEqual(engine.takePendingOrderRefreshCommand(), TmuxRuntimeHydrationQuery.commands[0])
        XCTAssertNil(engine.beginReorder(expecting: ids(2, 0, 1, 3)))
        XCTAssertTrue(engine.ingestWindowListQuery(windows(0, 1, 2, 3)))
        XCTAssertTrue(engine.snapshot.isWindowListHydrated)
        engine.reset(keepingSnapshot: true)
        XCTAssertFalse(engine.snapshot.isWindowListHydrated)
    }

    func testWindowCloseRelinksWithoutDiscardingTopologyOrChangingActiveWindow() {
        var engine = hydrated()
        let before = try! XCTUnwrap(engine.snapshot.windows.first { $0.id == WindowId(2) })
        let revision = engine.snapshot.revision

        _ = engine.feed(Array("%window-close @2\n".utf8))

        let relinked = try! XCTUnwrap(engine.snapshot.windows.first { $0.id == WindowId(2) })
        XCTAssertEqual(relinked.index, before.index)
        XCTAssertEqual(relinked.panes, before.panes)
        XCTAssertEqual(relinked.layout, before.layout)
        XCTAssertEqual(engine.snapshot.activeWindowID, WindowId(2))
        XCTAssertEqual(engine.snapshot.revision, revision, "relink alone must not rebind render owners")
        XCTAssertEqual(
            engine.takePendingOrderRefreshCommand(),
            TmuxRuntimeHydrationQuery.commands[0]
        )
        XCTAssertNil(engine.takePendingOrderRefreshCommand())
    }

    func testUnlinkedWindowCloseRemovesAndSchedulesOneSurvivorRefresh() {
        var engine = hydrated()

        _ = engine.feed(Array("%unlinked-window-close @1\n%unlinked-window-close @3\n".utf8))

        XCTAssertEqual(engine.snapshot.windows.map(\.id), [WindowId(0), WindowId(2)])
        XCTAssertEqual(engine.snapshot.activeWindowID, WindowId(2))
        XCTAssertEqual(engine.takePendingOrderRefreshCommand(), TmuxRuntimeHydrationQuery.commands[0])
        XCTAssertNil(engine.takePendingOrderRefreshCommand())
    }

    func testPendingOrderSurvivesAckUntilAuthoritativeListReply() throws {
        var engine = hydrated()
        let token = try XCTUnwrap(engine.beginReorder(expecting: ids(2, 0, 1, 3)))

        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(2, 0, 1, 3))
        XCTAssertTrue(engine.snapshot.isReorderPending)
        XCTAssertTrue(engine.confirmReorder(token: token))
        XCTAssertTrue(engine.snapshot.isReorderPending, "a command ACK is not server order truth")
        XCTAssertEqual(engine.takePendingOrderRefreshCommand(), TmuxRuntimeHydrationQuery.commands[0])

        XCTAssertTrue(engine.ingestWindowListQuery(windows(0, 1, 2, 3)))
        XCTAssertTrue(engine.snapshot.isReorderPending, "uncorrelated ingest is not confirmation")
        engine.completeOrderRefresh(succeeded: true)
        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(0, 1, 2, 3))
        XCTAssertFalse(engine.snapshot.isReorderPending)
    }

    func testFailedPostAckRefreshWaitsForExplicitTimeoutAbandonment() throws {
        var engine = hydrated()
        let token = try XCTUnwrap(engine.beginReorder(expecting: ids(2, 0, 1, 3)))
        XCTAssertTrue(engine.confirmReorder(token: token))
        XCTAssertNotNil(engine.takePendingOrderRefreshCommand())

        engine.completeOrderRefresh(succeeded: false)

        XCTAssertTrue(
            engine.snapshot.isReorderPending,
            "failed truth must not look like successful reconciliation"
        )
        XCTAssertTrue(engine.abandonReorder(token: token))
        XCTAssertFalse(engine.snapshot.isReorderPending)
        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(0, 1, 2, 3))
    }

    func testPendingOrderRejectsConcurrentAndStaleTokensAndTimeoutAbandons() throws {
        var engine = hydrated()
        let token = try XCTUnwrap(engine.beginReorder(expecting: ids(1, 0, 2, 3)))

        XCTAssertNil(engine.beginReorder(expecting: ids(2, 1, 0, 3)))
        XCTAssertFalse(engine.confirmReorder(token: token &+ 1))
        XCTAssertFalse(engine.abandonReorder(token: token &+ 1))
        XCTAssertTrue(engine.snapshot.isReorderPending)
        XCTAssertTrue(engine.abandonReorder(token: token))
        XCTAssertFalse(engine.beginReorder(token: token, expecting: ids(1, 0, 2, 3)))
        XCTAssertFalse(engine.snapshot.isReorderPending)
        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(0, 1, 2, 3))
        XCTAssertEqual(engine.takePendingOrderRefreshCommand(), TmuxRuntimeHydrationQuery.commands[0])
    }

    func testDisconnectAbandonsPendingOrderWhileKeepingTopology() throws {
        var engine = hydrated()
        let token = try XCTUnwrap(engine.beginReorder(expecting: ids(2, 0, 1, 3)))
        XCTAssertTrue(engine.confirmReorder(token: token))

        engine.reset(keepingSnapshot: true)

        XCTAssertFalse(engine.snapshot.isReorderPending)
        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(0, 1, 2, 3))
    }

    func testPendingOrderRetainsNewAnnouncementAndRemoval() throws {
        var engine = hydrated()
        _ = try XCTUnwrap(engine.beginReorder(expecting: ids(2, 0, 1, 3)))

        _ = engine.feed(Array("%window-add @4\n%unlinked-window-close @1\n".utf8))

        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(2, 0, 3, 4))
        XCTAssertTrue(engine.snapshot.isReorderPending)
    }

    func testOrderSubscriptionUpdatesIndexesWithoutDiscardingPanesOrFocus() throws {
        var engine = hydrated()
        let paneBefore = try XCTUnwrap(
            engine.snapshot.windows.first { $0.id == WindowId(2) }?.panes
        )
        _ = try XCTUnwrap(engine.beginReorder(expecting: ids(2, 0, 1, 3)))

        XCTAssertTrue(engine.ingestWindowOrderSubscription(
            "0=@2* 1=@0 2=@1 3=@3",
            sessionID: SessionId(1)
        ))

        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(2, 0, 1, 3))
        XCTAssertEqual(engine.snapshot.windows.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(engine.snapshot.windows.first?.panes, paneBefore)
        XCTAssertEqual(engine.snapshot.activeWindowID, WindowId(2))
        XCTAssertTrue(
            engine.snapshot.isReorderPending,
            "a subscription sampled before the command reply cannot confirm optimism"
        )
    }

    func testLiveSessionScopedSubscriptionWireUpdatesOrder() {
        var engine = hydrated()

        _ = engine.feed(Array(
            "%subscription-changed tessera-window-order $1 - - - : 0=@3 1=@0 2=@1 3=@2* \n".utf8
        ))

        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(3, 0, 1, 2))
        XCTAssertEqual(engine.snapshot.windows.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(engine.snapshot.activeWindowID, WindowId(2))
    }

    func testListReplyForQueryStartedBeforeReorderCannotConfirmIt() throws {
        var engine = hydrated()
        _ = engine.feed(Array("%window-close @2\n".utf8))
        XCTAssertNotNil(engine.takePendingOrderRefreshCommand())
        let token = try XCTUnwrap(engine.beginReorder(expecting: ids(2, 0, 1, 3)))
        XCTAssertTrue(engine.confirmReorder(token: token))

        XCTAssertTrue(engine.ingestWindowListQuery(windows(0, 1, 2, 3)))
        engine.completeOrderRefresh(succeeded: true)

        XCTAssertTrue(engine.snapshot.isReorderPending)
        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(2, 0, 1, 3))
        XCTAssertEqual(
            engine.takePendingOrderRefreshCommand(),
            TmuxRuntimeHydrationQuery.commands[0],
            "the ACK dirties a pre-existing query so a post-reply query follows"
        )
        XCTAssertTrue(engine.ingestWindowListQuery(windows(2, 0, 1, 3)))
        engine.completeOrderRefresh(succeeded: true)
        XCTAssertFalse(engine.snapshot.isReorderPending)
    }

    func testListHydrationPreservesStablePanePresentationMetadata() {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array("%session-changed $1 work\n".utf8))
        let pane = TmuxPaneSnapshot(
            id: PaneId(12),
            title: "editor",
            titleIsDefault: false,
            currentCommand: "vim",
            currentPath: "/srv/project",
            isActive: true,
            isAlternateScreen: true,
            isMouseReporting: true,
            isSgrMouse: true,
            contentRect: CellRect(width: 80, height: 24, x: 0, y: 0)
        )
        XCTAssertTrue(engine.ingestWindowListQuery([TmuxWindowSnapshot(
            id: WindowId(2),
            index: 2,
            name: "w2",
            activePaneID: pane.id,
            activePaneTitle: pane.title,
            panes: [pane]
        )]))

        XCTAssertTrue(engine.ingestWindowListQuery([windows(2)[0]]))

        let retained = engine.snapshot.windows.first { $0.id == WindowId(2) }?.panes.first
        XCTAssertEqual(retained?.title, "editor")
        XCTAssertEqual(retained?.currentCommand, "vim")
        XCTAssertEqual(retained?.currentPath, "/srv/project")
        XCTAssertEqual(retained?.isAlternateScreen, true)
        XCTAssertEqual(retained?.isMouseReporting, true)
        XCTAssertEqual(retained?.isSgrMouse, true)
    }

    func testPartialListPreservesTopologyAndRichPaneMetadataWithoutConfirming() throws {
        var engine = hydrated()
        let pane = TmuxPaneSnapshot(id: PaneId(12), title: "editor", currentCommand: "vim", currentPath: "/work", isActive: true, isAlternateScreen: true, isMouseReporting: true, isSgrMouse: true)
        XCTAssertTrue(engine.ingestWindowMetadata(TmuxWindowSnapshot(id: WindowId(2), index: 2, name: "two", activePaneID: pane.id, activePaneTitle: "editor", panes: [pane])))
        let token = try XCTUnwrap(engine.beginReorder(expecting: ids(2, 0, 1, 3)))
        XCTAssertTrue(engine.confirmReorder(token: token))
        XCTAssertNotNil(engine.takePendingOrderRefreshCommand())
        let rows = ["__tessera_windows__\t@2\t2\t%12\tbb01,80x24,0,0,12\tbb01,80x24,0,0,12\t0\trenamed", "malformed"]
        engine.reply(rows.joined(separator: "\n"))
        engine.completeOrderRefresh(succeeded: TmuxRuntimeHydrationQuery.windowList(lines: rows) != nil)
        XCTAssertEqual(Set(engine.snapshot.windows.map(\.id)), Set(ids(0, 1, 2, 3)))
        let updated = try XCTUnwrap(engine.snapshot.windows.first { $0.id == WindowId(2) })
        XCTAssertEqual(updated.name, "renamed")
        XCTAssertEqual(updated.panes.first?.currentPath, "/work")
        XCTAssertEqual(updated.panes.first?.title, "editor")
        XCTAssertEqual(updated.panes.first?.currentCommand, "vim")
        XCTAssertEqual(updated.panes.first?.isMouseReporting, true)
        XCTAssertTrue(engine.snapshot.isReorderPending)
    }

    func testZoomedHydrationUsesFullLayoutPaneMembership() throws {
        let details = try XCTUnwrap(TmuxRuntimeHydrationQuery.windowDetails(lines: [
            "__tessera_window_details__\t@4\t2\t%8\t8205,80x24,0,0{40x24,0,0,8,39x24,41,0,9}\tcc02,80x24,0,0,8\t1\tmain",
        ]))

        XCTAssertEqual(details.window.panes.map(\.id), [PaneId(8), PaneId(9)])
        XCTAssertEqual(details.window.panes.first?.contentRect?.width, 80)
        XCTAssertEqual(details.window.panes.last?.contentRect?.width, 39)
    }

    func testWindowListParserRejectsPartialOrDuplicateTruth() {
        let valid = "__tessera_windows__\t@0\t0\t%0\tbb01,80x24,0,0,0\tbb01,80x24,0,0,0\t0\tmain"
        XCTAssertEqual(TmuxRuntimeHydrationQuery.windowList(lines: [valid])?.map(\.id), [WindowId(0)])
        XCTAssertNil(TmuxRuntimeHydrationQuery.windowList(lines: [valid, "malformed-row"]))
        XCTAssertNil(TmuxRuntimeHydrationQuery.windowList(lines: [valid, valid]))

        let duplicateFullLayout = "__tessera_windows__\t@0\t0\t%8\t8205,80x24,0,0{40x24,0,0,8,39x24,41,0,8}\tcc02,80x24,0,0,8\t1\tmain"
        XCTAssertNil(TmuxRuntimeHydrationQuery.windowList(lines: [duplicateFullLayout]))

        let duplicateVisibleLayout = "__tessera_windows__\t@0\t0\t%8\t8205,80x24,0,0{40x24,0,0,8,39x24,41,0,9}\t8205,80x24,0,0{40x24,0,0,8,39x24,41,0,8}\t1\tmain"
        XCTAssertNil(TmuxRuntimeHydrationQuery.windowList(lines: [duplicateVisibleLayout]))
    }

    func testUnknownSubscriptionIDPreservesStateAndRequestsFullHydration() {
        var engine = hydrated()
        let before = engine.snapshot

        XCTAssertFalse(engine.ingestWindowOrderSubscription(
            "0=@0 1=@99 2=@2* 3=@3",
            sessionID: SessionId(1)
        ))

        XCTAssertEqual(engine.snapshot.windows, before.windows)
        XCTAssertEqual(engine.snapshot.activeWindowID, before.activeWindowID)
        XCTAssertEqual(engine.takePendingOrderRefreshCommand(), TmuxRuntimeHydrationQuery.commands[0])
    }

    func testForeignSubscriptionIsIgnored() {
        var engine = hydrated()
        let before = engine.snapshot
        XCTAssertFalse(engine.ingestWindowOrderSubscription(
            "0=@3 1=@2* 2=@1 3=@0",
            sessionID: SessionId(9)
        ))
        XCTAssertEqual(engine.snapshot, before)
        XCTAssertNil(engine.takePendingOrderRefreshCommand())
    }

    func testActiveWindowHydrationPublishesCapabilitiesAndLegacySnapshotsDecode() throws {
        var engine = hydrated()
        engine.reply("__tessera_active_window__\t@2\t3.6a")
        XCTAssertEqual(engine.snapshot.capabilities, .forVersion("3.6a"))

        let legacy = """
        {"sessionID":{"rawValue":1},"sessionName":"work","activeWindowID":{"rawValue":2},"windows":[],"authority":{"unknown":{}},"revision":7}
        """
        let decoded = try JSONDecoder().decode(TmuxSnapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.capabilities)
        XCTAssertFalse(decoded.isReorderPending)
    }

    func testReorderRenderFactsHaveStableCanonicalShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(
            String(decoding: try encoder.encode(RenderFact.reorderBegan(
                token: 7,
                order: ids(2, 0, 1)
            )), as: UTF8.self),
            #"{"kind":"reorderBegan","order":[{"rawValue":2},{"rawValue":0},{"rawValue":1}],"token":7,"version":1}"#
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RenderFact.self,
                from: Data(#"{"kind":"reorderAbandoned","token":7,"version":1}"#.utf8)
            ),
            .reorderAbandoned(token: 7)
        )
    }

    func testMalformedOwnSubscriptionRequestsRecoveryButForeignOneDoesNot() {
        var engine = hydrated()
        let before = engine.snapshot
        XCTAssertFalse(engine.ingestWindowOrderSubscription("invalid", sessionID: SessionId(9)))
        XCTAssertNil(engine.takePendingOrderRefreshCommand())
        XCTAssertFalse(engine.ingestWindowOrderSubscription("invalid", sessionID: SessionId(1)))
        XCTAssertEqual(engine.snapshot.windows, before.windows)
        XCTAssertNotNil(engine.takePendingOrderRefreshCommand())
    }

    func testDisagreeingPeerOrderWinsAfterCorrelatedPostAckRefresh() throws {
        var engine = hydrated()
        let token = try XCTUnwrap(engine.beginReorder(expecting: ids(2, 0, 1, 3)))
        XCTAssertTrue(engine.ingestWindowOrderSubscription("0=@3 1=@1 2=@0 3=@2*", sessionID: SessionId(1)))
        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(2, 0, 1, 3))
        XCTAssertTrue(engine.confirmReorder(token: token))
        XCTAssertNotNil(engine.takePendingOrderRefreshCommand())
        let rows = [3, 1, 0, 2].enumerated().map { index, id in
            "__tessera_windows__\t@\(id)\t\(index)\t%\(id + 10)\tbb01,80x24,0,0,\(id + 10)\tbb01,80x24,0,0,\(id + 10)\t0\tw\(id)"
        }
        engine.reply(rows.joined(separator: "\n"))
        engine.completeOrderRefresh(succeeded: true)
        XCTAssertEqual(engine.snapshot.windows.map(\.id), ids(3, 1, 0, 2))
        XCTAssertFalse(engine.snapshot.isReorderPending)
    }

    func testMixedExplicitAndAllocatedTokensNeverReuseAnEpoch() throws {
        var engine = hydrated()
        XCTAssertTrue(engine.beginReorder(token: 40, expecting: ids(1, 0, 2, 3)))
        XCTAssertTrue(engine.abandonReorder(token: 40))
        XCTAssertEqual(engine.beginReorder(expecting: ids(1, 0, 2, 3)), 41)
        XCTAssertTrue(engine.abandonReorder(token: 41))
        XCTAssertTrue(engine.beginReorder(token: UInt64.max, expecting: ids(1, 0, 2, 3)))
        XCTAssertTrue(engine.abandonReorder(token: UInt64.max))
        XCTAssertNil(engine.beginReorder(expecting: ids(1, 0, 2, 3)))
    }

    private func hydrated() -> TmuxRuntimeEngine {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array("%session-changed $1 work\n".utf8))
        XCTAssertTrue(engine.ingestWindowListQuery(windows(0, 1, 2, 3)))
        XCTAssertTrue(engine.ingestActiveWindowQuery(WindowId(2)))
        return engine
    }

    private func windows(_ indexes: Int...) -> [TmuxWindowSnapshot] {
        indexes.map { index in
            let pane = PaneId(index + 10)
            return TmuxWindowSnapshot(
                id: WindowId(index),
                index: index,
                name: "w\(index)",
                activePaneID: pane,
                panes: [TmuxPaneSnapshot(id: pane, isActive: true)],
                layout: WindowLayout.parse("bb01,80x24,0,0,\(pane.rawValue)")
            )
        }
    }

    private func ids(_ values: Int...) -> [WindowId] { values.map(WindowId.init) }
}

private extension TmuxRuntimeEngine {
    mutating func reply(_ line: String) {
        _ = feed(Array("%begin 1 1 1\n\(line)\n%end 1 1 1\n".utf8))
    }
}
