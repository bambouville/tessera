import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

/// The Android bridge's snapshot bookkeeping (`SharedTmuxEventDecoder`)
/// restated over the Swift types, so the core is held to the contract the
/// bridge relies on. A wire-only event never needs a snapshot. A state event
/// that omits one must name the held snapshot's key; otherwise a carrying
/// event was lost and the model asks for a resync, once per elided key. A
/// decode failure forgets the held key and asks once until the stream is in
/// step again, so an answer that fails to decode cannot ask for another.
struct TmuxSnapshotStreamModel {
    struct Envelope: Decodable {
        struct Key: Decodable, Equatable, CustomStringConvertible {
            let epoch: UInt64
            let revision: UInt64
            var description: String { "\(epoch)/\(revision)" }
        }

        struct Wire: Decodable {
            let tag: UInt64
        }

        let version: Int
        let snapshot: TmuxSnapshot?
        let snapshotKey: Key?
        let platformWireCommands: [Wire]?
        let testOracleSnapshot: TmuxSnapshot?
    }

    enum Outcome: Equatable {
        /// Wire-only: its commands are delivered whatever the model holds.
        case wire
        /// A state event delivered with the snapshot it stands for.
        case current
        /// A state event delivered with a snapshot known to be stale.
        case stale(requestsResync: Bool)
    }

    /// The engine's initial snapshot until one arrives, as on Android.
    private(set) var held = TmuxRuntimeEngine().snapshot
    private(set) var heldKey: Envelope.Key?
    private var resyncRequestedFor: Envelope.Key?
    private var failureResyncArmed = true

    mutating func decode(_ envelope: Envelope) -> Outcome {
        if let snapshot = envelope.snapshot {
            held = snapshot
            heldKey = envelope.snapshotKey
            resyncRequestedFor = nil
            failureResyncArmed = true
            return envelope.platformWireCommands == nil ? .current : .wire
        }
        if envelope.platformWireCommands != nil { return .wire }
        if let key = envelope.snapshotKey, key == heldKey {
            failureResyncArmed = true
            return .current
        }
        if let key = envelope.snapshotKey, key == resyncRequestedFor {
            return .stale(requestsResync: false)
        }
        resyncRequestedFor = envelope.snapshotKey
        return .stale(requestsResync: true)
    }

    /// The bridge failed to decode this payload. Returns whether it asks.
    mutating func failed(key: Envelope.Key?) -> Bool {
        heldKey = nil
        guard failureResyncArmed else { return false }
        failureResyncArmed = false
        resyncRequestedFor = key
        return true
    }

    /// The core refused a request: the next mismatch may ask again.
    mutating func resyncRefused() {
        resyncRequestedFor = nil
        failureResyncArmed = true
    }
}

private final class SnapshotElisionTrace: @unchecked Sendable {
    var payloads: [Data] = []
    var onEvent: (() -> Void)?
}

private let receiveSnapshotElisionEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let trace = Unmanaged<SnapshotElisionTrace>.fromOpaque(context).takeUnretainedValue()
    trace.payloads.append(Data(bytes: bytes, count: count))
    if let hook = trace.onEvent {
        trace.onEvent = nil
        hook()
    }
}

/// A bridge that decodes live, inside the callback, as Android does, and can
/// lose payloads before they reach its decoder the way the JNI shim can.
private final class LiveBridge: @unchecked Sendable {
    struct Delivery {
        let envelope: TmuxSnapshotStreamModel.Envelope
        let outcome: TmuxSnapshotStreamModel.Outcome
        let snapshot: TmuxSnapshot
    }

    var model = TmuxSnapshotStreamModel()
    var handle: UnsafeMutableRawPointer?
    var deliveries: [Delivery] = []
    var resyncStatuses: [Int32] = []
    /// True drops the payload before the decoder sees it.
    var loses: (TmuxSnapshotStreamModel.Envelope) -> Bool = { _ in false }
}

