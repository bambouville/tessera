import XCTest
@testable import TesseraAgentCore

final class AgentCandidateReconciliationTests: XCTestCase {
    func testRepeatedDiscoveryDoesNotReorderTerminalRows() async {
        let runtime = AgentCenterRuntime()
        let first = AgentSourceCandidateID(hostID: host, providerID: .claude, sourceIdentity: "first")!
        let second = AgentSourceCandidateID(hostID: host, providerID: .codex, sourceIdentity: "second")!
        for pass in 0..<20 {
            for id in pass.isMultiple(of: 2) ? [first, second] : [second, first] {
                await runtime.registerCandidate(id, fallback: .init(status: .unavailable, location: "same host",
                    integrationAvailable: false, liveTail: "unchanged", prompt: nil, binding: binding()),
                    lastActivity: Date())
            }
            let list = await runtime.listSnapshot()
            XCTAssertEqual(list.candidates.map(\.id), [first, second])
        }
    }

    private let host = UUID()
    private let session = UUID()

    private func binding(_ transport: AgentTransportKind = .sshTmux, pid: Int? = 42,
                         generation: UInt64 = 1, session: UUID? = nil,
                         pane: String = "%2", window: String = "@1", tmux: String = "work") -> AgentTerminalBinding {
        let multiplexed = transport == .sshTmux || transport == .moshTmux
        return .init(liveSessionID: session ?? self.session, carrierGeneration: generation,
                     incarnation: AgentIncarnationToken("process-\(pid ?? 0)")!, transport: transport,
                     tmuxSession: multiplexed ? tmux : nil, windowID: multiplexed ? window : nil,
                     paneID: multiplexed ? pane : nil, agentPID: pid, capabilities: [.observe])
    }

    @discardableResult
    private func candidate(_ runtime: AgentCenterRuntime, source: String, binding: AgentTerminalBinding,
                           host: UUID? = nil, provider: AgentProviderID = .claude,
                           pids: Set<Int>? = nil, tail: String = "working") async -> AgentSourceCandidateID {
        let id = AgentSourceCandidateID(hostID: host ?? self.host, providerID: provider, sourceIdentity: source)!
        await runtime.registerCandidate(id, fallback: .init(status: .working, location: "fixture",
            integrationAvailable: false, liveTail: tail, prompt: nil, binding: binding), processIDs: pids)
        return id
    }

    func testParentAndChildShareOneFallbackOnEveryTransportAndRemovalKeepsRemainingSource() async {
        for transport in [AgentTransportKind.ssh, .sshTmux, .mosh, .moshTmux] {
            let runtime = AgentCenterRuntime()
            let parent = await candidate(runtime, source: "parent", binding: binding(transport), pids: [42, 43])
            let child = await candidate(runtime, source: "child", binding: binding(transport, pid: 43), pids: [42, 43])
            var list = await runtime.listSnapshot()
            XCTAssertEqual(list.candidates.map(\.id), [child])
            XCTAssertTrue(list.threads.isEmpty)
            await runtime.removeCandidate(child)
            list = await runtime.listSnapshot()
            XCTAssertEqual(list.candidates.map(\.id), [parent])
            await runtime.removeCandidate(parent)
            list = await runtime.listSnapshot()
            XCTAssertTrue(list.candidates.isEmpty)
        }
    }

    func testSeparateHostsProvidersSessionsGenerationsAndTmuxAddressesStayVisible() async {
        let runtime = AgentCenterRuntime()
        await candidate(runtime, source: "base", binding: binding())
        await candidate(runtime, source: "host", binding: binding(), host: UUID())
        await candidate(runtime, source: "provider", binding: binding(), provider: .codex)
        await candidate(runtime, source: "session", binding: binding(session: UUID()))
        await candidate(runtime, source: "generation", binding: binding(generation: 2))
        await candidate(runtime, source: "pane", binding: binding(pane: "%3"))
        await candidate(runtime, source: "window", binding: binding(window: "@2"))
        await candidate(runtime, source: "tmux", binding: binding(tmux: "other"))
        await candidate(runtime, source: "transport", binding: binding(.moshTmux))
        let list = await runtime.listSnapshot()
        XCTAssertEqual(list.candidates.count, 9)
    }

    func testHistoryDoesNotHideFallbackAndLiveIdentityRequiresCurrentProcessEvidence() async {
        let runtime = AgentCenterRuntime()
        let id = AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "conversation")!
        let summary = AgentThreadSummary(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false))
        await runtime.register(summary, binding: binding())
        let parent = await candidate(runtime, source: "parent", binding: binding(), pids: [42, 43])
        await candidate(runtime, source: "child", binding: binding(pid: 43), pids: [42, 43])
        var list = await runtime.listSnapshot()
        XCTAssertEqual(list.candidates.count, 1, "inventory is not a live identity")
        await runtime.promoteCandidate(parent, to: summary)
        list = await runtime.listSnapshot()
        XCTAssertEqual(list.threads.map(\.id), [id])
        XCTAssertTrue(list.candidates.isEmpty, "the child process belongs to the identified terminal")
        await candidate(runtime, source: "child", binding: binding(pid: 43), pids: [43])
        list = await runtime.listSnapshot()
        XCTAssertEqual(list.candidates.count, 1, "the old identified PID has exited")
        await candidate(runtime, source: "other-pane", binding: binding(pane: "%3"), pids: [42])
        list = await runtime.listSnapshot()
        XCTAssertEqual(list.candidates.count, 2, "identity on another pane cannot suppress this fallback")
    }

    func testTwoIdentifiedConversationsOnOneSurfaceAreNeverMerged() async {
        let runtime = AgentCenterRuntime()
        for number in 1...2 {
            let id = AgentThreadID(hostID: host, providerID: .claude, providerSessionID: "conversation-\(number)")!
            let source = await candidate(runtime, source: "source-\(number)", binding: binding())
            await runtime.promoteCandidate(source, to: .init(id: id, providerName: "Claude", availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: false)))
        }
        await candidate(runtime, source: "rediscovery", binding: binding())
        let list = await runtime.listSnapshot()
        XCTAssertEqual(list.threads.count, 2)
        XCTAssertTrue(list.candidates.isEmpty)
    }

    func testPreviewRemovesColorAndHyperlinkControlsAndDropsIncompleteEscapeTail() async {
        let runtime = AgentCenterRuntime()
        await candidate(runtime, source: "colored", binding: binding(),
                        tail: "\u{1b}(B\u{1b}=\u{1b}7\u{1b}[32mWorking\u{1b}[0m\r\n\u{1b}]8;;https://example.test\u{7}link\u{1b}]8;;\u{1b}\\\n\u{1b}[31")
        let list = await runtime.listSnapshot()
        XCTAssertEqual(list.candidates.first?.fallback.liveTail, "Working\nlink\n")
    }
}
