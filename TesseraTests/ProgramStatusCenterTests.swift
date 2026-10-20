import XCTest
import TmuxControl
import TmuxControlCore
@testable import Tessera

@MainActor
final class ProgramStatusCenterTests: XCTestCase {
    private let sessionID = UUID(uuidString: "0501F000-0000-4000-8000-000000000001")!

    /// A raw SSH controller whose terminal reported `bodies`, in order.
    private func rawController(_ bodies: [String]) -> TmuxController {
        let controller = TmuxController(controlPath: .inline)
        controller.programStatusEnabled = true
        controller.feedTerminal = { _ in }
        for body in bodies { controller.ingest(Array("\u{1B}]7501;\(body)\u{7}".utf8)) }
        return controller
    }

    private func rawSnapshot(_ bodies: [String]) -> ProgramStatusTerminalSnapshot? {
        rawController(bodies).programStatus.terminal(.raw)
    }

    func testNativeLiveStateOwnsTheAgentCue() {
        // A late fallback completion while the agent reports work is stale.
        XCTAssertNil(ChromeAttentionMerge.attention(
            agentNeedsInput: false, agentUnreadCompletion: true,
            program: rawSnapshot(["state=working"])
        ))
        XCTAssertEqual(ChromeAttentionMerge.attention(
            agentNeedsInput: true, agentUnreadCompletion: false,
            program: rawSnapshot(["state=blocked:kind=permission"])
        ), .needsInput(.permission))
        // Otherwise the higher-precedence verdict wins.
        XCTAssertEqual(ChromeAttentionMerge.attention(
            agentNeedsInput: false, agentUnreadCompletion: true,
            program: rawSnapshot(["state=error"])
        ), .failed)
        XCTAssertEqual(ChromeAttentionMerge.attention(
            agentNeedsInput: true, agentUnreadCompletion: false,
            program: rawSnapshot(["state=done"])
        ), .needsInput(nil))
        XCTAssertEqual(ChromeAttentionMerge.attention(
            agentNeedsInput: false, agentUnreadCompletion: true, program: nil
        ), .finished)
        XCTAssertNil(ChromeAttentionMerge.attention(
            agentNeedsInput: false, agentUnreadCompletion: false,
            program: rawSnapshot(["state=idle"])
        ))
    }

    func testGenericProgramsCountWithoutAgentCenter() {
        let center = ProgramStatusCenter()
        let agents = AgentCenterV2Coordinator()
        let controller = rawController(["state=blocked:kind=question:app=deploy"])
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)

        var counts = center.counts(agentCenter: agents)
        XCTAssertEqual(counts.needsInput, 1)
        XCTAssertEqual(counts.tone, .needsInput)
        XCTAssertEqual(ProgramStatusWords.countSummary(counts), "1 needs input")
        XCTAssertEqual(ProgramStatusWords.countSummary(counts, specificKinds: true), "1 needs an answer")
        XCTAssertEqual(center.programItems(agentCenter: agents).map(\.entry.app), ["deploy"])

