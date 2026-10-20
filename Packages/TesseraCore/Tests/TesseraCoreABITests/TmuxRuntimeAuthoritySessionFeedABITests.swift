import Foundation
import XCTest
import TmuxControlCore
@testable import TesseraCoreABI

private final class SessionFeedABITrace: @unchecked Sendable {
    var events: [[String: Any]] = []
    var errors: [String] = []
    var onEvent: (() -> Void)?
}

private let receiveSessionFeedABIEvent: TesseraCoreABIEventCallback = { bytes, count, context in
    guard let bytes, let context else { return }
    let trace = Unmanaged<SessionFeedABITrace>.fromOpaque(context).takeUnretainedValue()
    guard let event = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: count))
        as? [String: Any] else {
        trace.errors.append("callback was not a JSON object")
        return
    }
    trace.events.append(event)
    trace.onEvent?()
}

/// An authority session on the lifecycle ABI, as Android's adapter holds it.
private final class LifecycleSession {
    let handle: UnsafeMutableRawPointer

    init(seed: Int64 = 100) {
        handle = tesseraTmuxAuthorityLifecycleCreateSeeded(initialGeneration: seed)!
    }

    deinit { tesseraTmuxAuthorityLifecycleDestroy(handle: handle) }

    /// A version 2 request at `now`; nil when the core rejected it.
    func reduce(_ event: String, at now: Int64, _ fields: [String: Any] = [:]) -> [String: Any]? {
        var request = fields
        request["version"] = 2
        request["event"] = event
        request["nowMillis"] = now
        let input = try! JSONSerialization.data(withJSONObject: request)
        let capacity = TmuxAuthorityLifecycleABI.maximumPayloadBytes
        var output = [UInt8](repeating: 0, count: capacity)
        let count = input.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                tesseraTmuxAuthorityLifecycleReduce(
                    handle: handle,
                    requestBytes: inputRaw.bindMemory(to: UInt8.self).baseAddress,
                    requestCount: input.count,
                    outputBytes: outputRaw.bindMemory(to: UInt8.self).baseAddress,
                    outputCapacity: capacity
                )
            }
        }
        guard count > 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output.prefix(Int(count)))) as? [String: Any]
    }

    func snapshot(at now: Int64) -> NSDictionary {
        NSDictionary(dictionary: reduce("snapshot", at: now) ?? [:])
    }
}

/// One runtime handle fed through the ABI, its events kept in order.
private final class SessionFeedHarness {
    let trace = SessionFeedABITrace()
    let handle: UnsafeMutableRawPointer
    private let context: UnsafeMutableRawPointer

    init() {
        let context = Unmanaged.passRetained(trace).toOpaque()
        self.context = context
        handle = tesseraTmuxRuntimeCreate(callback: receiveSessionFeedABIEvent, context: context)
    }

    deinit {
        tesseraTmuxRuntimeDestroy(handle: handle)
        Unmanaged<SessionFeedABITrace>.fromOpaque(context).release()
    }

    func feed(_ text: String, at nowMillis: Int64? = nil) -> Int32 {
        Array(text.utf8).withUnsafeBytes { raw in
            guard let nowMillis else {
                return tesseraTmuxRuntimeFeed(
                    handle: handle,
                    bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count
                )
            }
            return tesseraTmuxRuntimeFeedAt(
                handle: handle,
                bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                count: raw.count,
                nowMillis: nowMillis
            )
        }
    }

    func attach(_ session: LifecycleSession?) -> Int32 {
        tesseraTmuxRuntimeAttachAuthoritySession(handle: handle, session: session?.handle)
    }

    func redeliver(at nowMillis: Int64) -> Int32 {
        tesseraTmuxRuntimeRedeliverAuthorityResult(handle: handle, nowMillis: nowMillis)
    }

    func resync() -> Int32 {
        tesseraTmuxRuntimeResyncSnapshot(handle: handle)
    }
}

/// S3′ step 3 (§6.17): Android's runtime handle hosts the authority session.
/// A read's stamp edges are reduced at their place in the read, as iOS
/// reduces each message, and the session's answer rides in the read's own
/// event: no further call for a stamp that changes the verdict, nothing at
/// all for one that does not, and a peer's stamp judges the relayout that
/// follows it in the same read.
final class TmuxRuntimeAuthoritySessionFeedABITests: XCTestCase {
    private static let mac = "v1 MAC 7 Mac"
    private static let own = "v1 SELF 9 iPad"
    private let paneOne = "pane:1"
    private let paneTwo = "pane:2"
    private let deepOne = RenderCommands.deepPrimary(target: PaneId(1), depth: 2_000)
    private let deepTwo = RenderCommands.deepPrimary(target: PaneId(2), depth: 2_000)

    private static func stamp(_ raw: String, session: Int = 0, pane: Int = 1) -> String {
        "%subscription-changed tessera-authority $\(session) @1 0 %\(pane) : \(raw)\r\n"
    }

    private func layout(firstWidth: Int) -> String {
        "abcd,80x24,0,0{\(firstWidth)x24,0,0,1,\(79 - firstWidth)x24,\(firstWidth + 1),0,2}"
    }

