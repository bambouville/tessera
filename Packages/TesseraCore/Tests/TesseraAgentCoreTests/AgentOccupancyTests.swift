import XCTest
@testable import TesseraAgentCore

final class AgentOccupancyTests: XCTestCase {
    private let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func thread(_ session: String = "root") -> AgentThreadID {
        AgentThreadID(hostID: hostID, providerID: .codex, providerSessionID: session)!
    }

    private func binding(pid: Int? = 7, paneID: String? = "%2",
                         capabilities: AgentTerminalCapabilities = [.observe, .send, .tmux],
                         transport: AgentTransportKind = .sshTmux, tmuxSession: String? = "work") -> AgentTerminalBinding {
        .init(liveSessionID: sessionID, carrierGeneration: 1, incarnation: AgentIncarnationToken("process")!,
              transport: transport, tmuxSession: tmuxSession, windowID: "@1", paneID: paneID,
              agentPID: pid, capabilities: capabilities)
    }

    private func observation(panes: [AgentOccupancyObservation.Pane] = [], allPaneIDs: [String]? = nil,
                             hostID: UUID? = nil, sessionID: UUID? = nil, generation: UInt64 = 1,
                             transport: AgentTransportKind = .sshTmux, tmuxSession: String? = "work") -> AgentOccupancyObservation {
        .init(hostID: hostID ?? self.hostID, liveSessionID: sessionID ?? self.sessionID, carrierGeneration: generation,
              transport: transport, tmuxSession: tmuxSession, panes: panes, allPaneIDs: allPaneIDs)
    }

    func testCompleteAndIncompleteOccupancyTable() {
        let present = AgentOccupancyObservation.Process(pid: 7, providerID: .codex)
        let otherPID = AgentOccupancyObservation.Process(pid: 8, providerID: .codex)
        let reused = AgentOccupancyObservation.Process(pid: 7, providerID: .claude)
        let cases: [(String, AgentOccupancyObservation, Bool)] = [
            ("matching PID and provider", observation(panes: [.init(paneID: "%2", exists: true, complete: true, processes: [present])]), false),
            ("absent PID", observation(panes: [.init(paneID: "%2", exists: true, complete: true, processes: [otherPID])]), true),
            ("PID reused by another provider", observation(panes: [.init(paneID: "%2", exists: true, complete: true, processes: [reused])]), true),
            ("empty process inventory", observation(panes: [.init(paneID: "%2", exists: true, complete: true, processes: [])]), true),
            ("present PID the inventory could not classify", observation(panes: [.init(paneID: "%2", exists: true, complete: true,
                processes: [], unclassifiedPIDs: [7])]), false),
            ("only another PID unclassified", observation(panes: [.init(paneID: "%2", exists: true, complete: true,
                processes: [], unclassifiedPIDs: [8])]), true),
            ("pane definitively gone", observation(panes: [.init(paneID: "%2", exists: false, complete: false, processes: [])]), true),
            ("pane missing from complete list", observation(allPaneIDs: ["%3"]), true),
            ("pane present but process inventory unknown", observation(allPaneIDs: ["%2"]), false),
            ("incomplete pane", observation(panes: [.init(paneID: "%2", exists: true, complete: false, processes: [])]), false),
            ("incomplete pane despite complete pane list", observation(panes: [.init(paneID: "%2", exists: true, complete: false, processes: [])], allPaneIDs: ["%2"]), false),
            ("incomplete pane list", observation(panes: [.init(paneID: "%3", exists: true, complete: true, processes: [])]), false),
            ("no observations", observation(), false),
            ("conflicting duplicate observations", observation(panes: [.init(paneID: "%2", exists: false, complete: false, processes: []),
                .init(paneID: "%2", exists: true, complete: true, processes: [present])]), false),
        ]
        for (name, observation, retires) in cases {
            XCTAssertEqual(AgentOccupancyPolicy.retirements(live: [(thread(), binding())], observation: observation),
                           retires ? [thread()] : [], name)
        }
    }

