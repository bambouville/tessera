import XCTest
@testable import TmuxControlCore

/// mosh never relays the alternate screen, so a mosh+tmux client learns that
/// a pane runs a full-screen program (Claude Code, htop, Vim) only from the
/// pane-metadata feed. Both platforms read these flags off the core snapshot.
final class PaneModeSubscriptionTests: XCTestCase {
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

    private func report(pane: String = "%8", modes: [String]) -> [UInt8] {
        let fields = ["@4", pane, pane == "%8" ? "1" : "0", "0", "0", "80", "24",
                      "claude", "vps", "main", "vps", "/home/dev", ""] + modes
        return Array(("%subscription-changed tessera-pane-meta $1 @4 0 \(pane) : " +
                      fields.joined(separator: "\t") + "\n").utf8)
    }

    private func pane(_ id: Int, in engine: TmuxRuntimeEngine) -> TmuxPaneSnapshot? {
        engine.snapshot.windows.first?.panes.first { $0.id == PaneId(id) }
    }

    func testFormatRequestsPaneModesAfterAgentState() {
        XCTAssertTrue(TmuxPaneMetadataSubscription.format.hasSuffix(
            "#{s/\t/ /:@tessera_agent_state}\t#{alternate_on}\t#{mouse_any_flag}\t#{mouse_sgr_flag}"
        ))
    }

    func testParseReadsModesAndLeavesThemUnknownOnOlderPayloads() throws {
        let modern = try XCTUnwrap(TmuxPaneMetadataSubscription.parse(
            "@4\t%8\t1\t0\t0\t80\t24\tclaude\tvps\tmain\tvps\t/home/dev\t\t1\t1\t1",
            fallbackWindowID: WindowId(1), fallbackPaneID: PaneId(1)
        ))
        XCTAssertEqual(modern.isAlternateScreen, true)
        XCTAssertEqual(modern.isMouseReporting, true)
        XCTAssertEqual(modern.isSgrMouse, true)
        XCTAssertNil(modern.agentStateJSON)

        let legacy = try XCTUnwrap(TmuxPaneMetadataSubscription.parse(
            "@4\t%8\t1\t0\t0\t80\t24\tclaude\tvps\tmain\tvps\t/home/dev\t",
            fallbackWindowID: WindowId(1), fallbackPaneID: PaneId(1)
        ))
        XCTAssertNil(legacy.isAlternateScreen)
        XCTAssertNil(legacy.isMouseReporting)
        XCTAssertNil(legacy.isSgrMouse)
    }

    func testFeedPublishesModesOnlyWhenTheyChange() {
        var engine = attached()
        XCTAssertNil(pane(8, in: engine)?.isAlternateScreen)

        let entered = engine.feed(report(modes: ["1", "1", "1"])).snapshot
        XCTAssertEqual(pane(8, in: engine)?.isAlternateScreen, true)
        XCTAssertEqual(pane(8, in: engine)?.isMouseReporting, true)
        XCTAssertEqual(pane(8, in: engine)?.isSgrMouse, true)
        XCTAssertEqual(engine.feed(report(modes: ["1", "1", "1"])).snapshot.revision, entered.revision)

        _ = engine.feed(report(modes: ["0", "0", "0"]))
        XCTAssertEqual(pane(8, in: engine)?.isAlternateScreen, false)
        XCTAssertEqual(pane(8, in: engine)?.isMouseReporting, false)
    }

    func testOlderPayloadKeepsKnownModesAndBackgroundPaneKeepsItsOwn() {
        var engine = attached()
        _ = engine.feed(report(modes: ["1", "0", "0"]))
        _ = engine.feed(report(modes: []))
        XCTAssertEqual(pane(8, in: engine)?.isAlternateScreen, true)
        XCTAssertEqual(pane(8, in: engine)?.isMouseReporting, false)

        _ = engine.feed(report(pane: "%9", modes: ["0", "0", "0"]))
        XCTAssertEqual(pane(8, in: engine)?.isAlternateScreen, true)
        XCTAssertEqual(pane(9, in: engine)?.isAlternateScreen, false)
    }

    func testHydrationRepliesKeepModesTheSubscriptionReported() {
        var engine = attached()
        _ = engine.feed(report(modes: ["1", "1", "1"]))

        // Neither hydration query asks for pane modes; a quiet full-screen
        // pane may never report again, so a reply must not forget them.
        _ = engine.feed(Array((
            "%begin 2 1 1\n" +
            "__tessera_panes__\t@4\t%8\t1\t0\t0\t80\t24\tvps\t/home/dev\tvps\n" +
            "__tessera_panes__\t@4\t%9\t0\t0\t0\t80\t24\tvps\t/tmp\tvps\n" +
            "%end 2 1 1\n"
        ).utf8))
        XCTAssertEqual(pane(8, in: engine)?.isAlternateScreen, true)
        XCTAssertEqual(pane(8, in: engine)?.isMouseReporting, true)
        XCTAssertEqual(pane(8, in: engine)?.isSgrMouse, true)

        _ = engine.feed(Array((
            "%begin 2 2 1\n" +
            "__tessera_window_details__\t@4\t0\t%8\t0000,80x24,0,0{39x24,0,0,8,40x24,40,0,9}\t0000,80x24,0,0{39x24,0,0,8,40x24,40,0,9}\t0\tmain\n" +
            "%end 2 2 1\n"
        ).utf8))
        XCTAssertEqual(pane(8, in: engine)?.isAlternateScreen, true)
        XCTAssertEqual(pane(8, in: engine)?.isMouseReporting, true)
        XCTAssertNil(pane(9, in: engine)?.isAlternateScreen)
    }
}
