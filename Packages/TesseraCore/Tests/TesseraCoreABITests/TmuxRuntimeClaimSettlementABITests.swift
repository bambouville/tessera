import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

private final class ClaimSettlementABITrace: @unchecked Sendable {
    var events: [[String: Any]] = []
    var errors: [String] = []
    var callbackDepth = 0
    var maximumCallbackDepth = 0
    var onEvent: (([String: Any]) -> Void)?
}

private let receiveClaimSettlementABIEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let trace = Unmanaged<ClaimSettlementABITrace>.fromOpaque(context).takeUnretainedValue()
    trace.callbackDepth += 1
    trace.maximumCallbackDepth = max(trace.maximumCallbackDepth, trace.callbackDepth)
    defer { trace.callbackDepth -= 1 }
    guard let event = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: count))
        as? [String: Any] else {
        trace.errors.append("callback was not a JSON object")
        return
    }
    trace.events.append(event)
    trace.onEvent?(event)
}

/// Drives one inline runtime handle through the ABI only, as the Android
/// adapter does.
private final class ClaimSettlementABIHarness {
    let trace = ClaimSettlementABITrace()
    let handle: UnsafeMutableRawPointer
    private let context: UnsafeMutableRawPointer
    private var nextReply = 1

    init() {
        let context = Unmanaged.passRetained(trace).toOpaque()
        self.context = context
        handle = tesseraTmuxRuntimeCreate(
            callback: receiveClaimSettlementABIEvent,
            context: context
        )
    }

    deinit {
        tesseraTmuxRuntimeDestroy(handle: handle)
        Unmanaged<ClaimSettlementABITrace>.fromOpaque(context).release()
    }