    /// Older platforms send no `unclassifiedPIDs`; a missing list is empty.
    func testUnclassifiedPIDsDecodeWhenPresentAndDefaultToNone() throws {
        let legacy = #"{"paneID":"%2","exists":true,"complete":true,"processes":[{"pid":7,"providerID":{"rawValue":"codex"}}]}"#
        let current = #"{"paneID":"%2","exists":true,"complete":true,"processes":[],"unclassifiedPIDs":[7]}"#
        let decoder = JSONDecoder()
        let old = try decoder.decode(AgentOccupancyObservation.Pane.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.unclassifiedPIDs, [])
        XCTAssertEqual(old.processes, [.init(pid: 7, providerID: .codex)])
        let new = try decoder.decode(AgentOccupancyObservation.Pane.self, from: Data(current.utf8))
        XCTAssertEqual(new.unclassifiedPIDs, [7])
        let roundTrip = try decoder.decode(AgentOccupancyObservation.Pane.self, from: JSONEncoder().encode(new))
        XCTAssertEqual(roundTrip, new)
    }

    func testEveryCarrierScopeFieldMustMatch() {
        let pane = AgentOccupancyObservation.Pane(paneID: "%2", exists: false, complete: true, processes: [])
        let mismatches = [observation(panes: [pane], hostID: UUID()), observation(panes: [pane], sessionID: UUID()),
            observation(panes: [pane], generation: 2), observation(panes: [pane], transport: .moshTmux),
            observation(panes: [pane], tmuxSession: "other")]
        for observation in mismatches {
            XCTAssertEqual(AgentOccupancyPolicy.retirements(live: [(thread(), binding())], observation: observation), [])
        }
    }

    /// A pid-less binding names no process; an observe-only one that names
    /// a PID (a restored holder) leaves with that process.
    func testPidlessBindingsNeverRetireButObserveOnlyPIDsDo() {
        let missing = observation(allPaneIDs: [])
        XCTAssertEqual(AgentOccupancyPolicy.retirements(live: [(thread(), binding(pid: nil))], observation: missing), [])
        for held in [binding(capabilities: [.observe]), binding(capabilities: [.observe, .tmux])] {
            XCTAssertEqual(AgentOccupancyPolicy.retirements(live: [(thread(), held)], observation: missing), [thread()])
        }
    }

    func testNonTmuxSessionUsesTheNilPaneInventory() throws {
        let held = binding(paneID: nil, transport: .ssh, tmuxSession: nil)
        let absent = observation(panes: [.init(paneID: nil, exists: true, complete: true, processes: [])],
                                 transport: .ssh, tmuxSession: nil)
        XCTAssertEqual(AgentOccupancyPolicy.retirements(live: [(thread(), held)], observation: absent), [thread()])
        let unknown = observation(allPaneIDs: [], transport: .ssh, tmuxSession: nil)
        XCTAssertEqual(AgentOccupancyPolicy.retirements(live: [(thread(), held)], observation: unknown), [])
        XCTAssertEqual(try JSONDecoder().decode(AgentOccupancyObservation.self, from: JSONEncoder().encode(absent)), absent)
    }

