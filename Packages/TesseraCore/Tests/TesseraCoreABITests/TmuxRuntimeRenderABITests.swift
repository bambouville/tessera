import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

private final class TmuxABIRenderEventCapture: @unchecked Sendable {
    var events: [Data] = []
    var callbackDepth = 0
    var maximumCallbackDepth = 0
    var reentrantFact: Data?
    var handle: UnsafeMutableRawPointer?
    var submittedReentrantFact = false
    var destroyAfterReentrantFact = false
    var destroyedReentrantly = false
}

private let receiveTmuxABIRenderEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let capture = Unmanaged<TmuxABIRenderEventCapture>
        .fromOpaque(context)
        .takeUnretainedValue()
    capture.callbackDepth += 1
    capture.maximumCallbackDepth = max(capture.maximumCallbackDepth, capture.callbackDepth)
    capture.events.append(Data(bytes: bytes, count: count))
    if !capture.submittedReentrantFact,
       let handle = capture.handle,
       let fact = capture.reentrantFact {
        capture.submittedReentrantFact = true
        _ = fact.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
        if capture.destroyAfterReentrantFact {
            tesseraTmuxRuntimeDestroy(handle: handle)
            capture.destroyedReentrantly = true
        }
    }
    capture.callbackDepth -= 1
}

private final class TmuxABIReentrantBurstCapture: @unchecked Sendable {
    let fact: Data
    var handle: UnsafeMutableRawPointer?
    var callbackCount = 0
    var didBurst = false
    var results: [Int32] = []

    init(fact: Data) {
        self.fact = fact
    }
}

private let receiveTmuxABIReentrantBurst: TesseraCoreABIEventCallback = { _, _, context in
    guard let context else { return }
    let capture = Unmanaged<TmuxABIReentrantBurstCapture>
        .fromOpaque(context)
        .takeUnretainedValue()
    capture.callbackCount += 1
    guard !capture.didBurst, let handle = capture.handle else { return }
    capture.didBurst = true
    capture.results.reserveCapacity(5_000)
    for _ in 0..<5_000 {
        capture.results.append(capture.fact.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        })
    }
}

final class TmuxRuntimeRenderABITests: XCTestCase {
    private func submit(_ fact: RenderFact, to handle: UnsafeMutableRawPointer) throws -> Int32 {
        let encoded = try SharedABI.encoder.encode(fact)
        return encoded.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    private func feed(_ text: String, to handle: UnsafeMutableRawPointer) -> Int32 {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBytes { raw in
            tesseraTmuxRuntimeFeed(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
    }

    private func events(_ capture: TmuxABIRenderEventCapture) throws -> [[String: Any]] {
        try capture.events.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
    }

    private func latestEffect(
        named kind: String,
        from capture: TmuxABIRenderEventCapture
    ) throws -> [String: Any] {
        for event in try events(capture).reversed() {
            let effects = event["renderEffects"] as? [[String: Any]] ?? []
            if let effect = effects.last(where: { $0["kind"] as? String == kind }) {
                return effect
            }
        }
        XCTFail("expected render effect \(kind)")
        return [:]
    }

    func testUnwrittenSuffixRollbackKeepsWrittenReplyCorrelation() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(callback: receiveTmuxABIRenderEvent, context: context)
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }
        func reserve() -> UInt64 {
            let bytes = Array("display-message -p x".utf8)
            let tag = bytes.withUnsafeBytes { raw in
                tesseraTmuxRuntimeSendCommand(handle: handle, text: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count)
            }
            XCTAssertGreaterThan(tag, 0)
            return UInt64(tag)
        }
        let written = reserve()
        let unwritten = [reserve(), reserve()]
        XCTAssertNotEqual(try submit(.unwrittenCommandsCancelled(tags: [written]), to: handle), 0, "cannot remove a prefix while later commands remain reserved")
        XCTAssertEqual(try submit(.unwrittenCommandsCancelled(tags: unwritten), to: handle), 0)
        let next = reserve()
        XCTAssertEqual(feed("%begin 1 1 1\r\nx\r\n%end 1 1 1\r\n%begin 1 2 1\r\nx\r\n%end 1 2 1\r\n", to: handle), 0)
        let tags = try events(capture).flatMap { ($0["renderEffects"] as? [[String: Any]] ?? []) }
            .filter { $0["kind"] as? String == "commandReply" }
            .compactMap { ($0["tag"] as? NSNumber)?.uint64Value }
        XCTAssertEqual(tags, [written, next])
    }

    func testReorderFactsReconcileOnlyAgainstTheirStrictCorrelatedFullList() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }
        func row(_ id: Int, _ index: Int) -> String {
            "__tessera_windows__\t@\(id)\t\(index)\t%\(id)\t\t\t0\twindow-\(id)"
        }
        func response(_ sequence: Int, _ rows: [String]) -> String {
            "%begin \(sequence) 1 1\r\n"
                + rows.map { $0 + "\r\n" }.joined()
                + "%end \(sequence) 1 1\r\n"
        }
        func latestSnapshot() throws -> [String: Any] {
            // An unchanged snapshot is elided; the adapter keeps the last one.
            try XCTUnwrap(try events(capture).last(where: { $0["snapshot"] != nil })?["snapshot"]
                as? [String: Any])
        }
        func windowIDs(_ snapshot: [String: Any]) -> [Int] {
            (snapshot["windows"] as? [[String: Any]] ?? []).compactMap {
                ($0["id"] as? [String: Any])?["rawValue"] as? Int
            }
        }

        XCTAssertEqual(
            feed(
                "%session-changed $7 work\r\n"
                    + response(1, [row(1, 0), row(2, 1)]),
                to: handle
            ),
            0
        )
        XCTAssertEqual(try submit(.reorderBegan(
            token: 1,
            order: [WindowId(2), WindowId(1)]
        ), to: handle), 0)
        XCTAssertEqual(try latestSnapshot()["isReorderPending"] as? Bool, true)
        XCTAssertEqual(windowIDs(try latestSnapshot()), [2, 1])