        controller.ingest(Array("\u{1B}]7501;state=error\u{7}".utf8))
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)
        counts = center.counts(agentCenter: agents)
        XCTAssertEqual(ProgramStatusWords.countSummary(counts), "1 failed")
        XCTAssertEqual(counts.tone, .failed)

        center.remove(sessionID: sessionID)
        XCTAssertEqual(center.counts(agentCenter: agents).total, 0)
    }

    func testPresentingATerminalChecksItsResultOnlyWhileTheAppIsActive() {
        let center = ProgramStatusCenter()
        let controller = rawController(["state=done:app=cargo"])
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)

        center.setApplicationActive(false)
        center.setPresented(sessionID: sessionID, terminals: [.raw])
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.attention, .finished)

        center.setApplicationActive(true)
        XCTAssertNil(controller.programStatus.terminal(.raw)?.attention)

        // A blocked record is never checked, even while presented.
        controller.ingest(Array("\u{1B}]7501;state=blocked\u{7}".utf8))
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.attention, .needsInput(nil))
        // A new result while presented is checked as it arrives.
        controller.ingest(Array("\u{1B}]7501;state=done\u{7}".utf8))
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)
        XCTAssertNil(controller.programStatus.terminal(.raw)?.attention)
    }

    func testCoveredResultsStayUnreadUntilBothVisibilityGatesOpen() {
        let center = ProgramStatusCenter()
        let controller = rawController(["state=error"])
        center.setApplicationObscured(true)
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)
        center.setPresented(sessionID: sessionID, terminals: [.raw])
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.attention, .failed)

        // Foregrounding while locked or under a cover cannot check it.
        center.setApplicationActive(false)
        center.setApplicationActive(true)
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.attention, .failed)
        // Uncovering in the background also cannot check it.
        center.setApplicationActive(false)
        center.setApplicationObscured(false)
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.attention, .failed)
        center.setApplicationActive(true)
        XCTAssertNil(controller.programStatus.terminal(.raw)?.attention)

        center.setApplicationObscured(true)
        controller.ingest(Array("\u{1B}]7501;state=working\u{7}\u{1B}]7501;state=done\u{7}".utf8))
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.attention, .finished)
        center.setApplicationObscured(false)
        XCTAssertNil(controller.programStatus.terminal(.raw)?.attention)
    }

    func testIndependentSessionCoversMustAllDismissBeforeChecking() {
        let center = ProgramStatusCenter()
        let controller = rawController(["state=error"])
        let first = UUID(), second = UUID()
        center.setSessionObscured(true, sessionID: sessionID, source: first)
        center.setSessionObscured(true, sessionID: sessionID, source: second)
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)
        center.setPresented(sessionID: sessionID, terminals: [.raw])
        center.setSessionObscured(false, sessionID: sessionID, source: first)
        center.setApplicationObscured(false)
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.attention, .failed)
        center.setSessionObscured(false, sessionID: sessionID, source: second)
        XCTAssertNil(controller.programStatus.terminal(.raw)?.attention)
    }

    func testSessionCoverPresentsNothingAndChecksTheResultWhenUncovered() {
        let center = ProgramStatusCenter()
        let controller = rawController(["state=done"])
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)
        center.setPresented(sessionID: sessionID, terminals: ProgramStatusCenter.presentedTerminals(
            isActive: true, isObscured: true, tmux: controller, gridWindow: nil
        ))
        XCTAssertEqual(controller.programStatus.terminal(.raw)?.attention, .finished)
        center.setPresented(sessionID: sessionID, terminals: ProgramStatusCenter.presentedTerminals(
            isActive: true, isObscured: false, tmux: controller, gridWindow: nil
        ))
        XCTAssertNil(controller.programStatus.terminal(.raw)?.attention)
    }

    func testNativeAttentionOnAnAgentWithoutFallbackAttentionHasARow() throws {
        let center = ProgramStatusCenter()
        for body in ["state=blocked:kind=permission", "state=error", "state=done"] {
            center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: rawController([body]))
            let items = center.programItems { id, pane in
                XCTAssertEqual(id, self.sessionID)
                XCTAssertNil(pane)
                return (needsInput: false, unreadCompletion: false)
            }
            let item = try XCTUnwrap(items.first)
            XCTAssertEqual(items.count, 1)
            XCTAssertTrue(item.hasAgent)
            XCTAssertEqual(item.attention, center.terminal(sessionID: sessionID, key: .raw)?.attention)
            XCTAssertTrue(center.programItems { _, _ in (true, false) }.isEmpty)
            XCTAssertTrue(center.programItems { _, _ in (false, true) }.isEmpty)
            XCTAssertEqual(center.programItems { _, _ in nil }.first?.hasAgent, false)
        }
    }

    func testMergedStatusWordsPreferFallbackInputToNativeError() throws {
        let program = try XCTUnwrap(rawSnapshot(["state=error:app=deploy"]))
        let words = try XCTUnwrap(ChromeStatusWords(ChromeTerminalAttention(
            windowID: 1, paneID: 10, hasAgent: true,
            attention: ChromeAttentionMerge.attention(
                agentNeedsInput: true, agentUnreadCompletion: false, program: program
            ), program: program
        )))
        XCTAssertEqual(words.text, "needs input")
        XCTAssertEqual(words.tone, .needsInput)
        XCTAssertEqual(words.app, "deploy")
    }

    func testInlinePresentationWaitsForRenderingWhileSideChannelUsesFocus() {
        for path in [TmuxController.ControlPath.inline, .sideChannel] {
            let controller = TmuxController(controlPath: path)
            controller.feedTerminal = { _ in }
            controller.sendBytes = { _ in }
            controller.ingest(Array("\u{1B}P1000p%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
            let lastCommand = path == .inline ? 8 : 7
            for command in 2...lastCommand {
                controller.ingest(Array("%begin 0 \(command) 1\r\n%end 0 \(command) 1\r\n".utf8))
            }
            controller.ingest(Array("%window-add @1\r\n".utf8))
            // Drain the details query without metadata to retain a provisional pane.
            controller.ingest(Array("%begin 0 50 1\r\n%end 0 50 1\r\n".utf8))
            controller.ingest(Array("%window-pane-changed @1 %10\r\n".utf8))
            XCTAssertEqual(controller.activePaneId, PaneId(10))
            XCTAssertNil(controller.renderedPaneId)
            XCTAssertEqual(ProgramStatusCenter.presentedTerminals(
                isActive: true, tmux: controller, gridWindow: nil
            ), path == .inline ? [] : [.pane(PaneId(10))])

            let grid = TmuxController.WindowInfo(id: WindowId(1), panes: [
                .init(id: PaneId(10), isActive: true), .init(id: PaneId(11))
            ])
            XCTAssertEqual(ProgramStatusCenter.presentedTerminals(
                isActive: true, tmux: controller, gridWindow: grid
            ), [.pane(PaneId(10)), .pane(PaneId(11))])
            XCTAssertTrue(ProgramStatusCenter.presentedTerminals(
                isActive: true, isObscured: true, tmux: controller, gridWindow: grid
            ).isEmpty)
            XCTAssertTrue(ProgramStatusCenter.presentedTerminals(
                isActive: false, tmux: controller, gridWindow: grid
            ).isEmpty)
        }
    }

    func testPendingInlinePaneKeepsItsResultUnreadUntilItIsRendered() {
        let controller = TmuxController(controlPath: .inline)
        controller.programStatusEnabled = true
        controller.feedTerminal = { _ in }
        controller.sendBytes = { _ in }
        controller.ingest(Array("\u{1B}P1000p%begin 0 1 0\r\n%end 0 1 0\r\n".utf8))
        for command in 2...8 {
            controller.ingest(Array("%begin 0 \(command) 1\r\n%end 0 \(command) 1\r\n".utf8))
        }
        controller.ingest(Array("%window-add @1\r\n".utf8))
        // Drain the details query without metadata to retain a provisional pane.
        controller.ingest(Array("%begin 0 50 1\r\n%end 0 50 1\r\n".utf8))
        controller.ingest(Array("%output %10 boot\r\n".utf8))
        XCTAssertEqual(controller.renderedPaneId, PaneId(10))
        controller.ingest(Array("%window-pane-changed @1 %11\r\n".utf8))
        controller.ingest(Array("%output %11 \\033]7501;state=error\\007\r\n".utf8))
        XCTAssertEqual(controller.activePaneId, PaneId(11))
        XCTAssertNotEqual(controller.renderedPaneId, PaneId(11))

        let center = ProgramStatusCenter()
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)
        center.setPresented(sessionID: sessionID, terminals: ProgramStatusCenter.presentedTerminals(
            isActive: true, tmux: controller, gridWindow: nil
        ))
        XCTAssertEqual(controller.programStatus.terminal(.pane(PaneId(11)))?.attention, .failed)
    }

    func testOpeningARowReprovesItsTerminal() {
        let center = ProgramStatusCenter()
        let agents = AgentCenterV2Coordinator()
        var opened: [UUID] = []
        center.onOpenTerminal = { sessionID, _, _ in opened.append(sessionID) }
        let controller = rawController(["state=blocked"])
        center.publish(sessionID: sessionID, hostLabel: "devbox", tmux: controller)
        let item = try! XCTUnwrap(center.programItems(agentCenter: agents).first)

        center.open(item)
        XCTAssertEqual(opened, [sessionID])

        center.remove(sessionID: sessionID)
        center.open(item)
        XCTAssertEqual(opened, [sessionID])
    }

    func testWordsAndNames() throws {
        let entry = try XCTUnwrap(rawSnapshot(["state=working:app=cargo:progress=42"])?.primaryEntry)
        XCTAssertEqual(ProgramStatusWords.line(entry), "cargo · working · 42%")
        XCTAssertEqual(ProgramStatusWords.name(entry, windowName: "build"), "cargo")
        let titled = try XCTUnwrap(rawSnapshot(["state=blocked:kind=auth:title=ZGVwbG95IHByb2Q="])?.primaryEntry)
        XCTAssertEqual(ProgramStatusWords.name(titled, windowName: "build"), "deploy prod")
        XCTAssertEqual(ProgramStatusWords.line(titled), "sign-in needed")
        let bare = try XCTUnwrap(rawSnapshot(["state=idle"])?.primaryEntry)
        XCTAssertEqual(ProgramStatusWords.name(bare, windowName: nil), "program")
        XCTAssertEqual(ProgramStatusWords.state(bare), "ready")

        var counts = ChromeAttentionCounts()
        counts.add(.needsInput(.permission))
        counts.add(.needsInput(.permission))
        counts.add(.finished)
        XCTAssertEqual(ProgramStatusWords.countSummary(counts, specificKinds: true), "2 need approval · 1 finished")
        counts.add(.needsInput(nil))
        XCTAssertEqual(ProgramStatusWords.countSummary(counts, specificKinds: true), "3 need input · 1 finished")
    }
}