    func submit(_ fact: RenderFact) throws -> Int32 {
        let encoded = try SharedABI.encoder.encode(fact)
        return encoded.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    func feed(_ text: String) -> Int32 {
        Array(text.utf8).withUnsafeBytes { raw in
            tesseraTmuxRuntimeFeed(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    /// Answer the oldest command still waiting in tmux's reply FIFO.
    func reply(_ lines: [String]) -> Int32 {
        let sequence = nextReply
        nextReply += 1
        return feed(
            "%begin 1 \(sequence) 1\r\n"
                + lines.map { $0 + "\r\n" }.joined()
                + "%end 1 \(sequence) 1\r\n"
        )
    }

    func projectReleasing(
        _ authority: TmuxGridAuthoritySnapshot,
        capacity: Int = Int(CoreABICommand.maximumPayloadBytes),
        nullOutput: Bool = false,
        jsonOverride: Data? = nil
    ) -> (result: Int32, document: Data) {
        projectRuntimeAuthority(handle: handle, authority: authority, capacity: capacity,
            nullOutput: nullOutput, jsonOverride: jsonOverride)
    }

    var effects: [[String: Any]] {
        trace.events.flatMap { $0["renderEffects"] as? [[String: Any]] ?? [] }
    }

    func commands(since eventIndex: Int = 0) -> [String] {
        trace.events.dropFirst(eventIndex)
            .flatMap { $0["renderEffects"] as? [[String: Any]] ?? [] }
            .filter { $0["kind"] as? String == "sendCommand" }
            .compactMap { $0["command"] as? String }
    }

    func resolveLatestSurfaceState(columns: Int = 80, rows: Int = 24) throws {
        let state = try XCTUnwrap(
            effects.last { $0["kind"] as? String == "resolveSurfaceState" },
            "expected a surface-state request"
        )
        let request = try XCTUnwrap((state["request"] as? NSNumber)?.uint64Value)
        XCTAssertEqual(try submit(.surfaceState(
            .live,
            request: request,
            altScreen: false,
            mouseMode: .off,
            columns: columns,
            rows: rows
        )), 0)
    }
}

/// The projection half of the shared take-back: what the ledger deferred
/// while a peer held the grid is released by the session's mine projection,
/// as on iOS, instead of waiting for the next wire event. The work is handed
/// back in the result, never through a callback nested in the caller's
/// transport-order critical section.
final class TmuxRuntimeClaimSettlementABITests: XCTestCase {
    private static let paneMetadata = "%1\t0\t0\t\twindow\thost\t0"
    private let deepMetadata = RenderCommands.renderedPaneMetadata(target: WindowId(1))

    /// A painted inline pane, a peer holding the grid, and a take-back's
    /// visible repaint finished at visible rows: the deep history is owed.
    /// Without `claims`, an ordinary refresh under the peer owes it instead.
    private func takeBackWithDeferredHistory(
        pipelines: Bool = true,
        claims: Bool = true
    ) throws -> ClaimSettlementABIHarness {
        let harness = ClaimSettlementABIHarness()
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        XCTAssertEqual(try harness.submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ])), 0)
        XCTAssertEqual(harness.feed(
            "%window-add @1\r\n%session-window-changed $0 @1\r\n%window-pane-changed @1 %1\r\n"
        ), 0)
        XCTAssertEqual(harness.reply([Self.paneMetadata]), 0)
        XCTAssertEqual(harness.reply([Self.paneMetadata]), 0)
        XCTAssertEqual(harness.reply(["initial payload"]), 0)
        try harness.resolveLatestSurfaceState()

        // Project a stamp-less peer verdict. The ledger takes it immediately;
        // the next wire event publishes that projection to the adapter.
        XCTAssertGreaterThan(harness.projectReleasing(.peer(deviceID: "-", displayName: "another device", generation: 0)).result, 0)
        XCTAssertEqual(harness.feed("%window-renamed @1 shell\r\n"), 0)
        if pipelines {
            XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(
                handle: harness.handle,
                options: TmuxABIRenderLedgerOptions.pipelinesVisibleCapture.rawValue
            ), 0)
        }

        let beforeRepaint = harness.trace.events.count
        XCTAssertEqual(try harness.submit(
            .refreshRequested(.live, stage: .viewport, reason: claims ? "authority-claim" : "owner")
        ), 0)
        if pipelines {
            XCTAssertEqual(harness.commands(since: beforeRepaint), [
                RenderCommands.renderedPaneMetadata(target: WindowId(1)),
                RenderCommands.viewport(target: WindowId(1)),
            ], "P8: metadata and visible capture in one burst")
        } else {
            XCTAssertEqual(harness.commands(since: beforeRepaint), [
                RenderCommands.renderedPaneMetadata(target: WindowId(1)),
            ])
        }
        XCTAssertEqual(harness.reply([Self.paneMetadata]), 0)
        XCTAssertEqual(harness.reply(["visible rows"]), 0)
        try harness.resolveLatestSurfaceState()
        XCTAssertEqual(
            harness.commands(since: beforeRepaint),
            [RenderCommands.renderedPaneMetadata(target: WindowId(1)), RenderCommands.viewport(target: WindowId(1))],
            "no history capture while the peer holds the grid"
        )
        XCTAssertTrue(harness.trace.errors.isEmpty, "\(harness.trace.errors)")
        return harness
    }

