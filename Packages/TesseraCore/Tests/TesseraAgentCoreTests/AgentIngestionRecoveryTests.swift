import Foundation
import XCTest
@testable import TesseraAgentCore

/// Transport suspension and replacement have the same transaction boundary on
/// iOS and Android. These tests exercise the shared bytes-to-window path; they
/// do not stand in for native connection or physical network-transition tests.
final class AgentIngestionRecoveryTests: XCTestCase {
    private let transports: [AgentTransportKind] = [.ssh, .sshTmux, .mosh, .moshTmux]

    private func wire(epoch: String, request: String, lane: AgentIngestionWindowTransaction.Lane,
                      version: UInt64, order: UInt64, from: String? = nil) throws -> Data {
        let operation = lane == .bootstrap ? "bootstrap" : "updates"
        let common: [String: AgentJSONValue] = ["serviceEpoch": .string(epoch), "id": .string(request), "thread": .string("thread")]
        func frame(_ fields: [String: AgentJSONValue]) throws -> Data {
            try AgentIngestionFramer.encode(.object(common.merging(fields) { _, new in new }))
        }
        var begin: [String: AgentJSONValue] = ["kind": .string("page.begin"), "sourceIdentity": .string("codex-history:fixture"), "operation": .string(operation)]
        if let from { begin["from"] = .string(from) }
        let row: [String: AgentJSONValue] = ["kind": .string("page.record"), "recordID": .string("r\(order)"),
            "order": .number(Decimal(order)), "sourceOffset": .number(Decimal(order)), "revision": .number(1),
            "record": .object(["type": .string("assistant"), "text": .string("Recovered 🌍 \(order)")])]
        let end: [String: AgentJSONValue] = ["kind": .string("page.end"), "records": .number(1),
            "liveCursor": .string("live_\(request)"), "hasNewer": .bool(false),
            "sourceEnd": .number(Decimal(order + 1)),
            "window": .object(["lane": .string(lane.rawValue), "version": .number(Decimal(version)),
                "segmentID": .string("segment_\(request)"), "before": .string("before_\(request)"),
                "after": .string("after_\(request)"), "hasOlder": .bool(false), "hasNewer": .bool(false)])]
        var final = end
        if lane == .bootstrap { final["hasOlder"] = .bool(false) }
        return try frame(begin) + frame(row) + frame(final)
    }

    private func binding(_ transport: AgentTransportKind, session: UUID, generation: UInt64) -> AgentTerminalBinding {
        let tmux = transport == .sshTmux || transport == .moshTmux
        return .init(liveSessionID: session, carrierGeneration: generation,
            incarnation: AgentIncarnationToken("process")!, transport: transport,
            tmuxSession: tmux ? "fixture" : nil, windowID: tmux ? "@1" : nil, paneID: tmux ? "%1" : nil,
            agentPID: 42, capabilities: tmux ? [.observe, .tmux] : [.observe])
    }

    private func registered(_ transport: AgentTransportKind) async -> (AgentCenterRuntime, AgentThreadID, UUID) {
        let runtime = AgentCenterRuntime(), session = UUID()
        let id = AgentThreadID(hostID: UUID(), providerID: .codex, providerSessionID: "recovery")!
        await runtime.register(.init(id: id, providerName: "Codex", availability: .init(content: true,
            status: true, actions: false, spawn: false, fork: false, search: false)),
            binding: binding(transport, session: session, generation: 1))
        return (runtime, id, session)
    }

