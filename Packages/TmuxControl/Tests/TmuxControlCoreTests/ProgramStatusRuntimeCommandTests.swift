import XCTest
@testable import TmuxControlCore

final class ProgramStatusRuntimeCommandTests: XCTestCase {
    private func metadata(command: String, session: Int = 1) -> [UInt8] {
        let value = ["@1", "%10", "1", "0", "0", "80", "24", command,
                     "build", "work", "vps-1", "/work"].joined(separator: "\t")
        return Array("%subscription-changed tessera-pane-meta $\(session) @1 0 %10 : \(value)\n".utf8)
    }

    private func attached() -> TmuxRuntimeEngine {
        var engine = TmuxRuntimeEngine()
        _ = engine.feed(Array("%session-changed $1 work\n".utf8))
        XCTAssertTrue(engine.ingestWindowListQuery([
            .init(id: WindowId(1), name: "work", activePaneID: PaneId(10),
                  panes: [.init(id: PaneId(10), title: "build", currentCommand: "cargo",
                                currentPath: "/work", isActive: true)])
        ]))
        return engine
    }

    func testLiveCommandChangeToShellMarksBlockedRecordHistorical() {
        var engine = attached()
        var monitor = ProgramStatusMonitor(answersQueries: false)
        monitor.observe(batch: engine.feed(metadata(command: "cargo")))
        monitor.observe(batch: engine.feed(Array("%output %10 \\033]7501;state=blocked:app=cargo\\007\n".utf8)))
        let key = ProgramStatusTerminalKey.pane(PaneId(10))
        XCTAssertEqual(monitor.snapshot().terminal(key)?.attention, .needsInput(nil))
        let revision = engine.snapshot.revision
        let batch = engine.feed(metadata(command: "zsh"))
        XCTAssertEqual(batch.snapshot.windows.first?.panes.first?.currentCommand, "zsh")
        XCTAssertGreaterThan(batch.snapshot.revision, revision)
        monitor.observe(batch: batch)
        XCTAssertEqual(monitor.snapshot().terminal(key)?.entries.first?.isHistorical, true)
        XCTAssertNil(monitor.snapshot().terminal(key)?.attention)
        XCTAssertEqual(engine.feed(metadata(command: "zsh")).snapshot.revision, batch.snapshot.revision)
    }

    func testMissingAndForeignCommandUpdatesPreserveKnownCommand() {
        var engine = attached()
        _ = engine.feed(metadata(command: ""))
        XCTAssertEqual(engine.snapshot.windows.first?.panes.first?.currentCommand, "cargo")
        _ = engine.feed(metadata(command: "zsh", session: 2))
        XCTAssertEqual(engine.snapshot.windows.first?.panes.first?.currentCommand, "cargo")
    }
}