    private func releasedEffects(_ document: Data) throws -> [RenderEffect] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: document) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["renderEffects"], "the result's shape is the contract")
        let effects = try XCTUnwrap(object["renderEffects"] as? [Any])
        return try effects.map {
            try JSONDecoder().decode(
                RenderEffect.self,
                from: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
            )
        }
    }

    private func sentCommands(_ effects: [RenderEffect]) -> [String] {
        effects.compactMap { effect in
            if case .sendCommand(let command) = effect { return command }
            return nil
        }
    }

    func testProjectionReturnsTheDeferredHistoryInsteadOfACallback() throws {
        let harness = try takeBackWithDeferredHistory()
        let eventsBefore = harness.trace.events.count

        let settled = harness.projectReleasing(.mine(generation: 7))
        XCTAssertGreaterThan(settled.result, 0)
        XCTAssertEqual(harness.trace.events.count, eventsBefore, "returned, not delivered through a callback")
        let effects = try releasedEffects(settled.document)
        XCTAssertEqual(sentCommands(effects), [deepMetadata])
        XCTAssertEqual(
            settled.document,
            try SharedABI.encoder.encode(["renderEffects": effects]),
            "canonical JSON, like every callback envelope"
        )

        // The returned command already holds its FIFO slot: its reply drives
        // the history capture through the ordinary callback.
        XCTAssertEqual(harness.reply([Self.paneMetadata]), 0)
        XCTAssertEqual(
            harness.commands(since: eventsBefore),
            [RenderCommands.deepPrimary(target: WindowId(1), depth: 2_000)]
        )

        // The settled authority reaches the adapter on the next state event.
        let snapshot = try XCTUnwrap(
            harness.trace.events.last { $0["snapshot"] != nil }?["snapshot"] as? [String: Any]
        )
        let authority = try XCTUnwrap(snapshot["authority"] as? [String: Any])
        XCTAssertNotNil(authority["mine"], "\(authority)")

        XCTAssertEqual(
            try releasedEffects(harness.projectReleasing(.mine(generation: 7)).document),
            [],
            "released once"
        )
    }

    /// Without the pipelining switch the take-back costs one more round trip,
    /// but its history is still deferred and released the same way.
    func testProjectionReleasesTheHistoryOfAnUnpipelinedTakeBack() throws {
        let harness = try takeBackWithDeferredHistory(pipelines: false)
        XCTAssertEqual(sentCommands(try releasedEffects(harness.projectReleasing(.mine(generation: 2)).document)), [deepMetadata])
    }

    /// Called from a callback, the work queues behind the event being
    /// delivered (whose commands hold earlier FIFO slots) and is delivered
    /// after it returns: never nested, never ahead of it.
    func testProjectionFromACallbackQueuesTheWorkBehindIt() throws {
        let harness = try takeBackWithDeferredHistory()
        var nested: (result: Int32, document: Data)?
        var depthAtSettlement = 0
        harness.trace.onEvent = { [unowned harness] _ in
            guard nested == nil else { return }
            depthAtSettlement = harness.trace.callbackDepth
            nested = harness.projectReleasing(.mine(generation: 7))
        }
        let eventsBefore = harness.trace.events.count
        harness.trace.maximumCallbackDepth = 0
        XCTAssertEqual(tesseraTmuxRuntimeResyncSnapshot(handle: harness.handle), 0)

        let settled = try XCTUnwrap(nested)
        XCTAssertEqual(depthAtSettlement, 1)
        XCTAssertGreaterThan(settled.result, 0)
        XCTAssertEqual(String(decoding: settled.document, as: UTF8.self), #"{"renderEffects":[]}"#)
        XCTAssertEqual(harness.trace.maximumCallbackDepth, 1, "never a nested callback")
        XCTAssertEqual(harness.trace.events.count, eventsBefore + 2)
        XCTAssertEqual(harness.commands(since: eventsBefore + 1), [deepMetadata], "delivered after the resync answer")
        XCTAssertEqual(harness.commands(since: eventsBefore), [deepMetadata])
    }

    /// Settling cannot be repeated to size its result, so a missing or short
    /// buffer is refused before anything changes.
    func testProjectionRefusesAShortBufferBeforeChangingAnything() throws {
        let harness = try takeBackWithDeferredHistory()
        XCTAssertEqual(harness.projectReleasing(.mine(generation: 7), nullOutput: true).result, -1)
        for malformed in ["not-json", "{}", #"{"mine":{"generation":-1}}"#] {
            XCTAssertEqual(harness.projectReleasing(.mine(generation: 7), jsonOverride: Data(malformed.utf8)).result, -1)
        }
        XCTAssertEqual(
            harness.projectReleasing(.mine(generation: 7), capacity: Int(CoreABICommand.maximumPayloadBytes) - 1).result,
            -1
        )
        XCTAssertEqual(
            sentCommands(try releasedEffects(harness.projectReleasing(.mine(generation: 7)).document)),
            [deepMetadata],
            "the refused calls released nothing"
        )

        tesseraTmuxRuntimeDestroy(handle: harness.handle)
        XCTAssertEqual(harness.projectReleasing(.mine(generation: 8)).result, -2)
    }

    /// Facts after a projection see its authority without waiting for wire traffic.
    func testFactsAfterProjectionSeeTheProjectedAuthority() throws {
        let harness = ClaimSettlementABIHarness()
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        XCTAssertEqual(try harness.submit(.surfacesDeclared([.init(surfaceID: .live, presentation: .single)])), 0)
        XCTAssertEqual(harness.feed("%window-add @1\r\n%session-window-changed $0 @1\r\n%window-pane-changed @1 %1\r\n"), 0)
        XCTAssertEqual(harness.reply([Self.paneMetadata]), 0)
        XCTAssertEqual(harness.reply([Self.paneMetadata]), 0)
        XCTAssertEqual(harness.reply(["initial payload"]), 0)
        try harness.resolveLatestSurfaceState()
        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(handle: harness.handle,
            options: TmuxABIRenderLedgerOptions.pipelinesVisibleCapture.rawValue), 0)
        XCTAssertGreaterThan(harness.projectReleasing(.peer(deviceID: "peer", displayName: "iPad", generation: 1)).result, 0)
        XCTAssertEqual(try releasedEffects(harness.projectReleasing(.mine(generation: 3)).document), [])
        let before = harness.trace.events.count
        XCTAssertEqual(try harness.submit(.refreshRequested(.live, stage: .viewport, reason: "owner")), 0)
        XCTAssertEqual(harness.commands(since: before), [deepMetadata])
    }

    /// The peer verdict reaches the ledger with the projection call: a fact
    /// submitted before any wire event is decided under the peer. The
    /// ledger used to keep the snapshot from before the verdict until the
    /// next feed, so a refresh still went out as the owner's.
    func testFactsAfterPeerProjectionSeeThePeer() throws {
        let harness = ClaimSettlementABIHarness()
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        XCTAssertEqual(try harness.submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ])), 0)
        XCTAssertEqual(harness.feed(
            "%window-add @1\r\n%session-window-changed $0 @1\r\n%window-pane-changed @1 %1\r\n"
        ), 0)
        XCTAssertEqual(harness.reply([Self.paneMetadata]), 0)
        XCTAssertEqual(harness.reply([Self.paneMetadata]), 0)
        XCTAssertEqual(harness.reply(["initial payload"]), 0)
        try harness.resolveLatestSurfaceState()
        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(
            handle: harness.handle,
            options: TmuxABIRenderLedgerOptions.pipelinesVisibleCapture.rawValue
        ), 0)

        XCTAssertGreaterThan(harness.projectReleasing(.peer(deviceID: "-", displayName: "another device", generation: 0)).result, 0)
        let before = harness.trace.events.count
        XCTAssertEqual(try harness.submit(.refreshRequested(.live, stage: .viewport, reason: "owner")), 0)
        XCTAssertEqual(
            harness.commands(since: before),
            [RenderCommands.renderedPaneMetadata(target: WindowId(1)), RenderCommands.viewport(target: WindowId(1))],
            "decided under the peer with no wire event in between"
        )
        XCTAssertTrue(harness.trace.errors.isEmpty, "\(harness.trace.errors)")
    }

    /// A verdict reached while a replacement transport has not named its
    /// active window leaves the ledger on the retained topology, as a
    /// settlement there does, rather than on the new parser's empty
    /// snapshot: the reattach still repaints the retained target.
    func testPeerProjectionBeforeTheReattachTopologyKeepsTheRetainedTarget() throws {
        let harness = ClaimSettlementABIHarness()
        XCTAssertEqual(harness.feed(
            "%session-changed $0 work\r\n%window-add @1\r\n%window-pane-changed @1 %1\r\n%session-window-changed $0 @1\r\n"
        ), 0)
        XCTAssertEqual(try harness.submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ])), 0)
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        XCTAssertEqual(try harness.submit(.clientSize(columns: 80, rows: 24)), 0)
        XCTAssertEqual(try harness.submit(.transportLost), 0)

        XCTAssertGreaterThan(harness.projectReleasing(.peer(deviceID: "-", displayName: "another device", generation: 0)).result, 0)
        let before = harness.trace.events.count
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        XCTAssertTrue(
            harness.commands(since: before).contains { $0.hasPrefix("display-message -p -t @1 ") },
            "\(harness.commands(since: before))"
        )
        XCTAssertTrue(harness.trace.errors.isEmpty, "\(harness.trace.errors)")
    }

    /// The retained topology takes the verdict with it. A replacement
    /// transport that has not named its active window keeps the ledger on
    /// the retained target, and a fact submitted meanwhile is decided under
    /// the peer: a visible refresh pipelines its capture as a veiled one
    /// does. A verdict that skipped the retained snapshot left it decided as
    /// the owner's until tmux named the window.
    func testPeerProjectionBeforeTheReattachTopologyStillReachesItsFacts() throws {
        let harness = ClaimSettlementABIHarness()
        var answered = 0
        func answerEverything() {
            while answered < harness.commands().count {
                let command = harness.commands()[answered]
                answered += 1
                XCTAssertEqual(harness.reply([
                    command.hasPrefix("display-message") ? Self.paneMetadata : "payload",
                ]), 0)
            }
        }
        XCTAssertEqual(harness.feed(
            "%session-changed $0 work\r\n%window-add @1\r\n%window-pane-changed @1 %1\r\n%session-window-changed $0 @1\r\n"
        ), 0)
        XCTAssertEqual(try harness.submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ])), 0)
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(
            handle: harness.handle,
            options: TmuxABIRenderLedgerOptions.pipelinesVisibleCapture.rawValue
        ), 0)
        XCTAssertEqual(try harness.submit(.transportLost), 0)

        XCTAssertGreaterThan(harness.projectReleasing(.peer(deviceID: "-", displayName: "another device", generation: 0)).result, 0)
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        answerEverything()
        try harness.resolveLatestSurfaceState()
        answerEverything()
        let before = harness.trace.events.count
        XCTAssertEqual(try harness.submit(.refreshRequested(.live, stage: .viewport, reason: "owner")), 0)
        XCTAssertEqual(
            harness.commands(since: before),
            [RenderCommands.renderedPaneMetadata(target: WindowId(1)), RenderCommands.viewport(target: WindowId(1))],
            "decided under the peer on the retained target"
        )
        XCTAssertTrue(harness.trace.errors.isEmpty, "\(harness.trace.errors)")
    }

    /// A read that found no stamp moves the shared reducer off the
    /// stamp-less peer to `.unknown`. Projecting that verdict returns
    /// what the ledger deferred under the peer.
    func testProjectionToUnknownReleasesWhatItDeferred() throws {
        let harness = try takeBackWithDeferredHistory(claims: false)
        let eventsBefore = harness.trace.events.count

        let cleared = harness.projectReleasing(.unknown)
        XCTAssertGreaterThan(cleared.result, 0)
        XCTAssertEqual(harness.trace.events.count, eventsBefore, "returned, not delivered through a callback")
        XCTAssertEqual(sentCommands(try releasedEffects(cleared.document)), [deepMetadata])

        XCTAssertEqual(harness.reply([Self.paneMetadata]), 0)
        XCTAssertEqual(harness.feed("%window-renamed @1 again\r\n"), 0)
        let snapshot = try XCTUnwrap(
            harness.trace.events.last { $0["snapshot"] != nil }?["snapshot"] as? [String: Any]
        )
        let authority = try XCTUnwrap(snapshot["authority"] as? [String: Any])
        XCTAssertNotNil(authority["unknown"], "\(authority)")
        XCTAssertTrue(harness.trace.errors.isEmpty, "\(harness.trace.errors)")
    }

    /// Unchanged projection leaves deferred work and the ledger alone.
    func testAnUnchangedPeerProjectionLeavesItsHistoryDeferred() throws {
        let harness = try takeBackWithDeferredHistory()
        let before = harness.trace.events.count
        XCTAssertEqual(String(decoding: harness.projectReleasing(.peer(deviceID: "-", displayName: "another device", generation: 0)).document,
            as: UTF8.self), #"{"renderEffects":[]}"#)
        XCTAssertEqual(harness.trace.events.count, before)
        XCTAssertEqual(sentCommands(try releasedEffects(harness.projectReleasing(.mine(generation: 7)).document)), [deepMetadata])
    }

    /// Cleared while a replacement transport has not named its active
    /// window, the retained topology takes the cleared authority, as it took
    /// the verdict: a visible refresh is the owner's single metadata step.
    func testProjectionToUnknownBeforeTheReattachTopologyReachesItsFacts() throws {
        let harness = ClaimSettlementABIHarness()
        var answered = 0
        func answerEverything() {
            while answered < harness.commands().count {
                let command = harness.commands()[answered]
                answered += 1
                XCTAssertEqual(harness.reply([
                    command.hasPrefix("display-message") ? Self.paneMetadata : "payload",
                ]), 0)
            }
        }
        XCTAssertEqual(harness.feed(
            "%session-changed $0 work\r\n%window-add @1\r\n%window-pane-changed @1 %1\r\n%session-window-changed $0 @1\r\n"
        ), 0)
        XCTAssertEqual(try harness.submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ])), 0)
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(
            handle: harness.handle,
            options: TmuxABIRenderLedgerOptions.pipelinesVisibleCapture.rawValue
        ), 0)
        XCTAssertEqual(try harness.submit(.transportLost), 0)
        XCTAssertGreaterThan(harness.projectReleasing(.peer(deviceID: "-", displayName: "another device", generation: 0)).result, 0)
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        answerEverything()
        try harness.resolveLatestSurfaceState()
        answerEverything()

        XCTAssertGreaterThan(harness.projectReleasing(.unknown).result, 0)
        let before = harness.trace.events.count
        XCTAssertEqual(try harness.submit(.refreshRequested(.live, stage: .viewport, reason: "owner")), 0)
        XCTAssertEqual(
            harness.commands(since: before),
            [RenderCommands.renderedPaneMetadata(target: WindowId(1))],
            "decided as nobody's on the retained target"
        )
        XCTAssertTrue(harness.trace.errors.isEmpty, "\(harness.trace.errors)")
    }

    func testProjectionWithNothingDeferredReturnsAnEmptyList() throws {
        let harness = ClaimSettlementABIHarness()
        let settled = harness.projectReleasing(.mine(generation: 1))
        XCTAssertGreaterThan(settled.result, 0)
        XCTAssertEqual(String(decoding: settled.document, as: UTF8.self), #"{"renderEffects":[]}"#)
        XCTAssertTrue(harness.trace.events.isEmpty)
    }

    func testProjectionChangesTheSnapshotRevisionOnlyForANewValue() throws {
        let harness = ClaimSettlementABIHarness()
        let values: [TmuxGridAuthoritySnapshot] = [.unknown, .mine(generation: 9), .mine(generation: 9),
            .peer(deviceID: "PEER", displayName: "iPad", generation: 7)]
        for (index, authority) in values.enumerated() {
            XCTAssertEqual(String(decoding: harness.projectReleasing(authority).document, as: UTF8.self),
                #"{"renderEffects":[]}"#)
            XCTAssertEqual(harness.trace.events.count, index, "projection has no event of its own")
            XCTAssertEqual(tesseraTmuxRuntimeResyncSnapshot(handle: harness.handle), 0)
        }
        let snapshots = try harness.trace.events.map { event -> TmuxSnapshot in
            let object = try XCTUnwrap(event["snapshot"])
            return try JSONDecoder().decode(TmuxSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(snapshots.map(\.revision), [0, 1, 1, 2])
        XCTAssertEqual(snapshots.map(\.authority), values)
    }

    // MARK: - Render-ledger options

    func testRenderLedgerOptionsSetExactlyTheFieldsTheyName() throws {
        let harness = ClaimSettlementABIHarness()
        let core = TmuxRenderLedger.Configuration()
        XCTAssertEqual(tesseraTmuxRuntimeRenderLedgerConfiguration(handle: harness.handle), core)

        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(handle: harness.handle, options: 7), 0)
        var all = core
        all.suppressesUnchangedClientSizeReplay = true
        all.inlineClientSizeReplayBelongsToClaim = true
        all.pipelinesVisibleCapture = true
        XCTAssertEqual(tesseraTmuxRuntimeRenderLedgerConfiguration(handle: harness.handle), all)

        for (bit, field) in [
            (UInt32(1), \TmuxRenderLedger.Configuration.suppressesUnchangedClientSizeReplay),
            (2, \.inlineClientSizeReplayBelongsToClaim),
            (4, \.pipelinesVisibleCapture),
        ] {
            XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(handle: harness.handle, options: bit), 0)
            var expected = core
            expected[keyPath: field] = true
            XCTAssertEqual(tesseraTmuxRuntimeRenderLedgerConfiguration(handle: harness.handle), expected, "bit \(bit)")
        }

        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(handle: harness.handle, options: 7), 0)
        for undefined in [UInt32(8), 1 << 31, 15] {
            XCTAssertEqual(
                tesseraTmuxRuntimeSetRenderLedgerOptions(handle: harness.handle, options: undefined),
                -1,
                "an undefined bit is refused, never ignored"
            )
            XCTAssertEqual(tesseraTmuxRuntimeRenderLedgerConfiguration(handle: harness.handle), all)
        }
        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(handle: harness.handle, options: 0), 0)
        XCTAssertEqual(tesseraTmuxRuntimeRenderLedgerConfiguration(handle: harness.handle), core)
        XCTAssertTrue(harness.trace.events.isEmpty, "the knob emits nothing")

        tesseraTmuxRuntimeDestroy(handle: harness.handle)
        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(handle: harness.handle, options: 0), -2)
    }

    /// The header's bit values are the ones the core reads.
    func testRenderLedgerOptionBitsMatchTheHeader() {
        XCTAssertEqual(TmuxABIRenderLedgerOptions.suppressesUnchangedClientSizeReplay.rawValue, 1)
        XCTAssertEqual(TmuxABIRenderLedgerOptions.inlineClientSizeReplayBelongsToClaim.rawValue, 2)
        XCTAssertEqual(TmuxABIRenderLedgerOptions.pipelinesVisibleCapture.rawValue, 4)
    }

    /// P6 and the claim's fence rule, driven through the ABI: the adapter's
    /// own memo and fence become unnecessary once both switches are set.
    func testClientSizeReplayFollowsTheOptions() throws {
        let harness = ClaimSettlementABIHarness()
        XCTAssertEqual(try harness.submit(.transportAttached(.inline)), 0)
        func replay(_ columns: Int, _ rows: Int) throws -> [String] {
            let before = harness.trace.events.count
            XCTAssertEqual(try harness.submit(.clientSize(columns: columns, rows: rows)), 0)
            let sent = harness.commands(since: before)
            for _ in sent { XCTAssertEqual(harness.reply([]), 0) }
            return sent
        }

        // Off by default: every replay goes out whole.
        XCTAssertEqual(try replay(80, 24), ["refresh-client -C 80,24", "select-window"])
        XCTAssertEqual(try replay(80, 24), ["refresh-client -C 80,24", "select-window"])

        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(
            handle: harness.handle,
            options: TmuxABIRenderLedgerOptions.suppressesUnchangedClientSizeReplay.rawValue
        ), 0)
        XCTAssertEqual(try replay(80, 24), ["select-window"], "P6: the grid this connection already has")
        XCTAssertEqual(try replay(100, 30), ["refresh-client -C 100,30", "select-window"])

        // A pending claim fences itself.
        XCTAssertEqual(tesseraTmuxRuntimeSetRenderLedgerOptions(
            handle: harness.handle,
            options: TmuxABIRenderLedgerOptions([
                .suppressesUnchangedClientSizeReplay,
                .inlineClientSizeReplayBelongsToClaim,
            ]).rawValue
        ), 0)
        XCTAssertEqual(try replay(90, 28), ["refresh-client -C 90,28"])
        XCTAssertEqual(try replay(90, 28), [])

        // A rejected advertisement is forgotten, so the same grid goes again.
        let before = harness.trace.events.count
        XCTAssertEqual(try harness.submit(.clientSize(columns: 70, rows: 20)), 0)
        XCTAssertEqual(harness.commands(since: before), ["refresh-client -C 70,20"])
        XCTAssertEqual(harness.feed("%begin 1 99 1\r\nbad size\r\n%error 1 99 1\r\n"), 0)
        XCTAssertEqual(try replay(70, 20), ["refresh-client -C 70,20"])
        XCTAssertTrue(harness.trace.errors.isEmpty, "\(harness.trace.errors)")
    }
}
