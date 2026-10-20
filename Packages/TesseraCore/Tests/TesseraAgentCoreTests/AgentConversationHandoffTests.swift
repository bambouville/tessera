import XCTest
@testable import TesseraAgentCore

/// `/clear`, `/new` and `/resume` start another conversation in the same
/// provider process and pane. The pane then belongs to the new conversation;
/// the old one leaves the list of open agents instead of staying behind as a
/// live row that no pane will ever update again.
final class AgentConversationHandoffTests: XCTestCase {
    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let route = "live:route:%2"

    private func thread(_ session: String, _ provider: AgentProviderID = .claude) -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: provider, providerSessionID: session)!
    }

    private func binding(incarnation: String = "incarnation-1", pid: Int = 42, paneID: String = "%2",
                         capabilities: AgentTerminalCapabilities = [.observe, .send, .interrupt, .promptAnswer, .tmux]) -> AgentTerminalBinding {
        AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken(incarnation)!, transport: .sshTmux, tmuxSession: "work",
            windowID: "@1", paneID: paneID, agentPID: pid, capabilities: capabilities)
    }

    private func summary(_ id: AgentThreadID) -> AgentThreadSummary {
        AgentThreadSummary(id: id, providerName: "Claude Code",
            availability: .init(content: true, status: true, actions: true, spawn: true, fork: true, search: true))
    }

    private func proof(_ binding: AgentTerminalBinding) -> AgentLifecycleBindingProof {
        AgentLifecycleBindingProof(hostID: hostID, binding: binding, sourceIdentity: route,
            processIDs: Set([binding.agentPID].compactMap { $0 }))
    }

    private func envelope(_ id: AgentThreadID, _ event: AgentLifecycleEventKind, _ status: AgentStatus,
                          arrival: UInt64, agentID: String? = nil, rootAgentID: String? = nil) -> AgentLifecycleEnvelope {
        AgentLifecycleEnvelope(version: 9, providerID: id.providerID, event: event, status: status,
            providerSessionID: id.providerSessionID, agentPID: 42, transcriptRef: "b3BhcXVl", agentID: agentID, rootAgentID: rootAgentID,
            eventSequence: arrival, sourceTimestampNanoseconds: arrival * 1_000)!
    }

    private func listed(_ core: AgentCenterRuntime) async -> [String] {
        await core.listSnapshot().threads.map(\.id.providerSessionID).sorted()
    }

    /// Both platforms register the new conversation on the pane's binding
    /// before they forward its first frame, so two threads hold that binding
    /// when Core reduces it. Which one a dictionary scan met first decided
    /// whether the old conversation left the list; many names cover both
    /// orders.
    func testClearedConversationLeavesTheListWhateverTheRegistrationOrder() async {
        for provider in [AgentProviderID.claude, .codex] {
            for index in 0..<48 {
                let core = AgentCenterRuntime()
                let old = thread("old-\(index)", provider), new = thread("new-\(index)", provider)
                await core.register(summary(old), binding: binding())
                let working = await core.applyLifecycle(envelope(old, .userPromptSubmit, .working, arrival: 1),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(working, .accepted(threadID: old))
                let ended = await core.applyLifecycle(envelope(old, .sessionEnd, .unavailable, arrival: 2),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(ended, .accepted(threadID: old))

                await core.register(summary(new), binding: binding())
                let started = await core.applyLifecycle(envelope(new, .sessionStart, .idle, arrival: 3),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(started, .accepted(threadID: new))
                let rows = await listed(core)
                XCTAssertEqual(rows, [new.providerSessionID], "\(provider.rawValue) #\(index)")
                let retired = await core.snapshot(for: old)
                XCTAssertNotEqual(retired?.binding, binding(), "the old conversation keeps no authority over the pane")
            }
        }
    }

    /// Without a platform registration first, Core itself moves the route.
    func testClearedConversationHandsOverWithoutAPriorRegistration() async {
        let core = AgentCenterRuntime()
        let old = thread("old"), new = thread("new")
        await core.register(summary(old), binding: binding())
        _ = await core.applyLifecycle(envelope(old, .stop, .finished, arrival: 1), proof: proof(binding()), expectedSourceIdentity: route)
        let started = await core.applyLifecycle(envelope(new, .sessionStart, .idle, arrival: 2),
            proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(started, .accepted(threadID: new))
        let rows = await listed(core)
        XCTAssertEqual(rows, ["new"])
        let snapshot = await core.snapshot(for: new)
        XCTAssertEqual(snapshot?.binding, binding())
        let replaced = await core.takeReplacedConversations()
        XCTAssertEqual(replaced, [old: new])
    }

    /// A platform can keep a conversation observe-only on a process it
    /// proved (iOS restores a pane's holder that way after a connection is
    /// replaced). `/clear` in that process replaces it all the same; a
    /// conversation on another process or with no proven process stays.
    func testClearedConversationReplacesAnObserveOnlyConversationOnTheSameProcess() async {
        let core = AgentCenterRuntime()
        let old = thread("old"), new = thread("new"), other = thread("other"), unproven = thread("unproven")
        let full = binding()
        let observing = AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: 1,
            incarnation: full.incarnation, transport: .sshTmux, tmuxSession: "work",
            windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .tmux])
        let otherPane = AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("incarnation-2")!, transport: .sshTmux, tmuxSession: "work",
            windowID: "@1", paneID: "%3", agentPID: 43, capabilities: [.observe, .tmux])
        let noProcess = AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: 1,
            incarnation: full.incarnation, transport: .sshTmux, tmuxSession: "work",
            windowID: "@1", paneID: "%2", capabilities: [.observe, .tmux])
        for (id, held, pid) in [(old, observing, 42), (other, otherPane, 43), (unproven, noProcess, 42)] {
            await core.register(summary(id), binding: held)
            let applied = await core.applyLifecycle(
                AgentLifecycleEnvelope(version: 9, providerID: .claude, event: .userPromptSubmit, status: .working,
                    providerSessionID: id.providerSessionID, agentPID: pid, transcriptRef: "b3BhcXVl",
                    eventSequence: 1, sourceTimestampNanoseconds: 1_000)!,
                proof: AgentLifecycleBindingProof(hostID: hostID, binding: held, sourceIdentity: route, processIDs: [pid]),
                expectedSourceIdentity: route)
            XCTAssertEqual(applied, .accepted(threadID: id))
        }
        await core.register(summary(new), binding: full)
        let started = await core.applyLifecycle(envelope(new, .sessionStart, .idle, arrival: 2),
            proof: proof(full), expectedSourceIdentity: route)
        XCTAssertEqual(started, .accepted(threadID: new))
        let rows = await listed(core)
        XCTAssertEqual(rows, ["new", "other", "unproven"])
        let replaced = await core.takeReplacedConversations()
        XCTAssertEqual(replaced, [old: new])
    }

    /// A retained frame cannot take the process from a newer tenure.
    func testReplayedOlderFrameCannotRetireTheNewerConversation() async {
        let core = AgentCenterRuntime()
        let old = thread("old"), new = thread("new")
        let start = envelope(new, .sessionStart, .idle, arrival: 2)
        await core.register(summary(new), binding: binding())
        _ = await core.applyLifecycle(start, proof: proof(binding()), expectedSourceIdentity: route)
        // A transient discovery miss retires the route, and meanwhile the old
        // conversation takes the pane with a frame of its own.
        await core.replaceBinding(nil, for: new)
        await core.register(summary(old), binding: binding())
        _ = await core.applyLifecycle(envelope(old, .stop, .finished, arrival: 3), proof: proof(binding()), expectedSourceIdentity: route)
        let taken = await listed(core)
        XCTAssertEqual(taken, ["old"])
        _ = await core.takeReplacedConversations()
        // Rediscovery replays the pane's retained SessionStart.
        await core.register(summary(new), binding: binding())
        let replayed = await core.applyLifecycle(start, proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(replayed, .rejected(.staleBinding))
        let rows = await listed(core)
        XCTAssertEqual(rows, ["old"])
        let replaced = await core.takeReplacedConversations()
        XCTAssertEqual(replaced, [:])
    }

    /// Claude runs `/clear`'s SessionEnd and the next SessionStart hooks back
    /// to back, so the end can land second. It must not take the pane back
    /// from the conversation that now runs there.
    func testLateSessionEndOfTheClearedConversationKeepsTheNewOne() async {
        let core = AgentCenterRuntime()
        let old = thread("old"), new = thread("new")
        await core.register(summary(old), binding: binding())
        _ = await core.applyLifecycle(envelope(old, .stop, .finished, arrival: 1), proof: proof(binding()), expectedSourceIdentity: route)
        await core.register(summary(new), binding: binding())
        _ = await core.applyLifecycle(envelope(new, .sessionStart, .idle, arrival: 2), proof: proof(binding()), expectedSourceIdentity: route)
        let first = await core.takeReplacedConversations()
        XCTAssertEqual(first, [old: new])
        await core.register(summary(old), binding: binding())
        let ended = await core.applyLifecycle(envelope(old, .sessionEnd, .unavailable, arrival: 3),
            proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(ended, .rejected(.staleBinding))
        let rows = await listed(core)
        XCTAssertEqual(rows, ["new"])
        let dropped = await core.snapshot(for: old)
        XCTAssertNil(dropped, "registered only for its late frame, it leaves again")
        let second = await core.takeReplacedConversations()
        XCTAssertEqual(second, [old: new])
        let again = await core.takeReplacedConversations()
        XCTAssertEqual(again, [:])
        // Its end still applies while it holds the pane.
        let own = await core.applyLifecycle(envelope(new, .sessionEnd, .unavailable, arrival: 4),
            proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(own, .accepted(threadID: new))
    }

    /// A Codex child agent reports under its own thread in its root's
    /// process. Neither conversation replaces the other.
    func testChildAgentThreadRunsBesideItsRoot() async {
        let core = AgentCenterRuntime()
        let root = thread("root", .codex), child = thread("child", .codex)
        await core.register(summary(root), binding: binding())
        _ = await core.applyLifecycle(envelope(root, .userPromptSubmit, .working, arrival: 1),
            proof: proof(binding()), expectedSourceIdentity: route)
        await core.register(summary(child), binding: binding())
        let asked = await core.applyLifecycle(
            AgentLifecycleEnvelope(version: 9, providerID: .codex, event: .permissionRequest, status: .waitingForInput,
                providerSessionID: "child", agentPID: 42, transcriptRef: "b3BhcXVl", agentID: "child-agent",
                eventSequence: 2, sourceTimestampNanoseconds: 2_000)!,
            proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(asked, .accepted(threadID: child))
        let both = await listed(core)
        XCTAssertEqual(both, ["child", "root"])
        _ = await core.applyLifecycle(envelope(root, .postToolUse, .working, arrival: 3),
            proof: proof(binding()), expectedSourceIdentity: route)
        let still = await listed(core)
        XCTAssertEqual(still, ["child", "root"])
        let replaced = await core.takeReplacedConversations()
        XCTAssertEqual(replaced, [:])
    }

    /// Claude reports its subagents' frames under the root's own session.
    /// Such a frame on a root conversation leaves it a root, so `/clear`
    /// still replaces it, and its late SessionEnd still cannot take the
    /// pane back.
    func testSubagentFrameLeavesAClaudeRootReplaceable() async {
        for lateEnd in [false, true] {
            let core = AgentCenterRuntime()
            let old = thread("old"), new = thread("new")
            await core.register(summary(old), binding: binding())
            _ = await core.applyLifecycle(envelope(old, .userPromptSubmit, .working, arrival: 1),
                proof: proof(binding()), expectedSourceIdentity: route)
            let asked = await core.applyLifecycle(envelope(old, .permissionRequest, .waitingForInput, arrival: 2, agentID: "subagent"),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(asked, .accepted(threadID: old))
            if !lateEnd {
                _ = await core.applyLifecycle(envelope(old, .sessionEnd, .unavailable, arrival: 3),
                    proof: proof(binding()), expectedSourceIdentity: route)
            }
            await core.register(summary(new), binding: binding())
            let started = await core.applyLifecycle(envelope(new, .sessionStart, .idle, arrival: 4),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(started, .accepted(threadID: new))
            let rows = await listed(core)
            XCTAssertEqual(rows, ["new"], "late end: \(lateEnd)")
            let replaced = await core.takeReplacedConversations()
            XCTAssertEqual(replaced, [old: new], "late end: \(lateEnd)")
            if lateEnd {
                await core.register(summary(old), binding: binding())
                let ended = await core.applyLifecycle(envelope(old, .sessionEnd, .unavailable, arrival: 5),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(ended, .rejected(.staleBinding))
                let after = await listed(core)
                XCTAssertEqual(after, ["new"])
            }
        }
    }

    /// After a relaunch or reconnect a Claude root can first be seen through
    /// a subagent's permission frame, which carries the root's own session.
    /// It is still the root: `/clear` replaces it in either frame order.
    func testClaudeRootFirstSeenThroughASubagentFrameIsReplacedByClear() async {
        for event in [AgentLifecycleEventKind.permissionRequest, .notification] {
            let core = AgentCenterRuntime()
            let old = thread("old"), new = thread("new")
            await core.register(summary(old), binding: binding())
            let asked = await core.applyLifecycle(envelope(old, event, .waitingForInput, arrival: 1, agentID: "subagent"),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(asked, .accepted(threadID: old))
            await core.register(summary(new), binding: binding())
            _ = await core.applyLifecycle(envelope(new, .sessionStart, .idle, arrival: 3),
                proof: proof(binding()), expectedSourceIdentity: route)
            let rows = await listed(core)
            XCTAssertEqual(rows, ["new"], "\(event)")
            await core.register(summary(old), binding: binding())
            let ended = await core.applyLifecycle(envelope(old, .sessionEnd, .unavailable, arrival: 2),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(ended, .rejected(.staleBinding), "\(event)")
            let after = await listed(core)
            XCTAssertEqual(after, ["new"], "\(event)")
            let replaced = await core.takeReplacedConversations()
            XCTAssertEqual(replaced, [old: new], "\(event)")
        }
    }

    /// The hook reports nothing of a Codex child after its permission frame,
    /// so its root's end is its end too.
    func testCodexChildAgentsEndWithTheirRoot() async {
        for end in [AgentLifecycleEventKind.stop, .stopFailure, .wrapperExit] {
            let core = AgentCenterRuntime()
            let root = thread("root", .codex), child = thread("child", .codex)
            await core.register(summary(root), binding: binding())
            _ = await core.applyLifecycle(envelope(root, .userPromptSubmit, .working, arrival: 1),
                proof: proof(binding()), expectedSourceIdentity: route)
            await core.register(summary(child), binding: binding())
            _ = await core.applyLifecycle(envelope(child, .permissionRequest, .waitingForInput, arrival: 2, agentID: "child-agent"),
                proof: proof(binding()), expectedSourceIdentity: route)
            _ = await core.applyLifecycle(envelope(root, .postToolUse, .working, arrival: 3),
                proof: proof(binding()), expectedSourceIdentity: route)
            let working = await listed(core)
            XCTAssertEqual(working, ["child", "root"], "\(end)")
            _ = await core.applyLifecycle(envelope(root, end, end == .stop ? .finished : .unavailable, arrival: 4),
                proof: proof(binding()), expectedSourceIdentity: route)
            let rows = await listed(core)
            XCTAssertEqual(rows, ["root"], "\(end)")
            let replaced = await core.takeReplacedConversations()
            XCTAssertEqual(replaced, [child: root], "\(end)")
        }
    }

    /// A reader that asks after the platform took the replacements, or after
    /// `/clear` twice, still finds the conversation that holds the pane.
    func testReplacedConversationNamesItsSuccessorAfterItWasTaken() async {
        let core = AgentCenterRuntime()
        let first = thread("first"), second = thread("second"), third = thread("third")
        for (arrival, id) in [first, second, third].enumerated() {
            await core.register(summary(id), binding: binding())
            _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: UInt64(arrival + 1)),
                proof: proof(binding()), expectedSourceIdentity: route)
            _ = await core.takeReplacedConversations()
        }
        let fromFirst = await core.conversationReplacing(first)
        XCTAssertEqual(fromFirst, third)
        let fromSecond = await core.conversationReplacing(second)
        XCTAssertEqual(fromSecond, third)
        let held = await core.conversationReplacing(third)
        XCTAssertNil(held)
        // `/resume` back to the first: it holds the pane again.
        await core.register(summary(first), binding: binding())
        _ = await core.applyLifecycle(envelope(first, .sessionStart, .idle, arrival: 9),
            proof: proof(binding()), expectedSourceIdentity: route)
        let resumed = await core.conversationReplacing(first)
        XCTAssertNil(resumed)
        let fromThird = await core.conversationReplacing(third)
        XCTAssertEqual(fromThird, first)
    }

    /// A Codex thread seen through a child agent's frame runs beside its
    /// root, until a frame of its own shows it is a root after all.
    func testChildThreadBecomesARootOnItsOwnFrame() async {
        let core = AgentCenterRuntime()
        let root = thread("root", .codex), child = thread("child", .codex)
        await core.register(summary(root), binding: binding())
        _ = await core.applyLifecycle(envelope(root, .userPromptSubmit, .working, arrival: 1),
            proof: proof(binding()), expectedSourceIdentity: route)
        await core.register(summary(child), binding: binding())
        _ = await core.applyLifecycle(envelope(child, .permissionRequest, .waitingForInput, arrival: 2, agentID: "child-agent"),
            proof: proof(binding()), expectedSourceIdentity: route)
        let both = await listed(core)
        XCTAssertEqual(both, ["child", "root"])
        _ = await core.applyLifecycle(envelope(child, .userPromptSubmit, .working, arrival: 3),
            proof: proof(binding()), expectedSourceIdentity: route)
        let rows = await listed(core)
        XCTAssertEqual(rows, ["child"])
        let replaced = await core.takeReplacedConversations()
        XCTAssertEqual(replaced, [root: child])
    }

    /// Codex `/new` ends the conversation and the child agents it spawned.
    /// Their threads leave with it; the new conversation's own children,
    /// which arrive later, stay beside it.
    func testChildAgentsLeaveWithTheConversationTheyBelongedTo() async {
        for registeredFirst in [true, false] {
            let core = AgentCenterRuntime()
            let old = thread("old", .codex), child = thread("child", .codex)
            let new = thread("new", .codex), newChild = thread("new-child", .codex)
            await core.register(summary(old), binding: binding())
            _ = await core.applyLifecycle(envelope(old, .userPromptSubmit, .working, arrival: 1),
                proof: proof(binding()), expectedSourceIdentity: route)
            await core.register(summary(child), binding: binding())
            _ = await core.applyLifecycle(envelope(child, .permissionRequest, .waitingForInput, arrival: 2, agentID: "child-agent"),
                proof: proof(binding()), expectedSourceIdentity: route)
            if registeredFirst { await core.register(summary(new), binding: binding()) }
            _ = await core.applyLifecycle(envelope(new, .sessionStart, .idle, arrival: 3),
                proof: proof(binding()), expectedSourceIdentity: route)
            let rows = await listed(core)
            XCTAssertEqual(rows, ["new"], "registered first: \(registeredFirst)")
            let replaced = await core.takeReplacedConversations()
            XCTAssertEqual(replaced, [old: new, child: new], "registered first: \(registeredFirst)")

            await core.register(summary(newChild), binding: binding())
            _ = await core.applyLifecycle(envelope(newChild, .permissionRequest, .waitingForInput, arrival: 4, agentID: "new-agent"),
                proof: proof(binding()), expectedSourceIdentity: route)
            _ = await core.applyLifecycle(envelope(new, .postToolUse, .working, arrival: 5),
                proof: proof(binding()), expectedSourceIdentity: route)
            let both = await listed(core)
            XCTAssertEqual(both, ["new", "new-child"], "registered first: \(registeredFirst)")
            let none = await core.takeReplacedConversations()
            XCTAssertEqual(none, [:], "registered first: \(registeredFirst)")
        }
    }

    /// Another pane's conversation shares nothing with this one.
    func testConversationOnAnotherPaneStaysListed() async {
        let core = AgentCenterRuntime()
        let other = thread("other"), new = thread("new")
        let otherBinding = AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("incarnation-2")!, transport: .sshTmux, tmuxSession: "work",
            windowID: "@1", paneID: "%3", agentPID: 43,
            capabilities: [.observe, .send, .interrupt, .promptAnswer, .tmux])
        await core.register(summary(other), binding: otherBinding)
        _ = await core.applyLifecycle(envelope(other, .stop, .finished, arrival: 1).withPID(43),
            proof: AgentLifecycleBindingProof(hostID: hostID, binding: otherBinding, sourceIdentity: "live:route:%3", processIDs: [43]),
            expectedSourceIdentity: "live:route:%3")
        await core.register(summary(new), binding: binding())
        _ = await core.applyLifecycle(envelope(new, .sessionStart, .idle, arrival: 2), proof: proof(binding()), expectedSourceIdentity: route)
        let rows = await listed(core)
        XCTAssertEqual(rows, ["new", "other"])
    }

    /// An observe-only binding proves no process, only the pane. A frame for
    /// one conversation there (say `codex exec` run from inside Claude's
    /// pane) says nothing about another conversation on that pane.
    func testUnprovenPaneKeepsItsOtherConversation() async {
        let core = AgentCenterRuntime()
        let observed = AgentTerminalBinding(liveSessionID: sessionID, carrierGeneration: 1,
            incarnation: AgentIncarnationToken("incarnation-1")!, transport: .sshTmux, tmuxSession: "work",
            windowID: "@1", paneID: "%2", agentPID: nil, capabilities: [.observe])
        let unproven = AgentLifecycleBindingProof(hostID: hostID, binding: observed, sourceIdentity: route, processIDs: [])
        for (arrival, id) in [thread("outer", .claude), thread("inner", .codex)].enumerated() {
            await core.register(summary(id), binding: observed)
            let accepted = await core.applyLifecycle(
                AgentLifecycleEnvelope(version: 9, providerID: id.providerID, event: .userPromptSubmit, status: .working,
                    providerSessionID: id.providerSessionID, agentPID: nil, transcriptRef: "b3BhcXVl",
                    eventSequence: UInt64(arrival + 1), sourceTimestampNanoseconds: UInt64(arrival + 1) * 1_000)!,
                proof: unproven, expectedSourceIdentity: route)
            XCTAssertEqual(accepted, .accepted(threadID: id))
        }
        let rows = await listed(core)
        XCTAssertEqual(rows, ["inner", "outer"])
    }

    func testFieldExitWithoutAnAcceptedEndIsRetiredByOccupancy() async {
        let core = AgentCenterRuntime()
        let old = thread("3f3a2313"), new = thread("b0ed9d7d")
        let oldBinding = binding(pid: 95076, paneID: "%75")
        let newBinding = binding(incarnation: "process-2", pid: 2, paneID: "%75")
        for (id, held, arrival) in [(old, oldBinding, UInt64(1)), (new, newBinding, 2)] {
            await core.register(summary(id), binding: held)
            let result = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: arrival).withPID(held.agentPID!),
                proof: proof(held), expectedSourceIdentity: route)
            XCTAssertEqual(result, .accepted(threadID: id))
        }
        let before = await listed(core)
        XCTAssertEqual(before, ["3f3a2313", "b0ed9d7d"])
        let retired = await core.reconcileOccupancy(.init(hostID: hostID, liveSessionID: sessionID,
            carrierGeneration: 1, transport: .sshTmux, tmuxSession: "work",
            panes: [.init(paneID: "%75", exists: true, complete: true, processes: [.init(pid: 2, providerID: .claude)])]))
        XCTAssertEqual(retired, [old])
        let after = await listed(core)
        XCTAssertEqual(after, ["b0ed9d7d"])
        let oldSnapshot = await core.snapshot(for: old)
        XCTAssertNotNil(oldSnapshot)
        XCTAssertNil(oldSnapshot?.binding)
        let replacements = await core.takeReplacedConversations()
        XCTAssertEqual(replacements, [:])
    }

    func testEndedConversationRevokesMutationsButKeepsTerminalNavigation() async throws {
        for end in [AgentLifecycleEventKind.sessionEnd, .wrapperExit] {
            let core = AgentCenterRuntime(), id = thread("ended")
            await core.register(summary(id), binding: binding())
            _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 1),
                proof: proof(binding()), expectedSourceIdentity: route)
            let pending = try await core.acquireLease(threadID: id, action: .send, binding: binding(),
                textRequest: AgentTextSendRequest(threadID: id, binding: binding(), text: "in flight", queueWhenWorking: false)!)
            _ = await core.applyLifecycle(envelope(id, end, .unavailable, arrival: 2),
                proof: proof(binding()), expectedSourceIdentity: route)
            for action in [AgentActionKind.send, .queue, .interrupt, .answerPrompt, .spawn, .fork] {
                do {
                    _ = try await core.acquireLease(threadID: id, action: action, binding: binding())
                    XCTFail("\(action) after \(end)")
                } catch { XCTAssertEqual(error as? AgentActionError, .unavailable) }
            }
            let snapshot = await core.snapshot(for: id)
            XCTAssertEqual(snapshot?.outgoingMessages?.first?.id, pending.token)
            XCTAssertEqual(snapshot?.outgoingMessages?.first?.status, .unconfirmed)
            let rows = await listed(core)
            XCTAssertEqual(rows, ["ended"])
            let opened = try await core.acquireLease(threadID: id, action: .openTerminal, binding: binding())
            await core.releaseLease(opened, result: .verified)
            // A neutral subagent hook cannot reopen the root conversation.
            _ = await core.applyLifecycle(envelope(id, .subagentStart, .working, arrival: 3, agentID: "child"),
                proof: proof(binding()), expectedSourceIdentity: route)
            do {
                _ = try await core.acquireLease(threadID: id, action: .send, binding: binding())
                XCTFail("neutral subagent frame reopened an ended root")
            } catch { XCTAssertEqual(error as? AgentActionError, .unavailable) }
            _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 4),
                proof: proof(binding()), expectedSourceIdentity: route)
            _ = try await core.acquireLease(threadID: id, action: .send, binding: binding())
        }
    }

    func testClearingAProvedCodexRootRetiresItsChildrenOnlyOnThatProcess() async {
        let core = AgentCenterRuntime()
        let root = thread("root", .codex), child = thread("child", .codex)
        let otherProvider = thread("claude"), otherPID = thread("other", .codex)
        let held = binding(pid: 7)
        let other = binding(incarnation: "other", pid: 8, paneID: "%3")
        for (id, routeBinding, agentID) in [(root, held, nil), (child, held, "child-agent"),
                                          (otherProvider, binding(pid: 9), nil), (otherPID, other, nil)] as [(AgentThreadID, AgentTerminalBinding, String?)] {
            await core.register(summary(id), binding: routeBinding)
            _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 1, agentID: agentID).withPID(routeBinding.agentPID!),
                proof: proof(routeBinding), expectedSourceIdentity: route)
        }
        let retired = await core.clearConversations(providerID: .codex, binding: held)
        XCTAssertEqual(Set(retired), [root, child])
        let rows = await listed(core)
        XCTAssertEqual(rows, ["claude", "other"])
        for id in [root, child] {
            let snapshot = await core.snapshot(for: id)
            XCTAssertNotNil(snapshot)
            XCTAssertNil(snapshot?.binding)
        }
        let again = await core.clearConversations(providerID: .codex, binding: held)
        XCTAssertEqual(again, [])
        let replacements = await core.takeReplacedConversations()
        XCTAssertEqual(replacements, [:])
    }

    func testReplacementFencesRejectLateNonEndFramesAcrossSeveralHandoffs() async {
        let core = AgentCenterRuntime(), a = thread("A"), b = thread("B"), c = thread("C")
        for (index, id) in [a, b, c].enumerated() {
            await core.register(summary(id), binding: binding())
            _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: UInt64(index + 1)),
                proof: proof(binding()), expectedSourceIdentity: route)
        }
        for (id, timestamp) in [(a, UInt64(2_000)), (b, 3_000)] {
            for event in [AgentLifecycleEventKind.sessionStart, .stop, .notification, .permissionRequest] {
                await core.register(summary(id), binding: binding())
                let result = await core.applyLifecycle(envelope(id, event, .working, arrival: 100).withTimestamp(timestamp),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(result, .rejected(.staleBinding))
                let rows = await listed(core)
                XCTAssertEqual(rows, ["C"])
                let discarded = await core.snapshot(for: id)
                XCTAssertNil(discarded)
            }
        }
    }

    func testResumedTenureRejectsAnEndFromTheSameConversationsPreviousTenure() async {
        for end in [AgentLifecycleEventKind.sessionEnd, .wrapperExit] {
            let core = AgentCenterRuntime(), a = thread("A"), b = thread("B")
            for (id, arrival) in [(a, UInt64(1)), (b, 2), (a, 3)] {
                await core.register(summary(id), binding: binding())
                let accepted = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: arrival),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(accepted, .accepted(threadID: id))
            }
            let before = await core.snapshot(for: a)
            let result = await core.applyLifecycle(envelope(a, end, .unavailable, arrival: 4).withTimestamp(1_500),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(result, .rejected(.staleBinding))
            let after = await core.snapshot(for: a)
            XCTAssertEqual(after, before)
            let rows = await listed(core)
            XCTAssertEqual(rows, ["A"])
        }
    }

    func testChildTimestampFencesAndEarlyChildrenSurviveTheirNewRootsAdmission() async {
        for registeredFirst in [false, true] {
            let core = AgentCenterRuntime(), old = thread("old", .codex), new = thread("new", .codex)
            let oldChild = thread("old-child", .codex), earlyChild = thread("early-child", .codex)
            for (id, arrival, agentID) in [(old, UInt64(1), nil), (oldChild, 2, "old-agent"), (earlyChild, 4, "new-agent")] as [(AgentThreadID, UInt64, String?)] {
                await core.register(summary(id), binding: binding())
                _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: arrival, agentID: agentID),
                    proof: proof(binding()), expectedSourceIdentity: route)
            }
            if registeredFirst { await core.register(summary(new), binding: binding()) }
            _ = await core.applyLifecycle(envelope(new, .sessionStart, .idle, arrival: 3),
                proof: proof(binding()), expectedSourceIdentity: route)
            let rows = await listed(core)
            XCTAssertEqual(rows, ["early-child", "new"])
            await core.register(summary(oldChild), binding: binding())
            let stale = await core.applyLifecycle(envelope(oldChild, .permissionRequest, .waitingForInput, arrival: 5,
                agentID: "old-agent").withTimestamp(2_500), proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(stale, .rejected(.staleBinding))
            let after = await listed(core)
            XCTAssertEqual(after, ["early-child", "new"])
            // A previously unseen old child is fenced by the current root too.
            let late = thread("late-child", .codex)
            await core.register(summary(late), binding: binding())
            let lateResult = await core.applyLifecycle(envelope(late, .permissionRequest, .waitingForInput,
                arrival: 6, agentID: "late-agent").withTimestamp(2_999), proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(lateResult, .rejected(.staleBinding))
        }
    }

    func testFramesWithoutSourceTimestampsKeepLegacyHandoffBehavior() async {
        let core = AgentCenterRuntime(), a = thread("A"), b = thread("B")
        for (id, arrival) in [(a, UInt64(1)), (b, 2), (a, 3)] {
            await core.register(summary(id), binding: binding())
            let accepted = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: arrival).withTimestamp(nil),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(accepted, .accepted(threadID: id))
        }
        let rows = await listed(core)
        XCTAssertEqual(rows, ["A"])
    }

    func testFreshClientRejectsAnOlderRootAndAcceptsANewerResume() async {
        for provider in [AgentProviderID.claude, .codex] {
            let core = AgentCenterRuntime(), a = thread("A", provider), b = thread("B", provider)
            await core.register(summary(b), binding: binding())
            _ = await core.applyLifecycle(envelope(b, .sessionStart, .idle, arrival: 1).withTimestamp(200),
                proof: proof(binding()), expectedSourceIdentity: route)
            await core.register(summary(a), binding: binding())
            let stale = await core.applyLifecycle(envelope(a, .userPromptSubmit, .working, arrival: 2).withTimestamp(100),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(stale, .rejected(.staleBinding))
            let held = await listed(core), discarded = await core.snapshot(for: a)
            XCTAssertEqual(held, ["B"])
            XCTAssertNil(discarded)
            for (id, arrival) in [(a, UInt64(3)), (b, 4), (a, 5)] {
                await core.register(summary(id), binding: binding())
                let accepted = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: arrival).withTimestamp(arrival * 100),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(accepted, .accepted(threadID: id))
            }
            let resumed = await listed(core)
            XCTAssertEqual(resumed, ["A"])
        }
    }

    /// A pane moved to another window keeps its process: the next root in
    /// it replaces the conversation it held, and a clear on the new window
    /// reaches the old binding.
    func testPaneMovedToAnotherWindowStillReplacesItsConversation() async {
        func moved(_ held: AgentTerminalBinding) -> AgentTerminalBinding {
            AgentTerminalBinding(liveSessionID: held.liveSessionID, carrierGeneration: held.carrierGeneration,
                incarnation: held.incarnation, transport: held.transport, tmuxSession: held.tmuxSession,
                windowID: "@9", paneID: held.paneID, agentPID: held.agentPID, capabilities: held.capabilities)
        }
        for provider in [AgentProviderID.claude, .codex] {
            let core = AgentCenterRuntime(), a = thread("A", provider), b = thread("B", provider)
            await core.register(summary(a), binding: binding())
            _ = await core.applyLifecycle(envelope(a, .sessionStart, .idle, arrival: 1).withTimestamp(100),
                proof: proof(binding()), expectedSourceIdentity: route)
            await core.register(summary(b), binding: moved(binding()))
            let accepted = await core.applyLifecycle(envelope(b, .sessionStart, .idle, arrival: 2).withTimestamp(200),
                proof: proof(moved(binding())), expectedSourceIdentity: route)
            XCTAssertEqual(accepted, .accepted(threadID: b))
            let held = await listed(core)
            XCTAssertEqual(held, ["B"], "\(provider)")
            let cleared = await core.clearConversations(providerID: provider, binding: binding(), timestampNanoseconds: 300)
            XCTAssertEqual(cleared, [b], "\(provider)")
        }
    }

    func testEndedConversationRejectsOlderActivityAndReopensOnANewerFrame() async throws {
        for end in [AgentLifecycleEventKind.sessionEnd, .wrapperExit] {
            let core = AgentCenterRuntime(), id = thread("A")
            await core.register(summary(id), binding: binding())
            _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 1).withTimestamp(100),
                proof: proof(binding()), expectedSourceIdentity: route)
            _ = await core.applyLifecycle(envelope(id, end, .unavailable, arrival: 2).withTimestamp(200),
                proof: proof(binding()), expectedSourceIdentity: route)
            let ended = await core.snapshot(for: id)
            for timestamp in [UInt64(150), 200] {
                let stale = await core.applyLifecycle(envelope(id, .userPromptSubmit, .working, arrival: 3).withTimestamp(timestamp),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(stale, .rejected(.staleBinding))
                let after = await core.snapshot(for: id)
                XCTAssertEqual(after, ended)
                XCTAssertEqual(after?.conversationEnded, true)
            }
            let newer = await core.applyLifecycle(envelope(id, .userPromptSubmit, .working, arrival: 4).withTimestamp(250),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(newer, .accepted(threadID: id))
            let reopened = await core.snapshot(for: id)
            XCTAssertEqual(reopened?.conversationEnded, false)
            let lease = try await core.acquireLease(threadID: id, action: .send, binding: binding())
            await core.releaseLease(lease)
        }
    }

    func testTimestampedClearRejectsReplayedAndDuplicateFramesBeforeAdoption() async {
        let core = AgentCenterRuntime(), id = thread("A", .codex)
        let start = envelope(id, .sessionStart, .idle, arrival: 1).withTimestamp(100)
        await core.register(summary(id), binding: binding())
        _ = await core.applyLifecycle(start, proof: proof(binding()), expectedSourceIdentity: route)
        let retired = await core.clearConversations(providerID: .codex, binding: binding(), timestampNanoseconds: 200)
        XCTAssertEqual(retired, [id])
        for frame in [start, envelope(id, .permissionRequest, .waitingForInput, arrival: 2).withTimestamp(150),
                      envelope(id, .userPromptSubmit, .working, arrival: 3).withTimestamp(200)] {
            await core.register(summary(id), binding: binding())
            let stale = await core.applyLifecycle(frame, proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(stale, .rejected(.staleBinding))
            let snapshot = await core.snapshot(for: id), rows = await listed(core)
            XCTAssertNil(snapshot?.binding)
            XCTAssertEqual(rows, [])
        }
        await core.register(summary(id), binding: binding())
        let resumed = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 4).withTimestamp(250),
            proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(resumed, .accepted(threadID: id))
    }

    func testTimestampedClearPreservesTenuresStartingAtOrAfterIt() async {
        for timestamp in [UInt64(200), 250] {
            let core = AgentCenterRuntime(), id = thread("new", .codex)
            await core.register(summary(id), binding: binding())
            _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 1).withTimestamp(timestamp),
                proof: proof(binding()), expectedSourceIdentity: route)
            let before = await core.snapshot(for: id)
            let retired = await core.clearConversations(providerID: .codex, binding: binding(), timestampNanoseconds: 200)
            let after = await core.snapshot(for: id)
            XCTAssertEqual(retired, [])
            XCTAssertEqual(after, before)
        }
    }

    /// A phone that catches up from retained pane state may see only the
    /// newest frame of a conversation resumed on its process, never the
    /// `/resume` that reopened it: a newer frame takes the process back.
    func testNewerFrameOfAReplacedConversationTakesItsProcessBack() async {
        for provider in [AgentProviderID.claude, .codex] {
            for event in [AgentLifecycleEventKind.permissionRequest, .postToolUse, .stop, .sessionStart] {
                let core = AgentCenterRuntime(), a = thread("A", provider), b = thread("B", provider)
                for (id, timestamp) in [(a, UInt64(100)), (b, 200)] {
                    await core.register(summary(id), binding: binding())
                    _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: timestamp).withTimestamp(timestamp),
                        proof: proof(binding()), expectedSourceIdentity: route)
                }
                await core.register(summary(a), binding: binding())
                let late = await core.applyLifecycle(envelope(a, event, .waitingForInput, arrival: 300).withTimestamp(150),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(late, .rejected(.staleBinding), "\(provider) \(event)")
                await core.register(summary(a), binding: binding())
                let resumed = await core.applyLifecycle(envelope(a, event, .waitingForInput, arrival: 400).withTimestamp(400),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(resumed, .accepted(threadID: a), "\(provider) \(event)")
                let rows = await listed(core)
                XCTAssertEqual(rows, ["A"], "\(provider) \(event)")
            }
        }
    }

    /// A clear marks its process, not just the conversations it retired:
    /// an older frame arriving later, from a conversation the clear's own
    /// predecessor had replaced or with no root registered at all, ran
    /// there before the clear.
    func testTimestampedClearFencesEveryOlderFrameOnItsProcess() async {
        for registered in [true, false] {
            let core = AgentCenterRuntime(), a = thread("A", .codex), b = thread("B", .codex), c = thread("C", .codex)
            if registered {
                for (id, timestamp) in [(a, UInt64(100)), (b, 200)] {
                    await core.register(summary(id), binding: binding())
                    _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: timestamp).withTimestamp(timestamp),
                        proof: proof(binding()), expectedSourceIdentity: route)
                }
            }
            let retired = await core.clearConversations(providerID: .codex, binding: binding(), timestampNanoseconds: 300)
            XCTAssertEqual(retired, registered ? [b] : [])
            for event in [AgentLifecycleEventKind.sessionStart, .userPromptSubmit] {
                await core.register(summary(a), binding: binding())
                let late = await core.applyLifecycle(envelope(a, event, .working, arrival: 250).withTimestamp(250),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(late, .rejected(.staleBinding), "registered=\(registered) \(event)")
                let rows = await listed(core)
                XCTAssertEqual(rows, [], "registered=\(registered) \(event)")
            }
            let elsewhere = binding(pid: 43)
            await core.register(summary(a), binding: elsewhere)
            let otherProcess = await core.applyLifecycle(envelope(a, .sessionStart, .idle, arrival: 260).withTimestamp(260).withPID(43),
                proof: proof(elsewhere), expectedSourceIdentity: route)
            XCTAssertEqual(otherProcess, .accepted(threadID: a), "registered=\(registered)")
            await core.register(summary(c), binding: binding())
            let next = await core.applyLifecycle(envelope(c, .sessionStart, .idle, arrival: 350).withTimestamp(350),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(next, .accepted(threadID: c), "registered=\(registered)")
        }
    }

    /// A resume of the live conversation keeps its ID and tenure, but an
    /// End older than that SessionStart ended an earlier run of it.
    func testSessionStartOfTheLiveConversationFencesItsEarlierEnd() async throws {
        for end in [AgentLifecycleEventKind.sessionEnd, .wrapperExit] {
            let core = AgentCenterRuntime(), a = thread("A")
            await core.register(summary(a), binding: binding())
            for timestamp in [UInt64(100), 300] {
                let accepted = await core.applyLifecycle(envelope(a, .sessionStart, .idle, arrival: timestamp).withTimestamp(timestamp),
                    proof: proof(binding()), expectedSourceIdentity: route)
                XCTAssertEqual(accepted, .accepted(threadID: a))
            }
            let before = await core.snapshot(for: a)
            let stale = await core.applyLifecycle(envelope(a, end, .unavailable, arrival: 400).withTimestamp(150),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(stale, .rejected(.staleBinding))
            let after = await core.snapshot(for: a)
            XCTAssertEqual(after, before)
            XCTAssertEqual(after?.conversationEnded, false)
            let lease = try await core.acquireLease(threadID: a, action: .send, binding: binding())
            await core.releaseLease(lease)
            let ended = await core.applyLifecycle(envelope(a, end, .unavailable, arrival: 500).withTimestamp(350),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(ended, .accepted(threadID: a))
            let snapshot = await core.snapshot(for: a)
            XCTAssertEqual(snapshot?.conversationEnded, true)
        }
    }

    /// Only root activity shows a root outlived a clear: a neutral subagent
    /// callback or an End proves no ownership of the process.
    func testNeutralCallbacksAndEndsDoNotOutliveAClear() async {
        for (event, status) in [(AgentLifecycleEventKind.subagentStart, AgentStatus.working), (.subagentStop, .working),
                                (.sessionEnd, .unavailable)] {
            let core = AgentCenterRuntime(), a = thread("A")
            await core.register(summary(a), binding: binding())
            _ = await core.applyLifecycle(envelope(a, .sessionStart, .idle, arrival: 1).withTimestamp(100),
                proof: proof(binding()), expectedSourceIdentity: route)
            let late = await core.applyLifecycle(envelope(a, event, status, arrival: 2, agentID: event == .sessionEnd ? nil : "task")
                .withTimestamp(300), proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(late, .accepted(threadID: a), "\(event)")
            let cleared = await core.clearConversations(providerID: .claude, binding: binding(), timestampNanoseconds: 200)
            XCTAssertEqual(cleared, [a], "\(event)")
        }
    }

    /// A→B→A where B's start could not be located: B's clear arrives after
    /// A's newer frames. A outlived it and keeps its route and children.
    func testDelayedClearCannotRetireARootSeenAfterIt() async throws {
        for latest in [AgentLifecycleEventKind.sessionStart, .userPromptSubmit] {
            let core = AgentCenterRuntime(), a = thread("A", .codex), child = thread("child", .codex)
            await core.register(summary(a), binding: binding())
            _ = await core.applyLifecycle(envelope(a, .sessionStart, .idle, arrival: 1).withTimestamp(100),
                proof: proof(binding()), expectedSourceIdentity: route)
            await core.register(summary(child), binding: binding())
            _ = await core.applyLifecycle(envelope(child, .sessionStart, .idle, arrival: 2, agentID: "agent").withTimestamp(120),
                proof: proof(binding()), expectedSourceIdentity: route)
            let observed = await core.applyLifecycle(envelope(a, latest, .working, arrival: 3).withTimestamp(200),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(observed, .accepted(threadID: a))
            let stale = await core.clearConversations(providerID: .codex, binding: binding(), timestampNanoseconds: 150)
            XCTAssertEqual(stale, [], "\(latest)")
            let rows = await listed(core)
            XCTAssertEqual(rows, ["A", "child"], "\(latest)")
            let lease = try await core.acquireLease(threadID: a, action: .send, binding: binding())
            await core.releaseLease(lease)
            let current = await core.clearConversations(providerID: .codex, binding: binding(), timestampNanoseconds: 250)
            XCTAssertEqual(Set(current), [a, child], "\(latest)")
        }
    }

    func testChildOfAReplacedRootCannotAcquireSendOrAnswerLeases() async throws {
        let core = AgentCenterRuntime(), a = thread("A", .codex), b = thread("B", .codex)
        let child = thread("child", .codex), currentChild = thread("current-child", .codex)
        for (id, timestamp, agentID, rootID) in [(a, UInt64(100), nil, nil),
            (child, 150, "child-agent", "A"), (b, 200, nil, nil)] as [(AgentThreadID, UInt64, String?, String?)] {
            await core.register(summary(id), binding: binding())
            let accepted = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: timestamp, agentID: agentID,
                rootAgentID: rootID), proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(accepted, .accepted(threadID: id))
        }
        await core.register(summary(child), binding: binding())
        let stale = await core.applyLifecycle(envelope(child, .permissionRequest, .waitingForInput, arrival: 300,
            agentID: "child-agent", rootAgentID: "A"), proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(stale, .rejected(.staleBinding))
        for action in [AgentActionKind.send, .answerPrompt] {
            do {
                _ = try await core.acquireLease(threadID: child, action: action, binding: binding())
                XCTFail("an obsolete child acquired \(action)")
            } catch { XCTAssertEqual(error as? AgentActionError, .unavailable) }
        }
        await core.register(summary(currentChild), binding: binding())
        let current = await core.applyLifecycle(envelope(currentChild, .permissionRequest, .waitingForInput, arrival: 350,
            agentID: "current-agent", rootAgentID: "B"), proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(current, .accepted(threadID: currentChild))
        for action in [AgentActionKind.send, .answerPrompt] {
            let lease = try await core.acquireLease(threadID: currentChild, action: action, binding: binding())
            await core.releaseLease(lease)
        }
    }

    /// Codex's hooks carry `agent_id` but no `root_agent_id`: an unnamed
    /// child acts under the root tenure it was first seen in, and loses
    /// that when another root takes the process.
    func testUnnamedChildActsOnlyUnderTheRootTenureItWasSeenIn() async throws {
        let core = AgentCenterRuntime(), root = thread("root", .codex), child = thread("child", .codex)
        let successor = thread("successor", .codex)
        for (id, timestamp, agentID) in [(root, UInt64(100), nil), (child, 150, "child-agent")] as [(AgentThreadID, UInt64, String?)] {
            await core.register(summary(id), binding: binding())
            _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: timestamp, agentID: agentID)
                .withTimestamp(timestamp), proof: proof(binding()), expectedSourceIdentity: route)
        }
        for action in [AgentActionKind.send, .answerPrompt] {
            let lease = try await core.acquireLease(threadID: child, action: action, binding: binding())
            await core.releaseLease(lease)
        }
        let navigation = try await core.acquireLease(threadID: child, action: .openTerminal, binding: binding())
        await core.releaseLease(navigation)

        await core.register(summary(successor), binding: binding())
        let replaced = await core.applyLifecycle(envelope(successor, .sessionStart, .idle, arrival: 200).withTimestamp(200),
            proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(replaced, .accepted(threadID: successor))
        for action in [AgentActionKind.send, .answerPrompt] {
            do {
                _ = try await core.acquireLease(threadID: child, action: action, binding: binding())
                XCTFail("a child of the replaced root acquired \(action)")
            } catch { XCTAssertNotNil(error as? AgentActionError) }
        }
    }

    /// A root name nothing here recognises is no evidence of another root:
    /// the child joins the live tenure. One naming the replaced root does not.
    /// Codex names no root, so an unnamed child joins the live tenure. A
    /// named one must name that root: a name this client cannot match may be
    /// a root it never saw, replaced before it connected.
    func testChildJoinsTheLiveTenureOnlyUnnamedOrNamingThatRoot() async throws {
        let core = AgentCenterRuntime(), first = thread("first", .codex), root = thread("root", .codex)
        await core.register(summary(first), binding: binding())
        _ = await core.applyLifecycle(envelope(first, .sessionStart, .idle, arrival: 1).withTimestamp(100),
            proof: proof(binding()), expectedSourceIdentity: route)
        await core.register(summary(root), binding: binding())
        let replaced = await core.applyLifecycle(envelope(root, .sessionStart, .idle, arrival: 2).withTimestamp(200),
            proof: proof(binding()), expectedSourceIdentity: route)
        XCTAssertEqual(replaced, .accepted(threadID: root))
        for (index, (name, joins)) in [(nil, true), ("root", true), ("never-seen", false), ("first", false)]
            .enumerated() as EnumeratedSequence<[(String?, Bool)]> {
            let child = thread("child-\(index)", .codex)
            await core.register(summary(child), binding: binding())
            let result = await core.applyLifecycle(envelope(child, .sessionStart, .idle, arrival: UInt64(3 + index),
                agentID: "agent-\(index)", rootAgentID: name).withTimestamp(UInt64(300 + index)),
                proof: proof(binding()), expectedSourceIdentity: route)
            XCTAssertEqual(result, joins ? .accepted(threadID: child) : .rejected(.staleBinding), "\(name ?? "unnamed")")
            if joins {
                let lease = try await core.acquireLease(threadID: child, action: .send, binding: binding())
                await core.releaseLease(lease)
            } else {
                let discarded = await core.snapshot(for: child)
                XCTAssertNil(discarded, "\(name ?? "unnamed")")
            }
        }
    }

    func testChildLeaseRequiresALiveMatchingRootTenure() async throws {
        let core = AgentCenterRuntime(), root = thread("root", .codex), child = thread("child", .codex)
        await core.register(summary(root), binding: binding())
        _ = await core.applyLifecycle(envelope(root, .sessionStart, .idle, arrival: 1).withTimestamp(100),
            proof: proof(binding()), expectedSourceIdentity: route)
        await core.register(summary(child), binding: binding())
        _ = await core.applyLifecycle(envelope(child, .sessionStart, .idle, arrival: 2, agentID: "child-agent",
            rootAgentID: "root").withTimestamp(300), proof: proof(binding()), expectedSourceIdentity: route)
        let current = try await core.acquireLease(threadID: child, action: .send, binding: binding())
        await core.releaseLease(current)
        await core.replaceBinding(nil, for: root)
        for reproveRoot in [false, true] {
            if reproveRoot {
                await core.register(summary(root), binding: binding())
                _ = await core.applyLifecycle(envelope(root, .sessionStart, .idle, arrival: 3).withTimestamp(200),
                    proof: proof(binding()), expectedSourceIdentity: route)
                let retained = await core.snapshot(for: child)
                XCTAssertEqual(retained?.binding, binding())
            }
            for action in [AgentActionKind.send, .answerPrompt] {
                do {
                    _ = try await core.acquireLease(threadID: child, action: action, binding: binding())
                    XCTFail("a child without its original live root acquired \(action)")
                } catch { XCTAssertEqual(error as? AgentActionError, .unavailable) }
            }
        }
    }

    func testLiveConversationCannotBeStolenUntilOccupancyRetiresItsOldProcess() async {
        let core = AgentCenterRuntime(), id = thread("B")
        let old = binding(), new = binding(incarnation: "process-2", pid: 43, paneID: "%3")
        await core.register(summary(id), binding: old)
        _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 1),
            proof: proof(old), expectedSourceIdentity: route)
        let before = await core.snapshot(for: id)
        let refused = await core.register(summary(id), binding: new)
        XCTAssertEqual(refused, .liveElsewhere(current: old))
        let after = await core.snapshot(for: id)
        XCTAssertEqual(after, before)
        let retired = await core.reconcileOccupancy(.init(hostID: hostID, liveSessionID: sessionID,
            carrierGeneration: 1, transport: .sshTmux, tmuxSession: "work",
            panes: [.init(paneID: "%2", exists: true, complete: true, processes: [])]))
        XCTAssertEqual(retired, [id])
        let rebound = await core.register(summary(id), binding: new)
        XCTAssertEqual(rebound, .registered)
        let accepted = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 2).withPID(43),
            proof: proof(new), expectedSourceIdentity: route)
        XCTAssertEqual(accepted, .accepted(threadID: id))
        let snapshot = await core.snapshot(for: id)
        XCTAssertEqual(snapshot?.binding, new)
        let rows = await listed(core)
        XCTAssertEqual(rows, ["B"])
        let changed = binding(incarnation: "process-2", pid: 43, paneID: "%3", capabilities: [.observe, .interrupt, .tmux])
        let reproof = await core.register(summary(id), binding: changed)
        XCTAssertEqual(reproof, .registered)
        let refreshed = await core.snapshot(for: id)
        XCTAssertEqual(refreshed?.binding, changed)
    }

    /// `claude --continue` in the pane the conversation's exited process
    /// held, or the same pane over a reconnected carrier, takes the
    /// conversation over at once: its old route is dead or unobservable.
    func testSamePaneProcessOrNewerCarrierTakesTheConversationOver() async {
        let reconnected = AgentTerminalBinding(liveSessionID: UUID(), carrierGeneration: 2,
            incarnation: AgentIncarnationToken("incarnation-1")!, transport: .sshTmux, tmuxSession: "work",
            windowID: "@1", paneID: "%2", agentPID: 42, capabilities: [.observe, .send, .interrupt, .promptAnswer, .tmux])
        for successor in [binding(incarnation: "process-2", pid: 43), reconnected] {
            let core = AgentCenterRuntime(), id = thread("B")
            await core.register(summary(id), binding: binding())
            _ = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 1),
                proof: proof(binding()), expectedSourceIdentity: route)
            let registration = await core.register(summary(id), binding: successor)
            XCTAssertEqual(registration, .registered)
            let accepted = await core.applyLifecycle(envelope(id, .sessionStart, .idle, arrival: 2).withPID(successor.agentPID!),
                proof: proof(successor), expectedSourceIdentity: route)
            XCTAssertEqual(accepted, .accepted(threadID: id))
            let snapshot = await core.snapshot(for: id)
            XCTAssertEqual(snapshot?.binding, successor)
            let rows = await listed(core)
            XCTAssertEqual(rows, ["B"])
        }
    }
}

private extension AgentLifecycleEnvelope {
    func withPID(_ pid: Int) -> AgentLifecycleEnvelope {
        AgentLifecycleEnvelope(version: version, providerID: providerID, event: event, status: status,
            providerSessionID: providerSessionID, agentPID: pid, transcriptRef: transcriptRef,
            agentID: agentID, agentType: agentType, rootAgentID: rootAgentID,
            eventSequence: eventSequence, sourceTimestampNanoseconds: sourceTimestampNanoseconds)!
    }

    func withTimestamp(_ timestamp: UInt64?) -> AgentLifecycleEnvelope {
        AgentLifecycleEnvelope(version: version, providerID: providerID, event: event, status: status,
            providerSessionID: providerSessionID, agentPID: agentPID, transcriptRef: transcriptRef,
            agentID: agentID, agentType: agentType, rootAgentID: rootAgentID,
            eventSequence: eventSequence, sourceTimestampNanoseconds: timestamp)!
    }
}