    func testRootAndChildRetireTogetherAndTeardownKeepsHistory() async throws {
        let core = AgentCenterRuntime(), root = thread(), child = thread("child"), historical = thread("historical")
        let held = binding()
        for (index, id) in [root, child, historical].enumerated() {
            await core.register(.init(id: id, providerName: "Codex",
                availability: .init(content: true, status: true, actions: true, spawn: false, fork: false, search: true)), binding: held)
            if id != historical {
                let envelope = AgentLifecycleEnvelope(version: 9, providerID: .codex, event: .sessionStart, status: .working,
                    providerSessionID: id.providerSessionID, agentPID: 7, transcriptRef: "b3BhcXVl",
                    agentID: id == child ? "child-agent" : nil, eventSequence: UInt64(index + 1),
                    sourceTimestampNanoseconds: UInt64(index + 1) * 1_000)!
                _ = await core.applyLifecycle(envelope, proof: .init(hostID: hostID, binding: held, sourceIdentity: "route", processIDs: [7]),
                                              expectedSourceIdentity: "route")
            }
        }
        let record = AgentProjectionRecord(sequence: 1, recordID: "record", record: .object([
            "type": .string("assistant"), "text": .string("kept history")]))!
        _ = await core.apply(page: AgentProjectionPage(sourceIdentity: "source", records: [record], cursor: nil, hasMore: false)!, to: root)
        let lease = try await core.acquireLease(threadID: root, action: .send, binding: held,
            textRequest: AgentTextSendRequest(threadID: root, binding: held, text: "pending", queueWhenWorking: false)!)
        let before = await core.snapshot(for: root)
        XCTAssertEqual(before?.messages.first { $0.recordID == "record" }?.blocks, [.text("kept history")])
        let absent = observation(panes: [.init(paneID: "%2", exists: true, complete: true, processes: [])])
        let retired = await core.reconcileOccupancy(absent)
        XCTAssertEqual(Set(retired), [root, child])
        let after = await core.snapshot(for: root)
        XCTAssertNil(after?.binding)
        XCTAssertEqual(after?.messages.filter { $0.recordID == "record" }, before?.messages.filter { $0.recordID == "record" })
        XCTAssertEqual(after?.deliveryGeneration, (before?.deliveryGeneration ?? 0) + 1)
        XCTAssertEqual(after?.outgoingMessages?.first?.status, .unconfirmed)
        do {
            try await core.markOutgoingDispatched(lease)
            XCTFail("retired lease remained valid")
        } catch { XCTAssertEqual(error as? AgentActionError, .staleBinding) }
        let history = await core.snapshot(for: historical)
        XCTAssertEqual(history?.binding, held, "a catalog registration never held a live route")
        let again = await core.reconcileOccupancy(absent)
        XCTAssertEqual(again, [])
        let replacements = await core.takeReplacedConversations()
        XCTAssertEqual(replacements, [:])
    }

    func testOccupancyReturnsTheExactRetiredBinding() async {
        let core = AgentCenterRuntime(), id = thread(), held = binding(capabilities: [.observe])
        await core.register(.init(id: id, providerName: "Codex",
            availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: true)), binding: held)
        let frame = AgentLifecycleEnvelope(version: 9, providerID: .codex, event: .sessionStart, status: .idle,
            providerSessionID: id.providerSessionID, agentPID: 7, transcriptRef: "b3BhcXVl",
            eventSequence: 1, sourceTimestampNanoseconds: 100)!
        _ = await core.applyLifecycle(frame, proof: .init(hostID: hostID, binding: held, sourceIdentity: "route", processIDs: [7]),
                                      expectedSourceIdentity: "route")
        let retired = await core.reconcileOccupancyRetiringBindings(observation(allPaneIDs: []))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: retired), [id: held])
        let again = await core.reconcileOccupancyRetiringBindings(observation(allPaneIDs: []))
        XCTAssertTrue(again.isEmpty)
    }

    func testTimestampedClearReturnsExactBindingsAndPreservesNewerChildren() async {
        let core = AgentCenterRuntime(), root = thread(), child = thread("child"), newer = thread("newer-child")
        let rootBinding = binding(), childBinding = binding(capabilities: [.observe])
        for (id, held, timestamp) in [(root, rootBinding, UInt64(100)), (child, childBinding, 150), (newer, rootBinding, 250)] {
            await core.register(.init(id: id, providerName: "Codex",
                availability: .init(content: true, status: true, actions: false, spawn: false, fork: false, search: true)), binding: held)
            let frame = AgentLifecycleEnvelope(version: 9, providerID: .codex, event: .sessionStart, status: .idle,
                providerSessionID: id.providerSessionID, agentPID: 7, transcriptRef: "b3BhcXVl",
                agentID: id == root ? nil : "child-agent", rootAgentID: id == root ? nil : "root",
                eventSequence: timestamp, sourceTimestampNanoseconds: timestamp)!
            _ = await core.applyLifecycle(frame, proof: .init(hostID: hostID, binding: held, sourceIdentity: "route", processIDs: [7]),
                                          expectedSourceIdentity: "route")
        }
        let retired = await core.clearConversationsRetiringBindings(providerID: .codex, binding: rootBinding, timestampNanoseconds: 200)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: retired), [root: rootBinding, child: childBinding])
        let kept = await core.snapshot(for: newer)
        XCTAssertEqual(kept?.binding, rootBinding)
    }
}
