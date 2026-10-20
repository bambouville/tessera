import XCTest
@testable import TesseraAgentCore

/// Registration and lifecycle admission are separate actor calls. A delayed
/// live frame can resume after another root took its pane and inventory
/// recreated the delayed conversation as historical in the meantime.
final class AgentLifecycleAdmissionTests: XCTestCase {
    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let route = "live:admission:%2:agent-42"

    func testDelayedLiveFrameRestoresAdmissionAfterHistoricalRecreation() async throws {
        let fixture = await prepareOverlap(canSend: true)
        let admitted = await fixture.core.applyLifecycle(
            frame(fixture.delayed, sequence: 2, timestamp: 300),
            proof: proof(fixture.binding), expectedSourceIdentity: route)
        XCTAssertEqual(admitted, .accepted(threadID: fixture.delayed))
        let observed = await fixture.core.snapshot(for: fixture.delayed)
        let snapshot = try XCTUnwrap(observed)
        XCTAssertEqual(snapshot.binding, fixture.binding)
        XCTAssertTrue(snapshot.binding?.capabilities.contains(.send) == true)
        XCTAssertEqual(snapshot.conversationEnded, false)
        XCTAssertTrue(snapshot.summary.availability.actions,
            "a freshly admitted live route must not keep historical action availability")
        let replaced = await fixture.core.snapshot(for: fixture.intervening)
        XCTAssertNil(replaced)
        let listed = await fixture.core.listSnapshot().threads.map(\.id)
        XCTAssertEqual(listed, [fixture.delayed])

        for verification in [AgentComposerVerification.required, .userOverride] {
            for queue in [false, true] {
                let request = try XCTUnwrap(AgentTextSendRequest(threadID: fixture.delayed,
                    binding: fixture.binding, text: "next instruction", queueWhenWorking: queue,
                    composerVerification: verification))
                do {
                    let lease = try await fixture.core.acquireLease(threadID: fixture.delayed,
                        action: queue ? .queue : .send, binding: fixture.binding, textRequest: request)
                    await fixture.core.releaseLease(lease, result: .notSent)
                } catch {
                    XCTFail("fresh live frame refused \(queue ? "Queue" : "Send") (\(verification)): \(error)")
                }
            }
        }
    }

    func testHistoricalRecreationCannotUpgradeAnObserveOnlyHolder() async throws {
        let fixture = await prepareOverlap(canSend: false)
        let admitted = await fixture.core.applyLifecycle(
            frame(fixture.delayed, sequence: 2, timestamp: 300),
            proof: proof(fixture.binding), expectedSourceIdentity: route)
        XCTAssertEqual(admitted, .accepted(threadID: fixture.delayed))
        let observed = await fixture.core.snapshot(for: fixture.delayed)
        let snapshot = try XCTUnwrap(observed)
        XCTAssertEqual(snapshot.binding, fixture.binding)
        XCTAssertFalse(snapshot.binding?.capabilities.contains(.send) == true)
        XCTAssertFalse(snapshot.summary.availability.actions)
        XCTAssertEqual(snapshot.conversationEnded, false)
        for action in [AgentActionKind.send, .queue] {
            do {
                _ = try await fixture.core.acquireLease(threadID: fixture.delayed,
                    action: action, binding: fixture.binding)
                XCTFail("an observe-only route acquired \(action)")
            } catch { XCTAssertEqual(error as? AgentActionError, .unavailable) }
        }
    }

    func testOlderDelayedFrameCannotReplaceCurrentHolder() async throws {
        let fixture = await prepareOverlap(canSend: true)
        let before = await fixture.core.snapshot(for: fixture.intervening)
        let refused = await fixture.core.applyLifecycle(
            frame(fixture.delayed, sequence: 2, timestamp: 150),
            proof: proof(fixture.binding), expectedSourceIdentity: route)
        XCTAssertEqual(refused, .rejected(.staleBinding))
        let after = await fixture.core.snapshot(for: fixture.intervening)
        XCTAssertEqual(after, before)
        let stale = await fixture.core.snapshot(for: fixture.delayed)
        XCTAssertNil(stale)
        let lease = try await fixture.core.acquireLease(threadID: fixture.intervening,
            action: .send, binding: fixture.binding)
        await fixture.core.releaseLease(lease)
    }