    private func relayoutLine(_ wire: GridReleaseABIWire, firstWidth: Int) -> String {
        wire.paneWidths = [paneOne: firstWidth, paneTwo: 79 - firstWidth]
        return "%layout-change @1 \(layout(firstWidth: firstWidth)) \(layout(firstWidth: firstWidth)) *\r\n"
    }

    private func attachedSession(seed: Int64 = 100) -> LifecycleSession {
        let session = LifecycleSession(seed: seed)
        XCTAssertNotNil(session.reduce("attached", at: 0, ["localDeviceID": "SELF"]))
        return session
    }

    /// A split window whose two grid panes were painted by a deep first fill,
    /// with nobody's stamp seen yet.
    private func paintedGrid() -> GridReleaseABIWire {
        let wire = GridReleaseABIWire()
        wire.setOptions([.suppressesUnchangedClientSizeReplay, .pipelinesVisibleCapture])
        wire.submit(.transportAttached(.inline))
        wire.feed("%session-changed $0 work\r\n%window-add @1\r\n%session-window-changed $0 @1\r\n"
            + "%window-pane-changed @1 %1\r\n")
        wire.feed(relayoutLine(wire, firstWidth: 40))
        wire.submit(.surfacesDeclared([
            .init(surfaceID: SurfaceId(paneOne), presentation: .grid, windowID: WindowId(1), paneID: PaneId(1)),
            .init(surfaceID: SurfaceId(paneTwo), presentation: .grid, windowID: WindowId(1), paneID: PaneId(2)),
        ]))
        wire.drain()
        for surface in [paneOne, paneTwo] {
            wire.submit(.refreshRequested(SurfaceId(surface), stage: .deep, reason: "mount"))
            wire.drain()
        }
        XCTAssertEqual(Set(wire.deepCaptures), [deepOne, deepTwo], "precondition: both panes painted deep \(wire.sent)")
        wire.resetObservations()
        return wire
    }

    /// The events since `index` that carried a session response or raw edges.
    private func authorityEvents(_ events: [[String: Any]], since index: Int) -> [[String: Any]] {
        events.dropFirst(index).filter {
            $0["authoritySession"] != nil || !(($0["authorityStamps"] as? [String]) ?? []).isEmpty
        }
    }

    // MARK: - Wire order

