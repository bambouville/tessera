import XCTest
@testable import TmuxControlCore

final class LiveCurrentPathTests: XCTestCase {
    private func attached() -> TmuxRuntimeEngine {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array((
            "%session-changed $1 work\n" +
            "%begin 1 1 1\n" +
            "__tessera_windows__\t@4\t0\t%8\t0000,80x24,0,0{39x24,0,0,8,40x24,40,0,9}\t0000,80x24,0,0{39x24,0,0,8,40x24,40,0,9}\t0\tmain\n" +
            "%end 1 1 1\n" +
            "%begin 1 2 1\n" +
            "__tessera_panes__\t@4\t%8\t1\t0\t0\t80\t24\tvps\t/home/dev\tvps\n" +
            "__tessera_panes__\t@4\t%9\t0\t0\t0\t80\t24\tvps\t/tmp\tvps\n" +
            "%end 1 2 1\n" +
            "%session-window-changed $1 @4\n"
        ).utf8))
        return engine
    }

    private func report(path: String, pane: String = "%8", session: String = "$1") -> [UInt8] {
        let fields = ["@4", pane, pane == "%8" ? "1" : "0", "0", "0", "80", "24",
                      "bash", "vps", "main", "vps", path, ""]
        return Array(("%subscription-changed tessera-pane-meta \(session) @4 0 \(pane) : " +
                      fields.joined(separator: "\t") + "\n").utf8)
    }

    func testDirectoryOnlyChangeReplacesHydratedPathAndPublishesRevision() {
        var engine = attached()
        _ = engine.feed(report(path: "/home/dev"))
        let revision = engine.snapshot.revision
        let updated = engine.feed(report(path: "/srv/Project Files")).snapshot
        XCTAssertEqual(updated.windows.first?.panes.first?.currentPath, "/srv/Project Files")
        XCTAssertGreaterThan(updated.revision, revision)
        XCTAssertEqual(engine.feed(report(path: "/srv/Project Files")).snapshot.revision, updated.revision)
    }

    func testBackgroundPaneTracksItsOwnDirectoryWithoutMovingFocus() {
        var engine = attached()
        let snapshot = engine.feed(report(path: "/var/log", pane: "%9")).snapshot
        XCTAssertEqual(snapshot.windows.first?.activePaneID, PaneId(8))
        XCTAssertEqual(snapshot.windows.first?.panes.first { $0.id == PaneId(8) }?.currentPath, "/home/dev")
        XCTAssertEqual(snapshot.windows.first?.panes.first { $0.id == PaneId(9) }?.currentPath, "/var/log")
    }

    func testForeignSessionCannotChangeDirectoryAndEmptyReportClearsStalePath() {
        var engine = attached()
        let revision = engine.snapshot.revision
        let foreign = engine.feed(report(path: "/foreign", session: "$2")).snapshot
        XCTAssertEqual(foreign.windows.first?.panes.first?.currentPath, "/home/dev")
        XCTAssertEqual(foreign.revision, revision)
        XCTAssertNil(engine.feed(report(path: "")).snapshot.windows.first?.panes.first?.currentPath)
    }
}