    func testExactBindingRetirementCannotBeRevivedByALaterFrame() async throws {
        let fixture = await prepareOverlap(canSend: true)
        let admitted = await fixture.core.applyLifecycle(
            frame(fixture.delayed, sequence: 2, timestamp: 300),
            proof: proof(fixture.binding), expectedSourceIdentity: route)
        XCTAssertEqual(admitted, .accepted(threadID: fixture.delayed))
        await fixture.core.retireProjection(for: fixture.delayed)

        // A newer lifecycle frame proves this same route is still live, but
        // cannot undo an explicit availability downgrade on that route.
        let refreshed = await fixture.core.applyLifecycle(
            frame(fixture.delayed, sequence: 4, timestamp: 400),
            proof: proof(fixture.binding), expectedSourceIdentity: route)
        XCTAssertEqual(refreshed, .accepted(threadID: fixture.delayed))
        let observed = await fixture.core.snapshot(for: fixture.delayed)
        let snapshot = try XCTUnwrap(observed)
        XCTAssertEqual(snapshot.binding, fixture.binding)
        XCTAssertTrue(snapshot.binding?.capabilities.contains(.send) == true)
        XCTAssertFalse(snapshot.summary.availability.actions)
        XCTAssertEqual(snapshot.conversationEnded, false)
        for verification in [AgentComposerVerification.required, .userOverride] {
            for queue in [false, true] {
                let request = try XCTUnwrap(AgentTextSendRequest(threadID: fixture.delayed,
                    binding: fixture.binding, text: "next instruction", queueWhenWorking: queue,
                    composerVerification: verification))
                do {
                    _ = try await fixture.core.acquireLease(threadID: fixture.delayed,
                        action: queue ? .queue : .send, binding: fixture.binding, textRequest: request)
                    XCTFail("a retired exact route acquired \(queue ? "Queue" : "Send") (\(verification))")
                } catch { XCTAssertEqual(error as? AgentActionError, .unavailable) }
            }
        }
    }

    private struct Overlap {
        let core: AgentCenterRuntime
        let delayed: AgentThreadID
        let intervening: AgentThreadID
        let binding: AgentTerminalBinding
    }

    private func prepareOverlap(canSend: Bool) async -> Overlap {
        let core = AgentCenterRuntime()
        let delayed = AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "C")!
        let intervening = AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: "A")!
        let binding = AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("same-provider-process")!, transport: .sshTmux,
            tmuxSession: "work", windowID: "@1", paneID: "%2", agentPID: 42,
            capabilities: canSend ? [.observe, .send, .tmux] : [.observe, .tmux])
        await core.register(summary(delayed, actions: canSend), binding: binding)
        let initial = await core.applyLifecycle(frame(delayed, sequence: 1, timestamp: 100),
            proof: proof(binding), expectedSourceIdentity: route)
        XCTAssertEqual(initial, .accepted(threadID: delayed))

        // C's T300 frame has registered, but has not yet reached lifecycle
        // reduction. A's later-arriving T200 frame wins that actor hop first.
        await core.register(summary(delayed, actions: canSend), binding: binding)
        await core.register(summary(intervening, actions: canSend), binding: binding)
        let moved = await core.applyLifecycle(frame(intervening, sequence: 3, timestamp: 200),
            proof: proof(binding), expectedSourceIdentity: route)
        XCTAssertEqual(moved, .accepted(threadID: intervening))
        let removed = await core.snapshot(for: delayed)
        XCTAssertNil(removed)

        // This is a legitimate inventory registration: C no longer owns a
        // live route, so the atomic inventory guard must allow its history.
        await core.registerInventorySummary(summary(delayed, actions: false))
        let historical = await core.snapshot(for: delayed)
        XCTAssertNotNil(historical)
        XCTAssertNil(historical?.binding)
        XCTAssertEqual(historical?.summary.availability.actions, false)
        return .init(core: core, delayed: delayed, intervening: intervening, binding: binding)
    }

    private func summary(_ thread: AgentThreadID, actions: Bool) -> AgentThreadSummary {
        .init(id: thread, providerName: "Codex", availability: .init(content: true, status: true,
            actions: actions, spawn: false, fork: false, search: true))
    }

    private func frame(_ thread: AgentThreadID, sequence: UInt64, timestamp: UInt64) -> AgentLifecycleEnvelope {
        AgentLifecycleEnvelope(version: 9, providerID: .codex, event: .sessionStart, status: .idle,
            providerSessionID: thread.providerSessionID, agentPID: 42, transcriptRef: "b3BhcXVl",
            eventSequence: sequence, sourceTimestampNanoseconds: timestamp)!
    }

    private func proof(_ binding: AgentTerminalBinding) -> AgentLifecycleBindingProof {
        .init(hostID: hostID, binding: binding, sourceIdentity: route, processIDs: [42])
    }
}