    /// P7 for Android: a peer's stamp and its relayout arrive in one read.
    /// Projected after the whole read, the relayout was judged as ours and
    /// cost every painted pane a capture; reduced at its step, it costs none.
    func testAPeerStampAndItsRelayoutInOneReadCostNoCapture() throws {
        let wire = paintedGrid()
        let session = attachedSession()
        XCTAssertEqual(tesseraTmuxRuntimeAttachAuthoritySession(handle: wire.handle, session: session.handle), 0)
        let before = wire.trace.events.count

        wire.feed(Self.stamp(Self.mac) + relayoutLine(wire, firstWidth: 30), at: 10)
        wire.drain()

        XCTAssertEqual(wire.sent, [], "the relayout is judged under the peer its read named first")
        let events = authorityEvents(wire.trace.events, since: before)
        XCTAssertEqual(events.count, 1, "one response, in the read's own event")
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["authorityStamps"] as? [String], [], "the session reduced the edge")
        let response = try XCTUnwrap(event["authoritySession"] as? [String: Any])
        XCTAssertEqual(response["authorityKind"] as? String, "peer")
        XCTAssertEqual(response["authorityDeviceID"] as? String, "MAC")
        let snapshot = try XCTUnwrap(event["snapshot"] as? [String: Any], "the projection moved the snapshot")
        XCTAssertNotNil((snapshot["authority"] as? [String: Any])?["peer"], "\(snapshot["authority"] ?? "nil")")
        XCTAssertEqual(session.reduce("snapshot", at: 10)?["authorityKind"] as? String, "peer")
        XCTAssertTrue(wire.trace.errors.isEmpty, "\(wire.trace.errors)")
    }

    /// The control: the same read with no session reduces nothing, so the
    /// relayout is judged under the old verdict and the edge is the adapter's.
    func testWithoutASessionThatReadIsJudgedUnderTheOldVerdict() throws {
        let wire = paintedGrid()
        let before = wire.trace.events.count

        wire.feed(Self.stamp(Self.mac) + relayoutLine(wire, firstWidth: 30), at: 10)
        wire.drain()

        XCTAssertFalse(wire.sent.filter { $0.hasPrefix("capture-pane") }.isEmpty, "\(wire.sent)")
        let event = try XCTUnwrap(authorityEvents(wire.trace.events, since: before).first)
        XCTAssertEqual(event["authorityStamps"] as? [String], [Self.mac])
        XCTAssertNil(event["authoritySession"])
    }

    /// A stamp never lifts a peer (only a read or a claim does, and the
    /// adapter projects those): the relayout the in-read projection skipped
    /// is owed, and the adapter's later mine projection pays it.
    func testTheRelayoutSkippedUnderAnInReadPeerIsRepaidAtTheNextOwnProjection() throws {
        let wire = paintedGrid()
        let session = attachedSession()
        XCTAssertEqual(tesseraTmuxRuntimeAttachAuthoritySession(handle: wire.handle, session: session.handle), 0)
        wire.feed(Self.stamp(Self.mac) + relayoutLine(wire, firstWidth: 30), at: 10)
        wire.drain()
        XCTAssertEqual(wire.sent, [])

        wire.feed(Self.stamp(Self.own), at: 20)
        XCTAssertEqual(session.reduce("snapshot", at: 20)?["authorityKind"] as? String, "peer", "an own echo")
        wire.drain()
        XCTAssertEqual(wire.sent, [])

        try wire.settleReleasing(generation: 9)
        wire.drain()
        XCTAssertEqual(Set(wire.bound), [paneOne, paneTwo], "rebuilt under fresh owners")
        XCTAssertEqual(Set(wire.deepCaptures), [deepOne, deepTwo], "\(wire.sent)")
        XCTAssertTrue(wire.trace.errors.isEmpty, "\(wire.trace.errors)")
    }

    /// A later read repeating the stamp the session already holds costs
    /// nothing: no response and no raw edge for the adapter to send back.
    func testAnUnchangedEdgeCarriesNothing() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n%window-add @1\r\n"), 0)
        XCTAssertEqual(harness.feed(Self.stamp(Self.mac), at: 10), 1, "the feed reports the result it carried")
        XCTAssertNotNil(harness.trace.events.last?["authoritySession"])

        XCTAssertEqual(harness.feed(Self.stamp(Self.mac, pane: 2), at: 20), 0)
        let last = try XCTUnwrap(harness.trace.events.last)
        XCTAssertNil(last["authoritySession"])
        XCTAssertEqual(last["authorityStamps"] as? [String], [])
    }

    /// A read whose verdicts end where they began publishes none of them:
    /// its steps were judged under each, but the runtime rebuilt no
    /// topology for a verdict the read itself replaced.
    func testAnIntermediateVerdictIsNeverPublished() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n%window-add @1\r\n"), 0)
        XCTAssertEqual(harness.feed(Self.stamp(Self.mac), at: 10), 1)
        XCTAssertNotNil(harness.trace.events.last?["snapshot"], "precondition: the verdict was published")

        XCTAssertEqual(harness.feed(Self.stamp("v1 PEER 8 iPad") + Self.stamp(Self.mac, pane: 2), at: 20), 1)

        let event = try XCTUnwrap(harness.trace.events.last)
        let response = try XCTUnwrap(event["authoritySession"] as? [String: Any])
        XCTAssertEqual(response["authorityDeviceID"] as? String, "MAC")
        XCTAssertEqual((response["trace"] as? String)?.components(separatedBy: "\n").count, 2, "both reduced")
        XCTAssertNil(event["snapshot"], "the published authority ended where it began")
    }

    /// The response is the lifecycle ABI's own answer to the same edges:
    /// Android applies it exactly as that call's result.
    func testTheResponseIsTheLifecycleReplyToTheSameEdges() throws {
        let harness = SessionFeedHarness()
        let hosted = attachedSession(seed: 300)
        let twin = attachedSession(seed: 300)
        XCTAssertEqual(harness.attach(hosted), 0)
        // The topology read's own edges, mirrored in the twin.
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n%window-add @1\r\n", at: 0), 1)
        XCTAssertEqual(reduced(try lastResponse(harness)), ["controlSessionChanged(resolved)", "windowFacts(hydrating @1 - provisional)"])
        XCTAssertNotNil(twin.reduce("controlSessionChanged", at: 0, ["replacedKnownSession": false]))
        XCTAssertNotNil(twin.reduce("windowFacts", at: 0, ["windowListHydrated": false, "windowID": 1, "windowAuthoritative": false]))

        XCTAssertEqual(harness.feed(Self.stamp(Self.mac) + "%window-renamed @1 x\r\n" + Self.stamp(Self.own), at: 40), 1)

        let hostedResponse = try XCTUnwrap(harness.trace.events.last?["authoritySession"] as? [String: Any])
        let twinResponse = try XCTUnwrap(twin.reduce("stampObserved", at: 40, ["rawValues": [Self.mac, Self.own]]))
        XCTAssertEqual(NSDictionary(dictionary: hostedResponse), NSDictionary(dictionary: twinResponse))
        XCTAssertEqual((hostedResponse["trace"] as? String)?.components(separatedBy: "\n").count, 2)
        XCTAssertEqual(hosted.snapshot(at: 40), twin.snapshot(at: 40))
    }

    // MARK: - Reads the adapter still reduces

    private func assertRawEdge(
        _ harness: SessionFeedHarness,
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let last = harness.trace.events.last
        XCTAssertEqual(last?["authorityStamps"] as? [String], expected, file: file, line: line)
        XCTAssertNil(last?["authoritySession"], file: file, line: line)
    }

    func testWithoutAClockOrASessionTheEdgeIsTheAdapters() throws {
        let harness = SessionFeedHarness()
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        XCTAssertEqual(harness.feed(Self.stamp(Self.mac), at: 10), 0)
        assertRawEdge(harness, [Self.mac])

        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        let untouched = session.snapshot(at: 20)
        XCTAssertEqual(harness.feed(Self.stamp(Self.own)), 0)
        assertRawEdge(harness, [Self.own])
        XCTAssertEqual(session.snapshot(at: 20), untouched, "a read without the clock leaves the session alone")

        XCTAssertEqual(harness.attach(nil), 0)
        XCTAssertEqual(harness.feed(Self.stamp(Self.mac), at: 30), 0)
        assertRawEdge(harness, [Self.mac])
        XCTAssertEqual(session.snapshot(at: 20), untouched, "detached")
    }

    func testADestroyedSessionIsNoLongerReduced() throws {
        let harness = SessionFeedHarness()
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        var session: LifecycleSession? = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        session = nil
        XCTAssertEqual(harness.feed(Self.stamp(Self.mac), at: 10), 0)
        assertRawEdge(harness, [Self.mac])
    }

    // MARK: - Session changes and window facts at their steps (§6.18)

    /// The session's events this response reduced, in order.
    private func reduced(_ response: [String: Any]) -> [String] {
        ((response["trace"] as? String) ?? "").split(separator: "\n").compactMap { line in
            // A label may hold spaces; the authority field always follows it.
            guard let start = line.range(of: "event="),
                  let end = line.range(of: " authority=", range: start.upperBound..<line.endIndex)
            else { return nil }
            return String(line[start.upperBound..<end.lowerBound])
        }
    }

    private func lastResponse(_ harness: SessionFeedHarness, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(harness.trace.events.last?["authoritySession"] as? [String: Any], file: file, line: line)
    }

    private func effectKinds(_ response: [String: Any]) -> [String] {
        ((response["effects"] as? [[String: Any]]) ?? []).compactMap { $0["kind"] as? String }
    }

    private static let window80x24 = "__tessera_windows__\t@1\t0\t%1\tb25d,80x24,0,0,1\tb25d,80x24,0,0,1\t0\tone\r\n"

    /// A first resolution and a switch, each at its step: the switch resets
    /// the session there and attaches it again, and the adapter is told so.
    func testASessionChangeIsReducedAtItsStep() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n" + Self.stamp(Self.mac), at: 10), 1)
        var event = try XCTUnwrap(harness.trace.events.last)
        XCTAssertEqual(event["authorityReducedInFeed"] as? Bool, true)
        XCTAssertNil(event["controlSessionSwitched"], "a first resolution is no switch")
        XCTAssertEqual(event["authorityStamps"] as? [String], [])
        var response = try lastResponse(harness)
        XCTAssertEqual(reduced(response), ["controlSessionChanged(resolved)", "stampObserved"])
        XCTAssertEqual(response["authorityKind"] as? String, "peer")

        XCTAssertEqual(harness.feed("%session-changed $3 other\r\n", at: 20), 1)
        event = try XCTUnwrap(harness.trace.events.last)
        XCTAssertEqual(event["authorityReducedInFeed"] as? Bool, true)
        XCTAssertEqual(event["controlSessionSwitched"] as? Bool, true)
        response = try lastResponse(harness)
        XCTAssertEqual(reduced(response).first, "controlSessionChanged(switched)")
        XCTAssertEqual(reduced(response).last, "attached")
        XCTAssertEqual(response["authorityKind"] as? String, "unknown", "the old session's peer is gone")
        XCTAssertEqual(response["channelAttached"] as? Bool, true)
        XCTAssertTrue(effectKinds(response).contains("queryAuthority"), "\(effectKinds(response))")
        XCTAssertEqual(session.reduce("snapshot", at: 20)?["authorityKind"] as? String, "unknown")
    }

    /// A stamp the old session published spoke for that session: the
    /// switch after it in the same read resets the session it set.
    func testAStampBeforeASwitchDoesNotSpeakForTheNewSession() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)

        XCTAssertEqual(harness.feed(Self.stamp(Self.mac) + "%session-changed $3 other\r\n", at: 10), 1)

        let response = try lastResponse(harness)
        XCTAssertEqual(Array(reduced(response).prefix(2)), ["stampObserved", "controlSessionChanged(switched)"])
        XCTAssertEqual(response["authorityKind"] as? String, "unknown")
        XCTAssertNotNil(response["currentQueryID"], "the new session's attach read")
    }

    /// A read collapses a repeated stamp only within one session: the new
    /// session's first stamp is news even when it repeats the old one's
    /// last, as iOS, whose switch reset forgets the stamp, observes it.
    func testAStampRepeatedAfterASwitchSpeaksForTheNewSession() throws {
        let read = Self.stamp(Self.mac) + "%session-changed $3 other\r\n" + Self.stamp(Self.mac, session: 3)
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        XCTAssertEqual(harness.feed(read, at: 10), 1)
        let response = try lastResponse(harness)
        XCTAssertEqual(reduced(response).filter { $0 == "stampObserved" }.count, 2, "\(reduced(response))")
        XCTAssertEqual(response["authorityKind"] as? String, "peer")

        // Left to the adapter, the edge after the switch survives the trim.
        let unhosted = SessionFeedHarness()
        XCTAssertEqual(unhosted.feed("%session-changed $0 work\r\n"), 0)
        XCTAssertEqual(unhosted.feed(read), 0)
        assertRawEdge(unhosted, [Self.mac])
    }

    /// Leaving a session and returning in one read resets at each switch,
    /// as iOS does message by message: the other session's stamp never
    /// reaches the session the read ends in.
    func testAReadThatLeavesAndReturnsResetsAtEachSwitch() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)

        XCTAssertEqual(harness.feed(
            "%session-changed $3 other\r\n" + Self.stamp(Self.mac, session: 3) + "%session-changed $0 work\r\n",
            at: 10
        ), 1)

        XCTAssertEqual(harness.trace.events.last?["controlSessionSwitched"] as? Bool, true)
        let response = try lastResponse(harness)
        XCTAssertEqual(reduced(response).filter { $0 == "controlSessionChanged(switched)" }.count, 2, "\(reduced(response))")
        XCTAssertEqual(response["authorityKind"] as? String, "unknown")
    }

    /// The adapter reduces a read fed from a callback itself: it still
    /// learns of the switch, and gets only the edges after it.
    func testAReadLeftToTheAdapterKeepsOnlyTheStampsAfterItsLastSwitch() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        let untouched = session.snapshot(at: 10)
        var nested: Int32?
        harness.trace.onEvent = {
            guard nested == nil else { return }
            nested = harness.feed(
                Self.stamp(Self.mac) + "%session-changed $3 other\r\n" + Self.stamp(Self.own, session: 3),
                at: 10
            )
        }
        // Unclocked, the outer read is the adapter's too: only the nested one is under test.
        XCTAssertEqual(harness.feed("%window-add @1\r\n"), 0)
        harness.trace.onEvent = nil
        XCTAssertEqual(nested, 0)
        assertRawEdge(harness, [Self.own])
        let event = try XCTUnwrap(harness.trace.events.last)
        XCTAssertEqual(event["controlSessionSwitched"] as? Bool, true)
        XCTAssertNil(event["authorityReducedInFeed"])
        XCTAssertEqual(session.snapshot(at: 10), untouched)
    }

    /// A session whose show waits on an own-stamp reply held until the
    /// window is known.
    private func sessionHoldingAShowsOwnReply() throws -> LifecycleSession {
        let session = LifecycleSession()
        XCTAssertNotNil(session.reduce("localSize", at: 0, ["columns": 80, "rows": 24]))
        XCTAssertNotNil(session.reduce("attached", at: 0, ["localDeviceID": "SELF"]))
        // The show reads again for its intent: the attach's read cannot decide it.
        let shown = try XCTUnwrap(session.reduce("shown", at: 0, ["source": "show"]))
        let read = try XCTUnwrap(shown["currentQueryID"] as? Int)
        let held = try XCTUnwrap(session.reduce("queryReplied", at: 1, ["queryID": read, "rawAuthorityValue": Self.own]))
        XCTAssertNotNil(held["pendingIntent"], "precondition: the show waits on that reply")
        XCTAssertNil(held["currentQueryID"], "precondition: the reply is held, not outstanding")
        return session
    }

    /// The layout that resolves a show's held own reply is judged before a
    /// peer stamp later in the same read, as iOS reduces them message by
    /// message. Reported after the read's stamps, as the adapter did, the
    /// facts lost to the newer stamp, which decided the show instead.
    func testWindowFactsAreJudgedBeforeTheStampThatFollowsThem() throws {
        let harness = SessionFeedHarness()
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        let hosted = try sessionHoldingAShowsOwnReply()
        let inMessageOrder = try sessionHoldingAShowsOwnReply()
        let stampsFirst = try sessionHoldingAShowsOwnReply()
        XCTAssertEqual(harness.attach(hosted), 0)

        XCTAssertEqual(harness.feed(
            "%begin 1 1 1\r\n" + Self.window80x24 + "%end 1 1 1\r\n%session-window-changed $0 @1\r\n" + Self.stamp(Self.mac),
            at: 10
        ), 1)

        XCTAssertEqual(reduced(try lastResponse(harness)),
                       ["windowFacts(hydrated none)", "windowFacts(hydrated @1 80x24)", "stampObserved"])
        let facts: [String: Any] = [
            "windowListHydrated": true, "windowID": 1, "windowColumns": 80, "windowRows": 24, "windowAuthoritative": true,
        ]
        XCTAssertNotNil(inMessageOrder.reduce("windowFacts", at: 10, ["windowListHydrated": true]))
        XCTAssertNotNil(inMessageOrder.reduce("windowFacts", at: 10, facts))
        XCTAssertNotNil(inMessageOrder.reduce("stampObserved", at: 10, ["rawValues": [Self.mac]]))
        XCTAssertNotNil(stampsFirst.reduce("stampObserved", at: 10, ["rawValues": [Self.mac]]))
        XCTAssertNotNil(stampsFirst.reduce("windowFacts", at: 10, facts))
        XCTAssertEqual(hosted.snapshot(at: 10), inMessageOrder.snapshot(at: 10))
        XCTAssertNotEqual(hosted.snapshot(at: 10), stampsFirst.snapshot(at: 10), "the order decides the show")
    }

    /// Each layout of a read is judged at its step, as iOS judges each
    /// message: the window named at the show's own size resolves its held
    /// reply before a peer's resize later in the read. Judged only at the
    /// read's end, the resize decided the show instead.
    func testEachLayoutOfAReadIsJudgedAtItsStep() throws {
        let harness = SessionFeedHarness()
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        let hosted = try sessionHoldingAShowsOwnReply()
        let inMessageOrder = try sessionHoldingAShowsOwnReply()
        let lastOnly = try sessionHoldingAShowsOwnReply()
        XCTAssertEqual(harness.attach(hosted), 0)

        XCTAssertEqual(harness.feed(
            "%begin 1 1 1\r\n" + Self.window80x24 + "%end 1 1 1\r\n%session-window-changed $0 @1\r\n"
                + "%layout-change @1 b25d,100x30,0,0,1 b25d,100x30,0,0,1 *\r\n",
            at: 10
        ), 1)

        XCTAssertEqual(reduced(try lastResponse(harness)),
                       ["windowFacts(hydrated none)", "windowFacts(hydrated @1 80x24)", "windowFacts(hydrated @1 100x30)"])
        func facts(_ columns: Int, _ rows: Int) -> [String: Any] {
            ["windowListHydrated": true, "windowID": 1, "windowColumns": columns, "windowRows": rows, "windowAuthoritative": true]
        }
        XCTAssertNotNil(inMessageOrder.reduce("windowFacts", at: 10, ["windowListHydrated": true]))
        XCTAssertNotNil(inMessageOrder.reduce("windowFacts", at: 10, facts(80, 24)))
        XCTAssertNotNil(inMessageOrder.reduce("windowFacts", at: 10, facts(100, 30)))
        XCTAssertNotNil(lastOnly.reduce("windowFacts", at: 10, facts(100, 30)))
        XCTAssertEqual(hosted.snapshot(at: 10), inMessageOrder.snapshot(at: 10))
        XCTAssertNotEqual(hosted.snapshot(at: 10), lastOnly.snapshot(at: 10), "the intermediate layout decides the show")
    }

    /// A storm of layouts reports its first changes at their steps, then
    /// coalesces to the read's last, inside the response bound.
    func testALayoutStormCoalescesPastItsBudget() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n%begin 1 1 1\r\n" + Self.window80x24
            + "%end 1 1 1\r\n%session-window-changed $0 @1\r\n"), 0)
        let storm = (0..<40).map { "%layout-change @1 b25d,\(40 + $0)x24,0,0,1 b25d,\(40 + $0)x24,0,0,1 *\r\n" }.joined()

        XCTAssertEqual(harness.feed(storm, at: 10), 1)

        let facts = reduced(try lastResponse(harness)).filter { $0.hasPrefix("windowFacts(") }
        XCTAssertEqual(facts.count, 33, "\(facts)")
        XCTAssertEqual(facts.dropLast().last, "windowFacts(hydrated @1 71x24)")
        XCTAssertEqual(facts.last, "windowFacts(hydrated @1 79x24)")
    }

    /// A read with no stamp reports each change of its facts, the list's
    /// hydration before the window it names.
    func testATopologyReadReportsEachChangeOfItsFacts() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)

        XCTAssertEqual(harness.feed("%begin 1 1 1\r\n" + Self.window80x24 + "%end 1 1 1\r\n%session-window-changed $0 @1\r\n", at: 10), 1)

        XCTAssertEqual(harness.trace.events.last?["authorityReducedInFeed"] as? Bool, true)
        XCTAssertEqual(reduced(try lastResponse(harness)), ["windowFacts(hydrated none)", "windowFacts(hydrated @1 80x24)"])

        // The same facts again are no news; output says nothing to the session.
        XCTAssertEqual(harness.feed("%layout-change @1 b25d,80x24,0,0,1 b25d,80x24,0,0,1 *\r\n", at: 20), 0)
        XCTAssertNil(harness.trace.events.last?["authoritySession"])
        let quiet = session.snapshot(at: 30)
        XCTAssertEqual(harness.feed("%output %1 hello\r\n", at: 30), 0)
        let output = try XCTUnwrap(harness.trace.events.last)
        XCTAssertNil(output["authorityReducedInFeed"], "an output-only read never reaches the session")
        XCTAssertEqual(session.snapshot(at: 30), quiet)
    }

    /// The adapter's half of a switch rode in the lost event too.
    func testARedeliveredSwitchStillNamesTheSwitch() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        XCTAssertEqual(harness.feed("%session-changed $3 other\r\n", at: 10), 1)

        XCTAssertEqual(harness.redeliver(at: 20), 0)

        let event = try XCTUnwrap(harness.trace.events.last)
        XCTAssertNotNil(event["authoritySession"])
        XCTAssertEqual(event["controlSessionSwitched"] as? Bool, true)
        XCTAssertEqual(event["authorityReducedInFeed"] as? Bool, true, "the adapter must not reduce the switch again")
    }

    /// An event outside a feed says whether the session already holds its
    /// snapshot. An adapter that lost a switch read's event and recovers
    /// the snapshot by a resync must not reset the session a second time,
    /// which would drop the new session's verdict; a read it reduces itself
    /// is the adapter's to judge.
    func testAResyncSaysWhetherTheSessionHoldsItsSnapshot() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        XCTAssertEqual(harness.resync(), 0)
        XCTAssertNil(harness.trace.events.last?["authorityReducedInFeed"], "never reduced")

        XCTAssertEqual(harness.feed("%session-changed $3 other\r\n" + Self.stamp(Self.mac, session: 3), at: 10), 1)
        XCTAssertEqual(harness.resync(), 0)
        var resync = try XCTUnwrap(harness.trace.events.last)
        XCTAssertEqual(resync["authorityReducedInFeed"] as? Bool, true)
        XCTAssertNil(resync["controlSessionSwitched"], "the switch's adapter work rides in its own event")
        XCTAssertNil(resync["authoritySession"])

        // Output moves no revision: the session still holds the snapshot.
        XCTAssertEqual(harness.feed("%output %1 hello\r\n"), 0)
        XCTAssertEqual(harness.resync(), 0)
        XCTAssertEqual(harness.trace.events.last?["authorityReducedInFeed"] as? Bool, true)

        // A topology read left to the adapter: the snapshot is its to judge.
        XCTAssertEqual(harness.feed("%window-add @2\r\n"), 0)
        XCTAssertEqual(harness.resync(), 0)
        resync = try XCTUnwrap(harness.trace.events.last)
        XCTAssertNil(resync["authorityReducedInFeed"])
    }

    /// More edges than one session request carries are the adapter's, which
    /// splits them across requests.
    func testAReadPastTheRequestBoundLeavesItsStampsToTheAdapter() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        let edges = (0..<33).map { "v1 PEER\($0) 7 Mac" }
        XCTAssertEqual(harness.feed(edges.map { Self.stamp($0) }.joined(), at: 10), 0)
        assertRawEdge(harness, edges)

        let fits = (0..<32).map { "v1 OTHER\($0) 7 Mac" }
        XCTAssertEqual(harness.feed(fits.map { Self.stamp($0) }.joined(), at: 20), 1)
        XCTAssertNotNil(harness.trace.events.last?["authoritySession"])
    }

    /// More session changes than a user makes are the adapter's too: each
    /// one resets the session, and the response must stay inside its bound.
    func testAReadPastTheSessionChangeBoundIsLeftToTheAdapter() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        let untouched = session.snapshot(at: 10)
        let hops = (1...5).map { "%session-changed $\($0) s\($0)\r\n" }.joined()
        XCTAssertEqual(harness.feed(hops + Self.stamp(Self.own, session: 5), at: 10), 0)
        assertRawEdge(harness, [Self.own])
        XCTAssertEqual(harness.trace.events.last?["controlSessionSwitched"] as? Bool, true)
        XCTAssertEqual(session.snapshot(at: 10), untouched)

        let fits = (1...4).map { "%session-changed $\($0 + 10) t\($0)\r\n" }.joined()
        XCTAssertEqual(harness.feed(fits, at: 20), 1)
        XCTAssertEqual(harness.trace.events.last?["authorityReducedInFeed"] as? Bool, true)
    }

    /// A read fed from a callback would queue its response behind that
    /// callback, which may reduce the session again first.
    func testAReadFedFromACallbackLeavesItsStampsToTheAdapter() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n"), 0)
        let untouched = session.snapshot(at: 10)
        var nested: Int32?
        harness.trace.onEvent = {
            guard nested == nil else { return }
            nested = harness.feed(Self.stamp(Self.mac), at: 10)
        }
        // Unclocked, the outer read is the adapter's too: only the nested one is under test.
        XCTAssertEqual(harness.feed("%window-add @1\r\n"), 0)
        harness.trace.onEvent = nil
        XCTAssertEqual(nested, 0)
        assertRawEdge(harness, [Self.mac])
        XCTAssertEqual(session.snapshot(at: 10), untouched)
    }

    // MARK: - Delivery

    /// A partitioned event carries the response once, with the other
    /// one-shot edges, in its first envelope.
    func testASplitEventCarriesTheResponseInItsFirstEnvelopeOnly() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n%window-add @1\r\n"), 0)
        let command = Array("display-message -p x".utf8)
        let replyCount = 20_000
        for _ in 0..<replyCount {
            XCTAssertGreaterThan(command.withUnsafeBytes { raw in
                tesseraTmuxRuntimeSendCommand(
                    handle: harness.handle,
                    text: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count
                )
            }, 0)
        }
        let before = harness.trace.events.count
        let replies = (1...replyCount).map { "%begin 1 \($0) 1\r\nx\r\n%end 1 \($0) 1\r\n" }.joined()
        XCTAssertEqual(harness.feed(Self.stamp(Self.mac) + replies, at: 10), 1)

        let parts = Array(harness.trace.events.dropFirst(before))
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.map { $0["authoritySession"] != nil }, [true] + Array(repeating: false, count: parts.count - 1))
        XCTAssertEqual(parts.map { ($0["authorityStamps"] as? [String]) ?? ["missing"] }, Array(repeating: [], count: parts.count))
    }

    /// The session has moved on whether or not the event reached the
    /// adapter, and a repeat of its stamp reduces nothing: an adapter whose
    /// session did not adopt the result asks for it again, and gets the
    /// lost effects over the session's state now.
    func testALostResultIsDeliveredAgainOverTheSessionsStateNow() throws {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n%window-add @1\r\n"), 0)
        XCTAssertEqual(harness.redeliver(at: 5), -1, "nothing to deliver")
        XCTAssertEqual(harness.feed(Self.stamp(Self.mac), at: 10), 1)
        let lost = try XCTUnwrap(harness.trace.events.last?["authoritySession"] as? [String: Any])
        XCTAssertFalse(((lost["effects"] as? [Any]) ?? []).isEmpty, "precondition: the result had effects")
        // The adapter reduced the session again before it noticed.
        XCTAssertEqual(lost["channelLive"] as? Bool, true)
        let moved = try XCTUnwrap(session.reduce("channelLiveness", at: 15, ["channelLive": false]))
        XCTAssertEqual(moved["channelLive"] as? Bool, false, "\(moved)")
        let before = harness.trace.events.count

        XCTAssertEqual(harness.redeliver(at: 20), 0)

        let events = Array(harness.trace.events.dropFirst(before))
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertNotNil(event["snapshot"], "the lost event may have carried a newer snapshot")
        let redelivered = try XCTUnwrap(event["authoritySession"] as? [String: Any])
        XCTAssertEqual(redelivered["effects"] as? NSArray, lost["effects"] as? NSArray)
        XCTAssertEqual(redelivered["trace"] as? String, lost["trace"] as? String)
        var state = redelivered
        var now = try XCTUnwrap(session.reduce("snapshot", at: 20))
        for key in ["effects", "trace"] {
            state[key] = nil
            now[key] = nil
        }
        XCTAssertEqual(NSDictionary(dictionary: state), NSDictionary(dictionary: now), "the state is the session's now")
        XCTAssertEqual(state["channelLive"] as? Bool, false)
        XCTAssertEqual(harness.redeliver(at: 20), -1, "delivered once")
    }

    /// Only the last feed's result, and only until the next feed or attach.
    func testTheRetainedResultLastsUntilTheNextFeedOrAttach() {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n%window-add @1\r\n"), 0)
        XCTAssertEqual(harness.feed(Self.stamp(Self.mac), at: 10), 1)
        XCTAssertEqual(harness.feed("%window-renamed @1 x\r\n", at: 20), 0)
        XCTAssertEqual(harness.redeliver(at: 20), -1, "the next feed forgot it")

        XCTAssertEqual(harness.feed(Self.stamp("v1 PEER 8 iPad"), at: 30), 1)
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.redeliver(at: 30), -1, "an attach forgot it")
    }

    /// A callback that feeds or attaches again forgets the result its own
    /// feed carried: the feed must not reinstate it once its callbacks end,
    /// or a redelivery could replay one session's effects over another.
    func testAFeedOrAttachFromTheResultsOwnCallbackForgetsIt() {
        for invalidation in ["attach another session", "attach the same session", "feed again"] {
            let harness = SessionFeedHarness()
            let session = attachedSession()
            let other = attachedSession(seed: 200)
            XCTAssertEqual(harness.attach(session), 0)
            XCTAssertEqual(harness.feed("%session-changed $0 work\r\n%window-add @1\r\n"), 0)
            var invalidated = false
            harness.trace.onEvent = {
                guard !invalidated, harness.trace.events.last?["authoritySession"] != nil else { return }
                invalidated = true
                switch invalidation {
                case "attach another session": XCTAssertEqual(harness.attach(other), 0)
                case "attach the same session": XCTAssertEqual(harness.attach(session), 0)
                default: XCTAssertEqual(harness.feed("%window-renamed @1 x\r\n", at: 10), 0)
                }
            }
            XCTAssertEqual(harness.feed(Self.stamp(Self.mac), at: 10), 1, invalidation)
            harness.trace.onEvent = nil
            XCTAssertTrue(invalidated, invalidation)
            XCTAssertEqual(harness.redeliver(at: 10), -1, invalidation)
        }
    }

    /// From a callback, the answer would queue behind that callback, which
    /// can reduce the session again first.
    func testARedeliveryFromACallbackIsRefused() {
        let harness = SessionFeedHarness()
        let session = attachedSession()
        XCTAssertEqual(harness.attach(session), 0)
        XCTAssertEqual(harness.feed("%session-changed $0 work\r\n%window-add @1\r\n"), 0)
        XCTAssertEqual(harness.feed(Self.stamp(Self.mac), at: 10), 1)
        var nested: Int32?
        harness.trace.onEvent = {
            guard nested == nil else { return }
            nested = harness.redeliver(at: 10)
        }
        XCTAssertEqual(tesseraTmuxRuntimeResyncSnapshot(handle: harness.handle), 0)
        harness.trace.onEvent = nil
        XCTAssertEqual(nested, -1)
        XCTAssertEqual(harness.redeliver(at: 10), 0, "a refusal keeps it")
    }

    func testAttachRefusesADeadSessionAndAStaleRuntime() {
        let harness = SessionFeedHarness()
        let bogus = UnsafeMutableRawPointer(bitPattern: UInt.max)
        XCTAssertEqual(tesseraTmuxRuntimeAttachAuthoritySession(handle: harness.handle, session: bogus), -1)

        let session = attachedSession()
        let runtime = tesseraTmuxRuntimeCreate(callback: receiveSessionFeedABIEvent, context: nil)
        tesseraTmuxRuntimeDestroy(handle: runtime)
        XCTAssertEqual(tesseraTmuxRuntimeAttachAuthoritySession(handle: runtime, session: session.handle), -2)
        XCTAssertEqual(tesseraTmuxRuntimeRedeliverAuthorityResult(handle: runtime, nowMillis: 0), -2)
        XCTAssertEqual(
            Array("%session-changed $0 work\r\n".utf8).withUnsafeBytes { raw in
                tesseraTmuxRuntimeFeedAt(
                    handle: harness.handle,
                    bytes: raw.bindMemory(to: UInt8.self).baseAddress,
                    count: raw.count,
                    nowMillis: -1
                )
            },
            -1,
            "a clock never runs backwards past boot"
        )
    }
}
