import Foundation
import XCTest
import TesseraSessionCore
@testable import TesseraCoreABI

final class SessionAuthorityGateABITests: XCTestCase {
    private func table() throws -> [String: String] {
        let size = tesseraSessionAuthorityGates(outputBytes: nil, outputCapacity: 0)
        XCTAssertGreaterThan(size, 0)
        var output = [UInt8](repeating: 0, count: max(0, Int(size)))
        let written = output.withUnsafeMutableBufferPointer {
            tesseraSessionAuthorityGates(outputBytes: $0.baseAddress, outputCapacity: $0.count)
        }
        XCTAssertEqual(written, size)
        return try JSONDecoder().decode([String: String].self, from: Data(output))
    }

    func testTheTableHasOneSampleOfEveryCommandKind() throws {
        let samples = SessionAuthorityGateTable.samples
        XCTAssertEqual(Set(samples.map(\.kindCode)).count, samples.count)
        XCTAssertEqual(samples.count, CoreABICommand.Kind.allCases.count)
        XCTAssertEqual(try table().count, CoreABICommand.Kind.allCases.count)
    }

    func testTheTableClassifiesTypingMutationsAndTheRest() throws {
        let table = try table()
        XCTAssertEqual(table["send_input"], "typing")
        for kind in [
            "select_tmux_window", "select_tmux_pane", "send_tmux_pane_input", "send_tmux_pane_key",
            "create_tmux_window", "close_tmux_window", "close_tmux_pane", "split_tmux_pane",
            "cycle_tmux_pane", "set_tmux_pane_zoomed", "rename_tmux_window", "move_tmux_window",
            "renumber_tmux_windows", "claim_tmux_grid_authority",
        ] {
            XCTAssertEqual(table[kind], "mutation", kind)
        }
        for kind in [
            "connect", "cancel_connect", "disconnect", "resize", "set_tmux_grid_presentation",
            "reclaim_tmux_grid_authority", "complete_tmux_grid_authority_repaint", "set_focused",
            "set_application_visibility", "request_full_repaint", "submit_challenge_response", "destroy",
        ] {
            XCTAssertEqual(table[kind], "ungated", kind)
        }
    }

    func testACommandAndItsBackendOperationShareOneGate() {
        XCTAssertEqual(SessionCommand.sendInput(Data([0x61])).authorityGate, .typing)
        XCTAssertEqual(SessionCommand.closeTmuxPane("%1").authorityGate, .mutation)
        XCTAssertEqual(SessionCommand.reclaimTmuxGridAuthority(reason: .user).authorityGate, .ungated)
    }

    func testTypingWaitsOnEveryGatedProjection() {
        let typing = SessionCommandAuthorityGate.typing
        XCTAssertNil(typing.refusal(gatesTyping: false, mutationRefusal: nil))
        XCTAssertEqual(typing.refusal(gatesTyping: true, mutationRefusal: nil), .resuming)
        XCTAssertEqual(typing.refusal(gatesTyping: true, mutationRefusal: .yielded), .yielded)
        XCTAssertEqual(typing.refusal(gatesTyping: true, mutationRefusal: .reclaiming), .reclaiming)
    }

    func testMutationsFollowOnlyTheMutationRefusal() {
        let mutation = SessionCommandAuthorityGate.mutation
        // A resume over our own grid gates typing but lets window commands through (D7).
        XCTAssertNil(mutation.refusal(gatesTyping: true, mutationRefusal: nil))
        XCTAssertEqual(mutation.refusal(gatesTyping: true, mutationRefusal: .yielded), .yielded)
        XCTAssertEqual(mutation.refusal(gatesTyping: true, mutationRefusal: .reclaiming), .reclaiming)
    }

    func testUngatedCommandsAreNeverRefused() {
        XCTAssertNil(SessionCommandAuthorityGate.ungated.refusal(gatesTyping: true, mutationRefusal: .yielded))
    }

    func testTheProjectionsGateAsThePresentationSays() {
        let peer = TmuxGridAuthoritySnapshot.peer(deviceID: "P", displayName: "iPad", generation: 1)
        let cases: [(TmuxGridAuthorityPresentation, TmuxGridAuthoritySnapshot, SessionCommandAuthorityRefusal?, SessionCommandAuthorityRefusal?)] = [
            (.none, .unknown, nil, nil),
            (.veiled(peerName: "iPad"), peer, .yielded, .yielded),
            (.reclaiming(peerName: "iPad", awaitingConnection: false), peer, .reclaiming, .reclaiming),
            (.resuming(awaitingConnection: false), .mine(generation: 1), .resuming, nil),
            (.resuming(awaitingConnection: false), peer, .yielded, .yielded),
            // A mosh link typing while the side channel reconnects (M7).
            (.resuming(awaitingConnection: true), .mine(generation: 1), nil, nil),
        ]
        for (presentation, lastKnown, typing, mutation) in cases {
            let gatesTyping = presentation.gatesTyping(lastKnown: lastKnown)
            let refusal = presentation.mutationRefusal(lastKnown: lastKnown)
            XCTAssertEqual(SessionCommandAuthorityGate.typing.refusal(gatesTyping: gatesTyping, mutationRefusal: refusal), typing, "\(presentation)")
            XCTAssertEqual(SessionCommandAuthorityGate.mutation.refusal(gatesTyping: gatesTyping, mutationRefusal: refusal), mutation, "\(presentation)")
        }
    }
}

final class TmuxAgentCommandAccessABITests: XCTestCase {
    private func classify(_ command: String) -> Int32 {
        let bytes = Array(command.utf8)
        return bytes.withUnsafeBufferPointer {
            tesseraTmuxAgentCommandIsReadOnly(commandBytes: $0.baseAddress, commandCount: $0.count)
        }
    }

    func testTheExportClassifiesLikeTheCore() {
        XCTAssertEqual(classify("capture-pane -p -t %3"), 1)
        XCTAssertEqual(classify("new-window -d -P -F '#{pane_id}'"), 0)
        XCTAssertEqual(tesseraTmuxAgentCommandIsReadOnly(commandBytes: nil, commandCount: 0), -1)
    }
}