    func testEveryInterruptedWirePrefixKeepsCommittedWindowAndFreshBootstrapRecovers() async throws {
        for transport in transports {
            let (runtime, id, session) = await registered(transport)
            let initial = try AgentIngestionProjection.decode(wire(epoch: "original", request: "initial", lane: .bootstrap,
                version: 1, order: 10), epoch: "original", thread: "thread")
            let applied = await runtime.apply(page: initial, to: id)
            XCTAssertEqual(applied, .sourceReset)
            let previous = await runtime.snapshot(for: id)!
            let interrupted = try wire(epoch: "original", request: "interrupted", lane: .head,
                version: 2, order: 20, from: "live_initial")
            // Includes all four-byte header boundaries, all UTF-8 splits, and
            // the fully decoded records before the terminal page.end frame.
            for cut in 0..<interrupted.count {
                XCTAssertThrowsError(try AgentIngestionProjection.decode(Data(interrupted.prefix(cut)),
                    epoch: "original", thread: "thread"), "\(transport) accepted partial page at byte \(cut)")
            }
            let unchanged = await runtime.snapshot(for: id)!
            XCTAssertEqual(unchanged.messages, previous.messages)
            XCTAssertEqual(unchanged.ingestionWindow, previous.ingestionWindow)
            await runtime.replaceBinding(binding(transport, session: session, generation: 2), for: id)
            let recovered = try AgentIngestionProjection.decode(wire(epoch: "replacement", request: "recovery", lane: .bootstrap,
                version: 1, order: 30), epoch: "replacement", thread: "thread")
            let accepted = await runtime.apply(page: recovered, to: id)
            XCTAssertEqual(accepted, .sourceReset)
            let delayed = try AgentIngestionProjection.decode(interrupted, epoch: "original", thread: "thread")
            let stale = await runtime.apply(page: delayed, to: id)
            XCTAssertEqual(stale, .resyncRequired)
            let current = await runtime.snapshot(for: id)!
            XCTAssertEqual(current.messages.map(\.recordID), ["r30"])
            XCTAssertEqual(current.ingestionWindow?.epoch, "replacement")
            XCTAssertEqual(current.binding?.carrierGeneration, 2)
        }
    }

    func testRepeatedMemoryEvictionAndServiceRestartRecoverWithoutRecreatingRuntime() async throws {
        for transport in transports {
            let (runtime, id, _) = await registered(transport)
            var lastUpdate: AgentProjectionPage?
            for cycle in 0..<12 {
                await runtime.memoryWarning()
                let evictions = await runtime.takeIngestionEvictions()
                XCTAssertEqual(evictions, cycle == 0 ? [] : [id])
                let epoch = "epoch_\(cycle)"
                let bootstrap = try AgentIngestionProjection.decode(wire(epoch: epoch, request: "boot_\(cycle)", lane: .bootstrap,
                    version: 1, order: UInt64(cycle * 100)), epoch: epoch, thread: "thread")
                let accepted = await runtime.apply(page: bootstrap, to: id)
                XCTAssertEqual(accepted, .sourceReset)
                if let lastUpdate {
                    let stale = await runtime.apply(page: lastUpdate, to: id)
                    XCTAssertEqual(stale, .resyncRequired)
                }
                let update = try AgentIngestionProjection.decode(wire(epoch: epoch, request: "head_\(cycle)", lane: .head,
                    version: 2, order: UInt64(cycle * 100 + 1), from: "live_boot_\(cycle)"), epoch: epoch, thread: "thread")
                let advanced = await runtime.apply(page: update, to: id)
                XCTAssertEqual(advanced, .applied)
                let replay = await runtime.apply(page: update, to: id)
                XCTAssertEqual(replay, .duplicate)
                let snapshot = await runtime.snapshot(for: id)!
                XCTAssertEqual(snapshot.messages.map(\.recordID), ["r\(cycle * 100 + 1)"])
                XCTAssertEqual(snapshot.ingestionWindow?.version, 2)
                XCTAssertEqual(snapshot.ingestionWindow?.liveCursor, "live_head_\(cycle)")
                lastUpdate = update
            }
        }
    }

    func testNativeWireRetainsSparseOrderPrecisionAboveJavaScriptIntegerRange() throws {
        let order = UInt64.max - 1
        let bytes = try wire(epoch: "epoch", request: "large", lane: .bootstrap, version: 1, order: order)
        let page = try AgentIngestionProjection.decode(bytes, epoch: "epoch", thread: "thread")
        XCTAssertEqual(page.records.first?.sequence, order)
        XCTAssertEqual(page.records.first?.sourceOffset, order)
        XCTAssertEqual(page.ingestion?.sourceEnd, UInt64.max)
        var window = AgentIngestionWindow()
        try window.bootstrap(page.ingestion!.window!.segment(source: page.sourceIdentity, records: page.records))
        XCTAssertEqual(window.records.first?.sequence, order)
    }
}