        XCTAssertEqual(try submit(.reorderConfirmed(token: 1), to: handle), 0)
        XCTAssertEqual(try latestSnapshot()["isReorderPending"] as? Bool, true)
        XCTAssertTrue(try latestEffect(named: "sendCommand", from: capture)["command"] as? String
            == TmuxRuntimeHydrationQuery.commands[0])

        // The add shares the socket read with the full-list reply. Validation
        // must use the correlated step's snapshot while retaining the later
        // announcement in the final event.
        XCTAssertEqual(
            feed(response(2, [row(2, 0), row(1, 1)]) + "%window-add @3\r\n", to: handle),
            0
        )
        XCTAssertEqual(try latestSnapshot()["isReorderPending"] as? Bool, false)
        XCTAssertEqual(windowIDs(try latestSnapshot()), [2, 1, 3])

        XCTAssertEqual(try submit(.reorderBegan(
            token: 2,
            order: [WindowId(1), WindowId(2), WindowId(3)]
        ), to: handle), 0)
        XCTAssertEqual(try submit(.reorderConfirmed(token: 2), to: handle), 0)
        XCTAssertEqual(
            feed(response(3, ["__tessera_windows__\tmalformed"]), to: handle),
            0
        )
        XCTAssertEqual(
            try latestSnapshot()["isReorderPending"] as? Bool,
            true,
            "a malformed success reply cannot confirm or abandon optimism"
        )
        XCTAssertEqual(try submit(.reorderAbandoned(token: 2), to: handle), 0)
        XCTAssertEqual(
            try latestSnapshot()["isReorderPending"] as? Bool,
            false,
            "the adapter deadline explicitly abandons unresolved optimism"
        )
    }

    func testRealWireSessionSubscriptionChangesKnownWindowOrderAndIgnoresForeignSession() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }
        func latestSnapshot() throws -> [String: Any] {
            // An unchanged snapshot is elided; the adapter keeps the last one.
            try XCTUnwrap(try events(capture).last(where: { $0["snapshot"] != nil })?["snapshot"]
                as? [String: Any])
        }
        func windowIDs(_ snapshot: [String: Any]) -> [Int] {
            (snapshot["windows"] as? [[String: Any]] ?? []).compactMap {
                ($0["id"] as? [String: Any])?["rawValue"] as? Int
            }
        }
        let rows = [
            "__tessera_windows__\t@1\t0\t%1\t\t\t0\tone",
            "__tessera_windows__\t@2\t1\t%2\t\t\t0\ttwo",
        ]
        let hydration = "%begin 1 1 1\r\n"
            + rows.map { $0 + "\r\n" }.joined()
            + "%end 1 1 1\r\n"
        XCTAssertEqual(feed(
            "%session-changed $7 work\r\n"
                + "%session-window-changed $7 @1\r\n"
                + hydration,
            to: handle
        ), 0)
        XCTAssertEqual(windowIDs(try latestSnapshot()), [1, 2])

        XCTAssertEqual(feed(
            "%subscription-changed tessera-window-order $7 - - - : 0=@2* 1=@1 \r\n",
            to: handle
        ), 0)
        var snapshot = try latestSnapshot()
        XCTAssertEqual(windowIDs(snapshot), [2, 1])
        XCTAssertEqual(
            ((snapshot["activeWindowID"] as? [String: Any])?["rawValue"] as? Int),
            1,
            "an order-only subscription must not select its starred window"
        )

        XCTAssertEqual(feed(
            "%subscription-changed tessera-window-order $8 - - - : 0=@1* 1=@2 \r\n",
            to: handle
        ), 0)
        snapshot = try latestSnapshot()
        XCTAssertEqual(windowIDs(snapshot), [2, 1], "a foreign session cannot reorder this runtime")
        XCTAssertEqual(
            ((snapshot["activeWindowID"] as? [String: Any])?["rawValue"] as? Int),
            1
        )
    }

    /// Android reads pane lifecycle only through this envelope. When the field
    /// was missing, an agent working in any window the client was not painting
    /// could not appear in Agent Center at all — including every window the
    /// user had just opened.
    func testAgentStateCrossesTheABIWithItsPaneAddress() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }
        XCTAssertEqual(feed("%session-changed $1 work\n%window-add @1\n", to: handle), 0)
        let json = #"{"version":9,"provider":"codex","event":"SessionStart","state":"idle"}"#
        let value = [
            "@7", "%70", "1", "0", "0", "80", "24",
            "codex", "codex", "agents", "vps-1", "/home/tessera", json,
        ].joined(separator: "\t")

        XCTAssertEqual(
            feed("%subscription-changed tessera-pane-meta $1 @7 0 %70 : \(value)\n", to: handle),
            0
        )

        let states = try events(capture).flatMap { $0["agentStates"] as? [[String: Any]] ?? [] }
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual((states.first?["windowID"] as? [String: Any])?["rawValue"] as? Int, 7)
        XCTAssertEqual((states.first?["paneID"] as? [String: Any])?["rawValue"] as? Int, 70)
        XCTAssertEqual(states.first?["json"] as? String, json)
    }

    func testRenderLedgerABIUsesCanonicalV2EffectsAndQueuesReentrantFacts() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        capture.handle = handle
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        capture.reentrantFact = try SharedABI.encoder.encode(
            RenderFact.clientSize(columns: 80, rows: 24)
        )
        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), 0)
        XCTAssertTrue(capture.submittedReentrantFact)
        XCTAssertEqual(capture.maximumCallbackDepth, 1)
        XCTAssertEqual(capture.events.count, 2, "the re-entrant fact must queue behind the current callback")

        let firstJSON = try XCTUnwrap(String(data: capture.events[0], encoding: .utf8))
        XCTAssertTrue(
            firstJSON.hasPrefix("{\"agentStates\":"),
            "callbacks use SharedABI's sorted-key encoder, so the envelope opens on "
                + "whichever field sorts first by name"
        )
        XCTAssertFalse(firstJSON.contains("paneOutputs"))
        XCTAssertFalse(firstJSON.contains("responseFrames"))
        XCTAssertTrue(firstJSON.contains("\"renderEffects\":"))
        XCTAssertEqual((try events(capture)[0]["version"] as? NSNumber)?.intValue, 3)

        let command = Array("display-message -p 'platform'".utf8)
        let tag = command.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSendCommand(
                handle: handle,
                text: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }
        XCTAssertGreaterThan(tag, 0)
        // The re-entrant size fact already placed these two ledger commands
        // ahead of the platform command. Their replies must drain first.
        XCTAssertEqual(feed("%begin 1 1 1\r\n%end 1 1 1\r\n", to: handle), 0)
        XCTAssertEqual(feed("%begin 1 2 1\r\n%end 1 2 1\r\n", to: handle), 0)
        XCTAssertEqual(feed("%begin 1 3 1\r\nplatform reply\r\n%end 1 3 1\r\n", to: handle), 0)
        let reply = try latestEffect(named: "commandReply", from: capture)
        XCTAssertEqual((reply["tag"] as? NSNumber)?.int64Value, tag)
        XCTAssertEqual(reply["lines"] as? [String], ["platform reply"])
    }

    func testRetainedFeedBytesUseQueryThenSingleConsumingCopy() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), 0)
        XCTAssertEqual(try submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ]), to: handle), 0)
        XCTAssertEqual(feed(
            "%window-add @1\r\n%session-window-changed $0 @1\r\n%window-pane-changed @1 %1\r\n",
            to: handle
        ), 0)

        // Wire-order reduction first observes the authoritative window before
        // it observes that window's pane. The window-only metadata request is
        // superseded by the pane-bound request, but its FIFO reply must still
        // drain before the current metadata and deep-capture replies.
        XCTAssertEqual(feed(
            "%begin 1 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 1 1 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 1 2 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 1 2 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 1 3 1\r\nretained render payload\r\n%end 1 3 1\r\n",
            to: handle
        ), 0)
        let state = try latestEffect(named: "resolveSurfaceState", from: capture)
        let request = try XCTUnwrap((state["request"] as? NSNumber)?.uint64Value)
        XCTAssertEqual(try submit(.surfaceState(
            .live,
            request: request,
            altScreen: false,
            mouseMode: .off,
            columns: 80,
            rows: 24
        ), to: handle), 0)

        let feedEffect = try latestEffect(named: "feed", from: capture)
        let bytesRef = try XCTUnwrap(
            ((feedEffect["bytesRef"] as? [String: Any])?["id"] as? NSNumber)?.uint64Value
        )
        let required = tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: bytesRef,
            outputBytes: nil,
            outputCapacity: 0
        )
        XCTAssertGreaterThan(required, 0)
        XCTAssertLessThanOrEqual(required, Int32(CoreABICommand.maximumPayloadBytes))

        var copied = [UInt8](repeating: 0, count: Int(required))
        let copiedCount = copied.withUnsafeMutableBytes { raw in
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: bytesRef,
                outputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                outputCapacity: raw.count
            )
        }
        XCTAssertEqual(copiedCount, required)
        XCTAssertTrue(String(decoding: copied, as: UTF8.self).contains("retained render payload"))
        XCTAssertEqual(
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: bytesRef,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1,
            "a successful copy consumes the reference"
        )
    }

    func testRenderLedgerABIPreservesIntermediateTopologyWithinOneWireRead() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        XCTAssertEqual(try submit(.transportAttached(.sideChannel), to: handle), 0)
        XCTAssertEqual(try submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ]), to: handle), 0)
        XCTAssertEqual(feed(
            "%session-changed $1 work\n" +
                "%window-add @1\n" +
                "%window-add @2\n" +
                "%window-pane-changed @1 %10\n" +
                "%window-pane-changed @2 %20\n" +
                "%session-window-changed $1 @1\n",
            to: handle
        ), 0)

        capture.events.removeAll()
        XCTAssertEqual(feed(
            "%session-window-changed $1 @2\n" +
                "%output %20 foreign\n" +
                "%session-window-changed $1 @1\n",
            to: handle
        ), 0)

        let callback = try XCTUnwrap(try events(capture).last)
        let effects = callback["renderEffects"] as? [[String: Any]] ?? []
        let boundWindows = effects.compactMap { effect -> Int? in
            guard effect["kind"] as? String == "bindSurface",
                  let owner = effect["owner"] as? [String: Any]
            else { return nil }
            return (owner["windowID"] as? NSNumber)?.intValue
        }
        XCTAssertEqual(boundWindows, [2, 1])
    }

    func testRetainedFeedBytesSurviveMoreThanFiveHundredTwelveDelayedCallbackBatches() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), 0)
        XCTAssertEqual(try submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ]), to: handle), 0)
        XCTAssertEqual(feed(
            "%window-add @1\r\n%session-window-changed $0 @1\r\n%window-pane-changed @1 %1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 1 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 1 1 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 1 2 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 1 2 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 1 3 1\r\ninitial render payload\r\n%end 1 3 1\r\n",
            to: handle
        ), 0)
        let state = try latestEffect(named: "resolveSurfaceState", from: capture)
        let request = try XCTUnwrap((state["request"] as? NSNumber)?.uint64Value)
        XCTAssertEqual(try submit(.surfaceState(
            .live,
            request: request,
            altScreen: false,
            mouseMode: .off,
            columns: 80,
            rows: 24
        ), to: handle), 0)

        // Deliberately leave more than 512 callback batches unclaimed. A
        // promised ref survives callback return and later callbacks until the
        // adapter takes it or the transport/handle lifetime ends.
        let callbackCountBeforeOutputs = capture.events.count
        let payloads = (0..<600).map { "retained-feed-\($0)" }
        for payload in payloads {
            XCTAssertEqual(feed("%output %1 \(payload)\r\n", to: handle), 0)
        }
        let outputEvents = try capture.events.dropFirst(callbackCountBeforeOutputs).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        let feedEffects = outputEvents.flatMap { event in
            (event["renderEffects"] as? [[String: Any]] ?? []).filter {
                $0["kind"] as? String == "feed"
                    && $0["source"] as? String == "pane-output"
            }
        }
        XCTAssertEqual(feedEffects.count, payloads.count)
        let references = try feedEffects.map { effect in
            try XCTUnwrap(
                ((effect["bytesRef"] as? [String: Any])?["id"] as? NSNumber)?.uint64Value
            )
        }
        XCTAssertEqual(Set(references).count, payloads.count)

        let first = try XCTUnwrap(references.first)
        let firstSize = tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: first,
            outputBytes: nil,
            outputCapacity: 0
        )
        XCTAssertEqual(firstSize, Int32(payloads[0].utf8.count))
        var tooSmall = [UInt8](repeating: 0, count: Int(firstSize) - 1)
        XCTAssertEqual(tooSmall.withUnsafeMutableBytes { raw in
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: first,
                outputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                outputCapacity: raw.count
            )
        }, -1, "an insufficient second pass must leave the ref claimable")
        XCTAssertEqual(
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: first,
                outputBytes: nil,
                outputCapacity: 0
            ),
            firstSize
        )

        var firstBytes = [UInt8](repeating: 0, count: Int(firstSize))
        XCTAssertEqual(firstBytes.withUnsafeMutableBytes { raw in
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: first,
                outputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                outputCapacity: raw.count
            )
        }, firstSize)
        XCTAssertEqual(String(decoding: firstBytes, as: UTF8.self), payloads[0])

        let last = try XCTUnwrap(references.last)
        let lastSize = tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: last,
            outputBytes: nil,
            outputCapacity: 0
        )
        XCTAssertEqual(lastSize, Int32(payloads.last!.utf8.count))
        var lastBytes = [UInt8](repeating: 0, count: Int(lastSize))
        XCTAssertEqual(lastBytes.withUnsafeMutableBytes { raw in
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: last,
                outputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                outputCapacity: raw.count
            )
        }, lastSize)
        XCTAssertEqual(String(decoding: lastBytes, as: UTF8.self), payloads[599])
    }

    func testRenderLedgerExportsRejectMalformedAndStaleInputs() throws {
        let callback: TesseraCoreABIEventCallback = { _, _, _ in }
        let handle = tesseraTmuxRuntimeCreate(
            callback: callback,
            context: nil
        )
        let unversioned = Array(#"{"kind":"transportLost"}"#.utf8)
        XCTAssertEqual(unversioned.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, -1)
        let noncanonical = Array(#"{"version":1,"kind":"transportLost"}"#.utf8)
        XCTAssertEqual(noncanonical.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, -1, "the fact ABI requires sorted canonical JSON")
        let extended = Array(#"{"kind":"transportLost","unexpected":true,"version":1}"#.utf8)
        XCTAssertEqual(extended.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, -1, "unknown fields must not be silently ignored")
        for canonicalPoints in [
            "1", "9.9e-05", "1e+16", "-0",
            "5e-324", "-5e-324", "1e-323", "1.5e-323",
            "2.225073858507201e-308", "2.2250738585072014e-308",
            "2.225073858507202e-308", "1.7976931348623157e+308", "1e+23",
        ] {
            let validScroll = Array(
                "{\"isInertial\":false,\"kind\":\"scrollbackRequested\",\"pointsY\":\(canonicalPoints),\"surfaceID\":\"live\",\"version\":1}".utf8
            )
            XCTAssertEqual(validScroll.withUnsafeBytes { raw in
                tesseraTmuxRuntimeSubmitFact(
                    handle: handle,
                    json: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count
                )
            }, 0, "Kotlin's canonical Double spelling must cross the Swift ABI")
        }
        XCTAssertEqual(tesseraTmuxRuntimeSendCommand(handle: handle, text: nil, count: 0), -1)
        XCTAssertEqual(
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: 1,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -1
        )
        tesseraTmuxRuntimeDestroy(handle: handle)
        let validCommand = Array("display-message -p ready".utf8)
        XCTAssertEqual(validCommand.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSendCommand(
                handle: handle,
                text: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, -2)
        let validFact = Array(#"{"kind":"transportLost","version":1}"#.utf8)
        XCTAssertEqual(validFact.withUnsafeBytes { raw in
            tesseraTmuxRuntimeSubmitFact(
                handle: handle,
                json: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count
            )
        }, -2)
        XCTAssertEqual(
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: 1,
                outputBytes: nil,
                outputCapacity: 0
            ),
            -2
        )
    }

    func testDestroyWaitsForConcurrentCallbackBeforeReturning() throws {
        final class BarrierCapture: @unchecked Sendable {
            let callbackEntered = DispatchSemaphore(value: 0)
            let releaseCallback = DispatchSemaphore(value: 0)
        }
        let capture = BarrierCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let callback: TesseraCoreABIEventCallback = { _, _, context in
            guard let context else { return }
            let capture = Unmanaged<BarrierCapture>.fromOpaque(context).takeUnretainedValue()
            capture.callbackEntered.signal()
            _ = capture.releaseCallback.wait(timeout: .now() + 5)
        }
        let handle = tesseraTmuxRuntimeCreate(
            callback: callback,
            context: context
        )
        let operationFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? self.submit(.transportAttached(.inline), to: handle)
            operationFinished.signal()
        }
        XCTAssertEqual(capture.callbackEntered.wait(timeout: .now() + 2), .success)

        let destroyStarted = DispatchSemaphore(value: 0)
        let destroyReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            destroyStarted.signal()
            tesseraTmuxRuntimeDestroy(handle: handle)
            destroyReturned.signal()
        }
        XCTAssertEqual(destroyStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            destroyReturned.wait(timeout: .now() + 0.1),
            .timedOut,
            "destroy must wait while the callback is using its context"
        )
        capture.releaseCallback.signal()
        XCTAssertEqual(operationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(destroyReturned.wait(timeout: .now() + 2), .success)
        Unmanaged<BarrierCapture>.fromOpaque(context).release()

        XCTAssertEqual(try submit(.transportLost, to: handle), -2)
    }

    func testReentrantDestroySuppressesCallbackPayloadsQueuedByTheCurrentCallback() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        capture.handle = handle
        capture.reentrantFact = try SharedABI.encoder.encode(
            RenderFact.clientSize(columns: 80, rows: 24)
        )
        capture.destroyAfterReentrantFact = true

        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), -1)
        XCTAssertTrue(capture.submittedReentrantFact)
        XCTAssertTrue(capture.destroyedReentrantly)
        XCTAssertEqual(capture.maximumCallbackDepth, 1)
        XCTAssertEqual(capture.events.count, 1, "destroy must discard the callback queued by re-entry")
        XCTAssertEqual(try submit(.transportLost, to: handle), -2)
        Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
    }

    func testReentrantCallbackBurstIsBoundedAndRecoversAfterTheOuterCallback() throws {
        let fact = try SharedABI.encoder.encode(RenderFact.userInput)
        let capture = TmuxABIReentrantBurstCapture(fact: fact)
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIReentrantBurst,
            context: context
        )
        capture.handle = handle
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIReentrantBurstCapture>.fromOpaque(context).release()
        }

        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), 0)
        let accepted = capture.results.filter { $0 == 0 }.count
        let rejected = capture.results.filter { $0 == -1 }.count
        XCTAssertGreaterThan(accepted, 0)
        XCTAssertGreaterThan(rejected, 0)
        XCTAssertLessThan(accepted, capture.results.count)
        XCTAssertEqual(capture.callbackCount, accepted + 1)

        let callbacksBeforeRecovery = capture.callbackCount
        XCTAssertEqual(try submit(.userInput, to: handle), 0)
        XCTAssertEqual(capture.callbackCount, callbacksBeforeRecovery + 1)
    }

    func testReentrantTransportLossSuppressesUndeliveredOldTransportPartitions() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        capture.handle = handle
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        try establishInlineSurface(handle: handle, capture: capture)
        capture.events.removeAll(keepingCapacity: true)
        capture.reentrantFact = try SharedABI.encoder.encode(RenderFact.transportLost)

        // One parser feed stays under the input ceiling but produces enough
        // small effect records to require several independently valid callback
        // envelopes. Loss from callback #1 must cull every older partition.
        let framed = (0..<4_100).map { "%output %1 p\($0 % 10)\r\n" }.joined()
        XCTAssertLessThan(framed.utf8.count, CoreABICommand.maximumPayloadBytes)
        XCTAssertEqual(feed(framed, to: handle), -1)
        XCTAssertTrue(capture.submittedReentrantFact)
        XCTAssertGreaterThanOrEqual(capture.events.count, 2)

        let callbackEvents = try events(capture)
        let firstEffects = callbackEvents.first?["renderEffects"] as? [[String: Any]] ?? []
        XCTAssertTrue(firstEffects.contains { $0["kind"] as? String == "feed" })
        let feedsAfterLoss = callbackEvents.dropFirst().flatMap { event in
            (event["renderEffects"] as? [[String: Any]] ?? []).filter {
                $0["kind"] as? String == "feed"
            }
        }
        XCTAssertTrue(
            feedsAfterLoss.isEmpty,
            "no queued pre-loss partition may deliver already-revoked byte refs"
        )
    }

    func testTinyRetainedFeedsHitReferenceBudgetWithoutEvictingPromisedRefs() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        try establishInlineSurface(handle: handle, capture: capture)
        let initialRef = try bytesReference(in: latestEffect(named: "feed", from: capture))
        let initialSize = tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: initialRef,
            outputBytes: nil,
            outputCapacity: 0
        )
        var initialBytes = [UInt8](repeating: 0, count: Int(initialSize))
        XCTAssertEqual(initialBytes.withUnsafeMutableBytes { raw in
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: initialRef,
                outputBytes: raw.bindMemory(to: UInt8.self).baseAddress,
                outputCapacity: raw.count
            )
        }, initialSize)
        capture.events.removeAll(keepingCapacity: true)

        let framed = (0..<4_100).map { "%output %1 x\($0 % 10)\r\n" }.joined()
        XCTAssertLessThan(framed.utf8.count, CoreABICommand.maximumPayloadBytes)
        XCTAssertEqual(feed(framed, to: handle), -1)
        let feedEffects = try events(capture).flatMap { event in
            (event["renderEffects"] as? [[String: Any]] ?? []).filter {
                $0["kind"] as? String == "feed"
            }
        }
        XCTAssertEqual(feedEffects.count, 4_096)
        let firstRef = try bytesReference(in: try XCTUnwrap(feedEffects.first))
        XCTAssertEqual(
            tesseraTmuxRuntimeTakeRenderBytes(
                handle: handle,
                bytesRef: firstRef,
                outputBytes: nil,
                outputCapacity: 0
            ),
            2,
            "hitting the ref budget must not evict an earlier promised payload"
        )

        XCTAssertEqual(try submit(.refreshRequested(
            .live,
            stage: .viewportOnly,
            reason: "recover-at-reference-cap"
        ), to: handle), 0)
        XCTAssertEqual(feed(
            "%begin 2 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 2 1 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 2 2 1\r\nauthoritative recovery at ref cap\r\n%end 2 2 1\r\n",
            to: handle
        ), 0)
        let state = try latestEffect(named: "resolveSurfaceState", from: capture)
        let request = try XCTUnwrap((state["request"] as? NSNumber)?.uint64Value)
        XCTAssertEqual(try submit(.surfaceState(
            .live,
            request: request,
            altScreen: false,
            mouseMode: .off,
            columns: 80,
            rows: 24
        ), to: handle), -1, "new render work must be rejected at the ref cap")
        XCTAssertEqual(tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: firstRef,
            outputBytes: nil,
            outputCapacity: 0
        ), 2, "resource refusal must not revoke an already promised ref")
    }

    func testOversizedEffectBatchIsLosslesslyPartitionedBelowCallbackLimit() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        let replyCount = 20_000
        var expectedTags: [Int64] = []
        expectedTags.reserveCapacity(replyCount)
        let command = Array("display-message -p x".utf8)
        for _ in 0..<replyCount {
            expectedTags.append(command.withUnsafeBytes { raw in
                tesseraTmuxRuntimeSendCommand(
                    handle: handle,
                    text: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count
                )
            })
        }
        XCTAssertTrue(expectedTags.allSatisfy { $0 > 0 })

        let replies = (1...replyCount).map {
            "%begin 1 \($0) 1\r\nx\r\n%end 1 \($0) 1\r\n"
        }.joined()
        XCTAssertLessThan(replies.utf8.count, CoreABICommand.maximumPayloadBytes)
        XCTAssertEqual(feed(replies, to: handle), 0)
        XCTAssertGreaterThan(capture.events.count, 1)
        XCTAssertTrue(capture.events.allSatisfy {
            $0.count <= CoreABICommand.maximumPayloadBytes
        })

        let replyEffects = try events(capture).flatMap { event in
            (event["renderEffects"] as? [[String: Any]] ?? []).filter {
                $0["kind"] as? String == "commandReply"
            }
        }
        XCTAssertEqual(replyEffects.count, replyCount)
        XCTAssertEqual(
            replyEffects.compactMap { ($0["tag"] as? NSNumber)?.int64Value },
            expectedTags
        )
    }

    func testRetainedBytesHaveAggregateByteBoundWithoutEvictingPromisedReferences() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        try establishInlineSurface(handle: handle, capture: capture)
        let payload = String(repeating: "z", count: 512 * 1024)
        let framed = "%output %1 \(payload)\r\n"
        XCTAssertLessThan(framed.utf8.count, CoreABICommand.maximumPayloadBytes)

        var acceptedRefs: [UInt64] = []
        var rejected = false
        for _ in 0..<32 {
            let result = feed(framed, to: handle)
            if result == 0 {
                acceptedRefs.append(try bytesReference(in: latestEffect(named: "feed", from: capture)))
            } else {
                rejected = true
                break
            }
        }
        XCTAssertTrue(rejected, "a stalled consumer must hit the aggregate byte budget")
        XCTAssertGreaterThan(acceptedRefs.count, 1)

        let firstRef = try XCTUnwrap(acceptedRefs.first)
        let lastRef = try XCTUnwrap(acceptedRefs.last)
        let firstSize = tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: firstRef,
            outputBytes: nil,
            outputCapacity: 0
        )
        XCTAssertEqual(firstSize, Int32(payload.utf8.count), "budget refusal must not evict a promised ref")
        XCTAssertEqual(tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: lastRef,
            outputBytes: nil,
            outputCapacity: 0
        ), Int32(payload.utf8.count))

        var copied = [UInt8](repeating: 0, count: Int(firstSize))
        XCTAssertEqual(tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: firstRef,
            outputBytes: &copied,
            outputCapacity: copied.count
        ), firstSize)
        XCTAssertEqual(feed(framed, to: handle), 0, "consuming a ref must free aggregate byte budget")
    }

    func testSameOwnerAuthoritativeGenerationDoesNotRevokePromisedBytes() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        try establishInlineSurface(handle: handle, capture: capture)
        let oldRef = try bytesReference(in: latestEffect(named: "feed", from: capture))

        XCTAssertEqual(try submit(.refreshRequested(
            .live,
            stage: .viewportOnly,
            reason: "abi-same-owner"
        ), to: handle), 0)
        XCTAssertEqual(feed(
            "%begin 2 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 2 1 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 2 2 1\r\nnew authoritative payload\r\n%end 2 2 1\r\n",
            to: handle
        ), 0)
        let state = try latestEffect(named: "resolveSurfaceState", from: capture)
        let request = try XCTUnwrap((state["request"] as? NSNumber)?.uint64Value)
        XCTAssertEqual(try submit(.surfaceState(
            .live,
            request: request,
            altScreen: false,
            mouseMode: .off,
            columns: 80,
            rows: 24
        ), to: handle), 0)
        let newRef = try bytesReference(in: latestEffect(named: "feed", from: capture))
        XCTAssertNotEqual(newRef, oldRef)
        XCTAssertGreaterThan(tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: oldRef,
            outputBytes: nil,
            outputCapacity: 0
        ), 0, "a later generation cannot revoke a ref already delivered to the adapter")
        XCTAssertGreaterThan(tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: newRef,
            outputBytes: nil,
            outputCapacity: 0
        ), 0)
    }

    func testPromisedBytesSurviveAttachButTransportLossRevokesThem() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        try establishInlineSurface(handle: handle, capture: capture)
        let reference = try bytesReference(in: latestEffect(named: "feed", from: capture))
        let size = tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: reference,
            outputBytes: nil,
            outputCapacity: 0
        )
        XCTAssertGreaterThan(size, 0)

        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), 0)
        XCTAssertEqual(tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: reference,
            outputBytes: nil,
            outputCapacity: 0
        ), size, "attach alone must not revoke a promised reference")

        XCTAssertEqual(try submit(.transportLost, to: handle), 0)
        XCTAssertEqual(tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: reference,
            outputBytes: nil,
            outputCapacity: 0
        ), -1, "transport loss ends every promised-reference lifetime")
    }

    func testTransportReattachUsesRetainedLogicalTopologyUntilParserRehydrates() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        XCTAssertEqual(feed(
            "%session-changed $0 work\r\n%window-add @1\r\n%window-pane-changed @1 %1\r\n%session-window-changed $0 @1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(try submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ]), to: handle), 0)
        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), 0)
        XCTAssertEqual(try submit(.clientSize(columns: 80, rows: 24), to: handle), 0)
        XCTAssertEqual(try submit(.transportLost, to: handle), 0)

        capture.events.removeAll(keepingCapacity: true)
        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), 0)
        let effects = try events(capture).flatMap {
            $0["renderEffects"] as? [[String: Any]] ?? []
        }
        XCTAssertTrue(effects.contains { effect in
            guard effect["kind"] as? String == "sendCommand",
                  let command = effect["command"] as? String
            else { return false }
            return command.hasPrefix("display-message -p -t @1 ")
        }, "reattach must repaint the retained @1 target before fresh parser hydration")

        XCTAssertEqual(feed(
            "%begin 2 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 2 1 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 2 2 1\r\nreattached authoritative payload\r\n%end 2 2 1\r\n",
            to: handle
        ), 0)
        let reattachedState = try latestEffect(named: "resolveSurfaceState", from: capture)
        let reattachedRequest = try XCTUnwrap(
            (reattachedState["request"] as? NSNumber)?.uint64Value
        )
        XCTAssertEqual(try submit(.surfaceState(
            .live,
            request: reattachedRequest,
            altScreen: false,
            mouseMode: .off,
            columns: 80,
            rows: 24
        ), to: handle), 0)

        capture.events.removeAll(keepingCapacity: true)
        XCTAssertEqual(feed("%window-add @2\r\n%window-pane-changed @2 %2\r\n", to: handle), 0)
        XCTAssertEqual(feed("%session-window-changed $9 @2\r\n", to: handle), 0)
        XCTAssertEqual(feed(
            "%begin 9 9 0\r\n__tessera_active_window__\t@2\r\n%end 9 9 0\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(try submit(.refreshRequested(
            .live,
            stage: .viewportOnly,
            reason: "pre-authority-window-add"
        ), to: handle), 0)
        let preAuthorityCommands = try events(capture).flatMap { event in
            event["renderEffects"] as? [[String: Any]] ?? []
        }.compactMap { effect in
            effect["kind"] as? String == "sendCommand" ? effect["command"] as? String : nil
        }
        XCTAssertTrue(preAuthorityCommands.contains { $0.contains(" -t @1 ") })
        XCTAssertFalse(
            preAuthorityCommands.contains { $0.contains(" -t @2 ") },
            "a split-read window-add fallback must not replace the retained ledger target"
        )
        XCTAssertEqual(feed(
            "%begin 3 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 3 1 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 3 2 1\r\nretained target refresh\r\n%end 3 2 1\r\n",
            to: handle
        ), 0)
        let retainedState = try latestEffect(named: "resolveSurfaceState", from: capture)
        let retainedRequest = try XCTUnwrap((retainedState["request"] as? NSNumber)?.uint64Value)
        XCTAssertEqual(try submit(.surfaceState(
            .live,
            request: retainedRequest,
            altScreen: false,
            mouseMode: .off,
            columns: 80,
            rows: 24
        ), to: handle), 0)

        capture.events.removeAll(keepingCapacity: true)
        XCTAssertEqual(feed("%session-window-changed $0 @2\r\n", to: handle), 0)
        let unprovenEffects = try events(capture).flatMap { event in
            event["renderEffects"] as? [[String: Any]] ?? []
        }
        XCTAssertFalse(unprovenEffects.contains { effect in
            guard effect["kind"] as? String == "sendCommand",
                  let command = effect["command"] as? String
            else { return false }
            return command.contains(" -t @2 ")
        }, "a session broadcast without this client's identity is not a rehydration cut")

        capture.events.removeAll(keepingCapacity: true)
        XCTAssertEqual(feed("%session-changed $0 work\r\n", to: handle), 0)
        XCTAssertEqual(try submit(.refreshRequested(
            .live,
            stage: .viewportOnly,
            reason: "post-authority-session"
        ), to: handle), 0)
        let postAuthorityEffects = try events(capture).flatMap { event in
            event["renderEffects"] as? [[String: Any]] ?? []
        }
        XCTAssertTrue(postAuthorityEffects.contains { effect in
            guard effect["kind"] as? String == "sendCommand",
                  let command = effect["command"] as? String
            else { return false }
            return command.contains(" -t @2 ")
        }, "the explicit session active-window signal must release rehydration onto @2")
    }


    /// The settling effect reaches a platform through the ordinary render
    /// event stream, under the keys both Kotlin and Swift readers index.
    func testInlineHistorySettledCrossesTheEventStreamWithItsCanDeepenFlag() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        try establishInlineSurface(handle: handle, capture: capture)
        let settled = try latestEffect(named: "inlineHistorySettled", from: capture)
        XCTAssertEqual(
            Set(settled.keys),
            ["kind", "surfaceID", "owner", "depth", "historySize", "canDeepen"],
            "the wire shape is the contract; an added or renamed key is an ABI break"
        )
        XCTAssertEqual(settled["surfaceID"] as? String, "live")
        let owner = try XCTUnwrap(settled["owner"] as? [String: Any])
        XCTAssertEqual((owner["windowID"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((owner["paneID"] as? NSNumber)?.intValue, 1)
        XCTAssertNotNil((owner["epoch"] as? NSNumber)?.uint64Value)
        // The whole (empty) history fitted in the first fill, so the surface
        // is credited with the full ladder depth and cannot deepen further.
        XCTAssertEqual((settled["depth"] as? NSNumber)?.intValue, 10_000)
        XCTAssertEqual((settled["historySize"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(settled["canDeepen"] as? Bool, false)

        XCTAssertEqual(
            try JSONDecoder().decode(
                RenderEffect.self,
                from: try JSONSerialization.data(withJSONObject: settled, options: [.sortedKeys])
            ),
            .inlineHistorySettled(
                .live,
                owner: .init(
                    windowID: WindowId(1),
                    paneID: PaneId(1),
                    epoch: try XCTUnwrap((owner["epoch"] as? NSNumber)?.uint64Value)
                ),
                depth: 10_000,
                historySize: 0,
                canDeepen: false
            )
        )

        // The reader's gesture is answered from ledger state once exhausted,
        // so the platform's single-flight latch is released without a capture.
        capture.events.removeAll(keepingCapacity: true)
        XCTAssertEqual(try submit(
            .scrollbackRequested(.live, pointsY: 1, isInertial: false),
            to: handle
        ), 0)
        let answered = try latestEffect(named: "inlineHistorySettled", from: capture)
        XCTAssertEqual(answered["canDeepen"] as? Bool, false)
        XCTAssertFalse(
            try events(capture)
                .flatMap { $0["renderEffects"] as? [[String: Any]] ?? [] }
                .contains { $0["kind"] as? String == "sendCommand" },
            "an exhausted surface must not spend a capture answering the gesture"
        )
    }

    /// A full-depth inline history capture of a wide pane runs to several
    /// hundred kilobytes and can pass two megabytes; the former 1 MiB render
    /// ceiling dropped exactly those frames, which is the deepest rung of the
    /// SSH+tmux scrollback ladder.
    func testRenderFeedLargerThanTheArgumentCeilingIsDeliveredNotDropped() throws {
        let capture = TmuxABIRenderEventCapture()
        let context = Unmanaged.passRetained(capture).toOpaque()
        let handle = tesseraTmuxRuntimeCreate(
            callback: receiveTmuxABIRenderEvent,
            context: context
        )
        defer {
            tesseraTmuxRuntimeDestroy(handle: handle)
            Unmanaged<TmuxABIRenderEventCapture>.fromOpaque(context).release()
        }

        try establishInlineSurface(handle: handle, capture: capture)
        capture.events.removeAll(keepingCapacity: true)

        XCTAssertEqual(try submit(
            .refreshRequested(.live, stage: .deep, reason: "deepen"),
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 2 4 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 2 4 1\r\n",
            to: handle
        ), 0)

        // 12 000 rows of a 200-column pane: the shape of a real
        // `capture-pane -p -e -N -S -10000` reply, not one impossible line.
        let row = String(repeating: "r", count: 200)
        var reply = "%begin 2 5 1\r\n"
        for _ in 0..<12_000 {
            reply += row
            reply += "\r\n"
        }
        reply += "%end 2 5 1\r\n"
        XCTAssertGreaterThan(reply.utf8.count, 2 * 1_024 * 1_024)

        // The transport hands the reply over in reads no larger than the
        // argument ceiling, exactly as a real control connection does.
        var offset = reply.startIndex
        while offset < reply.endIndex {
            let end = reply.index(offset, offsetBy: 512 * 1_024, limitedBy: reply.endIndex) ?? reply.endIndex
            XCTAssertEqual(feed(String(reply[offset..<end]), to: handle), 0)
            offset = end
        }

        let state = try latestEffect(named: "resolveSurfaceState", from: capture)
        let request = try XCTUnwrap((state["request"] as? NSNumber)?.uint64Value)
        capture.events.removeAll(keepingCapacity: true)
        XCTAssertEqual(try submit(.surfaceState(
            .live,
            request: request,
            altScreen: false,
            mouseMode: .off,
            columns: 200,
            rows: 24
        ), to: handle), 0)

        let dropped = try events(capture)
            .flatMap { $0["renderEffects"] as? [[String: Any]] ?? [] }
            .compactMap { $0["message"] as? String }
            .filter { $0.contains("dropped-oversized-bytes") || $0.contains("render-bytes-too-large") }
        XCTAssertTrue(dropped.isEmpty, "a multi-megabyte deep repaint must not be dropped: \(dropped)")

        let reference = try bytesReference(in: latestEffect(named: "feed", from: capture))
        let required = tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: reference,
            outputBytes: nil,
            outputCapacity: 0
        )
        XCTAssertGreaterThan(
            required,
            Int32(2 * 1_024 * 1_024),
            "the promised payload is the whole deep repaint, past the 1 MiB argument ceiling"
        )
        XCTAssertLessThanOrEqual(Int(required), SharedABI.maximumRenderBytes)
        var copied = [UInt8](repeating: 0, count: Int(required))
        XCTAssertEqual(tesseraTmuxRuntimeTakeRenderBytes(
            handle: handle,
            bytesRef: reference,
            outputBytes: &copied,
            outputCapacity: copied.count
        ), required, "a payload above the argument ceiling must still copy out in one call")
        XCTAssertTrue(copied.contains(UInt8(ascii: "r")))
    }

    private func bytesReference(in effect: [String: Any]) throws -> UInt64 {
        try XCTUnwrap(
            ((effect["bytesRef"] as? [String: Any])?["id"] as? NSNumber)?.uint64Value
        )
    }

    private func establishInlineSurface(
        handle: UnsafeMutableRawPointer,
        capture: TmuxABIRenderEventCapture
    ) throws {
        XCTAssertEqual(try submit(.transportAttached(.inline), to: handle), 0)
        XCTAssertEqual(try submit(.surfacesDeclared([
            .init(surfaceID: .live, presentation: .single),
        ]), to: handle), 0)
        XCTAssertEqual(feed(
            "%window-add @1\r\n%session-window-changed $0 @1\r\n%window-pane-changed @1 %1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 1 1 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 1 1 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 1 2 1\r\n%1\t0\t0\t\twindow\thost\t0\r\n%end 1 2 1\r\n",
            to: handle
        ), 0)
        XCTAssertEqual(feed(
            "%begin 1 3 1\r\ninitial authoritative payload\r\n%end 1 3 1\r\n",
            to: handle
        ), 0)
        let state = try latestEffect(named: "resolveSurfaceState", from: capture)
        let request = try XCTUnwrap((state["request"] as? NSNumber)?.uint64Value)
        XCTAssertEqual(try submit(.surfaceState(
            .live,
            request: request,
            altScreen: false,
            mouseMode: .off,
            columns: 80,
            rows: 24
        ), to: handle), 0)
    }
}
