import XCTest
@testable import TmuxControl

@MainActor
final class PaneCurrentPathTests: XCTestCase {

    func test_parsePaneSubscriptionMetadata_newFormatIncludesCurrentPath() throws {
        let metadata = try XCTUnwrap(parse(
            "@5\t%12\t1\t0\t1\t80\t24\tvim\tPane Title\teditor\tremote.example.com\t/home/user/src/tessera"
        ))

        XCTAssertEqual(metadata.windowId, WindowId(5))
        XCTAssertEqual(metadata.paneId, PaneId(12))
        XCTAssertTrue(metadata.isActive)
        XCTAssertEqual(metadata.contentRect, CellRect(width: 80, height: 24, x: 0, y: 1))
        XCTAssertEqual(metadata.currentCommand, "vim")
        XCTAssertEqual(metadata.paneTitle, "Pane Title")
        XCTAssertEqual(metadata.windowName, "editor")
        XCTAssertEqual(metadata.currentPath, "/home/user/src/tessera")
    }

    func test_parsePaneSubscriptionMetadata_oldFormatLeavesCurrentPathNil() throws {
        let metadata = try XCTUnwrap(parse(
            "@5\t%12\t1\t0\t1\t80\t24\tvim\tPane Title\teditor\tremote.example.com"
        ))

        XCTAssertEqual(metadata.windowId, WindowId(5))
        XCTAssertEqual(metadata.paneId, PaneId(12))
        XCTAssertTrue(metadata.isActive)
        XCTAssertEqual(metadata.contentRect, CellRect(width: 80, height: 24, x: 0, y: 1))
        XCTAssertEqual(metadata.currentCommand, "vim")
        XCTAssertEqual(metadata.paneTitle, "Pane Title")
        XCTAssertEqual(metadata.windowName, "editor")
        XCTAssertNil(metadata.currentPath)
    }

    func test_parsePaneSubscriptionMetadata_emptyCurrentPathIsNil() throws {
        let metadata = try XCTUnwrap(parse(
            "@5\t%12\t1\t0\t1\t80\t24\tvim\tPane Title\teditor\tremote.example.com\t"
        ))

        XCTAssertNil(metadata.currentPath)
    }

    func test_parsePaneSubscriptionMetadata_currentPathCanContainSpaces() throws {
        let metadata = try XCTUnwrap(parse(
            "@5\t%12\t1\t0\t1\t80\t24\tvim\tPane Title\teditor\tremote.example.com\t/home/user/Project Files"
        ))

        XCTAssertEqual(metadata.currentPath, "/home/user/Project Files")
    }

    func test_controllerSubscriptionUpdatesPaneCurrentPathForActivePane() {
        let controller = makeController()
        enterTmuxMode(controller)
        controller.ingest(Array("%session-changed $0 main\r\n".utf8))
        controller.ingest(Array("%window-add @5\r\n".utf8))

        controller.ingest(Array(
            "%subscription-changed tessera-pane-meta $0 @5 0 %12 : @5\\t%12\\t1\\t0\\t1\\t80\\t24\\tvim\\tPane Title\\teditor\\tremote.example.com\\t/home/user/Project Files\r\n".utf8
        ))

        XCTAssertEqual(controller.paneCurrentPaths[PaneId(12)], "/home/user/Project Files")
        XCTAssertEqual(controller.activePaneId, PaneId(12))
        XCTAssertEqual(controller.activePaneCurrentPath, "/home/user/Project Files")
    }

    func test_controllerSubscriptionIgnoresForeignSessionCurrentPath() {
        let controller = makeController()
        enterTmuxMode(controller)
        controller.ingest(Array("%session-changed $0 main\r\n".utf8))
        controller.ingest(Array("%window-add @5\r\n".utf8))

        controller.ingest(Array(
            "%subscription-changed tessera-pane-meta $1 @5 0 %12 : @5\\t%12\\t1\\t0\\t1\\t80\\t24\\tvim\\tPane Title\\teditor\\tremote.example.com\\t/foreign/path\r\n".utf8
        ))

        XCTAssertTrue(controller.paneCurrentPaths.isEmpty)
        XCTAssertNil(controller.activePaneCurrentPath)
    }

    func test_controllerPrunesPaneCurrentPathWhenWindowCloses() {
        let controller = makeController()
        enterTmuxMode(controller)
        controller.ingest(Array("%session-changed $0 main\r\n".utf8))
        controller.ingest(Array("%window-add @5\r\n".utf8))
        controller.ingest(Array(
            "%subscription-changed tessera-pane-meta $0 @5 0 %12 : @5\\t%12\\t1\\t0\\t1\\t80\\t24\\tvim\\tPane Title\\teditor\\tremote.example.com\\t/home/user/src/tessera\r\n".utf8
        ))
        XCTAssertEqual(controller.paneCurrentPaths[PaneId(12)], "/home/user/src/tessera")

        controller.ingest(Array("%window-close @5\r\n".utf8))

        XCTAssertTrue(controller.paneCurrentPaths.isEmpty)
        XCTAssertNil(controller.activePaneCurrentPath)
    }

    func test_paneMetadataSubscriptionFormatEndsWithRetainedAgentState() {
        XCTAssertTrue(
            TmuxController.paneMetadataSubscriptionFormat.hasSuffix("#{pane_current_path}\t#{@tessera_agent_state}"),
            "pane metadata subscription must replay cwd and retained agent state"
        )
    }

    func test_parsePaneSubscriptionMetadata_includesRetainedAgentState() throws {
        let json = #"{"version":1,"provider":"codex","state":"idle"}"#
        let metadata = try XCTUnwrap(parse(
            "@5\t%12\t1\t0\t1\t80\t24\tcodex\tCodex\teditor\tremote.example.com\t/home/user/src\t\(json)"
        ))

        XCTAssertEqual(metadata.currentPath, "/home/user/src")
        XCTAssertEqual(metadata.agentStateJSON, json)
    }

    func test_controllerSubscriptionReplaysAgentStateBeforeWindowHydration() {
        let controller = makeController()
        enterTmuxMode(controller)
        controller.ingest(Array("%session-changed $0 main\r\n".utf8))
        let json = #"{"version":1,"provider":"claude","state":"working"}"#
        var received: [(PaneId, String)] = []
        controller.paneAgentStateObserver = { received.append(($0, $1)) }

        controller.ingest(Array(
            "%subscription-changed tessera-pane-meta $0 @5 0 %12 : @5\\t%12\\t1\\t0\\t1\\t80\\t24\\tclaude\\tClaude\\teditor\\tremote.example.com\\t/home/user/src\\t\(json)\r\n".utf8
        ))

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, PaneId(12))
        XCTAssertEqual(received.first?.1, json)
    }

    private func parse(_ line: String) -> TmuxController.PaneSubscriptionMetadata? {
        TmuxController.parsePaneSubscriptionMetadata(
            line,
            fallbackWindowId: WindowId(99),
            fallbackPaneId: PaneId(99)
        )
    }

    private func makeController() -> TmuxController {
        let controller = TmuxController(controlPath: .sideChannel)
        controller.sendBytes = { _ in }
        return controller
    }

    private func enterTmuxMode(_ controller: TmuxController) {
        controller.ingest([0x1B, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70])
    }
}