private let receiveLiveBridgeEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let bridge = Unmanaged<LiveBridge>.fromOpaque(context).takeUnretainedValue()
    guard let envelope = try? JSONDecoder().decode(
        TmuxSnapshotStreamModel.Envelope.self,
        from: Data(bytes: bytes, count: count)
    ) else { return }
    guard !bridge.loses(envelope) else { return }
    let outcome = bridge.model.decode(envelope)
    bridge.deliveries.append(.init(envelope: envelope, outcome: outcome, snapshot: bridge.model.held))
    if outcome == .stale(requestsResync: true) {
        let status = tesseraTmuxRuntimeResyncSnapshot(handle: bridge.handle)
        bridge.resyncStatuses.append(status)
        if status != 0 { bridge.model.resyncRefused() }
    }
}

/// Event v3 sends the snapshot only when it changed since the last one the
/// handle queued. These tests decode the stream the way the Android bridge
/// does (keep the last snapshot, attach it to events without one) and require
/// the result to be exactly the snapshot every v2 event used to carry.
final class TmuxRuntimeSnapshotElisionABITests: XCTestCase {
    private var trace: SnapshotElisionTrace!
    private var handle: UnsafeMutableRawPointer!
    private var context: UnsafeMutableRawPointer!

    override func setUp() {
        super.setUp()
        trace = SnapshotElisionTrace()
        context = Unmanaged.passRetained(trace).toOpaque()
        handle = tesseraTmuxRuntimeCreate(
            callback: receiveSnapshotElisionEvent,
            context: context
        )
    }

    override func tearDown() {
        tesseraTmuxRuntimeDestroy(handle: handle)
        Unmanaged<SnapshotElisionTrace>.fromOpaque(context).release()
        super.tearDown()
    }

    @discardableResult
    private func feed(_ text: String) -> Int32 {
        Array(text.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeFeed(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    @discardableResult
    private func submit(_ fact: RenderFact) throws -> Int32 {
        try SharedABI.encoder.encode(fact).withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    private func queue(_ command: String) -> Int64 {
        Array(command.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeQueueCommand(
                handle: handle,
                text: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    private typealias Envelope = TmuxSnapshotStreamModel.Envelope

    private func envelopes() throws -> [Envelope] {
        try trace.payloads.map { try JSONDecoder().decode(Envelope.self, from: $0) }
    }

    /// The snapshot each delivered event stands for, as the bridge decodes it.
    /// Every state event must name the snapshot it stands for by key: an
    /// elided one the key of the last carried snapshot, so a bridge that
    /// compares keys never sees a mismatch in a lossless stream.
    private func carriedSnapshots() throws -> [TmuxSnapshot] {
        var last: TmuxSnapshot?
        var lastKey: Envelope.Key?
        return try envelopes().map { envelope in
            XCTAssertEqual(envelope.version, 3)
            let key = try XCTUnwrap(envelope.snapshotKey, "every envelope names its snapshot")
            if let snapshot = envelope.snapshot {
                XCTAssertEqual(key.revision, snapshot.revision)
                lastKey = key
            } else if envelope.platformWireCommands == nil {
                XCTAssertEqual(key, lastKey, "an elided state event names the last carried snapshot")
            }
            last = try XCTUnwrap(envelope.snapshot ?? last, "an event omitted a snapshot before any was sent")
            return last!
        }
    }

    func testOutputEventsElideTheUnchangedSnapshotAndTopologyEventsCarryIt() throws {
        var shadow = TmuxRuntimeEngine()
        var expected: [TmuxSnapshot] = []
        let lines = [
            "%session-changed $1 work\r\n",
            "%window-add @1\r\n",
            "%layout-change @1 abcd,80x24,0,0,1 abcd,80x24,0,0,1 *\r\n",
            "%session-window-changed $1 @1\r\n",
            "%output %1 hello\r\n",
            "%output %1 world\r\n",
            "%window-renamed @1 editor\r\n",
            "%output %1 again\r\n",
            "%window-add @2\r\n%output %1 same read\r\n",
            "%output %1 last\r\n",
        ]
        for line in lines {
            XCTAssertEqual(feed(line), 0, line)
            _ = shadow.feed(Array(line.utf8))
            expected.append(shadow.snapshot)
        }

        XCTAssertEqual(try carriedSnapshots(), expected)
        let carried = try envelopes().map { $0.snapshot != nil }
        XCTAssertEqual(carried, [true, true, true, true, false, false, true, false, true, false])
        // An elided event is the envelope alone, whatever the topology size.
        for (index, payload) in trace.payloads.enumerated() where !carried[index] {
            XCTAssertLessThan(payload.count, 256)
        }
    }

    /// Whether tmux named the active window is part of the snapshot, so a
    /// flip is carried even when the active id and every window stay put: a
    /// provisional `%window-add` pick later named by `%session-window-changed`
    /// or by the active-window reply must reach the bridge, not be elided as
    /// "unchanged".
    func testAnActiveWindowAuthorityFlipIsCarriedNotElided() throws {
        var shadow = TmuxRuntimeEngine()
        var expected: [TmuxSnapshot] = []
        let lines = [
            "%session-changed $1 work\r\n",
            // Capabilities first, so the reply below changes only the flag.
            "%begin 1 1 1\r\n__tessera_active_window__\t@9\t3.4\r\n%end 1 1 1\r\n",
            "%window-add @1\r\n",
            "%output %1 x\r\n",
            "%session-window-changed $1 @1\r\n",
            "%output %1 y\r\n",
            "%begin 1 2 1\r\n__tessera_windows__\t@2\t0\t%2\t\t\t0\ttwo\r\n%end 1 2 1\r\n",
            "%window-add @3\r\n",
            "%begin 1 3 1\r\n__tessera_active_window__\t@3\t3.4\r\n%end 1 3 1\r\n",
            "%output %3 z\r\n",
        ]
        for line in lines {
            XCTAssertEqual(feed(line), 0, line)
            _ = shadow.feed(Array(line.utf8))
            expected.append(shadow.snapshot)
        }

        let snapshots = try carriedSnapshots()
        XCTAssertEqual(snapshots, expected)
        XCTAssertEqual(
            snapshots.map(\.activeWindowID),
            [nil, nil, WindowId(1), WindowId(1), WindowId(1), WindowId(1), nil, WindowId(3), WindowId(3), WindowId(3)]
        )
        XCTAssertEqual(
            snapshots.map(\.isActiveWindowAuthoritative),
            [false, false, false, false, true, true, false, false, true, true]
        )
        XCTAssertEqual(
            try envelopes().map { $0.snapshot != nil },
            [true, true, true, false, true, false, true, true, true, false]
        )
        // The two promotions moved nothing but the flag and the revision.
        for (provisional, named) in [(3, 4), (7, 8)] {
            XCTAssertEqual(snapshots[named].activeWindowID, snapshots[provisional].activeWindowID)
            XCTAssertEqual(snapshots[named].windows, snapshots[provisional].windows)
            XCTAssertEqual(snapshots[named].capabilities, snapshots[provisional].capabilities)
            XCTAssertNotEqual(snapshots[named].revision, snapshots[provisional].revision)
        }
    }

    func testFactsCarryTheSnapshotOnlyWhenTheyChangeIt() throws {
        let rows = "__tessera_windows__\t@1\t0\t%1\t\t\t0\tone\r\n__tessera_windows__\t@2\t1\t%2\t\t\t0\ttwo\r\n"
        XCTAssertEqual(feed("%session-changed $1 work\r\n%begin 1 1 1\r\n\(rows)%end 1 1 1\r\n"), 0)
        XCTAssertEqual(try submit(.userInput), 0)
        XCTAssertEqual(try submit(.reorderBegan(token: 1, order: [WindowId(2), WindowId(1)])), 0)
        XCTAssertEqual(try submit(.reorderConfirmed(token: 1)), 0)

        let all = try envelopes()
        XCTAssertEqual(all.map { $0.snapshot != nil }, [true, false, true, false])
        let snapshots = try carriedSnapshots()
        XCTAssertEqual(snapshots[1], snapshots[0])
        XCTAssertEqual(snapshots[2].isReorderPending, true)
        XCTAssertEqual(snapshots[2].windows.map(\.id), [WindowId(2), WindowId(1)])
        XCTAssertEqual(snapshots[3], snapshots[2])
    }

    func testOnlyAHandlesFirstEventCarriesASnapshotWhenItIsWireOnly() throws {
        XCTAssertGreaterThan(queue("display-message -p first"), 0)
        XCTAssertGreaterThan(queue("display-message -p second"), 0)
        XCTAssertEqual(feed("%output %1 x\r\n"), 0)

        let all = try envelopes()
        XCTAssertEqual(all.map { $0.snapshot != nil }, [true, false, false])
        XCTAssertEqual(all.map { $0.platformWireCommands?.count }, [1, 1, nil])
        XCTAssertEqual(try carriedSnapshots(), Array(repeating: TmuxRuntimeEngine().snapshot, count: 3))
    }

    func testWireOnlyEventsCarryNoSnapshotEvenAfterTopologyMoved() throws {
        XCTAssertEqual(feed("%session-changed $1 work\r\n"), 0)
        XCTAssertGreaterThan(queue("display-message -p policy"), 0)
        XCTAssertEqual(feed("%window-add @3\r\n"), 0)
        XCTAssertGreaterThan(queue("display-message -p again"), 0)
        XCTAssertEqual(feed("%output %1 x\r\n"), 0)

        let all = try envelopes()
        XCTAssertEqual(all.map { $0.snapshot != nil }, [true, false, true, false, false])
        XCTAssertEqual(try carriedSnapshots().last?.windows.map(\.id), [WindowId(3)])
    }

    /// A split event carries the snapshot once, in its first envelope.
    func testAPartitionedEventCarriesItsSnapshotInTheFirstEnvelopeOnly() throws {
        let command = Array("display-message -p x".utf8)
        let replyCount = 20_000
        for _ in 0..<replyCount {
            XCTAssertGreaterThan(command.withUnsafeBytes { raw in
                tesseraTmuxRuntimeSendCommand(
                    handle: handle,
                    text: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count
                )
            }, 0)
        }
        let replies = (1...replyCount).map { "%begin 1 \($0) 1\r\nx\r\n%end 1 \($0) 1\r\n" }.joined()
        XCTAssertEqual(feed("%session-changed $1 work\r\n%window-add @1\r\n%subscription-changed tessera-authority $1 @1 0 %1 : v1 peer 7 iPad\r\n" + replies), 0)

        let all = try envelopes()
        XCTAssertGreaterThan(all.count, 1)
        let stampEdges = try trace.payloads.map { data -> [String] in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap(object["authorityStamps"] as? [String])
        }
        XCTAssertEqual(stampEdges, [["v1 peer 7 iPad"]] + Array(repeating: [], count: all.count - 1))
        XCTAssertEqual(all.map { $0.snapshot != nil }, [true] + Array(repeating: false, count: all.count - 1))
        var shadow = TmuxRuntimeEngine()
        _ = shadow.feed(Array("%session-changed $1 work\r\n%window-add @1\r\n".utf8))
        XCTAssertEqual(try carriedSnapshots().last, shadow.snapshot)
    }

    /// A transport loss drops every undelivered old-transport payload. If one
    /// of them carried the latest snapshot, the next event must carry it again.
    func testTransportLossThatDropsAQueuedSnapshotResendsIt() throws {
        XCTAssertEqual(feed("%session-changed $1 work\r\n%window-add @1\r\n"), 0)
        var lossStatus: Int32 = -1
        trace.onEvent = { [self] in
            // Queued behind this callback, with a new snapshot...
            XCTAssertEqual(feed("%window-add @2\r\n"), 0)
            // ...and dropped undelivered by the loss.
            lossStatus = (try? submit(.transportLost)) ?? -1
        }
        XCTAssertEqual(try submit(.userInput), 0)
        XCTAssertEqual(lossStatus, 0)

        var shadow = TmuxRuntimeEngine()
        _ = shadow.feed(Array("%session-changed $1 work\r\n%window-add @1\r\n%window-add @2\r\n".utf8))
        let all = try envelopes()
        XCTAssertEqual(all.count, 3, "the queued @2 event is dropped; the loss event is delivered")
        XCTAssertEqual(all.map { $0.snapshot != nil }, [true, false, true])
        XCTAssertEqual(try carriedSnapshots().last, shadow.snapshot)
    }

    /// Transport reset preserves the projection and changes its snapshot epoch.
    func testTransportResetPreservesProjectionAndSendsTheNextChangedSnapshot() throws {
        XCTAssertGreaterThan(projectRuntimeAuthority(handle: handle, authority: .mine(generation: 5)).result, 0)
        XCTAssertEqual(try submit(.userInput), 0)
        XCTAssertEqual(try submit(.transportLost), 0)
        XCTAssertGreaterThan(projectRuntimeAuthority(handle: handle, authority: .mine(generation: 9)).result, 0)
        XCTAssertEqual(try submit(.userInput), 0)

        let snapshots = try carriedSnapshots()
        XCTAssertEqual(snapshots.map(\.revision), [1, 1, 3])
        XCTAssertEqual(snapshots.map(\.authority), [.mine(generation: 5), .mine(generation: 5), .mine(generation: 9)])
    }

    func testAuthorityStampEdgesAreRawOrderedDedupedPerReadBoundedAndSessionFiltered() throws {
        XCTAssertEqual(feed("%session-changed $1 work\r\n"), 0)
        let raw = "v1 peer 7 iPad"
        func stamp(_ session: Int, _ value: String) -> String {
            "%subscription-changed tessera-authority $\(session) @1 0 %1 : \(value)\r\n"
        }
        XCTAssertEqual(feed(stamp(1, raw) + stamp(1, raw) + stamp(2, "v1 other 8 Mac") + stamp(1, "invalid raw")), 0)
        func edges(_ data: Data) throws -> [String] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(object["foreignAuthorityStampArrived"])
            XCTAssertNil(object["ownAuthorityStampGeneration"])
            return try XCTUnwrap(object["authorityStamps"] as? [String])
        }
        XCTAssertEqual(try edges(trace.payloads.last!), [raw, "invalid raw"])
        XCTAssertEqual(try carriedSnapshots().last?.authority, .unknown, "no runtime classification")
        // A later read's unchanged value is the session's to dedupe.
        XCTAssertEqual(feed(stamp(1, "invalid raw") + stamp(1, "invalid raw")), 0)
        XCTAssertEqual(try edges(trace.payloads.last!), ["invalid raw"])
        // No value can outgrow the authority session's request bound.
        let name = String(repeating: "N", count: 70_000)
        XCTAssertEqual(feed(stamp(1, "v1 peer 9 \(name)") + stamp(1, String(repeating: "x", count: 70_000))), 0)
        XCTAssertEqual(try edges(trace.payloads.last!), ["v1 peer 9 " + name.prefix(64), ""])
        XCTAssertEqual(try submit(.transportLost), 0)
        XCTAssertEqual(feed(stamp(1, "invalid raw")), 0)
        XCTAssertEqual(try edges(trace.payloads.last!), ["invalid raw"])
        for _ in 0..<1_000 {
            XCTAssertEqual(feed("%output %1 x\r\n"), 0)
            XCTAssertEqual(try edges(trace.payloads.last!), [])
        }
    }

    // MARK: - Resync

    private func makeLiveBridge() -> (LiveBridge, UnsafeMutableRawPointer, () -> Void) {
        let bridge = LiveBridge()
        let context = Unmanaged.passRetained(bridge).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveLiveBridgeEvent,
            context: context
        )
        bridge.handle = handle
        tesseraTmuxRuntimeEmbedTestOracleSnapshot(handle: handle)
        return (bridge, handle, {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<LiveBridge>.fromOpaque(context).release()
        })
    }

    private func feed(_ text: String, into handle: UnsafeMutableRawPointer) -> Int32 {
        Array(text.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeFeed(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    private func queue(_ command: String, into handle: UnsafeMutableRawPointer) -> Int64 {
        Array(command.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeQueueCommand(
                handle: handle,
                text: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    /// A resync answers with a bare state event that carries the current
    /// snapshot under a new epoch, and later elided events name that key.
    func testAResyncAnswersWithTheCurrentSnapshotUnderANewEpoch() throws {
        XCTAssertEqual(feed("%session-changed $1 work\r\n%window-add @1\r\n"), 0)
        XCTAssertEqual(tesseraTmuxRuntimeResyncSnapshot(handle: handle), 0)
        XCTAssertEqual(feed("%output %1 x\r\n"), 0)

        let all = try envelopes()
        XCTAssertEqual(all.map { $0.snapshot != nil }, [true, true, false])
        XCTAssertEqual(all.map { $0.snapshotKey?.epoch }, [0, 1, 1])
        XCTAssertEqual(all[1].snapshotKey?.revision, all[0].snapshotKey?.revision)
        XCTAssertEqual(all[1].snapshot, all[0].snapshot)
        XCTAssertNil(all[0].testOracleSnapshot, "production envelopes never carry the oracle")

        struct Edges: Decodable {
            let renderEffects: [RenderEffect]
            let bells: [TmuxABIBellProbe]
            let authorityStamps: [String]
            let peerDepartureObserved: Bool
            let topologyQueries: [String]
            struct TmuxABIBellProbe: Decodable {}
        }
        let answer = try JSONDecoder().decode(Edges.self, from: trace.payloads[1])
        XCTAssertTrue(answer.renderEffects.isEmpty)
        XCTAssertTrue(answer.bells.isEmpty)
        XCTAssertTrue(answer.authorityStamps.isEmpty)
        XCTAssertFalse(answer.peerDepartureObserved)
        XCTAssertTrue(answer.topologyQueries.isEmpty)
        XCTAssertEqual(try carriedSnapshots().count, 3)
    }

    func testAResyncOnADestroyedHandleIsStale() {
        let stale = tesseraTmuxRuntimeCreate(
            callback: receiveSnapshotElisionEvent,
            context: context
        )
        tesseraTmuxRuntimeDestroy(handle: stale)
        XCTAssertEqual(tesseraTmuxRuntimeResyncSnapshot(handle: stale), -2)
        XCTAssertEqual(tesseraTmuxRuntimeResyncSnapshot(handle: nil), -2)
    }

    /// Scenario A: a carrying event never reaches the decoder. v2 healed on
    /// the next event; v3 would reuse the older snapshot until the revision
    /// next moved. The next event's key exposes the loss, and the resync the
    /// bridge requests from inside that callback heals it before the
    /// operation returns.
    func testALostCarryingEventIsDetectedByItsKeyAndHealedByAResync() throws {
        let (bridge, handle, close) = makeLiveBridge()
        defer { close() }
        XCTAssertEqual(feed("%session-changed $1 work\r\n", into: handle), 0)
        var lost = false
        bridge.loses = { envelope in
            guard !lost, envelope.snapshot != nil else { return false }
            lost = true
            return true
        }
        XCTAssertEqual(feed("%window-add @1\r\n", into: handle), 0)
        XCTAssertTrue(lost)
        XCTAssertEqual(feed("%output %1 x\r\n", into: handle), 0)
        XCTAssertEqual(feed("%output %1 y\r\n", into: handle), 0)

        XCTAssertEqual(
            bridge.deliveries.map(\.outcome),
            [.current, .stale(requestsResync: true), .current, .current]
        )
        XCTAssertEqual(bridge.resyncStatuses, [0])
        // The stale event still delivered its effects, with the held snapshot.
        XCTAssertEqual(bridge.deliveries[1].snapshot.windows.map(\.id), [])
        for delivery in bridge.deliveries where delivery.outcome == .current {
            XCTAssertEqual(delivery.snapshot, delivery.envelope.testOracleSnapshot)
        }
        XCTAssertEqual(bridge.model.held.windows.map(\.id), [WindowId(1)])
        XCTAssertEqual(bridge.model.heldKey?.epoch, 1)
    }

    /// Scenario B: the handle's first payload is lost. Wire-only commands
    /// after it must still be delivered (each holds a reply slot), and the
    /// first state event resyncs instead of failing for want of a snapshot.
    func testLosingTheFirstEventBlocksNeitherWireCommandsNorState() throws {
        let (bridge, handle, close) = makeLiveBridge()
        defer { close() }
        var lost = false
        bridge.loses = { _ in
            defer { lost = true }
            return !lost
        }
        XCTAssertGreaterThan(queue("display-message -p first", into: handle), 0)
        let second = queue("display-message -p second", into: handle)
        XCTAssertGreaterThan(second, 0)
        XCTAssertEqual(try submit(.userInput, into: handle), 0)

        XCTAssertEqual(
            bridge.deliveries.map(\.outcome),
            [.wire, .stale(requestsResync: true), .current]
        )
        XCTAssertEqual(bridge.deliveries[0].envelope.platformWireCommands?.map(\.tag), [UInt64(second)])
        XCTAssertEqual(bridge.resyncStatuses, [0])
        XCTAssertEqual(bridge.model.held, TmuxRuntimeEngine().snapshot)
        XCTAssertEqual(bridge.model.heldKey?.epoch, 1)
    }

    /// Every payload queued behind a lost carrying one names the same key, so
    /// one request answers them all: the answer is queued behind them.
    func testOneResyncAnswersEveryPayloadQueuedBehindALostSnapshot() throws {
        let (bridge, handle, close) = makeLiveBridge()
        defer { close() }
        let command = Array("display-message -p x".utf8)
        // Control bytes JSON-escape to six bytes each, so a read within the
        // input ceiling still splits into several envelopes.
        let filler = String(repeating: "\u{01}", count: 500)
        let replyCount = 1_500
        for _ in 0..<replyCount {
            XCTAssertGreaterThan(command.withUnsafeBytes { raw in
                tesseraTmuxRuntimeSendCommand(
                    handle: handle,
                    text: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count
                )
            }, 0)
        }
        bridge.loses = { $0.snapshot != nil && $0.snapshotKey?.epoch == 0 }
        let replies = (1...replyCount).map { "%begin 1 \($0) 1\r\n\(filler)\r\n%end 1 \($0) 1\r\n" }.joined()
        XCTAssertEqual(feed("%session-changed $1 work\r\n%window-add @1\r\n" + replies, into: handle), 0)

        let outcomes = bridge.deliveries.map(\.outcome)
        XCTAssertGreaterThan(outcomes.count, 3)
        XCTAssertEqual(outcomes.first, .stale(requestsResync: true))
        XCTAssertEqual(outcomes.last, .current)
        XCTAssertEqual(
            Array(outcomes.dropFirst().dropLast()),
            Array(repeating: .stale(requestsResync: false), count: outcomes.count - 2)
        )
        XCTAssertEqual(bridge.resyncStatuses, [0])
        XCTAssertEqual(bridge.model.held.windows.map(\.id), [WindowId(1)])
    }

    private func submit(_ fact: RenderFact, into handle: UnsafeMutableRawPointer) throws -> Int32 {
        try SharedABI.encoder.encode(fact).withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    /// Until a snapshot arrives the Android decoder holds the engine's initial
    /// one, spelled out in `SharedTmuxEventDecoder.INITIAL_SNAPSHOT_JSON`; it
    /// is relayed to the session core like any other, so it must stay exactly
    /// what the core itself would have sent.
    func testTheInitialSnapshotTheBridgeHoldsIsTheEnginesOwn() throws {
        let expected = #"{"authoritativeWindowOrder":[],"authority":{"unknown":{}},"#
            + #""isActiveWindowAuthoritative":false,"isReorderPending":false,"isWindowListHydrated":false,"#
            + #""revision":0,"windows":[]}"#
        let encoded = try SharedABI.encoder.encode(TmuxRuntimeEngine().snapshot)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), expected)
    }
}
